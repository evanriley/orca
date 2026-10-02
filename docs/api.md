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
  `ScanStats`, ...), tag
  write-back (`TagWritePlan`, `TagWriteConflict`, `TagWriteDigest`, ...),
  artwork
  (`ArtworkSubject`, `ArtworkResult`), watching (`WatchOptions`,
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
  unit runs cancel it and return a `queued` job, which `pump` starts once
  the unit has finished. See
  [control-plane.md](control-plane.md#idle-maintenance).
- A scan or reconcile of a root whose path now lies on another volume than
  the one recorded, as an unmounted drive's mount point does, walks and
  sweeps nothing and ends `failed`. See
  [storage.md](storage.md#volume-check-before-a-walk).
- `playerSetEqualizer` and `playerSetCrossfeed` (and their getters) set a
  Player's ten-band `Equalizer` (or an `EqualizerPreset`) and stereo crossfeed;
  `playerSignalPath` returns a `SignalPath`: the source, ReplayGain, DSP, volume
  and output stream, and why the path is or is not bit-perfect.
- `libraryTrackDetails` returns `TrackDetails` for one Track: codec, sample
  rate, bit depth, channels, bitrate, duration, file size and path (or that
  the file is missing), loudness when measured, tags, and the MusicBrainz
  recording ID in effect with its `RecordingIdSource` (`tag`, `match` or
  `edit`). The caller frees it with `deinit`.
- `libraryEditTracks` returns `EditedTracks`: the Tracks the edited files
  back afterwards. An edit that moves a track to another album or position
  reprojects it under a new id.
- `planTagWrite` returns a `TagWritePlan`: each file's `TagWriteChange`s with
  the `Provenance` of Orca's value, the `TagWriteConflict`s it leaves out
  because an unlocked value disagrees with the file's tag, and the files it
  skips. `isMusicBrainzId` is the check `libraryEditTracks` applies to a
  recording ID, for a client to validate input before saving.
- The queue can be edited in place: `playerQueueJump` plays an entry now,
  `playerQueueInsertNext` queues Tracks after the current one, and
  `playerQueueRemove` removes an entry. The entry playing, and one the engine
  has already lined up after it, are refused with `error.QueueEntryInUse`.
- `TrackSummary` carries `release_id` and `artist_id`, so a host can link a
  Track to its Release and Artist without a second query.
- Cover art is read either on the caller's thread (`libraryTrackArtwork`,
  `libraryReleaseArtwork`) or off it: `libraryRequestArtwork` queues a lookup
  on the Library's artwork loader, at most 64 outstanding, and
  `libraryTakeArtwork` collects finished ones. `libraryCancelArtwork` skips a
  request that has not started.
- Lyrics are read on a job: `startTrackLyrics` starts one for a Track,
  `jobLyricsOutcome` reports `local` or `not_found` once it finishes, and
  `jobTakeLyrics` moves the `Lyrics` to the caller once. `Lyrics.lineAt`
  gives the synced line at a playback position. See
  [metadata.md](metadata.md#lyrics).
- Playback is recorded as local listening history. `processNextCommand`
  samples every Player bound to a Library at most every 100 ms; a play heard
  for half its length or four minutes (tracks of 30 s or more) is recorded on
  that Library's listen worker. `libraryTrackPlayStats` and `TrackDetails`
  report the play count and last play.
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
  `TrackSort.loved` orders them most recently loved first, the rest last;
  `libraryTrackQuery` returns `error.SearchDoesNotFilter` for a text search
  with `loved_only`, as it does with an Artist or Release filter.
- `librarySetRating(library, track_ids, ?u8)` rates the song behind each
  Track from 1 to 100, or clears it, and returns a `RatingChange`; it shows as
  `TrackSummary.rating` and `TrackDetails.rating`. Playlists are
  `libraryPlaylists`, `libraryCreatePlaylist`, `libraryRenamePlaylist`,
  `libraryDeletePlaylist`, `libraryPlaylistEntries`, `libraryPlaylistInsert`,
  `libraryPlaylistRemove` and `libraryPlaylistMove`, with
  `playerPlayPlaylist` to play one and `libraryImportPlaylist` and
  `libraryExportPlaylist` for M3U files. See [playlists.md](playlists.md).
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
  [metadata.md](metadata.md#accepting-a-match).
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

- Until it is set, `startLibraryMatching`, `startAcoustIdSubmission` and
  `librarySetScrobbling(library, true, ...)` return
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
