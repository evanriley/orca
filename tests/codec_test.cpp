#include "liborca/codec/decoder.hpp"
#include "liborca/codec/registry.hpp"
#include "liborca/codec/wav.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <doctest/doctest.h>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace {

auto fixture(std::string_view name) -> std::filesystem::path {
    return std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / name;
}

void append_le16(std::vector<std::byte>& out, std::uint16_t value) {
    out.push_back(static_cast<std::byte>(value & 0xffU));
    out.push_back(static_cast<std::byte>((value >> 8U) & 0xffU));
}

void append_le32(std::vector<std::byte>& out, std::uint32_t value) {
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((value >> (index * 8U)) & 0xffU));
    }
}

void append_be16(std::vector<std::byte>& out, std::uint16_t value) {
    out.push_back(static_cast<std::byte>((value >> 8U) & 0xffU));
    out.push_back(static_cast<std::byte>(value & 0xffU));
}

void append_be32(std::vector<std::byte>& out, std::uint32_t value) {
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((value >> ((3 - index) * 8U)) & 0xffU));
    }
}

void append_text(std::vector<std::byte>& out, std::string_view text) {
    for (const char value : text) {
        out.push_back(static_cast<std::byte>(value));
    }
}

auto stereo16_wav(std::span<const std::uint8_t> samples) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    append_text(out, "RIFF");
    append_le32(out, static_cast<std::uint32_t>(36 + samples.size() + (samples.size() & 1U)));
    append_text(out, "WAVE");
    append_text(out, "fmt ");
    append_le32(out, 16);
    append_le16(out, 1);
    append_le16(out, 2);
    append_le32(out, 44100);
    append_le32(out, 44100 * 4);
    append_le16(out, 4);
    append_le16(out, 16);
    append_text(out, "data");
    append_le32(out, static_cast<std::uint32_t>(samples.size()));
    for (const std::uint8_t value : samples) {
        out.push_back(static_cast<std::byte>(value));
    }
    if ((samples.size() & 1U) != 0U) {
        out.push_back(std::byte{0});
    }
    return out;
}

auto mono_aiff(std::uint32_t frames, std::uint16_t bits, std::span<const std::uint8_t> sound)
    -> std::vector<std::byte> {
    std::vector<std::byte> out;
    const std::uint32_t ssnd_bytes =
        sound.empty() ? 0 : static_cast<std::uint32_t>(8 + sound.size() + (sound.size() & 1U));
    append_text(out, "FORM");
    append_be32(out, 30 + ssnd_bytes);
    append_text(out, "AIFF");
    append_text(out, "COMM");
    append_be32(out, 18);
    append_be16(out, 1);
    append_be32(out, frames);
    append_be16(out, bits);
    const std::array<std::byte, 10> rate{
        std::byte{0x40}, std::byte{0x0e}, std::byte{0xac}, std::byte{0x44}, std::byte{0},
        std::byte{0},    std::byte{0},    std::byte{0},    std::byte{0},    std::byte{0}};
    out.insert(out.end(), rate.begin(), rate.end());
    if (!sound.empty()) {
        append_text(out, "SSND");
        append_be32(out, static_cast<std::uint32_t>(8 + sound.size()));
        append_be32(out, 0);
        append_be32(out, 0);
        for (const std::uint8_t value : sound) {
            out.push_back(static_cast<std::byte>(value));
        }
        if ((sound.size() & 1U) != 0U) {
            out.push_back(std::byte{0});
        }
    }
    return out;
}

auto open_source(orca::storage::MemorySource& source) -> std::unique_ptr<orca::codec::Decoder> {
    auto registry = orca::codec::CodecRegistry::builtins();
    auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());
    return std::move(decoder.value());
}

}

TEST_CASE("wav decodes bounded PCM frames from a generated file") {
    const std::array<std::uint8_t, 4> data{0x01, 0x00, 0xff, 0x7f};
    const auto bytes = stereo16_wav(data);
    orca::storage::MemorySource source(bytes);
    const auto decoder = open_source(source);

    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 1);
    CHECK(decoder->format.sample_rate == 44100);
    CHECK(decoder->format.channels == 2);

    std::array<float, 4> samples{};
    const auto read = decoder->read_frames(samples);
    REQUIRE(read.has_value());
    CHECK(*read == 1);
    CHECK(samples[0] == doctest::Approx(1.0F / 32768.0F));
    CHECK(samples[1] == doctest::Approx(32767.0F / 32768.0F));
}

TEST_CASE("wav reports a data chunk that ends inside a frame as damage") {
    const std::array<std::uint8_t, 10> data{1, 0, 2, 0, 3, 0, 4, 0, 5, 0};
    const auto bytes = stereo16_wav(data);
    orca::storage::MemorySource source(bytes);
    const auto decoder = open_source(source);

    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 2);
    std::array<float, 8> samples{};
    const auto read = decoder->read_frames(samples);
    REQUIRE(read.has_value());
    CHECK(*read == 2);
    const auto end = decoder->read_frames(samples);
    REQUIRE(end.has_value());
    CHECK(*end == 0);
    REQUIRE(decoder->damage().has_value());
    CHECK(*decoder->damage() == orca::codec::Damage::partial_wav_frame);
}

TEST_CASE("wav probe reports container-declared facts") {
    const auto source = orca::storage::LocalFileSource::open(fixture("generated-reference.wav"));
    REQUIRE(source.has_value());
    const auto registry = orca::codec::CodecRegistry::builtins();
    const auto properties = registry.probe_detected(*source);
    REQUIRE(properties.has_value());
    REQUIRE(properties->codec.has_value());
    CHECK(*properties->codec == "pcm");
    CHECK(*properties->sample_rate == 48000);
    CHECK(*properties->channels == 2);
    CHECK(*properties->bit_depth == 16);
    CHECK(*properties->duration_ms == 200);
}

TEST_CASE("aiff reports a tagged file's layout and length") {
    const auto source = orca::storage::LocalFileSource::open(fixture("tagged-reference.aiff"));
    REQUIRE(source.has_value());
    const auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(*source);
    REQUIRE(decoder.has_value());

    REQUIRE((*decoder)->frame_count.has_value());
    CHECK(*(*decoder)->frame_count == 8820);
    CHECK((*decoder)->format.sample_rate == 44100);
    REQUIRE((*decoder)->source_format.has_value());
    CHECK((*decoder)->source_format->bits_per_sample == 16);
    CHECK((*decoder)->source_format->sample_format == orca::codec::SampleFormat::signed_16);
}

TEST_CASE("integer aiff samples read left-justified and agree with the float read") {
    const std::array<std::uint8_t, 2> data{0x80, 0x40};
    const auto bytes = mono_aiff(2, 8, data);
    orca::storage::MemorySource source(bytes);
    const auto decoder = open_source(source);
    REQUIRE(decoder->has_integer_samples());

    std::array<float, 2> floats{};
    const auto read = decoder->read_frames(floats);
    REQUIRE(read.has_value());
    CHECK(*read == 2);
    CHECK(floats[0] == doctest::Approx(-1.0F));
    CHECK(floats[1] == doctest::Approx(0.5F));

    const auto seek = decoder->seek(0);
    REQUIRE(seek.has_value());
    std::array<std::int32_t, 2> integers{};
    const auto read_i32 = decoder->read_frames_i32(integers);
    REQUIRE(read_i32.has_value());
    CHECK(*read_i32 == 2);
    CHECK(orca::codec::integer_sample_to_float(integers[0]) == doctest::Approx(-1.0F));
    CHECK(orca::codec::integer_sample_to_float(integers[1]) == doctest::Approx(0.5F));
}

TEST_CASE("an aiff whose COMM declares more frames than SSND holds reports truncation") {
    const std::array<std::uint8_t, 8> data{0, 1, 0, 2, 0, 3, 0, 4};
    const auto bytes = mono_aiff(10, 16, data);
    orca::storage::MemorySource source(bytes);
    const auto decoder = open_source(source);

    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 4);
    std::array<float, 16> samples{};
    const auto read = decoder->read_frames(samples);
    REQUIRE(read.has_value());
    CHECK(*read == 4);
    const auto end = decoder->read_frames(samples);
    REQUIRE(end.has_value());
    CHECK(*end == 0);
    REQUIRE(decoder->damage().has_value());
    CHECK(*decoder->damage() == orca::codec::Damage::truncated_aiff);
}

TEST_CASE("an aiff whose SSND holds at least the COMM frames reports no damage") {
    for (const std::uint32_t frames : {4U, 3U}) {
        const std::array<std::uint8_t, 8> data{0, 1, 0, 2, 0, 3, 0, 4};
        const auto bytes = mono_aiff(frames, 16, data);
        orca::storage::MemorySource source(bytes);
        const auto decoder = open_source(source);
        REQUIRE(decoder->frame_count.has_value());
        CHECK(*decoder->frame_count == frames);
        CHECK_FALSE(decoder->damage().has_value());
    }
}

TEST_CASE("an aiff with no SSND chunk is refused as missing its sound") {
    const auto bytes = mono_aiff(10, 16, std::span<const std::uint8_t>());
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE_FALSE(decoder.has_value());
    CHECK(decoder.error().code == orca::ErrorCode::parse);
}

TEST_CASE("a seek at or past the frame count succeeds and the next read is end of stream") {
    const std::array<std::uint8_t, 4> data{1, 0, 2, 0};
    const auto bytes = stereo16_wav(data);
    orca::storage::MemorySource source(bytes);
    const auto decoder = open_source(source);
    REQUIRE(decoder->frame_count.has_value());
    const std::uint64_t total = *decoder->frame_count;

    std::array<float, 16> samples{};
    for (const std::uint64_t target : {total, total + 1, total + 100'000}) {
        REQUIRE(decoder->seek(0).has_value());
        const auto first = decoder->read_frames(samples);
        REQUIRE(first.has_value());
        CHECK(*first > 0);

        REQUIRE(decoder->seek(target).has_value());
        const auto end = decoder->read_frames(samples);
        REQUIRE(end.has_value());
        CHECK(*end == 0);
    }
}

namespace {

auto byte_span(std::initializer_list<unsigned> values) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    for (const unsigned value : values) {
        out.push_back(static_cast<std::byte>(value & 0xffU));
    }
    return out;
}

auto mono_aifc(std::uint32_t frames, std::uint16_t bits, std::string_view compression,
               std::span<const std::uint8_t> sound) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    const std::uint32_t ssnd_bytes =
        sound.empty() ? 0 : static_cast<std::uint32_t>(8 + sound.size() + (sound.size() & 1U));
    append_text(out, "FORM");
    append_be32(out, 4 + 8 + 22 + ssnd_bytes);
    append_text(out, "AIFC");
    append_text(out, "COMM");
    append_be32(out, 22);
    append_be16(out, 1);
    append_be32(out, frames);
    append_be16(out, bits);
    const std::array<std::byte, 10> rate{
        std::byte{0x40}, std::byte{0x0e}, std::byte{0xac}, std::byte{0x44}, std::byte{0},
        std::byte{0},    std::byte{0},    std::byte{0},    std::byte{0},    std::byte{0}};
    out.insert(out.end(), rate.begin(), rate.end());
    for (const char value : compression) {
        out.push_back(static_cast<std::byte>(value));
    }
    if (!sound.empty()) {
        append_text(out, "SSND");
        append_be32(out, static_cast<std::uint32_t>(8 + sound.size()));
        append_be32(out, 0);
        append_be32(out, 0);
        for (const std::uint8_t value : sound) {
            out.push_back(static_cast<std::byte>(value));
        }
        if ((sound.size() & 1U) != 0U) {
            out.push_back(std::byte{0});
        }
    }
    return out;
}

}

TEST_CASE("wav canonical conversion covers every sample form") {
    using orca::codec::SampleFormat;
    const auto sample = [](SampleFormat format, std::vector<std::byte> bytes) {
        return orca::codec::decode_sample(format, bytes);
    };
    CHECK(sample(SampleFormat::unsigned_8, byte_span({0x00})) == doctest::Approx(-1.0F));
    CHECK(sample(SampleFormat::unsigned_8, byte_span({0x80})) == doctest::Approx(0.0F));
    CHECK(sample(SampleFormat::signed_8, byte_span({0x80})) == doctest::Approx(-1.0F));
    CHECK(sample(SampleFormat::signed_16, byte_span({0x00, 0x80})) == doctest::Approx(-1.0F));
    CHECK(sample(SampleFormat::signed_24, byte_span({0x00, 0x00, 0x80})) == doctest::Approx(-1.0F));
    CHECK(sample(SampleFormat::signed_32, byte_span({0x00, 0x00, 0x00, 0x80})) ==
          doctest::Approx(-1.0F));
    CHECK(sample(SampleFormat::float_32, byte_span({0x00, 0x00, 0x00, 0x3f})) ==
          doctest::Approx(0.5F));
    CHECK(sample(SampleFormat::float_64, byte_span({0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0,
                                                    0x3f})) == doctest::Approx(0.5F));

    CHECK(orca::codec::decode_integer(SampleFormat::unsigned_8, byte_span({0x00})).value() ==
          std::numeric_limits<std::int32_t>::min());
    CHECK(orca::codec::decode_integer(SampleFormat::unsigned_8, byte_span({0xff})).value() ==
          0x7f000000);
    CHECK(orca::codec::decode_integer(SampleFormat::signed_16, byte_span({0xff, 0xff})).value() ==
          -0x10000);
    CHECK(orca::codec::decode_integer(SampleFormat::signed_16, byte_span({0x01, 0x00})).value() ==
          0x00010000);
    CHECK(orca::codec::decode_integer(SampleFormat::signed_24, byte_span({0xff, 0xff, 0xff}))
              .value() == -0x100);
    CHECK(orca::codec::decode_integer(SampleFormat::signed_24, byte_span({0xff, 0xff, 0x7f}))
              .value() == 0x7fffff00);
    CHECK(orca::codec::decode_integer(SampleFormat::signed_32, byte_span({0x01, 0x00, 0x00, 0x00}))
              .value() == 1);
    CHECK_FALSE(orca::codec::decode_integer(SampleFormat::float_32, byte_span({0, 0, 0, 0x3f}))
                    .has_value());

    for (const SampleFormat format :
         {SampleFormat::unsigned_8, SampleFormat::signed_8, SampleFormat::signed_16,
          SampleFormat::signed_24, SampleFormat::signed_32}) {
        const auto bytes = byte_span({0x35, 0x12, 0x7f, 0x01});
        const auto integer = orca::codec::decode_integer(format, bytes);
        REQUIRE(integer.has_value());
        CHECK(orca::codec::decode_sample(format, bytes) ==
              doctest::Approx(orca::codec::integer_sample_to_float(*integer)));
    }
}

TEST_CASE("a wav data chunk of whole frames reports no damage") {
    const std::array<std::uint8_t, 4> data{1, 0, 2, 0};
    const auto bytes = stereo16_wav(data);
    orca::storage::MemorySource source(bytes);
    const auto decoder = open_source(source);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 1);
    CHECK_FALSE(decoder->damage().has_value());
}

TEST_CASE("a compressed AIFC is refused rather than read as PCM") {
    const std::array<std::uint8_t, 4> data{0, 0, 0, 0};
    const auto bytes = mono_aifc(1, 16, "ima4", data);
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE_FALSE(decoder.has_value());
    CHECK(decoder.error().code == orca::ErrorCode::unsupported);
}

TEST_CASE("a wav whose declared frame size overflows uint16 is refused") {
    std::vector<std::byte> out;
    append_text(out, "RIFF");
    append_le32(out, 40);
    append_text(out, "WAVE");
    append_text(out, "fmt ");
    append_le32(out, 16);
    append_le16(out, 1);
    append_le16(out, 0xffff);
    append_le32(out, 44100);
    append_le32(out, 44100);
    append_le16(out, 1);
    append_le16(out, 32);
    append_text(out, "data");
    append_le32(out, 4);
    for (int index = 0; index < 4; ++index) {
        out.push_back(std::byte{0});
    }

    orca::storage::MemorySource source(out);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE_FALSE(decoder.has_value());
    CHECK(decoder.error().code == orca::ErrorCode::overflow);
}
