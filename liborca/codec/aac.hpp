#pragma once

#include "liborca/codec/engine.hpp"

#include <memory>
#include <span>

namespace orca::codec {

[[nodiscard]] auto open_aac_engine(std::span<const std::byte> config,
                                   std::span<const std::byte> first_unit)
    -> expected<std::unique_ptr<Engine>>;

}
