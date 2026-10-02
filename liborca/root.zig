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
pub const TrackSort = database.TrackSort;
pub const SortDirection = database.SortDirection;
pub const TrackPage = database.TrackPage;
pub const TrackSummary = database.TrackSummary;
pub const TrackDetails = runtime.TrackDetails;
pub const TrackLoudness = runtime.TrackLoudness;
pub const RecordingIdSource = runtime.RecordingIdSource;
pub const ArtistQuery = database.ArtistQuery;
pub const ArtistPage = database.ArtistPage;
pub const ArtistSummary = database.ArtistSummary;
pub const ReleaseQuery = database.ReleaseQuery;
pub const ReleaseSort = database.ReleaseSort;
pub const ReleasePage = database.ReleasePage;
pub const ReleaseSummary = database.ReleaseSummary;
pub const HealthIssuePage = database.HealthIssuePage;
pub const HealthIssue = database.HealthIssue;
pub const HealthIssueKind = database.HealthIssueKind;
pub const HealthSeverity = database.HealthSeverity;
pub const HealthAction = database.HealthAction;
pub const HealthFile = database.HealthFile;
pub const HealthKindSummary = database.HealthKindSummary;
pub const HealthSummary = database.HealthSummary;
pub const LibraryRootPage = database.repository.LibraryRootPage;
pub const RootBinding = database.RootBinding;
pub const RemovedRoot = runtime.RemovedRoot;
pub const EmbeddedImage = internal.metadata.EmbeddedImage;
pub const ArtworkSubject = runtime.ArtworkSubject;
pub const ArtworkResult = runtime.ArtworkResult;
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
pub const PlaylistImport = runtime.PlaylistImport;
pub const PlaylistExport = runtime.PlaylistExport;
pub const PlaylistExportOptions = runtime.PlaylistExportOptions;
pub const PlaylistPathStyle = runtime.PlaylistPathStyle;
pub const max_playlist_entries = database.repository.max_playlist_entries;
pub const max_rating = database.repository.max_rating;
pub const MetadataField = internal.metadata.Field;
pub const isMusicBrainzId = internal.metadata.isMusicBrainzId;
pub const Provenance = internal.metadata.Provenance;

// Tag write-back: a sealed plan, previewed, then approved by its digest.
pub const TagWritePlan = runtime.TagWritePlan;
pub const TagWriteFile = runtime.TagWriteFile;
pub const TagWriteChange = runtime.TagWriteChange;
pub const TagWriteConflict = runtime.TagWriteConflict;
pub const TagWriteSkip = runtime.TagWriteSkip;
pub const TagWriteSkipReason = runtime.TagWriteSkipReason;
pub const TagWriteFailure = runtime.TagWriteFailure;
pub const TagWriteFailureReason = runtime.TagWriteFailureReason;
pub const TagWriteDigest = internal.metadata.mutation.Digest;
pub const PruneSummary = runtime.PruneSummary;

// Playback.
pub const PlayerStatus = runtime.PlayerStatus;
pub const PlayerSnapshot = audio.player.Snapshot;
pub const TransportState = audio.player.TransportState;
pub const RepeatMode = runtime.RepeatMode;
pub const ReplayGainMode = audio.processing.ReplayGainMode;
pub const Equalizer = audio.dsp.Equalizer;
pub const EqualizerPreset = audio.dsp.Preset;
pub const SignalPath = audio.dsp.SignalPath;
pub const SignalPathReason = audio.signal_path.Reason;
pub const PcmFormat = audio.pcm.Format;
pub const SampleFormat = audio.pcm.SampleFormat;
pub const QueueSnapshot = runtime.QueueSnapshot;
pub const QueueStats = runtime.QueueStats;
pub const TrackRef = runtime.TrackRef;

// Outputs.
pub const Device = audio.backend.Device;
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
pub const AnalysisRequest = runtime.AnalysisRequest;
/// Logical processors: the most `AnalysisRequest.threads` that can each have
/// one of their own.
pub const analysisAvailableThreads = internal.library.analysis_pass.availableThreads;
/// What a null `AnalysisRequest.threads` takes: one fewer than
/// `analysisAvailableThreads`, and at least 1.
pub const analysisDefaultThreads = internal.library.analysis_pass.defaultThreads;
pub const DuplicateScanRequest = runtime.DuplicateScanRequest;
pub const ScanStats = runtime.ScanStats;
pub const JobSnapshot = job.Snapshot;
pub const JobKind = job.Kind;
pub const JobState = job.State;

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
