#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/base/logging.hpp"
#include "liborca/metadata/file_mutation.hpp"
#include "liborca/metadata/journal.hpp"
#include "liborca/metadata/journal_lock.hpp"
#include "liborca/metadata/mutation.hpp"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace orca::metadata::executor {

enum class FaultPoint : std::uint8_t {
    after_journal_prepare,
    after_stage,
    after_stage_journaled,
    after_backup_copy,
    after_source_rename,
    after_move_rename,
    before_journal_commit,
    rollback_after_restore_copy,
    rollback_after_restore,
    undo_after_intent,
    undo_after_operation,
    recovery_after_operation,
};

struct Fault {
    FaultPoint point = FaultPoint::after_journal_prepare;
    std::uint32_t action_index = 0;
};

struct PruneSummary {
    std::uint64_t backups = 0;
    std::uint64_t bytes = 0;
};

enum class TagFormat : std::uint8_t { mpeg, flac };

class Executor {
public:
    Executor(journal::Store& store, const journal_lock::JournalLock& lock,
             std::optional<std::filesystem::path> backup_directory,
             std::optional<Fault> fault = std::nullopt)
        : store_(&store), lock_(&lock), backup_directory_(std::move(backup_directory)),
          fault_(fault) {
        ORCA_ASSERT(lock_ != nullptr);
    }

    [[nodiscard]] auto execute_plan(mutation::Plan& plan, std::uint64_t group_id) -> expected<void>;

    [[nodiscard]] auto undo_operation(std::int64_t operation_id) -> expected<void>;
    [[nodiscard]] auto undo_group(std::uint64_t group_id) -> expected<void>;
    [[nodiscard]] auto prune_backups(std::uint64_t older_than_s) -> expected<PruneSummary>;
    [[nodiscard]] auto recover_group(std::uint64_t group_id) -> expected<void>;
    [[nodiscard]] auto recover_operation(std::int64_t operation_id) -> expected<void>;

    [[nodiscard]] auto crashed() const -> bool {
        return crashed_;
    }

private:
    struct PreparedAction {
        std::int64_t id = 0;
        std::optional<std::string> stage_path;
        std::optional<std::string> backup_path;
    };

    struct CompletedAction {
        std::int64_t id = 0;
        std::uint32_t action_index = 0;
    };

    [[nodiscard]] auto prepare_actions(const mutation::Plan& plan, std::uint64_t group_id,
                                       const std::optional<std::string>& plan_backup_directory,
                                       std::vector<PreparedAction>& prepared) -> expected<void>;
    [[nodiscard]] auto check_plan(const mutation::Plan& plan)
        -> expected<std::optional<std::string>>;
    [[nodiscard]] auto execute_write_action(std::uint32_t action_index,
                                            const mutation::WriteTags& write,
                                            const std::vector<PreparedAction>& prepared,
                                            std::vector<CompletedAction>& completed)
        -> expected<void>;
    [[nodiscard]] auto execute_move_action(std::uint32_t action_index, const mutation::Move& move,
                                           const std::vector<PreparedAction>& prepared,
                                           std::vector<CompletedAction>& completed)
        -> expected<void>;
    void compensate(mutation::Plan& plan, const std::vector<PreparedAction>& prepared,
                    std::vector<CompletedAction>& completed);

    [[nodiscard]] auto plan_backup_directory(std::uint64_t plan_id) const -> expected<std::string>;
    [[nodiscard]] auto commit_write(const std::string& source_path, const std::string& stage_path,
                                    const std::string& backup_path,
                                    const mutation::FileIdentity& expected_identity,
                                    file_mutation::Interrupt interrupt) -> expected<void>;
    [[nodiscard]] auto group_produced_identity(const std::vector<CompletedAction>& actions,
                                               const std::string& path,
                                               const mutation::FileIdentity& current)
        -> expected<bool>;

    [[nodiscard]] auto recover_loaded(const journal::Operation& operation) -> expected<void>;
    [[nodiscard]] auto recover_move(const journal::Operation& operation) -> expected<void>;
    [[nodiscard]] auto recover_write_tags(const journal::Operation& operation) -> expected<void>;
    [[nodiscard]] auto finish_recovery_state(std::int64_t operation_id,
                                             journal::MutationState state) -> expected<void>;
    [[nodiscard]] auto finish_interrupted_undo(std::uint64_t group_id) -> expected<void>;
    [[nodiscard]] auto perform_group_undo(const std::vector<journal::Operation>& operations,
                                          std::uint64_t group_id) -> expected<void>;
    [[nodiscard]] auto cleanup_recovered_write(std::span<const std::string> temporaries,
                                               std::optional<std::string> backup_path,
                                               std::int64_t operation_id,
                                               journal::MutationState state) -> expected<void>;
    [[nodiscard]] auto validate_group_undo(const std::vector<journal::Operation>& operations)
        -> expected<void>;
    [[nodiscard]] auto reconcile(std::int64_t operation_id, journal::MutationState state,
                                 std::string_view message) -> expected<void>;
    [[nodiscard]] auto rollback_operation(std::int64_t operation_id,
                                          std::optional<file_mutation::Interrupt> interrupt)
        -> expected<void>;
    [[nodiscard]] auto discard_backup(const std::string& backup_path) -> expected<void>;
    [[nodiscard]] auto remove_empty_backup_directories(const std::string& backup_path)
        -> expected<void>;

    [[nodiscard]] auto transition(std::int64_t operation_id, journal::MutationState expected_state,
                                  journal::MutationState next,
                                  const std::optional<std::string>& message) -> expected<void>;
    [[nodiscard]] auto record_result_identity(std::int64_t operation_id,
                                              journal::MutationState expected_state,
                                              const mutation::FileIdentity& result)
        -> expected<void>;
    [[nodiscard]] auto commit_operation(std::int64_t operation_id,
                                        const mutation::FileIdentity& committed) -> expected<void>;

    [[nodiscard]] auto fault_matches(FaultPoint point, std::uint32_t action_index) const -> bool;
    [[nodiscard]] auto interrupt(FaultPoint point, std::uint32_t action_index) -> expected<void>;
    [[nodiscard]] auto commit_interrupt(std::uint32_t action_index) const
        -> std::optional<file_mutation::Interrupt>;
    [[nodiscard]] auto rollback_interrupt(std::uint32_t action_index) const
        -> std::optional<file_mutation::Interrupt>;
    void stop_if_stale(const Error& error);

    journal::Store* store_;
    const journal_lock::JournalLock* lock_;
    std::optional<std::filesystem::path> backup_directory_;
    std::optional<Fault> fault_;
    bool crashed_ = false;
    std::optional<std::uint32_t> failed_action_index_;
};

}
