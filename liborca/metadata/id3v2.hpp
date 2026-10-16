#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/arena.hpp"
#include "liborca/metadata/lyrics.hpp"
#include "liborca/metadata/model.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>

namespace orca::metadata::id3v2 {

inline constexpr std::size_t max_tag_bytes = 16U << 20;

[[nodiscard]] auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>>;
[[nodiscard]] auto read_picture(const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>>;
[[nodiscard]] auto read_lyrics(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<lyrics::Content>>;
[[nodiscard]] auto prefix_length(const storage::ReadableSource& source) -> expected<std::uint64_t>;

}
