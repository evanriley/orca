#include "liborca/base/path.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/base/string.hpp"

#include <fstream>
#include <limits>
#include <system_error>

namespace orca::fs {

auto from_utf8(std::string_view text) -> path {
    const auto* const data = reinterpret_cast<const char8_t*>(text.data());
    return {std::u8string(data, data + text.size())};
}

auto to_utf8(const path& value) -> std::string {
    const std::u8string bytes = value.u8string();
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
}

auto extension_lower(const path& value) -> std::string {
    return strings::to_lower_ascii(value.extension().string());
}

auto exists(const path& value) -> bool {
    std::error_code error;
    return std::filesystem::exists(value, error);
}

auto is_regular_file(const path& value) -> bool {
    std::error_code error;
    return std::filesystem::is_regular_file(value, error);
}

auto is_directory(const path& value) -> bool {
    std::error_code error;
    return std::filesystem::is_directory(value, error);
}

auto read_file(const path& value, std::size_t bytes_max) -> expected<std::string> {
    std::error_code error;
    const std::uintmax_t size = std::filesystem::file_size(value, error);
    if (error) {
        return fail(ErrorCode::io, "read_file: cannot stat " + to_utf8(value));
    }
    if (size > bytes_max) {
        return fail(ErrorCode::out_of_range, "read_file: " + to_utf8(value) + " exceeds limit");
    }
    ORCA_ASSERT(size <= static_cast<std::uintmax_t>(std::numeric_limits<std::streamsize>::max()));

    std::ifstream input(value, std::ios::binary);
    if (!input) {
        return fail(ErrorCode::io, "read_file: cannot open " + to_utf8(value));
    }

    std::string data(static_cast<std::size_t>(size), '\0');
    input.read(data.data(), static_cast<std::streamsize>(data.size()));
    if (input.gcount() != static_cast<std::streamsize>(data.size())) {
        return fail(ErrorCode::io, "read_file: short read from " + to_utf8(value));
    }
    return data;
}

auto write_file(const path& value, std::string_view data) -> expected<void> {
    std::ofstream output(value, std::ios::binary | std::ios::trunc);
    if (!output) {
        return fail(ErrorCode::io, "write_file: cannot open " + to_utf8(value));
    }
    output.write(data.data(), static_cast<std::streamsize>(data.size()));
    output.flush();
    if (!output) {
        return fail(ErrorCode::io, "write_file: cannot write " + to_utf8(value));
    }
    return {};
}

}
