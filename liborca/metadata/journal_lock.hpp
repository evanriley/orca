#pragma once

#include "liborca/base/expected.hpp"

#include <filesystem>
#include <optional>

namespace orca::metadata::journal_lock {

class JournalLock {
public:
    JournalLock() = default;
    ~JournalLock();

    JournalLock(const JournalLock&) = delete;
    auto operator=(const JournalLock&) -> JournalLock& = delete;
    JournalLock(JournalLock&& other) noexcept;
    auto operator=(JournalLock&& other) noexcept -> JournalLock&;

    [[nodiscard]] static auto try_acquire(const std::filesystem::path& path)
        -> expected<std::optional<JournalLock>>;
    [[nodiscard]] static auto acquire_for_mutation(const std::optional<std::filesystem::path>& path)
        -> expected<JournalLock>;

    void release() noexcept;

private:
    explicit JournalLock(int file_descriptor) : file_descriptor_(file_descriptor) {}

    int file_descriptor_ = -1;
};

}
