#pragma once

#include "liborca/base/expected.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <span>
#include <string_view>
#include <vector>

namespace orca::storage {

struct StorageIdentity {
    std::uint64_t inode = 0;
    std::uint64_t size = 0;
    std::int64_t modified_ns = 0;
};

class ReadableSource {
public:
    virtual ~ReadableSource() = default;

    ReadableSource(const ReadableSource&) = delete;
    auto operator=(const ReadableSource&) -> ReadableSource& = delete;

    [[nodiscard]] virtual auto read_at(std::uint64_t offset, std::span<std::byte> buffer) const
        -> expected<std::size_t> = 0;
    [[nodiscard]] virtual auto size() const -> std::uint64_t = 0;
    [[nodiscard]] virtual auto identity() const -> StorageIdentity = 0;

protected:
    ReadableSource() = default;
};

[[nodiscard]] auto read_all(const ReadableSource& source, std::uint64_t offset,
                            std::span<std::byte> buffer) -> expected<std::size_t>;

class MemorySource final : public ReadableSource {
public:
    explicit MemorySource(std::span<const std::byte> bytes, std::uint64_t inode = 0,
                          std::int64_t modified_ns = 0);
    explicit MemorySource(std::string_view text, std::uint64_t inode = 0,
                          std::int64_t modified_ns = 0);

    [[nodiscard]] auto read_at(std::uint64_t offset, std::span<std::byte> buffer) const
        -> expected<std::size_t> override;
    [[nodiscard]] auto size() const -> std::uint64_t override;
    [[nodiscard]] auto identity() const -> StorageIdentity override;

private:
    std::vector<std::byte> bytes_;
    std::uint64_t inode_;
    std::int64_t modified_ns_;
};

class OffsetSource final : public ReadableSource {
public:
    OffsetSource(const ReadableSource& inner, std::uint64_t offset);

    [[nodiscard]] auto read_at(std::uint64_t offset, std::span<std::byte> buffer) const
        -> expected<std::size_t> override;
    [[nodiscard]] auto size() const -> std::uint64_t override;
    [[nodiscard]] auto identity() const -> StorageIdentity override;

private:
    const ReadableSource* inner_;
    std::uint64_t offset_;
};

class LocalFileSource final : public ReadableSource {
public:
    LocalFileSource() = default;
    ~LocalFileSource();

    LocalFileSource(const LocalFileSource&) = delete;
    auto operator=(const LocalFileSource&) -> LocalFileSource& = delete;
    LocalFileSource(LocalFileSource&& other) noexcept;
    auto operator=(LocalFileSource&& other) noexcept -> LocalFileSource&;

    [[nodiscard]] static auto open(const std::filesystem::path& path) -> expected<LocalFileSource>;

    [[nodiscard]] auto read_at(std::uint64_t offset, std::span<std::byte> buffer) const
        -> expected<std::size_t> override;
    [[nodiscard]] auto size() const -> std::uint64_t override;
    [[nodiscard]] auto identity() const -> StorageIdentity override;

private:
    int fd_ = -1;
    StorageIdentity identity_{};
};

}
