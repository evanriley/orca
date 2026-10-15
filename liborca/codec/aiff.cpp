#include "liborca/codec/aiff.hpp"

#include "liborca/base/logging.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <optional>
#include <span>
#include <utility>
#include <vector>

namespace orca::codec {

namespace {

enum class Encoding : std::uint8_t { big_integer, little_integer, big_float };

constexpr std::uint16_t max_scratch_frames = 4096;

[[nodiscard]] auto big16(std::span<const std::byte> bytes, std::size_t offset) -> std::uint16_t {
    return static_cast<std::uint16_t>((std::to_integer<std::uint16_t>(bytes[offset]) << 8U) |
                                      std::to_integer<std::uint16_t>(bytes[offset + 1]));
}

[[nodiscard]] auto big32(std::span<const std::byte> bytes, std::size_t offset) -> std::uint32_t {
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value = (value << 8U) | std::to_integer<std::uint32_t>(bytes[offset + index]);
    }
    return value;
}

[[nodiscard]] auto big64(std::span<const std::byte> bytes, std::size_t offset) -> std::uint64_t {
    std::uint64_t value = 0;
    for (std::size_t index = 0; index < 8; ++index) {
        value = (value << 8U) | std::to_integer<std::uint64_t>(bytes[offset + index]);
    }
    return value;
}

[[nodiscard]] auto extended_to_rate(std::span<const std::byte> bytes)
    -> std::optional<std::uint32_t> {
    const std::uint16_t sign_exponent = big16(bytes, 0);
    if ((sign_exponent & 0x8000U) != 0U) {
        return std::nullopt;
    }
    const std::int32_t exponent = static_cast<std::int32_t>(sign_exponent) - 16383;
    const std::uint64_t mantissa = big64(bytes, 2);
    if (mantissa == 0 || exponent < 0 || exponent > 31) {
        return std::nullopt;
    }
    return static_cast<std::uint32_t>(mantissa >> (63 - exponent));
}

[[nodiscard]] auto compression(std::span<const std::byte> tag, std::uint16_t bits)
    -> expected<Encoding> {
    if (std::memcmp(tag.data(), "NONE", 4) == 0 || std::memcmp(tag.data(), "twos", 4) == 0) {
        return Encoding::big_integer;
    }
    if (std::memcmp(tag.data(), "sowt", 4) == 0) {
        return bits == 8 ? Encoding::big_integer : Encoding::little_integer;
    }
    if (std::memcmp(tag.data(), "fl32", 4) == 0 || std::memcmp(tag.data(), "FL32", 4) == 0 ||
        std::memcmp(tag.data(), "fl64", 4) == 0 || std::memcmp(tag.data(), "FL64", 4) == 0) {
        return Encoding::big_float;
    }
    return fail(ErrorCode::unsupported, "aiff: unsupported compression");
}

struct Layout {
    PcmFormat format{};
    Encoding encoding = Encoding::big_integer;
    std::uint64_t data_offset = 0;
    std::uint64_t frames = 0;
    std::optional<Damage> damage;
};

struct ChunkHeader {
    std::array<std::byte, 4> kind{};
    std::uint32_t size = 0;
    std::uint64_t body = 0;
};

[[nodiscard]] auto read_chunk_header(const storage::ReadableSource& source, std::uint64_t offset)
    -> expected<ChunkHeader> {
    std::array<std::byte, 8> header{};
    const auto got = source.read_at(offset, header);
    if (!got || *got != header.size()) {
        return fail(ErrorCode::parse, "aiff: truncated chunk header");
    }
    ChunkHeader parsed;
    std::memcpy(parsed.kind.data(), header.data(), parsed.kind.size());
    parsed.size = big32(header, 4);
    parsed.body = offset + 8;
    return parsed;
}

struct Common {
    std::uint16_t channels = 0;
    std::uint32_t frames = 0;
    std::uint16_t bits = 0;
    std::uint32_t rate = 0;
    Encoding encoding = Encoding::big_integer;
};

[[nodiscard]] auto parse_common(const storage::ReadableSource& source, std::uint64_t body,
                                std::uint32_t size, bool compressed) -> expected<Common> {
    const std::size_t wanted = compressed ? 22 : 18;
    if (size < wanted) {
        return fail(ErrorCode::parse, "aiff: short COMM chunk");
    }
    std::array<std::byte, 22> comm{};
    const auto comm_read = source.read_at(body, std::span<std::byte>(comm.data(), wanted));
    if (!comm_read || *comm_read != wanted) {
        return fail(ErrorCode::parse, "aiff: truncated COMM chunk");
    }
    Common parsed;
    parsed.channels = big16(comm, 0);
    parsed.frames = big32(comm, 2);
    parsed.bits = big16(comm, 6);
    const auto rate = extended_to_rate(std::span<const std::byte>(comm.data() + 8, 10));
    if (!rate) {
        return fail(ErrorCode::parse, "aiff: invalid sample rate");
    }
    parsed.rate = *rate;
    if (compressed) {
        const auto encoding =
            compression(std::span<const std::byte>(comm.data() + 18, 4), parsed.bits);
        if (!encoding) {
            return std::unexpected(encoding.error());
        }
        parsed.encoding = *encoding;
    }
    return parsed;
}

[[nodiscard]] auto parse_ssnd(const storage::ReadableSource& source, std::uint64_t body,
                              std::uint32_t size)
    -> expected<std::pair<std::uint64_t, std::uint64_t>> {
    if (size < 8) {
        return fail(ErrorCode::parse, "aiff: short SSND chunk");
    }
    std::array<std::byte, 4> ssnd{};
    const auto ssnd_read = source.read_at(body, ssnd);
    if (!ssnd_read || *ssnd_read != ssnd.size()) {
        return fail(ErrorCode::parse, "aiff: truncated SSND chunk");
    }
    const std::uint32_t skip = big32(ssnd, 0);
    if (skip > size - 8) {
        return fail(ErrorCode::parse, "aiff: SSND skip past end");
    }
    return std::pair(body + 8 + skip, size - 8 - skip);
}

[[nodiscard]] auto resolve_sample_format(Encoding encoding, std::uint16_t bits)
    -> expected<SampleFormat> {
    if (encoding == Encoding::big_float) {
        if (bits == 32) {
            return SampleFormat::float_32;
        }
        if (bits == 64) {
            return SampleFormat::float_64;
        }
        return fail(ErrorCode::unsupported, "aiff: unsupported float width");
    }
    switch (bits) {
    case 8:
        return SampleFormat::signed_8;
    case 16:
        return SampleFormat::signed_16;
    case 24:
        return SampleFormat::signed_24;
    case 32:
        return SampleFormat::signed_32;
    default:
        return fail(ErrorCode::unsupported, "aiff: unsupported PCM width");
    }
}

[[nodiscard]] auto build_layout(const Common& common, std::uint64_t data_offset,
                                std::uint64_t data_bytes) -> expected<Layout> {
    if (common.channels == 0 || common.rate == 0 || common.bits % 8 != 0) {
        return fail(ErrorCode::parse, "aiff: invalid COMM chunk");
    }
    const auto sample_format = resolve_sample_format(common.encoding, common.bits);
    if (!sample_format) {
        return std::unexpected(sample_format.error());
    }
    const auto bytes_per_frame =
        static_cast<std::uint16_t>(common.channels * static_cast<std::uint16_t>(common.bits / 8));
    const std::uint64_t sound_frames = data_bytes / bytes_per_frame;

    Layout layout;
    layout.format = PcmFormat{.sample_format = *sample_format,
                              .channels = common.channels,
                              .sample_rate = common.rate,
                              .bits_per_sample = common.bits,
                              .bytes_per_frame = bytes_per_frame};
    layout.encoding = common.encoding;
    layout.data_offset = data_offset;
    layout.frames = std::min<std::uint64_t>(common.frames, sound_frames);
    if (common.frames > sound_frames) {
        layout.damage = Damage::truncated_aiff;
    }
    return layout;
}

[[nodiscard]] auto read_layout(const storage::ReadableSource& source) -> expected<Layout> {
    std::array<std::byte, 12> form{};
    const auto form_read = source.read_at(0, form);
    if (!form_read || *form_read != form.size()) {
        return fail(ErrorCode::parse, "aiff: truncated FORM header");
    }
    if (std::memcmp(form.data(), "FORM", 4) != 0) {
        return fail(ErrorCode::parse, "aiff: not a FORM file");
    }
    const bool compressed = std::memcmp(form.data() + 8, "AIFC", 4) == 0;
    if (!compressed && std::memcmp(form.data() + 8, "AIFF", 4) != 0) {
        return fail(ErrorCode::parse, "aiff: unknown FORM type");
    }

    std::optional<Common> common;
    std::optional<std::uint64_t> data_offset;
    std::uint64_t data_bytes = 0;
    std::uint64_t offset = 12;
    while (offset + 8 <= source.size()) {
        const auto header = read_chunk_header(source, offset);
        if (!header) {
            return std::unexpected(header.error());
        }
        const std::uint64_t body = header->body;
        const std::uint32_t size = header->size;
        if (body + size > source.size()) {
            return fail(ErrorCode::parse, "aiff: chunk past end");
        }
        if (std::memcmp(header->kind.data(), "COMM", 4) == 0) {
            const auto parsed = parse_common(source, body, size, compressed);
            if (!parsed) {
                return std::unexpected(parsed.error());
            }
            common = *parsed;
        } else {
            if (std::memcmp(header->kind.data(), "SSND", 4) == 0) {
                const auto parsed = parse_ssnd(source, body, size);
                if (!parsed) {
                    return std::unexpected(parsed.error());
                }
                data_offset = parsed->first;
                data_bytes = parsed->second;
            }
        }
        offset = body + size + (size & 1U);
    }

    if (!common) {
        return fail(ErrorCode::parse, "aiff: missing COMM chunk");
    }
    if (!data_offset) {
        return fail(ErrorCode::parse, "aiff: missing SSND chunk");
    }
    return build_layout(*common, *data_offset, data_bytes);
}

[[nodiscard]] auto read_integer(Encoding encoding, std::span<const std::byte> bytes)
    -> std::int32_t {
    ORCA_ASSERT(!bytes.empty());
    const bool little = encoding == Encoding::little_integer;
    const auto read16 = [little](std::span<const std::byte> data) -> std::int16_t {
        const std::uint16_t value =
            little ? static_cast<std::uint16_t>(std::to_integer<std::uint16_t>(data[0]) |
                                                (std::to_integer<std::uint16_t>(data[1]) << 8U))
                   : big16(data, 0);
        return static_cast<std::int16_t>(value);
    };
    const auto read24 = [little](std::span<const std::byte> data) -> std::int32_t {
        std::uint32_t value = 0;
        if (little) {
            value = std::to_integer<std::uint32_t>(data[0]) |
                    (std::to_integer<std::uint32_t>(data[1]) << 8U) |
                    (std::to_integer<std::uint32_t>(data[2]) << 16U);
        } else {
            value = (std::to_integer<std::uint32_t>(data[0]) << 16U) |
                    (std::to_integer<std::uint32_t>(data[1]) << 8U) |
                    std::to_integer<std::uint32_t>(data[2]);
        }
        if ((value & 0x800000U) != 0U) {
            value |= 0xff000000U;
        }
        return static_cast<std::int32_t>(value);
    };
    const auto read32 = [little](std::span<const std::byte> data) -> std::int32_t {
        if (little) {
            const std::uint32_t value = std::to_integer<std::uint32_t>(data[0]) |
                                        (std::to_integer<std::uint32_t>(data[1]) << 8U) |
                                        (std::to_integer<std::uint32_t>(data[2]) << 16U) |
                                        (std::to_integer<std::uint32_t>(data[3]) << 24U);
            return static_cast<std::int32_t>(value);
        }
        return static_cast<std::int32_t>(big32(data, 0));
    };

    switch (bytes.size()) {
    case 1:
        return static_cast<std::int32_t>(
                   static_cast<std::int8_t>(std::to_integer<std::uint8_t>(bytes[0])))
               << 24;
    case 2:
        return static_cast<std::int32_t>(read16(bytes)) << 16;
    case 3:
        return read24(bytes) << 8;
    default:
        return read32(bytes);
    }
}

[[nodiscard]] auto read_sample(Encoding encoding, std::span<const std::byte> bytes) -> float {
    if (encoding == Encoding::big_float) {
        if (bytes.size() == 4) {
            const std::uint32_t raw = big32(bytes, 0);
            float value = 0.0F;
            std::memcpy(&value, &raw, sizeof(value));
            return value;
        }
        const std::uint64_t raw = big64(bytes, 0);
        double value = 0.0;
        std::memcpy(&value, &raw, sizeof(value));
        return static_cast<float>(value);
    }
    return static_cast<float>(read_integer(encoding, bytes)) / 2147483648.0F;
}

class AiffDecoder final : public Decoder {
public:
    explicit AiffDecoder(const storage::ReadableSource& source, Layout layout)
        : source_(&source), layout_(layout) {
        const std::uint64_t frames = layout_.frames;
        const std::size_t scratch_frames = static_cast<std::size_t>(
            std::max<std::uint64_t>(1, std::min<std::uint64_t>(max_scratch_frames, frames)));
        scratch_.resize(scratch_frames * layout_.format.bytes_per_frame);
        codec = layout_.encoding == Encoding::big_float ? "pcm_float" : "pcm";
        source_format = layout_.format;
        format =
            PcmFormat{.sample_format = SampleFormat::float_32,
                      .channels = layout_.format.channels,
                      .sample_rate = layout_.format.sample_rate,
                      .bits_per_sample = 32,
                      .bytes_per_frame = static_cast<std::uint16_t>(layout_.format.channels * 4)};
        frame_count = frames;
    }

    [[nodiscard]] auto has_integer_samples() const -> bool override {
        return layout_.encoding != Encoding::big_float;
    }

    [[nodiscard]] auto read_frames_impl(std::span<float> output) -> expected<std::size_t> override {
        return read_as<float>(output, false);
    }

    [[nodiscard]] auto read_frames_i32_impl(std::span<std::int32_t> output)
        -> expected<std::size_t> override {
        if (layout_.encoding == Encoding::big_float) {
            return fail(ErrorCode::unsupported, "aiff: no integer samples for float PCM");
        }
        return read_as<std::int32_t>(output, true);
    }

    [[nodiscard]] auto seek(std::uint64_t frame) -> expected<void> override {
        position_ = std::min(frame, layout_.frames);
        return {};
    }

    [[nodiscard]] auto damage() const -> std::optional<Damage> override {
        return layout_.damage;
    }

private:
    template <typename Sample>
    [[nodiscard]] auto read_as(std::span<Sample> output, bool integer) -> expected<std::size_t> {
        ORCA_ASSERT(source_ != nullptr);
        ORCA_ASSERT(layout_.format.bytes_per_frame != 0);
        const std::uint16_t channels = layout_.format.channels;
        const std::uint64_t remaining = layout_.frames > position_ ? layout_.frames - position_ : 0;
        const std::size_t output_frames = output.size() / channels;
        const std::size_t scratch_frames = scratch_.size() / layout_.format.bytes_per_frame;
        const auto frame_limit = std::min({remaining, static_cast<std::uint64_t>(output_frames),
                                           static_cast<std::uint64_t>(scratch_frames)});
        const auto frames = static_cast<std::size_t>(frame_limit);
        if (frames == 0) {
            return std::size_t{0};
        }

        const std::uint64_t offset =
            layout_.data_offset + (position_ * layout_.format.bytes_per_frame);
        const auto read = source_->read_at(
            offset, std::span<std::byte>(scratch_.data(), frames * layout_.format.bytes_per_frame));
        if (!read) {
            return std::unexpected(read.error());
        }
        const std::size_t whole = *read / layout_.format.bytes_per_frame;
        const std::size_t width = layout_.format.bits_per_sample / 8;
        for (std::size_t index = 0; index < (whole * channels); ++index) {
            const auto slice = std::span<const std::byte>(scratch_.data() + (index * width), width);
            if (integer) {
                output[index] = static_cast<Sample>(read_integer(layout_.encoding, slice));
            } else {
                output[index] = static_cast<Sample>(read_sample(layout_.encoding, slice));
            }
        }
        position_ += whole;
        return whole;
    }

    const storage::ReadableSource* source_;
    Layout layout_;
    std::vector<std::byte> scratch_;
    std::uint64_t position_ = 0;
};

}

auto open_aiff(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
    const auto layout = read_layout(source);
    if (!layout) {
        return std::unexpected(layout.error());
    }
    return std::make_unique<AiffDecoder>(source, *layout);
}

}
