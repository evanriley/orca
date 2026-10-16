#include "liborca/metadata/journal_lock.hpp"

#include <doctest/doctest.h>
#include <filesystem>
#include <optional>

namespace {

auto lock_directory() -> std::filesystem::path {
    const auto directory = std::filesystem::temp_directory_path() / "orca-journal-lock-test";
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory);
    return directory;
}

}

TEST_CASE("a second journal lock acquisition in the same process is refused until released") {
    const auto directory = lock_directory();
    const auto path = directory / "library.db.orca-journal.lock";

    auto first = orca::metadata::journal_lock::JournalLock::try_acquire(path);
    REQUIRE(first.has_value());
    REQUIRE(first->has_value());

    auto second = orca::metadata::journal_lock::JournalLock::try_acquire(path);
    REQUIRE(second.has_value());
    CHECK_FALSE(second->has_value());

    (*first)->release();

    auto third = orca::metadata::journal_lock::JournalLock::try_acquire(path);
    REQUIRE(third.has_value());
    REQUIRE(third->has_value());
    (*third)->release();

    std::filesystem::remove_all(directory);
}

TEST_CASE("the journal lock file outlives the lock and is reused") {
    const auto directory = lock_directory();
    const auto path = directory / "library.db.orca-journal.lock";

    {
        auto lock = orca::metadata::journal_lock::JournalLock::try_acquire(path);
        REQUIRE(lock.has_value());
        REQUIRE(lock->has_value());
        (*lock)->release();
    }
    CHECK(std::filesystem::exists(path));

    auto again = orca::metadata::journal_lock::JournalLock::try_acquire(path);
    REQUIRE(again.has_value());
    REQUIRE(again->has_value());
    (*again)->release();

    std::filesystem::remove_all(directory);
}

TEST_CASE("acquireForMutation needs a lock path and refuses a held lock") {
    using orca::ErrorCode;

    const auto missing =
        orca::metadata::journal_lock::JournalLock::acquire_for_mutation(std::nullopt);
    REQUIRE_FALSE(missing.has_value());
    CHECK(missing.error().code == ErrorCode::no_backup_directory);

    const auto directory = lock_directory();
    const auto path = directory / "library.db.orca-journal.lock";
    auto held = orca::metadata::journal_lock::JournalLock::try_acquire(path);
    REQUIRE(held.has_value());
    REQUIRE(held->has_value());

    const auto refused = orca::metadata::journal_lock::JournalLock::acquire_for_mutation(path);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == ErrorCode::mutation_in_progress);

    (*held)->release();
    const auto acquired = orca::metadata::journal_lock::JournalLock::acquire_for_mutation(path);
    REQUIRE(acquired.has_value());

    std::filesystem::remove_all(directory);
}
