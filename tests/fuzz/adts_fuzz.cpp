#include "liborca/codec/adts.hpp"
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

    auto decoder = orca::codec::open_adts(source);
    if (decoder) {
        std::array<float, 256> samples{};
        (void)(*decoder)->read_frames(samples);
    }
    (void)orca::codec::probe_adts(source);
    return 0;
}
