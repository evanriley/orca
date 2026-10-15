#pragma once

#include "liborca/http/transport.hpp"

namespace orca::http {

class CurlTransport final : public Transport {
public:
    CurlTransport();
    ~CurlTransport() override;

    CurlTransport(const CurlTransport&) = delete;
    auto operator=(const CurlTransport&) -> CurlTransport& = delete;
    CurlTransport(CurlTransport&&) = delete;
    auto operator=(CurlTransport&&) -> CurlTransport& = delete;

    [[nodiscard]] auto perform(const Request& request) -> expected<Response> override;
};

}
