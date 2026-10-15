#pragma once

#include "liborca/crypto/digest.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

namespace orca::crypto {

class Sha256 {
public:
    static constexpr std::size_t state_size = 256;
    static constexpr std::size_t state_align = 8;

    Sha256() noexcept;
    ~Sha256() = default;

    Sha256(const Sha256&) = delete;
    auto operator=(const Sha256&) -> Sha256& = delete;
    Sha256(Sha256&&) = delete;
    auto operator=(Sha256&&) -> Sha256& = delete;

    void reset() noexcept;
    void update(std::span<const std::byte> data) noexcept;
    void update(std::string_view data) noexcept;

    [[nodiscard]] auto finalize() -> digest256;
    [[nodiscard]] auto finalize_hex() -> std::string;

private:
    alignas(state_align) std::array<std::byte, state_size> state_{};
    digest256 digest_{};
    bool finalized_ = false;
};

[[nodiscard]] auto sha256(std::span<const std::byte> data) -> digest256;
[[nodiscard]] auto sha256(std::string_view data) -> digest256;

}
