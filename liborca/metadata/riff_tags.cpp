#include "liborca/metadata/riff_tags.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/metadata/id3v1.hpp"
#include "liborca/metadata/id3v2.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string_view>
#include <utility>
#include <vector>

namespace orca::metadata::riff_tags {

namespace {

constexpr std::size_t max_chunks = 1024;
constexpr std::uint32_t max_info_bytes = 64U * 1024U;

struct Container {
    bool little_endian = true;
    std::uint64_t first_chunk = 12;
};

struct InfoChunk {
    std::uint64_t offset = 0;
    std::uint32_t size = 0;
};

struct Chunks {
    std::optional<std::uint64_t> id3;
    std::optional<InfoChunk> info;
};

[[nodiscard]] auto read_u32(std::span<const std::byte> bytes, bool little) -> std::uint32_t {
    std::uint32_t value = 0;
    if (little) {
        for (std::size_t index = 0; index < 4; ++index) {
            value |= static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(bytes[index]))
                     << (index * 8U);
        }
    } else {
        for (std::size_t index = 0; index < 4; ++index) {
            value = (value << 8U) | std::to_integer<std::uint8_t>(bytes[index]);
        }
    }
    return value;
}

[[nodiscard]] auto ascii_iequals(std::span<const std::byte> bytes, std::string_view expected)
    -> bool {
    if (bytes.size() != expected.size()) {
        return false;
    }
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        const auto lower = [](char value) {
            return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
        };
        if (lower(static_cast<char>(std::to_integer<std::uint8_t>(bytes[index]))) !=
            lower(expected[index])) {
            return false;
        }
    }
    return true;
}

[[nodiscard]] auto container(const storage::ReadableSource& source)
    -> expected<std::optional<Container>> {
    std::array<std::byte, 12> header{};
    ORCA_ASSERT(header.size() == 12);
    const auto read = source.read_at(0, header);
    if (!read) {
        return std::unexpected(read.error());
    }
    if (*read != header.size()) {
        return std::optional<Container>{};
    }
    if (std::memcmp(header.data(), "RIFF", 4) == 0 &&
        std::memcmp(header.data() + 8, "WAVE", 4) == 0) {
        return std::optional<Container>(Container{.little_endian = true});
    }
    if (std::memcmp(header.data(), "FORM", 4) == 0 &&
        (std::memcmp(header.data() + 8, "AIFF", 4) == 0 ||
         std::memcmp(header.data() + 8, "AIFC", 4) == 0)) {
        return std::optional<Container>(Container{.little_endian = false});
    }
    return std::optional<Container>{};
}

[[nodiscard]] auto find_chunks(const storage::ReadableSource& source)
    -> expected<std::optional<Chunks>> {
    const auto layout = container(source);
    if (!layout) {
        return std::unexpected(layout.error());
    }
    if (!*layout) {
        return std::optional<Chunks>{};
    }
    Chunks chunks;
    std::uint64_t offset = (*layout)->first_chunk;
    const std::uint64_t size = source.size();
    for (std::size_t index = 0; index < max_chunks; ++index) {
        ORCA_ASSERT(offset <= size);
        if (offset + 8 > size) {
            break;
        }
        std::array<std::byte, 8> header{};
        const auto read = source.read_at(offset, header);
        if (!read) {
            return std::unexpected(read.error());
        }
        if (*read != header.size()) {
            break;
        }
        const std::uint32_t length =
            read_u32(std::span<const std::byte>(header.data() + 4, 4), (*layout)->little_endian);
        const std::uint64_t body = offset + 8;
        if (body + length > size) {
            break;
        }
        if (ascii_iequals(std::span<const std::byte>(header.data(), 4), "id3 ")) {
            if (!chunks.id3) {
                chunks.id3 = body;
            }
        } else {
            if (std::memcmp(header.data(), "LIST", 4) == 0 && length >= 4) {
                std::array<std::byte, 4> kind{};
                const auto kind_read = source.read_at(body, kind);
                if (!kind_read) {
                    return std::unexpected(kind_read.error());
                }
                if (*kind_read == kind.size() && std::memcmp(kind.data(), "INFO", 4) == 0) {
                    chunks.info = InfoChunk{.offset = body + 4, .size = length - 4};
                }
            }
        }
        offset = body + length + (length & 1U);
    }
    return std::optional<Chunks>(chunks);
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

[[nodiscard]] auto parse_track_number(std::string_view value) -> std::optional<std::uint32_t> {
    if (value.empty()) {
        return std::nullopt;
    }
    std::uint32_t number = 0;
    for (const char byte : value) {
        if (byte < '0' || byte > '9') {
            return std::nullopt;
        }
        const std::uint64_t next =
            (static_cast<std::uint64_t>(number) * 10U) + static_cast<std::uint32_t>(byte - '0');
        if (next > 0xffffffffULL) {
            return std::nullopt;
        }
        number = static_cast<std::uint32_t>(next);
    }
    return number;
}

void assign_info_field(std::span<const std::byte> id, std::string_view value, ObservedTags& tags,
                       std::vector<std::string_view>& genres) {
    if (std::memcmp(id.data(), "INAM", 4) == 0) {
        if (!tags.title) {
            tags.title = value;
        }
    } else {
        if (std::memcmp(id.data(), "IART", 4) == 0) {
            if (!tags.artist) {
                tags.artist = value;
            }
        } else {
            if (std::memcmp(id.data(), "IPRD", 4) == 0) {
                if (!tags.album) {
                    tags.album = value;
                }
            } else {
                if (std::memcmp(id.data(), "ICRD", 4) == 0) {
                    if (!tags.date) {
                        tags.date = value;
                    }
                } else {
                    if (std::memcmp(id.data(), "IGNR", 4) == 0) {
                        genres.push_back(value);
                    } else {
                        if (std::memcmp(id.data(), "ITRK", 4) == 0 ||
                            std::memcmp(id.data(), "IPRT", 4) == 0) {
                            if (!tags.track_number) {
                                tags.track_number = parse_track_number(value);
                            }
                        }
                    }
                }
            }
        }
    }
}

[[nodiscard]] auto read_info(Arena& arena, const storage::ReadableSource& source,
                             std::uint64_t offset, std::uint32_t size)
    -> expected<std::optional<ObservedTags>> {
    if (size > max_info_bytes) {
        return std::optional<ObservedTags>{};
    }
    std::vector<std::byte> bytes(size);
    const auto read = source.read_at(offset, bytes);
    if (!read) {
        return std::unexpected(read.error());
    }
    if (*read != bytes.size()) {
        return std::optional<ObservedTags>{};
    }

    ObservedTags tags;
    std::vector<std::string_view> genres;
    std::size_t cursor = 0;
    while (cursor + 8 <= bytes.size()) {
        ORCA_ASSERT(cursor <= bytes.size());
        const auto id = std::span<const std::byte>(bytes.data() + cursor, 4);
        const std::uint32_t length =
            read_u32(std::span<const std::byte>(bytes.data() + cursor + 4, 4), true);
        const std::size_t start = cursor + 8;
        if (length > bytes.size() - start) {
            break;
        }
        ORCA_ASSERT(start <= bytes.size());
        cursor = start + length + (length & 1U);
        std::string_view raw(reinterpret_cast<const char*>(bytes.data() + start), length);
        while (!raw.empty() && (raw.front() == ' ' || raw.front() == '\0')) {
            raw.remove_prefix(1);
        }
        while (!raw.empty() && (raw.back() == ' ' || raw.back() == '\0')) {
            raw.remove_suffix(1);
        }
        if (raw.empty()) {
            continue;
        }
        const auto raw_bytes =
            std::span<const std::byte>(reinterpret_cast<const std::byte*>(raw.data()), raw.size());
        const std::string_view value =
            utf8_valid(raw) ? arena.store(raw) : arena.store(id3v1::latin1_to_utf8(raw_bytes));

        assign_info_field(id, value, tags, genres);
    }
    tags.genres = std::move(genres);
    if (tags.is_empty()) {
        return std::optional<ObservedTags>{};
    }
    return std::optional<ObservedTags>(std::move(tags));
}

}

auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>> {
    const auto chunks = find_chunks(source);
    if (!chunks) {
        return std::unexpected(chunks.error());
    }
    if (!*chunks) {
        return std::optional<ObservedTags>{};
    }
    ObservedTags partial;
    if ((*chunks)->id3) {
        const storage::OffsetSource view(source, *(*chunks)->id3);
        const auto tags = id3v2::read(arena, view);
        if (!tags) {
            return std::unexpected(tags.error());
        }
        if (*tags) {
            if ((*tags)->has_values_besides_artwork_and_comment()) {
                return tags;
            }
            partial = **tags;
        }
    }
    ObservedTags tags;
    if ((*chunks)->info) {
        const auto info = read_info(arena, source, (*chunks)->info->offset, (*chunks)->info->size);
        if (!info) {
            return std::unexpected(info.error());
        }
        if (*info) {
            tags = std::move(**info);
        }
    }
    tags.artwork = partial.artwork;
    tags.comment = partial.comment;
    if (tags.is_empty()) {
        return std::optional<ObservedTags>{};
    }
    return std::optional<ObservedTags>(std::move(tags));
}

auto read_picture(const storage::ReadableSource& source) -> expected<std::optional<EmbeddedImage>> {
    const auto chunks = find_chunks(source);
    if (!chunks) {
        return std::unexpected(chunks.error());
    }
    if (!*chunks || !(*chunks)->id3) {
        return std::optional<EmbeddedImage>{};
    }
    const storage::OffsetSource view(source, *(*chunks)->id3);
    return id3v2::read_picture(view);
}

}
