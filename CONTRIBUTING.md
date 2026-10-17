# Contributing

Orca is a 0.x preview and a personal project that takes no outside
contributions, issues or pull requests. These are the rules its own changes
follow. Known issues are [git-bug issues](https://b.maybemaybe.lol), and the
[roadmap](docs/roadmap.md) lists planned work.

## Development environment

Use Zig 0.17.0 from the Nix dev shell, which supplies every library and tool:

```sh
nix develop
```

With direnv, the shell loads on entering the directory. The
[install page](docs/install.md#requirements) lists the requirements for a build
outside Nix.

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

Other build and verification commands:

```sh
nix fmt                       # formats Nix files
zig build -Dgtk=false         # the same without orca-gtk and its files
zig build -Dembeddings=false  # liborca without audio embeddings and ONNX Runtime
zig build lib                 # static liborca and orca.h only; CI cross-builds it with -Dtarget=aarch64-macos
zig build test-liborca        # liborca's unit and integration tests only; CI runs them with -Doptimize=ReleaseSafe
zig build abi-compat          # orca.h keeps the layouts, values and functions of tests/abi/orca-0.1.0.h
zig build fuzz --fuzz[=N]     # fuzz the parser targets; N iterations per target, unlimited opens the web UI
zig build embed-example       # build examples/embed against this checkout
zig build package-check       # build examples/embed and an install from the fetched build.zig.zon package
zig build run -- --version    # orca-cli
zig build bench               # 500k-track persistence benchmark
zig build bench-build         # compile the benchmark programs without running them
zig build -Doptimize=ReleaseFast dsp-bench   # scalar vs SIMD DSP kernels
zig build -Doptimize=ReleaseFast analysis-bench -- FILE [ITERATIONS [EMBEDDING_MODEL]]   # one file's analysis with and without audio features; with a model, the audio embedding's stages
zig build dependency-smoke    # Linux foreign-library linking pattern
zig build pipewire-live-smoke -- ID   # opens a short stream on the silent sink ID
```

`zig build test` covers unit and integration tests, the C ABI smoke test and ABI
checks, and the PipeWire link smoke. The C ABI smoke test opens an output, so
on Linux the build creates the sink of `scripts/silent-sink.sh`, passes its
device id to the test and fails rather than fall back to the default output.
`dependency-smoke` and `pipewire-live-smoke` depend on the host and are not
part of the normal run; `ID` is the device id printed by
`scripts/silent-sink.sh`, and the smoke also reads `ORCA_TEST_DEVICE` and
refuses a missing, unknown or non-virtual device.

`build.zig` exposes no test filter; add `.filters` to the relevant `b.addTest`
call when one is needed. A bare `zig test` invocation does not work: the test
module needs its translated SQLite bindings, Zig packages, codec libraries,
libc, libc++ and C shims. Tests run from the repository root and load fixtures
by relative path.

`scripts/headless-gui.sh PAGE OUT.png [STEP...]` runs `orca-gtk` in a private
headless sway session, drives it and saves screenshots; it never opens a window
on the desktop. `ORCA_LIBRARY=... ORCA_OUTPUT_DEVICE=$(scripts/silent-sink.sh 1)
zig build run-linux` runs the GTK frontend on a silent output.

`scripts/alac-sanitize.sh` builds the ALAC decoder and `alac_shim.cpp`
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
- `test`: `zig build`, `zig build test bench-build embed-example` under
  `scripts/headless-audio.sh`, and `zig build fuzz`.

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

- `release`: `zig build test-liborca -Doptimize=ReleaseSafe` under
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
`zig-debug-` and the hash of `build.zig.zon` and `flake.lock`. A pull request
that changes either file falls back to the newest `zig-debug-` cache; a push
to `main` starts cold instead, which drops stale entries. Only pushes to
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

## Dependencies and licences

Orca is MPL-2.0. Dependencies are chosen on technical merit; GPL, LGPL and
AGPL are allowed. A copyleft dependency that can reasonably be optional gets a
build option so a build without it stays possible. Third-party source that Orca
changes lives in a fork at `github.com/evanriley/<name>`, with each change as a
commit, pinned by commit in `build.zig.zon`; the repository holds no
third-party source. The
[dependency table](docs/architecture.md#dependencies-and-licences) lists what
is there and why.

## Architecture

Read [docs/architecture.md](docs/architecture.md) before changing code across
subsystem boundaries. It states the rules that hold everywhere. The rules for
each tree are in [liborca/AGENTS.md](liborca/AGENTS.md) and
[apps/linux/AGENTS.md](apps/linux/AGENTS.md).

## Changes

- Commit messages follow
  [Conventional Commits](https://www.conventionalcommits.org):
  `<type>(<scope>): <description>`, with an optional body and footer.
- Every change adds a one-line entry to the Unreleased section of
  `CHANGELOG.md` in the same commit, as
  [releasing.md](docs/releasing.md#changelog) describes. Changes to CI alone
  need none.
- Docs are for users, embedders and contributors. Update the page a user,
  embedder or contributor reads when a change alters what it states; put
  measurements and the reasons behind a change in the commit message.
- Provider requests go through `network.Gateway`. Tests use injected
  transports, clocks and local mocks, never live services.
