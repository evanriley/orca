#include "liborca/metadata/vorbis_comment.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace {

using orca::metadata::Field;
using orca::metadata::ObservedTags;
using orca::metadata::mutation::Change;
using orca::metadata::mutation::GenreChange;

void put_u32le(std::vector<std::byte>& out, std::uint32_t value) {
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((value >> (index * 8U)) & 0xffU));
    }
}

void append_text(std::vector<std::byte>& out, std::string_view text) {
    for (const char value : text) {
        out.push_back(static_cast<std::byte>(value));
    }
}

auto comment_payload(const std::vector<std::string>& entries) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    const std::string vendor = "test";
    put_u32le(out, static_cast<std::uint32_t>(vendor.size()));
    append_text(out, vendor);
    put_u32le(out, static_cast<std::uint32_t>(entries.size()));
    for (const auto& entry : entries) {
        put_u32le(out, static_cast<std::uint32_t>(entry.size()));
        append_text(out, entry);
    }
    return out;
}

auto parse_payload(orca::metadata::Arena& arena, std::span<const std::byte> payload)
    -> ObservedTags {
    const auto tags = orca::metadata::vorbis_comment::parse(arena, payload);
    REQUIRE(tags.has_value());
    return *tags;
}

auto apply_rewrite(std::span<const std::byte> payload, const std::vector<Change>& changes,
                   const std::optional<GenreChange>& genres) -> std::vector<std::byte> {
    const auto rewritten = orca::metadata::vorbis_comment::rewrite(payload, changes, genres);
    REQUIRE(rewritten.has_value());
    return *rewritten;
}

auto count_entries(std::span<const std::byte> payload, std::string_view key) -> std::size_t {
    auto entries = orca::metadata::vorbis_comment::Entries::init(payload);
    REQUIRE(entries.has_value());
    std::size_t count = 0;
    while (true) {
        const auto entry = entries->next();
        REQUIRE(entry.has_value());
        if (!*entry) {
            break;
        }
        const auto lower = [](char value) {
            return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
        };
        if ((*entry)->key.size() != key.size()) {
            continue;
        }
        bool equal = true;
        for (std::size_t index = 0; index < key.size(); ++index) {
            if (lower((*entry)->key[index]) != lower(key[index])) {
                equal = false;
                break;
            }
        }
        if (equal) {
            ++count;
        }
    }
    return count;
}

auto contains_text(std::span<const std::byte> haystack, std::string_view needle) -> bool {
    const std::string_view text(reinterpret_cast<const char*>(haystack.data()), haystack.size());
    return text.find(needle) != std::string_view::npos;
}

}

TEST_CASE("a Vorbis rewrite preserves unknown entries and supports UTF-8") {
    const auto payload =
        comment_payload({"TITLE=Old title", "CUSTOM=preserved", "ARTIST=Old artist"});
    const auto rewritten = apply_rewrite(
        payload,
        {Change{.field = Field::title, .before = "Old title", .after = "N\u00e9w title"},
         Change{.field = Field::artist, .before = "Old artist", .after = std::nullopt}},
        std::nullopt);
    CHECK(contains_text(rewritten, "TITLE=N\u00e9w title"));
    CHECK(contains_text(rewritten, "CUSTOM=preserved"));
    CHECK_FALSE(contains_text(rewritten, "ARTIST="));
}

TEST_CASE("a Vorbis rewrite validates framing and create makes a new comment block") {
    const std::string_view short_payload = "short";
    const auto invalid = orca::metadata::vorbis_comment::rewrite(
        std::span<const std::byte>(reinterpret_cast<const std::byte*>(short_payload.data()),
                                   short_payload.size()),
        {}, std::nullopt);
    REQUIRE_FALSE(invalid.has_value());
    CHECK(invalid.error().code == orca::ErrorCode::invalid_vorbis_comment);

    const auto created = orca::metadata::vorbis_comment::create(
        {Change{.field = Field::album, .before = std::nullopt, .after = "Generated album"}},
        std::nullopt);
    REQUIRE(created.has_value());
    CHECK(contains_text(*created, "ALBUM=Generated album"));
}

TEST_CASE("a rewrite matches aliased keys, n/total numbers and truth values") {
    const auto payload = comment_payload({"ALBUM ARTIST=Old Artist", "TRACKNUMBER=2/9",
                                          "COMPILATION=true", "YEAR=1999", "COMMENT=kept"});
    orca::metadata::Arena before_arena;
    const auto before = parse_payload(before_arena, payload);
    CHECK(before.album_artist == std::optional<std::string_view>("Old Artist"));

    const auto rewritten = apply_rewrite(
        payload,
        {Change{.field = Field::album_artist, .before = "Old Artist", .after = "New Artist"},
         Change{.field = Field::track_number, .before = "2", .after = "5"},
         Change{.field = Field::compilation, .before = "1", .after = "0"},
         Change{.field = Field::date, .before = "1999", .after = "2024"}},
        std::nullopt);
    orca::metadata::Arena after_arena;
    const auto after = parse_payload(after_arena, rewritten);
    CHECK(after.album_artist == std::optional<std::string_view>("New Artist"));
    CHECK(after.track_number == std::optional<std::uint32_t>(5));
    CHECK(after.track_total == std::optional<std::uint32_t>(9));
    CHECK(after.compilation == std::optional<bool>(false));
    CHECK(after.date == std::optional<std::string_view>("2024"));
    CHECK_FALSE(contains_text(rewritten, "ALBUM ARTIST="));
    CHECK_FALSE(contains_text(rewritten, "YEAR="));
    CHECK(contains_text(rewritten, "COMMENT=kept"));
}

TEST_CASE("a recording id rewrite replaces the existing MUSICBRAINZ_TRACKID in place") {
    const std::string_view old_id = "11111111-2222-4333-8444-555555555555";
    const std::string_view new_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    const auto payload =
        comment_payload({"TITLE=Kept", std::string("musicbrainz_trackid=") + std::string(old_id),
                         "MUSICBRAINZ_RELEASETRACKID=release-track-uuid"});
    const auto rewritten = apply_rewrite(payload,
                                         {Change{.field = Field::musicbrainz_recording_id,
                                                 .before = std::string(old_id),
                                                 .after = std::string(new_id)}},
                                         std::nullopt);
    orca::metadata::Arena arena;
    const auto after = parse_payload(arena, rewritten);
    CHECK(after.musicbrainz_recording_id == std::optional<std::string_view>(new_id));
    CHECK(after.musicbrainz_release_track_id ==
          std::optional<std::string_view>("release-track-uuid"));
    CHECK(after.title == std::optional<std::string_view>("Kept"));
    CHECK_FALSE(contains_text(rewritten, old_id));
    CHECK(count_entries(rewritten, "MUSICBRAINZ_TRACKID") == 1);
}

TEST_CASE("a composer and comment rewrite replaces in any case and keeps every other entry") {
    const std::vector<std::string> kept = {
        "TITLE=Kept", "REPLAYGAIN_TRACK_GAIN=-6.50 dB", "DESCRIPTION=Liner notes",
        "ENCODER=reference libFLAC 1.4.3", "Lyricist=Someone Else"};
    const auto payload =
        comment_payload({kept[0], "composer=Old Composer", kept[1], "Comment=Old note", kept[2],
                         "COMMENT=Second note", kept[3], kept[4]});
    const auto rewritten = apply_rewrite(
        payload,
        {Change{.field = Field::composer, .before = "Old Composer", .after = "Nick Drake"},
         Change{.field = Field::comment,
                .before = "Old note",
                .after = "\u03a9\u03bc\u03ad\u03b3\u03b1 remaster"}},
        std::nullopt);
    orca::metadata::Arena arena;
    const auto after = parse_payload(arena, rewritten);
    CHECK(after.composer == std::optional<std::string_view>("Nick Drake"));
    CHECK(after.comment ==
          std::optional<std::string_view>("\u03a9\u03bc\u03ad\u03b3\u03b1 remaster"));
    CHECK(after.title == std::optional<std::string_view>("Kept"));
    for (const auto& entry : kept) {
        CHECK(contains_text(rewritten, entry));
    }
    CHECK(count_entries(rewritten, "COMMENT") == 1);
    CHECK(count_entries(rewritten, "COMPOSER") == 1);
    CHECK(contains_text(rewritten, "COMMENT=\u03a9\u03bc\u03ad\u03b3\u03b1 remaster"));
    CHECK(contains_text(rewritten, "COMPOSER=Nick Drake"));
}

TEST_CASE("a comment read from DESCRIPTION is the precondition and DESCRIPTION is kept") {
    const auto payload = comment_payload({"TITLE=Kept", "DESCRIPTION=Liner notes"});
    const auto refused = orca::metadata::vorbis_comment::rewrite(
        payload, {Change{.field = Field::comment, .before = "Something else", .after = "New note"}},
        std::nullopt);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::metadata_precondition_changed);

    const auto rewritten = apply_rewrite(
        payload, {Change{.field = Field::comment, .before = "Liner notes", .after = "New note"}},
        std::nullopt);
    orca::metadata::Arena arena;
    const auto after = parse_payload(arena, rewritten);
    CHECK(after.comment == std::optional<std::string_view>("New note"));
    CHECK(contains_text(rewritten, "DESCRIPTION=Liner notes"));
}

TEST_CASE("clearing the comment removes every COMMENT entry and leaves COMPOSER") {
    const auto payload =
        comment_payload({"COMPOSER=Nick Drake", "COMMENT=Old note", "comment=Another"});
    const auto rewritten = apply_rewrite(
        payload, {Change{.field = Field::comment, .before = "Old note", .after = std::nullopt}},
        std::nullopt);
    orca::metadata::Arena arena;
    const auto after = parse_payload(arena, rewritten);
    CHECK_FALSE(after.comment.has_value());
    CHECK(after.composer == std::optional<std::string_view>("Nick Drake"));
    CHECK(count_entries(rewritten, "COMMENT") == 0);
}

TEST_CASE("a genre rewrite replaces every GENRE entry in any case with one per genre") {
    const auto payload =
        comment_payload({"genre=Indie Rock, Rock", "TITLE=Kept", "GENRE= ", "Genre=Pop"});
    const GenreChange changed{.before = {"Indie Rock, Rock", "Pop"},
                              .after = {"Shoegaze", "Dream Pop"}};
    const auto rewritten = apply_rewrite(payload, {}, changed);
    orca::metadata::Arena arena;
    const auto after = parse_payload(arena, rewritten);
    REQUIRE(after.genres.size() == 2);
    CHECK(after.genres[0] == "Shoegaze");
    CHECK(after.genres[1] == "Dream Pop");
    CHECK(after.title == std::optional<std::string_view>("Kept"));
    CHECK(count_entries(rewritten, "GENRE") == 2);
    CHECK_FALSE(contains_text(rewritten, "Indie Rock"));

    const auto created = orca::metadata::vorbis_comment::create(
        {}, std::optional<GenreChange>(GenreChange{.before = {}, .after = {"Jazz"}}));
    REQUIRE(created.has_value());
    orca::metadata::Arena created_arena;
    const auto created_tags = parse_payload(created_arena, *created);
    REQUIRE(created_tags.genres.size() == 1);
    CHECK(created_tags.genres[0] == "Jazz");
}

TEST_CASE("a genre rewrite refuses a file whose genres are no longer the ones previewed") {
    const auto payload = comment_payload({"GENRE=Rock", "GENRE=Pop"});
    const std::vector<std::vector<std::string>> wrong{
        {"Rock"}, {"Pop", "Rock"}, {"Rock", "Pop", "Jazz"}, {}};
    for (const auto& before : wrong) {
        const auto refused = orca::metadata::vorbis_comment::rewrite(
            payload, {},
            std::optional<GenreChange>(GenreChange{.before = before, .after = {"Jazz"}}));
        REQUIRE_FALSE(refused.has_value());
        CHECK(refused.error().code == orca::ErrorCode::metadata_precondition_changed);
    }
    const auto refused = orca::metadata::vorbis_comment::create(
        {}, std::optional<GenreChange>(GenreChange{.before = {"Rock"}, .after = {"Jazz"}}));
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::metadata_precondition_changed);
}

TEST_CASE("a release id rewrite replaces every MUSICBRAINZ_ALBUMID entry and keeps other keys") {
    const std::string_view old_id = "11111111-2222-4333-8444-555555555555";
    const std::string_view second_old_id = "22222222-3333-4444-8555-666666666666";
    const std::string_view new_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    const std::string_view recording_id = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
    const auto payload = comment_payload(
        {"TITLE=Kept", std::string("musicbrainz_albumid=") + std::string(old_id),
         std::string("MUSICBRAINZ_TRACKID=") + std::string(recording_id),
         std::string("MusicBrainz_AlbumId=") + std::string(second_old_id), "CUSTOM=preserved"});
    const auto rewritten = apply_rewrite(payload,
                                         {Change{.field = Field::musicbrainz_release_id,
                                                 .before = std::string(old_id),
                                                 .after = std::string(new_id)}},
                                         std::nullopt);
    orca::metadata::Arena arena;
    const auto after = parse_payload(arena, rewritten);
    CHECK(after.musicbrainz_release_id == std::optional<std::string_view>(new_id));
    CHECK(after.musicbrainz_recording_id == std::optional<std::string_view>(recording_id));
    CHECK(after.title == std::optional<std::string_view>("Kept"));
    CHECK(
        contains_text(rewritten, std::string("MUSICBRAINZ_TRACKID=") + std::string(recording_id)));
    CHECK(contains_text(rewritten, "CUSTOM=preserved"));
    CHECK_FALSE(contains_text(rewritten, old_id));
    CHECK_FALSE(contains_text(rewritten, second_old_id));
    CHECK(contains_text(rewritten, std::string("MUSICBRAINZ_ALBUMID=") + std::string(new_id)));
    CHECK(count_entries(rewritten, "MUSICBRAINZ_ALBUMID") == 1);
}

TEST_CASE("every release-level MusicBrainz id is written under Picard's Vorbis key") {
    const std::string_view release_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    const std::string_view release_group_id = "0b6a3a3e-3b2c-4c8e-9a51-1f2d3c4b5a69";
    const std::string_view release_track_id = "c2f7b3a4-5d6e-4f80-9a1b-2c3d4e5f6a7b";
    const std::string_view album_artist_id = "d4e5f6a7-b8c9-4d0e-8f1a-2b3c4d5e6f70";
    const auto created =
        orca::metadata::vorbis_comment::create({Change{.field = Field::musicbrainz_release_id,
                                                       .before = std::nullopt,
                                                       .after = std::string(release_id)},
                                                Change{.field = Field::musicbrainz_release_group_id,
                                                       .before = std::nullopt,
                                                       .after = std::string(release_group_id)},
                                                Change{.field = Field::musicbrainz_release_track_id,
                                                       .before = std::nullopt,
                                                       .after = std::string(release_track_id)},
                                                Change{.field = Field::musicbrainz_album_artist_id,
                                                       .before = std::nullopt,
                                                       .after = std::string(album_artist_id)}},
                                               std::nullopt);
    REQUIRE(created.has_value());
    orca::metadata::Arena arena;
    const auto tags = parse_payload(arena, *created);
    CHECK(tags.musicbrainz_release_id == std::optional<std::string_view>(release_id));
    CHECK(tags.musicbrainz_release_group_id == std::optional<std::string_view>(release_group_id));
    CHECK(tags.musicbrainz_release_track_id == std::optional<std::string_view>(release_track_id));
    CHECK(tags.musicbrainz_album_artist_id == std::optional<std::string_view>(album_artist_id));
    for (const std::string& entry :
         {std::string("MUSICBRAINZ_ALBUMID=") + std::string(release_id),
          std::string("MUSICBRAINZ_RELEASEGROUPID=") + std::string(release_group_id),
          std::string("MUSICBRAINZ_RELEASETRACKID=") + std::string(release_track_id),
          std::string("MUSICBRAINZ_ALBUMARTISTID=") + std::string(album_artist_id)}) {
        CHECK(contains_text(*created, entry));
    }
}
