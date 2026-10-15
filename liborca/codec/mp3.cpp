#include "liborca/codec/mp3.hpp"

#include "liborca/base/logging.hpp"

extern "C" {
#include "liborca/codec/mp3_shim.h"
}

#include <algorithm>
#include <cstdint>
#include <limits>
#include <memory>
#include <span>

namespace orca::codec {

namespace {

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

class Mp3Decoder final : public Decoder {
public:
    static auto open(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
        orca_mp3_info info{};
        std::int32_t error_code = ORCA_MP3_ERROR_OTHER;
        orca_mp3_decoder* const handle =
            orca_mp3_decoder_create(const_cast<storage::ReadableSource*>(&source), source_read,
                                    source.size(), &info, &error_code);
        if (handle == nullptr) {
            switch (error_code) {
            case ORCA_MP3_ERROR_NO_SYNC:
                return fail(ErrorCode::unsupported, "mp3: no MPEG sync");
            case ORCA_MP3_ERROR_OUT_OF_MEMORY:
                return fail(ErrorCode::internal, "mp3: out of memory");
            default:
                return fail(ErrorCode::parse, "mp3: decoder setup failed");
            }
        }
        if (info.channels <= 0 || info.sample_rate <= 0) {
            orca_mp3_decoder_destroy(handle);
            return fail(ErrorCode::parse, "mp3: invalid stream format");
        }

        auto decoder = std::make_unique<Mp3Decoder>(handle);
        decoder->channels_ = static_cast<std::uint16_t>(info.channels);
        switch (info.layer) {
        case 1:
            decoder->codec = "mp1";
            break;
        case 2:
            decoder->codec = "mp2";
            break;
        case 3:
            decoder->codec = "mp3";
            break;
        default:
            return fail(ErrorCode::parse, "mp3: invalid layer");
        }
        decoder->source_format = std::nullopt;
        decoder->format =
            PcmFormat{.sample_format = SampleFormat::float_32,
                      .channels = decoder->channels_,
                      .sample_rate = static_cast<std::uint32_t>(info.sample_rate),
                      .bits_per_sample = 32,
                      .bytes_per_frame = static_cast<std::uint16_t>(decoder->channels_ * 4U)};
        if (info.frame_count >= 0) {
            decoder->frame_count = static_cast<std::uint64_t>(info.frame_count);
        }
        return decoder;
    }

    ~Mp3Decoder() override {
        if (handle_ != nullptr) {
            orca_mp3_decoder_destroy(handle_);
        }
    }

    [[nodiscard]] auto read_frames_impl(std::span<float> output) -> expected<std::size_t> override {
        ORCA_ASSERT(handle_ != nullptr);
        ORCA_ASSERT(channels_ != 0);
        const std::size_t capacity = output.size() / channels_;
        if (capacity == 0) {
            return std::size_t{0};
        }
        std::uint32_t produced = 0;
        const std::int32_t status =
            orca_mp3_decoder_read(handle_, output.data(),
                                  static_cast<std::uint32_t>(std::min<std::size_t>(
                                      capacity, std::numeric_limits<std::uint32_t>::max())),
                                  &produced);
        if (status == ORCA_MP3_OK) {
            return static_cast<std::size_t>(produced);
        }
        if (status == ORCA_MP3_END_OF_STREAM) {
            return std::size_t{0};
        }
        return fail(ErrorCode::parse, "mp3: decode failed");
    }

    [[nodiscard]] auto seek(std::uint64_t frame) -> expected<void> override {
        if (orca_mp3_decoder_seek(handle_, frame) != ORCA_MP3_OK) {
            return fail(ErrorCode::parse, "mp3: seek failed");
        }
        return {};
    }

    explicit Mp3Decoder(orca_mp3_decoder* handle) : handle_(handle) {}

private:
    orca_mp3_decoder* handle_ = nullptr;
    std::uint16_t channels_ = 0;
};

}

auto open_mp3(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
    return Mp3Decoder::open(source);
}

}
