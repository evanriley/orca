# Roadmap

What Orca does today, what comes next, and what is deferred. "Works" means
reachable from `orca-cli` or `orca-gtk` through the public runtime path, per
the rule in [architecture.md](architecture.md).

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
  format.
- Per-entry ReplayGain from analysis results.
- A ten-band equalizer with presets, stereo crossfeed, and a signal-path
  report of the source, each processing stage, the output stream and whether
  the path could be bit-perfect (`orca-cli play-tracks --eq --crossfeed`).
- Output device selection.

### Analysis

- Loudness and ReplayGain, peaks, silence, waveform and a temporal
  fingerprint, cached by algorithm version and parameters.
- Library-wide analysis and indexed duplicate detection as cancellable jobs.
- Library health issues.

### Clients

- `orca-cli`: scan, browse, search, library edits, tag write-back and undo,
  analysis, duplicates, artwork and queue playback.
- `orca-gtk`: a libadwaita window with an album grid and album pages, artist
  pages, track browsing and search, Now Playing, an editable queue, context
  menus, tag editing with write-back and undo, Preferences, a Health page, a
  player bar with cover art and an output menu, job progress, a welcome page,
  toasts, a shortcuts dialog and MPRIS.
- C ABI (`liborca/orca.h`), exercised end to end by `tests/c_abi_smoke.c`.

## Built but not reachable

These exist with tests, but no client can use them yet. Each needs a runtime
entry point and a client before it counts as working.

- File moves through the journaled `MutationPlan` executor. Tag writes are
  reachable; moves are not.
- Providers: MusicBrainz, AcoustID, ListenBrainz and Last.fm adapters, match
  proposals and the scrobble queue. Before connecting them: HTTP requests need
  deadlines and cancellation, proposal acceptance must re-read the stored
  payload inside its transaction, and scrobble delivery must lease queue rows.
- The ordered DSP graph (`Chain`, `PublishedChain`) and the resampler. The
  Player's equalizer, crossfeed and volume run through `PlayerDsp` instead, and
  the signal-path inspector is reachable through `playerSignalPath`, but
  neither uses the graph, and nothing resamples.
- The Linux filesystem watcher.

## Next

In priority order. Each step leaves `orca-gtk` usable every day.

1. **Play at the source's sample rate.** The PipeWire stream asks for no
   device rate (`node.rate`), so the graph stays at its default and PipeWire
   resamples: a 44.1 kHz FLAC plays through a sink running at 48 kHz. Request
   the source rate, read back the rate the device actually runs at, and report
   resampling in the signal path when the request is not honoured.
2. **Track details.** A `libraryTrackDetails` query (codec, sample rate, bit
   depth, channels, bitrate, duration, size, path, loudness, tags), an
   `orca-cli track` command, and an optional details panel in `orca-gtk`
   beside the track list and on album pages, with the live signal path for
   the playing track.
3. **A fixed output rate with a band-limited resampler** (libsamplerate or
   speexdsp behind a shim), for gapless playback across sample rates.
4. **MusicBrainz, AcoustID and ListenBrainz**, after the fixes listed above.
   Last.fm follows.
5. **Filesystem watching** as a scan accelerator.
6. **Forgetting a removed folder.** `libraryRemoveRoot` stops scanning a
   folder, but its files and tracks stay in the library, listed.
7. **Tag writers for the remaining formats, and the C ABI's catch-up.** FLAC,
   MP3 and ADTS are written; M4A, Ogg, WAV and AIFF are reported as not
   writable. The C ABI has neither tag writes nor queue editing.
8. **Playlists, ratings and play history.** `tracks.rating` exists; playlists
   and history have no schema yet.
9. **Undecodable files are re-examined on every analysis run.** They are
   declined cheaply, but a library of WavPack or APE files still pays two
   64 KiB reads per file per run until declines are remembered.

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
