#include "liborca/metadata/model.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <doctest/doctest.h>
#include <string_view>

TEST_CASE("advisory numbers map to explicit, clean and none, and anything else is unstated") {
    using orca::metadata::Explicit;
    using orca::metadata::from_advisory;
    using orca::metadata::from_advisory_text;
    CHECK(from_advisory(1) == std::optional(Explicit::explicit_value));
    CHECK(from_advisory(4) == std::optional(Explicit::explicit_value));
    CHECK(from_advisory(2) == std::optional(Explicit::clean));
    CHECK(from_advisory(0) == std::optional(Explicit::none));
    CHECK_FALSE(from_advisory(3).has_value());
    CHECK(from_advisory_text(" 2\0") == std::optional(Explicit::clean));
    CHECK_FALSE(from_advisory_text("yes").has_value());
}

TEST_CASE("a MusicBrainz id is a lowercase UUID and nothing else") {
    using orca::metadata::is_music_brainz_id;
    CHECK(is_music_brainz_id("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"));
    CHECK_FALSE(is_music_brainz_id("8F3471B5-7E6A-48DA-86A9-C1C07A0F5B4A"));
    CHECK_FALSE(is_music_brainz_id("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4"));
    CHECK_FALSE(is_music_brainz_id("8f3471b5x7e6a-48da-86a9-c1c07a0f5b4a"));
    CHECK_FALSE(is_music_brainz_id(""));
}

TEST_CASE("locked user values outrank file preference") {
    using namespace orca::metadata;
    const ObservedFileMetadata observed{
        .title = Value{.text = "File title", .provenance = Provenance::observed_file}};
    const OrcaMetadata orca{
        .title = Value{.text = "User title", .provenance = Provenance::user, .locked = true}};
    const auto effective = resolve(observed, orca, ResolutionPolicy::prefer_file);
    REQUIRE(effective.title.has_value());
    CHECK(effective.title->text == "User title");
    CHECK(effective.title->provenance == Provenance::user);
}

TEST_CASE("cover images are typed by their bytes rather than by what a tag claimed") {
    using orca::metadata::sniff_image_mime_type;
    const auto image = []<std::size_t Size>(const char (&text)[Size]) {
        return std::span<const std::byte>(reinterpret_cast<const std::byte*>(text), Size - 1);
    };
    CHECK(sniff_image_mime_type(image("\x89PNG\r\n\x1a\n\x00")) ==
          std::optional(std::string_view("image/png")));
    CHECK(sniff_image_mime_type(image("\xff\xd8\xff\xe0")) ==
          std::optional(std::string_view("image/jpeg")));
    CHECK(sniff_image_mime_type(image("RIFF\x00\x00\x00\x00WEBPVP8 ")) ==
          std::optional(std::string_view("image/webp")));
    CHECK_FALSE(sniff_image_mime_type(image("RIFF\x00\x00\x00\x00WAVEfmt ")).has_value());
    CHECK_FALSE(sniff_image_mime_type(image("not an image")).has_value());
    CHECK_FALSE(sniff_image_mime_type(image("")).has_value());
}

TEST_CASE("observed tags project onto the layered metadata model with file provenance") {
    using namespace orca::metadata;
    const ObservedTags tags{
        .title = "Reference Tone", .artist = "Orca Test", .album = "", .track_number = 1};
    const auto observed = tags.observed_file_metadata();
    REQUIRE(observed.title.has_value());
    CHECK(observed.title->text == "Reference Tone");
    REQUIRE(observed.artist.has_value());
    CHECK(observed.artist->provenance == Provenance::observed_file);
    CHECK_FALSE(observed.album.has_value());
    CHECK_FALSE(tags.is_empty());
    CHECK(ObservedTags{}.is_empty());
}

TEST_CASE("artwork and a comment are not values besides themselves, while any other field or a "
          "genre is") {
    using namespace orca::metadata;
    const Artwork cover{
        .mime_type = "image/jpeg", .byte_size = 64, .kind = ArtworkKind::front_cover};
    CHECK_FALSE(ObservedTags{}.has_values_besides_artwork_and_comment());
    CHECK_FALSE(ObservedTags{.artwork = cover}.has_values_besides_artwork_and_comment());
    CHECK_FALSE(ObservedTags{.comment = "Ripped", .artwork = cover}
                    .has_values_besides_artwork_and_comment());
    CHECK_FALSE(ObservedTags{.artwork = cover}.is_empty());
    CHECK_FALSE(ObservedTags{.comment = "Ripped"}.is_empty());
    CHECK(ObservedTags{.title = "Song", .artwork = cover}.has_values_besides_artwork_and_comment());
    CHECK(ObservedTags{.composer = "Nick Drake", .comment = "Ripped"}
              .has_values_besides_artwork_and_comment());
    CHECK(ObservedTags{.musicbrainz_recording_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"}
              .has_values_besides_artwork_and_comment());
    CHECK(ObservedTags{.genres = std::vector<std::string_view>{"Rock"}, .artwork = cover}
              .has_values_besides_artwork_and_comment());
}
