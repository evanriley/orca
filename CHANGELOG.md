# Changelog

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
