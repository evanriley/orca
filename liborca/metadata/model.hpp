#pragma once

#include "liborca/base/expected.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace orca::metadata {

enum class Provenance : std::uint8_t {
    observed_file,
    user,
    provider,
    inference,
    analysis,
};

enum class Field : std::uint32_t {
    title,
    artist,
    album,
    track_number,
    album_artist,
    disc_number,
    date,
    compilation,
    musicbrainz_recording_id,
    musicbrainz_release_id,
    musicbrainz_release_group_id,
    musicbrainz_release_track_id,
    musicbrainz_album_artist_id,
    explicit_advisory,
    composer,
    comment,
};

enum class Explicit : std::uint8_t {
    unknown,
    none,
    explicit_value,
    clean,
};

[[nodiscard]] auto from_advisory(std::uint64_t number) -> std::optional<Explicit>;
[[nodiscard]] auto from_advisory_text(std::string_view text) -> std::optional<Explicit>;
[[nodiscard]] auto advisory_text(Explicit value) -> std::optional<std::string_view>;

[[nodiscard]] auto is_music_brainz_id(std::string_view text) -> bool;

struct Value {
    std::string_view text;
    Provenance provenance = Provenance::observed_file;
    bool locked = false;
};

struct ObservedFileMetadata {
    std::optional<Value> title = std::nullopt;
    std::optional<Value> artist = std::nullopt;
    std::optional<Value> album = std::nullopt;
};

struct OrcaMetadata {
    std::optional<Value> title = std::nullopt;
    std::optional<Value> artist = std::nullopt;
    std::optional<Value> album = std::nullopt;
};

enum class ResolutionPolicy {
    prefer_file,
    prefer_orca,
};

struct EffectiveMetadata {
    std::optional<Value> title = std::nullopt;
    std::optional<Value> artist = std::nullopt;
    std::optional<Value> album = std::nullopt;
};

[[nodiscard]] auto resolve(const ObservedFileMetadata& observed, const OrcaMetadata& orca,
                           ResolutionPolicy policy) -> EffectiveMetadata;
[[nodiscard]] auto resolve_value(const std::optional<Value>& observed,
                                 const std::optional<Value>& orca, ResolutionPolicy policy)
    -> std::optional<Value>;

enum class ArtworkKind : std::uint8_t {
    front_cover,
    back_cover,
    other,
};

struct Artwork {
    std::string_view mime_type;
    std::uint64_t byte_size = 0;
    ArtworkKind kind = ArtworkKind::other;
    std::optional<std::uint32_t> width = std::nullopt;
    std::optional<std::uint32_t> height = std::nullopt;
    std::optional<std::int64_t> hash = std::nullopt;
};

inline constexpr std::size_t max_image_bytes = 12U << 20;

struct EmbeddedImage {
    std::vector<std::byte> bytes;
    std::string_view mime_type;
    ArtworkKind kind = ArtworkKind::other;
};

[[nodiscard]] auto adopt_image(std::vector<std::byte> bytes, ArtworkKind kind)
    -> expected<EmbeddedImage>;
[[nodiscard]] auto sniff_image_mime_type(std::span<const std::byte> bytes)
    -> std::optional<std::string_view>;

struct ObservedTags {
    std::optional<std::string_view> title = std::nullopt;
    std::optional<std::string_view> artist = std::nullopt;
    std::optional<std::string_view> album = std::nullopt;
    std::optional<std::string_view> album_artist = std::nullopt;
    std::optional<std::string_view> composer = std::nullopt;
    std::optional<std::string_view> comment = std::nullopt;
    std::optional<std::uint32_t> track_number = std::nullopt;
    std::optional<std::uint32_t> track_total = std::nullopt;
    std::optional<std::uint32_t> disc_number = std::nullopt;
    std::optional<std::uint32_t> disc_total = std::nullopt;
    std::optional<std::string_view> date = std::nullopt;
    std::optional<std::string_view> original_date = std::nullopt;
    std::vector<std::string_view> genres = {};
    std::optional<bool> compilation = std::nullopt;
    std::optional<std::string_view> label = std::nullopt;
    std::optional<std::string_view> media = std::nullopt;
    std::optional<std::string_view> isrc = std::nullopt;
    std::optional<std::string_view> release_country = std::nullopt;
    std::optional<std::string_view> release_type = std::nullopt;
    std::optional<std::string_view> release_status = std::nullopt;
    std::optional<std::string_view> musicbrainz_recording_id = std::nullopt;
    std::optional<std::string_view> musicbrainz_release_id = std::nullopt;
    std::optional<std::string_view> musicbrainz_release_group_id = std::nullopt;
    std::optional<std::string_view> musicbrainz_release_track_id = std::nullopt;
    std::optional<std::string_view> musicbrainz_artist_id = std::nullopt;
    std::optional<std::string_view> musicbrainz_album_artist_id = std::nullopt;
    std::optional<Explicit> explicit_flag = std::nullopt;
    std::optional<Artwork> artwork = std::nullopt;

    [[nodiscard]] auto is_empty() const -> bool;
    [[nodiscard]] auto has_values_besides_artwork_and_comment() const -> bool;
    [[nodiscard]] auto observed_file_metadata() const -> ObservedFileMetadata;
};

}
