#pragma once

#include "liborca/base/expected.hpp"
#include "liborca/metadata/mutation.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>

namespace orca::metadata::file_mutation {

enum class Interrupt : std::uint8_t {
    none,
    after_backup_copy,
    after_source_rename,
    after_restore_copy,
    after_restore_rename,
};

[[nodiscard]] auto is_orca_temporary_name(std::string_view name) -> bool;

[[nodiscard]] auto sibling_path(const std::filesystem::path& source_path, std::string_view purpose,
                                std::uint64_t plan_id, std::size_t action_index) -> std::string;

[[nodiscard]] auto plan_backup_directory(const std::filesystem::path& backup_directory,
                                         std::uint64_t plan_id) -> std::string;

[[nodiscard]] auto backup_path(const std::string& plan_directory, std::size_t action_index,
                               const std::filesystem::path& source_path) -> std::string;

[[nodiscard]] auto identity(const std::filesystem::path& path) -> expected<mutation::FileIdentity>;

[[nodiscard]] auto require_identity_at(const std::filesystem::path& path,
                                       const mutation::FileIdentity& expected_identity)
    -> expected<void>;

[[nodiscard]] auto matches(const std::filesystem::path& path,
                           const mutation::FileIdentity& expected_identity) -> expected<bool>;

[[nodiscard]] auto require_writable_file(const std::filesystem::path& path) -> expected<void>;

[[nodiscard]] auto sync_containing_directory(const std::filesystem::path& path) -> expected<void>;

[[nodiscard]] auto create_directory_durably(const std::filesystem::path& path) -> expected<void>;

[[nodiscard]] auto delete_if_present(const std::filesystem::path& path) -> expected<void>;

[[nodiscard]] auto copy_verified(const std::filesystem::path& source_path,
                                 const std::filesystem::path& copy_path,
                                 const mutation::FileIdentity& expected_identity) -> expected<void>;

[[nodiscard]] auto stage_flac(const std::filesystem::path& source_path,
                              const std::filesystem::path& stage_path,
                              const mutation::FileIdentity& expected_identity,
                              const std::vector<mutation::Change>& changes,
                              const std::optional<mutation::GenreChange>& genres) -> expected<void>;

[[nodiscard]] auto stage_mpeg(const std::filesystem::path& source_path,
                              const std::filesystem::path& stage_path,
                              const mutation::FileIdentity& expected_identity,
                              const std::vector<mutation::Change>& changes,
                              const std::optional<mutation::GenreChange>& genres) -> expected<void>;

[[nodiscard]] auto commit_replacement(const std::filesystem::path& source_path,
                                      const std::filesystem::path& stage_path,
                                      const std::filesystem::path& backup_path,
                                      const mutation::FileIdentity& expected_identity)
    -> expected<void>;

[[nodiscard]] auto commit_replacement_interrupted(const std::filesystem::path& source_path,
                                                  const std::filesystem::path& stage_path,
                                                  const std::filesystem::path& backup_path,
                                                  const mutation::FileIdentity& expected_identity,
                                                  Interrupt interrupt) -> expected<void>;

[[nodiscard]] auto commit_move(const std::filesystem::path& source_path,
                               const std::filesystem::path& destination_path) -> expected<void>;

[[nodiscard]] auto restore_from_backup(const std::filesystem::path& source_path,
                                       const std::filesystem::path& backup_path,
                                       const std::filesystem::path& restore_path,
                                       const mutation::FileIdentity& original,
                                       const mutation::FileIdentity& replacing) -> expected<void>;

[[nodiscard]] auto restore_from_backup_interrupted(const std::filesystem::path& source_path,
                                                   const std::filesystem::path& backup_path,
                                                   const std::filesystem::path& restore_path,
                                                   const mutation::FileIdentity& original,
                                                   const mutation::FileIdentity& replacing,
                                                   Interrupt interrupt) -> expected<void>;

}
