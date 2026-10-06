# Storage and scanning

This file covers how Orca reads files: the source interface, container sniffing,
scanning and reconciliation, volume checks, root relocation, property backfill
and filesystem watching. [database.md](database.md) covers the tables these
write.

## Sources

Decoders and analyzers consume `ReadableSource`, a capability interface for
positional reads, total size and observed identity. It exposes neither path
strings nor filesystem handles, so non-local sources can implement it.
`LocalFileSource` is the desktop implementation: it captures size, inode and
modification time at open and reads at offsets without moving a shared stream
position.

## Container sniffing

`storage/format.zig` recognizes WAV, AIFF, FLAC, MPEG audio, MP4, Opus, Vorbis,
WavPack, QOA and ADTS AAC from source bytes, never from file extensions.
`format.detect` returns the container and the offset where its encoded stream
begins.

- The offset is not always zero: an ID3v2 tag may precede any container,
  including FLAC. Detection reads 64 bytes at offset zero and, when they are an
  ID3v2 header, 64 more past the tag. The tag size is computed from its header
  and footer flag, never estimated, because formats whose magic must land on an
  exact byte fail on a small error.
- When the bytes past the tag are unrecognizable or an MPEG frame header,
  detection reports MPEG audio at offset zero and the MPEG decoder owns tag and
  frame resync.
- `CodecRegistry.open` and `openDetected` give the codec a `source.OffsetSource`
  over the suffix when the offset is non-zero. No codec parses tags, and every
  position a decoder computes is relative to the start of the stream.
- An `OffsetSource` shifts reads and size but forwards `identity` unchanged. The
  scanner compares identity with the file's `locations` row, so a shortened
  identity would make every tagged file look modified on every scan.

## Incremental scanning

The scanner walks a root recursively and compares each file's path and identity
(inode, size, modification time) with the path's `present` row in `locations`
under the root (`LocationRepository.unchangedLocationId`). An unchanged file
costs no format or metadata work. Changed audio files commit in bounded
transactions (256 rows by default) through the Library's write lane; unsupported
and transiently unreadable files are counted without invalidating successful
batches. A cancelled or interrupted scan resumes by restarting, because
committed unchanged identities are skipped. `orca-cli analyze PATH` records a
location without reading tags: a new one belongs to no root, and an existing one
keeps its scan's identity so the next scan re-reads the path.

A changed file is probed through the codec registry for what its container
declares (`files.codec`, sample rate, channels, sample width, frame count, which
becomes `files.duration_ms`); only headers are read. A file that sniffs as audio
and then refuses to open is recorded with no properties.
`ScanRequest.reprobe_all` (`orca-cli scan --reprobe`) re-reads and re-probes
every file. On the same path the scanner records the pixel size and byte hash of
changed embedded pictures and folder images, so settling `artwork_problem` never
reads image bytes (see [database.md](database.md#release-artwork)).

### Skipped names

The walk and the watcher skip Orca's own files by name anywhere under the root:

- tag-write temporaries (`isOrcaTemporaryName`): names containing `.orca-stage-`
  or `.orca-backup-`, names ending in `.recovery-displaced`, and hidden names
  containing `.orca-restore-`. Recording one would list a second Track with the
  old tags;
- the database and its `-wal`, `-shm`, `-journal`, `.orca-journal.lock` and
  `.orca-scan.lock` files;
- the volume marker `.orca-volume-id`;
- the backup directory `<database>.orca-backups`, which is not walked into
  ([Tag-write files](metadata.md#tag-write-files)).

Symbolic links are not followed.

### Scan runs and sweeps

Each walk of a root opens a `scan_runs` row with the root's next generation and
stamps every location and folder image it reaches. Only a run that ends
`completed` sweeps: it marks unreached locations `missing` and deletes unreached
folder images. A `cancelled` or `failed` run (the root's directory is gone or
cannot be opened, or listing a directory fails) sweeps nothing; the exception is
a subtree reconcile that fails on one directory, which still sweeps the
directories whose walks completed.

- A directory that cannot be entered, and a file or image that cannot be read,
  add one to `ScanStats.errors` and do not fail the walk. Their recorded rows
  are stamped with the run's generation, so the sweep keeps them.
- A stamp keeps the higher of its stored generation and the one being written,
  so an earlier walk cannot lower a stamp and make a later sweep mark a present
  file `missing`. Generations count per root.

`ScanStats` reports `stage` (`discover`, `read_tags`, `done`), `current_path`,
`files_seen`, `albums_found`, `marked_missing` and `volume_changed`. Before
walking, a Job runs `scanner.countFiles` (the same walk and skips, opening no
file) so `total_units` is files walked, not audio files. `orca-cli scan` prints
`progress stage= files= total= albums= current=` lines, with `total=-` while
counting.

## Estimating a folder before it is a root

`estimateAudioFiles(io, allocator, path, token, limit)` counts the audio files
under a folder that is not a root, so a host can show a library's size before
adding it. It walks as a scan does, counts a file when `storage.format.detect`
names an audio format, reads nothing past a header and writes nothing. It stops
at `limit` (`estimate_default_limit`, 100,000, also for a zero limit through the
C ABI) and sets `FolderEstimate.truncated`. It polls `token` between entries and
returns `error.Cancelled`. `orca-cli estimate PATH` prints `audio_files=N
truncated=no|yes`.

## Folder-scoped reconciliation

`Runtime.startLibraryReconcile(library, ReconcileRequest)` starts a `reconcile`
Job over one registered root: `.whole_root` is a scan of the root; `.subtrees`
walks only the named directories, relative to the root, and marks missing only
locations under them. `orca-cli reconcile DATABASE ROOT_ID [DIR...]` runs it.

- A directory must be non-empty, relative, and without empty, `.` or `..`
  components, or it is refused with `error.InvalidReconcileDirectory`. A
  directory inside another listed one is walked once.
- One scan run and generation cover all the directories, and each uri is built
  as a full scan builds it.
- A directory that is gone or not a directory is a completed walk that found
  nothing: everything under it becomes `missing`.
- A directory is swept only if its recursive walk completed and the Job was not
  cancelled. A directory whose own listing fails keeps its locations and the Job
  ends `failed`; the other directories are still walked and swept.
- The sweep is bounded by `volume_id` and the uri range `[prefix/, prefix0)`, so
  `A/Newer` is never swept for `A/New`.

## One walk at a time

A runtime never runs two walks of a Library at once: a host scan or reconcile
waits for the Library's Job slot (see
[control-plane.md](control-plane.md#one-job-per-library-and-the-waiting-queue)),
a host walk stops the watcher's reconcile first, and a walk that would still
overlap another is refused with `error.LibraryScanRunning` (`ORCA_STATUS_BUSY`
through the C ABI).

Across runtimes and processes sharing a database file, a walk holds an exclusive
`flock` on `<database>.orca-scan.lock` from before its scan run begins until its
sweep ends, however it ends; the operating system drops it when a process exits.
The control lane takes it without waiting, so a refused walk adds no scan run
and changes no location. A Job that waited for its slot and then meets a held
lock ends `failed`; the watcher keeps a refused reconcile's changes and retries
after `WatchOptions.quiet_ms`. The walk lock is separate from the [journal
lock](metadata.md#the-journal-lock), so a walk and a tag write never wait for
each other. A walk holding the lock first ends every run of its root still
`running` as `failed`, since no live walk owns it. A Library with no database
file has no lock file and coordinates walks only within its runtime.

## Volume check before a walk

An unmounted drive leaves its mount point as an empty directory, so a walk would
find nothing and its sweep would mark every file `missing`. Before every scan or
reconcile of a root, host-started or automatic, the Job resolves the volume the
root's path lies on as `ensureRoot` does (with `allow_persist` off, so nothing
is written) and compares it with the volume the root is bound to
(`library/volume_check.zig`).

- A root bound to a filesystem UUID (`uuid:`) or a persisted marker (`ulid:`,
  from `.orca-volume-id` at the mount root) passes only when its path resolves
  to the same key.
- A root bound to `root:<id>`, because the platform named no volume, passes
  while the platform still names none. Such a root on an unmounted drive whose
  parent filesystem has no UUID either is not caught.
- A root on the fallback volume (`volumes.id` 1) always passes.

A root that fails is neither walked nor swept: the Job counts one error, ends
`failed`, sets `ScanStats.volume_changed` and marks nothing `missing`; other
roots of the scan are still walked. `libraryAddRoot` is the one path that
rebinds an existing root to the volume its path is on, which accepts a
replacement drive at the same path. `orca-cli scan DATABASE ROOT` scans a
registered root without adding it and fails when the check fails; `orca-cli
add-root DATABASE ROOT` rebinds it.

## Unavailable and relocated roots

A root is available when its directory opens for reading and passes the volume
check; while it is unavailable, every Track under it is. `libraryRootPage`
reports `LibraryRoot.available`, `libraryAvailability` gathers the unavailable
roots, their Tracks and the Releases left with nothing to play, and
`libraryReleasesAvailable` answers per Release (`orca-cli availability DATABASE
[RELEASE_ID...]`), so a frontend dims what cannot play without deciding
availability itself.

Playback applies the same test. When a Track's file cannot be found, an
unavailable root fails the open with `TrackFolderUnavailable` and leaves the
location alone; only a missing file under an available root is marked `missing`
and fails with `TrackFileMissing`.

`libraryRelocateRoot` (`orca-cli relocate-root DATABASE ID PATH`) repairs a root
that moved. It refuses a path that is not absolute or not a readable directory,
binds the path to its volume as `libraryAddRoot` does, and rewrites the root,
its locations, its folder images and the tag-write journal's paths under it (see
[metadata.md](metadata.md#relocated-roots)) in one `BEGIN IMMEDIATE`
transaction, so a crash leaves the root wholly old or wholly new. Root, file,
location and Track ids survive, so play counts, ratings, playlists and edits
stay attached. It refuses with `error.RootPathOverlaps`, leaving no new volume
row, a path that:

- is another root's, or inside or around one;
- already holds locations or folder images of another root or of none;
- is inside or around the old path while the old directory still exists;
- is nested with the old path so that a moved location or folder image would
  land on another of the root's.

The relocate takes the [walk lock](#one-walk-at-a-time) and is refused with
`error.LibraryScanRunning` while another runtime or process walks the Library.
The reconcile Job it starts holds the lock from then on, so changes made while
the root was elsewhere are noticed and no other walk runs between.

## Repairing properties without a walk

Only changed bytes are probed, so a row written without probing keeps null
`duration_ms`, `sample_rate` or `channels`. `library/property_backfill.zig`
repairs those rows by `files.id` without walking a filesystem, as the Job
`Runtime.startLibraryPropertyBackfill` (`orca_library_start_property_backfill`,
`orca-cli backfill`).

- Selection is a null `duration_ms`, `sample_rate` or `channels`, or `codec =
  ''`, served by the partial index `files_incomplete_properties`.
  `repository.incomplete_properties_predicate` is its one definition, because
  SQLite matches a partial index by expression. `bit_depth` is not a term: a
  transform codec has none.
- It commits one page at a time and checks cancellation between rows. There is
  no checkpoint: which rows owe a probe is a property of the rows, so a second
  run resumes by asking again. `--force` re-probes complete rows and is not
  resumable.
- A row whose file is gone or is not audio is passed over with no health issue
  (`locations.state` models absence). A file that opens and then fails to decode
  raises `unreadable_file`, a kind the backfill owns outright so clearing it
  cannot erase an analysis finding.
- Each committed batch is reprojected scoped to its file ids. A FLAC whose
  STREAMINFO declares `total_samples = 0` keeps a null duration.
- After the files, the Job runs `library/artwork_backfill.zig` over unmeasured
  covers ([database.md](database.md#release-artwork)).

`Runtime.libraryBackfillPending` (`orca_library_backfill_pending`) counts only
what the Job can repair: it leaves out missing files, files on an offline root,
formats no codec decodes, files with an `unreadable_file` issue, and covers of
such files. `orca-gtk` starts the Job once per launch when either count is
non-zero. `library/analysis_pass.zig` is also keyed on `files.id` but decodes
whole files ([analysis.md](analysis.md#the-pass)).

## Watching roots

`Runtime.libraryWatch(library, WatchOptions)` watches every enabled root of a
Library and reconciles changes through the [folder-scoped
reconcile](#folder-scoped-reconciliation). `libraryUnwatch` stops it,
`libraryWatchStatus` reports it, and `orca-cli watch DATABASE` runs it. Only
Linux has a watcher; elsewhere `libraryWatch` returns
`error.WatchingUnsupported`. Watching speeds reconciliation up and replaces none
of it: a scan still finds anything no event reported.

Each watched Library has one watcher thread (`library/watch_linux.zig`) blocking
in poll(2) on a nonblocking inotify descriptor and an eventfd, with one watch
per directory. `IN_MODIFY` is not watched, so a file being written is reported
once, on close. An event marks a directory dirty relative to its root. A root's
dirty set is published after `WatchOptions.quiet_ms` of quiet (default 2000) or
`max_delay_ms` after its first unpublished change (default 30000); it holds at
most 64 directories, a directory inside another is absorbed, and one more makes
the whole root dirty. `Runtime.pump` merges what watchers published per root and
starts a `reconcile` Job for one root at a time, reconciling each dirty
directory recursively. One that recorded or marked missing a file publishes
`Telemetry.library_changed`.

### Invariants

1. The watcher thread touches only its own state, its descriptors, the queues to
   the control lane, the host signal, and the directories, mount table and
   volume markers it reads. It never touches a database, a handle pool or the
   work registry; the control lane hands it each root's recorded volume key.
2. Hints are advisory. Only the scanner, run by the reconcile Job, writes files
   and locations.
3. A Library runs at most one automatic reconcile, never while a scan,
   reconcile, projection or tag write of that Library runs. A host scan,
   reconcile or tag write first cancels and joins a running automatic reconcile
   without a `job_finished` event, and its root waits again as a whole root. A
   host scan of a whole root takes over the root's waiting changes and returns
   them whole if it does not succeed.
4. Every arm marks its root dirty as a whole and publishes it at once, because
   nothing that changed while the root was unwatched produced an event.
5. A root that is deleted, moved or unmounted, is on another volume than the one
   recorded, or cannot be watched when armed is unavailable and never
   reconciled; its automatic reconcile is cancelled and its locations keep their
   state, so an unmounted drive never empties a library. An automatic reconcile
   that fails the volume check makes its root unavailable the same way.
6. Every `WatchOptions.degraded_rescan_ms` (default 15 minutes) the watcher
   retries each unavailable root, arming and reconciling it whole once its path
   is a directory on its recorded volume, and walks a degraded root again,
   adding the watches it can.
7. Everything is bounded: 16 commands to the watcher, 256 hints from it, 64
   directories per root, a 64 KiB read buffer.
8. Orca's own files never dirty anything ([skipped names](#skipped-names)). A
   tag write still dirties its file's directory once, when the staged copy is
   renamed over the file.

### Limits

- Watches count against `fs.inotify.max_user_watches`. On `ENOSPC` the watcher
  keeps the watches it has, counts the root in `roots_degraded`, reports
  `watch_limit_reached` and sets the Library's state to `degraded`; the root is
  reconciled whole every `degraded_rescan_ms` until a walk adds every watch.
- Each watched Library uses one inotify instance, counted against
  `fs.inotify.max_user_instances`; `libraryWatch` returns
  `error.WatchInstanceLimit` when none is left.
- A directory reachable by two paths (a bind mount) is watched once, under the
  first path found; a root inside another watched root is watched as part of
  whichever was armed first. An unmount below a root drops its watches and
  dirties nothing. A directory the watcher cannot read is not watched.
- An unavailable root that returns, and changes in a degraded root's unwatched
  directories, are found at most `degraded_rescan_ms` late.
- On `IN_Q_OVERFLOW` every root is walked again for new directories and
  reconciled whole. When 16 commands are already waiting, the control lane
  rebuilds the watcher from the Library's roots and every root is armed and
  reconciled again.
