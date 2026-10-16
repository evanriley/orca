#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace orca {

enum class ErrorCode : std::uint32_t {
    none = 0,
    invalid_argument,
    out_of_range,
    overflow,
    underflow,
    division_by_zero,
    io,
    not_found,
    already_exists,
    parse,
    unsupported,
    network,
    timeout,
    too_many_redirects,
    insecure_transport,
    cancelled,
    internal,
    truncated_flac,
    flac_stream_errors,
    flac_md5_mismatch,
    invalid_id3v2_tag,
    truncated_id3v2_tag,
    invalid_id3v2_text,
    id3v2_tag_too_large,
    invalid_flac_stream,
    truncated_flac_stream,
    invalid_vorbis_comment,
    invalid_ogg_stream,
    truncated_ogg_stream,
    ogg_comment_not_found,
    ogg_comment_too_large,
    no_backup_directory,
    mutation_in_progress,
    invalid_mutation_plan,
    invalid_mutation_transition,
    mutation_approval_mismatch,
    mutation_plan_not_approved,
    mutation_plan_seal_broken,
    invalid_mutation_operation,
    stale_mutation_operation,
    mutation_operation_not_found,
    mutation_group_not_found,
    mutation_group_not_committed,
    file_identity_changed,
    copy_identity_mismatch,
    file_read_only,
    file_timestamp_out_of_range,
    unsupported_id3_layout,
    invalid_tag_value,
    metadata_precondition_changed,
    duplicate_metadata_field_change,
    invalid_metadata_text,
    metadata_value_too_long,
    destination_exists,
    multiple_vorbis_comment_blocks,
    invalid_mpeg_stream,
    simulated_power_loss,
    tag_target_unavailable,
    mutation_recovery_incomplete,
    library_opened_with_unrecoverable_journal,
    invalid_mutation_group,
    tag_write_backup_exists,
    tag_write_backup_pruned,
    unsupported_tag_writer,
    missing_committed_identity,
    missing_expected_identity,
    missing_mutation_destination,
    missing_mutation_stage_path,
    missing_mutation_backup_path,
    missing_content_hash,
    mutation_operation_not_committed,
    mutation_operation_not_recoverable,
    mutation_needs_reconciliation,
    mutation_group_already_undone,
    error_code_count,
};

struct Error {
    ErrorCode code = ErrorCode::none;
    std::string context{};

    [[nodiscard]] auto ok() const noexcept -> bool {
        return code == ErrorCode::none;
    }
};

[[nodiscard]] auto to_string(ErrorCode code) -> std::string_view;

}
