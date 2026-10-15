#include "liborca/codec/codec_id.hpp"
#include "liborca/codec/decoder.hpp"
#include "liborca/codec/registry.hpp"
#include "liborca/codec/wav.hpp"
#include "liborca/storage/source.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <doctest/doctest.h>
#include <filesystem>
#include <memory>
#include <optional>
#include <random>
#include <span>
#include <string_view>
#include <vector>

namespace {

auto fixture(std::string_view name) -> std::filesystem::path {
    return std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / name;
}

auto open_fixture(std::string_view name)
    -> std::pair<std::unique_ptr<orca::storage::LocalFileSource>,
                 std::unique_ptr<orca::codec::Decoder>> {
    auto opened = orca::storage::LocalFileSource::open(fixture(name));
    REQUIRE(opened.has_value());
    auto source = std::make_unique<orca::storage::LocalFileSource>(std::move(*opened));
    auto registry = orca::codec::CodecRegistry::builtins();
    auto decoder = registry.open_detected(*source);
    REQUIRE(decoder.has_value());
    return {std::move(source), std::move(decoder.value())};
}

auto drain(orca::codec::Decoder& decoder) -> orca::expected<std::uint64_t> {
    std::array<float, 4096> buffer{};
    const std::size_t usable = buffer.size() - buffer.size() % decoder.format.channels;
    std::uint64_t total = 0;
    while (true) {
        const auto read = decoder.read_frames(std::span<float>(buffer.data(), usable));
        if (!read) {
            return std::unexpected(read.error());
        }
        if (*read == 0) {
            return total;
        }
        total += *read;
    }
}

auto read_fixture(std::string_view name) -> std::vector<std::byte> {
    auto source = orca::storage::LocalFileSource::open(fixture(name));
    REQUIRE(source.has_value());
    std::vector<std::byte> bytes(static_cast<std::size_t>(source->size()));
    const auto read = orca::storage::read_all(*source, 0, bytes);
    REQUIRE(read.has_value());
    REQUIRE(*read == bytes.size());
    return bytes;
}

auto mid_side_probe(std::uint32_t index) -> std::array<std::int16_t, 2> {
    std::uint32_t state = index * 2654435761U + 1U;
    state ^= state >> 13U;
    state *= 1274126177U;
    state ^= state >> 16U;
    const auto amplitude =
        static_cast<std::int16_t>(static_cast<std::int32_t>(state % 16000U) - 8000);
    return {amplitude, static_cast<std::int16_t>(1 - amplitude)};
}

auto hires_probe(std::uint32_t index) -> std::array<std::int32_t, 2> {
    const auto first = static_cast<std::int32_t>((index * 40961U) % (1U << 24)) - (1 << 23);
    const auto second = (1 << 23) - 1 - static_cast<std::int32_t>((index * 2654435761U) >> 8U);
    return {first, second};
}

auto mean_squared_error(std::span<const float> first, std::span<const float> second) -> double {
    double sum = 0.0;
    for (std::size_t index = 0; index < first.size(); ++index) {
        const double difference = static_cast<double>(first[index]) - second[index];
        sum += difference * difference;
    }
    return sum / static_cast<double>(first.size());
}

}

TEST_CASE("flac reports stream facts and seeks generated audio") {
    auto [source, decoder] = open_fixture("generated-reference.flac");
    REQUIRE(decoder->codec == "flac");
    REQUIRE(decoder->source_format.has_value());
    CHECK(decoder->source_format->sample_format == orca::codec::SampleFormat::signed_16);
    CHECK(decoder->format.channels == 2);
    CHECK(decoder->format.sample_rate == 48000);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 480);

    std::array<float, 64> samples{};
    const auto read = decoder->read_frames(samples);
    REQUIRE(read.has_value());
    CHECK(*read == 32);
    REQUIRE(decoder->seek(0).has_value());
    const auto again = decoder->read_frames(samples);
    REQUIRE(again.has_value());
    CHECK(*again == 32);
}

TEST_CASE("malformed flac metadata fails before decoder allocation") {
    std::vector<std::byte> bytes = {std::byte{'f'}, std::byte{'L'}, std::byte{'a'}, std::byte{'C'}};
    bytes.resize(26, std::byte{0});
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE_FALSE(decoder.has_value());
}

TEST_CASE("mid-side stereo flac decodes bit-exactly") {
    auto [source, decoder] = open_fixture("midside-reference.flac");
    const std::uint64_t total = decoder->frame_count.value_or(0);
    REQUIRE(total > 0);

    std::array<float, 2048> scratch{};
    std::uint32_t frame_index = 0;
    while (frame_index < total) {
        const auto read = decoder->read_frames(scratch);
        REQUIRE(read.has_value());
        REQUIRE(*read > 0);
        for (std::size_t offset = 0; offset < *read; ++offset) {
            const auto expected = mid_side_probe(frame_index + static_cast<std::uint32_t>(offset));
            for (std::size_t channel = 0; channel < 2; ++channel) {
                const double decoded = scratch[offset * 2 + channel] * 32768.0;
                CHECK(static_cast<std::int32_t>(std::llround(decoded)) == expected[channel]);
            }
        }
        frame_index += static_cast<std::uint32_t>(*read);
    }
    CHECK(frame_index == total);
}

TEST_CASE("24-bit 192 kHz flac decodes every sample exactly") {
    auto [source, decoder] = open_fixture("hires-reference.flac");
    REQUIRE(decoder->source_format.has_value());
    CHECK(decoder->source_format->sample_format == orca::codec::SampleFormat::signed_24);
    CHECK(decoder->source_format->bits_per_sample == 24);
    CHECK(decoder->format.sample_rate == 192000);
    CHECK(decoder->format.channels == 2);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 4096);

    std::array<float, 2048> scratch{};
    std::uint32_t frame_index = 0;
    while (true) {
        const auto read = decoder->read_frames(scratch);
        REQUIRE(read.has_value());
        if (*read == 0) {
            break;
        }
        for (std::size_t offset = 0; offset < *read; ++offset) {
            const auto expected = hires_probe(frame_index + static_cast<std::uint32_t>(offset));
            for (std::size_t channel = 0; channel < 2; ++channel) {
                CHECK(scratch[offset * 2 + channel] ==
                      static_cast<float>(expected[channel]) / static_cast<float>(1 << 23));
            }
        }
        frame_index += static_cast<std::uint32_t>(*read);
    }
    CHECK(frame_index == 4096);
}

TEST_CASE("a clean flac stream decodes to its declared total with no damage") {
    for (const std::string_view name :
         {"generated-reference.flac", "tagged-reference.flac", "midside-reference.flac",
          "covered-reference.flac", "lyrics-synced.flac", "id3-prefixed-reference.flac",
          "id3-footer-prefixed-reference.flac", "id3-covered-reference.flac"}) {
        auto [source, decoder] = open_fixture(name);
        REQUIRE(decoder->frame_count.has_value());
        const auto frames = drain(*decoder);
        REQUIRE(frames.has_value());
        CHECK(*frames == *decoder->frame_count);
        CHECK_FALSE(decoder->damage().has_value());
    }
}

TEST_CASE("a flac stream whose audio disagrees with its MD5 reports the mismatch") {
    auto bytes = read_fixture("tagged-reference.flac");
    bytes[26] = static_cast<std::byte>(std::to_integer<unsigned>(bytes[26]) ^ 0xffU);
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());
    const std::uint64_t total = (*decoder)->frame_count.value_or(0);
    const auto frames = drain(**decoder);
    REQUIRE(frames.has_value());
    CHECK(*frames == total);
    REQUIRE((*decoder)->damage().has_value());
    CHECK(*(*decoder)->damage() == orca::codec::Damage::flac_md5_mismatch);
}

TEST_CASE("a flac stream with no MD5 signature reports no damage") {
    auto bytes = read_fixture("tagged-reference.flac");
    std::fill(bytes.begin() + 26, bytes.begin() + 42, std::byte{0});
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());
    const auto frames = drain(**decoder);
    REQUIRE(frames.has_value());
    CHECK_FALSE((*decoder)->damage().has_value());
}

TEST_CASE("seeking a flac stream past its declared total reads zero frames") {
    auto [source, decoder] = open_fixture("generated-reference.flac");
    const std::uint64_t total = decoder->frame_count.value_or(0);
    std::array<float, 64> samples{};
    for (const std::uint64_t target : {total, total + 1, total + 100'000}) {
        REQUIRE(decoder->seek(target).has_value());
        const auto read = decoder->read_frames(samples);
        REQUIRE(read.has_value());
        CHECK(*read == 0);
    }
}

TEST_CASE("mp3 reports its declared format and decodes finite samples") {
    auto [source, decoder] = open_fixture("tagged-reference.mp3");
    REQUIRE(decoder->codec == "mp3");
    CHECK_FALSE(decoder->source_format.has_value());
    CHECK(decoder->format.sample_rate == 44100);
    CHECK(decoder->format.channels == 2);
    std::array<float, 2048> samples{};
    const std::size_t usable = samples.size() - samples.size() % decoder->format.channels;
    const auto read = decoder->read_frames(std::span<float>(samples.data(), usable));
    REQUIRE(read.has_value());
    CHECK(*read > 0);
    for (std::size_t index = 0; index < 16; ++index) {
        CHECK(std::isfinite(samples[index]));
    }
}

TEST_CASE("a Xing and LAME tagged mp3 decodes exactly its trimmed frame count") {
    auto [source, decoder] = open_fixture("vbr-xing-reference.mp3");
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 88200);
    const auto frames = drain(*decoder);
    REQUIRE(frames.has_value());
    CHECK(*frames == 88200);
}

TEST_CASE("a constant bitrate mp3 without a Xing header reports a length") {
    auto [source, decoder] = open_fixture("cbr-noxing-reference.mp3");
    REQUIRE(decoder->frame_count.has_value());
    const std::uint64_t estimated = *decoder->frame_count;
    const auto frames = drain(*decoder);
    REQUIRE(frames.has_value());
    CHECK(*frames + 1152 >= estimated);
    CHECK(estimated + 1152 >= *frames);
}

TEST_CASE("seeking a constant bitrate mp3 lands on the requested frame") {
    auto [source, decoder] = open_fixture("cbr-noxing-reference.mp3");
    const auto decoded = drain(*decoder);
    REQUIRE(decoded.has_value());
    const std::uint64_t target = *decoded / 2;
    REQUIRE(decoder->seek(target).has_value());
    const auto tail = drain(*decoder);
    REQUIRE(tail.has_value());
    CHECK(*tail == *decoded - target);
}

TEST_CASE("seeking a variable bitrate mp3 lands exactly on the requested frame") {
    auto [source, decoder] = open_fixture("vbr-xing-reference.mp3");
    const std::uint64_t total = decoder->frame_count.value_or(0);
    const std::uint64_t target = total / 3;
    REQUIRE(decoder->seek(target).has_value());
    const auto tail = drain(*decoder);
    REQUIRE(tail.has_value());
    CHECK(*tail == total - target);
}

TEST_CASE("seeking beyond a stream's declared length reads zero frames") {
    auto [source, decoder] = open_fixture("vbr-xing-reference.mp3");
    const std::uint64_t total = decoder->frame_count.value_or(0);
    REQUIRE(decoder->seek(total + 1).has_value());
    const auto tail = drain(*decoder);
    REQUIRE(tail.has_value());
    CHECK(*tail == 0);
}

TEST_CASE("a file holding no MPEG frame is refused") {
    std::array<std::byte, 4096> bytes{};
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE_FALSE(decoder.has_value());
}

TEST_CASE("a truncated mp3 ends its stream before the whole file does") {
    auto [whole_source, whole_decoder] = open_fixture("cbr-noxing-reference.mp3");
    const auto whole = drain(*whole_decoder);
    REQUIRE(whole.has_value());

    auto [source, decoder] = open_fixture("truncated-reference.mp3");
    const auto decoded = drain(*decoder);
    REQUIRE(decoded.has_value());
    CHECK(*decoded > 0);
    CHECK(*decoded < *whole);
}

TEST_CASE("an MPEG-1 Layer II stream decodes at its declared facts") {
    auto [source, decoder] = open_fixture("layer2-reference.mp2");
    REQUIRE(decoder->codec == "mp2");
    CHECK(decoder->format.sample_rate == 48000);
    CHECK(decoder->format.channels == 2);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 48384);
    const auto frames = drain(*decoder);
    REQUIRE(frames.has_value());
    CHECK(*frames == 48384);
}

TEST_CASE("qoa decodes to the length its header declares") {
    auto [source, decoder] = open_fixture("generated-reference.qoa");
    REQUIRE(decoder->codec == "qoa");
    REQUIRE(decoder->source_format.has_value());
    CHECK(decoder->source_format->sample_format == orca::codec::SampleFormat::signed_16);
    CHECK(decoder->format.channels == 1);
    CHECK(decoder->format.sample_rate == 48000);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 20);
    std::array<float, 20> samples{};
    const auto read = decoder->read_frames(samples);
    REQUIRE(read.has_value());
    CHECK(*read == 20);
    for (const float sample : samples) {
        CHECK(std::isfinite(sample));
    }
}

TEST_CASE("a malformed qoa frame size is refused") {
    std::vector<std::byte> bytes = {
        std::byte{'q'}, std::byte{'o'}, std::byte{'a'},  std::byte{'f'},
        std::byte{0},   std::byte{0},   std::byte{0},    std::byte{1},
        std::byte{1},   std::byte{0},   std::byte{0xbb}, std::byte{0x80},
        std::byte{0},   std::byte{1},   std::byte{0},    std::byte{1}};
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE_FALSE(decoder.has_value());
}

TEST_CASE("seeking into either qoa frame matches a sequential decode") {
    auto [source, decoder] = open_fixture("stereo-reference.qoa");
    const std::uint64_t total = decoder->frame_count.value_or(0);
    CHECK(total == 9600);

    std::vector<float> whole(static_cast<std::size_t>(total) * 2);
    auto cursor = std::span<float>(whole);
    std::size_t filled = 0;
    while (filled < whole.size()) {
        const auto read = decoder->read_frames(cursor.subspan(filled));
        REQUIRE(read.has_value());
        if (*read == 0) {
            break;
        }
        filled += *read * 2;
    }
    REQUIRE(filled == whole.size());

    std::vector<float> tail(whole.size());
    for (const std::uint64_t target : {std::uint64_t{0}, std::uint64_t{4999}, std::uint64_t{5120},
                                       std::uint64_t{7000}, std::uint64_t{9600}}) {
        REQUIRE(decoder->seek(target).has_value());
        std::size_t tail_filled = 0;
        while (tail_filled < tail.size()) {
            const auto read = decoder->read_frames(std::span<float>(tail).subspan(tail_filled));
            REQUIRE(read.has_value());
            if (*read == 0) {
                break;
            }
            tail_filled += *read * 2;
        }
        const std::size_t expected_samples = static_cast<std::size_t>(total - target) * 2;
        CHECK(tail_filled == expected_samples);
        CHECK(std::equal(tail.begin(), tail.begin() + static_cast<std::ptrdiff_t>(expected_samples),
                         whole.begin() + static_cast<std::ptrdiff_t>(target * 2)));
    }
    REQUIRE(decoder->seek(total + 1).has_value());
    const auto end = drain(*decoder);
    REQUIRE(end.has_value());
    CHECK(*end == 0);
}

TEST_CASE("an Ogg Opus stream decodes to exactly the length the encoder was given") {
    auto [source, decoder] = open_fixture("tagged-reference.opus");
    REQUIRE(decoder->codec == "opus");
    CHECK_FALSE(decoder->source_format.has_value());
    CHECK(decoder->format.channels == 2);
    CHECK(decoder->format.sample_rate == 48000);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 9600);
    const auto frames = drain(*decoder);
    REQUIRE(frames.has_value());
    CHECK(*frames == 9600);
}

TEST_CASE("seeking an Ogg Opus stream lands on the requested frame") {
    auto [source, decoder] = open_fixture("tagged-reference.opus");
    std::vector<float> whole(12000 * 2);
    std::size_t filled = 0;
    while (filled < whole.size()) {
        const auto read = decoder->read_frames(std::span<float>(whole).subspan(filled));
        REQUIRE(read.has_value());
        if (*read == 0) {
            break;
        }
        filled += *read * 2;
    }

    REQUIRE(decoder->seek(4800).has_value());
    std::vector<float> tail(12000 * 2);
    std::size_t tail_filled = 0;
    while (tail_filled < tail.size()) {
        const auto read = decoder->read_frames(std::span<float>(tail).subspan(tail_filled));
        REQUIRE(read.has_value());
        if (*read == 0) {
            break;
        }
        tail_filled += *read * 2;
    }
    REQUIRE(tail_filled == 4800 * 2);

    const std::size_t settled = 2000;
    const auto aligned = mean_squared_error(
        std::span<const float>(tail.data() + settled * 2, (4000 - settled) * 2),
        std::span<const float>(whole.data() + (4800 + settled) * 2, (4000 - settled) * 2));
    const auto early = mean_squared_error(
        std::span<const float>(tail.data() + settled * 2, (4000 - settled) * 2),
        std::span<const float>(whole.data() + (4799 + settled) * 2, (4000 - settled) * 2));
    const auto late = mean_squared_error(
        std::span<const float>(tail.data() + settled * 2, (4000 - settled) * 2),
        std::span<const float>(whole.data() + (4801 + settled) * 2, (4000 - settled) * 2));
    CHECK(aligned * 4 < early);
    CHECK(aligned * 4 < late);
}

TEST_CASE("bytes that are not Ogg Opus fail to open") {
    orca::storage::MemorySource source("OggS but nothing after it");
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE_FALSE(decoder.has_value());
}

TEST_CASE("an Ogg Vorbis stream decodes to exactly the length the encoder was given") {
    auto [source, decoder] = open_fixture("tagged-reference.ogg");
    REQUIRE(decoder->codec == "vorbis");
    CHECK_FALSE(decoder->source_format.has_value());
    CHECK(decoder->format.channels == 2);
    CHECK(decoder->format.sample_rate == 44100);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 8820);
    const auto frames = drain(*decoder);
    REQUIRE(frames.has_value());
    CHECK(*frames == 8820);
}

TEST_CASE("seeking an Ogg Vorbis stream lands on the requested frame") {
    auto [source, decoder] = open_fixture("tagged-reference.ogg");
    std::vector<float> whole(10000 * 2);
    std::size_t filled = 0;
    while (filled < whole.size()) {
        const auto read = decoder->read_frames(std::span<float>(whole).subspan(filled));
        REQUIRE(read.has_value());
        if (*read == 0) {
            break;
        }
        filled += *read * 2;
    }

    REQUIRE(decoder->seek(4410).has_value());
    std::vector<float> tail(10000 * 2);
    std::size_t tail_filled = 0;
    while (tail_filled < tail.size()) {
        const auto read = decoder->read_frames(std::span<float>(tail).subspan(tail_filled));
        REQUIRE(read.has_value());
        if (*read == 0) {
            break;
        }
        tail_filled += *read * 2;
    }
    REQUIRE(tail_filled == 4410 * 2);
    for (std::size_t index = 0; index < tail_filled; ++index) {
        CHECK(tail[index] == doctest::Approx(whole[4410 * 2 + index]).epsilon(1e-4));
    }
}

TEST_CASE("bytes that are not Ogg Vorbis fail to open") {
    orca::storage::MemorySource source("OggS but nothing after it");
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE_FALSE(decoder.has_value());
}

namespace {

auto big64_at(const std::vector<std::byte>& bytes, std::size_t offset) -> std::uint64_t {
    std::uint64_t value = 0;
    for (std::size_t index = 0; index < 8; ++index) {
        value = (value << 8U) | std::to_integer<std::uint64_t>(bytes[offset + index]);
    }
    return value;
}

void declare_extra_frames(std::vector<std::byte>& bytes, std::uint64_t shortfall) {
    const std::uint64_t packed = big64_at(bytes, 18);
    const std::uint64_t declared = packed & 0x0000000fffffffffULL;
    const std::uint64_t inflated =
        (packed & ~0x0000000fffffffffULL) | ((declared + shortfall) & 0x0000000fffffffffULL);
    for (std::size_t index = 0; index < 8; ++index) {
        bytes[18 + index] = static_cast<std::byte>((inflated >> (8 * (7 - index))) & 0xffU);
    }
}

auto read_fixture_bytes(std::string_view name) -> std::vector<std::byte> {
    return read_fixture(name);
}

}

TEST_CASE("flac reads to the end after a seek rather than failing") {
    auto [source, decoder] = open_fixture("generated-reference.flac");
    const std::uint64_t total = decoder->frame_count.value_or(0);
    REQUIRE(total > 1);
    REQUIRE(decoder->seek(total - 1).has_value());
    const auto frames = drain(*decoder);
    REQUIRE(frames.has_value());
    std::array<float, 64> samples{};
    const auto extra = decoder->read_frames(samples);
    REQUIRE(extra.has_value());
    CHECK(*extra == 0);
}

TEST_CASE("a flac stream that stops inside its final block reports truncation") {
    auto bytes = read_fixture_bytes("tagged-reference.flac");
    declare_extra_frames(bytes, 1);
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());
    const auto frames = drain(**decoder);
    REQUIRE(frames.has_value());
    REQUIRE((*decoder)->damage().has_value());
    CHECK(*(*decoder)->damage() == orca::codec::Damage::truncated_flac);
}

TEST_CASE("a flac stream missing more than its final block fails instead of ending cleanly") {
    auto bytes = read_fixture_bytes("tagged-reference.flac");
    declare_extra_frames(bytes, 1'000'000);
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());
    std::array<float, 4096> samples{};
    bool errored = false;
    for (std::size_t guard = 0; guard < 4096; ++guard) {
        const auto read = (*decoder)->read_frames(samples);
        if (!read) {
            errored = true;
            break;
        }
        if (*read == 0) {
            break;
        }
    }
    CHECK(errored);
}

TEST_CASE("a flac stream seeked into after a large shortfall still ends cleanly") {
    auto bytes = read_fixture_bytes("tagged-reference.flac");
    declare_extra_frames(bytes, 1'000'000);
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());
    REQUIRE((*decoder)->seek(1).has_value());
    const auto frames = drain(**decoder);
    CHECK(frames.has_value());
}

TEST_CASE("a flac final frame failing its CRC reports stream errors") {
    auto bytes = read_fixture_bytes("tagged-reference.flac");
    bytes.back() = static_cast<std::byte>(std::to_integer<unsigned>(bytes.back()) ^ 0xffU);
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());
    const auto frames = drain(**decoder);
    REQUIRE(frames.has_value());
    CHECK(*frames > 0);
    REQUIRE((*decoder)->damage().has_value());
    CHECK(*(*decoder)->damage() == orca::codec::Damage::flac_stream_errors);
}

TEST_CASE("mp3 seeking back to zero replays the opening samples byte for byte") {
    auto [source, decoder] = open_fixture("cbr-noxing-reference.mp3");
    std::array<float, 512> first{};
    std::array<float, 512> again{};
    const std::size_t usable = first.size() - first.size() % decoder->format.channels;
    REQUIRE(decoder->read_frames(std::span<float>(first.data(), usable)).has_value());
    REQUIRE(decoder->read_frames(std::span<float>(again.data(), usable)).has_value());
    REQUIRE(decoder->seek(0).has_value());
    REQUIRE(decoder->read_frames(std::span<float>(again.data(), usable)).has_value());
    CHECK(std::equal(first.begin(), first.begin() + static_cast<std::ptrdiff_t>(usable),
                     again.begin()));
}

TEST_CASE("a sought variable bitrate mp3 yields the samples of a sequential decode") {
    auto [source, decoder] = open_fixture("vbr-xing-reference.mp3");
    const std::size_t channels = decoder->format.channels;
    const std::size_t total = static_cast<std::size_t>(decoder->frame_count.value_or(0));
    std::vector<float> whole(total * channels);
    std::size_t decoded = 0;
    while (decoded < total) {
        const auto read = decoder->read_frames(std::span<float>(whole).subspan(decoded * channels));
        REQUIRE(read.has_value());
        if (*read == 0) {
            break;
        }
        decoded += *read;
    }
    REQUIRE(decoded == total);

    const std::size_t target = total / 3;
    REQUIRE(decoder->seek(target).has_value());
    std::array<float, 1024> tail{};
    const std::size_t usable = tail.size() - tail.size() % channels;
    const auto read = decoder->read_frames(std::span<float>(tail.data(), usable));
    REQUIRE(read.has_value());
    CHECK(*read == usable / channels);
    CHECK(std::equal(tail.begin(), tail.begin() + static_cast<std::ptrdiff_t>(usable),
                     whole.begin() + static_cast<std::ptrdiff_t>(target * channels)));
}

TEST_CASE("a stream cut off mid-frame still seeks and stops at its real end") {
    auto [source, decoder] = open_fixture("truncated-reference.mp3");
    const auto decoded = drain(*decoder);
    REQUIRE(decoded.has_value());
    const std::uint64_t target = *decoded / 2;
    REQUIRE(decoder->seek(target).has_value());
    const auto tail = drain(*decoder);
    REQUIRE(tail.has_value());
    CHECK(*tail == *decoded - target);
}

TEST_CASE("a trailing ID3v1 tag does not cost the final frame of audio") {
    const auto original = read_fixture("vbr-xing-reference.mp3");
    std::vector<std::byte> tagged = original;
    tagged.resize(original.size() + 128, std::byte{0});
    tagged[original.size()] = std::byte{'T'};
    tagged[original.size() + 1] = std::byte{'A'};
    tagged[original.size() + 2] = std::byte{'G'};

    orca::storage::MemorySource plain_source(original);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto plain = registry.open_detected(plain_source);
    REQUIRE(plain.has_value());
    const auto plain_frames = drain(**plain);
    REQUIRE(plain_frames.has_value());

    orca::storage::MemorySource tagged_source(tagged);
    const auto appended = registry.open_detected(tagged_source);
    REQUIRE(appended.has_value());
    CHECK((*appended)->frame_count == (*plain)->frame_count);
    const auto appended_frames = drain(**appended);
    REQUIRE(appended_frames.has_value());
    CHECK(*appended_frames == *plain_frames);
}

TEST_CASE("corrupted MPEG payloads end or error without reading out of bounds") {
    const auto original = read_fixture("cbr-noxing-reference.mp3");
    std::vector<std::byte> corrupted = original;
    std::mt19937 random(0x5eed1234U);
    for (std::size_t round = 0; round < 24; ++round) {
        corrupted = original;
        for (std::size_t mutation = 0; mutation < 64; ++mutation) {
            const std::size_t at = random() % corrupted.size();
            corrupted[at] = static_cast<std::byte>(random() & 0xffU);
        }
        orca::storage::MemorySource source(corrupted);
        auto registry = orca::codec::CodecRegistry::builtins();
        auto decoder = registry.open_detected(source);
        if (!decoder) {
            continue;
        }
        const auto frames = drain(**decoder);
        if (!frames) {
            continue;
        }
        const auto seek = (*decoder)->seek((*decoder)->frame_count.value_or(0) / 2);
        if (!seek) {
            continue;
        }
        (void)drain(**decoder);
    }
}

namespace {

auto decode_into(orca::codec::Decoder& decoder, std::span<float> output) -> std::size_t {
    std::size_t frames = 0;
    while (frames * decoder.format.channels < output.size()) {
        const auto read = decoder.read_frames(output.subspan(frames * decoder.format.channels));
        REQUIRE(read.has_value());
        if (*read == 0) {
            break;
        }
        frames += *read;
    }
    return frames;
}

}

TEST_CASE("a WAVE_FORMAT_EXTENSIBLE file decodes as the format its SubFormat names") {
    auto [ext_source, extensible] = open_fixture("extensible-reference.wav");
    REQUIRE(extensible->source_format.has_value());
    CHECK(extensible->source_format->sample_format == orca::codec::SampleFormat::signed_24);
    REQUIRE(extensible->frame_count.has_value());
    CHECK(*extensible->frame_count == 480);

    auto [flac_source, flac] = open_fixture("generated-reference.flac");
    std::vector<float> from_wav(480 * 2);
    std::vector<float> from_flac(480 * 2);
    CHECK(decode_into(*extensible, from_wav) == 480);
    CHECK(decode_into(*flac, from_flac) == 480);
    CHECK(std::equal(from_wav.begin(), from_wav.end(), from_flac.begin()));
}

namespace {

auto flac_audio_offset(const std::vector<std::byte>& bytes) -> std::size_t {
    std::size_t offset = 4;
    while (offset + 4 <= bytes.size()) {
        const bool last = (std::to_integer<unsigned>(bytes[offset]) & 0x80U) != 0U;
        const std::uint32_t length = (std::to_integer<std::uint32_t>(bytes[offset + 1]) << 16U) |
                                     (std::to_integer<std::uint32_t>(bytes[offset + 2]) << 8U) |
                                     std::to_integer<std::uint32_t>(bytes[offset + 3]);
        offset += 4 + length;
        if (last) {
            return offset;
        }
    }
    return bytes.size();
}

}

TEST_CASE("a flac first frame failing its CRC plays later frames and fails naming stream errors") {
    auto bytes = read_fixture_bytes("tagged-reference.flac");
    const std::size_t audio = flac_audio_offset(bytes);
    const std::array<std::byte, 2> sync{std::byte{0xff}, std::byte{0xf8}};
    const auto found = std::search(bytes.begin() + static_cast<std::ptrdiff_t>(audio + 2),
                                   bytes.end(), sync.begin(), sync.end());
    REQUIRE(found != bytes.end());
    const std::size_t second_frame = static_cast<std::size_t>(std::distance(bytes.begin(), found));
    REQUIRE(second_frame > 0);
    bytes[second_frame - 1] =
        static_cast<std::byte>(std::to_integer<unsigned>(bytes[second_frame - 1]) ^ 0xffU);

    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());

    std::array<float, 4096> samples{};
    std::uint64_t frames = 0;
    bool errored = false;
    orca::ErrorCode code = orca::ErrorCode::none;
    for (std::size_t guard = 0; guard < 4096; ++guard) {
        const auto read = (*decoder)->read_frames(samples);
        if (!read) {
            errored = true;
            code = read.error().code;
            break;
        }
        if (*read == 0) {
            break;
        }
        frames += *read;
    }
    CHECK(errored);
    CHECK(code == orca::ErrorCode::flac_stream_errors);
    const auto first_block = (std::to_integer<std::uint32_t>(bytes[10]) << 8U) |
                             std::to_integer<std::uint32_t>(bytes[11]);
    REQUIRE((*decoder)->frame_count.has_value());
    CHECK(*(*decoder)->frame_count - first_block == frames);
}

namespace {

auto open_decoder_source(std::string_view name)
    -> std::pair<std::unique_ptr<orca::storage::LocalFileSource>,
                 std::unique_ptr<orca::codec::Decoder>> {
    return open_fixture(name);
}

}

TEST_CASE("the registry rejects a duplicate codec registration") {
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto duplicate =
        registry.register_codec(orca::codec::Descriptor{.name = "duplicate WAV",
                                                        .format = orca::storage::AudioFormat::wav,
                                                        .open = &orca::codec::open_wav});
    CHECK_FALSE(duplicate.has_value());
}

TEST_CASE("probing reports the facts a container declares and invents none") {
    auto registry = orca::codec::CodecRegistry::builtins();
    auto lossless_source = orca::storage::LocalFileSource::open(fixture("tagged-reference.flac"));
    REQUIRE(lossless_source.has_value());
    const auto flac = registry.probe_detected(*lossless_source);
    REQUIRE(flac.has_value());
    REQUIRE(flac->codec.has_value());
    CHECK(*flac->codec == "flac");
    CHECK(*flac->sample_rate == 44100);
    CHECK(*flac->channels == 2);
    CHECK(*flac->bit_depth == 16);
    CHECK(*flac->duration_ms == 200);

    auto lossy_source = orca::storage::LocalFileSource::open(fixture("vbr-xing-reference.mp3"));
    REQUIRE(lossy_source.has_value());
    const auto mp3 = registry.probe_detected(*lossy_source);
    REQUIRE(mp3.has_value());
    REQUIRE(mp3->codec.has_value());
    CHECK(*mp3->codec == "mp3");
    CHECK(*mp3->sample_rate == 44100);
    CHECK(*mp3->channels == 2);
    CHECK_FALSE(mp3->bit_depth.has_value());
    CHECK(*mp3->duration_ms == 2000);
}

TEST_CASE("probing a file no codec can open fails rather than reporting zeroes") {
    orca::storage::MemorySource source("fLaC not really a stream");
    auto registry = orca::codec::CodecRegistry::builtins();
    CHECK_FALSE(registry.probe_detected(source).has_value());
}

TEST_CASE("an ID3-prefixed flac decodes the same audio as the untagged stream") {
    auto [untagged_source, untagged] = open_decoder_source("generated-reference.flac");
    auto [prefixed_source, prefixed] = open_decoder_source("id3-prefixed-reference.flac");
    std::vector<float> expected(480 * 2);
    std::vector<float> actual(480 * 2);
    CHECK(decode_into(*untagged, expected) == 480);
    CHECK(decode_into(*prefixed, actual) == 480);
    CHECK(std::equal(expected.begin(), expected.end(), actual.begin()));
}

TEST_CASE("seeking inside an ID3-prefixed flac lands on the frame that was asked for") {
    auto [untagged_source, untagged] = open_decoder_source("generated-reference.flac");
    auto [prefixed_source, prefixed] = open_decoder_source("id3-prefixed-reference.flac");
    REQUIRE(untagged->seek(240).has_value());
    REQUIRE(prefixed->seek(240).has_value());
    std::vector<float> expected(128 * 2);
    std::vector<float> actual(128 * 2);
    CHECK(decode_into(*untagged, expected) == 128);
    CHECK(decode_into(*prefixed, actual) == 128);
    CHECK(std::equal(expected.begin(), expected.end(), actual.begin()));
}

TEST_CASE("probing an ID3-prefixed flac reports the flac stream's own properties") {
    auto source = orca::storage::LocalFileSource::open(fixture("id3-prefixed-reference.flac"));
    REQUIRE(source.has_value());
    const auto probed = orca::codec::CodecRegistry::builtins().probe_detected(*source);
    REQUIRE(probed.has_value());
    REQUIRE(probed->codec.has_value());
    CHECK(*probed->codec == "flac");
    CHECK(*probed->sample_rate == 48000);
    CHECK(*probed->channels == 2);
    CHECK(*probed->duration_ms == 10);
}

TEST_CASE("seeking to or past the end of any stream succeeds and the next read is end of stream") {
    for (const std::string_view name :
         {"generated-reference.wav", "tagged-reference.aiff", "sowt-reference.aifc",
          "generated-reference.flac", "hires-reference.flac", "id3-prefixed-reference.flac",
          "stereo-reference.qoa", "tagged-reference.mp3", "vbr-xing-reference.mp3",
          "cbr-noxing-reference.mp3", "tagged-reference.ogg", "tagged-reference.opus",
          "tagged-reference-aac.m4a", "tagged-reference-alac.m4a", "tagged-reference.aac"}) {
        auto [source, decoder] = open_decoder_source(name);
        REQUIRE(decoder->frame_count.has_value());
        const std::uint64_t total = *decoder->frame_count;
        std::array<float, 4096 * 2> samples{};
        for (const std::uint64_t target :
             {total, total + 1, total + 100'000, std::numeric_limits<std::uint64_t>::max()}) {
            REQUIRE(decoder->seek(0).has_value());
            const auto first = decoder->read_frames(samples);
            REQUIRE(first.has_value());
            CHECK(*first > 0);

            REQUIRE(decoder->seek(target).has_value());
            const auto end = decoder->read_frames(samples);
            REQUIRE(end.has_value());
            CHECK(*end == 0);
            const auto again = decoder->read_frames(samples);
            REQUIRE(again.has_value());
            CHECK(*again == 0);
            CHECK_FALSE(decoder->damage().has_value());
        }
        REQUIRE(decoder->seek(0).has_value());
        const auto restart = decoder->read_frames(samples);
        REQUIRE(restart.has_value());
        CHECK(*restart > 0);
    }
}

TEST_CASE("AIFF, sowt AIFC and 24-bit AIFF decode to the samples of the FLAC they came from") {
    auto [flac_source, flac] = open_decoder_source("generated-reference.flac");
    std::vector<float> reference(480 * 2);
    CHECK(decode_into(*flac, reference) == 480);
    for (const std::string_view name : {"sowt-reference.aifc", "generated-reference-24.aiff"}) {
        auto [source, decoder] = open_decoder_source(name);
        REQUIRE(decoder->source_format.has_value());
        CHECK(decoder->source_format->sample_rate == 48000);
        std::vector<float> decoded(480 * 2);
        CHECK(decode_into(*decoder, decoded) == 480);
        CHECK(std::equal(reference.begin(), reference.end(), decoded.begin()));
    }
}

TEST_CASE("a flac stream with a wrong MD5 signature reads cleanly when sought") {
    auto bytes = read_fixture_bytes("tagged-reference.flac");
    bytes[26] = static_cast<std::byte>(std::to_integer<unsigned>(bytes[26]) ^ 0xffU);
    orca::storage::MemorySource source(bytes);
    auto registry = orca::codec::CodecRegistry::builtins();
    const auto decoder = registry.open_detected(source);
    REQUIRE(decoder.has_value());
    REQUIRE((*decoder)->seek(0).has_value());
    REQUIRE((*decoder)->frame_count.has_value());
    const auto frames = drain(**decoder);
    REQUIRE(frames.has_value());
    CHECK(*frames == *(*decoder)->frame_count);
    CHECK_FALSE((*decoder)->damage().has_value());
}

TEST_CASE("a flac stream decoded to its end can be sought and decoded again") {
    auto [source, decoder] = open_decoder_source("tagged-reference.flac");
    REQUIRE(decoder->frame_count.has_value());
    const std::uint64_t total = *decoder->frame_count;
    const auto first = drain(*decoder);
    REQUIRE(first.has_value());
    CHECK(*first == total);
    REQUIRE(decoder->seek(100).has_value());
    const auto second = drain(*decoder);
    REQUIRE(second.has_value());
    CHECK(*second == total - 100);
}

TEST_CASE("a qoa stream decodes close to the audio it was encoded from") {
    auto [qoa_source, qoa] = open_decoder_source("stereo-reference.qoa");
    auto [wav_source, wav] = open_decoder_source("generated-reference.wav");
    std::vector<float> decoded(10000 * 2);
    std::vector<float> source_pcm(10000 * 2);
    CHECK(decode_into(*qoa, decoded) == 9600);
    CHECK(decode_into(*wav, source_pcm) == 9600);
    CHECK(mean_squared_error(std::span<const float>(decoded.data(), 9600 * 2),
                             std::span<const float>(source_pcm.data(), 9600 * 2)) < 1e-5);
}

TEST_CASE("every codec identifier is classified as lossless exactly once") {
    using namespace orca::codec::codec_id;
    CHECK(is_lossless(pcm));
    CHECK(is_lossless(pcm_float));
    CHECK(is_lossless(flac));
    CHECK_FALSE(is_lossless(qoa));
    CHECK_FALSE(is_lossless(mp1));
    CHECK_FALSE(is_lossless(mp2));
    CHECK_FALSE(is_lossless(mp3));
    CHECK(is_lossless(alac));
    CHECK_FALSE(is_lossless(aac));
    CHECK_FALSE(is_lossless(opus));
    CHECK_FALSE(is_lossless(vorbis));
    CHECK_FALSE(is_lossless(""));
}

TEST_CASE("every decoder rejects a buffer that is not whole frames") {
    for (const std::string_view name : {"generated-reference.wav", "generated-reference.flac",
                                        "tagged-reference.mp3", "stereo-reference.qoa"}) {
        auto [source, decoder] = open_decoder_source(name);
        REQUIRE(decoder->format.channels == 2);

        std::array<float, 3> odd_floats{};
        const auto float_read = decoder->read_frames(odd_floats);
        REQUIRE_FALSE(float_read.has_value());
        CHECK(float_read.error().code == orca::ErrorCode::invalid_argument);

        std::array<std::int32_t, 3> odd_integers{};
        const auto integer_read = decoder->read_frames_i32(odd_integers);
        REQUIRE_FALSE(integer_read.has_value());
        CHECK(integer_read.error().code == orca::ErrorCode::invalid_argument);

        std::array<float, 4> whole_frames{};
        CHECK(decoder->read_frames(whole_frames).has_value());
    }
}
