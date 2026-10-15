#include "liborca/storage/source.hpp"

#include "liborca/base/logging.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <sys/stat.h>
#include <unistd.h>

namespace orca::storage {

namespace {

auto error_from_errno() -> Error {
    return Error{.code = ErrorCode::io, .context = std::strerror(errno)};
}

}

auto read_all(const ReadableSource& source, std::uint64_t offset, std::span<std::byte> buffer)
    -> expected<std::size_t> {
    std::size_t filled = 0;
    while (filled < buffer.size()) {
        const auto read = source.read_at(offset + filled, buffer.subspan(filled));
        if (!read) {
            return read;
        }
        if (*read == 0) {
            break;
        }
        filled += *read;
    }
    return filled;
}

MemorySource::MemorySource(std::span<const std::byte> bytes, std::uint64_t inode,
                           std::int64_t modified_ns)
    : bytes_(bytes.begin(), bytes.end()), inode_(inode), modified_ns_(modified_ns) {}

MemorySource::MemorySource(std::string_view text, std::uint64_t inode, std::int64_t modified_ns)
    : inode_(inode), modified_ns_(modified_ns) {
    bytes_.resize(text.size());
    if (!text.empty()) {
        std::memcpy(bytes_.data(), text.data(), text.size());
    }
}

auto MemorySource::read_at(std::uint64_t offset, std::span<std::byte> buffer) const
    -> expected<std::size_t> {
    if (offset >= bytes_.size()) {
        return std::size_t{0};
    }
    const auto start = static_cast<std::size_t>(offset);
    const std::size_t count = std::min(buffer.size(), bytes_.size() - start);
    std::memcpy(buffer.data(), bytes_.data() + start, count);
    return count;
}

auto MemorySource::size() const -> std::uint64_t {
    return bytes_.size();
}

auto MemorySource::identity() const -> StorageIdentity {
    return StorageIdentity{.inode = inode_, .size = bytes_.size(), .modified_ns = modified_ns_};
}

OffsetSource::OffsetSource(const ReadableSource& inner, std::uint64_t offset)
    : inner_(&inner), offset_(offset) {}

auto OffsetSource::read_at(std::uint64_t offset, std::span<std::byte> buffer) const
    -> expected<std::size_t> {
    ORCA_ASSERT(inner_ != nullptr);
    if (offset > std::numeric_limits<std::uint64_t>::max() - offset_) {
        return std::size_t{0};
    }
    const std::uint64_t absolute = offset_ + offset;
    if (absolute >= inner_->size()) {
        return std::size_t{0};
    }
    return inner_->read_at(absolute, buffer);
}

auto OffsetSource::size() const -> std::uint64_t {
    const std::uint64_t inner_size = inner_->size();
    return inner_size > offset_ ? inner_size - offset_ : 0;
}

auto OffsetSource::identity() const -> StorageIdentity {
    return inner_->identity();
}

LocalFileSource::~LocalFileSource() {
    if (fd_ >= 0) {
        ::close(fd_);
    }
}

LocalFileSource::LocalFileSource(LocalFileSource&& other) noexcept
    : fd_(other.fd_), identity_(other.identity_) {
    other.fd_ = -1;
}

auto LocalFileSource::operator=(LocalFileSource&& other) noexcept -> LocalFileSource& {
    if (this != &other) {
        if (fd_ >= 0) {
            ::close(fd_);
        }
        fd_ = other.fd_;
        identity_ = other.identity_;
        other.fd_ = -1;
    }
    return *this;
}

auto LocalFileSource::open(const std::filesystem::path& path) -> expected<LocalFileSource> {
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return fail(ErrorCode::io, "open: " + path.string() + ": " + std::strerror(errno));
    }

    struct stat info{};
    if (::fstat(fd, &info) != 0) {
        const auto error = error_from_errno();
        ::close(fd);
        return std::unexpected(error);
    }

    LocalFileSource source;
    source.fd_ = fd;
    source.identity_ = StorageIdentity{
        .inode = static_cast<std::uint64_t>(info.st_ino),
        .size = static_cast<std::uint64_t>(info.st_size),
        .modified_ns = (static_cast<std::int64_t>(info.st_mtim.tv_sec) * 1'000'000'000) +
                       static_cast<std::int64_t>(info.st_mtim.tv_nsec),
    };
    return source;
}

auto LocalFileSource::read_at(std::uint64_t offset, std::span<std::byte> buffer) const
    -> expected<std::size_t> {
    std::size_t filled = 0;
    while (filled < buffer.size()) {
        const ssize_t read = ::pread(fd_, buffer.data() + filled, buffer.size() - filled,
                                     static_cast<off_t>(offset + filled));
        if (read < 0) {
            if (errno == EINTR) {
                continue;
            }
            return std::unexpected(error_from_errno());
        }
        if (read == 0) {
            break;
        }
        filled += static_cast<std::size_t>(read);
    }
    return filled;
}

auto LocalFileSource::size() const -> std::uint64_t {
    return identity_.size;
}

auto LocalFileSource::identity() const -> StorageIdentity {
    return identity_;
}

}
