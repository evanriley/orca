# Orca

Orca is a local-files-first music player and library-maintenance application
for Linux. Its engine, `liborca`, is a Zig library that owns the music library,
playback, metadata, analysis and online identification; `orca-gtk` and
`orca-cli` are thin clients of it, and other applications can embed it through
its Zig API or C ABI.

Orca is pre-1.0. A release before 1.0 bumps the minor version when it breaks
the Zig API, the C ABI or the Library schema. Orca builds and plays on
x86_64 Linux with PipeWire; other platforms are on the roadmap.

Orca changes music files only through a plan the user approves, journaled so
that an interrupted write is recovered and a finished one can be undone. It
contacts outside services only for features the user starts or switches on,
and sends no telemetry; [Privacy](docs/privacy.md) lists each service and what
it receives.

## Roadmap and status

| # | Feature | Status |
| --- | --- | --- |
| 1 | Local library, gapless playback, journaled tag writes, identification | ✅ 0.1.0 |
| 2 | Stable Zig API, C ABI and Library schema (1.0) | ⚠️ [release gates](docs/roadmap.md#release-gates) open |
| 3 | Library radio and mixes | ❌ |
| 4 | Tag writing for M4A, Ogg, WAV and AIFF | ❌ |
| 5 | Full multichannel playback | ❌ |
| 6 | Fixed output rate with a band-limited resampler | ❌ |
| 7 | Crossfade, and convolution DSP for room correction | ❌ |
| 8 | Synchronized multi-zone playback | ❌ |
| 9 | Conversion and encoding | ❌ |
| 10 | Secure CD ripping | ❌ |
| 11 | Terminal client, macOS and Windows apps | ❌ |

[The roadmap](docs/roadmap.md) lists what works today, the release gates,
known issues and everything planned.

## Install with Nix

The flake packages Orca for `x86_64-linux`. The package installs `orca-gtk`,
`orca-cli`, static and shared `liborca`, `include/orca/orca.h`,
`lib/pkgconfig/orca.pc`, the desktop entry and the icons.

Run it without installing:

```sh
nix run github:evanriley/orca
nix run github:evanriley/orca#orca-cli -- --version
```

### NixOS

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.orca.url = "github:evanriley/orca";
  inputs.orca.inputs.nixpkgs.follows = "nixpkgs";

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

The default `programs.orca.package` is built against the system's nixpkgs when
it provides `zig_0_17`, and against the nixpkgs pinned in this flake's
`flake.lock` otherwise. NixOS loads the host's GPU drivers from
`/run/opengl-driver` into the application, and they need a glibc at least as
new as the one they were built against. A package built against an older
nixpkgs than the system leaves `orca-gtk` without a Vulkan device, and GTK
renders in software.

`inputs.orca.inputs.nixpkgs.follows = "nixpkgs";` builds
`orca.packages.x86_64-linux.orca` against the system's nixpkgs as well.

### Home Manager

`orca.homeModules.default` adds the package to `home.packages`. Its default
package follows the same rule as the NixOS module, using the `pkgs` passed to
Home Manager:

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
applied to, which must provide Zig 0.17 as `pkgs.zig_0_17`. The modules'
default package is built the same way when `pkgs` provides `zig_0_17`.
`orca.packages.x86_64-linux.orca` is built against the nixpkgs pinned in this
flake's `flake.lock` unless `inputs.orca.inputs.nixpkgs.follows` replaces it.

### Binary cache

CI uploads every `main` build of `orca.packages.x86_64-linux.orca` to
[orca.cachix.org](https://orca.cachix.org). The flake's `nixConfig` names the
cache, so `nix run` and `nix build` of this flake ask whether to use it, and
`--accept-flake-config` accepts it without asking. Nix applies `nixConfig`
only from the flake it is run on, and the daemon ignores it for users not in
`trusted-users`. For the modules, or for such users, add the cache to the
system configuration:

```nix
nix.settings = {
  substituters = [ "https://orca.cachix.org" ];
  trusted-public-keys = [ "orca.cachix.org-1:Cn49KmT1A0Sg/RPfc6TnKmaQYirb2b58eZD6nUP/Nxg=" ];
};
```

A package built against another nixpkgs is not in the cache and is built
locally.

## Build from source

The steps below are checked in clean containers of Arch Linux, Fedora 43,
Debian 13 and Ubuntu 24.04.

### Requirements

- Zig 0.17.0. Zig compiles the bundled C and C++ sources (the codec shims,
  ALAC, libxaac and Chromaprint), so no separate C or C++ compiler is needed.
- pkg-config.
- For `liborca` and `orca-cli`: development files for SQLite, libFLAC, libogg,
  libvorbis, Opus, opusfile, libsamplerate and PipeWire.
- For `orca-gtk`: development files for GTK 4.18 or newer, libadwaita 1.8 or
  newer, Pango 1.56 or newer and libsecret.

Debian 13 ships libadwaita 1.7, and Ubuntu 24.04 ships GTK 4.14, libadwaita
1.5 and Pango 1.52. Both build `liborca` and `orca-cli`; build them with
`-Dgtk=false`, which leaves `orca-gtk` out.

### Install Zig

Install the official Zig 0.17.0 release:

```sh
curl -fLO https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
echo "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026  zig-x86_64-linux-0.17.0.tar.xz" | sha256sum -c -
mkdir -p ~/.local/zig
tar -xJf zig-x86_64-linux-0.17.0.tar.xz -C ~/.local/zig --strip-components=1
export PATH="$HOME/.local/zig:$PATH"
zig version
```

### Install the dependencies

Arch Linux:

```sh
sudo pacman -S --needed curl pkgconf sqlite flac libogg libvorbis opus opusfile libsamplerate pipewire gtk4 libadwaita libsecret
```

Fedora:

```sh
sudo dnf install curl xz pkgconf-pkg-config sqlite-devel flac-devel libogg-devel libvorbis-devel opus-devel opusfile-devel libsamplerate-devel pipewire-devel gtk4-devel libadwaita-devel libsecret-devel
```

Debian and Ubuntu:

```sh
sudo apt-get install --no-install-recommends ca-certificates curl xz-utils pkg-config libsqlite3-dev libflac-dev libogg-dev libvorbis-dev libopus-dev libopusfile-dev libsamplerate0-dev libpipewire-0.3-dev
```

Add `libgtk-4-dev libadwaita-1-dev libsecret-1-dev` on a release whose GTK and
libadwaita meet the requirements above.

### Build and install

```sh
zig build -Doptimize=ReleaseSafe -p ~/.local
```

`-p` sets the install prefix. Add `-Dgtk=false` to build without `orca-gtk`,
and pass it to `zig build test` as well. The install holds:

- `bin/orca-gtk` and `bin/orca-cli`;
- `lib/liborca.a`, `lib/liborca.so` and `lib/pkgconfig/orca.pc`;
- `include/orca/orca.h`;
- `share/applications`, `share/icons` and `share/orca/fonts` for `orca-gtk`;
- `share/doc/orca/licenses`, the licences of the bundled third-party code.

`orca-gtk` finds its fonts and icons relative to its executable, so keep `bin`
and `share` under one prefix. A missing development package stops the build
with its pkg-config name, for example `pkg-config: package not found:
samplerate`.

### Run the tests

The tests start a private PipeWire and WirePlumber through
`scripts/headless-audio.sh` and never use an audio device. The script needs
WirePlumber 0.5 or newer and refuses to start with an older one; Ubuntu 24.04
ships 0.4, so run the tests there inside `nix develop`. The tests also need
Python 3, `nm` and `ps`:

```sh
sudo pacman -S --needed wireplumber python binutils    # Arch Linux
sudo dnf install pipewire pipewire-utils wireplumber python3 binutils procps-ng    # Fedora
sudo apt-get install --no-install-recommends pipewire pipewire-bin wireplumber python3 binutils procps    # Debian
```

```sh
scripts/headless-audio.sh zig build test
```

## Runtime requirements

- A PipeWire audio server for playback. On NixOS, set
  `services.pipewire.enable = true;`.
- A Secret Service provider, such as GNOME Keyring, for the ListenBrainz token
  and AcoustID user key `orca-gtk` stores. `orca-cli` reads them from
  `ORCA_LISTENBRAINZ_TOKEN` and `ORCA_ACOUSTID_USER_KEY`.
- With the Nix package on a distribution other than NixOS, including
  `nix run github:evanriley/orca#orca-gtk`, `orca-gtk` may need
  [nixGL](https://github.com/nix-community/nixGL) to find the host's OpenGL
  drivers.

## Usage

`orca-gtk` opens from the desktop entry, or from a shell:

```sh
orca-gtk
ORCA_LIBRARY=/path/to/library.db orca-gtk    # another Library, for this run only
```

`orca-cli` drives the whole engine from a shell. Each command takes the Library
database path first:

```sh
orca-cli scan ~/orca.db ~/Music
orca-cli stats ~/orca.db
orca-cli health ~/orca.db --summary
orca-cli devices
orca-cli play-tracks ~/orca.db 1,2,3 --device=ID
```

[The CLI reference](docs/cli.md) lists every command, its options and its
output.

## Embedding

- [The Zig API](docs/api.md) covers adding `liborca` as a Zig package, the
  runtime, ownership and shutdown, and what stays stable between releases.
- [examples/embed](examples/embed) is a complete Zig project that lists a
  Library's tracks through that API.
- [The C ABI](docs/frontends.md#c-abi) covers `orca.h` for other languages,
  including linking through pkg-config.

## Documentation

- [Architecture](docs/architecture.md): subsystems, dependencies and licences,
  supported formats.
- [Roadmap](docs/roadmap.md): feature status, release gates and releases.
- [Privacy](docs/privacy.md): what each outside service receives.
- [CLI](docs/cli.md), [Zig API](docs/api.md) and
  [C ABI and frontends](docs/frontends.md).
- Subsystems: [audio engine](docs/audio-engine.md),
  [control plane and jobs](docs/control-plane.md),
  [database](docs/database.md), [storage and scanning](docs/storage.md),
  [metadata and file mutation](docs/metadata.md),
  [providers](docs/providers.md) and [analysis](docs/analysis.md).

## Contributing and security

[CONTRIBUTING.md](CONTRIBUTING.md) covers the development environment, the
checks a change must pass and the licence boundary. Report vulnerabilities as
[SECURITY.md](SECURITY.md) describes.

## License

Orca is licensed under the [Mozilla Public License 2.0](LICENSE). Applications
under any licence may embed `liborca`; changes to Orca's own files are shared
under the same terms.

`liborca` compiles in Apple's ALAC decoder and Ittiam's libxaac (Apache-2.0),
Chromaprint (MIT) with KissFFT (BSD-3-Clause), minimp3 (CC0) and the reference
QOA decoder (MIT). `zig build` installs their licence and notice files under
`share/doc/orca/licenses`; distribute that directory with any binary. The
system libraries Orca links are distributed under their own licences. The
fonts `orca-gtk` bundles use the SIL Open Font License, installed beside them.

## Resources

- [MusicBrainz](https://musicbrainz.org) and the
  [Cover Art Archive](https://coverartarchive.org): release metadata and
  covers.
- [AcoustID](https://acoustid.org) and
  [Chromaprint](https://acoustid.org/chromaprint): audio fingerprints.
- [ListenBrainz](https://listenbrainz.org): scrobbling and listening data.
- [LRCLIB](https://lrclib.net): synchronized lyrics.
- [Wikidata](https://www.wikidata.org),
  [Wikimedia Commons](https://commons.wikimedia.org) and
  [Wikipedia](https://www.wikipedia.org): artist information.
