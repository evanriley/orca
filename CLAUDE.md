# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Orca is a local-files-first music player and library-maintenance application,
written in Zig. `liborca/` is a reusable headless engine; `apps/` holds thin
native frontends that are *clients* of it.

`Orca_Full_Implementation_Plan_v1.0.md` is the authoritative product and
architecture specification. `docs/` holds per-subsystem contracts and is the
fastest way to load a subsystem's invariants before editing it.

## Toolchain

Zig `0.17.0-dev.1770+5d7cf3f34` or a newer compatible snapshot (pinned in
`build.zig.zon`). This is a **post-Writergate `std.Io` Zig**: `std.Io.File`,
`std.Io.Dir`, `std.Io.Reader`/`Writer`, and an explicit `io: std.Io` parameter
threaded through I/O call sites (`std.testing.io` in tests). Do not write code
against the older `std.fs` / `std.io` APIs.

Linux builds additionally need PipeWire, GTK4, and SQLite development
libraries. `sqlite3` is linked via pkg-config; PipeWire deliberately is not
(its emitted flags break Zig's current pkg-config parser — see the comment in
`build.zig`).

### Snapshot facts that cost time to rediscover

These are properties of this specific Zig snapshot, not of the project. Each one
was found the expensive way.

- **`std.Thread.Mutex`, `std.Thread.Condition` and `std.Thread.ResetEvent` do not
  exist.** Use atomics plus `std.Thread.join`. `std.Io.Mutex` and
  `std.Io.Condition` do exist, but need an `io` in scope.
- **`@cImport` does not exist.** `b.addTranslateC` is the replacement, and it
  fails outright on GTK4's headers.
- **`std.Io.Dir` cannot fsync a directory.** Its `handle` is not an fsync-able fd
  (`EBADF` under `std.Io.Threaded`); open the directory *path as a file* instead.
  Durable renames depend on this.
- **`{d:0>2}` on a signed integer emits a sign**, so a duration of six seconds
  formats as `0:+6`. Convert to unsigned before formatting.
- `std.crypto.hash.Blake3` is available.

### Verifying a build

Never write `zig build 2>&1 | tail -3 && echo OK`. In a pipeline `$?` is the
status of `tail`, not of the compiler, so a failed build reports success and the
"verification" that follows runs a stale binary. This masked a real compile
failure for two rounds. Check `${PIPESTATUS[0]}`, or run `zig build` unpiped.

## Commands

```sh
zig build                     # static + shared liborca, orca-cli, headers; orca-gtk on Linux
zig build test                # unit + integration + C ABI smoke (+ PipeWire link smoke on Linux)
zig build run -- --version    # orca-cli
zig build bench               # 500k-track persistence benchmark
zig build -Doptimize=ReleaseFast dsp-bench   # scalar vs SIMD DSP kernels
```

`orca-cli` surface:

```sh
zig build run -- demo
zig build run -- devices

# library
zig build run -- scan DATABASE ROOT
zig build run -- project DATABASE
zig build run -- backfill DATABASE [--force] [--cancel-after=MS]
zig build run -- health DATABASE [OFFSET]
zig build run -- analyze DATABASE AUDIO

# browse
zig build run -- artists DATABASE [--limit N] [--offset N]
zig build run -- releases DATABASE [--artist ID] [--limit N] [--offset N]
zig build run -- tracks DATABASE [--artist ID] [--release ID] [--sort KEY] [--desc] [--limit N] [--offset N]

# playback -- pass a device from scripts/silent-sink.sh, never the default
zig build run -- play AUDIO [DEVICE_ID]
zig build run -- play-tracks DATABASE IDS --device=ID [--start N] [--repeat MODE] [--shuffle]
```

Frontends:

```sh
ORCA_LIBRARY=/path/to/library.db zig build run-linux   # GTK4 frontend
```

macOS: `zig build` first, then build `apps/macos` with SwiftPM — it links
`zig-out/lib/liborca` through a systemLibrary modulemap.

Live/host-dependent checks, excluded from the normal test run:

```sh
zig build dependency-smoke      # Linux foreign-library linking pattern
zig build pipewire-live-smoke   # opens a short silent stream on the user's PipeWire server
```

Ordinary tests require no audio server.

### Testing playback without making noise

This project is developed on somebody's desk, and playback verification used to
mean audible test tones firing while they worked. Do not play test audio to real
hardware.

```sh
device=$(scripts/silent-sink.sh)
zig build run -- play fixtures/audio/tagged-reference.flac "$device"
```

`scripts/silent-sink.sh` creates (idempotently) a `support.null-audio-sink`
PipeWire node and prints its orca device id. It is a *real* sink: it consumes
audio in real time and discards it, so quantum negotiation, render callbacks,
epoch handling, position anchoring, underrun accounting and drain all behave
exactly as on hardware. Verified against `ffprobe` — frame counts match the
source exactly and the negotiated quantum tracks the sample rate (256 at 48 kHz,
235 at 44.1 kHz), so timing-sensitive measurement on it is trustworthy.

The id it prints is **orca's** device id, which is not the PipeWire node id —
liborca's enumeration numbers devices itself. Resolve it through the script or
`orca-cli devices`, never through `pw-dump`.

Pass an index for a second, distinct silent sink. Multi-zone and device-attach
tests need two different outputs, and reaching for real hardware to get the
second one defeats the purpose:

```sh
zone_a=$(scripts/silent-sink.sh 1)
zone_b=$(scripts/silent-sink.sh 2)
```

Note that **omitting the device argument is not silent**: device id 0 means the
system default sink, which is real hardware. Pass an explicit device on every
invocation, including throwaway checks.

### Running a single test

There is no test filter wired into `build.zig` — `zig build test` runs all ~109
tests (it is fast and heavily cached, so this is usually fine). If you need
filtering, add `.filters` to the relevant `b.addTest` call rather than trying
to invoke the test binary by hand; the `liborca` module needs translate-C
SQLite, the `flac`/`qoa` dependencies, libc, and the PipeWire shim, which is
impractical to reconstruct on a bare `zig test` command line.

Tests are run from the repository root and load fixtures by relative path
(`fixtures/audio/...`). Do not make test working-directory assumptions.

## Architecture

### The non-negotiable boundary

`liborca` owns *all* music, library, audio, metadata, mutation, and job
behavior. Frontends own windows, widgets, accessibility, and event loops —
nothing else. When adding a feature, the semantics belong in `liborca` and only
the presentation belongs in `apps/`. A frontend must never grow its own notion
of transport state, library paging, or metadata resolution.

**Frontend language is Zig wherever the platform permits it.** The project is
Zig-first, and that applies to `apps/`, not only to `liborca`. `orca-cli` and
`orca-gtk` are Zig and consume liborca's **Zig-facing API** directly, per
section 17.1 of the implementation plan. C appears in a frontend only where a
platform genuinely forces it.

Non-Zig frontends reach the engine through `liborca/orca.h` (a C ABI of opaque
runtime ownership, generational handles, POD snapshots, and **callback-scoped**
query views). String views are valid only for the duration of their callback; no
SQLite row, Zig container, or internal layout crosses the ABI. The SwiftUI
client uses that ABI because AppKit requires Swift; `tests/c_abi_smoke.c`
exercises it end to end so it cannot rot while macOS is uncompiled.

GTK4 is bound with hand-written `extern fn` declarations rather than generated
bindings. `@cImport` no longer exists in this Zig, `translate-C` fails on GTK4's
headers (glib's `_Pragma` macros produce thousands of errors), and
`zig-gobject` does not build on this snapshot. Declare only the symbols the app
actually uses.

### Runtime ownership

`core.OrcaRuntime` is the process-level root. Every runtime-visible object is a
typed generational handle (`handle.Pool`), so destroying an object bumps its
slot generation and a stale handle can never resolve to a later occupant of the
same slot. Shutdown is strictly dependency-ordered — work → Zones → Players →
Libraries — and `deinit` always performs shutdown, idempotently. See
`docs/ownership.md`.

Hosts drive a single logical control lane via a fixed-capacity command queue
with request-ID-correlated completions. Completion events are lossless and
apply backpressure when full; high-frequency telemetry uses a *separate*
channel that coalesces unread Player-position and Job-progress hints by handle.
Authoritative consumers query snapshots — never reconstruct state from events.
Jobs share one state/progress/cancellation representation across all worker
kinds. See `docs/control-plane.md`.

### Real-time audio boundary

This is the sharpest constraint in the codebase. The render callback must never
allocate, free, lock, wait, perform I/O, or touch SQLite. Decoded PCM lives in
a preallocated `BlockPool`; one producer hands block indices to the callback
over a wait-free SPSC queue, and the callback returns consumed indices over a
second SPSC queue for producer-side reclamation. Missing audio is zero-filled
and counted as an underrun.

Related invariants: transport state is independent of physical output (seeks
publish a new **epoch**, and stale-epoch blocks are discarded rather than
surgically removed from the queue). Track identity travels separately, as
`entry_serial`, because the two questions are incompatible: "is this audio
stale after a seek" must be compared, while "which track is this" must not be,
or gapless breaks. What is *audible* is resolved from the entry serial the
render callback publishes, never from the decode cursor, which runs a whole
entry ahead of the audio; Players decode canonical PCM once and
fanout copies it into independently owned Zone pools so one Zone's failure
cannot starve another; processing chains are fixed-capacity and triple-buffered
so the control lane publishes a prepared chain that the render lane adopts only
at a block boundary. On Linux, PipeWire headers and native object lifetime stay
inside a narrow C shim (`liborca/audio/backends/pipewire_shim.c`); stream
creation/destruction stays on the control side. Read `docs/audio-engine.md`
before touching anything under `liborca/audio/`.

### Persistence

Each `LibraryDatabase` owns one SQLite database and one serialized logical
write lane. Schema is selected by `PRAGMA user_version` with transactional
migrations; unknown newer versions are rejected rather than opened. Artist /
Release / Recording / Track / File / Location are separate tables so
**filesystem paths never become musical identity**. Track FTS uses an
external-content FTS5 table maintained by triggers. Repositories return
bounded, caller-owned pages — never SQLite rows or statements. WAL +
`synchronous=NORMAL`, full-mutex connections, five-second busy timeout, reads
on independent read-only connections. See `docs/database.md`.

### Storage, codecs, scanning

Decoders and analyzers consume `ReadableSource` — positional reads, size, and
stable observed identity, with **no path strings or filesystem handles
exposed**, so provider/mobile/permission-sensitive sources can implement it
honestly. Container detection sniffs bytes, never filename extensions.

Codec-specific state never escapes `liborca/codec/`; playback sees only the
Orca `Decoder` interface, and `SourceSession` owns the registered decoder.
Prefer pure-Zig adapters (the pinned `audiophile/flac` and `audiophile/qoa`
dependencies) over C libraries.

Scanning is incremental and restart-resumable: unchanged path + storage
identity skips all format/metadata work, commits are bounded, and cancellation
is checked before filesystem work and between entries. Because only changed
bytes are probed, a library scanned before probing existed keeps null
properties for ever; `library/property_backfill.zig` repairs those rows by
`files.id` with no walk, selected through a partial index over exactly the rows
that are incomplete, and reprojects each batch it repairs. Filesystem watchers are
an *acceleration only* — they emit bounded, coalescing, root-scoped hints and
never directly insert, remove, or mutate observed state. See `docs/storage.md`.

### Metadata and file mutation

Three concepts stay strictly separate, and conflating them is the most likely
way to break this subsystem:

- `ObservedFileMetadata` — what the file currently says.
- `OrcaMetadata` — preferred values, user edits, locks, provider proposals.
- `EffectiveMetadata` — a resolved view under an explicit preference policy.

Every value carries provenance, and a user lock outranks automatic resolution.
Scanner observations never update Track metadata and never write a file.
Format-specific concerns (ID3v1 genre numbers, fixed-width fields, Vorbis
comment keys) terminate at the reader/writer and must not leak into the
canonical model.

File writes and moves execute **only** from an explicitly approved immutable
`MutationPlan`. Source identity and intended after-identity are journaled to
SQLite before the filesystem changes; tag writes stage-and-fsync a complete
same-filesystem copy and retain the exact original as a journaled backup.
Groups undo in reverse action order, startup recovery converges toward the
original state, and if a target changed externally Orca keeps every file,
records `needs_reconciliation`, and refuses to claim rollback succeeded. See
`docs/metadata.md`.

### Network and providers

All provider traffic passes through **one** rate-limited, retrying HTTP
boundary (`network.Gateway`) with bounded responses, service identification,
and an explicit offline mode. Do not add a second HTTP path. Credentials come
from platform secure-storage adapters, are never stored in an Orca library, and
must never enter durable cache keys. Provider matches remain reviewable
proposals with explicit confidence until accepted; acceptance is a transaction
into Orca metadata that preserves user locks and does **not** write media files.

## Conventions

- **Subsystem roots.** Each `liborca/<subsystem>/root.zig` re-exports every file
  as a `pub const` and mirrors that list in a `test { _ = @import(...); }`
  block. Add new files to both.
- **Interfaces are context+vtable structs** (`ReadableSource`, `Transport`,
  `Clock`, `Decoder`) rather than generics, which keeps the C ABI and platform
  adapters possible.
- **Inject time and I/O for determinism.** Provider and network tests supply a
  `Mock` transport and `FakeClock` through those vtables — no live network, no
  wall-clock sleeps. Follow that pattern for anything with retry or rate-limit
  behavior.
- **Platform code is contained.** `liborca/platform.zig` switches on
  `builtin.os.tag`; foreign headers and native object lifetimes live in the
  adapter (or C shim) for that platform and nowhere else.
- **Test names are behavioral sentences** describing the invariant being
  protected, e.g. `test "removed handles stay stale when their slot is reused"`.
- Bounded everything: fixed-capacity queues, 256-row query pages, bounded
  commits, bounded retries. Prefer rejecting or applying backpressure over
  unbounded growth.
- Update `CHANGELOG.md` and the `version` in both `build.zig.zon` and
  `liborca/root.zig` together when releasing.
