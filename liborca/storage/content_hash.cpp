#include "liborca/storage/content_hash.hpp"

#include "liborca/crypto/blake3.hpp"

#include <algorithm>
#include <vector>

namespace orca::storage::content_hash {

auto from_source(const ReadableSource& source) -> expected<Digest> {
    crypto::Blake3 hasher;
    std::vector<std::byte> buffer(static_cast<std::size_t>(64) * 1024);
    const std::uint64_t size = source.size();
    std::uint64_t offset = 0;
    while (offset < size) {
        const auto wanted = static_cast<std::size_t>(
            std::min<std::uint64_t>(static_cast<std::uint64_t>(buffer.size()), size - offset));
        const auto read = source.read_at(offset, std::span<std::byte>(buffer.data(), wanted));
        if (!read) {
            return std::unexpected(read.error());
        }
        if (*read == 0) {
            return fail(ErrorCode::io, "content_hash: unexpected end of source");
        }
        hasher.update(std::span<const std::byte>(buffer.data(), *read));
        offset += *read;
    }
    return hasher.finalize();
}

auto from_path(const std::filesystem::path& path) -> expected<Digest> {
    auto source = LocalFileSource::open(path);
    if (!source) {
        return std::unexpected(source.error());
    }
    return from_source(*source);
}

}
