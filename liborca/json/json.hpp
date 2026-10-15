#pragma once

#include "liborca/base/expected.hpp"

#include <cstddef>
#include <string>
#include <string_view>

struct yyjson_doc;

namespace orca::json {

inline constexpr std::size_t input_bytes_max = 16U * 1024U * 1024U;

class Document {
public:
    Document() noexcept = default;
    ~Document();

    Document(Document&& other) noexcept;
    auto operator=(Document&& other) noexcept -> Document&;

    Document(const Document&) = delete;
    auto operator=(const Document&) -> Document& = delete;

    [[nodiscard]] static auto parse(std::string_view text, std::size_t bytes_max = input_bytes_max)
        -> expected<Document>;

    [[nodiscard]] auto valid() const noexcept -> bool;
    [[nodiscard]] auto dump(bool pretty = false) const -> expected<std::string>;

private:
    explicit Document(yyjson_doc* doc) noexcept;

    yyjson_doc* doc_ = nullptr;
};

}
