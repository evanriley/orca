//! liborca's public Zig API.
//!
//! Everything a client needs is declared here: `Runtime`, the handles it
//! hands out, and the types its methods take and return. `internal` holds the
//! subsystems behind them; it exists for liborca's own tests and benchmarks,
//! and nothing in it is part of the API. See `docs/api.md`.

const std = @import("std");

pub const internal = struct {
    pub const audio = @import("audio/root.zig");
    pub const analysis = @import("analysis/root.zig");
    pub const c_api = @import("c_api.zig");
    pub const codec = @import("codec/root.zig");
    pub const core = @import("core/root.zig");
    pub const database = @import("database/root.zig");
    pub const library = @import("library/root.zig");
    pub const metadata = @import("metadata/root.zig");
    pub const network = @import("network/root.zig");
    pub const platform = @import("platform.zig");
    pub const providers = @import("providers/root.zig");
    pub const storage = @import("storage/root.zig");
};

const runtime = internal.core.runtime;
const database = internal.database;
const audio = internal.audio;
const control = internal.core.control;
const job = internal.core.job;

pub const version = @import("version.zig").value;

pub const SupportedFormat = struct {
    name: []const u8,
    /// Recognized but not yet decoded; see docs/roadmap.md, Deferred formats.
    planned: bool = false,
};

/// The audio formats Orca imports and plays, then those it only plans to.
pub const supported_formats = [_]SupportedFormat{
    .{ .name = "FLAC" },
    .{ .name = "ALAC" },
    .{ .name = "WAV" },
    .{ .name = "AIFF" },
    .{ .name = "MP3" },
    .{ .name = "AAC" },
    .{ .name = "Opus" },
    .{ .name = "Vorbis" },
    .{ .name = "QOA" },
    .{ .name = "WavPack", .planned = true },
    .{ .name = "DSD", .planned = true },
};

/// The root object: owns libraries, players, zones and jobs, and shuts them
/// down in dependency order.
pub const Runtime = runtime.OrcaRuntime;

// Handles. Generational: a destroyed object's handle never resolves again.
pub const LibraryHandle = runtime.LibraryHandle;
pub const PlayerHandle = runtime.PlayerHandle;
pub const ZoneHandle = runtime.ZoneHandle;
pub const JobHandle = runtime.JobHandle;

// Library queries and the bounded pages they return.
pub const TrackQuery = database.TrackQuery;
pub const TrackTotals = database.TrackTotals;
pub const TrackSort = database.TrackSort;
pub const SortDirection = database.SortDirection;
pub const TrackPage = database.TrackPage;
pub const TrackSummary = database.TrackSummary;
pub const TrackDetails = runtime.TrackDetails;
pub const TrackFieldStates = runtime.TrackFieldStates;
pub const TrackFieldState = runtime.TrackFieldState;
pub const EditableTrackField = runtime.EditableTrackField;
pub const TrackFieldCover = runtime.TrackFieldCover;
pub const TrackFieldCoverSource = runtime.TrackFieldCoverSource;
pub const TrackLoudness = runtime.TrackLoudness;
pub const RecordingIdSource = runtime.RecordingIdSource;
pub const ArtistQuery = database.ArtistQuery;
pub const ArtistSort = database.ArtistSort;
pub const ArtistRole = database.ArtistRole;
pub const ArtistPage = database.ArtistPage;
pub const ArtistTotals = database.ArtistTotals;
pub const ArtistSummary = database.ArtistSummary;
pub const ReleaseQuery = database.ReleaseQuery;
pub const ReleaseSort = database.ReleaseSort;
pub const ReleaseKind = database.ReleaseKind;
pub const NameOrder = database.NameOrder;
pub const LetterBucket = database.LetterBucket;
pub const ReleaseTotals = database.ReleaseTotals;
pub const ReleasePage = database.ReleasePage;
pub const ReleaseSummary = database.ReleaseSummary;
pub const GenreQuery = database.GenreQuery;
pub const GenreSort = database.GenreSort;
pub const GenrePage = database.GenrePage;
pub const GenreSummary = database.GenreSummary;
pub const GenreNames = database.GenreNames;
pub const GenreName = database.GenreName;
pub const GenreCounts = database.GenreCounts;
pub const GenreCount = database.GenreCount;
pub const ReleaseIds = database.ReleaseIds;
pub const max_track_genres = database.max_track_genres;
pub const SearchKind = database.SearchKind;
pub const SearchReason = database.SearchReason;
pub const SearchHit = database.SearchHit;
pub const SearchLimits = database.SearchLimits;
pub const SearchResults = database.SearchResults;
pub const max_search_text = database.max_search_text;
pub const max_search_hits_per_kind = database.max_search_hits_per_kind;
pub const HealthIssuePage = database.HealthIssuePage;
pub const HealthIssue = database.HealthIssue;
pub const HealthIssueKind = database.HealthIssueKind;
pub const HealthSeverity = database.HealthSeverity;
pub const HealthAction = database.HealthAction;
pub const HealthFile = database.HealthFile;
pub const HealthKindSummary = database.HealthKindSummary;
pub const HealthSummary = database.HealthSummary;
pub const ReanalysisOutcome = runtime.ReanalysisOutcome;
pub const DuplicateGroup = runtime.DuplicateGroup;
pub const DuplicateGroupPage = runtime.DuplicateGroupPage;
pub const DuplicateGroupTotals = runtime.DuplicateGroupTotals;
pub const DuplicateCopy = runtime.DuplicateCopy;
pub const DuplicateCopyList = runtime.DuplicateCopyList;
pub const DuplicateMerge = runtime.DuplicateMerge;
pub const LibraryStats = database.LibraryStats;
pub const ProviderSource = internal.core.provider_sources.ProviderSource;
pub const ProviderSourceId = internal.core.provider_sources.ProviderSourceId;
pub const LibraryRoot = database.repository.LibraryRoot;
pub const LibraryRootPage = database.repository.LibraryRootPage;
pub const FolderEntry = database.repository.FolderEntry;
pub const FolderEntryKind = database.repository.FolderEntryKind;
pub const FolderEntryStatus = database.repository.FolderEntryStatus;
pub const ArtworkRole = database.repository.ArtworkRole;
pub const FolderPage = database.repository.FolderPage;
pub const RootBinding = database.RootBinding;
pub const RemovedRoot = runtime.RemovedRoot;
pub const LibraryAvailability = runtime.LibraryAvailability;
pub const EmbeddedImage = internal.metadata.EmbeddedImage;
pub const ArtworkSubject = runtime.ArtworkSubject;
pub const ReleaseArtworkKind = database.ReleaseArtworkKind;
pub const CoverArtCandidate = database.CoverArtCandidate;
pub const CoverArtCandidateKind = database.CoverArtCandidateKind;
pub const max_cover_art_candidates = database.repository.max_cover_art_candidates;
pub const ArtworkProblem = database.ArtworkProblem;
pub const ArtworkFinding = database.ArtworkFinding;
pub const minimum_cover_pixels = database.repository.minimum_cover_pixels;
pub const max_image_bytes = internal.metadata.model.max_image_bytes;
pub const sniffImageMimeType = internal.metadata.model.sniffImageMimeType;
pub const ArtworkResult = runtime.ArtworkResult;
pub const BrowseKind = runtime.BrowseKind;
pub const BrowseTrackListing = runtime.BrowseTrackListing;
pub const BrowseRequest = runtime.BrowseRequest;
pub const BrowsePayload = runtime.BrowsePayload;
pub const BrowseResult = runtime.BrowseResult;
pub const FileAnalysis = runtime.FileAnalysis;
pub const TrackEdit = runtime.TrackEdit;
pub const TrackEditPage = runtime.TrackEditPage;
pub const EditedTracks = runtime.EditedTracks;
pub const RatingChange = runtime.RatingChange;
pub const ReleaseLoveChange = runtime.ReleaseLoveChange;
pub const PlaylistSummary = runtime.PlaylistSummary;
pub const PlaylistPage = runtime.PlaylistPage;
pub const PlaylistEntry = runtime.PlaylistEntry;
pub const PlaylistEntryPage = runtime.PlaylistEntryPage;
pub const PlaylistInsertion = runtime.PlaylistInsertion;
pub const PlaylistKind = runtime.PlaylistKind;
pub const PlaylistCreator = runtime.PlaylistCreator;
pub const PlaylistSort = runtime.PlaylistSort;
pub const PlaylistQuery = runtime.PlaylistQuery;
pub const PlaylistUpdate = runtime.PlaylistUpdate;
pub const PlaylistFormats = runtime.PlaylistFormats;
pub const CodecCount = runtime.CodecCount;
pub const SmartPlaylistPreview = runtime.SmartPlaylistPreview;
pub const PlaylistImport = runtime.PlaylistImport;
pub const PlaylistExport = runtime.PlaylistExport;
pub const PlaylistExportOptions = runtime.PlaylistExportOptions;
pub const PlaylistPathStyle = runtime.PlaylistPathStyle;
pub const max_playlist_entries = database.repository.max_playlist_entries;
pub const max_playlist_tags = database.repository.max_playlist_tags;
pub const max_smart_playlist_rules_bytes = internal.library.smart_playlist.max_rules_bytes;
pub const max_rating = database.repository.max_rating;
pub const MetadataField = internal.metadata.Field;
pub const Explicit = internal.metadata.Explicit;
pub const isMusicBrainzId = internal.metadata.isMusicBrainzId;
pub const Provenance = internal.metadata.Provenance;

// Tag write-back: a sealed plan, previewed, then approved by its digest.
pub const TagWritePlan = runtime.TagWritePlan;
pub const TagWriteFile = runtime.TagWriteFile;
pub const TagWriteChange = runtime.TagWriteChange;
pub const TagWriteFormat = runtime.TagWriteFormat;
pub const TagWriteGenres = runtime.TagWriteGenres;
pub const TagWriteConflict = runtime.TagWriteConflict;
pub const TagWriteSkip = runtime.TagWriteSkip;
pub const TagWriteSkipReason = runtime.TagWriteSkipReason;
pub const TagWriteFailure = runtime.TagWriteFailure;
pub const TagWriteFailureReason = runtime.TagWriteFailureReason;
pub const TagWriteGroupState = runtime.TagWriteGroupState;
pub const TagWriteGroup = runtime.TagWriteGroup;
pub const TagWriteGroupPage = runtime.TagWriteGroupPage;
pub const TagWriteDiffSubject = runtime.TagWriteDiffSubject;
pub const TagWriteDiff = runtime.TagWriteDiff;
pub const TagWriteGroupDetail = runtime.TagWriteGroupDetail;
pub const TagWriteHistoryExport = runtime.TagWriteHistoryExport;
pub const TagWriteHistoryExportOptions = runtime.TagWriteHistoryExportOptions;
pub const TagWriteDigest = internal.metadata.mutation.Digest;
pub const PruneSummary = runtime.PruneSummary;

// Playback.
pub const PlayerStatus = runtime.PlayerStatus;
pub const PlaybackFailure = runtime.PlaybackFailure;
pub const PlayerSnapshot = audio.player.Snapshot;
pub const TransportState = audio.player.TransportState;
pub const RepeatMode = runtime.RepeatMode;
pub const ReplayGainMode = audio.processing.ReplayGainMode;
pub const ReplayGainSource = audio.processing.ReplayGainSource;
pub const ReplayGainSettings = audio.processing.ReplayGainSettings;
pub const UntaggedFallback = audio.processing.UntaggedFallback;
pub const Equalizer = audio.dsp.Equalizer;
pub const EqualizerPreset = audio.dsp.Preset;
pub const equalizer_band_frequencies_hz = audio.dsp.band_frequencies_hz;
pub const ParametricEqualizer = audio.dsp.ParametricEqualizer;
pub const ParametricFilter = audio.dsp.Filter;
pub const ParametricFilterKind = audio.dsp.FilterKind;
pub const max_parametric_filters = audio.dsp.max_parametric_filters;
pub const parseEqualizerApo = audio.eq_text.parseEqualizerApo;
pub const writeEqualizerApo = audio.eq_text.writeEqualizerApo;
pub const SignalPath = audio.dsp.SignalPath;
pub const SignalPathReason = audio.signal_path.Reason;
pub const PcmFormat = audio.pcm.Format;
pub const SampleFormat = audio.pcm.SampleFormat;
pub const QueueSnapshot = runtime.QueueSnapshot;
pub const QueueStats = runtime.QueueStats;
pub const QueueHistoryEntry = runtime.QueueHistoryEntry;
pub const QueueHistoryReason = runtime.QueueHistoryReason;
pub const queue_history_capacity = runtime.queue_history_capacity;
pub const playback_queue_capacity = audio.playback_queue.capacity;

comptime {
    std.debug.assert(database.max_track_id_window >= playback_queue_capacity);
}
pub const TrackRef = runtime.TrackRef;

// Outputs.
pub const Device = audio.backend.Device;
pub const DeviceKind = audio.backend.DeviceKind;
pub const DeviceCapabilities = audio.backend.DeviceCapabilities;
pub const DeviceState = audio.backend.DeviceState;
pub const DeviceFormat = audio.backend.DeviceFormat;
pub const DeviceSampleFormat = audio.backend.DeviceSampleFormat;
pub const DiscoveryDetail = audio.backend.DiscoveryDetail;
pub const OutputFactory = audio.output.Factory;
pub const ZoneStats = runtime.ZoneStats;
pub const OutputState = audio.zone.OutputState;
pub const RenderPolicy = audio.zone.RenderPolicy;
pub const RenderStrategy = audio.zone.RenderStrategy;

// Listening history and ListenBrainz.
pub const PlayStats = runtime.PlayStats;
pub const Feedback = runtime.Feedback;
pub const FeedbackChange = runtime.FeedbackChange;
pub const ClientIdentity = runtime.ClientIdentity;
pub const CredentialStore = runtime.CredentialStore;
pub const ScrobblerStatus = runtime.ScrobblerStatus;
pub const ListenPolicy = runtime.ListenPolicy;
pub const CacheSize = runtime.CacheSize;
pub const ScrobblerState = runtime.ScrobblerState;
pub const BoundedText = runtime.BoundedText;

// MusicBrainz matching: proposals found by a job, reviewed by a person.
pub const MatchRequest = runtime.MatchRequest;
pub const MatchMode = runtime.MatchMode;
pub const MatchStats = runtime.MatchStats;
pub const MatchProposal = runtime.MatchProposal;
pub const MatchProposalPage = runtime.MatchProposalPage;
pub const MatchAcceptance = runtime.MatchAcceptance;
pub const ConfidentMatchAcceptance = runtime.ConfidentMatchAcceptance;
pub const MatchReviewItem = runtime.MatchReviewItem;
pub const MatchReviewPage = runtime.MatchReviewPage;
pub const ReleaseMatchBucket = runtime.ReleaseMatchBucket;
pub const ReleaseCandidate = runtime.ReleaseCandidate;
pub const ReleaseMatchItem = runtime.ReleaseMatchItem;
pub const ReleaseMatchPage = runtime.ReleaseMatchPage;
pub const ReleaseMatchCounts = runtime.ReleaseMatchCounts;
pub const ReleaseField = runtime.ReleaseField;
pub const ReleaseFieldSet = runtime.ReleaseFieldSet;
pub const MatchEvidence = runtime.MatchEvidence;
pub const ReleaseFieldDiff = runtime.ReleaseFieldDiff;
pub const ReleaseTrackAlignment = runtime.ReleaseTrackAlignment;
pub const ReleaseMatchDiff = runtime.ReleaseMatchDiff;
pub const CorrectionGroup = runtime.CorrectionGroup;
pub const CorrectionGroupMember = runtime.CorrectionGroupMember;
pub const CorrectionGroupPage = runtime.CorrectionGroupPage;
pub const CorrectionGroupAcceptance = runtime.CorrectionGroupAcceptance;
pub const TrackVerification = runtime.TrackVerification;
pub const VerificationOutcome = runtime.VerificationOutcome;
pub const HeardRecording = runtime.HeardRecording;
pub const AcoustIdUse = runtime.AcoustIdUse;
pub const BusyService = runtime.BusyService;
pub const CoverArtOutcome = runtime.CoverArtOutcome;

// Lyrics: read from a Track's sidecar or file on a job worker.
pub const Lyrics = runtime.Lyrics;
pub const LyricsLine = internal.metadata.lyrics.Line;
pub const LyricsSource = internal.metadata.lyrics.Source;
pub const LyricsKind = internal.metadata.lyrics.Kind;
pub const LyricsOutcome = runtime.LyricsOutcome;
pub const LyricsOptions = runtime.LyricsOptions;

pub const ArtistInfo = database.ArtistInfo;
pub const ArtistInfoRecord = database.ArtistInfoRecord;
pub const ArtistInfoOptions = runtime.ArtistInfoOptions;
pub const ArtistInfoOutcome = runtime.ArtistInfoOutcome;
pub const ArtistPhotoSource = database.ArtistPhotoSource;
pub const ArtistBiographySource = database.ArtistBiographySource;
pub const ArtistLinks = database.ArtistLinks;
pub const ArtistLink = database.ArtistLink;
pub const ArtistLinkKind = database.ArtistLinkKind;
pub const ArtistLoveChange = database.ArtistLoveChange;
pub const RelatedArtist = database.RelatedArtist;
pub const ElsewhereRelease = database.ElsewhereRelease;
pub const ReleaseGroupCoverState = database.ReleaseGroupCoverState;
pub const RelatedArtists = database.RelatedArtists;
pub const RelatedArtistPhotoRecord = database.RelatedArtistPhotoRecord;
pub const RelatedArtistPhotoInfo = database.RelatedArtistPhotoInfo;
pub const related_artists_max = database.related_artists_max;
pub const ReleaseInfo = database.ReleaseInfo;
pub const ReleaseInfoRecord = database.ReleaseInfoRecord;
pub const ReleaseDescriptionSource = database.ReleaseDescriptionSource;
pub const ReleaseInfoOptions = runtime.ReleaseInfoOptions;
pub const ReleaseInfoOutcome = runtime.ReleaseInfoOutcome;
pub const GenreFill = runtime.GenreFill;
pub const GenreFillOptions = runtime.GenreFillOptions;
/// The licence of genres filled from MusicBrainz, for the credit a frontend
/// shows beside them.
pub const musicbrainz_genre_licence = internal.providers.musicbrainz.genre_licence;

// AcoustID: fingerprints, and submissions of recording IDs a person chose.
pub const TrackFingerprint = runtime.TrackFingerprint;
pub const SubmissionStats = runtime.SubmissionStats;
pub const SubmissionOutcome = runtime.SubmissionOutcome;
pub const AcoustIdSubmittable = runtime.AcoustIdSubmittable;
pub const AcoustIdSubmittablePage = runtime.AcoustIdSubmittablePage;
/// Where a `CredentialStore` holds AcoustID keys: the user's own under
/// `acoustid_user_key_account`, and an application key that overrides the
/// host's under `acoustid_client_key_account`.
pub const acoustid_credential_service = internal.providers.acoustid.credential_service;
pub const acoustid_user_key_account = internal.providers.acoustid.user_key_account;
pub const acoustid_client_key_account = internal.providers.acoustid.client_key_account;
/// The service and account under which a `CredentialStore` holds the user's
/// ListenBrainz token.
pub const listenbrainz_token_service = internal.providers.listenbrainz.token_service;
pub const listenbrainz_token_account = internal.providers.listenbrainz.token_account;

// Jobs.
pub const ScanRequest = runtime.ScanRequest;
pub const ReconcileRequest = runtime.ReconcileRequest;
pub const ReconcileScope = runtime.ReconcileScope;
pub const BackfillRequest = runtime.BackfillRequest;
pub const BackfillPending = runtime.BackfillPending;
pub const AnalysisRequest = runtime.AnalysisRequest;
/// Logical processors: the most `AnalysisRequest.threads` that can each have
/// one of their own.
pub const analysisAvailableThreads = internal.library.analysis_pass.availableThreads;
/// What a null `AnalysisRequest.threads` takes: one fewer than
/// `analysisAvailableThreads`, and at least 1.
pub const analysisDefaultThreads = internal.library.analysis_pass.defaultThreads;
pub const DuplicateScanRequest = runtime.DuplicateScanRequest;
pub const ScanStats = runtime.ScanStats;
pub const ScanStage = runtime.ScanStage;
pub const CancellationToken = internal.library.CancellationToken;
pub const FolderEstimate = internal.library.FolderEstimate;
pub const estimateAudioFiles = internal.library.folder_estimate.estimateAudioFiles;
pub const estimate_default_limit = internal.library.folder_estimate.default_limit;
pub const JobSnapshot = job.Snapshot;
pub const JobKind = job.Kind;
pub const JobState = job.State;
pub const QueuedJob = runtime.QueuedJob;
pub const JobHistoryEntry = runtime.JobHistoryEntry;
pub const JobHistoryFilter = runtime.JobHistoryFilter;
pub const max_waiting_jobs = runtime.max_waiting_jobs;

// Filesystem watching: automatic reconciles of what changed under a root.
pub const WatchOptions = runtime.WatchOptions;
pub const WatchState = runtime.WatchState;
pub const WatchStatus = runtime.WatchStatus;

pub const MaintenanceOptions = runtime.MaintenanceOptions;
pub const MaintenanceState = runtime.MaintenanceState;
pub const MaintenanceBlock = runtime.MaintenanceBlock;
pub const MaintenanceUnit = runtime.MaintenanceUnit;
pub const MaintenanceStatus = runtime.MaintenanceStatus;
pub const JobOrigin = runtime.JobOrigin;

// The control lane: commands in, completions and telemetry out.
pub const Action = control.Action;
pub const RequestId = control.RequestId;
pub const Event = control.Event;
pub const Telemetry = control.Telemetry;
pub const Failure = control.Failure;
pub const HostWaker = runtime.HostWaker;

comptime {
    // Keep exported C symbols reachable when this root builds as liborca.so.
    _ = internal.c_api.orca_runtime_create;
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(internal);
    _ = @import("fuzz.zig");
}
