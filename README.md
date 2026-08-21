# Orca

Orca is a local-files-first music player and library-maintenance application.
Its reusable Zig core, `liborca`, owns music-domain behavior while thin native
frontends provide platform integration.

The authoritative product and architecture specification is
[`Orca_Full_Implementation_Plan_v1.0.md`](Orca_Full_Implementation_Plan_v1.0.md).

## Requirements

- Zig `0.17.0-dev.1770+5d7cf3f34` or newer compatible development snapshot
- Linux builds: PipeWire development library

## Build and test

```sh
zig build
zig build test
zig build run -- --version
zig build run -- demo
zig build run -- scan /tmp/orca.db /path/to/music
zig build run -- analyze /tmp/orca.db /path/to/audio
zig build run -- health /tmp/orca.db
zig build run -- play /path/to/audio
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

## Repository layout

- `liborca/` — reusable headless engine
- `apps/` — CLI and native application frontends
- `benchmarks/` — executable performance fixtures
- `tests/` — integration, platform, recovery, and performance tests
- `fixtures/` — checked-in test media and pathological inputs
- `docs/` — architecture decisions and subsystem documentation
