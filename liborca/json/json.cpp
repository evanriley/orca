#include "liborca/json/json.hpp"

#include "liborca/base/logging.hpp"

#include <cstdlib>
#include <yyjson.h>

namespace orca::json {

Document::Document(yyjson_doc* doc) noexcept : doc_(doc) {}

Document::~Document() {
    if (doc_ != nullptr) {
        yyjson_doc_free(doc_);
    }
}

Document::Document(Document&& other) noexcept : doc_(other.doc_) {
    other.doc_ = nullptr;
}

auto Document::operator=(Document&& other) noexcept -> Document& {
    if (this != &other) {
        if (doc_ != nullptr) {
            yyjson_doc_free(doc_);
        }
        doc_ = other.doc_;
        other.doc_ = nullptr;
    }
    return *this;
}

auto Document::valid() const noexcept -> bool {
    return doc_ != nullptr;
}

auto Document::parse(std::string_view text, std::size_t bytes_max) -> expected<Document> {
    if (text.size() > bytes_max) {
        return fail(ErrorCode::out_of_range, "json input exceeds limit");
    }

    yyjson_read_err error{};
    yyjson_doc* const doc =
        yyjson_read_opts(const_cast<char*>(text.data()), text.size(), 0, nullptr, &error);
    if (doc == nullptr) {
        const char* const message = error.msg != nullptr ? error.msg : "invalid json";
        return fail(ErrorCode::parse, message);
    }
    ORCA_ASSERT(doc != nullptr);
    return Document(doc);
}

auto Document::dump(bool pretty) const -> expected<std::string> {
    if (doc_ == nullptr) {
        return fail(ErrorCode::invalid_argument, "json document is empty");
    }
    ORCA_ASSERT(doc_ != nullptr);

    const yyjson_write_flag flags =
        pretty ? YYJSON_WRITE_PRETTY : static_cast<yyjson_write_flag>(0);
    std::size_t length = 0;
    char* const text = yyjson_write(doc_, flags, &length);
    if (text == nullptr) {
        return fail(ErrorCode::internal, "json write failed");
    }

    std::string out(text, length);
    std::free(text);
    return out;
}

}
