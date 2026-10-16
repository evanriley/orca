#include "liborca/metadata/id3v2.hpp"
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
    (void)orca::metadata::id3v2::read(arena, source);
    (void)orca::metadata::id3v2::read_picture(source);
    (void)orca::metadata::id3v2::read_lyrics(arena, source);
    (void)orca::metadata::id3v2::prefix_length(source);
    return 0;
}
