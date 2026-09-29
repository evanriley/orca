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
pub const ArtistQuery = database.ArtistQuery;
pub const ArtistPage = database.ArtistPage;
pub const ArtistSummary = database.ArtistSummary;
pub const ReleaseQuery = database.ReleaseQuery;
pub const ReleaseSort = database.ReleaseSort;
pub const ReleasePage = database.ReleasePage;
pub const ReleaseSummary = database.ReleaseSummary;
pub const HealthIssuePage = database.HealthIssuePage;
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
pub const MetadataField = internal.metadata.Field;
pub const Provenance = internal.metadata.Provenance;

// Tag write-back: a sealed plan, previewed, then approved by its digest.
pub const TagWritePlan = runtime.TagWritePlan;
pub const TagWriteFile = runtime.TagWriteFile;
pub const TagWriteChange = runtime.TagWriteChange;
pub const TagWriteSkip = runtime.TagWriteSkip;
pub const TagWriteSkipReason = runtime.TagWriteSkipReason;
pub const TagWriteDigest = internal.metadata.mutation.Digest;

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
/// The service and account under which a `CredentialStore` holds the user's
/// ListenBrainz token.
pub const listenbrainz_token_service = internal.providers.listenbrainz.token_service;
pub const listenbrainz_token_account = internal.providers.listenbrainz.token_account;

// Jobs.
pub const ScanRequest = runtime.ScanRequest;
pub const BackfillRequest = runtime.BackfillRequest;
pub const AnalysisRequest = runtime.AnalysisRequest;
pub const DuplicateScanRequest = runtime.DuplicateScanRequest;
pub const ScanStats = runtime.ScanStats;
pub const JobSnapshot = job.Snapshot;
pub const JobKind = job.Kind;
pub const JobState = job.State;

// The control lane: commands in, completions and telemetry out.
pub const Action = control.Action;
pub const RequestId = control.RequestId;
pub const Event = control.Event;
pub const Telemetry = control.Telemetry;
pub const Failure = control.Failure;

comptime {
    // Keep exported C symbols reachable when this root builds as liborca.so.
    _ = internal.c_api.orca_runtime_create;
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(internal);
}
