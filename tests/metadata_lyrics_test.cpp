#include "liborca/metadata/lyrics.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstdint>
#include <doctest/doctest.h>
#include <filesystem>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

namespace {

auto fixture(std::string_view name) -> std::filesystem::path {
    return std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / name;
}

auto synced(std::initializer_list<std::uint32_t> starts) -> orca::metadata::lyrics::Content {
    orca::metadata::lyrics::Content content;
    content.kind = orca::metadata::lyrics::Kind::synced;
    for (const std::uint32_t start : starts) {
        content.lines.push_back(orca::metadata::lyrics::Line{.start_ms = start, .text = {}});
    }
    return content;
}

}

TEST_CASE("no line is current before the first line starts") {
    const auto lyrics = synced({1000, 2000});
    CHECK_FALSE(orca::metadata::lyrics::line_at(lyrics, 999).has_value());
    CHECK(orca::metadata::lyrics::line_at(lyrics, 1000) == std::optional<std::size_t>(0));
}

TEST_CASE("the last line stays current after it starts") {
    const auto lyrics = synced({1000, 2000});
    CHECK(orca::metadata::lyrics::line_at(lyrics, 2000) == std::optional<std::size_t>(1));
    CHECK(orca::metadata::lyrics::line_at(lyrics, 600'000) == std::optional<std::size_t>(1));
}

TEST_CASE("of two lines sharing a start the later one is current") {
    const auto lyrics = synced({1000, 3000, 3000, 5000});
    CHECK(orca::metadata::lyrics::line_at(lyrics, 3000) == std::optional<std::size_t>(2));
    CHECK(orca::metadata::lyrics::line_at(lyrics, 4999) == std::optional<std::size_t>(2));
}

TEST_CASE("plain lyrics have no current line") {
    orca::metadata::lyrics::Content content;
    content.kind = orca::metadata::lyrics::Kind::plain;
    CHECK_FALSE(orca::metadata::lyrics::line_at(content, 10'000).has_value());
}

TEST_CASE("a language code is three letters other than the placeholder") {
    CHECK(orca::metadata::lyrics::language_code({'E', 'N', 'G'}) ==
          std::optional<std::array<char, 3>>({'e', 'n', 'g'}));
    CHECK_FALSE(orca::metadata::lyrics::language_code({'X', 'X', 'X'}).has_value());
    CHECK_FALSE(orca::metadata::lyrics::language_code({'e', '\0', 'g'}).has_value());
}

namespace {

auto synced_lyrics(std::initializer_list<std::uint32_t> starts) -> orca::metadata::lyrics::Lyrics {
    orca::metadata::lyrics::Content content;
    content.kind = orca::metadata::lyrics::Kind::synced;
    for (const std::uint32_t start : starts) {
        content.lines.push_back(orca::metadata::lyrics::Line{.start_ms = start, .text = {}});
    }
    return orca::metadata::lyrics::adopt(orca::metadata::Arena{}, std::move(content),
                                         orca::metadata::lyrics::Source::sidecar);
}

}

TEST_CASE("the wrapper finds the current line like the content does") {
    const auto lyrics = synced_lyrics({1000, 2000});
    CHECK_FALSE(lyrics.line_at(999).has_value());
    CHECK(lyrics.line_at(1000) == std::optional<std::size_t>(0));
    CHECK(lyrics.line_at(600'000) == std::optional<std::size_t>(1));
}

TEST_CASE("plain parsed lyrics have no current line") {
    const auto parsed =
        orca::metadata::lyrics::parse("one\ntwo\n", orca::metadata::lyrics::Source::sidecar);
    REQUIRE(parsed.has_value());
    REQUIRE(parsed->has_value());
    CHECK((*parsed)->kind() == orca::metadata::lyrics::Kind::plain);
    CHECK_FALSE((*parsed)->line_at(10'000).has_value());
    CHECK((*parsed)->source() == orca::metadata::lyrics::Source::sidecar);
    CHECK((*parsed)->source_name().empty());
}

TEST_CASE("a sidecar's name is copied into the lyrics") {
    auto lyrics = synced_lyrics({1000});
    lyrics.set_source_name("track.lrc");
    CHECK(lyrics.source_name() == "track.lrc");
}

TEST_CASE("instrumental lyrics carry no lines") {
    const auto lyrics =
        orca::metadata::lyrics::instrumental(orca::metadata::lyrics::Source::embedded);
    CHECK(lyrics.kind() == orca::metadata::lyrics::Kind::instrumental);
    CHECK(lyrics.lines().empty());
    CHECK(lyrics.source_name() == "embedded");
}

TEST_CASE("embedded lyrics are read from each fixture container") {
    struct Case {
        std::string_view name;
        orca::metadata::lyrics::Kind kind;
        std::string_view first;
    };
    const std::array<Case, 3> cases = {
        Case{"lyrics-synced.flac", orca::metadata::lyrics::Kind::synced, "First line of the FLAC"},
        Case{"lyrics-sylt.mp3", orca::metadata::lyrics::Kind::synced, "First synced line"},
        Case{"lyrics-plain.m4a", orca::metadata::lyrics::Kind::plain, "Plain first line"},
    };
    for (const Case& item : cases) {
        CAPTURE(item.name);
        const auto opened = orca::storage::LocalFileSource::open(fixture(item.name));
        REQUIRE(opened.has_value());
        const auto lyrics = orca::metadata::lyrics::read_embedded(*opened);
        REQUIRE(lyrics.has_value());
        CHECK(lyrics->source() == orca::metadata::lyrics::Source::embedded);
        CHECK(lyrics->kind() == item.kind);
        CHECK(lyrics->source_name() == "embedded");
        REQUIRE_FALSE(lyrics->lines().empty());
        CHECK(lyrics->lines().front().text == item.first);
    }
}

TEST_CASE("a file without lyrics reads as none") {
    const auto opened = orca::storage::LocalFileSource::open(fixture("tagged-reference.flac"));
    REQUIRE(opened.has_value());
    CHECK_FALSE(orca::metadata::lyrics::read_embedded(*opened).has_value());
}

TEST_CASE("bytes that are no container read as none") {
    const orca::storage::MemorySource source("not audio at all");
    CHECK_FALSE(orca::metadata::lyrics::read_embedded(source).has_value());
}
