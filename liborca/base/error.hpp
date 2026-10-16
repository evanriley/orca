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
    invalid_id3v2_tag,
    truncated_id3v2_tag,
    invalid_id3v2_text,
    id3v2_tag_too_large,
    invalid_flac_stream,
    truncated_flac_stream,
    invalid_vorbis_comment,
    invalid_ogg_stream,
    truncated_ogg_stream,
    ogg_comment_not_found,
    ogg_comment_too_large,
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
