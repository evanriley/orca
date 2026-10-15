#include "liborca/base/string.hpp"

#include "liborca/base/logging.hpp"

#include <charconv>
#include <system_error>

namespace orca::strings {

namespace {

[[nodiscard]] auto is_ascii_space(char value) -> bool {
    return value == ' ' || value == '\t' || value == '\n' || value == '\r' || value == '\f' ||
           value == '\v';
}

[[nodiscard]] auto hex_value(char value) -> int {
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'a' && value <= 'f') {
        return value - 'a' + 10;
    }
    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }
    return -1;
}

template <typename T>
[[nodiscard]] auto parse_integer(std::string_view text, std::string_view name) -> expected<T> {
    ORCA_ASSERT(!name.empty());
    if (text.empty()) {
        return fail(ErrorCode::invalid_argument, std::string(name) + ": empty input");
    }
    T value{};
    const char* const begin = text.data();
    const char* const end = begin + text.size();
    const auto result = std::from_chars(begin, end, value);
    if (result.ec != std::errc{} || result.ptr != end) {
        return fail(ErrorCode::parse, std::string(name) + ": invalid input");
    }
    return value;
}

}

auto trim_left(std::string_view text) -> std::string_view {
    std::size_t index = 0;
    while (index < text.size() && is_ascii_space(text[index])) {
        ++index;
    }
    ORCA_ASSERT(index <= text.size());
    return text.substr(index);
}

auto trim_right(std::string_view text) -> std::string_view {
    std::size_t size = text.size();
    while (size > 0 && is_ascii_space(text[size - 1])) {
        --size;
    }
    ORCA_ASSERT(size <= text.size());
    return text.substr(0, size);
}

auto trim(std::string_view text) -> std::string_view {
    return trim_right(trim_left(text));
}

auto to_lower_ascii(std::string_view text) -> std::string {
    std::string out;
    out.reserve(text.size());
    for (const char value : text) {
        if (value >= 'A' && value <= 'Z') {
            out.push_back(static_cast<char>(value - 'A' + 'a'));
        } else {
            out.push_back(value);
        }
    }
    return out;
}

auto to_upper_ascii(std::string_view text) -> std::string {
    std::string out;
    out.reserve(text.size());
    for (const char value : text) {
        if (value >= 'a' && value <= 'z') {
            out.push_back(static_cast<char>(value - 'a' + 'A'));
        } else {
            out.push_back(value);
        }
    }
    return out;
}

auto split(std::string_view text, char delimiter) -> std::vector<std::string_view> {
    std::vector<std::string_view> parts;
    std::size_t start = 0;
    while (start <= text.size()) {
        const std::size_t position = text.find(delimiter, start);
        if (position == std::string_view::npos) {
            parts.push_back(text.substr(start));
            break;
        }
        parts.push_back(text.substr(start, position - start));
        start = position + 1;
    }
    ORCA_ASSERT(parts.size() <= text.size() + 1);
    return parts;
}

auto parse_int64(std::string_view text) -> expected<std::int64_t> {
    return parse_integer<std::int64_t>(text, "parse_int64");
}

auto parse_uint64(std::string_view text) -> expected<std::uint64_t> {
    return parse_integer<std::uint64_t>(text, "parse_uint64");
}

auto parse_float64(std::string_view text) -> expected<double> {
    if (text.empty()) {
        return fail(ErrorCode::invalid_argument, "parse_float64: empty input");
    }
    double value = 0.0;
    const char* const begin = text.data();
    const char* const end = begin + text.size();
    const auto result = std::from_chars(begin, end, value);
    if (result.ec != std::errc{} || result.ptr != end) {
        return fail(ErrorCode::parse, "parse_float64: invalid input");
    }
    return value;
}

auto hex_encode(std::span<const std::byte> bytes) -> std::string {
    static constexpr std::string_view digits = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (const std::byte byte : bytes) {
        const auto value = std::to_integer<unsigned>(byte);
        out.push_back(digits[(value >> 4U) & 0x0FU]);
        out.push_back(digits[value & 0x0FU]);
    }
    return out;
}

auto hex_decode(std::string_view text) -> expected<std::vector<std::byte>> {
    if (text.size() % 2 != 0) {
        return fail(ErrorCode::invalid_argument, "hex_decode: odd length");
    }
    std::vector<std::byte> out;
    out.reserve(text.size() / 2);
    for (std::size_t index = 0; index < text.size(); index += 2) {
        const int high = hex_value(text[index]);
        const int low = hex_value(text[index + 1]);
        if (high < 0 || low < 0) {
            return fail(ErrorCode::invalid_argument, "hex_decode: invalid digit");
        }
        out.push_back(static_cast<std::byte>((high << 4) | low));
    }
    return out;
}

}
