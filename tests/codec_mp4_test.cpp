#include "liborca/codec/alac.hpp"
#include "liborca/codec/decoder.hpp"
#include "liborca/codec/mp4.hpp"
#include "liborca/codec/registry.hpp"
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

auto open_track_fixture(std::string_view name)
    -> std::pair<std::unique_ptr<orca::storage::LocalFileSource>, orca::codec::Mp4Track> {
    auto opened = orca::storage::LocalFileSource::open(fixture(name));
    REQUIRE(opened.has_value());
    auto source = std::make_unique<orca::storage::LocalFileSource>(std::move(*opened));
    auto track = orca::codec::mp4_read_track(*source);
    REQUIRE(track.has_value());
    return {std::move(source), std::move(*track)};
}

auto decode_all(orca::codec::Decoder& decoder, std::span<float> output) -> std::size_t {
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

auto drain(orca::codec::Decoder& decoder) -> std::uint64_t {
    std::array<float, 4096> buffer{};
    const std::size_t usable = buffer.size() - buffer.size() % decoder.format.channels;
    std::uint64_t total = 0;
    while (true) {
        const auto read = decoder.read_frames(std::span<float>(buffer.data(), usable));
        REQUIRE(read.has_value());
        if (*read == 0) {
            return total;
        }
        total += *read;
    }
}

auto chirp_sample(std::size_t frame, std::size_t channel) -> float {
    const double t = static_cast<double>(frame) / 48000.0;
    const double phase = channel == 0 ? 200.0 * t + 2000.0 * t * t : 300.0 * t + 1500.0 * t * t;
    return static_cast<float>(0.4 * std::sin(2.0 * M_PI * phase));
}

auto chirp_error(std::span<const float> decoded, std::size_t first, std::size_t last,
                 std::int64_t lag) -> double {
    double sum = 0.0;
    for (std::size_t frame = first; frame < last; ++frame) {
        const auto source_frame = static_cast<std::size_t>(static_cast<std::int64_t>(frame) + lag);
        for (std::size_t channel = 0; channel < 2; ++channel) {
            const double difference = static_cast<double>(decoded[frame * 2 + channel]) -
                                      chirp_sample(source_frame, channel);
            sum += difference * difference;
        }
    }
    return sum / static_cast<double>((last - first) * 2);
}

}

TEST_CASE("an ALAC track exposes its configuration and packet table") {
    auto [source, track] = open_track_fixture("tagged-reference-alac.m4a");
    CHECK(track.codec == orca::codec::Mp4Codec::alac);
    CHECK(track.config.size() == 24);
    CHECK(track.channels == 2);
    CHECK(track.sample_rate == 44100);
    CHECK(track.timescale == 44100);
    CHECK(track.samples.size() == 3);
    REQUIRE(orca::codec::mp4_media_time(track).has_value());
    CHECK(*orca::codec::mp4_media_time(track) == 8820);
    CHECK(track.start_time == 0);
    REQUIRE(track.play_time.has_value());
    CHECK(*track.play_time == 8820);
}

TEST_CASE("an AAC track's edit list trims encoder priming to the source length") {
    auto [source, track] = open_track_fixture("tagged-reference-aac.m4a");
    CHECK(track.codec == orca::codec::Mp4Codec::aac);
    CHECK(track.config.size() >= 2);
    CHECK(track.timescale == 48000);
    CHECK(track.samples.size() == 11);
    CHECK(track.start_time == 1024);
    REQUIRE(track.play_time.has_value());
    CHECK(*track.play_time == 9600);
}

TEST_CASE("a packet is found by the media time it contains") {
    auto [source, track] = open_track_fixture("tagged-reference-aac.m4a");
    const auto first = orca::codec::mp4_packet_at(track, 0);
    REQUIRE(first.has_value());
    CHECK(first->index == 0);
    const auto later = orca::codec::mp4_packet_at(track, 2500);
    REQUIRE(later.has_value());
    CHECK(later->index == 2);
    CHECK(later->start == 2048);
}

TEST_CASE("packets sit inside the file and in order") {
    auto [source, track] = open_track_fixture("tagged-reference-aac.m4a");
    std::uint64_t previous_end = 0;
    for (const auto& sample : track.samples) {
        CHECK(sample.offset >= previous_end);
        previous_end = sample.offset + sample.size;
    }
    CHECK(previous_end <= source->size());
}

TEST_CASE("ALAC in MP4 decodes bit-identically to the FLAC it was encoded from") {
    auto [alac_source, alac_decoder] = open_fixture("tagged-reference-alac.m4a");
    auto [flac_source, flac_decoder] = open_fixture("tagged-reference.flac");

    std::vector<float> alac(10000 * 2);
    std::vector<float> flac(10000 * 2);
    const std::size_t alac_frames = decode_all(*alac_decoder, alac);
    const std::size_t flac_frames = decode_all(*flac_decoder, flac);
    CHECK(alac_frames == 8820);
    CHECK(flac_frames == alac_frames);
    CHECK(std::equal(alac.begin(), alac.begin() + static_cast<std::ptrdiff_t>(alac_frames * 2),
                     flac.begin()));
}

TEST_CASE("24-bit ALAC in MP4 decodes bit-identically to the FLAC it was encoded from") {
    auto [alac_source, alac_decoder] = open_fixture("hires-reference-alac.m4a");
    auto [flac_source, flac_decoder] = open_fixture("hires-reference.flac");

    std::vector<float> alac(4096 * 2);
    std::vector<float> flac(4096 * 2);
    const std::size_t alac_frames = decode_all(*alac_decoder, alac);
    const std::size_t flac_frames = decode_all(*flac_decoder, flac);
    CHECK(alac_frames == 4096);
    CHECK(flac_frames == alac_frames);
    CHECK(std::equal(alac.begin(), alac.begin() + static_cast<std::ptrdiff_t>(alac_frames * 2),
                     flac.begin()));
}

TEST_CASE("an ALAC decoder reports lossless source facts") {
    auto [source, decoder] = open_fixture("tagged-reference-alac.m4a");
    CHECK(decoder->codec == "alac");
    REQUIRE(decoder->source_format.has_value());
    CHECK(decoder->source_format->bits_per_sample == 16);
    CHECK(decoder->format.sample_rate == 44100);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 8820);
}

TEST_CASE("seeking into ALAC lands on the exact frame") {
    auto [whole_source, whole_decoder] = open_fixture("tagged-reference-alac.m4a");
    std::vector<float> whole(10000 * 2);
    const std::size_t whole_frames = decode_all(*whole_decoder, whole);
    REQUIRE(whole_frames == 8820);

    auto [source, decoder] = open_fixture("tagged-reference-alac.m4a");
    REQUIRE(decoder->seek(5000).has_value());
    std::vector<float> tail(10000 * 2);
    const std::size_t tail_frames = decode_all(*decoder, tail);
    CHECK(tail_frames == 3820);
    CHECK(std::equal(tail.begin(), tail.begin() + static_cast<std::ptrdiff_t>(tail_frames * 2),
                     whole.begin() + static_cast<std::ptrdiff_t>(5000 * 2)));
}

TEST_CASE("AAC in MP4 decodes to exactly the source length, trimmed of encoder priming") {
    auto [source, decoder] = open_fixture("tagged-reference-aac.m4a");
    CHECK(decoder->codec == "aac");
    CHECK_FALSE(decoder->source_format.has_value());
    CHECK(decoder->format.channels == 2);
    CHECK(decoder->format.sample_rate == 48000);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 9600);
    const auto frames = drain(*decoder);
    CHECK(frames == 9600);
}

TEST_CASE("the AAC front-padding rule keeps packets aligned to the sample table") {
    auto [source, decoder] = open_fixture("chirp-reference-aac.m4a");
    std::vector<float> decoded(12000 * 2);
    const std::size_t frames = decode_all(*decoder, decoded);
    REQUIRE(frames == 9600);

    const double aligned = chirp_error(decoded, 1000, 8000, 0);
    CHECK(aligned < 2e-4);
    CHECK(aligned * 3 < chirp_error(decoded, 1000, 8000, -1));
    CHECK(aligned * 3 < chirp_error(decoded, 1000, 8000, 1));
}

TEST_CASE("seeking into AAC lands on the requested frame") {
    auto [source, decoder] = open_fixture("chirp-reference-aac.m4a");
    REQUIRE(decoder->seek(4800).has_value());
    std::vector<float> tail(12000 * 2);
    const std::size_t frames = decode_all(*decoder, tail);
    REQUIRE(frames == 4800);
    double sum = 0.0;
    for (std::size_t frame = 0; frame < 4000; ++frame) {
        const double difference =
            static_cast<double>(tail[frame * 2]) - chirp_sample(4800 + frame, 0);
        sum += difference * difference;
    }
    CHECK(sum / 4000.0 < 2e-4);
}

TEST_CASE("the container probe reports exactly what the decoder does") {
    for (const std::string_view name : {"tagged-reference-alac.m4a", "tagged-reference-aac.m4a",
                                        "chirp-reference-aac.m4a", "covered-reference.m4a"}) {
        auto opened = orca::storage::LocalFileSource::open(fixture(name));
        REQUIRE(opened.has_value());
        const auto declared = orca::codec::mp4_probe(*opened);
        REQUIRE(declared.has_value());
        auto registry = orca::codec::CodecRegistry::builtins();
        auto decoder = registry.open_detected(*opened);
        REQUIRE(decoder.has_value());
        const auto decoded = orca::codec::properties(**decoder);
        REQUIRE(decoded.codec.has_value());
        REQUIRE(declared->codec.has_value());
        CHECK(*decoded.codec == *declared->codec);
        CHECK(decoded.sample_rate == declared->sample_rate);
        CHECK(decoded.channels == declared->channels);
        CHECK(decoded.bit_depth == declared->bit_depth);
        CHECK(decoded.duration_ms == declared->duration_ms);
    }
}

namespace {

void put_be32(std::vector<std::byte>& out, std::uint32_t value) {
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((value >> ((3 - index) * 8U)) & 0xffU));
    }
}

void put_be64(std::vector<std::byte>& out, std::uint64_t value) {
    for (std::size_t index = 0; index < 8; ++index) {
        out.push_back(static_cast<std::byte>((value >> ((7 - index) * 8U)) & 0xffU));
    }
}

auto be32(std::uint32_t value) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    put_be32(out, value);
    return out;
}

auto be64(std::uint64_t value) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    put_be64(out, value);
    return out;
}

auto test_box(std::string_view kind, std::span<const std::byte> body) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    put_be32(out, static_cast<std::uint32_t>(8 + body.size()));
    for (const char value : kind) {
        out.push_back(static_cast<std::byte>(value));
    }
    out.insert(out.end(), body.begin(), body.end());
    return out;
}

auto zeros(std::size_t count) -> std::vector<std::byte> {
    return std::vector<std::byte>(count, std::byte{0});
}

void append_zeros(std::vector<std::byte>& out, std::size_t count) {
    for (std::size_t index = 0; index < count; ++index) {
        out.push_back(std::byte{0});
    }
}

auto concat(std::vector<std::vector<std::byte>> parts) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    for (const auto& part : parts) {
        out.insert(out.end(), part.begin(), part.end());
    }
    return out;
}

struct TestMovie {
    std::uint32_t movie_timescale = 1000;
    std::uint32_t media_timescale = 44100;
    std::uint32_t sample_count = 3;
    std::uint32_t sample_size = 32;
    std::vector<std::pair<std::uint32_t, std::uint32_t>> time_runs = {{3, 4096}};
    std::vector<std::byte> chunk_offsets = test_box("stco", concat({zeros(4), be32(1), be32(0)}));
    std::vector<std::byte> edits;
    std::uint32_t frame_length = 4096;
    std::uint8_t bit_depth = 16;
    std::uint8_t channels = 2;
    std::uint8_t kb = 14;

    [[nodiscard]] auto bytes() const -> std::vector<std::byte> {
        const std::vector<std::byte> full_box = zeros(4);
        std::vector<std::byte> alac_config;
        put_be32(alac_config, frame_length);
        for (const std::uint8_t value :
             {std::uint8_t{0}, bit_depth, std::uint8_t{40}, std::uint8_t{10}, kb, channels}) {
            alac_config.push_back(static_cast<std::byte>(value));
        }
        {
            const auto mixed = be32(255U << 16U);
            alac_config.push_back(mixed[0]);
            alac_config.push_back(mixed[1]);
        }
        put_be32(alac_config, 0);
        put_be32(alac_config, 0);
        put_be32(alac_config, 44100);
        const auto inner = test_box("alac", concat({full_box, alac_config}));

        std::vector<std::byte> entry_body = zeros(6);
        entry_body.push_back(std::byte{0});
        entry_body.push_back(std::byte{1});
        append_zeros(entry_body, 8);
        entry_body.push_back(std::byte{0});
        entry_body.push_back(static_cast<std::byte>(channels));
        entry_body.push_back(std::byte{0});
        entry_body.push_back(std::byte{0x10});
        append_zeros(entry_body, 4);
        const auto rate = be32(44100U << 16U);
        entry_body.insert(entry_body.end(), rate.begin(), rate.end());
        entry_body.insert(entry_body.end(), inner.begin(), inner.end());
        const auto sample_entry = test_box("alac", entry_body);

        std::vector<std::byte> runs;
        for (const auto& [count, delta] : time_runs) {
            put_be32(runs, count);
            put_be32(runs, delta);
        }
        const auto table = concat({
            test_box("stsd", concat({full_box, be32(1), sample_entry})),
            test_box("stts",
                     concat({full_box, be32(static_cast<std::uint32_t>(time_runs.size())), runs})),
            test_box("stsz", concat({full_box, be32(sample_size), be32(sample_count)})),
            test_box("stsc", concat({full_box, be32(1), be32(1), be32(sample_count), be32(1)})),
            chunk_offsets,
        });
        std::vector<std::byte> hdlr_body = concat({full_box, zeros(4)});
        for (const char value : std::string_view("soun")) {
            hdlr_body.push_back(static_cast<std::byte>(value));
        }
        append_zeros(hdlr_body, 12);
        const auto media = concat({
            test_box("mdhd", concat({full_box, zeros(8), be32(media_timescale), zeros(8)})),
            test_box("hdlr", hdlr_body),
            test_box("minf", test_box("stbl", table)),
        });
        const auto movie_header =
            test_box("mvhd", concat({full_box, zeros(8), be32(movie_timescale), zeros(4)}));
        return test_box(
            "moov",
            concat({movie_header, test_box("trak", concat({edits, test_box("mdia", media)}))}));
    }
};

}

TEST_CASE("an ID3-tagged ADTS stream decodes every frame it holds") {
    auto [source, decoder] = open_fixture("tagged-reference.aac");
    CHECK(decoder->codec == "aac");
    CHECK(decoder->format.channels == 2);
    CHECK(decoder->format.sample_rate == 48000);
    REQUIRE(decoder->frame_count.has_value());
    CHECK(*decoder->frame_count == 11 * 1024);
    const auto frames = drain(*decoder);
    CHECK(frames == 11 * 1024);
}

TEST_CASE("the ADTS probe agrees with the decoder") {
    auto opened = orca::storage::LocalFileSource::open(fixture("tagged-reference.aac"));
    REQUIRE(opened.has_value());
    const auto declared = orca::codec::CodecRegistry::builtins().probe_detected(*opened);
    REQUIRE(declared.has_value());
    REQUIRE(declared->codec.has_value());
    CHECK(*declared->codec == "aac");
    CHECK(*declared->sample_rate == 48000);
    CHECK(*declared->channels == 2);
    CHECK(*declared->duration_ms == 11 * 1024 * 1000 / 48000);
}

TEST_CASE("ADTS decodes the same audio as the MP4 its frames were copied from") {
    auto [adts_source, adts] = open_fixture("tagged-reference.aac");
    auto [mp4_source, from_mp4] = open_fixture("chirp-reference-aac.m4a");
    REQUIRE(adts->codec == "aac");
    REQUIRE(from_mp4->codec == "aac");

    REQUIRE(adts->seek(1024).has_value());
    std::vector<float> adts_samples(4096 * 2);
    std::vector<float> mp4_samples(4096 * 2);
    CHECK(decode_all(*adts, adts_samples) == 4096);
    CHECK(decode_all(*from_mp4, mp4_samples) == 4096);
    CHECK(std::equal(adts_samples.begin(), adts_samples.end(), mp4_samples.begin()));
}

TEST_CASE("a hand-assembled movie reads as the track it declares") {
    const TestMovie movie;
    const auto bytes = movie.bytes();
    orca::storage::MemorySource source(bytes);
    auto track = orca::codec::mp4_read_track(source);
    REQUIRE(track.has_value());
    CHECK(track->samples.size() == 3);
    CHECK(track->samples[2].offset == 64);
    REQUIRE(orca::codec::mp4_media_time(*track).has_value());
    CHECK(*orca::codec::mp4_media_time(*track) == 3 * 4096);
}

TEST_CASE("a media time too long to count in frames is invalid rather than a crash") {
    TestMovie movie;
    movie.media_timescale = 1;
    movie.sample_count = 1U << 17;
    movie.time_runs = {{1U << 17, 0xffffffffU}};
    const auto bytes = movie.bytes();
    orca::storage::MemorySource source(bytes);
    CHECK_FALSE(orca::codec::mp4_open(source).has_value());
    CHECK_FALSE(orca::codec::mp4_probe(source).has_value());
}

TEST_CASE("a chunk offset that runs a packet past 2^64 is invalid") {
    TestMovie movie;
    movie.sample_count = 1;
    movie.time_runs = {{1, 4096}};
    movie.chunk_offsets =
        test_box("co64", concat({zeros(4), be32(1), be64(0xfffffffffffffff0ULL)}));
    const auto bytes = movie.bytes();
    orca::storage::MemorySource source(bytes);
    CHECK_FALSE(orca::codec::mp4_read_track(source).has_value());
}

TEST_CASE("an edit too long to convert to media time is invalid") {
    TestMovie movie;
    movie.movie_timescale = 1;
    movie.media_timescale = 96000;
    movie.edits = test_box(
        "edts", test_box("elst", concat({std::vector<std::byte>{std::byte{1}, std::byte{0},
                                                                std::byte{0}, std::byte{0}},
                                         be32(1), be64(0xffffffffffffffffULL), be64(0),
                                         std::vector<std::byte>{std::byte{0}, std::byte{1},
                                                                std::byte{0}, std::byte{0}}})));
    const auto bytes = movie.bytes();
    orca::storage::MemorySource source(bytes);
    CHECK_FALSE(orca::codec::mp4_read_track(source).has_value());
}

TEST_CASE("time runs whose total overflows a u64 are invalid") {
    orca::codec::Mp4Track track;
    track.time_runs = {{0xffffffffU, 0xffffffffU}, {3, 0xffffffffU}};
    CHECK_FALSE(orca::codec::mp4_media_time(track).has_value());
    CHECK_FALSE(orca::codec::mp4_packet_at(track, 0xffffffffffffffffULL).has_value());
}

TEST_CASE("a movie with no audio track is reported as such") {
    const auto movie_header = test_box("mvhd", concat({zeros(4), zeros(8), be32(1000), zeros(4)}));
    const auto bytes = test_box("moov", movie_header);
    orca::storage::MemorySource source(bytes);
    CHECK_FALSE(orca::codec::mp4_read_track(source).has_value());
}

namespace {

auto alac_packet_stream(const TestMovie& cookie, std::span<const std::byte> packet)
    -> std::vector<std::byte> {
    TestMovie movie = cookie;
    movie.sample_count = 1;
    movie.sample_size = static_cast<std::uint32_t>(packet.size());
    movie.time_runs = {{1, cookie.frame_length}};
    movie.chunk_offsets = test_box("stco", concat({zeros(4), be32(1), be32(8)}));
    auto bytes = test_box("mdat", packet);
    const auto movie_bytes = movie.bytes();
    bytes.insert(bytes.end(), movie_bytes.begin(), movie_bytes.end());
    return bytes;
}

void expect_alac_rejected(const TestMovie& cookie, std::span<const std::byte> packet) {
    const auto bytes = alac_packet_stream(cookie, packet);
    orca::storage::MemorySource source(bytes);
    auto decoder = orca::codec::mp4_open(source);
    REQUIRE(decoder.has_value());
    std::vector<float> output(static_cast<std::size_t>(cookie.frame_length) * cookie.channels);
    const auto read = (*decoder)->read_frames(output);
    CHECK_FALSE(read.has_value());
}

auto byte_list(std::initializer_list<unsigned> values) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    for (const unsigned value : values) {
        out.push_back(static_cast<std::byte>(value & 0xffU));
    }
    return out;
}

}

TEST_CASE("ALAC rejects a partial frame claiming more samples than the stream holds") {
    TestMovie monochrome;
    monochrome.channels = 1;
    const auto partial_low = byte_list({0x00, 0x00, 0x12, 0x00, 0x00, 0x20, 0x03, 0xc0});
    const auto partial_high = byte_list({0x00, 0x00, 0x12, 0x00, 0x02, 0x00, 0x01, 0xc0});
    const auto stereo_low = byte_list({0x20, 0x00, 0x12, 0x00, 0x00, 0x20, 0x03, 0xc0});
    const auto stereo_high = byte_list({0x20, 0x00, 0x12, 0x00, 0x02, 0x00, 0x01, 0xc0});
    expect_alac_rejected(monochrome, partial_low);
    expect_alac_rejected(monochrome, partial_high);
    expect_alac_rejected(TestMovie(), stereo_low);
    expect_alac_rejected(TestMovie(), stereo_high);
}

TEST_CASE("ALAC rejects an uncompressed frame whose samples run past the packet") {
    TestMovie monochrome;
    monochrome.channels = 1;
    expect_alac_rejected(monochrome, byte_list({0x00, 0x00, 0x02}));
    expect_alac_rejected(TestMovie(), byte_list({0x20, 0x00, 0x02}));
}

TEST_CASE("ALAC rejects a shift-off region that advances past the packet") {
    TestMovie mono24;
    mono24.channels = 1;
    mono24.bit_depth = 24;
    expect_alac_rejected(TestMovie(),
                         byte_list({0x20, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}));
    expect_alac_rejected(mono24, byte_list({0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00}));
}

TEST_CASE("ALAC rejects a packet that ends inside the element header") {
    TestMovie monochrome;
    monochrome.channels = 1;
    expect_alac_rejected(monochrome, byte_list({0x00}));
    expect_alac_rejected(TestMovie(), byte_list({0x20, 0x00}));
}

TEST_CASE("ALAC rejects a zero-length packet") {
    auto [source, track] = open_track_fixture("tagged-reference-alac.m4a");
    REQUIRE(track.codec == orca::codec::Mp4Codec::alac);
    auto engine = orca::codec::open_alac_engine(track.config);
    REQUIRE(engine.has_value());
    std::vector<std::int32_t> output(static_cast<std::size_t>((*engine)->max_packet_frames) *
                                     (*engine)->channels);
    CHECK_FALSE((*engine)->decode_i32(std::span<const std::byte>(), output).has_value());
}

TEST_CASE("ALAC decodes a frame shorter than its predictor order") {
    TestMovie cookie;
    cookie.channels = 1;
    cookie.frame_length = 16;
    std::vector<std::byte> packet = byte_list({0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x7c});
    packet.insert(packet.end(), 70, std::byte{0});
    const auto bytes = alac_packet_stream(cookie, packet);
    orca::storage::MemorySource source(bytes);
    auto decoder = orca::codec::mp4_open(source);
    REQUIRE(decoder.has_value());
    std::vector<float> output(16);
    CHECK(decode_all(**decoder, output) == 16);
}

TEST_CASE("ALAC rejects a cookie with an out-of-range field") {
    TestMovie frame_length_zero;
    frame_length_zero.frame_length = 0;
    TestMovie depth_eight;
    depth_eight.bit_depth = 8;
    TestMovie nine_channels;
    nine_channels.channels = 9;
    TestMovie kb_zero;
    kb_zero.kb = 0;
    TestMovie kb_high;
    kb_high.kb = 32;
    for (const TestMovie* cookie :
         {&frame_length_zero, &depth_eight, &nine_channels, &kb_zero, &kb_high}) {
        const auto bytes = cookie->bytes();
        orca::storage::MemorySource source(bytes);
        CHECK_FALSE(orca::codec::mp4_open(source).has_value());
    }
}

TEST_CASE("ALAC rejects a packet whose mix shift exceeds the sample width") {
    auto [source, track] = open_track_fixture("tagged-reference-alac.m4a");
    REQUIRE(orca::codec::mp4_media_time(track).has_value());
    const auto sample = track.samples.front();
    std::vector<std::byte> packet(sample.size);
    const auto read = source->read_at(sample.offset, packet);
    REQUIRE(read.has_value());
    REQUIRE(*read == packet.size());

    const auto mix_bits = static_cast<unsigned>(32);
    packet[2] =
        static_cast<std::byte>((std::to_integer<unsigned>(packet[2]) & 0xfeU) | (mix_bits >> 7U));
    packet[3] =
        static_cast<std::byte>((std::to_integer<unsigned>(packet[3]) & 0x01U) | (mix_bits << 1U));

    auto engine = orca::codec::open_alac_engine(track.config);
    REQUIRE(engine.has_value());
    std::vector<std::int32_t> output(static_cast<std::size_t>((*engine)->max_packet_frames) *
                                     (*engine)->channels);
    CHECK_FALSE((*engine)->decode_i32(packet, output).has_value());
}
