#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/model.hpp"
#include "liborca/storage/content_hash.hpp"
#include "liborca/storage/quick_hash.hpp"

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace orca::metadata::mutation {

struct FileIdentity {
    std::uint64_t size_bytes = 0;
    std::int64_t modified_ns = 0;
    storage::quick_hash::Digest quick_hash{};
    std::optional<storage::content_hash::Digest> content_hash = std::nullopt;

    [[nodiscard]] auto eql(const FileIdentity& other) const -> bool;
};

using Field = orca::metadata::Field;

struct Change {
    Field field = Field::title;
    std::optional<std::string> before = std::nullopt;
    std::optional<std::string> after = std::nullopt;
};

struct GenreChange {
    std::vector<std::string> before;
    std::vector<std::string> after;
};

struct WriteTags {
    std::string path;
    FileIdentity expected;
    std::vector<Change> changes;
    std::optional<GenreChange> genres = std::nullopt;
};

struct Move {
    std::string source_path;
    std::string destination_path;
    FileIdentity expected;
};

using Action = std::variant<WriteTags, Move>;

enum class State : std::uint8_t {
    draft,
    approved,
    executing,
    completed,
    failed,
};

struct Preview {
    std::size_t tag_writes = 0;
    std::size_t moves = 0;
    std::size_t field_changes = 0;
};

using Digest = storage::quick_hash::Digest;

struct Approval {
    std::uint64_t plan_id = 0;
    Digest digest{};
};

class Plan {
public:
    Plan() = default;

    [[nodiscard]] static auto init(std::uint64_t id, std::vector<Action> actions) -> expected<Plan>;

    [[nodiscard]] auto id() const -> std::uint64_t {
        return id_;
    }
    [[nodiscard]] auto state() const -> State {
        return state_;
    }
    [[nodiscard]] auto actions() const -> const std::vector<Action>& {
        return actions_;
    }
    [[nodiscard]] auto sealed_digest() const -> const Digest& {
        return sealed_digest_;
    }

    [[nodiscard]] auto preview() const -> Preview;
    [[nodiscard]] auto approval() const -> Approval;
    [[nodiscard]] auto approve(const Approval& confirmed) -> expected<void>;
    [[nodiscard]] auto begin_execution() -> expected<void>;
    [[nodiscard]] auto finish(bool success) -> expected<void>;

private:
    [[nodiscard]] auto verify_seal() const -> expected<void>;

    std::uint64_t id_ = 0;
    std::vector<Action> actions_;
    Digest sealed_digest_{};
    State state_ = State::draft;
};

[[nodiscard]] auto digest_of(std::uint64_t id, const std::vector<Action>& actions) -> Digest;

}
