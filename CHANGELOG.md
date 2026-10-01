# Changelog

## Unreleased

### Added

- **Write Tags to Files from the context menu, with recording IDs.** A track
  or album menu in `orca-gtk` has Write Tags to Files…, which shows the plan
  and writes it once confirmed. Tag writes now store the MusicBrainz
  recording ID: FLAC as `MUSICBRAINZ_TRACKID`, MP3 and ADTS as a MusicBrainz
  `UFID` frame, replacing a legacy `TXXX:MusicBrainz Track Id` and keeping
  other `UFID` owners and `TXXX` frames byte for byte, in ID3v2.3 and 2.4.
  The Edit Tags dialog has a MusicBrainz Recording field for a single track,
  and `orca-cli edit` a `--recording-id` option.

### Changed

- **A tag write never overwrites a file's tag with an automatic value.** A
  locked value, a user's edit, is written wherever it differs from the file;
  an unlocked one, such as an accepted match, only where the file has no tag
  for its field. One that disagrees with the file's tag is reported in
  `TagWritePlan.conflicts` (`TagWriteConflict`) and not written, and each
  `TagWriteChange` carries the `provenance` of Orca's value. `orca-cli
  write-tags` labels changes `edit` or `match` and prints a `conflict` line
  per conflict; `orca-gtk`'s confirmation lists both. `isMusicBrainzId` is
  exported.
- **Library schema version 21.** `orca_metadata_values.written_at` records
  when a tag write put a value into its file, so a recording ID Orca wrote
  stays eligible for AcoustID submission; IDs Orca did not choose are still
  never sent.
- **Library schema version 22.** Files observed with a cover and no other
  tag value are re-read by the next scan, reconcile or watch pass, so a
  library scanned before the fix below gains their trailer and INFO values.
- **Library schema version 24.** `provider_state.next_request_ms` keeps the
  earliest time a service may be sent its next request, so a quota window or
  the one-request-per-second spacing outlives the job that learned it.
- **Library schema version 23.** `files.audio_hash` is cleared unless a
  current fingerprint was measured from the file's present bytes, so stale
  hashes in an existing library stop producing exact-duplicate findings;
  `orca-cli analyze-library` measures those files again.

- **Accept Confident takes each file's best match.** Before, a file's match
  was accepted in bulk only when it was the file's one pending proposal at the
  threshold, so a text-only MusicBrainz rival such as a live version, or
  AcoustID naming several MusicBrainz recordings of the same audio, left the
  file unaccepted, and raising the threshold could accept more. Now a match
  AcoustID found with a fingerprint score of at least 0.9 wins, ties going to
  the higher percent, the Track's own track number, one MusicBrainz found too,
  the higher MusicBrainz score, the closer length and the lowest recording ID.
  Without one, the most confident match is accepted when its percent is above
  every other's. `acceptConfident`, `acceptConfidentInRelease` (Match Album)
  and `confidentCount` share the selection, and a higher threshold never
  accepts more.

### Fixed

- **Writing tags to a FLAC file with a comment block of 256 bytes or more no
  longer crashes.** The block header's length was narrowed to one byte, so a
  Debug or ReleaseSafe build panicked mid-write on nearly every real FLAC file
  and startup recovery rolled the write back.
- **Writing tags to an MP3 or ADTS file whose values were only in its ID3v1
  trailer no longer drops them from the library.** The new ID3v2 tag held only
  the written fields, such as an accepted recording ID, and a re-scan reads
  ID3v2 first, so the file lost its title, artist, album, year, track and
  genre. The trailer's values are now written into the new tag too, unless a
  change replaces them.
- **An MP3, ADTS, WAV or AIFF file whose ID3v2 tag holds only a cover shows
  its ID3v1 or `LIST`/`INFO` values.** The cover counted as a tag value, so
  the ID3v2 tag was read in preference to the trailer or INFO chunk and the
  file had no title, artist, album, year, track or genre. Such a tag now
  falls back to them and keeps its cover, and a tag write to it carries the
  trailer's values into the new tag.
- **Loudness and ReplayGain are correct for stereo files.** Integrated
  loudness averaged the channels' K-weighted energy where ITU-R BS.1770 sums
  it, so a stereo file measured 3.01 LU too quiet and was played 3.01 dB too
  loud. `diagnostics_algorithm_version` is now 3: measurements taken before
  are ignored until `orca-cli analyze-library` measures the files again, and
  until then playback applies no measured correction to them. Channels are
  summed at weight 1.0; surround weighting waits for a channel layout.
- **A file whose tags were removed loses them in the library on the next
  scan.** A rescan of changed bytes that found no tags, or could not read
  them, kept the tags observed from the old bytes. They are now cleared, as a
  fresh import of the same file would have none.
- **`zig build test` can no longer play through the speakers.** The C ABI
  smoke test fell back to the default output when the silent sink could not
  be created, and the build hid that failure. The build now creates the sink
  with the `orca-cli` it builds and hands the test its device id; on Linux the
  test fails rather than open the default output.
- **A file whose audio changed is no longer reported as an exact duplicate of
  its old audio.** A rescan of changed bytes kept `files.audio_hash`, the hash
  of the decoded audio, and the duplicate pass trusted it. A new quick hash
  now clears it until the analysis pass decodes the file again.
- **Playing a stopped queue whose current file has gone plays the next
  entry.** The engine retried the missing entry until its failure limit and
  never reached the next one. It now steps over it, as it already did for an
  entry reached by auto-advance, and an engine that gives up with nothing
  loaded goes idle instead of waking every 2 ms.
- **A provider's quota window and request spacing hold across jobs.** A
  response announcing no remaining requests, and the time of the last
  request, were kept only by the job's own Gateway, so the next matching or
  submission job could send at once. Both are now stored with the service's
  block and backoff and honoured by every later Gateway.
- **An output that failed for good no longer stops a Player's other
  outputs.** A Zone whose recovery attempts were exhausted kept its queued
  audio, so a change of sample rate or channel count waited for it for ever
  and the healthy Zones went silent, and the Player never reported its queue
  drained. Such a Zone now gives back its audio and takes no part in
  draining, and closing its output and requesting it again opens it afresh.
- **Moving a Zone to another Player no longer plays the previous Player's
  audio.** `attachZone` kept the Zone's output, queued audio and published
  position, which the new Player could take for its own. Moving a Zone now
  closes its output and forgets that state; the new Player reopens it in its
  own format. Detaching a Zone and destroying a Player forget it too.

## 0.5.0 - 2026-09-30

Ships Library schema version 20.

### Added

- **The analysis decodes on a pool of threads.** `AnalysisRequest.threads`
  sets how many files of a batch are decoded at once; unset, it takes
  `analysisDefaultThreads()`, one fewer than `analysisAvailableThreads()`,
  the logical processors. `orca_analysis_options.threads` (zero for the
  default), `orca_analysis_default_threads()` and
  `orca_analysis_available_threads()` reach them through the C ABI, and
  `orca-cli analyze-library --threads=N` and an Analysis threads row in
  `orca-gtk`'s Preferences, saved in `settings.ini`, set them. The stored
  results are the same at any thread count.
- **The analysis stores each file's AcoustID fingerprint.** The new streaming
  `chromaprint.Analyzer` takes it in the same decode as the loudness, so
  matching and AcoustID submission find it cached instead of decoding the
  file again. `FileAnalysis.chromaprint` holds it, null for audio too short
  to fingerprint, and `orca-cli analyze` prints `chromaprint=yes|no`.

- **Match Album and Cover Art Archive covers.** `MatchRequest.release_id`
  limits matching to one Release; with it, `accept_minimum_confidence`
  accepts that Release's confident matches and `cover_art` fetches its front
  cover. `Runtime.startReleaseCoverArtFetch` fetches the cover alone, and
  `jobMatchStats` reports `accepted` and the `CoverArtOutcome`. A cover is
  fetched only for a Release none of whose files carries one, under its
  tagged release ID or the one most of its accepted matches name, through
  `Gateway.fetch`, which follows at most two `https` redirects within
  `archive.org`. It is stored in the new `release_artwork` table, a missing
  cover for 30 days, and the artwork reads return it when no file has a
  cover. `Runtime.setCoverArtArchiveServer` and `ORCA_COVERARTARCHIVE_URL`
  select another server. `orca-cli match --release=ID
  [--accept-min-score=SCORE] [--cover-art]` and `orca-cli cover-art DATABASE
  RELEASE_ID` run them, and `orca-gtk` offers Match Album and Fetch Cover Art
  on an album's menu.

- **The flake installs Orca on NixOS and Home Manager.** `nix/package.nix`
  holds the package, `packages.orca` (also `default`) builds it, and
  `nix run` starts `orca-gtk` (`orca-cli` on macOS);
  `nix run .#orca-cli` runs the CLI. `nixosModules.default` and
  `homeModules.default` add `programs.orca.enable` and
  `programs.orca.package`, and `overlays.default` adds `pkgs.orca` built
  against the overlaid nixpkgs.
- **`nix flake check` builds the package, runs `zig fmt --check` and
  evaluates the NixOS module.**
- The dev shell provides Python, `ffprobe` and the `sqlite3` shell.

### Changed

- **Breaking (Zig API): the analysis no longer hashes the whole file.** It
  read every file a second time for a BLAKE3 hash nothing used.
  `FileAnalysis.fingerprint.source_hash` and `DuplicateKind.exact_file` are
  gone; a stored temporal fingerprint keeps its layout, with the hash's bytes
  written as zeros.
- `orca-cli analyze-library` runs on `std.heap.smp_allocator` rather than
  the process arena, which kept every decoded file's buffers until it exited.

### Fixed

- **`orca-gtk` renders on the GPU again on current NixOS.** The pinned
  nixpkgs carried glibc 2.42, older than the system's GPU drivers need, so
  the Vulkan loader rejected them and GTK drew in software: the album grid
  lagged, more so the wider the window. nixpkgs is updated to glibc 2.44.

## 0.4.0 - 2026-09-30

Ships Library schema version 19.

### Added

- **Folder-scoped reconciliation.** `Runtime.startLibraryReconcile(library,
  ReconcileRequest)` walks a registered root, or only some directories under
  it, and marks missing only files under the directories whose walk
  completed. `orca-cli reconcile DATABASE ROOT_ID [DIR...]` runs it. The job
  kind is `reconcile`.
- `ScanStats.marked_missing` counts the locations a scan or reconcile marked
  missing; `orca-cli scan` prints it as `missing=`.
- **Filesystem watching on Linux.** `Runtime.libraryWatch(library,
  WatchOptions)` watches every root of a Library with inotify and, from
  `pump`, reconciles each directory that changes once its root has been quiet
  for `quiet_ms`. A reconcile that changed the Library publishes
  `Telemetry.library_changed`. A root that is deleted, moved or unmounted is
  reported, never marked missing. `libraryUnwatch` and `libraryWatchStatus`
  complete it, `jobReconcileRoot` names a reconcile job's root, and
  `orca-cli watch DATABASE` runs it. The unconnected `RootWatcher` and
  `watch_hints.Channel` are gone.
- **Degraded and unavailable roots are retried.** A root the watch limit left
  partly unwatched is walked again and reconciled whole every
  `WatchOptions.degraded_rescan_ms` (default 15 minutes) while it stays so,
  and an unavailable root is armed again on the same interval once its path
  is back on its recorded volume. `WatchStatus.roots_degraded` counts the
  degraded roots.
- **`orca-gtk` watches the music folders.** Preferences > Library > Watch
  folders for changes, on by default and saved in `settings.ini`, watches
  the open library; the views reload when a watcher's reconcile changes it,
  and the switch's subtitle reports what is watched, what is unavailable and
  when `fs.inotify.max_user_watches` must be raised.
- **C ABI: watching and reconciling.** `orca_library_watch`,
  `orca_library_unwatch`, `orca_library_watch_status` with
  `orca_watch_options`, `orca_watch_status` and `ORCA_WATCH_STATE_*`;
  `orca_library_start_reconcile`; `ORCA_EVENT_LIBRARY_CHANGED` with an
  `orca_library_changed_event` payload; and `ORCA_JOB_KIND_RECONCILE`, which
  reconcile jobs report instead of `ORCA_JOB_KIND_OTHER`. All are additions
  within ABI version 0. `orca_scan_stats` does not carry `marked_missing`:
  the struct has no reserved room for a 64-bit field, and growing it would
  change its size.
- **Breaking (Zig API):** `Telemetry` has a `library_changed` variant, so an
  exhaustive switch over it needs an arm for it.

### Fixed

- **A scan of an unmounted drive's root no longer marks its files missing.**
  Every scan and reconcile, host-started or automatic, first checks that the
  root's path still resolves to the volume the root was recorded on; a root
  that does not is neither walked nor swept, and the job ends `failed`. A
  watched root that fails the check is reported unavailable until it is back.
  `orca-cli scan` no longer re-adds a registered root, which rebound it to
  the volume its path is on now and so bypassed the check; `orca-cli
  add-root DATABASE ROOT` rebinds a root explicitly, and
  `ScanStats.volume_changed` reports the failure.

- **Two scans of one Library could mark present files missing.** A second
  scan or reconcile of a Library while one runs is now refused with
  `error.LibraryScanRunning`, `ORCA_STATUS_BUSY` through the C ABI.

## 0.3.0 - 2026-09-30

Ships Library schema version 19.

### liborca as a library for others

- **Breaking (Zig API): the host names itself before provider work.**
  liborca no longer carries Orca's identity as a default. Until
  `Runtime.setClientIdentity` is called, `startLibraryMatching`,
  `startAcoustIdSubmission` and `librarySetScrobbling(library, true, ...)`
  return `error.ClientIdentityRequired`; turning scrobbling off and
  `libraryTrackFingerprint` need none. `setClientIdentity` copies its strings,
  so they no longer have to outlive the runtime, and refuses an identity longer
  than 256 bytes in all. `network.client.Identity.orca` is gone,
  `network.client.Config.identity` has no default, and a listen recorded before
  an identity is set has an empty `player_client`. An identity named `Orca` at
  liborca's own version sends no `liborca/x` suffix whatever its contact.
- **`orca-cli` and `orca-gtk` take their provider contact from
  `-Dprovider-contact`** (default `evan@evanriley.com`); `match`, `scrobble`,
  `submit-acoustid` and `play-tracks` identify as `Orca/<version>`.
- **Versioned shared library.** `liborca.so` has the SONAME `liborca.so.0` and
  installs as `liborca.so.0.0.0` with `liborca.so.0` and `liborca.so` links.
  The number is `ORCA_ABI_VERSION`, new in `orca.h` and separate from the
  product version.
- **`liborca.so` exports only the functions `orca.h` declares.** It exported
  1,513 symbols, among them the C shims, libxaac, Chromaprint and libc++'s
  `operator new`. A version script generated from the header hides the rest,
  a declared function liborca does not define fails the link, and the new
  `abi-exports` step in `zig build test` (`scripts/check-exports.sh`) fails
  when the exports and the header differ.
- **`orca_version()`** returns liborca's version.
- **`orca_runtime_last_error()`** describes why the last call on a runtime
  failed, as `"<function>: <reason>"`: the Zig error name, or which argument
  was refused. It was lost behind `ORCA_STATUS_INTERNAL` and
  `ORCA_STATUS_INVALID_ARGUMENT`.
- **Hosts can sleep until liborca wakes them.**
  `orca_runtime_set_wake_callback` (`Runtime.setWaker` with a `HostWaker`)
  installs a callback liborca calls, at most once between two pumps, after a
  command is submitted and when a Player's position or end of queue, a Zone's
  output state, a finished job, an artwork result, a recorded listen or the
  scrobbler status changes. `orca_runtime_pump_timeout`
  (`Runtime.nextPumpTimeoutMs`) gives how long the host may sleep without it:
  0, at most one second while a bound Player plays and 100 ms while a job
  runs, or
  `ORCA_PUMP_NO_TIMEOUT`. An idle runtime asks for no timeout and makes no
  wake. The callback is the one exception to the threading contract: it runs
  on liborca's threads, must only signal the host's loop, is never called from
  a render callback or after `orca_runtime_destroy` returns, and can be set
  only before any worker thread exists. `Runtime.pump` is the loop's pump,
  which `orca_runtime_pump` now calls.
- **`orca-gtk` sleeps until liborca wakes it.** Its 100 ms timer is gone: the
  waker writes an eventfd the GTK main loop watches, and the pump timeout is
  re-armed after each tick. An idle window makes no wakeups. Handlers that
  change what the window shows request a tick themselves, a seek drag applies
  on its own settle timer, and a context menu is re-presented on idle.
- **`lib/pkgconfig/orca.pc`** is installed, so C hosts build with
  `pkg-config --cflags --libs orca`, or `--static` for the static library and
  its dependencies, libc++ included.
- **A stability statement** in `orca.h` and `docs/api.md`: within one ABI
  version functions and enum values are only added and reserved fields gain
  zero-compatible meanings; the Zig API may break in any minor release.

### Parser hardening

- **A crafted MP4 no longer overflows the sample-table arithmetic.** Media
  time, packet lookup, chunk offsets, the edit list's conversion to media
  time, frame counts and the probe's duration are checked, and a value that
  does not fit is `error.InvalidMp4` rather than a panic in safe builds and
  undefined behaviour in `ReleaseFast`. The movie-box walk in `iso_bmff.zig`
  checks its offset arithmetic the same way.
- **Fuzz targets for every parser that reads untrusted bytes**: ID3v2, MP4
  and ISO-BMFF, Vorbis comments (FLAC, Ogg and bare), WAV, AIFF, ADTS, the
  MP3 stream reader, and the scanner's detect, probe and artwork path
  (`liborca/fuzz.zig`). `zig build test` replays their seeds, including every
  input under `fixtures/fuzz/`; `zig build fuzz --fuzz[=N]` fuzzes them. A
  single allocation above the largest designed bound fails the input.
- **WAV and AIFF size their read buffer by the frames the file holds.** A
  header declaring thousands of channels made the decoder allocate 4,096
  frames of them, 256 MiB for a 41-byte file.
- **ALAC rejects a configuration of more than 8 channels or 65,536 frames per
  packet.** The decoder's buffers were sized from the declared frame length,
  so a crafted cookie could demand gigabytes.
- **An ID3v2 tag larger than its file is rejected before its body is
  allocated.** The declared size, up to 16 MiB, was allocated first and only
  then found to be short.

### Playback engine

- **Back-to-back control calls no longer starve the engine.** A quiesce that
  came within one park interval of the previous release suspended the engine
  before it ran a pass, so a host calling `playerSignalPath`,
  `playerSetEqualizer`, `playerSetCrossfeed` or `seekPlayer` every few
  milliseconds kept the output from ever opening. A quiesce now waits for one
  full pass after a release.
- **Player status and listens no longer pair a new entry with the previous
  entry's gain, duration or position.** The engine moved the queue cursor
  before it published the audible entry's figures; it now publishes the
  position, duration and gain first and the cursor last, and a status read
  takes the cursor first.

### Providers

- **Provider rate limits survive the process** (Library schema 19). A `429`
  block and its backoff are stored per service in `provider_state`, so a
  restart or a new `orca-cli scrobble` no longer sends into a block. A listen
  that failed for a transient reason keeps its retry time in the queue
  (`next_attempt_at`) instead of being released at once.
- **One process at a time talks to each service.** A Gateway claims a
  per-service lease in `provider_leases` before each request and releases
  it when its job ends; a second claimant fails fast with
  `error.ProviderBusy`. A matching or submission job fails with the new
  `BusyService`, the listen worker reports the new `busy` state and tries
  again after the lease runs out, and `orca-cli` prints "MusicBrainz is in
  use by another Orca process" (breaking Zig API change: new enum values in
  exhaustive switches).
- **`Retry-After` is honoured uncapped, as delta-seconds or an HTTP-date, and
  on a `503`.** It was capped at an hour, its date form was ignored, and a
  `503`'s was ignored altogether.
- **Every backoff Orca chooses is jittered** by a factor between 0.5 and 1.5,
  so clients that failed together do not retry together. A server's own
  `Retry-After` is never shortened.
- **A query MusicBrainz or AcoustID refused is not sent again for 7 days.** A
  `4xx` other than `401`, `403`, `408` and `429` is cached with its status. A
  refused AcoustID lookup batch is asked again one fingerprint at a time, so
  only the bad fingerprint's refusal is cached.
- **`ScrobblerStatus.blocked_until`** reports when a stored block ends, also
  when no worker is running; `orca-cli scrobble` and `scrobble --status`
  print it.
- **AcoustID submissions only send what AcoustID does not already know.** A
  recording ID from an accepted proposal that AcoustID took part in is not
  submitted back, and neither is a text-only match accepted in bulk
  (`identification_proposals.accepted_in_bulk`). Acceptances made before
  schema 19 count as reviewed.

### Idle power

- **An idle Player makes no wakeups.** The engine thread slept 2 ms at a time
  for the Player's whole life; it now waits on a futex while there is nothing
  to do, and is woken by control calls, cancellation and PipeWire stream state
  changes. Measured on a paused and on a stopped Player: 4,882 context
  switches per 10 s before, 0 after.
- **The artwork loader waits with no timeout.** It woke every 50 ms to check
  for cancellation; a `work.Registration` now carries a waker that
  `requestCancellation` calls.

### Maintenance

- **`core/runtime.zig` is split** into `runtime_queue.zig`,
  `runtime_listens.zig`, `runtime_roots.zig`, `runtime_jobs.zig`,
  `runtime_status.zig`, `runtime_zones.zig` and `job_worker.zig`, with its
  tests in `runtime_tests.zig` and `runtime_provider_tests.zig`. `JobWorker`
  holds a tagged-union request and stats per job kind; the duplicate job's
  counts are mapped into `ScanStats` only at the public boundary, as before.
  The public API is unchanged.
- **`database/repository.zig` is split by aggregate** into
  `database/repository/`, and the column helpers copied across the library
  code live once in `database/columns.zig`.
- **One set of network test doubles** in `network/testing.zig`
  (`ScriptedTransport`, `TestClock`) replaces the copies in each provider and
  in the runtime tests.
- **`orca-cli` dispatches through a command table** with one job-option
  parser. `--help` is built from it and now lists `--volume` and
  `--set-volume`.
- **Removed:** the Last.fm adapter and `scrobble.Adapter`, the DSP graph
  (`Chain`, `PublishedChain`), `audio/transition.zig`, the `Resampler`
  interface with its linear implementation (`resampler.SampleRate` remains
  for fingerprints), `published_device_delay_frames`, and uncalled functions
  (`setEnabled`, `stampGeneration`, `jobSnapshot`, `applyAlgorithmicLatency`).
- **Comments that narrated history, and section dividers, are removed**;
  those that held an invariant state it instead.

### Documentation

- **The docs match the code.** `analysis.md` no longer describes the
  replaced FLAC decoder; `storage.md` and `metadata.md` name the current
  tables and journalled identity; `ownership.md`, `frontends.md` and
  `audio-engine.md` drop superseded stages. Measurements and reference-library
  figures are removed from the contract docs.
- **`README.md` has an Embedding section** and a complete list of
  requirements, and warns that device 0 is real hardware.

## 0.2.0 - 2026-09-29

The first tagged release. Ships Library schema version 18.

### The first release

- **The version is `0.2.0`, without `-alpha`**: a `0.x` version already makes
  no stability promise. `orca-cli --version`, the About dialog and the
  User-Agent read `0.2.0`.
- **`build.zig.zon` holds the version.** `build.zig` passes it to liborca,
  which parses `liborca.version` from it, and `flake.nix` reads it for the
  package; `liborca/version.zig` no longer writes it out.
- **`orca_player_snapshot` and `orca_player_state_snapshot` are removed**
  (breaking C ABI change). They were kept for a pre-0.2 boundary that was never
  released; `orca_player_status_get` reports the transport, queue and timeline.

### aarch64 builds and CI

- **`liborca` builds for aarch64, Apple Silicon included.** SQLite's
  `SQLITE_TRANSIENT` was built as a misaligned function pointer, which
  aarch64 rejects; text results are now copied into SQLite's allocator and
  freed with `sqlite3_free`. The `ogg` and `opus` include directories come
  from pkg-config, where only Nix's native environment used to supply them.
- **`zig build lib`** installs only the static `liborca` and
  `include/orca/orca.h`, which cross-compiles:
  `zig build lib -Dtarget=aarch64-macos`.
- **A CI workflow** (`.github/workflows/test.yml`) runs `zig build test`,
  `zig fmt --check` and the aarch64 macOS cross-build on every push to `main`
  and every pull request.
- **`scripts/headless-audio.sh CMD`** runs a command against a private
  PipeWire and WirePlumber with every hardware monitor off, so the C ABI smoke
  test has an audio server in CI without reaching real devices. The dev shell
  gains WirePlumber on Linux.

### Truthful signal-path report

- **Exact widening is bit-perfect.** An 8-, 16- or 24-bit integer source
  widened to float32 reaches the output unchanged, so FLAC, ALAC, WAV and AIFF
  are no longer reported "not bit-perfect" for it; the report marks the path
  `widened_exactly`, and `orca-cli` prints `(exact)` after the output format.
  A 32-bit integer or 64-bit float source is still a
  `sample_format_conversion`.
- **Lossy sources are not bit-perfect.** MP3, AAC, Opus, Vorbis and QOA carry
  the new reason `lossy_source`. They used to report "bit-perfect: yes"
  because a decoder that declares no source format reported the canonical
  float32 format, which matched the stream.
- **A volume ramp lands exactly on its target**, where a ramp ending on a
  block boundary stopped at 0.99999, and the report reads the gain being
  applied rather than the target, so volume 1 is bit-perfect once the ramp
  ends.
- **No bit depth for lossy sources.** `orca-cli` and `orca-gtk` print a depth
  only when the decoder declared a source format.
- **`orca-gtk` says "Bit-perfect up to PipeWire"**, with "PipeWire's own
  volume and resampling are not visible to Orca." on hover over the signal
  path, and shows the volume whenever it is not 100 %, above it included.
- `SignalPath` gains `source_declared` and `widened_exactly`, and
  `SignalPathReason` gains `lossy_source` (public API addition).

### Tag-write backups out of the music folders

- **A tag write leaves nothing beside the music.** The original is copied,
  with its modification time, fsynced and verified, into
  `<database>.orca-backups/<plan>/<action>-<name>` before the replacement is
  renamed into place. The stage is a hidden file beside the music
  (`.<name>.orca-stage-<plan>-<action>`) that exists only during the write, and
  an undo copies the backup to a hidden `.orca-restore-` file and renames it
  over the file. A rescan after a write used to list each backup as a second
  Track with the old tags, and after an undo as a `missing` one.
- **Scans skip Orca's temporaries**: hidden `.orca-stage-` and
  `.orca-restore-` files, and the `.orca-backup-`, `.orca-stage-` and
  `.recovery-displaced` names of earlier versions.
- **Schema version 18 forgets the ghost rows.** Files whose every location is
  a journaled stage or backup path go, with their Tracks and the Releases and
  Artists left without Tracks.
- **Backups can be pruned.** `Runtime.pruneTagWriteBackups` (new type
  `PruneSummary`) and `orca-cli prune-backups DATABASE [--older-than=DAYS]`
  delete the backups of fully committed writes, including backups earlier
  versions left beside the music, and print how many and their size. A pruned
  write cannot be undone: `undoTagWrite` returns `error.TagWriteBackupPruned`
  and changes nothing.
- **Undo checks every backup first.** A backup that is missing or no longer
  holds the original records `needs_reconciliation` before any file changes.
  Recovery restores from a verified backup, keeps every file when the backup is
  gone, and handles journals of both layouts. When a changed file's folder is
  missing, as on an unmounted drive, the Library refuses to open with
  `error.TagTargetUnavailable` and recovery runs again at the next open.
- **An in-memory Library cannot write tags.** `startTagWrite` returns
  `error.NoBackupDirectory`, because it has nowhere to keep the originals.
  (Breaking for hosts that wrote tags through an in-memory Library.)
- `orca-cli` and `orca-gtk` explain a pruned write and a missing backup
  directory instead of printing the error name.

### AcoustID

- **Matching fingerprints files and asks AcoustID.** A matching job
  fingerprints each Track's file (the first 120 s, decoded by Orca, resampled
  to 11,025 Hz by libsamplerate and fingerprinted by Chromaprint) and looks up
  to 20 fingerprints at a time on AcoustID, at one request a second, in a
  gzip-compressed form. Candidates from MusicBrainz and AcoustID are merged
  into one proposal per recording, named `musicbrainz`, `acoustid` or
  `musicbrainz+acoustid`; two services agreeing rank above either alone, and a
  proposal found again keeps its state, so a dismissed one stays dismissed.
  `MatchRequest.fingerprints` (default true) turns it off. `MatchStats` gains
  `fingerprinted`, `fingerprint_cache_hits`, `fingerprint_failures`,
  `acoustid_requests`, `acoustid_cache_hits`, `acoustid_refused` and
  `acoustid` (new type `AcoustIdUse`); `MatchProposal` gains
  `acoustid_score`.
- **Each service is asked once per file.** Schema version 17 adds
  `identification_searches`, recording which service has answered for which
  file, empty answers included. Matching selects a Track until every service
  in scope has answered for its file, so a rerun asks nothing already
  answered; files with MusicBrainz proposals from before count as searched by
  MusicBrainz. A Track with a pending proposal is no longer skipped when
  AcoustID has not been asked about it.
- **Application key.** `Runtime.setAcoustIdClientKey` sets the key AcoustID
  identifies the application by; `orca-cli` and `orca-gtk` set it from the new
  build option `-Dacoustid-key=` (default `AqlfLksN1K`). A `CredentialStore`
  value under `org.acoustid` / `client-key` overrides it; without a key
  AcoustID is skipped. `setAcoustIdServer` and `ORCA_ACOUSTID_URL` select
  another server.
- **Fingerprints are cached.** `analysis_results` gains kind 3,
  `orca.chromaprint`, keyed by the algorithm, the resampler and the bytes.
  A file that does not decode cleanly gets no fingerprint.
  `Runtime.libraryTrackFingerprint` (new type `TrackFingerprint`) and
  `orca-cli fingerprint DATABASE TRACK_ID` print one in `fpcalc`'s format.
- **Chosen recording IDs can be submitted.** `startAcoustIdSubmission` starts
  an `acoustid_submission` Job (new `JobKind`) that sends the fingerprints of
  files whose recording ID came from an accepted match or an edit, never a
  tagged one, once per file and ID, in batches of at most 50 items and
  900 KB, with the user key the `CredentialStore` holds under `org.acoustid`
  / `user-key`. A file more than 30 s from its recording's length is sent
  with its metadata instead of the ID. It fails with `needs_user_key` or
  `invalid_user_key` without marking anything sent, and records each
  submission ID in the new `acoustid_submissions` table.
  `jobSubmissionStats` (new types `SubmissionStats`, `SubmissionOutcome`),
  `libraryAcoustIdSubmittableCount` and `libraryAcoustIdSubmittablePage` (new
  types `AcoustIdSubmittable`, `AcoustIdSubmittablePage`) report it.
  Matching and submission cannot run at once (`error.AcoustIdBusy`).
  `orca-cli submit-acoustid DATABASE [--dry-run]` reads the key from
  `ORCA_ACOUSTID_USER_KEY`.
- **`orca-cli`**: `match` prints a line of AcoustID counters and takes
  `--no-fingerprints`; `matches` prints each proposal's source and AcoustID
  score.
- **`orca-gtk`**: Preferences > Library gains an AcoustID group with Match
  by audio fingerprint (`[matching] fingerprints` in `settings.ini`, on by
  default), the user's AcoustID key saved in the Secret Service with Save,
  Remove and Unlock, and Get a key. The Matches page shows each proposal's
  source and AcoustID score, the details panel shows them in the proposal's
  tooltip, and Submit to AcoustID (N) sends accepted matches as a job after
  asking. `ORCA_ACOUSTID_URL` selects another AcoustID server. A failed
  matching job now names MusicBrainz or AcoustID. The GTK credential store
  labels each keyring item by its service.
- **New dependencies.** Chromaprint 1.6.1 (MIT) with KissFFT (BSD-3-Clause)
  is built from source without its LGPL resampler, and a build step fails if
  a compiled source carries a GPL or LGPL notice. libsamplerate (BSD-2-Clause)
  is linked through pkg-config and exposed as `resampler.SampleRate`.

### MusicBrainz matching

- **Tracks without a MusicBrainz recording ID can be matched.**
  `Runtime.startLibraryMatching(library, MatchRequest)` starts a cancellable
  `metadata_lookup` Job that searches MusicBrainz for every Track whose file
  has no recording ID and no pending match, at one request a second, caching
  answers for 30 days, and stores the candidates Orca scores at 0.5 or above as
  proposals. At most one runs per runtime. `jobMatchStats` reports what it
  did as `MatchStats`. `libraryMatchProposals`,
  `libraryAcceptMatch`, `libraryDismissMatch` and
  `libraryAcceptConfidentMatches` review them; `setMusicBrainzServer` selects a
  mirror. New public types: `MatchRequest`, `MatchStats`, `MatchProposal`,
  `MatchProposalPage`, `MatchAcceptance`, `RecordingIdSource`.
- **An accepted match is the recording ID loves and listens are sent under.**
  `MetadataField` gains `musicbrainz_recording_id`. The ID in effect is a
  locked Orca value, else the file's tag, else an accepted match; listens,
  feedback sync and `TrackDetails.feedback_syncable` all use it.
  `TrackDetails` gains `musicbrainz_recording_id` and
  `musicbrainz_recording_id_source`. Acceptance re-reads the proposal inside
  its transaction, refuses one that is no longer pending
  (`error.StaleIdentificationProposal`) or cannot be read
  (`error.InvalidProposalPayload`), keeps a locked value, writes only the
  recording ID, and never writes a file. Tag writes leave the field out.
- **Matches can be reviewed in `orca-gtk`.** A Matches page lists the songs
  awaiting review with a count in the sidebar, each beside its best proposal
  and expanding to all of them with Accept, Dismiss and a link to the
  recording on MusicBrainz. Find Matches runs the job in the status card;
  Accept Confident asks, then takes each song's only proposal at or above a
  threshold set in Preferences (90% by default). The details panel gains a
  MusicBrainz section: the recording ID and its source, or the top proposals,
  or Find Match for that song alone. `ORCA_MUSICBRAINZ_URL` selects another
  server.
- **Review queries.** `libraryMatchReviewPage` (new types `MatchReviewPage`,
  `MatchReviewItem`), `libraryMatchReviewCount`, `libraryUnidentifiedCount`
  and `libraryConfidentMatchCount`, which counts exactly what
  `libraryAcceptConfidentMatches` would accept. `MatchRequest.track_id`
  searches one Track. `jobMatchStats` reports `matched` while the job runs.
- **`orca-cli match`, `matches`, `accept-match`, `dismiss-match` and
  `accept-matches`** drive it, with `ORCA_MUSICBRAINZ_URL` for another server;
  `orca-cli track` prints `recording id:` and its source.
- **Provider requests carry one User-Agent.** Every request also sent
  `zig/0.16.0 (std.http)` ahead of Orca's; it now sends Orca's alone.

### Listening history and ListenBrainz

- **Orca keeps a play history.** Schema version 15 adds `listens`: one row per
  heard play, kept forever, keyed on the file so it survives re-projection and
  keeps a snapshot of the title, artist and album when a folder is removed. A
  listen is a track of 30 s or more heard for half its length or four minutes;
  seeks and pauses do not count, and a queue that plays out ends its last
  listen with the whole time heard. `Runtime.libraryTrackPlayStats` and
  `TrackDetails.play_count` and `last_played_at` report it. `orca-cli track`
  prints `plays:` and `last played:`, `orca-cli play-tracks` records listens,
  and `orca-gtk`'s details panel shows a History section.
- **ListenBrainz scrobbling.** `librarySetScrobbling` sends a Library's
  listens through a leased, restart-safe queue; `libraryScrobblerStatus`
  reports state, user name, queue counts and the last error;
  `libraryScrobblerCredentialsChanged` validates a changed token once. The
  token comes from a host-supplied `CredentialStore`
  (`Runtime.setCredentialStore`), which must never prompt or block on the
  user, and is never stored in the Library. `libraryListensRecorded` is a
  cheap counter a host can poll every tick.
  `setClientIdentity` names the host, and `setListenBrainzServer` selects a
  compatible server (`https`, or `http` to `127.0.0.1`, `[::1]` and
  `localhost` only). The rules toward providers are in
  [docs/providers.md](docs/providers.md).
- **`orca-cli scrobble DATABASE [--status] [--timeout=MS]`** sends the queue
  with the token in `ORCA_LISTENBRAINZ_TOKEN` and the server in
  `ORCA_LISTENBRAINZ_URL`, prints one `scrobble:` line, and exits non-zero when
  the token is missing or rejected. It never validates the token up front: with
  nothing queued it makes no request and looks up no token, and otherwise a bad
  token shows as a refused delivery. `--status` prints the state and queue counts
  from the database, starts no worker and makes no request.
- **`orca-gtk` gets a Listening page in Preferences**: a Submit listens
  switch, a user token field stored in the Secret Service through libsecret
  (linked into `orca-gtk` only), a link to the ListenBrainz settings, and a
  status row; its lookup never unlocks the keyring. `settings.ini` saves `[listening] scrobble=true|false`, never the
  token. `ORCA_LISTENBRAINZ_URL` points the app at another server.
- **Love and dislike in `orca-gtk`.** A heart beside the title in the player
  bar loves the audible song or removes the love; loved songs show a small
  heart in the track list and on album pages; the context menu offers Love,
  Dislike, Remove Love and Remove Dislike on one song or a selection; the
  details panel has a Feedback row that says when a song has no MusicBrainz ID
  and is saved on this computer only. The Listening page shows how many loves
  and dislikes are waiting to sync. The heart icons are `orca-heart-*-symbolic`
  SVGs under `apps/linux/data`, dedicated to the public domain (CC0-1.0).
- **Now Playing in `orca-gtk`.** Preferences > Listening has Show what I'm
  playing now, off by default and available while Submit listens is on; it is
  saved as `[listening] now_playing=true|false`.
- **`orca-cli feedback DATABASE IDS (--love | --hate | --clear)`** sets
  feedback and prints how many Tracks were updated and skipped. `orca-cli track`
  prints `feedback:` and `feedback sync:`, and `scrobble` sends pending
  feedback as well as listens, reports `feedback_pending` and finishes when
  neither queue has anything left; with both empty it still makes no request
  and looks up no token. `scrobble --status` prints `feedback_pending`.
- **Love and hate for songs.** `Runtime.librarySetFeedback` marks the song
  behind each Track loved, hated or cleared, and `libraryTrackFeedback` reads
  it; `TrackSummary.feedback` and `TrackDetails.feedback` report it and
  `TrackDetails.feedback_syncable` says whether ListenBrainz can be told. The
  mark belongs to the Recording, so a FLAC and an MP3 of one song share it and
  a reprojection keeps it. While a Library scrobbles, changes are sent as
  ListenBrainz recording feedback, one request per change, only for
  Recordings with a MusicBrainz recording id, including changes made while
  scrobbling was off. `ScrobblerStatus.feedback_pending` counts the changes
  waiting. A change is sent once it has stood for 2 s, so only the final state
  goes out, and nothing if it matches what the service has; clearing a change
  the service rejected forgets it locally with no request; a change the service
  accepted but Orca could not record is not sent again, and only the local mark
  is retried, from 60 s doubling to an hour. `TrackSummary.recording_id` names
  the song behind a row.
- **Now Playing, off by default.** `librarySetScrobbling`'s new last argument
  announces the playing track to ListenBrainz once it has been heard for 10 s
  (tracks of 30 s or more): one request per track, never retried, dropped when
  the service is rate limited, offline or 60 s stale, and never ahead of a due
  batch of listens.
- **Breaking.**
  - `Runtime.librarySetScrobbling` takes a fourth argument, `now_playing`.
  - Schema version 16 adds `feedback`, keyed on the recording, and the index
    `files_by_recording ON files(recording_id)`; a database
    opened by this build is refused by earlier builds.
  - Schema version 15: a database opened by this build is refused by earlier
    builds. `scrobble_queue` gains `lease_owner` and `lease_expires_at`; queued
    rows stay pending.
  - `network.client.Config.user_agent` is replaced by `Config.identity`
    (`ClientIdentity`), and the default User-Agent is now
    `Orca/0.2.0 ( evan@evanriley.com )`.
  - `providers.scrobble.dispatchReady` and the `ListenBrainz` adapter are
    removed; `providers.listenbrainz.Delivery` replaces them.
  - `playerBindLibrary` starts the Library's listen worker and can fail doing
    so.

- **`orca-gtk` shows whether a ListenBrainz token is saved.** The token field
  no longer has an apply checkmark that looked like the token was already
  stored: it has a Save button, enabled while the field has text, and Enter
  saves too. When a token is stored, a row reads "Saved in your keyring" with a
  Remove button, and the field is titled Replace token. The stored state is
  looked up when the Listening page is first shown and after each save and
  remove, asynchronously and without reading the secret; a keyring that stays
  locked reads "Keyring locked", with an Unlock button. An empty field no longer
  removes the token; Remove does.
- **A heart on every song row in `orca-gtk`.** The Tracks list, album pages, the
  queue and the Now Playing page (the audible song and the songs up next) have a
  heart button after the title: filled and red when loved, otherwise an outline
  dimmed until the row is hovered or selected. Pressing it loves the song or
  removes the love, and a disliked song becomes loved, without playing the song
  or changing the selection. All rows of the recording, the player bar and the
  details panel update together. The queue repaints in place instead of
  rebuilding, so it keeps its scroll position.

### Daily-use fixes

- **`orca-gtk` keeps the equalizer curve and crossfeed amount while they are
  off.** `settings.ini` saves `equalizer` and `crossfeed` as values and adds
  `equalizer_enabled` and `crossfeed_enabled`; older files still load.
- **Album page rows can be selected.** A click or the arrow keys select a
  row and show it in the details panel; double-click or Enter plays from it.
- **`orca-cli` reports errors as one line**, `orca-cli: no track with that id`,
  instead of an error trace, and exits with status 1.
- **A library migrated from before file identity, on storage Orca cannot
  name, moves its root onto the root's own volume.** Without a filesystem
  UUID or a writable mount root, the root and its files used to stay on the
  shared `legacy` volume after every scan. No data was lost.

### Removing a folder forgets its tracks

- **`Runtime.libraryRemoveRoot` forgets everything that exists only under the
  root**: its files, their tags and Orca values, the Tracks they backed, and
  the Releases and Artists nothing else references. It returns `RemovedRoot`
  with the counts. Files on disk are not touched; a file also located under
  another root stays and is reprojected; the tag-write undo journal keeps its
  rows. It returns `error.LibraryJobRunning` while any job on the Library runs,
  and `error.UnknownRoot` for an unregistered id. (Breaking: it returned
  nothing.)
- **`orca-cli roots` and `orca-cli remove-root`** list the registered folders
  and forget one. `orca-gtk` asks first, then reports how many tracks left.
- `orca_library_remove_root` keeps its signature and now reports
  `ORCA_STATUS_NOT_FOUND` for an unknown root and `ORCA_STATUS_BUSY` while a
  job is running.

### Live DSP

- **A ten-band equalizer, stereo crossfeed and a signal-path report.**
  `Runtime.playerSetEqualizer`, `playerSetCrossfeed` and `playerSignalPath`
  drive a per-Player DSP chain (preamp, equalizer, crossfeed, volume) that
  runs on the engine thread and costs nothing when off;
  `orca-cli play-tracks --eq=PRESET|G1,...,G10[:PREAMP] --crossfeed=AMOUNT`
  applies it and prints the signal path.
- **`orca-gtk` gets a Sound page and a signal path.** Preferences has a Sound
  page with the ten-band equalizer, presets, preamp and crossfeed, saved in
  `settings.ini` and applied at launch; the output menu shows the signal path
  and whether it is bit-perfect.
- **Playback at the source's sample rate.** Each PipeWire stream requests
  `node.rate` at its source rate, and the signal path reports the rate the
  device runs at (`SignalPath.device_rate`), adding sample rate conversion
  when PipeWire resamples because the request was not honoured.
- **Track details.** `Runtime.libraryTrackDetails` returns a Track's format,
  file, loudness and tags; `orca-cli track DATABASE ID` prints them, and
  `orca-gtk` shows them in a panel beside the Tracks list and album pages
  (`Ctrl+I`), with the signal path for the playing track.

### A designed GTK frontend

- **`orca-gtk` is a libadwaita app.** A sidebar of pages, a full-width player
  bar with the cover, centred transport and an output menu, a queue page,
  scan progress in the sidebar, a welcome page for an empty library, toasts
  instead of a status line, a shortcuts dialog (Ctrl+?) and an About dialog.
  The window adapts below 760sp.
- **Albums**: a grid of covers sorted by artist, title, year or recently
  added, and a page per album with Play, Shuffle and its tracks by disc.
  Albums without covers show their initials on a colour of their own.
- **Now Playing**: the cover, large, on a wash of its own colour, with what
  comes next. Click the cover in the player bar to open it.
- **Queue thumbnails**, and covers everywhere load and decode off the main
  thread.
- **Artists**: every Artist, searchable, and a page per artist with their
  albums, Play and Shuffle.
- **Back goes back**: the mouse back button and Alt+← return to the page shown
  before, including from Now Playing.
- **Right-click menus on artists, album covers and titles, and the playing
  track's cover**, besides tracks, album tiles and queue entries. The track
  list's menu no longer opens a row short.
- **The playing track is marked on album pages**, and on its whole row
  wherever tracks are listed.
- **Edit Tags** from any right-click menu: one track or many, saved to the
  library, then optionally written to the files after a preview, with Undo.
- **Preferences** (Ctrl+,): music folders, loudness measurement, duplicate
  finding, ReplayGain and the output device, which are remembered.
- **Health**: the issues liborca found, with Find Duplicates.
- Scans, measurement, duplicate finding and tag writes share one progress card.
- **The queue is editable**: click an entry to play it, remove entries, and
  Play Next or Add to Queue from a right-click menu on tracks, albums and
  queue entries, which also offers Show Album and Show Artist.
- **The playing track is marked** in the track list and the queue.
- **Enter in the search box plays the results.**
- **Rescan Library** is in the main menu.
- `nix build` installs a desktop entry and an icon.
- The dev shell sets `XDG_DATA_DIRS` for the GSettings schemas GTK looks up.

### Cover art off the caller's thread

- **`Runtime.libraryRequestArtwork`** queues a cover lookup on the Library's
  artwork loader, and `libraryTakeArtwork` collects it; `libraryCancelArtwork`
  skips one not yet started. `orca-cli covers` reads a page of covers this way.
- **`ReleaseQuery.sort`** orders Releases by title, artist, year or recently
  added.
- **The queue can be edited in place**: `Runtime.playerQueueJump`,
  `playerQueueInsertNext` and `playerQueueRemove`. Play Next lands after the
  entry the engine has already lined up, if it has, and neither that entry nor
  the playing one can be removed.
- **`TrackSummary` carries `release_id` and `artist_id`.**
- **`libraryEditTracks` returns `EditedTracks`**, the Tracks the edited files
  back afterwards, since moving a track to another album gives it a new id.
  `orca-cli edit` prints them. (Breaking: it returned nothing.)
- `core/root.zig` now lists its files in a test block, so their tests run.

### Tag write-back

- **Library edits can be written into the files.** `Runtime.planTagWrite`
  previews the changes as a sealed plan, `Runtime.startTagWrite` writes it as a
  Job once approved by its digest, and `Runtime.undoTagWrite` restores the
  files' previous bytes. `orca-cli write-tags` and `orca-cli undo-tags` reach
  them. FLAC, MP3 and ADTS are written; other formats are reported as not
  writable, and files changed since their scan are left out.
- **MP3 and ADTS tags are written as ID3v2**, in the file's existing version,
  with every other frame, the cover art and the audio bytes kept. The ID3v1
  writer is gone; an existing ID3v1 trailer is updated to match.
- **FLAC comment writes match the reader.** A write used to compare field names
  and values literally, so an `ALBUMARTIST` field or a `3/12` track number was
  duplicated or refused instead of replaced.

### Library edits, and a projection that cleans up after itself

- **Tracks can be edited in the library.** `Runtime.libraryEditTracks` and
  `orca-cli edit` set title, artist, album, album artist, track, disc, date and
  compilation as locked user values; the files are never written, rescans keep
  the edit, and `--clear` returns a field to the file's own tag.
- **Retagged files no longer leave ghost tracks.** Reprojection created a new
  Track when a file's tags moved it to another album or position and left the
  old row, its Release and its Artist listed with nothing behind them. They are
  now pruned; migration 14 adds the index that keeps this cheap.

### The common formats are complete; the rest wait until after 1.0

- **WAV files written as `WAVE_FORMAT_EXTENSIBLE` open**, which is what FFmpeg
  and most DAWs write past 16-bit stereo.
- **AIFF and uncompressed AIFC decode**, including `sowt`, bit-identically to
  the FLAC they were written from.
- **WAV and AIFF carry tags and cover art** from their ID3 chunk, and WAV from
  `LIST`/`INFO` as well.
- **Ogg Opus and Vorbis files show their cover art** from
  `METADATA_BLOCK_PICTURE`.
- **Raw `.aac` (ADTS) files play** instead of being mistaken for MP3.
- WavPack, APE, TTA, Musepack, DSD, WMA and less common containers are
  deferred; `docs/roadmap.md` lists them.

### A deliberate public Zig API (breaking)

- **`liborca`'s top level is the API.** It exports `Runtime`, its handles and
  every type its methods take or return. The twelve subsystem namespaces moved
  under `liborca.internal`, which is for liborca's own tests and benchmarks.
- **`OrcaRuntime` is `Runtime`** from outside the library.
- **`Runtime.libraryDatabase` is no longer public.** The CLI used it to reach
  the database directly; `libraryUnanalyzedCount`, `libraryAnalyzeFile` and the
  existing `libraryHealthIssuePage` replace those uses. Seven test-only hooks
  (`startDummyWork`, `markZoneOutputLost`, ...) are private too.
- **`examples/embed`** depends on Orca as a Zig package and lists a library's
  tracks; `zig build test` builds it. `docs/api.md` documents embedding and the
  surface.

### QOA decodes through the reference decoder, and seeks

- **The `audiophile/qoa` package is gone.** It shipped no licence, which left
  Orca redistributing code it had no right to, and it could not seek. The
  reference `qoa.h` (MIT) is vendored behind `codec/qoa_shim.c`, as minimp3 is.
- **QOA seeks exactly.** Frames are independent and all but the last are
  full, so a seek lands on its frame by arithmetic; a sought decode equals a
  sequential one sample for sample, across a frame boundary included.

### MP4: ALAC and AAC play, scan and tag

- **ALAC decodes bit-identically** through Apple's reference decoder, built
  from source behind a C++ shim: the ALAC fixture's samples equal those of the
  FLAC it was encoded from, and seeks land on the exact frame.
- **AAC (LC, HE-AAC v1/v2, xHE-AAC) decodes through libxaac**, AOSP's
  Apache-2.0 decoder, built from its portable C sources. Against FFmpeg's decode
  of the same file the output has zero lag, the exact length and differences at
  16-bit quantization level. libxaac withholds 240 frames of the first access
  unit after init; the packet loop restores them as silence so the timeline
  stays where the sample table puts it.
- **Gapless bounds come from the edit list**, with Apple's `iTunSMPB` as a
  fallback, so a 200 ms AAC fixture carrying 1,024 frames of encoder priming
  decodes to exactly 9,600 frames.
- **iTunes tags and cover art** are read from `ilst`, including `----`
  freeform atoms for MusicBrainz identifiers.
- **Scanning MP4 costs what scanning FLAC does.** Properties come from the
  movie box rather than from an AAC decoder whose setup costs about 6 ms: a
  300-file AAC scan fell from 1.83 s to 0.14 s.
- **Files without a decoder are no longer reported as corrupt.** The analysis
  pass and property backfill filed AIFF, WavPack and any other sniffed but
  undecodable file as `corrupt_audio` or `unreadable_file` on every run.
- `zig build` installs the licence and notice files of the compiled-in
  Apache-2.0 and CC0 code under `share/doc/orca/licenses`.

### Ogg Opus and Ogg Vorbis play, scan and tag

- **Opus and Vorbis decode through libopusfile and libvorbisfile**, each behind
  a shim on the same terms as libFLAC. The libraries own the Ogg container,
  pre-skip, end trimming and sample-exact seeking, so a 200 ms Opus fixture
  whose container also carries 312 frames of encoder pre-skip decodes to
  exactly 9,600 frames, and 30-second streams report exactly 30,000 ms.
- **Tags come from the Ogg comment header** through a small page reader in
  `metadata/ogg_comment.zig` and the existing Vorbis comment parser. A comment
  packet spanning several pages is reassembled, bounded at 16 MiB.
- Scanning records `codec` as `opus` or `vorbis`, the decode rate, and no bit
  depth; analysis measures both formats and playback applies their
  ReplayGain. Embedded Ogg artwork is not read yet.

### Stable Zig, a Nix flake, and three defects the old snapshot hid

- **Orca builds with Zig 0.16.0.** The previous pin, `0.17.0-dev.1770`, is no
  longer downloadable, so the project could not be built reproducibly. The port
  is mechanical: `@backingInt`/`@fromBackingInt` became
  `@intFromEnum`/`@enumFromInt`, plus a handful of renamed `std` functions.
- **`flake.nix` provides the dev shell and a package.** `nix develop` (or
  direnv) supplies Zig, zls, pkg-config, SQLite, libFLAC, PipeWire and GTK4;
  `nix build` produces `orca-cli`, `orca-gtk`, `liborca` and `orca.h`.
- **`build.zig` no longer assumes `/usr/include`.** PipeWire and SQLite include
  paths come from `pkg-config --cflags-only-I`, so the build works on NixOS and
  on FHS distributions alike.
- **Volumes on device-mapper storage now get a stable identity.** A mount
  source such as `/dev/mapper/cryptroot` is a symlink to `/dev/dm-N`, and the
  `/dev/disk/by-uuid` lookup compared the symlink's own name, so LUKS and LVM
  volumes never matched their UUID and every Location on them was filed under
  no volume.
- **The analysis pass no longer re-measures every file.** The query selecting
  unanalyzed files bound its parameter hash as an SQLite static blob from a
  pointer into a by-value copy that died before the statement ran. The old
  compiler passed that struct by reference, which hid the defect.
- **A queue test stopped starving the engine it waited on.** It polled
  `playerQueueStats`, which pauses the engine on every call; it now polls the
  lock-free queue snapshot.

### Planning documents replaced

- `docs/architecture.md` and `docs/roadmap.md` replace the v1.0 implementation
  plan, the v0.10.0 review and the integration-recovery design. The recovery
  work those documents drove is complete; what remains is in the roadmap.

### FLAC decoding moved to libFLAC, because the pure-Zig package was not lossless

- **The pinned `audiophile/flac` dependency is gone.** It reconstructed
  mid-side stereo without restoring the low bit the encoder discards, so
  roughly half of all decoded samples came back one LSB low on the majority of
  real FLAC files. Exhaustively over 208,208 (left, right) pairs its formula is
  wrong for 50.0% of them; on ten 20-second excerpts of real music it differed
  from reference PCM on 10.2%–48.2% of samples. Inaudible at −96 dBFS, and
  fatal to `files.audio_hash`, to fingerprints, and to the one promise the
  format makes. The package ships no licence, so a corrected vendored copy was
  not an option.
- **`codec/flac_shim.c` contains libFLAC** on the same terms as `mp3_shim.c`
  and `pipewire_shim.c`. It is driven from `ReadableSource` through
  `FLAC__stream_decoder_init_stream`, so no path string or file handle is
  needed and no `FLAC__` type is visible above the shim. The same ten excerpts
  now decode bit-exactly — 0 differing samples, `max |delta| = 0` — and two
  encodings of one PCM stream at compression levels 0 and 12 decode
  identically to each other and to the WAV. Decoding is 2.7× faster: 15.7M
  frames in 0.148 s against 0.403 s, ReleaseFast.
- **`fixtures/audio/midside-reference.flac` is a regression fixture whose every
  sample has an odd `side`,** so a decoder that skips the low-bit restoration
  is wrong on 100% of them rather than 50%.
- **Stored analysis is invalidated.** `diagnostics_algorithm_version` and
  `fingerprint_algorithm_version` are both 2, so an existing library
  re-measures rather than trusting figures taken through the old decoder. Run
  `orca-cli analyze-library DATABASE`, then `orca-cli duplicates DATABASE`.

### Duplicate detection became reachable, indexed and bounded

- **`orca-cli duplicates` reports the audio a Library holds twice.** A runtime
  job (`OrcaRuntime.startLibraryDuplicateScan`,
  `orca_library_start_duplicate_scan`) on the same `JobWorker` machinery as the
  scan, the projection, the property backfill and the analysis pass: same
  cancellation token, same job snapshot, bounded commits, indexed row
  selection. Findings land in `library_health_issues` as `exact_duplicate` and
  `likely_duplicate` — two kinds that had existed, and two `analysis/health.zig`
  facts that had existed, with nothing producing either.
- **`fingerprint.findDuplicates` is gone.** It took every candidate in the
  library as one slice and compared all pairs: correct, tested, called by
  nothing, and impossible to call at 22,060 files let alone 500,000.
  `classifyDuplicate` survives it as the only pairwise comparison in the
  codebase; what changed is that an index now decides which pairs reach it.
- **Three indexed queries, no scans.** Selection walks `files` by primary key;
  the certain bucket is an equality search of `files_audio_hash`; the plausible
  bucket is a range search of `files_duration`, added by migration 13. A bucket
  holds at most 64 files, so the work is bounded by a constant per file, and at
  most two decoded fingerprints are resident at a time.
- **A file nothing has measured is counted, not silently called unique.**
  Reporting "no duplicates" over an unanalyzed library would be a lie of
  omission; 19,108 of the reference library's 22,060 rows are uncomparable
  today, and the run says so on its own line.
- **The likely threshold is 0.985, measured against the real library.**
  Constructed encodings of one master score 0.9904–1.0000 and the library's one
  real FLAC-and-MP3 pair scores 0.98511; unrelated tracks sharing a duration
  window reach 0.9590 across 11,568 real comparisons, and a track against its
  own karaoke cut reaches 0.9800. An earlier 0.95 produced 31 findings on the
  reference library, most of them unrelated tracks.
- Full run over the 22,060-file reference library (3,543 of it analyzed):
  1.30 s, 16.1 MiB peak RSS, 20,117 comparisons, five duplicate pairs and **no
  false positives** — every finding confirmed by hand against the files. One of
  them, `Roel Funcken — Nefit Kraton` against `— Scane Breitner`, is identical
  PCM under two different titles, which nothing else in the codebase could have
  found. 18,532 rows were reported uncomparable because `analyze-library` has
  not reached them. Re-running produces the same rows rather than twice as
  many, and a duplicate that has been deleted stops being reported.
- **Known limitation, recorded rather than worked around.** `codec/flac.zig`
  disagrees with the file's own PCM on 25.5% of samples (one LSB low, measured
  against ffmpeg on 18,522,000 samples), and its error pattern depends on the
  encoding, so two FLACs holding identical audio hash differently. That costs
  the exact test some findings it should make: a real byte-identical pair is
  reported as likely at 100.0% instead of exact. See `docs/analysis.md`.

### Album art became reachable, and the player shows it

- **Embedded cover art can be read, not just counted.** `observed_file_tags`
  had recorded an artwork MIME type, size and kind since the scanner existed,
  and nothing could obtain the image behind them. `metadata/artwork.zig` sniffs
  the container and dispatches to `id3v2.readPicture` or
  `vorbis_comment.readPicture`, which extract `APIC` and `PICTURE` payloads
  through the *same* frame and block parsers the observation already used — so
  an observation and a fetch cannot disagree about which bytes are the image.
  Verified byte-for-byte against an independent extractor on a real FLAC
  (254,372 bytes) and a real MP3 (422,564 bytes).
- **A leading ID3v2 tag does not hide a cover.** Artwork resolves the payload
  offset exactly as the codec registry does, so the reference library's 104
  ID3-fronted FLACs give up their `PICTURE` block. The adversarial case — a
  216,921-byte picture block behind a 219,663-byte tag — extracts to the exact
  216,870 image bytes an independent tool reports.
- **The media type is read from the bytes, not from the claim.** 93 files in
  the reference library declare `image/jpg`, 24 declare nothing, and one
  album's covers are 5.3 MB animated GIFs behind an empty declaration. A
  payload that is not a recognised image is refused rather than handed to a
  platform decoder, and the size bound — 12 MiB, below both containers'
  ceilings so it can actually fire, above the library's largest real cover of
  11.29 MiB — is checked against the declared length before anything is
  allocated to honour it.
- **Nothing is stored in the Library and nothing is cached.** 19,031 of the
  22,060 files carry a readable cover, totalling 6.09 GB; that does not belong
  in a SQLite file. Reading on demand costs one open per request, can never go
  stale — a track whose observation predates the current reader still yields
  its cover — and a whole-library audit of all 22,060 files took 6.3 seconds.
  A bounded per-Release cache is the right next step and is deliberately not
  here yet, because the one consumer loads a single image per track change.
- **A Release's artwork is its first track's, in listening order, that has
  one.** Real tag data disagrees within an album, so the rule is chosen to be
  stable across runs (the unique `tracks_position` order), cheap (candidates
  are pre-filtered by what the scan observed, so a coverless Release opens no
  files at all, and at most eight are tried), and unsurprising.
- **The GTK transport bar shows the now-playing cover.** One `GtkImage` in two
  states, refreshed only when the audible Track changes. A missing cover, a
  missing file, a refused image and an undecodable one all show the same
  placeholder. Decoding is bounded to 128 pixels inside gdk-pixbuf's scaling
  loader, because an 11.3 MiB JPEG is 3000 pixels square and encoded size says
  nothing about pixel count. Driven through the real widgets on the real
  library: 154 MB resident with all 22,060 tracks open and no cover shown,
  168 MB with an ordinary cover, 192 MB with the largest cover in the library,
  steady across eleven consecutive loads.
- **The Releases pane deliberately shows no thumbnails.** 512 covers per page
  load is 512 file opens and roughly 150 MB of encoded image on one scroll.
  `libraryReleaseArtwork` exists for when a grid view and a cache do.
- `orca-cli artwork DATABASE (--track=ID | --release=ID) [--out=PATH]`.

### Analysis became a library job, and playback started using it

- **`orca-cli analyze-library DATABASE` measures a whole Library.** Loudness,
  peak, clipping, silence, waveform and temporal fingerprint were computed only
  for one file a human named, so `Gain.setReplayGain` was called by nothing and
  a quiet track stayed quiet. `library/analysis_pass.zig` runs the same
  measurement over every file the Library has not measured yet, as a runtime
  job on the shared `JobWorker` — reachable from the Zig API, the C ABI
  (`orca_library_start_analysis`) and the CLI, with `files.audio_hash` written
  for the first time.
- **It is built to be stopped.** It decodes whole files, so a run is hours
  rather than seconds: 50 real files measured in 27.2 s (0.545 s each,
  ReleaseFast), which extrapolates to about 3.3 hours for the 22,060-file
  reference library. Cancellation is honored inside a decode, the batch already
  measured still commits, and the next run selects only the remainder — a pass
  cancelled after 11 of 50 files was followed by one that measured exactly 39.
- **"Already analyzed" is the analysis cache key, not a new flag.** The key
  already encodes every reason a measurement stops describing a file — its
  bytes, its algorithm version, its parameters — so selection is an anti-join
  against `analysis_results`' own primary key rather than a marker column free
  to disagree with the results it describes. The page query is
  `SEARCH files USING INTEGER PRIMARY KEY` plus one full-prefix covering-index
  probe per row; no new index, no table scan.
- **ReplayGain reaches the audio, and stays right across a gapless
  transition.** The correction is a property of the audio rather than of the
  Player: the session that decodes an entry carries the figure measured from
  those exact bytes and scales its own frames by it, so an entry with no
  measurement plays at unity instead of inheriting the previous one's and a
  file edited since the last scan loses a correction it no longer matches. A
  Player-level multiplier could not be right during a gapless advance — the
  pipe holds two entries' blocks at once — and neither could a per-block one,
  because a canonical block is filled from two decoders across the boundary.
  Attaching it at the single point where a queue entry becomes audio covers
  the hard load, the auto-advance, the format switch and the seek re-open
  together. On the reference corpus the loudest and quietest tracks went from
  17.30 dB apart to 0.71 dB, gaplessly as well as on a skip, with the
  transition's gapless, decode-error, open-failure and underrun counts
  unchanged. `off` and `track` reach the ABI and `orca-cli play-tracks
  --replay-gain=`, and now take effect as the decoded-ahead audio drains
  rather than at the next track; album gain is out of scope.
- **`orca-cli play-tracks` can move the volume.** `--volume=N` and
  `--set-volume=MS:N` exist so that user volume and loudness correction being
  independent is checkable from outside: changing one mid-track leaves the
  other exactly where it was.

### The library became browsable, and stopped losing 104 files

- **Tracks are connected to artists.** The projection wrote 2,474 artists and
  2,637 releases and nothing could read any of them back — no list, no page, no
  lookup by id — and there was no relational link at all: `tracks` had no
  `artist_id`, `recordings` no artist, `releases` no `album_artist_id`.
  Migration 9 adds the links and 11 re-keys them; `ArtistPage`, `ReleasePage`
  and a `TrackQuery` with seven sort keys, a direction and artist/release
  filters expose them through the runtime, the C ABI and `orca-cli artists /
  releases / tracks`. Paging is exact under ties: every `ORDER BY` ends with a
  unique tiebreaker, without which `LIMIT`/`OFFSET` silently drops and
  duplicates rows — 3,476 of 22,060 tracks share a title.
- **An artist's tracks are the ones credited to them *or* on a release they are
  the album artist of.** The narrow definition left 33 artists owning an album
  and no songs, and those are not tag defects to normalize away: a featured
  credit, a collaboration, an `&`-versus-`,` convention, or simply no `ARTIST`
  tag. Widening the definition covers all of them and guesses at nothing.
- **The key fold learned typographic punctuation.** `ALBUMARTIST` carries what
  a metadata service supplied and `ARTIST` carries what somebody typed, so
  `El‐P` (U+2010) and `El-P` were two artists — one holding every release, the
  other every track. Migration 11 merges them; **migration 12 re-keys releases
  for the same reason**, without which any reprojection built a parallel
  release beside each stale one and turned 22,060 tracks into 23,271.
- **An ID3 tag is not a format.** `sniff` answered `ID3` with `.mp3`, so 104
  genuine FLAC files in a real library were handed to the MPEG decoder and were
  **unplayable**. Detection now returns a payload offset and the codec registry
  presents the decoder an `OffsetSource`; the scanner steps the tag reader over
  it too, so those files stop scanning as untitled with no artist. MPEG
  deliberately keeps offset 0, because its decoder is defined over the whole
  file including trailing tags.
- **A FLAC that stops inside its final block is finished, not broken.** Real
  files end untidily — one of those 104 stops 2,620 frames short of the
  11,979,324 its STREAMINFO declares. That raised `OutOfSync`, which failed
  analysis outright and ended playback in a decode error. A shortfall smaller
  than one maximum block is at most the final frame; anything larger still
  errors.
- **Destroying one Player no longer tears down every other one.** It drained
  the whole work registry, cancelling every other Player's engine thread and
  every scan in flight. Registrations carry an owner tag now.
- **User volume and replay gain no longer overwrite each other.** They shared
  one stored value, so applying a loudness correction would have moved the
  host's volume slider.

### Files declare what they are, and old rows can be repaired

- **`files.codec` is written.** It was declared and then always stored as the
  empty string, so every row in a real library recorded no encoding at all. A
  probe already opens a decoder; the decoder now names its encoding through
  `codec/decoder.zig`'s `codec_id` — `pcm`, `pcm_float`, `flac`, `qoa`, `mp1`,
  `mp2`, `mp3` — and the scanner carries that into the row. It is deliberately
  **not** a synonym for `audio_format`: that names the container, which decides
  who opens a file, while `codec` names the encoding inside it, which decides
  what the bytes cost. The two diverge wherever a container is a wrapper — a
  WAV holding integer PCM or IEEE float, an MPEG stream's layer, and the
  AAC-or-ALAC and Vorbis-or-Opus cases still to come. Lossy and lossless are
  told apart by `codec_id.isLossless`, a function of the identifier rather than
  a second column that could disagree with it.
- **A property backfill, as a runtime job.** The scanner probes only files
  whose bytes changed, which is what keeps a rescan of a large library nearly
  free — and which means a library scanned before probing existed keeps null
  `duration_ms` for ever, because a music collection's bytes never change.
  `library/property_backfill.zig` repairs those rows by `files.id` with no
  filesystem walk: `OrcaRuntime.startLibraryPropertyBackfill`,
  `orca_library_start_property_backfill`, `orca-cli backfill`. Row selection is
  a search over `files_incomplete_properties`, a **partial** index (migration
  10) over exactly the incomplete rows, so it shrinks to nothing as the pass
  works. Commits are bounded, cancellation is checked between rows, and a
  cancelled run commits what it already probed — so a second run resumes with a
  shorter list rather than starting over. **Unlike a scan the job publishes a
  total**, because how many rows still owe a probe is one indexed count.
- **The backfill reprojects what it repaired.** `tracks.duration_ms` is derived
  from the file rows, so a pass that repaired `files` and left the Tracks
  reading zero would have fixed nothing a transport bar can show. Each
  committed batch is handed to the projection scoped to its own file ids,
  exactly as a scan batch is.
- **An unreadable file is not a failure of the pass.** A row whose file is gone
  or is not audio is counted and passed over with no health issue, because
  `locations.state` already models absence. A file that opens and then refuses
  to decode raises the new `unreadable_file` health issue, a kind the backfill
  owns outright so that clearing it cannot erase a `corrupt_audio` finding the
  analyzer made by decoding audio this pass never read.

### The C ABI reaches the runtime (breaking)

Until now `liborca/orca.h` exposed runtime create/destroy, library open/query,
and a Player state machine that was not connected to anything. There was no way
to load a track, attach an output, trigger a scan, read a position, or observe
an event, which is why the GTK app's play button did nothing. The boundary now
exposes the surface the frontends actually need.

- **Breaking: `orca_track_view` grew.** It now carries `artist`, `duration_ms`,
  `track_number`, `disc_number` and `has_file`, each numeric field paired with a
  `has_*` flag so "zero" and "the library does not know" stay distinguishable.
  `TrackSummary` already carried all of it. Both consumers are in-tree and there
  are no external clients, so the break was taken now rather than later.
  `orca_player_state_snapshot` is untouched; the richer transport view is a
  **new** `orca_player_status` rather than a grown struct that already shipped.
- **Scanning is a job, not a blocking call.** `orca_library_add_root`,
  `orca_library_remove_root` and `orca_library_query_roots` manage roots;
  `orca_library_start_scan` registers a `work.Registry` worker with its own
  `std.Io` and its own cancellation token and returns immediately.
  `orca_job_snapshot_get`, `orca_job_cancel` and `orca_library_scan_stats`
  observe it. **Scan progress reports `completed_units = files_processed` with
  `has_total = 0`:** a filesystem walk has no honest denominator until it has
  finished walking, and Orca does not invent one. Shutdown, `orca_library_close`
  and `orca_player_destroy` all cancel and join scan workers before anything
  they hold can be freed.
- **The scan projects as it commits**, exactly as `orca-cli scan` does, because
  a scan whose results are never projected has not made a library browsable.
  `orca_library_start_projection` is the other direction — reprojecting after a
  metadata change, with no filesystem walk. `orca-cli scan` and `project` now
  run through those same runtime jobs, so the CLI and the ABI cannot drift.
- **Events.** `orca_runtime_pump` drives the control lane;
  `orca_runtime_poll_event` drains the existing lossless completion channel and
  the existing coalescing telemetry channel into one tagged POD `orca_event`
  with a named `extern union` payload — ABI-stable, and it imports cleanly into
  Swift. Kinds: command completed, job progress, job finished, player position.
- **Transport, queue and now-playing.** `orca_player_set_library`,
  `_play_track` (through the control lane, correlated by request id),
  `_play_tracks`, `_enqueue_tracks`, `_next`, `_previous`, `_clear_queue`,
  `_set_repeat`, `_set_shuffle`, `_set_volume`, `_volume`, `_seek_ms`,
  `_status_get`, `_now_playing` and `_query_queue`. `orca_player_status`
  carries transport, repeat, shuffle, epoch, `position_ms`, `duration_ms`,
  `track_id`, `queue_length`, `queue_index` and volume in one lock-free read.
  Position is derived from the packed epoch+frames atomic the render callback
  writes, never reconstructed from events, and now-playing reports the
  **audible** entry rather than the decode cursor.
- **Devices and zones.** `orca_enumerate_output_devices`, `orca_zone_create`,
  `_destroy`, `_attach_player`, `_detach`, `_open_output`, `_close_output` and
  `_status_get`, plus `orca_player_open_default_output`, which creates,
  attaches and opens in one call so a single-output frontend never has to know
  Zones exist. Device id 0 delegates to the server default.
- **Volume is real.** A `processing.Gain` lives beside each Player, is installed
  as the engine's Player-scope processor, and applies to canonical PCM once
  before fanout, so every Zone hears the same level and a stop/start keeps it.
- **A single-thread contract that is enforced.** All `orca_*` calls for one
  runtime must come from one thread, `orca_runtime_poll_event` included. Debug
  builds record the creating thread and return `ORCA_STATUS_WRONG_THREAD` on a
  violation. This is no longer theoretical: the runtime behind the boundary is
  genuinely multithreaded and its object pools take no lock.
- **A Player with nothing to play refuses to play.** `orca_player_play` now
  requires a loaded source or a non-empty queue *and* an attached Zone. The C
  ABI smoke test asserted the opposite for as long as the defect existed; that
  assertion is now inverted, and the test drives the whole path — open, add
  root, scan as a job, wait, project, query, open a default output, play by id,
  watch the position advance, pause, seek, next, clear, shut down.
- **Position is anchored to the audible queue entry, not to the epoch.**
  `orca_player_status.position_ms` used to keep accumulating across a gapless
  auto-advance, so every entry after the first reported the sum of everything
  played before it — elapsed time past the end of the track, and a seek slider
  pinned past its maximum. A gapless transition deliberately does not bump the
  epoch, so frames-since-epoch was never the right anchor for a per-track
  position. The render callback now also publishes the frames-since-epoch value
  at which the audible entry started, packed with that entry's serial in a
  single `u64` so the control lane can detect a torn pair and discard it exactly
  as it discards a mismatched epoch. No lock, no allocation and no extra work in
  the render callback.

## 0.1.0-alpha

**Version reset.** The project was previously tagged `0.10.0`. That number, and
the release notes below it, describe subsystems that exist as tested components
but are **not reachable through the authoritative runtime or ABI path**. The
version has been reset to `0.1.0-alpha` to stop the changelog from overstating
what works.

### Added since the reset

- **A playback queue: Orca plays a song, and a list of songs.** A bounded
  `PlaybackQueue` of Library track references sits above the gapless decode
  queue, with enqueue, play-now, next, previous, stop, clear, repeat and
  shuffle. `playerPlayTrack` resolves a Track id through
  `TrackRepository.playableLocation` on an independent read-only connection,
  opens a self-contained decoder for it, and loads it on the control lane —
  never on a caller's UI thread — failing with typed reasons (`track_has_no_file`,
  `track_file_missing`, `codec_unavailable`) and marking the Location `missing`
  when the file has gone. Auto-advance primes the next entry at end-of-decode, so
  a real album plays gaplessly; a canonical format mismatch is not fatal but
  drains the pipe and reopens the Zone output at the new format, verified on
  hardware across 44.1 kHz -> 96 kHz -> 44.1 kHz. A user skip is a hard switch
  and immediate, `previous` restarts past three seconds, shuffle uses a
  permutation so `previous` keeps working, and now-playing is derived from the
  `entry_serial` the render callback publishes rather than from the decode
  cursor, which leads it by the whole render-ahead depth. `orca-cli play-tracks`
  drives all of it.
- **`playFileBlocking` is gone.** The stack-local single-Zone playback path has
  been deleted; `orca-cli play` runs through the runtime object graph, which is
  the only implementation left.

- **Scanned files carry their decoded audio properties.** A file whose bytes are
  new or changed is probed through the codec registry, and `files.sample_rate`,
  `bit_depth`, `channels` and `duration_ms` record what its container declares.
  Only headers are read, so a 22,060-file cold scan is unchanged at ~3.2 s and a
  rescan that finds nothing changed still does no format work at all. A file that
  will not open is recorded with no properties rather than failing the scan.
  Duration reaches `tracks.duration_ms` through the projection, so a Track lists
  its length. Verified against `ffprobe` on real library files: exact for every
  FLAC and every MP3 carrying a Xing/Info header, and within 0.1% on
  variable-bitrate MP3s that declare no length at all, which no reader can do
  better on without decoding.
- **`tracks.preferred_file_id` is chosen on declared properties.** Higher bit
  depth wins, then higher sample rate, then a location a scan has confirmed; the
  container ranking is now only a tiebreak between encodings that declare the
  same thing. A missing property is unknown rather than zero, so a lossy file
  with no sample width to state loses to a real 16-bit one, and a file the
  scanner could not open never outranks one it could.
- **MP3 playback.** `codec/mp3.zig` decodes MPEG Layer I/II/III through a
  vendored public-domain `minimp3` contained behind `codec/mp3_shim.c`, with
  pure-Zig Xing/Info/VBRI parsing, LAME encoder delay and padding trimming, and
  seeking that is exact for both constant-bitrate streams and variable-bitrate
  streams with a lazily built frame index. Verified against real library files:
  reported length matches `ffprobe` on every tagged file tested, and decoded
  length matches it exactly on eleven of thirteen.

### Fixed since the reset

- **File mutation is now crash-safe end to end.** Journal writes raise SQLite
  durability for their own transaction, every action of a group is journaled
  before any filesystem work, stage creation and both rename boundaries fsync the
  containing directory, `commitReplacement` revalidates source identity
  immediately before renaming, and `FileIdentity` carries a `quick_hash`
  (BLAKE3 over first 64 KiB ‖ last 64 KiB ‖ size) so a same-size edit with a
  preserved timestamp is detected. Recovery never reports `rolled_back` unless
  the original file is provably back in place; otherwise it records
  `needs_reconciliation` and retains every file.

### Errata against the release notes below

Verified against the code and by running the binaries, not inferred from docs:

- **No music can be played from the application.** Playback exists only inside
  `audio/backends/pipewire_playback.zig:playFileBlocking`, reachable solely from
  `orca-cli play FILE`. The runtime's Player is a detached state machine, no
  runtime Zone owns an output device, and `orca_player_play` only sets an enum.
- **Scanning does not produce a browsable library.** `library/scanner.zig`
  writes only `observed_files`; the `tracks`, `files`, `locations`, `artists`,
  `releases`, `recordings` and `library_roots` tables stay empty. Confirmed by
  scanning a 3-file folder and reading the resulting database.
- **Tags are not read for real-world files.** Only ID3v1 (the obsolete 128-byte
  trailer) is parsed, and only for MP3. `metadata/vorbis_comment.zig` has
  `rewrite` and `create` but **no `read`**, so FLAC tags are never extracted.
  There is no ID3v2 and no MP4 metadata support.
- **Only WAV, FLAC and QOA can be decoded.** MP3, AAC/M4A/ALAC, Opus and Vorbis
  fail with `CodecUnavailable`.
- `0.7.0`'s "immutable mutation previews" *was* inaccurate — an approved plan
  borrowed caller-owned slices and could be mutated through another alias, and
  startup journal recovery was only invoked directly by tests. **Both are now
  fixed:** a plan deep-copies and seals its actions and approval names a content
  digest, and `LibraryDatabase.open` drives every nonterminal journal record to a
  terminal state before returning, refusing to open if it cannot.
- `0.8.0`'s native frontends cannot select or play a track. The GTK list has no
  row-activation handler, MPRIS accepts Next/Previous with no behavior and
  reports empty metadata and zero position, and macOS has never been compiled.
- `0.9.0`'s claim that scheduler yields keep analysis subordinate to playback is
  unproven; there is no shared scheduler and no contended workload test.
- `0.10.0`'s scrobble queue is idempotent only for *local enqueue*. Remote
  delivery is at-least-once, and nothing connects the queue to playback events.
- Releases `0.3.0` through `0.6.0` are missing from this file entirely.

A capability is now considered done only when it is reachable from `orca-cli` or
the GUI through the public runtime/ABI path. The notes below are retained
unedited as a record of what was built, not as a statement of what works.

---

## Pre-reset 0.10.0 - 2026-08-21

Provider-assisted identification and scrobbling milestone.

- Central native HTTP gateway with bounded responses, service identification,
  serialized rate limits, retry/backoff policy, and explicit offline mode.
- Durable fresh/stale provider cache and MusicBrainz recording search with
  offline fallback.
- Credential-safe AcoustID lookup for externally generated
  Chromaprint-compatible fingerprints; secrets never enter durable cache keys.
- Multi-evidence candidate scoring and durable alternatives with explicit
  confidence instead of silent metadata replacement.
- Transactional proposal acceptance into Orca metadata that preserves user
  locks and remains separate from file mutation.
- Idempotent persistent scrobble queue with eligibility policy, retry state,
  and secure ListenBrainz and signed Last.fm adapters.

## Pre-reset 0.9.0 - 2026-08-21

Cached analysis and Library Health milestone.

- Streaming EBU-style gated loudness, ReplayGain adjustment, peak, RMS,
  clipping, silence, and fixed-size waveform summaries over native decoders.
- Portable, versioned analysis identities and result encodings with selective
  parameter, algorithm, and source-identity invalidation.
- Temporal fingerprints, decoded-audio and exact-file hashes, plus exact and
  likely duplicate classification.
- Cooperative cancellation, bounded progress, source revalidation, and
  scheduler yields that keep background work subordinate to playback.
- Indexed Library Health evaluation and bounded query APIs exposed through the
  CLI, stable C ABI, and virtualized GTK frontend.

## Pre-reset 0.8.0 - 2026-08-21

Native frontend and desktop-media integration milestone.

- Installed static/shared liborca with an opaque, C-compatible runtime,
  generational handles, POD Player snapshots, and callback-scoped query views.
- Bounded 256-row library pages shared by foreign clients without exposing
  SQLite rows or internal Zig layouts.
- Native GTK4 frontend with paged search, transport controls, file dialogs,
  drag/drop, notifications, accessibility-native widgets, and shortcuts.
- Verified MPRIS service whose controls and `PlaybackStatus` mirror the
  authoritative liborca Player.
- SwiftUI/AppKit client source over the same ABI with virtualized views, native
  interactions, Now Playing, and remote-command integration.

## Pre-reset 0.7.0 - 2026-08-21

Canonical metadata and safe file-mutation milestone.

- Separate observed, preferred Orca, and policy-resolved effective metadata
  layers with persisted provenance and user locks.
- Immutable mutation previews that require exact explicit approval before any
  external write.
- Durable operation journaling with staged after-identities, reverse-order
  grouped undo, startup recovery, and explicit reconciliation for external
  conflicts.
- Conservative, recoverable ID3v1 writes and Zig-native FLAC Vorbis-comment
  writes that preserve unknown metadata and encoded audio frames.
- Collision-safe journaled file moves with crash recovery and after-state-aware
  undo.

## Pre-reset 0.2.0 - 2026-08-21

Incremental local-library acquisition milestone.

- Path-independent local readable sources and byte-based format sniffing.
- Cancellable, restart-resumable recursive scans with bounded commits and
  unchanged-file identity checks.
- Persisted observed-file state and ID3v1 metadata kept separate from preferred
  Orca metadata.
- Shared per-Library write serialization and schema migrations through v3.
- Bounded/coalesced watcher hints plus a tested Linux inotify adapter.
- Headless durable scanning through `orca-cli scan`.

## Pre-reset 0.1.0 - 2026-08-21

First verified liborca foundation milestone.

- Reproducible Zig build, test, benchmark, CLI, and platform boundaries.
- Typed generational runtime handles and ordered, allocation-free shutdown.
- Bounded asynchronous commands, completion backpressure, coalesced telemetry,
  and common Job state/snapshots.
- Runtime-owned, independently openable SQLite libraries with transactional
  migrations, FTS5 search, typed batched repositories, WAL readers, and
  serialized writes.
- Repeatable 500,000-track persistence benchmark and concurrency coverage.
