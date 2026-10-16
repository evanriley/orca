#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace orca::metadata::id3v1 {

struct Tag {
    std::string_view title = {};
    std::string_view artist = {};
    std::string_view album = {};
    std::string_view year = {};
    std::string_view comment = {};
    std::optional<std::uint8_t> track_number = std::nullopt;
    std::uint8_t genre = 0;
};

[[nodiscard]] auto read(const storage::ReadableSource& source, std::array<std::byte, 128>& buffer)
    -> expected<std::optional<Tag>>;
[[nodiscard]] auto parse(const std::array<std::byte, 128>& bytes) -> std::optional<Tag>;
[[nodiscard]] auto encode(const Tag& tag) -> expected<std::array<std::byte, 128>>;

[[nodiscard]] auto latin1_to_utf8(std::span<const std::byte> bytes) -> std::string;
[[nodiscard]] auto genre_name(std::uint8_t code) -> std::optional<std::string_view>;

}
