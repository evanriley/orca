#include "liborca/crypto/blake3.hpp"
#include "liborca/storage/content_hash.hpp"
#include "liborca/storage/format.hpp"
#include "liborca/storage/iso_bmff.hpp"
#include "liborca/storage/quick_hash.hpp"
#include "liborca/storage/source.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <doctest/doctest.h>
#include <filesystem>
#include <fstream>
#include <limits>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace {

template <std::size_t Size>
auto bytes_of(const char (&text)[Size]) -> std::vector<std::byte> {
    std::vector<std::byte> bytes(Size - 1);
    for (std::size_t index = 0; index + 1 < Size; ++index) {
        bytes[index] = static_cast<std::byte>(text[index]);
    }
    return bytes;
}

auto fixture(std::string_view name) -> std::filesystem::path {
    return std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" / name;
}

}

TEST_CASE("format sniffing prioritizes containers by magic bytes") {
    const auto flac = bytes_of("fLaCpayload");
    CHECK(orca::storage::sniff_bytes(flac) == std::optional(orca::storage::AudioFormat::flac));

    const auto wav = bytes_of("RIFFxxxxWAVEfmt ");
    CHECK(orca::storage::sniff_bytes(wav) == std::optional(orca::storage::AudioFormat::wav));

    const auto opus = bytes_of("OggSxxxxOpusHead");
    CHECK(orca::storage::sniff_bytes(opus) == std::optional(orca::storage::AudioFormat::opus));

    const std::array<std::byte, 8> qoa{std::byte{'q'}, std::byte{'o'}, std::byte{'a'},
                                       std::byte{'f'}, std::byte{0},   std::byte{0},
                                       std::byte{0},   std::byte{0x10}};
    CHECK(orca::storage::sniff_bytes(qoa) == std::optional(orca::storage::AudioFormat::qoa));

    const std::array<std::byte, 4> aac{std::byte{0xff}, std::byte{0xf1}, std::byte{0x4c},
                                       std::byte{0x80}};
    CHECK(orca::storage::sniff_bytes(aac) == std::optional(orca::storage::AudioFormat::aac));

    const std::array<std::byte, 4> mp3{std::byte{0xff}, std::byte{0xfb}, std::byte{0x90},
                                       std::byte{0x64}};
    CHECK(orca::storage::sniff_bytes(mp3) == std::optional(orca::storage::AudioFormat::mp3));

    CHECK_FALSE(orca::storage::sniff_bytes(bytes_of("not audio")).has_value());
}

TEST_CASE("an ID3v2 tag in front of a FLAC sniffs as FLAC rather than MPEG audio") {
    std::vector<std::byte> bytes(214, std::byte{0});
    const auto tag = bytes_of("ID3\x04\x00\x00\x00\x00\x01\x48");
    std::copy(tag.begin(), tag.end(), bytes.begin());
    const auto magic = bytes_of("fLaC");
    std::copy(magic.begin(), magic.end(), bytes.begin() + 210);

    CHECK(orca::storage::sniff_bytes(bytes) == std::optional(orca::storage::AudioFormat::flac));
}

TEST_CASE("an ID3v2 tag with a footer sniffs the payload after the footer") {
    std::vector<std::byte> bytes(224, std::byte{0});
    const auto tag = bytes_of("ID3\x04\x00\x10\x00\x00\x01\x48");
    std::copy(tag.begin(), tag.end(), bytes.begin());
    const auto footer = bytes_of("3DI\x04\x00\x10\x00\x00\x01\x48");
    std::copy(footer.begin(), footer.end(), bytes.begin() + 210);
    const auto magic = bytes_of("fLaC");
    std::copy(magic.begin(), magic.end(), bytes.begin() + 220);

    CHECK(orca::storage::sniff_bytes(bytes) == std::optional(orca::storage::AudioFormat::flac));
}

TEST_CASE("an ID3-tagged MPEG stream still sniffs as MPEG audio") {
    std::vector<std::byte> bytes(214, std::byte{0});
    const auto tag = bytes_of("ID3\x04\x00\x00\x00\x00\x01\x48");
    std::copy(tag.begin(), tag.end(), bytes.begin());
    bytes[210] = std::byte{0xff};
    bytes[211] = std::byte{0xfb};

    CHECK(orca::storage::sniff_bytes(bytes) == std::optional(orca::storage::AudioFormat::mp3));
}

TEST_CASE("a prefix too short to reach past an ID3v2 tag sniffs as MPEG audio") {
    std::vector<std::byte> bytes(64, std::byte{0});
    const auto tag = bytes_of("ID3\x04\x00\x00\x00\x02\x01\x48");
    std::copy(tag.begin(), tag.end(), bytes.begin());

    CHECK(orca::storage::sniff_bytes(bytes) == std::optional(orca::storage::AudioFormat::mp3));
}

TEST_CASE("detect resolves an ID3 prefix by offset and reports it") {
    std::vector<std::byte> bytes(214, std::byte{0});
    const auto tag = bytes_of("ID3\x04\x00\x00\x00\x00\x01\x48");
    std::copy(tag.begin(), tag.end(), bytes.begin());
    const auto magic = bytes_of("fLaC");
    std::copy(magic.begin(), magic.end(), bytes.begin() + 210);

    orca::storage::MemorySource source(bytes);
    const auto detected = orca::storage::detect(source);
    REQUIRE(detected.has_value());
    REQUIRE(detected->has_value());
    CHECK((*detected)->format == orca::storage::AudioFormat::flac);
    CHECK((*detected)->payload_offset == 210);
}

TEST_CASE("memory sources answer bounded reads past their end") {
    orca::storage::MemorySource memory("orca");
    std::array<std::byte, 8> buffer{};
    const auto read = memory.read_at(2, buffer);
    REQUIRE(read.has_value());
    CHECK(*read == 2);
    CHECK(std::string_view(reinterpret_cast<const char*>(buffer.data()), 2) == "ca");

    const auto past = memory.read_at(4, buffer);
    REQUIRE(past.has_value());
    CHECK(*past == 0);
    CHECK(memory.size() == 4);
}

TEST_CASE("an offset view reads a suffix while reporting the whole file identity") {
    orca::storage::MemorySource memory("ID3-tag-bytesfLaCstream", 77);
    const orca::storage::OffsetSource view(memory, 13);

    std::array<std::byte, 10> buffer{};
    const auto first = view.read_at(0, buffer);
    REQUIRE(first.has_value());
    CHECK(*first == 10);
    CHECK(std::string_view(reinterpret_cast<const char*>(buffer.data()), 10) == "fLaCstream");

    const auto second = view.read_at(4, buffer);
    REQUIRE(second.has_value());
    CHECK(*second == 6);
    CHECK(std::string_view(reinterpret_cast<const char*>(buffer.data()), 6) == "stream");
    CHECK(view.size() == 10);

    CHECK(view.identity().size == 23);
    CHECK(view.identity().inode == 77);
}

TEST_CASE("an offset view past the end of its source reads nothing") {
    orca::storage::MemorySource memory("short");
    const orca::storage::OffsetSource view(memory, 64);
    std::array<std::byte, 4> buffer{};

    const auto read = view.read_at(0, buffer);
    REQUIRE(read.has_value());
    CHECK(*read == 0);
    const auto far = view.read_at(std::numeric_limits<std::uint64_t>::max(), buffer);
    REQUIRE(far.has_value());
    CHECK(*far == 0);
    CHECK(view.size() == 0);
}

TEST_CASE("local files satisfy offset reads and identity capabilities") {
    const auto path = std::filesystem::temp_directory_path() / "orca-source-test.bin";
    {
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        output << "orca-source";
    }

    const auto source = orca::storage::LocalFileSource::open(path);
    REQUIRE(source.has_value());
    std::array<std::byte, 6> buffer{};
    const auto read = source->read_at(5, buffer);
    REQUIRE(read.has_value());
    CHECK(*read == 6);
    CHECK(std::string_view(reinterpret_cast<const char*>(buffer.data()), 6) == "source");
    CHECK(source->size() == 11);
    CHECK(source->size() == source->identity().size);

    std::filesystem::remove(path);
}

TEST_CASE("quick hashes separate same-size content") {
    orca::storage::MemorySource first("generated payload A");
    orca::storage::MemorySource second("generated payload B");
    const auto first_digest = orca::storage::quick_hash::from_source(first);
    const auto second_digest = orca::storage::quick_hash::from_source(second);
    REQUIRE(first_digest.has_value());
    REQUIRE(second_digest.has_value());
    CHECK(*first_digest != *second_digest);
}

TEST_CASE("quick hashes cover trailing bytes of a file larger than one window") {
    const std::size_t size = orca::storage::quick_hash::window_bytes + 4096;
    std::vector<std::byte> payload(size);
    for (std::size_t index = 0; index < size; ++index) {
        payload[index] = static_cast<std::byte>(index & 0xffU);
    }

    orca::storage::MemorySource before(payload);
    const auto before_digest = orca::storage::quick_hash::from_source(before);
    REQUIRE(before_digest.has_value());

    payload[size - 1] =
        static_cast<std::byte>((std::to_integer<unsigned>(payload[size - 1]) + 1U) & 0xffU);
    orca::storage::MemorySource after(payload);
    const auto after_digest = orca::storage::quick_hash::from_source(after);
    REQUIRE(after_digest.has_value());
    CHECK(*before_digest != *after_digest);
}

TEST_CASE("content hashes every byte and agrees with one-shot BLAKE3") {
    const std::size_t size = 2 * orca::storage::quick_hash::window_bytes + 4096;
    std::vector<std::byte> payload(size);
    for (std::size_t index = 0; index < size; ++index) {
        payload[index] = static_cast<std::byte>((index * 31U) & 0xffU);
    }

    orca::storage::MemorySource source(payload);
    const auto from_bytes =
        orca::crypto::blake3(std::span<const std::byte>(payload.data(), payload.size()));
    const auto hashed = orca::storage::content_hash::from_source(source);
    REQUIRE(hashed.has_value());
    CHECK(*hashed == from_bytes);

    orca::storage::quick_hash::Digest quick_before{};
    {
        const auto quick = orca::storage::quick_hash::from_source(source);
        REQUIRE(quick.has_value());
        quick_before = *quick;
    }

    payload[size / 2] =
        static_cast<std::byte>((std::to_integer<unsigned>(payload[size / 2]) + 1U) & 0xffU);
    orca::storage::MemorySource edited(payload);
    const auto quick_after = orca::storage::quick_hash::from_source(edited);
    REQUIRE(quick_after.has_value());
    CHECK(quick_before == *quick_after);

    const auto content_after = orca::storage::content_hash::from_source(edited);
    REQUIRE(content_after.has_value());
    CHECK(*content_after != *hashed);
}

TEST_CASE("iso bmff boxes iterate by declared size including 64-bit sizes") {
    std::vector<std::byte> bytes = bytes_of("\x00\x00\x00\x0c"
                                            "free"
                                            "\x01\x02\x03\x04");
    const auto extended = bytes_of("\x00\x00\x00\x01wide\x00\x00\x00\x00\x00\x00\x00\x12\xaa\xbb");
    bytes.insert(bytes.end(), extended.begin(), extended.end());

    orca::storage::iso_bmff::Iterator boxes(bytes);
    const auto first = boxes.next();
    REQUIRE(first.has_value());
    REQUIRE(first->has_value());
    CHECK((*first)->is("free"));
    CHECK(std::string_view(reinterpret_cast<const char*>((*first)->body.data()),
                           (*first)->body.size()) == "\x01\x02\x03\x04");

    const auto second = boxes.next();
    REQUIRE(second.has_value());
    REQUIRE(second->has_value());
    CHECK((*second)->is("wide"));
    CHECK((*second)->body.size() == 2);

    const auto end = boxes.next();
    REQUIRE(end.has_value());
    CHECK_FALSE(end->has_value());
}

TEST_CASE("an iso bmff box claiming more than its parent holds is invalid") {
    const auto bytes = bytes_of("\x00\x00\x00\x40"
                                "free"
                                "\x00");
    orca::storage::iso_bmff::Iterator boxes(bytes);
    const auto box = boxes.next();
    REQUIRE_FALSE(box.has_value());
    CHECK(box.error().code == orca::ErrorCode::parse);
}

TEST_CASE("the movie box is found behind media data without reading the media") {
    const auto source = orca::storage::LocalFileSource::open(fixture("tagged-reference-alac.m4a"));
    REQUIRE(source.has_value());
    const auto movie = orca::storage::iso_bmff::read_movie(*source);
    REQUIRE(movie.has_value());

    const std::array<std::string_view, 5> path{"trak", "mdia", "minf", "stbl", "stsd"};
    const auto box = orca::storage::iso_bmff::descend(*movie, path);
    REQUIRE(box.has_value());
    REQUIRE(box->has_value());
}

TEST_CASE("a file with no movie box is reported as such") {
    orca::storage::MemorySource source(bytes_of("\x00\x00\x00\x10"
                                                "ftypM4A "
                                                "\x00\x00\x02\x00"));
    const auto movie = orca::storage::iso_bmff::read_movie(source);
    REQUIRE_FALSE(movie.has_value());
    CHECK(movie.error().code == orca::ErrorCode::not_found);
}

TEST_CASE("a top-level box walking past the address space is invalid") {
    orca::storage::MemorySource source(bytes_of("\x00\x00\x00\x01"
                                                "free"
                                                "\xff\xff\xff\xff\xff\xff\xff\xfc"));
    const auto movie = orca::storage::iso_bmff::read_movie(source);
    REQUIRE_FALSE(movie.has_value());
    CHECK(movie.error().code == orca::ErrorCode::parse);
}

TEST_CASE("quick and content hashes agree between a source and its path") {
    const auto path = std::filesystem::temp_directory_path() / "orca-hash-path-test.bin";
    std::vector<std::byte> payload(orca::storage::quick_hash::window_bytes + 4096);
    for (std::size_t index = 0; index < payload.size(); ++index) {
        payload[index] = static_cast<std::byte>((index * 7U) & 0xffU);
    }
    {
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        output.write(reinterpret_cast<const char*>(payload.data()),
                     static_cast<std::streamsize>(payload.size()));
    }

    const auto source = orca::storage::LocalFileSource::open(path);
    REQUIRE(source.has_value());

    const auto quick_source = orca::storage::quick_hash::from_source(*source);
    const auto quick_path = orca::storage::quick_hash::from_path(path);
    REQUIRE(quick_source.has_value());
    REQUIRE(quick_path.has_value());
    CHECK(*quick_source == *quick_path);

    const auto content_source = orca::storage::content_hash::from_source(*source);
    const auto content_path = orca::storage::content_hash::from_path(path);
    REQUIRE(content_source.has_value());
    REQUIRE(content_path.has_value());
    CHECK(*content_source == *content_path);

    std::filesystem::remove(path);
}
