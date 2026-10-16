#include "liborca/metadata/ogg_comment.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <filesystem>
#include <optional>
#include <string_view>
#include <vector>

namespace {

auto fixture(std::string_view name) -> std::filesystem::path {
    return std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / name;
}

auto read_fixture(orca::metadata::Arena& arena, std::string_view name)
    -> std::optional<orca::metadata::ObservedTags> {
    auto file = orca::storage::LocalFileSource::open(fixture(name));
    REQUIRE(file.has_value());
    const auto tags = orca::metadata::ogg_comment::read(arena, *file);
    REQUIRE(tags.has_value());
    return *tags;
}

}

TEST_CASE("an Ogg Opus comment header yields canonical tags") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "tagged-reference.opus");
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Opus Reference"));
    CHECK(tags->artist == std::optional<std::string_view>("Orca Fixtures"));
    CHECK(tags->album == std::optional<std::string_view>("Codec References"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(3));
    CHECK(tags->date == std::optional<std::string_view>("2026"));
    REQUIRE(tags->genres.size() == 1);
    CHECK(tags->genres[0] == "Test Tone");
}

TEST_CASE("an Ogg Vorbis comment header yields canonical tags") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "tagged-reference.ogg");
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Reference Tone"));
    CHECK(tags->artist == std::optional<std::string_view>("Orca Test"));
    CHECK(tags->album == std::optional<std::string_view>("Fixtures"));
    CHECK(tags->album_artist == std::optional<std::string_view>("Orca Test"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(1));
    CHECK(tags->track_total == std::optional<std::uint32_t>(3));
}

TEST_CASE("an Ogg stream of another codec yields no tags") {
    orca::metadata::Arena arena;
    std::vector<std::byte> page(27 + 1 + 5, std::byte{0});
    std::memcpy(page.data(), "OggS", 4);
    page[26] = std::byte{1};
    page[27] = std::byte{5};
    std::memcpy(page.data() + 28,
                "\x7f"
                "FLAC",
                5);
    orca::storage::MemorySource source(page);
    const auto tags = orca::metadata::ogg_comment::read(arena, source);
    REQUIRE(tags.has_value());
    CHECK_FALSE(tags->has_value());
}

TEST_CASE("bytes that are not Ogg pages are rejected") {
    orca::metadata::Arena arena;
    std::vector<std::byte> bytes;
    for (const char value : std::string_view("fLaC")) {
        bytes.push_back(static_cast<std::byte>(value));
    }
    bytes.insert(bytes.end(), 40, std::byte{0});
    orca::storage::MemorySource source(bytes);
    const auto tags = orca::metadata::ogg_comment::read(arena, source);
    REQUIRE_FALSE(tags.has_value());
    CHECK(tags.error().code == orca::ErrorCode::invalid_ogg_stream);
}

TEST_CASE("a page that claims more bytes than the stream holds is truncated") {
    orca::metadata::Arena arena;
    std::vector<std::byte> page(27 + 1, std::byte{0});
    std::memcpy(page.data(), "OggS", 4);
    page[26] = std::byte{1};
    page[27] = std::byte{200};
    orca::storage::MemorySource source(page);
    const auto tags = orca::metadata::ogg_comment::read(arena, source);
    REQUIRE_FALSE(tags.has_value());
    CHECK(tags.error().code == orca::ErrorCode::truncated_ogg_stream);
}

TEST_CASE("a stream of empty pages is abandoned after a bounded number of them") {
    orca::metadata::Arena arena;
    std::vector<std::byte> bytes;
    for (std::size_t index = 0; index < 4097; ++index) {
        std::vector<std::byte> page(27, std::byte{0});
        std::memcpy(page.data(), "OggS", 4);
        bytes.insert(bytes.end(), page.begin(), page.end());
    }
    orca::storage::MemorySource source(bytes);
    const auto tags = orca::metadata::ogg_comment::read(arena, source);
    REQUIRE_FALSE(tags.has_value());
    CHECK(tags.error().code == orca::ErrorCode::ogg_comment_not_found);
}

TEST_CASE("a METADATA_BLOCK_PICTURE comment is observed and read back as the same image") {
    for (const std::string_view name : {"covered-reference.opus", "covered-reference.ogg"}) {
        orca::metadata::Arena arena;
        const auto tags = read_fixture(arena, name);
        REQUIRE(tags.has_value());
        REQUIRE(tags->artwork.has_value());
        CHECK(tags->artwork->mime_type == "image/png");
        CHECK(tags->artwork->byte_size == 217);
        CHECK(tags->artwork->kind == orca::metadata::ArtworkKind::front_cover);

        auto file = orca::storage::LocalFileSource::open(fixture(name));
        REQUIRE(file.has_value());
        const auto image = orca::metadata::ogg_comment::read_picture(*file);
        REQUIRE(image.has_value());
        REQUIRE(image->has_value());
        CHECK((*image)->bytes.size() == 217);
        CHECK((*image)->mime_type == "image/png");
    }
}

TEST_CASE("an Ogg stream without a picture comment has no cover") {
    auto file = orca::storage::LocalFileSource::open(fixture("tagged-reference.opus"));
    REQUIRE(file.has_value());
    const auto image = orca::metadata::ogg_comment::read_picture(*file);
    REQUIRE(image.has_value());
    CHECK_FALSE(image->has_value());
}
