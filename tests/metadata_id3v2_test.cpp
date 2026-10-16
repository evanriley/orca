#include "liborca/metadata/id3v2.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <filesystem>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace {

template <std::size_t Size>
auto payload(const char (&text)[Size]) -> std::span<const std::byte> {
    return std::span<const std::byte>(reinterpret_cast<const std::byte*>(text), Size - 1);
}

auto build_frame(std::string_view id, std::uint8_t major, std::span<const std::byte> body)
    -> std::vector<std::byte> {
    std::vector<std::byte> out;
    for (const char value : id) {
        out.push_back(static_cast<std::byte>(value));
    }
    const std::uint32_t length = static_cast<std::uint32_t>(body.size());
    if (major >= 4) {
        out.push_back(static_cast<std::byte>((length >> 21U) & 0x7fU));
        out.push_back(static_cast<std::byte>((length >> 14U) & 0x7fU));
        out.push_back(static_cast<std::byte>((length >> 7U) & 0x7fU));
        out.push_back(static_cast<std::byte>(length & 0x7fU));
    } else {
        for (std::size_t index = 0; index < 4; ++index) {
            out.push_back(static_cast<std::byte>((length >> ((3 - index) * 8U)) & 0xffU));
        }
    }
    out.push_back(std::byte{0});
    out.push_back(std::byte{0});
    out.insert(out.end(), body.begin(), body.end());
    return out;
}

auto build_tag(std::uint8_t major, std::uint8_t flags, std::span<const std::byte> frames)
    -> std::vector<std::byte> {
    std::vector<std::byte> out;
    for (const char value : std::string_view("ID3")) {
        out.push_back(static_cast<std::byte>(value));
    }
    out.push_back(static_cast<std::byte>(major));
    out.push_back(std::byte{0});
    out.push_back(static_cast<std::byte>(flags));
    const std::uint32_t length = static_cast<std::uint32_t>(frames.size());
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((length >> ((3 - index) * 7U)) & 0x7fU));
    }
    out.insert(out.end(), frames.begin(), frames.end());
    return out;
}

auto expect_tags(orca::metadata::Arena& arena, std::span<const std::byte> tag)
    -> std::optional<orca::metadata::ObservedTags> {
    orca::storage::MemorySource source(tag);
    const auto tags = orca::metadata::id3v2::read(arena, source);
    REQUIRE(tags.has_value());
    return *tags;
}

auto read_lyrics_from(orca::metadata::Arena& arena, std::span<const std::byte> tag)
    -> std::optional<orca::metadata::lyrics::Content> {
    orca::storage::MemorySource source(tag);
    const auto content = orca::metadata::id3v2::read_lyrics(arena, source);
    REQUIRE(content.has_value());
    return *content;
}

}

TEST_CASE("ID3v2.4 frames map onto canonical fields without leaking frame identifiers") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto append = [&frames](std::string_view id, std::span<const std::byte> body) {
        const auto frame = build_frame(id, 4, body);
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append("TIT2", payload("\x03Reference Tone"));
    append("TPE1", payload("\x03Orca Test"));
    append("TPE2", payload("\x03Orca Ensemble"));
    append("TALB", payload("\x03"
                           "Fixtures"));
    append("TRCK", payload("\x03"
                           "2/9"));
    append("TPOS", payload("\x03"
                           "1/2"));
    append("TDRC", payload("\x03"
                           "2026-08-23"));
    append("TCMP", payload("\x03"
                           "1"));
    append("TCON", payload("\x03"
                           "Ambient\x00(9)"));
    append("TXXX", payload("\x03MusicBrainz Album Id\x00release-uuid"));
    const auto tag = build_tag(4, 0, frames);
    const auto tags = expect_tags(arena, tag);
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Reference Tone"));
    CHECK(tags->artist == std::optional<std::string_view>("Orca Test"));
    CHECK(tags->album_artist == std::optional<std::string_view>("Orca Ensemble"));
    CHECK(tags->album == std::optional<std::string_view>("Fixtures"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(2));
    CHECK(tags->track_total == std::optional<std::uint32_t>(9));
    CHECK(tags->disc_number == std::optional<std::uint32_t>(1));
    CHECK(tags->disc_total == std::optional<std::uint32_t>(2));
    CHECK(tags->date == std::optional<std::string_view>("2026-08-23"));
    CHECK(tags->compilation == std::optional<bool>(true));
    REQUIRE(tags->genres.size() == 2);
    CHECK(tags->genres[0] == "Ambient");
    CHECK(tags->genres[1] == "Metal");
    CHECK(tags->musicbrainz_release_id == std::optional<std::string_view>("release-uuid"));
}

TEST_CASE("ID3v2.3 sizes, Latin-1 text, and split date frames read correctly") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto append = [&frames](std::string_view id, std::span<const std::byte> body) {
        const auto frame = build_frame(id, 3, body);
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append("TIT2", payload("\x00"
                           "Caf\xe9"));
    append("TYER", payload("\x00"
                           "1999"));
    append("TDAT", payload("\x00"
                           "0112"));
    append("TRCK", payload("\x00"
                           "07"));
    const auto tag = build_tag(3, 0, frames);
    const auto tags = expect_tags(arena, tag);
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Caf\u00e9"));
    CHECK(tags->date == std::optional<std::string_view>("1999-12-01"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(7));
}

TEST_CASE("UTF-16 text frames decode from either byte order") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto append = [&frames](std::string_view id, std::uint8_t major,
                                  std::span<const std::byte> body) {
        const auto frame = build_frame(id, major, body);
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append("TIT2", 3, payload("\x01\xff\xfeS\x00o\x00l\x00"));
    append("TPE1", 3, payload("\x01\xfe\xff\x00M\x00o\x00o\x00n"));
    append("TALB", 4, payload("\x02\x00S\x00k\x00y"));
    const auto tag = build_tag(4, 0, frames);
    const auto tags = expect_tags(arena, tag);
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Sol"));
    CHECK(tags->artist == std::optional<std::string_view>("Moon"));
    CHECK(tags->album == std::optional<std::string_view>("Sky"));
}

TEST_CASE("unsynchronized tags are restored before frames are parsed") {
    orca::metadata::Arena arena;
    const auto frame = build_frame("TIT2", 3,
                                   payload("\x00\xff\xfe"
                                           "end"));
    std::vector<std::byte> unsynced;
    for (const std::byte byte : frame) {
        unsynced.push_back(byte);
        if (byte == std::byte{0xff}) {
            unsynced.push_back(std::byte{0});
        }
    }
    const auto tag = build_tag(3, 0x80, unsynced);
    const auto tags = expect_tags(arena, tag);
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("\u00ff\u00feend"));
}

TEST_CASE("extended headers are skipped in both supported versions") {
    orca::metadata::Arena arena;
    const auto frame3 = build_frame("TIT2", 3,
                                    payload("\x00"
                                            "After header"));
    std::vector<std::byte> v3 = {std::byte{0}, std::byte{0}, std::byte{0}, std::byte{6},
                                 std::byte{0}, std::byte{0}, std::byte{0}, std::byte{0},
                                 std::byte{0}, std::byte{0}};
    v3.insert(v3.end(), frame3.begin(), frame3.end());
    const auto v3_tags = expect_tags(arena, build_tag(3, 0x40, v3));
    REQUIRE(v3_tags.has_value());
    CHECK(v3_tags->title == std::optional<std::string_view>("After header"));

    const auto frame4 = build_frame("TIT2", 4,
                                    payload("\x00"
                                            "After header"));
    std::vector<std::byte> v4 = {std::byte{0}, std::byte{0}, std::byte{0},
                                 std::byte{6}, std::byte{1}, std::byte{0}};
    v4.insert(v4.end(), frame4.begin(), frame4.end());
    const auto v4_tags = expect_tags(arena, build_tag(4, 0x40, v4));
    REQUIRE(v4_tags.has_value());
    CHECK(v4_tags->title == std::optional<std::string_view>("After header"));
}

TEST_CASE("APIC artwork is reported by type and size without decoding image data") {
    orca::metadata::Arena arena;
    std::vector<std::byte> body;
    const auto header = payload("\x00image/jpeg\x00");
    body.insert(body.end(), header.begin(), header.end());
    body.push_back(std::byte{3});
    const auto description = payload("cover\x00");
    body.insert(body.end(), description.begin(), description.end());
    body.insert(body.end(), 64, std::byte{0x5a});
    const auto tag = build_tag(4, 0, build_frame("APIC", 4, body));
    const auto tags = expect_tags(arena, tag);
    REQUIRE(tags.has_value());
    REQUIRE(tags->artwork.has_value());
    CHECK(tags->artwork->mime_type == "image/jpeg");
    CHECK(tags->artwork->byte_size == 64);
    CHECK(tags->artwork->kind == orca::metadata::ArtworkKind::front_cover);
}

TEST_CASE("truncated and malformed ID3v2 tags are rejected without reading past the end") {
    orca::metadata::Arena arena;
    using orca::ErrorCode;
    const auto expect_error = [&arena](std::span<const std::byte> tag, ErrorCode code) {
        orca::storage::MemorySource source(tag);
        const auto tags = orca::metadata::id3v2::read(arena, source);
        REQUIRE_FALSE(tags.has_value());
        CHECK(tags.error().code == code);
    };
    const auto expect_null = [&arena](std::span<const std::byte> tag) {
        orca::storage::MemorySource source(tag);
        const auto tags = orca::metadata::id3v2::read(arena, source);
        REQUIRE(tags.has_value());
        CHECK_FALSE(tags->has_value());
    };
    expect_null(payload("ID3"));
    expect_null(payload("no tag here at all"));
    expect_null(payload("ID3\x02\x00\x00\x00\x00\x00\x0aTT2\x00\x00\x04\x00"
                        "abc"));
    expect_error(payload("ID3\xff\x00\x00\x00\x00\x00\x0a"), ErrorCode::invalid_id3v2_tag);
    expect_error(payload("ID3\x04\x00\x00\x00\x00\x80\x0a"), ErrorCode::invalid_id3v2_tag);
    expect_error(payload("ID3\x04\x00\x00\x00\x00\x01\x00short"), ErrorCode::truncated_id3v2_tag);

    auto frames = build_frame("TIT2", 4, payload("\x03Title"));
    frames[7] = std::byte{0x40};
    expect_error(build_tag(4, 0, frames), ErrorCode::truncated_id3v2_tag);

    std::vector<std::byte> mixed;
    const auto kept = build_frame("TIT2", 4, payload("\x03Kept"));
    mixed.insert(mixed.end(), kept.begin(), kept.end());
    const auto garbage = payload("\xfe\xfe\xfe\xfe\x00\x00\x00\x02\x00\x00zz");
    mixed.insert(mixed.end(), garbage.begin(), garbage.end());
    const auto tags = expect_tags(arena, build_tag(4, 0, mixed));
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Kept"));
}

TEST_CASE("tagged MP3 fixture reads its real ID3v2 frames") {
    orca::metadata::Arena arena;
    const auto path =
        std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / "tagged-reference.mp3";
    auto file = orca::storage::LocalFileSource::open(path);
    REQUIRE(file.has_value());
    const auto tags = orca::metadata::id3v2::read(arena, *file);
    REQUIRE(tags.has_value());
    REQUIRE(tags->has_value());
    CHECK((*tags)->title == std::optional<std::string_view>("Reference Tone"));
    CHECK((*tags)->artist == std::optional<std::string_view>("Orca Test"));
    CHECK((*tags)->album == std::optional<std::string_view>("Fixtures"));
    CHECK((*tags)->track_number == std::optional<std::uint32_t>(1));
    const auto prefix = orca::metadata::id3v2::prefix_length(*file);
    REQUIRE(prefix.has_value());
    CHECK(*prefix > 10);
}

TEST_CASE("an all-digit TCON above the genre table keeps its text") {
    orca::metadata::Arena arena;
    const auto frame = build_frame("TCON", 4,
                                   payload("\x03"
                                           "999"));
    const auto tags = expect_tags(arena, build_tag(4, 0, frame));
    REQUIRE(tags.has_value());
    REQUIRE(tags->genres.size() == 1);
    CHECK(tags->genres[0] == "999");
}

TEST_CASE("a TXXX ITUNESADVISORY of 1 marks an MP3 explicit") {
    orca::metadata::Arena arena;
    const auto path =
        std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / "explicit-reference.mp3";
    auto file = orca::storage::LocalFileSource::open(path);
    REQUIRE(file.has_value());
    const auto tags = orca::metadata::id3v2::read(arena, *file);
    REQUIRE(tags.has_value());
    REQUIRE(tags->has_value());
    CHECK((*tags)->explicit_flag == std::optional(orca::metadata::Explicit::explicit_value));
    CHECK((*tags)->track_total == std::optional<std::uint32_t>(2));
}

TEST_CASE("a described COMM such as iTunNORM is never read as the comment") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto described = build_frame("COMM", 3,
                                       payload("\x00"
                                               "engiTunNORM\x00 00000A2B"));
    frames.insert(frames.end(), described.begin(), described.end());
    const auto note = build_frame("COMM", 3,
                                  payload("\x01"
                                          "eng\xff\xfe\x00\x00\xff\xfeN\x00o\x00t\x00"
                                          "e\x00"));
    frames.insert(frames.end(), note.begin(), note.end());
    const auto tags = expect_tags(arena, build_tag(3, 0, frames));
    REQUIRE(tags.has_value());
    CHECK(tags->comment == std::optional<std::string_view>("Note"));

    const auto described_only = build_frame("COMM", 4,
                                            payload("\x03"
                                                    "engiTunNORM\x00 00000A2B"));
    const auto only = expect_tags(arena, build_tag(4, 0, described_only));
    REQUIRE(only.has_value());
    CHECK_FALSE(only->comment.has_value());
}

TEST_CASE("a TXXX described comment in any case is the comment when no undescribed COMM has one") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto described = build_frame("COMM", 4,
                                       payload("\x03"
                                               "engiTunNORM\x00 00000A2B"));
    frames.insert(frames.end(), described.begin(), described.end());
    const auto txxx = build_frame("TXXX", 4,
                                  payload("\x03"
                                          "Comment\x00"
                                          "From ffmpeg"));
    frames.insert(frames.end(), txxx.begin(), txxx.end());
    const auto tags = expect_tags(arena, build_tag(4, 0, frames));
    REQUIRE(tags.has_value());
    CHECK(tags->comment == std::optional<std::string_view>("From ffmpeg"));
}

TEST_CASE("an undescribed COMM wins over a TXXX described comment that comes before it") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto txxx = build_frame("TXXX", 3,
                                  payload("\x00"
                                          "comment\x00"
                                          "From ffmpeg"));
    frames.insert(frames.end(), txxx.begin(), txxx.end());
    const auto comm = build_frame("COMM", 3,
                                  payload("\x00"
                                          "eng\x00"
                                          "From COMM"));
    frames.insert(frames.end(), comm.begin(), comm.end());
    const auto tags = expect_tags(arena, build_tag(3, 0, frames));
    REQUIRE(tags.has_value());
    CHECK(tags->comment == std::optional<std::string_view>("From COMM"));
}

TEST_CASE("a SYLT frame of millisecond lyrics is synced and wins over USLT") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto unsynced = build_frame("USLT", 4,
                                      payload("\x03"
                                              "engDesc\x00Plain words"));
    frames.insert(frames.end(), unsynced.begin(), unsynced.end());
    const auto synced = build_frame("SYLT", 4,
                                    payload("\x03"
                                            "eng\x02\x01\x00\nSecond\x00\x00\x00\x07\xd0"
                                            "First\x00\x00\x00\x03\xe8"));
    frames.insert(frames.end(), synced.begin(), synced.end());
    const auto content = read_lyrics_from(arena, build_tag(4, 0, frames));
    REQUIRE(content.has_value());
    CHECK(content->kind == orca::metadata::lyrics::Kind::synced);
    REQUIRE(content->language.has_value());
    CHECK(*content->language == std::array<char, 3>{'e', 'n', 'g'});
    REQUIRE(content->lines.size() == 2);
    CHECK(content->lines[0].start_ms == std::optional<std::uint32_t>(1000));
    CHECK(content->lines[0].text == "First");
    CHECK(content->lines[1].text == "Second");
}

TEST_CASE("a SYLT frame timed in MPEG frames is passed over for USLT") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto sylt = build_frame("SYLT", 4,
                                  payload("\x03"
                                          "eng\x01\x01\x00Line\x00\x00\x00\x00\x10"));
    frames.insert(frames.end(), sylt.begin(), sylt.end());
    const auto uslt = build_frame("USLT", 4, payload("\x03XXX\x00Plain words"));
    frames.insert(frames.end(), uslt.begin(), uslt.end());
    const auto content = read_lyrics_from(arena, build_tag(4, 0, frames));
    REQUIRE(content.has_value());
    CHECK(content->kind == orca::metadata::lyrics::Kind::plain);
    CHECK_FALSE(content->language.has_value());
    CHECK(content->lines[0].text == "Plain words");
}

TEST_CASE("a SYLT frame of another content type is passed over") {
    orca::metadata::Arena arena;
    const auto chords = build_frame("SYLT", 4,
                                    payload("\x03"
                                            "eng\x02\x05\x00"
                                            "Am\x00\x00\x00\x00\x10"));
    const auto content = read_lyrics_from(arena, build_tag(4, 0, chords));
    CHECK_FALSE(content.has_value());
}

TEST_CASE("a UTF-16 USLT with a byte order mark decodes, LRC included") {
    orca::metadata::Arena arena;
    const auto frame = build_frame("USLT", 3,
                                   payload("\x01"
                                           "deu\xff\xfe\x00\x00\xff\xfe[\x00"
                                           "0\x00"
                                           "0\x00:\x00"
                                           "0\x00"
                                           "2\x00]\x00G\x00r\x00"
                                           "\xfc\x00\xdf\x00"
                                           "e\x00\x00\x00"));
    const auto content = read_lyrics_from(arena, build_tag(3, 0, frame));
    REQUIRE(content.has_value());
    CHECK(content->kind == orca::metadata::lyrics::Kind::synced);
    REQUIRE(content->language.has_value());
    CHECK(*content->language == std::array<char, 3>{'d', 'e', 'u'});
    CHECK(content->lines[0].start_ms == std::optional<std::uint32_t>(2000));
    CHECK(content->lines[0].text == "Gr\u00fc\u00dfe");
}

TEST_CASE("an empty USLT is ignored and the first USLT with text wins") {
    orca::metadata::Arena arena;
    std::vector<std::byte> frames;
    const auto append = [&frames](std::span<const std::byte> body) {
        const auto frame = build_frame("USLT", 4, body);
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(payload("\x03"
                   "eng\x00"));
    append(payload("\x03"
                   "eng\x00\n\n"));
    append(payload("\x03"
                   "eng\x00"
                   "First text"));
    append(payload("\x03"
                   "eng\x00Second text"));
    const auto content = read_lyrics_from(arena, build_tag(4, 0, frames));
    REQUIRE(content.has_value());
    CHECK(content->lines[0].text == "First text");
}

TEST_CASE("a truncated SYLT reads as no lyrics without failing the tag") {
    orca::metadata::Arena arena;
    const auto broken = build_frame("SYLT", 4,
                                    payload("\x03"
                                            "eng\x02\x01\x00Line\x00\x00\x00"));
    const auto content = read_lyrics_from(arena, build_tag(4, 0, broken));
    CHECK_FALSE(content.has_value());
}
