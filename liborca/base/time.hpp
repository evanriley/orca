#pragma once

#include "liborca/base/expected.hpp"

#include <chrono>
#include <cstdint>
#include <string>

namespace orca::time {

[[nodiscard]] auto now_unix_seconds() -> std::int64_t;
[[nodiscard]] auto now_unix_millis() -> std::int64_t;

[[nodiscard]] auto to_unix(std::chrono::system_clock::time_point point) -> std::int64_t;
[[nodiscard]] auto from_unix(std::int64_t seconds) -> std::chrono::system_clock::time_point;

[[nodiscard]] auto format_rfc3339(std::int64_t unix_seconds) -> expected<std::string>;

}
