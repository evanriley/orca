#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/executor.hpp"
#include "liborca/metadata/journal.hpp"
#include "liborca/metadata/journal_lock.hpp"

#include <cstddef>
#include <filesystem>
#include <optional>

namespace orca::metadata::recovery {

struct Summary {
    std::size_t groups = 0;
    std::size_t operations = 0;
    std::size_t rolled_back = 0;
    std::size_t needs_reconciliation = 0;
};

[[nodiscard]] auto recover_pending(journal::Store& store, const journal_lock::JournalLock& lock,
                                   std::optional<std::filesystem::path> backup_directory,
                                   std::optional<executor::Fault> fault = std::nullopt)
    -> expected<Summary>;

}
