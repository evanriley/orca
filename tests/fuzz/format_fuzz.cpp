#include "liborca/storage/format.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <cstdint>
#include <span>

extern "C" auto LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) -> int {
    if (size == 0) {
        return 0;
    }
    const auto bytes = std::span<const std::byte>(reinterpret_cast<const std::byte*>(data), size);
    (void)orca::storage::sniff_bytes(bytes);
    orca::storage::MemorySource source(bytes);
    (void)orca::storage::detect(source);
    return 0;
}
