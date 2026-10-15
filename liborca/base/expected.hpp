#pragma once

#include "liborca/base/error.hpp"

#include <expected>
#include <string>
#include <utility>

namespace orca {

template <typename T>
using expected = std::expected<T, Error>;

using unexpected = std::unexpected<Error>;

[[nodiscard]] inline auto fail(ErrorCode code, std::string context = {}) -> unexpected {
    return unexpected(Error{code, std::move(context)});
}

template <typename T>
[[nodiscard]] auto failure(const expected<T>& value) -> unexpected {
    return unexpected(value.error());
}

}
