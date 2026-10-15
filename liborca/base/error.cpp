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
    }
    return "unknown";
}

}
