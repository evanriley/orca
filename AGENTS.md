# Orca repository guidance

Working rules for coding agents, whichever agent is used, and for the people
directing them. `liborca/AGENTS.md` and `apps/linux/AGENTS.md` add rules for
their trees; read them before changing files there.

## Project

Orca is a local-files-first music player and library-maintenance application
written in Zig. `liborca/` is the reusable headless engine and the product;
`apps/` contains thin native clients of its public API.

Direction (Planned, Ideas, Not planned) belongs in
[docs/roadmap.md](docs/roadmap.md), and what works today in the README's
Features list. Defects, test gaps and small enhancements are GitHub issues.
Subsystem behavior and contracts belong in `docs/*.md`. Change an `AGENTS.md` file only
when an agent working rule changes.

## Dependencies and licences

Orca is MPL-2.0. Dependencies are chosen on technical merit; GPL, LGPL and AGPL
are allowed. A copyleft dependency that can reasonably be optional gets a build
option so a build without it stays possible, but that never blocks adopting it.
Third-party source that Orca changes lives in a fork at
`github.com/evanriley/<name>`, with each change as a commit, pinned by commit
in `build.zig.zon`. The repository holds no third-party source. Frontend-only
fonts may use the SIL Open Font License and keep their licence texts beside
them.

Chromaprint is built without its resampler and uses libsamplerate instead.
ONNX Runtime (MIT, with some MPL-2.0 files) is a dynamically linked system
library that `-Dembeddings=false` removes; never vendor it or link it
statically.

An audio-embedding model is a data file, never committed or compiled in. The
engine downloads one only when a host asks, to a path the host names, and
checks it against the compiled-in SHA-256. A model the engine can download may
carry a non-commercial licence when its release states the licence, the
attribution and the source, as `discogs_maest` (CC BY-NC-SA 4.0) does. A
package bundles only permissively licensed models. See
[the architecture dependency table](docs/architecture.md#dependencies-and-licences).

## Toolchain

- Use Zig 0.17.0, from `nix develop` or direnv, or installed as
  [the README's requirements](README.md#requirements) describe for a build
  outside Nix. This codebase uses `std.Io`, not the older `std.fs` and
  `std.io` APIs.
- The dev shell supplies SQLite, the codec libraries, PipeWire, GTK4, and
  libsecret. Never hard-code library paths under `/usr` or `/nix/store`.
- When `build.zig.zon` dependencies change, update the
  `zig_0_17.fetchDeps` hash in `nix/package.nix`; set it to `lib.fakeHash`
  and rebuild to obtain the hash.
- GTK4 is hand-bound because `translate-C` cannot parse its headers.
- nixpkgs has no zls for Zig 0.17, so the dev shell does not provide one.

Zig 0.17 constraints that affect correctness:

- A by-value struct parameter is a copy. Pass `*const T` when a pointer into
  the argument must outlive the call.
- Use `std.Io.Mutex` and `std.Io.Condition` when an `io` is available;
  `std.Thread.Mutex`, `Condition`, and `ResetEvent` do not exist.
- `std.Io.Dir` cannot fsync a directory. Open the directory path as a file for
  durable renames.
- Convert signed durations to unsigned before zero-padded formatting.
- Sentinel strings use `std.fmt.bufPrintSentinel`,
  `std.fmt.allocPrintSentinel` and `Allocator.dupeSentinel`.
- `@typeInfo` returns parallel arrays (`field_names`, `field_types`,
  `field_attrs`), not a `fields` slice; `std.meta.fields` does not exist.
- `std.http.Client` and `std.Io.net.HostName` accept only RFC 1123 host
  names, so a bracketed IPv6 literal URL cannot be requested.
- Build scripts cannot read `zig build -- ARGS` or the install prefix; use
  `Run.addPassthruArgs` and install-relative `LazyPath`s.

## Architecture invariants

- A capability is complete only when a client reaches it through the public
  runtime or ABI path. Verify the connected path, not only an isolated unit.
- `liborca` owns music, library, audio, metadata, mutation, provider, and job
  behavior. Frontends own presentation, accessibility, event loops, and
  platform integration.
- Zig clients use exports from `liborca/root.zig`, never
  `liborca.internal`. Non-Zig clients use `liborca/orca.h`.
- The real-time render callback never allocates, frees, locks, waits, performs
  I/O, or touches SQLite.
- Filesystem paths are not musical identity. File mutation occurs only through
  an explicitly approved, journaled `MutationPlan`.
- Queues, pages, transactions, retries, and external responses stay bounded.
- Provider traffic uses `network.Gateway`. Tests use injected transports,
  clocks, and local mocks; never live services.

Read [docs/architecture.md](docs/architecture.md) before crossing subsystem
boundaries. Read `liborca/AGENTS.md` before changing `liborca/` and
`apps/linux/AGENTS.md` before changing `apps/linux/`.

## Verification

Run commands from the repository root inside the dev shell. Outside Nix, run
the `zig` commands; CI runs the `nix` ones. What CI runs on pull requests and
on `main` is in [CONTRIBUTING.md](CONTRIBUTING.md#continuous-integration).

```sh
zig fmt --check liborca apps benchmarks tests build build.zig
zig build
zig build test
zig build fuzz
nix flake check
nix build
```

Run compiler commands unpiped so their exit status is preserved. A plain
`zig build` replaces `zig-out/bin` with Debug artifacts; rebuild with
`-Doptimize=ReleaseFast` immediately before benchmarks.

Tests must not use real audio hardware. Playback checks receive an explicit
device from `scripts/silent-sink.sh`; an omitted device selects the system
default output. `scripts/headless-audio.sh zig build test` supplies the private
PipeWire and WirePlumber setup used by CI. `zig build pipewire-live-smoke` is a
host-dependent check and is not part of the normal suite.

Every implementation change updates the Unreleased section of `CHANGELOG.md`.

## Documentation index

- [Architecture and subsystem index](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Release process](docs/releasing.md)
- [CLI command catalogue](docs/cli.md)
- [Public Zig API](docs/api.md)
- [Runtime ownership and shutdown](docs/api.md#runtime-ownership-and-shutdown)
- [Control plane and jobs](docs/control-plane.md)
- [Audio engine](docs/audio-engine.md)
- [Database and schema](docs/database.md)
- [Storage and scanning](docs/storage.md)
- [Metadata and file mutation](docs/metadata.md)
- [Providers and listening history](docs/providers.md)
- [Frontend and C ABI contracts](docs/frontends.md)
