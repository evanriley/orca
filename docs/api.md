# liborca Zig API

The public Zig API is everything declared at the top level of the `liborca`
module (`liborca/root.zig`). `liborca.internal` holds the subsystems behind it
for liborca's own tests and benchmarks; it is not part of the API and changes
without notice.

Non-Zig clients use the C ABI in `liborca/orca.h` instead; see
[frontends.md](frontends.md).

## Embedding

Add Orca to the dependent project's `build.zig.zon`, by URL or by path:

```zig
.dependencies = .{
    .orca = .{ .path = "../orca" },
},
```

Import the module in its `build.zig`:

```zig
const orca = b.dependency("orca", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("liborca", orca.module("liborca"));
```

The module links SQLite, libFLAC, libopusfile, libvorbisfile and libsamplerate
through the host's pkg-config, plus PipeWire on Linux, and compiles in its ALAC,
AAC, MP3 and QOA decoders and Chromaprint. [`examples/embed`](../examples/embed)
is a complete project that does this; `zig build test` builds it, so these steps
stay correct.

## Surface

```zig
const orca = @import("liborca");

var runtime = orca.Runtime.init(allocator);
defer runtime.deinit();
const library = try runtime.openLibrary(io, "library.db");
var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 50, .sort = .title });
defer page.deinit();
```

- `Runtime` owns every library, player, zone and job, and shuts them down in
  dependency order in `deinit`. Its methods are the operations: library
  queries and scans, playback and queue control, outputs, jobs, and the command
  and event lanes.
- Handles (`LibraryHandle`, `PlayerHandle`, `ZoneHandle`, `JobHandle`) are
  generational: a handle to a destroyed object never resolves again.
- Every type a `Runtime` method takes or returns is exported beside it: queries
  and pages (`TrackQuery`, `TrackPage`, `ArtistQuery`, ...), playback state
  (`PlayerStatus`, `RepeatMode`, `ReplayGainMode`, ...), outputs (`Device`,
  `ZoneStats`, ...), jobs (`ScanRequest`, `ReconcileRequest`, `JobSnapshot`,
  `ScanStats`, `QueuedJob`, `JobHistoryEntry`, `JobHistoryFilter`, ...), tag
  write-back (`TagWritePlan`, `TagWriteConflict`, `TagWriteDigest`, ...),
  change history (`TagWriteGroup`, `TagWriteGroupDetail`, `TagWriteDiff`, ...),
  artwork
  (`ArtworkSubject`, `ArtworkResult`), browse loading (`BrowseRequest`,
  `BrowseResult`, `BrowsePayload`, ...), watching (`WatchOptions`,
  `WatchStatus`, `WatchState`), idle maintenance (`MaintenanceOptions`,
  `MaintenanceStatus`, `JobOrigin`, ...) and the control lane (`Action`, `Event`,
  `Telemetry`, `Failure`, `HostWaker`).
- A host's event loop sleeps until liborca has something for it:
  `setWaker(HostWaker)`, called right after `init` and refused with
  `error.WorkersRunning` once a worker thread exists, installs the function
  liborca calls when the loop should pump;
  `pump` executes the submitted commands and publishes finished jobs; and
  `nextPumpTimeoutMs` returns how long the loop may sleep, 0 to pump now or
  null to wait for the waker alone. See
  [control-plane.md](control-plane.md#waking-the-host).
- `libraryWatch(library, WatchOptions)` watches the Library's roots and
  reconciles each directory that changes under one, from `pump`, one
  reconcile at a time and never beside a scan, reconcile, projection or tag
  write of the Library. It
  returns `error.AlreadyWatching` for a Library already watched and
  `error.WatchingUnsupported` off Linux. `libraryUnwatch` stops it, and
  `libraryWatchStatus` returns a `WatchStatus`: its `WatchState` (`off`,
  `watching`, `degraded` or `unsupported`), the roots and directories
  watched, the roots unavailable, the roots degraded by the watch limit,
  whether the watch limit was reached, and whether a reconcile waits or
  runs. `WatchOptions.degraded_rescan_ms` sets how often degraded roots are
  reconciled whole and unavailable roots tried again. A reconcile that
  recorded or marked missing a file publishes `Telemetry.library_changed`,
  and `jobReconcileRoot` names the root a reconcile job walks. See
  [storage.md](storage.md#watching-roots).
- `libraryMaintenance(library, MaintenanceOptions)` turns idle maintenance on
  or off. It is off until enabled. When on, `pump` verifies one Release's
  recording IDs (or at most 20 Tracks on no Release) every
  `interval_ms` while every Player is idle and no other job runs. A
  disagreement lands in Health as `recording_mismatch`.
  `error.InvalidMaintenanceOptions` refuses an interval of 0.
  `libraryMaintenanceStatus` returns a `MaintenanceStatus`: its
  `MaintenanceState` (`off`, `waiting`, `running` or `blocked`), the
  `MaintenanceBlock` (`client_identity_required`, `acoustid_required` or
  `provider_busy`), the time until the next unit, the units run and the
  last one as a `MaintenanceUnit`. `jobOrigin` returns a job's `JobOrigin`
  (`host`, `watcher` or `maintenance`). `startLibraryMatching`,
  `startReleaseCoverArtFetch` and `startAcoustIdSubmission` called while a
  unit runs cancel it and return a `waiting` job, which `pump` starts once
  the unit has finished. See
  [control-plane.md](control-plane.md#idle-maintenance).
- A Library runs one host job at a time. A job started while another holds
  its Library's slot, or while the Library is paused, is returned in state
  `waiting` and started by `pump` in order; at most `max_waiting_jobs` (32)
  wait in the runtime, and the next start returns `error.JobQueueFull`.
  Lyrics, artist info and single-Release info fetches never wait.
  `jobQueuePage(library, allocator)` returns the job holding the slot and the
  waiting ones as `QueuedJob`s, each with the job it waits `after`.
  `pauseJob(job)` holds a running job at its next cancellation poll, keeping
  its thread and any provider lease, and `resumeJob(job)` lets it carry on;
  a projection or tag write returns `error.JobNotPausable`, a finished job
  `error.JobAlreadyFinished`. `pauseAll(library)` pauses the Library's
  running jobs and holds its waiting jobs, watcher reconciles and idle
  maintenance until `resumeAll(library)`; `libraryJobsPaused` reports it.
  `cancelJob` wakes a paused job within one 50 ms poll. `JobSnapshot` adds
  `started_at`, `paused`, `estimated_remaining_ms` (null until 10 s of
  progress, while paused, and without a total), `current_item` and `detail`,
  and `pump` publishes `Telemetry.job_progress` whenever a host job's units or
  state move. `jobHistoryPage(library, allocator, filter, limit, offset)`
  returns finished jobs newest first as `JobHistoryEntry`s, filtered by
  `JobHistoryFilter` (`all`, `scans`, `analysis`, `file_changes` or
  `problems`), and `jobRetry(library, history_id)` starts a failed or
  cancelled one's request again (`error.JobNotRetryable` for one that
  succeeded or was a tag write, `error.UnknownJobHistory` for an unknown id).
  See [control-plane.md](control-plane.md#one-job-per-library-and-the-waiting-queue).
- `jobScanStats` adds `stage` (`ScanStage`: `discover`, `read_tags`,
  `done`), `current_path` (the file a scan or reconcile is reading) and
  `albums_found` (distinct Releases written that still exist).
  `estimateAudioFiles(io,
  allocator, path, token, limit)` counts the audio files under a folder not
  yet added, by their bytes, as a `FolderEstimate` (`audio_files`,
  `truncated` at `limit`, `estimate_default_limit` 100000); it runs on the
  caller's thread and returns `error.Cancelled` once `token`, a
  `CancellationToken`, is cancelled. See
  [storage.md](storage.md#estimating-a-folder-before-it-is-a-root).
- `ScanRequest.reprobe_all` makes a scan read every file's tags and
  properties again, skipping none for an unchanged path and storage identity;
  the C ABI's `orca_scan_options.reprobe_all` is the same flag. See
  [storage.md](storage.md#incremental-scanning).
- A scan or reconcile of a root whose path now lies on another volume than
  the one recorded, as an unmounted drive's mount point does, walks and
  sweeps nothing and ends `failed`. See
  [storage.md](storage.md#volume-check-before-a-walk).
- `libraryRootPage` fills each `LibraryRoot`'s `available` (its directory is
  readable and on the volume it records), `track_count` (Tracks whose
  preferred file is located under it) and `unavailable_tracks` (those with no
  present file, or all of them while the root is unavailable).
  `libraryRelocateRoot(library, io, root_id, path)` moves a root to a new
  path, keeping its id and every file and Track id, binds it to the volume
  that path is on now, rewrites the tag write journal's paths under it, and
  returns the reconcile job it starts. A path that is not a readable
  directory is `error.InvalidLibraryRoot`; one nested with another root, its
  files, or the root's old directory while that still exists
  `error.RootPathOverlaps`; an unknown root `error.UnknownRoot`; a running
  library job `error.LibraryJobRunning`; a held journal lock or an unfinished
  tag write under the root `error.MutationInProgress`; and one under the root
  awaiting reconciliation `error.MutationNeedsReconciliation`.
  `libraryMissingFileCount(library)` counts the Tracks whose preferred file
  has no present location. Each `LibraryRoot` also carries `volume`, the
  label or stable key of the volume it is bound to, and `last_seen_at`, when
  its newest scan completed, else when its volume was last bound.
  `libraryAvailability(library, io)` re-checks every enabled root and returns a
  caller-owned `LibraryAvailability`: the offline roots and the Tracks and
  Releases they leave unable to play (a Release counts when it has a Track
  under an offline root and none with a present file elsewhere). The check
  can block on a hung mount, so a host with a UI calls it off its event loop
  with that thread's own `io`. `libraryReleasesAvailable(library, &availability, ids,
  available)` answers that per Release for one page of ids. See
  [storage.md](storage.md#unavailable-and-relocated-roots).
- `PlayerStatus.last_failure` is the last queue entry that could not be
  opened, as a `PlaybackFailure`: its `track_id` and a
  `PlaybackFailure.Reason` (`file_missing`, `folder_unavailable`,
  `codec_unavailable`, `decode_error`, `unsupported_channels`). It is set
  when a play command cannot open its entry and when the engine steps over
  one, and cleared once an entry opened after it is heard. Opening a Track
  whose root is unavailable fails with `error.TrackFolderUnavailable` and
  marks nothing missing. See
  [audio-engine.md](audio-engine.md#playback-failures).
- `libraryFolderPage(library, root_id, relative_path, limit, offset)` returns
  a `FolderPage` of one folder's children as `FolderEntry` values: its
  subfolders first, each with `file_count`, `track_count` and
  `total_duration_ms` counted through every folder below it, then its files,
  each with its `file_id`, the `track_id` of the Track it is preferred for
  and its duration and `status` (`FolderEntryStatus.imported`, or
  `unreadable` once property backfill could not decode it), then its images,
  each with `mime` and `artwork_role` (`ArtworkRole`: `front`, `back`,
  `booklet` or `other`, from the file name). `FolderEntryKind` is `folder`,
  `file` or `image`. The page carries `image_count`, `last_scanned_at` (Unix
  seconds, null before any scan finished the folder) and `release_id`,
  `release_title` and `release_artist` when every Track in the folder
  belongs to one Release. In the C ABI an image is
  `ORCA_FOLDER_ENTRY_KIND_IMAGE` (2), with no ids and zero counts. The path is
  relative to the root, `""` being the root itself; a path with a `.`, `..`
  or empty component, a leading or trailing `/` or a NUL is
  `error.InvalidFolderPath`, an unknown root `error.UnknownRoot`, and a limit
  outside 1 to 512 `error.InvalidLimit`. Missing files are left out.
  `playerPlayFolder(player, library, io, root_id, relative_path, shuffle)`
  plays every Track below the folder, recursively in path order and at most
  `max_playlist_entries`, after setting shuffle; a folder with none is
  `error.FolderEmpty`. See [database.md](database.md#folder-browsing).
- `playerSetEqualizer` and `playerSetCrossfeed` (and their getters) set a
  Player's ten-band `Equalizer` (or an `EqualizerPreset`) and stereo crossfeed;
  `playerSignalPath` returns a `SignalPath`: the source, ReplayGain (applied
  gain, `ReplayGainSource` and the replaced track gain), DSP, volume
  and output stream, the device's period in frames (`device_quantum_frames`)
  and how it is attached (`output_kind`, a `DeviceKind`), and why the path is
  or is not bit-perfect. `equalizer_band_frequencies_hz` holds the ten bands'
  centre frequencies, in `Equalizer.gains_db` order. `SignalPath` also
  reports the ReplayGain settings (`preamp_db`, `peak_protection`,
  `fallback`) and `peak_limited`, true when peak protection lowered the
  audible entry's correction. `device_format`, a `DeviceFormat`
  (`DeviceSampleFormat`, rate and channels), is the format the output
  device itself runs at, null when it is unknown: suspended, virtual, not
  reported yet, or not on PipeWire. A known integer format adds
  `sample_format_conversion`, and another rate `sample_rate_conversion`;
  null leaves the reasons as they are.
- `playerSetReplayGainMode` takes a `ReplayGainMode`: `off`, `track`, `album`,
  or `smart` (album while a neighbour in playback order shares the Release,
  track otherwise). `playerSetReplayGainPreamp` (dB, clamped to ±15),
  `playerSetReplayGainFallback` (an `UntaggedFallback`: `minus_6_db` or
  `as_is`, the default) and `playerSetPeakProtection` (default on) set the
  rest; `playerReplayGainSettings` reads them back as a `ReplayGainSettings`.
  `playerSetStopAfterCurrent` arms a one-shot stop at the end of the entry
  being heard; `playerStopAfterCurrent` reads it, false again once it fired.
  In the C ABI these are `orca_player_set_replay_gain_preamp`,
  `orca_player_set_replay_gain_fallback`, `orca_player_set_peak_protection`,
  `orca_player_replay_gain_settings`, `orca_player_set_stop_after_current` and
  `orca_player_stop_after_current`, with `ORCA_REPLAY_GAIN_SMART` (3).
- `enumerateOutputDevices` fills `Device` snapshots: id, name, `DeviceKind`
  (`usb`, `pci`, `bluetooth`, `hdmi`, `virtual` or `unknown`) and
  `capabilities`, a `DeviceCapabilities` or null when the audio server did not
  report them within 500 ms. `DeviceCapabilities` holds `rate_min` and
  `rate_max` in Hz, `bit_depths` (the `bit_depth_16`, `bit_depth_24` and
  `bit_depth_32` bits; float32 counts as 32), `channels_max`, a `DeviceState`
  (`active`, `suspended` or `unavailable`) and `bus`, the `DeviceKind`. See
  [audio-engine.md](audio-engine.md) for how PipeWire's answers map onto them.
  Its `detail` parameter, a `DiscoveryDetail`, sets the cost: `.identity`
  fills id, name and kind and leaves `capabilities` null without asking any
  device for its formats; `.capabilities` also waits up to 500 ms for those
  formats. Ask for `.identity` to list or resolve outputs, and for
  `.capabilities` only where they are shown.
- `playerSetParametricEqualizer` sets a Player's `ParametricEqualizer`: up to
  `max_parametric_filters` (16) `ParametricFilter`s, each a
  `ParametricFilterKind` (peak, low or high shelf, low or high pass, notch)
  with a frequency, gain and Q, and a preamp; `validate` states the ranges.
  It and `playerSetEqualizer` are exclusive: turning one on turns the other
  off, so `playerEqualizer` returns null while the parametric equalizer runs,
  and `playerParametricEqualizer` returns null while the ten-band one does.
  An invalid setting is rejected and the previous one kept. `SignalPath`
  carries it as `parametric`. `ParametricEqualizer.response` gives the gain
  in dB at any frequencies for a sample rate, with no Player;
  `parseEqualizerApo` reads EqualizerAPO text (`Preamp:` and `Filter:`
  lines) into one and `writeEqualizerApo` writes one back.
- `libraryTrackDetails` returns `TrackDetails` for one Track: codec, sample
  rate, bit depth, channels, bitrate, duration, file size and path (or that
  the file is missing), loudness when measured, tags, and the MusicBrainz
  recording ID in effect with its `RecordingIdSource` (`tag`, `match` or
  `edit`), track and disc totals with `track_total_inferred` when the track
  total was counted rather than stated, the `Explicit` advisory, `added_at`
  and `modified_at`, the first five `genres`, and the `composer` and
  `comment`: a locked edit, else the file's tag, else an unlocked edit, and
  null when none states one. The caller frees it with `deinit`.
- Genres are browsable: `libraryGenrePage` takes a `GenreQuery` (a filter,
  `GenreSort.name` or `track_count`) and returns a `GenrePage` of
  `GenreSummary`s with Track, Release and Artist counts and total duration;
  `libraryGenreCount` and `libraryGenre` count and fetch them.
  `libraryTrackGenres` returns a Track's `GenreNames` in order with their
  `Provenance`; `libraryReleaseGenres` and `libraryArtistGenres` return
  `GenreCounts`, most Tracks first; `libraryGenreArtwork` returns the
  `ReleaseIds` of a genre's most played Releases that have a cover, as
  `ReleaseQuery.has_artwork` defines one. `TrackQuery`,
  `ReleaseQuery` and `ArtistQuery` take a `genre_id`, and `ArtistQuery` an
  `ArtistSort` (`name`, `track_count`, `recently_loved` or `recently_added`,
  the Artist whose newest Release, filed under them or appeared on, came
  latest). `librarySetTrackGenres` gives
  Tracks up to `max_track_genres` (16) user genres, which outrank their files'
  tags until cleared with no names, splitting a name that lists several
  (`Rock, Pop`); it writes no file itself and returns `error.TooManyGenres`,
  `error.InvalidGenre` for a blank name, or `error.TrackNotFound`. See
  [database.md](database.md#genres).
- `libraryEditTracks` returns `EditedTracks`: the Tracks the edited files
  back afterwards. An edit that moves a track to another album or a free
  position keeps its id; one that moves it onto a position another Track
  holds takes that Track's id.
- `libraryTrackFieldStates` returns `TrackFieldStates` for up to 512 Tracks:
  per `EditableTrackField` the value they share, whether they are `mixed`, and
  whether Orca's value is `edited` (differs from a file's tag), the disc
  total they share, and the first Track's `TrackFieldCover` (`chosen`,
  `embedded`, `folder` or `fetched`, in that order of preference) with how
  many of them show the same one. It reads the
  database only. The caller frees it with `deinit`.
- `planTagWrite` returns a `TagWritePlan`: each file's `TagWriteChange`s with
  the `Provenance` of Orca's value, its `TagWriteFormat` (Vorbis comments or
  ID3v2) and `key` for a field's tag name, its `TagWriteGenres` when the user's
  genres replace the file's, the `TagWriteConflict`s it leaves out
  because an unlocked value disagrees with the file's tag, and the files it
  skips. `tagWriteGenres` returns one file's `TagWriteGenres` from a held
  plan, for the C ABI, which reads them beside the plan's view.
  `isMusicBrainzId` is the check `libraryEditTracks` applies to a
  recording ID, for a client to validate input before saving.
- `libraryTagWriteGroupPage(library, allocator, limit, offset)` returns a
  `TagWriteGroupPage` of finished tag writes, newest first: each
  `TagWriteGroup`'s files, `TagWriteGroupState`, `can_undo` and `expired`.
  `libraryTagWriteGroup(library, allocator, io, group_id)` returns a
  `TagWriteGroupDetail`: one `TagWriteDiff` per changed tag of each file,
  what an undo restores beside the file's value now, at most 512 rows, with
  `more_files` and `field_count`. Both only read; see
  [metadata.md](metadata.md#change-history).
  `exportTagWriteHistory(library, io, path, TagWriteHistoryExportOptions)`
  writes every group's `orca-cli changes` line to a file atomically and
  returns a `TagWriteHistoryExport` with the count; it refuses an existing
  file unless `replace` is set.
- The queue can be edited in place: `playerQueueJump` plays an entry now,
  `playerQueueInsertNext` queues Tracks after the current one,
  `playerQueueRemove` removes an entry, and `playerQueueMove(player, from,
  to)` moves the entry at playback position `from` to `to`. The entry
  playing, and one the engine has already lined up after it, are refused
  with `error.QueueEntryInUse`, and so is a move that would land between
  them. Under shuffle a move changes only the shuffled order, so turning
  shuffle off restores list order.
- `playerQueueHistory(player, offset, output)` fills `output` with
  `QueueHistoryEntry` values, newest first: the Track, `ended_at_ms` and a
  `QueueHistoryReason` (`finished`, `skipped`, `replaced`).
  `playerQueueHistoryTracks(player, allocator, offset, limit)` returns them
  as a `TrackPage`, and `playerClearQueueHistory` empties it. The history
  holds `queue_history_capacity` (100) entries in memory only and never
  records a listen. See [audio-engine.md](audio-engine.md#queue-history).
- `playerSaveQueueAsPlaylist(player, library, name)` saves the current
  entry and those after it as a new playlist and returns its id; see
  [playlists.md](playlists.md#playlists).
- Health can be shown grouped by kind: `libraryHealthSummary` returns a
  `HealthSummary` of `HealthKindSummary`s, each kind's count, highest
  severity, `files` and `bytes`, and `libraryHealthIssuePageOfKind` pages
  one kind's issues. For `exact_duplicate` and `likely_duplicate`, `bytes`
  is what removing the redundant copies would free. See
  [analysis.md](analysis.md#by-kind).
- Duplicates are shown as groups. `libraryDuplicateGroupPage(library,
  allocator, limit, offset)` returns a `DuplicateGroupPage` of
  `DuplicateGroup`s, each named by its lowest file id, and
  `libraryDuplicateGroupTotals` a `DuplicateGroupTotals`.
  `libraryDuplicateGroup(library, allocator, id)` returns a
  `DuplicateCopyList` of `DuplicateCopy`s, the suggested copy first, each
  with its `TrackDetails`. `libraryKeepBoth(library, file_id,
  other_file_id)` and `libraryIgnoreDuplicateGroup(library, id)` dismiss
  duplicate issues; `libraryMergeDuplicateMetadata(library, keep_track_id,
  from_track_id)` copies what one Track has and the other lacks and returns
  a `DuplicateMerge`. `libraryDuplicateCopyPlaylists(library, allocator,
  file_id)` names, caller-owned, up to 512 playlists holding a copy's
  recording. No file is written. The C ABI mirrors them as
  `orca_library_query_duplicate_groups`,
  `orca_library_duplicate_group_totals`,
  `orca_library_query_duplicate_group`, `orca_library_keep_both_duplicates`,
  `orca_library_ignore_duplicate_group`,
  `orca_library_merge_duplicate_metadata` and
  `orca_library_duplicate_copy_playlists`. See
  [analysis.md](analysis.md#groups).
- `libraryStats(library)` returns `LibraryStats`: the Artist, Release and
  Track counts the unfiltered listings show, the files with a location that
  is not missing and their bytes, the Tracks' summed `total_duration_ms`,
  `last_scan_finished_at` and `last_analysis_at` in Unix seconds, null
  before the first completed scan or measurement, `last_duplicate_scan_at`,
  null until a host's duplicate scan succeeds, and `listens`, the local play
  history's count. See [database.md](database.md#library-stats).
- `libraryCacheSize(library)` returns a `CacheSize`: the bytes of fetched
  Cover Art Archive covers (`artwork_bytes`), artist and related artist
  photos (`photo_bytes`), LRCLIB lyrics (`lyrics_bytes`) and artist and
  release info (`info_bytes`). `libraryClearCache(library)` deletes all of
  it, which is fetched again when next wanted, and returns what it held.
  Embedded and folder artwork and local lyrics are never touched. See
  [database.md](database.md#fetched-cache).
- `providerSources()` returns the `ProviderSource`s Orca takes data from, one
  per `ProviderSourceId` in its order: each one's `name`, `url`, what it
  `supplies`, its `licence`, and a `licence_url`, null when the licence has
  no single page. The list is fixed and needs no Library, so a frontend's
  credits read it rather than keeping their own. See
  [providers.md](providers.md).
- `supported_formats` lists the `SupportedFormat`s Orca reads, each a `name`
  and `planned`, true for a format recognized but not yet decoded. It is a
  constant, so an About page and `orca-cli formats` read it rather than
  keeping their own list.
- `TrackSummary` carries `release_id` and `artist_id`, so a host can link a
  Track to its Release and Artist without a second query, and the facts a
  song list shows: the playing file's `codec`, `sample_rate`, `bit_depth` and
  `lossy`, `added_at`, the recording's `play_count` and `last_played_at`,
  `explicit` (`Explicit`: `unknown`, `none`, `explicit`, `clean`),
  `track_total`, `disc_total`, `year`, `integrated_lufs`, `bitrate_kbps`,
  `path` and `album_artist_id`. `integrated_lufs` is the integrated loudness
  of the playing file's current default analysis (null before one, or when
  the file is too short or silent to measure); `bitrate_kbps` is the file's
  average bitrate, size over duration rounded to the nearest kbps, lossless
  or not (null when either is unknown or zero); `path` is the file's location
  that is not missing, present before unverified, empty when there is none,
  and is owned by the summary like the strings; `album_artist_id` is the
  Release's album artist. `TrackSort` appends `play_count`, `last_played`,
  `year`, `loudness`, `bitrate`, `path`, `album_artist` (the Track's album
  artist, then album and position, as `artist` does) and `genre` (the name of
  the Track's first genre, case-insensitively, then that genre's id); a Track
  with no value for the sort sorts last either way. Smart playlist rules
  accept the same names as `sort.field`. `ReleaseSummary.explicit` is
  explicit when any of its Tracks is.
- `ReleaseSummary` carries the facts an album grid shows, read from the files
  its Tracks play: `codec` (`mixed_codec` when they differ, empty when none
  was probed), `max_sample_rate`, `max_bit_depth`, `lossless` (every Track
  plays a lossless file), `release_type`, and `pending_reviews`, the Tracks
  with a pending match outside an album group plus the album groups with a
  pending correction. `ReleaseQuery` filters by `high_resolution_only` (a
  file above 48 kHz or 16 bits, as `ReleaseSummary.isHighResolution`),
  `needs_review_only`, `lossless_only`, `year_min` and `year_max` (inclusive;
  undated Releases are left out) and `has_artwork`, a cover embedded in a
  Track's file, fetched from the Cover Art Archive, or a front image in the
  Release's folder, as `releases.has_folder_cover` records it
  ([database.md](database.md#folder-browsing)). `ReleaseSort.most_played` orders by the listens of
  the Tracks' recordings. `ReleaseQuery.added_after` (Unix seconds) keeps
  the Releases whose Tracks' play files were all first seen after it, so a
  Release that only gained a Track is not newly added.
- `ReleaseQuery.name_order` (`NameOrder`) sets how `ReleaseSort.artist`
  reads the album artist: `ignore_articles`, the default, files "The Low
  Tides" under L by skipping a leading "The ", "A " or "An "; `as_written`
  does not. `ArtistQuery.name_order` does the same for `ArtistSort.name`
  and `ArtistSort.track_count`: `ignore_articles` orders by the stored sort
  key, `as_written` by the name itself. `ReleaseSort.title` and
  `ReleaseSort.artist` put names that do not start with an ASCII letter
  first, so each initial is one run.
- `libraryReleaseLetterIndex` returns a caller-owned `[]LetterBucket` for a
  `ReleaseQuery` sorted by `title` or `artist` (`error.SortHasNoLetters`
  otherwise): one bucket per initial present, in sort order, each with its
  `letter` (uppercase, or `'#'` for every name that does not start with an
  ASCII letter), `count` and `first_offset`, the `offset` at which that
  query's pages reach the bucket's first Release. The query's `limit` and
  `offset` are ignored, and the counts sum to `libraryReleaseCountMatching`.
- `libraryReleaseQueryTotals` returns `ReleaseTotals` for a `ReleaseQuery`:
  `count`, the Releases it lists; `artists`, their distinct album artists;
  and `bytes`, the size of the files their Tracks play.
- `release_type` is the lowercased primary type ("album", "ep", "single",
  "compilation", ...) the files' `RELEASETYPE` / `MusicBrainz Album Type`
  tags state, else the MusicBrainz release group's primary type, which a
  release-info fetch or genre fill writes only while the Release has none.
  `ReleaseQuery.release_kind` (`ReleaseKind`: `album`, `ep_or_single`,
  `other`) filters by it; a Release with no type counts as an `album`, as do
  compilations. `ReleaseQuery.appearing_artist_id` keeps the Releases with a
  Track credited to that Artist that are not filed under them as album
  artist. `ReleaseQuery.own_releases_only`, with `album_artist_id` set,
  narrows that filter to the Releases filed under the Artist as album
  artist, leaving out those they only appear on; without `album_artist_id`
  it does nothing. All combine with every other filter and sort.
- `libraryArtistTotals` returns an Artist's `ArtistTotals`, or null for an
  unknown Artist: `release_count`, the Releases `own_releases_only` lists,
  `track_count` as `ArtistSummary` counts it, `duration_ms` summed over
  the Tracks `TrackQuery.artist_id` lists (an unknown duration adds 0), and
  `appearance_count`, the Releases `appearing_artist_id` lists.
- `TrackQuery` filters by `year_min` and `year_max` (inclusive, read from the
  Release's date as `TrackSort.year` reads it; undated Tracks are left out),
  `lossless` (`true` for a lossless play file, `false` for a lossy one, a
  Track with no probed codec matching neither), `min_sample_rate` and
  `explicit_only` (`Explicit.explicit`), and by the play file's
  `max_sample_rate`, `codec` (the lowercase codec id, compared without
  case) and `added_after` (first seen after that Unix time). Every filter
  combines with AND, `libraryTrackMatchCount` counts what the page lists,
  and `libraryTrackQueryTotals` takes the same search text and returns its
  `TrackTotals`: `count` and `duration_ms` (an unknown duration adds 0).
  `libraryTrackQueryPlayableIds` returns the ids of the Tracks with a playable
  file among `limit` rows from `offset` of the same listing, in its order, up
  to `max_track_id_window` (10,000, at least `playback_queue_capacity`) rows,
  so a host can queue a listing from any row without paging through it. A text search in
  `libraryTrackQuery` keeps every filter of the query and orders the matches
  by relevance, so its `sort` and `direction` do not apply;
  `libraryTrackMatchCount` does not count a search. Each word of its text must begin a word of the Track's title,
  artist, album or album artist, no character is FTS5 syntax, and text with
  no word matches nothing.
- `librarySearch` finds Artists, Releases, Tracks, Playlists and genres in
  one call and returns `SearchResults`: `SearchHit`s grouped in that
  `SearchKind` order, each kind most relevant first (lower `rank` is
  better: for a Track 0 when every word is whole in the title, 1 when every
  word begins a title word, 2 otherwise, ties by id; bm25 for other kinds)
  and capped by `SearchLimits` (default 5, 5, 8, 4, 3; above
  `max_search_hits_per_kind`, 50, is `error.InvalidSearchLimits`). Each
  word of the text must begin a word of the hit's title or subtitle,
  ignoring case and diacritics; quotes, operators and column filters are
  matched as text. Text longer than `max_search_text` (256 bytes) is
  `error.SearchTextTooLong`. Each hit carries what a result row shows:
  an Artist its `release_count` and `track_count` (as `ArtistSummary`
  counts them), a Release its `year`, `artist` and `track_count`, a Track
  its `artist` and `duration_ms`, a manual Playlist its `track_count`
  (entries) and `duration_ms` (a smart Playlist 0 and null), a genre its
  `track_count`. A hit's `reason` is `name` when its text matched. The
  first Artist hit adds reason hits after the `name` hits of their kind,
  within the kind's cap and never repeating a hit: the Playlists holding
  its Tracks (`tracks_by`, `reason_count` the entries that are its,
  most first, then by id) and the genre most of its Tracks carry
  (`main_genre_of`, `reason_count` those Tracks, ties by name), each with
  `rank` 0. `SearchResults.top` is the hit to feature: among the `name`
  hits, the first in `hits` order whose title holds every word of the text
  as a whole word, else the first `name` hit, else null; a reason hit is
  never top. It is a copy of that element of `hits`, sharing its text, and
  is not freed separately. `ReleaseQuery.text` keeps the Releases the
  same search finds, under every filter and sort, and
  `libraryReleaseCountMatching` counts them.
- Cover art is read either on the caller's thread (`libraryTrackArtwork`,
  `libraryReleaseArtwork`) or off it. Both return the front cover a person
  chose first, then the front cover embedded in a file, then a front image (`folder_images` role `front`) in the
  folder holding most of the Release's Tracks, ties to the lowest path,
  preferring the stems `cover`, `front` and `folder` in that order, then the
  largest; then the cover the Cover Art Archive fetch kept. The folder image
  is read from disk on every call, bounded like embedded art and sniffed
  again, so a replaced file shows once a scan records it, and a missing,
  unreadable or no longer image file falls through to the archive's cover.
  Off the caller's thread, `libraryRequestArtwork` queues a lookup
  on the Library's artwork loader, at most 64 outstanding, and
  `libraryTakeArtwork` collects finished ones. `libraryCancelArtwork` skips a
  request that has not started. `ArtworkSubject.artist` asks the loader for
  the photo the Artist's artist info stores, with no image when none is.
  `ArtworkSubject.release_group`, a lowercase MusicBrainz release group ID
  as `[36]u8`, asks for the cover an Artist fetch kept for the group, with
  no image when none is; the loader makes no request. The C ABI has no
  such subject yet. `startReleaseCoverArtFetch` sends no request for a
  Release with a chosen, an embedded or a folder cover and reports
  `chosen`, `embedded` or `folder` as its `CoverArtOutcome`; the other
  outcomes are listed in [providers.md](providers.md#cover-art-archive).
- A Release keeps at most one cover of each `ReleaseArtworkKind` (`front`,
  `back`, `booklet`) in the Library, fetched or chosen. Media files are never
  written. `librarySetReleaseArtwork` keeps image bytes a person chose; the
  MIME type must be what the bytes sniff as, and an image over
  `max_image_bytes` is `error.ArtworkTooLarge`. `libraryClearReleaseArtwork`
  forgets the kept cover of a kind, returning false when none was kept, and
  `libraryStoredReleaseArtwork` reads it without looking at files or
  folders. `startCoverArtCandidates` is a Job that lists the Cover Art
  Archive's images for a Release: its release's index, then the index of
  its release group when its files name exactly one, deduplicated by
  image ID and capped at `max_cover_art_candidates` (8). Each candidate's
  full image is fetched through the Gateway to measure its size and then
  dropped; only its 250-pixel thumbnail is kept. A candidate whose full
  image would not come keeps a null size, and `MatchStats` counts it in
  `cover_art_candidates_unmeasured`; `cover_art_candidates` and
  `cover_art_candidates_examined` give the Job's progress in candidates.
  When the release group's index will not come after the release's was
  read, the release's own candidates are stored and the Job succeeds with
  `CoverArtOutcome.partial`. `libraryCoverArtCandidates` reads the stored list as
  `CoverArtCandidate`s, fronts first, then the release group's fronts,
  backs, booklets and the rest (`CoverArtCandidateKind`).
  `libraryUseCoverArtCandidate` fetches a listed candidate's full image
  again and keeps it as the cover of the kind asked for; a candidate the
  Release does not list is `error.UnknownCoverArtCandidate`, and an image
  the archive no longer holds fails the Job with `not_found`. A successful
  use reports `fetched`; the cover it keeps is `chosen`.
- The `artwork_problem` health issue names what is wrong with a file's front
  cover, in the order checked: `missing_front` (no chosen, embedded, folder
  or fetched front), `conflicting` (the file's embedded cover and its
  folder's front image differ by content hash), `undersized` (the front in
  effect, chosen before embedded before folder before fetched, is under
  `minimum_cover_pixels`, 500, on a side). A size or hash never measured,
  or a kept cover whose header would not read, raises nothing.
  `libraryArtworkProblem` reads an issue's details as an
  `ArtworkFinding`: its `ArtworkProblem` and, for `undersized`, the width
  and height; it is null for any other kind of issue.
- `libraryBackfillPending` takes a `LibraryAvailability` and returns a
  `BackfillPending`: the `files` that declare no duration, sample rate,
  channels or codec and the `covers` not yet measured, less what
  `startLibraryPropertyBackfill` cannot repair now. It leaves out files that
  are missing, on an offline root, in a format no codec decodes, or already
  found unreadable with the bytes they have, and covers of missing files or
  on an offline root. The Job still examines those. A host starts it when
  either count is non-zero, outside a scan.
- Track and Release listings can also be read off the caller's thread:
  `libraryRequestBrowse` queues a `BrowseRequest` on the Library's browse
  loader and returns its id, `libraryTakeBrowse` collects a finished
  `BrowseResult`, and `libraryCancelBrowse` skips a request that has not
  started and drops the result of one still running; a finished one still
  arrives. A request is a `track_page` or `track_totals`
  (`BrowseTrackListing`: the search text and `TrackQuery` that
  `libraryTrackQuery` and `libraryTrackQueryTotals` take), or a
  `release_page` or `release_count` (the `ReleaseQuery` that
  `libraryReleasePage` and `libraryReleaseCountMatching` take), and its
  result is what that method would return, or its error, in
  `BrowseResult.payload`. The request's text and codec are copied, so the
  caller's buffers may change once it returns; search text over
  `max_search_text` is `error.SearchTextTooLong` and a codec over 32 bytes
  `error.CodecNameTooLong`. At most 8 requests are outstanding, queued,
  running or finished and not taken; another is `error.BrowseQueueFull`.
  Results come in request order, and `BrowseResult.deinit` frees a page,
  which is allocated with the Runtime's allocator. The loader reads on its
  own read-only connection, so a result can predate a write the host has
  just made; the host reloads on `library_changed` as it would after a
  synchronous read. Destroying any Library joins every Library's browse
  loader, as it does the artwork loaders, and drops their requests and
  untaken results; a loader starts again on its Library's next request.
- `ArtistSummary.has_photo` says whether an Artist's artist info stores a
  photo, and `ArtistSummary.cover_release_id` names the Release to show in
  its place: the first the Artist's `ReleaseQuery` lists with
  `own_releases_only` and `ReleaseSort.artist`, else the first it lists
  without `own_releases_only`, null when the Artist has no Release.
- Lyrics are read on a job: `startTrackLyrics` starts one for a Track, and
  with `LyricsOptions.fetch` also asks LRCLIB, which needs the client
  identity and can be pointed at another server with `setLrclibServer`.
  `jobLyricsOutcome` reports a `LyricsOutcome` once it finishes: `local`,
  `fetched`, `cached` (LRCLIB's earlier answer to the same query),
  `cached_miss`, `not_found` or `no_metadata` (no title or artist to ask
  with). `jobTakeLyrics` moves the `Lyrics` to the caller once, and
  `Lyrics.lineAt` gives the synced line at a playback position;
  `Lyrics.source_name` (the sidecar's file name, `embedded` or `LRCLIB`) and
  `Lyrics.offset_ms` (the `[offset:]` tag, already applied to line starts)
  describe where it came from. See
  [metadata.md](metadata.md#lyrics) and [providers.md](providers.md#lrclib).
- Playback is recorded as local listening history. `processNextCommand`
  samples every Player bound to a Library at most every 100 ms; a play heard
  for half its length or four minutes (tracks of 30 s or more) is recorded on
  that Library's listen worker, credited to the Track the audible entry
  serial names. `libraryTrackPlayStats` and `TrackDetails` report the play
  count and last play of the Track's recording, through any of its files; a
  file that moves to another recording takes its plays along.
- `librarySetListenPolicy(library, ListenPolicy)` chooses how long a play
  must be heard to be kept: `half_or_four_minutes` (the default and
  ListenBrainz's rule), `thirty_seconds` or `full_track`;
  `libraryListenPolicy` reads it. A listen kept under another policy that
  falls short of ListenBrainz's rule is never sent.
  `librarySetListenRecording(library, false)` keeps no listens;
  `libraryListenRecording` reads it. `libraryClearListens(library)` deletes
  the history, the listens waiting to be sent and the play counts, returns
  how many listens went, and keeps ratings and loves. See
  [providers.md](providers.md#listens).
- `librarySetScrobbling` also sends a Library's listens to ListenBrainz, for
  at most one Library per runtime. The token comes from the `CredentialStore`
  given to `setCredentialStore`; `libraryScrobblerCredentialsChanged` has it
  validated once, and `libraryScrobblerStatus` returns a `ScrobblerStatus`.
  `setClientIdentity` names the host to every provider and in the listen
  history; see [Client identity](#client-identity).
  `setListenBrainzServer` points them at a compatible server: `https`, or
  `http` only to `127.0.0.1`, `[::1]` or `localhost`, and
  `error.InvalidServerUrl` otherwise. The three setters may be called at any
  time; each listen worker adopts the new values on its next pass.
  `listenbrainz_token_service` and `listenbrainz_token_account` name the
  secret a `CredentialStore` is asked for. See [providers.md](providers.md).
- `librarySetScrobbling(library, enabled, offline, now_playing)`: the last
  argument also announces the playing track to ListenBrainz, once per track
  heard for 10 s and never retried.
- `librarySetFeedback(library, track_ids, Feedback)` loves, hates or clears
  the song behind each Track and returns a `FeedbackChange` counting the
  Tracks changed and the ones skipped for having no Recording;
  `libraryTrackFeedback` reads one. `Feedback` is `none`, `loved` or `hated`.
  It belongs to the Recording, so it shows on every Track and file of the song
  as `TrackSummary.feedback` and `TrackDetails.feedback`; `TrackSummary.recording_id`
  names the song, so a host can repaint every row of it without a query. It is sent to
  ListenBrainz while the Library scrobbles when the song has a MusicBrainz
  recording id (`TrackDetails.feedback_syncable`). `ScrobblerStatus` reports
  the changes still waiting as `feedback_pending`, and the end of a
  ListenBrainz block the Library records as `blocked_until`.
- `librarySetReleaseLove(library, release_ids, loved)` loves or clears each
  Release and returns a `ReleaseLoveChange` counting the Releases changed and
  the ids that name no Release. It is kept in the Library only: it changes no
  song's feedback and is never sent to ListenBrainz. It shows as
  `ReleaseSummary.loved`; `ReleaseQuery.loved_only` lists only loved
  Releases and `ReleaseSort.loved` orders the most recently loved first.
  `TrackQuery.loved_only` lists only Tracks whose song is loved, and
  `TrackSort.loved` orders them most recently loved first, the rest last.
- `librarySetArtistLove(library, artist_ids, loved)` loves or clears each
  Artist and returns an `ArtistLoveChange` counting the Artists changed and
  the ids that name no Artist; `libraryArtistLoved` reads one. Like album
  love it is kept in the Library only and never sent. It shows as
  `ArtistSummary.loved`; `ArtistQuery.loved_only` lists only loved Artists
  and `ArtistSort.recently_loved` orders the most recently loved first.
  `ArtistQuery.role` (`ArtistRole.all`, or `album_artists` for only the
  Artists a Release is filed under) applies to the page and to
  `libraryArtistCountMatching` alike.
- `startArtistInfoFetch(library, artist_id, ArtistInfoOptions)` starts an
  `artist_info` Job that gathers an Artist's photo, biography, years active
  and links from a local image, MusicBrainz, Wikidata, Wikimedia Commons and
  Wikipedia, its listeners and related artists from ListenBrainz, and fills
  genres from MusicBrainz. `ArtistInfoOptions` holds the biography's
  `language` (default `en`, falling back to English), `force`, `offline`
  and `include_releases`, which also fetches each of the Artist's Releases'
  release info. It returns
  `error.ClientIdentityRequired`, `error.UnknownArtist` or
  `error.InvalidLanguage`. `jobArtistInfoOutcome` returns its
  `ArtistInfoOutcome` (`error.NotAnArtistInfoJob` for another kind).
  `libraryArtistInfo` returns the stored `ArtistInfo`, whose
  `ArtistInfoRecord` holds the years active, type, IDs, biography with its
  `ArtistBiographySource`, URL, licence and language, the
  `requested_language` the fetch asked for, the photo's
  `ArtistPhotoSource`, page, licence and credit, `fetched_at` and the
  outcome; null when nothing was stored. `libraryArtistPhoto` returns the
  photo as an `EmbeddedImage`, and `libraryArtistLinks` the `ArtistLinks`,
  each an `ArtistLink` with its `ArtistLinkKind`, by kind and URL.
  `ArtistInfoRecord.listeners` is ListenBrainz's listener count, and
  `libraryRelatedArtists` returns the `RelatedArtists`, at most
  `related_artists_max` `RelatedArtist`s with name, MusicBrainz ID, score
  and the matching library Artist's id, if any, and `has_photo`: the
  library Artist's photo for a matched one, else a kept related artist
  photo. An Artist fetch also keeps photos for related artists outside the
  Library, by MusicBrainz artist ID, for at most
  `artist_info.related_photos_per_fetch` (8) of them per fetch: those with
  no kept photo or marker, or one older than `refresh_after_s` (30 days),
  or with `force` any. `libraryRelatedArtistPhoto(library, mbid)` returns
  that photo as an `EmbeddedImage`, or null when none is kept; the ID is
  matched without case. `libraryRelatedArtistPhotoInfo(library, mbid)`
  returns its attribution as a `RelatedArtistPhotoInfo` whose
  `RelatedArtistPhotoRecord` holds `source` (always `.commons`), `url` (the
  Commons page), `licence`, `licence_url`, `credit` and `fetched_at`, or
  null when no photo is kept; free it with `deinit`.
  `ArtistInfoRecord.origin` is MusicBrainz's begin area, else its area,
  named with the subdivision it lies in (`Portland, Oregon`), else the
  country, found through at most 3 MusicBrainz area lookups; the name alone
  when the area is a subdivision or country, or none is found.
  `libraryArtistElsewhere(library, allocator, artist_id)` returns the
  Artist's stored MusicBrainz release groups that the Library does not
  hold, newest first, as caller-owned `ElsewhereRelease`s (free each with
  `deinit`, then the slice): `mbid`, `title`, `primary_type`, `year`,
  `credited_with`, the credit's other artists as MusicBrainz joins them, and
  `cover`, a `ReleaseGroupCoverState`: `kept`, `none` (the Cover Art Archive
  has none) or `not_fetched`. An Artist fetch asks the archive for the
  covers of the first `artist_info.release_group_covers_per_fetch` (24)
  groups listed, except with `offline`; request a kept one through
  `libraryRequestArtwork` with `.{ .release_group = mbid }`. A
  group is held when its release-group MBID, without case, is in the
  `release_info`, file tags or Orca values of a Release filed under the
  Artist or one they appear on, so `library_release_id` is always null here.
- `startReleaseInfoFetch(library, release_id, ReleaseInfoOptions)` starts a
  `release_info` Job that keeps a Release's Wikipedia description, found
  through its MusicBrainz release group and Wikidata, and fills genres from
  the release group. `ReleaseInfoOptions` holds `language`, `force` and
  `offline`; it returns `error.ClientIdentityRequired`,
  `error.UnknownRelease` or `error.InvalidLanguage`.
  `jobReleaseInfoOutcome` returns its `ReleaseInfoOutcome`
  (`error.NotAReleaseInfoJob` for another kind), and `libraryReleaseInfo`
  the stored `ReleaseInfo`, whose `ReleaseInfoRecord` holds the
  description with its `ReleaseDescriptionSource`, URL, licence and
  language, the MusicBrainz release and release group IDs, `fetched_at` and
  the outcome; null when nothing was stored.
- `setGenreFill(library, GenreFill)` turns automatic genre fill from
  MusicBrainz on or off for the Library (on by default), and
  `libraryGenreFill` reads it. `startGenreFill(library, GenreFillOptions)`
  starts a `release_info` Job that fills the genres of up to `limit`
  Releases with a Track without genres, whatever the setting
  (`error.InvalidLimit` outside 1 to 512). Such genres are shown with
  `musicbrainz_genre_licence`. `setListenBrainzLabsServer` selects another
  ListenBrainz Labs server. See [providers.md](providers.md#release-info).
  `setWikidataServer`, `setWikimediaCommonsServer` and `setWikipediaServer`
  select other servers under the same rules as `setListenBrainzServer`, from
  the next job; a null Wikipedia server asks each language's own wiki. See
  [providers.md](providers.md#artist-info).
- `librarySetRating(library, track_ids, ?u8)` rates the song behind each
  Track from 1 to 100, or clears it, and returns a `RatingChange`; it shows as
  `TrackSummary.rating` and `TrackDetails.rating`. Playlists are
  `libraryPlaylists`, `libraryCreatePlaylist`, `libraryRenamePlaylist`,
  `libraryDeletePlaylist`, `libraryPlaylistEntries`, `libraryPlaylistInsert`,
  `libraryPlaylistRemove` and `libraryPlaylistMove`, with
  `playerPlayPlaylist` to play one and `libraryImportPlaylist` and
  `libraryExportPlaylist` for M3U files. See [playlists.md](playlists.md).
  `libraryPlaylistPage(library, PlaylistQuery)` returns at most 512
  `PlaylistSummary`s, filtered by name, `PlaylistKind`, pin and
  `PlaylistCreator` and ordered by `PlaylistSort`; `libraryPlaylistCount`
  counts the same query and `libraryPlaylist` returns one summary, with its
  description, pin, love, tags, whether its entries name several Artists and
  its three most common genres; `PlaylistSummary.artist_count` counts the
  distinct Artists. `libraryPlaylistFormats(library, allocator, id)` returns a
  `PlaylistFormats`: up to 32 `CodecCount`s, the available entries per codec
  id, most used first, and how many entries are `analyzed` (a loudness
  measurement for their file's current bytes) or `unanalyzed`; the caller
  frees it with `deinit(allocator)`. `libraryUpdatePlaylist(library, id,
  PlaylistUpdate)` sets the description, pin, love or tags (at most
  `max_playlist_tags`); `libraryPlaylistTags` returns the tags alone.
  `libraryCreateSmartPlaylist(library, name, rules_json)` creates a smart
  playlist, `librarySetSmartPlaylistRules` replaces its rules and
  `librarySmartPlaylistRules` returns them as stored, or null for a manual
  playlist. `librarySmartPlaylistCount(library, rules_json)` counts the Tracks
  rules match now without storing anything.
  `librarySmartPlaylistPreview(library, allocator, rules_json, sample_limit)`
  returns a `SmartPlaylistPreview` from one evaluation: the count, the total
  `duration_ms` and the first `sample_limit` (at most 512,
  `error.PageOutOfRange` beyond) Tracks in the rules' order. Rules are at most
  `max_smart_playlist_rules_bytes`, in the format under
  [Smart playlist rules](#smart-playlist-rules).
- `startLibraryMatching(library, MatchRequest)` starts a `metadata_lookup`
  Job that searches MusicBrainz, and AcoustID by fingerprint, for the Tracks
  without a recording ID and stores proposals; its snapshot's total is the
  number of Tracks to search, and `jobMatchStats` reports its counters as
  `MatchStats`, `matched` included while it runs, whether AcoustID took
  part as `AcoustIdUse`, and, as `BusyService`, the service another Orca
  process held when the job failed for it. `MatchRequest.fingerprints`
  (default true) includes AcoustID when an application key is set. `MatchRequest.track_id` searches
  that Track alone, under the same rule: one already identified, or already
  answered for by every service in scope, is not searched, and the job
  succeeds with a total of 0. At most one runs per runtime
  (`error.MatchingAlreadyRunning`), and none while an AcoustID submission
  runs (`error.AcoustIdBusy`).
  `libraryMatchReviewPage(library, limit, offset)` returns a
  `MatchReviewPage` of at most 512 `MatchReviewItem`s: the Tracks with a
  pending proposal, by artist, album and position, each with its own title,
  artist, album and length, its number of proposals and its best one.
  `libraryMatchReviewCount` counts them, `libraryUnidentifiedCount` counts the
  Tracks a matching job would search, and
  `libraryConfidentMatchCount(library, minimum)` is the number
  `libraryAcceptConfidentMatches` would accept now.
  `libraryMatchProposals(library, track_id, limit)` returns a
  `MatchProposalPage` of the Track's pending `MatchProposal`s, each with its
  `provider` (`musicbrainz`, `acoustid` or `musicbrainz+acoustid`) and
  `acoustid_score`; `libraryAcceptMatch` accepts one and returns a
  `MatchAcceptance`, `libraryDismissMatch` dismisses one, and
  `libraryAcceptConfidentMatches(library, minimum)` accepts each file's best
  pending proposal at least that confident, chosen as
  [metadata.md](metadata.md#musicbrainz-recording-ids) describes, and
  returns a `ConfidentMatchAcceptance`. `libraryApplyMatchedRelease(library,
  release_id)` stores a Release's album values once its Tracks agree on one
  MusicBrainz release and returns how many it stored. Accepts reproject, so
  Track and Release ids can change; see
  [metadata.md](metadata.md#accepting-a-match). Once a job started with
  `MatchRequest.release_id` that searches or re-identifies has finished,
  `jobMatchRelease(job)` returns the Release that holds most of the files
  the album's Tracks had when it started, so a host can follow the album to
  its new id; it is the same id when the album kept its key, and null while
  the job runs, for any other job, and when no Release holds the files.
  `setMusicBrainzServer` and `setAcoustIdServer` select other servers under
  the same rules as `setListenBrainzServer`, from the next job.
  `setAcoustIdClientKey(key)` copies the AcoustID application key, or clears
  it when null, and a `CredentialStore` value under
  `acoustid_credential_service` / `acoustid_client_key_account` overrides
  it. See [providers.md](providers.md#matching) and
  [metadata.md](metadata.md#musicbrainz-recording-ids).
- `libraryTrackFingerprint(library, io, track_id)` returns the
  `TrackFingerprint` of the file a Track plays: Chromaprint's compressed
  fingerprint, the file's length and whether it came from the Library's
  cache. It decodes up to two minutes of audio on the caller's thread when
  the cache has none, and returns null when the file has no present
  location.
- `startAcoustIdSubmission(library)` starts an `acoustid_submission` Job that
  sends AcoustID the fingerprints of files whose recording ID came from an
  accepted match or an edit, as the user whose key the `CredentialStore`
  holds under `acoustid_credential_service` / `acoustid_user_key_account`.
  `jobSubmissionStats` returns its `SubmissionStats`: the files examined
  while it runs, and every counter and the `SubmissionOutcome` once it has
  finished; `SubmissionOutcome.busy` means another Orca process held
  AcoustID. `libraryAcoustIdSubmittableCount` and
  `libraryAcoustIdSubmittablePage(library, cursor, limit)` list what it would
  send, as `AcoustIdSubmittable`s by file id after `cursor`;
  `AcoustIdSubmittable.sendsRecordingId(file_duration_ms)` says whether the
  recording ID or the file's metadata is sent. It cannot run beside matching
  or another submission (`error.AcoustIdBusy`). See
  [providers.md](providers.md#acoustid-submission).
- Pages and returned values are owned by the caller and released with their
  `deinit`.

Threading and ordering rules are the runtime's, documented in
[ownership.md](ownership.md) and [control-plane.md](control-plane.md).

### Smart playlist rules

A smart playlist stores a JSON document, version 1, and lists the Tracks it
matches each time it is read, one Track per Recording (the lowest id).

```json
{"v":1,"match":"all","rules":[
  {"field":"lossless","op":"is","value":true},
  {"match":"any","rules":[
    {"field":"year","op":"between","value":[1965,1979]},
    {"field":"title","op":"contains","value":"love"}]}
],"sort":{"field":"year","descending":true},"limit":25}
```

- `v` is required and must be 1. `match` is `all` (default) or `any`.
  `rules` holds rules and nested groups (`match` and `rules`), at most four
  levels deep (`error.RuleNestingTooDeep`) and 32 rules in all
  (`error.TooManyRules`). An unknown key, or a document over 16 KiB, is
  `error.InvalidSmartPlaylistRules`.
- `sort.field` is a `TrackSort` name, `added_at`, `last_played_at`,
  `duration_ms` or `random`; `sort.descending` defaults to false. `random`
  orders by a hash of the Track id and a seed. A stored playlist's seed comes
  from the runtime's shuffle seed and its id, so its order, and so its pages,
  stay the same for the life of the runtime; rules read without a playlist
  (`librarySmartPlaylistCount`, `librarySmartPlaylistPreview`) use the shuffle
  seed itself. The shuffle seed is random per runtime, and
  `libraryReshufflePlaylists()` draws a new one. `playlist_position` also
  takes `playlist`, a manual playlist's id, and orders Tracks by the first
  position of their Recording in it, Tracks it does not hold last. A
  `playlist_position` sort without a positive integer `playlist` is
  `error.InvalidRuleValue`, and `playlist` on any other sort is
  `error.InvalidSmartPlaylistRules`. `limit` is 1 to 10,000
  and defaults to 10,000. `limit_hours` (1 to 10,000) replaces it: the
  leading Tracks, in the rules' order, whose lengths add up to at most that
  many hours, a Track with no length counting as none. A document with both
  is `error.InvalidSmartPlaylistRules`.
- A rule is `field`, `op` and `value`. An unknown field is
  `error.UnknownRuleField`, an unknown operator `error.UnknownRuleOperator`,
  an operator the field's type does not take `error.RuleOperatorMismatch`,
  and a value of the wrong shape `error.InvalidRuleValue`.

| Type | Fields | Operators |
| --- | --- | --- |
| text | `title`, `artist`, `album`, `album_artist`, `genre`, `codec`, `release_type` | `is`, `is_not`, `contains`, `starts_with`, `is_set`, `is_not_set` |
| integer | `year`, `play_count`, `rating`, `duration_ms`, `sample_rate`, `bit_depth` | `is`, `is_not`, `gt`, `gte`, `lt`, `lte`, `between`, `is_set`, `is_not_set` |
| date | `added_at`, `last_played_at` | `gt`, `gte`, `lt`, `lte`, `between`, `in_last_days`, `not_in_last_days`, `is_set`, `is_not_set` |
| boolean | `loved`, `lossless`, `explicit`, `has_artwork` | `is`, `is_not` |
| playlist | `in_playlist` | `is`, `is_not` |

Text values are 1 to 256 bytes and compare ignoring ASCII case; `genre`
compares the genre's folded key, the one `genres.key` stores. Dates are Unix seconds;
`in_last_days` and `not_in_last_days` take 1 to 100,000 days counted back from
now, and `not_in_last_days` includes Tracks never played. `between` takes
`[low, high]` and includes both ends. `is_set` and `is_not_set` take no value.
`in_playlist` takes a manual playlist's id and matches the Tracks of the
Recordings it holds. Saving or counting rules that name a smart playlist,
itself included, or no playlist is `error.InvalidRulePlaylist`, so membership
never nests; a stored rule whose playlist is later deleted matches nothing.
The same holds for a `playlist_position` sort's `playlist`; once that playlist
is deleted, the sort falls back to Track id order.
`has_artwork` matches a Track whose file embeds a cover or whose Release has
a fetched or a folder cover, the test `TrackDetails.has_artwork` also uses;
`ReleaseQuery.has_artwork` counts a cover embedded in any of the Release's
files.
Every value is bound as an SQL parameter, never spliced into the query.

## Client identity

liborca has no identity of its own toward MusicBrainz, AcoustID and
ListenBrainz: the host names itself before any provider work.

```zig
try runtime.setClientIdentity(.{
    .name = "MyPlayer",
    .version = "1.2.0",
    .contact = "https://myplayer.example",
});
```

- Until it is set, `startLibraryMatching`, `startAcoustIdSubmission`,
  `startArtistInfoFetch` and `librarySetScrobbling(library, true, ...)` return
  `error.ClientIdentityRequired`. Turning scrobbling off, and
  `libraryTrackFingerprint`, need none.
- The three strings are copied, so the caller's buffers may be freed after the
  call. A later call replaces the identity; running workers adopt it on their
  next pass.
- Each field must be non-empty, free of control characters and parentheses,
  and the three together at most 256 bytes; otherwise the call returns
  `error.InvalidNetworkConfiguration`.
- The `User-Agent` is `Name/version ( contact ) liborca/<version>`. The suffix
  is left out only for the name `Orca` at liborca's own version, which is how
  `orca-cli` and `orca-gtk` identify themselves.

## Stability

liborca is pre-1.0. The C ABI in `orca.h` is versioned by `ORCA_ABI_VERSION`
and the shared library's SONAME, `liborca.so.<ORCA_ABI_VERSION>`. Within one
ABI version:

- functions are only added, never removed or changed;
- a reserved field gains a meaning only as an addition for which zero keeps
  the old behaviour;
- enum values are only added.

The Zig API may break in any minor release; `CHANGELOG.md` records each break.
