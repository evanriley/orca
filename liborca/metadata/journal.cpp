#include "liborca/metadata/journal.hpp"

#include "liborca/base/checked.hpp"
#include "liborca/base/logging.hpp"

#include <algorithm>
#include <cstddef>
#include <utility>

namespace orca::metadata::journal {

auto valid_mutation_transition(MutationState from, MutationState to) -> bool {
    if (to == MutationState::needs_reconciliation) {
        return from != MutationState::rolled_back && from != MutationState::needs_reconciliation;
    }
    switch (from) {
    case MutationState::planned:
        return to == MutationState::staged || to == MutationState::failed;
    case MutationState::staged:
        return to == MutationState::committed || to == MutationState::rolled_back ||
               to == MutationState::failed;
    case MutationState::failed:
        return to == MutationState::rolled_back;
    case MutationState::committed:
        return to == MutationState::undoing;
    case MutationState::undoing:
        return to == MutationState::rolled_back;
    case MutationState::rolled_back:
    case MutationState::needs_reconciliation:
        return false;
    }
    return false;
}

auto MemoryStore::index_of(std::int64_t operation_id) const -> std::optional<std::size_t> {
    for (std::size_t index = 0; index < operations_.size(); ++index) {
        if (operations_[index].id == operation_id) {
            ORCA_ASSERT(index < operations_.size());
            return index;
        }
    }
    return std::nullopt;
}

auto MemoryStore::prepare(const OperationInput& input) -> expected<std::int64_t> {
    if (input.plan_id == 0 || input.group_id == 0 || input.source_path.empty()) {
        return fail(ErrorCode::invalid_mutation_operation, "journal: invalid operation");
    }
    Operation operation;
    operation.id = next_id_;
    operation.plan_id = input.plan_id;
    operation.group_id = input.group_id;
    operation.action_index = input.action_index;
    operation.kind = input.kind;
    operation.file_id = input.file_id;
    operation.source_path = input.source_path;
    operation.destination_path = input.destination_path;
    operation.stage_path = input.stage_path;
    operation.backup_path = input.backup_path;
    operation.expected_size = input.expected_size;
    operation.expected_modified_ns = input.expected_modified_ns;
    operation.expected_quick_hash = input.expected_quick_hash;
    operation.expected_content_hash = input.expected_content_hash;
    operation.state = MutationState::planned;
    operation.updated_at_s = now_s_;
    const std::int64_t id = next_id_;
    const auto advanced = checked::add(next_id_, std::int64_t{1});
    if (!advanced) {
        return std::unexpected(advanced.error());
    }
    next_id_ = *advanced;
    ORCA_ASSERT(operations_.size() <= operations_.max_size());
    operations_.push_back(std::move(operation));
    ORCA_ASSERT(operations_.back().id == id);
    return id;
}

auto MemoryStore::transition(std::int64_t operation_id, MutationState expected_state,
                             MutationState next, const std::optional<std::string>& message)
    -> expected<void> {
    if (!valid_mutation_transition(expected_state, next)) {
        return fail(ErrorCode::invalid_mutation_transition, "journal: invalid transition");
    }
    const auto index = index_of(operation_id);
    if (!index) {
        return fail(ErrorCode::mutation_operation_not_found, "journal: operation not found");
    }
    ORCA_ASSERT(*index < operations_.size());
    Operation& operation = operations_[*index];
    if (operation.state != expected_state) {
        return fail(ErrorCode::stale_mutation_operation, "journal: stale operation");
    }
    ORCA_ASSERT(operation.state == expected_state);
    operation.state = next;
    operation.error = message;
    operation.updated_at_s = now_s_;
    return {};
}

auto MemoryStore::roll_back_failed(std::int64_t operation_id) -> expected<void> {
    const auto index = index_of(operation_id);
    if (!index) {
        return fail(ErrorCode::mutation_operation_not_found, "journal: operation not found");
    }
    Operation& operation = operations_[*index];
    if (operation.state != MutationState::failed) {
        return fail(ErrorCode::stale_mutation_operation, "journal: operation not failed");
    }
    operation.state = MutationState::rolled_back;
    operation.updated_at_s = now_s_;
    return {};
}

auto MemoryStore::state(std::int64_t operation_id) const -> expected<MutationState> {
    const auto index = index_of(operation_id);
    if (!index) {
        return fail(ErrorCode::mutation_operation_not_found, "journal: operation not found");
    }
    return operations_[*index].state;
}

auto MemoryStore::commit(std::int64_t operation_id, std::uint64_t committed_size,
                         std::int64_t committed_modified_ns,
                         const storage::quick_hash::Digest& committed_quick_hash,
                         const storage::content_hash::Digest& committed_content_hash)
    -> expected<void> {
    const auto index = index_of(operation_id);
    if (!index) {
        return fail(ErrorCode::mutation_operation_not_found, "journal: operation not found");
    }
    Operation& operation = operations_[*index];
    if (operation.state != MutationState::staged) {
        return fail(ErrorCode::stale_mutation_operation, "journal: operation not staged");
    }
    operation.state = MutationState::committed;
    operation.committed_size = committed_size;
    operation.committed_modified_ns = committed_modified_ns;
    operation.committed_quick_hash = committed_quick_hash;
    operation.committed_content_hash = committed_content_hash;
    operation.updated_at_s = now_s_;
    return {};
}

auto MemoryStore::record_result_identity(std::int64_t operation_id, MutationState expected_state,
                                         std::uint64_t size, std::int64_t modified_ns,
                                         const storage::quick_hash::Digest& digest,
                                         const storage::content_hash::Digest& content)
    -> expected<void> {
    const auto index = index_of(operation_id);
    if (!index) {
        return fail(ErrorCode::mutation_operation_not_found, "journal: operation not found");
    }
    Operation& operation = operations_[*index];
    if (operation.state != expected_state) {
        return fail(ErrorCode::stale_mutation_operation, "journal: stale operation");
    }
    operation.committed_size = size;
    operation.committed_modified_ns = modified_ns;
    operation.committed_quick_hash = digest;
    operation.committed_content_hash = content;
    operation.updated_at_s = now_s_;
    return {};
}

auto MemoryStore::get(std::int64_t operation_id) const -> expected<Operation> {
    const auto index = index_of(operation_id);
    if (!index) {
        return fail(ErrorCode::mutation_operation_not_found, "journal: operation not found");
    }
    return operations_[*index];
}

auto MemoryStore::nonterminal_group_ids() const -> expected<std::vector<std::uint64_t>> {
    std::vector<std::uint64_t> ids;
    for (const Operation& operation : operations_) {
        if (operation.state == MutationState::planned || operation.state == MutationState::staged ||
            operation.state == MutationState::failed || operation.state == MutationState::undoing) {
            ids.push_back(operation.group_id);
        }
    }
    std::ranges::sort(ids);
    const auto unique = std::ranges::unique(ids);
    ids.erase(unique.begin(), unique.end());
    return ids;
}

auto MemoryStore::begin_undo(std::uint64_t group_id) -> expected<void> {
    std::size_t total = 0;
    std::size_t committed = 0;
    for (const Operation& operation : operations_) {
        if (operation.group_id != group_id) {
            continue;
        }
        total += 1;
        if (operation.state == MutationState::committed) {
            committed += 1;
        }
    }
    if (total == 0) {
        return fail(ErrorCode::mutation_group_not_found, "journal: group not found");
    }
    if (committed != total) {
        return fail(ErrorCode::mutation_group_not_committed, "journal: group not committed");
    }
    for (Operation& operation : operations_) {
        if (operation.group_id == group_id) {
            operation.state = MutationState::undoing;
        }
    }
    return {};
}

auto MemoryStore::undo_committed(std::uint64_t group_id) -> expected<std::uint64_t> {
    std::uint64_t changed = 0;
    for (Operation& operation : operations_) {
        if (operation.group_id == group_id && operation.state == MutationState::committed) {
            operation.state = MutationState::undoing;
            changed += 1;
        }
    }
    ORCA_ASSERT(changed <= operations_.size());
    return changed;
}

auto MemoryStore::next_group_id() const -> expected<std::uint64_t> {
    std::uint64_t greatest = 0;
    for (const Operation& operation : operations_) {
        greatest = std::max(greatest, operation.group_id);
        greatest = std::max(greatest, operation.plan_id);
    }
    return checked::add(greatest, std::uint64_t{1});
}

auto MemoryStore::group_operation_ids(std::uint64_t group_id) const
    -> expected<std::vector<std::int64_t>> {
    std::vector<std::pair<std::uint32_t, std::int64_t>> ordered;
    for (const Operation& operation : operations_) {
        if (operation.group_id == group_id) {
            ordered.emplace_back(operation.action_index, operation.id);
        }
    }
    std::ranges::sort(
        ordered, [](const auto& first, const auto& second) { return first.first > second.first; });
    std::vector<std::int64_t> ids;
    ids.reserve(ordered.size());
    for (const auto& [action_index, id] : ordered) {
        ids.push_back(id);
    }
    ORCA_ASSERT(ids.size() == ordered.size());
    return ids;
}

auto MemoryStore::clear_backup_path(std::int64_t operation_id) -> expected<void> {
    const auto index = index_of(operation_id);
    if (!index) {
        return fail(ErrorCode::mutation_operation_not_found, "journal: operation not found");
    }
    operations_[*index].backup_path = std::nullopt;
    operations_[*index].updated_at_s = now_s_;
    return {};
}

auto MemoryStore::prunable_backups(std::uint64_t older_than_s) const
    -> expected<std::vector<PrunableBackup>> {
    constexpr std::size_t max_prune_page = 1000;
    const std::uint64_t cutoff = now_s_ > older_than_s ? now_s_ - older_than_s : 0;
    std::vector<PrunableBackup> result;
    for (const Operation& operation : operations_) {
        if (operation.state != MutationState::committed || !operation.backup_path) {
            continue;
        }
        bool eligible = true;
        for (const Operation& member : operations_) {
            if (member.group_id != operation.group_id) {
                continue;
            }
            if (member.state != MutationState::committed || member.updated_at_s > cutoff) {
                eligible = false;
                break;
            }
        }
        if (!eligible) {
            continue;
        }
        result.push_back(
            PrunableBackup{.operation_id = operation.id, .backup_path = *operation.backup_path});
        if (result.size() == max_prune_page) {
            break;
        }
    }
    return result;
}

}
