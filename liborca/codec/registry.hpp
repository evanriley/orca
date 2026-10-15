#pragma once

#include "liborca/codec/decoder.hpp"
#include "liborca/storage/format.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string_view>

namespace orca::codec {

struct Properties {
    std::optional<std::string_view> codec;
    std::optional<std::uint32_t> sample_rate;
    std::optional<std::uint16_t> channels;
    std::optional<std::uint16_t> bit_depth;
    std::optional<std::uint64_t> duration_ms;
};

using ProbeFn = expected<Properties> (*)(const storage::ReadableSource&);

struct Descriptor {
    std::string_view name;
    storage::AudioFormat format;
    OpenFn open;
    ProbeFn probe = nullptr;
};

class CodecRegistry {
public:
    [[nodiscard]] auto register_codec(const Descriptor& descriptor) -> expected<void>;

    [[nodiscard]] auto open(storage::AudioFormat format,
                            const storage::ReadableSource& source) const
        -> expected<std::unique_ptr<Decoder>>;
    [[nodiscard]] auto open_detected(const storage::ReadableSource& source) const
        -> expected<std::unique_ptr<Decoder>>;

    [[nodiscard]] auto probe(storage::AudioFormat format,
                             const storage::ReadableSource& source) const -> expected<Properties>;
    [[nodiscard]] auto probe_detected(const storage::ReadableSource& source) const
        -> expected<Properties>;

    [[nodiscard]] static auto builtins() -> CodecRegistry;

private:
    [[nodiscard]] auto open_exact(storage::AudioFormat format,
                                  const storage::ReadableSource& source) const
        -> expected<std::unique_ptr<Decoder>>;
    [[nodiscard]] auto probe_container(storage::AudioFormat format,
                                       const storage::ReadableSource& source) const
        -> expected<std::optional<Properties>>;

    std::array<Descriptor, 16> entries_{};
    std::size_t count_ = 0;
};

[[nodiscard]] auto properties(const Decoder& decoder) -> Properties;

}
