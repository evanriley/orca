#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/storage/source.hpp"

#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string_view>

namespace orca::codec {

enum class SampleFormat : std::uint8_t {
    unsigned_8,
    signed_8,
    signed_16,
    signed_24,
    signed_32,
    float_32,
    float_64,
};

struct PcmFormat {
    SampleFormat sample_format = SampleFormat::signed_16;
    std::uint16_t channels = 0;
    std::uint32_t sample_rate = 0;
    std::uint16_t bits_per_sample = 0;
    std::uint16_t bytes_per_frame = 0;

    [[nodiscard]] auto operator==(const PcmFormat& other) const -> bool = default;
};

enum class Damage {
    truncated_aiff,
    partial_wav_frame,
    flac_stream_errors,
    truncated_flac,
    flac_md5_mismatch,
};

inline constexpr std::uint16_t max_supported_channels = 2;

[[nodiscard]] auto integer_sample_to_float(std::int32_t sample) -> float;

class Decoder {
public:
    virtual ~Decoder() = default;

    Decoder(const Decoder&) = delete;
    auto operator=(const Decoder&) -> Decoder& = delete;

    [[nodiscard]] auto read_frames(std::span<float> output) -> expected<std::size_t> {
        if (format.channels == 0 || output.size() % format.channels != 0) {
            return fail(ErrorCode::invalid_argument, "decoder: unaligned PCM buffer");
        }
        return read_frames_impl(output);
    }
    [[nodiscard]] virtual auto seek(std::uint64_t frame) -> expected<void> = 0;
    [[nodiscard]] virtual auto has_integer_samples() const -> bool {
        return false;
    }
    [[nodiscard]] auto read_frames_i32(std::span<std::int32_t> output) -> expected<std::size_t> {
        if (format.channels == 0 || output.size() % format.channels != 0) {
            return fail(ErrorCode::invalid_argument, "decoder: unaligned PCM buffer");
        }
        return read_frames_i32_impl(output);
    }
    [[nodiscard]] virtual auto damage() const -> std::optional<Damage> {
        return std::nullopt;
    }

    std::string_view codec;
    std::optional<PcmFormat> source_format;
    PcmFormat format;
    std::optional<std::uint64_t> frame_count;

protected:
    Decoder() = default;

    [[nodiscard]] virtual auto read_frames_impl(std::span<float> output)
        -> expected<std::size_t> = 0;
    [[nodiscard]] virtual auto read_frames_i32_impl(std::span<std::int32_t> output)
        -> expected<std::size_t>;
};

using OpenFn = expected<std::unique_ptr<Decoder>> (*)(const storage::ReadableSource&);

}
