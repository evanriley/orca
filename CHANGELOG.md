# Changelog

## Unreleased - 0.1.0-alpha

**Version reset.** The project was previously tagged `0.10.0`. That number, and
the release notes below it, describe subsystems that exist as tested components
but are **not reachable through the authoritative runtime or ABI path**. The
version has been reset to `0.1.0-alpha` to stop the changelog from overstating
what works.

### Added since the reset

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

## 0.10.0 - 2026-08-21

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

## 0.9.0 - 2026-08-21

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

## 0.8.0 - 2026-08-21

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

## 0.7.0 - 2026-08-21

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

## 0.2.0 - 2026-08-21

Incremental local-library acquisition milestone.

- Path-independent local readable sources and byte-based format sniffing.
- Cancellable, restart-resumable recursive scans with bounded commits and
  unchanged-file identity checks.
- Persisted observed-file state and ID3v1 metadata kept separate from preferred
  Orca metadata.
- Shared per-Library write serialization and schema migrations through v3.
- Bounded/coalesced watcher hints plus a tested Linux inotify adapter.
- Headless durable scanning through `orca-cli scan`.

## 0.1.0 - 2026-08-21

First verified liborca foundation milestone.

- Reproducible Zig build, test, benchmark, CLI, and platform boundaries.
- Typed generational runtime handles and ordered, allocation-free shutdown.
- Bounded asynchronous commands, completion backpressure, coalesced telemetry,
  and common Job state/snapshots.
- Runtime-owned, independently openable SQLite libraries with transactional
  migrations, FTS5 search, typed batched repositories, WAL readers, and
  serialized writes.
- Repeatable 500,000-track persistence benchmark and concurrency coverage.
