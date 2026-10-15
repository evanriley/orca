#include "liborca/base/string.hpp"
#include "liborca/http/client.hpp"

#include <cstddef>
#include <doctest/doctest.h>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

class MockTransport final : public orca::http::Transport {
public:
    struct Reply {
        int status = 0;
        std::vector<orca::http::Header> headers;
        std::string body;
    };

    std::vector<orca::http::Request> requests;
    std::vector<Reply> replies;

    [[nodiscard]] auto perform(const orca::http::Request& request)
        -> orca::expected<orca::http::Response> override {
        requests.push_back(request);
        if (reply_index_ >= replies.size()) {
            return orca::fail(orca::ErrorCode::internal, "mock: no reply queued");
        }
        const Reply& reply = replies[reply_index_];
        ++reply_index_;
        orca::http::Response response;
        response.status = reply.status;
        response.headers = reply.headers;
        response.body = reply.body;
        return response;
    }

private:
    std::size_t reply_index_ = 0;
};

auto request_header(const orca::http::Request& request, std::string_view name) -> std::string_view {
    for (const orca::http::Header& header : request.headers) {
        if (orca::strings::to_lower_ascii(header.name) == orca::strings::to_lower_ascii(name)) {
            return header.value;
        }
    }
    return {};
}

}

TEST_CASE("http client adds a user agent and applies the timeout") {
    MockTransport transport;
    transport.replies.push_back({200, {}, "ok"});
    orca::http::Client client(transport, orca::http::ClientOptions{.user_agent = "orca-test/1",
                                                                   .redirects_max = 3,
                                                                   .timeout_ms = 1234});

    const auto response = client.get("https://example.com/");
    REQUIRE(response.has_value());
    CHECK(response->status == 200);
    REQUIRE(transport.requests.size() == 1);
    CHECK(transport.requests[0].timeout_ms == 1234);
    CHECK(request_header(transport.requests[0], "user-agent") == "orca-test/1");
}

TEST_CASE("http client allows plain http only to loopback") {
    MockTransport transport;
    transport.replies.push_back({200, {}, "ok"});
    orca::http::Client client(transport);

    const auto loopback = client.get("http://127.0.0.1:8080/status");
    REQUIRE(loopback.has_value());
    CHECK(transport.requests.size() == 1);

    const auto external = client.get("http://example.com/");
    REQUIRE_FALSE(external.has_value());
    CHECK(external.error().code == orca::ErrorCode::insecure_transport);
    CHECK(transport.requests.size() == 1);
}

TEST_CASE("http client follows redirects and strips credentials") {
    MockTransport transport;
    transport.replies.push_back({302, {{"Location", "https://other.example/target"}}, ""});
    transport.replies.push_back({200, {}, "ok"});
    orca::http::Client client(transport);

    orca::http::Request request;
    request.url = "https://example.com/start";
    request.headers.push_back({"Authorization", "Bearer secret"});
    request.headers.push_back({"Cookie", "session=1"});

    const auto response = client.perform(std::move(request));
    REQUIRE(response.has_value());
    CHECK(response->status == 200);
    REQUIRE(transport.requests.size() == 2);
    CHECK(transport.requests[0].url == "https://example.com/start");
    CHECK(transport.requests[1].url == "https://other.example/target");
    CHECK(request_header(transport.requests[1], "authorization").empty());
    CHECK(request_header(transport.requests[1], "cookie").empty());
}

TEST_CASE("http client bounds redirects") {
    MockTransport transport;
    for (int index = 0; index < 10; ++index) {
        transport.replies.push_back({302, {{"Location", "https://example.com/next"}}, ""});
    }
    orca::http::Client client(transport, orca::http::ClientOptions{.user_agent = "orca-test/1",
                                                                   .redirects_max = 2,
                                                                   .timeout_ms = 1000});

    const auto response = client.get("https://example.com/");
    REQUIRE_FALSE(response.has_value());
    CHECK(response.error().code == orca::ErrorCode::too_many_redirects);
}

TEST_CASE("http client refuses a downgrade redirect to non-loopback") {
    MockTransport transport;
    transport.replies.push_back({302, {{"Location", "http://example.com/"}}, ""});
    orca::http::Client client(transport);

    const auto response = client.get("https://example.com/");
    REQUIRE_FALSE(response.has_value());
    CHECK(response.error().code == orca::ErrorCode::insecure_transport);
}

TEST_CASE("http client rejects unsupported schemes and userinfo") {
    MockTransport transport;
    orca::http::Client client(transport);

    const auto scheme = client.get("ftp://example.com/file");
    REQUIRE_FALSE(scheme.has_value());
    CHECK(scheme.error().code == orca::ErrorCode::unsupported);

    const auto userinfo = client.get("https://user:pass@example.com/");
    REQUIRE_FALSE(userinfo.has_value());
    CHECK(userinfo.error().code == orca::ErrorCode::invalid_argument);
}

TEST_CASE("http client bounds the response body") {
    MockTransport transport;
    transport.replies.push_back({200, {}, std::string(11, 'x')});
    orca::http::Client client(transport,
                              orca::http::ClientOptions{.user_agent = "orca-test/1",
                                                        .redirects_max = 3,
                                                        .timeout_ms = 1000,
                                                        .response_bytes_max = 10,
                                                        .response_headers_bytes_max = 1024});

    const auto response = client.get("https://example.com/");
    REQUIRE_FALSE(response.has_value());
    CHECK(response.error().code == orca::ErrorCode::out_of_range);
}

TEST_CASE("http client accepts a response body exactly at the cap") {
    MockTransport transport;
    transport.replies.push_back({200, {}, std::string(10, 'x')});
    orca::http::Client client(transport,
                              orca::http::ClientOptions{.user_agent = "orca-test/1",
                                                        .redirects_max = 3,
                                                        .timeout_ms = 1000,
                                                        .response_bytes_max = 10,
                                                        .response_headers_bytes_max = 1024});

    const auto response = client.get("https://example.com/");
    REQUIRE(response.has_value());
    CHECK(response->body.size() == 10);
}

TEST_CASE("http client bounds the response headers") {
    MockTransport transport;
    transport.replies.push_back({200, {{"X-Long", std::string(20, 'h')}}, "ok"});
    orca::http::Client client(transport,
                              orca::http::ClientOptions{.user_agent = "orca-test/1",
                                                        .redirects_max = 3,
                                                        .timeout_ms = 1000,
                                                        .response_bytes_max = 1024,
                                                        .response_headers_bytes_max = 10});

    const auto response = client.get("https://example.com/");
    REQUIRE_FALSE(response.has_value());
    CHECK(response.error().code == orca::ErrorCode::out_of_range);
}
