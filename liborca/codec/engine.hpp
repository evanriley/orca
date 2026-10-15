#pragma once

#include "liborca/base/expected.hpp"

#include <cstdint>
#include <optional>
#include <span>

namespace orca::codec {

class Engine {
public:
    virtual ~Engine() = default;

    Engine(const Engine&) = delete;
    auto operator=(const Engine&) -> Engine& = delete;

    [[nodiscard]] virtual auto decode(std::span<const std::byte> packet, std::span<float> output)
        -> expected<std::uint32_t> = 0;
    virtual void reset() = 0;
    [[nodiscard]] virtual auto has_integer_samples() const -> bool {
        return false;
    }
    [[nodiscard]] virtual auto decode_i32(std::span<const std::byte> packet,
                                          std::span<std::int32_t> output)
        -> expected<std::uint32_t>;

    std::uint32_t max_packet_frames = 0;
    std::uint16_t channels = 0;
    std::uint32_t sample_rate = 0;
    std::optional<std::uint16_t> bits_per_sample;
    std::uint32_t preroll_packets = 0;

protected:
    Engine() = default;
};

}
