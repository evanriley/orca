# Roadmap

Orca is 0.x: each release may still break the Zig API, the C ABI or the
Library schema. This page holds Orca's feature status.

- [Releases](#releases): what has shipped.
- [What works](#what-works): what `main` does.
- [Known issues](#known-issues): open defects.
- [Next](#next): queued fixes, test gaps and the 1.0 gates.
- [Planned](#planned): features with a decided scope.
- [Ideas](#ideas): noted, not scoped or scheduled.
- [Not planned](#not-planned): out of scope.

"Works" means reachable from `orca-cli` or `orca-gtk` through the public
runtime path, per the rule in [architecture.md](architecture.md).
[CHANGELOG.md](../CHANGELOG.md) has each release's details.

## Releases

| Version | Date | Highlights |
| --- | --- | --- |
| Unreleased | on main | Theme mixes, unplayed albums, rate released on pause |
| 0.3.0 | 2026-10-08 | Home, Daily Mixes, Library Radio, audio features |
| 0.2.0 | 2026-10-06 | Binary cache, AcoustID submitted count, fixes |
| 0.1.0 | 2026-10-06 | First public release |

[releasing.md](releasing.md) has the versioning rule and release procedure.

## What works

### Library

[storage.md](storage.md), [database.md](database.md) and [cli.md](cli.md)

- Incremental scanning that skips unchanged files and resumes after
  cancellation, with bounded, cancellable commits.
- File identity bound to the volume, so an unmounted drive's files are never
  marked missing, and byte-identical copies share one File until one changes.
- Watching the music folders on Linux, so changes show up without a rescan.
- Browsing by artist, album, track, genre and folder, and one search over
  all of them and playlists.
- Library edits, and tag write-back for FLAC, MP3 and ADTS from an approved
  plan with undo ([metadata.md](metadata.md#file-mutation)).
- Library stats, cover art, and artist and album info from online sources.

### Formats

[architecture.md](architecture.md#formats-and-codecs)

- Decoding of FLAC, MP3, AAC and ALAC in MP4, AAC in ADTS, Ogg Opus, Ogg
  Vorbis, WAV, AIFF and uncompressed AIFC, and QOA, with gapless trimming.
- Tags and cover art from ID3v1 and ID3v2, WAV `LIST`/`INFO`, Vorbis comments
  and FLAC pictures, and MP4 atoms.

### Playback

[audio-engine.md](audio-engine.md)

- Gapless playback through PipeWire, each source at its own sample rate, with
  queue history, and the queue resumed at launch.
- A paused or stopped Player releases the output's rate to other streams.
- ReplayGain by track or album from Orca's own analysis.
- A ten-band and a parametric equalizer, stereo crossfeed, output device
  selection, and a signal path that says whether playback can be bit-perfect.

### Listening

[providers.md](providers.md) and [cli.md](cli.md#playlists-and-ratings)

- A local play history kept forever, with play counts and last play.
- ListenBrainz scrobbling and Now Playing, off until enabled, with the token
  in the Secret Service.
- Love and hate for songs, sent to ListenBrainz; love for albums and artists.
- Star ratings, playlists with M3U import and export, and smart playlists.
- Lyrics, plain and synced, from tags, a sidecar `.lrc` or, opt-in, LRCLIB,
  following playback in `orca-gtk`.
- Provider rate limits and back-off kept in the Library, binding every process.

### Discovery

[discovery.md](discovery.md)

- Home: Daily Mixes, Start Radio, this week's listening, albums to jump back
  into or rediscover, unplayed albums, deep cuts and release anniversaries.
- Daily Mixes, regenerated each day from listening history, with genre mixes
  and theme mixes (decade, New to you, Deep cuts, Upbeat, Wind down).
- Library Radio: a queue that keeps extending from a Track, album, Artist,
  genre, decade or loved tracks, scored from local data only, with a reason for
  each pick and feedback.
- Tempo, key and energy measured from the audio
  ([analysis.md](analysis.md#audio-features)).

### Identification

[providers.md](providers.md#matching) and [metadata.md](metadata.md)

- MusicBrainz and AcoustID matching that stores reviewable proposals; nothing
  changes until one is accepted.
- Match Album, Match Review and release application, which fill album, date,
  disc and track numbers and MusicBrainz IDs as provider values.
- Front covers from the Cover Art Archive, and a list of credited sources.
- Verification of recording IDs against AcoustID fingerprints, with album
  corrections, and re-identification of one Track or album.
- AcoustID submission, off until enabled, with the user's key.
- Idle maintenance that verifies albums while nothing plays, off until
  enabled ([control-plane.md](control-plane.md#idle-maintenance)).

### Analysis

[analysis.md](analysis.md)

- Loudness, ReplayGain, peaks, clipping, silence, waveform and fingerprints,
  cached by algorithm version and analysed on a pool of threads.
- Duplicate detection: same bytes, same lossless audio or same fingerprint.
- Analysis coverage, and Health issues that each name the action resolving it.

### Clients

[cli.md](cli.md), [frontends.md](frontends.md) and [api.md](api.md)

- `orca-gtk`: a dark libadwaita player for Linux that opens on Home and can
  open more than one library.
- `orca-cli`: the library, playback, identification and analysis as commands.
- `liborca` as a library: a Zig API and a C ABI (`liborca.so.0`, `orca.pc`),
  checked against the 0.1.0 header, with a stability statement and a wake
  callback for event loops.

### Platforms and CI

[CONTRIBUTING.md](../CONTRIBUTING.md#continuous-integration)

- x86_64 Linux with PipeWire; `-Dgtk=false` builds without `orca-gtk`.
- A static `liborca` for aarch64 macOS, which has no audio output or watcher.
- CI runs the test suite against a private PipeWire on every change, and
  builds on Debian 13 and Fedora 43 and through Nix on every push to `main`
  (and pull requests whose packaging inputs change).

## Known issues

Each fix adds a test that fails without it, or a headless screenshot for a
display-only defect, and removes its entry.

- On macOS, which has no OFD locks, opening and closing a Library's
  database, `-wal` or `-shm` file from another part of the same process
  drops SQLite's POSIX locks on it. A second Orca process can then
  check-point and delete the WAL under the first, and the first process's
  later writes are lost. Linux uses OFD locks; see
  [database.md](database.md#concurrency).
- Match Review in `orca-gtk` ticks the Release ID row as differing while both
  columns show the same MusicBrainz release ID, when only the release-group,
  album-artist, release-track or recording IDs or the disc or track numbers
  differ.
- A saved queue entry has no foreign key, and SQLite reuses the highest
  deleted id, so after a root is removed and another scanned, a restored entry
  can play a different song that took the removed Track's or Recording's id.

## Next

### Tests and CI

- CI runs Debug builds only: no test run in ReleaseSafe, and fuzzing only in
  short `zig build fuzz` runs, with no scheduled long run that keeps failing
  inputs as regression cases.
- MP1 and MP2 decoding (`liborca/codec/mp3.zig`) has no fixture or test.
- NaN and Inf samples in float WAV and AIFF are untested through decoding,
  analysis and DSP.

### Before 1.0

Each gate closes when its check passes and its entry is removed. The 1.0
release itself is the maintainer's call.

- Compatibility promises for 1.0, written separately for the Zig API, the
  C ABI and the Library schema.
- A GTK launch, open, play and close smoke test on a private display in CI.
- A release candidate passes an acceptance period with no open data-loss,
  memory-corruption, wrong-song or unintended-output defect.
- A manual accessibility pass of `orca-gtk`: keyboard-only use, visible focus,
  accessible labels on icon-only buttons and text scaling.
- Written performance budgets for startup, the first scan and a rescan of a
  large library, browse latency, memory and no underruns during a scan, with
  a benchmark that checks them.

## Planned

- Tag writers for M4A, Ogg, WAV, AIFF and FLAC with a leading ID3 tag, which
  are reported as not writable today.
- File moves. The journaled `MutationPlan` executor performs them, with
  tests, but no runtime entry point or client reaches them.
- Full multichannel. Canonical PCM carries a channel count but no layout, so
  decoding, loudness analysis (BS.1770 channel weights, LFE excluded), DSP and
  PipeWire channel positions need one. Until then playback, loudness analysis
  and AcoustID fingerprinting refuse a file with more than two channels
  (`UnsupportedChannelCount`).
- An optional fixed output rate with a band-limited resampler, for devices
  held at another rate and for gapless playback across sample-rate changes,
  with a resampler quality setting. Output at the source rate stays the
  default, since only that path can be bit-perfect.
- Crossfade, never applied between gapless album tracks, and convolution DSP
  for room correction and headphone targets from impulse responses.
- Synchronized multi-zone playback with drift correction.
- Conversion and encoding.
- Secure, verified CD ripping.
- A terminal client built on the Zig API.
- A macOS app: a CoreAudio output behind the backend contract and an FSEvents
  watcher behind `library/watch.zig`. `liborca` compiles for macOS but cannot
  play there, and `libraryWatch` returns `error.WatchingUnsupported`. The
  macOS POSIX-lock known issue is fixed first.
- Windows.
- More formats, sniffed or not recognized until they are supported:
  - WavPack, Monkey's Audio (APE), TTA and Musepack.
  - DSD (DSF and DFF), which also needs DSD-to-PCM conversion or native DSD
    output.
  - WMA.
  - FLAC in Ogg, Matroska and WebM audio, and FLAC or Opus inside MP4.
  - Fixtures for HE-AAC and for the `iTunSMPB` gapless fallback, which are
    implemented but cannot be produced with FFmpeg; they wait for real files.
- C ABI functions for what only the Zig API offers. Each is named with its
  reason in `scripts/check-abi-coverage.sh`; the command lane (`submit`,
  `processNextCommand`) stays behind `orca_runtime_pump`.

## Ideas

### Library and metadata

- Ratings read from and written to tags (POPM, FMPS_RATING).
- `REPLAYGAIN_TRACK_*` and `REPLAYGAIN_ALBUM_*` tags read from files.
- Batched Track inserts for the first scan.
- Search tiers ranked by relevance, and bm25 ranking only for the page shown.
- Folders that hold only images in the folder views.
- Opt-in embedding of a fetched cover, only in files with no embedded picture,
  stored once per plan and referenced by digest from each action.
- Opt-in writing of the AcoustID track ID, never the fingerprint.
- Moving a duplicate copy to the system trash as a journaled action, and
  writing the chosen cover into the album folder as `cover.jpg`.
- A database change log, so Change History can undo Orca-only edits.
- Lyrics from a WAV or AIFF `id3 ` chunk and from a sidecar `.txt`.
- Listening history retention; Keep history for is fixed at Forever.
- Classical music by composition: works, composers and performers.
- Packed genre tags parsed: an ID3 `TCON` such as
  `#COO:US##G:soul##G:rnb#` shows today as one genre.

### Identification and providers

- ListenBrainz metadata lookup; it needs the user's token and must share the
  listen worker's gateway.
- Fewer provider requests: cover sizes without a download, combined searches.
- A per-Release MusicBrainz genre override: fetched release-group genres
  become proposed user genres, so a tag write replaces junk file genres.
- Similar artists from ListenBrainz Labs, sending only the seed artist's ID;
  the endpoint is experimental, so a failed lookup hides the list.
- A release calendar of new releases by library artists, fetched at most daily.
- Upcoming concerts, from a provider whose terms allow it.
- Song credits from MusicBrainz recording relationships.
- Last.fm scrobbling beside ListenBrainz.

### Playback and audio

- The output kind for the system default device and for sinks past the 64th.
- Exclusive output and an ALSA direct-hardware backend.
- Device hardware volume, so the signal stays bit-perfect.

### Analysis

- Exact album loudness from block energies instead of a weighted mean.
- True-peak measurement, 4x oversampled, and spectral transcode detection.

### orca-gtk

- Equalizer band captions from `equalizer_band_frequencies_hz`.
- A light theme, a System theme and accent colours.
- A frosted Activity popover.
- Customizable keyboard shortcuts, and localisation.
- Editing lyrics from Now Playing.
- Starting a waiting Job ahead of the running one.

### Platforms

- Automatic update checks and a release channel.
- Streaming sources and cross-device sync.

## Not planned

- Preserving file modification dates on tag writes: it would hide the
  write from the incremental scan.
- A DAW, plugin host, or arbitrary DSP graph.
- A required FFmpeg dependency.
- A custom database engine, TLS stack or cryptography.
- Distribution through app stores. Orca is open-source desktop software, and
  store terms would rule out data sources it uses.
