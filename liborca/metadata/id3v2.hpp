#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/arena.hpp"
#include "liborca/metadata/lyrics.hpp"
#include "liborca/metadata/model.hpp"
#include "liborca/metadata/mutation.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace orca::metadata::id3v2 {

inline constexpr std::size_t max_tag_bytes = 16U << 20;

[[nodiscard]] auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>>;
[[nodiscard]] auto read_picture(const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>>;
[[nodiscard]] auto read_lyrics(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<lyrics::Content>>;
[[nodiscard]] auto prefix_length(const storage::ReadableSource& source) -> expected<std::uint64_t>;

/// A replacement for an MPEG or ADTS stream's tags: the new leading tag, the
/// span of the original that is audio, and the trailer to end with.
struct Rewrite {
    std::vector<std::byte> tag;
    std::uint64_t audio_start = 0;
    std::uint64_t audio_end = 0;
    /// The ID3v1 trailer to write after the audio: the original one updated
    /// with the fields it can hold, or nullopt when the file had none.
    std::optional<std::array<std::byte, 128>> trailer = std::nullopt;
};

/// Plans a tag rewrite of the stream in `source` for `changes`.
///
/// Each change's `before` must equal what the file currently says, read the
/// way the scanner reads it. The tag keeps its version, and a stream with none
/// gets 2.4. Only the frames for the changed fields are replaced; every other
/// frame is copied byte for byte.
[[nodiscard]] auto rewrite(const storage::ReadableSource& source,
                           const std::vector<mutation::Change>& changes,
                           const std::optional<mutation::GenreChange>& genres) -> expected<Rewrite>;

}
