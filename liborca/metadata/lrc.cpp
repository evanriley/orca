#include "liborca/metadata/lrc.hpp"

#include "liborca/base/logging.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>

namespace orca::metadata::lrc {

namespace {

struct Timestamp {
    enum class Kind : std::uint8_t { valid, invalid, not_timestamp };
    Kind kind = Kind::not_timestamp;
    std::int64_t value = 0;
};

[[nodiscard]] auto is_ascii_digit(char value) -> bool {
    return value >= '0' && value <= '9';
}

[[nodiscard]] auto is_ascii_alpha(char value) -> bool {
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z');
}

[[nodiscard]] auto all_digits(std::string_view text) -> bool {
    for (const char byte : text) {
        if (!is_ascii_digit(byte)) {
            return false;
        }
    }
    return true;
}

[[nodiscard]] auto trim(std::string_view text, std::string_view set) -> std::string_view {
    while (!text.empty() && set.find(text.front()) != std::string_view::npos) {
        text.remove_prefix(1);
    }
    while (!text.empty() && set.find(text.back()) != std::string_view::npos) {
        text.remove_suffix(1);
    }
    return text;
}

[[nodiscard]] auto parse_i64(std::string_view text) -> std::optional<std::int64_t> {
    if (text.empty()) {
        return std::nullopt;
    }
    if (text.front() == '+') {
        text.remove_prefix(1);
        if (text.empty()) {
            return std::nullopt;
        }
    }
    std::int64_t value = 0;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), value);
    if (result.ec != std::errc{} || result.ptr != text.data() + text.size()) {
        return std::nullopt;
    }
    return value;
}

[[nodiscard]] auto parse_u32(std::string_view text) -> std::optional<std::uint32_t> {
    if (text.empty()) {
        return std::nullopt;
    }
    std::uint32_t value = 0;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), value);
    if (result.ec != std::errc{} || result.ptr != text.data() + text.size()) {
        return std::nullopt;
    }
    return value;
}

[[nodiscard]] auto parse_timestamp(std::string_view inner) -> Timestamp {
    if (inner.empty() || !is_ascii_digit(inner.front())) {
        return Timestamp{};
    }
    const auto colon = inner.find(':');
    if (colon == std::string_view::npos) {
        return Timestamp{};
    }
    const std::string_view minutes_text = inner.substr(0, colon);
    const std::string_view after = inner.substr(colon + 1);
    const auto dot = after.find('.');
    const std::string_view seconds_text =
        dot == std::string_view::npos ? after : after.substr(0, dot);
    const std::string_view fraction_text =
        dot == std::string_view::npos ? std::string_view() : after.substr(dot + 1);
    if (!all_digits(minutes_text) || seconds_text.empty() || !all_digits(seconds_text) ||
        !all_digits(fraction_text)) {
        return Timestamp{};
    }
    if (dot != std::string_view::npos && (fraction_text.empty() || fraction_text.size() > 3)) {
        return Timestamp{.kind = Timestamp::Kind::invalid};
    }
    const auto minutes = parse_u32(minutes_text);
    const auto seconds = parse_u32(seconds_text);
    if (!minutes || !seconds || *seconds >= 60) {
        return Timestamp{.kind = Timestamp::Kind::invalid};
    }
    std::int64_t fraction = 0;
    if (!fraction_text.empty()) {
        const auto parsed = parse_u32(fraction_text);
        if (!parsed) {
            return Timestamp{.kind = Timestamp::Kind::invalid};
        }
        fraction = *parsed;
    }
    std::size_t digits = fraction_text.size();
    while (digits < 3 && !fraction_text.empty()) {
        fraction *= 10;
        ++digits;
    }
    const std::int64_t total =
        ((static_cast<std::int64_t>(*minutes) * 60 + *seconds) * 1000) + fraction;
    if (std::cmp_greater(total, std::numeric_limits<std::uint32_t>::max())) {
        return Timestamp{.kind = Timestamp::Kind::invalid};
    }
    return Timestamp{.kind = Timestamp::Kind::valid, .value = total};
}

[[nodiscard]] auto is_id_tag(std::string_view inner) -> bool {
    const auto colon = inner.find(':');
    if (colon == std::string_view::npos || colon == 0) {
        return false;
    }
    for (const char byte : inner.substr(0, colon)) {
        if (!is_ascii_alpha(byte)) {
            return false;
        }
    }
    return true;
}

[[nodiscard]] auto tag_value(std::string_view inner, std::string_view key)
    -> std::optional<std::string_view> {
    const auto colon = inner.find(':');
    if (colon == std::string_view::npos) {
        return std::nullopt;
    }
    const std::string_view name = inner.substr(0, colon);
    if (name.size() != key.size()) {
        return std::nullopt;
    }
    for (std::size_t index = 0; index < name.size(); ++index) {
        const auto lower = [](char value) {
            return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
        };
        if (lower(name[index]) != lower(key[index])) {
            return std::nullopt;
        }
    }
    return inner.substr(colon + 1);
}

[[nodiscard]] auto strip_word_stamps(Arena& arena, std::string_view text) -> std::string_view {
    std::string out;
    std::size_t index = 0;
    while (index < text.size()) {
        if (text[index] == '<') {
            const auto close = text.find('>', index);
            if (close != std::string_view::npos &&
                parse_timestamp(text.substr(index + 1, close - index - 1)).kind !=
                    Timestamp::Kind::not_timestamp) {
                index = close + 1;
                continue;
            }
        }
        out.push_back(text[index]);
        ++index;
    }
    return trim(arena.store(out), " \t");
}

[[nodiscard]] auto utf8_valid(std::string_view text) -> bool {
    std::size_t index = 0;
    while (index < text.size()) {
        const auto byte = static_cast<unsigned char>(text[index]);
        std::size_t extra = 0;
        if (byte < 0x80U) {
            extra = 0;
        } else {
            if ((byte & 0xe0U) == 0xc0U) {
                extra = 1;
            } else {
                if ((byte & 0xf0U) == 0xe0U) {
                    extra = 2;
                } else {
                    if ((byte & 0xf8U) == 0xf0U) {
                        extra = 3;
                    } else {
                        return false;
                    }
                }
            }
        }
        if (index + extra >= text.size()) {
            return false;
        }
        for (std::size_t offset = 1; offset <= extra; ++offset) {
            if ((static_cast<unsigned char>(text[index + offset]) & 0xc0U) != 0x80U) {
                return false;
            }
        }
        index += extra + 1;
    }
    return true;
}

}

struct RowScan {
    bool tag_only = false;
    bool dropped = false;
    bool overflow = false;
    std::size_t stamp_count = 0;
    std::array<std::int64_t, lyrics::max_lines> stamps{};
    std::string_view rest;
};

[[nodiscard]] auto scan_row(std::string_view row, std::int64_t& offset_ms) -> RowScan {
    RowScan scan;
    scan.rest = row;
    while (!scan.rest.empty() && scan.rest.front() == '[') {
        ORCA_ASSERT(scan.stamp_count <= scan.stamps.size());
        const auto close = scan.rest.find(']');
        if (close == std::string_view::npos) {
            break;
        }
        const std::string_view inner = scan.rest.substr(1, close - 1);
        const Timestamp stamp = parse_timestamp(inner);
        if (stamp.kind == Timestamp::Kind::valid) {
            if (scan.stamp_count == scan.stamps.size()) {
                scan.overflow = true;
                break;
            }
            scan.stamps[scan.stamp_count] = stamp.value;
            ++scan.stamp_count;
        } else {
            if (stamp.kind == Timestamp::Kind::invalid) {
                scan.dropped = true;
            } else {
                if (scan.stamp_count == 0 && !scan.dropped && is_id_tag(inner) &&
                    trim(scan.rest.substr(close + 1), " \t").empty()) {
                    if (const auto value = tag_value(inner, "offset")) {
                        if (const auto parsed = parse_i64(trim(*value, " "))) {
                            offset_ms = *parsed;
                        }
                    }
                    scan.tag_only = true;
                }
                break;
            }
        }
        scan.rest = scan.rest.substr(close + 1);
        if (scan.dropped) {
            break;
        }
    }
    return scan;
}

[[nodiscard]] auto append_row(Arena& arena, std::string_view row, const RowScan& scan,
                              std::vector<std::pair<std::int64_t, std::string_view>>& timed,
                              std::vector<std::string_view>& plain, bool& any_text) -> bool {
    if (scan.tag_only || scan.dropped) {
        return true;
    }
    if (scan.stamp_count > 0) {
        const std::string_view line_text = strip_word_stamps(arena, trim(scan.rest, " \t"));
        if (!line_text.empty()) {
            any_text = true;
        }
        for (std::size_t index = 0; index < scan.stamp_count; ++index) {
            if (timed.size() == lyrics::max_lines) {
                return false;
            }
            timed.emplace_back(scan.stamps[index], line_text);
        }
        return true;
    }
    if (!row.empty()) {
        any_text = true;
    }
    if (plain.size() == lyrics::max_lines) {
        return false;
    }
    plain.push_back(row);
    return true;
}

[[nodiscard]] auto build_synced(std::vector<std::pair<std::int64_t, std::string_view>>& timed,
                                std::int64_t offset_ms) -> lyrics::Content {
    std::ranges::stable_sort(
        timed, [](const auto& first, const auto& second) { return first.first < second.first; });
    lyrics::Content content;
    content.kind = lyrics::Kind::synced;
    content.offset_ms = offset_ms;
    ORCA_ASSERT(content.lines.empty());
    for (const auto& [stamp, line_text] : timed) {
        std::int64_t adjusted = 0;
        if (__builtin_sub_overflow(stamp, offset_ms, &adjusted)) {
            adjusted = offset_ms > 0 ? std::numeric_limits<std::int64_t>::min()
                                     : std::numeric_limits<std::int64_t>::max();
        }
        const std::int64_t clamped =
            std::clamp<std::int64_t>(adjusted, 0, std::numeric_limits<std::uint32_t>::max());
        content.lines.push_back(
            lyrics::Line{.start_ms = static_cast<std::uint32_t>(clamped), .text = line_text});
    }
    return content;
}

[[nodiscard]] auto build_plain(Arena& arena, const std::vector<std::string_view>& plain,
                               std::int64_t offset_ms) -> lyrics::Content {
    std::size_t first = 0;
    std::size_t last = plain.size();
    while (first < last && plain[first].empty()) {
        ++first;
    }
    while (last > first && plain[last - 1].empty()) {
        --last;
    }
    lyrics::Content content;
    content.kind = lyrics::Kind::plain;
    content.offset_ms = offset_ms;
    for (std::size_t index = first; index < last; ++index) {
        content.lines.push_back(
            lyrics::Line{.start_ms = std::nullopt, .text = arena.store(plain[index])});
    }
    return content;
}

auto parse(Arena& arena, std::string_view input) -> expected<std::optional<lyrics::Content>> {
    if (input.size() > lyrics::max_text_bytes) {
        return std::optional<lyrics::Content>{};
    }
    std::string_view text = input;
    if (text.starts_with("\xef\xbb\xbf")) {
        text.remove_prefix(3);
    }
    if (!utf8_valid(text)) {
        return std::optional<lyrics::Content>{};
    }

    std::vector<std::pair<std::int64_t, std::string_view>> timed;
    std::vector<std::string_view> plain;
    std::int64_t offset_ms = 0;
    bool any_text = false;

    std::size_t start = 0;
    while (start <= text.size()) {
        ORCA_ASSERT(start <= text.size());
        const auto newline = text.find('\n', start);
        const std::string_view raw = newline == std::string_view::npos
                                         ? text.substr(start)
                                         : text.substr(start, newline - start);
        const std::string_view row = trim(raw, " \t\r");

        if (row.empty() || row.front() != '#') {
            const RowScan scan = scan_row(row, offset_ms);
            if (scan.overflow) {
                return std::optional<lyrics::Content>{};
            }
            if (!append_row(arena, row, scan, timed, plain, any_text)) {
                return std::optional<lyrics::Content>{};
            }
        }

        if (newline == std::string_view::npos) {
            break;
        }
        start = newline + 1;
    }

    if (!any_text) {
        return std::optional<lyrics::Content>{};
    }
    if (!timed.empty()) {
        return std::optional<lyrics::Content>(build_synced(timed, offset_ms));
    }
    return std::optional<lyrics::Content>(build_plain(arena, plain, offset_ms));
}

}
