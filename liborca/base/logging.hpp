#pragma once

#include <source_location>
#include <string_view>

namespace orca {

[[noreturn]] void trap(std::string_view message,
                       const std::source_location& location = std::source_location::current());

}

#if !defined(NDEBUG)
#define ORCA_ASSERT(condition)                                                                     \
    do {                                                                                           \
        if (!(condition)) {                                                                        \
            ::orca::trap("assertion failed: " #condition, std::source_location::current());        \
        }                                                                                          \
    } while (false)
#else
#define ORCA_ASSERT(condition) ((void)sizeof(condition))
#endif

#define ORCA_CHECK(condition)                                                                      \
    do {                                                                                           \
        if (!(condition)) {                                                                        \
            ::orca::trap("check failed: " #condition, std::source_location::current());            \
        }                                                                                          \
    } while (false)

#define ORCA_PANIC(message) ::orca::trap((message), std::source_location::current())
