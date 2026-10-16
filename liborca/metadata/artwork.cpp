#include "liborca/metadata/artwork.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/metadata/id3v2.hpp"
#include "liborca/metadata/mp4_tags.hpp"
#include "liborca/metadata/ogg_comment.hpp"
#include "liborca/metadata/riff_tags.hpp"
#include "liborca/metadata/vorbis_comment.hpp"
#include "liborca/storage/format.hpp"
#include "liborca/storage/source.hpp"

namespace orca::metadata::artwork {

namespace {

[[nodiscard]] auto picture_reader(storage::AudioFormat audio_format,
                                  const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>> {
    switch (audio_format) {
    case storage::AudioFormat::flac:
        return vorbis_comment::read_picture(source);
    case storage::AudioFormat::mp3:
    case storage::AudioFormat::aac:
        return id3v2::read_picture(source);
    case storage::AudioFormat::mp4:
        return mp4_tags::read_picture(source);
    case storage::AudioFormat::wav:
    case storage::AudioFormat::aiff:
        return riff_tags::read_picture(source);
    case storage::AudioFormat::opus:
    case storage::AudioFormat::vorbis:
        return ogg_comment::read_picture(source);
    case storage::AudioFormat::wavpack:
    case storage::AudioFormat::qoa:
        return std::optional<EmbeddedImage>{};
    }
    ORCA_ASSERT(false && "unhandled audio format");
    return std::optional<EmbeddedImage>{};
}

}

auto supports(storage::AudioFormat audio_format) -> bool {
    switch (audio_format) {
    case storage::AudioFormat::flac:
    case storage::AudioFormat::mp3:
    case storage::AudioFormat::aac:
    case storage::AudioFormat::mp4:
    case storage::AudioFormat::wav:
    case storage::AudioFormat::aiff:
    case storage::AudioFormat::opus:
    case storage::AudioFormat::vorbis:
        return true;
    case storage::AudioFormat::wavpack:
    case storage::AudioFormat::qoa:
        return false;
    }
    ORCA_ASSERT(false && "unhandled audio format");
    return false;
}

auto read_detected(storage::AudioFormat audio_format, const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>> {
    return picture_reader(audio_format, source);
}

auto read(const storage::ReadableSource& source) -> expected<std::optional<EmbeddedImage>> {
    const auto detection = storage::detect(source);
    if (!detection) {
        return std::unexpected(detection.error());
    }
    if (!*detection) {
        return std::optional<EmbeddedImage>{};
    }
    if ((*detection)->payload_offset == 0) {
        return read_detected((*detection)->format, source);
    }
    const storage::OffsetSource view(source, (*detection)->payload_offset);
    return read_detected((*detection)->format, view);
}

}
