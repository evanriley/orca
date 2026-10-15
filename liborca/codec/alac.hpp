#pragma once

#include "liborca/codec/engine.hpp"

#include <memory>
#include <span>

namespace orca::codec {

[[nodiscard]] auto open_alac_engine(std::span<const std::byte> config)
    -> expected<std::unique_ptr<Engine>>;

}
