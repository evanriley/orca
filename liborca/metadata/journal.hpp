#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/storage/content_hash.hpp"
#include "liborca/storage/quick_hash.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace orca::metadata::journal {

/// The numeric values are persisted in `mutation_operations` and are
/// append-only, so the order below is part of the on-disk format.
enum class MutationKind : std::uint32_t {
    write_tags,
    move,
};

inline constexpr std::string_view recovered_message = "recovered";

/// The numeric values are persisted in `mutation_operations` and are
/// append-only, so the order below is part of the on-disk format.
enum class MutationState : std::uint32_t {
    planned,
    staged,
    committed,
    rolled_back,
    failed,
    needs_reconciliation,
    undoing,
};

[[nodiscard]] auto valid_mutation_transition(MutationState from, MutationState to) -> bool;

struct OperationInput {
    std::uint64_t plan_id = 0;
    std::uint64_t group_id = 0;
    std::uint32_t action_index = 0;
    MutationKind kind = MutationKind::write_tags;
    std::optional<std::int64_t> file_id = std::nullopt;
    std::string source_path;
    std::optional<std::string> destination_path = std::nullopt;
    std::optional<std::string> stage_path = std::nullopt;
    std::optional<std::string> backup_path = std::nullopt;
    std::uint64_t expected_size = 0;
    std::int64_t expected_modified_ns = 0;
    storage::quick_hash::Digest expected_quick_hash{};
    std::optional<storage::content_hash::Digest> expected_content_hash = std::nullopt;
};

struct Operation {
    std::int64_t id = 0;
    std::uint64_t plan_id = 0;
    std::uint64_t group_id = 0;
    std::uint32_t action_index = 0;
    MutationKind kind = MutationKind::write_tags;
    std::optional<std::int64_t> file_id = std::nullopt;
    std::string source_path;
    std::optional<std::string> destination_path = std::nullopt;
    std::optional<std::string> stage_path = std::nullopt;
    std::optional<std::string> backup_path = std::nullopt;
    std::uint64_t expected_size = 0;
    std::int64_t expected_modified_ns = 0;
    std::optional<storage::quick_hash::Digest> expected_quick_hash = std::nullopt;
    std::optional<storage::content_hash::Digest> expected_content_hash = std::nullopt;
    std::optional<std::uint64_t> committed_size = std::nullopt;
    std::optional<std::int64_t> committed_modified_ns = std::nullopt;
    std::optional<storage::quick_hash::Digest> committed_quick_hash = std::nullopt;
    std::optional<storage::content_hash::Digest> committed_content_hash = std::nullopt;
    MutationState state = MutationState::planned;
    std::optional<std::string> error = std::nullopt;
    std::uint64_t updated_at_s = 0;
};

struct PrunableBackup {
    std::int64_t operation_id = 0;
    std::string backup_path;
};

class Store {
public:
    virtual ~Store() = default;

    Store(const Store&) = delete;
    auto operator=(const Store&) -> Store& = delete;

    [[nodiscard]] virtual auto prepare(const OperationInput& input) -> expected<std::int64_t> = 0;
    [[nodiscard]] virtual auto transition(std::int64_t operation_id, MutationState expected_state,
                                          MutationState next,
                                          const std::optional<std::string>& message)
        -> expected<void> = 0;
    [[nodiscard]] virtual auto roll_back_failed(std::int64_t operation_id) -> expected<void> = 0;
    [[nodiscard]] virtual auto state(std::int64_t operation_id) const
        -> expected<MutationState> = 0;
    [[nodiscard]] virtual auto commit(std::int64_t operation_id, std::uint64_t committed_size,
                                      std::int64_t committed_modified_ns,
                                      const storage::quick_hash::Digest& committed_quick_hash,
                                      const storage::content_hash::Digest& committed_content_hash)
        -> expected<void> = 0;
    [[nodiscard]] virtual auto record_result_identity(std::int64_t operation_id,
                                                      MutationState expected_state,
                                                      std::uint64_t size, std::int64_t modified_ns,
                                                      const storage::quick_hash::Digest& digest,
                                                      const storage::content_hash::Digest& content)
        -> expected<void> = 0;
    [[nodiscard]] virtual auto get(std::int64_t operation_id) const -> expected<Operation> = 0;
    [[nodiscard]] virtual auto nonterminal_group_ids() const
        -> expected<std::vector<std::uint64_t>> = 0;
    [[nodiscard]] virtual auto begin_undo(std::uint64_t group_id) -> expected<void> = 0;
    [[nodiscard]] virtual auto undo_committed(std::uint64_t group_id)
        -> expected<std::uint64_t> = 0;
    [[nodiscard]] virtual auto next_group_id() const -> expected<std::uint64_t> = 0;
    [[nodiscard]] virtual auto group_operation_ids(std::uint64_t group_id) const
        -> expected<std::vector<std::int64_t>> = 0;
    [[nodiscard]] virtual auto clear_backup_path(std::int64_t operation_id) -> expected<void> = 0;
    [[nodiscard]] virtual auto prunable_backups(std::uint64_t older_than_s) const
        -> expected<std::vector<PrunableBackup>> = 0;

protected:
    Store() = default;
};

class MemoryStore : public Store {
public:
    MemoryStore() = default;

    [[nodiscard]] auto prepare(const OperationInput& input) -> expected<std::int64_t> override;
    [[nodiscard]] auto transition(std::int64_t operation_id, MutationState expected_state,
                                  MutationState next, const std::optional<std::string>& message)
        -> expected<void> override;
    [[nodiscard]] auto roll_back_failed(std::int64_t operation_id) -> expected<void> override;
    [[nodiscard]] auto state(std::int64_t operation_id) const -> expected<MutationState> override;
    [[nodiscard]] auto commit(std::int64_t operation_id, std::uint64_t committed_size,
                              std::int64_t committed_modified_ns,
                              const storage::quick_hash::Digest& committed_quick_hash,
                              const storage::content_hash::Digest& committed_content_hash)
        -> expected<void> override;
    [[nodiscard]] auto record_result_identity(std::int64_t operation_id,
                                              MutationState expected_state, std::uint64_t size,
                                              std::int64_t modified_ns,
                                              const storage::quick_hash::Digest& digest,
                                              const storage::content_hash::Digest& content)
        -> expected<void> override;
    [[nodiscard]] auto get(std::int64_t operation_id) const -> expected<Operation> override;
    [[nodiscard]] auto nonterminal_group_ids() const
        -> expected<std::vector<std::uint64_t>> override;
    [[nodiscard]] auto begin_undo(std::uint64_t group_id) -> expected<void> override;
    [[nodiscard]] auto undo_committed(std::uint64_t group_id) -> expected<std::uint64_t> override;
    [[nodiscard]] auto next_group_id() const -> expected<std::uint64_t> override;
    [[nodiscard]] auto group_operation_ids(std::uint64_t group_id) const
        -> expected<std::vector<std::int64_t>> override;
    [[nodiscard]] auto clear_backup_path(std::int64_t operation_id) -> expected<void> override;
    [[nodiscard]] auto prunable_backups(std::uint64_t older_than_s) const
        -> expected<std::vector<PrunableBackup>> override;

    [[nodiscard]] auto operation_count() const -> std::size_t {
        return operations_.size();
    }
    void set_now(std::uint64_t now_s) {
        now_s_ = now_s;
    }

private:
    [[nodiscard]] auto index_of(std::int64_t operation_id) const -> std::optional<std::size_t>;

    std::vector<Operation> operations_;
    std::int64_t next_id_ = 1;
    std::uint64_t now_s_ = 0;
};

}
