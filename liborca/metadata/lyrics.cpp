#include "liborca/metadata/lyrics.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/metadata/id3v2.hpp"
#include "liborca/metadata/lrc.hpp"
#include "liborca/metadata/mp4_tags.hpp"
#include "liborca/metadata/ogg_comment.hpp"
#include "liborca/metadata/vorbis_comment.hpp"

#include <algorithm>
#include <utility>

namespace orca::metadata::lyrics {

namespace {

[[nodiscard]] auto is_alpha(char value) -> bool {
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z');
}

[[nodiscard]] auto to_lower(char value) -> char {
    return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
}

}

void sort_lines(Content& content) {
    std::ranges::stable_sort(content.lines, [](const Line& first, const Line& second) {
        return first.start_ms.value_or(0) < second.start_ms.value_or(0);
    });
}

auto language_code(const std::array<char, 3>& bytes) -> std::optional<std::array<char, 3>> {
    std::array<char, 3> code{};
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        if (!is_alpha(bytes[index])) {
            return std::nullopt;
        }
        code[index] = to_lower(bytes[index]);
    }
    if (code == std::array<char, 3>{'x', 'x', 'x'}) {
        return std::nullopt;
    }
    return code;
}

auto line_at(const Content& content, std::uint64_t position_ms) -> std::optional<std::size_t> {
    if (content.kind != Kind::synced) {
        return std::nullopt;
    }
    std::size_t low = 0;
    std::size_t high = content.lines.size();
    while (low < high) {
        const std::size_t middle = low + ((high - low) / 2);
        const std::uint64_t start = content.lines[middle].start_ms.value_or(0);
        if (start <= position_ms) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == 0) {
        return std::nullopt;
    }
    return low - 1;
}

namespace {

[[nodiscard]] auto lyrics_reader(storage::AudioFormat audio_format, Arena& arena,
                                 const storage::ReadableSource& source)
    -> expected<std::optional<Content>> {
    switch (audio_format) {
    case storage::AudioFormat::flac:
        return vorbis_comment::read_lyrics(arena, source);
    case storage::AudioFormat::mp3:
    case storage::AudioFormat::aac:
        return id3v2::read_lyrics(arena, source);
    case storage::AudioFormat::mp4:
        return mp4_tags::read_lyrics(arena, source);
    case storage::AudioFormat::opus:
    case storage::AudioFormat::vorbis:
        return ogg_comment::read_lyrics(arena, source);
    case storage::AudioFormat::wav:
    case storage::AudioFormat::aiff:
    case storage::AudioFormat::wavpack:
    case storage::AudioFormat::qoa:
        return std::optional<Content>{};
    }
    ORCA_ASSERT(false && "unhandled audio format");
    return std::optional<Content>{};
}

}

Lyrics::Lyrics(Arena arena, Content content, Source origin)
    : arena_{std::move(arena)}, content_{std::move(content)}, source_{origin} {}

auto adopt(Arena arena, Content content, Source origin) -> Lyrics {
    Lyrics lyrics{std::move(arena), std::move(content), origin};
    switch (origin) {
    case Source::sidecar:
        break;
    case Source::embedded:
        lyrics.source_name_ = "embedded";
        break;
    case Source::lrclib:
        lyrics.source_name_ = "LRCLIB";
        break;
    }
    return lyrics;
}

auto parse(std::string_view text, Source origin) -> expected<std::optional<Lyrics>> {
    Arena arena;
    auto content = lrc::parse(arena, text);
    if (!content) {
        return std::unexpected(content.error());
    }
    if (!*content) {
        return std::optional<Lyrics>{};
    }
    return adopt(std::move(arena), std::move(**content), origin);
}

auto instrumental(Source origin) -> Lyrics {
    Content content;
    content.kind = Kind::instrumental;
    return adopt(Arena{}, std::move(content), origin);
}

auto read_detected(storage::AudioFormat audio_format, const storage::ReadableSource& source)
    -> std::optional<Lyrics> {
    Arena arena;
    auto found = lyrics_reader(audio_format, arena, source);
    if (!found) {
        return std::nullopt;
    }
    if (!*found) {
        return std::nullopt;
    }
    return adopt(std::move(arena), std::move(**found), Source::embedded);
}

auto read_embedded(const storage::ReadableSource& source) -> std::optional<Lyrics> {
    const auto detection = storage::detect(source);
    if (!detection) {
        return std::nullopt;
    }
    if (!*detection) {
        return std::nullopt;
    }
    if ((*detection)->payload_offset == 0) {
        return read_detected((*detection)->format, source);
    }
    const storage::OffsetSource view(source, (*detection)->payload_offset);
    return read_detected((*detection)->format, view);
}

}
