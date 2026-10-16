#include "liborca/metadata/lrc.hpp"

#include <cstddef>
#include <cstdint>
#include <string_view>

extern "C" auto LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) -> int {
    if (size == 0) {
        return 0;
    }
    orca::metadata::Arena arena;
    const std::string_view text(reinterpret_cast<const char*>(data), size);
    (void)orca::metadata::lrc::parse(arena, text);
    return 0;
}
