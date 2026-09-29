# Roadmap

What Orca does today, what comes next, and what is deferred. "Works" means
reachable from `orca-cli` or `orca-gtk` through the public runtime path, per
the rule in [architecture.md](architecture.md).

## Status

Unreleased `0.2.0-alpha`. `orca-gtk` is a daily-usable player on Linux: a
designed libadwaita frontend, gapless playback at each source's sample rate,
live equalizer and crossfeed, tag editing with undo, track details, a local
play history, ListenBrainz scrobbling, MusicBrainz and AcoustID matching
with review, and AcoustID submission. Last.fm and filesystem watching are built but not connected; macOS
has no audio output yet.

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
- Track details: format, file, loudness and tags for one Track
  (`orca-cli track`), and a details panel in `orca-gtk`.

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
  ListenBrainz while scrobbling for recordings with a MusicBrainz ID. `orca-gtk`
  has a heart in the player bar, a heart button on every song row and context
  menu entries; `orca-cli feedback` sets it.
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
- Providers: the Last.fm adapter.
- The ordered DSP graph (`Chain`, `PublishedChain`) and the resamplers. The
  Player's equalizer, crossfeed and volume run through `PlayerDsp` instead, and
  the signal-path inspector is reachable through `playerSignalPath`, but
  neither uses the graph, and playback never resamples; libsamplerate
  (`resampler.SampleRate`) resamples only for fingerprints.
- The Linux filesystem watcher.

## Next

In priority order. Each step leaves `orca-gtk` usable every day.

1. **ListenBrainz lookup.** ListenBrainz's `/1/metadata/lookup` would match
   what MusicBrainz and AcoustID miss. Last.fm follows. No tag writer stores
   an accepted recording ID in a file yet.
2. **Filesystem watching** as a scan accelerator, so new files appear without
   a manual rescan.
3. **A fixed output rate with a band-limited resampler** (libsamplerate is
   already behind `resampler.SampleRate`), for gapless playback across sample-rate changes
   and for devices held at another rate. Playback at the source rate already
   covers the common case.
4. **Tag writers for the remaining formats, and the C ABI's catch-up.** FLAC,
   MP3 and ADTS are written; M4A, Ogg, WAV and AIFF are reported as not
   writable. The C ABI lacks tag writes, queue editing, DSP and track
   details.
5. **Playlists and ratings.** `tracks.rating` exists; playlists have no
   schema yet. Play history, love and hate, and Now Playing are done.
6. **Undecodable files are re-examined on every analysis run.** They are
   declined cheaply, but a library of WavPack or APE files still pays two
   64 KiB reads per file per run until declines are remembered.

## Known issues

Small defects that are not yet scheduled:

- A lossy source reports a bit-perfect signal path when no processing
  applies: the decoded output is unchanged, but the source was not lossless.
- `playerSignalPath` pauses the engine for a few milliseconds, so hosts read
  it on change, never on a tick.
- `ZoneRuntime.published_device_delay_frames` is written but never read.
- Two processes matching the same Library at once, such as `orca-gtk` and
  `orca-cli match`, each run their own gateways, so MusicBrainz and AcoustID
  see two requests a second.
- A file whose fingerprint fails, and a Track without a title or artist that
  MusicBrainz cannot search, are examined again by every matching run. No
  request is made, but a failed fingerprint is decoded again.
- An AcoustID candidate without a title is scored on length and fingerprint
  alone, so for a tagged Track it can rank level with a candidate whose title
  and artist match. Several recording IDs sharing one AcoustID fingerprint
  rank by how closely their artist credit matches the Track's.
- Two tests fail intermittently, unrelated to listening: "a Player's signal
  path reports sample processing only while DSP or volume is in effect" (the
  output never opens, `OutputNeverOpened`) and "an unanalyzed entry reached by
  a gapless advance plays at unity" (`tests/root.zig:779`, gain 0.358 instead
  of 1).

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
  client rebuilt against the current C ABI. `liborca` cannot play on macOS
  until then.
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
