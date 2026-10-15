#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace orca {

enum class ErrorCode : std::uint32_t {
    none = 0,
    invalid_argument,
    out_of_range,
    overflow,
    underflow,
    division_by_zero,
    io,
    not_found,
    already_exists,
    parse,
    unsupported,
    network,
    timeout,
    too_many_redirects,
    insecure_transport,
    cancelled,
    internal,
    truncated_flac,
    flac_stream_errors,
    flac_md5_mismatch,
};

struct Error {
    ErrorCode code = ErrorCode::none;
    std::string context{};

    [[nodiscard]] auto ok() const noexcept -> bool {
        return code == ErrorCode::none;
    }
};

[[nodiscard]] auto to_string(ErrorCode code) -> std::string_view;

}
