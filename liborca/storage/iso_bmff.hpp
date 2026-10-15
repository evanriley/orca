#pragma once

#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace orca::storage::iso_bmff {

inline constexpr std::size_t max_movie_bytes = 64 * 1024 * 1024;
inline constexpr std::size_t max_top_level_boxes = 1024;

struct Box {
    std::array<std::byte, 4> kind{};
    std::span<const std::byte> body{};

    [[nodiscard]] auto is(std::string_view name) const -> bool;
};

class Iterator {
public:
    explicit Iterator(std::span<const std::byte> bytes) : bytes_(bytes) {}

    [[nodiscard]] auto next() -> expected<std::optional<Box>>;

    [[nodiscard]] static auto find(std::span<const std::byte> bytes, std::string_view kind)
        -> expected<std::optional<Box>>;

private:
    std::span<const std::byte> bytes_;
    std::size_t cursor_ = 0;
};

[[nodiscard]] auto descend(std::span<const std::byte> bytes, std::span<const std::string_view> path)
    -> expected<std::optional<Box>>;

[[nodiscard]] auto read_movie(const ReadableSource& source) -> expected<std::vector<std::byte>>;

template <typename T>
[[nodiscard]] auto integer(std::span<const std::byte> bytes, std::size_t offset) -> expected<T> {
    constexpr std::size_t width = sizeof(T);
    if (offset > bytes.size() || bytes.size() - offset < width) {
        return fail(ErrorCode::parse, "iso_bmff: integer past end");
    }
    using Unsigned = std::make_unsigned_t<T>;
    Unsigned value = 0;
    for (std::size_t index = 0; index < width; ++index) {
        value =
            static_cast<Unsigned>((value << 8U) | std::to_integer<Unsigned>(bytes[offset + index]));
    }
    return static_cast<T>(value);
}

}
