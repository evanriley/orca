#include "liborca/crypto/blake3.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/base/string.hpp"

#include <blake3.h>

namespace orca::crypto {

namespace {

auto state_of(std::array<std::byte, Blake3::state_size>& storage) noexcept -> ::blake3_hasher* {
    static_assert(sizeof(::blake3_hasher) <= Blake3::state_size);
    static_assert(alignof(::blake3_hasher) <= Blake3::state_align);
    return reinterpret_cast<::blake3_hasher*>(storage.data());
}

auto state_of(const std::array<std::byte, Blake3::state_size>& storage) noexcept
    -> const ::blake3_hasher* {
    static_assert(sizeof(::blake3_hasher) <= Blake3::state_size);
    static_assert(alignof(::blake3_hasher) <= Blake3::state_align);
    return reinterpret_cast<const ::blake3_hasher*>(storage.data());
}

}

Blake3::Blake3() noexcept {
    blake3_hasher_init(state_of(state_));
}

void Blake3::reset() noexcept {
    blake3_hasher_reset(state_of(state_));
}

void Blake3::update(std::span<const std::byte> data) noexcept {
    ORCA_ASSERT(data.data() != nullptr || data.empty());
    blake3_hasher_update(state_of(state_), data.data(), data.size());
}

void Blake3::update(std::string_view data) noexcept {
    update(std::as_bytes(std::span(data.data(), data.size())));
}

auto Blake3::finalize() const -> digest256 {
    digest256 out{};
    blake3_hasher_finalize(state_of(state_), out.data(), out.size());
    return out;
}

auto Blake3::finalize_hex() const -> std::string {
    const digest256 digest = finalize();
    return strings::hex_encode(std::as_bytes(std::span(digest)));
}

auto blake3(std::span<const std::byte> data) -> digest256 {
    Blake3 hasher;
    hasher.update(data);
    return hasher.finalize();
}

auto blake3(std::string_view data) -> digest256 {
    return blake3(std::as_bytes(std::span(data.data(), data.size())));
}

}
