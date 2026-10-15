#pragma once

#include "liborca/codec/decoder.hpp"
#include "liborca/codec/registry.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

namespace orca::codec {

inline constexpr std::size_t mp4_max_samples = 4 * 1024 * 1024;
inline constexpr std::uint32_t mp4_max_packet_bytes = 4 * 1024 * 1024;

inline constexpr std::array<std::uint32_t, 13> mp4_sampling_rates = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};

struct Mp4Sample {
    std::uint64_t offset = 0;
    std::uint32_t size = 0;
};

struct Mp4TimeRun {
    std::uint32_t count = 0;
    std::uint32_t delta = 0;
};

enum class Mp4Codec : std::uint8_t { aac, alac };

struct Mp4Track {
    Mp4Codec codec = Mp4Codec::aac;
    std::vector<std::byte> config;
    std::uint16_t channels = 0;
    std::uint32_t sample_rate = 0;
    std::uint32_t timescale = 0;
    std::vector<Mp4Sample> samples;
    std::vector<Mp4TimeRun> time_runs;
    std::uint64_t start_time = 0;
    std::optional<std::uint64_t> play_time;
};

struct Mp4PacketTime {
    std::size_t index = 0;
    std::uint64_t start = 0;
};

[[nodiscard]] auto mp4_media_time(const Mp4Track& track) -> expected<std::uint64_t>;
[[nodiscard]] auto mp4_packet_at(const Mp4Track& track, std::uint64_t time)
    -> expected<Mp4PacketTime>;

[[nodiscard]] auto mp4_read_track(const storage::ReadableSource& source) -> expected<Mp4Track>;
[[nodiscard]] auto mp4_probe_track(const Mp4Track& track) -> expected<Properties>;
[[nodiscard]] auto mp4_probe(const storage::ReadableSource& source) -> expected<Properties>;
[[nodiscard]] auto mp4_open(const storage::ReadableSource& source)
    -> expected<std::unique_ptr<Decoder>>;
[[nodiscard]] auto mp4_open_track(const storage::ReadableSource& source, Mp4Track track)
    -> expected<std::unique_ptr<Decoder>>;

}
