#include "liborca/metadata/lrc.hpp"

#include <cstdint>
#include <doctest/doctest.h>
#include <limits>
#include <string>
#include <string_view>

namespace {

auto parsed(orca::metadata::Arena& arena, std::string_view text)
    -> std::optional<orca::metadata::lyrics::Content> {
    const auto content = orca::metadata::lrc::parse(arena, text);
    REQUIRE(content.has_value());
    return *content;
}

}

TEST_CASE("a line with two leading timestamps becomes one line at each") {
    orca::metadata::Arena arena;
    const auto content = parsed(arena, "[00:12.40][01:30.00]Chorus\n[00:20.00]Verse\n");
    REQUIRE(content.has_value());
    CHECK(content->kind == orca::metadata::lyrics::Kind::synced);
    REQUIRE(content->lines.size() == 3);
    CHECK(content->lines[0].start_ms == std::optional<std::uint32_t>(12400));
    CHECK(content->lines[0].text == "Chorus");
    CHECK(content->lines[1].start_ms == std::optional<std::uint32_t>(20000));
    CHECK(content->lines[2].start_ms == std::optional<std::uint32_t>(90000));
    CHECK(content->lines[2].text == "Chorus");
}

TEST_CASE("a positive offset moves lines earlier and clamps at zero") {
    orca::metadata::Arena arena;
    const auto content = parsed(arena, "[offset:+500]\n[00:00.20]Early\n[00:01.00]Second\n");
    REQUIRE(content.has_value());
    CHECK(content->lines[0].start_ms == std::optional<std::uint32_t>(0));
    CHECK(content->lines[1].start_ms == std::optional<std::uint32_t>(500));
}

TEST_CASE("a negative offset moves lines later") {
    orca::metadata::Arena arena;
    const auto content = parsed(arena, "[00:01.00]Line\n[offset:-250]\n");
    REQUIRE(content.has_value());
    CHECK(content->lines[0].start_ms == std::optional<std::uint32_t>(1250));
}

TEST_CASE("an offset at the limits of its type clamps instead of overflowing") {
    orca::metadata::Arena arena;
    const auto content = parsed(arena, "[offset:-9223372036854775808]\n[00:01.00]Late\n");
    REQUIRE(content.has_value());
    CHECK(content->lines[0].start_ms ==
          std::optional<std::uint32_t>(std::numeric_limits<std::uint32_t>::max()));

    orca::metadata::Arena max_arena;
    const auto early = parsed(max_arena, "[offset:9223372036854775807]\n[00:01.00]Early\n");
    REQUIRE(early.has_value());
    CHECK(early->lines[0].start_ms == std::optional<std::uint32_t>(0));
}

TEST_CASE("one fractional digit is tenths and single-digit minutes are accepted") {
    orca::metadata::Arena arena;
    const auto content = parsed(arena, "[1:02.5]Tenths\n[00:03.123]Millis\n[00:04]Whole\n");
    REQUIRE(content.has_value());
    CHECK(content->lines[0].start_ms == std::optional<std::uint32_t>(3123));
    CHECK(content->lines[1].start_ms == std::optional<std::uint32_t>(4000));
    CHECK(content->lines[2].start_ms == std::optional<std::uint32_t>(62500));
}

TEST_CASE("a timestamp with sixty or more seconds drops only its own line") {
    orca::metadata::Arena arena;
    const auto content = parsed(arena, "[00:61.00]Bad\n[00:02.00]Good\n");
    REQUIRE(content.has_value());
    REQUIRE(content->lines.size() == 1);
    CHECK(content->lines[0].text == "Good");
}

TEST_CASE("text with only ID tags and comments carries no lyrics") {
    orca::metadata::Arena arena;
    const auto content = orca::metadata::lrc::parse(
        arena, "[ar:Artist]\r\n[ti:Title]\r\n# a comment\r\n[length:03:20]\r\n");
    REQUIRE(content.has_value());
    CHECK_FALSE(content->has_value());
}

TEST_CASE("enhanced word stamps are removed from the line text") {
    orca::metadata::Arena arena;
    const auto content = parsed(arena, "[00:01.00]<00:01.00>Hello <00:01.50>world\n");
    REQUIRE(content.has_value());
    CHECK(content->lines[0].text == "Hello world");
}

TEST_CASE("text without timestamps is plain, one line per row, with BOM and CRLF tolerated") {
    orca::metadata::Arena arena;
    const auto content = parsed(
        arena, "\xef\xbb\xbf\r\n[ar:Someone]\r\nFirst row\r\n\r\n[Chorus]\r\nSecond row\r\n\r\n");
    REQUIRE(content.has_value());
    CHECK(content->kind == orca::metadata::lyrics::Kind::plain);
    REQUIRE(content->lines.size() == 4);
    CHECK(content->lines[0].text == "First row");
    CHECK(content->lines[1].text == "");
    CHECK(content->lines[2].text == "[Chorus]");
    CHECK_FALSE(content->lines[3].start_ms.has_value());
}

TEST_CASE("timed lines win over untimed rows in the same text") {
    orca::metadata::Arena arena;
    const auto content = parsed(arena, "Title row\n[00:05.00]Five\n[00:01.00]One\n");
    REQUIRE(content.has_value());
    CHECK(content->kind == orca::metadata::lyrics::Kind::synced);
    REQUIRE(content->lines.size() == 2);
    CHECK(content->lines[0].text == "One");
}

TEST_CASE("text that is not UTF-8 is not lyrics") {
    orca::metadata::Arena arena;
    const auto content = orca::metadata::lrc::parse(arena, "[00:01.00]caf\xe9\n");
    REQUIRE(content.has_value());
    CHECK_FALSE(content->has_value());
}

TEST_CASE("more lines than the bound is not lyrics") {
    std::string text;
    for (std::size_t index = 0; index <= orca::metadata::lyrics::max_lines; ++index) {
        text += "la\n";
    }
    orca::metadata::Arena arena;
    const auto content = orca::metadata::lrc::parse(arena, text);
    REQUIRE(content.has_value());
    CHECK_FALSE(content->has_value());
}
