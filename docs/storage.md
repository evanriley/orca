# Storage capabilities

Decoders and analyzers consume `ReadableSource`, a small capability interface
for positional reads, total size, and stable observed identity. It deliberately
does not expose path strings or filesystem handles.

`LocalFileSource` is the desktop implementation. It owns an open file, captures
size/inode/modification identity at open time, and supports offset reads without
changing shared stream position. Provider, mobile, and permission-sensitive
sources can implement the same contract without pretending to be local paths.

Container sniffing uses source bytes rather than filename extensions.
`storage/format.zig` recognizes WAV, AIFF, FLAC, MPEG audio, MP4, Opus, Vorbis,
WavPack, QOA and ADTS AAC.

## What sniffing guarantees

`format.detect` answers two questions together: **which container** the bytes
are, and **where its encoded stream begins**. The second is not always zero. An
ID3v2 tag says nothing about what follows it, and some taggers staple one to the
front of a FLAC stream. Reading `ID3` as "this is MPEG audio" would hand those
files to the MPEG decoder, which fails on the magic bytes, so they would neither
play nor probe.

- **The tag is measured, not guessed.** The declared size is four syncsafe bytes
  at offset 6, seven significant bits each, and excludes both the ten-byte
  header and the optional ten-byte footer that flag `0x10` announces. An error
  of ten bytes still "works" for MPEG audio, which resyncs on the next frame
  header, and silently breaks every format whose magic must land on an exact
  byte.
- **Two reads, not one long one.** Detection reads 64 bytes at zero, and when
  those are an ID3v2 header, 64 more at the first byte past the tag. A tag
  carrying artwork routinely runs to hundreds of kilobytes, so the payload check
  cannot be folded into a longer first read.
- **MPEG audio stays byte zero.** If the bytes past the tag are unrecognizable,
  or are an MPEG frame header, detection reports MPEG audio starting at zero.
  That is what an ID3v2 tag fronts in all but a handful of files, and the MPEG
  decoder owns tag and frame resync across the whole file, including the
  trailing ID3v1, APEv2 and Lyrics3 tags it must exclude from the audio region.
  `sniffBytes`, which is pure over a prefix and often cannot reach past the tag,
  answers the same way.
- **Neither does the artwork reader.** `metadata/artwork.zig` resolves the
  prefix the same way before asking a container for its cover, so an
  ID3-fronted FLAC gives up its `PICTURE` block like any other. Read from byte
  zero, such a file looks like an MPEG file with no `APIC` frame.
- **The decoder never sees the tag.** `CodecRegistry.open` and `openDetected`
  hand the codec a `source.OffsetSource` view of the suffix when detection
  reports a non-zero payload offset, and the returned Decoder owns that view for
  its whole life, releasing it strictly after the codec. `open` resolves the
  prefix as well as `openDetected` does, because the scanner opens with the
  container it already sniffed. No codec learns what a tag is.
- **Offsets do not change identity.** An `OffsetSource` shifts reads and size
  but forwards `identity` unchanged. Identity answers "which file is this and
  has it changed", which the scanner compares against the file's `locations`
  row; a view that reported a shortened size would make every tagged file look
  modified on every scan.
- **Seeking is in stream frames.** Because the offset lives in the source view
  rather than in a codec, every byte position a decoder computes — a FLAC
  seektable entry, an MPEG frame index — is already relative to the start of the
  stream, and a seek in a tagged file lands exactly where the same seek in the
  untagged stream does.

## Incremental scanning

The scanner recursively walks a configured root, opens candidate files through
`LocalFileSource`, and compares path plus storage identity (inode, size and
modification time) against the path's `present` row in `locations`
(`LocationRepository.unchangedLocationId`). Unchanged files avoid format or
metadata work. Changed audio files commit in bounded transactions through the
Library's shared write lane; unsupported and transiently unreadable files are
counted without invalidating successful batches.

A changed audio file is also probed through the codec registry for what its
container declares — the encoding identifier that becomes `files.codec`, plus
sample rate, channels, sample width and frame count, which becomes
`files.duration_ms`. Only headers are read, never audio. Probing is on
the changed path alone: the unchanged skip is what makes a rescan of a large
library nearly free, and reopening every file would spend that. A file that
sniffs as audio and then refuses to open is recorded with no properties and the
scan continues, exactly as an unreadable tag is handled — malformed and
truncated audio is normal in a real library. A transform codec such as MPEG has
no sample width to declare, and that stays unknown rather than being invented.

The walk skips the files a tag write puts beside the music, because each is a
temporary of Orca's and a scan that recorded one would list a second Track with
the old tags:

- hidden names containing `.orca-stage-` or `.orca-restore-`;
- names from journals that predate the backup directory: those containing
  `.orca-backup-` or `.orca-stage-`, or ending in `.recovery-displaced`.

Backups live in `<database>.orca-backups`, beside the database, which the walk
reaches only if the database itself sits inside a library root. Keep the
database outside every root. [Tag-write files](metadata.md#tag-write-files)
covers the layout and the disk space backups and undo need.

Cancellation is checked before filesystem work and between entries. A cancelled
or interrupted scan is resumable by restarting it: already committed unchanged
identities are skipped, so no traversal-order checkpoint is required.
[Watching roots](#watching-roots) drives the same reconciliation from
filesystem events.

## Folder-scoped reconciliation

`Runtime.startLibraryReconcile(library, ReconcileRequest)` starts a `reconcile`
Job over one registered root. With `.whole_root` it is a scan of that root.
With `.subtrees`, it walks only the named directories, given relative to the
root, and marks missing only locations under them. `orca-cli reconcile
DATABASE ROOT_ID [DIR...]` runs it.

- Directories are in normal form: not empty, not absolute, and no empty, `.`
  or `..` component. Anything else is refused with
  `error.InvalidReconcileDirectory`. A directory inside another listed one is
  walked once, as part of the outer one.
- A subtree walk builds each uri as a full scan does, so a file keeps the
  location a full scan gave it.
- One scan run, and one generation, covers all of a job's directories.
- A directory that is gone, or is no longer a directory, counts as a completed
  walk that found nothing. Everything recorded under it becomes `missing`.
- A directory is swept only if its recursive walk completed and the job was
  not cancelled. A directory whose walk failed, for example on an unreadable
  subdirectory, keeps every location it holds, and the job ends `failed`. The
  other directories are still walked and swept.
- The sweep is bounded by `volume_id` and the uri range `[prefix/, prefix0)`
  on the `(volume_id, uri)` unique index, so a sibling such as `A/Newer` is
  never swept for `A/New`, and the sweep reads only that directory's rows.

A runtime refuses a second scan or reconcile of a Library while one runs, with
`error.LibraryScanRunning` (`ORCA_STATUS_BUSY` through the C ABI). Each walk
stamps the locations it reaches with its own generation, so a second walk
could overwrite the first walk's stamp and the first walk's sweep would then
mark present files `missing`. The check covers jobs in one runtime only; two
processes scanning the same database are not coordinated.

`ScanStats.marked_missing` counts the locations a scan or reconcile marked
`missing`.

## Volume check before a walk

A drive that is not mounted leaves its mount point as an empty directory on
the parent filesystem. A walk of it would find nothing and its sweep would
mark every file on the drive `missing`. So before every scan or reconcile of a
root, host-started or automatic, the job resolves the volume the root's path
lies on now and compares it with the volume the root was bound to
(`library/volume_check.zig`):

- The current volume is resolved as `ensureRoot` resolves it, with
  `allow_persist` off: nothing is written, and no `volumes` row is created.
- A root bound to a filesystem UUID (`uuid:`) or a persisted volume marker
  (`ulid:`, from `.orca-volume-id` at the mount root) passes only when its
  path resolves to that same key.
- A root bound to its own `root:<id>` key, because the platform named no
  volume when it was added, passes while the platform still names none for
  its path. Such a root on an unmounted drive whose parent filesystem has no
  UUID either is not caught.
- A root on the legacy volume (`volumes.id` 1, from migration 8) records no
  identity and always passes.

A root that fails the check is neither walked nor swept: the job counts one
error, ends `failed`, and marks nothing `missing`. Other roots of the same
scan are still walked. The check runs for `startLibraryScan`,
`startLibraryReconcile` and automatic reconciles; `orca-cli scan DATABASE
ROOT` first adds the root again, which binds it to whatever volume its path
resolves to, so only an already registered root is protected there.

## Repairing properties without a walk

The unchanged fast path has a cost, and it is not paid at scan time. A file the
scanner skips is never probed, so a row written without probing keeps null
`duration_ms`, `sample_rate` and `channels` for ever — a music collection's
bytes essentially never change, and only changed bytes are re-read. A Track with
a null duration has nothing for a transport bar to draw against and shows no
length in a listing.

`library/property_backfill.zig` is the repair, and it is the same shape as the
projection: keyed on `files.id`, no filesystem walk, reachable as a runtime job
(`Runtime.startLibraryPropertyBackfill`,
`orca_library_start_property_backfill`, `orca-cli backfill`).

- **Selection is one indexed search.** `SELECT ... WHERE files.id > ? AND
  (duration_ms IS NULL OR sample_rate IS NULL OR channels IS NULL OR codec =
  '')` is served by the partial index migration 10 creates over exactly that
  predicate. The predicate has one definition,
  `repository.incomplete_properties_predicate`, shared by the index and the
  query, because SQLite matches a partial index by expression rather than by
  meaning. The index holds only the broken rows, so it shrinks as the pass
  works and asking the question on a healthy library costs one B-tree probe
  rather than 500,000 row reads. `bit_depth` is deliberately not a term: a
  transform codec has no sample width to declare, so a null there is an answer.
- **Bounded and resumable.** One page per bounded commit, cancellation checked
  between rows, and a cancelled run still commits what it already probed. There
  is no checkpoint of its own: which rows still owe a probe is a property of
  the rows, so a second run resumes by asking the same question and getting a
  shorter answer.
- **A missing file is not a failure.** A row whose file is gone, or is not
  audio, is counted and passed over with no health issue — `locations.state`
  already models absence, and filing an issue per file would bury every real
  finding under an unmounted drive. A file that *opens* and then refuses to
  decode raises `unreadable_file`, a kind this pass owns outright so that
  clearing it later cannot erase a finding the analyzer made by decoding audio
  this pass never looked at.
- **It reprojects what it repaired.** `tracks.duration_ms` is derived from the
  file rows, so a backfill that left the Tracks reading zero would have fixed
  nothing anybody can see. Each committed batch is handed to the projection
  scoped to its own file ids, exactly as a scan batch is.
- **`--force` re-probes rows that already answer**, and is not the default. A
  probe reads what a container declares, so re-running it on a row that has an
  answer writes the same numbers; force exists for a probe implementation that
  got *better*, where a stored value is present but no longer what the current
  build would compute. A forced run is not restart-resumable, because a
  re-probed row still matches the selection.

A FLAC whose STREAMINFO declares `total_samples = 0` keeps a null duration: the
length is honestly unknown rather than missing.

`library/analysis_pass.zig` is the same shape one level deeper: also keyed on
`files.id`, also a runtime job with bounded commits and no walk, but decoding
whole files rather than reading headers, which changes what "bounded" and
"resumable" have to mean. `docs/analysis.md` covers it.

## Watching roots

`Runtime.libraryWatch(library, WatchOptions)` watches every enabled root of a
Library and reconciles what changes under them through the
[folder-scoped reconcile](#folder-scoped-reconciliation).
`Runtime.libraryUnwatch` stops it, `Runtime.libraryWatchStatus` reports it,
and `orca-cli watch DATABASE` runs it. Only Linux has a watcher; elsewhere
`libraryWatch` returns `error.WatchingUnsupported`.

Watching speeds reconciliation up and replaces none of it: a scan or
reconcile still finds anything no event reported.

### How it works

- Each watched Library has one watcher thread (`library/watch_linux.zig`),
  registered with the work registry. It blocks in poll(2) on a nonblocking
  inotify descriptor and an eventfd; cancellation and every command from the
  control lane write the eventfd.
- Arming a root walks it on the watcher thread and adds one watch per
  directory, for `IN_CREATE`, `IN_DELETE`, `IN_MOVED_FROM`, `IN_MOVED_TO`,
  `IN_CLOSE_WRITE`, `IN_ATTRIB`, `IN_DELETE_SELF` and `IN_MOVE_SELF`, with
  `IN_ONLYDIR`, `IN_DONT_FOLLOW` and `IN_EXCL_UNLINK`. `IN_MODIFY` is not
  watched: a file being written is reported once, when it is closed. The walk
  checks for cancellation between entries.
- Each event marks a directory, relative to the root, dirty:
  - a file created, written and closed, changed in metadata, deleted or moved:
    the directory holding it;
  - a directory created or moved in: that directory, once it and every
    directory already inside it are watched;
  - a directory deleted or moved out: that directory, once its watches and
    those below it are dropped.
- A dirty directory is reconciled recursively, so a file created in a new
  directory before the directory was watched is still found, and a directory
  that is gone has everything under it marked missing.
- Arming a root first checks its path against its recorded volume, as a
  [walk does](#volume-check-before-a-walk); a root on another volume is
  reported unavailable and not armed.
- A root's changes are published once the root has been quiet for
  `WatchOptions.quiet_ms` (default 2000), or `max_delay_ms` (default 30000)
  after its first unpublished change. A root holds at most 64 dirty
  directories: a directory inside another is absorbed, and one more makes the
  whole root dirty.
- `Runtime.pump` takes what the watchers published, merges it per root under
  the same rules, and starts a `reconcile` job for one root at a time. The job
  reports `job_finished` like any other; one that recorded or marked missing
  a file also publishes `Telemetry.library_changed`.

### Invariants

1. The watcher thread touches only its own state, its two descriptors, the
   queues between it and the control lane, the host signal, and the
   directories, mount table and volume markers it reads. It never touches a
   database, a handle pool or the work registry: the control lane hands it
   each root's recorded volume key with the root.
2. Hints are advisory. Only the scanner, run by the reconcile job, writes
   files and locations.
3. A Library runs at most one automatic reconcile, and never starts one while
   a scan, reconcile, projection or tag write of the Library runs. Analysis,
   duplicate finding, matching and AcoustID submission run for hours without
   walking or rewriting files, so a reconcile runs beside them. A host's scan, reconcile or tag write
   first cancels and joins a running automatic reconcile, without a
   `job_finished` event, and its root waits again as a whole root. A host's
   scan of a whole root takes over the root's waiting changes, and returns
   them as the whole root if it does not succeed.
4. Every arm marks its root dirty as a whole and publishes it at once:
   nothing that changed while the root was unwatched produced an event. This
   is also how a Library catches up after a drain rebuilds its watcher.
5. A root that is deleted, moved or unmounted, is on another volume than the
   one recorded, or cannot be watched when it is armed, is reported
   unavailable and is never reconciled; its running automatic reconcile is
   cancelled. Its locations keep their state, so an unmounted drive never
   empties a library. An automatic reconcile that fails the volume check
   makes its root unavailable in the same way, rather than being started
   again by every event.
6. Every `WatchOptions.degraded_rescan_ms` (default 15 minutes) the watcher
   tries each unavailable root again: once its path is a directory on its
   recorded volume, the root is armed, and so reconciled whole. A root the
   watch limit left partly unwatched is degraded: on the same interval, and
   only while it stays degraded, the watcher walks it again, adding the
   watches it can, and publishes it whole. The timer lives on the watcher
   thread, in its poll timeout, and raises the host signal only when it
   publishes; `nextPumpTimeoutMs` does not wake for it.
7. Everything is bounded: 16 commands to the watcher, 256 hints from it, 64
   directories per root and a 64 KiB read buffer.
8. Orca's own files never dirty anything: tag-write temporaries
   (`isOrcaTemporaryName`), the volume marker `.orca-volume-id`, the database
   file and its `-wal`, `-shm` and `-journal` files, and the backup directory,
   which is neither watched nor walked into. These names are matched anywhere
   under a root. A tag write still dirties its file's directory once, when the
   staged copy is renamed over the file; the reconcile that follows finds the
   file as the write job already recorded it.

### Limits

- Watches are per directory and count against
  `fs.inotify.max_user_watches`. When `inotify_add_watch` fails with
  `ENOSPC`, the watcher keeps the watches it has, leaves the rest unwatched,
  counts the root in `roots_degraded` and reports `watch_limit_reached`, and
  the Library's state is `degraded`. The root is then reconciled whole every
  `degraded_rescan_ms` until a walk adds every watch it needs, for example
  after the limit is raised.
- Each watched Library uses one inotify instance, counted against
  `fs.inotify.max_user_instances`; `libraryWatch` returns
  `error.WatchInstanceLimit` when none is left.
- A directory the watcher cannot read is not watched.
- Symbolic links are not followed, as the scan does not follow them. A
  directory reachable by two paths, through a bind mount, is watched once,
  under the first path found, and its events are reported under that path
  only. A root inside another watched root is watched as part of whichever
  was armed first.
- An unmount below a root drops the watches on the unmounted filesystem and
  dirties nothing; those directories are watched again when the Library is.
- The periodic retry and rescan are at most every `degraded_rescan_ms`: an
  unavailable root that returns is picked up that late, and a degraded root's
  changes in unwatched directories are found that late.
- On `IN_Q_OVERFLOW`, events were lost: every root is walked again for new
  directories and reconciled whole.
- When a command cannot be queued to the watcher, because 16 are waiting, the
  control lane rebuilds the watcher from the Library's roots rather than drop
  the command, and every root is armed and reconciled again.
