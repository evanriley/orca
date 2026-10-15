#include "liborca/base/string.hpp"
#include "liborca/crypto/blake3.hpp"
#include "liborca/crypto/secure_zero.hpp"
#include "liborca/crypto/sha256.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <doctest/doctest.h>
#include <span>
#include <string>
#include <vector>

namespace {

auto pattern_bytes(std::size_t length) -> std::vector<std::byte> {
    std::vector<std::byte> bytes(length);
    for (std::size_t index = 0; index < length; ++index) {
        bytes[index] = static_cast<std::byte>(index % 251);
    }
    return bytes;
}

auto hex_of(const orca::crypto::digest256& digest) -> std::string {
    return orca::strings::hex_encode(std::as_bytes(std::span(digest)));
}

}

TEST_CASE("blake3 matches the official test vectors") {
    CHECK(hex_of(orca::crypto::blake3(std::span<const std::byte>())) ==
          "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262");

    const std::array<std::byte, 1> one{std::byte{0x00}};
    CHECK(hex_of(orca::crypto::blake3(one)) ==
          "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213");

    const std::vector<std::byte> length_1023 = pattern_bytes(1023);
    CHECK(hex_of(orca::crypto::blake3(length_1023)) ==
          "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11");

    const std::vector<std::byte> length_1024 = pattern_bytes(1024);
    CHECK(hex_of(orca::crypto::blake3(length_1024)) ==
          "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7");

    const std::vector<std::byte> length_2048 = pattern_bytes(2048);
    CHECK(hex_of(orca::crypto::blake3(length_2048)) ==
          "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a");
}

TEST_CASE("blake3 streaming matches one-shot") {
    const std::vector<std::byte> input = pattern_bytes(4096);
    orca::crypto::Blake3 streaming;
    streaming.update(std::span<const std::byte>(input.data(), 100));
    streaming.update(std::span<const std::byte>(input.data() + 100, input.size() - 100));
    CHECK(hex_of(streaming.finalize()) == hex_of(orca::crypto::blake3(input)));
}

TEST_CASE("sha256 matches the official test vectors") {
    CHECK(orca::crypto::sha256("").size() == 32);
    CHECK(orca::crypto::Sha256{}.finalize_hex() ==
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    orca::crypto::Sha256 abc;
    abc.update("abc");
    CHECK(abc.finalize_hex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    orca::crypto::Sha256 long_message;
    long_message.update("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    CHECK(long_message.finalize_hex() ==
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

    orca::crypto::Sha256 million_a;
    const std::string chunk(1000, 'a');
    for (int index = 0; index < 1000; ++index) {
        million_a.update(chunk);
    }
    CHECK(million_a.finalize_hex() ==
          "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

TEST_CASE("secure_zero clears a buffer") {
    std::array<std::byte, 16> bytes{};
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        bytes[index] = static_cast<std::byte>(index + 1);
    }
    orca::crypto::secure_zero(std::span<std::byte>(bytes));
    for (const std::byte byte : bytes) {
        CHECK(byte == std::byte{0});
    }
}
