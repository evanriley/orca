#include "liborca/base/error.hpp"

namespace orca {

auto to_string(ErrorCode code) -> std::string_view {
    switch (code) {
    case ErrorCode::none:
        return "none";
    case ErrorCode::invalid_argument:
        return "invalid_argument";
    case ErrorCode::out_of_range:
        return "out_of_range";
    case ErrorCode::overflow:
        return "overflow";
    case ErrorCode::underflow:
        return "underflow";
    case ErrorCode::division_by_zero:
        return "division_by_zero";
    case ErrorCode::io:
        return "io";
    case ErrorCode::not_found:
        return "not_found";
    case ErrorCode::already_exists:
        return "already_exists";
    case ErrorCode::parse:
        return "parse";
    case ErrorCode::unsupported:
        return "unsupported";
    case ErrorCode::network:
        return "network";
    case ErrorCode::timeout:
        return "timeout";
    case ErrorCode::too_many_redirects:
        return "too_many_redirects";
    case ErrorCode::insecure_transport:
        return "insecure_transport";
    case ErrorCode::cancelled:
        return "cancelled";
    case ErrorCode::internal:
        return "internal";
    case ErrorCode::truncated_flac:
        return "truncated_flac";
    case ErrorCode::flac_stream_errors:
        return "flac_stream_errors";
    case ErrorCode::flac_md5_mismatch:
        return "flac_md5_mismatch";
    case ErrorCode::invalid_id3v2_tag:
        return "invalid_id3v2_tag";
    case ErrorCode::truncated_id3v2_tag:
        return "truncated_id3v2_tag";
    case ErrorCode::invalid_id3v2_text:
        return "invalid_id3v2_text";
    case ErrorCode::id3v2_tag_too_large:
        return "id3v2_tag_too_large";
    case ErrorCode::invalid_flac_stream:
        return "invalid_flac_stream";
    case ErrorCode::truncated_flac_stream:
        return "truncated_flac_stream";
    case ErrorCode::invalid_vorbis_comment:
        return "invalid_vorbis_comment";
    case ErrorCode::invalid_ogg_stream:
        return "invalid_ogg_stream";
    case ErrorCode::truncated_ogg_stream:
        return "truncated_ogg_stream";
    case ErrorCode::ogg_comment_not_found:
        return "ogg_comment_not_found";
    case ErrorCode::ogg_comment_too_large:
        return "ogg_comment_too_large";
    }
    return "unknown";
}

}
