#include "liborca/metadata/ogg_comment.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/metadata/image_header.hpp"
#include "liborca/metadata/vorbis_comment.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace orca::metadata::ogg_comment {

namespace {

constexpr std::size_t page_header_bytes = 27;
constexpr std::size_t max_pages = 4096;

struct Signature {
    std::string_view identification;
    std::string_view comment;
};

constexpr Signature opus_signature{.identification = "OpusHead", .comment = "OpusTags"};
constexpr Signature vorbis_signature{.identification = "\x01vorbis", .comment = "\x03vorbis"};

[[nodiscard]] auto starts_with(std::span<const std::byte> bytes, std::string_view prefix) -> bool {
    return bytes.size() >= prefix.size() &&
           std::memcmp(bytes.data(), prefix.data(), prefix.size()) == 0;
}

[[nodiscard]] auto little32(std::span<const std::byte> bytes) -> std::uint32_t {
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value |= static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[index]))
                 << (index * 8U);
    }
    return value;
}

[[nodiscard]] auto base64_value(char value) -> int {
    if (value >= 'A' && value <= 'Z') {
        return value - 'A';
    }
    if (value >= 'a' && value <= 'z') {
        return value - 'a' + 26;
    }
    if (value >= '0' && value <= '9') {
        return value - '0' + 52;
    }
    if (value == '+') {
        return 62;
    }
    if (value == '/') {
        return 63;
    }
    return -1;
}

[[nodiscard]] auto base64_decode(std::string_view text) -> std::optional<std::vector<std::byte>> {
    std::vector<std::byte> out;
    std::uint32_t accumulator = 0;
    int count = 0;
    for (const char value : text) {
        if (value == '=') {
            break;
        }
        const int decoded = base64_value(value);
        if (decoded < 0) {
            return std::nullopt;
        }
        accumulator = (accumulator << 6U) | static_cast<std::uint32_t>(decoded);
        ++count;
        if (count == 4) {
            out.push_back(static_cast<std::byte>((accumulator >> 16U) & 0xffU));
            out.push_back(static_cast<std::byte>((accumulator >> 8U) & 0xffU));
            out.push_back(static_cast<std::byte>(accumulator & 0xffU));
            accumulator = 0;
            count = 0;
        }
    }
    if (count == 2) {
        out.push_back(static_cast<std::byte>((accumulator >> 4U) & 0xffU));
    } else {
        if (count == 3) {
            out.push_back(static_cast<std::byte>((accumulator >> 10U) & 0xffU));
            out.push_back(static_cast<std::byte>((accumulator >> 2U) & 0xffU));
        }
    }
    ORCA_ASSERT(count < 4);
    return out;
}

class PacketReader {
public:
    explicit PacketReader(const storage::ReadableSource& source) : source_(&source) {}

    [[nodiscard]] auto next() -> expected<std::optional<std::vector<std::byte>>> {
        ORCA_ASSERT(segment_index_ <= segment_count_);
        std::vector<std::byte> packet;
        while (true) {
            if (segment_index_ == segment_count_) {
                const auto page = next_page();
                if (!page) {
                    return std::unexpected(page.error());
                }
                if (!*page) {
                    if (packet.empty()) {
                        return std::optional<std::vector<std::byte>>{};
                    }
                    return fail(ErrorCode::truncated_ogg_stream, "ogg: truncated packet");
                }
                continue;
            }
            const std::size_t length = segments_[segment_index_];
            ++segment_index_;
            if (packet.size() + length > max_packet_bytes) {
                return fail(ErrorCode::ogg_comment_too_large, "ogg: packet too large");
            }
            const std::size_t start = packet.size();
            packet.resize(start + length);
            const auto read =
                source_->read_at(offset_, std::span<std::byte>(packet.data() + start, length));
            if (!read || *read != length) {
                return fail(ErrorCode::truncated_ogg_stream, "ogg: short packet");
            }
            offset_ += length;
            ORCA_ASSERT(segment_index_ <= segment_count_);
            if (length < 255) {
                return std::optional<std::vector<std::byte>>(std::move(packet));
            }
        }
    }

private:
    [[nodiscard]] auto next_page() -> expected<bool> {
        while (true) {
            if (pages_examined_ == max_pages) {
                return fail(ErrorCode::ogg_comment_not_found, "ogg: comment header not found");
            }
            ++pages_examined_;
            std::array<std::byte, page_header_bytes> header{};
            const auto got = source_->read_at(offset_, header);
            if (!got) {
                return std::unexpected(got.error());
            }
            if (*got == 0) {
                return false;
            }
            if (*got != header.size()) {
                return fail(ErrorCode::truncated_ogg_stream, "ogg: truncated page header");
            }
            if (std::memcmp(header.data(), "OggS", 4) != 0 || header[4] != std::byte{0}) {
                return fail(ErrorCode::invalid_ogg_stream, "ogg: invalid page");
            }
            const std::uint32_t serial =
                little32(std::span<const std::byte>(header.data() + 14, 4));
            const std::size_t count = std::to_integer<std::uint8_t>(header[26]);
            std::array<std::uint8_t, 255> table{};
            const auto table_read = source_->read_at(
                offset_ + page_header_bytes,
                std::span<std::byte>(reinterpret_cast<std::byte*>(table.data()), count));
            if (!table_read || *table_read != count) {
                return fail(ErrorCode::truncated_ogg_stream, "ogg: truncated segment table");
            }
            const std::uint64_t body_offset = offset_ + page_header_bytes + count;
            std::uint64_t body_length = 0;
            for (std::size_t index = 0; index < count; ++index) {
                body_length += table[index];
            }

            const std::uint32_t first = serial_.value_or(serial);
            serial_ = first;
            if (serial != first) {
                offset_ = body_offset + body_length;
                continue;
            }
            std::memcpy(segments_.data(), table.data(), count);
            segment_count_ = count;
            segment_index_ = 0;
            offset_ = body_offset;
            return true;
        }
    }

    const storage::ReadableSource* source_;
    std::uint64_t offset_ = 0;
    std::optional<std::uint32_t> serial_;
    std::array<std::uint8_t, 255> segments_{};
    std::size_t segment_count_ = 0;
    std::size_t segment_index_ = 0;
    std::size_t pages_examined_ = 0;
};

struct Comment {
    std::vector<std::byte> packet;
    std::span<const std::byte> payload;
};

[[nodiscard]] auto read_comment(const storage::ReadableSource& source)
    -> expected<std::optional<Comment>> {
    PacketReader packets(source);
    auto identification = packets.next();
    if (!identification) {
        return std::unexpected(identification.error());
    }
    if (!*identification) {
        return std::optional<Comment>{};
    }
    Signature signature;
    if (starts_with(**identification, opus_signature.identification)) {
        signature = opus_signature;
    } else {
        if (starts_with(**identification, vorbis_signature.identification)) {
            signature = vorbis_signature;
        } else {
            return std::optional<Comment>{};
        }
    }

    auto packet = packets.next();
    if (!packet) {
        return std::unexpected(packet.error());
    }
    if (!*packet) {
        return fail(ErrorCode::truncated_ogg_stream, "ogg: missing comment packet");
    }
    if (!starts_with(**packet, signature.comment)) {
        return fail(ErrorCode::invalid_ogg_stream, "ogg: bad comment signature");
    }
    Comment comment;
    comment.packet = std::move(**packet);
    comment.payload = std::span<const std::byte>(comment.packet).subspan(signature.comment.size());
    ORCA_ASSERT(comment.payload.size() <= comment.packet.size());
    return std::optional<Comment>(std::move(comment));
}

struct Picture {
    std::vector<std::byte> block;
    vorbis_comment::PictureView view;
};

[[nodiscard]] auto key_equals(std::string_view key, std::string_view expected) -> bool {
    if (key.size() != expected.size()) {
        return false;
    }
    for (std::size_t index = 0; index < key.size(); ++index) {
        const auto lower = [](char value) {
            return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
        };
        if (lower(key[index]) != lower(expected[index])) {
            return false;
        }
    }
    return true;
}

[[nodiscard]] auto choose_picture(std::span<const std::byte> payload)
    -> expected<std::optional<Picture>> {
    auto entries = vorbis_comment::Entries::init(payload);
    if (!entries) {
        return std::unexpected(entries.error());
    }
    std::optional<Picture> chosen;
    while (true) {
        const auto entry = entries->next();
        if (!entry) {
            return std::unexpected(entry.error());
        }
        if (!*entry) {
            break;
        }
        if (!key_equals((*entry)->key, "METADATA_BLOCK_PICTURE")) {
            continue;
        }
        if (chosen && chosen->view.kind == ArtworkKind::front_cover) {
            break;
        }
        auto decoded = base64_decode((*entry)->value);
        if (!decoded) {
            continue;
        }
        const auto view = vorbis_comment::picture_from_block(*decoded);
        if (!view) {
            continue;
        }
        if (chosen && view->kind != ArtworkKind::front_cover) {
            continue;
        }
        Picture picture;
        picture.block = std::move(*decoded);
        picture.view = *view;
        chosen = std::move(picture);
    }
    return chosen;
}

}

auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>> {
    auto comment = read_comment(source);
    if (!comment) {
        return std::unexpected(comment.error());
    }
    if (!*comment) {
        return std::optional<ObservedTags>{};
    }
    auto tags = vorbis_comment::parse(arena, (*comment)->payload);
    if (!tags) {
        return std::unexpected(tags.error());
    }
    auto picture = choose_picture((*comment)->payload);
    if (!picture) {
        return std::unexpected(picture.error());
    }
    if (*picture) {
        const auto measured = image_header::measure((*picture)->view.data);
        tags->artwork = Artwork{.mime_type = arena.store((*picture)->view.mime_type),
                                .byte_size = (*picture)->view.data.size(),
                                .kind = (*picture)->view.kind,
                                .width = measured.width,
                                .height = measured.height,
                                .hash = measured.hash};
    }
    return std::optional<ObservedTags>(std::move(*tags));
}

auto read_picture(const storage::ReadableSource& source) -> expected<std::optional<EmbeddedImage>> {
    auto comment = read_comment(source);
    if (!comment) {
        return std::unexpected(comment.error());
    }
    if (!*comment) {
        return std::optional<EmbeddedImage>{};
    }
    auto picture = choose_picture((*comment)->payload);
    if (!picture) {
        return std::unexpected(picture.error());
    }
    if (!*picture) {
        return std::optional<EmbeddedImage>{};
    }
    if ((*picture)->view.data.size() > max_image_bytes) {
        return fail(ErrorCode::out_of_range, "ogg: artwork too large");
    }
    std::vector<std::byte> bytes((*picture)->view.data.begin(), (*picture)->view.data.end());
    auto image = adopt_image(std::move(bytes), (*picture)->view.kind);
    if (!image) {
        return std::unexpected(image.error());
    }
    return std::optional<EmbeddedImage>(std::move(*image));
}

auto read_lyrics(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<lyrics::Content>> {
    auto comment = read_comment(source);
    if (!comment) {
        return std::unexpected(comment.error());
    }
    if (!*comment) {
        return std::optional<lyrics::Content>{};
    }
    return vorbis_comment::lyrics_from_comments(arena, (*comment)->payload);
}

}
