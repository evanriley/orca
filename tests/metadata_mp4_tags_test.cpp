#include "liborca/metadata/mp4_tags.hpp"
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
    const auto tags = orca::metadata::mp4_tags::read(arena, *file);
    REQUIRE(tags.has_value());
    return *tags;
}

template <typename Container>
void append_to(std::vector<std::byte>& out, const Container& part) {
    for (const std::byte value : part) {
        out.push_back(value);
    }
}

void put_be32(std::vector<std::byte>& out, std::uint32_t value) {
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((value >> ((3 - index) * 8U)) & 0xffU));
    }
}

void append_text(std::vector<std::byte>& out, std::string_view text) {
    for (const char value : text) {
        out.push_back(static_cast<std::byte>(value));
    }
}

auto box(std::string_view kind, const std::vector<std::byte>& body) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    put_be32(out, static_cast<std::uint32_t>(8 + body.size()));
    append_text(out, kind);
    append_to(out, body);
    return out;
}

auto concat(const std::vector<std::vector<std::byte>>& parts) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    for (const auto& part : parts) {
        append_to(out, part);
    }
    return out;
}

auto item(std::string_view kind, std::uint32_t type, const std::vector<std::byte>& payload)
    -> std::vector<std::byte> {
    std::vector<std::byte> data;
    data.push_back(std::byte{0});
    data.push_back(static_cast<std::byte>((type >> 16U) & 0xffU));
    data.push_back(static_cast<std::byte>((type >> 8U) & 0xffU));
    data.push_back(static_cast<std::byte>(type & 0xffU));
    for (int index = 0; index < 4; ++index) {
        data.push_back(std::byte{0});
    }
    append_to(data, payload);
    return box(kind, box("data", data));
}

auto text_payload(std::string_view text) -> std::vector<std::byte> {
    std::vector<std::byte> out;
    append_text(out, text);
    return out;
}

auto movie(const std::vector<std::vector<std::byte>>& items) -> std::vector<std::byte> {
    std::vector<std::byte> meta_body = {std::byte{0}, std::byte{0}, std::byte{0}, std::byte{0}};
    const auto ilst = box("ilst", concat(items));
    append_to(meta_body, ilst);
    return box("moov", box("udta", box("meta", meta_body)));
}

auto read_memory(orca::metadata::Arena& arena, const std::vector<std::byte>& bytes)
    -> std::optional<orca::metadata::ObservedTags> {
    orca::storage::MemorySource source(bytes);
    const auto tags = orca::metadata::mp4_tags::read(arena, source);
    REQUIRE(tags.has_value());
    return *tags;
}

}

TEST_CASE("iTunes atoms of an AAC file yield canonical tags") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "tagged-reference-aac.m4a");
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("AAC Reference"));
    CHECK(tags->artist == std::optional<std::string_view>("Orca Fixtures"));
    CHECK(tags->album_artist == std::optional<std::string_view>("Orca Fixtures"));
    CHECK(tags->album == std::optional<std::string_view>("Codec References"));
    CHECK(tags->date == std::optional<std::string_view>("2026"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(2));
    CHECK(tags->track_total == std::optional<std::uint32_t>(5));
    CHECK(tags->disc_number == std::optional<std::uint32_t>(1));
    CHECK(tags->disc_total == std::optional<std::uint32_t>(2));
    REQUIRE(tags->genres.size() == 1);
    CHECK(tags->genres[0] == "Test Tone");
}

TEST_CASE("iTunes atoms of an ALAC file carry the tags of the FLAC it came from") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "tagged-reference-alac.m4a");
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Reference Tone"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(1));
    CHECK(tags->track_total == std::optional<std::uint32_t>(3));
}

TEST_CASE("an rtng atom of 1 marks an MP4 file explicit") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "explicit-reference.m4a");
    REQUIRE(tags.has_value());
    CHECK(tags->explicit_flag == std::optional(orca::metadata::Explicit::explicit_value));
    CHECK(tags->track_number == std::optional<std::uint32_t>(2));
    CHECK(tags->track_total == std::optional<std::uint32_t>(2));
}

TEST_CASE("an MP4 file without an rtng atom states no advisory") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "tagged-reference-aac.m4a");
    REQUIRE(tags.has_value());
    CHECK_FALSE(tags->explicit_flag.has_value());
}

TEST_CASE("a cover atom is observed and read back as the same image") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "covered-reference.m4a");
    REQUIRE(tags.has_value());
    REQUIRE(tags->artwork.has_value());
    CHECK(tags->artwork->mime_type == "image/png");
    CHECK(tags->artwork->byte_size == 217);

    auto file = orca::storage::LocalFileSource::open(fixture("covered-reference.m4a"));
    REQUIRE(file.has_value());
    const auto image = orca::metadata::mp4_tags::read_picture(*file);
    REQUIRE(image.has_value());
    REQUIRE(image->has_value());
    CHECK((*image)->bytes.size() == 217);
    CHECK((*image)->mime_type == "image/png");
}

TEST_CASE("a genre stored as an ID3v1 number is named") {
    orca::metadata::Arena arena;
    std::vector<std::byte> payload = {std::byte{0}, std::byte{10}};
    const auto tags = read_memory(arena, movie({item("gnre", 0, payload)}));
    REQUIRE(tags.has_value());
    REQUIRE(tags->genres.size() == 1);
    CHECK(tags->genres[0] == "Metal");
}

TEST_CASE("the composer and comment atoms are read and text is trimmed") {
    orca::metadata::Arena arena;
    const auto tags = read_memory(arena, movie({item("\xa9"
                                                     "wrt",
                                                     1, text_payload("Nick Drake")),
                                                item("\xa9"
                                                     "cmt",
                                                     1, text_payload("Remastered "))}));
    REQUIRE(tags.has_value());
    CHECK(tags->composer == std::optional<std::string_view>("Nick Drake"));
    CHECK(tags->comment == std::optional<std::string_view>("Remastered"));
}

TEST_CASE("a binary data atom is not read as text") {
    orca::metadata::Arena arena;
    const auto tags = read_memory(arena, movie({item("\xa9"
                                                     "nam",
                                                     0, text_payload("Title")),
                                                item("\xa9"
                                                     "ART",
                                                     1, text_payload("Artist"))}));
    REQUIRE(tags.has_value());
    CHECK_FALSE(tags->title.has_value());
    CHECK(tags->artist == std::optional<std::string_view>("Artist"));
}
