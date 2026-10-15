#include "liborca/codec/registry.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

extern "C" auto LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) -> int {
    if (size == 0) {
        return 0;
    }
    const auto bytes = std::span<const std::byte>(reinterpret_cast<const std::byte*>(data), size);
    orca::storage::MemorySource source(bytes);

    const auto registry = orca::codec::CodecRegistry::builtins();
    auto decoder = registry.open_detected(source);
    if (decoder) {
        std::array<float, 4096> samples{};
        for (std::size_t index = 0; index < 8; ++index) {
            const auto read = (*decoder)->read_frames(samples);
            if (!read || *read == 0) {
                break;
            }
        }
    }
    (void)registry.probe_detected(source);
    return 0;
}
