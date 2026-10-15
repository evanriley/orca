#include "liborca/codec/decoder.hpp"

#include "liborca/codec/engine.hpp"

namespace orca::codec {

auto integer_sample_to_float(std::int32_t sample) -> float {
    return static_cast<float>(static_cast<double>(sample) / 2147483648.0);
}

auto Decoder::read_frames_i32_impl(std::span<std::int32_t> output) -> expected<std::size_t> {
    (void)output;
    return fail(ErrorCode::unsupported, "decoder: no integer samples");
}

auto Engine::decode_i32(std::span<const std::byte> packet, std::span<std::int32_t> output)
    -> expected<std::uint32_t> {
    (void)packet;
    (void)output;
    return fail(ErrorCode::unsupported, "engine: no integer samples");
}

}
