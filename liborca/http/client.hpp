#pragma once

#include "liborca/http/transport.hpp"

#include <cstddef>
#include <cstdint>
#include <string>

namespace orca::http {

[[nodiscard]] auto default_user_agent() -> std::string;

inline constexpr std::size_t redirects_max_limit = 32;

struct ClientOptions {
    std::string user_agent = default_user_agent();
    std::size_t redirects_max = 5;
    std::int64_t timeout_ms = 30000;
    std::size_t response_bytes_max = response_bytes_max_default;
    std::size_t response_headers_bytes_max = response_headers_bytes_max_default;
};

class Client {
public:
    explicit Client(Transport& transport, ClientOptions options = {});

    [[nodiscard]] auto get(std::string url) -> expected<Response>;
    [[nodiscard]] auto perform(Request request) -> expected<Response>;

private:
    Transport* transport_;
    ClientOptions options_;
};

}
