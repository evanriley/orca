#pragma once

#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>

namespace orca::storage::quick_hash {

inline constexpr std::size_t window_bytes = 64 * 1024;

using Digest = std::array<std::uint8_t, 32>;

inline constexpr Digest zero{};

[[nodiscard]] auto from_source(const ReadableSource& source) -> expected<Digest>;
[[nodiscard]] auto from_path(const std::filesystem::path& path) -> expected<Digest>;

}
