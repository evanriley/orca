#include "liborca/http/client.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/base/string.hpp"

#include <string_view>
#include <vector>

namespace orca::http {

namespace {

[[nodiscard]] auto lower_ascii(char value) -> char {
    return (value >= 'A' && value <= 'Z') ? static_cast<char>(value - 'A' + 'a') : value;
}

[[nodiscard]] auto equals_ascii_case(std::string_view lhs, std::string_view rhs) -> bool {
    if (lhs.size() != rhs.size()) {
        return false;
    }
    for (std::size_t index = 0; index < lhs.size(); ++index) {
        if (lower_ascii(lhs[index]) != lower_ascii(rhs[index])) {
            return false;
        }
    }
    return true;
}

struct UrlParts {
    std::string scheme;
    std::string host;
    std::string port;
    std::string path;
};

[[nodiscard]] auto parse_url(std::string_view url) -> expected<UrlParts> {
    ORCA_ASSERT(!url.empty());
    const std::size_t scheme_end = url.find("://");
    if (scheme_end == std::string_view::npos) {
        return fail(ErrorCode::invalid_argument, "url: missing scheme");
    }

    UrlParts parts;
    parts.scheme = strings::to_lower_ascii(url.substr(0, scheme_end));
    if (parts.scheme != "http" && parts.scheme != "https") {
        return fail(ErrorCode::unsupported, "url: unsupported scheme");
    }

    const std::string_view rest = url.substr(scheme_end + 3);
    const std::size_t path_start = rest.find('/');
    const std::string_view authority = rest.substr(0, path_start);
    parts.path = path_start == std::string_view::npos ? std::string("/")
                                                      : std::string(rest.substr(path_start));
    if (authority.empty()) {
        return fail(ErrorCode::invalid_argument, "url: empty authority");
    }
    if (authority.find('@') != std::string_view::npos) {
        return fail(ErrorCode::invalid_argument, "url: userinfo is not allowed");
    }

    if (authority.front() == '[') {
        const std::size_t close = authority.find(']');
        if (close == std::string_view::npos) {
            return fail(ErrorCode::invalid_argument, "url: malformed ipv6 host");
        }
        parts.host = std::string(authority.substr(1, close - 1));
        if (close + 1 < authority.size()) {
            if (authority[close + 1] != ':') {
                return fail(ErrorCode::invalid_argument, "url: malformed authority");
            }
            parts.port = std::string(authority.substr(close + 2));
        }
    } else {
        const std::size_t colon = authority.rfind(':');
        if (colon == std::string_view::npos) {
            parts.host = std::string(authority);
        } else {
            parts.host = std::string(authority.substr(0, colon));
            parts.port = std::string(authority.substr(colon + 1));
        }
    }

    if (parts.host.empty()) {
        return fail(ErrorCode::invalid_argument, "url: empty host");
    }
    ORCA_ASSERT(parts.path.starts_with('/'));
    return parts;
}

[[nodiscard]] auto is_loopback_host(std::string_view host) -> bool {
    const std::string lower = strings::to_lower_ascii(host);
    if (lower == "localhost") {
        return true;
    }
    if (lower == "::1" || lower == "0:0:0:0:0:0:0:1") {
        return true;
    }
    return lower.starts_with("127.");
}

[[nodiscard]] auto is_sensitive_header(std::string_view name) -> bool {
    return equals_ascii_case(name, "authorization") ||
           equals_ascii_case(name, "proxy-authorization") || equals_ascii_case(name, "cookie");
}

void strip_sensitive_headers(std::vector<Header>& headers) {
    std::erase_if(headers, [](const Header& header) { return is_sensitive_header(header.name); });
}

void ensure_header(std::vector<Header>& headers, std::string_view name, const std::string& value) {
    for (const Header& header : headers) {
        if (equals_ascii_case(header.name, name)) {
            return;
        }
    }
    headers.push_back(Header{.name = std::string(name), .value = value});
}

[[nodiscard]] auto resolve_url(std::string_view base, std::string_view location) -> std::string {
    if (location.starts_with("http://") || location.starts_with("https://")) {
        return std::string(location);
    }

    const auto parts = parse_url(base);
    if (!parts) {
        return std::string(location);
    }

    std::string authority = parts->host;
    if (!parts->port.empty()) {
        authority += ':';
        authority += parts->port;
    }

    std::string result = parts->scheme + "://" + authority;
    if (location.starts_with('/')) {
        result += location;
    } else {
        const std::size_t slash = parts->path.rfind('/');
        result += slash == std::string::npos ? "/" : parts->path.substr(0, slash + 1);
        result += location;
    }
    return result;
}

[[nodiscard]] auto response_within_bounds(const Response& response, const Request& request)
    -> bool {
    if (response.body.size() > request.response_bytes_max) {
        return false;
    }
    std::size_t headers_bytes = 0;
    for (const Header& header : response.headers) {
        const std::size_t header_bytes = header.name.size() + header.value.size();
        if (header_bytes > request.response_headers_bytes_max - headers_bytes) {
            return false;
        }
        headers_bytes += header_bytes;
    }
    return true;
}

}

auto Response::header(std::string_view name) const -> std::string_view {
    for (const Header& header : headers) {
        if (equals_ascii_case(header.name, name)) {
            return header.value;
        }
    }
    return {};
}

auto default_user_agent() -> std::string {
    return "orca/" ORCA_VERSION_STRING;
}

Client::Client(Transport& transport, ClientOptions options)
    : transport_(&transport), options_(std::move(options)) {
    ORCA_ASSERT(options_.redirects_max <= redirects_max_limit);
}

auto Client::get(std::string url) -> expected<Response> {
    Request request;
    request.method = "GET";
    request.url = std::move(url);
    request.timeout_ms = options_.timeout_ms;
    return perform(std::move(request));
}

auto Client::perform(Request request) -> expected<Response> {
    ORCA_ASSERT(transport_ != nullptr);
    if (request.url.empty()) {
        return fail(ErrorCode::invalid_argument, "http: empty url");
    }
    if (request.timeout_ms <= 0) {
        request.timeout_ms = options_.timeout_ms;
    }
    request.response_bytes_max = options_.response_bytes_max;
    request.response_headers_bytes_max = options_.response_headers_bytes_max;
    ensure_header(request.headers, "User-Agent", options_.user_agent);

    std::size_t redirects = 0;
    while (true) {
        ORCA_ASSERT(redirects <= options_.redirects_max);
        const auto parts = parse_url(request.url);
        if (!parts) {
            return std::unexpected(parts.error());
        }
        if (parts->scheme == "http" && !is_loopback_host(parts->host)) {
            return fail(ErrorCode::insecure_transport,
                        "http: plain http is only allowed to loopback");
        }

        auto response = transport_->perform(request);
        if (!response) {
            return response;
        }
        if (!response_within_bounds(*response, request)) {
            return fail(ErrorCode::out_of_range, "http: response exceeds limit");
        }

        const int status = response->status;
        const bool is_redirect =
            status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
        if (!is_redirect) {
            return response;
        }

        const std::string_view location = response->header("location");
        if (location.empty()) {
            return response;
        }
        if (redirects >= options_.redirects_max) {
            return fail(ErrorCode::too_many_redirects, "http: redirect limit reached");
        }

        strip_sensitive_headers(request.headers);
        request.url = resolve_url(request.url, location);
        if (status == 303) {
            request.method = "GET";
            request.body.clear();
        }
        ++redirects;
    }
}

}
