#pragma once

#include "liborca/codec/decoder.hpp"
#include "liborca/storage/source.hpp"

#include <cstdint>
#include <memory>
#include <span>

namespace orca::codec {

[[nodiscard]] auto open_wav(const storage::ReadableSource& source)
    -> expected<std::unique_ptr<Decoder>>;

[[nodiscard]] auto decode_sample(SampleFormat format, std::span<const std::byte> bytes) -> float;
[[nodiscard]] auto decode_integer(SampleFormat format, std::span<const std::byte> bytes)
    -> expected<std::int32_t>;

}
