#include "liborca/metadata/id3v1.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <span>

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

}

TEST_CASE("an ID3v1 read failure is an error, not an absent tag") {
    FailingSource source(200);
    std::array<std::byte, 128> buffer{};
    const auto tag = orca::metadata::id3v1::read(source, buffer);
    REQUIRE_FALSE(tag.has_value());
    CHECK(tag.error().code == orca::ErrorCode::io);
}

TEST_CASE("parses ID3v1.1 without leaking format conventions into metadata") {
    std::array<std::byte, 128> bytes{};
    std::memcpy(bytes.data(), "TAG", 3);
    std::memcpy(bytes.data() + 3, "Test title", 10);
    std::memcpy(bytes.data() + 33, "Test artist", 11);
    std::memcpy(bytes.data() + 63, "Test album", 10);
    std::memcpy(bytes.data() + 93, "2026", 4);
    bytes[126] = std::byte{7};
    bytes[127] = std::byte{13};

    const auto tag = orca::metadata::id3v1::parse(bytes);
    REQUIRE(tag.has_value());
    CHECK(tag->title == "Test title");
    CHECK(tag->artist == "Test artist");
    CHECK(tag->track_number == std::optional<std::uint8_t>(7));
}

TEST_CASE("portable ID3v1 writer round-trips without silent truncation") {
    using orca::metadata::id3v1::Tag;
    const auto bytes = orca::metadata::id3v1::encode(Tag{.title = "Generated title",
                                                         .artist = "Generated artist",
                                                         .album = "Generated album",
                                                         .year = "2026",
                                                         .comment = "Orca fixture",
                                                         .track_number = 3,
                                                         .genre = 13});
    REQUIRE(bytes.has_value());
    const auto tag = orca::metadata::id3v1::parse(*bytes);
    REQUIRE(tag.has_value());
    CHECK(tag->title == "Generated title");
    CHECK(tag->track_number == std::optional<std::uint8_t>(3));

    const auto too_long = orca::metadata::id3v1::encode(
        Tag{.title = "This title is deliberately longer than thirty bytes",
            .track_number = std::nullopt,
            .genre = 255});
    CHECK_FALSE(too_long.has_value());
}

TEST_CASE("Latin-1 text widens to UTF-8 instead of reaching the model as raw bytes") {
    const std::array<std::byte, 4> bytes{std::byte{'C'}, std::byte{'a'}, std::byte{'f'},
                                         std::byte{0xe9}};
    CHECK(orca::metadata::id3v1::latin1_to_utf8(bytes) == "Caf\u00e9");
}

TEST_CASE("ID3v1 genre numbers resolve to names instead of leaking codes") {
    CHECK(orca::metadata::id3v1::genre_name(9) == std::optional(std::string_view("Metal")));
    CHECK(orca::metadata::id3v1::genre_name(191) == std::optional(std::string_view("Psybient")));
    CHECK_FALSE(orca::metadata::id3v1::genre_name(192).has_value());
    CHECK_FALSE(orca::metadata::id3v1::genre_name(255).has_value());
}
