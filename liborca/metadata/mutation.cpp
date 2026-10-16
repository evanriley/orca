#include "liborca/metadata/mutation.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/crypto/blake3.hpp"

#include <array>
#include <cstddef>
#include <span>
#include <string_view>
#include <type_traits>
#include <utility>

namespace orca::metadata::mutation {

namespace {

[[nodiscard]] auto utf8_valid(std::string_view text) -> bool {
    std::size_t index = 0;
    while (index < text.size()) {
        ORCA_ASSERT(index < text.size());
        const auto first = static_cast<std::uint8_t>(text[index]);
        std::size_t length = 1;
        std::uint32_t point = first;
        if (first >= 0x80U) {
            if ((first & 0xe0U) == 0xc0U) {
                length = 2;
                point = first & 0x1fU;
            } else {
                if ((first & 0xf0U) == 0xe0U) {
                    length = 3;
                    point = first & 0x0fU;
                } else {
                    if ((first & 0xf8U) == 0xf0U) {
                        length = 4;
                        point = first & 0x07U;
                    } else {
                        return false;
                    }
                }
            }
        }
        if (index + length > text.size()) {
            return false;
        }
        for (std::size_t offset = 1; offset < length; ++offset) {
            const auto byte = static_cast<std::uint8_t>(text[index + offset]);
            if ((byte & 0xc0U) != 0x80U) {
                return false;
            }
            point = (point << 6U) | (byte & 0x3fU);
        }
        if (length == 2 && point < 0x80U) {
            return false;
        }
        if (length == 3 && point < 0x800U) {
            return false;
        }
        if (length == 4 && point < 0x10000U) {
            return false;
        }
        if (point > 0x10ffffU) {
            return false;
        }
        if (point >= 0xd800U && point <= 0xdfffU) {
            return false;
        }
        index += length;
    }
    return true;
}

[[nodiscard]] auto validate_change(const Change& change) -> expected<void> {
    switch (change.field) {
    case Field::musicbrainz_recording_id:
    case Field::musicbrainz_release_id:
    case Field::musicbrainz_release_group_id:
    case Field::musicbrainz_release_track_id:
    case Field::musicbrainz_album_artist_id: {
        if (!change.after) {
            return {};
        }
        if (!is_music_brainz_id(*change.after)) {
            return fail(ErrorCode::invalid_mutation_plan, "mutation: invalid MusicBrainz id");
        }
        return {};
    }
    case Field::explicit_advisory: {
        if (!change.after) {
            return {};
        }
        if (!from_advisory_text(*change.after)) {
            return fail(ErrorCode::invalid_mutation_plan, "mutation: invalid advisory text");
        }
        return {};
    }
    case Field::title:
    case Field::artist:
    case Field::album:
    case Field::track_number:
    case Field::album_artist:
    case Field::disc_number:
    case Field::date:
    case Field::compilation:
    case Field::composer:
    case Field::comment:
        return {};
    }
    return fail(ErrorCode::invalid_mutation_plan, "mutation: unknown field");
}

[[nodiscard]] auto validate_write(const WriteTags& write) -> expected<void> {
    if (write.path.empty()) {
        return fail(ErrorCode::invalid_mutation_plan, "mutation: empty write path");
    }
    if (!write.expected.content_hash) {
        return fail(ErrorCode::invalid_mutation_plan, "mutation: write without content hash");
    }
    if (write.changes.empty() && !write.genres) {
        return fail(ErrorCode::invalid_mutation_plan, "mutation: write without changes");
    }
    if (write.genres) {
        if (write.genres->after.empty()) {
            return fail(ErrorCode::invalid_mutation_plan, "mutation: empty genre list");
        }
        for (const std::string& genre : write.genres->after) {
            if (genre.empty()) {
                return fail(ErrorCode::invalid_mutation_plan, "mutation: blank genre");
            }
            if (genre.find('\0') != std::string::npos) {
                return fail(ErrorCode::invalid_mutation_plan, "mutation: genre contains NUL");
            }
            if (!utf8_valid(genre)) {
                return fail(ErrorCode::invalid_mutation_plan, "mutation: genre is not UTF-8");
            }
        }
    }
    for (const Change& change : write.changes) {
        const auto valid = validate_change(change);
        if (!valid) {
            return std::unexpected(valid.error());
        }
    }
    return {};
}

[[nodiscard]] auto validate_move(const Move& move) -> expected<void> {
    if (move.source_path.empty() || move.destination_path.empty()) {
        return fail(ErrorCode::invalid_mutation_plan, "mutation: empty move path");
    }
    if (!move.expected.content_hash) {
        return fail(ErrorCode::invalid_mutation_plan, "mutation: move without content hash");
    }
    if (move.source_path == move.destination_path) {
        return fail(ErrorCode::invalid_mutation_plan, "mutation: move onto itself");
    }
    return {};
}

void update_int(crypto::Blake3& hasher, std::uint64_t value) {
    std::array<std::byte, 8> bytes{};
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        bytes[index] = static_cast<std::byte>((value >> (index * 8U)) & 0xffU);
    }
    hasher.update(bytes);
}

void update_bytes(crypto::Blake3& hasher, std::string_view value) {
    update_int(hasher, value.size());
    hasher.update(value);
}

void update_optional_bytes(crypto::Blake3& hasher, const std::optional<std::string>& value) {
    const std::array<std::byte, 1> present{value ? std::byte{1} : std::byte{0}};
    hasher.update(present);
    update_bytes(hasher, value ? std::string_view(*value) : std::string_view{});
}

void update_digest(crypto::Blake3& hasher, const storage::content_hash::Digest& value) {
    hasher.update(std::as_bytes(std::span<const std::uint8_t>(value)));
}

void update_identity(crypto::Blake3& hasher, const FileIdentity& value) {
    update_int(hasher, value.size_bytes);
    update_int(hasher, static_cast<std::uint64_t>(value.modified_ns));
    update_digest(hasher, value.quick_hash);
    const std::array<std::byte, 1> present{value.content_hash ? std::byte{1} : std::byte{0}};
    hasher.update(present);
    storage::content_hash::Digest content{};
    if (value.content_hash) {
        content = *value.content_hash;
    }
    update_digest(hasher, content);
}

void update_values(crypto::Blake3& hasher, const std::vector<std::string>& values) {
    update_int(hasher, values.size());
    for (const std::string& value : values) {
        update_bytes(hasher, value);
    }
}

[[nodiscard]] auto field_backing(Field field) -> std::uint64_t {
    return static_cast<std::uint64_t>(static_cast<std::uint32_t>(field));
}

void update_action(crypto::Blake3& hasher, const Action& action) {
    std::visit(
        [&hasher](const auto& value) {
            using Tag = std::decay_t<decltype(value)>;
            if constexpr (std::is_same_v<Tag, WriteTags>) {
                const std::array<std::byte, 1> kind{std::byte{0}};
                hasher.update(kind);
                update_bytes(hasher, value.path);
                update_identity(hasher, value.expected);
                update_int(hasher, value.changes.size());
                for (const Change& change : value.changes) {
                    update_int(hasher, field_backing(change.field));
                    update_optional_bytes(hasher, change.before);
                    update_optional_bytes(hasher, change.after);
                }
                if (value.genres) {
                    hasher.update(std::string_view("genres"));
                    update_values(hasher, value.genres->before);
                    update_values(hasher, value.genres->after);
                }
            } else {
                const std::array<std::byte, 1> kind{std::byte{1}};
                hasher.update(kind);
                update_bytes(hasher, value.source_path);
                update_bytes(hasher, value.destination_path);
                update_identity(hasher, value.expected);
            }
        },
        action);
}

}

auto FileIdentity::eql(const FileIdentity& other) const -> bool {
    if (size_bytes != other.size_bytes) {
        return false;
    }
    if (modified_ns != other.modified_ns) {
        return false;
    }
    if (quick_hash != other.quick_hash) {
        return false;
    }
    if (!content_hash) {
        return true;
    }
    if (!other.content_hash) {
        return true;
    }
    return *content_hash == *other.content_hash;
}

auto digest_of(std::uint64_t id, const std::vector<Action>& actions) -> Digest {
    crypto::Blake3 hasher;
    hasher.update(std::string_view("orca.mutation.plan.v1"));
    update_int(hasher, id);
    update_int(hasher, actions.size());
    for (const Action& action : actions) {
        update_action(hasher, action);
    }
    return hasher.finalize();
}

auto Plan::init(std::uint64_t id, std::vector<Action> actions) -> expected<Plan> {
    if (id == 0 || actions.empty()) {
        return fail(ErrorCode::invalid_mutation_plan, "mutation: empty plan");
    }
    for (const Action& action : actions) {
        const auto valid = std::visit(
            [](const auto& value) -> expected<void> {
                using Tag = std::decay_t<decltype(value)>;
                if constexpr (std::is_same_v<Tag, WriteTags>) {
                    return validate_write(value);
                } else {
                    return validate_move(value);
                }
            },
            action);
        if (!valid) {
            return std::unexpected(valid.error());
        }
    }
    Plan plan;
    plan.id_ = id;
    plan.actions_ = std::move(actions);
    plan.sealed_digest_ = digest_of(id, plan.actions_);
    plan.state_ = State::draft;
    return plan;
}

auto Plan::preview() const -> Preview {
    ORCA_ASSERT(id_ != 0);
    Preview result;
    for (const Action& action : actions_) {
        std::visit(
            [&result](const auto& value) {
                using Tag = std::decay_t<decltype(value)>;
                if constexpr (std::is_same_v<Tag, WriteTags>) {
                    result.tag_writes += 1;
                    result.field_changes += value.changes.size();
                    if (value.genres) {
                        result.field_changes += 1;
                    }
                } else {
                    result.moves += 1;
                }
            },
            action);
    }
    ORCA_ASSERT(result.tag_writes + result.moves == actions_.size());
    return result;
}

auto Plan::approval() const -> Approval {
    return Approval{.plan_id = id_, .digest = sealed_digest_};
}

auto Plan::approve(const Approval& confirmed) -> expected<void> {
    if (state_ != State::draft) {
        return fail(ErrorCode::invalid_mutation_transition, "mutation: plan already approved");
    }
    const auto seal = verify_seal();
    if (!seal) {
        return std::unexpected(seal.error());
    }
    if (confirmed.plan_id != id_ || confirmed.digest != sealed_digest_) {
        return fail(ErrorCode::mutation_approval_mismatch, "mutation: approval mismatch");
    }
    state_ = State::approved;
    return {};
}

auto Plan::begin_execution() -> expected<void> {
    if (state_ != State::approved) {
        return fail(ErrorCode::mutation_plan_not_approved, "mutation: plan not approved");
    }
    const auto seal = verify_seal();
    if (!seal) {
        return std::unexpected(seal.error());
    }
    state_ = State::executing;
    return {};
}

auto Plan::finish(bool success) -> expected<void> {
    if (state_ != State::executing) {
        return fail(ErrorCode::invalid_mutation_transition, "mutation: plan not executing");
    }
    state_ = success ? State::completed : State::failed;
    return {};
}

auto Plan::verify_seal() const -> expected<void> {
    ORCA_ASSERT(id_ != 0);
    if (digest_of(id_, actions_) != sealed_digest_) {
        return fail(ErrorCode::mutation_plan_seal_broken, "mutation: plan seal broken");
    }
    return {};
}

}
