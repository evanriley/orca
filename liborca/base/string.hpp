#pragma once

#include "liborca/base/expected.hpp"

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace orca::strings {

[[nodiscard]] auto trim_left(std::string_view text) -> std::string_view;
[[nodiscard]] auto trim_right(std::string_view text) -> std::string_view;
[[nodiscard]] auto trim(std::string_view text) -> std::string_view;

[[nodiscard]] auto to_lower_ascii(std::string_view text) -> std::string;
[[nodiscard]] auto to_upper_ascii(std::string_view text) -> std::string;

[[nodiscard]] auto split(std::string_view text, char delimiter) -> std::vector<std::string_view>;

[[nodiscard]] auto parse_int64(std::string_view text) -> expected<std::int64_t>;
[[nodiscard]] auto parse_uint64(std::string_view text) -> expected<std::uint64_t>;
[[nodiscard]] auto parse_float64(std::string_view text) -> expected<double>;

[[nodiscard]] auto hex_encode(std::span<const std::byte> bytes) -> std::string;
[[nodiscard]] auto hex_decode(std::string_view text) -> expected<std::vector<std::byte>>;

}
