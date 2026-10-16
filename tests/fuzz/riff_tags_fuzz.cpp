#include "liborca/metadata/riff_tags.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <cstdint>
#include <span>

extern "C" auto LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) -> int {
    if (size == 0) {
        return 0;
    }
    const auto bytes = std::span<const std::byte>(reinterpret_cast<const std::byte*>(data), size);
    orca::storage::MemorySource source(bytes);
    orca::metadata::Arena arena;
    (void)orca::metadata::riff_tags::read(arena, source);
    (void)orca::metadata::riff_tags::read_picture(source);
    return 0;
}
