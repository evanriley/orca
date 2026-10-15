#pragma once

#include <cstddef>
#include <span>

namespace orca::crypto {

void secure_zero(void* data, std::size_t size) noexcept;

inline void secure_zero(std::span<std::byte> bytes) noexcept {
    secure_zero(bytes.data(), bytes.size());
}

}
