# Orca

Orca is a local-files-first music player and library-maintenance application.
Its engine, `liborca`, is a Zig library for everything music-related, and the
native frontends are thin clients of it. The [roadmap](docs/roadmap.md) lists
what works today.

The [architecture overview](docs/architecture.md) describes the design and
links each subsystem's contract.

## Preview status

Orca is a 0.x preview. Before 1.0, a release bumps the minor version when it
contains a breaking change to the Zig API, the C ABI or the Library schema,
and the patch version otherwise ([Releases](docs/roadmap.md#releases)).
Features are frozen until 1.0; the work now is fixes and the
[release gates](docs/roadmap.md#release-gates).

Orca changes music files only through an approved, journaled plan; tag writes
are the only kind reachable today. See
[Metadata and file mutation](docs/metadata.md).

### Platforms

| Platform | Built | Audio output | Application |
| --- | --- | --- | --- |
| x86_64-linux | `liborca`, `orca-cli`, `orca-gtk` | PipeWire | `orca-gtk` |
| aarch64-darwin | `liborca`, `orca-cli` | none | none |
| anything else | not built | none | none |

- aarch64-darwin has no audio output, so `orca-cli` cannot play there. There
  is no macOS app or filesystem watcher; both are on the roadmap's
  [Later](docs/roadmap.md#later) list. CI cross-compiles only the static
  `liborca` for macOS (`zig build lib -Dtarget=aarch64-macos`) and does not
  run Orca there.
- The Nix flake and package declare exactly `x86_64-linux` and
  `aarch64-darwin`.

### Privacy and security

Orca contacts outside services only for features you start or switch on, and
sends no telemetry. [Privacy](docs/privacy.md) lists each service, what it
receives and when. Report vulnerabilities as [SECURITY.md](SECURITY.md)
describes, and read [CONTRIBUTING.md](CONTRIBUTING.md) before sending changes.

## Install with Nix

The flake at `github:evanriley/orca` packages Orca for `x86_64-linux` and
`aarch64-darwin`. The package installs `orca-cli`, `orca-gtk` (Linux only),
static and shared `liborca`, `include/orca/orca.h`, `lib/pkgconfig/orca.pc`,
the desktop entry and the icons.

Run it without installing:

```sh
nix run github:evanriley/orca   # orca-gtk on Linux; orca-cli on macOS
nix run github:evanriley/orca#orca-cli -- --version
```

### NixOS

```nix
{
  inputs.orca.url = "github:evanriley/orca";

  outputs =
    { nixpkgs, orca, ... }:
    {
      nixosConfigurations.HOSTNAME = nixpkgs.lib.nixosSystem {
        modules = [
          ./configuration.nix
          orca.nixosModules.default
          { programs.orca.enable = true; }
        ];
      };
    };
}
```

`programs.orca.enable` adds `programs.orca.package` to
`environment.systemPackages`.

### Home Manager

Import `orca.homeModules.default` into the Home Manager configuration and set
`programs.orca.enable = true;`; the package goes into `home.packages`:

```nix
home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    ./home.nix
    orca.homeModules.default
    { programs.orca.enable = true; }
  ];
}
```

### Overlay

`orca.overlays.default` adds `pkgs.orca`, built against the nixpkgs it is
applied to. That nixpkgs must provide Zig 0.16 as `pkgs.zig`. The modules'
default package and `orca.packages.<system>.orca` are built against the
nixpkgs pinned in this flake's `flake.lock` instead.

### Runtime requirements

- A PipeWire audio server, for playback on Linux. The modules do not enable
  one; on NixOS, set `services.pipewire.enable = true;`.
- A Secret Service provider, such as GNOME Keyring, for the ListenBrainz token
  and the AcoustID user key `orca-gtk` stores. `orca-cli` reads them from
  `ORCA_LISTENBRAINZ_TOKEN` and `ORCA_ACOUSTID_USER_KEY`.
- On Linux distributions other than NixOS, `orca-gtk` may need
  [nixGL](https://github.com/nix-community/nixGL) to find the host's OpenGL
  drivers.

## Requirements

Every platform:

- Zig `0.16.0`. Zig compiles the C and C++ sources (the codec shims, ALAC,
  libxaac and Chromaprint) with its bundled Clang, so no separate C or C++
  compiler is needed.
- `pkg-config`
- Development files for SQLite (`sqlite3`), libFLAC (`FLAC`), libogg, libopus,
  opusfile, libvorbis (`vorbisfile`) and libsamplerate (`samplerate`)

Linux only:

- PipeWire (`libpipewire-0.3`), for audio output
- For `orca-gtk`: GTK4 (`gtk-4`), libadwaita (`libadwaita-1`), gdk-pixbuf
  (`gdk-pixbuf-2.0`) and libsecret (`libsecret-1`)

The names in parentheses are the pkg-config packages `build.zig` asks for. With
Nix, `nix develop` (or direnv) provides all of these, plus the tools the
scripts and checks use (Python, `ffprobe`, the `sqlite3` shell), and
`nix build` builds the package described in
[Install with Nix](#install-with-nix).

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
# The device argument is optional and defaults to 0, the system default
# output, which is real hardware. For tests and automated runs, pass the device
# `scripts/silent-sink.sh` prints; it discards audio.
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

Linux builds also install the GTK4 frontend with its desktop entry, static and
shared `liborca` (`liborca.so.0`), the foreign-client header at
`include/orca/orca.h`, and `lib/pkgconfig/orca.pc`.

`orca-cli` and `orca-gtk` identify themselves to MusicBrainz, AcoustID and
ListenBrainz with the contact given by `-Dprovider-contact=CONTACT`; the
default is set in `build.zig`.

Online identification and scrobbling are optional. Provider traffic passes
through one rate-limited HTTP boundary, described in
[Privacy](docs/privacy.md); credentials are supplied by
platform secure-storage adapters and are never stored in an Orca library.
Provider matches remain reviewable proposals until explicitly accepted, and
acceptance updates Orca metadata without writing media files.

## Embedding

`liborca` is a library for other applications as well as Orca's own:

- [docs/api.md](docs/api.md) covers the public Zig API, adding liborca as a
  Zig package dependency, the identity a host must supply before provider
  work, and what stays stable between releases.
- [examples/embed](examples/embed) is a complete Zig project that lists a
  library's tracks through that API; `zig build test` builds it.
- [docs/frontends.md](docs/frontends.md#c-abi) covers the C ABI in
  `liborca/orca.h` for clients in other languages, including linking through
  pkg-config.

## Repository layout

- `liborca/` — reusable headless engine
- `apps/` — CLI and native application frontends
- `benchmarks/` — executable performance fixtures
- `examples/` — projects that embed `liborca`
- `tests/` — integration, platform, recovery, and performance tests
- `fixtures/` — checked-in test media and pathological inputs
- `docs/` — architecture decisions and subsystem documentation

## License

Orca is licensed under the [Mozilla Public License 2.0](LICENSE). Applications
of any licence may embed `liborca`; changes to Orca's own files are shared
under the same terms.

`liborca` compiles in Apple's ALAC decoder and Ittiam's libxaac, both
Apache-2.0, Chromaprint (MIT) with its KissFFT (BSD-3-Clause), a vendored CC0
minimp3, and the vendored MIT reference QOA decoder. `zig build` installs their
licence and notice files under `share/doc/orca/licenses`; distribute that
directory with any binary. The system libraries Orca links (SQLite, libFLAC,
libogg, libopus, opusfile, libvorbis, libsamplerate, PipeWire, and for
`orca-gtk` GTK4, libadwaita, gdk-pixbuf and libsecret) are distributed under
their own licences.
