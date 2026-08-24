# Integration recovery design

Working design for the milestones in the integration-recovery plan. This is a
design document, not a description of current behavior. It supersedes nothing in
`docs/`; where it contradicts current code, the code is what exists today.

## W — Foundation fixes that gate everything

Small in code, large in consequence. Nothing in B/C/D is safe without them.

### W1 — Work registrations must represent live workers

`core/work.zig:Registry.drain` calls `pool.discardAll()` — it invalidates handles
and returns immediately. `OrcaRuntime.shutdown` (runtime.zig:75-92) then destroys
Zones, Players and Library databases on the next line. Harmless today because no
worker exists; a use-after-free plus `sqlite3_close` under an active statement the
moment one does.

- A registration owns a `std.Thread.ResetEvent` (or a Registry countdown latch).
- `requestCancellation()` sets a per-registration atomic flag.
- `drain()` **blocks** until every registration calls `complete()`. No timeout —
  a worker that ignores cancellation is a bug, and a timeout reintroduces the race.
- Shutdown order: refuse commands -> request cancellation -> **join workers** ->
  close OutputSessions -> destroy Zones -> destroy Players -> close Libraries.
- `destroyPlayer` / `destroyZone` need the same discipline, not just `shutdown`.

Note `core/handle.zig` has **no locking at all**, and `OrcaRuntime` takes no lock
around `self.zones.get(...)`. Worker threads must therefore never touch a Pool;
they hold a published snapshot (see B1).

### W2 — `SourceSession` must own its `ReadableSource`

`source_session.zig:17` `deinit` only deinits the Decoder. In `playFileBlocking`
the backing `LocalFileSource` lives on the caller's stack frame and outlives the
decoder by construction. In the runtime there is no such frame. A `LoadedSource`
wrapper must heap-own the `LocalFileSource` and free it *after* the decoder.

### W3 — Split `ReadyBlock.generation` into `epoch` + `entry_serial`

The subtlest problem here, and much cheaper to fix now than after the ABI ships.

`render.zig:57` discards any block whose `generation` differs from the Player's.
`source_session.zig:143-147` appends the *successor track's* blocks under the
*same* generation — that is how gapless works. One field, two incompatible jobs:

- "discard stale audio after a seek" -> must be compared
- "which track is this block" -> must **not** be compared, or gapless breaks

Consequence: accurate now-playing during a gapless transition is impossible,
because the decode cursor leads the render cursor by the whole render-ahead depth.

Fix: `ReadyBlock { index, frames, epoch: u32, entry_serial: u32 }`. The callback
compares only `epoch` and publishes `entry_serial` into a Zone-owned atomic.
Seek/stop/hard-skip bump `epoch`; each queue entry gets a new `entry_serial`.

### W4 — Pause must be honored inside the render callback

`Player.pause` only stores an enum; `pipewire.zig:173` never reads it, so up to
`8 x 1024` = 8192 frames (~170 ms) keeps playing after "pause" and the position
keeps advancing. Give `RenderContext` a `*const std.atomic.Value(bool)` owned by
the Zone; when set, `@memset(output, 0)` and return **without** consuming blocks
and **without** counting an underrun. One atomic load plus a memset — within the
RT rules in `docs/audio-engine.md`.

---

## A — Identity migration

### A.0 What the stable identity is

**`files.id` is the identity** — a surrogate INTEGER PRIMARY KEY. After this work
no table outside `files` / `locations` / `mutation_operations` stores a path.

The real question is how the scanner *re-finds* the same `files.id` after a
rename, move, tag write or restore. Tiered cascade, cheapest first:

| Tier | Signal | Catches | Cost |
|---|---|---|---|
| 1 | `locations(volume_id, uri)` exact | unchanged files | index lookup |
| 2 | `(volume_id, native_inode, size_bytes, modified_ns)` | rename/move within a filesystem | index lookup |
| 3 | `quick_hash` = BLAKE3(first 64 KiB ‖ last 64 KiB ‖ size) | copies, cross-volume moves, restores | two positional reads |
| 4 | `audio_hash` over the decoded/framed audio payload only | **tag writes** (size+mtime change, audio does not); duplicates | full read — an analysis Job, never the scanner |

Tier 4 is what stops Orca's own tag-writing from orphaning identity and what lets
`analysis_results` survive a tag edit. Compute it in the analysis job, store in
`files.audio_hash`. Content hash alone is insufficient (two identical rips are the
same content, different files); inode alone is insufficient (not stable across
filesystems, editors, backups). The cascade is.

**Volume identity.** `locations.device_id` is unused today. `st_dev` is *not*
stable across reboots or remounts. Add a `volumes` table whose `stable_key` is,
in order: filesystem UUID from `/proc/self/mountinfo`; else a ULID persisted in a
dotfile at the mount root; else `root:<library_roots.id>`. Keep `st_dev` as a
per-location hint only. Resolution lives in a platform adapter, not the scanner.

### A.1 Target schema (migration `user_version = 8`)

A real database at this stage is small, so **recreate** the affected tables
(`CREATE new; INSERT..SELECT; DROP old; ALTER RENAME`) rather than accreting
nullable columns. Clean end state for the same effort.

```
volumes(id PK, stable_key TEXT UNIQUE, label, last_seen_at)
library_roots(id PK, volume_id -> volumes, path, enabled)      -- finally used
files(id PK, recording_id -> recordings, audio_format, codec,
      size_bytes, sample_rate, bit_depth, channels, duration_ms,
      quick_hash BLOB, audio_hash BLOB, content_hash BLOB,
      first_seen_at, last_scan_generation)
locations(id PK, file_id -> files ON DELETE CASCADE, volume_id, root_id,
          uri, native_device, native_inode, size_bytes, modified_ns,
          state,                      -- present | missing | unverified
          missing_since, last_seen_generation,
          UNIQUE(volume_id, uri))
observed_file_tags(file_id PK -> files, title, artist, album, album_artist,
                   track_number, disc_number, disc_total, track_total, date,
                   compilation, musicbrainz_*_id)
orca_metadata_values(file_id, field, value, provenance, locked, updated_at,
                     PRIMARY KEY(file_id, field))
analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash,
                 source_identity BLOB,   -- quick_hash, NOT size+mtime
                 result BLOB, created_at, PRIMARY KEY(...))
library_health_issues(file_id, kind, severity, details, updated_at,
                      PRIMARY KEY(file_id, kind))
identification_proposals(id PK, file_id -> files, recording_id NULL, ...)
mutation_operations(... existing ..., file_id -> files)   -- paths RETAINED
scan_runs(id PK, root_id, generation, started_at, finished_at, state, counters)
```

Key decisions:

- **`observed_files` disappears entirely.** Filesystem facts -> `locations`; byte
  facts -> `files`; tag facts -> `observed_file_tags`. This removes the last
  path-keyed primary key. `ObservedFileRepository` splits into `FileRepository` +
  `LocationRepository` + `ObservedTagsRepository`.
- **`analysis_results` keys on `quick_hash`, not size+mtime** — a tag write no
  longer invalidates a loudness analysis. Free correctness win; take it.
- **`mutation_operations` keeps its paths.** A filesystem operation's subject
  genuinely *is* a path — not an identity violation. Add `file_id` so the journal
  can restore identity after a move.
- `tracks` gains `artist`, `preferred_file_id -> files`, and
  `CREATE UNIQUE INDEX tracks_position ON tracks(release_id, COALESCE(disc_number,1), COALESCE(track_number, -id))`.
- `releases` gains `is_compilation`, `disc_count`, `release_key TEXT UNIQUE`, `musicbrainz_release_id`.
- `artists` gains `key TEXT UNIQUE` (NFKC + casefold + whitespace-collapsed) and `musicbrainz_artist_id`.

### A.2 FTS rebuild

`track_search` (migrations.zig:56-74) is external-content FTS5 over
`title, album, album_artist` with three maintaining triggers. It needs an
`artist` column, and **FTS5 external-content tables cannot be `ALTER`ed to add
one**. Drop the three triggers and the virtual table, recreate both with the
fourth column, then `INSERT INTO track_search(track_search) VALUES('rebuild')`.
The triggers then maintain FTS for free once the projection writes tracks.

### A.3 Backfill order (fiddly, order matters)

1. **Run mutation-journal recovery first (A8).** Migrating a database with a
   nonterminal staged operation whose `source_path` is about to become a
   `file_id` is not recoverable afterward. If recovery cannot converge, **refuse
   to open** — matching the existing "reject unknown newer versions" posture.
2. Synthetic `volumes` row (`stable_key = 'legacy'`) and `library_roots` rows.
3. `INSERT INTO files SELECT ... FROM observed_files` — one file per observed path.
4. `INSERT INTO locations` by rowid correspondence, `state = 'unverified'`.
5. `CREATE TEMP TABLE path_to_file(path TEXT PRIMARY KEY, file_id INTEGER)`.
6. `INSERT..SELECT` each dependent table joining on `path_to_file`.
7. **Orphan paths.** `analysis_results` and `library_health_issues` can hold paths
   written by `orca-cli analyze` against never-scanned files. Do **not** drop them
   — synthesize `files` + `locations` rows with `state = 'unverified'`. Losing a
   user's analysis cache during a migration destroys trust in the tool.
8. `PRAGMA foreign_key_check` before `COMMIT`.

**Test requirement:** a checked-in **v7 fixture database** with rows in every
path-keyed table (including an orphan analysis path), migrated in a test that
asserts row-for-row preservation. Without it this migration is unverifiable.

### A.4 Scanner rewrite

- Takes a `root_id`, not a bare path. Opens a `scan_runs` row with a fresh
  monotonic `generation`.
- Per entry: stat -> identity cascade (Tier 1, then Tier 2 against *missing*
  locations, then Tier 3) -> resolve or create `file_id` -> upsert `locations`
  stamping `last_seen_generation` -> if bytes changed, sniff format and read tags.
- **Tier-2 hit on a location marked `missing` = a move**: update `locations.uri`
  in place. All metadata, locks, analysis and health attached to `file_id`
  survive. This is the whole point of the exercise.
- Bounded commits (existing 256 batch).
- **Sweep only after a successfully completed, uncancelled run**: locations under
  this root with `last_seen_generation < generation` become `state = missing`.
  **Never delete on first miss** — that is how an unmounted USB drive eats a
  library. Deletion is an explicit user action or a policy after N runs.
- Cancellation checks stay where they are; a cancelled run does not sweep.

### A.5 Tag reading

`liborca/library/tag_reader.zig` dispatches on sniffed `AudioFormat` to
`metadata.id3v2` (E1), `metadata.vorbis_comment` (FLAC and Ogg), and `codec.mp4`
iTunes atoms (E6). Format-specific concerns terminate here per `docs/metadata.md`.

### A.6 Projection — the piece that fills `tracks`

**This interprets a locked law; flagged deliberately.** `CLAUDE.md` says "Scanner
observations never update Track metadata." Resolution: the *scanner* still
doesn't — a separate **projection** does, and it reads `EffectiveMetadata`
(observed + orca overrides + locks, under an explicit policy), not raw
observations. The law stays intact and the projection becomes re-runnable after a
user edit or provider acceptance, not only after a scan. **Write this into
`docs/database.md` or someone will "fix" it back.**

`liborca/library/projection.zig`, run by the scan job after each batch and
standalone after metadata mutations:

- **Artist:** normalize(name) -> `artists.key`; MusicBrainz artist id wins if present.
- **Release:** `release_key = normalize(album) ‖ 0x1f ‖ normalize(album_artist) ‖ 0x1f ‖ (mb_release_id ?? year ?? "")`.
- **Various Artists / compilation**, in order:
  1. explicit `albumartist` tag -> use it
  2. compilation flag (`TCMP`, `COMPILATION=1`, `cpil`) -> "Various Artists", `is_compilation = 1`
  3. all files sharing the album key **within the same containing folder** have one artist -> that artist
  4. otherwise -> "Various Artists", `is_compilation = 1`

  Rule 3 forces a real constraint: **release resolution cannot be per-file
  streaming.** The projection must group changed files by
  `(containing folder, album key)` and resolve the release for the whole group.
  This is the main reason the item is Hard.
- **Multi-disc:** `releases.disc_count = max(disc_number)`; position is
  `(release_id, disc_number ?? 1, track_number)`. Missing `track_number` falls
  back to a synthetic position from the sorted filename and raises the existing
  `missing_track_number` health issue.
- **Track vs file:** a `track` is a position on a release; a `recording` is the
  performance; `files` are encodings of it. A FLAC and an MP3 of the same song
  collapse to one recording with two files. `tracks.preferred_file_id` is a
  denormalized cache (highest bit depth, then user format preference, then first
  present location) so playback is one indexed lookup, not a three-way join.

### A.7 Repository API changes

- `TrackInput` becomes the *projection's* input:
  `{ recording_id, release_id, title, artist, album, album_artist, duration_ms,
     track_number, disc_number, preferred_file_id }` with `upsertTracks` (not
  `insertBatch`). Update `benchmarks/main.zig`, `database/library.zig` tests, and
  the `c_api.zig` test.
- `ObservedFileInput` / `ObservedFileRepository` -> `FileUpsert` + `LocationUpsert`
  + `ObservedTagsInput` across three repositories.
- `TrackSummary` gains `artist`, `duration_ms`, `track_number`, `disc_number`, `has_playable_file`.
- **`TrackRepository.playableLocation(allocator, track_id) -> ?ResolvedLocation
  { file_id, volume_stable_key, uri, audio_format }`** — the single most important
  new call; it is what makes "double-click a row and hear it" possible.
- `FileRepository.{resolveByUri, resolveByIdentity, resolveByQuickHash, markMissingBelowGeneration}`.
- `LibraryRootRepository.{add, remove, list}`; `ScanRunRepository.{begin, finish, cancel}`.
- **`WriteLane` is a spinlock** (repository.zig:8-10). With a scan worker holding
  it across a 256-row transaction while a UI thread reads, that burns a core.
  Make it a real `std.Thread.Mutex`.

### A.8 Startup mutation recovery (P0, hard prerequisite for A.2)

`database/library.zig:22-47` never enumerates nonterminal journal records;
`metadata/executor.zig:recoverOperation` runs only when a test calls it. Recovery
must run **before the Library becomes available**, and therefore before migration
8 rewrites the tables it depends on.

Same pass, cheap while here: `fsync` the containing directory after stage creation
and after rename; revalidate identity immediately before `commitReplacement`
(file_mutation.zig:150-161); strengthen `FileIdentity` from (size, mtime) to
(size, mtime, quick_hash); refuse to claim rollback when neither source nor backup
can be proven present.

### A — work items

| ID | Description | Depends | Difficulty |
|---|---|---|---|
| A1 | `volumes`/`library_roots`/`scan_runs` + volume stable-key platform adapter | — | Medium |
| A2 | Migration 8: recreate path-keyed tables, backfill, FTS rebuild, v7 fixture test | A1, A8 | **Hard** |
| A3 | File/Location repositories: identity cascade, upsert, missing sweep | A2 | Medium |
| A4 | Scanner rewrite: root-scoped, generation-stamped, move/removal reconciliation | A3 | **Hard** |
| A5 | Tag-reader dispatch by sniffed format | A4, E1/E3/E6 | Medium |
| A6 | Projection: artist/release/recording/track, VA, multi-disc, `preferred_file_id` | A4 | **Hard** |
| A7 | Repository API, `TrackSummary`, `playableLocation`, `WriteLane` mutex | A6 | Medium |
| A8 | Startup journal recovery, dir fsync, pre-rename revalidation, stronger identity | — | **Hard** |

---

## B — Playback through the runtime

### B.0 One object graph

```
OrcaRuntime
├─ PlayerObject
│   ├─ Player                    transport, epoch, seek base, SourceQueue  [exists]
│   ├─ PlaybackQueue             track ids + cursor + repeat/shuffle       [C]
│   ├─ Player processing chain   Gain (volume + ReplayGain), Meter         [exists]
│   ├─ decode scratch            fixed-capacity canonical f32              [new]
│   ├─ published zone snapshot   immutable slice + ack counter             [new]
│   └─ PlayerEngine thread       the ONE decode producer                   [new]
└─ ZoneObject
    ├─ Zone                      policy, latency, output state             [exists]
    ├─ BlockPool / RenderPipe(N) / RenderContext(N) / OutputSession  [moved from stack]
    ├─ Zone atomics              epoch, paused, rendered_frames, entry_serial [new]
    └─ Zone processing chain
```

**Pool/pipe/context/session belong to the Zone, not the Player.**
`docs/audio-engine.md` is explicit: "Fanout copies that PCM into independently
owned Zone pools and queues." `playFileBlocking` has the Player priming directly
into one pool via `Player.prime` — the single-zone shortcut, and the reason the
two systems diverged. The unified path uses `Player.decodeProcessAndFanout`
(player.zig:84), which already exists and is already tested against two
independent Zone sinks. `Player.prime` demotes to a test/bench convenience.

### B.1 The dangling-pointer problem (architecture fights the goal)

`RenderContext` is handed to PipeWire as a raw `?*anyopaque` and holds
`generation: *const Value(u64)` and `rendered_position: ?*Value(u64)` —
**pointers into the Player** (pipewire_playback.zig:68-74). If a Player is
destroyed or detached while a Zone's OutputSession is open, the RT thread
dereferences freed memory. There is no reference counting and no epoch
reclamation; `handle.Pool` generations protect *handles*, not pointers an engine
thread already dereferenced.

1. **The Zone owns its own atomics.** The producer publishes the Player's epoch
   into the Zone's `epoch` atomic immediately before submitting blocks under it.
   The callback reads only Zone-owned memory. Detach then cannot dangle.
2. **Zone-set publication uses acknowledged double-buffering**, mirroring the
   triple-buffered DSP chain pattern the docs already describe: the control lane
   writes an unclaimed slot holding an immutable `[]*ZoneRuntime` and publishes it
   atomically; the engine thread adopts it at a block boundary and bumps an ack
   counter; the control lane frees the old Zone only after observing the ack.
   **Never let the engine thread call `runtime.zones.get()`** — the Pool is unlocked.

### B.2 Where the decode producer lives

**One engine thread per Player** (`liborca/audio/engine.zig` -> `PlayerEngine`).
Not one per Zone: SPSC queues require exactly one producer, and fanout is
one-producer-many-consumers by design. Spawned lazily when a Player first receives
a source; registered with `work.Registry` (W1); joined by `destroyPlayer` and
`shutdown`. Loop body:

1. Adopt a newly published zone snapshot if any; ack it.
2. For each Zone: `pipe.reclaim(pool)`.
3. Per-Zone budget from `zone.renderStrategy().blockBudget(...)` (zone.zig:14, already implemented).
4. If transport is `.playing` and any Zone has capacity: decode one canonical
   block into the Player scratch -> Player processing chain -> `fanout.submit`
   into each Zone's pool+pipe under the current epoch and entry serial.
5. If `sources.current.eof` and no successor primed: ask the PlaybackQueue for the
   next track, open it, `primeNext` (gapless) or defer to a hard switch on format
   mismatch (see C).
6. Publish coalesced position telemetry at ~10 Hz.
7. Poll each Zone's `OutputSession.status()`; on `.lost`, run bounded recovery
   (the existing 3-attempt loop at pipewire_playback.zig:102-117, moved into the
   Zone, using `Zone.deviceLost/beginRecovery/recoveryFailed` — which no
   production code currently calls).
8. Park on a futex/`ResetEvent` with a 5–10 ms timeout so play/pause/seek/enqueue
   wake it immediately. Replaces the current `nanosleep`.

### B.3 Track id -> playing audio

`runtime.playerPlayTrack(player, library, track_id)`, on the control lane /
engine thread, never synchronously on the caller's UI thread:

1. `tracks.playableLocation(track_id)` on an independent read-only connection (A7).
2. Heap-allocate a `LocalFileSource` for the location URI (W2).
3. `CodecRegistry.openDetected` -> `Decoder` -> `LoadedSource` -> `Player.loadSource` or `primeNext`.
4. Emit a completion event keyed to the request id. Failures (`CodecUnavailable`,
   missing file) surface as typed failures; the Location is marked `missing` if the
   open fails with `FileNotFound`.

`Player.loadSource` currently errors when a source already exists (player.zig:34)
— the queue needs a `replaceSource` that tears down the old `SourceQueue` and
bumps the epoch.

**Format changes between tracks** require reopening the OutputSession, because
`RenderContext.channels` and the negotiated rate are fixed at open
(pipewire.zig:181). v1: on mismatch, drain the pipe, close, reopen at the new
format, resume. A short audible gap, but correct. Resampling to a fixed Zone rate
is the alternative and is explicitly deferred — `docs/audio-engine.md` already
says the resampler is "a streaming scalar reference, not a production-quality
band-limited resampler", so routing all playback through it would silently
degrade every file.

### B.4 Position telemetry

The callback already does `rendered_position.fetchAdd(rendered)`; that becomes
Zone-owned. Authoritative position is derived on the control lane:

```
position_frames = seek_base_frames + clock_zone.rendered_since_epoch
```

To avoid a torn read across the epoch boundary, pack both into **one**
`Value(u64)`: high 16 bits = `epoch & 0xffff`, low 48 bits = frames since that
epoch (48 bits ~ 180 years at 48 kHz). The callback writes it with a single store;
the control lane reads it with a single load and discards the sample if the epoch
doesn't match. Wait-free, no seqlock, no `u128`.

The engine thread converts to ms and publishes `Telemetry.player_position` through
the existing coalescing channel (control.zig:106). Snapshots stay authoritative
per `docs/control-plane.md`. With multiple Zones, one is the **clock zone** (first
attached with an active output); if it fails, promote another and stamp a new epoch.

### B — work items

| ID | Description | Depends | Difficulty |
|---|---|---|---|
| B1 | Zone owns pool/pipe/context/session/atomics; acknowledged zone-set publication | W1, W3, W4 | **Hard** |
| B2 | `PlayerEngine` thread: decode -> process -> fanout -> prime -> recover -> park | B1 | **Hard** |
| B3 | `playerPlayTrack`: resolve -> open -> load, off the caller's thread | W2, B2, A7 | Medium |
| B4 | Packed epoch+frames position atomic; telemetry at 10 Hz | B1 | Medium |
| B5 | Device enumeration through the runtime (`Backend.discover` already written) | B1 | Easy |
| B6 | Delete `playFileBlocking`; `orca-cli play` drives the runtime graph | B2, B3 | Easy |
| B7 | Volume + ReplayGain in the Player chain (`processing.Gain` with ramps exists) | B2 | Medium |

**B6 is the integration proof:** if `orca-cli play` still works through the
runtime graph, the unification is real.

---

## C — Queue semantics

`SourceQueue` (source_session.zig:85) already gives one current + one
format-matched prepared successor with gapless append. That is the *decode* queue.
Missing is the *playback* queue above it.

`liborca/audio/playback_queue.zig`:

```
PlaybackQueue {
    entries: bounded list of TrackRef{ library, track_id },   // cap 10_000
    cursor: u32,
    next_entry_serial: u32,
    repeat: enum { off, all, one },
    shuffle: bool,
    order: ?[]u32,          // permutation when shuffled
}
```

Bounded per the project's rule; enqueue past capacity applies backpressure rather
than growing. Owned by the Player, mutated only from the control lane and engine
thread (a plain mutex is fine — the RT callback never touches it).

| Operation | Semantics |
|---|---|
| `enqueue(ids[])` | append; if idle, load the first and play |
| `playNow(ids[], start)` | replace queue, load `start`, bump epoch, play |
| `next()` | **hard** switch: bump epoch (callback discards stale blocks), advance cursor, load. User skips must be immediate, not gapless |
| `previous()` | if position > 3 s, seek to 0; else move cursor back. Requires B4 |
| `stop()` | transport stopped, release `SourceQueue`, **retain** entries and cursor |
| `clear()` | stop + empty |
| auto-advance | engine thread, on `current.eof && next == null`, pull next ref, open, `primeNext` |

**Auto-advance and format mismatch.** `primeNext` returns
`error.GaplessFormatMismatch` when canonical formats differ
(source_session.zig:114). The engine must not treat that as fatal: hold the
successor loaded but unprimed, wait for the pipe to drain, reopen the Zone output
at the new format, hard-load. Net: **gapless when formats match, gapped-but-correct
when they don't** — honest about the code, and right for a mixed library.

**Now-playing accuracy depends entirely on W3.** The decode cursor leads the
audible cursor by the full render-ahead; without the `entry_serial` split, a
gapless transition reports the next track several hundred ms early.

**Repeat.** `repeat_one` re-primes a *fresh* `SourceSession` seeked to 0 rather
than seeking the current one, which is still draining into the pipe. `repeat_all`
wraps the cursor. Both cheap once auto-advance exists — include them.

**Shuffle.** Generate a permutation on enable and keep the currently-playing entry
at the cursor so toggling doesn't restart the song. Random-next instead of a
permutation breaks `previous()` — the classic bug. ~40 lines; include it.

| ID | Description | Depends | Difficulty |
|---|---|---|---|
| C1 | `PlaybackQueue` type + control-lane operations | B2 | Medium |
| C2 | Auto-advance, gapless priming, format-mismatch reopen | C1, W3 | Medium–Hard |
| C3 | next/previous/repeat/shuffle | C1, B4 | Medium |

---

## D — C ABI extension

Style to preserve: `orca_status` returns, opaque runtime, `orca_handle{index,
generation}`, POD `extern struct` with explicit `reserved` padding,
callback-scoped `orca_string_view`, `limit` bounded 1..512.

**One breaking change is unavoidable and should be taken now:** `orca_track_view`
must grow `artist`, `duration_ms`, `track_number`, `disc_number`, `has_file`. Both
consumers are in-tree and there are no external clients. Take the break, bump the
version, update `CHANGELOG.md` + `build.zig.zon` + `liborca/root.zig` together per
the convention. Leave `orca_player_state_snapshot` alone and add a *new*
`orca_player_status` rather than growing a shipped struct.

**Scanning as a job**
```c
orca_status orca_library_add_root(rt, lib, const char *path, int64_t *root_id);
orca_status orca_library_remove_root(rt, lib, int64_t root_id);
orca_status orca_library_query_roots(rt, lib, void *ctx, orca_root_callback cb);
orca_status orca_library_start_scan(rt, lib, int64_t root_id /* -1 = all */,
                                    const orca_scan_options *opts, orca_handle *job);
orca_status orca_job_cancel(rt, orca_handle job);
orca_status orca_job_snapshot(rt, orca_handle job, orca_job_snapshot *out);
orca_status orca_library_scan_stats(rt, orca_handle job, orca_scan_stats *out);
```
Scan progress is genuinely indeterminate until the walk completes. **Do not fake a
denominator:** report `completed_units = files_processed`, leave `has_total = 0`,
and expose `orca_scan_stats` mirroring `scanner.Result`. `start_scan` must be
nonblocking and run on a `work.Registry`-registered worker — depends on W1.

**Event polling**
```c
orca_status orca_runtime_poll_event(rt, orca_event *out, uint32_t *remaining);
orca_status orca_runtime_pump(rt);   /* drive the control lane */
```
`orca_event` is a tagged POD with a **named `extern union`** of small per-kind
structs rather than opaque `a`/`b`/`c` fields — extern unions are ABI-stable,
import cleanly into Swift, and make the header self-documenting. Kinds: command
completed, job progress, job finished, player position, player track changed,
player state changed, zone output changed, library changed.

For GTK, v1 uses `g_timeout_add` (200 ms). An `orca_runtime_event_fd()` returning
an eventfd would let GTK use `g_unix_fd_add` and eliminate idle wakeups — a good
follow-up, but it is a platform-specific shape in a cross-platform ABI, so don't
rush it.

**Player / transport / queue**
```c
orca_status orca_player_set_library(rt, player, orca_handle library);
orca_status orca_player_play_track(rt, player, int64_t track_id, uint64_t *request_id);
orca_status orca_player_enqueue_tracks(rt, player, const int64_t *ids, size_t count);
orca_status orca_player_next / _previous / _clear_queue(rt, player);
orca_status orca_player_set_repeat(rt, player, uint8_t mode);
orca_status orca_player_set_shuffle(rt, player, uint8_t enabled);
orca_status orca_player_set_volume / _volume(rt, player, float linear /*|*/ float *out);
orca_status orca_player_seek_ms(rt, player, uint64_t ms, uint64_t *epoch);
orca_status orca_player_status_get(rt, player, orca_player_status *out);
orca_status orca_player_now_playing(rt, player, void *ctx, orca_now_playing_callback cb);
orca_status orca_player_query_queue(rt, player, uint32_t limit, uint32_t offset,
                                    void *ctx, orca_queue_entry_callback cb);
```
`orca_player_status` carries transport, repeat, shuffle, has_track, epoch,
`position_ms`, `duration_ms`, `track_id`, `queue_length`, `queue_index`, `volume`.
Now-playing strings need a callback because they cannot live in a POD.

**Devices / zones**
```c
orca_status orca_enumerate_output_devices(rt, void *ctx, orca_device_callback cb);
orca_status orca_zone_create / _destroy / _attach_player(...);
orca_status orca_zone_open_output(rt, zone, uint64_t device_id, uint8_t policy,
                                  uint32_t latency_frames);
orca_status orca_zone_close_output(rt, zone);
orca_status orca_zone_status(rt, zone, orca_zone_status *out);
/* convenience for single-output frontends: */
orca_status orca_player_open_default_output(rt, player, uint64_t device_id,
                                            orca_handle *zone_out);
```
GTK should not need to know Zones exist for the common case;
`orca_player_open_default_output` creates+attaches+opens in one control-lane
action. Device id 0 delegates to the server, which the PipeWire adapter supports.

**Concurrency contract.** Document that all `orca_*` calls come from a single
thread (`orca_runtime_poll_event` also single-consumer), and add a debug-build
thread-id guard returning `ORCA_STATUS_INVALID_ARGUMENT` on violation. Cheap;
prevents a whole class of bug report.

| ID | Description | Depends | Difficulty |
|---|---|---|---|
| D1 | Events, jobs, scan-as-a-job, roots | W1, A4 | Medium |
| D2 | Player status, transport, queue, now-playing, volume, seek_ms | B3, B4, C1 | Medium |
| D3 | Devices + zones + `open_default_output` | B1, B5 | Easy–Medium |
| D4 | Extended `orca_track_view` (breaking); version bump | A7 | Easy |
| D5 | Single-thread contract + debug guard + smoke-test coverage | D1–D4 | Easy |

---

## E — Codec expansion

The `Decoder` interface (`codec/decoder.zig`) is small and stable —
`{read_frames -> []f32, seek(frame), deinit, source_format, format, frame_count}`
— so **all of E is parallelizable from day one** and depends on nothing else here.

Two structural notes:

- **Each family needs a tag reader, not just a decoder.** Today only ID3v1 read
  and Vorbis-comment *write* exist. This roughly doubles E and is routinely
  forgotten.
- **`CodecRegistry.register` rejects duplicate `AudioFormat`s** (registry.zig:17),
  but `.mp4` holds AAC *or* ALAC and `.opus`/`.vorbis` share the Ogg container.
  The container adapter must own the internal dispatch. The abstraction is
  slightly wrong-shaped but the workaround is clean.

### MP3 — vendored `minimp3` behind a narrow C shim + pure-Zig Xing/LAME

There is no mature pure-Zig MP3 decoder. `minimp3` (CC0/public domain, single
header, ~2k lines, widely deployed) vendored under `liborca/codec/vendor/minimp3/`
follows exactly the `pipewire_shim.c` containment pattern `CLAUDE.md` sanctions. A
Zig adapter owns `mp3dec_t`.

The *real* work is not the decoder:
- **Xing / Info / VBRI header parsing** (~150 lines Zig) for `frame_count` and VBR
  duration. Without it, durations are wrong for every VBR file.
- **LAME encoder delay + padding trim** — required for correct `frame_count` and
  for MP3 gapless to sound gapless.
- **Seeking:** CBR by bitrate; VBR via Xing TOC approximately; otherwise build a
  frame-header index lazily in the background (header scan only, no decode).

### AAC / ALAC (MP4) — three separable pieces

- **MP4 / ISO-BMFF demuxer — pure Zig, the highest-value pure-Zig investment in
  E.** `ftyp/moov/trak/mdia/minf/stbl`, with `stsd` (codec config: `esds` for AAC,
  `alac` box for ALAC), `stts`/`ctts`, `stsc`/`stsz`/`stco`/`co64`. ~600–900 lines,
  fully specified, gives exact `frame_count` and accurate seeking for free, and
  **the same module yields `moov.udta.meta.ilst` iTunes tags** — the tag reader
  falls out at no extra cost. Do this first in the M4A track: it unblocks scanning
  and browsing every M4A file before either decoder exists.
- **ALAC — port Apple's reference decoder to Zig.** BSD-licensed, ~2k lines,
  structurally simple (predictor + Rice/Golomb). Very testable. Pure Zig, no dep.
- **AAC-LC — the genuinely hard one, no clean answer.** From scratch (MDCT, TNS,
  PNS, M/S, LTP, plus SBR/PS for HE-AAC) is Extremely Hard. `libfdk-aac` has the
  best quality but a patent clause awkward for redistribution; `libfaad2` is GPL;
  `libavcodec` is excluded by policy. **Recommendation:** link `libfdk-aac` as an
  *optional, build-flag-gated, dynamically-detected* system library
  (`-Daac=true`, the same posture as PipeWire's non-pkg-config link). Orca's own
  source stays unencumbered, packagers decide, and when absent AAC files still
  scan, tag, browse and appear in the library — they just return
  `codec_unavailable` on play. **ALAC-only M4A works with zero encumbrance**,
  covering a large share of a curated lossless library.

### Opus / Vorbis (Ogg)

- **Ogg demuxer — pure Zig** (~400 lines): pages, segment tables, CRC32, granule
  positions (exact duration + accurate seeking). Also surfaces the Vorbis comment
  header, which `metadata/vorbis_comment.zig` already parses — direct reuse. Bonus:
  Ogg FLAC comes nearly free with the existing FLAC decoder.
- **Opus — focused binding to system `libopus`** via pkg-config. BSD, ubiquitous,
  tiny; `opus_decode_float` returns exactly the interleaved f32 the `Decoder`
  interface wants. No credible pure-Zig Opus decoder exists (CELT+SILK is an
  enormous amount of DSP). Handle `pre_skip` from `OpusHead` for gapless.
- **Vorbis — `libvorbis`/`libvorbisfile`** via pkg-config (recommended for
  edge-case correctness, and libopus is already a system dep), or vendored
  public-domain `stb_vorbis.c` if avoiding the system dependency matters more.

### ID3v2

`liborca/metadata/id3v2.zig`, pure Zig: v2.3 and v2.4 frames, unsynchronization,
Latin-1/UTF-16/UTF-8 text decoding, `TIT2/TPE1/TPE2/TALB/TRCK/TPOS/TDRC/TCMP/TXXX`,
`APIC` for artwork. Substantial standalone module, entirely independent, and the
*soft* prerequisite for the library looking respectable after a first scan.

| ID | Description | Depends | Difficulty |
|---|---|---|---|
| E1 | ID3v2.3/2.4 reader (pure Zig) | — | Medium–Hard |
| E2 | MP3: minimp3 shim + Xing/LAME + delay trim + seek index | — | Medium |
| E3 | Ogg page/packet demuxer (pure Zig) | — | Medium |
| E4 | Opus via libopus binding | E3 | Medium |
| E5 | Vorbis via libvorbis (or stb_vorbis) | E3 | Medium |
| E6 | MP4/ISO-BMFF demuxer + iTunes tag atoms (pure Zig) | — | **Hard** |
| E7 | ALAC decoder (Zig port of the BSD reference) | E6 | **Hard** |
| E8 | AAC-LC via optional libfdk-aac + build flag + graceful absence | E6 | **Hard** + license decision |

Shared: bump `CodecRegistry.entries` past 16, add conditional registration in
`builtins()`, and loosen `openDetected`'s 64-byte sniff for raw ADTS AAC and files
with leading garbage.

---

## F — GTK app

`apps/linux/main.c` is 271 lines of `GtkStringList` with no selection handler. It
will roughly triple.

1. **A real model.** `GtkStringList` cannot carry a track id — that is *why*
   double-click does nothing. Replace with a `GListStore` of an `OrcaTrackObject`
   GObject (id, title, artist, album, duration_ms) and `GtkListView` ->
   `GtkColumnView`. **The single biggest change**; everything else depends on it.
2. **Activation.** `GtkColumnView::activate` (double-click / Enter) ->
   `orca_player_play_track`. Keep selection separate from activation.
3. **Add Music Folder.** `GtkFileDialog` in folder-select mode ->
   `orca_library_add_root` -> `orca_library_start_scan`. Roots list in preferences.
4. **Scan progress.** `GtkProgressBar` + status label + Cancel in a bottom bar,
   driven by `g_timeout_add(200)` polling `orca_job_snapshot` /
   `orca_library_scan_stats`. Hidden when idle. Reload the page on completion.
5. **Transport bar.** Previous / Play-Pause / Next, a `GtkScale` seek slider bound
   to position/duration, elapsed/total labels, `GtkVolumeButton`. Position via
   `g_timeout_add(200)` -> `orca_player_status_get`. **Suppress position writes
   while the user drags** so the timer doesn't fight the gesture.
6. **Now playing.** Title/artist/album from `orca_player_now_playing`.
7. **Output device.** `GtkDropDown` from `orca_enumerate_output_devices`,
   defaulting to "System Default" (id 0) -> `orca_player_open_default_output`.
8. **Queue pane.** Popover or side pane over `orca_player_query_queue`.
9. **MPRIS.** `mpris.c` currently only toggles. Needs `Metadata`
   (title/artist/album/length/trackid), `Position`, `CanGoNext`/`CanGoPrevious`,
   `Next`/`Previous`/`Seek`/`SetPosition`, `Volume` — all from authoritative
   snapshots, never reconstructed from events.
10. **Structure.** Split into `window.c`, `track_model.c`, `transport.c`,
    `scan.c`, keeping `mpris.c`; update `addCSourceFile` in `build.zig`. A
    GtkBuilder `.ui` template saves more than it costs at this size.
    `libadwaita` would give a modern shell for free — decide explicitly before F1
    rather than retrofitting.

Boundary discipline: "suppress updates while dragging" is presentation and is
fine. "Compute duration from frames and sample rate" is **not** — take
`duration_ms` from the ABI.

| ID | Description | Depends | Difficulty |
|---|---|---|---|
| F1 | `OrcaTrackObject` model + `GtkColumnView` + activate -> play | D2, D4 | Medium |
| F2 | Add-folder dialog, roots list, scan progress + cancel | D1 | Medium |
| F3 | Transport bar, seek slider, volume, now-playing | D2 | Medium |
| F4 | Output device dropdown | D3 | Easy |
| F5 | Queue pane | D2 | Medium |
| F6 | Full MPRIS properties + methods | D2 | Medium |
| F7 | File split, GtkBuilder `.ui`, optional libadwaita | F1 | Medium |

---

## Sequencing

**Critical path:** `W1` -> `A8` -> `A2` -> `A3/A4/A6` -> `A7` -> `B1/B2/B3` ->
`C1/C2` -> `D1/D2` -> `F1/F2/F3`.

**Genuinely parallel:**
- **All of E, from day one.** Touches only `liborca/codec/`,
  `liborca/metadata/id3v2.zig`, and `build.zig`. Zero contention with A/B/C/D.
  E1 and E6 should start immediately — a library scanned without ID3v2 and iTunes
  tags looks broken.
- **W2, W3, W4** any time before B; small and independent of each other.
- **A8** independent of everything except that it must precede A2.
- **A1** and **W1** independent of each other.
- **F7** can be done before D lands, on the current feature set.

**Serialization points that cannot be parallelized away:**
- A2 is one commit. There is no intermediate state where half the tables are
  path-keyed and half are file-keyed and the invariant still holds.
- A7 and D4 both touch `TrackSummary`/`orca_track_view`; do them adjacently.
- B1 and B2 both restructure `core/runtime.zig` substantially; sequential.

---

## Where the existing architecture actively fights these goals

1. **Handle generations do not protect dereferenced pointers.** `handle.Pool` has
   no locking and `OrcaRuntime` takes no lock around pool access. A generational
   handle stops a *stale handle* resolving; it does nothing about a raw `*Zone` an
   engine thread grabbed two iterations ago. Needs acknowledged publication (B1)
   or epoch reclamation. Biggest one, invisible today only because nothing is
   concurrent yet.
2. **`RenderPipe`'s single `generation` conflates "seek epoch" (must discard) with
   "which track" (must not discard).** Accurate now-playing and gapless cannot both
   be correct without splitting it (W3). Fix before the ABI freezes `track_id`.
3. **`RenderContext` holds pointers into the Player.** Player/Zone independence is
   claimed in the docs but is not structurally true, and becomes a live RT-thread
   use-after-free the moment Zones outlive Players.
4. **`observed_files.path` is load-bearing for five subsystems simultaneously.**
   There is no incremental migration that keeps "paths are not identity" satisfied
   halfway. Accept the single wide commit; back it with a v7 fixture database.
5. **`CodecRegistry` is one-descriptor-per-container-format**, but MP4 carries two
   codecs and Ogg carries three. Workable via internal dispatch; the abstraction is
   a size too small.
6. **`WriteLane` is a spinlock.** Harmless at zero worker threads; a burned core
   the moment a scan job holds it across a 256-row transaction while the UI reads.
7. **The scanner-vs-projection boundary interprets a locked law.** Preserved
   because the *projection* reads `EffectiveMetadata`, not raw observations. Write
   it into `docs/database.md` (A6) or it will be reverted by someone reading
   `CLAUDE.md` literally.
8. **`docs/audio-engine.md` describes several behaviors as if they exist** that
   exist only as models — Zone recovery, Zone latency reporting, DSP chain
   publication. The docs are the *target*, not the current state; treat them as the
   spec for B1/B2.
