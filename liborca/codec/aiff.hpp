#pragma once

#include "liborca/codec/decoder.hpp"
#include "liborca/storage/source.hpp"

#include <memory>

namespace orca::codec {

[[nodiscard]] auto open_aiff(const storage::ReadableSource& source)
    -> expected<std::unique_ptr<Decoder>>;

}
