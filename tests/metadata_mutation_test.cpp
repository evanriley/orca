#include "liborca/base/error.hpp"
#include "liborca/metadata/mutation.hpp"

#include <array>
#include <doctest/doctest.h>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using orca::metadata::Field;
using orca::metadata::mutation::Action;
using orca::metadata::mutation::Change;
using orca::metadata::mutation::FileIdentity;
using orca::metadata::mutation::GenreChange;
using orca::metadata::mutation::Move;
using orca::metadata::mutation::Plan;
using orca::metadata::mutation::State;
using orca::metadata::mutation::WriteTags;

auto identity(std::uint64_t size = 100, std::int64_t modified = 200) -> FileIdentity {
    FileIdentity value;
    value.size_bytes = size;
    value.modified_ns = modified;
    value.quick_hash = orca::storage::quick_hash::zero;
    value.content_hash = orca::storage::content_hash::Digest{};
    return value;
}

auto write_action(std::string path = "/music/example.flac") -> WriteTags {
    WriteTags write;
    write.path = std::move(path);
    write.expected = identity();
    return write;
}

}

TEST_CASE("mutation preview is inert and execution requires exact approval") {
    WriteTags write = write_action();
    write.changes.push_back(Change{.field = Field::title, .before = "Old", .after = "New"});
    auto plan = Plan::init(42, std::vector<Action>{write});
    REQUIRE(plan.has_value());

    const auto preview = plan->preview();
    CHECK(preview.tag_writes == 1);
    CHECK(preview.field_changes == 1);

    CHECK_FALSE(plan->begin_execution().has_value());

    auto wrong = plan->approval();
    wrong.plan_id = 41;
    CHECK(plan->approve(wrong).error().code == orca::ErrorCode::mutation_approval_mismatch);

    CHECK(plan->approve(plan->approval()).has_value());
    CHECK(plan->begin_execution().has_value());
    CHECK(plan->finish(true).has_value());
    CHECK(plan->state() == State::completed);
}

TEST_CASE("a plan writes a recording id only when it is a MusicBrainz id") {
    WriteTags valid = write_action();
    valid.changes.push_back(Change{.field = Field::musicbrainz_recording_id,
                                   .before = std::nullopt,
                                   .after = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"});
    auto plan = Plan::init(42, std::vector<Action>{valid});
    REQUIRE(plan.has_value());
    CHECK(plan->preview().field_changes == 1);

    WriteTags uppercase = write_action();
    uppercase.changes.push_back(Change{.field = Field::musicbrainz_recording_id,
                                       .before = std::nullopt,
                                       .after = "8F3471B5-7E6A-48DA-86A9-C1C07A0F5B4A"});
    const auto rejected = Plan::init(42, std::vector<Action>{uppercase});
    REQUIRE_FALSE(rejected.has_value());
    CHECK(rejected.error().code == orca::ErrorCode::invalid_mutation_plan);
}

TEST_CASE("a plan writes each release-level MusicBrainz id only when valid") {
    const std::array<Field, 4> fields{
        Field::musicbrainz_release_id, Field::musicbrainz_release_group_id,
        Field::musicbrainz_release_track_id, Field::musicbrainz_album_artist_id};
    for (const Field field : fields) {
        WriteTags valid = write_action();
        valid.changes.push_back(Change{.field = field,
                                       .before = std::nullopt,
                                       .after = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"});
        CHECK(Plan::init(42, std::vector<Action>{valid}).has_value());

        WriteTags invalid = write_action();
        invalid.changes.push_back(
            Change{.field = field, .before = std::nullopt, .after = "Some Album"});
        const auto rejected = Plan::init(42, std::vector<Action>{invalid});
        REQUIRE_FALSE(rejected.has_value());
        CHECK(rejected.error().code == orca::ErrorCode::invalid_mutation_plan);
    }
}

TEST_CASE("an approved plan cannot be altered through a caller-held alias") {
    std::vector<Action> actions{WriteTags{
        .path = "/music/original.mp3",
        .expected = identity(10, 20),
        .changes = {Change{
            .field = Field::title, .before = std::nullopt, .after = "Approved title"}},
        .genres = std::nullopt,
    }};
    auto plan = Plan::init(7, actions);
    REQUIRE(plan.has_value());
    const auto approval = plan->approval();
    CHECK(plan->approve(approval).has_value());

    std::get<WriteTags>(actions[0]).path = "/music/attacker.mp3";
    std::get<WriteTags>(actions[0]).changes[0].after = "Attacker title";
    actions[0] = Move{.source_path = "/music/original.mp3",
                      .destination_path = "/music/attacker.mp3",
                      .expected = identity(10, 20)};

    CHECK(plan->begin_execution().has_value());
    CHECK(plan->preview().tag_writes == 1);
    CHECK(std::get<WriteTags>(plan->actions()[0]).path == "/music/original.mp3");
    CHECK(std::get<WriteTags>(plan->actions()[0]).changes[0].after == "Approved title");
    CHECK(plan->sealed_digest() == approval.digest);
}

TEST_CASE("approval digests separate plans that differ only in a single value") {
    WriteTags first = write_action();
    first.changes.push_back(Change{.field = Field::title, .before = "Old", .after = "New"});
    WriteTags second = write_action();
    second.changes.push_back(Change{.field = Field::title, .before = "Old", .after = "Different"});

    auto first_plan = Plan::init(5, std::vector<Action>{first});
    auto second_plan = Plan::init(5, std::vector<Action>{second});
    REQUIRE(first_plan.has_value());
    REQUIRE(second_plan.has_value());
    CHECK(first_plan->sealed_digest() != second_plan->sealed_digest());

    const auto mismatch = second_plan->approve(first_plan->approval());
    REQUIRE_FALSE(mismatch.has_value());
    CHECK(mismatch.error().code == orca::ErrorCode::mutation_approval_mismatch);
}

TEST_CASE("a genre list alone is a tag write, sealed and copied away from the caller") {
    std::string genre_buffer = "Shoegaze";
    WriteTags write = write_action();
    write.genres = GenreChange{.before = {"Rock, Pop"}, .after = {genre_buffer, "Dream Pop"}};
    auto plan = Plan::init(9, std::vector<Action>{write});
    REQUIRE(plan.has_value());
    CHECK(plan->preview().field_changes == 1);

    genre_buffer = "Attacker";
    CHECK(std::get<WriteTags>(plan->actions()[0]).genres->after[0] == "Shoegaze");

    WriteTags reordered = write_action();
    reordered.genres = GenreChange{.before = {"Rock, Pop"}, .after = {"Dream Pop", "Shoegaze"}};
    auto reordered_plan = Plan::init(9, std::vector<Action>{reordered});
    REQUIRE(reordered_plan.has_value());
    const auto mismatch = reordered_plan->approve(plan->approval());
    REQUIRE_FALSE(mismatch.has_value());
    CHECK(mismatch.error().code == orca::ErrorCode::mutation_approval_mismatch);
    CHECK(plan->approve(plan->approval()).has_value());
}

TEST_CASE("a genre write refuses an empty list, a blank genre or one containing NUL") {
    const std::vector<std::vector<std::string>> invalid{
        {}, {""}, {"Rock", std::string("Po\0p", 4)}};
    for (const auto& after : invalid) {
        WriteTags write = write_action();
        write.genres = GenreChange{.before = {}, .after = after};
        const auto rejected = Plan::init(9, std::vector<Action>{write});
        REQUIRE_FALSE(rejected.has_value());
        CHECK(rejected.error().code == orca::ErrorCode::invalid_mutation_plan);
    }
}

TEST_CASE("file identity separates same-size edits that preserve a timestamp") {
    const FileIdentity base = identity(4096, 1234);

    FileIdentity edited = base;
    edited.quick_hash[0] = 1;
    CHECK_FALSE(base.eql(edited));

    FileIdentity middle = base;
    middle.content_hash->at(0) = 1;
    CHECK_FALSE(base.eql(middle));

    FileIdentity legacy = middle;
    legacy.content_hash = std::nullopt;
    CHECK(base.eql(legacy));
    CHECK(legacy.eql(base));
}

TEST_CASE("approval digests separate identities that differ only in content hash") {
    FileIdentity value = identity();
    WriteTags first = write_action();
    first.expected = value;
    first.changes.push_back(Change{.field = Field::title, .before = "Old", .after = "New"});

    value.content_hash->at(31) = 1;
    WriteTags second = write_action();
    second.expected = value;
    second.changes.push_back(Change{.field = Field::title, .before = "Old", .after = "New"});

    auto first_plan = Plan::init(5, std::vector<Action>{first});
    auto second_plan = Plan::init(5, std::vector<Action>{second});
    REQUIRE(first_plan.has_value());
    REQUIRE(second_plan.has_value());
    const auto mismatch = second_plan->approve(first_plan->approval());
    REQUIRE_FALSE(mismatch.has_value());
    CHECK(mismatch.error().code == orca::ErrorCode::mutation_approval_mismatch);
}

TEST_CASE("a plan refuses a file identity without a content hash") {
    FileIdentity missing;
    missing.size_bytes = 100;
    missing.modified_ns = 200;
    missing.quick_hash = orca::storage::quick_hash::zero;
    missing.content_hash = std::nullopt;

    WriteTags write = write_action();
    write.expected = missing;
    write.changes.push_back(Change{.field = Field::title, .before = "Old", .after = "New"});
    const auto write_plan = Plan::init(5, std::vector<Action>{write});
    REQUIRE_FALSE(write_plan.has_value());
    CHECK(write_plan.error().code == orca::ErrorCode::invalid_mutation_plan);

    const Move move{
        .source_path = "/music/a.flac", .destination_path = "/music/b.flac", .expected = missing};
    const auto move_plan = Plan::init(5, std::vector<Action>{move});
    REQUIRE_FALSE(move_plan.has_value());
    CHECK(move_plan.error().code == orca::ErrorCode::invalid_mutation_plan);
}
