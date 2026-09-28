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
- Pages and returned values are owned by the caller and released with their
  `deinit`.

Threading and ordering rules are the runtime's, documented in
[ownership.md](ownership.md) and [control-plane.md](control-plane.md).

## Stability

liborca is pre-1.0. The API changes when the design needs it; every change to
a top-level declaration is recorded in `CHANGELOG.md`.
