#include "liborca/metadata/id3v1.hpp"
#include "liborca/metadata/id3v2.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <filesystem>
#include <fstream>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace {

using orca::metadata::Field;
using orca::metadata::ObservedTags;
using orca::metadata::mutation::Change;
using orca::metadata::mutation::GenreChange;

template <std::size_t Size>
auto payload(const char (&text)[Size]) -> std::span<const std::byte> {
    return std::span<const std::byte>(reinterpret_cast<const std::byte*>(text), Size - 1);
}

auto bytes_of(std::string_view text) -> std::span<const std::byte> {
    return std::span<const std::byte>(reinterpret_cast<const std::byte*>(text.data()), text.size());
}

auto to_optional_string(const std::optional<std::string_view>& value)
    -> std::optional<std::string> {
    return value ? std::optional<std::string>(*value) : std::nullopt;
}

void put_syncsafe(std::vector<std::byte>& out, std::uint32_t value) {
    out.push_back(static_cast<std::byte>((value >> 21U) & 0x7fU));
    out.push_back(static_cast<std::byte>((value >> 14U) & 0x7fU));
    out.push_back(static_cast<std::byte>((value >> 7U) & 0x7fU));
    out.push_back(static_cast<std::byte>(value & 0x7fU));
}

auto build_frame(std::string_view id, std::uint8_t major, std::span<const std::byte> body)
    -> std::vector<std::byte> {
    std::vector<std::byte> out;
    for (const char value : id) {
        out.push_back(static_cast<std::byte>(value));
    }
    const std::uint32_t length = static_cast<std::uint32_t>(body.size());
    if (major >= 4) {
        put_syncsafe(out, length);
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

auto build_tag(std::uint8_t major, std::span<const std::byte> frames) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    for (const char value : std::string_view("ID3")) {
        out.push_back(static_cast<std::byte>(value));
    }
    out.push_back(static_cast<std::byte>(major));
    out.push_back(std::byte{0});
    out.push_back(std::byte{0});
    put_syncsafe(out, static_cast<std::uint32_t>(frames.size()));
    out.insert(out.end(), frames.begin(), frames.end());
    return out;
}

auto build_tag(std::uint8_t major, const std::vector<std::byte>& frames) -> std::vector<std::byte> {
    return build_tag(major, std::span<const std::byte>(frames));
}

auto concat(const std::vector<std::byte>& first, const std::vector<std::byte>& second)
    -> std::vector<std::byte> {
    std::vector<std::byte> out = first;
    out.insert(out.end(), second.begin(), second.end());
    return out;
}

auto with_audio(const std::vector<std::byte>& tag) -> std::vector<std::byte> {
    const auto audio = bytes_of("audio");
    return concat(tag, std::vector<std::byte>(audio.begin(), audio.end()));
}

auto read_tags(orca::metadata::Arena& arena, std::span<const std::byte> bytes)
    -> std::optional<ObservedTags> {
    orca::storage::MemorySource source(bytes);
    const auto tags = orca::metadata::id3v2::read(arena, source);
    REQUIRE(tags.has_value());
    return *tags;
}

auto apply_rewrite(std::span<const std::byte> original, const std::vector<Change>& changes,
                   const std::optional<GenreChange>& genres) -> std::vector<std::byte> {
    orca::storage::MemorySource source(original);
    const auto planned = orca::metadata::id3v2::rewrite(source, changes, genres);
    REQUIRE(planned.has_value());
    std::vector<std::byte> out = planned->tag;
    out.insert(out.end(), original.begin() + static_cast<std::ptrdiff_t>(planned->audio_start),
               original.begin() + static_cast<std::ptrdiff_t>(planned->audio_end));
    if (planned->trailer) {
        out.insert(out.end(), planned->trailer->begin(), planned->trailer->end());
    }
    return out;
}

auto contains(std::span<const std::byte> haystack, std::span<const std::byte> needle) -> bool {
    if (needle.empty() || haystack.size() < needle.size()) {
        return false;
    }
    for (std::size_t index = 0; index + needle.size() <= haystack.size(); ++index) {
        if (std::memcmp(haystack.data() + index, needle.data(), needle.size()) == 0) {
            return true;
        }
    }
    return false;
}

auto contains_text(std::span<const std::byte> haystack, std::string_view needle) -> bool {
    return contains(haystack, bytes_of(needle));
}

auto count_occurrences(std::span<const std::byte> haystack, std::string_view needle)
    -> std::size_t {
    const auto needle_bytes = bytes_of(needle);
    std::size_t count = 0;
    for (std::size_t index = 0; index + needle.size() <= haystack.size(); ++index) {
        if (std::memcmp(haystack.data() + index, needle_bytes.data(), needle.size()) == 0) {
            ++count;
            index += needle.size() - 1;
        }
    }
    return count;
}

auto read_file_bytes(const std::filesystem::path& path) -> std::vector<std::byte> {
    std::ifstream input(path, std::ios::binary);
    REQUIRE(input.good());
    input.seekg(0, std::ios::end);
    const std::streamoff size = input.tellg();
    input.seekg(0, std::ios::beg);
    std::vector<std::byte> bytes(static_cast<std::size_t>(size));
    input.read(reinterpret_cast<char*>(bytes.data()), size);
    return bytes;
}

auto fixture(std::string_view name) -> std::filesystem::path {
    return std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / name;
}

auto legacy_trailer(std::string_view year) -> std::array<std::byte, 128> {
    const auto encoded = orca::metadata::id3v1::encode(orca::metadata::id3v1::Tag{.title = "Song",
                                                                                  .artist = "Band",
                                                                                  .album = "Record",
                                                                                  .year = year,
                                                                                  .comment = "",
                                                                                  .track_number = 3,
                                                                                  .genre = 17});
    REQUIRE(encoded.has_value());
    return *encoded;
}

void expect_trailer_values(const ObservedTags& tags, std::string_view title,
                           std::string_view year) {
    CHECK(tags.title == std::optional<std::string_view>(title));
    CHECK(tags.artist == std::optional<std::string_view>("Band"));
    CHECK(tags.album == std::optional<std::string_view>("Record"));
    CHECK(tags.date == std::optional<std::string_view>(year));
    CHECK(tags.track_number == std::optional<std::uint32_t>(3));
    REQUIRE(tags.genres.size() == 1);
    CHECK(tags.genres[0] == "Rock");
}

auto count_user_text(std::span<const std::byte> bytes, std::string_view description)
    -> std::size_t {
    if (bytes.size() < 10 || std::memcmp(bytes.data(), "ID3", 3) != 0) {
        return 0;
    }
    const auto major = std::to_integer<std::uint8_t>(bytes[3]);
    std::string pattern;
    if (major >= 4) {
        pattern = std::string(description);
    } else {
        pattern.push_back(static_cast<char>(0xff));
        pattern.push_back(static_cast<char>(0xfe));
        for (const char value : description) {
            pattern.push_back(value);
            pattern.push_back('\0');
        }
    }
    return count_occurrences(bytes, pattern);
}

auto legacy_user_text(std::uint8_t major, std::string_view description, std::string_view value)
    -> std::vector<std::byte> {
    std::string body;
    body.push_back('\0');
    body += description;
    body.push_back('\0');
    body += value;
    return build_frame("TXXX", major, bytes_of(body));
}

auto expected_user_text_frame(std::uint8_t major, std::string_view description,
                              std::string_view value) -> std::vector<std::byte> {
    std::vector<std::byte> body;
    if (major >= 4) {
        body.push_back(std::byte{3});
        const auto description_bytes = bytes_of(description);
        body.insert(body.end(), description_bytes.begin(), description_bytes.end());
        body.push_back(std::byte{0});
        const auto value_bytes = bytes_of(value);
        body.insert(body.end(), value_bytes.begin(), value_bytes.end());
    } else {
        body.push_back(std::byte{1});
        body.push_back(std::byte{0xff});
        body.push_back(std::byte{0xfe});
        for (const char character : description) {
            body.push_back(static_cast<std::byte>(character));
            body.push_back(std::byte{0});
        }
        body.push_back(std::byte{0});
        body.push_back(std::byte{0});
        body.push_back(std::byte{0xff});
        body.push_back(std::byte{0xfe});
        for (const char character : value) {
            body.push_back(static_cast<std::byte>(character));
            body.push_back(std::byte{0});
        }
    }
    return build_frame("TXXX", major, body);
}

auto cover_body(std::size_t image_size) -> std::vector<std::byte> {
    std::vector<std::byte> body;
    const auto prefix = payload("\0image/png\0\3\0");
    body.insert(body.end(), prefix.begin(), prefix.end());
    body.insert(body.end(), image_size, std::byte{0x5a});
    return body;
}

}

TEST_CASE("a rewritten ID3v2.4 tag carries the edit, keeps the cover and audio, and is 2.4") {
    const auto original = read_file_bytes(fixture("covered-reference.mp3"));
    orca::metadata::Arena arena;
    const auto before = read_tags(arena, original);
    REQUIRE(before.has_value());

    const auto written = apply_rewrite(original,
                                       {Change{.field = Field::title,
                                               .before = to_optional_string(before->title),
                                               .after = "Rewritten Title"},
                                        Change{.field = Field::album_artist,
                                               .before = to_optional_string(before->album_artist),
                                               .after = "Rewritten Artist"}},
                                       std::nullopt);
    CHECK(written[3] == std::byte{4});

    orca::metadata::Arena after_arena;
    const auto after = read_tags(after_arena, written);
    REQUIRE(after.has_value());
    CHECK(after->title == std::optional<std::string_view>("Rewritten Title"));
    CHECK(after->album_artist == std::optional<std::string_view>("Rewritten Artist"));
    CHECK(after->artist == before->artist);
    REQUIRE(after->artwork.has_value());
    REQUIRE(before->artwork.has_value());
    CHECK(after->artwork->byte_size == before->artwork->byte_size);
}

TEST_CASE("an ID3v2.3 tag stays 2.3 and writes non-Latin text as UTF-16") {
    std::vector<std::byte> frames;
    const auto append = [&frames](std::string_view id, std::span<const std::byte> body) {
        const auto frame = build_frame(id, 3, body);
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append("TIT2", payload("\0Old"));
    append("TRCK", payload("\0"
                           "2/9"));
    append("TYER", payload("\0"
                           "1999"));
    append("TDAT", payload("\0"
                           "0101"));
    append("COMM", payload("\0engkept"));
    const auto original = with_audio(build_tag(3, frames));

    const auto written = apply_rewrite(
        original,
        {Change{.field = Field::title, .before = "Old", .after = "\u03a9\u03bc\u03ad\u03b3\u03b1"},
         Change{.field = Field::track_number, .before = "2", .after = "5"},
         Change{.field = Field::date, .before = "1999-01-01", .after = "2024-03-15"}},
        std::nullopt);
    CHECK(written[3] == std::byte{3});
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->title == std::optional<std::string_view>("\u03a9\u03bc\u03ad\u03b3\u03b1"));
    CHECK(after->track_number == std::optional<std::uint32_t>(5));
    CHECK(after->track_total == std::optional<std::uint32_t>(9));
    CHECK(after->date == std::optional<std::string_view>("2024-03-15"));
}

TEST_CASE("a 2.3 date write replaces TYER and TDAT and keeps TIME and TRDA byte for byte") {
    const auto time_frame = build_frame("TIME", 3,
                                        payload("\0"
                                                "1230"));
    const auto recording_dates = build_frame("TRDA", 3, payload("\0June 5th"));
    std::vector<std::byte> frames;
    const auto append = [&frames](const std::vector<std::byte>& frame) {
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(build_frame("TYER", 3,
                       payload("\0"
                               "1999")));
    append(build_frame("TDAT", 3,
                       payload("\0"
                               "0101")));
    append(time_frame);
    append(recording_dates);
    const auto original = with_audio(build_tag(3, frames));

    const auto full = apply_rewrite(
        original, {Change{.field = Field::date, .before = "1999-01-01", .after = "2024-03-15"}},
        std::nullopt);
    CHECK(contains(full, time_frame));
    CHECK(contains(full, recording_dates));
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, full);
    REQUIRE(after.has_value());
    CHECK(after->date == std::optional<std::string_view>("2024-03-15"));

    const auto year_only = apply_rewrite(
        original, {Change{.field = Field::date, .before = "1999-01-01", .after = "2024"}},
        std::nullopt);
    CHECK(contains(year_only, time_frame));
    CHECK(contains(year_only, recording_dates));
    CHECK_FALSE(contains_text(year_only, "TDAT"));
}

TEST_CASE("a stream with no ID3v2 tag gets a 2.4 one and its ID3v1 trailer is updated") {
    const auto encoded =
        orca::metadata::id3v1::encode(orca::metadata::id3v1::Tag{.title = "Legacy",
                                                                 .artist = "Artist",
                                                                 .album = "Album",
                                                                 .year = "2001",
                                                                 .comment = "",
                                                                 .track_number = 1,
                                                                 .genre = 13});
    REQUIRE(encoded.has_value());
    auto original = with_audio(std::vector<std::byte>{});
    original.insert(original.end(), encoded->begin(), encoded->end());

    const auto written = apply_rewrite(
        original, {Change{.field = Field::title, .before = "Legacy", .after = "Modern"}},
        std::nullopt);
    CHECK(written[3] == std::byte{4});
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->title == std::optional<std::string_view>("Modern"));

    std::array<std::byte, 128> trailer_out{};
    std::memcpy(trailer_out.data(), written.data() + written.size() - 128, 128);
    const auto parsed = orca::metadata::id3v1::parse(trailer_out);
    REQUIRE(parsed.has_value());
    CHECK(parsed->title == "Modern");
    CHECK(contains_text(written, "audio"));
}

TEST_CASE("a rewrite refuses a change whose before no longer matches the file") {
    const auto original = read_file_bytes(fixture("tagged-reference.mp3"));
    orca::storage::MemorySource source(original);
    const auto planned = orca::metadata::id3v2::rewrite(
        source, {Change{.field = Field::title, .before = "Not what the file says", .after = "New"}},
        std::nullopt);
    REQUIRE_FALSE(planned.has_value());
    CHECK(planned.error().code == orca::ErrorCode::metadata_precondition_changed);
}

TEST_CASE("clearing a field removes its frame") {
    const auto original = read_file_bytes(fixture("tagged-reference.mp3"));
    orca::metadata::Arena arena;
    const auto before = read_tags(arena, original);
    REQUIRE(before.has_value());
    const auto written = apply_rewrite(original,
                                       {Change{.field = Field::album,
                                               .before = to_optional_string(before->album),
                                               .after = std::nullopt}},
                                       std::nullopt);
    orca::metadata::Arena after_arena;
    const auto after = read_tags(after_arena, written);
    REQUIRE(after.has_value());
    CHECK_FALSE(after->album.has_value());
    CHECK(after->title == before->title);
}

void expect_composer_and_comment(std::uint8_t major) {
    const auto title = build_frame("TIT2", major, payload("\0Kept"));
    const auto encoder = build_frame("TSSE", major, payload("\0LAME 3.100"));
    const auto normalisation =
        build_frame("COMM", major, payload("\0engiTunNORM\0 00000A2B 00000B3C"));
    const auto replay_gain =
        build_frame("TXXX", major, payload("\0REPLAYGAIN_TRACK_GAIN\0-6.50 dB"));
    const auto cover = build_frame("APIC", major, bytes_of(std::string("\x89PNG\r\n\x1a\nimage")));
    std::vector<std::byte> frames;
    const auto append = [&frames](const std::vector<std::byte>& frame) {
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(title);
    append(build_frame("TCOM", major, payload("\0Old Composer")));
    append(encoder);
    append(normalisation);
    append(build_frame("COMM", major, payload("\0eng\0Old note")));
    append(replay_gain);
    append(build_frame("COMM", major, payload("\0fra\0Vieille note")));
    append(cover);
    const auto original = with_audio(build_tag(major, frames));

    const auto written = apply_rewrite(
        original,
        {Change{.field = Field::composer, .before = "Old Composer", .after = "Nick Drake"},
         Change{.field = Field::comment,
                .before = "Old note",
                .after = "\u03a9\u03bc\u03ad\u03b3\u03b1 remaster"}},
        std::nullopt);
    CHECK(written[3] == std::byte{major});
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->composer == std::optional<std::string_view>("Nick Drake"));
    CHECK(after->comment ==
          std::optional<std::string_view>("\u03a9\u03bc\u03ad\u03b3\u03b1 remaster"));
    CHECK(after->title == std::optional<std::string_view>("Kept"));
    for (const auto& frame : {title, encoder, normalisation, replay_gain, cover}) {
        CHECK(contains(written, frame));
    }
    CHECK_FALSE(contains_text(written, "Old note"));
    CHECK_FALSE(contains_text(written, "Vieille note"));
    CHECK_FALSE(contains_text(written, "Old Composer"));
    CHECK(count_occurrences(written, "COMM") == 2);
}

TEST_CASE("a composer and comment written to an ID3v2.4 tag replaces every undescribed COMM") {
    expect_composer_and_comment(4);
}

TEST_CASE("a composer and comment written to an ID3v2.3 tag replaces every undescribed COMM") {
    expect_composer_and_comment(3);
}

TEST_CASE("a comment write replaces a TXXX described comment and keeps other TXXX frames") {
    const auto replay_gain = build_frame("TXXX", 4, payload("\3REPLAYGAIN_TRACK_GAIN\0-6.50 dB"));
    std::vector<std::byte> frames;
    const auto append = [&frames](const std::vector<std::byte>& frame) {
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(build_frame("TIT2", 4, payload("\3Kept")));
    append(build_frame("TXXX", 4, payload("\3COMMENT\0From ffmpeg")));
    append(replay_gain);
    const auto original = with_audio(build_tag(4, frames));

    const auto written = apply_rewrite(
        original, {Change{.field = Field::comment, .before = "From ffmpeg", .after = "New note"}},
        std::nullopt);
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->comment == std::optional<std::string_view>("New note"));
    CHECK_FALSE(contains_text(written, "From ffmpeg"));
    CHECK(contains(written, replay_gain));
}

TEST_CASE("clearing the comment removes the undescribed COMM and leaves the described COMM") {
    const auto composer = build_frame("TCOM", 4, payload("\3Nick Drake"));
    const auto normalisation = build_frame("COMM", 4, payload("\3engiTunNORM\0 00000A2B"));
    std::vector<std::byte> frames;
    const auto append = [&frames](const std::vector<std::byte>& frame) {
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(composer);
    append(build_frame("COMM", 4, payload("\3eng\0Old note")));
    append(normalisation);
    const auto original = with_audio(build_tag(4, frames));

    const auto written = apply_rewrite(
        original, {Change{.field = Field::comment, .before = "Old note", .after = std::nullopt}},
        std::nullopt);
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK_FALSE(after->comment.has_value());
    CHECK(after->composer == std::optional<std::string_view>("Nick Drake"));
    CHECK(contains(written, composer));
    CHECK(contains(written, normalisation));
    CHECK_FALSE(contains_text(written, "Old note"));
}

TEST_CASE("a comment change whose before no longer matches is refused") {
    std::vector<std::byte> frames;
    const auto append = [&frames](const std::vector<std::byte>& frame) {
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(build_frame("TIT2", 4, payload("\3Kept")));
    append(build_frame("COMM", 4, payload("\3eng\0Changed elsewhere")));
    const auto original = with_audio(build_tag(4, frames));
    orca::storage::MemorySource source(original);
    const auto planned = orca::metadata::id3v2::rewrite(
        source, {Change{.field = Field::comment, .before = "Old note", .after = "New"}},
        std::nullopt);
    REQUIRE_FALSE(planned.has_value());
    CHECK(planned.error().code == orca::ErrorCode::metadata_precondition_changed);
}

TEST_CASE("a comment written to a comment-only tag keeps every trailer value and the trailer") {
    const auto trailer = legacy_trailer("1999");
    auto original = with_audio(build_tag(3, build_frame("COMM", 3, payload("\0eng\0Old note"))));
    original.insert(original.end(), trailer.begin(), trailer.end());

    const auto written = apply_rewrite(
        original,
        {Change{.field = Field::comment, .before = "Old note", .after = "New note"},
         Change{.field = Field::composer, .before = std::nullopt, .after = "Nick Drake"}},
        std::nullopt);
    CHECK(written[3] == std::byte{3});
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    expect_trailer_values(*after, "Song", "1999");
    CHECK(after->comment == std::optional<std::string_view>("New note"));
    CHECK(after->composer == std::optional<std::string_view>("Nick Drake"));
    CHECK(std::memcmp(written.data() + written.size() - 128, trailer.data(), 128) == 0);
}

void expect_recording_id(std::uint8_t major) {
    const std::string_view old_id = "11111111-2222-4333-8444-555555555555";
    const std::string_view new_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    const std::string description_body = major >= 4 ? std::string("\3MusicBrainz Track Id\0", 22)
                                                    : std::string("\0MusicBrainz Track Id\0", 22);
    const auto foreign_ufid = build_frame("UFID", major,
                                          payload("http://www.cddb.com/id3/taginfo1.html\0"
                                                  "3CD3N42R04-1"));
    const auto replay_gain =
        build_frame("TXXX", major, payload("\0REPLAYGAIN_TRACK_GAIN\0-6.50 dB"));
    const auto title = build_frame("TIT2", major, payload("\0Kept"));
    std::vector<std::byte> frames;
    const auto append = [&frames](const std::vector<std::byte>& frame) {
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(title);
    append(foreign_ufid);
    append(build_frame("TXXX", major, bytes_of(description_body + std::string(old_id))));
    append(replay_gain);
    const auto original = with_audio(build_tag(major, frames));

    const auto written = apply_rewrite(original,
                                       {Change{.field = Field::musicbrainz_recording_id,
                                               .before = std::string(old_id),
                                               .after = std::string(new_id)}},
                                       std::nullopt);
    CHECK(written[3] == std::byte{major});
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->musicbrainz_recording_id == std::optional<std::string_view>(new_id));
    CHECK(contains(written, title));
    CHECK(contains(written, foreign_ufid));
    CHECK(contains(written, replay_gain));
    CHECK_FALSE(contains_text(written, "MusicBrainz Track Id"));
    CHECK_FALSE(contains_text(written, old_id));
    const auto musicbrainz_ufid = [&]() {
        std::string body = "http://musicbrainz.org";
        body.push_back('\0');
        body += std::string(new_id);
        return build_frame("UFID", major, bytes_of(body));
    }();
    CHECK(contains(written, musicbrainz_ufid));
}

TEST_CASE("a recording id is written as a MusicBrainz UFID in 2.4") {
    expect_recording_id(4);
}

TEST_CASE("a recording id is written as a MusicBrainz UFID in 2.3") {
    expect_recording_id(3);
}

TEST_CASE("a recording id is added, and an earlier MusicBrainz UFID is replaced") {
    const auto original = read_file_bytes(fixture("covered-reference.mp3"));
    orca::metadata::Arena arena;
    const auto before = read_tags(arena, original);
    REQUIRE(before.has_value());
    CHECK_FALSE(before->musicbrainz_recording_id.has_value());
    const std::string_view first_id = "11111111-2222-4333-8444-555555555555";
    const std::string_view second_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

    const auto first = apply_rewrite(original,
                                     {Change{.field = Field::musicbrainz_recording_id,
                                             .before = std::nullopt,
                                             .after = std::string(first_id)}},
                                     std::nullopt);
    orca::metadata::Arena once_arena;
    const auto once = read_tags(once_arena, first);
    REQUIRE(once.has_value());
    CHECK(once->musicbrainz_recording_id == std::optional<std::string_view>(first_id));
    CHECK(once->title == before->title);

    const auto second = apply_rewrite(first,
                                      {Change{.field = Field::musicbrainz_recording_id,
                                              .before = std::string(first_id),
                                              .after = std::string(second_id)}},
                                      std::nullopt);
    orca::metadata::Arena twice_arena;
    const auto twice = read_tags(twice_arena, second);
    REQUIRE(twice.has_value());
    CHECK(twice->musicbrainz_recording_id == std::optional<std::string_view>(second_id));
    CHECK(count_occurrences(second, "http://musicbrainz.org") == 1);
}

void expect_genre(std::uint8_t major) {
    const auto title = build_frame("TIT2", major, payload("\0Kept"));
    std::vector<std::byte> frames;
    const auto append = [&frames](const std::vector<std::byte>& frame) {
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(build_frame("TCON", major, payload("\0(17)")));
    append(title);
    append(build_frame("TCON", major, payload("\0Indie Rock, Rock")));
    const auto original = with_audio(build_tag(major, frames));
    const GenreChange genres{.before = {"Rock", "Indie Rock, Rock"},
                             .after = {"Shoegaze", "Dream Pop"}};

    const auto written = apply_rewrite(original, {}, genres);
    CHECK(written[3] == std::byte{major});
    CHECK(count_occurrences(written, "TCON") == 1);
    CHECK(contains(written, title));
    CHECK_FALSE(contains_text(written, "Indie"));
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->title == std::optional<std::string_view>("Kept"));
    if (major >= 4) {
        REQUIRE(after->genres.size() == 2);
        CHECK(after->genres[0] == "Shoegaze");
        CHECK(after->genres[1] == "Dream Pop");
    } else {
        REQUIRE(after->genres.size() == 1);
        CHECK(after->genres[0] == "Shoegaze; Dream Pop");
    }

    orca::storage::MemorySource source(original);
    const auto refused = orca::metadata::id3v2::rewrite(
        source, {},
        std::optional<GenreChange>(GenreChange{.before = {"Rock"}, .after = {"Shoegaze"}}));
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::metadata_precondition_changed);
}

TEST_CASE("a genre write replaces every TCON frame with each genre a separate 2.4 value") {
    expect_genre(4);
}

TEST_CASE("a genre write replaces every TCON frame with one semicolon list in 2.3") {
    expect_genre(3);
}

TEST_CASE(
    "a genre write to a trailer-only stream puts genres in the new tag and leaves the trailer") {
    const auto trailer = legacy_trailer("1999");
    auto original = with_audio(std::vector<std::byte>{});
    original.insert(original.end(), trailer.begin(), trailer.end());

    const auto written = apply_rewrite(
        original, {},
        std::optional<GenreChange>(GenreChange{.before = {"Rock"}, .after = {"Jazz", "Blues"}}));
    CHECK(std::memcmp(written.data() + written.size() - 128, trailer.data(), 128) == 0);
    CHECK(count_occurrences(written, "TCON") == 1);
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->title == std::optional<std::string_view>("Song"));
    CHECK(after->date == std::optional<std::string_view>("1999"));
    REQUIRE(after->genres.size() == 2);
    CHECK(after->genres[0] == "Jazz");
    CHECK(after->genres[1] == "Blues");
}

TEST_CASE("a recording id given to a trailer-only stream keeps trailer values in the new tag") {
    const auto trailer = legacy_trailer("1999");
    auto original = with_audio(std::vector<std::byte>{});
    original.insert(original.end(), trailer.begin(), trailer.end());
    const std::string_view recording_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

    const auto written = apply_rewrite(original,
                                       {Change{.field = Field::musicbrainz_recording_id,
                                               .before = std::nullopt,
                                               .after = std::string(recording_id)}},
                                       std::nullopt);
    CHECK(written[3] == std::byte{4});
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    expect_trailer_values(*after, "Song", "1999");
    CHECK(after->musicbrainz_recording_id == std::optional<std::string_view>(recording_id));
    CHECK(std::memcmp(written.data() + written.size() - 128, trailer.data(), 128) == 0);
}

TEST_CASE("a changed field overrides the trailer value while other trailer values are kept") {
    const auto trailer = legacy_trailer("99");
    auto original = with_audio(std::vector<std::byte>{});
    original.insert(original.end(), trailer.begin(), trailer.end());

    const auto written = apply_rewrite(
        original, {Change{.field = Field::title, .before = "Song", .after = "Anthem"}},
        std::nullopt);
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    expect_trailer_values(*after, "Anthem", "99");
    CHECK(count_occurrences(written, "TIT2") == 1);
    std::array<std::byte, 128> updated_trailer{};
    std::memcpy(updated_trailer.data(), written.data() + written.size() - 128, 128);
    const auto parsed = orca::metadata::id3v1::parse(updated_trailer);
    REQUIRE(parsed.has_value());
    CHECK(parsed->title == "Anthem");

    const auto cleared = apply_rewrite(
        original, {Change{.field = Field::artist, .before = "Band", .after = std::nullopt}},
        std::nullopt);
    orca::metadata::Arena cleared_arena;
    const auto after_cleared = read_tags(cleared_arena, cleared);
    REQUIRE(after_cleared.has_value());
    CHECK_FALSE(after_cleared->artist.has_value());
    CHECK_FALSE(contains_text(cleared, "TPE1"));
}

TEST_CASE("a 2.3 tag holding only ReplayGain gains trailer values in 2.3 form") {
    const auto replay_gain = build_frame("TXXX", 3, payload("\0REPLAYGAIN_TRACK_GAIN\0-6.50 dB"));
    const auto trailer = legacy_trailer("1999");
    auto original = with_audio(build_tag(3, replay_gain));
    original.insert(original.end(), trailer.begin(), trailer.end());

    const auto written = apply_rewrite(original,
                                       {Change{.field = Field::musicbrainz_recording_id,
                                               .before = std::nullopt,
                                               .after = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"}},
                                       std::nullopt);
    CHECK(written[3] == std::byte{3});
    CHECK(contains(written, replay_gain));
    CHECK(contains_text(written, "TYER"));
    CHECK_FALSE(contains_text(written, "TDRC"));
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    expect_trailer_values(*after, "Song", "1999");
}

TEST_CASE("an ID3v2 tag with values of its own gains nothing from the trailer") {
    const auto title = build_frame("TIT2", 4, payload("\3Tagged"));
    const auto trailer = legacy_trailer("1999");
    auto original = with_audio(build_tag(4, title));
    original.insert(original.end(), trailer.begin(), trailer.end());

    const auto written = apply_rewrite(
        original, {Change{.field = Field::album, .before = std::nullopt, .after = "New Album"}},
        std::nullopt);
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->title == std::optional<std::string_view>("Tagged"));
    CHECK_FALSE(after->artist.has_value());
    CHECK(after->genres.empty());
}

TEST_CASE(
    "a recording id written to a cover-only 2.3 tag keeps the cover and gains trailer values") {
    const auto cover = build_frame("APIC", 3, cover_body(32));
    const auto trailer = legacy_trailer("1999");
    auto original = with_audio(build_tag(3, cover));
    original.insert(original.end(), trailer.begin(), trailer.end());
    const std::string_view recording_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

    const auto written = apply_rewrite(original,
                                       {Change{.field = Field::musicbrainz_recording_id,
                                               .before = std::nullopt,
                                               .after = std::string(recording_id)}},
                                       std::nullopt);
    CHECK(written[3] == std::byte{3});
    CHECK(std::memcmp(written.data() + 10, cover.data(), cover.size()) == 0);
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    expect_trailer_values(*after, "Song", "1999");
    CHECK(after->musicbrainz_recording_id == std::optional<std::string_view>(recording_id));
    REQUIRE(after->artwork.has_value());
    CHECK(after->artwork->byte_size == 32);
    CHECK(std::memcmp(written.data() + written.size() - 128, trailer.data(), 128) == 0);
}

TEST_CASE("a title change to a cover-only tag is checked against the trailer title") {
    const auto cover = build_frame("APIC", 4, cover_body(32));
    const auto trailer = legacy_trailer("1999");
    auto original = with_audio(build_tag(4, cover));
    original.insert(original.end(), trailer.begin(), trailer.end());

    const auto written = apply_rewrite(
        original, {Change{.field = Field::title, .before = "Song", .after = "Anthem"}},
        std::nullopt);
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    expect_trailer_values(*after, "Anthem", "1999");
}

struct ReleaseIds {
    std::string release;
    std::string release_group;
    std::string release_track;
    std::string album_artist;
};

const ReleaseIds first_release_ids{
    .release = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a",
    .release_group = "0b6a3a3e-3b2c-4c8e-9a51-1f2d3c4b5a69",
    .release_track = "c2f7b3a4-5d6e-4f80-9a1b-2c3d4e5f6a7b",
    .album_artist = "d4e5f6a7-b8c9-4d0e-8f1a-2b3c4d5e6f70",
};

const ReleaseIds second_release_ids{
    .release = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
    .release_group = "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e",
    .release_track = "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f",
    .album_artist = "4d5e6f7a-8b9c-4d0e-9f2a-3b4c5d6e7f80",
};

auto release_id_changes(const ReleaseIds* before, const ReleaseIds& after) -> std::vector<Change> {
    return {
        Change{.field = Field::musicbrainz_release_id,
               .before = before ? std::optional<std::string>(before->release) : std::nullopt,
               .after = after.release},
        Change{.field = Field::musicbrainz_release_group_id,
               .before = before ? std::optional<std::string>(before->release_group) : std::nullopt,
               .after = after.release_group},
        Change{.field = Field::musicbrainz_release_track_id,
               .before = before ? std::optional<std::string>(before->release_track) : std::nullopt,
               .after = after.release_track},
        Change{.field = Field::musicbrainz_album_artist_id,
               .before = before ? std::optional<std::string>(before->album_artist) : std::nullopt,
               .after = after.album_artist},
    };
}

void expect_release_ids(const ObservedTags& tags, const ReleaseIds& ids) {
    CHECK(tags.musicbrainz_release_id == std::optional<std::string_view>(ids.release));
    CHECK(tags.musicbrainz_release_group_id == std::optional<std::string_view>(ids.release_group));
    CHECK(tags.musicbrainz_release_track_id == std::optional<std::string_view>(ids.release_track));
    CHECK(tags.musicbrainz_album_artist_id == std::optional<std::string_view>(ids.album_artist));
}

void expect_every_release_id(std::uint8_t major) {
    const auto title = build_frame("TIT2", major, payload("\0Kept"));
    const auto original = with_audio(build_tag(major, title));

    const auto first =
        apply_rewrite(original, release_id_changes(nullptr, first_release_ids), std::nullopt);
    CHECK(first[3] == std::byte{major});
    orca::metadata::Arena once_arena;
    const auto once = read_tags(once_arena, first);
    REQUIRE(once.has_value());
    expect_release_ids(*once, first_release_ids);
    CHECK(once->title == std::optional<std::string_view>("Kept"));

    const auto second = apply_rewrite(
        first, release_id_changes(&first_release_ids, second_release_ids), std::nullopt);
    orca::metadata::Arena twice_arena;
    const auto twice = read_tags(twice_arena, second);
    REQUIRE(twice.has_value());
    expect_release_ids(*twice, second_release_ids);
    CHECK(contains(second, title));
    CHECK(count_user_text(second, "MusicBrainz Album Id") == 1);
    CHECK(count_user_text(second, "MusicBrainz Album Artist Id") == 1);
    CHECK(count_user_text(second, "MusicBrainz Release Group Id") == 1);
    CHECK(count_user_text(second, "MusicBrainz Release Track Id") == 1);
}

TEST_CASE("every release-level MusicBrainz id written to a 2.4 tag reads back and is replaced") {
    expect_every_release_id(4);
}

TEST_CASE("every release-level MusicBrainz id written to a 2.3 tag reads back and is replaced") {
    expect_every_release_id(3);
}

void expect_release_id_rewrite(std::uint8_t major) {
    const std::string_view old_id = "11111111-2222-4333-8444-555555555555";
    const std::string_view new_id = first_release_ids.release;
    const std::string_view release_group_id = first_release_ids.release_group;
    const std::string_view recording_id = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
    const auto title = build_frame("TIT2", major, payload("\0Kept"));
    const auto foreign_ufid = build_frame("UFID", major,
                                          payload("http://www.cddb.com/id3/taginfo1.html\0"
                                                  "3CD3N42R04-1"));
    const auto release_group =
        legacy_user_text(major, "MusicBrainz Release Group Id", release_group_id);
    const auto recording = legacy_user_text(major, "MusicBrainz Track Id", recording_id);
    const auto replay_gain =
        build_frame("TXXX", major, payload("\0REPLAYGAIN_TRACK_GAIN\0-6.50 dB"));
    const auto cover = build_frame("APIC", major, cover_body(32));
    std::vector<std::byte> frames;
    const auto append = [&frames](const std::vector<std::byte>& frame) {
        frames.insert(frames.end(), frame.begin(), frame.end());
    };
    append(title);
    append(foreign_ufid);
    append(release_group);
    append(legacy_user_text(major, "MUSICBRAINZ_ALBUMID", old_id));
    append(recording);
    append(replay_gain);
    append(cover);
    const auto original = with_audio(build_tag(major, frames));

    const auto written = apply_rewrite(original,
                                       {Change{.field = Field::musicbrainz_release_id,
                                               .before = std::string(old_id),
                                               .after = std::string(new_id)}},
                                       std::nullopt);
    CHECK(written[3] == std::byte{major});
    for (const auto& kept : {title, foreign_ufid, release_group, recording, replay_gain, cover}) {
        CHECK(contains(written, kept));
    }
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    CHECK(after->musicbrainz_release_id == std::optional<std::string_view>(new_id));
    CHECK(after->musicbrainz_release_group_id == std::optional<std::string_view>(release_group_id));
    CHECK(after->musicbrainz_recording_id == std::optional<std::string_view>(recording_id));
    CHECK(after->title == std::optional<std::string_view>("Kept"));
    REQUIRE(after->artwork.has_value());
    CHECK(after->artwork->byte_size == 32);
    CHECK_FALSE(contains_text(written, "MUSICBRAINZ_ALBUMID"));
    CHECK_FALSE(contains_text(written, old_id));
    CHECK(count_user_text(written, "MusicBrainz Album Id") == 1);
    const auto expected = expected_user_text_frame(major, "MusicBrainz Album Id", new_id);
    CHECK(contains(written, expected));
    const std::string_view text(reinterpret_cast<const char*>(written.data()), written.size());
    CHECK(text.ends_with("audio"));
}

TEST_CASE("a release id replaces the uppercase spelling and keeps other descriptions, owners and "
          "the cover in 2.4") {
    expect_release_id_rewrite(4);
}

TEST_CASE("a release id replaces the uppercase spelling and keeps other descriptions, owners and "
          "the cover in 2.3") {
    expect_release_id_rewrite(3);
}

TEST_CASE("release ids written to a cover-only 2.3 tag keep cover and ReplayGain and gain trailer "
          "values") {
    const auto cover = build_frame("APIC", 3, cover_body(32));
    const auto replay_gain = build_frame("TXXX", 3, payload("\0REPLAYGAIN_TRACK_GAIN\0-6.50 dB"));
    const auto trailer = legacy_trailer("1999");
    const auto frames = concat(cover, replay_gain);
    auto original = with_audio(build_tag(3, frames));
    original.insert(original.end(), trailer.begin(), trailer.end());

    const auto written =
        apply_rewrite(original, release_id_changes(nullptr, first_release_ids), std::nullopt);
    CHECK(written[3] == std::byte{3});
    CHECK(std::memcmp(written.data() + 10, cover.data(), cover.size()) == 0);
    CHECK(std::memcmp(written.data() + 10 + cover.size(), replay_gain.data(), replay_gain.size()) ==
          0);
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    expect_trailer_values(*after, "Song", "1999");
    expect_release_ids(*after, first_release_ids);
    REQUIRE(after->artwork.has_value());
    CHECK(after->artwork->byte_size == 32);
    CHECK(std::memcmp(written.data() + written.size() - 128, trailer.data(), 128) == 0);
}

TEST_CASE("release ids given to a trailer-only stream keep every trailer value in the new tag") {
    const auto trailer = legacy_trailer("1999");
    auto original = with_audio(std::vector<std::byte>{});
    original.insert(original.end(), trailer.begin(), trailer.end());

    const auto written =
        apply_rewrite(original, release_id_changes(nullptr, first_release_ids), std::nullopt);
    CHECK(written[3] == std::byte{4});
    orca::metadata::Arena arena;
    const auto after = read_tags(arena, written);
    REQUIRE(after.has_value());
    expect_trailer_values(*after, "Song", "1999");
    expect_release_ids(*after, first_release_ids);
    CHECK(std::memcmp(written.data() + written.size() - 128, trailer.data(), 128) == 0);
}
