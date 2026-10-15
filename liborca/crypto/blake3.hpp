#pragma once

#include "liborca/crypto/digest.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

namespace orca::crypto {

class Blake3 {
public:
    static constexpr std::size_t state_size = 2048;
    static constexpr std::size_t state_align = 8;

    Blake3() noexcept;
    ~Blake3() = default;

    Blake3(const Blake3&) = delete;
    auto operator=(const Blake3&) -> Blake3& = delete;
    Blake3(Blake3&&) = delete;
    auto operator=(Blake3&&) -> Blake3& = delete;

    void reset() noexcept;
    void update(std::span<const std::byte> data) noexcept;
    void update(std::string_view data) noexcept;

    [[nodiscard]] auto finalize() const -> digest256;
    [[nodiscard]] auto finalize_hex() const -> std::string;

private:
    alignas(state_align) std::array<std::byte, state_size> state_{};
};

[[nodiscard]] auto blake3(std::span<const std::byte> data) -> digest256;
[[nodiscard]] auto blake3(std::string_view data) -> digest256;

}
