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

The module links SQLite, libFLAC, libopusfile and libvorbisfile through the
host's pkg-config, plus PipeWire on Linux, and compiles in its ALAC, AAC, MP3
and QOA decoders. [`examples/embed`](../examples/embed) is a complete project
that does this; `zig build test` builds it, so these steps stay correct.

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
  `ZoneStats`, ...), jobs (`ScanRequest`, `JobSnapshot`, `ScanStats`, ...), tag
  write-back (`TagWritePlan`, `TagWriteDigest`, ...), artwork
  (`ArtworkSubject`, `ArtworkResult`) and the control lane (`Action`, `Event`,
  `Telemetry`, `Failure`).
- `playerSetEqualizer` and `playerSetCrossfeed` (and their getters) set a
  Player's ten-band `Equalizer` (or an `EqualizerPreset`) and stereo crossfeed;
  `playerSignalPath` returns a `SignalPath`: the source, ReplayGain, DSP, volume
  and output stream, and why the path is or is not bit-perfect.
- `libraryTrackDetails` returns `TrackDetails` for one Track: codec, sample
  rate, bit depth, channels, bitrate, duration, file size and path (or that
  the file is missing), loudness when measured, and tags. The caller frees it
  with `deinit`.
- `libraryEditTracks` returns `EditedTracks`: the Tracks the edited files
  back afterwards. An edit that moves a track to another album or position
  reprojects it under a new id.
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
- Playback is recorded as local listening history. `processNextCommand`
  samples every Player bound to a Library at most every 100 ms; a play heard
  for half its length or four minutes (tracks of 30 s or more) is recorded on
  that Library's listen worker. `libraryTrackPlayStats` and `TrackDetails`
  report the play count and last play.
- `librarySetScrobbling` also sends a Library's listens to ListenBrainz, for
  at most one Library per runtime. The token comes from the `CredentialStore`
  given to `setCredentialStore`; `libraryScrobblerCredentialsChanged` has it
  validated once, and `libraryScrobblerStatus` returns a `ScrobblerStatus`.
  `setClientIdentity` names the host in submissions and
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
  the changes still waiting as `feedback_pending`.
- Pages and returned values are owned by the caller and released with their
  `deinit`.

Threading and ordering rules are the runtime's, documented in
[ownership.md](ownership.md) and [control-plane.md](control-plane.md).

## Stability

liborca is pre-1.0. The API changes when the design needs it; every change to
a top-level declaration is recorded in `CHANGELOG.md`.
