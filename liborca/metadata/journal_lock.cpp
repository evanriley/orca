#include "liborca/metadata/journal_lock.hpp"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

namespace orca::metadata::journal_lock {

JournalLock::~JournalLock() {
    release();
}

JournalLock::JournalLock(JournalLock&& other) noexcept : file_descriptor_(other.file_descriptor_) {
    other.file_descriptor_ = -1;
}

auto JournalLock::operator=(JournalLock&& other) noexcept -> JournalLock& {
    if (this != &other) {
        release();
        file_descriptor_ = other.file_descriptor_;
        other.file_descriptor_ = -1;
    }
    return *this;
}

auto JournalLock::try_acquire(const std::filesystem::path& path)
    -> expected<std::optional<JournalLock>> {
    const int file_descriptor = ::open(path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0644);
    if (file_descriptor < 0) {
        return fail(ErrorCode::io,
                    "journal lock: open " + path.string() + ": " + std::strerror(errno));
    }
    if (::flock(file_descriptor, LOCK_EX | LOCK_NB) != 0) {
        const int lock_error = errno;
        ::close(file_descriptor);
        if (lock_error == EWOULDBLOCK) {
            return std::optional<JournalLock>{};
        }
        return fail(ErrorCode::io,
                    "journal lock: flock " + path.string() + ": " + std::strerror(lock_error));
    }
    return std::optional<JournalLock>(JournalLock(file_descriptor));
}

auto JournalLock::acquire_for_mutation(const std::optional<std::filesystem::path>& path)
    -> expected<JournalLock> {
    if (!path) {
        return fail(ErrorCode::no_backup_directory, "journal lock: no backup directory");
    }
    auto lock = try_acquire(*path);
    if (!lock) {
        return std::unexpected(lock.error());
    }
    if (!*lock) {
        return fail(ErrorCode::mutation_in_progress, "journal lock: held: " + path->string());
    }
    return std::move(**lock);
}

void JournalLock::release() noexcept {
    if (file_descriptor_ < 0) {
        return;
    }
    ::flock(file_descriptor_, LOCK_UN);
    ::close(file_descriptor_);
    file_descriptor_ = -1;
}

}
