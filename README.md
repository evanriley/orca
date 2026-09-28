# Orca

Orca is a local-files-first music player and library-maintenance application.
Its engine, `liborca`, is a Zig library for everything music-related, and the
native frontends are thin clients of it. The project is pre-release; the
[roadmap](docs/roadmap.md) lists what works today.

The [architecture overview](docs/architecture.md) describes the design and
links each subsystem's contract.

## Requirements

- Zig `0.16.0`
- libFLAC, libopusfile, libvorbis and SQLite development libraries
- Linux builds: PipeWire and GTK4 development libraries

With Nix, `nix develop` (or direnv) provides all of these, and `nix build`
builds the package.

## Build and test

```sh
zig build
zig build test
zig build run -- --version
zig build run -- demo
zig build run -- scan /tmp/orca.db /path/to/music
zig build run -- analyze /tmp/orca.db /path/to/audio
zig build run -- analyze-library /tmp/orca.db
zig build run -- health /tmp/orca.db
# The device argument is optional and defaults to 0, the system default sink.
# `scripts/silent-sink.sh` prints one that discards audio, for automated runs.
zig build run -- play /path/to/audio [DEVICE_ID]
ORCA_LIBRARY=/path/to/library.db zig build run-linux
zig build bench
zig build -Doptimize=ReleaseFast dsp-bench
```

The DSP benchmark checks scalar/vector output equality before reporting
per-sample timings; use a release build for meaningful SIMD measurements.

The benchmark defaults to a generated 500,000-track in-memory library. Pass a
track count and SQLite path to exercise durable WAL storage, for example:

```sh
zig build bench -- 500000 /tmp/orca-500k.db
```

`zig build dependency-smoke` verifies the system-library integration pattern on
Linux. `zig build pipewire-live-smoke` discovers the current user's output
devices and opens a short silent native stream. PipeWire C headers and foreign
types remain contained in the Linux adapter.

Linux builds also install the GTK4 frontend, static/shared `liborca`, and the
foreign-client header at `include/orca/orca.h`.

Online identification and scrobbling are optional. Provider traffic passes
through one rate-limited, retrying HTTP boundary; credentials are supplied by
platform secure-storage adapters and are never stored in an Orca library.
Provider matches remain reviewable proposals until explicitly accepted, and
acceptance updates Orca metadata without writing media files.

## Repository layout

- `liborca/` — reusable headless engine
- `apps/` — CLI and native application frontends
- `benchmarks/` — executable performance fixtures
- `tests/` — integration, platform, recovery, and performance tests
- `fixtures/` — checked-in test media and pathological inputs
- `docs/` — architecture decisions and subsystem documentation

## License

Orca is licensed under the [Mozilla Public License 2.0](LICENSE). Applications
of any licence may embed `liborca`; changes to Orca's own files are shared
under the same terms.

`liborca` compiles in Apple's ALAC decoder and Ittiam's libxaac, both
Apache-2.0, and a vendored CC0 minimp3. `zig build` installs their licence and
notice files under `share/doc/orca/licenses`; distribute that directory with
any binary. The system libraries Orca links (SQLite, libFLAC, libopusfile,
libvorbis, PipeWire, GTK4) are distributed under their own licences.
