#include "liborca/base/path.hpp"
#include "liborca/metadata/executor.hpp"
#include "liborca/metadata/id3v1.hpp"
#include "liborca/metadata/journal_lock.hpp"
#include "liborca/metadata/recovery.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

using orca::metadata::Field;
using orca::metadata::executor::Executor;
using orca::metadata::executor::Fault;
using orca::metadata::executor::FaultPoint;
using orca::metadata::file_mutation::backup_path;
using orca::metadata::file_mutation::identity;
using orca::metadata::file_mutation::plan_backup_directory;
using orca::metadata::file_mutation::sibling_path;
using orca::metadata::journal::MemoryStore;
using orca::metadata::journal::MutationState;
using orca::metadata::journal::Operation;
using orca::metadata::journal_lock::JournalLock;
using orca::metadata::mutation::Change;
using orca::metadata::mutation::FileIdentity;
using orca::metadata::mutation::Plan;

constexpr std::uint64_t plan_id = 1000;
constexpr std::uint64_t group_id = 1000;

std::uint64_t next_workspace = 0;

auto trailer(std::string_view title) -> std::string {
    const auto encoded =
        orca::metadata::id3v1::encode(orca::metadata::id3v1::Tag{.title = title,
                                                                 .artist = "Generated",
                                                                 .album = "Generated",
                                                                 .year = "2026",
                                                                 .comment = "Generated",
                                                                 .track_number = 1,
                                                                 .genre = 13});
    REQUIRE(encoded.has_value());
    return std::string(reinterpret_cast<const char*>(encoded->data()), encoded->size());
}

struct Harness {
    std::filesystem::path directory;
    std::filesystem::path source;
    std::filesystem::path second;
    std::filesystem::path backup_directory;
    std::filesystem::path lock_path;
    FileIdentity original;
    FileIdentity second_original;

    Harness() {
        directory = std::filesystem::temp_directory_path() /
                    ("orca-executor-test-" + std::to_string(next_workspace++));
        std::filesystem::remove_all(directory);
        std::filesystem::create_directories(directory);
        source = directory / "source.mp3";
        second = directory / "second.mp3";
        backup_directory = directory / "backups";
        lock_path = directory / "library.db.orca-journal.lock";
        REQUIRE(orca::fs::write_file(source, "\xff\xfb\x90\x64generated audio payload" +
                                                 trailer("Original"))
                    .has_value());
        REQUIRE(orca::fs::write_file(second, "\xff\xfb\x90\x64generated audio payload" +
                                                 trailer("Original"))
                    .has_value());
        original = *identity(source);
        second_original = *identity(second);
    }

    ~Harness() {
        std::filesystem::remove_all(directory);
    }

    [[nodiscard]] auto stage(std::uint32_t index) const -> std::string {
        return sibling_path(source, "stage", plan_id, index);
    }
    [[nodiscard]] auto backup(std::uint32_t index) const -> std::string {
        return backup_path(plan_backup_directory(backup_directory, plan_id), index, source);
    }
    [[nodiscard]] auto acquire() const -> JournalLock {
        auto lock = JournalLock::try_acquire(lock_path);
        REQUIRE(lock.has_value());
        REQUIRE(lock->has_value());
        return std::move(**lock);
    }
};

auto make_write_plan(std::vector<std::pair<std::filesystem::path, FileIdentity>> targets) -> Plan {
    std::vector<orca::metadata::mutation::Action> actions;
    for (auto& [path, expected] : targets) {
        orca::metadata::mutation::WriteTags write;
        write.path = path.string();
        write.expected = expected;
        write.changes.push_back(
            Change{.field = Field::title, .before = "Original", .after = "Replaced"});
        actions.push_back(std::move(write));
    }
    auto plan = Plan::init(plan_id, std::move(actions));
    REQUIRE(plan.has_value());
    REQUIRE(plan->approve(plan->approval()).has_value());
    return std::move(*plan);
}

auto read_title(const std::filesystem::path& path) -> std::string {
    const auto text = orca::fs::read_file(path, 1 << 20);
    REQUIRE(text.has_value());
    REQUIRE(text->size() >= 128);
    std::array<std::byte, 128> bytes{};
    std::memcpy(bytes.data(), text->data() + text->size() - 128, 128);
    const auto parsed = orca::metadata::id3v1::parse(bytes);
    REQUIRE(parsed.has_value());
    return std::string(parsed->title);
}
}

TEST_CASE("an approved plan journals and commits a tag write, and undo restores the original") {
    Harness harness;
    MemoryStore store;
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    REQUIRE(executor.execute_plan(plan, group_id).has_value());
    CHECK(read_title(harness.source) == "Replaced");
    CHECK(identity(harness.source)->eql(harness.original) == false);

    const auto ids = store.group_operation_ids(group_id);
    REQUIRE(ids.has_value());
    REQUIRE(ids->size() == 1);
    const auto operation = store.get((*ids)[0]);
    REQUIRE(operation.has_value());
    CHECK(operation->state == MutationState::committed);
    CHECK(operation->backup_path.has_value());
    CHECK(identity(*operation->backup_path)->eql(harness.original));
    CHECK_FALSE(std::filesystem::exists(harness.stage(0)));

    REQUIRE(executor.undo_group(group_id).has_value());
    CHECK(read_title(harness.source) == "Original");
    CHECK(identity(harness.source)->eql(harness.original));
    CHECK_FALSE(std::filesystem::exists(harness.backup(0)));
    CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
}

TEST_CASE("a tag write keeps the original in the backup directory and nothing beside the file") {
    Harness harness;
    MemoryStore store;
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    REQUIRE(executor.execute_plan(plan, group_id).has_value());

    CHECK(std::filesystem::exists(harness.backup(0)));
    CHECK_FALSE(std::filesystem::exists(harness.stage(0)));
    CHECK(identity(harness.backup(0))->eql(harness.original));
}

TEST_CASE("undo refuses a pruned write and changes nothing") {
    Harness harness;
    MemoryStore store;
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    REQUIRE(executor.execute_plan(plan, group_id).has_value());
    const auto ids = store.group_operation_ids(group_id);
    REQUIRE(ids.has_value());
    REQUIRE(store.clear_backup_path((*ids)[0]).has_value());

    const auto refused = executor.undo_group(group_id);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::tag_write_backup_pruned);
    CHECK(read_title(harness.source) == "Replaced");
}

TEST_CASE("undo reconciles a write whose backup is missing and changes nothing") {
    Harness harness;
    MemoryStore store;
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    REQUIRE(executor.execute_plan(plan, group_id).has_value());
    REQUIRE(std::filesystem::remove(harness.backup(0)));

    const auto refused = executor.undo_group(group_id);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::mutation_needs_reconciliation);
    CHECK(read_title(harness.source) == "Replaced");
    const auto ids = store.group_operation_ids(group_id);
    REQUIRE(ids.has_value());
    CHECK(*store.state((*ids)[0]) == MutationState::needs_reconciliation);
}

TEST_CASE("a tag write refuses a plan whose backup directory already exists") {
    Harness harness;
    MemoryStore store;
    REQUIRE(
        std::filesystem::create_directories(harness.backup_directory / std::to_string(plan_id)));
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    const auto refused = executor.execute_plan(plan, group_id);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::tag_write_backup_exists);
    CHECK(read_title(harness.source) == "Original");
}

TEST_CASE("a tag write refuses a read-only file before writing any file of its plan") {
    Harness harness;
    MemoryStore store;
    std::filesystem::permissions(harness.source, std::filesystem::perms::owner_read |
                                                     std::filesystem::perms::group_read |
                                                     std::filesystem::perms::others_read);
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    const auto refused = executor.execute_plan(plan, group_id);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_read_only);
    CHECK(read_title(harness.source) == "Original");
    CHECK_FALSE(std::filesystem::exists(harness.stage(0)));
    CHECK_FALSE(std::filesystem::exists(harness.backup(0)));
}

TEST_CASE("a tag write keeps the exact permission bits of the file it rewrites") {
    Harness harness;
    MemoryStore store;
    std::filesystem::permissions(harness.source, std::filesystem::perms::owner_read |
                                                     std::filesystem::perms::owner_write |
                                                     std::filesystem::perms::group_read);
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    REQUIRE(executor.execute_plan(plan, group_id).has_value());
    CHECK(std::filesystem::status(harness.source).permissions() ==
          (std::filesystem::perms::owner_read | std::filesystem::perms::owner_write |
           std::filesystem::perms::group_read));
}

TEST_CASE("pruning deletes a backup and clears its journal path, respecting the cutoff") {
    Harness harness;
    MemoryStore store;
    store.set_now(100);
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    REQUIRE(executor.execute_plan(plan, group_id).has_value());
    const auto ids = store.group_operation_ids(group_id);
    REQUIRE(ids.has_value());

    const auto too_young = executor.prune_backups(10);
    REQUIRE(too_young.has_value());
    CHECK(too_young->backups == 0);
    CHECK(std::filesystem::exists(harness.backup(0)));

    store.set_now(200);
    const auto pruned = executor.prune_backups(10);
    REQUIRE(pruned.has_value());
    CHECK(pruned->backups == 1);
    CHECK(pruned->bytes > 0);
    CHECK_FALSE(std::filesystem::exists(harness.backup(0)));
    const auto operation = store.get((*ids)[0]);
    REQUIRE(operation.has_value());
    CHECK_FALSE(operation->backup_path.has_value());
}

TEST_CASE("recovery drives every write fault point back to the original") {
    const std::array<FaultPoint, 6> points{
        FaultPoint::after_journal_prepare, FaultPoint::after_stage,
        FaultPoint::after_stage_journaled, FaultPoint::after_backup_copy,
        FaultPoint::after_source_rename,   FaultPoint::before_journal_commit};
    for (const FaultPoint point : points) {
        Harness harness;
        MemoryStore store;
        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory, Fault{.point = point});
        auto plan = make_write_plan({{harness.source, harness.original}});
        const auto outcome = executor.execute_plan(plan, group_id);
        REQUIRE_FALSE(outcome.has_value());
        CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
        CHECK(executor.crashed());

        const auto summary =
            orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
        REQUIRE(summary.has_value());
        CHECK(summary->groups == 1);
        CHECK(summary->operations == 1);
        CHECK(read_title(harness.source) == "Original");
        CHECK(identity(harness.source)->eql(harness.original));
        CHECK_FALSE(std::filesystem::exists(harness.stage(0)));
        CHECK_FALSE(std::filesystem::exists(harness.backup(0)));
        CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
    }
}

TEST_CASE("recovery drives every move fault point back to the original path") {
    const std::array<FaultPoint, 3> points{FaultPoint::after_journal_prepare,
                                           FaultPoint::after_stage_journaled,
                                           FaultPoint::after_move_rename};
    for (const FaultPoint point : points) {
        Harness harness;
        MemoryStore store;
        const std::filesystem::path destination = harness.directory / "moved.mp3";
        orca::metadata::mutation::Move move;
        move.source_path = harness.source.string();
        move.destination_path = destination.string();
        move.expected = harness.original;
        auto plan = Plan::init(plan_id, {orca::metadata::mutation::Action{move}});
        REQUIRE(plan.has_value());
        REQUIRE(plan->approve(plan->approval()).has_value());

        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory, Fault{.point = point});
        const auto outcome = executor.execute_plan(*plan, group_id);
        REQUIRE_FALSE(outcome.has_value());
        CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);

        const auto summary =
            orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
        REQUIRE(summary.has_value());
        CHECK(std::filesystem::exists(harness.source));
        CHECK_FALSE(std::filesystem::exists(destination));
        CHECK(identity(harness.source)->eql(harness.original));
    }
}

TEST_CASE("an interrupted undo finishes on the next recovery at every undo boundary") {
    const std::array<Fault, 4> faults{Fault{.point = FaultPoint::undo_after_intent},
                                      Fault{.point = FaultPoint::undo_after_operation},
                                      Fault{.point = FaultPoint::rollback_after_restore_copy},
                                      Fault{.point = FaultPoint::rollback_after_restore}};
    for (const Fault& fault : faults) {
        Harness harness;
        MemoryStore store;
        {
            auto lock = harness.acquire();
            Executor executor(store, lock, harness.backup_directory);
            auto plan = make_write_plan({{harness.source, harness.original}});
            REQUIRE(executor.execute_plan(plan, group_id).has_value());
        }
        {
            auto lock = harness.acquire();
            Executor executor(store, lock, harness.backup_directory, fault);
            const auto outcome = executor.undo_group(group_id);
            REQUIRE_FALSE(outcome.has_value());
            CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
        }
        auto lock = harness.acquire();
        const auto summary =
            orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
        REQUIRE(summary.has_value());
        CHECK(read_title(harness.source) == "Original");
        CHECK(identity(harness.source)->eql(harness.original));
        CHECK_FALSE(std::filesystem::exists(harness.backup(0)));
    }
}

TEST_CASE("a move plan commits and undo restores the source path") {
    Harness harness;
    MemoryStore store;
    const std::filesystem::path destination = harness.directory / "moved.mp3";
    orca::metadata::mutation::Move move;
    move.source_path = harness.source.string();
    move.destination_path = destination.string();
    move.expected = harness.original;
    auto plan = Plan::init(plan_id, {orca::metadata::mutation::Action{move}});
    REQUIRE(plan.has_value());
    REQUIRE(plan->approve(plan->approval()).has_value());

    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    REQUIRE(executor.execute_plan(*plan, group_id).has_value());
    CHECK_FALSE(std::filesystem::exists(harness.source));
    CHECK(std::filesystem::exists(destination));
    CHECK(identity(destination)->eql(harness.original));

    REQUIRE(executor.undo_group(group_id).has_value());
    CHECK(std::filesystem::exists(harness.source));
    CHECK_FALSE(std::filesystem::exists(destination));
    CHECK(identity(harness.source)->eql(harness.original));
}

namespace {

using orca::metadata::file_mutation::stage_flac;
using orca::metadata::file_mutation::stage_mpeg;
using orca::metadata::journal::MutationKind;
using orca::metadata::journal::OperationInput;
using orca::metadata::mutation::Action;
using orca::metadata::mutation::Move;
using orca::metadata::mutation::State;
using orca::metadata::mutation::WriteTags;

class ReadOnlyAfterStageStore : public MemoryStore {
public:
    explicit ReadOnlyAfterStageStore(std::filesystem::path source) : source_(std::move(source)) {}

    auto record_result_identity(std::int64_t operation_id, MutationState expected_state,
                                std::uint64_t size, std::int64_t modified_ns,
                                const orca::storage::quick_hash::Digest& digest,
                                const orca::storage::content_hash::Digest& content)
        -> orca::expected<void> override {
        const auto result = MemoryStore::record_result_identity(operation_id, expected_state, size,
                                                                modified_ns, digest, content);
        if (result) {
            std::filesystem::permissions(source_, std::filesystem::perms::owner_read |
                                                      std::filesystem::perms::group_read |
                                                      std::filesystem::perms::others_read);
        }
        return result;
    }

private:
    std::filesystem::path source_;
};

void expect_terminal(MemoryStore& store, std::int64_t operation_id) {
    const auto state = store.state(operation_id);
    REQUIRE(state.has_value());
    CHECK((*state == MutationState::rolled_back || *state == MutationState::needs_reconciliation));
}

auto write_action(const std::filesystem::path& path, const FileIdentity& expected) -> WriteTags {
    WriteTags write;
    write.path = path.string();
    write.expected = expected;
    write.changes.push_back(
        Change{.field = Field::title, .before = "Original", .after = "Replaced"});
    return write;
}

auto make_group_plan(const std::filesystem::path& first, const FileIdentity& first_identity,
                     const std::filesystem::path& second, const FileIdentity& second_identity)
    -> Plan {
    std::vector<Action> actions;
    actions.push_back(write_action(first, first_identity));
    actions.push_back(write_action(second, second_identity));
    auto plan = Plan::init(plan_id, std::move(actions));
    REQUIRE(plan.has_value());
    REQUIRE(plan->approve(plan->approval()).has_value());
    return std::move(*plan);
}

auto write_group(Harness& harness, MemoryStore& store) {
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan =
        make_group_plan(harness.source, harness.original, harness.second, harness.second_original);
    REQUIRE(executor.execute_plan(plan, group_id).has_value());
}

auto prepare_write(MemoryStore& store, const std::string& source, const FileIdentity& expected,
                   const std::string& stage, const std::string& backup) -> std::int64_t {
    OperationInput input;
    input.plan_id = plan_id;
    input.group_id = group_id;
    input.action_index = 0;
    input.kind = MutationKind::write_tags;
    input.source_path = source;
    input.stage_path = stage;
    input.backup_path = backup;
    input.expected_size = expected.size_bytes;
    input.expected_modified_ns = expected.modified_ns;
    input.expected_quick_hash = expected.quick_hash;
    input.expected_content_hash = expected.content_hash;
    const auto operation = store.prepare(input);
    REQUIRE(operation.has_value());
    return *operation;
}

auto commit_legacy_write(Harness& harness, MemoryStore& store) -> std::string {
    const std::string legacy_stage =
        harness.source.string() + ".orca-stage-" + std::to_string(plan_id) + "-0";
    const std::string legacy_backup =
        harness.source.string() + ".orca-backup-" + std::to_string(plan_id) + "-0";
    const auto operation = prepare_write(store, harness.source.string(), harness.original,
                                         legacy_stage, legacy_backup);
    REQUIRE(stage_mpeg(harness.source, legacy_stage, harness.original,
                       {Change{.field = Field::title, .before = "Original", .after = "Replaced"}},
                       std::nullopt)
                .has_value());
    const auto staged = identity(legacy_stage);
    REQUIRE(staged.has_value());
    REQUIRE(store
                .record_result_identity(operation, MutationState::planned, staged->size_bytes,
                                        staged->modified_ns, staged->quick_hash,
                                        *staged->content_hash)
                .has_value());
    REQUIRE(store.transition(operation, MutationState::planned, MutationState::staged, std::nullopt)
                .has_value());
    std::filesystem::rename(harness.source, legacy_backup);
    std::filesystem::rename(legacy_stage, harness.source);
    REQUIRE(store
                .commit(operation, staged->size_bytes, staged->modified_ns, staged->quick_hash,
                        *staged->content_hash)
                .has_value());
    return legacy_backup;
}

auto local_ids(MemoryStore& store) -> std::vector<std::int64_t> {
    const auto ids = store.group_operation_ids(group_id);
    REQUIRE(ids.has_value());
    return *ids;
}

}

TEST_CASE("a failed move rolls back an earlier tag write in the same group") {
    Harness harness;
    MemoryStore store;
    const auto move_source = harness.directory / "move-source.bin";
    const auto collision = harness.directory / "collision.bin";
    REQUIRE(orca::fs::write_file(move_source, "generated move source").has_value());
    REQUIRE(orca::fs::write_file(collision, "do not replace").has_value());
    const auto move_expected = identity(move_source);
    REQUIRE(move_expected.has_value());

    std::vector<Action> actions;
    actions.push_back(write_action(harness.source, harness.original));
    Move move;
    move.source_path = move_source.string();
    move.destination_path = collision.string();
    move.expected = *move_expected;
    actions.push_back(move);
    auto plan = Plan::init(plan_id, std::move(actions));
    REQUIRE(plan.has_value());
    REQUIRE(plan->approve(plan->approval()).has_value());

    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    const auto outcome = executor.execute_plan(*plan, group_id);
    REQUIRE_FALSE(outcome.has_value());
    CHECK(outcome.error().code == orca::ErrorCode::destination_exists);
    CHECK(plan->state() == State::failed);
    const auto ids = local_ids(store);
    REQUIRE(ids.size() == 2);
    CHECK(*store.state(ids[1]) == MutationState::rolled_back);
    expect_terminal(store, ids[0]);
    CHECK(read_title(harness.source) == "Original");
    CHECK(orca::fs::read_file(collision, 1024).value() == "do not replace");
    CHECK(orca::fs::read_file(move_source, 1024).value() == "generated move source");
}

TEST_CASE("recovery finishes a group rollback that was itself interrupted") {
    for (const auto point :
         {FaultPoint::rollback_after_restore_copy, FaultPoint::rollback_after_restore}) {
        Harness harness;
        MemoryStore store;
        const auto move_source = harness.directory / "move-source.bin";
        const auto collision = harness.directory / "collision.bin";
        REQUIRE(orca::fs::write_file(move_source, "generated move source").has_value());
        REQUIRE(orca::fs::write_file(collision, "do not replace").has_value());
        const auto move_expected = identity(move_source);
        REQUIRE(move_expected.has_value());

        std::vector<Action> actions;
        actions.push_back(write_action(harness.source, harness.original));
        Move move;
        move.source_path = move_source.string();
        move.destination_path = collision.string();
        move.expected = *move_expected;
        actions.push_back(move);
        auto plan = Plan::init(plan_id, std::move(actions));
        REQUIRE(plan.has_value());
        REQUIRE(plan->approve(plan->approval()).has_value());

        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory, Fault{.point = point});
        const auto outcome = executor.execute_plan(*plan, group_id);
        REQUIRE_FALSE(outcome.has_value());
        CHECK(outcome.error().code == orca::ErrorCode::destination_exists);
        CHECK(executor.crashed());

        const auto summary =
            orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
        REQUIRE(summary.has_value());
        for (const std::int64_t id : local_ids(store)) {
            expect_terminal(store, id);
        }
        CHECK(read_title(harness.source) == "Original");
        CHECK(orca::fs::read_file(collision, 1024).value() == "do not replace");
        CHECK(std::filesystem::exists(move_source));
        CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
    }
}

TEST_CASE(
    "recovery marks the committed actions of an interrupted write as undoing before unwinding") {
    Harness harness;
    MemoryStore store;
    {
        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory,
                          Fault{.point = FaultPoint::after_stage_journaled, .action_index = 1});
        auto plan = make_group_plan(harness.source, harness.original, harness.second,
                                    harness.second_original);
        const auto outcome = executor.execute_plan(plan, group_id);
        REQUIRE_FALSE(outcome.has_value());
        CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
    }
    const auto ids = local_ids(store);
    REQUIRE(ids.size() == 2);
    CHECK(*store.state(ids[1]) == MutationState::committed);
    CHECK(*store.state(ids[0]) == MutationState::staged);

    auto lock = harness.acquire();
    const auto interrupted = orca::metadata::recovery::recover_pending(
        store, lock, harness.backup_directory,
        Fault{.point = FaultPoint::recovery_after_operation, .action_index = 1});
    REQUIRE_FALSE(interrupted.has_value());
    CHECK(interrupted.error().code == orca::ErrorCode::simulated_power_loss);
    CHECK(*store.state(ids[1]) == MutationState::undoing);
    CHECK(*store.state(ids[0]) == MutationState::rolled_back);
    CHECK(read_title(harness.source) == "Replaced");

    const auto finished =
        orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
    REQUIRE(finished.has_value());
    CHECK(*store.state(ids[1]) == MutationState::rolled_back);
    CHECK(read_title(harness.source) == "Original");
    CHECK(read_title(harness.second) == "Original");
    CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
}

TEST_CASE("a crashed undo of a moved and re-tagged file restores the path before the bytes") {
    Harness harness;
    MemoryStore store;
    const auto destination = harness.directory / "moved.mp3";
    std::vector<Action> actions;
    actions.push_back(write_action(harness.source, harness.original));
    Move move;
    move.source_path = harness.source.string();
    move.destination_path = destination.string();
    move.expected = harness.original;
    actions.push_back(move);
    {
        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory);
        auto plan = Plan::init(plan_id, std::move(actions));
        REQUIRE(plan.has_value());
        REQUIRE(plan->approve(plan->approval()).has_value());
        REQUIRE(executor.execute_plan(*plan, group_id).has_value());
    }
    CHECK(read_title(destination) == "Replaced");

    {
        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory,
                          Fault{.point = FaultPoint::undo_after_intent});
        const auto outcome = executor.undo_group(group_id);
        REQUIRE_FALSE(outcome.has_value());
        CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
    }
    CHECK_FALSE(std::filesystem::exists(harness.source));

    auto lock = harness.acquire();
    const auto summary =
        orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
    REQUIRE(summary.has_value());
    for (const std::int64_t id : local_ids(store)) {
        CHECK(*store.state(id) == MutationState::rolled_back);
    }
    CHECK_FALSE(std::filesystem::exists(destination));
    CHECK(read_title(harness.source) == "Original");
    CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
}

TEST_CASE("a two-file undo crash sweep converges at every undo boundary and action index") {
    for (const auto point : {FaultPoint::undo_after_operation, FaultPoint::rollback_after_restore,
                             FaultPoint::rollback_after_restore_copy}) {
        Harness harness;
        MemoryStore store;
        write_group(harness, store);
        {
            auto lock = harness.acquire();
            Executor executor(store, lock, harness.backup_directory,
                              Fault{.point = point, .action_index = 1});
            const auto outcome = executor.undo_group(group_id);
            REQUIRE_FALSE(outcome.has_value());
            CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
        }
        auto lock = harness.acquire();
        const auto summary =
            orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
        REQUIRE(summary.has_value());
        for (const std::int64_t id : local_ids(store)) {
            CHECK(*store.state(id) == MutationState::rolled_back);
        }
        CHECK(read_title(harness.source) == "Original");
        CHECK(read_title(harness.second) == "Original");
        CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
    }
}

TEST_CASE("backups of a group being undone are never pruned") {
    Harness harness;
    MemoryStore store;
    write_group(harness, store);
    {
        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory,
                          Fault{.point = FaultPoint::undo_after_operation, .action_index = 1});
        const auto outcome = executor.undo_group(group_id);
        REQUIRE_FALSE(outcome.has_value());
        CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
    }
    const auto ids = local_ids(store);
    REQUIRE(ids.size() == 2);
    CHECK(*store.state(ids[1]) == MutationState::undoing);
    CHECK(*store.state(ids[0]) == MutationState::rolled_back);

    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    const auto pruned = executor.prune_backups(0);
    REQUIRE(pruned.has_value());
    CHECK(pruned->backups == 0);
    REQUIRE(std::filesystem::exists(harness.backup(0)));
    CHECK(identity(harness.backup(0))->eql(harness.original));

    REQUIRE(executor.undo_group(group_id).has_value());
    CHECK(read_title(harness.source) == "Original");
}

TEST_CASE("an undo that fails on one file keeps its intent and finishes on the next attempt") {
    Harness harness;
    MemoryStore store;
    write_group(harness, store);
    const std::string obstacle = sibling_path(harness.source, "restore", plan_id, 0);
    REQUIRE(std::filesystem::create_directory(obstacle));

    {
        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory);
        const auto outcome = executor.undo_group(group_id);
        REQUIRE_FALSE(outcome.has_value());
    }
    const auto ids = local_ids(store);
    REQUIRE(ids.size() == 2);
    CHECK(*store.state(ids[1]) == MutationState::undoing);
    CHECK(*store.state(ids[0]) == MutationState::rolled_back);
    CHECK(read_title(harness.source) == "Replaced");
    CHECK(read_title(harness.second) == "Original");

    REQUIRE(std::filesystem::remove(obstacle));
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    REQUIRE(executor.undo_group(group_id).has_value());
    CHECK(read_title(harness.source) == "Original");
    CHECK(read_title(harness.second) == "Original");
    CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
}

TEST_CASE("undo restores a write whose backup sits beside the music and leaves the music folder") {
    Harness harness;
    MemoryStore store;
    const std::string legacy_backup = commit_legacy_write(harness, store);
    CHECK(read_title(harness.source) == "Replaced");

    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    REQUIRE(executor.undo_group(group_id).has_value());
    CHECK(identity(harness.source)->eql(harness.original));
    CHECK_FALSE(std::filesystem::exists(legacy_backup));
    CHECK(std::filesystem::exists(harness.directory));
    CHECK(std::filesystem::exists(harness.source));
}

TEST_CASE("pruning deletes a legacy backup beside the music and leaves the music folder") {
    Harness harness;
    MemoryStore store;
    const std::string legacy_backup = commit_legacy_write(harness, store);

    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    const auto pruned = executor.prune_backups(0);
    REQUIRE(pruned.has_value());
    CHECK(pruned->backups == 1);
    CHECK(pruned->bytes == harness.original.size_bytes);
    CHECK_FALSE(std::filesystem::exists(legacy_backup));
    CHECK(std::filesystem::exists(harness.directory));

    const auto refused = executor.undo_group(group_id);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::tag_write_backup_pruned);
}

TEST_CASE("recovery restores a write journaled with its backup beside the music") {
    Harness harness;
    MemoryStore store;
    const std::string legacy_stage =
        harness.source.string() + ".orca-stage-" + std::to_string(plan_id) + "-0";
    const std::string legacy_backup =
        harness.source.string() + ".orca-backup-" + std::to_string(plan_id) + "-0";
    const auto operation = prepare_write(store, harness.source.string(), harness.original,
                                         legacy_stage, legacy_backup);
    REQUIRE(stage_mpeg(harness.source, legacy_stage, harness.original,
                       {Change{.field = Field::title, .before = "Original", .after = "Replaced"}},
                       std::nullopt)
                .has_value());
    const auto staged = identity(legacy_stage);
    REQUIRE(staged.has_value());
    REQUIRE(store
                .record_result_identity(operation, MutationState::planned, staged->size_bytes,
                                        staged->modified_ns, staged->quick_hash,
                                        *staged->content_hash)
                .has_value());
    REQUIRE(store.transition(operation, MutationState::planned, MutationState::staged, std::nullopt)
                .has_value());
    std::filesystem::rename(harness.source, legacy_backup);
    std::filesystem::rename(legacy_stage, harness.source);
    CHECK(read_title(harness.source) == "Replaced");

    auto lock = harness.acquire();
    const auto summary =
        orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
    REQUIRE(summary.has_value());
    CHECK(*store.state(operation) == MutationState::rolled_back);
    CHECK(identity(harness.source)->eql(harness.original));
    CHECK_FALSE(std::filesystem::exists(legacy_backup));
    CHECK(std::filesystem::exists(harness.directory));
}

TEST_CASE("undoing a group that was already undone reports it") {
    Harness harness;
    MemoryStore store;
    write_group(harness, store);
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    REQUIRE(executor.undo_group(group_id).has_value());

    const auto again = executor.undo_group(group_id);
    REQUIRE_FALSE(again.has_value());
    CHECK(again.error().code == orca::ErrorCode::mutation_group_already_undone);
    CHECK(read_title(harness.source) == "Original");
}

TEST_CASE("undoing a group with a reconciled operation reports reconciliation") {
    Harness harness;
    MemoryStore store;
    write_group(harness, store);
    const auto current = orca::fs::read_file(harness.second, 1 << 20);
    REQUIRE(current.has_value());
    REQUIRE(orca::fs::write_file(harness.second, std::string(*current) + "external").has_value());

    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    const auto first = executor.undo_group(group_id);
    REQUIRE_FALSE(first.has_value());
    CHECK(first.error().code == orca::ErrorCode::mutation_needs_reconciliation);
    const auto second = executor.undo_group(group_id);
    REQUIRE_FALSE(second.has_value());
    CHECK(second.error().code == orca::ErrorCode::mutation_needs_reconciliation);
    const auto ids = local_ids(store);
    REQUIRE(ids.size() == 2);
    CHECK(*store.state(ids[1]) == MutationState::committed);
    CHECK(*store.state(ids[0]) == MutationState::needs_reconciliation);
    CHECK(read_title(harness.source) == "Replaced");
}

TEST_CASE("recovery keeps every file and counts needs-reconciliation when the original cannot be "
          "proven") {
    for (const int scenario : {0, 1, 2}) {
        Harness harness;
        MemoryStore store;
        {
            auto lock = harness.acquire();
            Executor executor(store, lock, harness.backup_directory,
                              Fault{.point = FaultPoint::after_source_rename});
            auto plan = make_write_plan({{harness.source, harness.original}});
            const auto outcome = executor.execute_plan(plan, group_id);
            REQUIRE_FALSE(outcome.has_value());
            CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
        }
        if (scenario == 0) {
            REQUIRE(std::filesystem::remove(harness.backup(0)));
        } else {
            if (scenario == 1) {
                const int descriptor = ::open(harness.backup(0).c_str(), O_RDWR);
                REQUIRE(descriptor >= 0);
                REQUIRE(::pwrite(descriptor, "damaged", 7, 0) == 7);
                ::close(descriptor);
            } else {
                const int descriptor = ::open(harness.source.c_str(), O_RDWR);
                REQUIRE(descriptor >= 0);
                struct stat info{};
                REQUIRE(::fstat(descriptor, &info) == 0);
                REQUIRE(::pwrite(descriptor, "EDITED", 6, info.st_size / 2) == 6);
                timespec times[2]{info.st_atim, info.st_mtim};
                REQUIRE(::futimens(descriptor, times) == 0);
                ::close(descriptor);
            }
        }
        auto lock = harness.acquire();
        const auto summary =
            orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
        REQUIRE(summary.has_value());
        CHECK(summary->needs_reconciliation == 1);
        const auto ids = local_ids(store);
        REQUIRE(ids.size() == 1);
        const auto recovered = store.get(ids[0]);
        REQUIRE(recovered.has_value());
        CHECK(recovered->state == MutationState::needs_reconciliation);
        REQUIRE(recovered->error.has_value());
        if (scenario == 2) {
            CHECK(*recovered->error == "tag target changed externally");
        } else {
            CHECK(*recovered->error ==
                  "the staged replacement is in place and its backup is missing or damaged");
        }
        CHECK(read_title(harness.source) == "Replaced");
    }
}

TEST_CASE("recovery keeps the error a failed write recorded") {
    Harness harness;
    MemoryStore store;
    const auto operation = prepare_write(store, harness.source.string(), harness.original,
                                         harness.stage(0), harness.backup(0));
    REQUIRE(store
                .transition(operation, MutationState::planned, MutationState::failed,
                            std::string("AccessDenied"))
                .has_value());

    auto lock = harness.acquire();
    const auto summary =
        orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
    REQUIRE(summary.has_value());
    const auto recovered = store.get(operation);
    REQUIRE(recovered.has_value());
    CHECK(recovered->state == MutationState::rolled_back);
    REQUIRE(recovered->error.has_value());
    CHECK(*recovered->error == "AccessDenied");
}

TEST_CASE("a tag write refuses a file made read-only after its stage was built") {
    Harness harness;
    ReadOnlyAfterStageStore store(harness.source);
    auto lock = harness.acquire();
    Executor executor(store, lock, harness.backup_directory);
    auto plan = make_write_plan({{harness.source, harness.original}});
    const auto refused = executor.execute_plan(plan, group_id);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_read_only);
    CHECK(identity(harness.source)->eql(harness.original));
    CHECK(read_title(harness.source) == "Original");
    CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
}

TEST_CASE(
    "recovery finishing an interrupted undo refuses a read-only file and retries once writable") {
    Harness harness;
    MemoryStore store;
    write_group(harness, store);
    {
        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory,
                          Fault{.point = FaultPoint::undo_after_intent});
        const auto outcome = executor.undo_group(group_id);
        REQUIRE_FALSE(outcome.has_value());
        CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
    }
    std::filesystem::permissions(harness.source, std::filesystem::perms::owner_read |
                                                     std::filesystem::perms::group_read |
                                                     std::filesystem::perms::others_read);

    auto lock = harness.acquire();
    const auto refused =
        orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_read_only);
    CHECK(read_title(harness.source) == "Replaced");

    std::filesystem::permissions(harness.source, std::filesystem::perms::owner_read |
                                                     std::filesystem::perms::owner_write);
    const auto finished =
        orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
    REQUIRE(finished.has_value());
    CHECK(read_title(harness.source) == "Original");
    CHECK(read_title(harness.second) == "Original");
}

TEST_CASE("recovery rolling back an interrupted write refuses a read-only file and retries once "
          "it is writable") {
    Harness harness;
    MemoryStore store;
    {
        auto lock = harness.acquire();
        Executor executor(store, lock, harness.backup_directory,
                          Fault{.point = FaultPoint::after_source_rename});
        auto plan = make_write_plan({{harness.source, harness.original}});
        const auto outcome = executor.execute_plan(plan, group_id);
        REQUIRE_FALSE(outcome.has_value());
        CHECK(outcome.error().code == orca::ErrorCode::simulated_power_loss);
    }

    std::filesystem::permissions(harness.source, std::filesystem::perms::owner_read |
                                                     std::filesystem::perms::group_read |
                                                     std::filesystem::perms::others_read);

    auto lock = harness.acquire();
    const auto refused =
        orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_read_only);
    CHECK(read_title(harness.source) == "Replaced");

    std::filesystem::permissions(harness.source, std::filesystem::perms::owner_read |
                                                     std::filesystem::perms::owner_write);
    const auto finished =
        orca::metadata::recovery::recover_pending(store, lock, harness.backup_directory);
    REQUIRE(finished.has_value());
    CHECK(read_title(harness.source) == "Original");
    CHECK(identity(harness.source)->eql(harness.original));
    CHECK_FALSE(std::filesystem::exists(harness.stage(0)));
    CHECK_FALSE(std::filesystem::exists(harness.backup(0)));
    CHECK_FALSE(std::filesystem::exists(harness.backup_directory));
}
