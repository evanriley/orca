#include "liborca/metadata/genre_alias.hpp"

#include "liborca/base/logging.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <utility>

namespace orca::metadata::genre_alias {

namespace {

constexpr std::string_view whitespace = " \t\r\n";
constexpr std::string_view list_separators = ",;";

constexpr std::array<std::string_view, 1> unsplit_names = {"Folk, World, & Country"};

[[nodiscard]] auto is_space(std::uint32_t point) -> bool {
    if (point == ' ' || point == '\t' || point == '\r' || point == '\n' || point == 0x0bU ||
        point == 0x0cU || point == 0x85U || point == 0xa0U || point == 0x1680U ||
        point == 0x3000U) {
        return true;
    }
    if (point >= 0x2000U && point <= 0x200aU) {
        return true;
    }
    return point == 0x2028U || point == 0x2029U || point == 0x202fU || point == 0x205fU;
}

[[nodiscard]] auto fold_point(std::uint32_t point) -> std::uint32_t {
    if (point >= 'A' && point <= 'Z') {
        return point + 32U;
    }
    if ((point >= 0x2010U && point <= 0x2015U) || point == 0x2212U) {
        return '-';
    }
    if ((point >= 0x2018U && point <= 0x201bU) || point == 0x2032U) {
        return '\'';
    }
    if ((point >= 0x201cU && point <= 0x201fU) || point == 0x2033U) {
        return '"';
    }
    if (point >= 0xff21U && point <= 0xff3aU) {
        return point - 0xfee0U + 32U;
    }
    if ((point >= 0xff01U && point <= 0xff20U) || (point >= 0xff3bU && point <= 0xff5eU)) {
        return point - 0xfee0U;
    }
    if ((point >= 0xc0U && point <= 0xd6U) || (point >= 0xd8U && point <= 0xdeU)) {
        return point + 32U;
    }
    if ((point >= 0x100U && point <= 0x137U) || (point >= 0x14aU && point <= 0x177U)) {
        return point % 2U == 0U ? point + 1U : point;
    }
    if ((point >= 0x139U && point <= 0x148U) || (point >= 0x179U && point <= 0x17eU)) {
        return point % 2U == 1U ? point + 1U : point;
    }
    if (point == 0x178U) {
        return 0xffU;
    }
    if ((point >= 0x391U && point <= 0x3a1U) || (point >= 0x3a3U && point <= 0x3abU)) {
        return point + 32U;
    }
    if (point >= 0x400U && point <= 0x40fU) {
        return point + 80U;
    }
    if (point >= 0x410U && point <= 0x42fU) {
        return point + 32U;
    }
    return point;
}

[[nodiscard]] auto decode_utf8(std::string_view text, std::size_t& index)
    -> std::optional<std::uint32_t> {
    ORCA_ASSERT(index < text.size());
    const auto first = static_cast<unsigned char>(text[index]);
    std::size_t length = 0;
    std::uint32_t point = 0;
    if (first < 0x80U) {
        point = first;
        length = 1;
    } else {
        if ((first & 0xe0U) == 0xc0U) {
            point = first & 0x1fU;
            length = 2;
        } else {
            if ((first & 0xf0U) == 0xe0U) {
                point = first & 0x0fU;
                length = 3;
            } else {
                if ((first & 0xf8U) == 0xf0U) {
                    point = first & 0x07U;
                    length = 4;
                } else {
                    index += 1;
                    return std::nullopt;
                }
            }
        }
    }
    if (index + length > text.size()) {
        index = text.size();
        return std::nullopt;
    }
    for (std::size_t offset = 1; offset < length; ++offset) {
        const auto byte = static_cast<unsigned char>(text[index + offset]);
        if ((byte & 0xc0U) != 0x80U) {
            index += 1;
            return std::nullopt;
        }
        point = (point << 6U) | (byte & 0x3fU);
    }
    index += length;
    return point;
}

void encode_utf8(std::string& out, std::uint32_t point) {
    ORCA_ASSERT(point <= 0x10ffffU);
    if (point < 0x80U) {
        out.push_back(static_cast<char>(point));
    } else {
        if (point < 0x800U) {
            out.push_back(static_cast<char>(0xc0U | (point >> 6U)));
            out.push_back(static_cast<char>(0x80U | (point & 0x3fU)));
        } else {
            if (point < 0x10000U) {
                out.push_back(static_cast<char>(0xe0U | (point >> 12U)));
                out.push_back(static_cast<char>(0x80U | ((point >> 6U) & 0x3fU)));
                out.push_back(static_cast<char>(0x80U | (point & 0x3fU)));
            } else {
                out.push_back(static_cast<char>(0xf0U | (point >> 18U)));
                out.push_back(static_cast<char>(0x80U | ((point >> 12U) & 0x3fU)));
                out.push_back(static_cast<char>(0x80U | ((point >> 6U) & 0x3fU)));
                out.push_back(static_cast<char>(0x80U | (point & 0x3fU)));
            }
        }
    }
}

[[nodiscard]] auto normalize_key(std::string_view text) -> std::string {
    std::string out;
    bool pending_space = false;
    bool wrote = false;
    std::size_t index = 0;
    while (index < text.size()) {
        const auto point = decode_utf8(text, index);
        if (!point) {
            continue;
        }
        if (is_space(*point)) {
            pending_space = wrote;
            continue;
        }
        if (pending_space) {
            out.push_back(' ');
            pending_space = false;
        }
        encode_utf8(out, fold_point(*point));
        wrote = true;
    }
    return out;
}

[[nodiscard]] auto is_separator(char byte) -> bool {
    return byte == ' ' || byte == '-' || byte == '_' || byte == '.' || byte == '/' || byte == '\'';
}

[[nodiscard]] auto starts_with_ignore_case(std::string_view text, std::string_view prefix) -> bool {
    if (text.size() < prefix.size()) {
        return false;
    }
    for (std::size_t index = 0; index < prefix.size(); ++index) {
        const auto lower = [](char value) {
            return value >= 'A' && value <= 'Z' ? static_cast<char>(value - 'A' + 'a') : value;
        };
        if (lower(text[index]) != lower(prefix[index])) {
            return false;
        }
    }
    return true;
}

[[nodiscard]] auto unsplit_name_length(std::string_view text) -> std::optional<std::size_t> {
    for (const std::string_view name : unsplit_names) {
        if (!starts_with_ignore_case(text, name)) {
            continue;
        }
        std::string_view after = text.substr(name.size());
        while (!after.empty() && whitespace.find(after.front()) != std::string_view::npos) {
            after.remove_prefix(1);
        }
        if (after.empty() || list_separators.find(after.front()) != std::string_view::npos) {
            return name.size();
        }
    }
    return std::nullopt;
}

[[nodiscard]] auto trim(std::string_view text) -> std::string_view {
    while (!text.empty() && whitespace.find(text.front()) != std::string_view::npos) {
        text.remove_prefix(1);
    }
    while (!text.empty() && whitespace.find(text.back()) != std::string_view::npos) {
        text.remove_suffix(1);
    }
    return text;
}

const std::pair<std::string_view, std::string_view> alias_data[] = {
    {"2step", "2-Step"},
    {"acidjazz", "Acid Jazz"},
    {"afrobeat", "Afrobeat"},
    {"altcountry", "Alternative Country"},
    {"alternativecountry", "Alternative Country"},
    {"althiphop", "Alternative Hip Hop"},
    {"alternativehiphop", "Alternative Hip Hop"},
    {"altrap", "Alternative Hip Hop"},
    {"altr&b", "Alternative R&B"},
    {"altrnb", "Alternative R&B"},
    {"alternativer&b", "Alternative R&B"},
    {"alternativernb", "Alternative R&B"},
    {"alternative", "Alternative Rock"},
    {"altrock", "Alternative Rock"},
    {"alternativerock", "Alternative Rock"},
    {"artpop", "Art Pop"},
    {"artrock", "Art Rock"},
    {"audiobook", "Audiobook"},
    {"audiobooks", "Audiobook"},
    {"avantgarde", "Avant-Garde"},
    {"bigband", "Big Band"},
    {"blackmetal", "Black Metal"},
    {"bluesrock", "Blues Rock"},
    {"bossanova", "Bossa Nova"},
    {"chillout", "Chillout"},
    {"childrens", "Children's Music"},
    {"childrensmusic", "Children's Music"},
    {"christmas", "Christmas"},
    {"christmasmusic", "Christmas"},
    {"xmas", "Christmas"},
    {"classicrock", "Classic Rock"},
    {"cloudrap", "Cloud Rap"},
    {"contemporaryr&b", "Contemporary R&B"},
    {"contemporaryrnb", "Contemporary R&B"},
    {"dancepop", "Dance-Pop"},
    {"deathmetal", "Death Metal"},
    {"deephouse", "Deep House"},
    {"doowop", "Doo-Wop"},
    {"dreampop", "Dream Pop"},
    {"drumandbass", "Drum and Bass"},
    {"drum&bass", "Drum and Bass"},
    {"drumnbass", "Drum and Bass"},
    {"dnb", "Drum and Bass"},
    {"d&b", "Drum and Bass"},
    {"easylistening", "Easy Listening"},
    {"eastcoasthiphop", "East Coast Hip Hop"},
    {"edm", "EDM"},
    {"electronicdancemusic", "EDM"},
    {"electropop", "Electropop"},
    {"folk,world,&country", "Folk, World, & Country"},
    {"folkrock", "Folk Rock"},
    {"garagerock", "Garage Rock"},
    {"hardrock", "Hard Rock"},
    {"hardcorepunk", "Hardcore Punk"},
    {"heavymetal", "Heavy Metal"},
    {"hiphop", "Hip Hop"},
    {"hiphoprap", "Hip Hop"},
    {"raphiphop", "Hip Hop"},
    {"rap&hiphop", "Hip Hop"},
    {"hiphop&rap", "Hip Hop"},
    {"indiefolk", "Indie Folk"},
    {"indiepop", "Indie Pop"},
    {"indierock", "Indie Rock"},
    {"jpop", "J-Pop"},
    {"jrock", "J-Rock"},
    {"jazzfusion", "Jazz Fusion"},
    {"kpop", "K-Pop"},
    {"lofi", "Lo-Fi"},
    {"mathrock", "Math Rock"},
    {"neosoul", "Neo Soul"},
    {"newage", "New Age"},
    {"newwave", "New Wave"},
    {"noiserock", "Noise Rock"},
    {"numetal", "Nu Metal"},
    {"poppunk", "Pop Punk"},
    {"poprap", "Pop Rap"},
    {"poprock", "Pop Rock"},
    {"posthardcore", "Post-Hardcore"},
    {"postpunk", "Post-Punk"},
    {"postpunkrevival", "Post-Punk Revival"},
    {"postrock", "Post-Rock"},
    {"progrock", "Progressive Rock"},
    {"progressiverock", "Progressive Rock"},
    {"progmetal", "Progressive Metal"},
    {"progressivemetal", "Progressive Metal"},
    {"psychrock", "Psychedelic Rock"},
    {"psychedelicrock", "Psychedelic Rock"},
    {"punkrock", "Punk Rock"},
    {"r&b", "R&B"},
    {"rnb", "R&B"},
    {"randb", "R&B"},
    {"rhythmandblues", "R&B"},
    {"rhythm&blues", "R&B"},
    {"rockandroll", "Rock and Roll"},
    {"rock&roll", "Rock and Roll"},
    {"rocknroll", "Rock and Roll"},
    {"shoegaze", "Shoegaze"},
    {"shoegazing", "Shoegaze"},
    {"singersongwriter", "Singer-Songwriter"},
    {"skapunk", "Ska Punk"},
    {"smoothjazz", "Smooth Jazz"},
    {"softrock", "Soft Rock"},
    {"soundtrack", "Soundtrack"},
    {"soundtracks", "Soundtrack"},
    {"ost", "Soundtrack"},
    {"originalsoundtrack", "Soundtrack"},
    {"spokenword", "Spoken Word"},
    {"synthpop", "Synth-Pop"},
    {"techhouse", "Tech House"},
    {"triphop", "Trip Hop"},
    {"ukgarage", "UK Garage"},
    {"westcoasthiphop", "West Coast Hip Hop"},
    {"world", "World"},
    {"worldmusic", "World"},
};

const std::vector<std::pair<std::string_view, std::string_view>>& alias_table() {
    static const std::vector<std::pair<std::string_view, std::string_view>> table(
        alias_data, alias_data + (sizeof(alias_data) / sizeof(alias_data[0])));
    return table;
}

[[nodiscard]] auto find_alias(std::string_view key) -> std::optional<std::string_view> {
    for (const auto& [candidate, canonical] : alias_table()) {
        if (candidate == key) {
            return canonical;
        }
    }
    return std::nullopt;
}

}

auto search_key(std::string_view text) -> std::string {
    const std::string normalized = normalize_key(text);
    std::string out;
    out.reserve(normalized.size());
    for (const char byte : normalized) {
        if (is_separator(byte)) {
            continue;
        }
        out.push_back(byte);
    }
    return out;
}

auto fold(std::string_view value) -> Folded {
    const std::string_view trimmed = trim(value);
    std::string compact = search_key(trimmed);
    if (compact.empty()) {
        return Folded{.key = std::move(compact), .name = {}};
    }
    const auto canonical = find_alias(compact);
    if (!canonical) {
        return Folded{.key = std::move(compact), .name = trimmed};
    }
    return Folded{.key = search_key(*canonical), .name = *canonical};
}

auto Parts::next() -> std::string_view {
    while (true) {
        while (!rest_.empty() && whitespace.find(rest_.front()) != std::string_view::npos) {
            rest_.remove_prefix(1);
        }
        if (rest_.empty()) {
            return {};
        }
        if (const auto length = unsplit_name_length(rest_)) {
            const std::string_view value = rest_.substr(0, *length);
            rest_.remove_prefix(*length);
            return value;
        }
        const auto separator = rest_.find_first_of(list_separators);
        const std::size_t end = separator == std::string_view::npos ? rest_.size() : separator;
        std::string_view part = rest_.substr(0, end);
        while (!part.empty() && whitespace.find(part.back()) != std::string_view::npos) {
            part.remove_suffix(1);
        }
        rest_.remove_prefix(std::min(end + 1, rest_.size()));
        if (!part.empty()) {
            return part;
        }
    }
}

auto parts(std::string_view value) -> Parts {
    return Parts(value);
}

auto fold_all(const std::vector<std::string_view>& values) -> std::vector<Folded> {
    std::vector<Folded> genres;
    for (const std::string_view value : values) {
        Parts iterator(value);
        while (true) {
            const std::string_view part = iterator.next();
            if (part.empty()) {
                break;
            }
            Folded genre = fold(part);
            if (genre.key.empty()) {
                continue;
            }
            const bool exists =
                std::any_of(genres.begin(), genres.end(),
                            [&genre](const Folded& existing) { return existing.key == genre.key; });
            if (exists) {
                continue;
            }
            genres.push_back(std::move(genre));
        }
    }
    return genres;
}

auto all_aliases() -> const std::vector<std::pair<std::string_view, std::string_view>>& {
    return alias_table();
}

}
