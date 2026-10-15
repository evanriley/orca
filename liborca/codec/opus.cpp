#include "liborca/codec/opus.hpp"

#include "liborca/base/logging.hpp"

extern "C" {
#include "liborca/codec/opus_shim.h"
}

#include <algorithm>
#include <cstdint>
#include <limits>
#include <memory>
#include <span>

namespace orca::codec {

namespace {

constexpr std::uint32_t decode_rate = 48000;

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

class OpusDecoder final : public Decoder {
public:
    static auto open(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
        orca_opus_info info{};
        orca_opus_decoder* const native = orca_opus_decoder_create(
            const_cast<storage::ReadableSource*>(&source), source_read, source.size(), &info);
        if (native == nullptr) {
            return fail(ErrorCode::parse, "opus: cannot open stream");
        }
        if (info.channels == 0) {
            orca_opus_decoder_destroy(native);
            return fail(ErrorCode::parse, "opus: invalid channel count");
        }

        auto decoder = std::make_unique<OpusDecoder>(native);
        decoder->channels_ = static_cast<std::uint16_t>(info.channels);
        if (info.total_frames >= 0) {
            decoder->total_frames_ = static_cast<std::uint64_t>(info.total_frames);
        }
        decoder->codec = "opus";
        decoder->source_format = std::nullopt;
        decoder->format =
            PcmFormat{.sample_format = SampleFormat::float_32,
                      .channels = decoder->channels_,
                      .sample_rate = decode_rate,
                      .bits_per_sample = 32,
                      .bytes_per_frame = static_cast<std::uint16_t>(decoder->channels_ * 4U)};
        if (info.total_frames >= 0) {
            decoder->frame_count = static_cast<std::uint64_t>(info.total_frames);
        }
        return decoder;
    }

    ~OpusDecoder() override {
        if (native_ != nullptr) {
            orca_opus_decoder_destroy(native_);
        }
    }

    [[nodiscard]] auto read_frames_impl(std::span<float> output) -> expected<std::size_t> override {
        ORCA_ASSERT(native_ != nullptr);
        ORCA_ASSERT(channels_ != 0);
        const std::size_t capacity = output.size() / channels_;
        if (capacity == 0 || at_end_) {
            return std::size_t{0};
        }
        std::uint32_t produced = 0;
        const std::int32_t status =
            orca_opus_decoder_read(native_, output.data(),
                                   static_cast<std::uint32_t>(std::min<std::size_t>(
                                       capacity, std::numeric_limits<std::uint32_t>::max())),
                                   &produced);
        if (status == ORCA_OPUS_OK) {
            return static_cast<std::size_t>(produced);
        }
        if (status == ORCA_OPUS_END_OF_STREAM) {
            return std::size_t{0};
        }
        return fail(ErrorCode::parse, "opus: decode failed");
    }

    [[nodiscard]] auto seek(std::uint64_t frame) -> expected<void> override {
        if (total_frames_ && frame >= *total_frames_) {
            at_end_ = true;
            return {};
        }
        if (orca_opus_decoder_seek(native_, frame) != ORCA_OPUS_OK) {
            return fail(ErrorCode::parse, "opus: seek failed");
        }
        at_end_ = false;
        return {};
    }

    explicit OpusDecoder(orca_opus_decoder* native) : native_(native) {}

private:
    orca_opus_decoder* native_ = nullptr;
    std::uint16_t channels_ = 0;
    std::optional<std::uint64_t> total_frames_;
    bool at_end_ = false;
};

}

auto open_opus(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
    return OpusDecoder::open(source);
}

}
