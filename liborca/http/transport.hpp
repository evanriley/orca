#pragma once

#include "liborca/base/expected.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace orca::http {

inline constexpr std::size_t response_bytes_max_default = 16U * 1024U * 1024U;
inline constexpr std::size_t response_headers_bytes_max_default = 1U * 1024U * 1024U;

struct Header {
    std::string name;
    std::string value;
};

struct Request {
    std::string method = "GET";
    std::string url;
    std::vector<Header> headers;
    std::string body;
    std::int64_t timeout_ms = 30000;
    std::size_t response_bytes_max = response_bytes_max_default;
    std::size_t response_headers_bytes_max = response_headers_bytes_max_default;
};

struct Response {
    int status = 0;
    std::vector<Header> headers;
    std::string body;

    [[nodiscard]] auto header(std::string_view name) const -> std::string_view;
};

class Transport {
public:
    virtual ~Transport() = default;

    Transport(const Transport&) = delete;
    auto operator=(const Transport&) -> Transport& = delete;
    Transport(Transport&&) = delete;
    auto operator=(Transport&&) -> Transport& = delete;

    [[nodiscard]] virtual auto perform(const Request& request) -> expected<Response> = 0;

protected:
    Transport() = default;
};

}
