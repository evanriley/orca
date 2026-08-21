# Changelog

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
