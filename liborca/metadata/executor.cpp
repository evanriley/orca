#include "liborca/metadata/executor.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/storage/format.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>

namespace orca::metadata::executor {

namespace {

using journal::MutationState;
using journal::Operation;

[[nodiscard]] auto result_identity(const Operation& operation) -> expected<mutation::FileIdentity> {
    if (!operation.committed_size || !operation.committed_modified_ns ||
        !operation.committed_quick_hash) {
        return fail(ErrorCode::missing_committed_identity, "executor: missing committed identity");
    }
    mutation::FileIdentity identity;
    identity.size_bytes = *operation.committed_size;
    identity.modified_ns = *operation.committed_modified_ns;
    identity.quick_hash = *operation.committed_quick_hash;
    identity.content_hash = operation.committed_content_hash;
    return identity;
}

[[nodiscard]] auto expected_identity(const Operation& operation)
    -> expected<mutation::FileIdentity> {
    if (!operation.expected_quick_hash) {
        return fail(ErrorCode::missing_expected_identity, "executor: missing expected identity");
    }
    mutation::FileIdentity identity;
    identity.size_bytes = operation.expected_size;
    identity.modified_ns = operation.expected_modified_ns;
    identity.quick_hash = *operation.expected_quick_hash;
    identity.content_hash = operation.expected_content_hash;
    return identity;
}

[[nodiscard]] auto path_exists(const std::filesystem::path& path) -> expected<bool> {
    std::error_code error;
    const bool exists = std::filesystem::exists(path, error);
    if (error) {
        return fail(ErrorCode::io, "executor: " + path.string());
    }
    return exists;
}

[[nodiscard]] auto directory_exists(const std::filesystem::path& path) -> expected<bool> {
    std::error_code error;
    const bool exists = std::filesystem::is_directory(path, error);
    if (error) {
        return fail(ErrorCode::io, "executor: " + path.string());
    }
    return exists;
}

[[nodiscard]] auto matches_if_present(const std::filesystem::path& path,
                                      const mutation::FileIdentity& expected_identity)
    -> expected<std::optional<bool>> {
    const auto result = file_mutation::matches(path, expected_identity);
    if (!result) {
        if (result.error().code == ErrorCode::not_found) {
            return std::optional<bool>{};
        }
        return std::unexpected(result.error());
    }
    return std::optional<bool>(*result);
}

[[nodiscard]] auto backup_holds_original(const Operation& operation) -> expected<bool> {
    if (!operation.backup_path) {
        return false;
    }
    const auto original = expected_identity(operation);
    if (!original) {
        return false;
    }
    const auto matched = matches_if_present(*operation.backup_path, *original);
    if (!matched) {
        return std::unexpected(matched.error());
    }
    return matched->value_or(false);
}

[[nodiscard]] auto delete_counting_bytes(const std::filesystem::path& path)
    -> expected<std::uint64_t> {
    std::error_code error;
    const auto size = std::filesystem::file_size(path, error);
    if (error) {
        if (!std::filesystem::exists(path)) {
            return std::uint64_t{0};
        }
        return fail(ErrorCode::io, "prune: " + path.string());
    }
    const auto deleted = file_mutation::delete_if_present(path);
    if (!deleted) {
        return std::unexpected(deleted.error());
    }
    return size;
}

void delete_directory_if_empty(const std::filesystem::path& path) {
    std::error_code ignored;
    std::filesystem::remove(path, ignored);
}

[[nodiscard]] auto tag_format(const std::filesystem::path& path)
    -> expected<std::optional<TagFormat>> {
    auto source = storage::LocalFileSource::open(path);
    if (!source) {
        return std::unexpected(source.error());
    }
    const auto detected = storage::detect(*source);
    if (!detected) {
        return std::unexpected(detected.error());
    }
    if (!*detected || (*detected)->payload_offset != 0) {
        return std::optional<TagFormat>{};
    }
    switch ((*detected)->format) {
    case storage::AudioFormat::flac:
        return std::optional<TagFormat>(TagFormat::flac);
    case storage::AudioFormat::mp3:
    case storage::AudioFormat::aac:
        return std::optional<TagFormat>(TagFormat::mpeg);
    default:
        return std::optional<TagFormat>{};
    }
}

struct GroupCounts {
    std::uint64_t planned = 0;
    std::uint64_t staged = 0;
    std::uint64_t committed = 0;
    std::uint64_t rolled_back = 0;
    std::uint64_t failed = 0;
    std::uint64_t needs_reconciliation = 0;
    std::uint64_t undoing = 0;

    void add(MutationState state) {
        switch (state) {
        case MutationState::planned:
            planned += 1;
            return;
        case MutationState::staged:
            staged += 1;
            return;
        case MutationState::committed:
            committed += 1;
            return;
        case MutationState::rolled_back:
            rolled_back += 1;
            return;
        case MutationState::failed:
            failed += 1;
            return;
        case MutationState::needs_reconciliation:
            needs_reconciliation += 1;
            return;
        case MutationState::undoing:
            undoing += 1;
            return;
        }
    }

    [[nodiscard]] auto total() const -> std::uint64_t {
        return planned + staged + committed + rolled_back + failed + needs_reconciliation + undoing;
    }
};

enum class UndoAvailability : std::uint8_t {
    fresh,
    interrupted,
    backups_pruned,
    already_undone,
    needs_reconciliation,
    not_committed,
};

[[nodiscard]] auto undo_availability(const GroupCounts& counts, bool backups_present)
    -> UndoAvailability {
    if (counts.planned + counts.staged + counts.failed > 0) {
        return UndoAvailability::not_committed;
    }
    const auto operations = counts.total();
    if (counts.committed == operations) {
        return backups_present ? UndoAvailability::fresh : UndoAvailability::backups_pruned;
    }
    if (counts.undoing > 0) {
        return UndoAvailability::interrupted;
    }
    if (counts.needs_reconciliation > 0) {
        return UndoAvailability::needs_reconciliation;
    }
    if (counts.rolled_back == operations) {
        return UndoAvailability::already_undone;
    }
    return UndoAvailability::not_committed;
}

}

auto Executor::fault_matches(FaultPoint point, std::uint32_t action_index) const -> bool {
    if (!fault_) {
        return false;
    }
    return fault_->point == point && fault_->action_index == action_index;
}

auto Executor::interrupt(FaultPoint point, std::uint32_t action_index) -> expected<void> {
    if (!fault_matches(point, action_index)) {
        return {};
    }
    crashed_ = true;
    return fail(ErrorCode::simulated_power_loss, "executor: injected fault");
}

auto Executor::commit_interrupt(std::uint32_t action_index) const
    -> std::optional<file_mutation::Interrupt> {
    if (fault_matches(FaultPoint::after_backup_copy, action_index)) {
        return file_mutation::Interrupt::after_backup_copy;
    }
    if (fault_matches(FaultPoint::after_source_rename, action_index)) {
        return file_mutation::Interrupt::after_source_rename;
    }
    return std::nullopt;
}

auto Executor::rollback_interrupt(std::uint32_t action_index) const
    -> std::optional<file_mutation::Interrupt> {
    if (fault_matches(FaultPoint::rollback_after_restore_copy, action_index)) {
        return file_mutation::Interrupt::after_restore_copy;
    }
    if (fault_matches(FaultPoint::rollback_after_restore, action_index)) {
        return file_mutation::Interrupt::after_restore_rename;
    }
    return std::nullopt;
}

void Executor::stop_if_stale(const Error& error) {
    if (error.code == ErrorCode::stale_mutation_operation) {
        crashed_ = true;
    }
}

auto Executor::transition(std::int64_t operation_id, MutationState expected_state,
                          MutationState next, const std::optional<std::string>& message)
    -> expected<void> {
    const auto result = store_->transition(operation_id, expected_state, next, message);
    if (!result) {
        stop_if_stale(result.error());
    }
    return result;
}

auto Executor::record_result_identity(std::int64_t operation_id, MutationState expected_state,
                                      const mutation::FileIdentity& result) -> expected<void> {
    if (!result.content_hash) {
        return fail(ErrorCode::missing_content_hash, "executor: missing content hash");
    }
    const auto outcome =
        store_->record_result_identity(operation_id, expected_state, result.size_bytes,
                                       result.modified_ns, result.quick_hash, *result.content_hash);
    if (!outcome) {
        stop_if_stale(outcome.error());
    }
    return outcome;
}

auto Executor::commit_operation(std::int64_t operation_id, const mutation::FileIdentity& committed)
    -> expected<void> {
    if (!committed.content_hash) {
        return fail(ErrorCode::missing_content_hash, "executor: missing content hash");
    }
    const auto outcome = store_->commit(operation_id, committed.size_bytes, committed.modified_ns,
                                        committed.quick_hash, *committed.content_hash);
    if (!outcome) {
        stop_if_stale(outcome.error());
    }
    return outcome;
}

auto Executor::plan_backup_directory(std::uint64_t plan_id) const -> expected<std::string> {
    if (!backup_directory_) {
        return fail(ErrorCode::no_backup_directory, "executor: no backup directory");
    }
    return file_mutation::plan_backup_directory(*backup_directory_, plan_id);
}

auto Executor::prepare_actions(const mutation::Plan& plan, std::uint64_t group_id,
                               const std::optional<std::string>& plan_backup_directory,
                               std::vector<PreparedAction>& prepared) -> expected<void> {
    for (std::size_t index = 0; index < plan.actions().size(); ++index) {
        const auto& action = plan.actions()[index];
        if (const auto* write = std::get_if<mutation::WriteTags>(&action)) {
            const std::string stage_path =
                file_mutation::sibling_path(write->path, "stage", plan.id(), index);
            const std::string backup_path = file_mutation::backup_path(
                *plan_backup_directory, index, std::filesystem::path(write->path));
            journal::OperationInput input;
            input.plan_id = plan.id();
            input.group_id = group_id;
            input.action_index = static_cast<std::uint32_t>(index);
            input.kind = journal::MutationKind::write_tags;
            input.source_path = write->path;
            input.stage_path = stage_path;
            input.backup_path = backup_path;
            input.expected_size = write->expected.size_bytes;
            input.expected_modified_ns = write->expected.modified_ns;
            input.expected_quick_hash = write->expected.quick_hash;
            input.expected_content_hash = write->expected.content_hash;
            const auto operation = store_->prepare(input);
            if (!operation) {
                return std::unexpected(operation.error());
            }
            prepared.push_back(PreparedAction{
                .id = *operation, .stage_path = stage_path, .backup_path = backup_path});
        } else {
            const auto& move = std::get<mutation::Move>(action);
            journal::OperationInput input;
            input.plan_id = plan.id();
            input.group_id = group_id;
            input.action_index = static_cast<std::uint32_t>(index);
            input.kind = journal::MutationKind::move;
            input.source_path = move.source_path;
            input.destination_path = move.destination_path;
            input.expected_size = move.expected.size_bytes;
            input.expected_modified_ns = move.expected.modified_ns;
            input.expected_quick_hash = move.expected.quick_hash;
            input.expected_content_hash = move.expected.content_hash;
            const auto operation = store_->prepare(input);
            if (!operation) {
                return std::unexpected(operation.error());
            }
            prepared.push_back(PreparedAction{
                .id = *operation, .stage_path = std::nullopt, .backup_path = std::nullopt});
            ORCA_ASSERT(prepared.back().id == *operation);
        }
    }
    ORCA_ASSERT(prepared.size() == plan.actions().size());
    return {};
}

auto Executor::check_plan(const mutation::Plan& plan) -> expected<std::optional<std::string>> {
    ORCA_ASSERT(!plan.actions().empty());
    failed_action_index_.reset();
    bool writes_tags = false;
    for (std::size_t index = 0; index < plan.actions().size(); ++index) {
        if (const auto* write = std::get_if<mutation::WriteTags>(&plan.actions()[index])) {
            writes_tags = true;
            failed_action_index_ = static_cast<std::uint32_t>(index);
            const auto format = tag_format(write->path);
            if (!format) {
                return std::unexpected(format.error());
            }
            if (!*format) {
                return fail(ErrorCode::unsupported_tag_writer, "executor: " + write->path);
            }
        }
    }
    failed_action_index_.reset();
    if (!writes_tags) {
        return std::optional<std::string>{};
    }
    const auto computed = plan_backup_directory(plan.id());
    if (!computed) {
        return std::unexpected(computed.error());
    }
    const auto exists = path_exists(*computed);
    if (!exists) {
        return std::unexpected(exists.error());
    }
    if (*exists) {
        return fail(ErrorCode::tag_write_backup_exists, "executor: " + *computed);
    }
    return std::optional<std::string>(*computed);
}

auto Executor::execute_plan(mutation::Plan& plan, std::uint64_t group_id) -> expected<void> {
    ORCA_ASSERT(store_ != nullptr);
    ORCA_ASSERT(lock_ != nullptr);
    if (group_id == 0) {
        return fail(ErrorCode::invalid_mutation_group, "executor: invalid group");
    }
    const auto plan_directory = check_plan(plan);
    if (!plan_directory) {
        return std::unexpected(plan_directory.error());
    }
    std::vector<PreparedAction> prepared;
    std::vector<CompletedAction> completed;
    const auto started = plan.begin_execution();
    if (!started) {
        return std::unexpected(started.error());
    }
    const auto prepared_ok = prepare_actions(plan, group_id, *plan_directory, prepared);
    if (!prepared_ok) {
        compensate(plan, prepared, completed);
        return std::unexpected(prepared_ok.error());
    }
    if (const auto fired = interrupt(FaultPoint::after_journal_prepare, 0); !fired) {
        compensate(plan, prepared, completed);
        return std::unexpected(fired.error());
    }
    for (std::size_t index = 0; index < plan.actions().size(); ++index) {
        if (const auto* write = std::get_if<mutation::WriteTags>(&plan.actions()[index])) {
            const auto writable = file_mutation::require_writable_file(write->path);
            if (!writable) {
                failed_action_index_ = static_cast<std::uint32_t>(index);
                (void)transition(prepared[index].id, MutationState::planned, MutationState::failed,
                                 writable.error().context);
                compensate(plan, prepared, completed);
                return std::unexpected(writable.error());
            }
        }
    }
    for (std::size_t index = 0; index < plan.actions().size(); ++index) {
        expected<void> outcome = {};
        if (const auto* write = std::get_if<mutation::WriteTags>(&plan.actions()[index])) {
            outcome = execute_write_action(static_cast<std::uint32_t>(index), *write, prepared,
                                           completed);
        } else {
            outcome = execute_move_action(static_cast<std::uint32_t>(index),
                                          std::get<mutation::Move>(plan.actions()[index]), prepared,
                                          completed);
        }
        if (!outcome) {
            compensate(plan, prepared, completed);
            return std::unexpected(outcome.error());
        }
    }
    failed_action_index_.reset();
    return plan.finish(true);
}

void Executor::compensate(mutation::Plan& plan, const std::vector<PreparedAction>& prepared,
                          std::vector<CompletedAction>& completed) {
    if (crashed_) {
        return;
    }
    for (std::size_t index = completed.size(); index > 0; --index) {
        const CompletedAction& done = completed[index - 1];
        (void)rollback_operation(done.id, rollback_interrupt(done.action_index));
        if (crashed_) {
            return;
        }
    }
    for (std::size_t index = prepared.size(); index > 0; --index) {
        const std::int64_t id = prepared[index - 1].id;
        const bool already =
            std::any_of(completed.begin(), completed.end(),
                        [id](const CompletedAction& done) { return done.id == id; });
        if (already) {
            continue;
        }
        (void)recover_operation(id);
    }
    (void)plan.finish(false);
}

auto Executor::commit_write(const std::string& source_path, const std::string& stage_path,
                            const std::string& backup_path,
                            const mutation::FileIdentity& expected_identity,
                            file_mutation::Interrupt interrupt) -> expected<void> {
    const auto writable = file_mutation::require_writable_file(source_path);
    if (!writable) {
        return std::unexpected(writable.error());
    }
    if (!backup_directory_) {
        return fail(ErrorCode::no_backup_directory, "executor: no backup directory");
    }
    if (const auto made = file_mutation::create_directory_durably(*backup_directory_); !made) {
        return std::unexpected(made.error());
    }
    if (const auto made = file_mutation::create_directory_durably(
            std::filesystem::path(backup_path).parent_path());
        !made) {
        return std::unexpected(made.error());
    }
    return file_mutation::commit_replacement_interrupted(source_path, stage_path, backup_path,
                                                         expected_identity, interrupt);
}

auto Executor::execute_write_action(std::uint32_t index, const mutation::WriteTags& write,
                                    const std::vector<PreparedAction>& prepared,
                                    std::vector<CompletedAction>& completed) -> expected<void> {
    ORCA_ASSERT(index < prepared.size());
    failed_action_index_ = index;
    const std::int64_t operation = prepared[index].id;
    ORCA_ASSERT(prepared[index].stage_path.has_value());
    ORCA_ASSERT(prepared[index].backup_path.has_value());
    const std::string& stage_path = *prepared[index].stage_path;
    const std::string& backup_path = *prepared[index].backup_path;
    const auto format = tag_format(write.path);
    if (!format || !*format) {
        return fail(ErrorCode::unsupported_tag_writer, "executor: " + write.path);
    }
    const auto staged = *format == TagFormat::mpeg
                            ? file_mutation::stage_mpeg(write.path, stage_path, write.expected,
                                                        write.changes, write.genres)
                            : file_mutation::stage_flac(write.path, stage_path, write.expected,
                                                        write.changes, write.genres);
    if (!staged) {
        (void)transition(operation, MutationState::planned, MutationState::failed,
                         staged.error().context);
        return std::unexpected(staged.error());
    }
    if (const auto fired = interrupt(FaultPoint::after_stage, index); !fired) {
        return std::unexpected(fired.error());
    }
    const auto staged_identity = file_mutation::identity(stage_path);
    if (!staged_identity) {
        return std::unexpected(staged_identity.error());
    }
    const auto recorded =
        record_result_identity(operation, MutationState::planned, *staged_identity);
    if (!recorded) {
        return std::unexpected(recorded.error());
    }
    if (const auto advanced =
            transition(operation, MutationState::planned, MutationState::staged, std::nullopt);
        !advanced) {
        return std::unexpected(advanced.error());
    }
    if (const auto fired = interrupt(FaultPoint::after_stage_journaled, index); !fired) {
        return std::unexpected(fired.error());
    }
    const auto commit_fault = commit_interrupt(index);
    if (commit_fault) {
        crashed_ = true;
    }
    const auto committed = commit_write(write.path, stage_path, backup_path, write.expected,
                                        commit_fault.value_or(file_mutation::Interrupt::none));
    if (!committed) {
        if (crashed_) {
            return std::unexpected(committed.error());
        }
        std::error_code ignored;
        std::filesystem::remove(stage_path, ignored);
        (void)transition(operation, MutationState::staged, MutationState::failed,
                         committed.error().context);
        return std::unexpected(committed.error());
    }
    completed.push_back(CompletedAction{.id = operation, .action_index = index});
    if (const auto fired = interrupt(FaultPoint::before_journal_commit, index); !fired) {
        return std::unexpected(fired.error());
    }
    const auto final_identity = file_mutation::identity(write.path);
    if (!final_identity) {
        return std::unexpected(final_identity.error());
    }
    return commit_operation(operation, *final_identity);
}

auto Executor::group_produced_identity(const std::vector<CompletedAction>& actions,
                                       const std::string& path,
                                       const mutation::FileIdentity& current) -> expected<bool> {
    for (auto iterator = actions.rbegin(); iterator != actions.rend(); ++iterator) {
        const auto operation = store_->get(iterator->id);
        if (!operation) {
            return std::unexpected(operation.error());
        }
        if (operation->kind == journal::MutationKind::write_tags &&
            operation->source_path == path) {
            const auto result = result_identity(*operation);
            if (result && result->eql(current)) {
                return true;
            }
        }
    }
    return false;
}

auto Executor::execute_move_action(std::uint32_t index, const mutation::Move& move,
                                   const std::vector<PreparedAction>& prepared,
                                   std::vector<CompletedAction>& completed) -> expected<void> {
    ORCA_ASSERT(index < prepared.size());
    failed_action_index_ = index;
    const std::int64_t operation = prepared[index].id;
    const auto current = file_mutation::identity(move.source_path);
    if (!current) {
        return std::unexpected(current.error());
    }
    if (!current->eql(move.expected)) {
        const auto produced = group_produced_identity(completed, move.source_path, *current);
        if (!produced) {
            return std::unexpected(produced.error());
        }
        if (!*produced) {
            return fail(ErrorCode::file_identity_changed, "executor: " + move.source_path);
        }
    }
    const auto exists = path_exists(move.destination_path);
    if (!exists) {
        return std::unexpected(exists.error());
    }
    if (*exists) {
        return fail(ErrorCode::destination_exists, "executor: " + move.destination_path);
    }
    const auto recorded = record_result_identity(operation, MutationState::planned, *current);
    if (!recorded) {
        return std::unexpected(recorded.error());
    }
    const auto advanced =
        transition(operation, MutationState::planned, MutationState::staged, std::nullopt);
    if (!advanced) {
        return std::unexpected(advanced.error());
    }
    if (const auto fired = interrupt(FaultPoint::after_stage_journaled, index); !fired) {
        return std::unexpected(fired.error());
    }
    const auto moved = file_mutation::commit_move(move.source_path, move.destination_path);
    if (!moved) {
        (void)transition(operation, MutationState::staged, MutationState::failed,
                         moved.error().context);
        return std::unexpected(moved.error());
    }
    completed.push_back(CompletedAction{.id = operation, .action_index = index});
    if (const auto fired = interrupt(FaultPoint::after_move_rename, index); !fired) {
        return std::unexpected(fired.error());
    }
    const auto destination_identity = file_mutation::identity(move.destination_path);
    if (!destination_identity) {
        return std::unexpected(destination_identity.error());
    }
    return commit_operation(operation, *destination_identity);
}

auto Executor::undo_operation(std::int64_t operation_id) -> expected<void> {
    const auto loaded = store_->get(operation_id);
    if (!loaded) {
        return std::unexpected(loaded.error());
    }
    const Operation operation = *loaded;
    if (operation.state != MutationState::committed) {
        return fail(ErrorCode::mutation_operation_not_committed, "executor: not committed");
    }
    if (operation.kind == journal::MutationKind::write_tags && !operation.backup_path) {
        return fail(ErrorCode::tag_write_backup_pruned, "executor: backup pruned");
    }
    if (operation.kind == journal::MutationKind::move && !operation.destination_path) {
        return fail(ErrorCode::missing_mutation_destination, "executor: no destination");
    }
    const auto expected = result_identity(operation);
    if (!expected) {
        return std::unexpected(expected.error());
    }
    const std::string& current_path = operation.kind == journal::MutationKind::write_tags
                                          ? operation.source_path
                                          : *operation.destination_path;
    const auto matched = file_mutation::matches(current_path, *expected);
    if (!matched) {
        return std::unexpected(matched.error());
    }
    if (!*matched) {
        (void)reconcile(operation_id, MutationState::committed, "undo target changed externally");
        return fail(ErrorCode::mutation_needs_reconciliation, "executor: undo target changed");
    }
    if (operation.kind == journal::MutationKind::write_tags) {
        const auto holds = backup_holds_original(operation);
        if (!holds) {
            return std::unexpected(holds.error());
        }
        if (!*holds) {
            (void)reconcile(operation_id, MutationState::committed,
                            "tag write backup is missing or damaged");
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: backup damaged");
        }
        const auto writable = file_mutation::require_writable_file(current_path);
        if (!writable) {
            return std::unexpected(writable.error());
        }
    }
    return rollback_operation(operation_id, std::nullopt);
}

auto Executor::validate_group_undo(const std::vector<Operation>& operations) -> expected<void> {
    for (std::size_t index = 0; index < operations.size(); ++index) {
        const Operation& operation = operations[index];
        if (operation.kind == journal::MutationKind::move && !operation.destination_path) {
            return fail(ErrorCode::missing_mutation_destination, "executor: no destination");
        }
        std::string current_path = operation.kind == journal::MutationKind::write_tags
                                       ? operation.source_path
                                       : *operation.destination_path;
        for (std::size_t later = index; later > 0; --later) {
            const Operation& previous = operations[later - 1];
            if (previous.kind == journal::MutationKind::move &&
                previous.source_path == current_path) {
                if (!previous.destination_path) {
                    return fail(ErrorCode::missing_mutation_destination,
                                "executor: no destination");
                }
                current_path = *previous.destination_path;
            }
        }
        const auto exists = path_exists(current_path);
        if (!exists) {
            return std::unexpected(exists.error());
        }
        if (!*exists) {
            (void)reconcile(operation.id, operation.state, "group undo target is missing");
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: target missing");
        }
        const auto expected = result_identity(operation);
        if (!expected) {
            return std::unexpected(expected.error());
        }
        const auto matched = file_mutation::matches(current_path, *expected);
        if (!matched) {
            return std::unexpected(matched.error());
        }
        if (!*matched) {
            (void)reconcile(operation.id, operation.state, "group undo target changed externally");
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: target changed");
        }
        if (operation.kind == journal::MutationKind::move) {
            const auto source_exists = path_exists(operation.source_path);
            if (!source_exists) {
                return std::unexpected(source_exists.error());
            }
            if (*source_exists) {
                (void)reconcile(operation.id, operation.state, "group undo destination exists");
                return fail(ErrorCode::mutation_needs_reconciliation,
                            "executor: destination exists");
            }
        } else {
            const auto holds = backup_holds_original(operation);
            if (!holds) {
                return std::unexpected(holds.error());
            }
            if (!*holds) {
                (void)reconcile(operation.id, operation.state,
                                "tag write backup is missing or damaged");
                return fail(ErrorCode::mutation_needs_reconciliation, "executor: backup damaged");
            }
            const auto writable = file_mutation::require_writable_file(current_path);
            if (!writable) {
                return std::unexpected(writable.error());
            }
        }
    }
    return {};
}

auto Executor::undo_group(std::uint64_t group_id) -> expected<void> {
    if (group_id == 0) {
        return fail(ErrorCode::invalid_mutation_group, "executor: invalid group");
    }
    const auto ids = store_->group_operation_ids(group_id);
    if (!ids) {
        return std::unexpected(ids.error());
    }
    if (ids->empty()) {
        return fail(ErrorCode::mutation_group_not_found, "executor: group not found");
    }
    std::vector<Operation> operations;
    for (const std::int64_t id : *ids) {
        const auto operation = store_->get(id);
        if (!operation) {
            return std::unexpected(operation.error());
        }
        operations.push_back(*operation);
    }
    GroupCounts counts;
    bool backups_present = true;
    for (const Operation& operation : operations) {
        counts.add(operation.state);
        if (operation.kind == journal::MutationKind::write_tags && !operation.backup_path) {
            backups_present = false;
        }
    }
    switch (undo_availability(counts, backups_present)) {
    case UndoAvailability::fresh:
        break;
    case UndoAvailability::interrupted:
        return finish_interrupted_undo(group_id);
    case UndoAvailability::backups_pruned:
        return fail(ErrorCode::tag_write_backup_pruned, "executor: backup pruned");
    case UndoAvailability::already_undone:
        return fail(ErrorCode::mutation_group_already_undone, "executor: already undone");
    case UndoAvailability::needs_reconciliation:
        return fail(ErrorCode::mutation_needs_reconciliation, "executor: needs reconciliation");
    case UndoAvailability::not_committed:
        return fail(ErrorCode::mutation_group_not_committed, "executor: not committed");
    }
    const auto validated = validate_group_undo(operations);
    if (!validated) {
        return std::unexpected(validated.error());
    }
    return perform_group_undo(operations, group_id);
}

auto Executor::perform_group_undo(const std::vector<Operation>& operations, std::uint64_t group_id)
    -> expected<void> {
    const auto began = store_->begin_undo(group_id);
    if (!began) {
        stop_if_stale(began.error());
        return std::unexpected(began.error());
    }
    if (const auto fired = interrupt(FaultPoint::undo_after_intent, 0); !fired) {
        return std::unexpected(fired.error());
    }
    bool reconciled = false;
    for (const Operation& operation : operations) {
        const auto outcome =
            rollback_operation(operation.id, rollback_interrupt(operation.action_index));
        if (!outcome) {
            if (outcome.error().code == ErrorCode::mutation_needs_reconciliation) {
                reconciled = true;
            } else {
                return std::unexpected(outcome.error());
            }
        }
        if (const auto fired = interrupt(FaultPoint::undo_after_operation, operation.action_index);
            !fired) {
            return std::unexpected(fired.error());
        }
    }
    if (reconciled) {
        return fail(ErrorCode::mutation_needs_reconciliation, "executor: reconciled");
    }
    return {};
}

auto Executor::finish_interrupted_undo(std::uint64_t group_id) -> expected<void> {
    const auto recovered = recover_group(group_id);
    if (!recovered) {
        return std::unexpected(recovered.error());
    }
    const auto ids = store_->group_operation_ids(group_id);
    if (!ids) {
        return std::unexpected(ids.error());
    }
    for (const std::int64_t id : *ids) {
        const auto current = store_->state(id);
        if (!current) {
            return std::unexpected(current.error());
        }
        if (*current == MutationState::needs_reconciliation) {
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: reconciled");
        }
    }
    return {};
}

auto Executor::prune_backups(std::uint64_t older_than_s) -> expected<PruneSummary> {
    PruneSummary summary;
    while (true) {
        const auto page = store_->prunable_backups(older_than_s);
        if (!page) {
            return std::unexpected(page.error());
        }
        if (page->empty()) {
            return summary;
        }
        ORCA_ASSERT(!page->empty());
        for (const journal::PrunableBackup& backup : *page) {
            ORCA_ASSERT(backup.operation_id != 0);
            const auto bytes = delete_counting_bytes(backup.backup_path);
            if (!bytes) {
                return std::unexpected(bytes.error());
            }
            summary.bytes += *bytes;
            const auto cleared = store_->clear_backup_path(backup.operation_id);
            if (!cleared) {
                stop_if_stale(cleared.error());
                return std::unexpected(cleared.error());
            }
            const auto removed = remove_empty_backup_directories(backup.backup_path);
            if (!removed) {
                return std::unexpected(removed.error());
            }
            summary.backups += 1;
        }
    }
}

auto Executor::recover_group(std::uint64_t group_id) -> expected<void> {
    ORCA_ASSERT(group_id != 0);
    const auto undone = store_->undo_committed(group_id);
    if (!undone) {
        stop_if_stale(undone.error());
        return std::unexpected(undone.error());
    }
    const auto ids = store_->group_operation_ids(group_id);
    if (!ids) {
        return std::unexpected(ids.error());
    }
    for (const std::int64_t id : *ids) {
        const auto operation = store_->get(id);
        if (!operation) {
            return std::unexpected(operation.error());
        }
        const auto outcome = recover_loaded(*operation);
        if (!outcome && outcome.error().code != ErrorCode::mutation_needs_reconciliation) {
            return std::unexpected(outcome.error());
        }
        if (const auto fired =
                interrupt(FaultPoint::recovery_after_operation, operation->action_index);
            !fired) {
            return std::unexpected(fired.error());
        }
    }
    return {};
}

auto Executor::recover_operation(std::int64_t operation_id) -> expected<void> {
    const auto operation = store_->get(operation_id);
    if (!operation) {
        return std::unexpected(operation.error());
    }
    return recover_loaded(*operation);
}

auto Executor::recover_loaded(const Operation& operation) -> expected<void> {
    switch (operation.state) {
    case MutationState::rolled_back:
    case MutationState::needs_reconciliation:
        return {};
    case MutationState::committed:
        return fail(ErrorCode::mutation_operation_not_recoverable, "executor: committed");
    case MutationState::planned:
    case MutationState::staged:
    case MutationState::failed:
    case MutationState::undoing:
        break;
    }
    if (operation.kind == journal::MutationKind::move) {
        if (!operation.destination_path) {
            (void)reconcile(operation.id, operation.state,
                            "move record has no journaled destination path");
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: no destination");
        }
        return recover_move(operation);
    }
    if (!operation.stage_path || !operation.backup_path) {
        (void)reconcile(operation.id, operation.state,
                        "tag write record has no journaled stage or backup path");
        return fail(ErrorCode::mutation_needs_reconciliation, "executor: no stage or backup");
    }
    return recover_write_tags(operation);
}

auto Executor::recover_move(const Operation& operation) -> expected<void> {
    const std::string& destination = *operation.destination_path;
    const auto destination_exists = path_exists(destination);
    if (!destination_exists) {
        return std::unexpected(destination_exists.error());
    }
    if (*destination_exists) {
        const auto source_exists = path_exists(operation.source_path);
        if (!source_exists) {
            return std::unexpected(source_exists.error());
        }
        if (*source_exists) {
            (void)reconcile(operation.id, operation.state,
                            "move source and destination both exist");
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: both exist");
        }
        const auto journaled = result_identity(operation);
        if (!journaled) {
            (void)reconcile(operation.id, operation.state,
                            "move destination exists without a journaled identity");
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: no identity");
        }
        const auto matched = file_mutation::matches(destination, *journaled);
        if (!matched) {
            return std::unexpected(matched.error());
        }
        if (!*matched) {
            (void)reconcile(operation.id, operation.state, "move destination changed externally");
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: destination changed");
        }
        const auto moved = file_mutation::commit_move(destination, operation.source_path);
        if (!moved) {
            return std::unexpected(moved.error());
        }
    }
    const auto source_exists = path_exists(operation.source_path);
    if (!source_exists) {
        return std::unexpected(source_exists.error());
    }
    if (!*source_exists) {
        (void)reconcile(operation.id, operation.state,
                        "neither the move source nor its destination is present");
        return fail(ErrorCode::mutation_needs_reconciliation, "executor: source missing");
    }
    return finish_recovery_state(operation.id, operation.state);
}

auto Executor::recover_write_tags(const Operation& operation) -> expected<void> {
    ORCA_ASSERT(operation.stage_path.has_value());
    ORCA_ASSERT(operation.backup_path.has_value());
    const std::string& stage_path = *operation.stage_path;
    const std::string& backup_path = *operation.backup_path;
    const auto original = expected_identity(operation);
    const auto staged = result_identity(operation);
    const std::string restore_path = file_mutation::sibling_path(
        operation.source_path, "restore", operation.plan_id, operation.action_index);
    const std::string displaced_path = stage_path + ".recovery-displaced";
    const std::array<std::string, 3> temporaries{stage_path, restore_path, displaced_path};

    if (original) {
        const auto matches = matches_if_present(operation.source_path, *original);
        if (!matches) {
            return std::unexpected(matches.error());
        }
        if (matches->value_or(false)) {
            return cleanup_recovered_write(temporaries, backup_path, operation.id, operation.state);
        }
    }
    if (!staged) {
        return cleanup_recovered_write(temporaries, std::nullopt, operation.id, operation.state);
    }
    const auto in_place = matches_if_present(operation.source_path, *staged);
    if (!in_place) {
        return std::unexpected(in_place.error());
    }
    if (!in_place->has_value()) {
        const auto directory =
            directory_exists(std::filesystem::path(operation.source_path).parent_path());
        if (!directory) {
            return std::unexpected(directory.error());
        }
        if (!*directory) {
            return fail(ErrorCode::tag_target_unavailable, "executor: tag target unavailable");
        }
        (void)reconcile(operation.id, operation.state, "the tag target is missing");
        return fail(ErrorCode::mutation_needs_reconciliation, "executor: target missing");
    }
    if (!in_place->value()) {
        (void)reconcile(operation.id, operation.state, "tag target changed externally");
        return fail(ErrorCode::mutation_needs_reconciliation,
                    "executor: target changed externally");
    }
    const auto holds = backup_holds_original(operation);
    if (!holds) {
        return std::unexpected(holds.error());
    }
    if (!*holds) {
        (void)reconcile(operation.id, operation.state,
                        "the staged replacement is in place and its backup is missing or damaged");
        return fail(ErrorCode::mutation_needs_reconciliation, "executor: backup damaged");
    }
    const auto writable = file_mutation::require_writable_file(operation.source_path);
    if (!writable) {
        return std::unexpected(writable.error());
    }
    const auto restored = file_mutation::restore_from_backup(operation.source_path, backup_path,
                                                             restore_path, *original, *staged);
    if (!restored) {
        return std::unexpected(restored.error());
    }
    return cleanup_recovered_write(temporaries, backup_path, operation.id, operation.state);
}

auto Executor::cleanup_recovered_write(std::span<const std::string> temporaries,
                                       std::optional<std::string> backup_path,
                                       std::int64_t operation_id, MutationState state)
    -> expected<void> {
    for (const std::string& path : temporaries) {
        const auto deleted = file_mutation::delete_if_present(path);
        if (!deleted) {
            return std::unexpected(deleted.error());
        }
    }
    if (backup_path) {
        const auto discarded = discard_backup(*backup_path);
        if (!discarded) {
            return std::unexpected(discarded.error());
        }
    }
    return finish_recovery_state(operation_id, state);
}

auto Executor::finish_recovery_state(std::int64_t operation_id, MutationState state)
    -> expected<void> {
    ORCA_ASSERT(operation_id != 0);
    const std::optional<std::string> recovered{std::string(journal::recovered_message)};
    switch (state) {
    case MutationState::planned: {
        const auto failed =
            transition(operation_id, MutationState::planned, MutationState::failed, recovered);
        if (!failed) {
            return std::unexpected(failed.error());
        }
        return transition(operation_id, MutationState::failed, MutationState::rolled_back,
                          recovered);
    }
    case MutationState::staged:
        return transition(operation_id, MutationState::staged, MutationState::rolled_back,
                          recovered);
    case MutationState::failed: {
        const auto result = store_->roll_back_failed(operation_id);
        if (!result) {
            stop_if_stale(result.error());
        }
        return result;
    }
    case MutationState::undoing:
        return transition(operation_id, MutationState::undoing, MutationState::rolled_back,
                          recovered);
    case MutationState::committed:
    case MutationState::rolled_back:
    case MutationState::needs_reconciliation:
        return {};
    }
    return {};
}

auto Executor::reconcile(std::int64_t operation_id, MutationState state, std::string_view message)
    -> expected<void> {
    return transition(operation_id, state, MutationState::needs_reconciliation,
                      std::string(message));
}

auto Executor::rollback_operation(std::int64_t operation_id,
                                  std::optional<file_mutation::Interrupt> interrupt)
    -> expected<void> {
    ORCA_ASSERT(operation_id != 0);
    const auto loaded = store_->get(operation_id);
    if (!loaded) {
        return std::unexpected(loaded.error());
    }
    const Operation operation = *loaded;
    MutationState state = operation.state;
    if (state == MutationState::committed) {
        const auto moved = transition(operation_id, MutationState::committed,
                                      MutationState::undoing, std::nullopt);
        if (!moved) {
            return std::unexpected(moved.error());
        }
        state = MutationState::undoing;
    } else {
        if (state != MutationState::staged && state != MutationState::undoing) {
            return fail(ErrorCode::mutation_operation_not_recoverable, "executor: not recoverable");
        }
    }
    if (operation.kind == journal::MutationKind::move) {
        if (!operation.destination_path) {
            return fail(ErrorCode::missing_mutation_destination, "executor: no destination");
        }
        const auto source_exists = path_exists(operation.source_path);
        if (!source_exists) {
            return std::unexpected(source_exists.error());
        }
        if (*source_exists) {
            (void)reconcile(operation_id, state, "move source already exists");
            return fail(ErrorCode::mutation_needs_reconciliation, "executor: source exists");
        }
        const auto moved =
            file_mutation::commit_move(*operation.destination_path, operation.source_path);
        if (!moved) {
            return std::unexpected(moved.error());
        }
        return transition(operation_id, state, MutationState::rolled_back, std::nullopt);
    }
    if (!operation.backup_path) {
        return fail(ErrorCode::tag_write_backup_pruned, "executor: backup pruned");
    }
    const std::string restore_path = file_mutation::sibling_path(
        operation.source_path, "restore", operation.plan_id, operation.action_index);
    if (interrupt) {
        crashed_ = true;
    }
    const auto expected = expected_identity(operation);
    if (!expected) {
        return std::unexpected(expected.error());
    }
    const auto result = result_identity(operation);
    if (!result) {
        return std::unexpected(result.error());
    }
    const auto restored = file_mutation::restore_from_backup_interrupted(
        operation.source_path, *operation.backup_path, restore_path, *expected, *result,
        interrupt.value_or(file_mutation::Interrupt::none));
    if (!restored) {
        return std::unexpected(restored.error());
    }
    const auto discarded = discard_backup(*operation.backup_path);
    if (!discarded) {
        return std::unexpected(discarded.error());
    }
    return transition(operation_id, state, MutationState::rolled_back, std::nullopt);
}

auto Executor::discard_backup(const std::string& backup_path) -> expected<void> {
    const auto deleted = file_mutation::delete_if_present(backup_path);
    if (!deleted) {
        return std::unexpected(deleted.error());
    }
    return remove_empty_backup_directories(backup_path);
}

auto Executor::remove_empty_backup_directories(const std::string& backup_path) -> expected<void> {
    if (!backup_directory_) {
        return {};
    }
    const std::filesystem::path plan_directory = std::filesystem::path(backup_path).parent_path();
    if (plan_directory.parent_path() != *backup_directory_) {
        return {};
    }
    delete_directory_if_empty(plan_directory);
    delete_directory_if_empty(*backup_directory_);
    return {};
}

}
