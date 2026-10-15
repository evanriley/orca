#include "liborca/crypto/secure_zero.hpp"

#include "liborca/base/logging.hpp"

#include <atomic>

namespace orca::crypto {

void secure_zero(void* data, std::size_t size) noexcept {
    ORCA_ASSERT(data != nullptr || size == 0);
    auto* pointer = static_cast<volatile unsigned char*>(data);
    while (size > 0) {
        *pointer = 0;
        ++pointer;
        --size;
    }
    std::atomic_signal_fence(std::memory_order_seq_cst);
}

}
