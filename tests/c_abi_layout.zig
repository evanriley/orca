const std = @import("std");
const liborca = @import("liborca");
const c = @import("orca_h");

const c_api = liborca.internal.c_api;
const audio = liborca.internal.audio;
const core = liborca.internal.core;
const database = liborca.internal.database;
const metadata = liborca.internal.metadata;

const struct_pairs = .{
    .{ c_api.Handle, c.orca_handle },
    .{ c_api.StringView, c.orca_string_view },
    .{ c_api.TrackView, c.orca_track_view },
    .{ c_api.TrackQueryView, c.orca_track_query },
    .{ c_api.TrackQueryV2View, c.orca_track_query_v2 },
    .{ c_api.TrackFactsView, c.orca_track_facts_view },
    .{ c_api.TrackDetailsExtraView, c.orca_track_details_extra_view },
    .{ c_api.TrackDetailsTextView, c.orca_track_details_text_view },
    .{ c_api.ArtistView, c.orca_artist_view },
    .{ c_api.ArtistViewV2, c.orca_artist_view_v2 },
    .{ c_api.ArtistInfoOptionsView, c.orca_artist_info_options },
    .{ c_api.ArtistInfoView, c.orca_artist_info_view },
    .{ c_api.ArtistLinkView, c.orca_artist_link_view },
    .{ c_api.RelatedArtistView, c.orca_related_artist_view },
    .{ c_api.RelatedArtistPhotoInfoView, c.orca_related_artist_photo_info_view },
    .{ c_api.ReleaseInfoOptionsView, c.orca_release_info_options },
    .{ c_api.ReleaseInfoView, c.orca_release_info_view },
    .{ c_api.GenreFillView, c.orca_genre_fill },
    .{ c_api.GenreFillOptionsView, c.orca_genre_fill_options },
    .{ c_api.ReleaseView, c.orca_release_view },
    .{ c_api.ReleaseQueryView, c.orca_release_query },
    .{ c_api.ArtistQueryView, c.orca_artist_query },
    .{ c_api.ReleaseQueryV2View, c.orca_release_query_v2 },
    .{ c_api.ReleaseFactsView, c.orca_release_facts_view },
    .{ c_api.ArtistQueryV2View, c.orca_artist_query_v2 },
    .{ c_api.GenreQueryView, c.orca_genre_query },
    .{ c_api.GenreView, c.orca_genre_view },
    .{ c_api.SearchLimitsView, c.orca_search_limits },
    .{ c_api.SearchHitView, c.orca_search_hit_view },
    .{ c_api.GenreCountView, c.orca_genre_count_view },
    .{ c_api.TrackSummaryView, c.orca_track_summary_view },
    .{ c_api.TrackDetailsView, c.orca_track_details_view },
    .{ c_api.PlayStatsView, c.orca_play_stats },
    .{ c_api.ArtistTotalsView, c.orca_artist_totals },
    .{ c_api.ChangeCount, c.orca_change_count },
    .{ c_api.PlaylistView, c.orca_playlist_view },
    .{ c_api.PlaylistQueryView, c.orca_playlist_query },
    .{ c_api.PlaylistFactsView, c.orca_playlist_facts_view },
    .{ c_api.PlaylistUpdateView, c.orca_playlist_update },
    .{ c_api.PlaylistEntryView, c.orca_playlist_entry_view },
    .{ c_api.PlaylistImport, c.orca_playlist_import },
    .{ c_api.ImageView, c.orca_image_view },
    .{ c_api.ArtworkResultView, c.orca_artwork_result_view },
    .{ c_api.LyricsLineView, c.orca_lyrics_line },
    .{ c_api.LyricsView, c.orca_lyrics_view },
    .{ c_api.TrackEditView, c.orca_track_edit },
    .{ c_api.FieldValueView, c.orca_field_value_view },
    .{ c_api.TagWriteDigest, c.orca_tag_write_digest },
    .{ c_api.TagWriteChangeView, c.orca_tag_write_change_view },
    .{ c_api.TagWriteFileView, c.orca_tag_write_file_view },
    .{ c_api.TagWriteConflictView, c.orca_tag_write_conflict_view },
    .{ c_api.TagWriteSkipView, c.orca_tag_write_skip_view },
    .{ c_api.TagWritePlanView, c.orca_tag_write_plan_view },
    .{ c_api.TagWriteFailureView, c.orca_tag_write_failure },
    .{ c_api.TagWriteGenresView, c.orca_tag_write_genres_view },
    .{ c_api.TagWriteGroupView, c.orca_tag_write_group_view },
    .{ c_api.TagWriteDiffView, c.orca_tag_write_diff_view },
    .{ c_api.TagWriteGroupDetailView, c.orca_tag_write_group_detail_view },
    .{ c_api.HealthIssueView, c.orca_health_issue_view },
    .{ c_api.HealthItemView, c.orca_health_item_view },
    .{ c_api.HealthKindSummaryView, c.orca_health_kind_summary_view },
    .{ c_api.HealthKindSummaryViewV2, c.orca_health_kind_summary_view_v2 },
    .{ c_api.LibraryStatsView, c.orca_library_stats_view },
    .{ c_api.LibraryStatsViewV2, c.orca_library_stats_view_v2 },
    .{ c_api.CacheSizeView, c.orca_cache_size },
    .{ c_api.ProviderSourceView, c.orca_provider_source_view },
    .{ c_api.HealthFileView, c.orca_health_file_view },
    .{ c_api.DuplicateGroupView, c.orca_duplicate_group_view },
    .{ c_api.DuplicateGroupTotalsView, c.orca_duplicate_group_totals },
    .{ c_api.DuplicateCopyView, c.orca_duplicate_copy_view },
    .{ c_api.DuplicateMergeView, c.orca_duplicate_merge },
    .{ c_api.RootView, c.orca_root_view },
    .{ c_api.RootViewV2, c.orca_root_view_v2 },
    .{ c_api.FolderEntryView, c.orca_folder_entry_view },
    .{ c_api.DeviceView, c.orca_device_view },
    .{ c_api.DeviceViewV2, c.orca_device_view_v2 },
    .{ c_api.DeviceViewV3, c.orca_device_view_v3 },
    .{ c_api.QueueEntryView, c.orca_queue_entry_view },
    .{ c_api.QueueStats, c.orca_queue_stats },
    .{ c_api.NowPlayingView, c.orca_now_playing_view },
    .{ c_api.PlayerStatus, c.orca_player_status },
    .{ c_api.PlayerStatusV2, c.orca_player_status_v2 },
    .{ c_api.ZoneStatus, c.orca_zone_status },
    .{ c_api.EqualizerView, c.orca_equalizer },
    .{ c_api.ParametricFilterView, c.orca_parametric_filter },
    .{ c_api.ParametricEqualizerView, c.orca_parametric_equalizer },
    .{ c_api.PcmFormatView, c.orca_pcm_format },
    .{ c_api.SignalPathView, c.orca_signal_path_view },
    .{ c_api.DeviceFormatView, c.orca_device_format },
    .{ c_api.ReplayGainSettingsView, c.orca_replay_gain_settings },
    .{ c_api.JobSnapshot, c.orca_job_snapshot },
    .{ c_api.JobDetails, c.orca_job_details },
    .{ c_api.QueuedJobView, c.orca_queued_job_view },
    .{ c_api.JobHistoryView, c.orca_job_history_view },
    .{ c_api.ScanStats, c.orca_scan_stats },
    .{ c_api.FolderEstimate, c.orca_folder_estimate },
    .{ c_api.ScanOptions, c.orca_scan_options },
    .{ c_api.AnalysisOptions, c.orca_analysis_options },
    .{ c_api.DuplicateScanOptions, c.orca_duplicate_scan_options },
    .{ c_api.BackfillOptions, c.orca_backfill_options },
    .{ c_api.CommandCompletedEvent, c.orca_command_completed_event },
    .{ c_api.JobProgressEvent, c.orca_job_progress_event },
    .{ c_api.JobFinishedEvent, c.orca_job_finished_event },
    .{ c_api.PlayerPositionEvent, c.orca_player_position_event },
    .{ c_api.LibraryChangedEvent, c.orca_library_changed_event },
    .{ c_api.EventPayload, c.orca_event_payload },
    .{ c_api.WatchOptions, c.orca_watch_options },
    .{ c_api.WatchStatus, c.orca_watch_status },
    .{ c_api.MaintenanceOptions, c.orca_maintenance_options },
    .{ c_api.MaintenanceStatus, c.orca_maintenance_status },
    .{ c_api.Event, c.orca_event },
    .{ c_api.MatchOptions, c.orca_match_options },
    .{ c_api.MatchStatsView, c.orca_match_stats },
    .{ c_api.SubmissionStatsView, c.orca_submission_stats },
    .{ c_api.AcoustIdSubmittableView, c.orca_acoustid_submittable_view },
    .{ c_api.MatchProposalView, c.orca_match_proposal_view },
    .{ c_api.MatchAcceptanceView, c.orca_match_acceptance },
    .{ c_api.ConfidentAcceptanceView, c.orca_confident_acceptance },
    .{ c_api.MatchReviewView, c.orca_match_review_view },
    .{ c_api.HeardRecordingView, c.orca_heard_recording_view },
    .{ c_api.TrackVerificationView, c.orca_track_verification_view },
    .{ c_api.CorrectionMemberView, c.orca_correction_member_view },
    .{ c_api.CorrectionGroupView, c.orca_correction_group_view },
    .{ c_api.ScrobblerStatusView, c.orca_scrobbler_status_view },
};

const export_mappings = .{
    struct {
        pub const prefix = "ORCA_ACOUSTID_USE_";
        pub const Tag = core.runtime.AcoustIdUse;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportAcoustIdUse(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_TAG_WRITE_GROUP_STATE_";
        pub const Tag = core.runtime.TagWriteGroupState;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportTagWriteGroupState(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_TAG_WRITE_DIFF_SUBJECT_";
        pub const Tag = std.meta.Tag(core.runtime.TagWriteDiffSubject);
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportTagWriteDiffSubject(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_SCAN_STAGE_";
        pub const Tag = core.runtime.ScanStage;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportScanStage(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_BUSY_SERVICE_";
        pub const Tag = core.runtime.BusyService;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportBusyService(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_COVER_ART_OUTCOME_";
        pub const Tag = core.runtime.CoverArtOutcome;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportCoverArtOutcome(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_LYRICS_OUTCOME_";
        pub const Tag = core.runtime.LyricsOutcome;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportLyricsOutcome(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_ARTIST_INFO_OUTCOME_";
        pub const Tag = core.runtime.ArtistInfoOutcome;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_ARTIST_PHOTO_SOURCE_";
        pub const Tag = database.ArtistPhotoSource;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_RELEASE_DESCRIPTION_SOURCE_";
        pub const Tag = database.ReleaseDescriptionSource;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_ARTIST_LINK_KIND_";
        pub const Tag = database.ArtistLinkKind;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_LYRICS_SOURCE_";
        pub const Tag = metadata.lyrics.Source;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportLyricsSource(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_LYRICS_KIND_";
        pub const Tag = metadata.lyrics.Kind;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportLyricsKind(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_SCROBBLER_STATE_";
        pub const Tag = core.runtime.ScrobblerState;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportScrobblerState(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_SUBMISSION_OUTCOME_";
        pub const Tag = core.runtime.SubmissionOutcome;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportSubmissionOutcome(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_VERIFICATION_OUTCOME_";
        pub const Tag = core.runtime.VerificationOutcome;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportVerificationOutcome(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_STATUS_";
        pub const Tag = c_api.Status;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_TRACK_SORT_";
        pub const Tag = c_api.TrackSortKey;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_PLAYLIST_SORT_";
        pub const Tag = c_api.PlaylistSortKey;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_PLAYLIST_KIND_";
        pub const Tag = database.PlaylistKind;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_PLAYLIST_CREATOR_";
        pub const Tag = database.PlaylistCreator;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_EXPLICIT_";
        pub const Tag = metadata.Explicit;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportExplicit(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_SEARCH_KIND_";
        pub const Tag = database.SearchKind;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportSearchKind(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_FOLDER_ENTRY_KIND_";
        pub const Tag = database.FolderEntryKind;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportFolderEntryKind(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_LISTEN_POLICY_";
        pub const Tag = core.runtime.ListenPolicy;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportListenPolicy(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_FEEDBACK_";
        pub const Tag = database.Feedback;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportFeedback(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_ID_SOURCE_";
        pub const Tag = c_api.IdSource;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_EVENT_";
        pub const Tag = c_api.EventKind;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_TRANSPORT_";
        pub const Tag = audio.player.TransportState;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_REPEAT_";
        pub const Tag = audio.playback_queue.RepeatMode;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_QUEUE_HISTORY_REASON_";
        pub const Tag = core.runtime.QueueHistoryReason;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_OUTPUT_";
        pub const Tag = audio.zone.OutputState;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_REPLAY_GAIN_";
        pub const Tag = audio.processing.ReplayGainMode;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_GAIN_SOURCE_";
        pub const Tag = audio.processing.ReplayGainSource;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportReplayGainSource(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_UNTAGGED_";
        pub const Tag = audio.processing.UntaggedFallback;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportUntaggedFallback(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_SAMPLE_FORMAT_";
        pub const Tag = audio.pcm.SampleFormat;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportSampleFormat(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_SIGNAL_REASON_";
        pub const Tag = audio.signal_path.Reason;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportSignalReason(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_PARAMETRIC_FILTER_";
        pub const Tag = audio.dsp.FilterKind;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportFilterKind(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_JOB_";
        pub const Tag = core.job.State;
        pub fn produce(tag: Tag) ?i64 {
            return @intFromEnum(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_JOB_KIND_";
        pub const fallback = "ORCA_JOB_KIND_OTHER";
        pub const Tag = core.job.Kind;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportJobKind(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_ARTWORK_KIND_";
        pub const Tag = metadata.ArtworkKind;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportArtworkKind(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_ARTWORK_SUBJECT_";
        pub const Tag = enum { track, release, artist };
        pub fn produce(tag: Tag) ?i64 {
            const value = c_api.exportArtworkSubject(switch (tag) {
                .track => .{ .track = 1 },
                .release => .{ .release = 1 },
                .artist => .{ .artist = 1 },
            }) orelse return null;
            return value;
        }
    },
    struct {
        pub const prefix = "ORCA_METADATA_FIELD_";
        pub const Tag = metadata.Field;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportMetadataField(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_PROVENANCE_";
        pub const Tag = metadata.Provenance;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportProvenance(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_TAG_WRITE_SKIP_";
        pub const Tag = core.runtime.TagWriteSkipReason;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportTagWriteSkipReason(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_TAG_WRITE_FAILURE_";
        pub const Tag = core.runtime.TagWriteFailureReason;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportTagWriteFailureReason(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_HEALTH_ISSUE_KIND_";
        pub const Tag = database.HealthIssueKind;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportHealthIssueKind(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_PROVIDER_SOURCE_";
        pub const Tag = core.provider_sources.ProviderSourceId;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportProviderSourceId(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_HEALTH_SEVERITY_";
        pub const fallback = "ORCA_HEALTH_SEVERITY_ERROR";
        pub const Tag = database.HealthSeverity;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportHealthSeverity(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_HEALTH_ACTION_";
        pub const Tag = database.HealthAction;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportHealthAction(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_DEVICE_KIND_";
        pub const Tag = audio.backend.DeviceKind;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportDeviceKind(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_DEVICE_SAMPLE_FORMAT_";
        pub const Tag = audio.backend.DeviceSampleFormat;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportDeviceSampleFormat(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_DEVICE_STATE_";
        pub const Tag = audio.backend.DeviceState;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportDeviceState(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_WATCH_STATE_";
        pub const Tag = core.runtime.WatchState;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportWatchState(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_MAINTENANCE_STATE_";
        pub const Tag = core.runtime.MaintenanceState;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportMaintenanceState(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_MAINTENANCE_BLOCK_";
        pub const Tag = core.runtime.MaintenanceBlock;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportMaintenanceBlock(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_JOB_ORIGIN_";
        pub const Tag = core.runtime.JobOrigin;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportJobOrigin(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_OUTCOME_";
        pub const Tag = std.meta.Tag(core.control.Outcome);
        pub fn produce(tag: Tag) ?i64 {
            const event = c_api.exportCompletion(.{ .request_id = 1, .outcome = sampleOutcome(tag) });
            if (event.kind != @intFromEnum(c_api.EventKind.command_completed)) return null;
            return event.payload.command_completed.outcome;
        }
    },
    struct {
        pub const prefix = "ORCA_PLAYBACK_FAILURE_";
        pub const Tag = core.runtime.PlaybackFailure.Reason;
        pub fn produce(tag: Tag) ?i64 {
            return c_api.exportPlaybackFailureReason(tag);
        }
    },
    struct {
        pub const prefix = "ORCA_FAILURE_";
        pub const Tag = core.control.Failure;
        pub fn produce(tag: Tag) ?i64 {
            const event = c_api.exportCompletion(.{ .request_id = 1, .outcome = .{ .failed = tag } });
            return event.payload.command_completed.failure;
        }
    },
};

const import_mappings = .{
    struct {
        pub const prefix = "ORCA_EQUALIZER_PRESET_";
        pub const Tag = audio.dsp.Preset;
        pub fn consume(value: u8) ?Tag {
            return c_api.importEqualizerPreset(value);
        }
    },
    struct {
        pub const prefix = "ORCA_PARAMETRIC_FILTER_";
        pub const Tag = audio.dsp.FilterKind;
        pub fn consume(value: u8) ?Tag {
            return c_api.importFilterKind(value);
        }
    },
    struct {
        pub const prefix = "ORCA_REPLAY_GAIN_";
        pub const Tag = audio.processing.ReplayGainMode;
        pub fn consume(value: u8) ?Tag {
            return c_api.importReplayGainMode(value);
        }
    },
    struct {
        pub const prefix = "ORCA_UNTAGGED_";
        pub const Tag = audio.processing.UntaggedFallback;
        pub fn consume(value: u8) ?Tag {
            return c_api.importUntaggedFallback(value);
        }
    },
    struct {
        pub const prefix = "ORCA_RENDER_POLICY_";
        pub const Tag = std.meta.Tag(audio.zone.RenderPolicy);
        pub fn consume(value: u8) ?Tag {
            const policy = c_api.importRenderPolicy(value) orelse return null;
            return std.meta.activeTag(policy);
        }
    },
    struct {
        pub const prefix = "ORCA_REPEAT_";
        pub const Tag = audio.playback_queue.RepeatMode;
        pub fn consume(value: u8) ?Tag {
            return std.enums.fromInt(Tag, value);
        }
    },
    struct {
        pub const prefix = "ORCA_TRACK_SORT_";
        pub const Tag = c_api.TrackSortKey;
        pub fn consume(value: u8) ?Tag {
            return std.enums.fromInt(Tag, value);
        }
    },
    struct {
        pub const prefix = "ORCA_ARTIST_SORT_";
        pub const Tag = c_api.ArtistSortKey;
        pub fn consume(value: u8) ?Tag {
            return std.enums.fromInt(Tag, value);
        }
    },
    struct {
        pub const prefix = "ORCA_GENRE_SORT_";
        pub const Tag = c_api.GenreSortKey;
        pub fn consume(value: u8) ?Tag {
            return std.enums.fromInt(Tag, value);
        }
    },
    struct {
        pub const prefix = "ORCA_PLAYLIST_PATH_";
        pub const Tag = core.runtime.PlaylistPathStyle;
        pub fn consume(value: u8) ?Tag {
            return c_api.importPlaylistPathStyle(value);
        }
    },
    struct {
        pub const prefix = "ORCA_ARTWORK_SUBJECT_";
        pub const Tag = std.meta.Tag(core.runtime.ArtworkSubject);
        pub fn consume(value: u8) ?Tag {
            return c_api.importArtworkSubject(value);
        }
    },
    struct {
        pub const prefix = "ORCA_HEALTH_ISSUE_KIND_";
        pub const Tag = database.HealthIssueKind;
        pub fn consume(value: u8) ?Tag {
            return c_api.importHealthIssueKind(value);
        }
    },
    struct {
        pub const prefix = "ORCA_METADATA_FIELD_";
        pub const Tag = metadata.Field;
        pub fn consume(value: u8) ?Tag {
            return c_api.importMetadataField(value);
        }
    },
    struct {
        pub const prefix = "ORCA_RELEASE_SORT_";
        pub const Tag = database.ReleaseSort;
        pub fn consume(value: u8) ?Tag {
            return c_api.importReleaseSort(value);
        }
    },
    struct {
        pub const prefix = "ORCA_RELEASE_ARTWORK_";
        pub const Tag = c_api.ReleaseArtworkFilter;
        pub fn consume(value: u8) ?Tag {
            return c_api.importReleaseArtworkFilter(value);
        }
    },
    struct {
        pub const prefix = "ORCA_RELEASE_KIND_";
        pub const Tag = c_api.ReleaseKindFilter;
        pub fn consume(value: u8) ?Tag {
            return c_api.importReleaseKindFilter(value);
        }
    },
    struct {
        pub const prefix = "ORCA_TRACK_FORMAT_";
        pub const Tag = c_api.TrackFormatFilter;
        pub fn consume(value: u8) ?Tag {
            return c_api.importTrackFormatFilter(value);
        }
    },
    struct {
        pub const prefix = "ORCA_MATCH_MODE_";
        pub const Tag = core.runtime.MatchMode;
        pub fn consume(value: u8) ?Tag {
            return c_api.importMatchMode(value);
        }
    },
    struct {
        pub const prefix = "ORCA_PROVIDER_SERVICE_";
        pub const Tag = c_api.ProviderService;
        pub fn consume(value: u8) ?Tag {
            return c_api.importProviderService(value);
        }
    },
    struct {
        pub const prefix = "ORCA_CREDENTIAL_RESULT_";
        pub const Tag = c_api.CredentialResult;
        pub fn consume(value: u8) ?Tag {
            return c_api.importCredentialResult(value);
        }
    },
    struct {
        pub const prefix = "ORCA_JOB_HISTORY_";
        pub const Tag = core.runtime.JobHistoryFilter;
        pub fn consume(value: u8) ?Tag {
            return c_api.importJobHistoryFilter(value);
        }
    },
};

const non_enum_constants = [_][]const u8{
    "ORCA_ABI_VERSION",
    "ORCA_PUMP_NO_TIMEOUT",
    "ORCA_EQUALIZER_BANDS",
    "ORCA_EQUALIZER_MAX_GAIN_DB",
    "ORCA_EQUALIZER_MIN_PREAMP_DB",
    "ORCA_EQUALIZER_MAX_PREAMP_DB",
    "ORCA_PARAMETRIC_MAX_FILTERS",
    "ORCA_PARAMETRIC_MIN_FREQUENCY_HZ",
    "ORCA_PARAMETRIC_MAX_FREQUENCY_HZ",
    "ORCA_PARAMETRIC_MAX_GAIN_DB",
    "ORCA_PARAMETRIC_MIN_PREAMP_DB",
    "ORCA_PARAMETRIC_MAX_PREAMP_DB",
    "ORCA_SIGNAL_MAX_REASONS",
    "ORCA_TAG_WRITE_DIGEST_BYTES",
    "ORCA_CREDENTIAL_MAX_BYTES",
    "ORCA_LYRICS_FETCH",
    "ORCA_DEVICE_BIT_DEPTH_16",
    "ORCA_DEVICE_BIT_DEPTH_24",
    "ORCA_DEVICE_BIT_DEPTH_32",
    "ORCA_DEVICE_SAMPLE_FORMAT_UNKNOWN",
    "ORCA_MAX_WAITING_JOBS",
};

fn sampleOutcome(tag: std.meta.Tag(core.control.Outcome)) core.control.Outcome {
    return switch (tag) {
        .library_created => .{ .library_created = .{ .index = 1, .generation = 1 } },
        .player_created => .{ .player_created = .{ .index = 1, .generation = 1 } },
        .zone_created => .{ .zone_created = .{ .index = 1, .generation = 1 } },
        .job_started => .{ .job_started = .{ .index = 1, .generation = 1 } },
        .job_cancellation_requested => .{ .job_cancellation_requested = .{ .index = 1, .generation = 1 } },
        .job_finished => .{ .job_finished = .{ .job = .{ .index = 1, .generation = 1 }, .state = .succeeded } },
        .track_playing => .{ .track_playing = .{ .index = 1, .generation = 1 } },
        .failed => .{ .failed = .internal },
    };
}

fn constantName(comptime prefix: []const u8, comptime tag_name: []const u8) []const u8 {
    comptime {
        var upper: [tag_name.len]u8 = undefined;
        for (tag_name, 0..) |character, index| upper[index] = std.ascii.toUpper(character);
        const final = upper;
        return prefix ++ &final;
    }
}

const FieldLayout = struct {
    name: [:0]const u8,
    offset: usize,
    Type: type,
};

fn fieldLayouts(comptime T: type) []const FieldLayout {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| layoutsOf(T, info.fields),
        .@"union" => |info| layoutsOf(T, info.fields),
        else => @compileError(@typeName(T) ++ " is neither a struct nor a union"),
    };
}

fn layoutsOf(comptime T: type, comptime fields: anytype) []const FieldLayout {
    comptime {
        var layouts: [fields.len]FieldLayout = undefined;
        for (fields, 0..) |field, index| layouts[index] = .{
            .name = field.name,
            .offset = if (@typeInfo(T) == .@"union") 0 else @offsetOf(T, field.name),
            .Type = field.type,
        };
        const final = layouts;
        return &final;
    }
}

fn isExternContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.layout == .@"extern",
        .@"union" => |info| info.layout == .@"extern",
        else => false,
    };
}

fn sameKind(comptime A: type, comptime B: type) bool {
    const a = @typeInfo(A);
    const b = @typeInfo(B);
    return switch (a) {
        .int => |int| b == .int and b.int.signedness == int.signedness and b.int.bits == int.bits,
        .float => |float| b == .float and b.float.bits == float.bits,
        .pointer => b == .pointer,
        .optional => |optional| @typeInfo(optional.child) == .pointer and b == .pointer,
        .array => |array| b == .array and b.array.len == array.len and sameKind(array.child, b.array.child),
        .@"struct", .@"union" => std.meta.activeTag(a) == std.meta.activeTag(b) and @sizeOf(A) == @sizeOf(B),
        else => false,
    };
}

fn countLayoutMismatches(comptime Zig: type, comptime C: type) usize {
    const zig_name = @typeName(Zig);
    const c_name = @typeName(C);
    var mismatches: usize = 0;
    if (@sizeOf(Zig) != @sizeOf(C)) {
        std.debug.print("{s}: size {d}, {s}: size {d}\n", .{ zig_name, @sizeOf(Zig), c_name, @sizeOf(C) });
        mismatches += 1;
    }
    if (@alignOf(Zig) != @alignOf(C)) {
        std.debug.print("{s}: align {d}, {s}: align {d}\n", .{ zig_name, @alignOf(Zig), c_name, @alignOf(C) });
        mismatches += 1;
    }
    if (@typeInfo(Zig) == .@"union" and @typeInfo(C) != .@"union") {
        std.debug.print("{s} is a union, {s} is not\n", .{ zig_name, c_name });
        return mismatches + 1;
    }
    const zig_fields = comptime fieldLayouts(Zig);
    const c_fields = comptime fieldLayouts(C);
    if (zig_fields.len != c_fields.len) {
        std.debug.print("{s}: {d} fields, {s}: {d} fields\n", .{ zig_name, zig_fields.len, c_name, c_fields.len });
        return mismatches + 1;
    }
    inline for (zig_fields, c_fields) |zig_field, c_field| {
        if (zig_field.offset != c_field.offset or @sizeOf(zig_field.Type) != @sizeOf(c_field.Type)) {
            std.debug.print("{s}.{s}: offset {d} size {d}, {s}.{s}: offset {d} size {d}\n", .{
                zig_name, zig_field.name, zig_field.offset, @sizeOf(zig_field.Type),
                c_name,   c_field.name,   c_field.offset,   @sizeOf(c_field.Type),
            });
            mismatches += 1;
        } else if (!sameKind(zig_field.Type, c_field.Type)) {
            std.debug.print("{s}.{s}: {s}, {s}.{s}: {s}\n", .{
                zig_name, zig_field.name, @typeName(zig_field.Type),
                c_name,   c_field.name,   @typeName(c_field.Type),
            });
            mismatches += 1;
        }
    }
    return mismatches;
}

fn isPaired(comptime T: type, comptime side: usize) bool {
    inline for (struct_pairs) |pair| {
        if (pair[side] == T) return true;
    }
    return false;
}

fn isIntegerConstant(comptime name: []const u8) bool {
    return switch (@typeInfo(@TypeOf(@field(c, name)))) {
        .int, .comptime_int => true,
        else => false,
    };
}

fn isMappedConstant(comptime name: []const u8) bool {
    inline for (non_enum_constants) |constant| {
        if (comptime std.mem.eql(u8, constant, name)) return true;
    }
    inline for (export_mappings) |mapping| {
        if (@hasDecl(mapping, "fallback") and comptime std.mem.eql(u8, mapping.fallback, name)) return true;
        inline for (@typeInfo(mapping.Tag).@"enum".fields) |field| {
            if (comptime std.mem.eql(u8, constantName(mapping.prefix, field.name), name)) return true;
        }
    }
    inline for (import_mappings) |mapping| {
        if (comptime std.mem.startsWith(u8, name, mapping.prefix)) return true;
    }
    return false;
}

test "every C ABI struct has the layout orca.h declares" {
    var mismatches: usize = 0;
    inline for (struct_pairs) |pair| mismatches += countLayoutMismatches(pair[0], pair[1]);
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "every public extern type in c_api.zig is paired with an orca.h type" {
    var unpaired: usize = 0;
    inline for (@typeInfo(c_api).@"struct".decls) |decl| {
        const value = @field(c_api, decl.name);
        if (@TypeOf(value) == type and isExternContainer(value) and !isPaired(value, 0)) {
            std.debug.print("c_api.{s} has no orca.h counterpart in struct_pairs\n", .{decl.name});
            unpaired += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), unpaired);
}

test "every orca.h struct and union is paired with a c_api.zig type" {
    @setEvalBranchQuota(100_000);
    var unpaired: usize = 0;
    inline for (@typeInfo(c).@"struct".decls) |decl| {
        if (comptime !std.mem.startsWith(u8, decl.name, "orca_")) continue;
        const value = @field(c, decl.name);
        if (@TypeOf(value) == type and isExternContainer(value) and !isPaired(value, 1)) {
            std.debug.print("{s} has no c_api.zig counterpart in struct_pairs\n", .{decl.name});
            unpaired += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), unpaired);
}

test "every value the C API produces equals the orca.h constant of the same name" {
    @setEvalBranchQuota(100_000);
    var mismatches: usize = 0;
    inline for (export_mappings) |mapping| {
        inline for (@typeInfo(mapping.Tag).@"enum".fields) |field| {
            const name = comptime constantName(mapping.prefix, field.name);
            const expected_name = if (@hasDecl(c, name))
                name
            else if (@hasDecl(mapping, "fallback"))
                mapping.fallback
            else
                @compileError(name ++ " is not declared in orca.h");
            const expected: i64 = @field(c, expected_name);
            if (mapping.produce(@field(mapping.Tag, field.name))) |actual| {
                if (actual != expected) {
                    std.debug.print("{s}.{s} produces {d}, orca.h {s} = {d}\n", .{
                        @typeName(mapping.Tag), field.name, actual, expected_name, expected,
                    });
                    mismatches += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "every orca.h constant the C API accepts imports as the Zig value of the same name" {
    @setEvalBranchQuota(1_000_000);
    var mismatches: usize = 0;
    inline for (import_mappings) |mapping| {
        inline for (@typeInfo(c).@"struct".decls) |decl| {
            if (comptime !std.mem.startsWith(u8, decl.name, mapping.prefix)) continue;
            const tag_name = comptime blk: {
                var lower: [decl.name.len - mapping.prefix.len]u8 = undefined;
                for (decl.name[mapping.prefix.len..], 0..) |character, index| lower[index] = std.ascii.toLower(character);
                const final = lower;
                break :blk &final;
            };
            const value: u8 = @field(c, decl.name);
            const imported = mapping.consume(value);
            const expected = std.meta.stringToEnum(mapping.Tag, tag_name);
            if (expected == null or imported != expected) {
                std.debug.print("{s} = {d} imports as {?t}, expected {s}.{s}\n", .{
                    decl.name, value, imported, @typeName(mapping.Tag), tag_name,
                });
                mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "every orca.h enum constant is checked against liborca" {
    @setEvalBranchQuota(4_000_000);
    var unchecked: usize = 0;
    inline for (@typeInfo(c).@"struct".decls) |decl| {
        if (comptime !std.mem.startsWith(u8, decl.name, "ORCA_")) continue;
        if (comptime !isIntegerConstant(decl.name)) continue;
        if (comptime !isMappedConstant(decl.name)) {
            std.debug.print("{s} is not checked by any mapping in c_abi_layout.zig\n", .{decl.name});
            unchecked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), unchecked);
}

test "the equalizer and signal path limits orca.h declares are liborca's" {
    try std.testing.expectEqual(audio.dsp.band_count, c.ORCA_EQUALIZER_BANDS);
    try std.testing.expectEqual(audio.dsp.max_band_gain_db, @as(f32, c.ORCA_EQUALIZER_MAX_GAIN_DB));
    try std.testing.expectEqual(audio.dsp.min_preamp_db, @as(f32, c.ORCA_EQUALIZER_MIN_PREAMP_DB));
    try std.testing.expectEqual(audio.dsp.max_preamp_db, @as(f32, c.ORCA_EQUALIZER_MAX_PREAMP_DB));
    try std.testing.expect(audio.dsp.SignalPath.max_reasons <= c.ORCA_SIGNAL_MAX_REASONS);
    try std.testing.expectEqual(@as(usize, c.ORCA_SIGNAL_MAX_REASONS), @typeInfo(@FieldType(c_api.SignalPathView, "reasons")).array.len);
}

test "an unknown device format exports as ORCA_DEVICE_SAMPLE_FORMAT_UNKNOWN with every field zero" {
    const unknown = c_api.exportDeviceFormat(null);
    try std.testing.expectEqual(@as(u8, c.ORCA_DEVICE_SAMPLE_FORMAT_UNKNOWN), unknown.sample_format);
    try std.testing.expectEqual(@as(u32, 0), unknown.sample_rate);
    try std.testing.expectEqual(@as(u16, 0), unknown.channels);
    try std.testing.expectEqual(@as(u8, 0), unknown.bits_per_sample);

    const known = c_api.exportDeviceFormat(.{ .sample_format = .signed_24_32, .sample_rate = 96_000, .channels = 2 });
    try std.testing.expectEqual(@as(u8, c.ORCA_DEVICE_SAMPLE_FORMAT_SIGNED_24_32), known.sample_format);
    try std.testing.expectEqual(@as(u8, 24), known.bits_per_sample);
    try std.testing.expectEqual(@as(u32, 96_000), known.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), known.channels);
}

test "the parametric equalizer limits orca.h declares are liborca's" {
    try std.testing.expectEqual(audio.dsp.max_parametric_filters, c.ORCA_PARAMETRIC_MAX_FILTERS);
    try std.testing.expectEqual(@as(usize, c.ORCA_PARAMETRIC_MAX_FILTERS), @typeInfo(@FieldType(c_api.ParametricEqualizerView, "filters")).array.len);
    try std.testing.expectEqual(audio.dsp.min_filter_frequency_hz, @as(f32, c.ORCA_PARAMETRIC_MIN_FREQUENCY_HZ));
    try std.testing.expectEqual(audio.dsp.max_filter_frequency_hz, @as(f32, c.ORCA_PARAMETRIC_MAX_FREQUENCY_HZ));
    try std.testing.expectEqual(audio.dsp.max_filter_gain_db, @as(f32, c.ORCA_PARAMETRIC_MAX_GAIN_DB));
    try std.testing.expectEqual(audio.dsp.min_filter_q, @as(f32, c.ORCA_PARAMETRIC_MIN_Q));
    try std.testing.expectEqual(audio.dsp.max_filter_q, @as(f32, c.ORCA_PARAMETRIC_MAX_Q));
    try std.testing.expectEqual(audio.dsp.min_shelf_q, @as(f32, c.ORCA_PARAMETRIC_MIN_SHELF_Q));
    try std.testing.expectEqual(audio.dsp.max_shelf_q, @as(f32, c.ORCA_PARAMETRIC_MAX_SHELF_Q));
    try std.testing.expectEqual(audio.dsp.min_parametric_preamp_db, @as(f32, c.ORCA_PARAMETRIC_MIN_PREAMP_DB));
    try std.testing.expectEqual(audio.dsp.max_parametric_preamp_db, @as(f32, c.ORCA_PARAMETRIC_MAX_PREAMP_DB));
}

test "the tag-write digest orca.h declares is as long as liborca's" {
    try std.testing.expectEqual(@as(usize, c.ORCA_TAG_WRITE_DIGEST_BYTES), @sizeOf(metadata.mutation.Digest));
    try std.testing.expectEqual(@as(usize, c.ORCA_TAG_WRITE_DIGEST_BYTES), @typeInfo(@FieldType(c_api.TagWriteDigest, "bytes")).array.len);
}

test "the lyrics fetch flag orca.h declares is liborca's" {
    try std.testing.expectEqual(@as(u8, c.ORCA_LYRICS_FETCH), c_api.lyrics_fetch_flag);
}

test "the device bit depths orca.h declares are liborca's" {
    const Capabilities = audio.backend.DeviceCapabilities;
    try std.testing.expectEqual(@as(u8, c.ORCA_DEVICE_BIT_DEPTH_16), Capabilities.bit_depth_16);
    try std.testing.expectEqual(@as(u8, c.ORCA_DEVICE_BIT_DEPTH_24), Capabilities.bit_depth_24);
    try std.testing.expectEqual(@as(u8, c.ORCA_DEVICE_BIT_DEPTH_32), Capabilities.bit_depth_32);
}

test "the credential limit and names orca.h declares are liborca's" {
    try std.testing.expectEqual(@as(usize, c.ORCA_CREDENTIAL_MAX_BYTES), c_api.credential_max_bytes);
    try std.testing.expectEqualStrings(liborca.listenbrainz_token_service, c.ORCA_CREDENTIAL_SERVICE_LISTENBRAINZ);
    try std.testing.expectEqualStrings(liborca.listenbrainz_token_account, c.ORCA_CREDENTIAL_ACCOUNT_USER_TOKEN);
    try std.testing.expectEqualStrings(liborca.acoustid_credential_service, c.ORCA_CREDENTIAL_SERVICE_ACOUSTID);
    try std.testing.expectEqualStrings(liborca.acoustid_client_key_account, c.ORCA_CREDENTIAL_ACCOUNT_CLIENT_KEY);
    try std.testing.expectEqualStrings(liborca.acoustid_user_key_account, c.ORCA_CREDENTIAL_ACCOUNT_USER_KEY);
}

test "the waiting-job bound orca.h declares is liborca's" {
    try std.testing.expectEqual(@as(usize, c.ORCA_MAX_WAITING_JOBS), liborca.max_waiting_jobs);
}

test "a finished job is reported as a job_finished event carrying its state" {
    const event = c_api.exportCompletion(.{ .request_id = 1, .outcome = sampleOutcome(.job_finished) });
    try std.testing.expectEqual(@as(u8, c.ORCA_EVENT_JOB_FINISHED), event.kind);
    try std.testing.expectEqual(@as(u8, c.ORCA_JOB_SUCCEEDED), event.payload.job_finished.state);
}
