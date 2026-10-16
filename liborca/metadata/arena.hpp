#pragma once

#include <cstddef>
#include <deque>
#include <span>
#include <string>
#include <string_view>

namespace orca::metadata {

class Arena {
public:
    [[nodiscard]] auto store(std::string_view text) -> std::string_view {
        strings_.emplace_back(text);
        return strings_.back();
    }

    [[nodiscard]] auto store_bytes(std::span<const std::byte> bytes) -> std::string_view {
        strings_.emplace_back(reinterpret_cast<const char*>(bytes.data()), bytes.size());
        return strings_.back();
    }

private:
    std::deque<std::string> strings_;
};

}
