#pragma once

#include "liborca/codec/mp4.hpp"
#include "liborca/storage/source.hpp"

#include <memory>

namespace orca::codec {

[[nodiscard]] auto open_adts(const storage::ReadableSource& source)
    -> expected<std::unique_ptr<Decoder>>;
[[nodiscard]] auto probe_adts(const storage::ReadableSource& source) -> expected<Properties>;

}
