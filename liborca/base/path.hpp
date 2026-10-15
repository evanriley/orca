#pragma once

#include "liborca/base/expected.hpp"

#include <cstddef>
#include <filesystem>
#include <string>
#include <string_view>

namespace orca::fs {

using std::filesystem::path;

[[nodiscard]] auto from_utf8(std::string_view text) -> path;
[[nodiscard]] auto to_utf8(const path& value) -> std::string;

[[nodiscard]] auto extension_lower(const path& value) -> std::string;

[[nodiscard]] auto exists(const path& value) -> bool;
[[nodiscard]] auto is_regular_file(const path& value) -> bool;
[[nodiscard]] auto is_directory(const path& value) -> bool;

[[nodiscard]] auto read_file(const path& value, std::size_t bytes_max) -> expected<std::string>;
[[nodiscard]] auto write_file(const path& value, std::string_view data) -> expected<void>;

}
