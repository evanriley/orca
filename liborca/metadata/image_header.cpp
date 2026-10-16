#include "liborca/metadata/image_header.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/crypto/blake3.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <functional>
#include <string_view>

namespace orca::metadata::image_header {

namespace {

constexpr std::size_t max_jpeg_segments = 256;
constexpr std::size_t window_bytes = 16U << 10;

using Reader = std::function<expected<std::size_t>(std::uint64_t, std::span<std::byte>)>;

[[nodiscard]] auto finish(const crypto::digest256& digest) -> std::int64_t {
    std::int64_t value = 0;
    for (std::size_t index = 0; index < 8; ++index) {
        value |= static_cast<std::int64_t>(digest[index]) << (index * 8U);
    }
    return value == unreadable_hash ? 1 : value;
}

[[nodiscard]] auto little16(std::span<const std::byte> bytes, std::size_t offset) -> std::uint32_t {
    return static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[offset])) |
           (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[offset + 1])) << 8U);
}

[[nodiscard]] auto big16(std::span<const std::byte> bytes, std::size_t offset) -> std::uint32_t {
    return (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[offset])) << 8U) |
           static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[offset + 1]));
}

[[nodiscard]] auto big32(std::span<const std::byte> bytes, std::size_t offset) -> std::uint32_t {
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value = (value << 8U) | std::to_integer<std::uint8_t>(bytes[offset + index]);
    }
    return value;
}

[[nodiscard]] auto little32(std::span<const std::byte> bytes, std::size_t offset) -> std::uint32_t {
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value |= static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[offset + index]))
                 << (index * 8U);
    }
    return value;
}

[[nodiscard]] auto little24(std::span<const std::byte> bytes, std::size_t offset) -> std::uint32_t {
    return static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[offset])) |
           (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[offset + 1])) << 8U) |
           (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[offset + 2])) << 16U);
}

[[nodiscard]] auto starts_with(std::span<const std::byte> bytes, std::string_view prefix) -> bool {
    return bytes.size() >= prefix.size() &&
           std::memcmp(bytes.data(), prefix.data(), prefix.size()) == 0;
}

[[nodiscard]] auto png(std::span<const std::byte> bytes) -> std::optional<Dimensions> {
    if (bytes.size() < 24 || !starts_with(bytes, "\x89PNG\r\n\x1a\n")) {
        return std::nullopt;
    }
    if (std::memcmp(bytes.data() + 12, "IHDR", 4) != 0) {
        return std::nullopt;
    }
    return Dimensions{.width = big32(bytes, 16), .height = big32(bytes, 20)};
}

[[nodiscard]] auto gif(std::span<const std::byte> bytes) -> std::optional<Dimensions> {
    if (bytes.size() < 10 || (!starts_with(bytes, "GIF87a") && !starts_with(bytes, "GIF89a"))) {
        return std::nullopt;
    }
    return Dimensions{.width = little16(bytes, 6), .height = little16(bytes, 8)};
}

[[nodiscard]] auto webp(std::span<const std::byte> bytes) -> std::optional<Dimensions> {
    if (bytes.size() < 30 || !starts_with(bytes, "RIFF") ||
        std::memcmp(bytes.data() + 8, "WEBP", 4) != 0) {
        return std::nullopt;
    }
    if (std::memcmp(bytes.data() + 12, "VP8 ", 4) == 0) {
        if (std::memcmp(bytes.data() + 23, "\x9d\x01\x2a", 3) != 0) {
            return std::nullopt;
        }
        return Dimensions{.width = little16(bytes, 26) & 0x3fffU,
                          .height = little16(bytes, 28) & 0x3fffU};
    }
    if (std::memcmp(bytes.data() + 12, "VP8L", 4) == 0) {
        if (std::to_integer<std::uint8_t>(bytes[20]) != 0x2fU) {
            return std::nullopt;
        }
        const std::uint32_t bits = little32(bytes, 21);
        return Dimensions{.width = (bits & 0x3fffU) + 1U, .height = ((bits >> 14U) & 0x3fffU) + 1U};
    }
    if (std::memcmp(bytes.data() + 12, "VP8X", 4) == 0) {
        return Dimensions{.width = little24(bytes, 24) + 1U, .height = little24(bytes, 27) + 1U};
    }
    return std::nullopt;
}

[[nodiscard]] auto bmp(std::span<const std::byte> bytes) -> std::optional<Dimensions> {
    if (bytes.size() < 26 || !starts_with(bytes, "BM")) {
        return std::nullopt;
    }
    const std::uint32_t header_size = little32(bytes, 14);
    if (header_size == 12) {
        return Dimensions{.width = little16(bytes, 18), .height = little16(bytes, 20)};
    }
    const auto width = static_cast<std::int32_t>(little32(bytes, 18));
    const auto height = static_cast<std::int32_t>(little32(bytes, 22));
    const auto abs = [](std::int32_t value) -> std::uint32_t {
        return value < 0 ? static_cast<std::uint32_t>(-static_cast<std::int64_t>(value))
                         : static_cast<std::uint32_t>(value);
    };
    return Dimensions{.width = abs(width), .height = abs(height)};
}

[[nodiscard]] auto slice_reader(std::span<const std::byte> bytes) -> Reader {
    return [bytes](std::uint64_t offset, std::span<std::byte> buffer) -> expected<std::size_t> {
        if (offset >= bytes.size()) {
            return std::size_t{0};
        }
        const auto available = bytes.subspan(static_cast<std::size_t>(offset));
        const std::size_t count = std::min(available.size(), buffer.size());
        std::memcpy(buffer.data(), available.data(), count);
        return count;
    };
}

[[nodiscard]] auto source_reader(const storage::ReadableSource& source, std::uint64_t offset,
                                 std::uint64_t length) -> Reader {
    return [&source, offset, length](std::uint64_t position,
                                     std::span<std::byte> buffer) -> expected<std::size_t> {
        if (position >= length) {
            return std::size_t{0};
        }
        const std::size_t count =
            static_cast<std::size_t>(std::min<std::uint64_t>(buffer.size(), length - position));
        return source.read_at(offset + position, buffer.subspan(0, count));
    };
}

[[nodiscard]] auto jpeg(const Reader& reader, std::uint64_t length)
    -> expected<std::optional<Dimensions>> {
    std::array<std::byte, 2> marker{};
    const auto marker_read = reader(0, marker);
    if (!marker_read || *marker_read != 2 || marker[0] != std::byte{0xff} ||
        marker[1] != std::byte{0xd8}) {
        return std::optional<Dimensions>{};
    }
    std::uint64_t offset = 2;
    for (std::size_t segments = 0; offset + 4 <= length && segments < max_jpeg_segments;
         ++segments) {
        std::array<std::byte, 9> segment{};
        const auto got = reader(offset, segment);
        if (!got || *got < 2 || segment[0] != std::byte{0xff}) {
            return std::optional<Dimensions>{};
        }
        const auto marker_value = std::to_integer<std::uint8_t>(segment[1]);
        if (marker_value == 0xffU) {
            ++offset;
            continue;
        }
        if (marker_value == 0x01U || (marker_value >= 0xd0U && marker_value <= 0xd8U)) {
            offset += 2;
            continue;
        }
        if (marker_value == 0xd9U || marker_value == 0xdaU || *got < 4) {
            return std::optional<Dimensions>{};
        }
        const std::uint32_t segment_length = big16(segment, 2);
        if (segment_length < 2) {
            return std::optional<Dimensions>{};
        }
        const bool start_of_frame = marker_value >= 0xc0U && marker_value <= 0xcfU &&
                                    marker_value != 0xc4U && marker_value != 0xc8U &&
                                    marker_value != 0xccU;
        if (start_of_frame) {
            if (*got < 9) {
                return std::optional<Dimensions>{};
            }
            return std::optional<Dimensions>(
                Dimensions{.width = big16(segment, 7), .height = big16(segment, 5)});
        }
        offset += 2 + segment_length;
    }
    return std::optional<Dimensions>{};
}

[[nodiscard]] auto dimensions_from(const Reader& reader, std::uint64_t length)
    -> expected<std::optional<Dimensions>> {
    std::array<std::byte, 30> head{};
    const auto read = reader(0, head);
    if (!read) {
        return std::unexpected(read.error());
    }
    const auto bytes = std::span<const std::byte>(head.data(), *read);
    ORCA_ASSERT(*read <= head.size());
    std::optional<Dimensions> size = png(bytes);
    if (!size) {
        size = gif(bytes);
    }
    if (!size) {
        size = webp(bytes);
    }
    if (!size) {
        size = bmp(bytes);
    }
    if (!size) {
        auto jpeg_size = jpeg(reader, length);
        if (!jpeg_size) {
            return std::unexpected(jpeg_size.error());
        }
        size = *jpeg_size;
    }
    if (!size || size->width == 0 || size->height == 0) {
        return std::optional<Dimensions>{};
    }
    return size;
}

}

auto hash(std::span<const std::byte> bytes) -> std::int64_t {
    crypto::Blake3 hasher;
    hasher.update(bytes);
    return finish(hasher.finalize());
}

auto measure(std::span<const std::byte> bytes) -> Measurement {
    const auto size = dimensions(bytes);
    return Measurement{.width = size ? std::optional<std::uint32_t>(size->width) : std::nullopt,
                       .height = size ? std::optional<std::uint32_t>(size->height) : std::nullopt,
                       .hash = hash(bytes)};
}

auto measure_at(const storage::ReadableSource& source, std::uint64_t offset, std::uint64_t length)
    -> expected<Measurement> {
    const auto reader = source_reader(source, offset, length);
    const auto size = dimensions_from(reader, length);
    if (!size) {
        return std::unexpected(size.error());
    }

    crypto::Blake3 hasher;
    std::array<std::byte, window_bytes> buffer{};
    std::uint64_t position = 0;
    while (position < length) {
        ORCA_ASSERT(position < length);
        const auto want =
            static_cast<std::size_t>(std::min<std::uint64_t>(buffer.size(), length - position));
        const auto got =
            source.read_at(offset + position, std::span<std::byte>(buffer.data(), want));
        if (!got || *got == 0) {
            return fail(ErrorCode::parse, "image_header: truncated image");
        }
        hasher.update(std::span<const std::byte>(buffer.data(), *got));
        position += *got;
    }
    return Measurement{.width = *size ? std::optional<std::uint32_t>((*size)->width) : std::nullopt,
                       .height =
                           *size ? std::optional<std::uint32_t>((*size)->height) : std::nullopt,
                       .hash = finish(hasher.finalize())};
}

auto dimensions(std::span<const std::byte> bytes) -> std::optional<Dimensions> {
    const auto reader = slice_reader(bytes);
    const auto size = dimensions_from(reader, bytes.size());
    if (!size) {
        return std::nullopt;
    }
    return *size;
}

}
