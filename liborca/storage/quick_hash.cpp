#include "liborca/storage/quick_hash.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/crypto/blake3.hpp"

#include <algorithm>
#include <vector>

namespace orca::storage::quick_hash {

namespace {

auto compute(const ReadableSource& source, std::uint64_t size) -> expected<Digest> {
    crypto::Blake3 hasher;
    std::vector<std::byte> buffer(window_bytes);
    const auto covered = static_cast<std::size_t>(
        std::min<std::uint64_t>(size, static_cast<std::uint64_t>(window_bytes)));

    const auto head = read_all(source, 0, std::span<std::byte>(buffer.data(), covered));
    if (!head || *head != covered) {
        return fail(ErrorCode::io, "quick_hash: short read at head");
    }
    hasher.update(std::span<const std::byte>(buffer.data(), covered));

    const auto tail =
        read_all(source, size - covered, std::span<std::byte>(buffer.data(), covered));
    if (!tail || *tail != covered) {
        return fail(ErrorCode::io, "quick_hash: short read at tail");
    }
    hasher.update(std::span<const std::byte>(buffer.data(), covered));

    std::array<std::uint8_t, 8> size_bytes{};
    for (std::size_t index = 0; index < size_bytes.size(); ++index) {
        size_bytes[index] = static_cast<std::uint8_t>((size >> (index * 8U)) & 0xffU);
    }
    hasher.update(std::as_bytes(std::span(size_bytes)));
    return hasher.finalize();
}

}

auto from_source(const ReadableSource& source) -> expected<Digest> {
    return compute(source, source.size());
}

auto from_path(const std::filesystem::path& path) -> expected<Digest> {
    auto source = LocalFileSource::open(path);
    if (!source) {
        return std::unexpected(source.error());
    }
    return from_source(*source);
}

}
