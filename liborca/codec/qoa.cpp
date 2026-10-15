#include "liborca/codec/qoa.hpp"

#include "liborca/base/logging.hpp"

extern "C" {
#include "liborca/codec/qoa_shim.h"
}

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <span>

namespace orca::codec {

namespace {

constexpr std::uint64_t frame_frames = 5120;
constexpr std::uint64_t file_header_bytes = 8;
constexpr std::uint16_t max_channels = 8;
constexpr std::uint32_t max_frame_bytes = 8 + (16 * max_channels) + (256 * 8 * max_channels);

struct StreamFormat {
    std::uint16_t channels = 0;
    std::uint32_t sample_rate = 0;
    std::uint64_t frames = 0;
};

[[nodiscard]] auto big32(std::span<const std::byte> bytes, std::size_t offset) -> std::uint32_t {
    return (std::to_integer<std::uint32_t>(bytes[offset]) << 24U) |
           (std::to_integer<std::uint32_t>(bytes[offset + 1]) << 16U) |
           (std::to_integer<std::uint32_t>(bytes[offset + 2]) << 8U) |
           std::to_integer<std::uint32_t>(bytes[offset + 3]);
}

[[nodiscard]] auto big64(std::span<const std::byte> bytes) -> std::uint64_t {
    return (static_cast<std::uint64_t>(big32(bytes, 0)) << 32U) | big32(bytes, 4);
}

[[nodiscard]] auto validate_source(const storage::ReadableSource& source)
    -> expected<StreamFormat> {
    std::array<std::byte, 8> file_header{};
    const auto header_read = source.read_at(0, file_header);
    if (!header_read || *header_read != file_header.size()) {
        return fail(ErrorCode::parse, "qoa: truncated header");
    }
    if (std::memcmp(file_header.data(), "qoaf", 4) != 0) {
        return fail(ErrorCode::parse, "qoa: missing qoaf marker");
    }
    const std::uint32_t expected_frames = big32(file_header, 4);
    std::uint64_t offset = 8;
    std::uint64_t decoded_frames = 0;
    bool have_format = false;
    StreamFormat format;

    while (decoded_frames < expected_frames) {
        std::array<std::byte, 8> bytes{};
        const auto read = source.read_at(offset, bytes);
        if (!read || *read != bytes.size()) {
            return fail(ErrorCode::parse, "qoa: truncated frame header");
        }
        const std::uint64_t value = big64(bytes);
        const auto channels = static_cast<std::uint16_t>((value >> 56U) & 0xffU);
        const auto sample_rate = static_cast<std::uint32_t>((value >> 32U) & 0xffffffU);
        const auto samples = static_cast<std::uint16_t>((value >> 16U) & 0xffffU);
        const auto size = static_cast<std::uint16_t>(value & 0xffffU);
        const std::uint32_t minimum_size = 8 + (16U * channels);
        if (channels == 0 || channels > max_channels || sample_rate == 0 || samples == 0 ||
            size < minimum_size || offset + size > source.size()) {
            return fail(ErrorCode::parse, "qoa: invalid frame header");
        }
        const std::uint32_t encoded_bytes = size - minimum_size;
        if (encoded_bytes % 8 != 0) {
            return fail(ErrorCode::parse, "qoa: misaligned frame");
        }
        const std::uint32_t slices = encoded_bytes / 8;
        const std::uint32_t expected_slices =
            ((static_cast<std::uint32_t>(samples) + 19U) / 20U) * channels;
        if (slices != expected_slices) {
            return fail(ErrorCode::parse, "qoa: wrong slice count");
        }
        if (have_format) {
            if (format.channels != channels || format.sample_rate != sample_rate) {
                return fail(ErrorCode::parse, "qoa: changing format");
            }
        } else {
            format = StreamFormat{
                .channels = channels, .sample_rate = sample_rate, .frames = expected_frames};
            have_format = true;
        }
        decoded_frames += samples;
        if (decoded_frames > expected_frames) {
            return fail(ErrorCode::parse, "qoa: frames past declared total");
        }
        if (samples != frame_frames && decoded_frames != expected_frames) {
            return fail(ErrorCode::parse, "qoa: short frame not last");
        }
        offset += size;
    }
    if (!have_format || decoded_frames != expected_frames || offset != source.size()) {
        return fail(ErrorCode::parse, "qoa: frame walk mismatch");
    }
    return format;
}

class QoaDecoder final : public Decoder {
public:
    static auto open(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
        const auto format = validate_source(source);
        if (!format) {
            return std::unexpected(format.error());
        }
        std::array<std::byte, 16> header{};
        const auto header_read = source.read_at(0, header);
        if (!header_read || *header_read != header.size()) {
            return fail(ErrorCode::parse, "qoa: truncated header");
        }
        orca_qoa_info info{};
        orca_qoa_decoder* const native =
            orca_qoa_decoder_create(reinterpret_cast<const std::uint8_t*>(header.data()),
                                    static_cast<std::uint32_t>(header.size()), &info);
        if (native == nullptr) {
            return fail(ErrorCode::parse, "qoa: cannot open stream");
        }
        if (info.max_frame_bytes > max_frame_bytes) {
            orca_qoa_decoder_destroy(native);
            return fail(ErrorCode::parse, "qoa: frame too large");
        }

        auto decoder = std::make_unique<QoaDecoder>(source, native);
        decoder->channels_ = format->channels;
        decoder->total_frames_ = format->frames;
        decoder->full_frame_bytes_ = info.max_frame_bytes;
        decoder->remaining_frames_ = format->frames;
        decoder->codec = "qoa";
        decoder->source_format =
            PcmFormat{.sample_format = SampleFormat::signed_16,
                      .channels = format->channels,
                      .sample_rate = format->sample_rate,
                      .bits_per_sample = 16,
                      .bytes_per_frame = static_cast<std::uint16_t>(format->channels * 2U)};
        decoder->format =
            PcmFormat{.sample_format = SampleFormat::float_32,
                      .channels = format->channels,
                      .sample_rate = format->sample_rate,
                      .bits_per_sample = 32,
                      .bytes_per_frame = static_cast<std::uint16_t>(format->channels * 4U)};
        decoder->frame_count = format->frames;
        return decoder;
    }

    ~QoaDecoder() override {
        if (native_ != nullptr) {
            orca_qoa_decoder_destroy(native_);
        }
    }

    [[nodiscard]] auto read_frames_impl(std::span<float> output) -> expected<std::size_t> override {
        ORCA_ASSERT(native_ != nullptr);
        ORCA_ASSERT(channels_ != 0);
        if (remaining_frames_ == 0) {
            return std::size_t{0};
        }
        if (pending_start_ == pending_end_) {
            const auto decoded = decode_next();
            if (!decoded) {
                return std::unexpected(decoded.error());
            }
            if (!*decoded) {
                return std::size_t{0};
            }
        }
        const std::size_t pending = (pending_end_ - pending_start_) / channels_;
        const auto frame_limit =
            std::min({static_cast<std::uint64_t>(pending),
                      static_cast<std::uint64_t>(output.size() / channels_), remaining_frames_});
        const auto frames = static_cast<std::size_t>(frame_limit);
        const std::size_t samples = frames * channels_;
        std::copy_n(pcm_.data() + pending_start_, samples, output.data());
        pending_start_ += samples;
        remaining_frames_ -= frames;
        return frames;
    }

    [[nodiscard]] auto seek(std::uint64_t requested) -> expected<void> override {
        const std::uint64_t frame = std::min(requested, total_frames_);
        const std::uint64_t index = frame / frame_frames;
        offset_ = file_header_bytes + (index * full_frame_bytes_);
        skip_frames_ = frame - (index * frame_frames);
        remaining_frames_ = total_frames_ - frame;
        pending_start_ = 0;
        pending_end_ = 0;
        return {};
    }

    QoaDecoder(const storage::ReadableSource& source, orca_qoa_decoder* native)
        : source_(&source), native_(native) {}

private:
    [[nodiscard]] auto decode_next() -> expected<bool> {
        while (remaining_frames_ > 0) {
            const std::uint64_t available =
                source_->size() > offset_ ? source_->size() - offset_ : 0;
            const auto wanted =
                static_cast<std::size_t>(std::min<std::uint64_t>(available, full_frame_bytes_));
            if (wanted == 0) {
                return false;
            }
            const auto read =
                source_->read_at(offset_, std::span<std::byte>(frame_.data(), wanted));
            if (!read || *read != wanted) {
                return fail(ErrorCode::parse, "qoa: truncated frame");
            }
            std::uint32_t frames = 0;
            const std::uint32_t consumed = orca_qoa_decoder_decode_frame(
                native_, reinterpret_cast<const std::uint8_t*>(frame_.data()),
                static_cast<std::uint32_t>(wanted), pcm_.data(), &frames);
            if (consumed == 0) {
                return fail(ErrorCode::parse, "qoa: invalid frame");
            }
            offset_ += consumed;
            const std::uint64_t dropped = std::min<std::uint64_t>(frames, skip_frames_);
            skip_frames_ -= dropped;
            if (frames == dropped) {
                continue;
            }
            pending_start_ = static_cast<std::size_t>(dropped * channels_);
            pending_end_ = (static_cast<std::size_t>(frames) * channels_);
            return true;
        }
        return false;
    }

    const storage::ReadableSource* source_;
    orca_qoa_decoder* native_ = nullptr;
    std::uint16_t channels_ = 0;
    std::uint64_t total_frames_ = 0;
    std::uint64_t full_frame_bytes_ = 0;
    std::array<std::byte, max_frame_bytes> frame_{};
    std::array<float, frame_frames * max_channels> pcm_{};
    std::size_t pending_start_ = 0;
    std::size_t pending_end_ = 0;
    std::uint64_t offset_ = file_header_bytes;
    std::uint64_t skip_frames_ = 0;
    std::uint64_t remaining_frames_ = 0;
};

}

auto open_qoa(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
    return QoaDecoder::open(source);
}

}
