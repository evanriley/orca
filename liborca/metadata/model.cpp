#include "liborca/metadata/model.hpp"

#include <algorithm>
#include <charconv>
#include <cstring>

namespace orca::metadata {

namespace {

[[nodiscard]] auto starts_with(std::span<const std::byte> bytes, std::string_view prefix) -> bool {
    return bytes.size() >= prefix.size() &&
           std::memcmp(bytes.data(), prefix.data(), prefix.size()) == 0;
}

[[nodiscard]] auto observed_value(const std::optional<std::string_view>& text)
    -> std::optional<Value> {
    if (!text || text->empty()) {
        return std::nullopt;
    }
    return Value{.text = *text, .provenance = Provenance::observed_file};
}

[[nodiscard]] auto is_ascii_space(char value) -> bool {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n' || value == '\0';
}

}

auto from_advisory(std::uint64_t number) -> std::optional<Explicit> {
    switch (number) {
    case 0:
        return Explicit::none;
    case 1:
    case 4:
        return Explicit::explicit_value;
    case 2:
        return Explicit::clean;
    default:
        return std::nullopt;
    }
}

auto from_advisory_text(std::string_view text) -> std::optional<Explicit> {
    while (!text.empty() && is_ascii_space(text.front())) {
        text.remove_prefix(1);
    }
    while (!text.empty() && is_ascii_space(text.back())) {
        text.remove_suffix(1);
    }
    if (text.empty()) {
        return std::nullopt;
    }
    std::uint64_t number = 0;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), number);
    if (result.ec != std::errc{} || result.ptr != text.data() + text.size()) {
        return std::nullopt;
    }
    return from_advisory(number);
}

auto advisory_text(Explicit value) -> std::optional<std::string_view> {
    switch (value) {
    case Explicit::unknown:
        return std::nullopt;
    case Explicit::none:
        return "0";
    case Explicit::explicit_value:
        return "1";
    case Explicit::clean:
        return "2";
    }
    return std::nullopt;
}

auto is_music_brainz_id(std::string_view text) -> bool {
    if (text.size() != 36) {
        return false;
    }
    for (std::size_t index = 0; index < text.size(); ++index) {
        const char byte = text[index];
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (byte != '-') {
                return false;
            }
            continue;
        }
        const bool digit = byte >= '0' && byte <= '9';
        const bool lower = byte >= 'a' && byte <= 'f';
        if (!digit && !lower) {
            return false;
        }
    }
    return true;
}

auto resolve(const ObservedFileMetadata& observed, const OrcaMetadata& orca,
             ResolutionPolicy policy) -> EffectiveMetadata {
    return EffectiveMetadata{.title = resolve_value(observed.title, orca.title, policy),
                             .artist = resolve_value(observed.artist, orca.artist, policy),
                             .album = resolve_value(observed.album, orca.album, policy)};
}

auto resolve_value(const std::optional<Value>& observed, const std::optional<Value>& orca,
                   ResolutionPolicy policy) -> std::optional<Value> {
    if (orca && orca->locked) {
        return orca;
    }
    if (policy == ResolutionPolicy::prefer_file) {
        return observed ? observed : orca;
    }
    return orca ? orca : observed;
}

auto adopt_image(std::vector<std::byte> bytes, ArtworkKind kind) -> expected<EmbeddedImage> {
    if (bytes.size() > max_image_bytes) {
        return fail(ErrorCode::out_of_range, "artwork: image too large");
    }
    const auto mime_type = sniff_image_mime_type(bytes);
    if (!mime_type) {
        return fail(ErrorCode::parse, "artwork: unrecognized image");
    }
    return EmbeddedImage{.bytes = std::move(bytes), .mime_type = *mime_type, .kind = kind};
}

auto sniff_image_mime_type(std::span<const std::byte> bytes) -> std::optional<std::string_view> {
    if (starts_with(bytes, "\x89PNG\r\n\x1a\n")) {
        return "image/png";
    }
    if (starts_with(bytes, "\xff\xd8\xff")) {
        return "image/jpeg";
    }
    if (starts_with(bytes, "GIF87a") || starts_with(bytes, "GIF89a")) {
        return "image/gif";
    }
    if (bytes.size() >= 12 && starts_with(bytes, "RIFF") &&
        std::memcmp(bytes.data() + 8, "WEBP", 4) == 0) {
        return "image/webp";
    }
    if (starts_with(bytes, "BM")) {
        return "image/bmp";
    }
    return std::nullopt;
}

auto ObservedTags::is_empty() const -> bool {
    if (!genres.empty()) {
        return false;
    }
    return !(title || artist || album || album_artist || composer || comment || track_number ||
             track_total || disc_number || disc_total || date || original_date || compilation ||
             label || media || isrc || release_country || release_type || release_status ||
             musicbrainz_recording_id || musicbrainz_release_id || musicbrainz_release_group_id ||
             musicbrainz_release_track_id || musicbrainz_artist_id || musicbrainz_album_artist_id ||
             explicit_flag || artwork);
}

auto ObservedTags::has_values_besides_artwork_and_comment() const -> bool {
    ObservedTags rest = *this;
    rest.artwork.reset();
    rest.comment.reset();
    return !rest.is_empty();
}

auto ObservedTags::observed_file_metadata() const -> ObservedFileMetadata {
    return ObservedFileMetadata{.title = observed_value(title),
                                .artist = observed_value(artist),
                                .album = observed_value(album)};
}

}
