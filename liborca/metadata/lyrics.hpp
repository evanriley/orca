#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/arena.hpp"
#include "liborca/storage/format.hpp"
#include "liborca/storage/source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace orca::metadata::lyrics {

enum class Source : std::uint8_t {
    sidecar,
    embedded,
    lrclib,
};

enum class Kind : std::uint8_t {
    synced,
    plain,
    instrumental,
};

struct Line {
    std::optional<std::uint32_t> start_ms;
    std::string_view text;
};

inline constexpr std::size_t max_text_bytes = 512U << 10;
inline constexpr std::size_t max_lines = 4096;

struct Content {
    Kind kind = Kind::plain;
    std::optional<std::array<char, 3>> language = std::nullopt;
    std::int64_t offset_ms = 0;
    std::vector<Line> lines;
};

void sort_lines(Content& content);

[[nodiscard]] auto language_code(const std::array<char, 3>& bytes)
    -> std::optional<std::array<char, 3>>;

[[nodiscard]] auto line_at(const Content& content, std::uint64_t position_ms)
    -> std::optional<std::size_t>;

class Lyrics {
public:
    Lyrics(const Lyrics&) = delete;
    auto operator=(const Lyrics&) -> Lyrics& = delete;
    Lyrics(Lyrics&&) = default;
    auto operator=(Lyrics&&) -> Lyrics& = default;

    [[nodiscard]] auto source() const noexcept -> Source {
        return source_;
    }

    [[nodiscard]] auto kind() const noexcept -> Kind {
        return content_.kind;
    }

    [[nodiscard]] auto language() const noexcept -> std::optional<std::array<char, 3>> {
        return content_.language;
    }

    [[nodiscard]] auto offset_ms() const noexcept -> std::int64_t {
        return content_.offset_ms;
    }

    [[nodiscard]] auto source_name() const noexcept -> std::string_view {
        return source_name_;
    }

    [[nodiscard]] auto lines() const noexcept -> std::span<const Line> {
        return content_.lines;
    }

    void set_source_name(std::string_view name) {
        source_name_ = arena_.store(name);
    }

    [[nodiscard]] auto line_at(std::uint64_t position_ms) const -> std::optional<std::size_t> {
        return lyrics::line_at(content_, position_ms);
    }

private:
    friend auto adopt(Arena arena, Content content, Source origin) -> Lyrics;

    Lyrics(Arena arena, Content content, Source origin);

    Arena arena_;
    Content content_;
    Source source_ = Source::sidecar;
    std::string_view source_name_;
};

[[nodiscard]] auto adopt(Arena arena, Content content, Source origin) -> Lyrics;

[[nodiscard]] auto parse(std::string_view text, Source origin) -> expected<std::optional<Lyrics>>;

[[nodiscard]] auto instrumental(Source origin) -> Lyrics;

[[nodiscard]] auto read_embedded(const storage::ReadableSource& source) -> std::optional<Lyrics>;

[[nodiscard]] auto read_detected(storage::AudioFormat audio_format,
                                 const storage::ReadableSource& source) -> std::optional<Lyrics>;

}
