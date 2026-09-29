# Roadmap

What Orca does today, what comes next, and what is deferred. "Works" means
reachable from `orca-cli` or `orca-gtk` through the public runtime path, per
the rule in [architecture.md](architecture.md).

## Status

Unreleased `0.2.0-alpha`. `orca-gtk` is a daily-usable player on Linux: a
designed libadwaita frontend, gapless playback between entries of one format,
output at each source's sample rate, live equalizer and crossfeed, tag
editing with undo, track details, a local play history, ListenBrainz
scrobbling, MusicBrainz and AcoustID matching with review, and AcoustID
submission. Filesystem watching is built but not connected. `liborca` does
not compile for aarch64 targets, Apple Silicon included, and macOS has no
audio output yet.

The next milestone is correctness and maintenance, not features: the
signal-path report, tag-write backups, provider state that is lost on restart,
parser hardening and the size of `runtime.zig` come before filesystem
watching.

## Works today

### Library

- Incremental, restart-resumable scanning of library roots. Unchanged files
  are skipped by path and storage identity; commits are bounded and
  cancellable.
- File and Location identity keyed by stable volume identifiers (filesystem
  UUID, including device-mapper volumes, or a persisted volume marker).
- Projection into artists, releases, recordings and tracks, with FTS5 search
  and bounded browse pages by artist, release and track.
- Property backfill for rows scanned before audio properties were recorded.
- Embedded cover art extraction.

### Formats

- Decoding: FLAC (libFLAC), MP3 (vendored minimp3 with Xing/LAME gapless
  trimming), ALAC and AAC in MP4 (Apple's reference decoder and libxaac, with
  edit-list gapless trimming), raw AAC in ADTS, Ogg Opus (libopusfile), Ogg
  Vorbis (libvorbisfile), WAV including `WAVE_FORMAT_EXTENSIBLE`, AIFF and
  uncompressed AIFC, QOA (the reference decoder).
- Tags and cover art: ID3v1 and ID3v2 (MP3, ADTS, and the ID3 chunk of WAV and
  AIFF), WAV `LIST`/`INFO`, Vorbis comments and pictures in FLAC and Ogg, and
  iTunes atoms in MP4.

### Playback

- A runtime-owned Player and Zone object graph with PipeWire output.
- A gapless queue with repeat, shuffle, next, previous, seek, pause and
  volume. A format change between entries reopens the output at the new
  format, and each stream asks PipeWire for its source's sample rate; the
  signal path reports the rate the device actually runs at.
- Per-entry ReplayGain from analysis results.
- A ten-band equalizer with presets, stereo crossfeed, and a signal-path
  report of the source, each processing stage, the output stream and whether
  the path could be bit-perfect (`orca-cli play-tracks --eq --crossfeed`).
- Output device selection.
- Track details: format, file, loudness, tags and MusicBrainz recording ID
  with its source for one Track (`orca-cli track`), and a details panel in
  `orca-gtk`.

### Listening

- A local play history: every listen (a track of 30 s or more, heard for half
  its length or four minutes) is recorded in the Library and kept forever.
  Play count and last play appear in `orca-cli track` and in the `orca-gtk`
  details panel. `orca-cli play-tracks` records listens too.
- ListenBrainz scrobbling, off until enabled: a leased, restart-safe queue, a
  gateway that identifies Orca, spaces requests and honours `429`, and a token
  held in the Secret Service (`orca-gtk` Preferences > Listening) or read from
  `ORCA_LISTENBRAINZ_TOKEN` (`orca-cli scrobble`). See
  [providers.md](providers.md).
- Love and hate for songs, kept in the Library per recording and sent to
  ListenBrainz while scrobbling for recordings with a MusicBrainz recording
  ID, from the file's tags or an accepted match. `orca-gtk` has a heart in the
  player bar, a heart button on every song row and context menu entries, and
  its details panel says when a love cannot sync; `orca-cli feedback` sets
  it.
- Now Playing, off until enabled: the playing track is announced to
  ListenBrainz after 10 s (`orca-gtk` Preferences > Listening).

### Identification

- MusicBrainz matching: a cancellable job searches MusicBrainz for every
  Track whose file has no recording ID, one request a second with answers
  cached for 30 days, and stores reviewable proposals. Accepting one records
  the recording ID in the Library only, so loves and listens can be sent under
  it; bulk acceptance of confident matches is an explicit action. Reachable
  through `orca-cli match`, `matches`, `accept-match`, `dismiss-match` and
  `accept-matches`, and in `orca-gtk` through the Matches page, the details
  panel's MusicBrainz section (with a single-song Find Match) and the
  confidence threshold in Preferences. See
  [providers.md](providers.md#matching).
- AcoustID matching: the same job fingerprints each file with Chromaprint and
  looks up to 20 fingerprints at a time on AcoustID, merging both services'
  candidates into one proposal per recording; each service is asked once per
  file. Reachable through `orca-cli match` (`--no-fingerprints` leaves it
  out), `matches` and `fingerprint`, and in `orca-gtk` through Find Matches
  (Preferences > Library > Match by audio fingerprint turns it off), with
  each proposal's source and AcoustID score on the Matches page and in the
  details panel.
- AcoustID submission: `orca-cli submit-acoustid` sends the fingerprints of
  files whose recording ID came from an accepted match or an edit, once per
  file and ID, with the user key from `ORCA_ACOUSTID_USER_KEY`; `orca-gtk`
  sends them from the Matches page's Submit to AcoustID, with the key saved
  in Preferences > Library. See
  [providers.md](providers.md#acoustid-submission).

### Analysis

- Loudness and ReplayGain, peaks, silence, waveform and a temporal
  fingerprint, cached by algorithm version and parameters.
- AcoustID fingerprints (Chromaprint over libsamplerate), cached per file.
- Library-wide analysis and indexed duplicate detection as cancellable jobs.
- Library health issues.

### Clients

- `orca-cli`: scan, browse, search, library edits, tag write-back and undo,
  analysis, duplicates, artwork, queue playback, `feedback`, `scrobble`,
  MusicBrainz and AcoustID matching, fingerprints and AcoustID submission.
- `orca-gtk`: a libadwaita window with an album grid and album pages, artist
  pages, track browsing and search, Now Playing, an editable queue, context
  menus, tag editing with write-back and undo, Preferences, a Health page, a
  player bar with cover art and an output menu, job progress, a welcome page,
  toasts, a shortcuts dialog, MPRIS, ListenBrainz submission with play counts
  in the details panel, love and dislike, MusicBrainz and AcoustID match
  review, and AcoustID submission.
- C ABI (`liborca/orca.h`), exercised end to end by `tests/c_abi_smoke.c`.

## Built but not reachable

These exist with tests, but no client can use them yet. Each needs a runtime
entry point and a client before it counts as working.

- File moves through the journaled `MutationPlan` executor. Tag writes are
  reachable; moves are not.
- Setting a recording ID by hand: `libraryEditTracks` accepts a locked
  MusicBrainz recording ID, but neither `orca-cli edit` nor the `orca-gtk` tag
  editor offers the field.
- The Linux filesystem watcher.

These have no planned client and are deleted in the maintenance milestone:

- The Last.fm adapter.
- The ordered DSP graph (`Chain`, `PublishedChain`), `audio/transition.zig`,
  and the `Resampler` interface with its linear implementation. The Player's
  equalizer, crossfeed and volume run through `PlayerDsp`, playback never
  resamples, and libsamplerate (`resampler.SampleRate`) resamples only for
  fingerprints.

## Next

In priority order. Each step leaves `orca-gtk` usable every day.

1. **Correctness and maintenance.** No new features until these land:
   - **Tag-write backups out of the scan path.** The staged copy and the
     retained original sit beside the music, so the next scan ingests the
     backup as a second Track with the old tags, and after an undo its rows
     stay as `missing`. Keep stage and backup files where the scanner never
     looks, prune backups, and drop ghost rows.
   - **A truthful signal-path report.** Widening a source of 24 bits or fewer
     to 32-bit float is exact and must not make a path "not bit-perfect"; a
     lossy source, a 32-bit integer or 64-bit float source, and any gain that
     is not exactly 1 must. A volume ramp back to 1.0 ends at 0.99999 and is
     reported as 1.0: the ramp snaps to its target, and the report reads the
     gain that is applied. `orca-gtk` states that PipeWire's own volume and
     resampling are not visible to Orca.
   - **aarch64 builds, and CI.** `database/sqlite.zig` builds
     `SQLITE_TRANSIENT` as a misaligned function pointer, which aarch64
     rejects. A CI workflow runs `zig build test`, `zig fmt --check` and a
     cross-build of `liborca` for `aarch64-macos`.
   - **Release `v0.2.0`** once the three items above land: the first tag,
     following [Releases](#releases). `build.zig` and `flake.nix` read the
     version from `build.zig.zon`, so it is written in one place, and the
     `-alpha` suffix is dropped: a `0.x` version already makes no stability
     promise.
   - **Parser hardening.** Checked arithmetic in `codec/mp4.zig`, where a
     crafted sample table overflows, and fuzz targets for ID3v2, MP4 and
     ISO-BMFF, Vorbis comments, WAV, AIFF, ADTS and the MP3 stream reader.
   - **The two intermittent test failures, fixed at their causes.** The
     engine's `quiesce` can starve it when the control lane suspends it again
     within one park interval, so its output never opens; and the queue
     cursor is published before the Player's gain and duration, so a reader
     can pair a new entry with the previous entry's figures.
   - **Provider state that survives the process.** A `429` block and its
     backoff are held in memory, so a restart or a new `orca-cli scrobble`
     sends into the block: queue rows record their retry time, and each
     service's block is stored in the Library. A per-service lease lets one
     process at a time talk to each service. Backoffs get jitter,
     `Retry-After` is honoured uncapped, in both forms and on `503`, and a
     query a provider refused is not sent again for a week.
   - **AcoustID submissions that add information.** A recording ID that
     AcoustID itself proposed is not submitted back, and bulk-accepted
     text-only matches are not submitted.
   - **Idle power.** The engine thread wakes every 2 ms for the Player's
     lifetime, paused or not, and the artwork loader every 50 ms: both wait
     on a futex while idle.
   - **Maintenance.** Split `core/runtime.zig` (job worker with per-kind
     requests and stats, tests and fakes, queue, listens, jobs and zones) and
     `database/repository.zig` (by aggregate, with shared column helpers);
     one set of network test doubles; a dispatch table for `orca-cli`; delete
     the code listed above; remove comments that narrate history.
   - **Documentation cleanup.** Bring `docs/` in line with the code:
     `analysis.md` still describes the replaced FLAC decoder as one LSB low;
     `storage.md` and `metadata.md` name tables that schema 8 dropped;
     `metadata.md` misstates the journalled identity and which client edits
     recording IDs; `ownership.md`, `frontends.md` and `audio-engine.md`
     describe superseded stages. Contract docs keep invariants, ownership and
     threading; measurements, reference-library figures and history move to
     `CHANGELOG.md` or are deleted. `README.md` gains an embedding entry
     point and a complete list of requirements.
2. **`liborca` as a library for others.** A versioned SONAME, `orca_version`,
   an installed `orca.pc`, and only `orca_*` symbols exported: today every
   bundled C and C++ dependency is exported from `liborca.so`, libc++'s
   `operator new` included. A last-error message for C callers, a wakeup
   callback or file descriptor so hosts need not poll on a timer, a stability
   statement in `orca.h` and [api.md](api.md), and a provider identity the
   host must supply instead of a default.
3. **Filesystem watching** as a scan accelerator, so new files appear without
   a manual rescan. The Linux watcher exists; it needs a runtime entry point
   and a client.
4. **Faster analysis.** The analysis pass decodes on one thread and reads
   every file twice, once for a whole-file hash nothing uses. Decode on a
   bounded pool of threads, drop the hash, and compute the Chromaprint
   fingerprint in the same decode.
5. **Tag writers for the remaining formats, and the C ABI's catch-up.** FLAC,
   MP3 and ADTS are written; M4A, Ogg, WAV, AIFF and FLAC with a leading ID3
   tag are reported as not writable. No writer stores an accepted recording
   ID in a file yet: ID3 needs a `UFID` frame and Vorbis comments a
   `MUSICBRAINZ_TRACKID` field. The C ABI covers about a third of the Zig API:
   it lacks tag writes, queue editing, artwork, DSP, track details, matching
   and AcoustID submission.
6. **Playlists and ratings.** `tracks.rating` exists; playlists have no
   schema yet. Play history, love and hate, and Now Playing are done.
7. **More identification sources.** ListenBrainz's `/1/metadata/lookup`
   would match what MusicBrainz and AcoustID miss, 50 songs per request, but
   needs the user's token and must share the listen worker's gateway.
8. **An optional fixed output rate with a band-limited resampler**, for
   devices held at another rate and for gapless playback across sample-rate
   changes. Output at the source rate stays the default, since it is the
   only path that can be bit-perfect.

## Releases

Orca follows [Semantic Versioning](https://semver.org). Before 1.0, a
release bumps the minor version when it contains a breaking change to the
Zig API, the C ABI or the Library schema, and the patch version otherwise.
Each milestone in [Next](#next) ends with a release.

Every change adds its entry to the Unreleased section of `CHANGELOG.md` in
the same commit: features, fixes, refactors, removals and breaking changes
alike.

To release:

1. Rename the Unreleased section of `CHANGELOG.md` to the version and date,
   and state the Library schema version it ships.
2. Set `.version` in `build.zig.zon`.
3. Commit, and tag the commit `vX.Y.Z`.
4. Update Orca's application entry on the AcoustID website to the new
   version. Every lookup and submission sends the version as
   `clientversion`, and the registered details should match what the
   service receives.

## Known issues

Small defects that are not yet scheduled:

- `playerSignalPath` pauses the engine for a few milliseconds, so hosts read
  it on change, never on a tick.
- `orca-cli play-tracks` prints a bit depth for lossy sources ("MP3 32-bit"),
  and `orca-cli --help` omits `--volume` and `--set-volume`.
- `orca-cli` runs every command on an arena, so a cold scan holds about
  23 KB per file until it exits.
- `write-tags` rewrites a file whose permissions make it read-only.
- The scanner skips symbolic links to files without counting them.
- On a volume with no filesystem UUID, such as NFS, SMB or tmpfs, adding a
  root writes `.orca-volume-id` at the mount point.
- Removing a root leaves its recordings, and their love and hate, in the
  Library.
- `orca-gtk` ignores a Library that fails to open, including one with a newer
  schema, and shows the welcome page.
- A file whose fingerprint fails, and a Track without a title or artist that
  MusicBrainz cannot search, are examined again by every matching run. A
  failed fingerprint is decoded again.
- Undecodable files are examined again by every analysis run: a library of
  WavPack or APE files pays two 64 KiB reads per file per run.
- Matching has no offline setting, and `orca-gtk` has none for scrobbling.
  Without a network, matching uses cached answers and stops at the first
  Track it has none for.
- Listens carry `submission_client` but not `media_player`.
- MusicBrainz finds nothing for a Track whose artist tag joins several
  artists with commas, such as "Pa Salieu, Black Sherif"; AcoustID can still
  match it by fingerprint.
- An AcoustID candidate without a title is scored on length and fingerprint
  alone, so for a tagged Track it can rank level with a candidate whose title
  and artist match. Several recording IDs sharing one AcoustID fingerprint
  rank by how closely their artist credit matches the Track's.

## Deferred formats

The formats above cover nearly every library. These wait until after 1.0, and
are sniffed or not recognized until then:

- WavPack, Monkey's Audio (APE), TTA and Musepack.
- DSD (DSF and DFF), which also needs DSD-to-PCM conversion or native DSD
  output.
- WMA.
- FLAC in Ogg, Matroska and WebM audio, and FLAC or Opus inside MP4.
- Fixtures for HE-AAC and for the `iTunSMPB` gapless fallback, which are
  implemented but cannot be produced with FFmpeg; they wait for real files.

## Later

- macOS: a CoreAudio output behind the same backend contract, and a SwiftUI
  client rebuilt against the current C ABI. The aarch64 fix in [Next](#next)
  lets `liborca` compile for macOS; without this output it cannot play there.
- A terminal client built on the Zig API.
- Conversion and encoding.
- Synchronized multi-zone playback with drift correction.
- Secure, verified CD ripping.
- Windows, then iOS and Android.
- Streaming sources and cross-device sync.

## Not planned

- A DAW, plugin host, or arbitrary DSP graph.
- A required FFmpeg dependency.
- A custom database engine, TLS stack or cryptography.
