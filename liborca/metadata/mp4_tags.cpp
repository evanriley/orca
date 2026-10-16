#include "liborca/metadata/mp4_tags.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/metadata/id3v1.hpp"
#include "liborca/metadata/image_header.hpp"
#include "liborca/metadata/lrc.hpp"
#include "liborca/storage/iso_bmff.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace orca::metadata::mp4_tags {

namespace {

using storage::iso_bmff::Box;
using storage::iso_bmff::Iterator;

enum class DataType : std::uint32_t {
    binary = 0,
    utf8 = 1,
    utf16 = 2,
    jpeg = 13,
    png = 14,
    signed_integer = 21,
    unsigned_integer = 22,
    bmp = 27,
};

struct Value {
    DataType kind = DataType::binary;
    std::span<const std::byte> bytes;
};

[[nodiscard]] auto find_box(std::span<const std::byte> bytes, std::string_view kind)
    -> expected<std::optional<Box>> {
    return Iterator::find(bytes, kind);
}

[[nodiscard]] auto big16(std::span<const std::byte> bytes, std::size_t offset) -> std::uint16_t {
    return static_cast<std::uint16_t>((std::to_integer<std::uint16_t>(bytes[offset]) << 8U) |
                                      std::to_integer<std::uint16_t>(bytes[offset + 1]));
}

[[nodiscard]] auto item_list(std::span<const std::byte> movie)
    -> expected<std::optional<std::span<const std::byte>>> {
    const std::array<std::string_view, 2> path{"udta", "meta"};
    const auto meta = storage::iso_bmff::descend(movie, path);
    if (!meta) {
        return std::unexpected(meta.error());
    }
    if (!*meta) {
        return std::optional<std::span<const std::byte>>{};
    }
    if ((*meta)->body.size() < 4) {
        return fail(ErrorCode::parse, "mp4_tags: short meta box");
    }
    const auto list = find_box((*meta)->body.subspan(4), "ilst");
    if (!list) {
        return std::unexpected(list.error());
    }
    if (!*list) {
        return std::optional<std::span<const std::byte>>{};
    }
    return std::optional<std::span<const std::byte>>((*list)->body);
}

[[nodiscard]] auto first_value(std::span<const std::byte> item) -> expected<std::optional<Value>> {
    const auto data = find_box(item, "data");
    if (!data) {
        return std::unexpected(data.error());
    }
    if (!*data) {
        return std::optional<Value>{};
    }
    const auto body = (*data)->body;
    if (body.size() < 8) {
        return fail(ErrorCode::parse, "mp4_tags: short data atom");
    }
    ORCA_ASSERT(body.size() >= 8);
    const std::uint32_t kind = (std::to_integer<std::uint32_t>(body[1]) << 16U) |
                               (std::to_integer<std::uint32_t>(body[2]) << 8U) |
                               std::to_integer<std::uint32_t>(body[3]);
    return std::optional<Value>(
        Value{.kind = static_cast<DataType>(kind), .bytes = body.subspan(8)});
}

[[nodiscard]] auto utf8_valid(std::string_view text) -> bool {
    std::size_t index = 0;
    while (index < text.size()) {
        const auto byte = static_cast<unsigned char>(text[index]);
        std::size_t extra = 0;
        if (byte < 0x80U) {
            extra = 0;
        } else {
            if ((byte & 0xe0U) == 0xc0U) {
                extra = 1;
            } else {
                if ((byte & 0xf0U) == 0xe0U) {
                    extra = 2;
                } else {
                    if ((byte & 0xf8U) == 0xf0U) {
                        extra = 3;
                    } else {
                        return false;
                    }
                }
            }
        }
        if (index + extra >= text.size()) {
            return false;
        }
        for (std::size_t offset = 1; offset <= extra; ++offset) {
            if ((static_cast<unsigned char>(text[index + offset]) & 0xc0U) != 0x80U) {
                return false;
            }
        }
        index += extra + 1;
    }
    return true;
}

[[nodiscard]] auto text(const Value& value) -> std::optional<std::string_view> {
    if (value.kind != DataType::utf8) {
        return std::nullopt;
    }
    std::string_view result(reinterpret_cast<const char*>(value.bytes.data()), value.bytes.size());
    while (!result.empty() &&
           (result.front() == ' ' || result.front() == '\t' || result.front() == '\r' ||
            result.front() == '\n' || result.front() == '\0')) {
        result.remove_prefix(1);
    }
    while (!result.empty() &&
           (result.back() == ' ' || result.back() == '\t' || result.back() == '\r' ||
            result.back() == '\n' || result.back() == '\0')) {
        result.remove_suffix(1);
    }
    if (result.empty() || !utf8_valid(result)) {
        return std::nullopt;
    }
    return result;
}

[[nodiscard]] auto set_text(Arena& arena, std::optional<std::string_view>& field,
                            std::string_view value) -> bool {
    if (field) {
        return false;
    }
    field = arena.store(value);
    return true;
}

[[nodiscard]] auto set_pair(const Value& value, std::optional<std::uint32_t>& number,
                            std::optional<std::uint32_t>& total) -> bool {
    if (value.bytes.size() < 6 || number) {
        return false;
    }
    const std::uint16_t n = big16(value.bytes, 2);
    const std::uint16_t t = big16(value.bytes, 4);
    if (n != 0) {
        number = n;
    }
    if (t != 0) {
        total = t;
    }
    return n != 0 || t != 0;
}

[[nodiscard]] auto assign_text(Arena& arena, std::string_view identifier, const Value& value,
                               ObservedTags& tags, std::vector<std::string_view>& genres)
    -> std::optional<bool> {
    if (identifier == "\xa9nam") {
        const auto content = text(value);
        return content ? set_text(arena, tags.title, *content) : false;
    }
    if (identifier == "\xa9"
                      "ART") {
        const auto content = text(value);
        return content ? set_text(arena, tags.artist, *content) : false;
    }
    if (identifier == "aART") {
        const auto content = text(value);
        return content ? set_text(arena, tags.album_artist, *content) : false;
    }
    if (identifier == "\xa9"
                      "alb") {
        const auto content = text(value);
        return content ? set_text(arena, tags.album, *content) : false;
    }
    if (identifier == "\xa9wrt") {
        const auto content = text(value);
        return content ? set_text(arena, tags.composer, *content) : false;
    }
    if (identifier == "\xa9"
                      "cmt") {
        const auto content = text(value);
        return content ? set_text(arena, tags.comment, *content) : false;
    }
    if (identifier == "\xa9"
                      "day") {
        const auto content = text(value);
        if (!content) {
            return false;
        }
        const auto separator = content->find('T');
        const std::string_view day =
            separator == std::string_view::npos ? *content : content->substr(0, separator);
        return set_text(arena, tags.date, day);
    }
    if (identifier == "\xa9gen") {
        const auto content = text(value);
        if (!content) {
            return false;
        }
        genres.push_back(arena.store(*content));
        return true;
    }
    return std::nullopt;
}

[[nodiscard]] auto assign_number(Arena& arena, std::string_view identifier, const Value& value,
                                 ObservedTags& tags, std::vector<std::string_view>& genres)
    -> std::optional<bool> {
    if (identifier == "gnre") {
        if (value.bytes.size() < 2) {
            return false;
        }
        const std::uint16_t number = big16(value.bytes, 0);
        if (number == 0 || number > 256) {
            return false;
        }
        const auto name = id3v1::genre_name(static_cast<std::uint8_t>(number - 1));
        if (!name) {
            return false;
        }
        genres.push_back(arena.store(*name));
        return true;
    }
    if (identifier == "trkn") {
        return set_pair(value, tags.track_number, tags.track_total);
    }
    if (identifier == "disk") {
        return set_pair(value, tags.disc_number, tags.disc_total);
    }
    if (identifier == "rtng") {
        if (value.bytes.empty() || value.bytes.size() > 8 || tags.explicit_flag) {
            return false;
        }
        std::uint64_t number = 0;
        for (const std::byte byte : value.bytes) {
            number = (number << 8U) | std::to_integer<std::uint8_t>(byte);
        }
        const auto advisory = from_advisory(number);
        if (!advisory) {
            return false;
        }
        tags.explicit_flag = advisory;
        return true;
    }
    if (identifier == "cpil") {
        if (value.bytes.empty() || tags.compilation) {
            return false;
        }
        tags.compilation = value.bytes[0] != std::byte{0};
        return true;
    }
    return std::nullopt;
}

[[nodiscard]] auto assign(Arena& arena, const std::array<std::byte, 4>& code, const Value& value,
                          ObservedTags& tags, std::vector<std::string_view>& genres)
    -> expected<bool> {
    const std::string_view identifier(reinterpret_cast<const char*>(code.data()), code.size());
    if (const auto assigned = assign_text(arena, identifier, value, tags, genres)) {
        return *assigned;
    }
    if (const auto assigned = assign_number(arena, identifier, value, tags, genres)) {
        return *assigned;
    }
    return false;
}

[[nodiscard]] auto equals_ascii_case(std::string_view text, std::string_view expected) -> bool {
    if (text.size() != expected.size()) {
        return false;
    }
    for (std::size_t index = 0; index < text.size(); ++index) {
        const auto lower = [](char value) {
            return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
        };
        if (lower(text[index]) != lower(expected[index])) {
            return false;
        }
    }
    return true;
}

[[nodiscard]] auto assign_freeform_text(Arena& arena, std::string_view name,
                                        std::string_view content, ObservedTags& tags) -> bool {
    if (equals_ascii_case(name, "MusicBrainz Track Id")) {
        return set_text(arena, tags.musicbrainz_recording_id, content);
    }
    if (equals_ascii_case(name, "MusicBrainz Album Id")) {
        return set_text(arena, tags.musicbrainz_release_id, content);
    }
    if (equals_ascii_case(name, "MusicBrainz Release Group Id")) {
        return set_text(arena, tags.musicbrainz_release_group_id, content);
    }
    if (equals_ascii_case(name, "MusicBrainz Release Track Id")) {
        return set_text(arena, tags.musicbrainz_release_track_id, content);
    }
    if (equals_ascii_case(name, "MusicBrainz Artist Id")) {
        return set_text(arena, tags.musicbrainz_artist_id, content);
    }
    if (equals_ascii_case(name, "MusicBrainz Album Artist Id")) {
        return set_text(arena, tags.musicbrainz_album_artist_id, content);
    }
    if (equals_ascii_case(name, "MusicBrainz Album Release Country")) {
        return set_text(arena, tags.release_country, content);
    }
    if (equals_ascii_case(name, "MusicBrainz Album Type")) {
        return set_text(arena, tags.release_type, content);
    }
    if (equals_ascii_case(name, "MusicBrainz Album Status")) {
        return set_text(arena, tags.release_status, content);
    }
    if (equals_ascii_case(name, "ISRC")) {
        return set_text(arena, tags.isrc, content);
    }
    if (equals_ascii_case(name, "LABEL") || equals_ascii_case(name, "publisher")) {
        return set_text(arena, tags.label, content);
    }
    if (equals_ascii_case(name, "MEDIA")) {
        return set_text(arena, tags.media, content);
    }
    if (equals_ascii_case(name, "originaldate") || equals_ascii_case(name, "ORIGINAL YEAR") ||
        equals_ascii_case(name, "originalyear")) {
        return set_text(arena, tags.original_date, content);
    }
    return false;
}

[[nodiscard]] auto assign_freeform(Arena& arena, std::span<const std::byte> item,
                                   ObservedTags& tags) -> expected<bool> {
    const auto name_box = find_box(item, "name");
    if (!name_box) {
        return std::unexpected(name_box.error());
    }
    if (!*name_box) {
        return false;
    }
    if ((*name_box)->body.size() < 4) {
        return fail(ErrorCode::parse, "mp4_tags: short name atom");
    }
    const std::string_view name(reinterpret_cast<const char*>((*name_box)->body.data() + 4),
                                (*name_box)->body.size() - 4);
    const auto value = first_value(item);
    if (!value) {
        return std::unexpected(value.error());
    }
    if (!*value) {
        return false;
    }
    const auto content = text(**value);
    if (!content) {
        return false;
    }

    if (equals_ascii_case(name, "ITUNESADVISORY")) {
        if (tags.explicit_flag) {
            return false;
        }
        const auto advisory = from_advisory_text(*content);
        if (!advisory) {
            return false;
        }
        tags.explicit_flag = advisory;
        return true;
    }

    return assign_freeform_text(arena, name, *content, tags);
}

}

[[nodiscard]] auto apply_item(Arena& arena, const Box& item, ObservedTags& tags,
                              std::vector<std::string_view>& genres) -> expected<bool> {
    if (item.is("covr")) {
        const auto value = first_value(item.body);
        if (!value) {
            return std::unexpected(value.error());
        }
        if (!*value) {
            return false;
        }
        if (!tags.artwork) {
            const auto measured = image_header::measure((*value)->bytes);
            const auto mime = sniff_image_mime_type((*value)->bytes);
            tags.artwork = Artwork{.mime_type = mime.value_or(""),
                                   .byte_size = (*value)->bytes.size(),
                                   .kind = ArtworkKind::front_cover,
                                   .width = measured.width,
                                   .height = measured.height,
                                   .hash = measured.hash};
        }
        return true;
    }
    if (item.is("----")) {
        return assign_freeform(arena, item.body, tags);
    }
    const auto value = first_value(item.body);
    if (!value) {
        return std::unexpected(value.error());
    }
    if (!*value) {
        return false;
    }
    return assign(arena, item.kind, **value, tags, genres);
}

auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>> {
    auto movie = storage::iso_bmff::read_movie(source);
    if (!movie) {
        return std::unexpected(movie.error());
    }
    const auto items = item_list(*movie);
    if (!items) {
        return std::unexpected(items.error());
    }
    if (!*items) {
        return std::optional<ObservedTags>{};
    }
    ORCA_ASSERT(*items);

    ObservedTags tags;
    std::vector<std::string_view> genres;
    bool any = false;
    Iterator boxes(**items);
    while (true) {
        const auto item = boxes.next();
        if (!item) {
            return std::unexpected(item.error());
        }
        if (!*item) {
            break;
        }
        const auto assigned = apply_item(arena, **item, tags, genres);
        if (!assigned) {
            return std::unexpected(assigned.error());
        }
        any = *assigned || any;
    }
    if (!any) {
        return std::optional<ObservedTags>{};
    }
    tags.genres = std::move(genres);
    return std::optional<ObservedTags>(std::move(tags));
}

auto read_picture(const storage::ReadableSource& source) -> expected<std::optional<EmbeddedImage>> {
    auto movie = storage::iso_bmff::read_movie(source);
    if (!movie) {
        return std::unexpected(movie.error());
    }
    const auto items = item_list(*movie);
    if (!items) {
        return std::unexpected(items.error());
    }
    if (!*items) {
        return std::optional<EmbeddedImage>{};
    }
    const auto cover = find_box(**items, "covr");
    if (!cover) {
        return std::unexpected(cover.error());
    }
    if (!*cover) {
        return std::optional<EmbeddedImage>{};
    }
    const auto value = first_value((*cover)->body);
    if (!value) {
        return std::unexpected(value.error());
    }
    if (!*value) {
        return std::optional<EmbeddedImage>{};
    }
    if ((*value)->bytes.size() > max_image_bytes) {
        return fail(ErrorCode::out_of_range, "mp4_tags: artwork too large");
    }
    ORCA_ASSERT((*value)->bytes.size() <= max_image_bytes);
    std::vector<std::byte> bytes((*value)->bytes.begin(), (*value)->bytes.end());
    auto image = adopt_image(std::move(bytes), ArtworkKind::front_cover);
    if (!image) {
        return std::unexpected(image.error());
    }
    return std::optional<EmbeddedImage>(std::move(*image));
}

auto read_lyrics(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<lyrics::Content>> {
    auto movie = storage::iso_bmff::read_movie(source);
    if (!movie) {
        return std::unexpected(movie.error());
    }
    const auto items = item_list(*movie);
    if (!items) {
        return std::unexpected(items.error());
    }
    if (!*items) {
        return std::optional<lyrics::Content>{};
    }
    const auto item = find_box(**items, "\xa9lyr");
    if (!item) {
        return std::unexpected(item.error());
    }
    if (!*item) {
        return std::optional<lyrics::Content>{};
    }
    const auto value = first_value((*item)->body);
    if (!value) {
        return std::unexpected(value.error());
    }
    if (!*value || (*value)->kind != DataType::utf8) {
        return std::optional<lyrics::Content>{};
    }
    const std::string_view content(reinterpret_cast<const char*>((*value)->bytes.data()),
                                   (*value)->bytes.size());
    return lrc::parse(arena, content);
}

}
