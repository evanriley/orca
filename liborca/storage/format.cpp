#include "liborca/storage/format.hpp"

#include <algorithm>
#include <array>
#include <cstring>

namespace orca::storage {

namespace {

[[nodiscard]] auto equal_at(std::span<const std::byte> bytes, std::size_t offset,
                            std::string_view value) -> bool {
    return bytes.size() >= offset + value.size() &&
           std::memcmp(bytes.data() + offset, value.data(), value.size()) == 0;
}

[[nodiscard]] auto starts(std::span<const std::byte> bytes, std::string_view value) -> bool {
    return equal_at(bytes, 0, value);
}

[[nodiscard]] auto contains(std::span<const std::byte> bytes, std::string_view value) -> bool {
    if (value.empty() || bytes.size() < value.size()) {
        return false;
    }
    const auto* begin = reinterpret_cast<const char*>(bytes.data());
    const auto* end = begin + bytes.size();
    return std::search(begin, end, value.begin(), value.end()) != end;
}

[[nodiscard]] auto identify_container(std::span<const std::byte> bytes)
    -> std::optional<AudioFormat> {
    if (starts(bytes, "fLaC")) {
        return AudioFormat::flac;
    }
    if (starts(bytes, "wvpk")) {
        return AudioFormat::wavpack;
    }
    if (starts(bytes, "qoaf")) {
        return AudioFormat::qoa;
    }
    if (bytes.size() >= 2 && bytes[0] == std::byte{0xff} &&
        (std::to_integer<unsigned>(bytes[1]) & 0xf6U) == 0xf0U) {
        return AudioFormat::aac;
    }
    if (bytes.size() >= 2 && bytes[0] == std::byte{0xff} &&
        (std::to_integer<unsigned>(bytes[1]) & 0xe0U) == 0xe0U) {
        return AudioFormat::mp3;
    }
    if (bytes.size() >= 12 && starts(bytes, "RIFF") && equal_at(bytes, 8, "WAVE")) {
        return AudioFormat::wav;
    }
    if (bytes.size() >= 12 && starts(bytes, "FORM") &&
        (equal_at(bytes, 8, "AIFF") || equal_at(bytes, 8, "AIFC"))) {
        return AudioFormat::aiff;
    }
    if (bytes.size() >= 12 && equal_at(bytes, 4, "ftyp")) {
        return AudioFormat::mp4;
    }
    if (starts(bytes, "OggS")) {
        if (contains(bytes, "OpusHead")) {
            return AudioFormat::opus;
        }
        if (contains(bytes, "vorbis")) {
            return AudioFormat::vorbis;
        }
    }
    return std::nullopt;
}

}

auto id3v2_payload_offset(std::span<const std::byte> bytes) -> std::optional<std::uint64_t> {
    constexpr std::size_t header_len = 10;
    if (bytes.size() < header_len || !starts(bytes, "ID3")) {
        return std::nullopt;
    }
    if (bytes[3] == std::byte{0xff} || bytes[4] == std::byte{0xff}) {
        return std::nullopt;
    }
    std::uint64_t declared = 0;
    for (std::size_t index = 6; index < 10; ++index) {
        const auto byte = std::to_integer<unsigned>(bytes[index]);
        if ((byte & 0x80U) != 0U) {
            return std::nullopt;
        }
        declared = (declared << 7U) | byte;
    }
    const std::uint64_t footer_len = (std::to_integer<unsigned>(bytes[5]) & 0x10U) != 0U ? 10U : 0U;
    return header_len + declared + footer_len;
}

auto detect(const ReadableSource& source) -> expected<std::optional<Detection>> {
    std::array<std::byte, 64> header{};
    const auto count = source.read_at(0, header);
    if (!count) {
        return std::unexpected(count.error());
    }
    const auto prefix = std::span<const std::byte>(header.data(), *count);
    if (const auto format = identify_container(prefix)) {
        return std::optional<Detection>(Detection{.format = *format, .payload_offset = 0});
    }

    const auto payload_offset = id3v2_payload_offset(prefix);
    if (!payload_offset) {
        return std::optional<Detection>{};
    }

    std::array<std::byte, 64> payload{};
    const auto payload_count = source.read_at(*payload_offset, payload);
    if (!payload_count) {
        return std::unexpected(payload_count.error());
    }
    const auto payload_bytes = std::span<const std::byte>(payload.data(), *payload_count);
    if (const auto format = identify_container(payload_bytes)) {
        if (*format == AudioFormat::aac) {
            return std::optional<Detection>(Detection{.format = AudioFormat::aac});
        }
        if (*format != AudioFormat::mp3) {
            return std::optional<Detection>(
                Detection{.format = *format, .payload_offset = *payload_offset});
        }
    }
    return std::optional<Detection>(Detection{.format = AudioFormat::mp3});
}

auto sniff(const ReadableSource& source) -> expected<std::optional<AudioFormat>> {
    const auto detected = detect(source);
    if (!detected) {
        return std::unexpected(detected.error());
    }
    if (!*detected) {
        return std::optional<AudioFormat>{};
    }
    return std::optional<AudioFormat>((*detected)->format);
}

auto sniff_bytes(std::span<const std::byte> bytes) -> std::optional<AudioFormat> {
    if (const auto format = identify_container(bytes)) {
        return format;
    }
    const auto payload_offset = id3v2_payload_offset(bytes);
    if (!payload_offset) {
        return std::nullopt;
    }
    if (*payload_offset <= bytes.size()) {
        const auto suffix = bytes.subspan(static_cast<std::size_t>(*payload_offset));
        if (const auto format = identify_container(suffix)) {
            if (*format != AudioFormat::mp3) {
                return format;
            }
        }
    }
    return AudioFormat::mp3;
}

}
