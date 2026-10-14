# liborca guidance

## Ownership and API

`liborca` owns all library, playback, audio, metadata, mutation, provider, and
job semantics. Expose client behavior through `Runtime` and public types from
`root.zig`; do not move engine policy into a frontend. Runtime-visible objects
use typed generational handles. Preserve dependency-ordered, idempotent
shutdown: work, Zones, Players, then Libraries.

Each subsystem `root.zig` re-exports its files and imports them in its test
block. Add new files to both lists. Interfaces use context-and-vtable structs
where platform or ABI adapters require them.

Read [the API reference](../docs/api.md) and
[runtime ownership](../docs/api.md#runtime-ownership-and-shutdown).

## Control plane and jobs

- `OrcaRuntime.pump` runs in a fixed order: at most `CommandQueue.capacity`
  commands, reap finished workers, start waiting host Jobs, take watcher
  reports, start a due maintenance unit, save Player state. Never loop on
  commands until the queue is empty; a host that keeps submitting would never
  leave its pump.
- Raise `HostSignal` after the change it announces is visible, and clear it on
  the control lane before the host reads what changed, so a raise in between
  is not lost. The waker fires only on the edge to pending and is never called
  from a render callback.
- Tear down only through `OrcaRuntime.shutdown`: refuse commands, cancel and
  join every worker through `work.Registry.drain`, close Zone outputs, then
  destroy Zones, Players and Libraries. A thread that holds a raw pointer into
  a runtime object must be registered, or it outlives what it reads.
- One host Job runs per Library; others wait in a queue of `max_waiting_jobs`
  that fails when full rather than growing. Waiting Jobs start only from
  `pump`. A paused Library starts no Job, maintenance unit or reconcile, and
  pausing never cancels a running Job.
- Maintenance starts only when no Player plays and no host Job is live or
  waiting; a host Job or playback preempts it through `preemptUnit`.
- Job progress and events are published from the control lane only; a worker
  reports through its registration and `HostSignal`.

## Persistence

Each Library owns one SQLite database and a serialized logical write lane.
Repositories return bounded caller-owned values, never SQLite rows or
statements. Paths never define musical identity.

- Install the OFD lock replacement (`database/sqlite_locks.zig`) before any
  SQLite connection opens; never open a database earlier in the process or
  bypass the override.
- A file Library opens only in WAL mode. Every write commits behind
  `SchemaGuard`, so a process never commits to a file whose `user_version`
  differs from the one it opened.
- Each migration and its `user_version` bump run in one transaction; a version
  above `current_version` is refused without touching the file. A schema
  change adds a step, a `tests/upgrade_fixtures/seed-v<N>.sql` and a
  regenerated `fixtures/library/upgrade/v<N>.sqlite`
  (`zig build regenerate-upgrade-fixtures`).
- The `.pre-v<N>.sqlite` copy is written inside the upgrade's
  `BEGIN IMMEDIATE` transaction before the first step; when it cannot be
  written the open fails with `error.PreUpgradeCopyFailed`.
- The database layer picks the read or write connection by write-lane
  ownership; call sites never choose one. File bytes are read before the write
  transaction, never under the write lane.
- Pages stay at or below `columns.max_page`; a larger request is refused, not
  clamped. Every generated Track `ORDER BY` ends in `tracks.id`.
- A path lives only in `locations` and `mutation_operations`. A path joins an
  existing file only through `FileRepository.resolveForBytes`, never by quick
  hash alone.
- `files.recording_id` is written only through
  `FileRepository.setRecordingLocked`. Trigger-maintained columns
  (`genre_totals`, `sort_lufs`, `first_genre_id`, `recording_play_stats`) are
  never set directly. Moving Tracks to another Release carries its state
  through `carryReleaseState` before the old Release is pruned.
- Enums stored by number (`MutationState`, `metadata.Field`, `ReasonKind`,
  analysis kinds) are append-only.

## Storage and scanning

- Check the root's volume (`library/volume_check.zig`) before every scan and
  reconcile; on failure walk and sweep nothing, or an unmounted drive marks
  every file missing.
- Only a run that completed uncancelled marks locations missing or deletes
  folder images. A subtree sweep is bounded by `volume_id` and the uri range
  `[prefix/, prefix0)`, so `A/Newer` is never swept for `A/New`. Only explicit
  root removal forgets files.
- `last_seen_generation` is stamped with `max(stored, new)`, and a walk error
  stamps the run's generation so the sweep keeps that row.
- Claim `<database>.orca-scan.lock` before a walk and hold it until the sweep
  ends; it stays separate from the journal lock.
- The walk and the watcher skip Orca's own files by name; a new Orca-owned
  file name is added to `watch.Ignore.matches` or `isOrcaTemporaryName`.
  Symbolic links are never followed.
- `OffsetSource` forwards `identity` unchanged, or every ID3-prefixed file
  looks modified on every scan.
- The watcher thread never touches databases, handle pools or the work
  registry; its hints are advisory and only the reconcile Job writes.
- `libraryRelocateRoot` runs as one `BEGIN IMMEDIATE` transaction under both
  locks and does not run mutation recovery.

## Metadata and file mutation

Keep observed file metadata, Orca metadata, and effective metadata separate.
Scanner observations never change Track metadata or source files. User locks
outrank automatic resolution.

- A tag write, undo, prune or relocation holds `metadata.JournalLock` for its
  whole run; a held lock returns `error.MutationInProgress` and changes
  nothing. Never delete `.orca-journal.lock` or `.orca-scan.lock`: a process
  holding the old file would share ownership with one holding a new file.
- Run `recoverPendingMutations` under the lock before any write, undo or
  prune, and fail without journaling when it fails.
- A `MutationPlan` is sealed with a BLAKE3 digest over deep-copied actions,
  approved by id and digest, and re-verified in `beginExecution`.
- Journal every action of a group before any filesystem change. A write
  stages and fsyncs, copies and verifies the backup, revalidates identity,
  then renames and fsyncs the directory, so the original or a verified copy
  exists at every step. Stage and backup keep the file's permission bits.
- Never change a read-only file (`requireWritableFile`) or a file's
  permissions.
- Undo checks every operation first, moves the group to `undoing` in one
  transaction (`beginUndo`) and restores in reverse order. A changed file or
  damaged backup becomes `needs_reconciliation`, never a reported rollback.
  `recovered_message` stays unchanged; history distinguishes recovery from
  undo by it.
- Delete a backup before clearing its journal path; keep the backups of groups
  that are undoing or need reconciliation.
- Tags are written only from values in effect; other differences are listed as
  conflicts. The tag-write Job cannot be cancelled once started.

## Codecs

- Each C or C++ codec library stays behind its one shim in `codec/`, mpg123
  behind the declarations in `mp3.zig`; no library type, and no C type beyond
  fixed-width integers, appears above it.
- Never replace libFLAC: `files.audio_hash`, loudness, peaks and fingerprints
  depend on bit-exact output, and `fixtures/audio/midside-reference.flac`
  guards it.
- A seek at or past the declared frame count succeeds and the next read
  returns zero frames. A recoverable defect is reported through
  `Decoder.damage`, not as a failed open.
- `codec/mp4.zig` front-pads a packet shorter than its sample-table duration
  with silence; libxaac withholds the start of the first access unit, and
  without the padding every later frame shifts early.
- Keep the ALAC build flags (`-fno-sanitize=shift-base`, `-fwrapv`) and the
  zero-padded packet copy in `alac_shim.cpp`; `scripts/alac-sanitize.sh` must
  pass after any ALAC change.

## Analysis

- One decode per Track feeds every analyser in `analysis/service.zig`.
- An `analysis_results` row is keyed by kind, algorithm, version, parameter
  hash and content hash. Bump the version or parameter hash whenever an
  analyser's output changes, or stale rows are served as current. The
  undecodable verdict is recorded against the decoder set, so adding a decoder
  re-admits those files.
- The audio hash (`analysis/fingerprint.zig`) changes only with a version
  bump; equal hashes drive identical-audio groups and cleanup.
- Embedding rows are keyed by model; never compare vectors across models. A
  model file is checked against its compiled-in SHA-256 before loading.
- Analysis helper threads never touch SQLite; results reach the database
  through the write lane in batches.
- Each health issue kind has one owning pass; another pass never resolves or
  rewrites it. Dismissals are keyed by `quick_hash` and never reopened.
- Duplicate detection stays conservative (bounded buckets, high threshold);
  consistency checks propose `metadata_proposals` and never edit tags.

## Real-time audio

The render callback never allocates, frees, locks, waits, performs I/O, or
touches SQLite. Keep callback-owned data preallocated and communicate through
the bounded SPSC queues and atomics. Decode and DSP run on the engine thread.
Control changes that require it quiesce the engine.

Epoch determines whether audio is stale; `entry_serial` identifies audible
queue entries. Do not combine them or infer audible state from the decode
cursor. Players decode canonical PCM once, and each Zone owns an independent
pool and output path. PipeWire headers and native lifetimes remain behind the C
shim; stream creation and destruction remain off the callback.

- Position is published as one word from `render.packPosition` with a single
  store and load; splitting it pairs a new epoch with old frames.
- A new zone set is published only after the engine acknowledges it, and the
  old set is freed only after that; the callback holds raw pointers into it.
- Device targeting fails closed: a named device that is missing is an error,
  never the default output.
- "Bit-perfect" is reported only when no gain, DSP, volume or resampling
  touches the samples. A disabled DSP stage leaves samples unchanged.
- A queue entry that fails to open is reported through `OpenFailureSlot`, not
  dropped.

## Providers

All traffic uses the single bounded, rate-limited `network.Gateway`. Preserve
offline mode, provider leases, rate limits, durable backoff, service identity,
and response bounds. Credentials come from host secure-storage adapters and
never enter a Library, log, settings file, fixture, or durable cache key.
Matches remain reviewable proposals until accepted; acceptance changes Orca
metadata without writing media files.

- A request without a client identity fails with `ClientIdentityRequired`;
  never send anonymously.
- Never lower a service's `minimum_interval_ms`. `Retry-After` on 429 and 503
  is honoured and persisted in `provider_state`, so a restart does not resume
  early.
- Plain `http` is allowed only to loopback hosts. Redirects are bounded, stay
  on HTTPS within the allowed host, and carry no credentials.
- Validate MusicBrainz ids with `metadata.isMusicBrainzId` before building a
  URL from them.
- A listen recorded while scrobbling was off is never sent.

Provider and retry tests use `network.testing.ScriptedTransport` and
`TestClock`. Do not contact live services or sleep on wall-clock time.

## Discovery

- Radio sessions and candidate pools stay bounded (`max_session_exclusions`,
  `max_session_adjustments`, `max_session_recent`, `max_pool`).
- `samplePlayer` stays free of SQLite, I/O and allocation; Radio's database
  work runs in the top-up worker in `core/runtime_radio.zig`.
- Hated, Not-for-me, live and recently played Tracks are excluded before
  scoring; the recent filter relaxes only through `relaxed_recent`.
- A missing embedding or audio feature scores neutral (`neutral_audio`), never
  zero or excluding.
- Daily Mixes are replaced in one `BEGIN IMMEDIATE` transaction.

## C ABI

The C ABI exposes opaque ownership, generational handles, POD snapshots, and
bounded callback-scoped views. No Zig container, SQLite row, statement, or
internal layout crosses it. Returned strings are valid only during their
callback. All calls for one runtime stay on its creating thread except the
documented wake and credential callbacks. Keep `tests/c_abi_smoke.c` on the
public end-to-end path. Read [the C ABI reference](../docs/c-abi.md).
