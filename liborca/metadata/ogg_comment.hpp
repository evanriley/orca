#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/arena.hpp"
#include "liborca/metadata/lyrics.hpp"
#include "liborca/metadata/model.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <optional>

namespace orca::metadata::ogg_comment {

inline constexpr std::size_t max_packet_bytes = (1U << 24) - 1;

[[nodiscard]] auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>>;
[[nodiscard]] auto read_picture(const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>>;
[[nodiscard]] auto read_lyrics(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<lyrics::Content>>;

}
