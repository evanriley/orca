#include "liborca/metadata/id3v1.hpp"

#include "liborca/base/logging.hpp"

#include <cstring>

namespace orca::metadata::id3v1 {

namespace {

[[nodiscard]] auto trim(std::span<const std::byte> bytes) -> std::string_view {
    std::size_t size = bytes.size();
    while (size > 0) {
        const auto byte = bytes[size - 1];
        if (byte != std::byte{' '} && byte != std::byte{0}) {
            break;
        }
        --size;
    }
    return {reinterpret_cast<const char*>(bytes.data()), size};
}

[[nodiscard]] auto write_field(std::span<std::byte> destination, std::string_view value)
    -> expected<void> {
    if (value.size() > destination.size()) {
        return fail(ErrorCode::invalid_argument, "id3v1: field too long");
    }
    ORCA_ASSERT(value.size() <= destination.size());
    for (const char byte : value) {
        if (static_cast<unsigned char>(byte) >= 0x80U) {
            return fail(ErrorCode::invalid_argument, "id3v1: field requires ASCII");
        }
    }
    std::memcpy(destination.data(), value.data(), value.size());
    return {};
}

constexpr std::array<std::string_view, 192> genre_names = {
    "Blues",
    "Classic Rock",
    "Country",
    "Dance",
    "Disco",
    "Funk",
    "Grunge",
    "Hip-Hop",
    "Jazz",
    "Metal",
    "New Age",
    "Oldies",
    "Other",
    "Pop",
    "R&B",
    "Rap",
    "Reggae",
    "Rock",
    "Techno",
    "Industrial",
    "Alternative",
    "Ska",
    "Death Metal",
    "Pranks",
    "Soundtrack",
    "Euro-Techno",
    "Ambient",
    "Trip-Hop",
    "Vocal",
    "Jazz+Funk",
    "Fusion",
    "Trance",
    "Classical",
    "Instrumental",
    "Acid",
    "House",
    "Game",
    "Sound Clip",
    "Gospel",
    "Noise",
    "Alternative Rock",
    "Bass",
    "Soul",
    "Punk",
    "Space",
    "Meditative",
    "Instrumental Pop",
    "Instrumental Rock",
    "Ethnic",
    "Gothic",
    "Darkwave",
    "Techno-Industrial",
    "Electronic",
    "Pop-Folk",
    "Eurodance",
    "Dream",
    "Southern Rock",
    "Comedy",
    "Cult",
    "Gangsta",
    "Top 40",
    "Christian Rap",
    "Pop/Funk",
    "Jungle",
    "Native US",
    "Cabaret",
    "New Wave",
    "Psychedelic",
    "Rave",
    "Showtunes",
    "Trailer",
    "Lo-Fi",
    "Tribal",
    "Acid Punk",
    "Acid Jazz",
    "Polka",
    "Retro",
    "Musical",
    "Rock & Roll",
    "Hard Rock",
    "Folk",
    "Folk-Rock",
    "National Folk",
    "Swing",
    "Fast Fusion",
    "Bebop",
    "Latin",
    "Revival",
    "Celtic",
    "Bluegrass",
    "Avantgarde",
    "Gothic Rock",
    "Progressive Rock",
    "Psychedelic Rock",
    "Symphonic Rock",
    "Slow Rock",
    "Big Band",
    "Chorus",
    "Easy Listening",
    "Acoustic",
    "Humour",
    "Speech",
    "Chanson",
    "Opera",
    "Chamber Music",
    "Sonata",
    "Symphony",
    "Booty Bass",
    "Primus",
    "Porn Groove",
    "Satire",
    "Slow Jam",
    "Club",
    "Tango",
    "Samba",
    "Folklore",
    "Ballad",
    "Power Ballad",
    "Rhythmic Soul",
    "Freestyle",
    "Duet",
    "Punk Rock",
    "Drum Solo",
    "A Cappella",
    "Euro-House",
    "Dance Hall",
    "Goa",
    "Drum & Bass",
    "Club-House",
    "Hardcore",
    "Terror",
    "Indie",
    "BritPop",
    "Negerpunk",
    "Polsk Punk",
    "Beat",
    "Christian Gangsta Rap",
    "Heavy Metal",
    "Black Metal",
    "Crossover",
    "Contemporary Christian",
    "Christian Rock",
    "Merengue",
    "Salsa",
    "Thrash Metal",
    "Anime",
    "Jpop",
    "Synthpop",
    "Abstract",
    "Art Rock",
    "Baroque",
    "Bhangra",
    "Big Beat",
    "Breakbeat",
    "Chillout",
    "Downtempo",
    "Dub",
    "EBM",
    "Eclectic",
    "Electro",
    "Electroclash",
    "Emo",
    "Experimental",
    "Garage",
    "Global",
    "IDM",
    "Illbient",
    "Industro-Goth",
    "Jam Band",
    "Krautrock",
    "Leftfield",
    "Lounge",
    "Math Rock",
    "New Romantic",
    "Nu-Breakz",
    "Post-Punk",
    "Post-Rock",
    "Psytrance",
    "Shoegaze",
    "Space Rock",
    "Trop Rock",
    "World Music",
    "Neoclassical",
    "Audiobook",
    "Audio Theatre",
    "Neue Deutsche Welle",
    "Podcast",
    "Indie Rock",
    "G-Funk",
    "Dubstep",
    "Garage Rock",
    "Psybient",
};

}

auto read(const storage::ReadableSource& source, std::array<std::byte, 128>& buffer)
    -> expected<std::optional<Tag>> {
    if (source.size() < buffer.size()) {
        return std::optional<Tag>{};
    }
    ORCA_ASSERT(source.size() >= buffer.size());
    const auto read_count = source.read_at(source.size() - buffer.size(), buffer);
    if (!read_count) {
        return std::unexpected(read_count.error());
    }
    if (*read_count != buffer.size()) {
        return std::optional<Tag>{};
    }
    return parse(buffer);
}

auto parse(const std::array<std::byte, 128>& bytes) -> std::optional<Tag> {
    if (std::memcmp(bytes.data(), "TAG", 3) != 0) {
        return std::nullopt;
    }
    const bool is_v11 = bytes[125] == std::byte{0} && bytes[126] != std::byte{0};
    const auto comment_end = is_v11 ? 125U : 127U;
    return Tag{
        .title = trim(std::span<const std::byte>(bytes.data() + 3, 30)),
        .artist = trim(std::span<const std::byte>(bytes.data() + 33, 30)),
        .album = trim(std::span<const std::byte>(bytes.data() + 63, 30)),
        .year = trim(std::span<const std::byte>(bytes.data() + 93, 4)),
        .comment = trim(std::span<const std::byte>(bytes.data() + 97, comment_end - 97)),
        .track_number = is_v11
                            ? std::optional<std::uint8_t>(std::to_integer<std::uint8_t>(bytes[126]))
                            : std::nullopt,
        .genre = std::to_integer<std::uint8_t>(bytes[127]),
    };
}

auto encode(const Tag& tag) -> expected<std::array<std::byte, 128>> {
    std::array<std::byte, 128> bytes{};
    std::memcpy(bytes.data(), "TAG", 3);
    const auto title = write_field(std::span<std::byte>(bytes.data() + 3, 30), tag.title);
    if (!title) {
        return std::unexpected(title.error());
    }
    const auto artist = write_field(std::span<std::byte>(bytes.data() + 33, 30), tag.artist);
    if (!artist) {
        return std::unexpected(artist.error());
    }
    const auto album = write_field(std::span<std::byte>(bytes.data() + 63, 30), tag.album);
    if (!album) {
        return std::unexpected(album.error());
    }
    const auto year = write_field(std::span<std::byte>(bytes.data() + 93, 4), tag.year);
    if (!year) {
        return std::unexpected(year.error());
    }
    if (tag.track_number) {
        if (*tag.track_number == 0) {
            return fail(ErrorCode::invalid_argument, "id3v1: invalid track number");
        }
        const auto comment = write_field(std::span<std::byte>(bytes.data() + 97, 28), tag.comment);
        if (!comment) {
            return std::unexpected(comment.error());
        }
        bytes[125] = std::byte{0};
        bytes[126] = static_cast<std::byte>(*tag.track_number);
    } else {
        const auto comment = write_field(std::span<std::byte>(bytes.data() + 97, 30), tag.comment);
        if (!comment) {
            return std::unexpected(comment.error());
        }
    }
    bytes[127] = static_cast<std::byte>(tag.genre);
    return bytes;
}

auto latin1_to_utf8(std::span<const std::byte> bytes) -> std::string {
    std::string out;
    out.reserve(bytes.size());
    for (const std::byte byte : bytes) {
        const auto value = std::to_integer<std::uint8_t>(byte);
        if (value < 0x80U) {
            out.push_back(static_cast<char>(value));
        } else {
            out.push_back(static_cast<char>(0xc0U | (value >> 6U)));
            out.push_back(static_cast<char>(0x80U | (value & 0x3fU)));
        }
    }
    return out;
}

auto genre_name(std::uint8_t code) -> std::optional<std::string_view> {
    if (code >= genre_names.size()) {
        return std::nullopt;
    }
    return genre_names[code];
}

}
