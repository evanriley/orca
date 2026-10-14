# Contributing

Orca is a 0.x preview. The [roadmap](docs/roadmap.md) lists its known issues
and planned work. Open an issue before starting anything larger than a fix.

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

`scripts/alac-sanitize.sh` builds the vendored ALAC decoder and `alac_shim.cpp`
with AddressSanitizer and UndefinedBehaviorSanitizer and decodes the
`fixtures/fuzz/alac` seeds. Run it inside the dev shell after changing the
decoder or its bounds checks.

## Audio in tests

Tests never use real audio hardware. Run the suite with the private PipeWire
and WirePlumber setup CI uses:

```sh
scripts/headless-audio.sh zig build test
```

Playback checks receive an explicit device from `scripts/silent-sink.sh`; an
omitted device selects the system default output, which is real hardware.

## Continuous integration

`.github/workflows/test.yml` runs in three tiers. A `required` job fails when
any job fails; a skipped job counts as passing.

### Fast tier

Every pull request that changes anything outside `docs/`, `orca-design/` and
Markdown files runs:

- `lint`: `zig fmt --check` and a pinact check that every action is pinned to
  the commit its version comment names;
- `test`: `zig build`, `zig build test` under `scripts/headless-audio.sh`,
  and `zig build fuzz`.

A pull request that touches only `docs/`, `orca-design/` or Markdown files
skips every job.

### Scoped tier

These jobs run on a pull request only when it changes their inputs:

- `nix`: `nix flake check`, the package build, the NixOS module and the
  installed tree. Inputs: `flake.nix`, `flake.lock`, `nix/`, `build/`,
  `build.zig` and `build.zig.zon`;
- `package`: `zig build package-check` against the fetched Zig package.
  Inputs: `build.zig.zon`, `build/`, `build.zig`, `examples/` and
  `scripts/check-package.sh`.

### Full tier

The full tier runs every job: the fast and scoped jobs plus

- `release`: `zig build test -Doptimize=ReleaseSafe` under
  `scripts/headless-audio.sh`;
- `sanitize`: the ALAC and AAC sanitizer scripts;
- `cross-macos`: the static `liborca` cross-build for aarch64 macOS;
- `distro`: a build with the official Zig release against the libraries of
  Debian 13 (with `-Dgtk=false`) and Fedora 43.

It runs on:

- every push to `main`;
- a manual dispatch of the workflow;
- a pull request that carries the `ci:full` label. Adding a label re-runs the
  pull request's tiers;
- the nightly schedule at 07:00 UTC;
- completion of the `ci-images` workflow, when it succeeded.

The nightly run is skipped when the head commit of `main` already has a
successful run of this workflow from a push, a dispatch, a `ci-images`
completion or an earlier nightly, unless the latest successful `ci-images` run
finished after that run.

On pushes to `main` the `nix` job uploads the package to the
[orca.cachix.org](https://orca.cachix.org) binary cache.

### Zig cache

The `test` job restores `.zig-cache`, `~/.cache/zig` and
`examples/embed/.zig-cache` from the newest cache whose key starts with
`zig-debug-` and the hash of `build.zig.zon` and `flake.lock`. Only pushes to
`main` save the cache, and only when the three directories total at most
4 GiB.

### Images

The `distro` jobs run in prebuilt images on GitHub Container Registry, built
weekly by `.github/workflows/ci-images.yml`, instead of pulling from Docker Hub
on every run. Dependabot proposes action updates weekly, a week after their
release.

## Coding agents

[AGENTS.md](AGENTS.md) holds the working rules for coding agents: toolchain
constraints, architecture invariants and verification.
[liborca/AGENTS.md](liborca/AGENTS.md) and
[apps/linux/AGENTS.md](apps/linux/AGENTS.md) add rules for those trees. Point
an agent that does not read `AGENTS.md` files by itself at them.

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
