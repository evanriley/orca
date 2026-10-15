#include "liborca/base/logging.hpp"

#include <array>
#include <cstdio>
#include <cstdlib>

#if !defined(NDEBUG) && defined(__has_include)
#if __has_include(<execinfo.h>)
#include <execinfo.h>
#define ORCA_HAVE_BACKTRACE 1
#endif
#endif

namespace orca {

void trap(std::string_view message, const std::source_location& location) {
    std::fprintf(stderr, "orca: fatal: %.*s (%s:%u)\n", static_cast<int>(message.size()),
                 message.data(), location.file_name(), static_cast<unsigned>(location.line()));
#ifdef ORCA_HAVE_BACKTRACE
    std::fprintf(stderr, "orca: stack trace:\n");
    std::array<void*, 64> frames{};
    const int count = ::backtrace(frames.data(), static_cast<int>(frames.size()));
    ::backtrace_symbols_fd(frames.data(), count, ::fileno(stderr));
#endif
    std::fflush(stderr);
    std::abort();
}

}
