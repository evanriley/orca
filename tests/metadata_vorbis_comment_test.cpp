#include "liborca/metadata/vorbis_comment.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace {

void put_u32le(std::vector<std::byte>& out, std::uint32_t value) {
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((value >> (index * 8U)) & 0xffU));
    }
}

void put_u32be(std::vector<std::byte>& out, std::uint32_t value) {
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((value >> ((3 - index) * 8U)) & 0xffU));
    }
}

void append_text(std::vector<std::byte>& out, std::string_view text) {
    for (const char value : text) {
        out.push_back(static_cast<std::byte>(value));
    }
}

auto build_comments(const std::vector<std::string>& entries) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    const std::string vendor = "Orca";
    put_u32le(out, static_cast<std::uint32_t>(vendor.size()));
    append_text(out, vendor);
    put_u32le(out, static_cast<std::uint32_t>(entries.size()));
    for (const auto& entry : entries) {
        put_u32le(out, static_cast<std::uint32_t>(entry.size()));
        append_text(out, entry);
    }
    return out;
}

struct Block {
    std::uint8_t block_type = 0;
    std::vector<std::byte> payload;
};

auto build_flac(const std::vector<Block>& blocks) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    append_text(out, "fLaC");
    for (std::size_t index = 0; index < blocks.size(); ++index) {
        const bool last = index + 1 == blocks.size();
        const std::uint32_t length = static_cast<std::uint32_t>(blocks[index].payload.size());
        out.push_back(static_cast<std::byte>((last ? 0x80U : 0U) | blocks[index].block_type));
        out.push_back(static_cast<std::byte>((length >> 16U) & 0xffU));
        out.push_back(static_cast<std::byte>((length >> 8U) & 0xffU));
        out.push_back(static_cast<std::byte>(length & 0xffU));
        out.insert(out.end(), blocks[index].payload.begin(), blocks[index].payload.end());
    }
    return out;
}

auto read_stream(orca::metadata::Arena& arena, std::span<const std::byte> bytes)
    -> std::optional<orca::metadata::ObservedTags> {
    orca::storage::MemorySource source(bytes);
    const auto tags = orca::metadata::vorbis_comment::read(arena, source);
    REQUIRE(tags.has_value());
    return *tags;
}

auto picture_block(std::uint32_t kind, std::string_view mime, std::size_t data_size)
    -> std::vector<std::byte> {
    std::vector<std::byte> out;
    put_u32be(out, kind);
    put_u32be(out, static_cast<std::uint32_t>(mime.size()));
    append_text(out, mime);
    put_u32be(out, 0);
    put_u32be(out, 300);
    put_u32be(out, 200);
    put_u32be(out, 24);
    put_u32be(out, 0);
    put_u32be(out, static_cast<std::uint32_t>(data_size));
    out.insert(out.end(), data_size, std::byte{0x5a});
    return out;
}

}

TEST_CASE("Vorbis comment keys match case-insensitively in their real mixed spellings") {
    orca::metadata::Arena arena;
    const auto payload = build_comments({"TITLE=Reference Tone", "artist=Orca Test",
                                         "Album=Fixtures", "ALBUM ARTIST=Orca Ensemble",
                                         "tracknumber=7", "DATE=2026", "Genre=Ambient"});
    const auto tags = read_stream(arena, build_flac({{4, payload}}));
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Reference Tone"));
    CHECK(tags->artist == std::optional<std::string_view>("Orca Test"));
    CHECK(tags->album == std::optional<std::string_view>("Fixtures"));
    CHECK(tags->album_artist == std::optional<std::string_view>("Orca Ensemble"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(7));
    CHECK(tags->date == std::optional<std::string_view>("2026"));
    REQUIRE(tags->genres.size() == 1);
    CHECK(tags->genres[0] == "Ambient");
}

TEST_CASE("repeated Vorbis keys keep the first value and collect every genre") {
    orca::metadata::Arena arena;
    const auto payload = build_comments({"TITLE=First", "TITLE=Second", "GENRE=A", "genre=B"});
    const auto tags = read_stream(arena, build_flac({{4, payload}}));
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("First"));
    REQUIRE(tags->genres.size() == 2);
    CHECK(tags->genres[0] == "A");
    CHECK(tags->genres[1] == "B");
}

TEST_CASE("both total-count conventions and MusicBrainz identifiers are read") {
    orca::metadata::Arena arena;
    const auto payload =
        build_comments({"TRACKNUMBER=3/12", "DISCNUMBER=1", "DISCTOTAL=2",
                        "MUSICBRAINZ_TRACKID=8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a",
                        "MUSICBRAINZ_ALBUMID=8f3471b5-7e6a-48da-86a9-c1c07a0f5b4b"});
    const auto tags = read_stream(arena, build_flac({{4, payload}}));
    REQUIRE(tags.has_value());
    CHECK(tags->track_number == std::optional<std::uint32_t>(3));
    CHECK(tags->track_total == std::optional<std::uint32_t>(12));
    CHECK(tags->disc_number == std::optional<std::uint32_t>(1));
    CHECK(tags->disc_total == std::optional<std::uint32_t>(2));
    CHECK(tags->musicbrainz_recording_id ==
          std::optional<std::string_view>("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"));
    CHECK(tags->musicbrainz_release_id ==
          std::optional<std::string_view>("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4b"));
}

TEST_CASE("an ITUNESADVISORY comment states the advisory, and an unmapped value states none") {
    orca::metadata::Arena arena;
    const auto explicit_tags =
        read_stream(arena, build_flac({{4, build_comments({"ITUNESADVISORY=1"})}}));
    REQUIRE(explicit_tags.has_value());
    CHECK(explicit_tags->explicit_flag == std::optional(orca::metadata::Explicit::explicit_value));

    orca::metadata::Arena other;
    const auto none_tags =
        read_stream(other, build_flac({{4, build_comments({"ITUNESADVISORY=9"})}}));
    REQUIRE(none_tags.has_value());
    CHECK_FALSE(none_tags->explicit_flag.has_value());
}

TEST_CASE("packed track totals and missing core fields are normal outcomes") {
    orca::metadata::Arena arena;
    const auto tags = read_stream(arena, build_flac({{4, build_comments({"TRACKNUMBER=3/12"})}}));
    REQUIRE(tags.has_value());
    CHECK(tags->track_number == std::optional<std::uint32_t>(3));
    CHECK(tags->track_total == std::optional<std::uint32_t>(12));
    CHECK_FALSE(tags->title.has_value());
}

TEST_CASE("FLAC picture blocks are reported without decoding image data") {
    orca::metadata::Arena arena;
    const auto payload = build_comments({"TITLE=Covered"});
    const auto picture = picture_block(3, "image/jpeg", 64);
    const auto tags = read_stream(arena, build_flac({{4, payload}, {6, picture}}));
    REQUIRE(tags.has_value());
    REQUIRE(tags->artwork.has_value());
    CHECK(tags->artwork->mime_type == "image/jpeg");
    CHECK(tags->artwork->byte_size == 64);
    CHECK(tags->artwork->kind == orca::metadata::ArtworkKind::front_cover);
}

TEST_CASE("truncated and malformed FLAC metadata is rejected without reading past the end") {
    orca::metadata::Arena arena;
    orca::storage::MemorySource not_flac("not a flac stream at all");
    const auto invalid = orca::metadata::vorbis_comment::read(arena, not_flac);
    REQUIRE_FALSE(invalid.has_value());
    CHECK(invalid.error().code == orca::ErrorCode::invalid_flac_stream);

    orca::storage::MemorySource short_stream("fLaC");
    const auto truncated = orca::metadata::vorbis_comment::read(arena, short_stream);
    REQUIRE_FALSE(truncated.has_value());
    CHECK(truncated.error().code == orca::ErrorCode::truncated_flac_stream);
}

TEST_CASE("a malformed comment block fails the read instead of yielding partial tags") {
    orca::metadata::Arena arena;
    using orca::ErrorCode;
    const auto expect_invalid = [&arena](const std::vector<std::byte>& payload) {
        const auto bytes = build_flac({{4, payload}});
        orca::storage::MemorySource source(bytes);
        const auto tags = orca::metadata::vorbis_comment::read(arena, source);
        REQUIRE_FALSE(tags.has_value());
        CHECK(tags.error().code == ErrorCode::invalid_vorbis_comment);
    };

    expect_invalid(build_comments({"TITLE=Good", "no equals sign here"}));
    expect_invalid(build_comments({"=value"}));
    expect_invalid(build_comments({std::string("bad") + '\x01' + "key=value"}));
    expect_invalid(build_comments({std::string("KEY=") + '\xff'}));

    std::vector<std::byte> truncated;
    append_text(truncated, "Orca");
    put_u32le(truncated, 1);
    put_u32le(truncated, 100);
    append_text(truncated, "TITLE=short");
    expect_invalid(truncated);
}

TEST_CASE("tagged FLAC fixture reads its real Vorbis comments") {
    orca::metadata::Arena arena;
    const auto path =
        std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / "tagged-reference.flac";
    auto file = orca::storage::LocalFileSource::open(path);
    REQUIRE(file.has_value());
    const auto tags = orca::metadata::vorbis_comment::read(arena, *file);
    REQUIRE(tags.has_value());
    REQUIRE(tags->has_value());
    CHECK((*tags)->title.has_value());
}

TEST_CASE("COMMENT outranks DESCRIPTION, and DESCRIPTION is the comment only without COMMENT") {
    orca::metadata::Arena arena;
    const auto both =
        read_stream(arena, build_flac({{4, build_comments({"COMMENT=From COMMENT",
                                                           "DESCRIPTION=From DESCRIPTION"})}}));
    REQUIRE(both.has_value());
    CHECK(both->comment == std::optional<std::string_view>("From COMMENT"));

    orca::metadata::Arena only;
    const auto described =
        read_stream(only, build_flac({{4, build_comments({"DESCRIPTION=From DESCRIPTION"})}}));
    REQUIRE(described.has_value());
    CHECK(described->comment == std::optional<std::string_view>("From DESCRIPTION"));
}

TEST_CASE("LYRICS outranks UNSYNCEDLYRICS and is parsed as LRC") {
    orca::metadata::Arena arena;
    const auto payload = build_comments({"UNSYNCEDLYRICS=Plain", "LYRICS=[00:01.00]Line"});
    const auto bytes = build_flac({{4, payload}});
    orca::storage::MemorySource source(bytes);
    const auto content = orca::metadata::vorbis_comment::read_lyrics(arena, source);
    REQUIRE(content.has_value());
    REQUIRE(content->has_value());
    CHECK((*content)->kind == orca::metadata::lyrics::Kind::synced);
    CHECK((*content)->lines[0].start_ms == std::optional<std::uint32_t>(1000));
    CHECK((*content)->lines[0].text == "Line");
}

TEST_CASE("lyrics keys match in any case and an empty one is passed over") {
    orca::metadata::Arena arena;
    const auto payload =
        build_comments({"unsyncedlyrics=Plain text", "Lyrics=", "lyrics=[00:01.50]Timed"});
    const auto bytes = build_flac({{4, payload}});
    orca::storage::MemorySource source(bytes);
    const auto content = orca::metadata::vorbis_comment::read_lyrics(arena, source);
    REQUIRE(content.has_value());
    REQUIRE(content->has_value());
    CHECK((*content)->kind == orca::metadata::lyrics::Kind::synced);
    CHECK((*content)->lines[0].start_ms == std::optional<std::uint32_t>(1500));
    CHECK((*content)->lines[0].text == "Timed");
}

TEST_CASE("UNSYNCEDLYRICS is read when no LYRICS comment has text") {
    orca::metadata::Arena arena;
    const auto payload = build_comments({"TITLE=Song", "UNSYNCEDLYRICS=Plain text"});
    const auto bytes = build_flac({{4, payload}});
    orca::storage::MemorySource source(bytes);
    const auto content = orca::metadata::vorbis_comment::read_lyrics(arena, source);
    REQUIRE(content.has_value());
    REQUIRE(content->has_value());
    CHECK((*content)->kind == orca::metadata::lyrics::Kind::plain);
    CHECK((*content)->lines[0].text == "Plain text");
}
