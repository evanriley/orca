#include "liborca/metadata/recovery.hpp"

#include <cstdint>
#include <utility>

namespace orca::metadata::recovery {

auto recover_pending(journal::Store& store, const journal_lock::JournalLock& lock,
                     std::optional<std::filesystem::path> backup_directory,
                     std::optional<executor::Fault> fault) -> expected<Summary> {
    Summary summary;
    const auto group_ids = store.nonterminal_group_ids();
    if (!group_ids) {
        return std::unexpected(group_ids.error());
    }
    summary.groups = group_ids->size();
    ORCA_ASSERT(summary.groups == group_ids->size());
    if (group_ids->empty()) {
        return summary;
    }

    executor::Executor executor(store, lock, std::move(backup_directory), fault);
    for (const std::uint64_t group_id : *group_ids) {
        ORCA_ASSERT(group_id != 0);
        const auto recovered = executor.recover_group(group_id);
        if (!recovered) {
            return std::unexpected(recovered.error());
        }
    }

    for (const std::uint64_t group_id : *group_ids) {
        const auto operation_ids = store.group_operation_ids(group_id);
        if (!operation_ids) {
            return std::unexpected(operation_ids.error());
        }
        for (const std::int64_t operation_id : *operation_ids) {
            summary.operations += 1;
            const auto state = store.state(operation_id);
            if (!state) {
                return std::unexpected(state.error());
            }
            switch (*state) {
            case journal::MutationState::rolled_back:
                ORCA_ASSERT(summary.rolled_back < summary.operations);
                summary.rolled_back += 1;
                break;
            case journal::MutationState::needs_reconciliation:
                ORCA_ASSERT(summary.needs_reconciliation < summary.operations);
                summary.needs_reconciliation += 1;
                break;
            case journal::MutationState::committed:
                break;
            case journal::MutationState::planned:
            case journal::MutationState::staged:
            case journal::MutationState::failed:
            case journal::MutationState::undoing:
                return fail(ErrorCode::mutation_recovery_incomplete,
                            "recovery: nonterminal operation remains");
            }
        }
    }
    ORCA_ASSERT(summary.rolled_back + summary.needs_reconciliation <= summary.operations);
    return summary;
}

}
