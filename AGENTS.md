# Orca repository guidance

Working rules for coding agents, whichever agent is used, and for the people
directing them. `liborca/AGENTS.md` and `apps/linux/AGENTS.md` add rules for
their trees; read them before changing files there.

## Project

Orca is a local-files-first music player and library-maintenance application
written in Zig. `liborca/` is the reusable headless engine and the product;
`apps/` contains thin native clients of its public API.

Docs are for users, embedders and contributors: what something is, how to use
it, and the rules a contributor must keep. They hold no measurements, decision
history, session notes or implementation narrative; those belong in commit
messages. Direction (Planned, Ideas, Not planned) belongs in
[docs/roadmap.md](docs/roadmap.md), what works today in the README's Features
list, and defects, test gaps and small enhancements in GitHub issues. Rules an
agent must not break belong in the `AGENTS.md` of the tree they govern. Change
an `AGENTS.md` file only when an agent working rule changes.

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

- Use C++23 with GCC 15, from `nix develop` or direnv. Clang builds the fuzz
  and sanitizer presets.
- The dev shell supplies CMake, Ninja, ccache, pkg-config, SQLite, the codec
  libraries, PipeWire, GTK4, gtkmm4, libadwaita, libsecret and libcurl. Never
  hard-code library paths under `/usr` or `/nix/store`.
- Vendored dependencies (yyjson, BLAKE3, a single-file SHA-256, doctest) are
  fetched by commit from `cmake/Dependencies.cmake`; the repository holds no
  third-party source.
- Formatting is clang-format (`.clang-format`); naming and lint checks are in
  `.clang-tidy`. [docs/style.md](docs/style.md) governs what the formatter
  cannot: bounds, assertions, naming and function length.
- Engine code does not throw exceptions and does not use bare `new`/`delete`;
  errors travel in `std::expected<T, orca::Error>`.

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

Run commands from the repository root inside the dev shell. What CI runs on
pull requests and on `main` is in
[CONTRIBUTING.md](CONTRIBUTING.md#continuous-integration).

```sh
clang-format --dry-run -Werror $(git ls-files '*.cpp' '*.hpp')
cmake --preset debug && cmake --build --preset debug && ctest --preset debug
cmake --preset asan && cmake --build --preset asan && ctest --preset asan
cmake --preset ubsan && cmake --build --preset ubsan && ctest --preset ubsan
cmake --preset fuzz && cmake --build --preset fuzz
nix flake check
nix build
```

Run compiler commands unpiped so their exit status is preserved.

Tests must not use real audio hardware, real network services or wall-clock
sleeps. Playback checks receive an explicit device from
`scripts/silent-sink.sh`; an omitted device selects the system default output.
`scripts/headless-audio.sh` supplies the private PipeWire and WirePlumber setup
used by CI.

Every implementation change adds a one-line entry to the Unreleased section of
`CHANGELOG.md`, as [releasing.md](docs/releasing.md#changelog) describes.

## Documentation index

- [Install and build](docs/install.md)
- [The Library, upgrades and tag writing](docs/library.md)
- [Command-line interface](docs/cli.md)
- [Sound similarity models](docs/sound-similarity.md)
- [Privacy](docs/privacy.md)
- [Zig API](docs/api.md)
- [Runtime ownership and shutdown](docs/api.md#runtime-ownership-and-shutdown)
- [C ABI](docs/c-abi.md)
- [Architecture, formats and dependencies](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Release process](docs/releasing.md)
