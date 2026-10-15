#include "liborca/codec/registry.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/codec/adts.hpp"
#include "liborca/codec/aiff.hpp"
#include "liborca/codec/flac.hpp"
#include "liborca/codec/mp3.hpp"
#include "liborca/codec/mp4.hpp"
#include "liborca/codec/opus.hpp"
#include "liborca/codec/qoa.hpp"
#include "liborca/codec/vorbis.hpp"
#include "liborca/codec/wav.hpp"

#include <memory>
#include <utility>

namespace orca::codec {

namespace {

class OwnedViewDecoder final : public Decoder {
public:
    OwnedViewDecoder(std::unique_ptr<storage::OffsetSource> view, std::unique_ptr<Decoder> inner)
        : view_(std::move(view)), inner_(std::move(inner)) {
        codec = inner_->codec;
        source_format = inner_->source_format;
        format = inner_->format;
        frame_count = inner_->frame_count;
    }

    [[nodiscard]] auto read_frames_impl(std::span<float> output) -> expected<std::size_t> override {
        return inner_->read_frames(output);
    }
    [[nodiscard]] auto read_frames_i32_impl(std::span<std::int32_t> output)
        -> expected<std::size_t> override {
        return inner_->read_frames_i32(output);
    }
    [[nodiscard]] auto has_integer_samples() const -> bool override {
        return inner_->has_integer_samples();
    }
    [[nodiscard]] auto seek(std::uint64_t frame) -> expected<void> override {
        return inner_->seek(frame);
    }
    [[nodiscard]] auto damage() const -> std::optional<Damage> override {
        return inner_->damage();
    }

private:
    std::unique_ptr<storage::OffsetSource> view_;
    std::unique_ptr<Decoder> inner_;
};

[[nodiscard]] auto make_prefixed(const storage::ReadableSource& source, std::uint64_t offset,
                                 const CodecRegistry& registry, storage::AudioFormat format)
    -> expected<std::unique_ptr<Decoder>> {
    auto view = std::make_unique<storage::OffsetSource>(source, offset);
    auto inner = registry.open(format, *view);
    if (!inner) {
        return std::unexpected(inner.error());
    }
    return std::make_unique<OwnedViewDecoder>(std::move(view), std::move(*inner));
}

}

auto properties(const Decoder& decoder) -> Properties {
    Properties result;
    if (!decoder.codec.empty()) {
        result.codec = decoder.codec;
    }
    const std::uint32_t rate = decoder.format.sample_rate;
    if (rate != 0) {
        result.sample_rate = rate;
    }
    if (decoder.format.channels != 0) {
        result.channels = decoder.format.channels;
    }
    if (decoder.source_format) {
        result.bit_depth = decoder.source_format->bits_per_sample;
    }
    if (rate != 0 && decoder.frame_count) {
        result.duration_ms = *decoder.frame_count * 1000 / rate;
    }
    return result;
}

auto CodecRegistry::register_codec(const Descriptor& descriptor) -> expected<void> {
    for (std::size_t index = 0; index < count_; ++index) {
        if (entries_[index].format == descriptor.format) {
            return fail(ErrorCode::already_exists, "codec: format already registered");
        }
    }
    if (count_ == entries_.size()) {
        return fail(ErrorCode::out_of_range, "codec: registry full");
    }
    entries_[count_] = descriptor;
    ++count_;
    return {};
}

auto CodecRegistry::open_exact(storage::AudioFormat format,
                               const storage::ReadableSource& source) const
    -> expected<std::unique_ptr<Decoder>> {
    for (std::size_t index = 0; index < count_; ++index) {
        if (entries_[index].format == format) {
            return entries_[index].open(source);
        }
    }
    return fail(ErrorCode::unsupported, "codec: no decoder for format");
}

auto CodecRegistry::open(storage::AudioFormat format, const storage::ReadableSource& source) const
    -> expected<std::unique_ptr<Decoder>> {
    const auto detected = storage::detect(source);
    if (detected && *detected && (*detected)->format == format &&
        (*detected)->payload_offset != 0) {
        return make_prefixed(source, (*detected)->payload_offset, *this, format);
    }
    return open_exact(format, source);
}

auto CodecRegistry::open_detected(const storage::ReadableSource& source) const
    -> expected<std::unique_ptr<Decoder>> {
    const auto detected = storage::detect(source);
    if (!detected) {
        return std::unexpected(detected.error());
    }
    if (!*detected) {
        return fail(ErrorCode::unsupported, "codec: unsupported audio format");
    }
    if ((*detected)->payload_offset == 0) {
        return open_exact((*detected)->format, source);
    }
    return make_prefixed(source, (*detected)->payload_offset, *this, (*detected)->format);
}

auto CodecRegistry::probe_container(storage::AudioFormat format,
                                    const storage::ReadableSource& source) const
    -> expected<std::optional<Properties>> {
    for (std::size_t index = 0; index < count_; ++index) {
        if (entries_[index].format != format) {
            continue;
        }
        const ProbeFn probe_fn = entries_[index].probe;
        if (probe_fn == nullptr) {
            return std::optional<Properties>{};
        }
        const auto detected = storage::detect(source);
        if (!detected) {
            return std::optional<Properties>{};
        }
        if (*detected && (*detected)->payload_offset != 0) {
            return std::optional<Properties>{};
        }
        const auto value = probe_fn(source);
        if (!value) {
            return std::unexpected(value.error());
        }
        return std::optional<Properties>(*value);
    }
    return std::optional<Properties>{};
}

auto CodecRegistry::probe(storage::AudioFormat format, const storage::ReadableSource& source) const
    -> expected<Properties> {
    const auto declared = probe_container(format, source);
    if (!declared) {
        return std::unexpected(declared.error());
    }
    if (*declared) {
        return **declared;
    }
    auto opened = open(format, source);
    if (!opened) {
        return std::unexpected(opened.error());
    }
    return properties(**opened);
}

auto CodecRegistry::probe_detected(const storage::ReadableSource& source) const
    -> expected<Properties> {
    const auto detected = storage::detect(source);
    if (detected && *detected) {
        const auto declared = probe_container((*detected)->format, source);
        if (!declared) {
            return std::unexpected(declared.error());
        }
        if (*declared) {
            return **declared;
        }
    }
    auto opened = open_detected(source);
    if (!opened) {
        return std::unexpected(opened.error());
    }
    return properties(**opened);
}

auto CodecRegistry::builtins() -> CodecRegistry {
    CodecRegistry registry;
    ORCA_CHECK(registry
                   .register_codec(Descriptor{
                       .name = "PCM WAV", .format = storage::AudioFormat::wav, .open = &open_wav})
                   .has_value());
    ORCA_CHECK(registry
                   .register_codec(Descriptor{
                       .name = "AIFF", .format = storage::AudioFormat::aiff, .open = &open_aiff})
                   .has_value());
    ORCA_CHECK(registry
                   .register_codec(Descriptor{.name = "AAC (ADTS)",
                                              .format = storage::AudioFormat::aac,
                                              .open = &open_adts,
                                              .probe = &probe_adts})
                   .has_value());
    ORCA_CHECK(registry
                   .register_codec(Descriptor{
                       .name = "FLAC", .format = storage::AudioFormat::flac, .open = &open_flac})
                   .has_value());
    ORCA_CHECK(registry
                   .register_codec(Descriptor{.name = "MPEG Audio",
                                              .format = storage::AudioFormat::mp3,
                                              .open = &open_mp3})
                   .has_value());
    ORCA_CHECK(registry
                   .register_codec(Descriptor{.name = "MP4 audio",
                                              .format = storage::AudioFormat::mp4,
                                              .open = &mp4_open,
                                              .probe = &mp4_probe})
                   .has_value());
    ORCA_CHECK(registry
                   .register_codec(Descriptor{.name = "Ogg Opus",
                                              .format = storage::AudioFormat::opus,
                                              .open = &open_opus})
                   .has_value());
    ORCA_CHECK(registry
                   .register_codec(Descriptor{.name = "Ogg Vorbis",
                                              .format = storage::AudioFormat::vorbis,
                                              .open = &open_vorbis})
                   .has_value());
    ORCA_CHECK(registry
                   .register_codec(Descriptor{.name = "Quite OK Audio",
                                              .format = storage::AudioFormat::qoa,
                                              .open = &open_qoa})
                   .has_value());
    return registry;
}

}
