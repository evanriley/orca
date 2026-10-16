#include "liborca/base/error.hpp"
#include "liborca/metadata/journal.hpp"

#include <cstdint>
#include <doctest/doctest.h>
#include <string>

namespace {

using orca::ErrorCode;
using orca::metadata::journal::MemoryStore;
using orca::metadata::journal::MutationKind;
using orca::metadata::journal::MutationState;
using orca::metadata::journal::OperationInput;
using orca::metadata::journal::Store;

auto input(std::uint64_t plan, std::uint64_t group, std::uint32_t index, std::string source)
    -> OperationInput {
    OperationInput value;
    value.plan_id = plan;
    value.group_id = group;
    value.action_index = index;
    value.source_path = std::move(source);
    value.expected_size = 10;
    value.expected_modified_ns = 20;
    value.expected_content_hash = orca::storage::content_hash::Digest{};
    return value;
}

void stage(MemoryStore& store, std::int64_t id) {
    REQUIRE(store.transition(id, MutationState::planned, MutationState::staged, std::nullopt)
                .has_value());
}

void commit_staged(MemoryStore& store, std::int64_t id) {
    stage(store, id);
    REQUIRE(store
                .commit(id, 5, 6, orca::storage::quick_hash::Digest{},
                        orca::storage::content_hash::Digest{})
                .has_value());
}

}

TEST_CASE("the journal store drives the operation state machine") {
    MemoryStore store;
    const auto id = store.prepare(input(1, 1, 0, "/music/a.flac"));
    REQUIRE(id.has_value());
    REQUIRE(store.state(*id).has_value());
    CHECK(*store.state(*id) == MutationState::planned);
    CHECK(store.operation_count() == 1);

    CHECK(store.transition(*id, MutationState::planned, MutationState::staged, std::nullopt)
              .has_value());
    const auto stale =
        store.transition(*id, MutationState::planned, MutationState::staged, std::nullopt);
    REQUIRE_FALSE(stale.has_value());
    CHECK(stale.error().code == ErrorCode::stale_mutation_operation);

    CHECK(store
              .commit(*id, 5, 6, orca::storage::quick_hash::Digest{},
                      orca::storage::content_hash::Digest{})
              .has_value());
    const auto operation = store.get(*id);
    REQUIRE(operation.has_value());
    CHECK(operation->source_path == "/music/a.flac");
    CHECK(operation->kind == MutationKind::write_tags);
    CHECK(operation->action_index == 0);
    CHECK(operation->state == MutationState::committed);
    CHECK(operation->committed_size == std::optional<std::uint64_t>(5));

    const auto unknown = store.state(999);
    REQUIRE_FALSE(unknown.has_value());
    CHECK(unknown.error().code == ErrorCode::mutation_operation_not_found);
}

TEST_CASE("a failed operation can be rolled back and a wrong transition is refused") {
    MemoryStore store;
    const auto id = store.prepare(input(1, 1, 0, "/music/a.flac"));
    REQUIRE(id.has_value());
    REQUIRE(
        store.transition(*id, MutationState::planned, MutationState::failed, "boom").has_value());
    CHECK(store.roll_back_failed(*id).has_value());
    REQUIRE(store.state(*id).has_value());
    CHECK(*store.state(*id) == MutationState::rolled_back);

    const auto again = store.roll_back_failed(*id);
    REQUIRE_FALSE(again.has_value());
    CHECK(again.error().code == ErrorCode::stale_mutation_operation);

    CHECK_FALSE(orca::metadata::journal::valid_mutation_transition(MutationState::planned,
                                                                   MutationState::committed));
    CHECK(orca::metadata::journal::valid_mutation_transition(MutationState::staged,
                                                             MutationState::rolled_back));
    CHECK(orca::metadata::journal::valid_mutation_transition(MutationState::committed,
                                                             MutationState::needs_reconciliation));
}

TEST_CASE("undo begins only when every operation of a group is committed") {
    MemoryStore store;
    const auto first = store.prepare(input(1, 1, 0, "/a.flac"));
    const auto second = store.prepare(input(1, 1, 1, "/b.flac"));
    REQUIRE(first.has_value());
    REQUIRE(second.has_value());
    commit_staged(store, *first);
    stage(store, *second);

    const auto early = store.begin_undo(1);
    REQUIRE_FALSE(early.has_value());
    CHECK(early.error().code == ErrorCode::mutation_group_not_committed);

    REQUIRE(store.transition(*second, MutationState::staged, MutationState::committed, std::nullopt)
                .has_value());
    CHECK(store.begin_undo(1).has_value());
    REQUIRE(store.state(*first).has_value());
    REQUIRE(store.state(*second).has_value());
    CHECK(*store.state(*first) == MutationState::undoing);
    CHECK(*store.state(*second) == MutationState::undoing);

    const auto missing = store.begin_undo(99);
    REQUIRE_FALSE(missing.has_value());
    CHECK(missing.error().code == ErrorCode::mutation_group_not_found);
}

TEST_CASE("group ids come back in reverse action order and nonterminal groups are reported") {
    MemoryStore store;
    const auto zero = store.prepare(input(1, 1, 0, "/a.flac"));
    const auto two = store.prepare(input(1, 1, 2, "/c.flac"));
    const auto one = store.prepare(input(1, 1, 1, "/b.flac"));
    REQUIRE(zero.has_value());
    REQUIRE(two.has_value());
    REQUIRE(one.has_value());

    const auto ids = store.group_operation_ids(1);
    REQUIRE(ids.has_value());
    REQUIRE(ids->size() == 3);
    CHECK(*ids == std::vector<std::int64_t>{*two, *one, *zero});

    commit_staged(store, *zero);
    commit_staged(store, *one);
    commit_staged(store, *two);
    const auto terminal = store.nonterminal_group_ids();
    REQUIRE(terminal.has_value());
    CHECK(terminal->empty());

    const auto other = store.prepare(input(2, 2, 0, "/d.flac"));
    REQUIRE(other.has_value());
    const auto groups = store.nonterminal_group_ids();
    REQUIRE(groups.has_value());
    CHECK(*groups == std::vector<std::uint64_t>{2});
    CHECK(*store.next_group_id() == 3);
}

TEST_CASE("an empty journal hands out group id one and rejects an invalid operation") {
    MemoryStore store;
    CHECK(*store.next_group_id() == 1);

    const auto invalid = store.prepare(input(0, 0, 0, ""));
    REQUIRE_FALSE(invalid.has_value());
    CHECK(invalid.error().code == ErrorCode::invalid_mutation_operation);
}
