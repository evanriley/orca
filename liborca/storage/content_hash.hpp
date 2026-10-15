#pragma once

#include "liborca/storage/source.hpp"

#include <array>
#include <cstdint>
#include <filesystem>

namespace orca::storage::content_hash {

using Digest = std::array<std::uint8_t, 32>;

[[nodiscard]] auto from_source(const ReadableSource& source) -> expected<Digest>;
[[nodiscard]] auto from_path(const std::filesystem::path& path) -> expected<Digest>;

}
