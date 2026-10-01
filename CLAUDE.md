# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Orca is a local-files-first music player and library-maintenance application,
written in Zig. `liborca/` is a reusable headless engine; `apps/` holds thin
native frontends that are *clients* of it.

`liborca` is the product, in the way libghostty is Ghostty's: GUIs, CLIs and
TUIs are built on it. `docs/architecture.md` is the overview,
`docs/roadmap.md` records what works, what is built but unreachable, and what
comes next, and the other files in `docs/` are per-subsystem contracts: the
fastest way to load a subsystem's invariants before editing it.

## Licence

Orca is MPL-2.0 (`LICENSE`): embedders may keep their own code closed, changes
to Orca's files stay open, and App Store distribution stays possible.
`liborca`'s dependencies, and anything it vendors or links statically, must
be permissive (BSD, MIT, Apache-2.0, zlib, CC0, public domain): a GPL or LGPL
dependency there would bind every embedder and rule out the App Stores. This is
why AAC comes from libxaac (Apache-2.0) rather than libfaad2 (GPL) or libfdk-aac
(FDK licence), and why Chromaprint is built without its bundled LGPL
resampler, with libsamplerate (BSD-2-Clause) resampling instead; a build step
fails if a compiled Chromaprint source carries a GPL or LGPL notice. A frontend dynamically linking its platform's own toolkit or
keyring, as `orca-gtk` does with LGPL GTK4 and libsecret, is outside that rule.

## Toolchain

Zig `0.16.0`, the stable release, provided by the flake's dev shell
(`nix develop`, or direnv via `.envrc`). Development snapshots are not pinned:
ziglang.org deletes old nightly tarballs, which is how the previous pin
(`0.17.0-dev.1770`) became unbuildable. This is a **`std.Io` Zig**:
`std.Io.File`, `std.Io.Dir`, `std.Io.Reader`/`Writer`, and an explicit
`io: std.Io` parameter threaded through I/O call sites (`std.testing.io` in
tests). Do not write code against the older `std.fs` / `std.io` APIs.

The dev shell supplies libFLAC, libopusfile, libvorbis, libsamplerate and
SQLite, plus PipeWire, GTK4 and libsecret on Linux. `sqlite3`, `FLAC`,
`opusfile`, `vorbisfile`, `samplerate`, GTK and libsecret (`orca-gtk` only)
are linked via pkg-config.
PipeWire's include paths come from `pkg-config --cflags-only-I`
(`pkgConfigIncludePaths` in `build.zig`) and its library is linked without
pkg-config, because the rest of its `--cflags` breaks Zig's pkg-config parser.
No path under `/usr` is assumed, so the same build works on NixOS and FHS
distributions. The Zig package dependencies are `alac`, `libxaac` and
`chromaprint` (built by `build/chromaprint.zig`);
`nix build` fetches them through `zig.fetchDeps`. When `build.zig.zon`
dependencies change, set that hash in `nix/package.nix` to `lib.fakeHash` and
rebuild to learn the new one: an unchanged hash makes Nix reuse the old
dependency directory, and the sandboxed build then fails trying to fetch the
new packages.

### Zig facts that cost time to rediscover

Each one was found the expensive way.

- **A by-value struct parameter is a copy.** A pointer to one of its fields
  dangles once the function returns. The old snapshot happened to pass large
  structs by reference, which hid exactly this: an SQLite `SQLITE_STATIC` blob
  bound from `&selector.parameter_hash` in a helper read freed stack memory, and
  the analysis pass re-measured every file. Take `*const T` when a pointer into
  the argument must outlive the call.
- **`std.Thread.Mutex`, `std.Thread.Condition` and `std.Thread.ResetEvent` do not
  exist.** Use atomics plus `std.Thread.join`. `std.Io.Mutex` and
  `std.Io.Condition` do exist, but need an `io` in scope.
- **`translate-C` (`b.addTranslateC` or `@cImport`) fails outright on GTK4's
  headers**, so GTK is bound by hand.
- **`std.Io.Dir` cannot fsync a directory.** Its `handle` is not an fsync-able fd
  (`EBADF` under `std.Io.Threaded`); open the directory *path as a file* instead.
  Durable renames depend on this.
- **`{d:0>2}` on a signed integer emits a sign**, so a duration of six seconds
  formats as `0:+6`. Convert to unsigned before formatting.
- **`@enumFromInt(@intCast(x))` has no result type** for the inner cast. Write
  `@enumFromInt(@as(std.meta.Tag(E), @intCast(x)))`.
- Sentinel formatting is `std.fmt.bufPrintSentinel` / `std.fmt.allocPrintSentinel`.
- `std.crypto.hash.Blake3` is available.

### Verifying a build

Never write `zig build 2>&1 | tail -3 && echo OK`. In a pipeline `$?` is the
status of `tail`, not of the compiler, so a failed build reports success and the
"verification" that follows runs a stale binary. This masked a real compile
failure for two rounds. Check `${PIPESTATUS[0]}`, or run `zig build` unpiped.

`zig build` also **reinstalls the Debug binary over `zig-out/bin/`**. A
ReleaseFast timing taken after any plain `zig build` is therefore silently
measuring Debug — it reported 8.7× slow once and looked plausible. Re-run
`zig build -Doptimize=ReleaseFast` immediately before timing anything, and
treat a suspiciously slow number as a stale binary before believing it.

## Commands

Run these inside the dev shell (`nix develop`, or automatically with direnv).

```sh
nix build                     # package: orca-cli, orca-gtk (Linux), liborca, orca.h
nix flake check
nix fmt                       # formats Nix files
zig fmt --check liborca apps benchmarks tests build.zig

zig build                     # static + shared liborca, orca-cli, headers; orca-gtk on Linux
zig build lib                 # static liborca and orca.h only; CI cross-builds it with -Dtarget=aarch64-macos
zig build test                # unit + integration + C ABI smoke (+ PipeWire link smoke on Linux)
zig build fuzz                # replay the parser fuzz targets' seeds
zig build fuzz --fuzz[=N]     # fuzz them; N iterations per target, unlimited opens the web UI
scripts/headless-audio.sh zig build test   # tests against a private PipeWire and WirePlumber, as CI runs them
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
zig build run -- roots DATABASE
zig build run -- add-root DATABASE ROOT   # binds an existing root to the volume it is on now
zig build run -- remove-root DATABASE ID   # forgets the root's files and tracks; nothing on disk
zig build run -- watch DATABASE [--quiet=MS] [--max-delay=MS] [--once] [--limit=MS]   # Linux; reconciles folders as they change
zig build run -- reconcile DATABASE ROOT_ID [DIR...]   # rescans the root or only DIRs under it; marks missing only under them
zig build run -- project DATABASE
zig build run -- backfill DATABASE [--force] [--cancel-after=MS]
zig build run -- health DATABASE [OFFSET]
zig build run -- analyze DATABASE AUDIO
zig build run -- analyze-library DATABASE [--batch=N] [--threads=N] [--cancel-after=MS]
zig build run -- duplicates DATABASE [--batch=N] [--cancel-after=MS]

# browse
zig build run -- artists DATABASE [--filter TEXT] [--limit N] [--offset N]
zig build run -- releases DATABASE [--artist ID] [--limit N] [--offset N]
zig build run -- tracks DATABASE [--artist ID] [--release ID] [--sort KEY] [--desc] [--limit N] [--offset N]   # KEY includes rating
zig build run -- track DATABASE ID
zig build run -- artwork DATABASE (--track=ID | --release=ID) [--out=PATH]
zig build run -- covers DATABASE [--limit N] [--offset N]   # a page of covers via the artwork loader
zig build run -- edit DATABASE IDS [--title=…] [--artist=…] [--clear=FIELD]…   # library only
zig build run -- write-tags DATABASE IDS [--approve=DIGEST]   # preview, then write FLAC/MP3/ADTS
zig build run -- undo-tags DATABASE GROUP
zig build run -- prune-backups DATABASE [--older-than=DAYS]   # deletes backups; those writes can no longer be undone

# ratings and playlists -- kept per recording in the library; no file is written
zig build run -- rate DATABASE IDS (--stars=1..5 | --rating=1..100 | --clear)
zig build run -- playlists DATABASE
zig build run -- playlist DATABASE ID [--limit N] [--offset N]
zig build run -- playlist-create DATABASE NAME
zig build run -- playlist-rename DATABASE ID NAME
zig build run -- playlist-delete DATABASE ID
zig build run -- playlist-add DATABASE ID IDS [--at=N]   # appends, or inserts before position N
zig build run -- playlist-remove DATABASE ID POSITIONS
zig build run -- playlist-move DATABASE ID FROM TO
zig build run -- playlist-import DATABASE FILE [--name=NAME]   # M3U/M3U8; matches by path, then #EXTINF; never scans
zig build run -- playlist-export DATABASE ID FILE [--relative] [--force]   # atomic; refuses an existing FILE without --force

# playback -- pass a device from scripts/silent-sink.sh, never the default
zig build run -- play AUDIO [DEVICE_ID]
zig build run -- play-tracks DATABASE (IDS | --playlist=ID) --device=ID [--start=N] [--repeat=off|one|all] [--shuffle]
    [--replay-gain=off|track] [--volume=LINEAR] [--set-volume=MS:LINEAR]
    [--eq=PRESET|G1,...,G10[:PREAMP]] [--crossfeed=0..1]   # prints a `signal:` line
    [--skip-after=MS] [--previous-after=MS] [--tail=MS] [--limit=MS]   # --limit defaults to 10 min
    # records listens in the play history; never sends them

# listening history and ListenBrainz -- token from ORCA_LISTENBRAINZ_TOKEN,
# server from ORCA_LISTENBRAINZ_URL (https, or http to localhost)
zig build run -- scrobble DATABASE [--status] [--timeout=MS]   # send queued listens and feedback (nothing queued: no request); --status sends nothing
zig build run -- feedback DATABASE IDS (--love | --hate | --clear)   # kept locally; scrobble syncs it to ListenBrainz

# MusicBrainz and AcoustID matching -- servers from ORCA_MUSICBRAINZ_URL and
# ORCA_ACOUSTID_URL (https, or http to localhost); AcoustID application key from
# -Dacoustid-key=KEY at build time (default AqlfLksN1K)
zig build run -- match DATABASE [--batch=N] [--limit=N] [--no-fingerprints] [--cancel-after=MS]   # each service once per file, 1 request/s
zig build run -- matches DATABASE TRACK_ID   # source and AcoustID score per proposal
zig build run -- fingerprint DATABASE TRACK_ID   # fpcalc-style DURATION= and FINGERPRINT=
zig build run -- accept-match DATABASE PROPOSAL_ID   # records the recording ID in the library only
zig build run -- dismiss-match DATABASE PROPOSAL_ID
zig build run -- accept-matches DATABASE --min-score=0.9   # each file's best match that confident
zig build run -- match DATABASE --release=ID [--accept-min-score=0.9] [--cover-art]   # Match Album

# Cover Art Archive -- server from ORCA_COVERARTARCHIVE_URL (https, or http to
# localhost); stores the cover in the library, never in a file
zig build run -- cover-art DATABASE RELEASE_ID   # prints source=embedded|fetched|cached|cached-miss|not-found|no-release-id and bytes

# AcoustID submission of recording IDs from accepted matches or edits -- user key
# from ORCA_ACOUSTID_USER_KEY; point ORCA_ACOUSTID_URL at a local mock when testing
zig build run -- submit-acoustid DATABASE [--dry-run]
```

Frontends:

```sh
ORCA_LIBRARY=/path/to/library.db zig build run-linux   # GTK4 frontend

# Pin the output so an automated run cannot reach the speakers. Unset, the app
# uses the output menu, which defaults to the system default -- device 0.
ORCA_LIBRARY=... ORCA_OUTPUT_DEVICE=$(scripts/silent-sink.sh 1) zig build run-linux

# Point ListenBrainz submission at a local mock instead of listenbrainz.org
ORCA_LISTENBRAINZ_URL=http://127.0.0.1:PORT zig build run-linux

# Point MusicBrainz matching at a local mock instead of musicbrainz.org
ORCA_MUSICBRAINZ_URL=http://127.0.0.1:PORT zig build run-linux

# Point AcoustID lookups and submissions at a local mock instead of acoustid.org
ORCA_ACOUSTID_URL=http://127.0.0.1:PORT zig build run-linux

# Point cover fetches at a local mock instead of coverartarchive.org
ORCA_COVERARTARCHIVE_URL=http://127.0.0.1:PORT zig build run-linux
```

The app opens an output on first play, not at launch, so an idle window does
not hold the user's default sink.

To look at the GUI without putting a window on the user's desktop, run it in a
headless sway session and screenshot it with `grim`; drive it with `wtype`,
which reaches GTK where transient virtual pointers do not. Use
`GSK_RENDERER=cairo` there. Pointer input needs one long-lived virtual pointer
(`zwlr_virtual_pointer_v1`): GTK does not bind a device that exists only for a
single command, as `wlrctl`'s do.

macOS: `zig build` first, then build `apps/macos` with SwiftPM — it links
`zig-out/lib/liborca` through a systemLibrary modulemap. The SwiftUI client is
not built or tested against the current C ABI, and liborca has no macOS audio
output (`docs/roadmap.md`, Later).

Live/host-dependent checks, excluded from the normal test run:

```sh
zig build dependency-smoke      # Linux foreign-library linking pattern
zig build pipewire-live-smoke   # opens a short silent stream on the user's PipeWire server
```

Unit and integration tests require no audio server. The C ABI smoke test (`c-abi-smoke`,
part of `zig build test`) opens an output, so on Linux `zig build test` needs
PipeWire: the build creates `scripts/silent-sink.sh`'s sink and passes its
device id to the test, and fails rather than fall back to the default output.
On the desktop it plays into that sink; `scripts/headless-audio.sh` gives it a
private PipeWire and WirePlumber where no audio server runs, as in CI.

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

There is no test filter wired into `build.zig` — `zig build test` runs every
test (it is fast and heavily cached, so this is usually fine). If you need
filtering, add `.filters` to the relevant `b.addTest` call rather than trying
to invoke the test binary by hand; the `liborca` module needs translate-C
SQLite, the `alac`, `libxaac` and `chromaprint` packages, libFLAC,
libopusfile, libvorbisfile, libsamplerate, libc, libc++ and the C shims, which
is impractical to
reconstruct on a bare `zig test` command line.

Tests are run from the repository root and load fixtures by relative path
(`fixtures/audio/...`). Do not make test working-directory assumptions.

## Architecture

### The rule that matters most

**A capability is not done until it is reachable from `orca-cli` or the GUI
through the public runtime/ABI path.** No exit criterion may be closed by a
unit test against an isolated component.

This is not a style preference. It is the rule whose absence produced the state
this repository had to be recovered from: ~12,000 lines of well-tested,
genuinely good components, a tag claiming a working music player, and no way to
play music. Every subsystem was an island. The scanner wrote only
`observed_files`; the `tracks` table was empty in any real database; playback
existed solely as a stack-local path in one CLI subcommand; the GTK window had
no row-activation handler. Each piece had passing tests.

The same pattern keeps surfacing as the seams get built. `Gain.setReplayGain`
existed, was correct, and was called by nothing. `fingerprint.findDuplicates`
existed, was correct, was called by nothing, and was O(n²) over a slice that
cannot be constructed at the target scale. Both were found by asking "what
calls this?", which is the question a test never asks.

So: when you finish something, run it. Through `orca-cli`, against real data if
any exists, and look at the output. A green `zig build test` means the parts
work. It says nothing about whether they are connected, and this codebase's
characteristic defect lives exactly there.

### The non-negotiable boundary

`liborca` owns *all* music, library, audio, metadata, mutation, and job
behavior. Frontends own windows, widgets, accessibility, and event loops —
nothing else. When adding a feature, the semantics belong in `liborca` and only
the presentation belongs in `apps/`. A frontend must never grow its own notion
of transport state, library paging, or metadata resolution.

**Frontend language is Zig wherever the platform permits it.** The project is
Zig-first, and that applies to `apps/`, not only to `liborca`. `orca-cli` and
`orca-gtk` are Zig and consume liborca's **public Zig API** directly: the
top level of `liborca/root.zig`, never `liborca.internal` (see `docs/api.md`).
A frontend that needs something only `internal` has is missing a `Runtime`
method; add the method. C appears
in a frontend only where a platform genuinely forces it.

Non-Zig frontends reach the engine through `liborca/orca.h` (a C ABI of opaque
runtime ownership, generational handles, POD snapshots, and **callback-scoped**
query views). String views are valid only for the duration of their callback; no
SQLite row, Zig container, or internal layout crosses the ABI. All `orca_*` calls
for one runtime must come from a single thread (Debug builds return
`ORCA_STATUS_WRONG_THREAD`); see `docs/frontends.md`. The SwiftUI
client uses that ABI because AppKit requires Swift; `tests/c_abi_smoke.c`
exercises it end to end so it cannot rot while macOS is uncompiled.

GTK4 is bound with hand-written `extern fn` declarations rather than generated
bindings. `translate-C` fails on GTK4's headers (glib's `_Pragma` macros
produce thousands of errors), and `zig-gobject` did not build on the snapshot
this frontend was written against. Declare only the symbols the app
actually uses.

### Runtime ownership

`Runtime` (`core.OrcaRuntime` inside liborca) is the process-level root. It is
defined in `core/runtime.zig`; its methods delegate by area to
`core/runtime_*.zig` (jobs, listens, queue, roots, status, zones), and
`core/job_worker.zig` holds `JobWorker`, the thread behind each Job. Every
runtime-visible object is a typed generational handle (`handle.Pool`), so
destroying an object bumps its slot generation and a stale handle can never
resolve to a later occupant of the same slot. Shutdown is strictly
dependency-ordered — work → Zones → Players → Libraries — and `deinit` always
performs shutdown, idempotently. See `docs/ownership.md`.

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
`entry_serial`, because the two questions are incompatible: "is this audio stale
after a seek" must be compared, while "which track is this" must not be, or
gapless breaks. What is *audible* is resolved from the entry serial the render
callback publishes, never from the decode cursor, which runs a whole entry ahead
of the audio; Players decode canonical PCM once and fanout copies it into
independently owned Zone pools so one Zone's failure cannot starve another; the
Player's DSP chain runs on the engine thread before fanout, never in the
callback, and the control lane changes its settings only while the engine is
quiesced. On Linux, PipeWire headers and native object lifetime stay inside a
narrow C shim (`liborca/audio/backends/pipewire_shim.c`); stream
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
Codec sourcing order: an existing, correct, licensed Zig package, then the
reference C library behind a narrow shim, and an Orca-written codec only when
neither exists. The project is not an exercise in writing codecs, and
correctness outranks purity. FLAC decodes through libFLAC
behind `codec/flac_shim.c` because the pure-Zig package that preceded it
reconstructed mid-side stereo one LSB low, which made a lossless format lossy;
see `docs/codecs.md`.

Scanning is incremental and restart-resumable: unchanged path + storage identity
skips all format/metadata work, commits are bounded, and cancellation is checked
before filesystem work and between entries. Because only changed bytes are
probed, a row written without a probe keeps null properties for ever;
`library/property_backfill.zig` repairs those rows by `files.id` with no walk,
selected through a partial index over exactly the rows that are incomplete, and
reprojects each batch it repairs. Filesystem watchers are an *acceleration only*
— they emit bounded, coalescing, root-scoped hints and never directly insert,
remove, or mutate observed state. See `docs/storage.md`.

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

`docs/providers.md` holds the rules Orca follows toward every provider:
identification, rate limits, backoff, credentials and listen eligibility.

All provider traffic passes through **one** rate-limited, retrying HTTP
boundary (`network.Gateway`) with bounded responses, service identification,
and an explicit offline mode. Do not add a second HTTP path. Credentials come
from platform secure-storage adapters, are never stored in an Orca library, and
must never enter durable cache keys. Provider matches remain reviewable
proposals with explicit confidence until accepted; acceptance is a transaction
into Orca metadata that preserves user locks and does **not** write media files.

## Conventions

- **Public API.** A new `Runtime` method's parameter and return types are
  exported at the top of `liborca/root.zig`; test-only hooks stay private.
- **Subsystem roots.** Each `liborca/<subsystem>/root.zig` re-exports every file
  as a `pub const` and mirrors that list in a `test { _ = @import(...); }`
  block. Add new files to both.
- **Interfaces are context+vtable structs** (`ReadableSource`, `Transport`,
  `Clock`, `Decoder`) rather than generics, which keeps the C ABI and platform
  adapters possible.
- **Inject time and I/O for determinism.** Provider and network tests supply
  `network.testing`'s `ScriptedTransport` and `TestClock`
  (`liborca/network/testing.zig`) through those vtables — no live network, no
  wall-clock sleeps. Follow that pattern for anything with retry or rate-limit
  behavior.
- **Platform code is contained.** `liborca/platform.zig` switches on
  `builtin.os.tag`; foreign headers and native object lifetimes live in the
  adapter (or C shim) for that platform and nowhere else.
- **Test names are behavioral sentences** describing the invariant being
  protected, e.g. `test "removed handles stay stale when their slot is reused"`.
- Bounded everything: fixed-capacity queues, 512-row query pages, bounded
  commits, bounded retries. Prefer rejecting or applying backpressure over
  unbounded growth.
- Every commit that adds, fixes, refactors or removes something adds its
  entry to the Unreleased section of `CHANGELOG.md` in the same commit.
  Versioning and the release steps are in
  [docs/roadmap.md](docs/roadmap.md#releases).
