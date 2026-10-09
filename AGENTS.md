# Orca repository guidance

Working rules for coding agents, whichever agent is used, and for the people
directing them. `liborca/AGENTS.md` and `apps/linux/AGENTS.md` add rules for
their trees; read them before changing files there.

## Project

Orca is a local-files-first music player and library-maintenance application
written in Zig. `liborca/` is the reusable headless engine and the product;
`apps/` contains thin native clients of its public API.

Feature status belongs only in [docs/roadmap.md](docs/roadmap.md). Subsystem
behavior and contracts belong in `docs/*.md`. Change an `AGENTS.md` file only
when an agent working rule changes.

## Licence boundary

Orca is MPL-2.0. Everything vendored, compiled into, or statically linked by
`liborca` must use a permissive licence such as BSD, MIT, Apache-2.0, zlib,
CC0, or public domain. GPL and LGPL dependencies are not permitted in the
engine because they would constrain embedders. A frontend may dynamically
link its platform toolkit or keyring. Frontend-only fonts may use the SIL Open
Font License and keep their licence texts beside them.

Chromaprint is built without its LGPL resampler and uses libsamplerate instead.
Its build-time licence check must remain enabled. See
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
the `zig` commands; CI runs the `nix` ones.

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
- [Feature status](docs/roadmap.md)
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
