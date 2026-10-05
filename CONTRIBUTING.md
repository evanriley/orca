# Contributing

Orca is a 0.x preview. Features are frozen until 1.0, so fixes and
documentation are what is accepted now. The work in progress is the
[release gates](docs/roadmap.md#release-gates). Open an issue before starting
anything larger than a fix.

## Development environment

Use Zig 0.17.0 from the Nix dev shell, which supplies every library and tool:

```sh
nix develop
```

With direnv, the shell loads on entering the directory. The
[README](README.md#requirements) lists the requirements for a build outside
Nix.

## Verification

Run these from the repository root inside the dev shell. Run compiler commands
unpiped so their exit status is preserved.

```sh
zig fmt --check liborca apps benchmarks tests build build.zig
zig build
zig build test
zig build fuzz
nix flake check
nix build
```

A plain `zig build` replaces `zig-out/bin` with Debug artifacts; rebuild with
`-Doptimize=ReleaseFast` immediately before benchmarks.

## Audio in tests

Tests never use real audio hardware. Run the suite with the private PipeWire
and WirePlumber setup CI uses:

```sh
scripts/headless-audio.sh zig build test
```

Playback checks receive an explicit device from `scripts/silent-sink.sh`; an
omitted device selects the system default output, which is real hardware.

## Licence boundary

Orca is MPL-2.0. Everything vendored, compiled into or statically linked by
`liborca` must use a permissive licence such as BSD, MIT, Apache-2.0, zlib,
CC0 or public domain. GPL and LGPL dependencies are not permitted in the
engine. The
[dependency table](docs/architecture.md#dependencies-and-licences) lists
what is there and why.

## Architecture

Read [docs/architecture.md](docs/architecture.md) before changing code across
subsystem boundaries. It states the rules that hold everywhere and links each
subsystem's contract.

## Changes

- Commit messages follow
  [Conventional Commits](https://www.conventionalcommits.org):
  `<type>(<scope>): <description>`, with an optional body and footer.
- Every change adds an entry to the Unreleased section of `CHANGELOG.md` in the
  same commit: features, fixes, refactors, removals and breaking changes alike.
- Behavior and contracts are documented in `docs/*.md`; update the page that
  owns what you change.
- Provider requests go through `network.Gateway`. Tests use injected
  transports, clocks and local mocks, never live services.
