#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/arena.hpp"
#include "liborca/metadata/lyrics.hpp"

#include <optional>
#include <string_view>

namespace orca::metadata::lrc {

[[nodiscard]] auto parse(Arena& arena, std::string_view input)
    -> expected<std::optional<lyrics::Content>>;

}
