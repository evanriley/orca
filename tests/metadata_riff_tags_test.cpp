#include "liborca/metadata/id3v2.hpp"
#include "liborca/metadata/riff_tags.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string_view>
#include <vector>

namespace {

class FailingSource final : public orca::storage::ReadableSource {
public:
    explicit FailingSource(std::uint64_t size) : size_(size) {}

    auto read_at(std::uint64_t, std::span<std::byte>) const
        -> orca::expected<std::size_t> override {
        return orca::fail(orca::ErrorCode::io, "injected read failure");
    }
    auto size() const -> std::uint64_t override {
        return size_;
    }
    auto identity() const -> orca::storage::StorageIdentity override {
        return {};
    }

private:
    std::uint64_t size_;
};

auto fixture(std::string_view name) -> std::filesystem::path {
    return std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / name;
}

auto read_fixture(orca::metadata::Arena& arena, std::string_view name)
    -> std::optional<orca::metadata::ObservedTags> {
    auto file = orca::storage::LocalFileSource::open(fixture(name));
    REQUIRE(file.has_value());
    const auto tags = orca::metadata::riff_tags::read(arena, *file);
    REQUIRE(tags.has_value());
    return *tags;
}

auto read_bytes(orca::metadata::Arena& arena, const std::vector<std::byte>& bytes)
    -> std::optional<orca::metadata::ObservedTags> {
    orca::storage::MemorySource source(bytes);
    const auto tags = orca::metadata::riff_tags::read(arena, source);
    REQUIRE(tags.has_value());
    return *tags;
}

template <std::size_t Size>
void append(std::vector<std::byte>& out, const char (&text)[Size]) {
    for (std::size_t index = 0; index + 1 < Size; ++index) {
        out.push_back(static_cast<std::byte>(text[index]));
    }
}

void put_le32(std::vector<std::byte>& out, std::uint32_t value) {
    for (std::size_t index = 0; index < 4; ++index) {
        out.push_back(static_cast<std::byte>((value >> (index * 8U)) & 0xffU));
    }
}

auto wav_with_info(const std::vector<std::pair<std::string, std::string>>& fields)
    -> std::vector<std::byte> {
    std::vector<std::byte> info;
    append(info, "INFO");
    for (const auto& [id, value] : fields) {
        for (const char character : id) {
            info.push_back(static_cast<std::byte>(character));
        }
        put_le32(info, static_cast<std::uint32_t>(value.size()));
        for (const char character : value) {
            info.push_back(static_cast<std::byte>(character));
        }
        if (value.size() % 2 != 0) {
            info.push_back(std::byte{0});
        }
    }
    std::vector<std::byte> out;
    append(out, "RIFF");
    put_le32(out, 0);
    append(out, "WAVE");
    append(out, "LIST");
    put_le32(out, static_cast<std::uint32_t>(info.size()));
    out.insert(out.end(), info.begin(), info.end());
    const std::uint32_t riff_size = static_cast<std::uint32_t>(out.size() - 8);
    for (std::size_t index = 0; index < 4; ++index) {
        out[4 + index] = static_cast<std::byte>((riff_size >> (index * 8U)) & 0xffU);
    }
    return out;
}

auto read_file(std::string_view name) -> std::vector<std::byte> {
    std::ifstream input(fixture(name), std::ios::binary);
    REQUIRE(input.good());
    input.seekg(0, std::ios::end);
    const std::streamoff size = input.tellg();
    input.seekg(0, std::ios::beg);
    std::vector<std::byte> bytes(static_cast<std::size_t>(size));
    input.read(reinterpret_cast<char*>(bytes.data()), size);
    return bytes;
}

auto with_cover_only_id3(std::string_view name) -> std::vector<std::byte> {
    const auto original = read_file(name);
    std::vector<std::byte> picture;
    append(picture, "\x00image/png\x00\x03\x00");
    for (int index = 0; index < 32; ++index) {
        picture.push_back(std::byte{0x5a});
    }
    std::vector<std::byte> frame;
    append(frame, "APIC");
    put_le32(frame, 0);
    frame[4] = static_cast<std::byte>((picture.size() >> 24U) & 0xffU);
    frame[5] = static_cast<std::byte>((picture.size() >> 16U) & 0xffU);
    frame[6] = static_cast<std::byte>((picture.size() >> 8U) & 0xffU);
    frame[7] = static_cast<std::byte>(picture.size() & 0xffU);
    frame.push_back(std::byte{0});
    frame.push_back(std::byte{0});
    for (const std::byte value : picture) {
        frame.push_back(value);
    }

    std::vector<std::byte> tag;
    append(tag, "ID3");
    tag.push_back(std::byte{3});
    tag.push_back(std::byte{0});
    tag.push_back(std::byte{0});
    const std::size_t length = frame.size();
    tag.push_back(static_cast<std::byte>((length >> 21U) & 0x7fU));
    tag.push_back(static_cast<std::byte>((length >> 14U) & 0x7fU));
    tag.push_back(static_cast<std::byte>((length >> 7U) & 0x7fU));
    tag.push_back(static_cast<std::byte>(length & 0x7fU));
    for (const std::byte value : frame) {
        tag.push_back(value);
    }

    std::vector<std::byte> chunk_header;
    append(chunk_header, "id3 ");
    put_le32(chunk_header, static_cast<std::uint32_t>(tag.size()));

    std::vector<std::byte> bytes = original;
    bytes.insert(bytes.end(), chunk_header.begin(), chunk_header.end());
    bytes.insert(bytes.end(), tag.begin(), tag.end());
    put_le32(bytes, 0);
    const std::uint32_t riff_size = static_cast<std::uint32_t>(bytes.size() - 8);
    for (std::size_t index = 0; index < 4; ++index) {
        bytes[4 + index] = static_cast<std::byte>((riff_size >> (index * 8U)) & 0xffU);
    }
    return bytes;
}

}

TEST_CASE("a RIFF read failure is an error, not an absent tag") {
    orca::metadata::Arena arena;
    FailingSource source(200);
    const auto tags = orca::metadata::riff_tags::read(arena, source);
    REQUIRE_FALSE(tags.has_value());
    CHECK(tags.error().code == orca::ErrorCode::io);
}

TEST_CASE("a WAV LIST/INFO chunk yields canonical tags") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "tagged-reference.wav");
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("WAV Reference"));
    CHECK(tags->artist == std::optional<std::string_view>("Orca Fixtures"));
    CHECK(tags->album == std::optional<std::string_view>("Codec References"));
    CHECK(tags->date == std::optional<std::string_view>("2026"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(4));
    CHECK(tags->genres[0] == "Test Tone");
}

TEST_CASE("a WAV id3 chunk outranks its LIST/INFO chunk") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "id3-tagged-reference.wav");
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Reference Tone"));
    CHECK(tags->album_artist == std::optional<std::string_view>("Orca Test"));
    CHECK(tags->track_total == std::optional<std::uint32_t>(3));
}

TEST_CASE("an AIFF ID3 chunk yields tags and its cover") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "tagged-reference.aiff");
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("Reference Tone"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(1));

    const auto covered = read_fixture(arena, "covered-reference.aiff");
    REQUIRE(covered.has_value());
    REQUIRE(covered->artwork.has_value());
    CHECK(covered->artwork->byte_size == 217);

    auto file = orca::storage::LocalFileSource::open(fixture("covered-reference.aiff"));
    REQUIRE(file.has_value());
    const auto image = orca::metadata::riff_tags::read_picture(*file);
    REQUIRE(image.has_value());
    REQUIRE(image->has_value());
    CHECK((*image)->mime_type == "image/png");
    CHECK((*image)->bytes.size() == 217);
}

TEST_CASE("a WAV id3 chunk holding only a cover yields LIST/INFO values and keeps the cover") {
    orca::metadata::Arena arena;
    const auto bytes = with_cover_only_id3("tagged-reference.wav");
    const auto tags = read_bytes(arena, bytes);
    REQUIRE(tags.has_value());
    CHECK(tags->title == std::optional<std::string_view>("WAV Reference"));
    CHECK(tags->artist == std::optional<std::string_view>("Orca Fixtures"));
    CHECK(tags->track_number == std::optional<std::uint32_t>(4));
    REQUIRE(tags->artwork.has_value());
    CHECK(tags->artwork->mime_type == "image/png");
    CHECK(tags->artwork->byte_size == 32);
}

TEST_CASE("a WAV id3 chunk holding only a cover and no LIST/INFO chunk yields the cover alone") {
    orca::metadata::Arena arena;
    const auto bytes = with_cover_only_id3("generated-reference.wav");
    const auto tags = read_bytes(arena, bytes);
    REQUIRE(tags.has_value());
    CHECK_FALSE(tags->has_values_besides_artwork_and_comment());
    REQUIRE(tags->artwork.has_value());
    CHECK(tags->artwork->byte_size == 32);
}

TEST_CASE("an INFO track number that overflows u32 is rejected rather than wrapped") {
    orca::metadata::Arena arena;
    const auto overflow =
        read_bytes(arena, wav_with_info({{"INAM", "Song"}, {"ITRK", "4294967296"}}));
    REQUIRE(overflow.has_value());
    CHECK(overflow->title == std::optional<std::string_view>("Song"));
    CHECK_FALSE(overflow->track_number.has_value());

    const auto valid = read_bytes(arena, wav_with_info({{"INAM", "Song"}, {"ITRK", "12345"}}));
    REQUIRE(valid.has_value());
    CHECK(valid->track_number == std::optional<std::uint32_t>(12345));
}

TEST_CASE("an untagged WAV yields no tags") {
    orca::metadata::Arena arena;
    const auto tags = read_fixture(arena, "generated-reference.wav");
    CHECK_FALSE(tags.has_value());
}
