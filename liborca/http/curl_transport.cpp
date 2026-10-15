#include "liborca/http/curl_transport.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/base/string.hpp"

#include <array>
#include <cstddef>
#include <curl/curl.h>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace orca::http {

namespace {

void ensure_curl_global_init() {
    static std::once_flag flag;
    std::call_once(flag, [] { (void)curl_global_init(CURL_GLOBAL_DEFAULT); });
}

struct CurlSink {
    Response response;
    std::size_t response_bytes_max = response_bytes_max_default;
    std::size_t response_headers_bytes_max = response_headers_bytes_max_default;
    std::size_t response_headers_bytes = 0;
    bool body_exceeded = false;
    bool headers_exceeded = false;
};

auto write_callback(char* data, std::size_t size, std::size_t count, void* userdata)
    -> std::size_t {
    auto* const sink = static_cast<CurlSink*>(userdata);
    const std::size_t total = size * count;
    if (sink->body_exceeded) {
        return 0;
    }
    if (total > sink->response_bytes_max - sink->response.body.size()) {
        sink->body_exceeded = true;
        return 0;
    }
    sink->response.body.append(data, total);
    return total;
}

auto header_callback(char* data, std::size_t size, std::size_t count, void* userdata)
    -> std::size_t {
    auto* const sink = static_cast<CurlSink*>(userdata);
    const std::size_t total = size * count;
    if (sink->headers_exceeded) {
        return 0;
    }
    if (total > sink->response_headers_bytes_max - sink->response_headers_bytes) {
        sink->headers_exceeded = true;
        return 0;
    }
    sink->response_headers_bytes += total;
    const std::string_view line(data, total);
    const std::size_t colon = line.find(':');
    if (colon != std::string_view::npos) {
        Header header;
        header.name = std::string(strings::trim(line.substr(0, colon)));
        header.value = std::string(strings::trim(line.substr(colon + 1)));
        sink->response.headers.push_back(std::move(header));
    }
    return total;
}

[[nodiscard]] auto header_has_control_byte(std::string_view text) -> bool {
    for (const char value : text) {
        if (value == '\r' || value == '\n' || value == '\0') {
            return true;
        }
    }
    return false;
}

[[nodiscard]] auto headers_have_control_bytes(const std::vector<Header>& headers) -> bool {
    for (const Header& header : headers) {
        if (header_has_control_byte(header.name)) {
            return true;
        }
        if (header_has_control_byte(header.value)) {
            return true;
        }
    }
    return false;
}

[[nodiscard]] auto build_header_list(const std::vector<Header>& headers) -> curl_slist* {
    curl_slist* list = nullptr;
    for (const Header& header : headers) {
        const std::string line = header.name + ": " + header.value;
        curl_slist* const appended = curl_slist_append(list, line.c_str());
        if (appended == nullptr) {
            curl_slist_free_all(list);
            return nullptr;
        }
        list = appended;
    }
    return list;
}

void set_method_options(CURL* handle, const Request& request) {
    if (request.method == "POST") {
        curl_easy_setopt(handle, CURLOPT_POST, 1L);
        curl_easy_setopt(handle, CURLOPT_POSTFIELDS, request.body.data());
        curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, static_cast<long>(request.body.size()));
        return;
    }
    if (request.method == "GET") {
        return;
    }
    curl_easy_setopt(handle, CURLOPT_CUSTOMREQUEST, request.method.c_str());
    if (request.body.empty()) {
        return;
    }
    curl_easy_setopt(handle, CURLOPT_POSTFIELDS, request.body.data());
    curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, static_cast<long>(request.body.size()));
}

struct SlistDeleter {
    void operator()(curl_slist* list) const noexcept {
        curl_slist_free_all(list);
    }
};

}

CurlTransport::CurlTransport() = default;

CurlTransport::~CurlTransport() = default;

auto CurlTransport::perform(const Request& request) -> expected<Response> {
    ORCA_ASSERT(!request.url.empty());
    ensure_curl_global_init();

    if (headers_have_control_bytes(request.headers)) {
        return fail(ErrorCode::invalid_argument, "curl: header contains control bytes");
    }

    const std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> handle(curl_easy_init(),
                                                                     &curl_easy_cleanup);
    if (!handle) {
        return fail(ErrorCode::internal, "curl: cannot create handle");
    }
    ORCA_ASSERT(handle.get() != nullptr);

    CurlSink sink;
    sink.response_bytes_max = request.response_bytes_max;
    sink.response_headers_bytes_max = request.response_headers_bytes_max;
    std::array<char, CURL_ERROR_SIZE> error_buffer{};

    const std::unique_ptr<curl_slist, SlistDeleter> headers(build_header_list(request.headers));
    if (headers == nullptr && !request.headers.empty()) {
        return fail(ErrorCode::internal, "curl: cannot allocate header list");
    }

    curl_easy_setopt(handle.get(), CURLOPT_URL, request.url.c_str());
    curl_easy_setopt(handle.get(), CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(handle.get(), CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(handle.get(), CURLOPT_TIMEOUT_MS, static_cast<long>(request.timeout_ms));
    curl_easy_setopt(handle.get(), CURLOPT_CONNECTTIMEOUT_MS,
                     static_cast<long>(request.timeout_ms));
    curl_easy_setopt(handle.get(), CURLOPT_ERRORBUFFER, error_buffer.data());
    curl_easy_setopt(handle.get(), CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(handle.get(), CURLOPT_WRITEDATA, &sink);
    curl_easy_setopt(handle.get(), CURLOPT_HEADERFUNCTION, header_callback);
    curl_easy_setopt(handle.get(), CURLOPT_HEADERDATA, &sink);
    if (headers != nullptr) {
        curl_easy_setopt(handle.get(), CURLOPT_HTTPHEADER, headers.get());
    }

    set_method_options(handle.get(), request);

    const CURLcode result = curl_easy_perform(handle.get());
    if (sink.body_exceeded || sink.headers_exceeded) {
        return fail(ErrorCode::out_of_range, "curl: response exceeds limit");
    }
    if (result == CURLE_OPERATION_TIMEDOUT) {
        return fail(ErrorCode::timeout, "curl: request timed out");
    }
    if (result != CURLE_OK) {
        const char* const message =
            error_buffer[0] != '\0' ? error_buffer.data() : curl_easy_strerror(result);
        return fail(ErrorCode::network, message);
    }

    long status = 0;
    curl_easy_getinfo(handle.get(), CURLINFO_RESPONSE_CODE, &status);
    sink.response.status = static_cast<int>(status);
    return sink.response;
}

}
