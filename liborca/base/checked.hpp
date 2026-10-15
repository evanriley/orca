#pragma once

#include "liborca/base/error.hpp"
#include "liborca/base/expected.hpp"
#include "liborca/base/logging.hpp"

#include <concepts>
#include <limits>
#include <type_traits>
#include <utility>

namespace orca::checked {

template <std::integral T>
[[nodiscard]] auto add(T lhs, T rhs) -> expected<T> {
    T result{};
    if (__builtin_add_overflow(lhs, rhs, &result)) {
        return fail(ErrorCode::overflow, "checked add");
    }
    return result;
}

template <std::integral T>
[[nodiscard]] auto sub(T lhs, T rhs) -> expected<T> {
    T result{};
    if (__builtin_sub_overflow(lhs, rhs, &result)) {
        return fail(ErrorCode::overflow, "checked sub");
    }
    return result;
}

template <std::integral T>
[[nodiscard]] auto mul(T lhs, T rhs) -> expected<T> {
    T result{};
    if (__builtin_mul_overflow(lhs, rhs, &result)) {
        return fail(ErrorCode::overflow, "checked mul");
    }
    return result;
}

template <std::integral T>
[[nodiscard]] auto div(T lhs, T rhs) -> expected<T> {
    if (rhs == T{0}) {
        return fail(ErrorCode::division_by_zero, "checked div");
    }
    if constexpr (std::signed_integral<T>) {
        if (lhs == std::numeric_limits<T>::min() && rhs == static_cast<T>(-1)) {
            return fail(ErrorCode::overflow, "checked div");
        }
    }
    return static_cast<T>(lhs / rhs);
}

template <std::integral To, std::integral From>
[[nodiscard]] auto narrow(From value) -> expected<To> {
    if (!std::in_range<To>(value)) {
        return fail(ErrorCode::overflow, "checked narrow");
    }
    return static_cast<To>(value);
}

template <std::integral T>
[[nodiscard]] auto add_or_trap(T lhs, T rhs) -> T {
    const auto result = add(lhs, rhs);
    if (!result) {
        ORCA_PANIC("checked add overflow");
    }
    return *result;
}

template <std::integral T>
[[nodiscard]] auto sub_or_trap(T lhs, T rhs) -> T {
    const auto result = sub(lhs, rhs);
    if (!result) {
        ORCA_PANIC("checked sub overflow");
    }
    return *result;
}

template <std::integral T>
[[nodiscard]] auto mul_or_trap(T lhs, T rhs) -> T {
    const auto result = mul(lhs, rhs);
    if (!result) {
        ORCA_PANIC("checked mul overflow");
    }
    return *result;
}

template <std::integral T>
[[nodiscard]] auto div_or_trap(T lhs, T rhs) -> T {
    const auto result = div(lhs, rhs);
    if (!result) {
        ORCA_PANIC("checked division failed");
    }
    return *result;
}

template <std::integral To, std::integral From>
[[nodiscard]] auto narrow_or_trap(From value) -> To {
    const auto result = narrow<To>(value);
    if (!result) {
        ORCA_PANIC("checked narrow overflow");
    }
    return *result;
}

}
