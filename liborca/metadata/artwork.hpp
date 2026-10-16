#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/model.hpp"
#include "liborca/storage/format.hpp"
#include "liborca/storage/source.hpp"

#include <optional>

namespace orca::metadata::artwork {

[[nodiscard]] auto read(const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>>;

[[nodiscard]] auto supports(storage::AudioFormat audio_format) -> bool;

[[nodiscard]] auto read_detected(storage::AudioFormat audio_format,
                                 const storage::ReadableSource& source)
    -> expected<std::optional<EmbeddedImage>>;

}
