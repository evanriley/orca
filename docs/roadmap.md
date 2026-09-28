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

- Decoding: WAV, FLAC (libFLAC), MP3 (vendored minimp3 with Xing/LAME gapless
  trimming), Ogg Opus (libopusfile), Ogg Vorbis (libvorbisfile), QOA.
- Tags: ID3v1, ID3v2.3/2.4, Vorbis comments in FLAC and Ogg, embedded pictures
  in FLAC and MP3.

### Playback

- A runtime-owned Player and Zone object graph with PipeWire output.
- A gapless queue with repeat, shuffle, next, previous, seek, pause and
  volume. A format change between entries reopens the output at the new
  format.
- Per-entry ReplayGain from analysis results.
- Output device selection.

### Analysis

- Loudness and ReplayGain, peaks, silence, waveform and a temporal
  fingerprint, cached by algorithm version and parameters.
- Library-wide analysis and indexed duplicate detection as cancellable jobs.
- Library health issues.

### Clients

- `orca-cli`: scan, browse, search, analysis, duplicates, artwork and queue
  playback.
- `orca-gtk`: library browsing and search, queue, transport, device picker,
  scan progress, MPRIS with cover art.
- C ABI (`liborca/orca.h`), exercised end to end by `tests/c_abi_smoke.c`.

## Built but not reachable

These exist with tests, but no client can use them yet. Each needs a runtime
entry point and a client before it counts as working.

- Tag writing and file moves through the journaled `MutationPlan` executor.
- Providers: MusicBrainz, AcoustID, ListenBrainz and Last.fm adapters, match
  proposals and the scrobble queue. Before connecting them: HTTP requests need
  deadlines and cancellation, proposal acceptance must re-read the stored
  payload inside its transaction, and scrobble delivery must lease queue rows.
- The ordered DSP graph, the resampler and the signal-path inspector.
- The Linux filesystem watcher.

## Next

In priority order.

1. **Formats: MP4 (ALAC and AAC).** Sourcing order: a correct Zig package,
   then the reference C library behind a narrow shim, then an Orca
   implementation only when neither exists; no Zig package exists for any of
   these. MP4 needs a demuxer and an iTunes-atom tag reader as well as the
   decoders. Apple's ALAC reference is Apache-licensed. AAC needs a licensing
   decision: libfdk-aac carries its own FDK licence and libfaad2 is GPL, and
   the repository has no licence of its own yet to weigh them against.
   Ogg artwork (`METADATA_BLOCK_PICTURE`) is also still unread.
2. **macOS playback.** `liborca` has no CoreAudio backend, so it cannot play
   on macOS, and the SwiftUI client has not been built since the C ABI changed.
   A CoreAudio output behind the same backend contract, plus a SwiftUI client
   that plays a track, proves the C ABI with a real host.
3. **A deliberate public Zig API.** `liborca/root.zig` re-exports every
   subsystem. Embedders need a documented, stable subset: the runtime, handles,
   snapshots and queries.
4. **Tag editing.** Expose `MutationPlan` preview, approval, execution and
   undo through the runtime and C ABI, then in `orca-cli` and `orca-gtk`.
5. **Playlists, ratings and play history.** `tracks.rating` exists; playlists
   and history have no schema yet.
6. **Live DSP.** Put the prepared DSP chain and resampler in the Zone render
   path and report the signal path from the negotiated output.
7. **Providers and scrobbling**, after the fixes listed above.
8. **Filesystem watching** as a scan accelerator.

## Later

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
