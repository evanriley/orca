#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/storage/source.hpp"

#include <cstdint>
#include <optional>
#include <span>

namespace orca::metadata::image_header {

struct Dimensions {
    std::uint32_t width = 0;
    std::uint32_t height = 0;

    [[nodiscard]] auto operator==(const Dimensions& other) const -> bool = default;
};

struct Measurement {
    std::optional<std::uint32_t> width = std::nullopt;
    std::optional<std::uint32_t> height = std::nullopt;
    std::int64_t hash = 0;
};

inline constexpr std::int64_t unreadable_hash = 0;

[[nodiscard]] auto hash(std::span<const std::byte> bytes) -> std::int64_t;
[[nodiscard]] auto measure(std::span<const std::byte> bytes) -> Measurement;
[[nodiscard]] auto measure_at(const storage::ReadableSource& source, std::uint64_t offset,
                              std::uint64_t length) -> expected<Measurement>;
[[nodiscard]] auto dimensions(std::span<const std::byte> bytes) -> std::optional<Dimensions>;

}
