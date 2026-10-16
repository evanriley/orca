#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace orca::metadata::genre_alias {

struct Folded {
    std::string key;
    std::string_view name;
};

[[nodiscard]] auto fold(std::string_view value) -> Folded;

class Parts {
public:
    explicit Parts(std::string_view value) : rest_(value) {}
    [[nodiscard]] auto next() -> std::string_view;

private:
    std::string_view rest_;
};

[[nodiscard]] auto parts(std::string_view value) -> Parts;

[[nodiscard]] auto fold_all(const std::vector<std::string_view>& values) -> std::vector<Folded>;

[[nodiscard]] auto search_key(std::string_view text) -> std::string;

[[nodiscard]] auto all_aliases()
    -> const std::vector<std::pair<std::string_view, std::string_view>>&;

}
