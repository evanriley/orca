#include "liborca/crypto/sha256.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/base/string.hpp"

#include <sha-256.h>

namespace orca::crypto {

namespace {

auto state_of(std::array<std::byte, Sha256::state_size>& storage) noexcept -> ::Sha_256* {
    static_assert(sizeof(::Sha_256) <= Sha256::state_size);
    return reinterpret_cast<::Sha_256*>(storage.data());
}

}

Sha256::Sha256() noexcept {
    sha_256_init(state_of(state_), digest_.data());
}

void Sha256::reset() noexcept {
    sha_256_init(state_of(state_), digest_.data());
    finalized_ = false;
}

void Sha256::update(std::span<const std::byte> data) noexcept {
    if (!finalized_) {
        sha_256_write(state_of(state_), data.data(), data.size());
    } else {
        ORCA_ASSERT(false && "sha256 updated after finalize");
    }
}

void Sha256::update(std::string_view data) noexcept {
    update(std::as_bytes(std::span(data.data(), data.size())));
}

auto Sha256::finalize() -> digest256 {
    if (!finalized_) {
        sha_256_close(state_of(state_));
        finalized_ = true;
        return digest_;
    }
    ORCA_ASSERT(false && "sha256 finalized twice");
    return digest_;
}

auto Sha256::finalize_hex() -> std::string {
    const digest256 digest = finalize();
    return strings::hex_encode(std::as_bytes(std::span(digest)));
}

auto sha256(std::span<const std::byte> data) -> digest256 {
    Sha256 hasher;
    hasher.update(data);
    return hasher.finalize();
}

auto sha256(std::string_view data) -> digest256 {
    return sha256(std::as_bytes(std::span(data.data(), data.size())));
}

}
