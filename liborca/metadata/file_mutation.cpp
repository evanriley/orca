#include "liborca/metadata/file_mutation.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/metadata/id3v2.hpp"
#include "liborca/metadata/vorbis_comment.hpp"
#include "liborca/storage/content_hash.hpp"
#include "liborca/storage/quick_hash.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <linux/fs.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <system_error>
#include <unistd.h>
#include <vector>

namespace orca::metadata::file_mutation {

namespace {

constexpr std::size_t copy_buffer_bytes = 64U * 1024U;

auto error_from_errno(std::string_view action, const std::filesystem::path& path) -> Error {
    return Error{.code = ErrorCode::io,
                 .context =
                     std::string(action) + " " + path.string() + ": " + std::strerror(errno)};
}

[[nodiscard]] auto modified_ns_of(const struct stat& info) -> expected<std::int64_t> {
    const auto seconds = static_cast<std::int64_t>(info.st_mtim.tv_sec);
    std::int64_t value = 0;
    if (__builtin_mul_overflow(seconds, 1'000'000'000LL, &value)) {
        return fail(ErrorCode::file_timestamp_out_of_range, "file: timestamp out of range");
    }
    return value + static_cast<std::int64_t>(info.st_mtim.tv_nsec);
}

[[nodiscard]] auto mode_bits(const struct stat& info) -> mode_t {
    return info.st_mode & static_cast<mode_t>(07777);
}

[[nodiscard]] auto copy_contents(int source, int destination, std::uint64_t length)
    -> expected<void> {
    std::array<std::byte, copy_buffer_bytes> buffer{};
    std::uint64_t copied = 0;
    while (copied < length) {
        ORCA_ASSERT(copied < length);
        const auto want =
            static_cast<std::size_t>(std::min<std::uint64_t>(buffer.size(), length - copied));
        ssize_t read_count = 0;
        do {
            read_count = ::pread(source, buffer.data(), want, static_cast<off_t>(copied));
        } while (read_count < 0 && errno == EINTR);
        if (read_count < 0) {
            return fail(ErrorCode::io, std::string("copy: read: ") + std::strerror(errno));
        }
        if (read_count == 0) {
            return fail(ErrorCode::io, "copy: unexpected end of file");
        }
        std::size_t written = 0;
        while (written < static_cast<std::size_t>(read_count)) {
            ssize_t write_count = 0;
            do {
                write_count = ::write(destination, buffer.data() + written,
                                      static_cast<std::size_t>(read_count) - written);
            } while (write_count < 0 && errno == EINTR);
            if (write_count < 0) {
                return fail(ErrorCode::io, std::string("copy: write: ") + std::strerror(errno));
            }
            written += static_cast<std::size_t>(write_count);
        }
        copied += static_cast<std::uint64_t>(read_count);
    }
    return {};
}

[[nodiscard]] auto write_all(int file_descriptor, std::span<const std::byte> data)
    -> expected<void> {
    std::size_t written = 0;
    while (written < data.size()) {
        ssize_t count = 0;
        do {
            count = ::write(file_descriptor, data.data() + written, data.size() - written);
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            return fail(ErrorCode::io, std::string("write: ") + std::strerror(errno));
        }
        written += static_cast<std::size_t>(count);
    }
    return {};
}

[[nodiscard]] auto read_exact_fd(int file_descriptor, std::span<std::byte> buffer,
                                 std::uint64_t offset) -> expected<void> {
    std::size_t filled = 0;
    while (filled < buffer.size()) {
        ssize_t count = 0;
        do {
            count = ::pread(file_descriptor, buffer.data() + filled, buffer.size() - filled,
                            static_cast<off_t>(offset + filled));
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            return fail(ErrorCode::io, std::string("read: ") + std::strerror(errno));
        }
        if (count == 0) {
            return fail(ErrorCode::io, "read: unexpected end of file");
        }
        filled += static_cast<std::size_t>(count);
    }
    return {};
}

[[nodiscard]] auto copy_range_fd(int source, int destination, std::uint64_t start,
                                 std::uint64_t length) -> expected<void> {
    std::array<std::byte, copy_buffer_bytes> buffer{};
    std::uint64_t copied = 0;
    while (copied < length) {
        const auto want =
            static_cast<std::size_t>(std::min<std::uint64_t>(buffer.size(), length - copied));
        ssize_t count = 0;
        do {
            count = ::pread(source, buffer.data(), want, static_cast<off_t>(start + copied));
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            return fail(ErrorCode::io, std::string("read: ") + std::strerror(errno));
        }
        if (count == 0) {
            return fail(ErrorCode::io, "read: unexpected end of file");
        }
        const auto written =
            write_all(destination,
                      std::span<const std::byte>(buffer.data(), static_cast<std::size_t>(count)));
        if (!written) {
            return std::unexpected(written.error());
        }
        copied += static_cast<std::uint64_t>(count);
    }
    return {};
}

[[nodiscard]] auto open_stage(const std::filesystem::path& path, mode_t mode) -> expected<int> {
    const int file_descriptor = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
    if (file_descriptor < 0) {
        return std::unexpected(error_from_errno("create stage", path));
    }
    if (::fchmod(file_descriptor, mode) != 0) {
        const Error error = error_from_errno("chmod stage", path);
        ::close(file_descriptor);
        return std::unexpected(error);
    }
    return file_descriptor;
}

void remove_stage(int file_descriptor, const std::filesystem::path& path) {
    ::close(file_descriptor);
    std::error_code ignored;
    std::filesystem::remove(path, ignored);
}

[[nodiscard]] auto read_u24(std::span<const std::byte> bytes) -> std::uint32_t {
    return (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[0])) << 16U) |
           (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[1])) << 8U) |
           static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[2]));
}

[[nodiscard]] auto write_metadata_header(int file_descriptor, bool is_last, std::uint8_t type,
                                         std::uint32_t length) -> expected<void> {
    std::array<std::byte, 4> header{};
    header[0] = static_cast<std::byte>(type | (is_last ? 0x80U : 0U));
    header[1] = static_cast<std::byte>((length >> 16U) & 0xffU);
    header[2] = static_cast<std::byte>((length >> 8U) & 0xffU);
    header[3] = static_cast<std::byte>(length & 0xffU);
    return write_all(file_descriptor, header);
}

[[nodiscard]] auto write_rewritten_comment(int stage, bool is_last,
                                           std::span<const std::byte> payload,
                                           const std::vector<mutation::Change>& changes,
                                           const std::optional<mutation::GenreChange>& genres)
    -> expected<void> {
    const auto rewritten = vorbis_comment::rewrite(payload, changes, genres);
    if (!rewritten) {
        return std::unexpected(rewritten.error());
    }
    if (rewritten->size() > vorbis_comment::max_metadata_block_size) {
        return fail(ErrorCode::metadata_value_too_long, "flac: comment block too large");
    }
    const auto header =
        write_metadata_header(stage, is_last, 4, static_cast<std::uint32_t>(rewritten->size()));
    if (!header) {
        return header;
    }
    return write_all(stage, *rewritten);
}

[[nodiscard]] auto write_created_comment(int stage, const std::vector<mutation::Change>& changes,
                                         const std::optional<mutation::GenreChange>& genres)
    -> expected<void> {
    const auto created = vorbis_comment::create(changes, genres);
    if (!created) {
        return std::unexpected(created.error());
    }
    if (created->size() > vorbis_comment::max_metadata_block_size) {
        return fail(ErrorCode::metadata_value_too_long, "flac: comment block too large");
    }
    const auto header =
        write_metadata_header(stage, true, 4, static_cast<std::uint32_t>(created->size()));
    if (!header) {
        return header;
    }
    return write_all(stage, *created);
}

[[nodiscard]] auto replace_verified(const std::filesystem::path& replacement_path,
                                    const std::filesystem::path& target_path,
                                    const mutation::FileIdentity& target_expected)
    -> expected<void> {
    const auto check = require_identity_at(target_path, target_expected);
    if (!check) {
        return std::unexpected(check.error());
    }
    std::error_code error;
    std::filesystem::rename(replacement_path, target_path, error);
    if (error) {
        return fail(ErrorCode::io,
                    "rename " + replacement_path.string() + " -> " + target_path.string());
    }
    const auto target_sync = sync_containing_directory(target_path);
    if (!target_sync) {
        return std::unexpected(target_sync.error());
    }
    return sync_containing_directory(replacement_path);
}

[[nodiscard]] auto write_flac_metadata_blocks(int source, int stage, std::uint64_t size,
                                              const std::vector<mutation::Change>& changes,
                                              const std::optional<mutation::GenreChange>& genres)
    -> expected<std::uint64_t> {
    std::uint64_t offset = 4;
    std::size_t block_index = 0;
    bool found_comment = false;
    while (true) {
        std::array<std::byte, 4> header{};
        if (const auto read = read_exact_fd(source, header, offset); !read) {
            return std::unexpected(read.error());
        }
        offset += header.size();
        const auto first = std::to_integer<std::uint8_t>(header[0]);
        const bool is_last = (first & 0x80U) != 0U;
        const auto block_type = static_cast<std::uint8_t>(first & 0x7fU);
        const std::uint32_t length = read_u24(std::span<const std::byte>(header.data() + 1, 3));
        if (block_index == 0 && (block_type != 0 || length != 34)) {
            return fail(ErrorCode::invalid_flac_stream, "flac: first block");
        }
        if (offset + length > size) {
            return fail(ErrorCode::invalid_flac_stream, "flac: block past end");
        }
        if (block_type == 4) {
            if (found_comment) {
                return fail(ErrorCode::multiple_vorbis_comment_blocks, "flac: duplicate comment");
            }
            found_comment = true;
            std::vector<std::byte> payload(length);
            if (const auto read = read_exact_fd(source, payload, offset); !read) {
                return std::unexpected(read.error());
            }
            if (const auto written =
                    write_rewritten_comment(stage, is_last, payload, changes, genres);
                !written) {
                return std::unexpected(written.error());
            }
        } else {
            if (is_last && !found_comment) {
                header[0] = static_cast<std::byte>(block_type);
            }
            if (const auto written = write_all(stage, header); !written) {
                return std::unexpected(written.error());
            }
            if (const auto copied = copy_range_fd(source, stage, offset, length); !copied) {
                return std::unexpected(copied.error());
            }
        }
        offset += length;
        if (is_last) {
            if (!found_comment) {
                if (const auto written = write_created_comment(stage, changes, genres); !written) {
                    return std::unexpected(written.error());
                }
            }
            return offset;
        }
        block_index += 1;
    }
}

}

auto is_orca_temporary_name(std::string_view name) -> bool {
    if (name.find(".orca-stage-") != std::string_view::npos) {
        return true;
    }
    if (name.find(".orca-backup-") != std::string_view::npos) {
        return true;
    }
    if (name.ends_with(".recovery-displaced")) {
        return true;
    }
    return name.starts_with(".") && name.find(".orca-restore-") != std::string_view::npos;
}

auto sibling_path(const std::filesystem::path& source_path, std::string_view purpose,
                  std::uint64_t plan_id, std::size_t action_index) -> std::string {
    const std::string hidden = "." + source_path.filename().string() + ".orca-" +
                               std::string(purpose) + "-" + std::to_string(plan_id) + "-" +
                               std::to_string(action_index);
    return (source_path.parent_path() / hidden).string();
}

auto plan_backup_directory(const std::filesystem::path& backup_directory, std::uint64_t plan_id)
    -> std::string {
    return backup_directory.string() + "/" + std::to_string(plan_id);
}

auto backup_path(const std::string& plan_directory, std::size_t action_index,
                 const std::filesystem::path& source_path) -> std::string {
    return plan_directory + "/" + std::to_string(action_index) + "-" +
           source_path.filename().string();
}

auto identity(const std::filesystem::path& path) -> expected<mutation::FileIdentity> {
    struct stat info{};
    if (::stat(path.c_str(), &info) != 0) {
        return fail(ErrorCode::not_found, "identity: " + path.string());
    }
    const auto modified = modified_ns_of(info);
    if (!modified) {
        return std::unexpected(modified.error());
    }
    const auto quick = storage::quick_hash::from_path(path);
    if (!quick) {
        return std::unexpected(quick.error());
    }
    const auto content = storage::content_hash::from_path(path);
    if (!content) {
        return std::unexpected(content.error());
    }
    mutation::FileIdentity result;
    result.size_bytes = static_cast<std::uint64_t>(info.st_size);
    result.modified_ns = *modified;
    result.quick_hash = *quick;
    result.content_hash = *content;
    return result;
}

auto require_identity_at(const std::filesystem::path& path,
                         const mutation::FileIdentity& expected_identity) -> expected<void> {
    struct stat info{};
    if (::stat(path.c_str(), &info) != 0) {
        return fail(ErrorCode::not_found, "identity: " + path.string());
    }
    const auto modified = modified_ns_of(info);
    if (!modified) {
        return std::unexpected(modified.error());
    }
    if (static_cast<std::uint64_t>(info.st_size) != expected_identity.size_bytes ||
        *modified != expected_identity.modified_ns) {
        return fail(ErrorCode::file_identity_changed, "identity: " + path.string());
    }
    const auto quick = storage::quick_hash::from_path(path);
    if (!quick) {
        return std::unexpected(quick.error());
    }
    if (*quick != expected_identity.quick_hash) {
        return fail(ErrorCode::file_identity_changed, "identity: " + path.string());
    }
    if (!expected_identity.content_hash) {
        return {};
    }
    const auto content = storage::content_hash::from_path(path);
    if (!content) {
        return std::unexpected(content.error());
    }
    if (*content != *expected_identity.content_hash) {
        return fail(ErrorCode::file_identity_changed, "identity: " + path.string());
    }
    return {};
}

auto matches(const std::filesystem::path& path, const mutation::FileIdentity& expected_identity)
    -> expected<bool> {
    const auto check = require_identity_at(path, expected_identity);
    if (!check) {
        if (check.error().code == ErrorCode::file_identity_changed) {
            return false;
        }
        return std::unexpected(check.error());
    }
    return true;
}

auto require_writable_file(const std::filesystem::path& path) -> expected<void> {
    struct stat info{};
    if (::stat(path.c_str(), &info) != 0) {
        return fail(ErrorCode::not_found, "writable: " + path.string());
    }
    if ((info.st_mode & static_cast<mode_t>(S_IWUSR | S_IWGRP | S_IWOTH)) == 0) {
        return fail(ErrorCode::file_read_only, "writable: " + path.string());
    }
    if (::access(path.c_str(), W_OK) != 0) {
        return fail(ErrorCode::file_read_only, "writable: " + path.string());
    }
    return {};
}

auto sync_containing_directory(const std::filesystem::path& path) -> expected<void> {
    const std::filesystem::path directory = path.parent_path();
    const int descriptor = ::open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0) {
        return std::unexpected(error_from_errno("open directory", directory));
    }
    const int result = ::fsync(descriptor);
    const int sync_error = errno;
    ::close(descriptor);
    if (result != 0) {
        return fail(ErrorCode::io,
                    "fsync " + directory.string() + ": " + std::strerror(sync_error));
    }
    return {};
}

auto create_directory_durably(const std::filesystem::path& path) -> expected<void> {
    std::error_code error;
    const bool created = std::filesystem::create_directory(path, error);
    if (error) {
        return fail(ErrorCode::io, "create directory " + path.string());
    }
    if (!created) {
        return {};
    }
    return sync_containing_directory(path);
}

auto delete_if_present(const std::filesystem::path& path) -> expected<void> {
    if (::unlink(path.c_str()) != 0) {
        if (errno == ENOENT) {
            return {};
        }
        return std::unexpected(error_from_errno("delete", path));
    }
    return sync_containing_directory(path);
}

auto copy_verified(const std::filesystem::path& source_path, const std::filesystem::path& copy_path,
                   const mutation::FileIdentity& expected_identity) -> expected<void> {
    const int source = ::open(source_path.c_str(), O_RDONLY | O_CLOEXEC);
    if (source < 0) {
        return std::unexpected(error_from_errno("open", source_path));
    }
    struct stat source_info{};
    if (::fstat(source, &source_info) != 0) {
        const Error error = error_from_errno("fstat", source_path);
        ::close(source);
        return std::unexpected(error);
    }
    const int copy =
        ::open(copy_path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_bits(source_info));
    if (copy < 0) {
        const Error error = error_from_errno("create", copy_path);
        ::close(source);
        return std::unexpected(error);
    }

    const auto copied =
        copy_contents(source, copy, static_cast<std::uint64_t>(source_info.st_size));
    if (!copied) {
        ::close(copy);
        ::close(source);
        std::error_code ignored;
        std::filesystem::remove(copy_path, ignored);
        return std::unexpected(copied.error());
    }

    ORCA_ASSERT(expected_identity.modified_ns >= 0);
    timespec times[2]{};
    times[0].tv_nsec = UTIME_OMIT;
    times[1].tv_sec = static_cast<time_t>(expected_identity.modified_ns / 1'000'000'000);
    times[1].tv_nsec = static_cast<long>(expected_identity.modified_ns % 1'000'000'000);
    (void)::fchmod(copy, mode_bits(source_info));
    (void)::futimens(copy, times);
    const int sync_result = ::fsync(copy);
    ::close(copy);
    ::close(source);
    if (sync_result != 0) {
        std::error_code ignored;
        std::filesystem::remove(copy_path, ignored);
        return fail(ErrorCode::io, "fsync " + copy_path.string());
    }

    const auto actual = identity(copy_path);
    if (!actual || !actual->eql(expected_identity)) {
        std::error_code ignored;
        std::filesystem::remove(copy_path, ignored);
        return fail(ErrorCode::copy_identity_mismatch, "copy " + copy_path.string());
    }
    return sync_containing_directory(copy_path);
}

auto stage_mpeg(const std::filesystem::path& source_path, const std::filesystem::path& stage_path,
                const mutation::FileIdentity& expected_identity,
                const std::vector<mutation::Change>& changes,
                const std::optional<mutation::GenreChange>& genres) -> expected<void> {
    struct stat info{};
    if (::stat(source_path.c_str(), &info) != 0) {
        return fail(ErrorCode::not_found, "stage: " + source_path.string());
    }
    const auto check = require_identity_at(source_path, expected_identity);
    if (!check) {
        return std::unexpected(check.error());
    }
    const int source = ::open(source_path.c_str(), O_RDONLY | O_CLOEXEC);
    if (source < 0) {
        return std::unexpected(error_from_errno("open", source_path));
    }
    const auto readable = storage::LocalFileSource::open(source_path);
    if (!readable) {
        ::close(source);
        return std::unexpected(readable.error());
    }
    const auto planned = id3v2::rewrite(*readable, changes, genres);
    if (!planned) {
        ::close(source);
        return std::unexpected(planned.error());
    }
    if (planned->audio_start > planned->audio_end ||
        planned->audio_end > static_cast<std::uint64_t>(info.st_size)) {
        ::close(source);
        return fail(ErrorCode::invalid_mpeg_stream, "stage: " + source_path.string());
    }
    const auto stage = open_stage(stage_path, mode_bits(info));
    if (!stage) {
        ::close(source);
        return std::unexpected(stage.error());
    }
    const auto abort = [&]() {
        remove_stage(*stage, stage_path);
        ::close(source);
    };
    if (const auto written = write_all(*stage, planned->tag); !written) {
        abort();
        return std::unexpected(written.error());
    }
    if (const auto copied = copy_range_fd(source, *stage, planned->audio_start,
                                          planned->audio_end - planned->audio_start);
        !copied) {
        abort();
        return std::unexpected(copied.error());
    }
    if (planned->trailer) {
        if (const auto written = write_all(*stage, *planned->trailer); !written) {
            abort();
            return std::unexpected(written.error());
        }
    }
    if (::fsync(*stage) != 0) {
        abort();
        return fail(ErrorCode::io, "fsync " + stage_path.string());
    }
    ::close(*stage);
    ::close(source);
    return sync_containing_directory(stage_path);
}

auto stage_flac(const std::filesystem::path& source_path, const std::filesystem::path& stage_path,
                const mutation::FileIdentity& expected_identity,
                const std::vector<mutation::Change>& changes,
                const std::optional<mutation::GenreChange>& genres) -> expected<void> {
    struct stat info{};
    if (::stat(source_path.c_str(), &info) != 0) {
        return fail(ErrorCode::not_found, "stage: " + source_path.string());
    }
    const auto check = require_identity_at(source_path, expected_identity);
    if (!check) {
        return std::unexpected(check.error());
    }
    const int source = ::open(source_path.c_str(), O_RDONLY | O_CLOEXEC);
    if (source < 0) {
        return std::unexpected(error_from_errno("open", source_path));
    }
    std::array<std::byte, 4> magic{};
    if (const auto read = read_exact_fd(source, magic, 0); !read) {
        ::close(source);
        return std::unexpected(read.error());
    }
    if (std::memcmp(magic.data(), "fLaC", 4) != 0) {
        ::close(source);
        return fail(ErrorCode::invalid_flac_stream, "stage: " + source_path.string());
    }
    const auto stage = open_stage(stage_path, mode_bits(info));
    if (!stage) {
        ::close(source);
        return std::unexpected(stage.error());
    }
    const auto abort = [&]() {
        remove_stage(*stage, stage_path);
        ::close(source);
    };
    if (const auto written = write_all(*stage, magic); !written) {
        abort();
        return std::unexpected(written.error());
    }
    std::uint64_t offset = magic.size();
    const auto audio_offset = write_flac_metadata_blocks(
        source, *stage, static_cast<std::uint64_t>(info.st_size), changes, genres);
    if (!audio_offset) {
        abort();
        return std::unexpected(audio_offset.error());
    }
    offset = *audio_offset;
    if (offset < static_cast<std::uint64_t>(info.st_size)) {
        if (const auto copied = copy_range_fd(source, *stage, offset,
                                              static_cast<std::uint64_t>(info.st_size) - offset);
            !copied) {
            abort();
            return std::unexpected(copied.error());
        }
    }
    if (::fsync(*stage) != 0) {
        abort();
        return fail(ErrorCode::io, "fsync " + stage_path.string());
    }
    ::close(*stage);
    ::close(source);
    return sync_containing_directory(stage_path);
}

auto commit_replacement_interrupted(const std::filesystem::path& source_path,
                                    const std::filesystem::path& stage_path,
                                    const std::filesystem::path& backup_path,
                                    const mutation::FileIdentity& expected_identity,
                                    Interrupt interrupt) -> expected<void> {
    const auto check = require_identity_at(source_path, expected_identity);
    if (!check) {
        return std::unexpected(check.error());
    }
    const auto copied = copy_verified(source_path, backup_path, expected_identity);
    if (!copied) {
        return std::unexpected(copied.error());
    }
    if (interrupt == Interrupt::after_backup_copy) {
        return fail(ErrorCode::simulated_power_loss, "commit: after backup copy");
    }
    const auto replaced = replace_verified(stage_path, source_path, expected_identity);
    if (!replaced) {
        return std::unexpected(replaced.error());
    }
    if (interrupt == Interrupt::after_source_rename) {
        return fail(ErrorCode::simulated_power_loss, "commit: after source rename");
    }
    return {};
}

auto commit_replacement(const std::filesystem::path& source_path,
                        const std::filesystem::path& stage_path,
                        const std::filesystem::path& backup_path,
                        const mutation::FileIdentity& expected_identity) -> expected<void> {
    return commit_replacement_interrupted(source_path, stage_path, backup_path, expected_identity,
                                          Interrupt::none);
}

auto commit_move(const std::filesystem::path& source_path,
                 const std::filesystem::path& destination_path) -> expected<void> {
    const int result = static_cast<int>(::syscall(SYS_renameat2, AT_FDCWD, source_path.c_str(),
                                                  AT_FDCWD, destination_path.c_str(),
                                                  static_cast<unsigned int>(RENAME_NOREPLACE)));
    if (result != 0) {
        if (errno == EEXIST) {
            return fail(ErrorCode::destination_exists, "move: " + destination_path.string());
        }
        return std::unexpected(error_from_errno("rename", source_path));
    }
    const auto source_sync = sync_containing_directory(source_path);
    if (!source_sync) {
        return std::unexpected(source_sync.error());
    }
    return sync_containing_directory(destination_path);
}

auto restore_from_backup_interrupted(const std::filesystem::path& source_path,
                                     const std::filesystem::path& backup_path,
                                     const std::filesystem::path& restore_path,
                                     const mutation::FileIdentity& original,
                                     const mutation::FileIdentity& replacing, Interrupt interrupt)
    -> expected<void> {
    const auto deleted = delete_if_present(restore_path);
    if (!deleted) {
        return std::unexpected(deleted.error());
    }
    const auto copied = copy_verified(backup_path, restore_path, original);
    if (!copied) {
        return std::unexpected(copied.error());
    }
    if (interrupt == Interrupt::after_restore_copy) {
        return fail(ErrorCode::simulated_power_loss, "restore: after restore copy");
    }
    const auto replaced = replace_verified(restore_path, source_path, replacing);
    if (!replaced) {
        std::error_code ignored;
        std::filesystem::remove(restore_path, ignored);
        return std::unexpected(replaced.error());
    }
    if (interrupt == Interrupt::after_restore_rename) {
        return fail(ErrorCode::simulated_power_loss, "restore: after restore rename");
    }
    return {};
}

auto restore_from_backup(const std::filesystem::path& source_path,
                         const std::filesystem::path& backup_path,
                         const std::filesystem::path& restore_path,
                         const mutation::FileIdentity& original,
                         const mutation::FileIdentity& replacing) -> expected<void> {
    return restore_from_backup_interrupted(source_path, backup_path, restore_path, original,
                                           replacing, Interrupt::none);
}

}
