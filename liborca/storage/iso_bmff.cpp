#include "liborca/storage/iso_bmff.hpp"

#include "liborca/base/logging.hpp"

#include <cstring>
#include <limits>

namespace orca::storage::iso_bmff {

namespace {

[[nodiscard]] auto is_invalid() -> unexpected {
    return fail(ErrorCode::parse, "iso_bmff: invalid box framing");
}

}

auto Box::is(std::string_view name) const -> bool {
    return name.size() == kind.size() && std::memcmp(kind.data(), name.data(), kind.size()) == 0;
}

auto Iterator::next() -> expected<std::optional<Box>> {
    ORCA_ASSERT(cursor_ <= bytes_.size());
    const std::size_t remaining = bytes_.size() - cursor_;
    if (remaining == 0) {
        return std::optional<Box>{};
    }
    if (remaining < 8) {
        return is_invalid();
    }

    const auto header = bytes_.subspan(cursor_);
    const auto size32 = integer<std::uint32_t>(header, 0);
    if (!size32) {
        return std::unexpected(size32.error());
    }
    std::uint64_t size = *size32;
    std::size_t header_bytes = 8;
    if (size == 1) {
        if (remaining < 16) {
            return is_invalid();
        }
        const auto size64 = integer<std::uint64_t>(header, 8);
        if (!size64) {
            return std::unexpected(size64.error());
        }
        size = *size64;
        header_bytes = 16;
    } else {
        if (size == 0) {
            size = remaining;
        }
    }
    if (size < header_bytes || size > remaining) {
        return is_invalid();
    }

    const auto length = static_cast<std::size_t>(size);
    Box box;
    std::memcpy(box.kind.data(), header.data() + 4, box.kind.size());
    box.body = header.subspan(header_bytes, length - header_bytes);
    cursor_ += length;
    return std::optional<Box>(box);
}

auto Iterator::find(std::span<const std::byte> bytes, std::string_view kind)
    -> expected<std::optional<Box>> {
    Iterator boxes(bytes);
    while (true) {
        const auto box = boxes.next();
        if (!box) {
            return std::unexpected(box.error());
        }
        if (!*box) {
            return std::optional<Box>{};
        }
        if ((*box)->is(kind)) {
            return box;
        }
    }
}

auto descend(std::span<const std::byte> bytes, std::span<const std::string_view> path)
    -> expected<std::optional<Box>> {
    std::span<const std::byte> current = bytes;
    std::optional<Box> found;
    for (const std::string_view kind : path) {
        const auto box = Iterator::find(current, kind);
        if (!box) {
            return std::unexpected(box.error());
        }
        if (!*box) {
            return std::optional<Box>{};
        }
        found = **box;
        current = found->body;
    }
    return found;
}

struct TopLevelHeader {
    std::uint64_t size = 0;
    std::uint64_t header_bytes = 0;
    bool is_movie = false;
};

[[nodiscard]] auto read_top_level_header(const ReadableSource& source, std::uint64_t offset,
                                         std::uint64_t file_size) -> expected<TopLevelHeader> {
    if (offset > std::numeric_limits<std::uint64_t>::max() - 8) {
        return is_invalid();
    }
    if (offset + 8 > file_size) {
        return fail(ErrorCode::not_found, "iso_bmff: movie box missing");
    }

    std::array<std::byte, 16> header{};
    const auto got = source.read_at(offset, header);
    if (!got) {
        return std::unexpected(got.error());
    }
    if (*got < 8) {
        return fail(ErrorCode::parse, "iso_bmff: truncated file");
    }

    const auto size32 = integer<std::uint32_t>(std::span<const std::byte>(header), 0);
    if (!size32) {
        return std::unexpected(size32.error());
    }
    std::uint64_t size = *size32;
    std::uint64_t header_bytes = 8;
    if (size == 1) {
        if (*got < 16) {
            return fail(ErrorCode::parse, "iso_bmff: truncated file");
        }
        const auto size64 = integer<std::uint64_t>(std::span<const std::byte>(header), 8);
        if (!size64) {
            return std::unexpected(size64.error());
        }
        size = *size64;
        header_bytes = 16;
    } else {
        if (size == 0) {
            size = file_size - offset;
        }
    }
    if (size < header_bytes) {
        return is_invalid();
    }

    return TopLevelHeader{.size = size,
                          .header_bytes = header_bytes,
                          .is_movie = std::memcmp(header.data() + 4, "moov", 4) == 0};
}

auto read_movie(const ReadableSource& source) -> expected<std::vector<std::byte>> {
    const std::uint64_t file_size = source.size();
    std::uint64_t offset = 0;
    for (std::size_t visited = 0; visited < max_top_level_boxes; ++visited) {
        const auto header = read_top_level_header(source, offset, file_size);
        if (!header) {
            return std::unexpected(header.error());
        }
        if (header->is_movie) {
            const std::uint64_t body_size = header->size - header->header_bytes;
            if (body_size > max_movie_bytes) {
                return fail(ErrorCode::out_of_range, "iso_bmff: movie box too large");
            }
            if (offset > std::numeric_limits<std::uint64_t>::max() - header->size) {
                return is_invalid();
            }
            if (offset + header->size > file_size) {
                return fail(ErrorCode::parse, "iso_bmff: truncated movie box");
            }
            std::vector<std::byte> body(static_cast<std::size_t>(body_size));
            const auto filled = read_all(source, offset + header->header_bytes, body);
            if (!filled || *filled != body.size()) {
                return fail(ErrorCode::parse, "iso_bmff: truncated movie box");
            }
            return body;
        }
        if (offset > std::numeric_limits<std::uint64_t>::max() - header->size) {
            return is_invalid();
        }
        offset += header->size;
    }
    return fail(ErrorCode::not_found, "iso_bmff: movie box missing");
}

}
