#include "liborca/base/time.hpp"

#include <array>
#include <ctime>

namespace orca::time {

namespace {

[[nodiscard]] auto now_millis() -> std::int64_t {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
}

}

auto now_unix_seconds() -> std::int64_t {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::seconds>(now).count();
}

auto now_unix_millis() -> std::int64_t {
    return now_millis();
}

auto to_unix(std::chrono::system_clock::time_point point) -> std::int64_t {
    const auto duration = point.time_since_epoch();
    return std::chrono::duration_cast<std::chrono::seconds>(duration).count();
}

auto from_unix(std::int64_t seconds) -> std::chrono::system_clock::time_point {
    return std::chrono::system_clock::time_point(std::chrono::seconds(seconds));
}

auto format_rfc3339(std::int64_t unix_seconds) -> expected<std::string> {
    const auto value = static_cast<std::time_t>(unix_seconds);
    std::tm parts{};
#ifdef _WIN32
    if (gmtime_s(&parts, &value) != 0) {
        return fail(ErrorCode::out_of_range, "format_rfc3339: time out of range");
    }
#else
    if (gmtime_r(&value, &parts) == nullptr) {
        return fail(ErrorCode::out_of_range, "format_rfc3339: time out of range");
    }
#endif
    std::array<char, 32> buffer{};
    const std::size_t written =
        std::strftime(buffer.data(), buffer.size(), "%Y-%m-%dT%H:%M:%SZ", &parts);
    if (written == 0) {
        return fail(ErrorCode::internal, "format_rfc3339: formatting failed");
    }
    return std::string(buffer.data());
}

}
