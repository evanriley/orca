#include "liborca/storage/iso_bmff.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <cstdint>
#include <span>

extern "C" auto LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) -> int {
    if (size == 0) {
        return 0;
    }
    const auto bytes = std::span<const std::byte>(reinterpret_cast<const std::byte*>(data), size);

    orca::storage::iso_bmff::Iterator boxes(bytes);
    for (std::size_t index = 0; index < 64; ++index) {
        const auto box = boxes.next();
        if (!box || !*box) {
            break;
        }
    }

    orca::storage::MemorySource source(bytes);
    (void)orca::storage::iso_bmff::read_movie(source);
    return 0;
}
