#include "liborca/base/bounded.hpp"
#include "liborca/base/checked.hpp"
#include "liborca/base/path.hpp"
#include "liborca/base/string.hpp"
#include "liborca/base/time.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <doctest/doctest.h>
#include <filesystem>
#include <limits>
#include <span>
#include <string>
#include <string_view>
#include <vector>

TEST_CASE("checked add, sub and mul report overflow") {
    CHECK(orca::checked::add<std::int32_t>(1, 2).value() == 3);
    CHECK_FALSE(
        orca::checked::add<std::int32_t>(std::numeric_limits<std::int32_t>::max(), 1).has_value());
    CHECK(orca::checked::add<std::uint8_t>(std::uint8_t{200}, std::uint8_t{55}).value() == 255);
    CHECK_FALSE(orca::checked::add<std::uint8_t>(std::uint8_t{200}, std::uint8_t{56}).has_value());

    CHECK(orca::checked::sub<std::int32_t>(5, 2).value() == 3);
    CHECK_FALSE(orca::checked::sub<std::uint32_t>(0, 1).has_value());
    CHECK_FALSE(
        orca::checked::sub<std::int32_t>(std::numeric_limits<std::int32_t>::min(), 1).has_value());

    CHECK(orca::checked::mul<std::int32_t>(6, 7).value() == 42);
    CHECK_FALSE(orca::checked::mul<std::int32_t>(100000, 100000).has_value());
}

TEST_CASE("checked div and narrow reject bad inputs") {
    CHECK(orca::checked::div<std::int32_t>(7, 2).value() == 3);
    CHECK_FALSE(orca::checked::div<std::int32_t>(1, 0).has_value());
    CHECK_FALSE(
        orca::checked::div<std::int32_t>(std::numeric_limits<std::int32_t>::min(), -1).has_value());

    CHECK(orca::checked::narrow<std::uint8_t>(std::int32_t{200}).value() == 200);
    CHECK_FALSE(orca::checked::narrow<std::uint8_t>(std::int32_t{300}).has_value());
    CHECK_FALSE(orca::checked::narrow<std::uint8_t>(std::int32_t{-1}).has_value());
}

TEST_CASE("BoundedVector respects capacity and lifetimes") {
    orca::BoundedVector<int, 3> values;
    CHECK(values.try_push_back(1));
    CHECK(values.try_push_back(2));
    CHECK(values.try_push_back(3));
    CHECK_FALSE(values.try_push_back(4));
    CHECK(values.size() == 3);
    CHECK(values.full());
    values.pop_back();
    CHECK(values.size() == 2);
    CHECK(values[0] == 1);
    CHECK(values[1] == 2);

    orca::BoundedVector<std::string, 2> names;
    CHECK(names.try_emplace_back("hello") != nullptr);
    CHECK(names.try_emplace_back(3, 'x') != nullptr);
    CHECK(names.try_emplace_back("overflow") == nullptr);
    CHECK(names[0] == "hello");
    CHECK(names[1] == "xxx");

    orca::BoundedVector<std::string, 2> copied = names;
    CHECK(copied.size() == 2);
    CHECK(copied[1] == "xxx");
    copied.clear();
    CHECK(copied.empty());
}

TEST_CASE("string helpers trim, split and parse") {
    CHECK(orca::strings::trim("  hello \t") == "hello");
    CHECK(orca::strings::trim_left("\n hi") == "hi");
    CHECK(orca::strings::trim_right("hi \r\n") == "hi");
    CHECK(orca::strings::to_upper_ascii("Abc1") == "ABC1");
    CHECK(orca::strings::to_lower_ascii("AbC1") == "abc1");

    const std::vector<std::string_view> parts = orca::strings::split("a,b,c", ',');
    REQUIRE(parts.size() == 3);
    CHECK(parts[0] == "a");
    CHECK(parts[1] == "b");
    CHECK(parts[2] == "c");

    CHECK(orca::strings::parse_int64("42").value() == 42);
    CHECK_FALSE(orca::strings::parse_int64("4x").has_value());
    CHECK_FALSE(orca::strings::parse_int64("").has_value());
    CHECK(orca::strings::parse_uint64("18446744073709551615").value() ==
          std::numeric_limits<std::uint64_t>::max());
    CHECK_FALSE(orca::strings::parse_uint64("-1").has_value());
    CHECK(orca::strings::parse_float64("3.5").value() == doctest::Approx(3.5));
}

TEST_CASE("hex encoding round trips") {
    const std::array<std::byte, 3> bytes{std::byte{0xAB}, std::byte{0x01}, std::byte{0xFF}};
    CHECK(orca::strings::hex_encode(bytes) == "ab01ff");

    const auto decoded = orca::strings::hex_decode("ab01ff");
    REQUIRE(decoded.has_value());
    REQUIRE(decoded->size() == 3);
    CHECK(std::to_integer<int>((*decoded)[0]) == 0xAB);
    CHECK(std::to_integer<int>((*decoded)[1]) == 0x01);
    CHECK(std::to_integer<int>((*decoded)[2]) == 0xFF);

    CHECK_FALSE(orca::strings::hex_decode("abc").has_value());
    CHECK_FALSE(orca::strings::hex_decode("zz").has_value());
}

TEST_CASE("time helpers convert and format") {
    CHECK(orca::time::format_rfc3339(0).value() == "1970-01-01T00:00:00Z");
    CHECK(orca::time::format_rfc3339(1700000000).value() == "2023-11-14T22:13:20Z");
    CHECK_FALSE(orca::time::format_rfc3339(std::numeric_limits<std::int64_t>::max()).has_value());
    CHECK(orca::time::to_unix(orca::time::from_unix(12345)) == 12345);
    CHECK(orca::time::now_unix_seconds() > 0);
}

TEST_CASE("path helpers convert and bound file reads") {
    const auto value = orca::fs::from_utf8("music/album/track.FLAC");
    CHECK(orca::fs::to_utf8(value) == "music/album/track.FLAC");
    CHECK(orca::fs::extension_lower(value) == ".flac");

    const auto directory = std::filesystem::temp_directory_path() / "orca-base-test";
    std::filesystem::create_directories(directory);
    const auto file = directory / "sample.txt";

    REQUIRE(orca::fs::write_file(file, "hello").has_value());
    const auto read = orca::fs::read_file(file, 1024);
    REQUIRE(read.has_value());
    CHECK(*read == "hello");
    CHECK_FALSE(orca::fs::read_file(file, 2).has_value());

    std::filesystem::remove(file);
    std::filesystem::remove(directory);
}
