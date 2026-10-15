#include "liborca/codec/adts.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/storage/format.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <vector>

namespace orca::codec {

namespace {

constexpr std::uint32_t frame_frames = 1024;
constexpr std::size_t window_bytes = std::size_t{64} * 1024;

struct AdtsLayout {
    std::uint8_t profile = 0;
    std::uint8_t rate_index = 0;
    std::uint8_t channels = 0;

    [[nodiscard]] auto operator==(const AdtsLayout& other) const -> bool = default;
};

[[nodiscard]] auto read_window(const storage::ReadableSource& source, std::uint64_t offset,
                               std::span<std::byte> window) -> std::size_t {
    const auto read = source.read_at(offset, window);
    if (!read) {
        return 0;
    }
    return *read;
}

}

struct AdtsFrame {
    AdtsLayout layout;
    std::uint32_t header_length = 0;
    std::uint32_t frame_length = 0;
};

[[nodiscard]] auto parse_adts_frame(std::span<const std::byte> header, std::uint64_t offset,
                                    std::uint64_t size) -> expected<std::optional<AdtsFrame>> {
    if (header.size() < 7 || header[0] != std::byte{0xff} ||
        (std::to_integer<unsigned>(header[1]) & 0xf6U) != 0xf0U) {
        return std::optional<AdtsFrame>{};
    }
    const bool protected_frame = (std::to_integer<unsigned>(header[1]) & 0x01U) == 0U;
    AdtsFrame frame;
    frame.layout.profile = static_cast<std::uint8_t>(std::to_integer<unsigned>(header[2]) >> 6U);
    frame.layout.rate_index =
        static_cast<std::uint8_t>((std::to_integer<unsigned>(header[2]) >> 2U) & 0x0fU);
    frame.layout.channels =
        static_cast<std::uint8_t>(((std::to_integer<unsigned>(header[2]) & 0x01U) << 2U) |
                                  (std::to_integer<unsigned>(header[3]) >> 6U));
    frame.frame_length =
        static_cast<std::uint32_t>(((std::to_integer<unsigned>(header[3]) & 0x03U) << 11U) |
                                   (std::to_integer<unsigned>(header[4]) << 3U) |
                                   (std::to_integer<unsigned>(header[5]) >> 5U));
    const auto raw_blocks = std::to_integer<unsigned>(header[6]) & 0x03U;
    frame.header_length = protected_frame ? 9 : 7;
    if (frame.frame_length <= frame.header_length || offset + frame.frame_length > size) {
        return std::optional<AdtsFrame>{};
    }
    if (raw_blocks != 0) {
        return fail(ErrorCode::unsupported, "adts: unsupported block count");
    }
    if (frame.layout.rate_index >= mp4_sampling_rates.size() || frame.layout.channels == 0) {
        return fail(ErrorCode::parse, "adts: invalid frame header");
    }
    return std::optional<AdtsFrame>(frame);
}

[[nodiscard]] auto build_adts_track(const AdtsLayout& layout, std::vector<Mp4Sample> samples)
    -> Mp4Track {
    const auto object_type = static_cast<std::uint16_t>(layout.profile + 1U);
    const auto packed = static_cast<std::uint16_t>(
        (object_type << 11U) | (static_cast<std::uint16_t>(layout.rate_index) << 7U) |
        (static_cast<std::uint16_t>(layout.channels) << 3U));
    Mp4Track track;
    track.codec = Mp4Codec::aac;
    track.config = {static_cast<std::byte>((packed >> 8U) & 0xffU),
                    static_cast<std::byte>(packed & 0xffU)};
    track.channels = layout.channels == 7 ? 8 : layout.channels;
    track.sample_rate = mp4_sampling_rates[layout.rate_index];
    track.timescale = track.sample_rate;
    track.samples = std::move(samples);
    track.time_runs = {Mp4TimeRun{.count = static_cast<std::uint32_t>(track.samples.size()),
                                  .delta = frame_frames}};
    track.start_time = 0;
    track.play_time = std::nullopt;
    return track;
}

auto read_adts_track(const storage::ReadableSource& source) -> expected<Mp4Track> {
    std::array<std::byte, 10> prefix{};
    const auto prefix_read = source.read_at(0, prefix);
    if (!prefix_read) {
        return std::unexpected(prefix_read.error());
    }
    const auto offset_value =
        storage::id3v2_payload_offset(std::span<const std::byte>(prefix.data(), *prefix_read));
    std::uint64_t offset = offset_value.value_or(0);

    std::vector<Mp4Sample> samples;
    std::optional<AdtsLayout> layout;
    std::array<std::byte, window_bytes> window{};
    std::uint64_t window_start = 0;
    std::size_t window_len = 0;
    const std::uint64_t size = source.size();

    while (offset + 7 <= size) {
        if (offset < window_start || offset + 9 > window_start + window_len) {
            window_start = offset;
            window_len = read_window(source, offset, window);
            if (window_len < 7) {
                break;
            }
        }
        const auto header = std::span<const std::byte>(window.data(), window_len)
                                .subspan(static_cast<std::size_t>(offset - window_start));
        const auto parsed = parse_adts_frame(header, offset, size);
        if (!parsed) {
            return std::unexpected(parsed.error());
        }
        if (!*parsed) {
            break;
        }
        if (layout && !(*layout == (*parsed)->layout)) {
            return fail(ErrorCode::parse, "adts: changing layout");
        }
        layout = (*parsed)->layout;
        if (samples.size() == mp4_max_samples) {
            return fail(ErrorCode::out_of_range, "adts: too many frames");
        }
        samples.push_back(Mp4Sample{.offset = offset + (*parsed)->header_length,
                                    .size = (*parsed)->frame_length - (*parsed)->header_length});
        offset += (*parsed)->frame_length;
    }
    if (!layout) {
        return fail(ErrorCode::parse, "adts: no frames");
    }
    return build_adts_track(*layout, std::move(samples));
}

auto open_adts(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
    auto track = read_adts_track(source);
    if (!track) {
        return std::unexpected(track.error());
    }
    return mp4_open_track(source, std::move(*track));
}

auto probe_adts(const storage::ReadableSource& source) -> expected<Properties> {
    auto track = read_adts_track(source);
    if (!track) {
        return std::unexpected(track.error());
    }
    return mp4_probe_track(*track);
}

}
