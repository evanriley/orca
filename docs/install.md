# Install

Orca installs from its Nix flake or builds from source. Both produce
`orca-gtk`, `orca-cli`, `liborca` and `orca.h`.

## Install with Nix

The flake packages Orca for `x86_64-linux`. The package installs `orca-gtk`,
`orca-cli`, static and shared `liborca`, `include/orca/orca.h`,
`lib/pkgconfig/orca.pc`, the desktop entry, the icons and the
[sound similarity model](sound-similarity.md).

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

CI runs the Debian 13 and Fedora 43 steps below in clean containers on every
code change. The Arch Linux and Ubuntu 24.04 steps are not run by CI.

### Requirements

- Zig 0.17.0. Zig compiles the bundled C and C++ sources (the codec shims,
  ALAC, libxaac and Chromaprint), so no separate C or C++ compiler is needed.
- pkg-config.
- For `liborca` and `orca-cli`: development files for SQLite, libFLAC, libogg,
  libvorbis, Opus, opusfile, mpg123 1.32 or newer, libsamplerate, PipeWire
  and ONNX Runtime 1.20 or newer.
- For `orca-gtk`: development files for GTK 4.18 or newer, libadwaita 1.8 or
  newer, Pango 1.56 or newer and libsecret.

Debian 13 ships libadwaita 1.7, and Ubuntu 24.04 ships GTK 4.14, libadwaita
1.5 and Pango 1.52. Both build `liborca` and `orca-cli`; build them with
`-Dgtk=false`, which leaves `orca-gtk` out.

Ubuntu 24.04 has no ONNX Runtime package. Build it with `-Dembeddings=false`,
which builds `liborca` without audio embeddings and without ONNX Runtime.

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
sudo pacman -S --needed curl pkgconf sqlite flac libogg libvorbis opus opusfile mpg123 libsamplerate onnxruntime-cpu pipewire gtk4 libadwaita libsecret
```

Fedora:

```sh
sudo dnf install curl xz pkgconf-pkg-config sqlite-devel flac-devel libogg-devel libvorbis-devel opus-devel opusfile-devel mpg123-devel libsamplerate-devel onnxruntime-devel pipewire-devel gtk4-devel libadwaita-devel libsecret-devel
```

Debian and Ubuntu:

```sh
sudo apt-get install --no-install-recommends ca-certificates curl xz-utils pkg-config libsqlite3-dev libflac-dev libogg-dev libvorbis-dev libopus-dev libopusfile-dev libmpg123-dev libsamplerate0-dev libonnxruntime-dev libpipewire-0.3-dev
```

Add `libgtk-4-dev libadwaita-1-dev libsecret-1-dev` on a release whose GTK and
libadwaita meet the requirements above. Leave `libonnxruntime-dev` out on
Ubuntu 24.04.

### Build and install

```sh
zig build -Doptimize=ReleaseSafe -p ~/.local
```

`-p` sets the install prefix. Add `-Dgtk=false` to build without `orca-gtk`
or `-Dembeddings=false` to build without ONNX Runtime, and pass the same
options to `zig build test`. The build targets the baseline CPU of the
architecture; `-Dcpu=native` uses every instruction set of the building
machine, which speeds analysis and produces a binary that may not run on
another CPU. The install holds:

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

The tests that run the embedding models are skipped unless
`-Dembedding-model=PATH` names the `clap_audio_int8.onnx` that
`scripts/embedding/export_model.py` writes and `-Dmaest-embedding-model=PATH`
names the `maest_audio_int8.onnx` that `scripts/embedding/export_maest.py`
writes.

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
