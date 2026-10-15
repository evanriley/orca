#include "liborca/base/checked.hpp"

#include <cstddef>
#include <cstdint>

extern "C" auto LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) -> int {
    if (size == 0) {
        return 0;
    }

    std::uint64_t raw = 0;
    for (std::size_t index = 0; index < size && index < 8; ++index) {
        raw = (raw << 8U) | static_cast<std::uint64_t>(data[index]);
    }
    const auto wide = static_cast<std::int64_t>(raw);

    const auto narrowed = orca::checked::narrow<std::int32_t>(wide);
    if (narrowed) {
        const auto incremented = orca::checked::add<std::int32_t>(narrowed.value(), 1);
        const auto negated = orca::checked::sub<std::int32_t>(0, narrowed.value());
        (void)incremented;
        (void)negated;
    }

    const auto unsigned_narrow = orca::checked::narrow<std::uint16_t>(wide);
    (void)unsigned_narrow;
    return 0;
}
