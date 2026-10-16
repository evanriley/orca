#include "liborca/metadata/artwork.hpp"
#include "liborca/metadata/model.hpp"
#include "liborca/storage/source.hpp"

#include <algorithm>
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

constexpr std::size_t fixture_cover_bytes = 217;
constexpr std::size_t flac_metadata_prefix_bytes = 4 + 4 + 34 + 4;

auto fixture(std::string_view name) -> std::filesystem::path {
    return std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / name;
}

class SparseSource final : public orca::storage::ReadableSource {
public:
    SparseSource(std::span<const std::byte> prefix, std::uint64_t total)
        : prefix_(prefix), total_(total) {}

    [[nodiscard]] auto read_at(std::uint64_t offset, std::span<std::byte> buffer) const
        -> orca::expected<std::size_t> override {
        if (offset >= total_) {
            return std::size_t{0};
        }
        const std::size_t start = static_cast<std::size_t>(offset);
        const std::size_t count = std::min<std::size_t>(buffer.size(), total_ - start);
        std::fill(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(count),
                  std::byte{0});
        if (start < prefix_.size()) {
            const std::size_t overlap = std::min(count, prefix_.size() - start);
            std::copy(prefix_.begin() + static_cast<std::ptrdiff_t>(start),
                      prefix_.begin() + static_cast<std::ptrdiff_t>(start + overlap),
                      buffer.begin());
        }
        return count;
    }

    [[nodiscard]] auto size() const -> std::uint64_t override {
        return total_;
    }

    [[nodiscard]] auto identity() const -> orca::storage::StorageIdentity override {
        return orca::storage::StorageIdentity{.size = total_};
    }

private:
    std::span<const std::byte> prefix_;
    std::uint64_t total_;
};

struct PictureFixture {
    std::string_view payload = {};
    std::optional<std::uint32_t> declared = std::nullopt;
    std::optional<std::uint32_t> stated = std::nullopt;
};

void append_big(std::vector<std::byte>& bytes, std::uint32_t value) {
    for (std::int32_t shift = 24; shift >= 0; shift -= 8) {
        bytes.push_back(static_cast<std::byte>((value >> shift) & 0xff));
    }
}

void append_text(std::vector<std::byte>& bytes, std::string_view text) {
    for (const char letter : text) {
        bytes.push_back(static_cast<std::byte>(letter));
    }
}

auto flac_with_picture(const PictureFixture& fixture) -> std::vector<std::byte> {
    std::vector<std::byte> block;
    append_big(block, 3);
    append_big(block, static_cast<std::uint32_t>(std::string_view("image/png").size()));
    append_text(block, "image/png");
    append_big(block, 0);
    for (std::int32_t index = 0; index < 4; index += 1) {
        append_big(block, 0);
    }
    append_big(block,
               fixture.declared.value_or(static_cast<std::uint32_t>(fixture.payload.size())));
    append_text(block, fixture.payload);
    const std::uint32_t stated = fixture.stated.value_or(static_cast<std::uint32_t>(block.size()));

    std::vector<std::byte> bytes;
    append_text(bytes, "fLaC");
    bytes.push_back(std::byte{0});
    bytes.push_back(std::byte{0});
    bytes.push_back(std::byte{0});
    bytes.push_back(std::byte{34});
    bytes.insert(bytes.end(), 34, std::byte{0});
    bytes.push_back(std::byte{0x80 | 6});
    bytes.push_back(static_cast<std::byte>((stated >> 16) & 0xff));
    bytes.push_back(static_cast<std::byte>((stated >> 8) & 0xff));
    bytes.push_back(static_cast<std::byte>(stated & 0xff));
    bytes.insert(bytes.end(), block.begin(), block.end());
    return bytes;
}

auto garbage_picture() -> std::vector<std::byte> {
    return flac_with_picture({.payload = "this is not an image at all"});
}

auto truncated_picture() -> std::vector<std::byte> {
    return flac_with_picture({.payload = "\x89PNG\r\n\x1a\n", .declared = 4096});
}

auto oversized_picture_header(std::uint32_t declared) -> std::vector<std::byte> {
    const auto empty = flac_with_picture({});
    const auto block_length =
        static_cast<std::uint32_t>(empty.size() - flac_metadata_prefix_bytes + declared);
    return flac_with_picture({.declared = declared, .stated = block_length});
}

auto read_fixture(std::string_view name)
    -> orca::expected<std::optional<orca::metadata::EmbeddedImage>> {
    const auto opened = orca::storage::LocalFileSource::open(fixture(name));
    REQUIRE(opened.has_value());
    return orca::metadata::artwork::read(*opened);
}

}

TEST_CASE("a FLAC PICTURE block yields its image bytes and the type those bytes are") {
    const auto image = read_fixture("covered-reference.flac");
    REQUIRE(image.has_value());
    REQUIRE(image->has_value());
    CHECK((*image)->bytes.size() == fixture_cover_bytes);
    CHECK((*image)->mime_type == "image/png");
    CHECK((*image)->kind == orca::metadata::ArtworkKind::front_cover);
    const auto signature = std::string_view("\x89PNG\r\n\x1a\n");
    CHECK(std::memcmp((*image)->bytes.data(), signature.data(), signature.size()) == 0);
}

TEST_CASE("an ID3v2 APIC frame yields its image bytes and the type those bytes are") {
    const auto image = read_fixture("covered-reference.mp3");
    REQUIRE(image.has_value());
    REQUIRE(image->has_value());
    CHECK((*image)->bytes.size() == fixture_cover_bytes);
    CHECK((*image)->mime_type == "image/png");
    CHECK((*image)->kind == orca::metadata::ArtworkKind::front_cover);
}

TEST_CASE("a cover behind a leading ID3v2 tag is read from the stream, not from byte zero") {
    const auto image = read_fixture("id3-covered-reference.flac");
    REQUIRE(image.has_value());
    REQUIRE(image->has_value());
    CHECK((*image)->bytes.size() == fixture_cover_bytes);
    CHECK((*image)->mime_type == "image/png");
}

TEST_CASE("a file with no embedded cover reports none rather than failing") {
    for (const std::string_view name : std::array<std::string_view, 5>{
             "generated-reference.flac",
             "tagged-reference.flac",
             "tagged-reference.mp3",
             "id3-prefixed-reference.flac",
             "generated-reference.wav",
         }) {
        CAPTURE(name);
        const auto image = read_fixture(name);
        REQUIRE(image.has_value());
        CHECK_FALSE(image->has_value());
    }
}

TEST_CASE("bytes that are not a recognised image are refused rather than handed on") {
    const auto garbage = garbage_picture();
    const orca::storage::MemorySource source(garbage);
    const auto image = orca::metadata::artwork::read(source);
    REQUIRE_FALSE(image.has_value());
    CHECK(image.error().code == orca::ErrorCode::parse);
}

TEST_CASE("a picture larger than the bound is refused rather than allocated") {
    const auto declared = static_cast<std::uint32_t>(orca::metadata::max_image_bytes + 1);
    const auto header = oversized_picture_header(declared);
    const SparseSource source(header, header.size() + declared);
    const auto image = orca::metadata::artwork::read(source);
    REQUIRE_FALSE(image.has_value());
    CHECK(image.error().code == orca::ErrorCode::out_of_range);
}

TEST_CASE("a picture block that declares more bytes than it holds is skipped") {
    const auto truncated = truncated_picture();
    const orca::storage::MemorySource source(truncated);
    const auto image = orca::metadata::artwork::read(source);
    REQUIRE(image.has_value());
    CHECK_FALSE(image->has_value());
}
