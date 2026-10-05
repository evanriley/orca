# liborca guidance

## Ownership and API

`liborca` owns all library, playback, audio, metadata, mutation, provider, and
job semantics. Expose client behavior through `Runtime` and public types from
`root.zig`; do not move engine policy into a frontend. Runtime-visible objects
use typed generational handles. Preserve dependency-ordered, idempotent
shutdown: work, Zones, Players, then Libraries.

Each subsystem `root.zig` re-exports its files and imports them in its test
block. Add new files to both lists. Interfaces use context-and-vtable structs
where platform or ABI adapters require them.

Read [the API contract](../docs/api.md),
[runtime ownership](../docs/ownership.md), and
[the control-plane contract](../docs/control-plane.md).

## Persistence and mutation safety

Each Library owns one SQLite database and a serialized logical write lane.
Schema changes use transactional `PRAGMA user_version` migrations and reject
unknown newer versions. Paths never define musical identity. Repositories
return bounded caller-owned values, never SQLite rows or statements.

Keep observed file metadata, Orca metadata, and effective metadata separate.
Scanner observations do not mutate Track metadata or source files. User locks
outrank automatic resolution.

File writes and moves require an approved immutable `MutationPlan`. Journal
source and intended identities before filesystem changes. Preserve the
stage-and-fsync, same-filesystem backup, reverse-order undo, and startup
recovery guarantees. Never report successful rollback after an external
change; retain the files and mark reconciliation required.

Read [the database contract](../docs/database.md) and
[metadata and mutation contract](../docs/metadata.md).

## Real-time audio

The render callback never allocates, frees, locks, waits, performs I/O, or
touches SQLite. Keep callback-owned data preallocated and communicate through
the bounded SPSC queues and atomics. Decode and DSP run on the engine thread.
Control changes that require it quiesce the engine.

Epoch determines whether audio is stale; `entry_serial` identifies audible
queue entries. Do not combine them or infer audible state from the decode
cursor. Players decode canonical PCM once, and each Zone owns an independent
pool and output path. PipeWire headers and native lifetimes remain behind the C
shim; stream creation and destruction remain off the callback.

Read [the audio-engine contract](../docs/audio-engine.md) before changing
`audio/`.

## Providers

All traffic uses the single bounded, rate-limited `network.Gateway`. Preserve
offline mode, provider leases, rate limits, durable backoff, service identity,
and response bounds. Credentials come from host secure-storage adapters and
never enter a Library, log, settings file, fixture, or durable cache key.
Matches remain reviewable proposals until accepted; acceptance changes Orca
metadata without writing media files.

Provider and retry tests use `network.testing.ScriptedTransport` and
`TestClock`. Do not contact live services or sleep on wall-clock time. Read
[the provider contract](../docs/providers.md).

## C ABI

The C ABI exposes opaque ownership, generational handles, POD snapshots, and
bounded callback-scoped views. No Zig container, SQLite row, statement, or
internal layout crosses it. Returned strings are valid only during their
callback. All calls for one runtime stay on its creating thread except the
documented wake and credential callbacks. Keep `tests/c_abi_smoke.c` on the
public end-to-end path. Read [the frontend and ABI contract](../docs/frontends.md).
