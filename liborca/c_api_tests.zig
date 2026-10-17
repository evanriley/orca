const builtin = @import("builtin");
const std = @import("std");
const audio = @import("audio/root.zig");
const audio_embedding = @import("analysis/audio_embedding.zig");
const control = @import("core/control.zig");
const core = @import("core/root.zig");
const daily_mixes = @import("library/daily_mixes.zig");
const database = @import("database/root.zig");
const discovery = @import("library/discovery.zig");
const job = @import("core/job.zig");
const metadata = @import("metadata/root.zig");
const network = @import("network/root.zig");
const providers = @import("providers/root.zig");
const version = @import("version.zig");

const c_api = @import("c_api.zig");

const AcoustIdSubmittableView = c_api.AcoustIdSubmittableView;
const ArtistInfoOptionsView = c_api.ArtistInfoOptionsView;
const ArtistInfoView = c_api.ArtistInfoView;
const ArtistLinkView = c_api.ArtistLinkView;
const ArtistQueryV2View = c_api.ArtistQueryV2View;
const ArtistQueryView = c_api.ArtistQueryView;
const ArtistSortKey = c_api.ArtistSortKey;
const ArtistTotalsView = c_api.ArtistTotalsView;
const ArtistView = c_api.ArtistView;
const ArtistViewV2 = c_api.ArtistViewV2;
const ArtworkResultView = c_api.ArtworkResultView;
const AudioFeaturesView = c_api.AudioFeaturesView;
const CacheSizeView = c_api.CacheSizeView;
const ChangeCount = c_api.ChangeCount;
const ConfidentAcceptanceView = c_api.ConfidentAcceptanceView;
const CorrectionGroupView = c_api.CorrectionGroupView;
const credential_max_bytes = c_api.credential_max_bytes;
const CredentialResult = c_api.CredentialResult;
const CredentialSlot = c_api.CredentialSlot;
const DailyMixEntriesView = c_api.DailyMixEntriesView;
const DailyMixEntryView = c_api.DailyMixEntryView;
const DailyMixesView = c_api.DailyMixesView;
const DailyMixView = c_api.DailyMixView;
const DeviceFormatView = c_api.DeviceFormatView;
const DiscoverySettingsView = c_api.DiscoverySettingsView;
const EqualizerView = c_api.EqualizerView;
const Event = c_api.Event;
const EventKind = c_api.EventKind;
const exportAcoustIdUse = c_api.exportAcoustIdUse;
const exportCoverArtOutcome = c_api.exportCoverArtOutcome;
const exportDeviceKind = c_api.exportDeviceKind;
const exportHealthIssueKind = c_api.exportHealthIssueKind;
const exportJobHandle = c_api.exportJobHandle;
const exportJobKind = c_api.exportJobKind;
const exportJobOrigin = c_api.exportJobOrigin;
const exportLibraryHandle = c_api.exportLibraryHandle;
const exportLyricsKind = c_api.exportLyricsKind;
const exportLyricsOutcome = c_api.exportLyricsOutcome;
const exportLyricsSource = c_api.exportLyricsSource;
const exportMaintenanceBlock = c_api.exportMaintenanceBlock;
const exportMaintenanceState = c_api.exportMaintenanceState;
const exportMetadataField = c_api.exportMetadataField;
const exportProvenance = c_api.exportProvenance;
const exportRadioOptions = c_api.exportRadioOptions;
const exportReplayGainSource = c_api.exportReplayGainSource;
const exportScrobblerState = c_api.exportScrobblerState;
const exportSignalReason = c_api.exportSignalReason;
const exportSubmissionOutcome = c_api.exportSubmissionOutcome;
const exportTagWriteSkipReason = c_api.exportTagWriteSkipReason;
const exportUntaggedFallback = c_api.exportUntaggedFallback;
const exportVerificationOutcome = c_api.exportVerificationOutcome;
const FieldValueView = c_api.FieldValueView;
const GenreCountView = c_api.GenreCountView;
const GenreFillOptionsView = c_api.GenreFillOptionsView;
const GenreFillView = c_api.GenreFillView;
const GenreQueryView = c_api.GenreQueryView;
const GenreSortKey = c_api.GenreSortKey;
const GenreView = c_api.GenreView;
const Handle = c_api.Handle;
const HealthFileView = c_api.HealthFileView;
const HealthIssueView = c_api.HealthIssueView;
const HealthItemView = c_api.HealthItemView;
const HealthKindSummaryViewV2 = c_api.HealthKindSummaryViewV2;
const hostCredential = c_api.hostCredential;
const IdSource = c_api.IdSource;
const ImageView = c_api.ImageView;
const importJob = c_api.importJob;
const importLibrary = c_api.importLibrary;
const importPlayer = c_api.importPlayer;
const importRadioOptions = c_api.importRadioOptions;
const JobSnapshot = c_api.JobSnapshot;
const last_error_capacity = c_api.last_error_capacity;
const LibraryStatsView = c_api.LibraryStatsView;
const LibraryStatsViewV2 = c_api.LibraryStatsViewV2;
const lyrics_fetch_flag = c_api.lyrics_fetch_flag;
const LyricsView = c_api.LyricsView;
const MaintenanceStatus = c_api.MaintenanceStatus;
const mapError = c_api.mapError;
const MatchAcceptanceView = c_api.MatchAcceptanceView;
const MatchOptions = c_api.MatchOptions;
const MatchProposalView = c_api.MatchProposalView;
const MatchReviewView = c_api.MatchReviewView;
const MatchStatsView = c_api.MatchStatsView;
const MatchStatsViewV2 = c_api.MatchStatsViewV2;
const max_page = c_api.max_page;
const max_track_edits = c_api.max_track_edits;
const orca_equalizer_preset_get = c_api.orca_equalizer_preset_get;
const orca_job_artist_info_outcome = c_api.orca_job_artist_info_outcome;
const orca_job_artist_info_stores = c_api.orca_job_artist_info_stores;
const orca_job_cancel = c_api.orca_job_cancel;
const orca_job_lyrics = c_api.orca_job_lyrics;
const orca_job_lyrics_outcome = c_api.orca_job_lyrics_outcome;
const orca_job_match_release = c_api.orca_job_match_release;
const orca_job_match_stats = c_api.orca_job_match_stats;
const orca_job_match_stats_v2 = c_api.orca_job_match_stats_v2;
const orca_job_origin_get = c_api.orca_job_origin_get;
const orca_job_reconcile_root = c_api.orca_job_reconcile_root;
const orca_job_release_info_outcome = c_api.orca_job_release_info_outcome;
const orca_job_snapshot_get = c_api.orca_job_snapshot_get;
const orca_job_submission_stats = c_api.orca_job_submission_stats;
const orca_job_tag_write_failure = c_api.orca_job_tag_write_failure;
const orca_library_accept_confident_matches = c_api.orca_library_accept_confident_matches;
const orca_library_accept_correction_group = c_api.orca_library_accept_correction_group;
const orca_library_accept_match = c_api.orca_library_accept_match;
const orca_library_acoustid_submittable_count = c_api.orca_library_acoustid_submittable_count;
const orca_library_acoustid_submitted_count = c_api.orca_library_acoustid_submitted_count;
const orca_library_analysis_coverage = c_api.orca_library_analysis_coverage;
const orca_library_apply_matched_release = c_api.orca_library_apply_matched_release;
const orca_library_artist_count_matching = c_api.orca_library_artist_count_matching;
const orca_library_artist_count_matching_v2 = c_api.orca_library_artist_count_matching_v2;
const orca_library_artist_info = c_api.orca_library_artist_info;
const orca_library_artist_links = c_api.orca_library_artist_links;
const orca_library_artist_loved = c_api.orca_library_artist_loved;
const orca_library_artist_photo = c_api.orca_library_artist_photo;
const orca_library_artist_totals = c_api.orca_library_artist_totals;
const orca_library_backfill_pending = c_api.orca_library_backfill_pending;
const orca_library_browse_artists = c_api.orca_library_browse_artists;
const orca_library_browse_releases = c_api.orca_library_browse_releases;
const orca_library_browse_releases_v2 = c_api.orca_library_browse_releases_v2;
const orca_library_browse_tracks = c_api.orca_library_browse_tracks;
const orca_library_browse_tracks_v2 = c_api.orca_library_browse_tracks_v2;
const orca_library_cache_size = c_api.orca_library_cache_size;
const orca_library_cancel_artwork = c_api.orca_library_cancel_artwork;
const orca_library_clear_cache = c_api.orca_library_clear_cache;
const orca_library_clear_listens = c_api.orca_library_clear_listens;
const orca_library_clear_not_for_me = c_api.orca_library_clear_not_for_me;
const orca_library_close = c_api.orca_library_close;
const orca_library_confident_match_count = c_api.orca_library_confident_match_count;
const orca_library_create_playlist = c_api.orca_library_create_playlist;
const orca_library_create_smart_playlist = c_api.orca_library_create_smart_playlist;
const orca_library_daily_mix_entries = c_api.orca_library_daily_mix_entries;
const orca_library_daily_mixes = c_api.orca_library_daily_mixes;
const orca_library_delete_playlist = c_api.orca_library_delete_playlist;
const orca_library_discard_tag_write = c_api.orca_library_discard_tag_write;
const orca_library_discovery_settings = c_api.orca_library_discovery_settings;
const orca_library_dismiss_correction_group = c_api.orca_library_dismiss_correction_group;
const orca_library_dismiss_health_issue = c_api.orca_library_dismiss_health_issue;
const orca_library_dismiss_match = c_api.orca_library_dismiss_match;
const orca_library_edit_tracks = c_api.orca_library_edit_tracks;
const orca_library_export_playlist = c_api.orca_library_export_playlist;
const orca_library_genre_artwork = c_api.orca_library_genre_artwork;
const orca_library_genre_count = c_api.orca_library_genre_count;
const orca_library_genre_fill = c_api.orca_library_genre_fill;
const orca_library_genre_get = c_api.orca_library_genre_get;
const orca_library_health_file = c_api.orca_library_health_file;
const orca_library_health_issue_count = c_api.orca_library_health_issue_count;
const orca_library_health_summary_v2 = c_api.orca_library_health_summary_v2;
const orca_library_import_playlist = c_api.orca_library_import_playlist;
const orca_library_listen_policy = c_api.orca_library_listen_policy;
const orca_library_listen_recording = c_api.orca_library_listen_recording;
const orca_library_listens_recorded = c_api.orca_library_listens_recorded;
const orca_library_maintenance_status = c_api.orca_library_maintenance_status;
const orca_library_match_review_count = c_api.orca_library_match_review_count;
const orca_library_not_for_me = c_api.orca_library_not_for_me;
const orca_library_open = c_api.orca_library_open;
const orca_library_plan_tag_write = c_api.orca_library_plan_tag_write;
const orca_library_playlist_count = c_api.orca_library_playlist_count;
const orca_library_playlist_genres = c_api.orca_library_playlist_genres;
const orca_library_playlist_get = c_api.orca_library_playlist_get;
const orca_library_playlist_insert = c_api.orca_library_playlist_insert;
const orca_library_playlist_move = c_api.orca_library_playlist_move;
const orca_library_playlist_remove = c_api.orca_library_playlist_remove;
const orca_library_playlist_tags = c_api.orca_library_playlist_tags;
const orca_library_prune_tag_write_backups = c_api.orca_library_prune_tag_write_backups;
const orca_library_query_acoustid_submittable = c_api.orca_library_query_acoustid_submittable;
const orca_library_query_artists_v2 = c_api.orca_library_query_artists_v2;
const orca_library_query_correction_groups = c_api.orca_library_query_correction_groups;
const orca_library_query_genres = c_api.orca_library_query_genres;
const orca_library_query_health_issues = c_api.orca_library_query_health_issues;
const orca_library_query_health_items = c_api.orca_library_query_health_items;
const orca_library_query_match_proposals = c_api.orca_library_query_match_proposals;
const orca_library_query_match_review = c_api.orca_library_query_match_review;
const orca_library_query_playlist_entries = c_api.orca_library_query_playlist_entries;
const orca_library_query_playlists = c_api.orca_library_query_playlists;
const orca_library_query_playlists_v2 = c_api.orca_library_query_playlists_v2;
const orca_library_query_tag_write_genres = c_api.orca_library_query_tag_write_genres;
const orca_library_query_track_edits = c_api.orca_library_query_track_edits;
const orca_library_query_tracks = c_api.orca_library_query_tracks;
const orca_library_radio_preview = c_api.orca_library_radio_preview;
const orca_library_related_artist_photo = c_api.orca_library_related_artist_photo;
const orca_library_related_artist_photo_info = c_api.orca_library_related_artist_photo_info;
const orca_library_related_artists = c_api.orca_library_related_artists;
const orca_library_release_artwork = c_api.orca_library_release_artwork;
const orca_library_release_count_matching = c_api.orca_library_release_count_matching;
const orca_library_release_count_matching_v2 = c_api.orca_library_release_count_matching_v2;
const orca_library_release_genres = c_api.orca_library_release_genres;
const orca_library_release_info = c_api.orca_library_release_info;
const orca_library_rename_playlist = c_api.orca_library_rename_playlist;
const orca_library_request_artwork = c_api.orca_library_request_artwork;
const orca_library_reset_recommendations = c_api.orca_library_reset_recommendations;
const orca_library_restore_health_issue = c_api.orca_library_restore_health_issue;
const orca_library_save_daily_mix = c_api.orca_library_save_daily_mix;
const orca_library_scrobbler_credentials_changed = c_api.orca_library_scrobbler_credentials_changed;
const orca_library_scrobbler_status = c_api.orca_library_scrobbler_status;
const orca_library_set_artist_love = c_api.orca_library_set_artist_love;
const orca_library_set_discovery_settings = c_api.orca_library_set_discovery_settings;
const orca_library_set_feedback = c_api.orca_library_set_feedback;
const orca_library_set_genre_fill = c_api.orca_library_set_genre_fill;
const orca_library_set_listen_policy = c_api.orca_library_set_listen_policy;
const orca_library_set_listen_recording = c_api.orca_library_set_listen_recording;
const orca_library_set_maintenance = c_api.orca_library_set_maintenance;
const orca_library_set_rating = c_api.orca_library_set_rating;
const orca_library_set_release_love = c_api.orca_library_set_release_love;
const orca_library_set_scrobbling = c_api.orca_library_set_scrobbling;
const orca_library_set_smart_playlist_rules = c_api.orca_library_set_smart_playlist_rules;
const orca_library_set_track_genres = c_api.orca_library_set_track_genres;
const orca_library_similar_tracks = c_api.orca_library_similar_tracks;
const orca_library_smart_playlist_count = c_api.orca_library_smart_playlist_count;
const orca_library_smart_playlist_rules = c_api.orca_library_smart_playlist_rules;
const orca_library_start_acoustid_submission = c_api.orca_library_start_acoustid_submission;
const orca_library_start_artist_info = c_api.orca_library_start_artist_info;
const orca_library_start_cover_art_fetch = c_api.orca_library_start_cover_art_fetch;
const orca_library_start_daily_mixes = c_api.orca_library_start_daily_mixes;
const orca_library_start_genre_fill = c_api.orca_library_start_genre_fill;
const orca_library_start_lyrics = c_api.orca_library_start_lyrics;
const orca_library_start_match = c_api.orca_library_start_match;
const orca_library_start_projection = c_api.orca_library_start_projection;
const orca_library_start_release_info = c_api.orca_library_start_release_info;
const orca_library_start_tag_write = c_api.orca_library_start_tag_write;
const orca_library_stats = c_api.orca_library_stats;
const orca_library_stats_v2 = c_api.orca_library_stats_v2;
const orca_library_take_artwork = c_api.orca_library_take_artwork;
const orca_library_track_artwork = c_api.orca_library_track_artwork;
const orca_library_track_audio_features = c_api.orca_library_track_audio_features;
const orca_library_track_count = c_api.orca_library_track_count;
const orca_library_track_details = c_api.orca_library_track_details;
const orca_library_track_feedback = c_api.orca_library_track_feedback;
const orca_library_track_get = c_api.orca_library_track_get;
const orca_library_track_match_count = c_api.orca_library_track_match_count;
const orca_library_track_match_count_v2 = c_api.orca_library_track_match_count_v2;
const orca_library_track_play_stats = c_api.orca_library_track_play_stats;
const orca_library_track_verification = c_api.orca_library_track_verification;
const orca_library_unanalyzed_count = c_api.orca_library_unanalyzed_count;
const orca_library_undo_tag_write = c_api.orca_library_undo_tag_write;
const orca_library_unidentified_count = c_api.orca_library_unidentified_count;
const orca_library_update_playlist = c_api.orca_library_update_playlist;
const orca_player_clear_queue_history = c_api.orca_player_clear_queue_history;
const orca_player_create = c_api.orca_player_create;
const orca_player_crossfeed = c_api.orca_player_crossfeed;
const orca_player_destroy = c_api.orca_player_destroy;
const orca_player_equalizer = c_api.orca_player_equalizer;
const orca_player_play = c_api.orca_player_play;
const orca_player_play_playlist = c_api.orca_player_play_playlist;
const orca_player_play_track = c_api.orca_player_play_track;
const orca_player_play_tracks = c_api.orca_player_play_tracks;
const orca_player_query_queue_history = c_api.orca_player_query_queue_history;
const orca_player_query_queue_tracks = c_api.orca_player_query_queue_tracks;
const orca_player_queue_insert_next = c_api.orca_player_queue_insert_next;
const orca_player_queue_jump = c_api.orca_player_queue_jump;
const orca_player_queue_move = c_api.orca_player_queue_move;
const orca_player_queue_remove = c_api.orca_player_queue_remove;
const orca_player_queue_stats = c_api.orca_player_queue_stats;
const orca_player_replay_gain_settings = c_api.orca_player_replay_gain_settings;
const orca_player_save_queue_as_playlist = c_api.orca_player_save_queue_as_playlist;
const orca_player_seek = c_api.orca_player_seek;
const orca_player_seek_ms = c_api.orca_player_seek_ms;
const orca_player_set_crossfeed = c_api.orca_player_set_crossfeed;
const orca_player_set_equalizer = c_api.orca_player_set_equalizer;
const orca_player_set_library = c_api.orca_player_set_library;
const orca_player_set_peak_protection = c_api.orca_player_set_peak_protection;
const orca_player_set_replay_gain_fallback = c_api.orca_player_set_replay_gain_fallback;
const orca_player_set_replay_gain_mode = c_api.orca_player_set_replay_gain_mode;
const orca_player_set_replay_gain_preamp = c_api.orca_player_set_replay_gain_preamp;
const orca_player_set_stop_after_current = c_api.orca_player_set_stop_after_current;
const orca_player_set_volume = c_api.orca_player_set_volume;
const orca_player_signal_path = c_api.orca_player_signal_path;
const orca_player_signal_path_v2 = c_api.orca_player_signal_path_v2;
const orca_player_status_get = c_api.orca_player_status_get;
const orca_player_stop_after_current = c_api.orca_player_stop_after_current;
const orca_player_volume = c_api.orca_player_volume;
const orca_provider_sources = c_api.orca_provider_sources;
const orca_runtime_create = c_api.orca_runtime_create;
const orca_runtime_destroy = c_api.orca_runtime_destroy;
const orca_runtime_embedding_model = c_api.orca_runtime_embedding_model;
const orca_runtime_embedding_model_state = c_api.orca_runtime_embedding_model_state;
const orca_runtime_last_error = c_api.orca_runtime_last_error;
const orca_runtime_poll_event = c_api.orca_runtime_poll_event;
const orca_runtime_pump = c_api.orca_runtime_pump;
const orca_runtime_pump_timeout = c_api.orca_runtime_pump_timeout;
const orca_runtime_set_acoustid_client_key = c_api.orca_runtime_set_acoustid_client_key;
const orca_runtime_set_client_identity = c_api.orca_runtime_set_client_identity;
const orca_runtime_set_credential_callback = c_api.orca_runtime_set_credential_callback;
const orca_runtime_set_embedding_model_path = c_api.orca_runtime_set_embedding_model_path;
const orca_runtime_set_provider_server = c_api.orca_runtime_set_provider_server;
const orca_runtime_set_wake_callback = c_api.orca_runtime_set_wake_callback;
const orca_runtime_start_embedding_model_download = c_api.orca_runtime_start_embedding_model_download;
const orca_version = c_api.orca_version;
const PlayerStatus = c_api.PlayerStatus;
const PlaylistEntryView = c_api.PlaylistEntryView;
const PlaylistFactsView = c_api.PlaylistFactsView;
const PlaylistImport = c_api.PlaylistImport;
const PlaylistQueryView = c_api.PlaylistQueryView;
const PlaylistSortKey = c_api.PlaylistSortKey;
const PlaylistUpdateView = c_api.PlaylistUpdateView;
const PlaylistView = c_api.PlaylistView;
const PlayStatsView = c_api.PlayStatsView;
const ProviderSourceView = c_api.ProviderSourceView;
const pump_no_timeout = c_api.pump_no_timeout;
const QueueStats = c_api.QueueStats;
const RadioOptionsView = c_api.RadioOptionsView;
const RadioPreviewSessionView = c_api.RadioPreviewSessionView;
const RadioPreviewView = c_api.RadioPreviewView;
const RadioSeedView = c_api.RadioSeedView;
const RelatedArtistPhotoInfoView = c_api.RelatedArtistPhotoInfoView;
const RelatedArtistView = c_api.RelatedArtistView;
const ReleaseArtworkFilter = c_api.ReleaseArtworkFilter;
const ReleaseFactsView = c_api.ReleaseFactsView;
const ReleaseInfoOptionsView = c_api.ReleaseInfoOptionsView;
const ReleaseInfoView = c_api.ReleaseInfoView;
const ReleaseKindFilter = c_api.ReleaseKindFilter;
const ReleaseQueryV2View = c_api.ReleaseQueryV2View;
const ReleaseQueryView = c_api.ReleaseQueryView;
const ReleaseView = c_api.ReleaseView;
const ReplayGainSettingsView = c_api.ReplayGainSettingsView;
const Runtime = c_api.Runtime;
const runtimeBox = c_api.runtimeBox;
const RuntimeBox = c_api.RuntimeBox;
const ScrobblerStatusView = c_api.ScrobblerStatusView;
const SignalPathView = c_api.SignalPathView;
const SignalPathViewV2 = c_api.SignalPathViewV2;
const SimilarTrackView = c_api.SimilarTrackView;
const Status = c_api.Status;
const StringInput = @FieldType(c_api.PlaylistUpdateView, "description");
const StringView = c_api.StringView;
const SubmissionStatsView = c_api.SubmissionStatsView;
const TagWriteDigest = c_api.TagWriteDigest;
const TagWriteFailureView = c_api.TagWriteFailureView;
const TagWriteGenresView = c_api.TagWriteGenresView;
const TagWritePlanView = c_api.TagWritePlanView;
const TrackDetailsView = c_api.TrackDetailsView;
const TrackEditView = c_api.TrackEditView;
const TrackFactsView = c_api.TrackFactsView;
const TrackFormatFilter = c_api.TrackFormatFilter;
const TrackQueryV2View = c_api.TrackQueryV2View;
const TrackQueryView = c_api.TrackQueryView;
const TrackSortKey = c_api.TrackSortKey;
const TrackSummaryView = c_api.TrackSummaryView;
const TrackVerificationView = c_api.TrackVerificationView;
const TrackView = c_api.TrackView;

test "a Player with nothing to play and nowhere to play it refuses to start" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.invalid_state, orca_player_play(runtime, player));
    var status: PlayerStatus = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_status_get(runtime, player, &status));
    try std.testing.expectEqual(@as(u8, 0), status.transport);
    try std.testing.expectEqual(@as(u8, 0), status.has_track);
    try std.testing.expectEqual(@as(u32, 0), status.queue_length);
    try std.testing.expectEqual(@as(f32, 1), status.volume);
    try std.testing.expectEqual(Status.ok, orca_player_set_volume(runtime, player, 0.5));
    var volume: f32 = 0;
    try std.testing.expectEqual(Status.ok, orca_player_volume(runtime, player, &volume));
    try std.testing.expectEqual(@as(f32, 0.5), volume);
    // Milliseconds cannot be converted without a loaded source, and the
    // boundary says so rather than seeking to frame zero.
    try std.testing.expectEqual(
        Status.invalid_state,
        orca_player_seek_ms(runtime, player, 1000, null),
    );
    var generation: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_player_seek(runtime, player, 48_000, &generation));
    try std.testing.expect(generation > 1);
    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_status_get(runtime, player, &status));
}

test "C ABI library query is bounded and callback-scoped" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api?mode=memory&cache=shared",
        &library,
    ));
    const box = runtimeBox(runtime).?;
    try (try core.runtime.databaseOf(&box.runtime, importLibrary(library))).tracks.upsertTracks(&.{
        .{ .title = "First", .album = "Generated", .album_artist = "Orca" },
        .{ .title = "Second", .album = "Generated", .album_artist = "Orca" },
    });
    var count: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_track_count(runtime, library, &count));
    try std.testing.expectEqual(@as(u64, 2), count);
    var visited: usize = 0;
    try std.testing.expectEqual(Status.ok, orca_library_query_tracks(
        runtime,
        library,
        null,
        0,
        1,
        1,
        &visited,
        countTrack,
    ));
    try std.testing.expectEqual(@as(usize, 1), visited);
    const library_database = try core.runtime.databaseOf(&box.runtime, importLibrary(library));
    const file_id = try library_database.files.create(.{ .size_bytes = 1024 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = @import("database/root.zig").LibraryDatabase.null_volume,
        .uri = "track.flac",
    });
    try library_database.health_issues.replaceFile(file_id, &.{.{
        .kind = .clipping,
        .severity = .warning,
        .details = "clipped",
    }});
    try std.testing.expectEqual(Status.ok, orca_library_health_issue_count(runtime, library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_query_health_issues(
        runtime,
        library,
        10,
        0,
        &visited,
        countHealthIssue,
    ));
    try std.testing.expectEqual(@as(usize, 1), visited);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "the wake callback fires on a submitted command and the pump timeout follows it" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var counter: control.CountingWaker = .{};
    const waker = counter.waker();
    try std.testing.expectEqual(Status.ok, orca_runtime_set_wake_callback(runtime, waker.wake_fn, waker.context));
    var timeout: i64 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_pump_timeout(runtime, null));
    try std.testing.expectEqual(Status.ok, orca_runtime_pump_timeout(runtime, &timeout));
    try std.testing.expectEqual(pump_no_timeout, timeout);

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-wake?mode=memory&cache=shared", &library));
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.ok, orca_player_set_library(runtime, player, library));
    var request_id: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_player_play_track(runtime, player, 1, &request_id));
    try std.testing.expectEqual(@as(u32, 1), counter.count());
    try std.testing.expectEqual(Status.ok, orca_runtime_pump_timeout(runtime, &timeout));
    try std.testing.expectEqual(@as(i64, 0), timeout);

    try std.testing.expectEqual(Status.ok, orca_runtime_pump(runtime));
    var event: Event = undefined;
    var completed = false;
    while (true) {
        try std.testing.expectEqual(Status.ok, orca_runtime_poll_event(runtime, &event, null));
        if (event.kind == @backingInt(EventKind.none)) break;
        if (event.kind == @backingInt(EventKind.command_completed) and
            event.payload.command_completed.request_id == request_id) completed = true;
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(Status.ok, orca_runtime_pump_timeout(runtime, &timeout));
    try std.testing.expectEqual(pump_no_timeout, timeout);

    try std.testing.expectEqual(Status.invalid_state, orca_runtime_set_wake_callback(runtime, null, null));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_wake_callback: WorkersRunning",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
}

test "orca_version is liborca's version" {
    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint("{f}", .{version.value}),
        std.mem.span(orca_version()),
    );
}

test "a failing call leaves its function and reason as the last error, and the next successful call clears it" {
    try std.testing.expectEqualStrings("", std.mem.span(orca_runtime_last_error(null)));
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    try std.testing.expectEqualStrings("", std.mem.span(orca_runtime_last_error(runtime)));

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_open(runtime, null, &library));
    try std.testing.expectEqualStrings("orca_library_open: path is null", std.mem.span(orca_runtime_last_error(runtime)));

    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqualStrings("", std.mem.span(orca_runtime_last_error(runtime)));

    try std.testing.expectEqual(Status.invalid_state, orca_player_play(runtime, player));
    try std.testing.expectEqualStrings("orca_player_play: PlayerHasNoSource", std.mem.span(orca_runtime_last_error(runtime)));
}

test "a call refused for its thread leaves the owner's last error untouched" {
    if (builtin.mode != .debug) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_open(runtime, null, &library));

    var status: Status = .ok;
    const thread = try std.Thread.spawn(.{}, playFromAnotherThread, .{ runtime, &status });
    thread.join();

    try std.testing.expectEqual(Status.wrong_thread, status);
    try std.testing.expectEqualStrings("orca_library_open: path is null", std.mem.span(orca_runtime_last_error(runtime)));
}

fn playFromAnotherThread(runtime: *Runtime, status: *Status) void {
    status.* = orca_player_play(runtime, .{ .index = 0, .generation = 0 });
}

test "a destroy from another thread is refused in debug builds and leaves the runtime usable" {
    if (builtin.mode != .debug) return error.SkipZigTest;
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_open(runtime, null, &library));

    const thread = try std.Thread.spawn(.{}, orca_runtime_destroy, .{runtime});
    thread.join();

    try std.testing.expectEqualStrings("orca_library_open: path is null", std.mem.span(orca_runtime_last_error(runtime)));
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-foreign-destroy?mode=memory&cache=shared", &library));
}

test "two runtimes share the SQLite lock replacement and destroying one leaves it for the other" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const first = orca_runtime_create() orelse return error.OutOfMemory;
    const second = orca_runtime_create() orelse {
        orca_runtime_destroy(first);
        return error.OutOfMemory;
    };
    defer orca_runtime_destroy(second);
    try std.testing.expect(database.sqlite_locks.active());
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(first, "file:orca-c-api-first-runtime?mode=memory&cache=shared", &library));
    try std.testing.expectEqual(Status.ok, orca_library_open(second, "file:orca-c-api-second-runtime?mode=memory&cache=shared", &library));

    orca_runtime_destroy(first);

    try std.testing.expect(database.sqlite_locks.active());
    try std.testing.expectEqual(Status.ok, orca_library_open(second, "file:orca-c-api-after-first-runtime?mode=memory&cache=shared", &library));
}

test "a last error longer than its buffer is truncated and stays terminated" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    box.recordError("orca_library_open", &@as([400]u8, @splat('x')));
    const message = std.mem.span(orca_runtime_last_error(runtime));
    try std.testing.expectEqual(@as(usize, last_error_capacity), message.len);
    try std.testing.expect(std.mem.startsWith(u8, message, "orca_library_open: xxx"));
}

test "browse queries refuse an unknown sort, an unbounded limit and null pointers" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-browse?mode=memory&cache=shared",
        &library,
    ));
    var visited: usize = 0;
    var count: u64 = 0;

    var releases: ReleaseQueryView = .{ .album_artist_id = -1, .sort = 6, .loved_only = 0, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, &releases, &visited, countRelease));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching(runtime, library, &releases, &count));
    releases.sort = 4;
    releases.limit = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, &releases, &visited, countRelease));
    releases.limit = max_page + 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, &releases, &visited, countRelease));
    releases.limit = max_page;
    try std.testing.expectEqual(Status.ok, orca_library_browse_releases(runtime, library, &releases, &visited, countRelease));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, null, &visited, countRelease));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, &releases, &visited, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching(runtime, library, null, &count));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching(runtime, library, &releases, null));

    var artists: ArtistQueryView = .{ .filter = .{ .pointer = null, .length = 3 }, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_artists(runtime, library, &artists, &visited, countArtist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching(runtime, library, &artists, &count));
    artists.filter.length = 0;
    try std.testing.expectEqual(Status.ok, orca_library_artist_count_matching(runtime, library, &artists, &count));
    artists.limit = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_artists(runtime, library, &artists, &visited, countArtist));
    artists.limit = max_page + 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_artists(runtime, library, &artists, &visited, countArtist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_artists(runtime, library, null, &visited, countArtist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching(runtime, library, null, &count));
    artists.limit = 8;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching(runtime, library, &artists, null));

    var tracks: TrackQueryView = .{ .artist_id = -1, .release_id = -1, .sort = 12, .descending = 0, .loved_only = 1, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks(runtime, library, &tracks, &visited, countTrack));
    tracks.sort = @backingInt(TrackSortKey.loved);
    try std.testing.expectEqual(Status.ok, orca_library_track_match_count(runtime, library, &tracks, &count));

    var tracks_v2: TrackQueryV2View = .{ .artist_id = 0, .release_id = 0, .genre_id = 0, .sort = 12, .descending = 0, .loved_only = 0, .has_artist_id = 0, .has_release_id = 0, .has_genre_id = 0, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    tracks_v2.sort = @backingInt(TrackSortKey.year);
    tracks_v2.has_genre_id = 1;
    tracks_v2.genre_id = 1;
    try std.testing.expectEqual(Status.ok, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    tracks_v2.has_genre_id = 0;
    tracks_v2.limit = max_page + 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    tracks_v2.limit = 8;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, null, &visited, countSummaryFacts));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    tracks_v2.format = @backingInt(TrackFormatFilter.lossless);
    tracks_v2.has_year_min = 1;
    tracks_v2.year_min = 1990;
    tracks_v2.min_sample_rate = 44_100;
    tracks_v2.explicit_only = 1;
    try std.testing.expectEqual(Status.ok, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    try std.testing.expectEqual(Status.ok, orca_library_track_match_count_v2(runtime, library, &tracks_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_match_count_v2(runtime, library, &tracks_v2, null));
    tracks_v2.format = 3;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_match_count_v2(runtime, library, &tracks_v2, &count));
    tracks_v2.format = @backingInt(TrackFormatFilter.any);

    var releases_v2: ReleaseQueryV2View = .{ .album_artist_id = 0, .genre_id = 1, .sort = 6, .loved_only = 0, .has_album_artist_id = 0, .has_genre_id = 1, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases_v2(runtime, library, &releases_v2, &visited, countReleaseFacts));
    releases_v2.sort = 5;
    try std.testing.expectEqual(Status.ok, orca_library_browse_releases_v2(runtime, library, &releases_v2, &visited, countReleaseFacts));
    try std.testing.expectEqual(Status.ok, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    releases_v2.artwork = 3;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases_v2(runtime, library, &releases_v2, &visited, countReleaseFacts));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    releases_v2.artwork = @backingInt(ReleaseArtworkFilter.absent);
    releases_v2.kind = 4;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    releases_v2.kind = @backingInt(ReleaseKindFilter.ep_or_single);
    releases_v2.has_appearing_artist_id = 1;
    releases_v2.appearing_artist_id = 1;
    try std.testing.expectEqual(Status.ok, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    releases_v2.has_album_artist_id = 1;
    releases_v2.album_artist_id = 1;
    releases_v2.own_releases_only = 1;
    try std.testing.expectEqual(Status.ok, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    releases_v2.has_album_artist_id = 0;
    releases_v2.own_releases_only = 0;
    releases_v2.has_year_min = 1;
    releases_v2.year_min = 2010;
    releases_v2.high_resolution_only = 1;
    try std.testing.expectEqual(Status.ok, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    releases_v2.limit = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));

    var artists_v2: ArtistQueryV2View = .{ .filter = .{ .pointer = null, .length = 0 }, .genre_id = 1, .limit = 8, .offset = 0, .sort = 4, .has_genre_id = 1, .loved_only = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_artists_v2(runtime, library, &artists_v2, &visited, countArtistV2));
    artists_v2.sort = @backingInt(ArtistSortKey.track_count);
    try std.testing.expectEqual(Status.ok, orca_library_query_artists_v2(runtime, library, &artists_v2, &visited, countArtistV2));
    artists_v2.loved_only = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching_v2(runtime, library, &artists_v2, &count));
    artists_v2.loved_only = 1;
    try std.testing.expectEqual(Status.ok, orca_library_artist_count_matching_v2(runtime, library, &artists_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    artists_v2.filter.length = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching_v2(runtime, library, &artists_v2, &count));
    var totals: ArtistTotalsView = undefined;
    try std.testing.expectEqual(Status.not_found, orca_library_artist_totals(runtime, library, 1, &totals));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_totals(runtime, library, 1, null));
    artists_v2.filter.length = 0;
    artists_v2.sort = @backingInt(ArtistSortKey.recently_added);
    try std.testing.expectEqual(Status.ok, orca_library_query_artists_v2(runtime, library, &artists_v2, &visited, countArtistV2));

    var genres: GenreQueryView = .{ .filter = .{ .pointer = null, .length = 0 }, .limit = 8, .offset = 0, .sort = 2 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_genres(runtime, library, &genres, &visited, countGenre));
    genres.sort = @backingInt(GenreSortKey.track_count);
    try std.testing.expectEqual(Status.ok, orca_library_query_genres(runtime, library, &genres, &visited, countGenre));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_genres(runtime, library, null, &visited, countGenre));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_genre_count(runtime, library, null, 3, &count));
    try std.testing.expectEqual(Status.ok, orca_library_genre_count(runtime, library, null, 0, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(Status.not_found, orca_library_genre_get(runtime, library, 1, &visited, countGenre));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_genres(runtime, library, 1, 0, &visited, countGenreCount));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_genre_artwork(runtime, library, 1, max_page + 1, &visited, null));
    const too_many: [database.max_track_genres + 1]StringInput = @splat(.{ .pointer = "Rock", .length = 4 });
    const one_track = [_]i64{1};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_track_genres(runtime, library, &one_track, 1, &too_many, too_many.len));
    try std.testing.expectEqual(Status.not_found, orca_library_set_track_genres(runtime, library, &one_track, 1, &too_many, 1));

    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_play_stats(runtime, library, 1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_listens_recorded(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_unanalyzed_count(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_analysis_coverage(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_backfill_pending(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_get(runtime, library, 1, null, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_details(runtime, library, 1, null, null));
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "health actions refuse an unknown kind, a missing file and a null callback, and change nothing" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-health-actions?mode=memory&cache=shared",
        &library,
    ));
    const box = runtimeBox(runtime).?;
    const library_database = try core.runtime.databaseOf(&box.runtime, importLibrary(library));
    const file_id = try library_database.files.create(.{ .size_bytes = 1024 });
    try library_database.health_issues.replaceFile(file_id, &.{.{
        .kind = .clipping,
        .severity = .warning,
        .details = "clipped",
    }});
    const clipping: u8 = exportHealthIssueKind(.clipping);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_dismiss_health_issue(runtime, library, file_id, 200));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_restore_health_issue(runtime, library, file_id, 14));
    try std.testing.expectEqual(Status.not_found, orca_library_dismiss_health_issue(runtime, library, file_id + 100, clipping));
    try std.testing.expectEqual(Status.ok, orca_library_restore_health_issue(runtime, library, file_id + 100, clipping));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_health_items(runtime, library, 1, 0, null, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_health_items(runtime, library, 0, 0, null, countHealthItem));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_health_items(runtime, library, 513, 0, null, countHealthItem));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_health_file(runtime, library, file_id, null, null));

    var visited: usize = 0;
    try std.testing.expectEqual(Status.not_found, orca_library_health_file(runtime, library, file_id + 100, &visited, countHealthFile));
    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.ok, orca_library_health_file(runtime, library, file_id, &visited, countHealthFile));
    try std.testing.expectEqual(@as(usize, 1), visited);

    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_dismiss_health_issue(runtime, library, file_id, clipping));
    try std.testing.expectEqual(Status.ok, orca_library_query_health_items(runtime, library, 10, 0, &visited, countHealthItem));
    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.ok, orca_library_restore_health_issue(runtime, library, file_id, clipping));
    try std.testing.expectEqual(Status.ok, orca_library_query_health_items(runtime, library, 10, 0, &visited, countHealthItem));
    try std.testing.expectEqual(@as(usize, 1), visited);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

fn captureHealthSummaryV2(context: ?*anyopaque, view: *const HealthKindSummaryViewV2) callconv(.c) void {
    const captured: *HealthKindSummaryViewV2 = @ptrCast(@alignCast(context.?));
    captured.* = view.*;
}

test "library stats and the sized health summary reach the C ABI, and a null output or callback is refused" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-library-stats?mode=memory&cache=shared",
        &library,
    ));
    var stats: LibraryStatsView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_stats(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_stats(runtime, library, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.files);
    try std.testing.expectEqual(@as(u8, 0), stats.has_last_scan_finished_at);
    try std.testing.expectEqual(@as(u8, 0), stats.has_last_analysis_at);

    const box = runtimeBox(runtime).?;
    const library_database = try core.runtime.databaseOf(&box.runtime, importLibrary(library));
    const kept = try library_database.files.create(.{ .size_bytes = 3_000 });
    const copy = try library_database.files.create(.{ .size_bytes = 3_000 });
    for ([_]i64{ kept, copy }, [_][]const u8{ "music/kept.flac", "music/copy.flac" }) |file_id, uri|
        _ = try library_database.locations.upsert(.{ .file_id = file_id, .volume_id = database.LibraryDatabase.null_volume, .uri = uri });
    try library_database.health_issues.replaceFile(kept, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = copy }});
    try library_database.health_issues.replaceFile(copy, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = kept }});

    try std.testing.expectEqual(Status.ok, orca_library_stats(runtime, library, &stats));
    try std.testing.expectEqual(@as(u64, 2), stats.files);
    try std.testing.expectEqual(@as(u64, 6_000), stats.total_bytes);

    var summary: HealthKindSummaryViewV2 = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_health_summary_v2(runtime, library, null, null));
    try std.testing.expectEqual(Status.ok, orca_library_health_summary_v2(runtime, library, &summary, captureHealthSummaryV2));
    try std.testing.expectEqual(exportHealthIssueKind(.exact_duplicate), summary.base.kind);
    try std.testing.expectEqual(@as(u64, 2), summary.base.count);
    try std.testing.expectEqual(@as(u64, 2), summary.files);
    try std.testing.expectEqual(@as(u64, 3_000), summary.bytes);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "listen settings, history clearing, the cache and the second library stats reach the C ABI" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-listen-settings?mode=memory&cache=shared",
        &library,
    ));

    var policy: u8 = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_listen_policy(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_listen_policy(runtime, library, &policy));
    try std.testing.expectEqual(@as(u8, 0), policy);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_listen_policy(runtime, library, 3));
    try std.testing.expectEqual(Status.ok, orca_library_set_listen_policy(runtime, library, 1));
    try std.testing.expectEqual(Status.ok, orca_library_listen_policy(runtime, library, &policy));
    try std.testing.expectEqual(@as(u8, 1), policy);

    var recording: u8 = 9;
    try std.testing.expectEqual(Status.ok, orca_library_listen_recording(runtime, library, &recording));
    try std.testing.expectEqual(@as(u8, 1), recording);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_listen_recording(runtime, library, 2));
    try std.testing.expectEqual(Status.ok, orca_library_set_listen_recording(runtime, library, 0));
    try std.testing.expectEqual(Status.ok, orca_library_listen_recording(runtime, library, &recording));
    try std.testing.expectEqual(@as(u8, 0), recording);

    const box = runtimeBox(runtime).?;
    const library_database = try core.runtime.databaseOf(&box.runtime, importLibrary(library));
    try library_database.database.exec(
        \\INSERT INTO listens(file_id, started_at, listened_ms, title, artist) VALUES (NULL, 1, 1, 'a', 'b'), (NULL, 2, 1, 'a', 'b');
        \\INSERT INTO job_history(kind, started_at, finished_at, state, completed_units) VALUES ('duplicate_scan', 5, 7, 'succeeded', 1);
        \\INSERT INTO releases(id, title) VALUES (1, 'Covered');
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at) VALUES (1, 'r', x'010203', 'image/jpeg', 1);
    );

    var stats: LibraryStatsViewV2 = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_stats_v2(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_stats_v2(runtime, library, &stats));
    try std.testing.expectEqual(@as(u64, 2), stats.listens);
    try std.testing.expectEqual(@as(u8, 1), stats.has_last_duplicate_scan_at);
    try std.testing.expectEqual(@as(i64, 7), stats.last_duplicate_scan_at);
    try std.testing.expectEqual(@as(u64, 1), stats.base.releases);

    var removed: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_clear_listens(runtime, library, &removed));
    try std.testing.expectEqual(@as(u64, 2), removed);
    try std.testing.expectEqual(Status.ok, orca_library_clear_listens(runtime, library, null));

    var size: CacheSizeView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_cache_size(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_cache_size(runtime, library, &size));
    try std.testing.expectEqual(@as(u64, 3), size.artwork_bytes);
    var cleared: CacheSizeView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_clear_cache(runtime, library, &cleared));
    try std.testing.expectEqual(@as(u64, 3), cleared.artwork_bytes);
    try std.testing.expectEqual(Status.ok, orca_library_clear_cache(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_cache_size(runtime, library, &size));
    try std.testing.expectEqual(@as(u64, 0), size.artwork_bytes);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const ProviderSourceCapture = struct {
    count: usize = 0,
    first_id: u8 = 255,
    first_name: [32]u8 = undefined,
    first_name_length: usize = 0,
    empty_licence_urls: usize = 0,
};

fn captureProviderSource(context: ?*anyopaque, view: *const ProviderSourceView) callconv(.c) void {
    const capture: *ProviderSourceCapture = @ptrCast(@alignCast(context.?));
    if (capture.count == 0) {
        capture.first_id = view.id;
        const name = view.name.pointer[0..view.name.length];
        @memcpy(capture.first_name[0..name.len], name);
        capture.first_name_length = name.len;
    }
    if (view.licence_url.length == 0) capture.empty_licence_urls += 1;
    capture.count += 1;
}

test "provider sources reach the C ABI in id order, and a null callback is refused" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    try std.testing.expectEqual(Status.invalid_argument, orca_provider_sources(runtime, null, null));
    var capture: ProviderSourceCapture = .{};
    try std.testing.expectEqual(Status.ok, orca_provider_sources(runtime, &capture, captureProviderSource));
    try std.testing.expectEqual(@as(usize, 9), capture.count);
    try std.testing.expectEqual(@as(u8, 0), capture.first_id);
    try std.testing.expectEqualStrings("MusicBrainz", capture.first_name[0..capture.first_name_length]);
    try std.testing.expectEqual(@as(usize, 3), capture.empty_licence_urls);
}

test "a Track the Library does not hold is not found, and its callback never runs" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-track-get?mode=memory&cache=shared",
        &library,
    ));
    const box = runtimeBox(runtime).?;
    try (try core.runtime.databaseOf(&box.runtime, importLibrary(library))).tracks.upsertTracks(&.{
        .{ .title = "Only", .album = "Generated", .album_artist = "Orca" },
    });
    var visited: usize = 0;
    try std.testing.expectEqual(Status.ok, orca_library_track_get(runtime, library, 1, &visited, countSummary));
    try std.testing.expectEqual(Status.ok, orca_library_track_details(runtime, library, 1, &visited, countDetails));
    try std.testing.expectEqual(@as(usize, 2), visited);
    try std.testing.expectEqual(Status.not_found, orca_library_track_get(runtime, library, 2, &visited, countSummary));
    try std.testing.expectEqualStrings("orca_library_track_get: no such track", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.not_found, orca_library_track_details(runtime, library, 2, &visited, countDetails));
    try std.testing.expectEqual(@as(usize, 2), visited);
    var stats: PlayStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_track_play_stats(runtime, library, 2, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.play_count);
    try std.testing.expectEqual(@as(u8, 0), stats.has_last_played_at);
    var features: AudioFeaturesView = undefined;
    try std.testing.expectEqual(Status.not_found, orca_library_track_audio_features(runtime, library, 1, &features));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_audio_features(runtime, library, 1, null));
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

fn countRelease(context: ?*anyopaque, release: *const ReleaseView) callconv(.c) void {
    _ = release;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countArtist(context: ?*anyopaque, artist: *const ArtistView) callconv(.c) void {
    _ = artist;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countArtistV2(context: ?*anyopaque, artist: *const ArtistViewV2) callconv(.c) void {
    _ = artist;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countGenre(context: ?*anyopaque, genre: *const GenreView) callconv(.c) void {
    _ = genre;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countGenreCount(context: ?*anyopaque, genre: *const GenreCountView) callconv(.c) void {
    _ = genre;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countSummary(context: ?*anyopaque, summary: *const TrackSummaryView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(summary.track.feedback == 0 and summary.track.has_rating == 0);
}

fn countDetails(context: ?*anyopaque, details: *const TrackDetailsView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(details.title.length != 0 and details.has_loudness == 0);
}

fn countReleaseFacts(context: ?*anyopaque, release: *const ReleaseView, facts: *const ReleaseFactsView) callconv(.c) void {
    _ = facts;
    countRelease(context, release);
}

fn countSummaryFacts(context: ?*anyopaque, summary: *const TrackSummaryView, facts: *const TrackFactsView) callconv(.c) void {
    _ = facts;
    countTrack(context, &summary.track);
}

fn countTrack(context: ?*anyopaque, track: *const TrackView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(track.title.length != 0);
}

fn countHealthItem(context: ?*anyopaque, item: *const HealthItemView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(item.file_id > 0);
}

fn countHealthFile(context: ?*anyopaque, file: *const HealthFileView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(file.file_id > 0);
}

fn countHealthIssue(context: ?*anyopaque, issue: *const HealthIssueView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(issue.path.length != 0);
}

test "feedback, rating and release love edits refuse bad arguments and leave the Library untouched" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-edits?mode=memory&cache=shared",
        &library,
    ));
    const ids = [_]i64{1};
    var change: ChangeCount = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_feedback(runtime, library, &ids, 1, 3, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_feedback(runtime, library, null, 1, 1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_feedback(runtime, library, &ids, 1, 1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_rating(runtime, library, &ids, 1, 101, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_rating(runtime, library, null, 1, 80, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_rating(runtime, library, &ids, 1, 80, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_release_love(runtime, library, &ids, 1, 2, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_release_love(runtime, library, null, 1, 1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_release_love(runtime, library, &ids, 1, 1, null));
    const too_many: [max_page + 1]i64 = @splat(1);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_rating(runtime, library, &too_many, too_many.len, 80, &change));
    var feedback: u8 = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_feedback(runtime, library, 1, null));
    try std.testing.expectEqual(Status.ok, orca_library_track_feedback(runtime, library, 1, &feedback));
    try std.testing.expectEqual(@as(u8, 0), feedback);

    change = .{ .updated = 7, .skipped = 7 };
    try std.testing.expectEqual(Status.ok, orca_library_set_rating(runtime, library, null, 0, 80, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 0 }, change);
    try std.testing.expectEqual(Status.ok, orca_library_set_rating(runtime, library, &ids, 1, 80, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 1 }, change);
    try std.testing.expectEqual(Status.ok, orca_library_set_release_love(runtime, library, &ids, 1, 1, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 1 }, change);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "queue edits refuse a Player without a Library, null ids and positions past the end" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    const ids = [_]i64{1};
    var visited: usize = 0;
    try std.testing.expectEqual(Status.invalid_state, orca_player_queue_insert_next(runtime, player, &ids, 1));
    try std.testing.expectEqual(Status.invalid_state, orca_player_query_queue_tracks(runtime, player, 8, 0, &visited, countTrack));

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-queue-edits?mode=memory&cache=shared", &library));
    try std.testing.expectEqual(Status.ok, orca_player_set_library(runtime, player, library));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_insert_next(runtime, player, null, 1));
    try std.testing.expectEqual(
        Status.invalid_argument,
        orca_player_queue_insert_next(runtime, player, &ids, audio.playback_queue.capacity + 1),
    );
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_jump(runtime, player, 0));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_play_tracks(runtime, player, &ids, 1, 1));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_remove(runtime, player, 0));
    try std.testing.expectEqualStrings(
        "orca_player_queue_remove: PositionOutOfRange",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_move(runtime, player, 0, 0));
    try std.testing.expectEqualStrings(
        "orca_player_queue_move: PositionOutOfRange",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, 0, 0, &visited, countTrack));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, max_page + 1, 0, &visited, countTrack));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, 8, 0, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_player_query_queue_tracks(runtime, player, 8, 0, &visited, countTrack));
    try std.testing.expectEqual(@as(usize, 0), visited);
}

fn countHistoryEntry(context: ?*anyopaque, summary: *const TrackSummaryView, ended_at: i64, reason: u8) callconv(.c) void {
    _ = summary;
    _ = ended_at;
    _ = reason;
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1;
}

test "queue history starts empty and saving refuses a Player without a Library or a current entry" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    var visited: usize = 0;
    var playlist_id: i64 = 0;
    try std.testing.expectEqual(Status.invalid_state, orca_player_save_queue_as_playlist(runtime, player, "queue", 5, &playlist_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_history(runtime, player, 0, 0, &visited, countHistoryEntry));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_history(runtime, player, max_page + 1, 0, &visited, countHistoryEntry));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_history(runtime, player, 8, 0, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_player_query_queue_history(runtime, player, 8, 0, &visited, countHistoryEntry));
    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.ok, orca_player_clear_queue_history(runtime, player));

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-queue-history?mode=memory&cache=shared", &library));
    try std.testing.expectEqual(Status.ok, orca_player_set_library(runtime, player, library));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_save_queue_as_playlist(runtime, player, "queue", 5, null));
    try std.testing.expectEqual(Status.invalid_state, orca_player_save_queue_as_playlist(runtime, player, "queue", 5, &playlist_id));
    try std.testing.expectEqualStrings(
        "orca_player_save_queue_as_playlist: QueueEmpty",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
}

fn countPlaylist(context: ?*anyopaque, playlist: *const PlaylistView) callconv(.c) void {
    _ = playlist;
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1;
}

fn countPlaylistEntry(context: ?*anyopaque, entry: *const PlaylistEntryView) callconv(.c) void {
    _ = entry;
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1;
}

test "playlist edits refuse bad arguments, blank or taken names and unknown playlists" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-playlists?mode=memory&cache=shared", &library));
    var id: i64 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_playlist(runtime, library, null, 3, &id));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_playlist(runtime, library, "Mix", 3, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_playlist(runtime, library, "   ", 3, &id));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_playlist(runtime, library, null, 0, &id));
    try std.testing.expectEqual(Status.ok, orca_library_create_playlist(runtime, library, "Mix", 3, &id));
    try std.testing.expectEqual(Status.invalid_state, orca_library_create_playlist(runtime, library, " Mix ", 5, &id));
    try std.testing.expectEqualStrings(
        "orca_library_create_playlist: PlaylistNameTaken",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    var visited: usize = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists(runtime, library, 0, 0, &visited, countPlaylist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists(runtime, library, max_page + 1, 0, &visited, countPlaylist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists(runtime, library, 8, 0, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_library_query_playlists(runtime, library, 8, 0, &visited, countPlaylist));
    try std.testing.expectEqual(@as(usize, 1), visited);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlist_entries(runtime, library, id, 0, 0, &visited, countPlaylistEntry));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlist_entries(runtime, library, id, 8, 0, &visited, null));

    const unknown: i64 = id + 1000;
    const ids = [_]i64{12345};
    const positions = [_]u32{0};
    var change: ChangeCount = undefined;
    var removed: u32 = 9;
    var written: u32 = 0;
    var skipped: u32 = 0;
    try std.testing.expectEqual(Status.not_found, orca_library_rename_playlist(runtime, library, unknown, "Other", 5));
    try std.testing.expectEqual(Status.not_found, orca_library_delete_playlist(runtime, library, unknown));
    try std.testing.expectEqual(Status.not_found, orca_library_query_playlist_entries(runtime, library, unknown, 8, 0, &visited, countPlaylistEntry));
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_insert(runtime, library, unknown, &ids, 1, -1, &change));
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_remove(runtime, library, unknown, &positions, 1, &removed));
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_move(runtime, library, unknown, 0, 0));
    try std.testing.expectEqual(Status.not_found, orca_library_export_playlist(runtime, library, unknown, "unused.m3u", 10, 0, 0, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_rename_playlist(runtime, library, id, "", 0));

    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, null, 1, -1, &change));
    const too_many: [max_page + 1]i64 = @splat(1);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &too_many, too_many.len, -1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, -1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, 1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, std.math.maxInt(u32) + 1, &change));
    try std.testing.expectEqual(Status.ok, orca_library_playlist_insert(runtime, library, id, &ids, 1, -1, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 1 }, change);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, null, 1, &removed));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, &positions, 1, null));
    const too_many_positions: [max_page + 1]u32 = @splat(0);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, &too_many_positions, too_many_positions.len, &removed));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, &positions, 1, &removed));
    try std.testing.expectEqual(Status.ok, orca_library_playlist_remove(runtime, library, id, null, 0, &removed));
    try std.testing.expectEqual(@as(u32, 0), removed);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_move(runtime, library, id, 0, 0));

    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "unused.m3u", 10, 2, 0, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "unused.m3u", 10, 0, 2, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, null, 10, 0, 0, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "", 0, 0, 0, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "unused.m3u", 10, 0, 0, null, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "unused.m3u", 10, 0, 0, &written, null));
    try std.testing.expectEqual(Status.not_found, orca_library_export_playlist(runtime, library, id, "/nonexistent/orca-c-api/out.m3u", 31, 0, 0, &written, &skipped));

    var imported: PlaylistImport = undefined;
    const missing = "/nonexistent/orca-c-api/missing.m3u";
    try std.testing.expectEqual(Status.invalid_argument, orca_library_import_playlist(runtime, library, missing, missing.len, null, 0, null, null, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_import_playlist(runtime, library, "", 0, null, 0, &imported, null, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_import_playlist(runtime, library, missing, missing.len, null, 2, &imported, null, null));
    try std.testing.expectEqual(Status.not_found, orca_library_import_playlist(runtime, library, missing, missing.len, null, 0, &imported, null, null));

    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.invalid_state, orca_player_play_playlist(runtime, player, id, 0));
    try std.testing.expectEqual(Status.ok, orca_player_set_library(runtime, player, library));
    try std.testing.expectEqual(Status.not_found, orca_player_play_playlist(runtime, player, unknown, 0));
    try std.testing.expectEqual(Status.invalid_state, orca_player_play_playlist(runtime, player, id, 0));
    try std.testing.expectEqualStrings(
        "orca_player_play_playlist: PlaylistEmpty",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    try std.testing.expectEqual(Status.ok, orca_library_delete_playlist(runtime, library, id));
    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_query_playlists(runtime, library, 8, 0, &visited, countPlaylist));
    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}
const PlaylistFactsSeen = struct {
    visited: usize = 0,
    kind: u8 = 255,
    pinned: u8 = 255,
    tag_count: u8 = 255,
    description_length: usize = 0,
};

fn recordPlaylistFacts(context: ?*anyopaque, playlist: *const PlaylistView, facts: *const PlaylistFactsView) callconv(.c) void {
    _ = playlist;
    const seen: *PlaylistFactsSeen = @ptrCast(@alignCast(context.?));
    seen.visited += 1;
    seen.kind = facts.kind;
    seen.pinned = facts.pinned;
    seen.tag_count = facts.tag_count;
    seen.description_length = facts.description.length;
}

fn countStrings(context: ?*anyopaque, value: *const StringView) callconv(.c) void {
    _ = value;
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1;
}

test "playlist metadata and smart playlists reach the C ABI and refuse bad arguments" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-smart-playlists?mode=memory&cache=shared", &library));
    var manual: i64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_create_playlist(runtime, library, "Mix", 3, &manual));

    const tags = [_]StringInput{ .{ .pointer = "focus", .length = 5 }, .{ .pointer = "lofi", .length = 4 } };
    var update: PlaylistUpdateView = .{
        .description = .{ .pointer = "For work", .length = 8 },
        .tags = &tags,
        .tag_count = tags.len,
        .has_description = 1,
        .has_pinned = 1,
        .pinned = 1,
        .has_loved = 0,
        .loved = 0,
        .has_tags = 1,
    };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_update_playlist(runtime, library, manual, null));
    try std.testing.expectEqual(Status.not_found, orca_library_update_playlist(runtime, library, manual + 1000, &update));
    try std.testing.expectEqual(Status.ok, orca_library_update_playlist(runtime, library, manual, &update));
    update.has_pinned = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_update_playlist(runtime, library, manual, &update));
    update.has_pinned = 0;
    update.tag_count = max_page;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_update_playlist(runtime, library, manual, &update));
    update.tag_count = 1;
    update.tags = null;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_update_playlist(runtime, library, manual, &update));

    var visited: usize = 0;
    try std.testing.expectEqual(Status.ok, orca_library_playlist_tags(runtime, library, manual, &visited, countStrings));
    try std.testing.expectEqual(@as(usize, 2), visited);
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_tags(runtime, library, manual + 1000, &visited, countStrings));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_tags(runtime, library, manual, &visited, null));

    const bad_field = "{\"v\":1,\"match\":\"all\",\"rules\":[{\"field\":\"mood\",\"op\":\"is\",\"value\":\"x\"}]}";
    const rules = "{\"v\":1,\"match\":\"all\",\"rules\":[{\"field\":\"year\",\"op\":\"gte\",\"value\":1990}]}";
    var smart: i64 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_smart_playlist(runtime, library, "Nineties", 8, bad_field, bad_field.len, &smart));
    try std.testing.expectEqualStrings(
        "orca_library_create_smart_playlist: UnknownRuleField",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_smart_playlist(runtime, library, "Nineties", 8, rules, rules.len, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_smart_playlist(runtime, library, "Nineties", 8, null, 4, &smart));
    try std.testing.expectEqual(Status.ok, orca_library_create_smart_playlist(runtime, library, "Nineties", 8, rules, rules.len, &smart));

    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_smart_playlist_rules(runtime, library, smart, &visited, countStrings));
    try std.testing.expectEqual(@as(usize, 1), visited);
    try std.testing.expectEqual(Status.invalid_state, orca_library_smart_playlist_rules(runtime, library, manual, &visited, countStrings));
    try std.testing.expectEqual(Status.ok, orca_library_set_smart_playlist_rules(runtime, library, smart, rules, rules.len));
    try std.testing.expectEqual(Status.invalid_state, orca_library_set_smart_playlist_rules(runtime, library, manual, rules, rules.len));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_smart_playlist_rules(runtime, library, smart, bad_field, bad_field.len));

    const ids = [_]i64{1};
    var change: ChangeCount = undefined;
    try std.testing.expectEqual(Status.invalid_state, orca_library_playlist_insert(runtime, library, smart, &ids, 1, -1, &change));
    try std.testing.expectEqual(Status.invalid_state, orca_library_playlist_move(runtime, library, smart, 0, 0));

    var count: u64 = 99;
    try std.testing.expectEqual(Status.ok, orca_library_smart_playlist_count(runtime, library, rules, rules.len, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_smart_playlist_count(runtime, library, rules, rules.len, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_smart_playlist_count(runtime, library, "{", 1, &count));

    var query: PlaylistQueryView = .{
        .filter = .{ .pointer = null, .length = 0 },
        .limit = 8,
        .offset = 0,
        .sort = @backingInt(PlaylistSortKey.name),
        .has_kind = 1,
        .kind = @backingInt(database.PlaylistKind.smart),
        .pinned_only = 0,
        .has_creator = 0,
        .creator = 0,
    };
    var seen: PlaylistFactsSeen = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_playlists_v2(runtime, library, &query, &seen, recordPlaylistFacts));
    try std.testing.expectEqual(@as(usize, 1), seen.visited);
    try std.testing.expectEqual(@as(u8, 1), seen.kind);
    try std.testing.expectEqual(Status.ok, orca_library_playlist_count(runtime, library, &query, &count));
    try std.testing.expectEqual(@as(u64, 1), count);

    query.has_kind = 0;
    query.pinned_only = 1;
    seen = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_playlists_v2(runtime, library, &query, &seen, recordPlaylistFacts));
    try std.testing.expectEqual(@as(usize, 1), seen.visited);
    try std.testing.expectEqual(@as(u8, 1), seen.pinned);
    try std.testing.expectEqual(@as(u8, 2), seen.tag_count);
    try std.testing.expectEqual(@as(usize, 8), seen.description_length);

    seen = .{};
    try std.testing.expectEqual(Status.ok, orca_library_playlist_get(runtime, library, smart, &seen, recordPlaylistFacts));
    try std.testing.expectEqual(@as(u8, 1), seen.kind);
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_get(runtime, library, smart + 1000, &seen, recordPlaylistFacts));
    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_playlist_genres(runtime, library, manual, &visited, countStrings));
    try std.testing.expectEqual(@as(usize, 0), visited);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists_v2(runtime, library, null, &seen, recordPlaylistFacts));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists_v2(runtime, library, &query, &seen, null));
    query.sort = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists_v2(runtime, library, &query, &seen, recordPlaylistFacts));
    query.sort = 0;
    query.limit = max_page + 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_count(runtime, library, &query, &count));
    query.limit = 8;
    query.has_creator = 1;
    query.creator = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists_v2(runtime, library, &query, &seen, recordPlaylistFacts));
}

test "queue stats are all zero before a Player has played, and a destroyed Player has none" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_stats(runtime, player, null));
    var stats: QueueStats = .{
        .entries_started = 7,
        .gapless_transitions = 7,
        .format_switch_transitions = 7,
        .open_failures = 7,
        .decode_errors = 7,
    };
    try std.testing.expectEqual(Status.ok, orca_player_queue_stats(runtime, player, &stats));
    try std.testing.expectEqual(QueueStats{
        .entries_started = 0,
        .gapless_transitions = 0,
        .format_switch_transitions = 0,
        .open_failures = 0,
        .decode_errors = 0,
    }, stats);
    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_queue_stats(runtime, player, &stats));
}

test "an unknown equalizer preset or a null output is refused, and a preset leaves headroom for its largest boost" {
    var equalizer: EqualizerView = std.mem.zeroes(EqualizerView);
    try std.testing.expectEqual(Status.invalid_argument, orca_equalizer_preset_get(5, &equalizer));
    try std.testing.expectEqual(Status.invalid_argument, orca_equalizer_preset_get(255, &equalizer));
    try std.testing.expectEqual(Status.invalid_argument, orca_equalizer_preset_get(0, null));
    try std.testing.expectEqual(@as(f32, 0), equalizer.preamp_db);
    try std.testing.expectEqual(Status.ok, orca_equalizer_preset_get(1, &equalizer));
    try std.testing.expectEqual(@as(f32, 6), equalizer.gains_db[0]);
    try std.testing.expectEqual(@as(f32, -6), equalizer.preamp_db);
}

test "a NaN or out-of-range equalizer or crossfeed is refused and leaves the previous setting in place" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));

    var bass: EqualizerView = undefined;
    try std.testing.expectEqual(Status.ok, orca_equalizer_preset_get(1, &bass));
    try std.testing.expectEqual(Status.ok, orca_player_set_equalizer(runtime, player, &bass));

    var invalid = bass;
    invalid.gains_db[3] = std.math.nan(f32);
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_equalizer(runtime, player, &invalid));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(orca_runtime_last_error(runtime)), "orca_player_set_equalizer") != null);
    invalid = bass;
    invalid.gains_db[0] = 12.5;
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_equalizer(runtime, player, &invalid));
    invalid = bass;
    invalid.preamp_db = std.math.nan(f32);
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_equalizer(runtime, player, &invalid));
    invalid.preamp_db = -24.5;
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_equalizer(runtime, player, &invalid));

    var read_back: EqualizerView = undefined;
    var enabled: u8 = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_player_equalizer(runtime, player, null, &enabled));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_equalizer(runtime, player, &read_back, null));
    try std.testing.expectEqual(Status.ok, orca_player_equalizer(runtime, player, &read_back, &enabled));
    try std.testing.expectEqual(@as(u8, 1), enabled);
    try std.testing.expectEqual(bass, read_back);

    try std.testing.expectEqual(Status.ok, orca_player_set_crossfeed(runtime, player, 1, 0.25));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_crossfeed(runtime, player, 1, std.math.nan(f32)));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_crossfeed(runtime, player, 1, -0.1));
    try std.testing.expectEqual(Status.ok, orca_player_set_crossfeed(runtime, player, 0, std.math.nan(f32)));
    var amount: f32 = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_player_crossfeed(runtime, player, null, &amount));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_crossfeed(runtime, player, &enabled, null));
    try std.testing.expectEqual(Status.ok, orca_player_crossfeed(runtime, player, &enabled, &amount));
    try std.testing.expectEqual(@as(u8, 0), enabled);
    try std.testing.expectEqual(@as(f32, 0), amount);

    try std.testing.expectEqual(Status.ok, orca_player_set_equalizer(runtime, player, null));
    try std.testing.expectEqual(Status.ok, orca_player_equalizer(runtime, player, &read_back, &enabled));
    try std.testing.expectEqual(@as(u8, 0), enabled);
    try std.testing.expectEqual(std.mem.zeroes(EqualizerView), read_back);
}

fn captureSignalPath(context: ?*anyopaque, view: *const SignalPathView) callconv(.c) void {
    const destination: *SignalPathView = @ptrCast(@alignCast(context.?));
    destination.* = view.*;
}

fn captureSignalPathV2(context: ?*anyopaque, view: *const SignalPathViewV2) callconv(.c) void {
    const destination: *SignalPathViewV2 = @ptrCast(@alignCast(context.?));
    destination.* = view.*;
}

test "a Player with no output reports a signal path with no source, no output and an unknown path" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_signal_path(runtime, player, null, null));

    var path: SignalPathView = std.mem.zeroes(SignalPathView);
    try std.testing.expectEqual(Status.ok, orca_player_signal_path(runtime, player, &path, captureSignalPath));
    try std.testing.expectEqual(@as(u8, 0), path.has_source);
    try std.testing.expectEqual(@as(u8, 0), path.has_output);
    try std.testing.expectEqual(@as(u8, 0), path.has_equalizer);
    try std.testing.expectEqual(@as(u32, 1), path.reason_count);
    try std.testing.expectEqual(exportSignalReason(.path_unknown), path.reasons[0]);
    try std.testing.expectEqual(@as(u8, 5), path.reasons[0]);
    try std.testing.expectEqual(@as(u8, 0), path.bit_perfect_eligible);
    try std.testing.expectEqual(@as(usize, 0), path.codec.length);
    try std.testing.expectEqual(exportDeviceKind(.unknown), path.output_kind);
    try std.testing.expectEqual(@as(u8, 0), path.has_device_quantum);
    try std.testing.expectEqual(exportReplayGainSource(.none), path.replay_gain_source);

    try std.testing.expectEqual(Status.invalid_argument, orca_player_signal_path_v2(runtime, player, null, null));
    var path_v2: SignalPathViewV2 = std.mem.zeroes(SignalPathViewV2);
    try std.testing.expectEqual(Status.ok, orca_player_signal_path_v2(runtime, player, &path_v2, captureSignalPathV2));
    try std.testing.expectEqual(path.bit_perfect_eligible, path_v2.base.bit_perfect_eligible);
    try std.testing.expectEqual(path.reason_count, path_v2.base.reason_count);
    try std.testing.expectEqual(@as(u8, 0), path_v2.has_parametric);
    try std.testing.expectEqual(@as(u8, 0), path_v2.has_replay_gain_track);
    try std.testing.expectEqual(std.mem.zeroes(DeviceFormatView), path_v2.device_format);

    try std.testing.expectEqual(Status.ok, orca_player_set_crossfeed(runtime, player, 1, 0.5));
    try std.testing.expectEqual(Status.ok, orca_player_signal_path(runtime, player, &path, captureSignalPath));
    try std.testing.expectEqual(@as(u8, 1), path.has_crossfeed);
    try std.testing.expectEqual(@as(f32, 0.5), path.crossfeed);
    try std.testing.expectEqual(@as(u32, 2), path.reason_count);
    try std.testing.expectEqual(exportSignalReason(.sample_processing), path.reasons[0]);
    try std.testing.expectEqual(exportSignalReason(.path_unknown), path.reasons[1]);
    try std.testing.expectEqual(@as(u8, 0), path.bit_perfect_eligible);

    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_signal_path(runtime, player, &path, captureSignalPath));
}

test "ReplayGain settings read back clamped, refuse unknown values and reach the signal path" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));

    try std.testing.expectEqual(Status.ok, orca_player_set_replay_gain_mode(runtime, player, 3));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_replay_gain_mode(runtime, player, 4));
    try std.testing.expectEqual(Status.ok, orca_player_set_replay_gain_preamp(runtime, player, 40));
    try std.testing.expectEqual(Status.ok, orca_player_set_replay_gain_fallback(runtime, player, 0));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_replay_gain_fallback(runtime, player, 2));
    try std.testing.expectEqual(Status.ok, orca_player_set_peak_protection(runtime, player, 0));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_replay_gain_settings(runtime, player, null));

    var settings: ReplayGainSettingsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_replay_gain_settings(runtime, player, &settings));
    try std.testing.expectEqual(ReplayGainSettingsView{ .preamp_db = 15, .mode = 3, .fallback = 0, .peak_protection = 0 }, settings);

    var path: SignalPathViewV2 = std.mem.zeroes(SignalPathViewV2);
    try std.testing.expectEqual(Status.ok, orca_player_signal_path_v2(runtime, player, &path, captureSignalPathV2));
    try std.testing.expectEqual(@as(f32, 15), path.preamp_db);
    try std.testing.expectEqual(@as(u8, 0), path.peak_protection);
    try std.testing.expectEqual(exportUntaggedFallback(.minus_6_db), path.fallback);
    try std.testing.expectEqual(@as(u8, 0), path.peak_limited);

    var armed: u8 = 9;
    try std.testing.expectEqual(Status.ok, orca_player_set_stop_after_current(runtime, player, 1));
    try std.testing.expectEqual(Status.ok, orca_player_stop_after_current(runtime, player, &armed));
    try std.testing.expectEqual(@as(u8, 1), armed);
    try std.testing.expectEqual(Status.invalid_argument, orca_player_stop_after_current(runtime, player, null));

    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_set_replay_gain_preamp(runtime, player, 0));
    try std.testing.expectEqual(Status.stale_handle, orca_player_set_stop_after_current(runtime, player, 0));
}

fn countImage(context: ?*anyopaque, image: *const ImageView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(image.length != 0);
}

fn captureArtworkResult(context: ?*anyopaque, result: *const ArtworkResultView) callconv(.c) void {
    const captured: *ArtworkResultView = @ptrCast(@alignCast(context.?));
    captured.* = result.*;
}

fn awaitArtworkResult(runtime: *Runtime, library: Handle, captured: *ArtworkResultView) !void {
    for (0..5_000) |_| {
        switch (orca_library_take_artwork(runtime, library, captured, captureArtworkResult)) {
            .ok => return,
            .not_found => try std.testing.io.sleep(.fromMilliseconds(1), .awake),
            else => |status| return std.testing.expectEqual(Status.ok, status),
        }
    }
    return error.ArtworkRequestNeverFinished;
}

test "artwork calls refuse null outputs and unknown subjects, find no cover for an unknown Track, and refuse a closed Library" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-artwork-arguments?mode=memory&cache=shared",
        &library,
    ));
    var images: usize = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_artwork(runtime, library, 1, &images, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_artwork(runtime, library, 1, &images, null));
    try std.testing.expectEqual(Status.not_found, orca_library_track_artwork(runtime, library, 1, &images, countImage));
    try std.testing.expectEqual(Status.not_found, orca_library_release_artwork(runtime, library, 1, &images, countImage));
    try std.testing.expectEqual(@as(usize, 0), images);

    var request: u64 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_request_artwork(runtime, library, 3, 1, &request));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_request_artwork(runtime, library, 0, 1, null));
    var captured: ArtworkResultView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_take_artwork(runtime, library, &captured, null));
    try std.testing.expectEqual(Status.not_found, orca_library_take_artwork(runtime, library, &captured, captureArtworkResult));
    try std.testing.expectEqual(Status.ok, orca_library_cancel_artwork(runtime, library, 12345));

    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
    try std.testing.expectEqual(Status.stale_handle, orca_library_cancel_artwork(runtime, library, 1));
    try std.testing.expectEqual(Status.stale_handle, orca_library_take_artwork(runtime, library, &captured, captureArtworkResult));
    try std.testing.expectEqual(Status.stale_handle, orca_library_request_artwork(runtime, library, 0, 1, &request));
    try std.testing.expectEqual(Status.stale_handle, orca_library_track_artwork(runtime, library, 1, &images, countImage));
}

const CapturedLyrics = struct {
    calls: usize = 0,
    source: u8 = 255,
    kind: u8 = 255,
    language: [3]u8 = @splat(0),
    language_length: usize = 0,
    line_count: usize = 0,
    first_start_ms: i64 = 0,
    last_start_ms: i64 = 0,
    first_text: [64]u8 = @splat(0),
    first_text_length: usize = 0,
};

fn captureLyrics(context: ?*anyopaque, view: *const LyricsView) callconv(.c) void {
    const captured: *CapturedLyrics = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.source = view.source;
    captured.kind = view.kind;
    captured.language_length = @min(view.language.length, captured.language.len);
    @memcpy(captured.language[0..captured.language_length], view.language.pointer[0..captured.language_length]);
    captured.line_count = view.line_count;
    if (view.line_count == 0) return;
    const lines = view.lines[0..view.line_count];
    captured.first_start_ms = lines[0].start_ms;
    captured.last_start_ms = lines[lines.len - 1].start_ms;
    captured.first_text_length = @min(lines[0].text.length, captured.first_text.len);
    @memcpy(captured.first_text[0..captured.first_text_length], lines[0].text.pointer[0..captured.first_text_length]);
}

fn finishedLyricsJob(runtime: *Runtime, fixture: []const u8, audio_name: []const u8, sidecar: ?[]const u8, name: [:0]const u8) !Handle {
    const box = runtimeBox(runtime).?;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try core.runtime_tests.copyFixtureInto(temporary.dir, fixture, audio_name);
    if (sidecar) |path| try core.runtime_tests.copyFixtureInto(temporary.dir, path, "a.lrc");
    const scanned = try core.runtime_tests.scannedTempFolder(&box.runtime, &temporary, name);
    const track_ids = try core.runtime_tests.allTrackIds(&box.runtime, scanned);
    defer std.testing.allocator.free(track_ids);
    try std.testing.expectEqual(@as(usize, 1), track_ids.len);
    var lyrics_job: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_lyrics(runtime, exportLibraryHandle(scanned), track_ids[0], 0, &lyrics_job));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(lyrics_job)));
    return lyrics_job;
}

test "a lyrics job hands its synced lines over once through the C ABI, and plain lines start at -1" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);

    const synced = try finishedLyricsJob(runtime, "fixtures/audio/fingerprint-reference.mp3", "a.mp3", "fixtures/audio/fingerprint-reference.lrc", "file:orca-c-api-lyrics-sidecar?mode=memory&cache=shared");
    var outcome: u8 = 255;
    try std.testing.expectEqual(Status.ok, orca_job_lyrics_outcome(runtime, synced, &outcome));
    try std.testing.expectEqual(exportLyricsOutcome(.local), outcome);
    var captured: CapturedLyrics = .{};
    try std.testing.expectEqual(Status.ok, orca_job_lyrics(runtime, synced, &captured, captureLyrics));
    try std.testing.expectEqual(@as(usize, 1), captured.calls);
    try std.testing.expectEqual(exportLyricsSource(.sidecar), captured.source);
    try std.testing.expectEqual(exportLyricsKind(.synced), captured.kind);
    try std.testing.expectEqual(@as(usize, 0), captured.language_length);
    try std.testing.expectEqual(@as(usize, 4), captured.line_count);
    try std.testing.expectEqual(@as(i64, 1000), captured.first_start_ms);
    try std.testing.expectEqual(@as(i64, 8000), captured.last_start_ms);
    try std.testing.expectEqualStrings("One second in", captured.first_text[0..captured.first_text_length]);
    captured = .{};
    try std.testing.expectEqual(Status.not_found, orca_job_lyrics(runtime, synced, &captured, captureLyrics));
    try std.testing.expectEqual(@as(usize, 0), captured.calls);

    const plain = try finishedLyricsJob(runtime, "fixtures/audio/lyrics-plain.m4a", "a.m4a", null, "file:orca-c-api-lyrics-plain?mode=memory&cache=shared");
    try std.testing.expectEqual(Status.ok, orca_job_lyrics(runtime, plain, &captured, captureLyrics));
    try std.testing.expectEqual(exportLyricsSource(.embedded), captured.source);
    try std.testing.expectEqual(exportLyricsKind(.plain), captured.kind);
    try std.testing.expectEqual(@as(usize, 2), captured.line_count);
    try std.testing.expectEqual(@as(i64, -1), captured.first_start_ms);
    try std.testing.expectEqual(@as(i64, -1), captured.last_start_ms);

    const tagged = try finishedLyricsJob(runtime, "fixtures/audio/lyrics-sylt.mp3", "a.mp3", null, "file:orca-c-api-lyrics-sylt?mode=memory&cache=shared");
    captured = .{};
    try std.testing.expectEqual(Status.ok, orca_job_lyrics(runtime, tagged, &captured, captureLyrics));
    try std.testing.expectEqual(exportLyricsKind(.synced), captured.kind);
    try std.testing.expectEqualStrings("eng", captured.language[0..captured.language_length]);
}

test "lyrics calls refuse null outputs, unknown flags, fetching without an identity, stale jobs and jobs of another kind" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-lyrics-arguments?mode=memory&cache=shared", &library));
    var lyrics_job: Handle = undefined;
    var outcome: u8 = 255;
    var captured: CapturedLyrics = .{};

    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_lyrics(null, library, 1, 0, &lyrics_job));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics_outcome(null, library, &outcome));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics(null, library, &captured, captureLyrics));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_lyrics(runtime, library, 1, 0, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_lyrics(runtime, library, 1, 2, &lyrics_job));
    try std.testing.expectEqualStrings("orca_library_start_lyrics: flags holds an unknown bit", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_lyrics(runtime, library, 1, lyrics_fetch_flag, &lyrics_job));
    try std.testing.expectEqualStrings("orca_library_start_lyrics: ClientIdentityRequired", std.mem.span(orca_runtime_last_error(runtime)));

    const stale: Handle = .{ .index = 7, .generation = 3 };
    try std.testing.expectEqual(Status.stale_handle, orca_job_lyrics_outcome(runtime, stale, &outcome));
    try std.testing.expectEqual(Status.stale_handle, orca_job_lyrics(runtime, stale, &captured, captureLyrics));

    try std.testing.expectEqual(Status.ok, orca_library_start_lyrics(runtime, library, 1_000_000, 0, &lyrics_job));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics_outcome(runtime, lyrics_job, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics(runtime, lyrics_job, &captured, null));
    const box = runtimeBox(runtime).?;
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(lyrics_job)));
    try std.testing.expectEqual(Status.ok, orca_job_lyrics_outcome(runtime, lyrics_job, &outcome));
    try std.testing.expectEqual(exportLyricsOutcome(.not_found), outcome);
    try std.testing.expectEqual(Status.not_found, orca_job_lyrics(runtime, lyrics_job, &captured, captureLyrics));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(runtime, lyrics_job, &snapshot));
    try std.testing.expectEqual(@as(u8, 9), snapshot.kind);

    var projection: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_projection(runtime, library, &projection));
    _ = try core.runtime_tests.awaitJob(&box.runtime, importJob(projection));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics_outcome(runtime, projection, &outcome));
    try std.testing.expectEqualStrings("orca_job_lyrics_outcome: NotALyricsJob", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics(runtime, projection, &captured, captureLyrics));
    try std.testing.expectEqual(@as(usize, 0), captured.calls);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const RelatedPhotoCredit = struct {
    calls: usize = 0,
    source: u8 = 0,
    fetched_at: i64 = 0,
    licence: [32]u8 = undefined,
    licence_len: usize = 0,
    credit: [32]u8 = undefined,
    credit_len: usize = 0,
};

fn captureRelatedPhotoCredit(context: ?*anyopaque, view: *const RelatedArtistPhotoInfoView) callconv(.c) void {
    const credit: *RelatedPhotoCredit = @ptrCast(@alignCast(context.?));
    credit.calls += 1;
    credit.source = view.photo_source;
    credit.fetched_at = view.fetched_at;
    credit.licence_len = view.photo_licence.length;
    @memcpy(credit.licence[0..credit.licence_len], view.photo_licence.pointer[0..credit.licence_len]);
    credit.credit_len = view.photo_credit.length;
    @memcpy(credit.credit[0..credit.credit_len], view.photo_credit.pointer[0..credit.credit_len]);
}

fn countArtistInfo(context: ?*anyopaque, view: *const ArtistInfoView) callconv(.c) void {
    _ = view;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countArtistLinks(context: ?*anyopaque, links: [*]const ArtistLinkView, count: usize) callconv(.c) void {
    _ = links;
    const total: *usize = @ptrCast(@alignCast(context.?));
    total.* += count;
}

test "artist info and love calls refuse null outputs, out-of-range flags, bad languages, unknown artists and jobs of another kind" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-artist-info-arguments?mode=memory&cache=shared", &library));
    var started: Handle = undefined;
    var outcome: u8 = 255;
    var calls: usize = 0;
    var change: ChangeCount = undefined;
    var loved: u8 = 255;
    const ids = [_]i64{1};
    var options: ArtistInfoOptionsView = .{ .language = .{ .pointer = null, .length = 0 }, .force = 0, .offline = 1 };

    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(null, library, 1, &options, &started));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, &options, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, null, &started));
    options.force = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, &options, &started));
    options.force = 0;
    options.language = .{ .pointer = null, .length = 2 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, &options, &started));
    options.language = .{ .pointer = "en.evil.org", .length = 11 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, &options, &started));
    try std.testing.expectEqualStrings("orca_library_start_artist_info: InvalidLanguage", std.mem.span(orca_runtime_last_error(runtime)));
    options.language = .{ .pointer = null, .length = 0 };
    try std.testing.expectEqual(Status.not_found, orca_library_start_artist_info(runtime, library, 1, &options, &started));
    try std.testing.expectEqualStrings("orca_library_start_artist_info: UnknownArtist", std.mem.span(orca_runtime_last_error(runtime)));

    try std.testing.expectEqual(Status.invalid_argument, orca_job_artist_info_outcome(runtime, library, null));
    const stale: Handle = .{ .index = 7, .generation = 3 };
    try std.testing.expectEqual(Status.stale_handle, orca_job_artist_info_outcome(runtime, stale, &outcome));
    var projection: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_projection(runtime, library, &projection));
    _ = try core.runtime_tests.awaitJob(&runtimeBox(runtime).?.runtime, importJob(projection));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_artist_info_outcome(runtime, projection, &outcome));
    try std.testing.expectEqualStrings("orca_job_artist_info_outcome: NotAnArtistInfoJob", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(@as(u8, 255), outcome);
    var stores: u32 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_job_artist_info_stores(runtime, projection, &stores));
    try std.testing.expectEqualStrings("orca_job_artist_info_stores: NotAnArtistInfoJob", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.stale_handle, orca_job_artist_info_stores(runtime, stale, &stores));

    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_info(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_artist_info(runtime, library, 1, &calls, countArtistInfo));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_photo(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_artist_photo(runtime, library, 1, &calls, countImage));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_links(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.ok, orca_library_artist_links(runtime, library, 1, &calls, countArtistLinks));
    try std.testing.expectEqual(@as(usize, 0), calls);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_artist_love(runtime, library, &ids, 1, 1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_artist_love(runtime, library, &ids, 1, 2, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_artist_love(runtime, library, null, 1, 1, &change));
    try std.testing.expectEqual(Status.ok, orca_library_set_artist_love(runtime, library, &ids, 1, 1, &change));
    try std.testing.expectEqual(@as(u32, 0), change.updated);
    try std.testing.expectEqual(@as(u32, 1), change.skipped);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_loved(runtime, library, 1, null));
    try std.testing.expectEqual(Status.ok, orca_library_artist_loved(runtime, library, 1, &loved));
    try std.testing.expectEqual(@as(u8, 0), loved);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

fn countReleaseInfo(context: ?*anyopaque, view: *const ReleaseInfoView) callconv(.c) void {
    _ = view;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countRelatedArtists(context: ?*anyopaque, artists: [*]const RelatedArtistView, count: usize) callconv(.c) void {
    _ = artists;
    const total: *usize = @ptrCast(@alignCast(context.?));
    total.* += count;
}

test "release info, related artist and genre fill calls refuse null outputs, out-of-range flags, unknown releases and jobs of another kind" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-release-info-arguments?mode=memory&cache=shared", &library));
    var started: Handle = undefined;
    var outcome: u8 = 255;
    var calls: usize = 0;
    var options: ReleaseInfoOptionsView = .{ .language = .{ .pointer = null, .length = 0 }, .force = 0, .offline = 1 };

    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_release_info(runtime, library, 1, &options, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_release_info(runtime, library, 1, null, &started));
    options.offline = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_release_info(runtime, library, 1, &options, &started));
    options.offline = 1;
    try std.testing.expectEqual(Status.not_found, orca_library_start_release_info(runtime, library, 1, &options, &started));
    try std.testing.expectEqualStrings("orca_library_start_release_info: UnknownRelease", std.mem.span(orca_runtime_last_error(runtime)));

    try std.testing.expectEqual(Status.invalid_argument, orca_job_release_info_outcome(runtime, library, null));
    var projection: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_projection(runtime, library, &projection));
    _ = try core.runtime_tests.awaitJob(&runtimeBox(runtime).?.runtime, importJob(projection));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_release_info_outcome(runtime, projection, &outcome));
    try std.testing.expectEqualStrings("orca_job_release_info_outcome: NotAReleaseInfoJob", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(@as(u8, 255), outcome);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_info(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_release_info(runtime, library, 1, &calls, countReleaseInfo));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artists(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.ok, orca_library_related_artists(runtime, library, 1, &calls, countRelatedArtists));
    try std.testing.expectEqual(@as(usize, 0), calls);

    const related_mbid = "cccccccc-0000-4000-8000-000000000003";
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artist_photo(runtime, library, related_mbid, related_mbid.len, &calls, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artist_photo(runtime, library, null, 4, &calls, countImage));
    try std.testing.expectEqual(Status.not_found, orca_library_related_artist_photo(runtime, library, related_mbid, related_mbid.len, &calls, countImage));
    var credit: RelatedPhotoCredit = .{};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artist_photo_info(runtime, library, related_mbid, related_mbid.len, &credit, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artist_photo_info(runtime, library, null, 4, &credit, captureRelatedPhotoCredit));
    try std.testing.expectEqual(Status.not_found, orca_library_related_artist_photo_info(runtime, library, related_mbid, related_mbid.len, &credit, captureRelatedPhotoCredit));
    const library_database = try core.runtime.libraryDatabase(&runtimeBox(runtime).?.runtime, importLibrary(library));
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 0 };
    try library_database.artist_info.storeRelatedPhoto(related_mbid, &.{
        .image = .{ .bytes = &png, .mime_type = "image/png" },
        .record = .{ .licence = "CC BY 4.0", .credit = "A. Photographer" },
    }, 10);
    try std.testing.expectEqual(Status.ok, orca_library_related_artist_photo(runtime, library, "CCCCCCCC-0000-4000-8000-000000000003", related_mbid.len, &calls, countImage));
    try std.testing.expectEqual(@as(usize, 1), calls);
    calls = 0;
    try std.testing.expectEqual(Status.ok, orca_library_related_artist_photo_info(runtime, library, related_mbid, related_mbid.len, &credit, captureRelatedPhotoCredit));
    try std.testing.expectEqual(@as(usize, 1), credit.calls);
    try std.testing.expectEqual(@as(u8, 1), credit.source);
    try std.testing.expectEqual(@as(i64, 10), credit.fetched_at);
    try std.testing.expectEqualStrings("CC BY 4.0", credit.licence[0..credit.licence_len]);
    try std.testing.expectEqualStrings("A. Photographer", credit.credit[0..credit.credit_len]);

    var fill: GenreFillView = .{ .musicbrainz = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_genre_fill(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_genre_fill(runtime, library, &fill));
    try std.testing.expectEqual(@as(u8, 1), fill.musicbrainz);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_genre_fill(runtime, library, null));
    fill.musicbrainz = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_genre_fill(runtime, library, &fill));
    fill.musicbrainz = 0;
    try std.testing.expectEqual(Status.ok, orca_library_set_genre_fill(runtime, library, &fill));
    fill.musicbrainz = 1;
    try std.testing.expectEqual(Status.ok, orca_library_genre_fill(runtime, library, &fill));
    try std.testing.expectEqual(@as(u8, 0), fill.musicbrainz);

    var fill_options: GenreFillOptionsView = .{ .limit = 0, .offline = 1 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_genre_fill(runtime, library, &fill_options, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_genre_fill(runtime, library, null, &started));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_genre_fill(runtime, library, &fill_options, &started));
    try std.testing.expectEqualStrings("orca_library_start_genre_fill: InvalidLimit", std.mem.span(orca_runtime_last_error(runtime)));
    fill_options.limit = 1;
    fill_options.offline = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_genre_fill(runtime, library, &fill_options, &started));
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "artwork requests past 64 outstanding are busy until a result is taken, and a coverless subject arrives without an image" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-artwork-busy?mode=memory&cache=shared",
        &library,
    ));
    var first: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_request_artwork(runtime, library, 1, 7, &first));
    var request: u64 = 0;
    for (1..core.artwork.capacity) |_| {
        try std.testing.expectEqual(Status.ok, orca_library_request_artwork(runtime, library, 0, 3, &request));
    }
    try std.testing.expectEqual(Status.busy, orca_library_request_artwork(runtime, library, 0, 3, &request));

    var captured: ArtworkResultView = undefined;
    try awaitArtworkResult(runtime, library, &captured);
    try std.testing.expectEqual(first, captured.request);
    try std.testing.expectEqual(@as(u8, 1), captured.subject);
    try std.testing.expectEqual(@as(i64, 7), captured.subject_id);
    try std.testing.expectEqual(@as(u8, 0), captured.has_image);
    try std.testing.expectEqual(@as(usize, 0), captured.image.length);
    try std.testing.expectEqual(Status.ok, orca_library_request_artwork(runtime, library, 0, 3, &request));
    try std.testing.expectEqual(Status.busy, orca_library_request_artwork(runtime, library, 0, 3, &request));
}

test "a Library that a newer Orca migrated is unsupported, whether the open or a later write met it" {
    try std.testing.expectEqual(Status.unsupported, mapError(error.SchemaVersionTooNew));
}

test "an undone, unreconciled or pruned tag write and a write still running each report their own status" {
    try std.testing.expectEqual(Status.already_done, mapError(error.MutationGroupAlreadyUndone));
    try std.testing.expectEqual(Status.needs_reconciliation, mapError(error.MutationNeedsReconciliation));
    try std.testing.expectEqual(Status.gone, mapError(error.TagWriteBackupPruned));
    try std.testing.expectEqual(Status.busy, mapError(error.TagWriteInProgress));
    try std.testing.expectEqual(Status.busy, mapError(error.TooManyPendingTagWrites));
    try std.testing.expectEqual(Status.not_found, mapError(error.MutationGroupNotFound));
    try std.testing.expectEqual(Status.invalid_state, mapError(error.MutationGroupNotCommitted));
    try std.testing.expectEqual(Status.invalid_state, mapError(error.TagTargetUnavailable));
    try std.testing.expectEqual(Status.invalid_argument, mapError(error.MutationApprovalMismatch));
}

test "a relocate onto another root's folder is an invalid argument, and over an unfinished or unreconciled write its own status" {
    try std.testing.expectEqual(Status.invalid_argument, mapError(error.RootPathOverlaps));
    try std.testing.expectEqual(Status.busy, mapError(error.MutationInProgress));
    try std.testing.expectEqual(Status.needs_reconciliation, mapError(error.MutationNeedsReconciliation));
}

test "tag edits and writes refuse bad arguments, unknown Tracks and plans, and a Library with no database file" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-tag-arguments?mode=memory&cache=shared",
        &library,
    ));
    const ids = [_]i64{1};
    const title = "Edited";
    const edit: TrackEditView = .{
        .field = exportMetadataField(.title),
        .has_value = 1,
        .value = .{ .pointer = title.ptr, .length = title.len },
    };
    var unknown_field = edit;
    unknown_field.field = 13;
    var null_value = edit;
    null_value.value = .{ .pointer = null, .length = 3 };
    const zero = "0";
    var bad_track_number = edit;
    bad_track_number.field = exportMetadataField(.track_number);
    bad_track_number.value = .{ .pointer = zero.ptr, .length = zero.len };
    const too_many_edits: [max_track_edits + 1]TrackEditView = @splat(edit);
    const too_many_ids: [max_page + 1]i64 = @splat(1);
    var calls: usize = 0;

    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, null, 1, &.{edit}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &too_many_ids, too_many_ids.len, &.{edit}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &.{edit}, 0, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &too_many_edits, too_many_edits.len, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, null, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &.{unknown_field}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &.{null_value}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &.{bad_track_number}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.not_found, orca_library_edit_tracks(runtime, library, &ids, 1, &.{edit}, 1, &calls, countIds));
    try std.testing.expectEqual(@as(usize, 0), calls);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_track_edits(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_query_track_edits(runtime, library, 1, &calls, countFieldValue));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_plan_tag_write(runtime, library, &ids, 1, &calls, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_plan_tag_write(runtime, library, &ids, 0, &calls, countPlan));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_plan_tag_write(runtime, library, null, 1, &calls, countPlan));
    try std.testing.expectEqual(Status.not_found, orca_library_plan_tag_write(runtime, library, &ids, 1, &calls, countPlan));
    try std.testing.expectEqual(@as(usize, 0), calls);

    const digest: TagWriteDigest = .{ .bytes = @splat(0) };
    var started: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_tag_write(runtime, library, 1, null, &started));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_tag_write(runtime, library, 1, &digest, null));
    try std.testing.expectEqual(Status.not_found, orca_library_start_tag_write(runtime, library, 1, &digest, &started));
    try std.testing.expectEqual(Status.not_found, orca_library_discard_tag_write(runtime, library, 1));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_tag_write_genres(runtime, library, 1, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_query_tag_write_genres(runtime, library, 1, 1, &calls, countGenres));
    try std.testing.expectEqual(@as(usize, 0), calls);

    var backups: u64 = 7;
    var bytes: u64 = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_prune_tag_write_backups(runtime, library, 0, null, &bytes));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_prune_tag_write_backups(runtime, library, 0, &backups, null));
    try std.testing.expectEqual(Status.invalid_state, orca_library_prune_tag_write_backups(runtime, library, 0, &backups, &bytes));
    try std.testing.expectEqual(@as(u64, 7), backups);
    try std.testing.expectEqual(Status.invalid_state, orca_library_undo_tag_write(runtime, library, 1));

    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
    try std.testing.expectEqual(Status.stale_handle, orca_library_edit_tracks(runtime, library, &ids, 1, &.{edit}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.stale_handle, orca_library_query_track_edits(runtime, library, 1, &calls, countFieldValue));
    try std.testing.expectEqual(Status.stale_handle, orca_library_plan_tag_write(runtime, library, &ids, 1, &calls, countPlan));
    try std.testing.expectEqual(Status.stale_handle, orca_library_query_tag_write_genres(runtime, library, 1, 1, &calls, countGenres));
    try std.testing.expectEqual(Status.stale_handle, orca_library_undo_tag_write(runtime, library, 1));
    try std.testing.expectEqual(Status.stale_handle, orca_library_prune_tag_write_backups(runtime, library, 0, &backups, &bytes));
}

test "an edit is held locked as the user's, and a Library with no database file keeps the plan it shows but refuses to write it" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const scanned = try core.runtime_tests.scannedTempLibrary(
        &box.runtime,
        &temporary,
        "file:orca-c-api-tag-plan?mode=memory&cache=shared",
    );
    const library = exportLibraryHandle(scanned);
    const track_ids = try core.runtime_tests.allTrackIds(&box.runtime, scanned);
    defer std.testing.allocator.free(track_ids);
    try std.testing.expectEqual(@as(usize, 3), track_ids.len);

    const title = "C ABI Title";
    const edit: TrackEditView = .{
        .field = exportMetadataField(.title),
        .has_value = 1,
        .value = .{ .pointer = title.ptr, .length = title.len },
    };
    var edited: CapturedIds = .{};
    try std.testing.expectEqual(Status.ok, orca_library_edit_tracks(runtime, library, track_ids.ptr, track_ids.len, &.{edit}, 1, &edited, captureIds));
    try std.testing.expectEqual(@as(usize, 3), edited.count);

    var value: CapturedFieldValue = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_track_edits(runtime, library, edited.ids[0], &value, captureFieldValue));
    try std.testing.expectEqual(@as(usize, 1), value.count);
    try std.testing.expectEqual(exportMetadataField(.title), value.field);
    try std.testing.expectEqual(exportProvenance(.user), value.provenance);
    try std.testing.expectEqual(@as(u8, 1), value.locked);
    try std.testing.expectEqualStrings(title, value.text[0..value.text_length]);

    var plan: CapturedPlan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, &edited.ids, edited.count, &plan, capturePlan));
    try std.testing.expectEqual(@as(usize, 1), plan.calls);
    try std.testing.expect(plan.plan_id != 0);
    try std.testing.expectEqual(@as(usize, 2), plan.file_count);
    try std.testing.expectEqual(@as(usize, 2), plan.title_changes);
    try std.testing.expectEqual(@as(usize, 1), plan.skip_count);
    try std.testing.expectEqual(exportTagWriteSkipReason(.format_not_writable), plan.skip_reason);
    try std.testing.expectEqual(@as(usize, 0), plan.conflict_count);
    var genre_calls: usize = 0;
    try std.testing.expectEqual(Status.not_found, orca_library_query_tag_write_genres(runtime, library, plan.plan_id, plan.first_file_id, &genre_calls, countGenres));
    try std.testing.expectEqual(@as(usize, 0), genre_calls);

    var started: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_tag_write(runtime, library, plan.plan_id, &plan.digest, &started));
    try std.testing.expectEqual(Status.ok, orca_library_discard_tag_write(runtime, library, plan.plan_id));
    try std.testing.expectEqual(Status.not_found, orca_library_discard_tag_write(runtime, library, plan.plan_id));

    const clear: TrackEditView = .{ .field = exportMetadataField(.title), .has_value = 0, .value = .{ .pointer = null, .length = 0 } };
    try std.testing.expectEqual(Status.ok, orca_library_edit_tracks(runtime, library, &edited.ids, edited.count, &.{clear}, 1, null, null));
    value = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_track_edits(runtime, library, edited.ids[0], &value, captureFieldValue));
    try std.testing.expectEqual(@as(usize, 0), value.count);
    plan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, &edited.ids, edited.count, &plan, capturePlan));
    try std.testing.expectEqual(@as(u64, 0), plan.plan_id);
    try std.testing.expectEqual(@as(usize, 0), plan.file_count);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "a folder Orca cannot create files in is skipped, and a write that failed there reports its file and reason" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try core.runtime_tests.tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    try core.runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    const scanned = try core.runtime_tests.scannedTempFolder(&box.runtime, &temporary, database_path);
    const library = exportLibraryHandle(scanned);
    const track_ids = try core.runtime_tests.allTrackIds(&box.runtime, scanned);
    defer std.testing.allocator.free(track_ids);
    const title = "C ABI Title";
    const edited = try box.runtime.libraryEditTracks(scanned, track_ids, &.{.{ .field = .title, .value = title }});
    defer edited.deinit();

    var held: CapturedPlan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, edited.ids.ptr, edited.ids.len, &held, capturePlan));
    try std.testing.expectEqual(@as(usize, 1), held.file_count);
    try temporary.parent_dir.setFilePermissions(std.testing.io, &temporary.sub_path, .fromMode(0o555), .{});
    defer temporary.parent_dir.setFilePermissions(std.testing.io, &temporary.sub_path, .default_dir, .{}) catch {};

    var skipped: CapturedPlan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, edited.ids.ptr, edited.ids.len, &skipped, capturePlan));
    try std.testing.expectEqual(@as(u64, 0), skipped.plan_id);
    try std.testing.expectEqual(@as(usize, 1), skipped.skip_count);
    try std.testing.expectEqual(@as(u8, 3), skipped.skip_reason);

    var failed: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_tag_write(runtime, library, held.plan_id, &held.digest, &failed));
    try std.testing.expectEqual(job.State.failed, try core.runtime_tests.awaitJob(&box.runtime, importJob(failed)));
    var failure: TagWriteFailureView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_tag_write_failure(runtime, failed, &failure));
    try std.testing.expectEqual(held.first_file_id, failure.file_id);
    try std.testing.expectEqual(@as(u32, 0), failure.action_index);
    try std.testing.expectEqual(@as(u8, 0), failure.reason);
    try std.testing.expectEqual(Status.invalid_argument, orca_job_tag_write_failure(runtime, failed, null));

    try temporary.parent_dir.setFilePermissions(std.testing.io, &temporary.sub_path, .default_dir, .{});
    var writable: CapturedPlan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, edited.ids.ptr, edited.ids.len, &writable, capturePlan));
    var written: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_tag_write(runtime, library, writable.plan_id, &writable.digest, &written));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(written)));
    try std.testing.expectEqual(Status.not_found, orca_job_tag_write_failure(runtime, written, &failure));

    const scan = try box.runtime.startLibraryScan(scanned, .{});
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, scan));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_tag_write_failure(runtime, exportJobHandle(scan), &failure));
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const CapturedIds = struct {
    ids: [8]i64 = @splat(0),
    count: usize = 0,
};

fn captureIds(context: ?*anyopaque, ids: [*]const i64, count: usize) callconv(.c) void {
    const captured: *CapturedIds = @ptrCast(@alignCast(context.?));
    const kept = @min(count, captured.ids.len);
    @memcpy(captured.ids[0..kept], ids[0..kept]);
    captured.count = count;
}

fn countIds(context: ?*anyopaque, ids: [*]const i64, count: usize) callconv(.c) void {
    _ = ids;
    _ = count;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
}

const CapturedFieldValue = struct {
    count: usize = 0,
    field: u8 = 0,
    provenance: u8 = 0,
    locked: u8 = 0,
    text: [64]u8 = @splat(0),
    text_length: usize = 0,
};

fn captureFieldValue(context: ?*anyopaque, value: *const FieldValueView) callconv(.c) void {
    const captured: *CapturedFieldValue = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.field = value.field;
    captured.provenance = value.provenance;
    captured.locked = value.locked;
    captured.text_length = @min(value.text.length, captured.text.len);
    @memcpy(captured.text[0..captured.text_length], value.text.pointer[0..captured.text_length]);
}

fn countFieldValue(context: ?*anyopaque, value: *const FieldValueView) callconv(.c) void {
    _ = value;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
}

const CapturedPlan = struct {
    title: []const u8,
    calls: usize = 0,
    plan_id: u64 = 0,
    digest: TagWriteDigest = .{ .bytes = @splat(0) },
    file_count: usize = 0,
    title_changes: usize = 0,
    skip_count: usize = 0,
    skip_reason: u8 = 255,
    conflict_count: usize = 0,
    first_file_id: i64 = 0,
};

fn capturePlan(context: ?*anyopaque, plan: *const TagWritePlanView) callconv(.c) void {
    const captured: *CapturedPlan = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.plan_id = plan.plan_id;
    captured.digest = plan.digest;
    captured.file_count = plan.file_count;
    captured.skip_count = plan.skip_count;
    captured.conflict_count = plan.conflict_count;
    if (plan.file_count != 0) captured.first_file_id = plan.files[0].file_id;
    for (plan.files[0..plan.file_count]) |file| {
        for (file.changes[0..file.change_count]) |change| {
            if (change.field == exportMetadataField(.title) and
                change.provenance == exportProvenance(.user) and
                change.has_before == 1 and
                std.mem.eql(u8, change.after.pointer[0..change.after.length], captured.title))
                captured.title_changes += 1;
        }
    }
    if (plan.skip_count != 0) captured.skip_reason = plan.skipped[0].reason;
}

fn countPlan(context: ?*anyopaque, plan: *const TagWritePlanView) callconv(.c) void {
    _ = plan;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
}

fn countGenres(context: ?*anyopaque, genres: *const TagWriteGenresView) callconv(.c) void {
    _ = genres;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
}

const FakeKeyring = struct {
    result: c_int = 0,
    secret: []const u8 = "host-secret",
    rotated: std.atomic.Value(bool) = .init(false),
    reported_length: ?usize = null,
    capacity: usize = 0,
    calls: std.atomic.Value(u32) = .init(0),
    late_calls: std.atomic.Value(u32) = .init(0),
    destroyed: std.atomic.Value(bool) = .init(false),
    thread: std.atomic.Value(std.Thread.Id) = .init(0),
    service: [32]u8 = @splat(0),
    account: [32]u8 = @splat(0),

    fn lookup(
        context: ?*anyopaque,
        service: [*:0]const u8,
        account: [*:0]const u8,
        buffer: [*]u8,
        capacity: usize,
        length: *usize,
    ) callconv(.c) c_int {
        const self: *FakeKeyring = @ptrCast(@alignCast(context.?));
        if (self.destroyed.load(.acquire)) _ = self.late_calls.fetchAdd(1, .acq_rel);
        self.capacity = capacity;
        const service_text = std.mem.span(service);
        const account_text = std.mem.span(account);
        @memcpy(self.service[0..service_text.len], service_text);
        @memcpy(self.account[0..account_text.len], account_text);
        self.thread.store(std.Thread.getCurrentId(), .release);
        const secret = if (self.rotated.load(.acquire)) "changed-secret" else self.secret;
        const written = @min(secret.len, capacity);
        @memcpy(buffer[0..written], secret[0..written]);
        length.* = self.reported_length orelse written;
        _ = self.calls.fetchAdd(1, .acq_rel);
        return self.result;
    }

    fn serviceName(self: *const FakeKeyring) []const u8 {
        return std.mem.sliceTo(&self.service, 0);
    }

    fn accountName(self: *const FakeKeyring) []const u8 {
        return std.mem.sliceTo(&self.account, 0);
    }
};

fn expectNoSecret(backing: []const u8, secret: []const u8) !void {
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, backing, secret));
}

test "a credential the host finds is returned whole, and no copy of it is left behind once freed" {
    var backing: [4096]u8 = @splat(0);
    var fixed: std.heap.FixedBufferAllocator = .init(&backing);
    var keyring: FakeKeyring = .{};
    var slot: CredentialSlot = .{ .callback = FakeKeyring.lookup, .context = &keyring };

    const secret = (try hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token")).?;
    try std.testing.expectEqualStrings("host-secret", secret);
    try std.testing.expectEqual(credential_max_bytes, keyring.capacity);
    try std.testing.expectEqualStrings("org.listenbrainz", keyring.serviceName());
    try std.testing.expectEqualStrings("user-token", keyring.accountName());
    providers.credentials.wipeAndFree(fixed.allocator(), secret);
    try expectNoSecret(&backing, "host-secret");

    var full: [credential_max_bytes]u8 = @splat('k');
    keyring.secret = &full;
    const largest = (try hostCredential(&slot, fixed.allocator(), "org.acoustid", "user-key")).?;
    try std.testing.expectEqual(credential_max_bytes, largest.len);
    providers.credentials.wipeAndFree(fixed.allocator(), largest);
    try expectNoSecret(&backing, &full);
}

test "a missing credential is absent, while an unavailable or oversized one is an error, and none leaves the secret behind" {
    var backing: [4096]u8 = @splat(0);
    var fixed: std.heap.FixedBufferAllocator = .init(&backing);
    var keyring: FakeKeyring = .{};
    var slot: CredentialSlot = .{ .callback = FakeKeyring.lookup, .context = &keyring };

    keyring.result = @backingInt(CredentialResult.not_found);
    try std.testing.expectEqual(@as(?[]u8, null), try hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @backingInt(CredentialResult.unavailable);
    try std.testing.expectError(error.CredentialUnavailable, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @backingInt(CredentialResult.too_large);
    try std.testing.expectError(error.CredentialTooLarge, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @backingInt(CredentialResult.found);
    keyring.reported_length = credential_max_bytes + 1;
    try std.testing.expectError(error.CredentialTooLarge, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.reported_length = null;
    keyring.result = 7;
    try std.testing.expectError(error.CredentialUnavailable, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");
    try std.testing.expectEqual(@as(u32, 5), keyring.calls.load(.acquire));

    slot = .{};
    try std.testing.expectEqual(@as(?[]u8, null), try hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try std.testing.expectEqual(@as(u32, 5), keyring.calls.load(.acquire));
}

test "a provider server is copied out of the caller's buffer, refused unless https or loopback http, and NULL restores the default" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;

    var caller: [64:0]u8 = @splat(0);
    const local = "http://127.0.0.1:8080/mb";
    @memcpy(caller[0..local.len], local);
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 1, &caller));
    const stored = box.runtime.musicbrainz_server.view();
    try std.testing.expect(@intFromPtr(stored.ptr) < @intFromPtr(&caller) or
        @intFromPtr(stored.ptr) >= @intFromPtr(&caller) + caller.len);
    @memset(caller[0..local.len], 'x');
    try std.testing.expectEqualStrings(local, box.runtime.musicbrainz_server.view());

    for ([_][*:0]const u8{
        "http://127.0.0.1@example.org",
        "http://example.org",
        "https://user:secret@example.org",
        "ftp://example.org",
        "http://[::1]:9/acoustid",
    }) |refused| {
        try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_provider_server(runtime, 1, refused));
        try std.testing.expectEqualStrings(
            "orca_runtime_set_provider_server: InvalidServerUrl",
            std.mem.span(orca_runtime_last_error(runtime)),
        );
        try std.testing.expectEqualStrings(local, box.runtime.musicbrainz_server.view());
    }
    var long: [providers.url.max_server_bytes + 1:0]u8 = @splat('a');
    @memcpy(long[0.."https://".len], "https://");
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_provider_server(runtime, 1, &long));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_provider_server(runtime, 99, "https://example.org"));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_provider_server: unknown provider service",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 0, "https://lb.example.org"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 2, "https://acoustid.example.org/v2"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 3, "http://localhost:9"));
    try std.testing.expectEqualStrings("https://lb.example.org", box.runtime.listenbrainz_server.view());
    try std.testing.expectEqualStrings("https://acoustid.example.org/v2", box.runtime.acoustid_server.view());
    try std.testing.expectEqualStrings("http://localhost:9", box.runtime.coverartarchive_server.view());

    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 4, "http://127.0.0.1:9/lrclib"));
    try std.testing.expectEqualStrings("http://127.0.0.1:9/lrclib", box.runtime.lrclib_server.view());

    for (0..5) |service| try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, @intCast(service), null));
    try std.testing.expectEqualStrings(providers.listenbrainz.default_server, box.runtime.listenbrainz_server.view());
    try std.testing.expectEqualStrings(providers.musicbrainz.default_server, box.runtime.musicbrainz_server.view());
    try std.testing.expectEqualStrings(providers.acoustid.default_server, box.runtime.acoustid_server.view());
    try std.testing.expectEqualStrings(providers.coverartarchive.default_server, box.runtime.coverartarchive_server.view());
    try std.testing.expectEqualStrings(providers.lrclib.default_server, box.runtime.lrclib_server.view());
}

test "the embedding model path and state are reachable and a similar-tracks search refuses what it cannot answer" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var state: u8 = 255;
    try std.testing.expectEqual(Status.ok, orca_runtime_embedding_model_state(runtime, &state));
    try std.testing.expect(state == @backingInt(core.embedding_model.State.missing) or state == @backingInt(core.embedding_model.State.built_without));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_embedding_model_state(runtime, null));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_embedding_model_path(runtime, "/nonexistent/model.onnx"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_embedding_model_path(runtime, null));

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-similar?mode=memory&cache=shared", &library));
    var buffer: [2]SimilarTrackView = undefined;
    var count: usize = 99;
    try std.testing.expectEqual(Status.not_found, orca_library_similar_tracks(runtime, library, 1, &buffer, buffer.len, &count));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_similar_tracks(runtime, library, 1, &buffer, 1001, &count));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_similar_tracks(runtime, library, 1, &buffer, buffer.len, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_similar_tracks(runtime, library, 1, null, buffer.len, &count));
    try std.testing.expectEqual(@as(usize, 99), count);

    const library_database = try core.runtime.databaseOf(&runtimeBox(runtime).?.runtime, importLibrary(library));
    try library_database.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'r'), (2, 'r'), (3, 'r'), (4, 'r');
        \\INSERT INTO files(id, recording_id, size_bytes, quick_hash, content_hash, content_hash_algorithm) VALUES
        \\    (1, 1, 1, x'01', x'01', 1), (2, 2, 1, x'01', x'01', 1), (3, 3, 1, x'01', x'01', 1), (4, 4, 1, x'01', x'01', 1);
        \\INSERT INTO tracks(id, recording_id, title) VALUES (11, 1, 'seed'), (12, 2, 'far'), (13, 3, 'near'), (14, 4, 'unmeasured');
    );
    var embedding = try library_database.database.prepare(
        "INSERT INTO file_audio_embeddings(model, file_id, source_identity, vector) VALUES (1, ?1, x'01', ?2);",
    );
    defer embedding.deinit();
    for ([_][2]i8{ .{ 100, 0 }, .{ 0, 100 }, .{ 80, 60 } }, 1..) |head, file_id| {
        var vector: [512]i8 = @splat(0);
        vector[0..2].* = head;
        try embedding.reset();
        try embedding.bindInt64(1, @intCast(file_id));
        try embedding.bindBlob(2, std.mem.asBytes(&vector));
        _ = try embedding.step();
    }

    var found: [3]SimilarTrackView = @splat(.{ .track_id = -1, .similarity = -1 });
    try std.testing.expectEqual(Status.ok, orca_library_similar_tracks(runtime, library, 11, &found, found.len, &count));
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(i64, 13), found[0].track_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), found[0].similarity, 1e-6);
    try std.testing.expectEqual(@as(i64, 12), found[1].track_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), found[1].similarity, 1e-6);
    try std.testing.expectEqual(@as(i64, -1), found[2].track_id);

    found = @splat(.{ .track_id = -1, .similarity = -1 });
    try std.testing.expectEqual(Status.ok, orca_library_similar_tracks(runtime, library, 11, &found, 1, &count));
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(i64, 13), found[0].track_id);
    try std.testing.expectEqual(@as(i64, -1), found[1].track_id);

    count = 99;
    try std.testing.expectEqual(Status.ok, orca_library_similar_tracks(runtime, library, 11, null, 0, &count));
    try std.testing.expectEqual(@as(usize, 0), count);

    count = 99;
    try std.testing.expectEqual(Status.invalid_state, orca_library_similar_tracks(runtime, library, 14, &found, found.len, &count));
    try std.testing.expectEqual(@as(usize, 99), count);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const model_download_body = bytes: {
    var bytes: [300]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
    break :bytes bytes;
};

const ModelDownloadRig = struct {
    temporary: std.testing.TmpDir,
    transport: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .{},
    prng: std.Random.DefaultPrng = .init(0x5eed),
    destination: [:0]u8,

    fn init(self: *ModelDownloadRig, box: *RuntimeBox) !void {
        self.* = .{
            .temporary = std.testing.tmpDir(.{}),
            .destination = undefined,
        };
        errdefer self.temporary.cleanup();
        self.destination = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/model.onnx", .{self.temporary.sub_path}, 0);
        self.transport.clock = &self.clock;
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&model_download_body, &digest, .{});
        box.runtime.model_download_hooks = .{
            .transport = self.transport.transport(),
            .clock = self.clock.clock(),
            .wall_clock = self.clock.wallClock(),
            .random = self.prng.random(),
            .descriptor = .{ .url = audio_embedding.ModelId.clap_htsat_unfused.spec().url, .size = model_download_body.len, .sha256 = digest },
        };
    }

    fn deinit(self: *ModelDownloadRig) void {
        self.transport.deinit();
        std.testing.allocator.free(self.destination);
        self.temporary.cleanup();
    }
};

fn finishedState(runtime: *Runtime, job_handle: Handle) !?u8 {
    var state: ?u8 = null;
    var event: Event = undefined;
    while (true) {
        try std.testing.expectEqual(Status.ok, orca_runtime_poll_event(runtime, &event, null));
        if (event.kind == @backingInt(EventKind.none)) return state;
        if (event.kind == @backingInt(EventKind.job_finished) and
            std.meta.eql(event.payload.job_finished.job, job_handle)) state = event.payload.job_finished.state;
    }
}

const model_id: u8 = @backingInt(core.runtime.EmbeddingModel.clap_htsat_unfused);

test "orca_runtime_start_embedding_model_download refuses an unknown model and starts nothing" {
    if (!audio_embedding.enabled) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var transport: network.testing.ScriptedTransport = .{};
    defer transport.deinit();
    box.runtime.model_download_hooks.transport = transport.transport();
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Orca C Test", "1.0", "https://orca.invalid"));
    var started = std.mem.zeroes(Handle);

    for ([_]u8{ 0, 3, 255 }) |unknown| {
        try std.testing.expectEqual(Status.invalid_argument, orca_runtime_start_embedding_model_download(runtime, unknown, "model.onnx", &started));
        try std.testing.expectEqualStrings(
            "orca_runtime_start_embedding_model_download: unknown embedding model",
            std.mem.span(orca_runtime_last_error(runtime)),
        );
    }
    try std.testing.expectEqual(std.mem.zeroes(Handle), started);
    try std.testing.expectEqual(@as(u32, 0), transport.requestCount());
    try std.testing.expect(box.runtime.model_download == null);
}

test "orca_runtime_start_embedding_model_download refuses a missing, empty, too long or unreceivable argument and starts nothing" {
    if (!audio_embedding.enabled) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var transport: network.testing.ScriptedTransport = .{};
    defer transport.deinit();
    box.runtime.model_download_hooks.transport = transport.transport();
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Orca C Test", "1.0", "https://orca.invalid"));
    var started = std.mem.zeroes(Handle);

    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_start_embedding_model_download(runtime, model_id, null, &started));
    try std.testing.expectEqualStrings(
        "orca_runtime_start_embedding_model_download: path is null",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_start_embedding_model_download(runtime, model_id, "", &started));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_start_embedding_model_download(runtime, model_id, "model.onnx", null));
    var long: [std.Io.Dir.max_path_bytes + 1:0]u8 = @splat('a');
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_start_embedding_model_download(runtime, model_id, &long, &started));
    try std.testing.expectEqual(std.mem.zeroes(Handle), started);
    try std.testing.expectEqual(@as(u32, 0), transport.requestCount());
    try std.testing.expect(box.runtime.model_download == null);
}

test "orca_runtime_start_embedding_model_download needs a client identity" {
    if (!audio_embedding.enabled) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var transport: network.testing.ScriptedTransport = .{};
    defer transport.deinit();
    box.runtime.model_download_hooks.transport = transport.transport();
    var started = std.mem.zeroes(Handle);

    try std.testing.expectEqual(Status.invalid_state, orca_runtime_start_embedding_model_download(runtime, model_id, "model.onnx", &started));
    try std.testing.expectEqualStrings(
        "orca_runtime_start_embedding_model_download: ClientIdentityRequired",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(@as(u32, 0), transport.requestCount());
}

test "orca_runtime_start_embedding_model_download is unsupported without embeddings" {
    if (audio_embedding.enabled) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Orca C Test", "1.0", "https://orca.invalid"));
    var started = std.mem.zeroes(Handle);

    try std.testing.expectEqual(Status.unsupported, orca_runtime_start_embedding_model_download(runtime, model_id, "model.onnx", &started));
    try std.testing.expectEqual(std.mem.zeroes(Handle), started);
}

test "orca_runtime_embedding_model writes zero before a path and for a wrong file and refuses a null output" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var model: u8 = 255;
    try std.testing.expectEqual(Status.ok, orca_runtime_embedding_model(runtime, &model));
    try std.testing.expectEqual(@as(u8, 0), model);
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_embedding_model(runtime, null));
    try std.testing.expectEqualStrings("orca_runtime_embedding_model: output is null", std.mem.span(orca_runtime_last_error(runtime)));

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "wrong.onnx", .data = "not a model" });
    const wrong = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/wrong.onnx", .{temporary.sub_path}, 0);
    defer std.testing.allocator.free(wrong);
    try std.testing.expectEqual(Status.ok, orca_runtime_set_embedding_model_path(runtime, wrong.ptr));
    model = 255;
    try std.testing.expectEqual(Status.ok, orca_runtime_embedding_model(runtime, &model));
    try std.testing.expectEqual(@as(u8, 0), model);
}

test "orca_runtime_start_embedding_model_download installs the MAEST model and orca_runtime_embedding_model then writes 2" {
    if (!audio_embedding.enabled) return error.SkipZigTest;
    const spec = audio_embedding.ModelId.discogs_maest.spec();
    const model_path = try audio_embedding.testModelPath(.discogs_maest);
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var rig: ModelDownloadRig = undefined;
    try rig.init(box);
    defer rig.deinit();
    const model = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, model_path, std.testing.allocator, .limited(spec.size + 1));
    defer std.testing.allocator.free(model);
    box.runtime.model_download_hooks.descriptor = null;
    rig.transport.chunk_bytes = network.client.Sink.max_chunk_bytes;
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Orca C Test", "1.0", "https://orca.invalid"));
    try rig.transport.script(.{ .respond = .{ .status = 302, .body = "", .location = "https://release-assets.githubusercontent.com/model?signature=1" } });
    try rig.transport.script(.{ .respond = .{ .body = model } });

    var started = std.mem.zeroes(Handle);
    try std.testing.expectEqual(Status.ok, orca_runtime_start_embedding_model_download(
        runtime,
        @backingInt(core.runtime.EmbeddingModel.discogs_maest),
        rig.destination.ptr,
        &started,
    ));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJobPumping(&box.runtime, importJob(started)));
    const installed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, rig.destination, std.testing.allocator, .limited(spec.size + 1));
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqual(spec.size, installed.len);

    var state: u8 = 255;
    try std.testing.expectEqual(Status.ok, orca_runtime_embedding_model_state(runtime, &state));
    try std.testing.expectEqual(@backingInt(core.embedding_model.State.ready), state);
    var active: u8 = 255;
    try std.testing.expectEqual(Status.ok, orca_runtime_embedding_model(runtime, &active));
    try std.testing.expectEqual(@as(u8, 2), active);
}

test "orca_runtime_start_embedding_model_download installs the model, reports the job and refuses a second download while one runs" {
    if (!audio_embedding.enabled) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var rig: ModelDownloadRig = undefined;
    try rig.init(box);
    defer rig.deinit();
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Orca C Test", "1.0", "https://orca.invalid"));
    try rig.transport.script(.{ .respond = .{ .body = &model_download_body } });

    var started = std.mem.zeroes(Handle);
    try std.testing.expectEqual(Status.ok, orca_runtime_start_embedding_model_download(runtime, model_id, rig.destination.ptr, &started));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJobPumping(&box.runtime, importJob(started)));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(runtime, started, &snapshot));
    try std.testing.expectEqual(@as(u8, 14), snapshot.kind);
    try std.testing.expectEqual(@backingInt(job.State.succeeded), snapshot.state);
    try std.testing.expectEqual(@as(u64, model_download_body.len), snapshot.completed_units);
    try std.testing.expectEqual(@as(u64, model_download_body.len), snapshot.total_units);
    try std.testing.expectEqual(@as(?u8, @backingInt(job.State.succeeded)), try finishedState(runtime, started));
    const installed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, rig.destination, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqualSlices(u8, &model_download_body, installed);
    try std.testing.expectEqual(@as(u32, 1), rig.transport.requestCount());

    try rig.transport.script(.hang);
    var hanging = std.mem.zeroes(Handle);
    const second_destination = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}.second", .{rig.destination}, 0);
    defer std.testing.allocator.free(second_destination);
    var refused = std.mem.zeroes(Handle);
    try std.testing.expectEqual(Status.ok, orca_runtime_start_embedding_model_download(runtime, model_id, second_destination.ptr, &hanging));
    var deadline: core.runtime_tests.TestDeadline = .init(5_000);
    while (rig.transport.requestCount() < 2 and deadline.tick()) {}
    try std.testing.expectEqual(@as(u32, 2), rig.transport.requestCount());
    try std.testing.expectEqual(Status.busy, orca_runtime_start_embedding_model_download(runtime, model_id, rig.destination.ptr, &refused));
    try std.testing.expectEqual(std.mem.zeroes(Handle), refused);

    try std.testing.expectEqual(Status.ok, orca_job_cancel(runtime, hanging));
    try std.testing.expectEqual(job.State.cancelled, try core.runtime_tests.awaitJobPumping(&box.runtime, importJob(hanging)));
}

test "the client identity and AcoustID key are copied, and invalid ones are refused" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;

    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_client_identity(runtime, null, "1.0", "https://host.invalid"));
    try std.testing.expectEqualStrings("orca_runtime_set_client_identity: name is null", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_client_identity(runtime, "Host", null, "https://host.invalid"));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_client_identity(runtime, "Host", "1.0", null));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_client_identity(runtime, "Player (beta)", "1.0", "https://host.invalid"));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_client_identity: InvalidNetworkConfiguration",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(@as(?core.runtime.ClientIdentity, null), if (box.runtime.client_identity) |owned| owned.view() else null);

    var name = "Host".*;
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, &name, "1.0", "https://host.invalid"));
    name = "Xxxx".*;
    try std.testing.expectEqualStrings("Host", box.runtime.client_identity.?.view().name);

    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_acoustid_client_key(runtime, "with space"));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_acoustid_client_key: InvalidAcoustIdKey",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    var key = "AbC123".*;
    try std.testing.expectEqual(Status.ok, orca_runtime_set_acoustid_client_key(runtime, &key));
    key = "zzzzzz".*;
    try std.testing.expectEqualStrings("AbC123", box.runtime.acoustid_client_key.?.view());
    try std.testing.expectEqual(Status.ok, orca_runtime_set_acoustid_client_key(runtime, null));
    try std.testing.expect(box.runtime.acoustid_client_key == null);
}

test "the credential callback answers a listen worker on its own thread, cannot change while work exists, and is never called after destroy" {
    var transport: network.testing.ScriptedTransport = .{
        .otherwise = .{ .respond = .{ .body = "{\"valid\":true,\"user_name\":\"listener\"}" } },
    };
    defer transport.deinit();
    var clock: network.testing.TestClock = .{ .wall_offset_ms = 1_800_000_000_000 };
    var keyring: FakeKeyring = .{};

    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    var destroyed = false;
    defer if (!destroyed) orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;

    try std.testing.expectEqual(Status.ok, orca_runtime_set_credential_callback(runtime, FakeKeyring.lookup, &keyring));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Host", "1.0", "https://host.invalid"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 0, "http://127.0.0.1:8080"));
    box.runtime.listen_hooks = .{
        .transport = transport.transport(),
        .clock = clock.clock(),
        .wall_clock = clock.wallClock(),
        .poll_ms = 1,
    };
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-credentials?mode=memory&cache=shared", &library));
    try box.runtime.librarySetScrobbling(importLibrary(library), true, false, false);
    try std.testing.expectEqual(Status.ok, orca_library_scrobbler_credentials_changed(runtime, library));

    var deadline: core.runtime_tests.TestDeadline = .init(5_000);
    while (transport.requestCount() < 1) {
        if (!deadline.tick()) return error.TokenNeverValidated;
    }
    try std.testing.expect(std.mem.startsWith(u8, transport.lastUrl(), "http://127.0.0.1:8080/1/validate-token"));
    try std.testing.expectEqualStrings("Token host-secret", transport.lastAuthorization());
    try std.testing.expectEqualStrings("org.listenbrainz", keyring.serviceName());
    try std.testing.expectEqualStrings("user-token", keyring.accountName());
    try std.testing.expect(keyring.thread.load(.acquire) != std.Thread.getCurrentId());

    try std.testing.expectEqual(Status.invalid_state, orca_runtime_set_credential_callback(runtime, FakeKeyring.lookup, &keyring));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_credential_callback: WorkersRunning",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(Status.invalid_state, orca_runtime_set_credential_callback(runtime, null, null));

    const lookups = keyring.calls.load(.acquire);
    keyring.rotated.store(true, .release);
    try std.testing.expectEqual(Status.ok, orca_library_scrobbler_credentials_changed(runtime, library));
    deadline = .init(5_000);
    while (transport.requestCount() < 2) {
        if (!deadline.tick()) return error.ChangedTokenNeverValidated;
    }
    try std.testing.expect(keyring.calls.load(.acquire) > lookups);
    try std.testing.expectEqualStrings("Token changed-secret", transport.lastAuthorization());
    try std.testing.expectEqual(Status.stale_handle, orca_library_scrobbler_credentials_changed(runtime, .{ .index = library.index, .generation = library.generation + 1 }));

    orca_runtime_destroy(runtime);
    destroyed = true;
    keyring.destroyed.store(true, .release);
    var settle: core.runtime_tests.TestDeadline = .init(20);
    while (settle.tick()) {}
    try std.testing.expectEqual(@as(u32, 0), keyring.late_calls.load(.acquire));
}

const provider_tests = core.runtime_provider_tests;

const MatchingRig = struct {
    musicbrainz: provider_tests.FakeMusicBrainz = .{},
    acoustid: provider_tests.FakeAcoustId = .{},
    cover: provider_tests.FakeCoverArt = .{},
    temporary: std.testing.TmpDir,
    runtime: *Runtime,
    library: Handle = undefined,
    library_database: *database.LibraryDatabase = undefined,

    fn init(self: *MatchingRig, uri: [*:0]const u8, acoustid_key: ?[*:0]const u8) !void {
        const runtime = orca_runtime_create() orelse return error.OutOfMemory;
        self.* = .{ .temporary = std.testing.tmpDir(.{}), .runtime = runtime };
        errdefer self.deinit();
        const box = runtimeBox(runtime).?;
        try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Host", "1.0", "https://host.invalid"));
        try std.testing.expectEqual(Status.ok, orca_runtime_set_acoustid_client_key(runtime, acoustid_key));
        box.runtime.matching_hooks = self.musicbrainz.hooks();
        box.runtime.matching_hooks.acoustid_transport = self.acoustid.transport();
        self.cover.attach(&box.runtime.matching_hooks);
        try std.testing.expectEqual(Status.ok, orca_library_open(runtime, uri, &self.library));
        self.library_database = try core.runtime.libraryDatabase(&box.runtime, importLibrary(self.library));
    }

    fn deinit(self: *MatchingRig) void {
        orca_runtime_destroy(self.runtime);
        self.cover.deinit();
        self.temporary.cleanup();
    }

    fn finish(self: *MatchingRig, job_handle: Handle) !job.State {
        return core.runtime_tests.awaitJob(&runtimeBox(self.runtime).?.runtime, importJob(job_handle));
    }

    fn addTone(self: *MatchingRig, name: []const u8, frequency: f32, title: []const u8, recording_mbid: []const u8, release_id: i64) !i64 {
        try provider_tests.writeToneWave(self.temporary.dir, name, frequency);
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.temporary.sub_path, name });
        defer std.testing.allocator.free(path);
        const binding = try self.library_database.resolveOrCreateFile(std.testing.io, path, .{ .stable_key = "test:c-verify" });
        try self.library_database.observed_tags.upsert(.{ .file_id = binding.file_id, .values = .{
            .title = title,
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .musicbrainz_recording_id = recording_mbid,
        } });
        try self.library_database.tracks.upsertTracks(&.{.{
            .release_id = release_id,
            .title = title,
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .duration_ms = 15_000,
            .preferred_file_id = binding.file_id,
        }});
        return provider_tests.trackOfFile(self.library_database, binding.file_id);
    }

    fn addUntaggedTone(self: *MatchingRig, name: []const u8, frequency: f32, title: []const u8) !i64 {
        try provider_tests.writeToneWave(self.temporary.dir, name, frequency);
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.temporary.sub_path, name });
        defer std.testing.allocator.free(path);
        const binding = try self.library_database.resolveOrCreateFile(std.testing.io, path, .{ .stable_key = "test:c-submit" });
        try self.library_database.tracks.upsertTracks(&.{.{
            .title = title,
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .duration_ms = 15_000,
            .preferred_file_id = binding.file_id,
        }});
        return provider_tests.trackOfFile(self.library_database, binding.file_id);
    }

    fn lastError(self: *MatchingRig) []const u8 {
        return std.mem.span(orca_runtime_last_error(self.runtime));
    }
};

const CapturedText = struct {
    bytes: [64]u8 = undefined,
    length: usize = 0,

    fn set(self: *CapturedText, view: StringView) void {
        self.length = @min(view.length, self.bytes.len);
        @memcpy(self.bytes[0..self.length], view.pointer[0..self.length]);
    }

    fn text(self: *const CapturedText) []const u8 {
        return self.bytes[0..self.length];
    }
};

const CapturedProposal = struct {
    count: usize = 0,
    id: i64 = 0,
    provider: CapturedText = .{},
    recording_mbid: CapturedText = .{},
    release_title: CapturedText = .{},
    has_release_mbid: u8 = 0,
    has_corrects: u8 = 0,
    confidence: f32 = 0,
};

fn captureProposal(context: ?*anyopaque, proposal: *const MatchProposalView) callconv(.c) void {
    const captured: *CapturedProposal = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    if (captured.count != 1) return;
    captured.id = proposal.id;
    captured.provider.set(proposal.provider);
    captured.recording_mbid.set(proposal.recording_mbid);
    captured.release_title.set(proposal.release_title);
    captured.has_release_mbid = proposal.has_release_mbid;
    captured.has_corrects = proposal.has_corrects;
    captured.confidence = proposal.confidence;
}

const CapturedReview = struct {
    count: usize = 0,
    track_ids: [2]i64 = @splat(0),
    proposal_counts: [2]u32 = @splat(0),
    titles: [2]CapturedText = @splat(.{}),
    best_recordings: [2]CapturedText = @splat(.{}),
};

fn captureReview(context: ?*anyopaque, item: *const MatchReviewView) callconv(.c) void {
    const captured: *CapturedReview = @ptrCast(@alignCast(context.?));
    defer captured.count += 1;
    if (captured.count >= captured.track_ids.len) return;
    captured.track_ids[captured.count] = item.track_id;
    captured.proposal_counts[captured.count] = item.proposal_count;
    captured.titles[captured.count].set(item.title);
    captured.best_recordings[captured.count].set(item.best.recording_mbid);
}

const CapturedRecording = struct {
    count: usize = 0,
    recording_mbid: CapturedText = .{},
    source: u8 = 0,
};

fn captureRecording(context: ?*anyopaque, details: *const TrackDetailsView) callconv(.c) void {
    const captured: *CapturedRecording = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.recording_mbid.set(details.musicbrainz_recording_id);
    captured.source = details.musicbrainz_recording_id_source;
}

const CapturedVerification = struct {
    count: usize = 0,
    outcome: u8 = 255,
    recording_mbid: CapturedText = .{},
    heard_count: usize = 0,
    strongest: CapturedText = .{},
    strongest_score: f32 = 0,
    stale: u8 = 255,
};

fn captureVerification(context: ?*anyopaque, verification: *const TrackVerificationView) callconv(.c) void {
    const captured: *CapturedVerification = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.outcome = verification.outcome;
    captured.recording_mbid.set(verification.recording_mbid);
    captured.heard_count = verification.heard_count;
    if (verification.heard_count != 0) {
        captured.strongest.set(verification.heard[0].mbid);
        captured.strongest_score = verification.heard[0].score;
    }
    captured.stale = verification.stale;
}

const CapturedGroup = struct {
    count: usize = 0,
    group_id: i64 = 0,
    release_id: i64 = 0,
    has_release_id: u8 = 0,
    album: CapturedText = .{},
    member_count: usize = 0,
    first_proposal_id: i64 = 0,
    members_with_corrects: usize = 0,
    members_with_track: usize = 0,
};

fn captureGroup(context: ?*anyopaque, group: *const CorrectionGroupView) callconv(.c) void {
    const captured: *CapturedGroup = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.group_id = group.group_id;
    captured.release_id = group.release_id;
    captured.has_release_id = group.has_release_id;
    captured.album.set(group.album);
    captured.member_count = group.member_count;
    captured.members_with_corrects = 0;
    captured.members_with_track = 0;
    for (group.members[0..group.member_count]) |member| {
        captured.members_with_corrects += member.has_corrects;
        captured.members_with_track += member.has_track_id;
    }
    if (group.member_count != 0) captured.first_proposal_id = group.members[0].proposal_id;
}

const CapturedImage = struct {
    count: usize = 0,
    bytes: [64]u8 = undefined,
    length: usize = 0,
};

fn captureImage(context: ?*anyopaque, image: *const ImageView) callconv(.c) void {
    const captured: *CapturedImage = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.length = @min(image.length, captured.bytes.len);
    @memcpy(captured.bytes[0..captured.length], image.bytes[0..captured.length]);
}

const CapturedSubmittable = struct {
    count: usize = 0,
    last_file_id: i64 = 0,
    track_id: i64 = 0,
    recording_mbid: CapturedText = .{},
    title: CapturedText = .{},
    artist: CapturedText = .{},
    codec: CapturedText = .{},
    path: CapturedText = .{},
    has_path: u8 = 0,
    has_duration_ms: u8 = 0,
    duration_ms: i64 = 0,
    has_track_number: u8 = 255,
    has_year: u8 = 255,
    has_recording_length_ms: u8 = 255,
    size_bytes: i64 = 0,
};

fn captureSubmittable(context: ?*anyopaque, item: *const AcoustIdSubmittableView) callconv(.c) void {
    const captured: *CapturedSubmittable = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.last_file_id = item.file_id;
    captured.track_id = item.track_id;
    captured.recording_mbid.set(item.recording_mbid);
    captured.title.set(item.title);
    captured.artist.set(item.artist);
    captured.codec.set(item.codec);
    captured.path.set(item.path);
    captured.has_path = item.has_path;
    captured.has_duration_ms = item.has_duration_ms;
    captured.duration_ms = item.duration_ms;
    captured.has_track_number = item.has_track_number;
    captured.has_year = item.has_year;
    captured.has_recording_length_ms = item.has_recording_length_ms;
    captured.size_bytes = item.size_bytes;
}

const nick_drake_answers = [_]std.meta.Elem(@FieldType(provider_tests.FakeMusicBrainz, "answers")){
    .{ .title = "Northern%20Sky", .body = provider_tests.northern_sky_answer },
    .{ .title = "Pink%20Moon", .body = provider_tests.pink_moon_answer },
};

test "a match started through the C ABI stores proposals that review lists, accept applies and dismiss discards" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-match-review?mode=memory&cache=shared", null);
    defer rig.deinit();
    rig.musicbrainz.answers = &nick_drake_answers;
    const northern_sky = try provider_tests.addMatchTrack(rig.library_database, "Northern Sky", "Nick Drake", null);
    const pink_moon = try provider_tests.addMatchTrack(rig.library_database, "Pink Moon", "Nick Drake", null);
    var count: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_unidentified_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 2), count);

    var matching: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, null, &matching));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(matching));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(rig.runtime, matching, &snapshot));
    try std.testing.expectEqual(exportJobKind(.metadata_lookup), snapshot.kind);
    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, matching, &stats));
    try std.testing.expectEqual(@as(u64, 2), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 2), stats.matched);
    try std.testing.expectEqual(@as(u64, 2), stats.proposals_stored);
    try std.testing.expect(stats.requests >= 2);
    try std.testing.expectEqual(exportAcoustIdUse(.no_client_key), stats.acoustid);
    try std.testing.expectEqual(exportCoverArtOutcome(.not_requested), stats.cover_art);
    try std.testing.expectEqual(@as(u8, 0), stats.cancelled);
    var stats_v2: MatchStatsViewV2 = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats_v2(rig.runtime, matching, &stats_v2));
    try std.testing.expectEqual(stats, stats_v2.base);
    try std.testing.expectEqual(@as(u64, 0), stats_v2.releases_to_review);
    try std.testing.expectEqual(Status.ok, orca_library_unidentified_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);

    try std.testing.expectEqual(Status.ok, orca_library_match_review_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 2), count);
    var review: CapturedReview = .{};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_match_review(rig.runtime, rig.library, 0, 0, &review, captureReview));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_match_review(rig.runtime, rig.library, 513, 0, &review, captureReview));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_match_review(rig.runtime, rig.library, 10, 0, null, null));
    try std.testing.expectEqual(Status.ok, orca_library_query_match_review(rig.runtime, rig.library, 10, 0, &review, captureReview));
    try std.testing.expectEqual(@as(usize, 2), review.count);
    for (review.track_ids, review.titles, review.best_recordings, review.proposal_counts) |track_id, title, best, proposal_count| {
        try std.testing.expectEqual(@as(u32, 1), proposal_count);
        if (track_id == northern_sky) {
            try std.testing.expectEqualStrings("Northern Sky", title.text());
            try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, best.text());
        } else {
            try std.testing.expectEqual(pink_moon, track_id);
            try std.testing.expectEqualStrings(provider_tests.pink_moon_mbid, best.text());
        }
    }

    var proposal: CapturedProposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, northern_sky, &proposal, captureProposal));
    try std.testing.expectEqual(@as(usize, 1), proposal.count);
    try std.testing.expectEqualStrings("musicbrainz", proposal.provider.text());
    try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, proposal.recording_mbid.text());
    try std.testing.expectEqualStrings("Bryter Layter", proposal.release_title.text());
    try std.testing.expectEqual(@as(u8, 1), proposal.has_release_mbid);
    try std.testing.expectEqual(@as(u8, 0), proposal.has_corrects);

    var acceptance: MatchAcceptanceView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_accept_match(rig.runtime, rig.library, proposal.id, null));
    try std.testing.expectEqual(Status.ok, orca_library_accept_match(rig.runtime, rig.library, proposal.id, &acceptance));
    try std.testing.expect(acceptance.values_written > 0);
    try std.testing.expectEqual(Status.invalid_state, orca_library_accept_match(rig.runtime, rig.library, proposal.id, &acceptance));
    try std.testing.expectEqualStrings("orca_library_accept_match: StaleIdentificationProposal", rig.lastError());
    try std.testing.expectEqual(Status.not_found, orca_library_accept_match(rig.runtime, rig.library, 1_000_000, &acceptance));
    try std.testing.expectEqualStrings("orca_library_accept_match: UnknownIdentificationProposal", rig.lastError());
    var recording: CapturedRecording = .{};
    const accepted_track = try provider_tests.trackOfFile(rig.library_database, acceptance.file_id);
    try std.testing.expectEqual(Status.ok, orca_library_track_details(rig.runtime, rig.library, accepted_track, &recording, captureRecording));
    try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, recording.recording_mbid.text());
    try std.testing.expectEqual(@backingInt(IdSource.match), recording.source);

    proposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, pink_moon, &proposal, captureProposal));
    try std.testing.expectEqual(@as(usize, 1), proposal.count);
    try std.testing.expectEqual(Status.ok, orca_library_dismiss_match(rig.runtime, rig.library, proposal.id));
    try std.testing.expectEqual(Status.invalid_state, orca_library_dismiss_match(rig.runtime, rig.library, proposal.id));
    try std.testing.expectEqual(Status.not_found, orca_library_dismiss_match(rig.runtime, rig.library, 1_000_000));
    try std.testing.expectEqual(Status.ok, orca_library_match_review_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    proposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, pink_moon, &proposal, captureProposal));
    try std.testing.expectEqual(@as(usize, 0), proposal.count);

    var verification: CapturedVerification = .{};
    try std.testing.expectEqual(Status.not_found, orca_library_track_verification(rig.runtime, rig.library, pink_moon, &verification, captureVerification));
    try std.testing.expectEqual(@as(usize, 0), verification.count);
}

test "a scoped match through the C ABI follows its options, and confident acceptance and apply-release take what it found" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-match-confident?mode=memory&cache=shared", null);
    defer rig.deinit();
    rig.musicbrainz.answers = &nick_drake_answers;
    const northern_sky = try provider_tests.addMatchTrack(rig.library_database, "Northern Sky", "Nick Drake", null);
    _ = try provider_tests.addMatchTrack(rig.library_database, "Pink Moon", "Nick Drake", null);

    const options: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = northern_sky,
        .release_id = 0,
        .accept_minimum_confidence = 0,
        .mode = 0,
        .has_limit = 0,
        .has_track_id = 1,
        .has_release_id = 0,
        .skip_fingerprints = 1,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };
    var matching: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(matching));
    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, matching, &stats));
    try std.testing.expectEqual(@as(u64, 1), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), stats.proposals_stored);
    try std.testing.expectEqual(exportAcoustIdUse(.off), stats.acoustid);

    var count: u64 = 0;
    for ([_]f32{ 0, -0.5, 1.5, std.math.nan(f32) }) |invalid| {
        try std.testing.expectEqual(Status.invalid_argument, orca_library_confident_match_count(rig.runtime, rig.library, invalid, &count));
        try std.testing.expectEqualStrings("orca_library_confident_match_count: InvalidMinimumConfidence", rig.lastError());
    }
    var acceptance: ConfidentAcceptanceView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_accept_confident_matches(rig.runtime, rig.library, 2, &acceptance));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_accept_confident_matches(rig.runtime, rig.library, 0.5, null));
    try std.testing.expectEqual(Status.ok, orca_library_confident_match_count(rig.runtime, rig.library, 0.01, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
    try std.testing.expectEqual(Status.ok, orca_library_accept_confident_matches(rig.runtime, rig.library, 0.01, &acceptance));
    try std.testing.expectEqual(@as(u64, 1), acceptance.accepted);
    try std.testing.expect(acceptance.values_written > 0);
    try std.testing.expectEqual(Status.ok, orca_library_confident_match_count(rig.runtime, rig.library, 0.01, &count));
    try std.testing.expectEqual(@as(u64, 0), count);

    const release = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    var values_written: u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(Status.ok, orca_library_apply_matched_release(rig.runtime, rig.library, release, &values_written));
    try std.testing.expectEqual(@as(u32, 0), values_written);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_apply_matched_release(rig.runtime, rig.library, release, null));
    try std.testing.expectEqual(Status.not_found, orca_library_apply_matched_release(rig.runtime, rig.library, 1_000_000, &values_written));
    try std.testing.expectEqualStrings("orca_library_apply_matched_release: UnknownRelease", rig.lastError());
}

test "a match through the C ABI refuses bad options and a second job, a job that is not a match has empty match stats, and only a finished Match Album names its Release" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-match-refusals?mode=memory&cache=shared", null);
    defer rig.deinit();
    rig.musicbrainz.hang_from = 0;
    _ = try provider_tests.addMatchTrack(rig.library_database, "Northern Sky", "Nick Drake", null);
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    var matching: Handle = undefined;
    const zero: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = 0,
        .release_id = 0,
        .accept_minimum_confidence = 0,
        .mode = 0,
        .has_limit = 0,
        .has_track_id = 0,
        .has_release_id = 0,
        .skip_fingerprints = 0,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };

    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, null, null));
    var options = zero;
    options.mode = 3;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    options = zero;
    options.has_track_id = 1;
    options.has_release_id = 1;
    options.release_id = album;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: InvalidMatchRequest", rig.lastError());
    options = zero;
    options.mode = 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    options = zero;
    options.cover_art = 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    options = zero;
    options.has_release_id = 1;
    options.release_id = album;
    options.has_accept_minimum_confidence = 1;
    options.accept_minimum_confidence = 1.5;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: InvalidMinimumConfidence", rig.lastError());
    options = zero;
    options.mode = 2;
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: AcoustIdRequired", rig.lastError());
    options = zero;
    options.has_release_id = 1;
    options.release_id = 1_000_000;
    try std.testing.expectEqual(Status.not_found, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: UnknownRelease", rig.lastError());
    try std.testing.expectEqual(Status.not_found, orca_library_start_cover_art_fetch(rig.runtime, rig.library, 1_000_000, &matching));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_cover_art_fetch(rig.runtime, rig.library, album, null));

    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.stale_handle, orca_job_match_stats(rig.runtime, .{ .index = 7, .generation = 3 }, &stats));
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, null, &matching));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_match_stats(rig.runtime, matching, null));
    var second: Handle = undefined;
    try std.testing.expectEqual(Status.busy, orca_library_start_match(rig.runtime, rig.library, null, &second));
    try std.testing.expectEqualStrings("orca_library_start_match: MatchingAlreadyRunning", rig.lastError());
    try std.testing.expectEqual(Status.busy, orca_library_start_cover_art_fetch(rig.runtime, rig.library, album, &second));
    try std.testing.expectEqual(Status.ok, orca_job_cancel(rig.runtime, matching));
    try std.testing.expectEqual(job.State.cancelled, try rig.finish(matching));
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, matching, &stats));
    try std.testing.expectEqual(@as(u8, 1), stats.cancelled);

    var scan: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_projection(rig.runtime, rig.library, &scan));
    _ = try rig.finish(scan);
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, scan, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.tracks_examined);
    try std.testing.expectEqual(exportAcoustIdUse(.off), stats.acoustid);

    var release_id: i64 = -1;
    var has_release_id: u8 = 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_job_match_release(rig.runtime, matching, null, &has_release_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_match_release(rig.runtime, matching, &release_id, null));
    try std.testing.expectEqual(Status.stale_handle, orca_job_match_release(rig.runtime, .{ .index = 7, .generation = 3 }, &release_id, &has_release_id));
    try std.testing.expectEqual(Status.ok, orca_job_match_release(rig.runtime, matching, &release_id, &has_release_id));
    try std.testing.expectEqual(@as(u8, 0), has_release_id);
    try std.testing.expectEqual(@as(i64, 0), release_id);
    try std.testing.expectEqual(Status.ok, orca_job_match_release(rig.runtime, scan, &release_id, &has_release_id));
    try std.testing.expectEqual(@as(u8, 0), has_release_id);
    rig.musicbrainz.hang_from = null;
    _ = try provider_tests.addAlbumTrack(rig.library_database, album, "Pink Moon");
    options = zero;
    options.has_release_id = 1;
    options.release_id = album;
    var album_match: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &album_match));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(album_match));
    try std.testing.expectEqual(Status.ok, orca_job_match_release(rig.runtime, album_match, &release_id, &has_release_id));
    try std.testing.expectEqual(@as(u8, 1), has_release_id);
    try std.testing.expectEqual(album, release_id);

    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var anonymous: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-match-anonymous?mode=memory&cache=shared", &anonymous));
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_match(runtime, anonymous, null, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: ClientIdentityRequired", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_cover_art_fetch(runtime, anonymous, 1, &matching));
}

test "a verification through the C ABI forms an album group of corrections that is listed with its members and accepted only whole" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-verify-accept?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    const sounds_northern = try rig.addTone("northern.wav", 300, "Pink Moon", provider_tests.pink_moon_mbid, album);
    _ = try rig.addTone("pink.wav", 420, "Northern Sky", provider_tests.northern_sky_mbid, album);
    rig.acoustid.lookup_body = provider_tests.acoustIdAnswer(
        provider_tests.heardBy("0", provider_tests.heardResult("0.97", provider_tests.northern_sky_heard)) ++ "," ++
            provider_tests.heardBy("1", provider_tests.heardResult("0.96", provider_tests.pink_moon_heard)),
    );

    var verification: CapturedVerification = .{};
    try std.testing.expectEqual(Status.not_found, orca_library_track_verification(rig.runtime, rig.library, sounds_northern, &verification, captureVerification));
    var options: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = 0,
        .release_id = album,
        .accept_minimum_confidence = 0,
        .mode = 2,
        .has_limit = 0,
        .has_track_id = 0,
        .has_release_id = 1,
        .skip_fingerprints = 0,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };
    var verifying: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &verifying));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(verifying));
    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, verifying, &stats));
    try std.testing.expectEqual(@as(u64, 2), stats.verified);
    try std.testing.expectEqual(@as(u64, 2), stats.disagreed);
    try std.testing.expectEqual(@as(u64, 1), stats.correction_groups);
    try std.testing.expectEqual(exportAcoustIdUse(.searched), stats.acoustid);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_verification(rig.runtime, rig.library, sounds_northern, null, null));
    try std.testing.expectEqual(Status.ok, orca_library_track_verification(rig.runtime, rig.library, sounds_northern, &verification, captureVerification));
    try std.testing.expectEqual(@as(usize, 1), verification.count);
    try std.testing.expectEqual(exportVerificationOutcome(.disagrees), verification.outcome);
    try std.testing.expectEqualStrings(provider_tests.pink_moon_mbid, verification.recording_mbid.text());
    try std.testing.expectEqual(@as(usize, 1), verification.heard_count);
    try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, verification.strongest.text());
    try std.testing.expectApproxEqAbs(@as(f32, 0.97), verification.strongest_score, 0.001);
    try std.testing.expectEqual(@as(u8, 0), verification.stale);

    var group: CapturedGroup = .{};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_correction_groups(rig.runtime, rig.library, 0, 0, &group, captureGroup));
    try std.testing.expectEqual(Status.ok, orca_library_query_correction_groups(rig.runtime, rig.library, 10, 0, &group, captureGroup));
    try std.testing.expectEqual(@as(usize, 1), group.count);
    try std.testing.expectEqual(@as(usize, 2), group.member_count);
    try std.testing.expectEqual(@as(usize, 2), group.members_with_corrects);
    try std.testing.expectEqual(@as(usize, 2), group.members_with_track);
    try std.testing.expectEqual(@as(u8, 1), group.has_release_id);
    try std.testing.expectEqual(album, group.release_id);
    try std.testing.expectEqualStrings("Bryter Layter", group.album.text());
    var proposal: CapturedProposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, sounds_northern, &proposal, captureProposal));
    try std.testing.expectEqual(@as(u8, 1), proposal.has_corrects);

    var single: MatchAcceptanceView = undefined;
    try std.testing.expectEqual(Status.invalid_state, orca_library_accept_match(rig.runtime, rig.library, group.first_proposal_id, &single));
    try std.testing.expectEqualStrings("orca_library_accept_match: ProposalInGroup", rig.lastError());
    var acceptance: ConfidentAcceptanceView = undefined;
    try std.testing.expectEqual(Status.not_found, orca_library_accept_correction_group(rig.runtime, rig.library, 1_000_000, &acceptance));
    try std.testing.expectEqualStrings("orca_library_accept_correction_group: UnknownCorrectionGroup", rig.lastError());
    try std.testing.expectEqual(Status.invalid_argument, orca_library_accept_correction_group(rig.runtime, rig.library, group.group_id, null));
    try std.testing.expectEqual(Status.ok, orca_library_accept_correction_group(rig.runtime, rig.library, group.group_id, &acceptance));
    try std.testing.expectEqual(@as(u64, 2), acceptance.accepted);
    try std.testing.expect(acceptance.values_written > 0);
    try std.testing.expectEqual(Status.invalid_state, orca_library_accept_correction_group(rig.runtime, rig.library, group.group_id, &acceptance));
    try std.testing.expectEqualStrings("orca_library_accept_correction_group: StaleCorrectionGroup", rig.lastError());
    try std.testing.expectEqual(Status.invalid_state, orca_library_dismiss_correction_group(rig.runtime, rig.library, group.group_id));
    group = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_correction_groups(rig.runtime, rig.library, 10, 0, &group, captureGroup));
    try std.testing.expectEqual(@as(usize, 0), group.count);

    options.has_release_id = 0;
    options.has_accept_minimum_confidence = 1;
    options.accept_minimum_confidence = 0.9;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &verifying));
}

test "an album group of corrections dismissed through the C ABI leaves every member's recording ID as it was" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-verify-dismiss?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    const sounds_northern = try rig.addTone("northern.wav", 300, "Pink Moon", provider_tests.pink_moon_mbid, album);
    _ = try rig.addTone("pink.wav", 420, "Northern Sky", provider_tests.northern_sky_mbid, album);
    rig.acoustid.lookup_body = provider_tests.acoustIdAnswer(
        provider_tests.heardBy("0", provider_tests.heardResult("0.97", provider_tests.northern_sky_heard)) ++ "," ++
            provider_tests.heardBy("1", provider_tests.heardResult("0.96", provider_tests.pink_moon_heard)),
    );
    const options: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = 0,
        .release_id = album,
        .accept_minimum_confidence = 0,
        .mode = 2,
        .has_limit = 0,
        .has_track_id = 0,
        .has_release_id = 1,
        .skip_fingerprints = 0,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };
    var verifying: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &verifying));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(verifying));
    var group: CapturedGroup = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_correction_groups(rig.runtime, rig.library, 10, 0, &group, captureGroup));
    try std.testing.expectEqual(@as(usize, 1), group.count);

    try std.testing.expectEqual(Status.not_found, orca_library_dismiss_correction_group(rig.runtime, rig.library, 1_000_000));
    try std.testing.expectEqual(Status.invalid_state, orca_library_dismiss_match(rig.runtime, rig.library, group.first_proposal_id));
    try std.testing.expectEqual(Status.ok, orca_library_dismiss_correction_group(rig.runtime, rig.library, group.group_id));
    try std.testing.expectEqual(Status.invalid_state, orca_library_dismiss_correction_group(rig.runtime, rig.library, group.group_id));
    group = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_correction_groups(rig.runtime, rig.library, 10, 0, &group, captureGroup));
    try std.testing.expectEqual(@as(usize, 0), group.count);
    var recording: CapturedRecording = .{};
    try std.testing.expectEqual(Status.ok, orca_library_track_details(rig.runtime, rig.library, sounds_northern, &recording, captureRecording));
    try std.testing.expectEqualStrings(provider_tests.pink_moon_mbid, recording.recording_mbid.text());
    try std.testing.expectEqual(@backingInt(IdSource.tag), recording.source);
}

test "a cover fetched through the C ABI is a metadata lookup whose stats say fetched, and the Release's artwork then returns it" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-cover-fetch?mode=memory&cache=shared", null);
    defer rig.deinit();
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    _ = try provider_tests.addAlbumTrack(rig.library_database, album, "Northern Sky");
    var image: CapturedImage = .{};
    try std.testing.expectEqual(Status.not_found, orca_library_release_artwork(rig.runtime, rig.library, album, &image, captureImage));

    var fetching: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_cover_art_fetch(rig.runtime, rig.library, album, &fetching));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(rig.runtime, fetching, &snapshot));
    try std.testing.expectEqual(exportJobKind(.metadata_lookup), snapshot.kind);
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(fetching));
    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, fetching, &stats));
    try std.testing.expectEqual(exportCoverArtOutcome(.fetched), stats.cover_art);
    try std.testing.expectEqual(@as(u64, 0), stats.requests);
    try std.testing.expectEqual(@as(u32, 1), rig.cover.requestCount());

    try std.testing.expectEqual(Status.ok, orca_library_release_artwork(rig.runtime, rig.library, album, &image, captureImage));
    try std.testing.expectEqual(@as(usize, 1), image.count);
    try std.testing.expectEqualStrings(provider_tests.jpeg_cover, image.bytes[0..image.length]);
}

test "a submission started through the C ABI sends an accepted recording ID once, and fails without a user key leaving it unsent" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-submission?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    rig.musicbrainz.answers = &nick_drake_answers;
    rig.acoustid.submit_body = "{\"status\":\"ok\",\"submissions\":[{\"id\":71,\"status\":\"pending\",\"index\":\"0\"}]}";
    var keyring: FakeKeyring = .{ .result = @backingInt(CredentialResult.not_found), .secret = "userkey" };
    try std.testing.expectEqual(Status.ok, orca_runtime_set_credential_callback(rig.runtime, FakeKeyring.lookup, &keyring));
    const northern_sky = try rig.addUntaggedTone("northern.wav", 440, "Northern Sky");

    var count: u64 = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_acoustid_submittable_count(rig.runtime, rig.library, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_acoustid_submittable_count(rig.runtime, .{ .index = 7, .generation = 3 }, &count));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    count = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_acoustid_submitted_count(rig.runtime, rig.library, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_acoustid_submitted_count(rig.runtime, .{ .index = 7, .generation = 3 }, &count));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submitted_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);

    var matching: Handle = undefined;
    const options: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = 0,
        .release_id = 0,
        .accept_minimum_confidence = 0,
        .mode = 0,
        .has_limit = 0,
        .has_track_id = 0,
        .has_release_id = 0,
        .skip_fingerprints = 1,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(matching));
    var proposal: CapturedProposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, northern_sky, &proposal, captureProposal));
    try std.testing.expectEqual(@as(usize, 1), proposal.count);
    var acceptance: MatchAcceptanceView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_accept_match(rig.runtime, rig.library, proposal.id, &acceptance));

    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
    var submittable: CapturedSubmittable = .{};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 0, &submittable, captureSubmittable));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 513, &submittable, captureSubmittable));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 10, &submittable, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_query_acoustid_submittable(rig.runtime, .{ .index = 7, .generation = 3 }, 0, 10, &submittable, captureSubmittable));
    try std.testing.expectEqual(Status.ok, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 10, &submittable, captureSubmittable));
    try std.testing.expectEqual(@as(usize, 1), submittable.count);
    try std.testing.expectEqual(acceptance.file_id, submittable.last_file_id);
    try std.testing.expectEqual(try provider_tests.trackOfFile(rig.library_database, acceptance.file_id), submittable.track_id);
    try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, submittable.recording_mbid.text());
    try std.testing.expectEqualStrings("Northern Sky", submittable.title.text());
    try std.testing.expectEqualStrings("Nick Drake", submittable.artist.text());
    try std.testing.expectEqual(@as(u8, 1), submittable.has_path);
    try std.testing.expect(std.mem.endsWith(u8, submittable.path.text(), "northern.wav"));
    try std.testing.expectEqual(@as(u8, 0), submittable.has_duration_ms);
    try std.testing.expectEqual(@as(i64, 0), submittable.duration_ms);
    try std.testing.expectEqual(@as(u8, 1), submittable.has_track_number);
    try std.testing.expectEqual(@as(u8, 1), submittable.has_recording_length_ms);
    try std.testing.expect(submittable.size_bytes > 0);
    submittable = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_acoustid_submittable(rig.runtime, rig.library, acceptance.file_id, 10, &submittable, captureSubmittable));
    try std.testing.expectEqual(@as(usize, 0), submittable.count);

    var submitting: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_acoustid_submission(rig.runtime, rig.library, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_start_acoustid_submission(rig.runtime, .{ .index = 7, .generation = 3 }, &submitting));
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(rig.runtime, submitting, &snapshot));
    try std.testing.expectEqual(exportJobKind(.acoustid_submission), snapshot.kind);
    try std.testing.expectEqual(job.State.failed, try rig.finish(submitting));
    var stats: SubmissionStatsView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_job_submission_stats(rig.runtime, submitting, null));
    try std.testing.expectEqual(Status.stale_handle, orca_job_submission_stats(rig.runtime, .{ .index = 7, .generation = 3 }, &stats));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.needs_user_key), stats.outcome);
    try std.testing.expectEqual(@as(u64, 0), stats.submitted);
    try std.testing.expectEqual(@as(u32, 0), rig.acoustid.submissions.load(.acquire));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);

    keyring.result = @backingInt(CredentialResult.unavailable);
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqual(job.State.failed, try rig.finish(submitting));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.credential_unavailable), stats.outcome);
    try std.testing.expectEqual(@as(u8, 8), stats.outcome);
    try std.testing.expectEqual(@as(u32, 0), rig.acoustid.submissions.load(.acquire));

    keyring.result = @backingInt(CredentialResult.too_large);
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqual(job.State.failed, try rig.finish(submitting));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.credential_unavailable), stats.outcome);
    try std.testing.expectEqual(@as(u32, 0), rig.acoustid.submissions.load(.acquire));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);

    keyring.result = @backingInt(CredentialResult.found);
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(submitting));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.completed), stats.outcome);
    try std.testing.expectEqual(@as(u64, 1), stats.files_examined);
    try std.testing.expectEqual(@as(u64, 1), stats.submitted);
    try std.testing.expectEqual(@as(u64, 1), stats.fingerprinted);
    try std.testing.expectEqual(@as(u64, 0), stats.rejected);
    try std.testing.expectEqual(@as(u64, 1), stats.requests);
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.submissions.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, rig.acoustid.lastForm(), "&user=userkey&") != null);
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submitted_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
    submittable = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 10, &submittable, captureSubmittable));
    try std.testing.expectEqual(@as(usize, 0), submittable.count);
}

test "a submission refuses to start beside a running match or without a client identity, and its stats are zero for another job" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-submission-busy?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    rig.musicbrainz.hang_from = 0;
    rig.musicbrainz.answers = &nick_drake_answers;
    _ = try rig.addUntaggedTone("northern.wav", 440, "Northern Sky");

    var matching: Handle = undefined;
    var options = std.mem.zeroes(MatchOptions);
    options.skip_fingerprints = 1;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    var submitting: Handle = undefined;
    try std.testing.expectEqual(Status.busy, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqualStrings("orca_library_start_acoustid_submission: AcoustIdBusy", rig.lastError());
    var stats: SubmissionStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, matching, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.files_examined);
    try std.testing.expectEqual(exportSubmissionOutcome(.completed), stats.outcome);
    try std.testing.expectEqual(Status.ok, orca_job_cancel(rig.runtime, matching));
    _ = try rig.finish(matching);

    const unnamed = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(unnamed);
    var unnamed_library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(unnamed, "file:orca-c-api-submission-unnamed?mode=memory&cache=shared", &unnamed_library));
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_acoustid_submission(unnamed, unnamed_library, &submitting));
    try std.testing.expectEqualStrings("orca_library_start_acoustid_submission: ClientIdentityRequired", std.mem.span(orca_runtime_last_error(unnamed)));
}

const CapturedScrobblerStatus = struct {
    calls: usize = 0,
    view: ScrobblerStatusView = std.mem.zeroes(ScrobblerStatusView),
    user_name: CapturedText = .{},
    last_error: CapturedText = .{},
};

fn captureScrobblerStatus(context: ?*anyopaque, status: *const ScrobblerStatusView) callconv(.c) void {
    const captured: *CapturedScrobblerStatus = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.view = status.*;
    captured.user_name.set(status.user_name);
    captured.last_error.set(status.last_error);
}

const ScrobbleRig = struct {
    transport: network.testing.ScriptedTransport = .{
        .otherwise = .{ .respond = .{ .body = "{\"valid\":true,\"user_name\":\"listener\"}" } },
    },
    clock: network.testing.TestClock = .{ .wall_offset_ms = 1_800_000_000_000 },
    sample_clock: network.testing.TestClock = .{ .wall_offset_ms = 1_700_000_000_000 },
    keyring: FakeKeyring = .{},
    runtime: *Runtime,
    library: Handle = undefined,
    track_id: i64 = 0,

    fn init(self: *ScrobbleRig, uri: [*:0]const u8) !void {
        const runtime = orca_runtime_create() orelse return error.OutOfMemory;
        self.* = .{ .runtime = runtime };
        errdefer self.deinit();
        const box = runtimeBox(runtime).?;
        try std.testing.expectEqual(Status.ok, orca_runtime_set_credential_callback(runtime, FakeKeyring.lookup, &self.keyring));
        try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Host", "1.0", "https://host.invalid"));
        try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 0, "http://127.0.0.1:8080"));
        box.runtime.listen_hooks = .{
            .transport = self.transport.transport(),
            .clock = self.clock.clock(),
            .wall_clock = self.clock.wallClock(),
            .sample_clock = provider_tests.sampleClock(&self.sample_clock),
            .poll_ms = 5,
        };
        try std.testing.expectEqual(Status.ok, orca_library_open(runtime, uri, &self.library));
        const library_database = try core.runtime.libraryDatabase(&box.runtime, importLibrary(self.library));
        self.track_id = try provider_tests.addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    }

    fn deinit(self: *ScrobbleRig) void {
        orca_runtime_destroy(self.runtime);
        self.transport.deinit();
    }

    fn status(self: *ScrobbleRig) !CapturedScrobblerStatus {
        var captured: CapturedScrobblerStatus = .{};
        try std.testing.expectEqual(Status.ok, orca_library_scrobbler_status(self.runtime, self.library, &captured, captureScrobblerStatus));
        try std.testing.expectEqual(@as(usize, 1), captured.calls);
        return captured;
    }

    fn hearListen(self: *ScrobbleRig) !void {
        const box = runtimeBox(self.runtime).?;
        var player: Handle = undefined;
        try std.testing.expectEqual(Status.ok, orca_player_create(self.runtime, &player));
        try std.testing.expectEqual(Status.ok, orca_player_set_library(self.runtime, player, self.library));
        const object_value = try box.runtime.players.get(importPlayer(player));
        try object_value.queue.replace(&.{.{ .library = importLibrary(self.library), .track_id = self.track_id }}, 0);
        object_value.queue.noteEntrySerial(7, 0);
        object_value.player.published_sample_rate.store(1000, .release);
        object_value.player.published_frame_count.store(180_000, .release);
        object_value.player.audible_entry_serial.store(7, .release);
        object_value.player.position_frames.store(0, .release);
        object_value.player.state.store(.playing, .release);
        var elapsed: u64 = 0;
        while (elapsed < 100_000) : (elapsed += 100) {
            self.sample_clock.advance(100);
            _ = object_value.player.position_frames.fetchAdd(100, .acq_rel);
            _ = box.runtime.processNextCommand();
        }
        var deadline: core.runtime_tests.TestDeadline = .init(5_000);
        while ((try self.status()).view.recorded_total < 1) {
            if (!deadline.tick()) return error.ListenNotRecorded;
        }
    }

    fn awaitStatus(self: *ScrobbleRig, comptime reached: fn (*const CapturedScrobblerStatus) bool) !CapturedScrobblerStatus {
        var deadline: core.runtime_tests.TestDeadline = .init(5_000);
        while (true) {
            const captured = try self.status();
            if (reached(&captured)) return captured;
            if (!deadline.tick()) return error.ScrobblerNeverReachedState;
        }
    }

    fn lastError(self: *ScrobbleRig) []const u8 {
        return std.mem.span(orca_runtime_last_error(self.runtime));
    }
};

fn deliveredWithUser(captured: *const CapturedScrobblerStatus) bool {
    return captured.view.delivered_total == 1 and std.mem.eql(u8, captured.user_name.text(), "listener");
}

fn heldOffline(captured: *const CapturedScrobblerStatus) bool {
    return captured.view.pending == 1 and captured.view.state == exportScrobblerState(.offline);
}

fn deliveredOnce(captured: *const CapturedScrobblerStatus) bool {
    return captured.view.delivered_total == 1 and captured.view.pending == 0;
}

test "scrobbling turned on through the C ABI validates the host's token and delivers a heard listen to ListenBrainz" {
    var rig: ScrobbleRig = undefined;
    try rig.init("file:orca-c-api-scrobbled?mode=memory&cache=shared");
    defer rig.deinit();

    var before = try rig.status();
    try std.testing.expectEqual(@as(u8, 0), before.view.enabled);
    try std.testing.expectEqual(exportScrobblerState(.disabled), before.view.state);

    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 0, 0));
    try std.testing.expectEqual(Status.ok, orca_library_scrobbler_credentials_changed(rig.runtime, rig.library));
    try rig.hearListen();

    const delivered = try rig.awaitStatus(deliveredWithUser);
    try std.testing.expectEqual(@as(u8, 1), delivered.view.enabled);
    try std.testing.expectEqual(@as(u64, 0), delivered.view.pending);
    try std.testing.expectEqual(@as(u64, 1), delivered.view.recorded_total);
    try std.testing.expectEqual(@as(u64, 0), delivered.view.dropped);
    try std.testing.expectEqual(@as(u8, 0), delivered.view.has_blocked_until);
    try std.testing.expectEqualStrings("", delivered.last_error.text());
    try std.testing.expectEqualStrings("Token host-secret", rig.transport.lastAuthorization());
    try std.testing.expect(std.mem.endsWith(u8, rig.transport.lastUrl(), "/1/submit-listens"));
    try std.testing.expectEqualStrings("org.listenbrainz", rig.keyring.serviceName());
    try std.testing.expectEqualStrings("user-token", rig.keyring.accountName());

    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 0, 0, 0));
    before = try rig.status();
    try std.testing.expectEqual(@as(u8, 0), before.view.enabled);
    try std.testing.expectEqual(exportScrobblerState(.disabled), before.view.state);
    try std.testing.expectEqual(@as(u64, 1), before.view.delivered_total);
}

test "offline scrobbling keeps a heard listen pending without any request, and going online sends it" {
    var rig: ScrobbleRig = undefined;
    try rig.init("file:orca-c-api-scrobbled-offline?mode=memory&cache=shared");
    defer rig.deinit();

    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 1, 1));
    try std.testing.expectEqual(Status.ok, orca_library_scrobbler_credentials_changed(rig.runtime, rig.library));
    try rig.hearListen();

    const held = try rig.awaitStatus(heldOffline);
    try std.testing.expectEqual(@as(u8, 1), held.view.enabled);
    try std.testing.expectEqual(@as(u64, 0), held.view.delivered_total);
    try std.testing.expectEqualStrings("", held.user_name.text());
    try std.testing.expectEqual(@as(u32, 0), rig.transport.requestCount());

    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 0, 0));
    _ = try rig.awaitStatus(deliveredOnce);
    try std.testing.expect(rig.transport.requestCount() >= 1);
}

test "scrobbling refuses flags other than 0 or 1, a host that has not named itself, a second Library and a null callback" {
    var rig: ScrobbleRig = undefined;
    try rig.init("file:orca-c-api-scrobble-refusals?mode=memory&cache=shared");
    defer rig.deinit();

    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_scrobbling(rig.runtime, rig.library, 2, 0, 0));
    try std.testing.expectEqualStrings("orca_library_set_scrobbling: enabled must be 0 or 1", rig.lastError());
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 2, 0));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 0, 255));
    try std.testing.expectEqual(@as(u8, 0), (try rig.status()).view.enabled);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_scrobbler_status(rig.runtime, rig.library, null, null));

    var second: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(rig.runtime, "file:orca-c-api-scrobble-second?mode=memory&cache=shared", &second));
    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 1, 0));
    try std.testing.expectEqual(Status.invalid_state, orca_library_set_scrobbling(rig.runtime, second, 1, 1, 0));
    try std.testing.expectEqualStrings("orca_library_set_scrobbling: ScrobblingEnabledElsewhere", rig.lastError());
    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, second, 0, 0, 0));
    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 0, 0, 0));
    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, second, 1, 1, 0));

    const stale: Handle = .{ .index = rig.library.index, .generation = rig.library.generation + 1 };
    try std.testing.expectEqual(Status.stale_handle, orca_library_set_scrobbling(rig.runtime, stale, 1, 0, 0));
    var captured: CapturedScrobblerStatus = .{};
    try std.testing.expectEqual(Status.stale_handle, orca_library_scrobbler_status(rig.runtime, stale, &captured, captureScrobblerStatus));
    try std.testing.expectEqual(@as(usize, 0), captured.calls);
    try std.testing.expectEqual(@as(u32, 0), rig.transport.requestCount());

    const unnamed = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(unnamed);
    var unnamed_library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(unnamed, "file:orca-c-api-scrobble-unnamed?mode=memory&cache=shared", &unnamed_library));
    try std.testing.expectEqual(Status.invalid_state, orca_library_set_scrobbling(unnamed, unnamed_library, 1, 1, 0));
    try std.testing.expectEqualStrings("orca_library_set_scrobbling: ClientIdentityRequired", std.mem.span(orca_runtime_last_error(unnamed)));
}

fn maintenanceStatus(runtime: *Runtime, library: Handle) !MaintenanceStatus {
    var status: MaintenanceStatus = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_maintenance_status(runtime, library, &status));
    return status;
}

test "a maintenance unit enabled through the C ABI is a metadata lookup of origin maintenance whose stats the status reports as its last unit" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-maintenance?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", null);
    _ = try rig.addTone("northern.wav", 300, "Northern Sky", provider_tests.northern_sky_mbid, album);
    rig.acoustid.lookup_body = provider_tests.acoustIdAnswer(
        provider_tests.heardBy("0", provider_tests.heardResult("0.95", provider_tests.northern_sky_heard)),
    );

    const off = try maintenanceStatus(rig.runtime, rig.library);
    try std.testing.expectEqual(@as(u8, 0), off.enabled);
    try std.testing.expectEqual(exportMaintenanceState(.off), off.state);
    try std.testing.expectEqual(@as(u8, 0), off.has_last);
    try std.testing.expectEqual(@as(u8, 0), off.has_next_due_ms);

    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(rig.runtime, rig.library, &.{ .interval_ms = 0, .enabled = 1 }));
    const due = try maintenanceStatus(rig.runtime, rig.library);
    try std.testing.expectEqual(exportMaintenanceState(.waiting), due.state);
    try std.testing.expectEqual(@as(u8, 1), due.has_next_due_ms);
    try std.testing.expectEqual(@as(u64, 0), due.next_due_ms);

    try std.testing.expectEqual(Status.ok, orca_runtime_pump(rig.runtime));
    try std.testing.expectEqual(exportMaintenanceState(.running), (try maintenanceStatus(rig.runtime, rig.library)).state);
    const running = core.runtime_jobs.maintenanceUnitRunning(&runtimeBox(rig.runtime).?.runtime) orelse return error.UnitNotRunning;
    const unit = exportJobHandle(running.job);
    var origin: u8 = 255;
    try std.testing.expectEqual(Status.ok, orca_job_origin_get(rig.runtime, unit, &origin));
    try std.testing.expectEqual(exportJobOrigin(.maintenance), origin);
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(rig.runtime, unit, &snapshot));
    try std.testing.expectEqual(exportJobKind(.metadata_lookup), snapshot.kind);
    var root_id: i64 = -1;
    var has_root_id: u8 = 1;
    try std.testing.expectEqual(Status.ok, orca_job_reconcile_root(rig.runtime, unit, &root_id, &has_root_id));
    try std.testing.expectEqual(@as(i64, 0), root_id);
    try std.testing.expectEqual(@as(u8, 0), has_root_id);

    try std.testing.expectEqual(job.State.succeeded, try rig.finish(unit));
    var deadline: core.runtime_tests.TestDeadline = .init(10_000);
    var waiting = try maintenanceStatus(rig.runtime, rig.library);
    while (waiting.units_run < 1) {
        if (!deadline.tick()) return error.UnitDidNotFinish;
        try std.testing.expectEqual(Status.ok, orca_runtime_pump(rig.runtime));
        waiting = try maintenanceStatus(rig.runtime, rig.library);
    }
    try std.testing.expectEqual(@as(u8, 1), waiting.enabled);
    try std.testing.expectEqual(exportMaintenanceState(.waiting), waiting.state);
    try std.testing.expectEqual(@as(u8, 0), waiting.has_blocked);
    try std.testing.expectEqual(@as(u8, 1), waiting.has_next_due_ms);
    try std.testing.expect(waiting.next_due_ms > 0 and waiting.next_due_ms <= 5 * 60 * 1000);
    try std.testing.expectEqual(@as(u8, 1), waiting.has_last);
    try std.testing.expectEqual(@as(u8, @backingInt(job.State.succeeded)), waiting.last_state);
    try std.testing.expectEqual(@as(u8, 1), waiting.has_last_release_id);
    try std.testing.expectEqual(album, waiting.last_release_id);
    try std.testing.expectEqual(@as(u64, 1), waiting.last_stats.verified);
    try std.testing.expectEqual(exportAcoustIdUse(.searched), waiting.last_stats.acoustid);
    var unit_stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, unit, &unit_stats));
    try std.testing.expectEqual(unit_stats, waiting.last_stats);
    try std.testing.expectEqual(Status.ok, orca_job_origin_get(rig.runtime, unit, &origin));
    try std.testing.expectEqual(exportJobOrigin(.maintenance), origin);

    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(rig.runtime, rig.library, null));
    const disabled = try maintenanceStatus(rig.runtime, rig.library);
    try std.testing.expectEqual(@as(u8, 0), disabled.enabled);
    try std.testing.expectEqual(exportMaintenanceState(.off), disabled.state);
    try std.testing.expectEqual(@as(u8, 0), disabled.has_last);
}

test "maintenance refuses an enabled flag other than 0 or 1, null outputs and stale handles, and reports why it is blocked" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-maintenance-refusals?mode=memory&cache=shared", &library));

    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_maintenance(runtime, library, &.{ .interval_ms = 0, .enabled = 2 }));
    try std.testing.expectEqualStrings("orca_library_set_maintenance: enabled is not 0 or 1", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_maintenance_status(runtime, library, null));
    const stale: Handle = .{ .index = library.index, .generation = library.generation + 1 };
    try std.testing.expectEqual(Status.stale_handle, orca_library_set_maintenance(runtime, stale, &.{ .interval_ms = 0, .enabled = 1 }));
    var status: MaintenanceStatus = undefined;
    try std.testing.expectEqual(Status.stale_handle, orca_library_maintenance_status(runtime, stale, &status));

    var origin: u8 = 0;
    var root_id: i64 = 0;
    var has_root_id: u8 = 0;
    const unknown_job: Handle = .{ .index = 7, .generation = 3 };
    try std.testing.expectEqual(Status.stale_handle, orca_job_origin_get(runtime, unknown_job, &origin));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_origin_get(runtime, unknown_job, null));
    try std.testing.expectEqual(Status.stale_handle, orca_job_reconcile_root(runtime, unknown_job, &root_id, &has_root_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_reconcile_root(runtime, unknown_job, null, &has_root_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_reconcile_root(runtime, unknown_job, &root_id, null));

    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(runtime, library, &.{ .interval_ms = 60_000, .enabled = 1 }));
    try std.testing.expectEqual(Status.ok, orca_runtime_pump(runtime));
    status = try maintenanceStatus(runtime, library);
    try std.testing.expectEqual(exportMaintenanceState(.blocked), status.state);
    try std.testing.expectEqual(@as(u8, 1), status.has_blocked);
    try std.testing.expectEqual(exportMaintenanceBlock(.client_identity_required), status.blocked);
    try std.testing.expectEqual(@as(u8, 1), status.has_next_due_ms);
    try std.testing.expect(status.next_due_ms > 0 and status.next_due_ms <= 60_000);

    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Host", "1.0", "https://host.invalid"));
    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(runtime, library, &.{ .interval_ms = 60_000, .enabled = 1 }));
    try std.testing.expectEqual(Status.ok, orca_runtime_pump(runtime));
    status = try maintenanceStatus(runtime, library);
    try std.testing.expectEqual(exportMaintenanceState(.blocked), status.state);
    try std.testing.expectEqual(exportMaintenanceBlock(.acoustid_required), status.blocked);
    try std.testing.expectEqual(@as(u8, 0), status.has_last);

    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(runtime, library, &.{ .interval_ms = 0, .enabled = 0 }));
    try std.testing.expectEqual(exportMaintenanceState(.off), (try maintenanceStatus(runtime, library)).state);
}

fn countRadioPicks(context: ?*anyopaque, preview: *const RadioPreviewView) callconv(.c) void {
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1 + preview.count;
}

test "the discovery settings round-trip and refuse values outside their sets, and a Radio preview checks its seed" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-radio?mode=memory&cache=shared", &library));
    var settings: DiscoverySettingsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(DiscoverySettingsView{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 6, .has_familiarity = 1, .familiarity = 0, .artist_variety = 2 }, settings);
    const changed: DiscoverySettingsView = .{ .radio_continue = 0, .include_unplayed = 0, .avoid_days = 7, .mix_count = 4, .has_familiarity = 1, .familiarity = 40, .artist_variety = 2 };
    try std.testing.expectEqual(Status.ok, orca_library_set_discovery_settings(runtime, library, &changed));
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(changed, settings);
    const legacy: DiscoverySettingsView = .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 6 };
    try std.testing.expectEqual(Status.ok, orca_library_set_discovery_settings(runtime, library, &legacy));
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(@as(u8, 1), settings.has_familiarity);
    try std.testing.expectEqual(@as(u8, 40), settings.familiarity);
    for ([_]DiscoverySettingsView{
        .{ .radio_continue = 2, .include_unplayed = 0, .avoid_days = 3, .mix_count = 6 },
        .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 2, .mix_count = 6 },
        .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 5 },
        .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 6, .has_familiarity = 2 },
        .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 6, .has_familiarity = 1, .familiarity = 101 },
        .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 6, .artist_variety = 4 },
    }) |invalid| try std.testing.expectEqual(Status.invalid_argument, orca_library_set_discovery_settings(runtime, library, &invalid));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_discovery_settings(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(@as(u8, 40), settings.familiarity);

    var visited: usize = 0;
    const loved: RadioSeedView = .{ .id = 0, .kind = @backingInt(std.meta.Tag(discovery.Seed).loved) };
    try std.testing.expectEqual(Status.ok, orca_library_radio_preview(runtime, library, &loved, null, null, 10, &visited, countRadioPicks));
    try std.testing.expectEqual(@as(usize, 1), visited);
    const unknown_track: RadioSeedView = .{ .id = 5, .kind = @backingInt(std.meta.Tag(discovery.Seed).track) };
    try std.testing.expectEqual(Status.not_found, orca_library_radio_preview(runtime, library, &unknown_track, null, null, 10, &visited, countRadioPicks));
    const unknown_kind: RadioSeedView = .{ .id = 0, .kind = 7 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &unknown_kind, null, null, 10, &visited, countRadioPicks));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, null, null, 513, &visited, countRadioPicks));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, null, null, 10, &visited, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, null, null, null, 10, &visited, countRadioPicks));
    var options = std.mem.zeroes(RadioOptionsView);
    options.explore = 101;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, &options, null, 10, &visited, countRadioPicks));
    options.explore = 35;
    options.focus_count = 5;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, &options, null, 10, &visited, countRadioPicks));
    options.focus_count = 1;
    options.focus[0] = .{ .id = 0, .kind = 4 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, &options, null, 10, &visited, countRadioPicks));
    options.focus[0] = .{ .id = 0, .kind = @backingInt(std.meta.Tag(discovery.Focus).high_energy) };
    var familiarity_view = std.mem.zeroes(RadioOptionsView);
    familiarity_view.familiarity = 101;
    const hundred = importRadioOptions(&familiarity_view) orelse return error.ImportFailed;
    try std.testing.expectEqual(@as(?u8, 100), hundred.familiarity);
    try std.testing.expectEqual(@as(u8, 101), exportRadioOptions(hundred).familiarity);
    const defaults = std.mem.zeroes(RadioOptionsView);
    try std.testing.expectEqual(@as(u8, 0), exportRadioOptions(importRadioOptions(&defaults) orelse return error.ImportFailed).familiarity);
    familiarity_view.familiarity = 102;
    try std.testing.expect(importRadioOptions(&familiarity_view) == null);
    familiarity_view.familiarity = 0;
    const box = runtimeBox(runtime).?;
    try box.runtime.setLibraryDiscoverySettings(importLibrary(library), .{ .familiarity = 40 });
    const session: RadioPreviewSessionView = .{ .now_s = 2_000_000_000, .seed = 1, .has_now = 1, .has_seed = 1 };
    try std.testing.expectEqual(Status.ok, orca_library_radio_preview(runtime, library, &loved, &familiarity_view, &session, 10, &visited, countRadioPicks));
    try std.testing.expectEqual(Status.ok, orca_library_radio_preview(runtime, library, &loved, &options, &session, 10, &visited, countRadioPicks));
    try std.testing.expect(visited > 2);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "a zero familiarity byte in C radio options reads the Library setting" {
    var view = std.mem.zeroes(RadioOptionsView);
    try std.testing.expectEqual(@as(?u8, null), (importRadioOptions(&view) orelse return error.ImportFailed).familiarity);
    view.familiarity = 1;
    try std.testing.expectEqual(@as(?u8, 0), (importRadioOptions(&view) orelse return error.ImportFailed).familiarity);
    view.familiarity = 101;
    try std.testing.expectEqual(@as(?u8, 100), (importRadioOptions(&view) orelse return error.ImportFailed).familiarity);
    view.familiarity = 102;
    try std.testing.expect(importRadioOptions(&view) == null);
    view.familiarity = 255;
    try std.testing.expect(importRadioOptions(&view) == null);
}

test "a discovery settings write from C keeps the stored Artist variety" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-artist-variety?mode=memory&cache=shared", &library));
    const box = runtimeBox(runtime).?;
    for ([_]discovery.ArtistVariety{ .strict, .relaxed, .balanced }) |variety| {
        try box.runtime.setLibraryDiscoverySettings(importLibrary(library), .{ .artist_variety = variety });
        for ([_]DiscoverySettingsView{
            .{ .radio_continue = 0, .include_unplayed = 0, .avoid_days = 7, .mix_count = 4, .has_familiarity = 1, .familiarity = 40 },
            .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 6 },
        }) |written| {
            try std.testing.expectEqual(Status.ok, orca_library_set_discovery_settings(runtime, library, &written));
            const stored = try box.runtime.libraryDiscoverySettings(importLibrary(library));
            try std.testing.expectEqual(variety, stored.artist_variety);
            try std.testing.expectEqual(written.avoid_days, @backingInt(stored.avoid_days));
            try std.testing.expectEqual(@as(u8, 40), stored.familiarity);
        }
    }
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "the discovery settings report and set the Artist variety" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-artist-variety-field?mode=memory&cache=shared", &library));
    const box = runtimeBox(runtime).?;
    var settings: DiscoverySettingsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(@as(u8, 2), settings.artist_variety);
    try box.runtime.setLibraryDiscoverySettings(importLibrary(library), .{ .artist_variety = .strict });
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(@as(u8, 3), settings.artist_variety);

    for ([_]discovery.ArtistVariety{ .relaxed, .balanced, .strict }) |variety| {
        const written: DiscoverySettingsView = .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 6, .artist_variety = @backingInt(variety) };
        try std.testing.expectEqual(Status.ok, orca_library_set_discovery_settings(runtime, library, &written));
        try std.testing.expectEqual(variety, (try box.runtime.libraryDiscoverySettings(importLibrary(library))).artist_variety);
    }

    try box.runtime.setLibraryDiscoverySettings(importLibrary(library), .{ .artist_variety = .relaxed });
    for ([_]u8{ 4, 255 }) |invalid_value| {
        const invalid: DiscoverySettingsView = .{ .radio_continue = 0, .include_unplayed = 0, .avoid_days = 7, .mix_count = 4, .artist_variety = invalid_value };
        try std.testing.expectEqual(Status.invalid_argument, orca_library_set_discovery_settings(runtime, library, &invalid));
        const stored = try box.runtime.libraryDiscoverySettings(importLibrary(library));
        try std.testing.expectEqual(discovery.ArtistVariety.relaxed, stored.artist_variety);
        try std.testing.expect(stored.radio_continue);
    }

    try box.runtime.setLibraryDiscoverySettings(importLibrary(library), .{ .artist_variety = .strict });
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(Status.ok, orca_library_set_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(discovery.ArtistVariety.strict, (try box.runtime.libraryDiscoverySettings(importLibrary(library))).artist_variety);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const CapturedDailyMixes = struct {
    calls: usize = 0,
    state: u8 = 255,
    count: usize = 0,
    first: DailyMixView = undefined,
    first_name: [32]u8 = undefined,
    first_name_length: usize = 0,
    last: DailyMixView = undefined,
    last_name: [32]u8 = undefined,
    last_name_length: usize = 0,
};

fn captureDailyMixes(context: ?*anyopaque, view: *const DailyMixesView) callconv(.c) void {
    const captured: *CapturedDailyMixes = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.state = view.state;
    captured.count = view.count;
    if (view.count == 0) return;
    captured.first = view.mixes[0];
    captured.first_name_length = @min(view.mixes[0].name.length, captured.first_name.len);
    @memcpy(captured.first_name[0..captured.first_name_length], view.mixes[0].name.pointer[0..captured.first_name_length]);
    const last = view.mixes[view.count - 1];
    captured.last = last;
    captured.last_name_length = @min(last.name.length, captured.last_name.len);
    @memcpy(captured.last_name[0..captured.last_name_length], last.name.pointer[0..captured.last_name_length]);
}

const CapturedDailyMixEntries = struct {
    calls: usize = 0,
    entries: [daily_mixes.max_entries]DailyMixEntryView = undefined,
    count: usize = 0,
};

fn captureDailyMixEntries(context: ?*anyopaque, view: *const DailyMixEntriesView) callconv(.c) void {
    const captured: *CapturedDailyMixEntries = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.count = view.count;
    @memcpy(captured.entries[0..view.count], view.entries[0..view.count]);
}

test "Daily Mixes are made, listed, read, marked Not for me, reset and saved through the C ABI" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-daily-mixes?mode=memory&cache=shared", &library));
    const now_s: i64 = 2_000_000_000;

    var mixes: CapturedDailyMixes = .{};
    try std.testing.expectEqual(Status.ok, orca_library_daily_mixes(runtime, library, now_s, 0, &mixes, captureDailyMixes));
    try std.testing.expectEqual(@as(usize, 1), mixes.calls);
    try std.testing.expectEqual(@backingInt(daily_mixes.State.not_enough_history), mixes.state);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(std.testing.allocator);
    try sql.appendSlice(std.testing.allocator, "INSERT INTO genres(id, name, key) VALUES (1, 'Jazz', 'jazz');\n");
    for (1..4) |artist| try sql.print(std.testing.allocator, "INSERT INTO artists(id, name, key) VALUES ({d}, 'Artist {d}', 'artist {d}');\n", .{ artist, artist, artist });
    for (1..46) |id| {
        const artist = (id - 1) / 15 + 1;
        try sql.print(std.testing.allocator,
            \\INSERT INTO releases(id, title) VALUES ({d}, 'Release {d}');
            \\INSERT INTO recordings(id, title) VALUES ({d}, 'r{d}');
            \\INSERT INTO files(id, recording_id, audio_format, size_bytes) VALUES ({d}, {d}, 1, 1);
            \\INSERT INTO tracks(id, recording_id, release_id, title, artist_id, preferred_file_id, duration_ms, created_at)
            \\    VALUES ({d}, {d}, {d}, 't{d}', {d}, {d}, 180000, 1000);
            \\INSERT INTO locations(file_id, volume_id, uri, state) VALUES ({d}, {d}, '/m/{d}', 'present');
            \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES ({d}, 1, 0, 0);
            \\
        , .{ id, id, id, id, id, id, id, id, id, id, artist, id, id, database.LibraryDatabase.null_volume, id, id });
        for (0..2) |play| try sql.print(
            std.testing.allocator,
            "INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES ({d}, {d}, {d}, 1000, 't', 'a');\n",
            .{ id, id, now_s - @as(i64, @intCast(1 + (id + play) % 3)) * 86_400 - @as(i64, @intCast(id)) },
        );
    }
    try sql.appendSlice(std.testing.allocator,
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
        \\    SELECT recording_id, count(*), max(started_at) FROM listens GROUP BY recording_id;
    );
    try sql.append(std.testing.allocator, 0);
    const library_database = try core.runtime.libraryDatabase(&box.runtime, importLibrary(library));
    try library_database.database.exec(sql.items[0 .. sql.items.len - 1 :0]);

    try box.runtime.setLibraryDiscoverySettings(importLibrary(library), .{ .artist_variety = .relaxed });
    var mix_job: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_daily_mixes(runtime, library, &.{ .now_s = now_s, .utc_offset_s = 0, .force = 2 }, &mix_job));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_daily_mixes(runtime, library, null, &mix_job));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_daily_mixes(runtime, library, &.{ .now_s = now_s, .utc_offset_s = 0, .force = 1 }, null));
    try std.testing.expectEqual(Status.ok, orca_library_start_daily_mixes(runtime, library, &.{ .now_s = now_s, .utc_offset_s = 0, .force = 1 }, &mix_job));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(mix_job)));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(runtime, mix_job, &snapshot));
    try std.testing.expectEqual(@as(u8, 13), snapshot.kind);

    try std.testing.expectEqual(Status.ok, orca_library_daily_mixes(runtime, library, now_s, 0, &mixes, captureDailyMixes));
    try std.testing.expectEqual(@backingInt(daily_mixes.State.ready), mixes.state);
    try std.testing.expectEqual(@as(usize, 1), mixes.count);
    try std.testing.expectEqualStrings("Jazz", mixes.first_name[0..mixes.first_name_length]);
    try std.testing.expectEqual(@backingInt(daily_mixes.Kind.genre), mixes.first.kind);
    try std.testing.expectEqual(@as(u8, 1), mixes.first.has_genre_id);
    try std.testing.expectEqual(@as(i64, 1), mixes.first.genre_id);
    try std.testing.expectEqual(@as(u8, 3), mixes.first.artist_count);
    try std.testing.expectEqual(@as(u32, 25), mixes.first.entry_count);
    try std.testing.expectEqual(@as(u64, 25 * 180_000), mixes.first.duration_ms);
    try std.testing.expect(mixes.first.cover_count > 0);
    try std.testing.expectEqual(@as(u16, 0), mixes.first.decade);
    const mix_id = mixes.first.id;

    var entries: CapturedDailyMixEntries = .{};
    try std.testing.expectEqual(Status.ok, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(@as(usize, 25), entries.count);
    const before = entries.entries;
    for (before[0..entries.count]) |entry| {
        try std.testing.expect(entry.reason_count >= 1);
        try std.testing.expectEqual(@as(u8, 1), entry.has_duration);
        try std.testing.expectEqual(@as(i64, 180_000), entry.duration_ms);
    }
    try std.testing.expectEqual(Status.not_found, orca_library_daily_mix_entries(runtime, library, mix_id + 100, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, null));

    const hidden = before[1].track_id;
    try std.testing.expectEqual(Status.ok, orca_library_not_for_me(runtime, library, hidden, now_s));
    try std.testing.expectEqual(Status.ok, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(@as(usize, 24), entries.count);
    try std.testing.expectEqual(before[0].track_id, entries.entries[0].track_id);
    try std.testing.expectEqual(before[2].track_id, entries.entries[1].track_id);
    try std.testing.expectEqual(Status.not_found, orca_library_not_for_me(runtime, library, 1_000_000, now_s));

    try std.testing.expectEqual(Status.ok, orca_library_clear_not_for_me(runtime, library, hidden));
    try std.testing.expectEqual(Status.ok, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(@as(usize, 25), entries.count);
    try std.testing.expectEqual(hidden, entries.entries[1].track_id);
    try std.testing.expectEqual(Status.not_found, orca_library_clear_not_for_me(runtime, library, 1_000_000));

    try std.testing.expectEqual(Status.ok, orca_library_not_for_me(runtime, library, hidden, now_s));
    try std.testing.expectEqual(Status.ok, orca_library_reset_recommendations(runtime, library));
    try std.testing.expectEqual(Status.ok, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(@as(usize, 25), entries.count);

    var playlist_id: i64 = 0;
    const name = "Jazz mix";
    try std.testing.expectEqual(Status.ok, orca_library_save_daily_mix(runtime, library, mix_id, name, name.len, &playlist_id));
    try std.testing.expect(playlist_id > 0);
    var saved = try library_database.database.prepare("SELECT count(*) FROM playlist_entries WHERE playlist_id = ?1;");
    defer saved.deinit();
    try saved.bindInt64(1, playlist_id);
    try std.testing.expect(try saved.step() == .row);
    try std.testing.expectEqual(@as(i64, 25), saved.columnInt64(0));
    try std.testing.expectEqual(Status.not_found, orca_library_save_daily_mix(runtime, library, mix_id + 100, name, name.len, &playlist_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_save_daily_mix(runtime, library, mix_id, null, 3, &playlist_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_save_daily_mix(runtime, library, mix_id, name, name.len, null));

    try library_database.database.exec("UPDATE releases SET release_date = '1994-05-01';");
    try std.testing.expectEqual(Status.ok, orca_library_start_daily_mixes(runtime, library, &.{ .now_s = now_s, .utc_offset_s = 0, .force = 1 }, &mix_job));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(mix_job)));
    try std.testing.expectEqual(Status.ok, orca_library_daily_mixes(runtime, library, now_s, 0, &mixes, captureDailyMixes));
    try std.testing.expectEqual(@as(usize, 2), mixes.count);
    try std.testing.expectEqualStrings("Jazz", mixes.first_name[0..mixes.first_name_length]);
    try std.testing.expectEqualStrings("1990s", mixes.last_name[0..mixes.last_name_length]);
    try std.testing.expectEqual(@backingInt(daily_mixes.Kind.decade), mixes.last.kind);
    try std.testing.expectEqual(@as(u16, 1990), mixes.last.decade);
    try std.testing.expectEqual(@as(u8, 0), mixes.last.has_genre_id);
    try std.testing.expect(mixes.last.entry_count > 0);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}
