#include "liborca/metadata/id3v1.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

extern "C" auto LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) -> int {
    if (size < 128) {
        return 0;
    }
    std::array<std::byte, 128> bytes{};
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        bytes[index] = static_cast<std::byte>(data[index]);
    }
    const auto tag = orca::metadata::id3v1::parse(bytes);
    if (tag) {
        (void)orca::metadata::id3v1::encode(*tag);
        (void)orca::metadata::id3v1::genre_name(tag->genre);
    }
    return 0;
}
