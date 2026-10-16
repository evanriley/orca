#include "liborca/metadata/image_header.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <span>

namespace {

template <std::size_t Size>
auto bytes_of(const char (&text)[Size]) -> std::span<const std::byte> {
    return std::span<const std::byte>(reinterpret_cast<const std::byte*>(text), Size - 1);
}

}

TEST_CASE("a PNG's size comes from its IHDR chunk") {
    const auto bytes = bytes_of(
        "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x01\x2c\x00\x00\x00\xc8\x08\x02\x00\x00"
        "\x00");
    const auto size = orca::metadata::image_header::dimensions(bytes);
    REQUIRE(size.has_value());
    CHECK(size->width == 300);
    CHECK(size->height == 200);
}

TEST_CASE("a JPEG's size comes from the frame header after any other segments") {
    const auto bytes = bytes_of(
        "\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xc2\x00\x11"
        "\x08\x04\xb0\x03\x20\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01");
    const auto size = orca::metadata::image_header::dimensions(bytes);
    REQUIRE(size.has_value());
    CHECK(size->width == 800);
    CHECK(size->height == 1200);
}

TEST_CASE("a JPEG that reaches its scan before a frame header has no size") {
    const auto bytes = bytes_of("\xff\xd8\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00");
    CHECK_FALSE(orca::metadata::image_header::dimensions(bytes).has_value());
}

TEST_CASE("GIF, WebP and BMP sizes come from their headers") {
    using orca::metadata::image_header::dimensions;
    const auto gif = bytes_of("GIF89a\x80\x02\xe0\x01\x00\x00");
    const auto gif_size = dimensions(gif);
    REQUIRE(gif_size.has_value());
    CHECK(gif_size->width == 640);
    CHECK(gif_size->height == 480);

    const auto lossy =
        bytes_of("RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\xf4\x01"
                 "\xf4\x01");
    const auto lossy_size = dimensions(lossy);
    REQUIRE(lossy_size.has_value());
    CHECK(lossy_size->width == 500);

    const auto extended =
        bytes_of("RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\xaf\x04\x00\xaf"
                 "\x04\x00");
    const auto extended_size = dimensions(extended);
    REQUIRE(extended_size.has_value());
    CHECK(extended_size->width == 1200);

    const auto bitmap = bytes_of(
        "BM\x00\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x40\x00\x00\x00\xc0"
        "\xff\xff\xff");
    const auto bitmap_size = dimensions(bitmap);
    REQUIRE(bitmap_size.has_value());
    CHECK(bitmap_size->width == 64);
    CHECK(bitmap_size->height == 64);
}

TEST_CASE("a lossless WebP stores each side less one in fourteen bits") {
    std::array<std::byte, 30> bytes{};
    std::memcpy(bytes.data(), "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00", 20);
    bytes[20] = std::byte{0x2f};
    const std::uint32_t width = 299;
    const std::uint32_t height = 149;
    const std::uint32_t bits = width | (height << 14U);
    for (std::size_t index = 0; index < 4; ++index) {
        bytes[21 + index] = static_cast<std::byte>((bits >> (index * 8U)) & 0xffU);
    }
    const auto size = orca::metadata::image_header::dimensions(bytes);
    REQUIRE(size.has_value());
    CHECK(size->width == 300);
    CHECK(size->height == 150);
}

TEST_CASE("a hash identifies the bytes and is never the unreadable marker") {
    using orca::metadata::image_header::hash;
    using orca::metadata::image_header::measure;
    using orca::metadata::image_header::unreadable_hash;
    CHECK(hash(bytes_of("cover")) == hash(bytes_of("cover")));
    CHECK(hash(bytes_of("cover")) != hash(bytes_of("cover.")));
    CHECK(hash(bytes_of("")) != unreadable_hash);
    const auto measured = measure(bytes_of("not an image"));
    CHECK_FALSE(measured.width.has_value());
    CHECK_FALSE(measured.height.has_value());
    CHECK(measured.hash == hash(bytes_of("not an image")));
}

TEST_CASE("measuring an image in place matches measuring its bytes") {
    const auto jpeg = bytes_of(
        "\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xc0\x00\x11"
        "\x08\x01\x2c\x01\x2c\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01\xff\xd9");
    std::vector<std::byte> container;
    const std::array<char, 8> padding{'p', 'a', 'd', 'd', 'i', 'n', 'g', '!'};
    for (const char value : padding) {
        container.push_back(static_cast<std::byte>(value));
    }
    container.insert(container.end(), jpeg.begin(), jpeg.end());
    orca::storage::MemorySource source(container);
    const auto in_place = orca::metadata::image_header::measure_at(source, 8, jpeg.size());
    REQUIRE(in_place.has_value());
    CHECK(orca::metadata::image_header::measure(jpeg).hash == in_place->hash);
    CHECK(orca::metadata::image_header::measure(jpeg).width == in_place->width);
    CHECK(in_place->width == std::optional<std::uint32_t>(300));
    CHECK(in_place->height == std::optional<std::uint32_t>(300));
}
