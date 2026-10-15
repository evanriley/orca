#include "liborca/codec/wav.hpp"

#include "liborca/base/checked.hpp"
#include "liborca/base/logging.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <vector>

namespace orca::codec {

namespace {

constexpr std::uint16_t wave_format_pcm = 1;
constexpr std::uint16_t wave_format_float = 3;
constexpr std::uint16_t wave_format_extensible = 0xfffe;
constexpr std::uint16_t max_scratch_frames = 4096;

[[nodiscard]] auto little16(std::span<const std::byte> bytes, std::size_t offset) -> std::uint16_t {
    return static_cast<std::uint16_t>(std::to_integer<std::uint16_t>(bytes[offset]) |
                                      (std::to_integer<std::uint16_t>(bytes[offset + 1]) << 8U));
}

[[nodiscard]] auto little32(std::span<const std::byte> bytes, std::size_t offset) -> std::uint32_t {
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value |= std::to_integer<std::uint32_t>(bytes[offset + index]) << (index * 8U);
    }
    return value;
}

[[nodiscard]] auto little64(std::span<const std::byte> bytes, std::size_t offset) -> std::uint64_t {
    return static_cast<std::uint64_t>(little32(bytes, offset)) |
           (static_cast<std::uint64_t>(little32(bytes, offset + 4)) << 32U);
}

[[nodiscard]] auto sample_format(std::uint16_t encoding, std::uint16_t bits)
    -> expected<SampleFormat> {
    if (encoding == wave_format_pcm) {
        switch (bits) {
        case 8:
            return SampleFormat::unsigned_8;
        case 16:
            return SampleFormat::signed_16;
        case 24:
            return SampleFormat::signed_24;
        case 32:
            return SampleFormat::signed_32;
        default:
            return fail(ErrorCode::unsupported, "wav: unsupported PCM width");
        }
    }
    if (encoding == wave_format_float) {
        switch (bits) {
        case 32:
            return SampleFormat::float_32;
        case 64:
            return SampleFormat::float_64;
        default:
            return fail(ErrorCode::unsupported, "wav: unsupported float width");
        }
    }
    return fail(ErrorCode::unsupported, "wav: unsupported encoding");
}

[[nodiscard]] auto format_tag(const storage::ReadableSource& source, std::uint64_t fmt_offset,
                              std::uint32_t fmt_size, std::uint16_t tag)
    -> expected<std::uint16_t> {
    if (tag != wave_format_extensible) {
        return tag;
    }
    if (fmt_size < 40) {
        return fail(ErrorCode::parse, "wav: short extensible format");
    }
    std::array<std::byte, 16> guid{};
    const auto read = source.read_at(fmt_offset + 24, guid);
    if (!read || *read != guid.size()) {
        return fail(ErrorCode::parse, "wav: truncated extensible format");
    }
    static constexpr std::array<std::uint8_t, 14> guid_tail{
        0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71};
    if (std::memcmp(guid.data() + 2, guid_tail.data(), guid_tail.size()) != 0) {
        return fail(ErrorCode::unsupported, "wav: unsupported subformat GUID");
    }
    return little16(guid, 0);
}

struct WavReader {
    const storage::ReadableSource* source = nullptr;
    PcmFormat format{};
    std::uint64_t data_offset = 0;
    std::uint64_t data_bytes = 0;

    [[nodiscard]] auto frame_count() const -> std::uint64_t {
        return data_bytes / format.bytes_per_frame;
    }

    [[nodiscard]] auto has_damage() const -> bool {
        return data_bytes % format.bytes_per_frame != 0;
    }
};

[[nodiscard]] auto parse_fmt(const storage::ReadableSource& source, std::uint64_t payload,
                             std::uint32_t chunk_size) -> expected<PcmFormat> {
    if (chunk_size < 16) {
        return fail(ErrorCode::parse, "wav: short format chunk");
    }
    std::array<std::byte, 16> fmt{};
    const auto fmt_read = source.read_at(payload, fmt);
    if (!fmt_read || *fmt_read != fmt.size()) {
        return fail(ErrorCode::parse, "wav: truncated format chunk");
    }
    const auto encoding = format_tag(source, payload, chunk_size, little16(fmt, 0));
    if (!encoding) {
        return std::unexpected(encoding.error());
    }
    const std::uint16_t channels = little16(fmt, 2);
    const std::uint32_t sample_rate = little32(fmt, 4);
    const std::uint16_t block_align = little16(fmt, 12);
    const std::uint16_t bits = little16(fmt, 14);
    if (channels == 0 || sample_rate == 0 || block_align == 0) {
        return fail(ErrorCode::parse, "wav: invalid format chunk");
    }
    const auto decoded = sample_format(*encoding, bits);
    if (!decoded) {
        return std::unexpected(decoded.error());
    }
    if (bits % 8 != 0) {
        return fail(ErrorCode::parse, "wav: unaligned sample width");
    }
    const auto expected_align =
        orca::checked::mul<std::uint16_t>(channels, static_cast<std::uint16_t>(bits / 8U));
    if (!expected_align) {
        return std::unexpected(expected_align.error());
    }
    if (block_align != *expected_align) {
        return fail(ErrorCode::parse, "wav: block alignment mismatch");
    }
    return PcmFormat{.sample_format = *decoded,
                     .channels = channels,
                     .sample_rate = sample_rate,
                     .bits_per_sample = bits,
                     .bytes_per_frame = block_align};
}

[[nodiscard]] auto open_reader(const storage::ReadableSource& source) -> expected<WavReader> {
    std::array<std::byte, 12> riff{};
    const auto read = source.read_at(0, riff);
    if (!read || *read != riff.size()) {
        return fail(ErrorCode::parse, "wav: truncated header");
    }
    if (std::memcmp(riff.data(), "RIFF", 4) != 0 || std::memcmp(riff.data() + 8, "WAVE", 4) != 0) {
        return fail(ErrorCode::parse, "wav: not a RIFF/WAVE file");
    }

    WavReader reader;
    reader.source = &source;
    std::optional<PcmFormat> parsed_format;
    std::optional<std::uint64_t> data_offset;
    std::uint64_t data_bytes = 0;

    std::uint64_t offset = 12;
    while (offset + 8 <= source.size()) {
        std::array<std::byte, 8> chunk{};
        const auto got = source.read_at(offset, chunk);
        if (!got || *got != chunk.size()) {
            return fail(ErrorCode::parse, "wav: truncated chunk header");
        }
        const std::uint32_t chunk_size = little32(chunk, 4);
        const std::uint64_t payload = offset + 8;
        if (payload + chunk_size > source.size()) {
            return fail(ErrorCode::parse, "wav: chunk past end");
        }

        if (std::memcmp(chunk.data(), "fmt ", 4) == 0) {
            const auto parsed = parse_fmt(source, payload, chunk_size);
            if (!parsed) {
                return std::unexpected(parsed.error());
            }
            parsed_format = *parsed;
        } else {
            if (std::memcmp(chunk.data(), "data", 4) == 0) {
                data_offset = payload;
                data_bytes = chunk_size;
            }
        }

        offset = payload + chunk_size + (chunk_size & 1U);
        if (parsed_format && data_offset) {
            break;
        }
    }

    if (!parsed_format) {
        return fail(ErrorCode::parse, "wav: missing format chunk");
    }
    if (!data_offset) {
        return fail(ErrorCode::parse, "wav: missing data chunk");
    }
    reader.format = *parsed_format;
    reader.data_offset = *data_offset;
    reader.data_bytes = data_bytes;
    return reader;
}

[[nodiscard]] auto decode_sample_impl(SampleFormat format, std::span<const std::byte> bytes)
    -> float {
    ORCA_ASSERT(!bytes.empty());
    switch (format) {
    case SampleFormat::unsigned_8:
        return (static_cast<float>(std::to_integer<std::uint8_t>(bytes[0])) - 128.0F) / 128.0F;
    case SampleFormat::signed_8:
        return static_cast<float>(
                   static_cast<std::int8_t>(std::to_integer<std::uint8_t>(bytes[0]))) /
               128.0F;
    case SampleFormat::signed_16: {
        const auto raw = static_cast<std::int16_t>(little16(bytes, 0));
        return static_cast<float>(raw) / 32768.0F;
    }
    case SampleFormat::signed_24: {
        const std::uint32_t raw = std::to_integer<std::uint32_t>(bytes[0]) |
                                  (std::to_integer<std::uint32_t>(bytes[1]) << 8U) |
                                  (std::to_integer<std::uint32_t>(bytes[2]) << 16U);
        std::int32_t signed_value = 0;
        if ((raw & 0x800000U) != 0U) {
            signed_value = static_cast<std::int32_t>(raw | 0xff000000U);
        } else {
            signed_value = static_cast<std::int32_t>(raw);
        }
        return static_cast<float>(signed_value) / 8388608.0F;
    }
    case SampleFormat::signed_32:
        return static_cast<float>(static_cast<std::int32_t>(little32(bytes, 0))) / 2147483648.0F;
    case SampleFormat::float_32: {
        const std::uint32_t raw = little32(bytes, 0);
        float value = 0.0F;
        std::memcpy(&value, &raw, sizeof(value));
        return value;
    }
    case SampleFormat::float_64: {
        const std::uint64_t raw = little64(bytes, 0);
        double value = 0.0;
        std::memcpy(&value, &raw, sizeof(value));
        return static_cast<float>(value);
    }
    }
    return 0.0F;
}

[[nodiscard]] auto decode_integer_impl(SampleFormat format, std::span<const std::byte> bytes)
    -> expected<std::int32_t> {
    switch (format) {
    case SampleFormat::unsigned_8: {
        const auto raw = static_cast<std::int8_t>(std::to_integer<std::uint8_t>(bytes[0]) ^ 0x80U);
        return static_cast<std::int32_t>(raw) << 24;
    }
    case SampleFormat::signed_8:
        return static_cast<std::int32_t>(
                   static_cast<std::int8_t>(std::to_integer<std::uint8_t>(bytes[0])))
               << 24;
    case SampleFormat::signed_16:
        return static_cast<std::int32_t>(static_cast<std::int16_t>(little16(bytes, 0))) << 16;
    case SampleFormat::signed_24: {
        const std::uint32_t raw = std::to_integer<std::uint32_t>(bytes[0]) |
                                  (std::to_integer<std::uint32_t>(bytes[1]) << 8U) |
                                  (std::to_integer<std::uint32_t>(bytes[2]) << 16U);
        return static_cast<std::int32_t>(raw) << 8;
    }
    case SampleFormat::signed_32:
        return static_cast<std::int32_t>(little32(bytes, 0));
    case SampleFormat::float_32:
    case SampleFormat::float_64:
        return fail(ErrorCode::unsupported, "wav: no integer samples for float PCM");
    }
    return fail(ErrorCode::unsupported, "wav: unsupported sample format");
}

class WavDecoder final : public Decoder {
public:
    explicit WavDecoder(WavReader reader) : reader_(reader) {
        const std::uint64_t frames = reader_.frame_count();
        const std::size_t scratch_frames = static_cast<std::size_t>(
            std::max<std::uint64_t>(1, std::min<std::uint64_t>(max_scratch_frames, frames)));
        scratch_.resize(scratch_frames * reader_.format.bytes_per_frame);
        codec = is_float(reader_.format.sample_format) ? "pcm_float" : "pcm";
        source_format = reader_.format;
        format =
            PcmFormat{.sample_format = SampleFormat::float_32,
                      .channels = reader_.format.channels,
                      .sample_rate = reader_.format.sample_rate,
                      .bits_per_sample = 32,
                      .bytes_per_frame = static_cast<std::uint16_t>(reader_.format.channels * 4)};
        frame_count = frames;
    }

    [[nodiscard]] auto has_integer_samples() const -> bool override {
        return !is_float(reader_.format.sample_format);
    }

    [[nodiscard]] auto read_frames_impl(std::span<float> output) -> expected<std::size_t> override {
        return read_as<float>(output, false);
    }

    [[nodiscard]] auto read_frames_i32_impl(std::span<std::int32_t> output)
        -> expected<std::size_t> override {
        return read_as<std::int32_t>(output, true);
    }

    [[nodiscard]] auto seek(std::uint64_t frame) -> expected<void> override {
        position_ = std::min(frame, reader_.frame_count());
        return {};
    }

    [[nodiscard]] auto damage() const -> std::optional<Damage> override {
        return reader_.has_damage() ? std::optional<Damage>(Damage::partial_wav_frame)
                                    : std::nullopt;
    }

private:
    [[nodiscard]] static auto is_float(SampleFormat format) -> bool {
        return format == SampleFormat::float_32 || format == SampleFormat::float_64;
    }

    template <typename Sample>
    [[nodiscard]] auto read_as(std::span<Sample> output, bool integer) -> expected<std::size_t> {
        ORCA_ASSERT(reader_.source != nullptr);
        ORCA_ASSERT(reader_.format.bytes_per_frame != 0);
        const std::size_t output_frames = output.size() / reader_.format.channels;
        const std::size_t scratch_frames = scratch_.size() / reader_.format.bytes_per_frame;
        const std::size_t requested = std::min(output_frames, scratch_frames);
        if (requested == 0) {
            return std::size_t{0};
        }

        const std::uint64_t byte_offset = position_ * reader_.format.bytes_per_frame;
        const auto available = static_cast<std::size_t>(
            std::min<std::uint64_t>(reader_.data_bytes - std::min(byte_offset, reader_.data_bytes),
                                    requested * reader_.format.bytes_per_frame));
        if (available == 0) {
            return std::size_t{0};
        }
        const auto read = reader_.source->read_at(reader_.data_offset + byte_offset,
                                                  std::span<std::byte>(scratch_.data(), available));
        if (!read) {
            return std::unexpected(read.error());
        }
        const std::size_t frames = *read / reader_.format.bytes_per_frame;
        const std::size_t sample_bytes = reader_.format.bits_per_sample / 8;
        const std::size_t sample_count = frames * reader_.format.channels;
        for (std::size_t index = 0; index < sample_count; ++index) {
            const auto slice =
                std::span<const std::byte>(scratch_.data() + (index * sample_bytes), sample_bytes);
            if (integer) {
                const auto decoded = decode_integer_impl(reader_.format.sample_format, slice);
                if (!decoded) {
                    return std::unexpected(decoded.error());
                }
                output[index] = static_cast<Sample>(*decoded);
            } else {
                output[index] =
                    static_cast<Sample>(decode_sample_impl(reader_.format.sample_format, slice));
            }
        }
        position_ += frames;
        return frames;
    }

    WavReader reader_;
    std::vector<std::byte> scratch_;
    std::uint64_t position_ = 0;
};

}

auto decode_sample(SampleFormat format, std::span<const std::byte> bytes) -> float {
    return decode_sample_impl(format, bytes);
}

auto decode_integer(SampleFormat format, std::span<const std::byte> bytes)
    -> expected<std::int32_t> {
    return decode_integer_impl(format, bytes);
}

auto open_wav(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
    const auto reader = open_reader(source);
    if (!reader) {
        return std::unexpected(reader.error());
    }
    return std::make_unique<WavDecoder>(*reader);
}

}
