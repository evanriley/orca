# Changelog

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
