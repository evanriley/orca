#pragma once

#include <array>
#include <string_view>

namespace orca::codec::codec_id {

inline constexpr std::string_view pcm = "pcm";
inline constexpr std::string_view pcm_float = "pcm_float";
inline constexpr std::string_view flac = "flac";
inline constexpr std::string_view qoa = "qoa";
inline constexpr std::string_view mp1 = "mp1";
inline constexpr std::string_view mp2 = "mp2";
inline constexpr std::string_view mp3 = "mp3";
inline constexpr std::string_view alac = "alac";
inline constexpr std::string_view aac = "aac";
inline constexpr std::string_view opus = "opus";
inline constexpr std::string_view vorbis = "vorbis";

inline constexpr std::array<std::string_view, 4> lossless = {pcm, pcm_float, flac, alac};

[[nodiscard]] inline auto is_lossless(std::string_view identifier) -> bool {
    for (const std::string_view candidate : lossless) {
        if (identifier == candidate) {
            return true;
        }
    }
    return false;
}

}
