#include "liborca/metadata/image_header.hpp"

#include <cstddef>
#include <cstdint>
#include <span>

extern "C" auto LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) -> int {
    if (size == 0) {
        return 0;
    }
    const auto bytes = std::span<const std::byte>(reinterpret_cast<const std::byte*>(data), size);
    (void)orca::metadata::image_header::dimensions(bytes);
    (void)orca::metadata::image_header::measure(bytes);
    return 0;
}
