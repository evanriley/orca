#include "liborca/metadata/vorbis_comment.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/metadata/image_header.hpp"
#include "liborca/metadata/lrc.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace orca::metadata::vorbis_comment {

namespace {

[[nodiscard]] auto read_exact(const storage::ReadableSource& source, std::uint64_t offset,
                              std::span<std::byte> buffer) -> expected<std::size_t> {
    std::size_t filled = 0;
    while (filled < buffer.size()) {
        const auto chunk = source.read_at(offset + filled, buffer.subspan(filled));
        if (!chunk) {
            return std::unexpected(chunk.error());
        }
        if (*chunk == 0) {
            break;
        }
        filled += *chunk;
    }
    return filled;
}

[[nodiscard]] auto take_u32(std::span<const std::byte> payload, std::size_t& cursor)
    -> expected<std::uint32_t> {
    ORCA_ASSERT(cursor <= payload.size());
    if (cursor > payload.size() || payload.size() - cursor < 4) {
        return fail(ErrorCode::invalid_vorbis_comment, "vorbis: truncated length");
    }
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value |= static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(payload[cursor + index]))
                 << (index * 8U);
    }
    cursor += 4;
    return value;
}

[[nodiscard]] auto take_string(std::span<const std::byte> payload, std::size_t& cursor)
    -> expected<std::span<const std::byte>> {
    const auto length = take_u32(payload, cursor);
    if (!length) {
        return std::unexpected(length.error());
    }
    if (*length > payload.size() - cursor) {
        return fail(ErrorCode::invalid_vorbis_comment, "vorbis: string past end");
    }
    const auto value = payload.subspan(cursor, *length);
    cursor += *length;
    ORCA_ASSERT(cursor <= payload.size());
    return value;
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

[[nodiscard]] auto parse_entry(std::span<const std::byte> entry) -> expected<Entry> {
    const std::string_view text(reinterpret_cast<const char*>(entry.data()), entry.size());
    const auto delimiter = text.find('=');
    if (delimiter == std::string_view::npos) {
        return fail(ErrorCode::invalid_vorbis_comment, "vorbis: missing '='");
    }
    const std::string_view key = text.substr(0, delimiter);
    if (key.empty()) {
        return fail(ErrorCode::invalid_vorbis_comment, "vorbis: empty key");
    }
    for (const char byte : key) {
        if (static_cast<unsigned char>(byte) < 0x20U || byte > 0x7d || byte == '=') {
            return fail(ErrorCode::invalid_vorbis_comment, "vorbis: invalid key byte");
        }
    }
    const std::string_view value = text.substr(delimiter + 1);
    if (!utf8_valid(value)) {
        return fail(ErrorCode::invalid_vorbis_comment, "vorbis: invalid UTF-8 value");
    }
    return Entry{.key = key, .value = value};
}

[[nodiscard]] auto matches(std::string_view key, std::initializer_list<std::string_view> spellings)
    -> bool {
    for (const std::string_view spelling : spellings) {
        if (key.size() != spelling.size()) {
            continue;
        }
        bool equal = true;
        for (std::size_t index = 0; index < key.size(); ++index) {
            const auto lower = [](char value) {
                return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
            };
            if (lower(key[index]) != lower(spelling[index])) {
                equal = false;
                break;
            }
        }
        if (equal) {
            return true;
        }
    }
    return false;
}

[[nodiscard]] auto parse_number(std::string_view value) -> std::optional<std::uint32_t> {
    while (!value.empty() && value.front() == ' ') {
        value.remove_prefix(1);
    }
    while (!value.empty() && value.back() == ' ') {
        value.remove_suffix(1);
    }
    if (value.empty()) {
        return std::nullopt;
    }
    std::uint32_t result = 0;
    for (const char byte : value) {
        if (byte < '0' || byte > '9') {
            return std::nullopt;
        }
        const std::uint64_t next =
            (static_cast<std::uint64_t>(result) * 10U) + static_cast<std::uint32_t>(byte - '0');
        if (next > 0xffffffffULL) {
            return std::nullopt;
        }
        result = static_cast<std::uint32_t>(next);
    }
    return result;
}

[[nodiscard]] auto is_truthy(std::string_view value) -> bool {
    std::string normalized(value);
    for (char& byte : normalized) {
        if (byte >= 'A' && byte <= 'Z') {
            byte = static_cast<char>(byte - 'A' + 'a');
        }
    }
    return normalized == "1" || normalized == "true" || normalized == "yes";
}

void set_text(Arena& arena, std::optional<std::string_view>& field, std::string_view value) {
    if (field) {
        return;
    }
    field = arena.store(value);
}

void set_number(std::string_view value, std::optional<std::uint32_t>& field) {
    if (field) {
        return;
    }
    field = parse_number(value);
}

void set_pair(std::string_view value, std::optional<std::uint32_t>& number,
              std::optional<std::uint32_t>& total) {
    const auto split = value.find('/');
    if (split != std::string_view::npos) {
        set_number(value.substr(0, split), number);
        set_number(value.substr(split + 1), total);
        return;
    }
    set_number(value, number);
}

void assign_identity(Arena& arena, std::string_view key, std::string_view value,
                     ObservedTags& tags) {
    if (matches(key, {"TITLE"})) {
        set_text(arena, tags.title, value);
        return;
    }
    if (matches(key, {"ARTIST"})) {
        set_text(arena, tags.artist, value);
        return;
    }
    if (matches(key, {"ALBUM"})) {
        set_text(arena, tags.album, value);
        return;
    }
    if (matches(key, {"ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"})) {
        set_text(arena, tags.album_artist, value);
        return;
    }
    if (matches(key, {"COMPOSER"})) {
        set_text(arena, tags.composer, value);
        return;
    }
    if (matches(key, {"COMMENT"})) {
        set_text(arena, tags.comment, value);
    }
}

void assign_numbers(Arena& arena, std::string_view key, std::string_view value,
                    ObservedTags& tags) {
    if (matches(key, {"TRACKNUMBER"})) {
        set_pair(value, tags.track_number, tags.track_total);
        return;
    }
    if (matches(key, {"TRACKTOTAL", "TOTALTRACKS"})) {
        set_number(value, tags.track_total);
        return;
    }
    if (matches(key, {"DISCNUMBER"})) {
        set_pair(value, tags.disc_number, tags.disc_total);
        return;
    }
    if (matches(key, {"DISCTOTAL", "TOTALDISCS"})) {
        set_number(value, tags.disc_total);
        return;
    }
    if (matches(key, {"DATE", "YEAR"})) {
        set_text(arena, tags.date, value);
        return;
    }
    if (matches(key, {"ORIGINALDATE", "ORIGINALYEAR"})) {
        set_text(arena, tags.original_date, value);
        return;
    }
    if (matches(key, {"COMPILATION"})) {
        if (!tags.compilation) {
            tags.compilation = is_truthy(value);
        }
        return;
    }
    if (matches(key, {"ITUNESADVISORY"})) {
        if (!tags.explicit_flag) {
            tags.explicit_flag = from_advisory_text(value);
        }
    }
}

void assign_release(Arena& arena, std::string_view key, std::string_view value,
                    ObservedTags& tags) {
    if (matches(key, {"LABEL", "ORGANIZATION"})) {
        set_text(arena, tags.label, value);
        return;
    }
    if (matches(key, {"MEDIA"})) {
        set_text(arena, tags.media, value);
        return;
    }
    if (matches(key, {"ISRC"})) {
        set_text(arena, tags.isrc, value);
        return;
    }
    if (matches(key, {"RELEASECOUNTRY", "MUSICBRAINZ_ALBUMCOUNTRY"})) {
        set_text(arena, tags.release_country, value);
        return;
    }
    if (matches(key, {"RELEASETYPE", "MUSICBRAINZ_ALBUMTYPE"})) {
        set_text(arena, tags.release_type, value);
        return;
    }
    if (matches(key, {"RELEASESTATUS", "MUSICBRAINZ_ALBUMSTATUS"})) {
        set_text(arena, tags.release_status, value);
    }
}

void assign_musicbrainz(Arena& arena, std::string_view key, std::string_view value,
                        ObservedTags& tags) {
    if (matches(key, {"MUSICBRAINZ_TRACKID"})) {
        set_text(arena, tags.musicbrainz_recording_id, value);
        return;
    }
    if (matches(key, {"MUSICBRAINZ_ALBUMID"})) {
        set_text(arena, tags.musicbrainz_release_id, value);
        return;
    }
    if (matches(key, {"MUSICBRAINZ_RELEASEGROUPID"})) {
        set_text(arena, tags.musicbrainz_release_group_id, value);
        return;
    }
    if (matches(key, {"MUSICBRAINZ_RELEASETRACKID"})) {
        set_text(arena, tags.musicbrainz_release_track_id, value);
        return;
    }
    if (matches(key, {"MUSICBRAINZ_ARTISTID"})) {
        set_text(arena, tags.musicbrainz_artist_id, value);
        return;
    }
    if (matches(key, {"MUSICBRAINZ_ALBUMARTISTID"})) {
        set_text(arena, tags.musicbrainz_album_artist_id, value);
    }
}

void assign(Arena& arena, std::string_view key, std::string_view value, ObservedTags& tags,
            std::vector<std::string_view>& genres) {
    if (matches(key, {"GENRE"})) {
        genres.push_back(arena.store(value));
        return;
    }
    assign_identity(arena, key, value, tags);
    assign_numbers(arena, key, value, tags);
    assign_release(arena, key, value, tags);
    assign_musicbrainz(arena, key, value, tags);
}

[[nodiscard]] auto parse_into(Arena& arena, std::span<const std::byte> payload, ObservedTags& tags,
                              std::vector<std::string_view>& genres) -> expected<void> {
    std::size_t cursor = 0;
    const auto vendor = take_string(payload, cursor);
    if (!vendor) {
        return std::unexpected(vendor.error());
    }
    const auto count = take_u32(payload, cursor);
    if (!count) {
        return std::unexpected(count.error());
    }
    std::optional<std::string_view> description;
    for (std::uint32_t index = 0; index < *count; ++index) {
        const auto entry = take_string(payload, cursor);
        if (!entry) {
            return std::unexpected(entry.error());
        }
        const auto parsed = parse_entry(*entry);
        if (!parsed) {
            return std::unexpected(parsed.error());
        }
        ORCA_ASSERT(cursor <= payload.size());
        std::string_view value = parsed->value;
        while (!value.empty() && (value.front() == ' ' || value.front() == '\t' ||
                                  value.front() == '\r' || value.front() == '\n')) {
            value.remove_prefix(1);
        }
        while (!value.empty() && (value.back() == ' ' || value.back() == '\t' ||
                                  value.back() == '\r' || value.back() == '\n')) {
            value.remove_suffix(1);
        }
        if (value.empty()) {
            continue;
        }
        if (matches(parsed->key, {"DESCRIPTION"})) {
            if (!description) {
                description = arena.store(value);
            }
            continue;
        }
        assign(arena, parsed->key, value, tags, genres);
    }
    if (description) {
        set_text(arena, tags.comment, *description);
    }
    return {};
}

struct PictureBlock {
    ArtworkKind kind = ArtworkKind::other;
    std::uint64_t mime_offset = 0;
    std::uint32_t mime_length = 0;
    std::uint64_t data_offset = 0;
    std::uint32_t data_length = 0;
};

struct MetadataBlock {
    std::uint8_t block_type = 0;
    std::uint64_t offset = 0;
    std::size_t length = 0;
};

[[nodiscard]] auto big32(std::span<const std::byte> bytes) -> std::uint32_t {
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value = (value << 8U) | std::to_integer<std::uint8_t>(bytes[index]);
    }
    return value;
}

[[nodiscard]] auto read_picture_block(const storage::ReadableSource& source,
                                      const MetadataBlock& block)
    -> expected<std::optional<PictureBlock>> {
    if (block.length < 32) {
        return std::optional<PictureBlock>{};
    }
    std::array<std::byte, 8> head{};
    const auto head_read = read_exact(source, block.offset, head);
    if (!head_read || *head_read != head.size()) {
        return fail(ErrorCode::truncated_flac_stream, "vorbis: truncated picture block");
    }
    const std::uint32_t picture_type = big32(head);
    const std::uint32_t mime_length = big32(std::span<const std::byte>(head.data() + 4, 4));
    if (mime_length > max_picture_text_size) {
        return std::optional<PictureBlock>{};
    }
    if (8 + static_cast<std::uint64_t>(mime_length) + 24 > block.length) {
        return std::optional<PictureBlock>{};
    }
    std::array<std::byte, 4> description_length{};
    const auto description_read =
        read_exact(source, block.offset + 8 + mime_length, description_length);
    if (!description_read || *description_read != description_length.size()) {
        return fail(ErrorCode::truncated_flac_stream, "vorbis: truncated picture block");
    }
    const std::uint32_t description = big32(description_length);
    if (description > max_picture_text_size) {
        return std::optional<PictureBlock>{};
    }
    const std::uint64_t length_offset =
        8 + static_cast<std::uint64_t>(mime_length) + 4 + description + 16;
    if (length_offset + 4 > block.length) {
        return std::optional<PictureBlock>{};
    }
    std::array<std::byte, 4> data_length{};
    const auto data_read = read_exact(source, block.offset + length_offset, data_length);
    if (!data_read || *data_read != data_length.size()) {
        return fail(ErrorCode::truncated_flac_stream, "vorbis: truncated picture block");
    }
    const std::uint32_t declared = big32(data_length);
    if (declared == 0) {
        return std::optional<PictureBlock>{};
    }
    if (length_offset + 4 + static_cast<std::uint64_t>(declared) > block.length) {
        return std::optional<PictureBlock>{};
    }
    return std::optional<PictureBlock>(PictureBlock{.kind = artwork_kind(picture_type),
                                                    .mime_offset = block.offset + 8,
                                                    .mime_length = mime_length,
                                                    .data_offset = block.offset + length_offset + 4,
                                                    .data_length = declared});
}

class BlockIterator {
public:
    [[nodiscard]] static auto init(const storage::ReadableSource& source)
        -> expected<std::optional<BlockIterator>> {
        std::array<std::byte, 4> magic{};
        const auto read = read_exact(source, 0, magic);
        if (!read) {
            return std::unexpected(read.error());
        }
        if (*read != magic.size()) {
            return std::optional<BlockIterator>{};
        }
        if (std::memcmp(magic.data(), "fLaC", 4) != 0) {
            return fail(ErrorCode::invalid_flac_stream, "vorbis: not a FLAC stream");
        }
        BlockIterator iterator;
        iterator.source_ = &source;
        return std::optional<BlockIterator>(iterator);
    }

    [[nodiscard]] auto next() -> expected<std::optional<MetadataBlock>> {
        if (finished_) {
            return std::optional<MetadataBlock>{};
        }
        if (remaining_ == 0) {
            return fail(ErrorCode::invalid_flac_stream, "vorbis: too many blocks");
        }
        --remaining_;
        std::array<std::byte, 4> header{};
        const auto read = read_exact(*source_, offset_, header);
        if (!read || *read != header.size()) {
            return fail(ErrorCode::truncated_flac_stream, "vorbis: truncated block header");
        }
        offset_ += header.size();
        ORCA_ASSERT(offset_ <= source_->size());
        finished_ = (std::to_integer<std::uint8_t>(header[0]) & 0x80U) != 0U;
        const std::size_t length =
            (static_cast<std::size_t>(std::to_integer<std::uint8_t>(header[1])) << 16U) |
            (static_cast<std::size_t>(std::to_integer<std::uint8_t>(header[2])) << 8U) |
            static_cast<std::size_t>(std::to_integer<std::uint8_t>(header[3]));
        if (offset_ + length > source_->size()) {
            return fail(ErrorCode::truncated_flac_stream, "vorbis: block past end");
        }
        const MetadataBlock block{
            .block_type =
                static_cast<std::uint8_t>(std::to_integer<std::uint8_t>(header[0]) & 0x7fU),
            .offset = offset_,
            .length = length,
        };
        offset_ += length;
        return std::optional<MetadataBlock>(block);
    }

private:
    const storage::ReadableSource* source_ = nullptr;
    std::uint64_t offset_ = 4;
    bool finished_ = false;
    std::size_t remaining_ = 4096;
};

[[nodiscard]] auto read_picture_header(Arena& arena, const storage::ReadableSource& source,
                                       const MetadataBlock& block, ObservedTags& tags)
    -> expected<void> {
    const auto picture = read_picture_block(source, block);
    if (!picture) {
        return std::unexpected(picture.error());
    }
    if (!*picture) {
        return {};
    }
    if (tags.artwork) {
        if (tags.artwork->kind == ArtworkKind::front_cover ||
            (*picture)->kind != ArtworkKind::front_cover) {
            return {};
        }
    }
    std::string mime((*picture)->mime_length, '\0');
    const auto read =
        read_exact(source, (*picture)->mime_offset,
                   std::span<std::byte>(reinterpret_cast<std::byte*>(mime.data()), mime.size()));
    if (!read || *read != mime.size()) {
        return fail(ErrorCode::truncated_flac_stream, "vorbis: truncated picture mime");
    }
    const auto measured =
        image_header::measure_at(source, (*picture)->data_offset, (*picture)->data_length);
    if (!measured) {
        return std::unexpected(measured.error());
    }
    tags.artwork = Artwork{.mime_type = arena.store(mime),
                           .byte_size = (*picture)->data_length,
                           .kind = (*picture)->kind,
                           .width = measured->width,
                           .height = measured->height,
                           .hash = measured->hash};
    return {};
}

}

auto Entries::init(std::span<const std::byte> payload) -> expected<Entries> {
    Entries entries;
    entries.payload_ = payload;
    std::size_t cursor = 0;
    const auto vendor = take_string(payload, cursor);
    if (!vendor) {
        return std::unexpected(vendor.error());
    }
    const auto count = take_u32(payload, cursor);
    if (!count) {
        return std::unexpected(count.error());
    }
    entries.cursor_ = cursor;
    entries.remaining_ = *count;
    return entries;
}

auto Entries::next() -> expected<std::optional<Entry>> {
    ORCA_ASSERT(cursor_ <= payload_.size());
    if (remaining_ == 0) {
        return std::optional<Entry>{};
    }
    --remaining_;
    const auto entry = take_string(payload_, cursor_);
    if (!entry) {
        return std::unexpected(entry.error());
    }
    const auto parsed = parse_entry(*entry);
    if (!parsed) {
        return std::unexpected(parsed.error());
    }
    return std::optional<Entry>(*parsed);
}

auto parse(Arena& arena, std::span<const std::byte> payload) -> expected<ObservedTags> {
    ObservedTags tags;
    std::vector<std::string_view> genres;
    const auto parsed = parse_into(arena, payload, tags, genres);
    if (!parsed) {
        return std::unexpected(parsed.error());
    }
    tags.genres = std::move(genres);
    return tags;
}

auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>> {
    ObservedTags tags;
    std::vector<std::string_view> genres;
    bool found_comment = false;
    auto blocks = BlockIterator::init(source);
    if (!blocks) {
        return std::unexpected(blocks.error());
    }
    if (!*blocks) {
        return std::optional<ObservedTags>{};
    }
    while (true) {
        const auto block = (*blocks)->next();
        if (!block) {
            return std::unexpected(block.error());
        }
        if (!*block) {
            break;
        }
        if ((*block)->block_type == 4) {
            if (found_comment) {
                return fail(ErrorCode::invalid_vorbis_comment, "vorbis: duplicate comment block");
            }
            found_comment = true;
            std::vector<std::byte> payload((*block)->length);
            const auto read_count = read_exact(source, (*block)->offset, payload);
            if (!read_count || *read_count != payload.size()) {
                return fail(ErrorCode::truncated_flac_stream, "vorbis: truncated comment block");
            }
            ORCA_ASSERT(read_count && *read_count == payload.size());
            const auto parsed = parse_into(arena, payload, tags, genres);
            if (!parsed) {
                return std::unexpected(parsed.error());
            }
        } else {
            if ((*block)->block_type == 6) {
                const auto applied = read_picture_header(arena, source, **block, tags);
                if (!applied) {
                    return std::unexpected(applied.error());
                }
            }
        }
    }
    if (!found_comment && !tags.artwork) {
        return std::optional<ObservedTags>{};
    }
    tags.genres = std::move(genres);
    return std::optional<ObservedTags>(std::move(tags));
}

auto read_picture(const storage::ReadableSource& source) -> expected<std::optional<EmbeddedImage>> {
    auto blocks = BlockIterator::init(source);
    if (!blocks) {
        return std::unexpected(blocks.error());
    }
    if (!*blocks) {
        return std::optional<EmbeddedImage>{};
    }
    std::optional<PictureBlock> chosen;
    while (true) {
        const auto block = (*blocks)->next();
        if (!block) {
            return std::unexpected(block.error());
        }
        if (!*block) {
            break;
        }
        if ((*block)->block_type != 6) {
            continue;
        }
        const auto picture = read_picture_block(source, **block);
        if (!picture) {
            return std::unexpected(picture.error());
        }
        if (!*picture) {
            continue;
        }
        if (chosen) {
            if (chosen->kind == ArtworkKind::front_cover ||
                (*picture)->kind != ArtworkKind::front_cover) {
                continue;
            }
        }
        chosen = *picture;
        if ((*picture)->kind == ArtworkKind::front_cover) {
            break;
        }
    }
    if (!chosen) {
        return std::optional<EmbeddedImage>{};
    }
    if (chosen->data_length > max_image_bytes) {
        return fail(ErrorCode::out_of_range, "vorbis: artwork too large");
    }
    std::vector<std::byte> bytes(chosen->data_length);
    const auto read_count = read_exact(source, chosen->data_offset, bytes);
    if (!read_count || *read_count != bytes.size()) {
        return fail(ErrorCode::truncated_flac_stream, "vorbis: truncated artwork");
    }
    ORCA_ASSERT(bytes.size() == chosen->data_length);
    auto image = adopt_image(std::move(bytes), chosen->kind);
    if (!image) {
        return std::unexpected(image.error());
    }
    return std::optional<EmbeddedImage>(std::move(*image));
}

auto read_lyrics(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<lyrics::Content>> {
    auto blocks = BlockIterator::init(source);
    if (!blocks) {
        return std::unexpected(blocks.error());
    }
    if (!*blocks) {
        return std::optional<lyrics::Content>{};
    }
    while (true) {
        const auto block = (*blocks)->next();
        if (!block) {
            return std::unexpected(block.error());
        }
        if (!*block) {
            break;
        }
        if ((*block)->block_type != 4) {
            continue;
        }
        std::vector<std::byte> payload((*block)->length);
        const auto read_count = read_exact(source, (*block)->offset, payload);
        if (!read_count || *read_count != payload.size()) {
            return fail(ErrorCode::truncated_flac_stream, "vorbis: truncated comment block");
        }
        return lyrics_from_comments(arena, payload);
    }
    return std::optional<lyrics::Content>{};
}

auto lyrics_from_comments(Arena& arena, std::span<const std::byte> payload)
    -> expected<std::optional<lyrics::Content>> {
    for (const std::string_view key : {"LYRICS", "UNSYNCEDLYRICS"}) {
        auto entries = Entries::init(payload);
        if (!entries) {
            return std::unexpected(entries.error());
        }
        while (true) {
            const auto entry = entries->next();
            if (!entry) {
                return std::unexpected(entry.error());
            }
            if (!*entry) {
                break;
            }
            if (!matches((*entry)->key, {key})) {
                continue;
            }
            const auto content = lrc::parse(arena, (*entry)->value);
            if (!content) {
                return std::unexpected(content.error());
            }
            if (*content) {
                return content;
            }
        }
    }
    return std::optional<lyrics::Content>{};
}

auto picture_from_block(std::span<const std::byte> block) -> std::optional<PictureView> {
    storage::MemorySource memory(block);
    const MetadataBlock metadata{.block_type = 6, .offset = 0, .length = block.size()};
    const auto picture = read_picture_block(memory, metadata);
    if (!picture || !*picture) {
        return std::nullopt;
    }
    const auto mime_start = static_cast<std::size_t>((*picture)->mime_offset);
    const auto data_start = static_cast<std::size_t>((*picture)->data_offset);
    return PictureView{
        .kind = (*picture)->kind,
        .mime_type = std::string_view(reinterpret_cast<const char*>(block.data() + mime_start),
                                      (*picture)->mime_length),
        .data = block.subspan(data_start, (*picture)->data_length)};
}

auto artwork_kind(std::uint32_t picture_type) -> ArtworkKind {
    if (picture_type == 3) {
        return ArtworkKind::front_cover;
    }
    if (picture_type == 4) {
        return ArtworkKind::back_cover;
    }
    return ArtworkKind::other;
}

}
