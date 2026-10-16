#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/arena.hpp"
#include "liborca/metadata/model.hpp"
#include "liborca/storage/source.hpp"

#include <optional>

namespace orca::metadata::riff_tags {

[[nodiscard]] auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>>;
[[nodiscard]] auto read_picture(const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>>;

}
