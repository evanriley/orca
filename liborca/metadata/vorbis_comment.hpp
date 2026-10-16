#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/arena.hpp"
#include "liborca/metadata/lyrics.hpp"
#include "liborca/metadata/model.hpp"
#include "liborca/metadata/mutation.hpp"
#include "liborca/storage/source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace orca::metadata::vorbis_comment {

inline constexpr std::size_t max_metadata_block_size = (1U << 24) - 1;
inline constexpr std::size_t max_picture_text_size = 4096;

struct Entry {
    std::string_view key;
    std::string_view value;
};

struct PictureView {
    ArtworkKind kind = ArtworkKind::other;
    std::string_view mime_type;
    std::span<const std::byte> data;
};

class Entries {
public:
    [[nodiscard]] static auto init(std::span<const std::byte> payload) -> expected<Entries>;
    [[nodiscard]] auto next() -> expected<std::optional<Entry>>;

private:
    std::span<const std::byte> payload_;
    std::size_t cursor_ = 0;
    std::uint32_t remaining_ = 0;
};

[[nodiscard]] auto parse(Arena& arena, std::span<const std::byte> payload)
    -> expected<ObservedTags>;
[[nodiscard]] auto read(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<ObservedTags>>;
[[nodiscard]] auto read_picture(const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>>;
[[nodiscard]] auto read_lyrics(Arena& arena, const storage::ReadableSource& source)
    -> expected<std::optional<lyrics::Content>>;
[[nodiscard]] auto lyrics_from_comments(Arena& arena, std::span<const std::byte> payload)
    -> expected<std::optional<lyrics::Content>>;
[[nodiscard]] auto picture_from_block(std::span<const std::byte> block)
    -> std::optional<PictureView>;
[[nodiscard]] auto artwork_kind(std::uint32_t picture_type) -> ArtworkKind;

/// The key a write stores `field` under.
[[nodiscard]] auto field_key(Field field) -> std::string_view;

/// `genres` replaces every GENRE entry with one entry per genre, after
/// checking the file's current GENRE values are `genres.before`.
[[nodiscard]] auto rewrite(std::span<const std::byte> payload,
                           const std::vector<mutation::Change>& changes,
                           const std::optional<mutation::GenreChange>& genres)
    -> expected<std::vector<std::byte>>;

/// A new comment block with `changes` and `genres`, refusing any change that
/// states a `before` and any non-empty genre precondition.
[[nodiscard]] auto create(const std::vector<mutation::Change>& changes,
                          const std::optional<mutation::GenreChange>& genres)
    -> expected<std::vector<std::byte>>;

}
