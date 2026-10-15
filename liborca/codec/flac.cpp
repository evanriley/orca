#include "liborca/codec/flac.hpp"

#include "liborca/base/logging.hpp"

extern "C" {
#include "liborca/codec/flac_shim.h"
}

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <utility>

namespace orca::codec {

namespace {

struct StreamFormat {
    std::uint16_t channels = 0;
    std::uint32_t sample_rate = 0;
    std::uint16_t bits_per_sample = 0;
    std::uint64_t frame_count = 0;
    std::uint64_t max_block_frames = 0;
};

[[nodiscard]] auto big64(std::span<const std::byte> bytes) -> std::uint64_t {
    std::uint64_t value = 0;
    for (const std::byte byte : bytes) {
        value = (value << 8U) | std::to_integer<std::uint64_t>(byte);
    }
    return value;
}

[[nodiscard]] auto source_sample_format(std::uint16_t bits_per_sample) -> SampleFormat {
    if (bits_per_sample <= 16) {
        return SampleFormat::signed_16;
    }
    if (bits_per_sample <= 24) {
        return SampleFormat::signed_24;
    }
    return SampleFormat::signed_32;
}

[[nodiscard]] auto read_format(const storage::ReadableSource& source) -> expected<StreamFormat> {
    std::array<std::byte, 26> header{};
    const auto read = source.read_at(0, header);
    if (!read || *read != header.size()) {
        return fail(ErrorCode::parse, "flac: truncated header");
    }
    if (std::memcmp(header.data(), "fLaC", 4) != 0) {
        return fail(ErrorCode::parse, "flac: missing fLaC marker");
    }
    if ((std::to_integer<unsigned>(header[4]) & 0x7fU) != 0U || header[5] != std::byte{0} ||
        header[6] != std::byte{0} || header[7] != std::byte{34}) {
        return fail(ErrorCode::parse, "flac: invalid STREAMINFO");
    }

    const std::uint64_t max_block = (std::to_integer<std::uint64_t>(header[10]) << 8U) |
                                    std::to_integer<std::uint64_t>(header[11]);
    const std::uint64_t stream_bits = big64(std::span<const std::byte>(header.data() + 18, 8));
    const auto sample_rate = static_cast<std::uint32_t>(stream_bits >> 44U);
    const auto channels = static_cast<std::uint16_t>(((stream_bits >> 41U) & 0x7U) + 1U);
    const auto bits_per_sample = static_cast<std::uint16_t>(((stream_bits >> 36U) & 0x1fU) + 1U);
    if (sample_rate == 0 || bits_per_sample < 4) {
        return fail(ErrorCode::parse, "flac: invalid STREAMINFO");
    }
    return StreamFormat{.channels = channels,
                        .sample_rate = sample_rate,
                        .bits_per_sample = bits_per_sample,
                        .frame_count = stream_bits & 0x0000000fffffffffULL,
                        .max_block_frames = max_block};
}

[[nodiscard]] auto source_read(void* opaque_context, std::uint64_t offset, std::uint8_t* buffer,
                               std::uint64_t length) -> std::int64_t {
    const auto* source = static_cast<const storage::ReadableSource*>(opaque_context);
    const auto wanted = static_cast<std::size_t>(
        std::min<std::uint64_t>(length, static_cast<std::uint64_t>(SIZE_MAX)));
    const auto read =
        source->read_at(offset, std::span<std::byte>(reinterpret_cast<std::byte*>(buffer), wanted));
    if (!read) {
        return -1;
    }
    return static_cast<std::int64_t>(*read);
}

class FlacDecoder final : public Decoder {
public:
    static auto open(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
        const auto format = read_format(source);
        if (!format) {
            return std::unexpected(format.error());
        }

        auto decoder = std::make_unique<FlacDecoder>();
        decoder->channels_ = format->channels;
        decoder->declared_frames_ = format->frame_count;
        decoder->max_block_frames_ = format->max_block_frames;
        decoder->native_ = orca_flac_decoder_create(
            const_cast<storage::ReadableSource*>(&source), source_read, source.size(),
            static_cast<std::uint32_t>(format->max_block_frames), format->channels);
        if (decoder->native_ == nullptr) {
            return fail(ErrorCode::parse, "flac: cannot open stream");
        }

        decoder->codec = "flac";
        decoder->source_format = PcmFormat{
            .sample_format = source_sample_format(format->bits_per_sample),
            .channels = format->channels,
            .sample_rate = format->sample_rate,
            .bits_per_sample = format->bits_per_sample,
            .bytes_per_frame = static_cast<std::uint16_t>(format->channels *
                                                          ((format->bits_per_sample + 7U) / 8U)),
        };
        decoder->format =
            PcmFormat{.sample_format = SampleFormat::float_32,
                      .channels = format->channels,
                      .sample_rate = format->sample_rate,
                      .bits_per_sample = 32,
                      .bytes_per_frame = static_cast<std::uint16_t>(format->channels * 4U)};
        if (format->frame_count != 0) {
            decoder->frame_count = format->frame_count;
        }
        return decoder;
    }

    ~FlacDecoder() override {
        if (native_ != nullptr) {
            orca_flac_decoder_destroy(native_);
        }
    }

    [[nodiscard]] auto has_integer_samples() const -> bool override {
        return true;
    }

    [[nodiscard]] auto read_frames_impl(std::span<float> output) -> expected<std::size_t> override {
        return read_as<float>(output, &orca_flac_decoder_read);
    }

    [[nodiscard]] auto read_frames_i32_impl(std::span<std::int32_t> output)
        -> expected<std::size_t> override {
        return read_as<std::int32_t>(output, &orca_flac_decoder_read_i32);
    }

    [[nodiscard]] auto seek(std::uint64_t frame) -> expected<void> override {
        sought_ = true;
        if (declared_frames_ != 0 && frame >= declared_frames_) {
            at_end_ = true;
            frames_decoded_ = declared_frames_;
            return {};
        }
        if (orca_flac_decoder_seek(native_, frame) != 0) {
            return fail(ErrorCode::parse, "flac: seek failed");
        }
        at_end_ = false;
        frames_decoded_ = frame;
        stream_errors_seen_ = orca_flac_decoder_stream_errors(native_);
        return {};
    }

    [[nodiscard]] auto damage() const -> std::optional<Damage> override {
        return damage_;
    }

    FlacDecoder() = default;

private:
    template <typename Sample>
    [[nodiscard]] auto read_as(std::span<Sample> output,
                               std::int32_t (*read_fn)(orca_flac_decoder*, Sample*, std::uint32_t,
                                                       std::uint32_t*)) -> expected<std::size_t> {
        ORCA_ASSERT(native_ != nullptr);
        ORCA_ASSERT(channels_ != 0);
        const std::size_t capacity = output.size() / channels_;
        if (capacity == 0 || at_end_) {
            return std::size_t{0};
        }
        std::uint32_t produced = 0;
        const std::uint64_t frames_before = frames_decoded_;
        const std::int32_t status =
            read_fn(native_, output.data(),
                    static_cast<std::uint32_t>(
                        std::min<std::size_t>(capacity, std::numeric_limits<std::uint32_t>::max())),
                    &produced);
        judge_stream_errors(frames_before, produced);
        if (status == 0) {
            frames_decoded_ += produced;
            return static_cast<std::size_t>(produced);
        }
        if (status == 1) {
            if (sought_) {
                return std::size_t{0};
            }
            if (!reached_declared_end()) {
                if (damage_) {
                    return fail(damage_error(*damage_), "flac: recoverable stream damage");
                }
                return fail(ErrorCode::truncated_flac, "flac: truncated stream");
            }
            if (frames_decoded_ < declared_frames_) {
                record_damage(Damage::truncated_flac);
            }
            if (orca_flac_decoder_md5_mismatch(native_) != 0) {
                record_damage(Damage::flac_md5_mismatch);
            }
            return std::size_t{0};
        }
        return fail(ErrorCode::parse, "flac: decode failed");
    }

    [[nodiscard]] static auto damage_error(Damage found) -> ErrorCode {
        switch (found) {
        case Damage::flac_stream_errors:
            return ErrorCode::flac_stream_errors;
        case Damage::truncated_flac:
            return ErrorCode::truncated_flac;
        case Damage::flac_md5_mismatch:
            return ErrorCode::flac_md5_mismatch;
        default:
            return ErrorCode::parse;
        }
    }

    void record_damage(Damage found) {
        if (!damage_) {
            damage_ = found;
        }
    }

    void judge_stream_errors(std::uint64_t frames_before, std::uint32_t produced) {
        const std::uint64_t errors = orca_flac_decoder_stream_errors(native_);
        if (errors == stream_errors_seen_) {
            return;
        }
        stream_errors_seen_ = errors;
        if (produced > 0 || frames_before < declared_frames_) {
            record_damage(Damage::flac_stream_errors);
        }
    }

    [[nodiscard]] auto reached_declared_end() const -> bool {
        if (declared_frames_ == 0) {
            return false;
        }
        if (frames_decoded_ >= declared_frames_) {
            return true;
        }
        const std::uint64_t missing = declared_frames_ - frames_decoded_;
        return missing < std::max<std::uint64_t>(max_block_frames_, 1);
    }

    orca_flac_decoder* native_ = nullptr;
    std::uint16_t channels_ = 0;
    bool sought_ = false;
    std::uint64_t declared_frames_ = 0;
    std::uint64_t frames_decoded_ = 0;
    std::uint64_t max_block_frames_ = 0;
    std::uint64_t stream_errors_seen_ = 0;
    bool at_end_ = false;
    std::optional<Damage> damage_;
};

}

auto open_flac(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
    return FlacDecoder::open(source);
}

}
