#include "liborca/metadata/id3v2.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/metadata/id3v1.hpp"
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

namespace orca::metadata::id3v2 {

namespace {

constexpr std::size_t max_text_bytes = 1U << 20;

struct LoadedTag {
    std::vector<std::byte> body;
    std::span<std::byte> span;
    std::uint8_t major = 0;
};

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
    ORCA_ASSERT(filled <= buffer.size());
    return filled;
}

[[nodiscard]] auto syncsafe(std::span<const std::byte> bytes) -> expected<std::uint32_t> {
    std::uint32_t value = 0;
    for (const std::byte byte : bytes) {
        const auto raw = std::to_integer<std::uint8_t>(byte);
        if ((raw & 0x80U) != 0U) {
            return fail(ErrorCode::invalid_id3v2_tag, "id3v2: bad syncsafe size");
        }
        value = (value << 7U) | raw;
    }
    return value;
}

[[nodiscard]] auto big32(std::span<const std::byte> bytes) -> std::uint32_t {
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value = (value << 8U) | std::to_integer<std::uint8_t>(bytes[index]);
    }
    return value;
}

[[nodiscard]] auto unsynchronize(std::span<std::byte> bytes) -> std::span<std::byte> {
    std::size_t write = 0;
    std::size_t read = 0;
    while (read < bytes.size()) {
        const std::byte byte = bytes[read];
        bytes[write] = byte;
        ++write;
        ++read;
        if (byte == std::byte{0xff} && read < bytes.size() && bytes[read] == std::byte{0}) {
            ++read;
        }
    }
    return bytes.subspan(0, write);
}

[[nodiscard]] auto skip_extended_header(std::span<std::byte> bytes, std::uint8_t major)
    -> expected<std::span<std::byte>> {
    if (bytes.size() < 6) {
        return fail(ErrorCode::truncated_id3v2_tag, "id3v2: short extended header");
    }
    std::size_t declared = 0;
    if (major >= 4) {
        const auto size = syncsafe(bytes.subspan(0, 4));
        if (!size) {
            return std::unexpected(size.error());
        }
        declared = *size;
    } else {
        declared = static_cast<std::size_t>(big32(bytes.subspan(0, 4))) + 4;
    }
    if (declared < 4 || declared > bytes.size()) {
        return fail(ErrorCode::truncated_id3v2_tag, "id3v2: extended header past end");
    }
    return bytes.subspan(declared);
}

[[nodiscard]] auto load_tag(const storage::ReadableSource& source)
    -> expected<std::optional<LoadedTag>> {
    std::array<std::byte, 10> header{};
    const auto header_read = read_exact(source, 0, header);
    if (!header_read) {
        return std::unexpected(header_read.error());
    }
    if (*header_read != header.size()) {
        return std::optional<LoadedTag>{};
    }
    if (std::memcmp(header.data(), "ID3", 3) != 0) {
        return std::optional<LoadedTag>{};
    }
    if (header[3] == std::byte{0xff} || header[4] == std::byte{0xff}) {
        return fail(ErrorCode::invalid_id3v2_tag, "id3v2: invalid version bytes");
    }
    const auto major = std::to_integer<std::uint8_t>(header[3]);
    const auto size = syncsafe(std::span<const std::byte>(header.data() + 6, 4));
    if (!size) {
        return std::unexpected(size.error());
    }
    if (*size == 0) {
        return std::optional<LoadedTag>{};
    }
    if (*size > max_tag_bytes) {
        return fail(ErrorCode::id3v2_tag_too_large, "id3v2: tag too large");
    }
    if (major < 3 || major > 4) {
        return std::optional<LoadedTag>{};
    }
    if (*size > source.size() - header.size()) {
        return fail(ErrorCode::truncated_id3v2_tag, "id3v2: tag past end");
    }

    LoadedTag tag;
    tag.body.resize(*size);
    const auto body_read = read_exact(source, header.size(), tag.body);
    if (!body_read) {
        return std::unexpected(body_read.error());
    }
    if (*body_read != tag.body.size()) {
        return fail(ErrorCode::truncated_id3v2_tag, "id3v2: short tag body");
    }
    tag.major = major;
    tag.span = tag.body;
    const auto flags = std::to_integer<std::uint8_t>(header[5]);
    if ((flags & 0x80U) != 0U) {
        tag.span = unsynchronize(tag.span);
    }
    if ((flags & 0x40U) != 0U) {
        const auto skipped = skip_extended_header(tag.span, major);
        if (!skipped) {
            return std::unexpected(skipped.error());
        }
        tag.span = *skipped;
    }
    return std::optional<LoadedTag>(std::move(tag));
}

[[nodiscard]] auto is_frame_identifier(const std::array<char, 4>& identifier) -> bool {
    for (const char byte : identifier) {
        const bool upper = byte >= 'A' && byte <= 'Z';
        const bool digit = byte >= '0' && byte <= '9';
        if (!upper && !digit) {
            return false;
        }
    }
    return true;
}

struct Frame {
    std::array<char, 4> identifier{};
    std::span<std::byte> data;
};

[[nodiscard]] auto strip_prefix(std::span<std::byte> data, std::size_t count)
    -> std::optional<std::span<std::byte>> {
    if (data.size() < count) {
        return std::nullopt;
    }
    return data.subspan(count);
}

class FrameIterator {
public:
    FrameIterator(std::span<std::byte> body, std::uint8_t major) : body_(body), major_(major) {}

    [[nodiscard]] auto next() -> expected<std::optional<Frame>> {
        ORCA_ASSERT(position_ <= body_.size());
        while (position_ + 10 <= body_.size()) {
            std::array<char, 4> identifier{};
            std::memcpy(identifier.data(), body_.data() + position_, 4);
            if (identifier[0] == '\0' || !is_frame_identifier(identifier)) {
                return std::optional<Frame>{};
            }
            const auto size_bytes = std::span<const std::byte>(body_.data() + position_ + 4, 4);
            std::size_t declared = 0;
            if (major_ >= 4) {
                const auto size = syncsafe(size_bytes);
                declared = size ? *size : big32(size_bytes);
            } else {
                declared = big32(size_bytes);
            }
            const auto format_flags = std::to_integer<std::uint8_t>(body_[position_ + 9]);
            position_ += 10;
            if (declared > body_.size() - position_) {
                return fail(ErrorCode::truncated_id3v2_tag, "id3v2: frame past end");
            }
            std::span<std::byte> data = body_.subspan(position_, declared);
            position_ += declared;
            ORCA_ASSERT(position_ <= body_.size());

            if (major_ >= 4) {
                if ((format_flags & 0x40U) != 0U) {
                    const auto stripped = strip_prefix(data, 1);
                    if (!stripped) {
                        continue;
                    }
                    data = *stripped;
                }
                if ((format_flags & 0x0cU) != 0U) {
                    continue;
                }
                if ((format_flags & 0x01U) != 0U) {
                    const auto stripped = strip_prefix(data, 4);
                    if (!stripped) {
                        continue;
                    }
                    data = *stripped;
                }
                if ((format_flags & 0x02U) != 0U) {
                    data = unsynchronize(data);
                }
            } else {
                if ((format_flags & 0xc0U) != 0U) {
                    continue;
                }
                if ((format_flags & 0x20U) != 0U) {
                    const auto stripped = strip_prefix(data, 1);
                    if (!stripped) {
                        continue;
                    }
                    data = *stripped;
                }
            }
            return std::optional<Frame>(Frame{.identifier = identifier, .data = data});
        }
        return std::optional<Frame>{};
    }

private:
    std::span<std::byte> body_;
    std::uint8_t major_;
    std::size_t position_ = 0;
};

[[nodiscard]] auto is_wide_encoding(std::uint8_t encoding) -> bool {
    return encoding == 1 || encoding == 2;
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

[[nodiscard]] auto utf16_to_utf8(std::span<const std::uint16_t> units)
    -> std::optional<std::string> {
    std::string out;
    std::size_t index = 0;
    while (index < units.size()) {
        std::uint32_t codepoint = units[index];
        ++index;
        if (codepoint >= 0xd800U && codepoint <= 0xdbffU) {
            if (index >= units.size()) {
                return std::nullopt;
            }
            const std::uint32_t low = units[index];
            if (low < 0xdc00U || low > 0xdfffU) {
                return std::nullopt;
            }
            ++index;
            codepoint = 0x10000U + ((codepoint - 0xd800U) << 10U) + (low - 0xdc00U);
        } else {
            if (codepoint >= 0xdc00U && codepoint <= 0xdfffU) {
                return std::nullopt;
            }
        }
        if (codepoint < 0x80U) {
            out.push_back(static_cast<char>(codepoint));
        } else {
            if (codepoint < 0x800U) {
                out.push_back(static_cast<char>(0xc0U | (codepoint >> 6U)));
                out.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
            } else {
                if (codepoint < 0x10000U) {
                    out.push_back(static_cast<char>(0xe0U | (codepoint >> 12U)));
                    out.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3fU)));
                    out.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
                } else {
                    out.push_back(static_cast<char>(0xf0U | (codepoint >> 18U)));
                    out.push_back(static_cast<char>(0x80U | ((codepoint >> 12U) & 0x3fU)));
                    out.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3fU)));
                    out.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
                }
            }
        }
    }
    return out;
}

[[nodiscard]] auto decode_utf16(Arena& arena, std::span<const std::byte> bytes,
                                std::optional<bool> big) -> expected<std::string_view> {
    std::span<const std::byte> rest = bytes;
    bool big_endian = big.value_or(false);
    if (!big && rest.size() >= 2) {
        if (rest[0] == std::byte{0xff} && rest[1] == std::byte{0xfe}) {
            big_endian = false;
            rest = rest.subspan(2);
        } else {
            if (rest[0] == std::byte{0xfe} && rest[1] == std::byte{0xff}) {
                big_endian = true;
                rest = rest.subspan(2);
            }
        }
    }
    if (rest.size() % 2 != 0) {
        return fail(ErrorCode::invalid_id3v2_text, "id3v2: odd UTF-16 length");
    }
    std::vector<std::uint16_t> units(rest.size() / 2);
    for (std::size_t index = 0; index < units.size(); ++index) {
        const auto low = std::to_integer<std::uint8_t>(rest[index * 2]);
        const auto high = std::to_integer<std::uint8_t>(rest[(index * 2) + 1]);
        units[index] = big_endian ? static_cast<std::uint16_t>((low << 8U) | high)
                                  : static_cast<std::uint16_t>((high << 8U) | low);
    }
    const auto text = utf16_to_utf8(units);
    if (!text) {
        return fail(ErrorCode::invalid_id3v2_text, "id3v2: invalid UTF-16");
    }
    return arena.store(*text);
}

[[nodiscard]] auto decode_text(Arena& arena, std::uint8_t encoding,
                               std::span<const std::byte> bytes) -> expected<std::string_view> {
    switch (encoding) {
    case 0:
        return arena.store(id3v1::latin1_to_utf8(bytes));
    case 1:
        return decode_utf16(arena, bytes, std::nullopt);
    case 2:
        return decode_utf16(arena, bytes, true);
    case 3: {
        const std::string_view text(reinterpret_cast<const char*>(bytes.data()), bytes.size());
        if (!utf8_valid(text)) {
            return fail(ErrorCode::invalid_id3v2_text, "id3v2: invalid UTF-8");
        }
        return arena.store(text);
    }
    default:
        return fail(ErrorCode::invalid_id3v2_text, "id3v2: unknown text encoding");
    }
}

[[nodiscard]] auto terminator_length(std::uint8_t encoding, std::span<const std::byte> bytes)
    -> std::size_t {
    if (is_wide_encoding(encoding)) {
        std::size_t index = 0;
        while (index + 1 < bytes.size()) {
            if (bytes[index] == std::byte{0} && bytes[index + 1] == std::byte{0}) {
                return index + 2;
            }
            index += 2;
        }
        return bytes.size();
    }
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        if (bytes[index] == std::byte{0}) {
            return index + 1;
        }
    }
    return bytes.size();
}

[[nodiscard]] auto split_terminated(std::uint8_t encoding, std::span<const std::byte> bytes)
    -> std::pair<std::span<const std::byte>, std::span<const std::byte>> {
    if (is_wide_encoding(encoding)) {
        std::size_t index = 0;
        while (index + 1 < bytes.size()) {
            if (bytes[index] == std::byte{0} && bytes[index + 1] == std::byte{0}) {
                return {bytes.subspan(0, index), bytes.subspan(index + 2)};
            }
            index += 2;
        }
        return {bytes, {}};
    }
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        if (bytes[index] == std::byte{0}) {
            return {bytes.subspan(0, index), bytes.subspan(index + 1)};
        }
    }
    return {bytes, {}};
}

[[nodiscard]] auto decode_text_values(Arena& arena, std::span<const std::byte> data)
    -> expected<std::vector<std::string_view>> {
    std::vector<std::string_view> values;
    if (data.empty()) {
        return values;
    }
    const auto encoding = std::to_integer<std::uint8_t>(data[0]);
    if (encoding > 3) {
        return fail(ErrorCode::invalid_id3v2_text, "id3v2: unknown text encoding");
    }
    const std::span<const std::byte> rest = data.subspan(1);
    if (rest.size() > max_text_bytes) {
        return fail(ErrorCode::invalid_id3v2_text, "id3v2: text too long");
    }
    const std::size_t step = is_wide_encoding(encoding) ? 2 : 1;
    std::size_t start = 0;
    std::size_t index = 0;
    while (index + step <= rest.size()) {
        const bool terminated =
            step == 1 ? rest[index] == std::byte{0}
                      : (rest[index] == std::byte{0} && rest[index + 1] == std::byte{0});
        if (!terminated) {
            index += step;
            continue;
        }
        const auto decoded = decode_text(arena, encoding, rest.subspan(start, index - start));
        if (!decoded) {
            return std::unexpected(decoded.error());
        }
        values.push_back(*decoded);
        start = index + step;
        ORCA_ASSERT(start <= rest.size());
        index += step;
    }
    if (start < rest.size()) {
        const auto decoded = decode_text(arena, encoding, rest.subspan(start));
        if (!decoded) {
            return std::unexpected(decoded.error());
        }
        values.push_back(*decoded);
    }
    while (!values.empty() && values.back().empty()) {
        values.pop_back();
    }
    return values;
}

[[nodiscard]] auto is_all_digits(std::string_view text) -> bool {
    for (const char byte : text) {
        if (byte < '0' || byte > '9') {
            return false;
        }
    }
    return true;
}

[[nodiscard]] auto canonical_genre(Arena& arena, std::string_view value) -> std::string_view {
    std::string_view text = value;
    while (!text.empty() && text.front() == ' ') {
        text.remove_prefix(1);
    }
    while (!text.empty() && text.back() == ' ') {
        text.remove_suffix(1);
    }
    if (text.size() >= 2 && text.front() == '(' && text.back() == ')') {
        text = text.substr(1, text.size() - 2);
    }
    if (text == "RX") {
        return arena.store("Remix");
    }
    if (text == "CR") {
        return arena.store("Cover");
    }
    if (!text.empty() && is_all_digits(text)) {
        std::uint32_t code = 0;
        bool overflow = false;
        for (const char byte : text) {
            const std::uint64_t next =
                (static_cast<std::uint64_t>(code) * 10U) + static_cast<std::uint32_t>(byte - '0');
            if (next > 0xffU) {
                overflow = true;
                break;
            }
            code = static_cast<std::uint32_t>(next);
        }
        if (overflow) {
            return arena.store(text);
        }
        const auto name = id3v1::genre_name(static_cast<std::uint8_t>(code));
        if (name) {
            return arena.store(*name);
        }
        return arena.store("");
    }
    return arena.store(text);
}

void claim(std::optional<std::string_view>& field, std::string_view value) {
    if (field || value.empty()) {
        return;
    }
    field = value;
}

[[nodiscard]] auto parse_u32(std::string_view text) -> std::optional<std::uint32_t> {
    if (text.empty()) {
        return std::nullopt;
    }
    std::uint32_t value = 0;
    for (const char byte : text) {
        if (byte < '0' || byte > '9') {
            return std::nullopt;
        }
        const std::uint64_t next =
            (static_cast<std::uint64_t>(value) * 10U) + static_cast<std::uint32_t>(byte - '0');
        if (next > 0xffffffffULL) {
            return std::nullopt;
        }
        value = static_cast<std::uint32_t>(next);
    }
    return value;
}

void claim_number(std::string_view value, std::optional<std::uint32_t>& field) {
    if (field) {
        return;
    }
    while (!value.empty() && value.front() == ' ') {
        value.remove_prefix(1);
    }
    while (!value.empty() && value.back() == ' ') {
        value.remove_suffix(1);
    }
    if (value.empty()) {
        return;
    }
    field = parse_u32(value);
}

void claim_pair(std::string_view value, std::optional<std::uint32_t>& number,
                std::optional<std::uint32_t>& total) {
    const auto split = value.find('/');
    if (split != std::string_view::npos) {
        claim_number(value.substr(0, split), number);
        claim_number(value.substr(split + 1), total);
        return;
    }
    claim_number(value, number);
}

[[nodiscard]] auto is_truthy(std::string_view value) -> bool {
    const auto lower = [](std::string_view text) {
        std::string out(text);
        for (char& byte : out) {
            if (byte >= 'A' && byte <= 'Z') {
                byte = static_cast<char>(byte - 'A' + 'a');
            }
        }
        return out;
    };
    const std::string normalized = lower(value);
    return normalized == "1" || normalized == "true" || normalized == "yes";
}

[[nodiscard]] auto eql_any(std::string_view text, std::initializer_list<std::string_view> spellings)
    -> bool {
    for (const std::string_view spelling : spellings) {
        if (text.size() != spelling.size()) {
            continue;
        }
        bool equal = true;
        for (std::size_t index = 0; index < text.size(); ++index) {
            const auto lower = [](char value) {
                return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
            };
            if (lower(text[index]) != lower(spelling[index])) {
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

struct Picture {
    std::string_view mime;
    std::span<const std::byte> data;
    ArtworkKind kind = ArtworkKind::other;
};

[[nodiscard]] auto decode_picture(std::span<const std::byte> data) -> std::optional<Picture> {
    if (data.size() < 4) {
        return std::nullopt;
    }
    const auto encoding = std::to_integer<std::uint8_t>(data[0]);
    std::size_t mime_end = 0;
    while (mime_end < data.size() - 1 && data[1 + mime_end] != std::byte{0}) {
        ++mime_end;
    }
    if (1 + mime_end >= data.size()) {
        return std::nullopt;
    }
    const std::string_view mime(reinterpret_cast<const char*>(data.data() + 1), mime_end);
    std::size_t cursor = 1 + mime_end + 1;
    if (cursor >= data.size()) {
        return std::nullopt;
    }
    const auto picture_type = std::to_integer<std::uint8_t>(data[cursor]);
    ++cursor;
    cursor += terminator_length(encoding, data.subspan(cursor));
    if (cursor >= data.size()) {
        return std::nullopt;
    }
    if (mime == "-->") {
        return std::nullopt;
    }
    ArtworkKind kind = ArtworkKind::other;
    if (picture_type == 3) {
        kind = ArtworkKind::front_cover;
    } else {
        if (picture_type == 4) {
            kind = ArtworkKind::back_cover;
        }
    }
    return Picture{.mime = mime, .data = data.subspan(cursor), .kind = kind};
}

void apply_picture(Arena& arena, std::span<const std::byte> data, ObservedTags& tags) {
    const auto picture = decode_picture(data);
    if (!picture) {
        return;
    }
    if (tags.artwork) {
        if (tags.artwork->kind == ArtworkKind::front_cover ||
            picture->kind != ArtworkKind::front_cover) {
            return;
        }
    }
    const auto measured = image_header::measure(picture->data);
    const auto mime = id3v1::latin1_to_utf8(std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(picture->mime.data()), picture->mime.size()));
    tags.artwork = Artwork{.mime_type = arena.store(mime),
                           .byte_size = picture->data.size(),
                           .kind = picture->kind,
                           .width = measured.width,
                           .height = measured.height,
                           .hash = measured.hash};
}

struct CommentFrame {
    std::uint8_t encoding = 0;
    std::span<const std::byte> description;
    std::span<const std::byte> text;
};

[[nodiscard]] auto split_comment(std::span<const std::byte> data) -> std::optional<CommentFrame> {
    if (data.size() < 4) {
        return std::nullopt;
    }
    const auto encoding = std::to_integer<std::uint8_t>(data[0]);
    if (encoding > 3) {
        return std::nullopt;
    }
    const auto description = split_terminated(encoding, data.subspan(4));
    const auto text = split_terminated(encoding, description.second);
    if (text.first.size() > max_text_bytes) {
        return std::nullopt;
    }
    return CommentFrame{.encoding = encoding, .description = description.first, .text = text.first};
}

[[nodiscard]] auto is_undescribed(const CommentFrame& comment) -> bool {
    if (comment.description.empty()) {
        return true;
    }
    return comment.encoding == 1 && comment.description.size() == 2 &&
           (std::memcmp(comment.description.data(), "\xff\xfe", 2) == 0 ||
            std::memcmp(comment.description.data(), "\xfe\xff", 2) == 0);
}

[[nodiscard]] auto apply_day_month(Arena& arena, ObservedTags& tags, std::string_view day_month)
    -> expected<void> {
    if (!tags.date || tags.date->size() != 4) {
        return {};
    }
    for (const char byte : day_month) {
        if (byte < '0' || byte > '9') {
            return {};
        }
    }
    std::string combined(*tags.date);
    combined += '-';
    combined.append(day_month.substr(2, 2));
    combined += '-';
    combined.append(day_month.substr(0, 2));
    tags.date = arena.store(combined);
    return {};
}

[[nodiscard]] auto assign_user_text_identifiers(std::string_view description,
                                                std::string_view value, ObservedTags& tags)
    -> bool {
    if (eql_any(description, {"MusicBrainz Track Id", "MUSICBRAINZ_TRACKID"})) {
        claim(tags.musicbrainz_recording_id, value);
        return true;
    }
    if (eql_any(description, {"MusicBrainz Album Id", "MUSICBRAINZ_ALBUMID"})) {
        claim(tags.musicbrainz_release_id, value);
        return true;
    }
    if (eql_any(description, {"MusicBrainz Release Group Id", "MUSICBRAINZ_RELEASEGROUPID"})) {
        claim(tags.musicbrainz_release_group_id, value);
        return true;
    }
    if (eql_any(description, {"MusicBrainz Release Track Id", "MUSICBRAINZ_RELEASETRACKID"})) {
        claim(tags.musicbrainz_release_track_id, value);
        return true;
    }
    if (eql_any(description, {"MusicBrainz Artist Id", "MUSICBRAINZ_ARTISTID"})) {
        claim(tags.musicbrainz_artist_id, value);
        return true;
    }
    if (eql_any(description, {"MusicBrainz Album Artist Id", "MUSICBRAINZ_ALBUMARTISTID"})) {
        claim(tags.musicbrainz_album_artist_id, value);
        return true;
    }
    return false;
}

[[nodiscard]] auto assign_user_text_release(std::string_view description, std::string_view value,
                                            ObservedTags& tags) -> bool {
    if (eql_any(description, {"MusicBrainz Album Type", "RELEASETYPE"})) {
        claim(tags.release_type, value);
        return true;
    }
    if (eql_any(description, {"MusicBrainz Album Status", "RELEASESTATUS"})) {
        claim(tags.release_status, value);
        return true;
    }
    if (eql_any(description, {"MusicBrainz Album Release Country", "RELEASECOUNTRY"})) {
        claim(tags.release_country, value);
        return true;
    }
    if (eql_any(description, {"originaldate", "originalyear"})) {
        claim(tags.original_date, value);
        return true;
    }
    if (eql_any(description, {"LABEL"})) {
        claim(tags.label, value);
        return true;
    }
    if (eql_any(description, {"ISRC"})) {
        claim(tags.isrc, value);
        return true;
    }
    return false;
}

void assign_user_text_flags(std::string_view description, std::string_view value,
                            ObservedTags& tags,
                            std::optional<std::string_view>& user_text_comment) {
    if (eql_any(description, {"COMPILATION"})) {
        if (!tags.compilation) {
            tags.compilation = is_truthy(value);
        }
        return;
    }
    if (eql_any(description, {"ITUNESADVISORY"})) {
        if (!tags.explicit_flag) {
            tags.explicit_flag = from_advisory_text(value);
        }
        return;
    }
    if (eql_any(description, {"comment"})) {
        claim(user_text_comment, value);
    }
}

[[nodiscard]] auto apply_user_text(Arena& arena, std::span<const std::byte> data,
                                   ObservedTags& tags,
                                   std::optional<std::string_view>& user_text_comment)
    -> expected<void> {
    const auto values = decode_text_values(arena, data);
    if (!values) {
        return std::unexpected(values.error());
    }
    if (values->size() < 2) {
        return {};
    }
    const std::string_view description = (*values)[0];
    const std::string_view value = (*values)[1];
    if (value.empty()) {
        return {};
    }
    if (assign_user_text_identifiers(description, value, tags)) {
        return {};
    }
    if (assign_user_text_release(description, value, tags)) {
        return {};
    }
    assign_user_text_flags(description, value, tags, user_text_comment);
    return {};
}

[[nodiscard]] auto apply_comment(Arena& arena, std::span<const std::byte> data, ObservedTags& tags)
    -> expected<void> {
    if (tags.comment) {
        return {};
    }
    const auto comment = split_comment(data);
    if (!comment || !is_undescribed(*comment)) {
        return {};
    }
    const auto text = decode_text(arena, comment->encoding, comment->text);
    if (!text) {
        return {};
    }
    claim(tags.comment, *text);
    return {};
}

[[nodiscard]] auto apply_unique_file_identifier(Arena& arena, std::span<const std::byte> data,
                                                ObservedTags& tags) -> expected<void> {
    std::size_t split = 0;
    while (split < data.size() && data[split] != std::byte{0}) {
        ++split;
    }
    if (split >= data.size()) {
        return {};
    }
    ORCA_ASSERT(split < data.size());
    const std::string_view owner(reinterpret_cast<const char*>(data.data()), split);
    if (owner != "http://musicbrainz.org") {
        return {};
    }
    const std::span<const std::byte> identifier = data.subspan(split + 1);
    if (identifier.empty() || identifier.size() > 128) {
        return {};
    }
    for (const std::byte byte : identifier) {
        const auto value = std::to_integer<std::uint8_t>(byte);
        if (value < 0x20U || value > 0x7eU) {
            return {};
        }
    }
    if (tags.musicbrainz_recording_id) {
        return {};
    }
    tags.musicbrainz_recording_id = arena.store_bytes(identifier);
    return {};
}

void assign_text_frame(Arena& arena, std::string_view identifier, std::string_view first,
                       ObservedTags& tags, std::optional<std::string_view>& pending_day_month) {
    if (identifier == "TIT2") {
        claim(tags.title, first);
        return;
    }
    if (identifier == "TPE1") {
        claim(tags.artist, first);
        return;
    }
    if (identifier == "TPE2") {
        claim(tags.album_artist, first);
        return;
    }
    if (identifier == "TALB") {
        claim(tags.album, first);
        return;
    }
    if (identifier == "TCOM") {
        claim(tags.composer, first);
        return;
    }
    if (identifier == "TPUB") {
        claim(tags.label, first);
        return;
    }
    if (identifier == "TMED") {
        claim(tags.media, first);
        return;
    }
    if (identifier == "TSRC") {
        claim(tags.isrc, first);
        return;
    }
    if (identifier == "TRCK") {
        claim_pair(first, tags.track_number, tags.track_total);
        return;
    }
    if (identifier == "TPOS") {
        claim_pair(first, tags.disc_number, tags.disc_total);
        return;
    }
    if (identifier == "TCMP") {
        if (!tags.compilation) {
            tags.compilation = is_truthy(first);
        }
        return;
    }
    if (identifier == "TDRC" || identifier == "TYER") {
        claim(tags.date, first);
        return;
    }
    if (identifier == "TDOR" || identifier == "TORY") {
        claim(tags.original_date, first);
        return;
    }
    if (identifier == "TDAT" && !pending_day_month && first.size() == 4) {
        pending_day_month = arena.store(first);
    }
}

[[nodiscard]] auto apply_frame(Arena& arena, const std::array<char, 4>& id,
                               std::span<const std::byte> data, ObservedTags& tags,
                               std::vector<std::string_view>& genres,
                               std::optional<std::string_view>& pending_day_month,
                               std::optional<std::string_view>& user_text_comment)
    -> expected<void> {
    const std::string_view identifier(id.data(), id.size());
    if (identifier == "APIC") {
        apply_picture(arena, data, tags);
        return {};
    }
    if (identifier == "UFID") {
        return apply_unique_file_identifier(arena, data, tags);
    }
    if (identifier == "TXXX") {
        return apply_user_text(arena, data, tags, user_text_comment);
    }
    if (identifier == "COMM") {
        return apply_comment(arena, data, tags);
    }
    if (id[0] != 'T') {
        return {};
    }

    const auto values = decode_text_values(arena, data);
    if (!values) {
        return std::unexpected(values.error());
    }
    if (values->empty()) {
        return {};
    }
    const std::string_view first = (*values)[0];

    if (identifier == "TCON") {
        for (const std::string_view value : *values) {
            const std::string_view name = canonical_genre(arena, value);
            if (!name.empty()) {
                genres.push_back(name);
            }
        }
        return {};
    }
    assign_text_frame(arena, identifier, first, tags, pending_day_month);
    return {};
}

[[nodiscard]] auto parse_frames(Arena& arena, std::span<std::byte> body, std::uint8_t major)
    -> expected<ObservedTags> {
    ORCA_ASSERT(major == 3 || major == 4);
    ObservedTags tags;
    std::vector<std::string_view> genres;
    std::optional<std::string_view> pending_day_month;
    std::optional<std::string_view> user_text_comment;

    FrameIterator frames(body, major);
    while (true) {
        const auto frame = frames.next();
        if (!frame) {
            return std::unexpected(frame.error());
        }
        if (!*frame) {
            break;
        }
        const auto applied = apply_frame(arena, (*frame)->identifier, (*frame)->data, tags, genres,
                                         pending_day_month, user_text_comment);
        if (!applied) {
            return std::unexpected(applied.error());
        }
    }

    if (pending_day_month) {
        const auto applied = apply_day_month(arena, tags, *pending_day_month);
        if (!applied) {
            return std::unexpected(applied.error());
        }
    }
    if (!tags.comment) {
        tags.comment = user_text_comment;
    }
    tags.genres = std::move(genres);
    return tags;
}

[[nodiscard]] auto decode_synchronised_lyrics(Arena& arena, std::span<const std::byte> data)
    -> std::optional<lyrics::Content> {
    if (data.size() < 6 || data.size() > lyrics::max_text_bytes) {
        return std::nullopt;
    }
    const auto encoding = std::to_integer<std::uint8_t>(data[0]);
    if (encoding > 3 || data[4] != std::byte{2} || data[5] != std::byte{1}) {
        return std::nullopt;
    }
    const std::size_t width = is_wide_encoding(encoding) ? 2 : 1;
    std::span<const std::byte> rest = data.subspan(6);
    const std::size_t header = terminator_length(encoding, rest);
    rest = rest.subspan(header);

    std::vector<lyrics::Line> lines;
    bool any_text = false;
    while (!rest.empty()) {
        const std::size_t consumed = terminator_length(encoding, rest);
        if (consumed < width || consumed + 4 > rest.size()) {
            return std::nullopt;
        }
        const auto decoded = decode_text(arena, encoding, rest.subspan(0, consumed - width));
        if (!decoded) {
            return std::nullopt;
        }
        std::string_view text = *decoded;
        if (text.starts_with("\n")) {
            text.remove_prefix(1);
        }
        if (!text.empty()) {
            any_text = true;
        }
        if (lines.size() == lyrics::max_lines) {
            return std::nullopt;
        }
        ORCA_ASSERT(lines.size() < lyrics::max_lines);
        lines.push_back(lyrics::Line{.start_ms = big32(rest.subspan(consumed, 4)), .text = text});
        rest = rest.subspan(consumed + 4);
    }
    if (!any_text) {
        return std::nullopt;
    }
    lyrics::Content content;
    content.kind = lyrics::Kind::synced;
    content.language = lyrics::language_code(
        {static_cast<char>(data[1]), static_cast<char>(data[2]), static_cast<char>(data[3])});
    content.lines = std::move(lines);
    lyrics::sort_lines(content);
    return content;
}

[[nodiscard]] auto decode_unsynchronised_lyrics(Arena& arena, std::span<const std::byte> data)
    -> std::optional<lyrics::Content> {
    if (data.size() < 4 || data.size() > 2 * lyrics::max_text_bytes) {
        return std::nullopt;
    }
    const auto encoding = std::to_integer<std::uint8_t>(data[0]);
    if (encoding > 3) {
        return std::nullopt;
    }
    std::span<const std::byte> rest = data.subspan(4);
    rest = rest.subspan(terminator_length(encoding, rest));
    const std::size_t width = is_wide_encoding(encoding) ? 2 : 1;
    while (rest.size() >= width) {
        bool all_zero = true;
        for (std::size_t index = rest.size() - width; index < rest.size(); ++index) {
            if (rest[index] != std::byte{0}) {
                all_zero = false;
                break;
            }
        }
        if (!all_zero) {
            break;
        }
        rest = rest.subspan(0, rest.size() - width);
    }
    const auto text = decode_text(arena, encoding, rest);
    if (!text) {
        return std::nullopt;
    }
    const auto content = lrc::parse(arena, *text);
    if (!content || !*content) {
        return std::nullopt;
    }
    lyrics::Content result = **content;
    result.language = lyrics::language_code(
        {static_cast<char>(data[1]), static_cast<char>(data[2]), static_cast<char>(data[3])});
    return result;
}

constexpr std::size_t write_padding = 1024;
constexpr std::string_view musicbrainz_ufid_owner = "http://musicbrainz.org";

constexpr std::array<std::string_view, 2> recording_id_descriptions = {"MusicBrainz Track Id",
                                                                       "MUSICBRAINZ_TRACKID"};
constexpr std::array<std::string_view, 2> release_id_descriptions = {"MusicBrainz Album Id",
                                                                     "MUSICBRAINZ_ALBUMID"};
constexpr std::array<std::string_view, 2> release_group_id_descriptions = {
    "MusicBrainz Release Group Id", "MUSICBRAINZ_RELEASEGROUPID"};
constexpr std::array<std::string_view, 2> release_track_id_descriptions = {
    "MusicBrainz Release Track Id", "MUSICBRAINZ_RELEASETRACKID"};
constexpr std::array<std::string_view, 2> album_artist_id_descriptions = {
    "MusicBrainz Album Artist Id", "MUSICBRAINZ_ALBUMARTISTID"};
constexpr std::array<std::string_view, 1> advisory_descriptions = {"ITUNESADVISORY"};
constexpr std::array<std::string_view, 1> comment_descriptions = {"comment"};

constexpr std::array<std::string_view, 1> frame_tit2 = {"TIT2"};
constexpr std::array<std::string_view, 1> frame_tpe1 = {"TPE1"};
constexpr std::array<std::string_view, 1> frame_talb = {"TALB"};
constexpr std::array<std::string_view, 1> frame_tpe2 = {"TPE2"};
constexpr std::array<std::string_view, 1> frame_trck = {"TRCK"};
constexpr std::array<std::string_view, 1> frame_tpos = {"TPOS"};
constexpr std::array<std::string_view, 1> frame_tcmp = {"TCMP"};
constexpr std::array<std::string_view, 1> frame_tcom = {"TCOM"};
constexpr std::array<std::string_view, 1> frame_tdrc = {"TDRC"};
constexpr std::array<std::string_view, 2> frame_date3 = {"TYER", "TDAT"};
constexpr std::array<std::string_view, 0> frame_none = {};

[[nodiscard]] auto field_frames(Field field, std::uint8_t major)
    -> std::span<const std::string_view> {
    switch (field) {
    case Field::title:
        return frame_tit2;
    case Field::artist:
        return frame_tpe1;
    case Field::album:
        return frame_talb;
    case Field::album_artist:
        return frame_tpe2;
    case Field::track_number:
        return frame_trck;
    case Field::disc_number:
        return frame_tpos;
    case Field::compilation:
        return frame_tcmp;
    case Field::composer:
        return frame_tcom;
    case Field::date:
        if (major >= 4) {
            return frame_tdrc;
        }
        return frame_date3;
    case Field::musicbrainz_recording_id:
    case Field::musicbrainz_release_id:
    case Field::musicbrainz_release_group_id:
    case Field::musicbrainz_release_track_id:
    case Field::musicbrainz_album_artist_id:
    case Field::explicit_advisory:
    case Field::comment:
        return frame_none;
    }
    return frame_none;
}

[[nodiscard]] auto user_text_descriptions(Field field) -> std::span<const std::string_view> {
    switch (field) {
    case Field::musicbrainz_recording_id:
        return recording_id_descriptions;
    case Field::musicbrainz_release_id:
        return release_id_descriptions;
    case Field::musicbrainz_release_group_id:
        return release_group_id_descriptions;
    case Field::musicbrainz_release_track_id:
        return release_track_id_descriptions;
    case Field::musicbrainz_album_artist_id:
        return album_artist_id_descriptions;
    case Field::explicit_advisory:
        return advisory_descriptions;
    case Field::title:
    case Field::artist:
    case Field::album:
    case Field::track_number:
    case Field::album_artist:
    case Field::disc_number:
    case Field::date:
    case Field::compilation:
    case Field::composer:
    case Field::comment:
        return frame_none;
    }
    return frame_none;
}

[[nodiscard]] auto current_value(const ObservedTags& tags, Field field)
    -> std::optional<std::string> {
    switch (field) {
    case Field::title:
        return tags.title ? std::optional<std::string>(*tags.title) : std::nullopt;
    case Field::artist:
        return tags.artist ? std::optional<std::string>(*tags.artist) : std::nullopt;
    case Field::album:
        return tags.album ? std::optional<std::string>(*tags.album) : std::nullopt;
    case Field::album_artist:
        return tags.album_artist ? std::optional<std::string>(*tags.album_artist) : std::nullopt;
    case Field::composer:
        return tags.composer ? std::optional<std::string>(*tags.composer) : std::nullopt;
    case Field::comment:
        return tags.comment ? std::optional<std::string>(*tags.comment) : std::nullopt;
    case Field::date:
        return tags.date ? std::optional<std::string>(*tags.date) : std::nullopt;
    case Field::track_number:
        if (tags.track_number) {
            return std::to_string(*tags.track_number);
        }
        return std::nullopt;
    case Field::disc_number:
        if (tags.disc_number) {
            return std::to_string(*tags.disc_number);
        }
        return std::nullopt;
    case Field::compilation:
        if (tags.compilation) {
            return *tags.compilation ? std::string("1") : std::string("0");
        }
        return std::nullopt;
    case Field::musicbrainz_recording_id:
        return tags.musicbrainz_recording_id
                   ? std::optional<std::string>(*tags.musicbrainz_recording_id)
                   : std::nullopt;
    case Field::musicbrainz_release_id:
        return tags.musicbrainz_release_id
                   ? std::optional<std::string>(*tags.musicbrainz_release_id)
                   : std::nullopt;
    case Field::musicbrainz_release_group_id:
        return tags.musicbrainz_release_group_id
                   ? std::optional<std::string>(*tags.musicbrainz_release_group_id)
                   : std::nullopt;
    case Field::musicbrainz_release_track_id:
        return tags.musicbrainz_release_track_id
                   ? std::optional<std::string>(*tags.musicbrainz_release_track_id)
                   : std::nullopt;
    case Field::musicbrainz_album_artist_id:
        return tags.musicbrainz_album_artist_id
                   ? std::optional<std::string>(*tags.musicbrainz_album_artist_id)
                   : std::nullopt;
    case Field::explicit_advisory:
        if (tags.explicit_flag) {
            const auto text = advisory_text(*tags.explicit_flag);
            if (text) {
                return std::string(*text);
            }
        }
        return std::nullopt;
    }
    return std::nullopt;
}

enum class Origin : std::uint8_t { id3v2, trailer, none };

struct CurrentTags {
    ObservedTags tags;
    Origin origin = Origin::none;
};

[[nodiscard]] inline auto as_bytes(std::string_view text) -> std::span<const std::byte> {
    return std::span<const std::byte>(reinterpret_cast<const std::byte*>(text.data()), text.size());
}

[[nodiscard]] auto parse_frames_checked(Arena& arena, const LoadedTag& loaded)
    -> expected<ObservedTags> {
    return parse_frames(arena, loaded.span, loaded.major);
}

[[nodiscard]] auto current_tags(Arena& arena, const std::optional<LoadedTag>& loaded,
                                const std::optional<id3v1::Tag>& trailer) -> expected<CurrentTags> {
    std::optional<std::string_view> comment;
    if (loaded) {
        const auto tags = parse_frames_checked(arena, *loaded);
        if (!tags) {
            return std::unexpected(tags.error());
        }
        if (tags->has_values_besides_artwork_and_comment()) {
            return CurrentTags{.tags = *tags, .origin = Origin::id3v2};
        }
        comment = tags->comment;
    }
    if (!trailer) {
        ObservedTags tags;
        tags.comment = comment;
        return CurrentTags{.tags = tags, .origin = Origin::none};
    }
    const id3v1::Tag& legacy = *trailer;
    ObservedTags tags;
    tags.comment = comment;
    if (!legacy.title.empty()) {
        tags.title = arena.store(id3v1::latin1_to_utf8(as_bytes(legacy.title)));
    }
    if (!legacy.artist.empty()) {
        tags.artist = arena.store(id3v1::latin1_to_utf8(as_bytes(legacy.artist)));
    }
    if (!legacy.album.empty()) {
        tags.album = arena.store(id3v1::latin1_to_utf8(as_bytes(legacy.album)));
    }
    if (!legacy.year.empty()) {
        tags.date = arena.store(id3v1::latin1_to_utf8(as_bytes(legacy.year)));
    }
    if (legacy.track_number && *legacy.track_number != 0) {
        tags.track_number = *legacy.track_number;
    }
    if (const auto name = id3v1::genre_name(legacy.genre)) {
        tags.genres.push_back(*name);
    }
    return CurrentTags{.tags = tags, .origin = Origin::trailer};
}

[[nodiscard]] auto frame_payload(std::span<const std::byte> frame, std::uint8_t major)
    -> std::optional<std::vector<std::byte>> {
    if (frame.size() < 10) {
        return std::nullopt;
    }
    const auto format_flags = std::to_integer<std::uint8_t>(frame[9]);
    std::span<const std::byte> data = frame.subspan(10);
    if (major >= 4) {
        if ((format_flags & 0x0cU) != 0U) {
            return std::nullopt;
        }
        if ((format_flags & 0x40U) != 0U) {
            if (data.size() < 1) {
                return std::nullopt;
            }
            data = data.subspan(1);
        }
        if ((format_flags & 0x01U) != 0U) {
            if (data.size() < 4) {
                return std::nullopt;
            }
            data = data.subspan(4);
        }
        if ((format_flags & 0x02U) != 0U) {
            std::vector<std::byte> copy(data.begin(), data.end());
            const auto shortened = unsynchronize(std::span<std::byte>(copy.data(), copy.size()));
            copy.resize(shortened.size());
            return copy;
        }
    } else {
        if ((format_flags & 0xc0U) != 0U) {
            return std::nullopt;
        }
        if ((format_flags & 0x20U) != 0U) {
            if (data.size() < 1) {
                return std::nullopt;
            }
            data = data.subspan(1);
        }
    }
    return std::vector<std::byte>(data.begin(), data.end());
}

[[nodiscard]] auto eql_any_span(std::string_view text, std::span<const std::string_view> spellings)
    -> bool {
    for (const std::string_view spelling : spellings) {
        if (text.size() != spelling.size()) {
            continue;
        }
        bool equal = true;
        for (std::size_t index = 0; index < text.size(); ++index) {
            const auto lower = [](char value) {
                return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
            };
            if (lower(text[index]) != lower(spelling[index])) {
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

[[nodiscard]] auto carries_undescribed_comment(std::span<const std::byte> frame, std::uint8_t major)
    -> bool {
    if (std::string_view(reinterpret_cast<const char*>(frame.data()), 4) != "COMM") {
        return false;
    }
    const auto payload = frame_payload(frame, major);
    if (!payload) {
        return false;
    }
    const auto comment = split_comment(std::span<const std::byte>(*payload));
    return comment && is_undescribed(*comment);
}

[[nodiscard]] auto carries_music_brainz_ufid(std::span<const std::byte> frame, std::uint8_t major)
    -> bool {
    if (std::string_view(reinterpret_cast<const char*>(frame.data()), 4) != "UFID") {
        return false;
    }
    const auto payload = frame_payload(frame, major);
    if (!payload) {
        return false;
    }
    std::size_t split = 0;
    while (split < payload->size() && (*payload)[split] != std::byte{0}) {
        ++split;
    }
    if (split >= payload->size()) {
        return false;
    }
    const std::string_view owner(reinterpret_cast<const char*>(payload->data()), split);
    return owner == musicbrainz_ufid_owner;
}

[[nodiscard]] auto carries_user_text(Arena& arena, std::span<const std::byte> frame,
                                     std::uint8_t major,
                                     std::span<const std::string_view> descriptions) -> bool {
    if (descriptions.empty()) {
        return false;
    }
    if (std::string_view(reinterpret_cast<const char*>(frame.data()), 4) != "TXXX") {
        return false;
    }
    const auto payload = frame_payload(frame, major);
    if (!payload) {
        return false;
    }
    const auto values = decode_text_values(arena, std::span<const std::byte>(*payload));
    if (!values || values->empty()) {
        return false;
    }
    return eql_any_span((*values)[0], descriptions);
}

[[nodiscard]] auto replaced(Arena& arena, std::span<const std::byte> frame, std::uint8_t major,
                            const std::vector<mutation::Change>& changes, bool replaces_genres)
    -> bool {
    const std::string_view identifier(reinterpret_cast<const char*>(frame.data()), 4);
    if (replaces_genres && identifier == "TCON") {
        return true;
    }
    for (const mutation::Change& change : changes) {
        for (const std::string_view candidate : field_frames(change.field, major)) {
            if (identifier == candidate) {
                return true;
            }
        }
        if (carries_user_text(arena, frame, major, user_text_descriptions(change.field))) {
            return true;
        }
        if (change.field == Field::musicbrainz_recording_id &&
            carries_music_brainz_ufid(frame, major)) {
            return true;
        }
        if (change.field == Field::comment && carries_undescribed_comment(frame, major)) {
            return true;
        }
        if (change.field == Field::comment &&
            carries_user_text(arena, frame, major, comment_descriptions)) {
            return true;
        }
    }
    return false;
}

[[nodiscard]] auto copy_unchanged_frames(Arena& arena, std::vector<std::byte>& body,
                                         const LoadedTag& tag,
                                         const std::vector<mutation::Change>& changes,
                                         bool replaces_genres) -> expected<void> {
    std::size_t position = 0;
    while (position + 10 <= tag.span.size()) {
        std::array<char, 4> identifier{};
        std::memcpy(identifier.data(), tag.span.data() + position, 4);
        if (identifier[0] == '\0' || !is_frame_identifier(identifier)) {
            break;
        }
        const auto size_bytes = std::span<const std::byte>(tag.span.data() + position + 4, 4);
        std::size_t declared = 0;
        if (tag.major >= 4) {
            const auto size = syncsafe(size_bytes);
            if (!size) {
                return std::unexpected(size.error());
            }
            declared = *size;
        } else {
            declared = big32(size_bytes);
        }
        if (declared > tag.span.size() - position - 10) {
            return fail(ErrorCode::truncated_id3v2_tag, "id3v2: frame past end");
        }
        const auto frame = tag.span.subspan(position, 10 + declared);
        position += frame.size();
        if (replaced(arena, frame, tag.major, changes, replaces_genres)) {
            continue;
        }
        body.insert(body.end(), frame.begin(), frame.end());
    }
    return {};
}

void append_bytes(std::vector<std::byte>& out, std::string_view text) {
    for (const char byte : text) {
        out.push_back(static_cast<std::byte>(byte));
    }
}

[[nodiscard]] auto write_syncsafe(std::uint32_t value) -> std::array<std::byte, 4> {
    return {static_cast<std::byte>((value >> 21U) & 0x7fU),
            static_cast<std::byte>((value >> 14U) & 0x7fU),
            static_cast<std::byte>((value >> 7U) & 0x7fU), static_cast<std::byte>(value & 0x7fU)};
}

void append_frame(std::vector<std::byte>& body, std::uint8_t major, std::string_view identifier,
                  std::span<const std::byte> payload) {
    append_bytes(body, identifier);
    if (major >= 4) {
        const auto size = write_syncsafe(static_cast<std::uint32_t>(payload.size()));
        body.insert(body.end(), size.begin(), size.end());
    } else {
        const std::uint32_t length = static_cast<std::uint32_t>(payload.size());
        for (std::size_t index = 0; index < 4; ++index) {
            body.push_back(static_cast<std::byte>((length >> ((3 - index) * 8U)) & 0xffU));
        }
    }
    body.push_back(std::byte{0});
    body.push_back(std::byte{0});
    body.insert(body.end(), payload.begin(), payload.end());
}

[[nodiscard]] auto append_utf16(std::vector<std::byte>& payload, std::string_view text) -> bool {
    payload.push_back(std::byte{0xff});
    payload.push_back(std::byte{0xfe});
    std::size_t index = 0;
    while (index < text.size()) {
        const auto first = static_cast<std::uint8_t>(text[index]);
        std::uint32_t point = first;
        std::size_t length = 1;
        if (first >= 0x80U) {
            if ((first & 0xe0U) == 0xc0U) {
                point = first & 0x1fU;
                length = 2;
            } else {
                if ((first & 0xf0U) == 0xe0U) {
                    point = first & 0x0fU;
                    length = 3;
                } else {
                    if ((first & 0xf8U) == 0xf0U) {
                        point = first & 0x07U;
                        length = 4;
                    } else {
                        return false;
                    }
                }
            }
        }
        if (index + length > text.size()) {
            return false;
        }
        for (std::size_t offset = 1; offset < length; ++offset) {
            const auto byte = static_cast<std::uint8_t>(text[index + offset]);
            if ((byte & 0xc0U) != 0x80U) {
                return false;
            }
            point = (point << 6U) | (byte & 0x3fU);
        }
        std::array<std::uint16_t, 2> units{};
        std::size_t count = 1;
        if (point < 0x10000U) {
            units[0] = static_cast<std::uint16_t>(point);
        } else {
            const std::uint32_t offset = point - 0x10000U;
            units[0] = static_cast<std::uint16_t>(0xd800U + (offset >> 10U));
            units[1] = static_cast<std::uint16_t>(0xdc00U + (offset & 0x3ffU));
            count = 2;
        }
        for (std::size_t unit = 0; unit < count; ++unit) {
            payload.push_back(static_cast<std::byte>(units[unit] & 0xffU));
            payload.push_back(static_cast<std::byte>((units[unit] >> 8U) & 0xffU));
        }
        index += length;
    }
    return true;
}

[[nodiscard]] auto append_text_frame(std::vector<std::byte>& body, std::uint8_t major,
                                     std::string_view identifier, std::string_view value)
    -> expected<void> {
    std::vector<std::byte> payload;
    if (major >= 4) {
        payload.push_back(std::byte{3});
        append_bytes(payload, value);
    } else {
        payload.push_back(std::byte{1});
        if (!append_utf16(payload, value)) {
            return fail(ErrorCode::invalid_tag_value, "id3v2: invalid UTF-8");
        }
    }
    append_frame(body, major, identifier, payload);
    return {};
}

[[nodiscard]] auto append_user_text(std::vector<std::byte>& body, std::uint8_t major,
                                    std::string_view description, std::string_view value)
    -> expected<void> {
    std::vector<std::byte> payload;
    if (major >= 4) {
        payload.push_back(std::byte{3});
        append_bytes(payload, description);
        payload.push_back(std::byte{0});
        append_bytes(payload, value);
    } else {
        payload.push_back(std::byte{1});
        if (!append_utf16(payload, description)) {
            return fail(ErrorCode::invalid_tag_value, "id3v2: invalid UTF-8");
        }
        payload.push_back(std::byte{0});
        payload.push_back(std::byte{0});
        if (!append_utf16(payload, value)) {
            return fail(ErrorCode::invalid_tag_value, "id3v2: invalid UTF-8");
        }
    }
    append_frame(body, major, "TXXX", payload);
    return {};
}

[[nodiscard]] auto append_comment(std::vector<std::byte>& body, std::uint8_t major,
                                  std::string_view value) -> expected<void> {
    std::vector<std::byte> payload;
    if (major >= 4) {
        payload.push_back(std::byte{3});
        append_bytes(payload, "eng");
        payload.push_back(std::byte{0});
        append_bytes(payload, value);
    } else {
        payload.push_back(std::byte{1});
        append_bytes(payload, "eng");
        if (!append_utf16(payload, "")) {
            return fail(ErrorCode::invalid_tag_value, "id3v2: invalid UTF-8");
        }
        payload.push_back(std::byte{0});
        payload.push_back(std::byte{0});
        if (!append_utf16(payload, value)) {
            return fail(ErrorCode::invalid_tag_value, "id3v2: invalid UTF-8");
        }
    }
    append_frame(body, major, "COMM", payload);
    return {};
}

[[nodiscard]] auto append_unique_file_identifier(std::vector<std::byte>& body, std::uint8_t major,
                                                 std::string_view owner,
                                                 std::string_view identifier) -> expected<void> {
    if (identifier.empty() || identifier.size() > 64) {
        return fail(ErrorCode::invalid_tag_value, "id3v2: invalid UFID length");
    }
    std::vector<std::byte> payload;
    append_bytes(payload, owner);
    payload.push_back(std::byte{0});
    append_bytes(payload, identifier);
    append_frame(body, major, "UFID", payload);
    return {};
}

[[nodiscard]] auto pair_value(std::string_view value, std::optional<std::uint32_t> total)
    -> std::string {
    if (!total) {
        return std::string(value);
    }
    std::string out(value);
    out += "/";
    out += std::to_string(*total);
    return out;
}

[[nodiscard]] auto append_changed_frames(std::vector<std::byte>& body, std::uint8_t major,
                                         Field field, std::string_view value,
                                         const ObservedTags& current) -> expected<void> {
    switch (field) {
    case Field::track_number:
        return append_text_frame(body, major, "TRCK", pair_value(value, current.track_total));
    case Field::disc_number:
        return append_text_frame(body, major, "TPOS", pair_value(value, current.disc_total));
    case Field::date:
        if (major >= 4) {
            return append_text_frame(body, major, "TDRC", value);
        }
        if (value.size() < 4 || !is_all_digits(value.substr(0, 4))) {
            return fail(ErrorCode::invalid_tag_value, "id3v2: invalid date");
        }
        if (const auto written = append_text_frame(body, major, "TYER", value.substr(0, 4));
            !written) {
            return written;
        }
        if (value.size() >= 10 && value[4] == '-' && value[7] == '-') {
            const std::array<char, 4> day_month{value[8], value[9], value[5], value[6]};
            if (is_all_digits(std::string_view(day_month.data(), day_month.size()))) {
                return append_text_frame(body, major, "TDAT",
                                         std::string_view(day_month.data(), day_month.size()));
            }
        }
        return {};
    case Field::title:
    case Field::artist:
    case Field::album:
    case Field::album_artist:
    case Field::compilation:
    case Field::composer:
        return append_text_frame(body, major, field_frames(field, major)[0], value);
    case Field::comment:
        return append_comment(body, major, value);
    case Field::musicbrainz_recording_id:
        return append_unique_file_identifier(body, major, musicbrainz_ufid_owner, value);
    case Field::musicbrainz_release_id:
    case Field::musicbrainz_release_group_id:
    case Field::musicbrainz_release_track_id:
    case Field::musicbrainz_album_artist_id:
    case Field::explicit_advisory:
        return append_user_text(body, major, user_text_descriptions(field)[0], value);
    }
    return {};
}

[[nodiscard]] auto changes_field(const std::vector<mutation::Change>& changes, Field field)
    -> bool {
    for (const mutation::Change& change : changes) {
        if (change.field == field) {
            return true;
        }
    }
    return false;
}

[[nodiscard]] auto append_trailer_frames(std::vector<std::byte>& body, std::uint8_t major,
                                         const ObservedTags& tags,
                                         const std::vector<mutation::Change>& changes,
                                         bool replaces_genres) -> expected<void> {
    for (const Field field :
         {Field::title, Field::artist, Field::album, Field::date, Field::track_number}) {
        if (changes_field(changes, field)) {
            continue;
        }
        const auto value = current_value(tags, field);
        if (!value) {
            continue;
        }
        if (field == Field::date && major < 4) {
            if (const auto written = append_text_frame(body, major, "TYER", *value); !written) {
                return written;
            }
        } else {
            if (const auto written = append_changed_frames(body, major, field, *value, tags);
                !written) {
                return written;
            }
        }
    }
    if (replaces_genres) {
        return {};
    }
    for (const std::string_view genre : tags.genres) {
        if (const auto written = append_text_frame(body, major, "TCON", genre); !written) {
            return written;
        }
    }
    return {};
}

[[nodiscard]] auto validate_rewrite_changes(const ObservedTags& current,
                                            const std::vector<mutation::Change>& changes,
                                            const std::optional<mutation::GenreChange>& genres)
    -> expected<void> {
    for (const mutation::Change& change : changes) {
        if (change.before) {
            const auto value = current_value(current, change.field);
            if (!value) {
                return fail(ErrorCode::metadata_precondition_changed, "id3v2: precondition");
            }
            if (*value != *change.before) {
                return fail(ErrorCode::metadata_precondition_changed, "id3v2: precondition");
            }
        }
        if (change.after) {
            if (change.after->empty() || !utf8_valid(*change.after)) {
                return fail(ErrorCode::invalid_tag_value, "id3v2: invalid value");
            }
        }
    }
    if (genres) {
        if (genres->before.size() != current.genres.size()) {
            return fail(ErrorCode::metadata_precondition_changed, "id3v2: genre precondition");
        }
        for (std::size_t index = 0; index < genres->before.size(); ++index) {
            if (std::string_view(genres->before[index]) != current.genres[index]) {
                return fail(ErrorCode::metadata_precondition_changed, "id3v2: genre precondition");
            }
        }
        if (genres->after.empty()) {
            return fail(ErrorCode::invalid_tag_value, "id3v2: empty genre list");
        }
        for (const std::string& value : genres->after) {
            if (value.empty() || value.find('\0') != std::string::npos || !utf8_valid(value)) {
                return fail(ErrorCode::invalid_tag_value, "id3v2: invalid genre");
            }
        }
    }
    return {};
}

[[nodiscard]] auto build_rewrite_body(Arena& arena, const std::optional<LoadedTag>& loaded,
                                      const CurrentTags& current, std::uint8_t major,
                                      const std::vector<mutation::Change>& changes,
                                      const std::optional<mutation::GenreChange>& genres)
    -> expected<std::vector<std::byte>> {
    std::vector<std::byte> body;
    if (loaded) {
        const auto copied =
            copy_unchanged_frames(arena, body, *loaded, changes, genres.has_value());
        if (!copied) {
            return std::unexpected(copied.error());
        }
    }
    if (current.origin == Origin::trailer) {
        const auto appended =
            append_trailer_frames(body, major, current.tags, changes, genres.has_value());
        if (!appended) {
            return std::unexpected(appended.error());
        }
    }
    for (const mutation::Change& change : changes) {
        if (!change.after) {
            continue;
        }
        const auto appended =
            append_changed_frames(body, major, change.field, *change.after, current.tags);
        if (!appended) {
            return std::unexpected(appended.error());
        }
    }
    if (genres) {
        const std::string separator = major >= 4 ? std::string(1, '\0') : std::string("; ");
        std::string joined;
        for (std::size_t index = 0; index < genres->after.size(); ++index) {
            if (index != 0) {
                joined += separator;
            }
            joined += genres->after[index];
        }
        if (const auto written = append_text_frame(body, major, "TCON", joined); !written) {
            return std::unexpected(written.error());
        }
    }
    body.resize(body.size() + write_padding, std::byte{0});
    if (body.size() >= (1U << 28)) {
        return fail(ErrorCode::id3v2_tag_too_large, "id3v2: tag too large");
    }
    return body;
}

[[nodiscard]] auto updated_trailer(const id3v1::Tag& legacy,
                                   const std::array<std::byte, 128>& original,
                                   const std::vector<mutation::Change>& changes)
    -> std::array<std::byte, 128> {
    std::string title(legacy.title);
    std::string artist(legacy.artist);
    std::string album(legacy.album);
    std::string year(legacy.year);
    std::optional<std::uint8_t> track = legacy.track_number;
    for (const mutation::Change& change : changes) {
        const std::string_view value =
            change.after ? std::string_view(*change.after) : std::string_view{};
        switch (change.field) {
        case Field::title:
            title = std::string(value);
            break;
        case Field::artist:
            artist = std::string(value);
            break;
        case Field::album:
            album = std::string(value);
            break;
        case Field::date:
            year = std::string(value.size() >= 4 ? value.substr(0, 4) : value);
            break;
        case Field::track_number:
            if (change.after) {
                const auto parsed = parse_u32(*change.after);
                if (!parsed || *parsed > 255) {
                    return original;
                }
                track = static_cast<std::uint8_t>(*parsed);
            } else {
                track = std::nullopt;
            }
            break;
        case Field::album_artist:
        case Field::disc_number:
        case Field::compilation:
        case Field::musicbrainz_recording_id:
        case Field::musicbrainz_release_id:
        case Field::musicbrainz_release_group_id:
        case Field::musicbrainz_release_track_id:
        case Field::musicbrainz_album_artist_id:
        case Field::explicit_advisory:
        case Field::composer:
        case Field::comment:
            break;
        }
    }
    id3v1::Tag tag;
    tag.title = title;
    tag.artist = artist;
    tag.album = album;
    tag.year = year;
    tag.comment = legacy.comment;
    tag.track_number = track;
    tag.genre = legacy.genre;
    const auto encoded = id3v1::encode(tag);
    if (!encoded) {
        return original;
    }
    return *encoded;
}

} // namespace

auto prefix_length(const storage::ReadableSource& source) -> expected<std::uint64_t> {
    std::array<std::byte, 10> header{};
    const auto header_read = read_exact(source, 0, header);
    if (!header_read) {
        return std::unexpected(header_read.error());
    }
    if (*header_read != header.size()) {
        return std::uint64_t{0};
    }
    if (std::memcmp(header.data(), "ID3", 3) != 0) {
        return std::uint64_t{0};
    }
    if (header[3] == std::byte{0xff} || header[4] == std::byte{0xff}) {
        return fail(ErrorCode::invalid_id3v2_tag, "id3v2: invalid version bytes");
    }
    const auto size = syncsafe(std::span<const std::byte>(header.data() + 6, 4));
    if (!size) {
        return std::unexpected(size.error());
    }
    const std::uint64_t footer =
        (std::to_integer<std::uint8_t>(header[5]) & 0x10U) != 0U ? 10U : 0U;
    return static_cast<std::uint64_t>(header.size()) + *size + footer;
}

auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>> {
    auto tag = load_tag(source);
    if (!tag) {
        return std::unexpected(tag.error());
    }
    if (!*tag) {
        return std::optional<ObservedTags>{};
    }
    auto tags = parse_frames(arena, (*tag)->span, (*tag)->major);
    if (!tags) {
        return std::unexpected(tags.error());
    }
    return std::optional<ObservedTags>(std::move(*tags));
}

auto read_picture(const storage::ReadableSource& source) -> expected<std::optional<EmbeddedImage>> {
    auto tag = load_tag(source);
    if (!tag) {
        return std::unexpected(tag.error());
    }
    if (!*tag) {
        return std::optional<EmbeddedImage>{};
    }

    FrameIterator frames((*tag)->span, (*tag)->major);
    std::optional<Picture> chosen;
    while (true) {
        const auto frame = frames.next();
        if (!frame) {
            return std::unexpected(frame.error());
        }
        if (!*frame) {
            break;
        }
        if (std::string_view((*frame)->identifier.data(), 4) != "APIC") {
            continue;
        }
        const auto picture = decode_picture((*frame)->data);
        if (!picture) {
            continue;
        }
        if (chosen) {
            if (chosen->kind == ArtworkKind::front_cover ||
                picture->kind != ArtworkKind::front_cover) {
                continue;
            }
        }
        chosen = picture;
        if (picture->kind == ArtworkKind::front_cover) {
            break;
        }
    }
    if (!chosen) {
        return std::optional<EmbeddedImage>{};
    }
    if (chosen->data.size() > max_image_bytes) {
        return fail(ErrorCode::out_of_range, "id3v2: artwork too large");
    }
    ORCA_ASSERT(chosen->data.size() <= max_image_bytes);
    std::vector<std::byte> bytes(chosen->data.begin(), chosen->data.end());
    auto image = adopt_image(std::move(bytes), chosen->kind);
    if (!image) {
        return std::unexpected(image.error());
    }
    return std::optional<EmbeddedImage>(std::move(*image));
}

auto read_lyrics(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<lyrics::Content>> {
    auto tag = load_tag(source);
    if (!tag) {
        return std::unexpected(tag.error());
    }
    if (!*tag) {
        return std::optional<lyrics::Content>{};
    }

    FrameIterator frames((*tag)->span, (*tag)->major);
    std::optional<lyrics::Content> unsynchronised;
    while (true) {
        const auto frame = frames.next();
        if (!frame || !*frame) {
            break;
        }
        const std::string_view identifier((*frame)->identifier.data(), 4);
        if (identifier == "SYLT") {
            auto content = decode_synchronised_lyrics(arena, (*frame)->data);
            if (content) {
                return content;
            }
        } else {
            if (!unsynchronised && identifier == "USLT") {
                unsynchronised = decode_unsynchronised_lyrics(arena, (*frame)->data);
            }
        }
    }
    return unsynchronised;
}

auto rewrite(const storage::ReadableSource& source, const std::vector<mutation::Change>& changes,
             const std::optional<mutation::GenreChange>& genres) -> expected<Rewrite> {
    Arena arena;
    auto loaded = load_tag(source);
    if (!loaded) {
        return std::unexpected(loaded.error());
    }
    std::array<std::byte, 10> header{};
    const auto header_read = read_exact(source, 0, header);
    if (!header_read) {
        return std::unexpected(header_read.error());
    }
    const bool has_header =
        *header_read == header.size() && std::memcmp(header.data(), "ID3", 3) == 0;
    if (has_header && !*loaded) {
        return fail(ErrorCode::unsupported_id3_layout, "id3v2: unsupported layout");
    }
    if (*loaded) {
        const auto flags = std::to_integer<std::uint8_t>(header[5]);
        if ((*loaded)->major == 4 && (flags & 0x80U) != 0U) {
            return fail(ErrorCode::unsupported_id3_layout, "id3v2: tag-level unsynchronization");
        }
    }
    const std::uint8_t major = *loaded ? (*loaded)->major : 4;
    const std::uint64_t size = source.size();
    std::array<std::byte, 128> trailer_bytes{};
    std::optional<id3v1::Tag> trailer;
    if (size >= trailer_bytes.size()) {
        const auto trailer_read = read_exact(source, size - trailer_bytes.size(), trailer_bytes);
        if (!trailer_read) {
            return std::unexpected(trailer_read.error());
        }
        if (*trailer_read == trailer_bytes.size()) {
            trailer = id3v1::parse(trailer_bytes);
        }
    }
    const auto current = current_tags(arena, *loaded, trailer);
    if (!current) {
        return std::unexpected(current.error());
    }
    const auto valid = validate_rewrite_changes(current->tags, changes, genres);
    if (!valid) {
        return std::unexpected(valid.error());
    }
    auto body = build_rewrite_body(arena, *loaded, *current, major, changes, genres);
    if (!body) {
        return std::unexpected(body.error());
    }

    Rewrite result;
    result.tag.reserve(10 + body->size());
    append_bytes(result.tag, "ID3");
    result.tag.push_back(static_cast<std::byte>(major));
    result.tag.push_back(std::byte{0});
    result.tag.push_back(std::byte{0});
    const auto size_field = write_syncsafe(static_cast<std::uint32_t>(body->size()));
    result.tag.insert(result.tag.end(), size_field.begin(), size_field.end());
    result.tag.insert(result.tag.end(), body->begin(), body->end());

    const auto start = prefix_length(source);
    if (!start) {
        return std::unexpected(start.error());
    }
    result.audio_start = *start;
    result.audio_end = trailer ? size - trailer_bytes.size() : size;
    if (trailer) {
        result.trailer = updated_trailer(*trailer, trailer_bytes, changes);
    }
    return result;
}

}
