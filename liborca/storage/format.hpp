#pragma once

#include "liborca/storage/source.hpp"

#include <cstdint>
#include <optional>
#include <span>

namespace orca::storage {

enum class AudioFormat : std::uint8_t {
    wav,
    aiff,
    flac,
    mp3,
    mp4,
    opus,
    vorbis,
    wavpack,
    qoa,
    aac,
};

struct Detection {
    AudioFormat format;
    std::uint64_t payload_offset = 0;
};

[[nodiscard]] auto detect(const ReadableSource& source) -> expected<std::optional<Detection>>;

[[nodiscard]] auto sniff(const ReadableSource& source) -> expected<std::optional<AudioFormat>>;

[[nodiscard]] auto sniff_bytes(std::span<const std::byte> bytes) -> std::optional<AudioFormat>;

[[nodiscard]] auto id3v2_payload_offset(std::span<const std::byte> bytes)
    -> std::optional<std::uint64_t>;

}
