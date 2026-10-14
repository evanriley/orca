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
| 2 | Stable Zig API, C ABI and Library schema (1.0) | ⚠️ [1.0 gates](docs/roadmap.md#before-10) open |
| 3 | Library radio and mixes | ✅ 0.3.0 |
| 4 | Tag writing for M4A, Ogg, WAV and AIFF | ❌ |
| 5 | Full multichannel playback | ❌ |
| 6 | Fixed output rate with a band-limited resampler | ❌ |
| 7 | Crossfade, and convolution DSP for room correction | ❌ |
| 8 | Synchronized multi-zone playback | ❌ |
| 9 | Conversion and encoding | ❌ |
| 10 | Secure CD ripping | ❌ |
| 11 | Terminal client, macOS and Windows apps | ❌ |

[The roadmap](docs/roadmap.md) lists releases, what works, known issues, what
is next, what is planned, ideas and what is not planned.

## Install with Nix

The flake packages Orca for `x86_64-linux`. The package installs `orca-gtk`,
`orca-cli`, static and shared `liborca`, `include/orca/orca.h`,
`lib/pkgconfig/orca.pc`, the desktop entry, the icons and the
[sound similarity model](#sound-similarity-model).

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
machine, which speeds analysis by up to 15 % and produces a binary that may
not run on another CPU. The install holds:

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

## Sound similarity model

Radio and Daily Mixes rank by how tracks sound when Orca has an
audio-embedding model. Without one they rank by tempo, key and energy instead,
and nothing else changes. Orca downloads a model only when asked to.

| Model | File | Size | Values per track | Licence of the weights |
| --- | --- | --- | --- | --- |
| Standard (default) | `clap_audio_int8.onnx` | 32.6 MB | 512 | Apache-2.0 |
| Large | `maest_audio_int8.onnx` | 80.4 MB | 768 | CC BY-NC-SA 4.0 |

Large tells genres and artists apart better than Standard and takes longer to
analyze. The Nix package includes Standard only. For any other build, or to use
Large, Settings › Listening › Sound Similarity in `orca-gtk` has a Model row
that picks Standard or Large; picking a model that is not installed offers
Download, which fetches it from `github.com` to
`$XDG_DATA_HOME/orca/models/`. `orca-cli` does the same, with `--model` naming
`clap_htsat_unfused` (the default) or `discogs_maest`. Either installs the file
only when its size and SHA-256 are the ones the build expects:

```sh
models="${XDG_DATA_HOME:-$HOME/.local/share}/orca/models"
orca-cli download-embedding-model "$models/clap_audio_int8.onnx"
orca-cli download-embedding-model "$models/maest_audio_int8.onnx" \
  --model discogs_maest
```

`curl` does the same without a build of Orca. Standard:

```sh
models="${XDG_DATA_HOME:-$HOME/.local/share}/orca/models"
mkdir -p "$models"
curl -L -o "$models/clap_audio_int8.onnx" \
  https://github.com/evanriley/orca/releases/download/model-clap-int8-1/clap_audio_int8.onnx
echo "12d3e2c1593ba111df6103feac2f3ce4f4e85e5efc2ad927ac16a8402e7b3c36  $models/clap_audio_int8.onnx" | sha256sum -c
```

Large:

```sh
models="${XDG_DATA_HOME:-$HOME/.local/share}/orca/models"
mkdir -p "$models"
curl -L -o "$models/maest_audio_int8.onnx" \
  https://github.com/evanriley/orca/releases/download/model-maest-int8-1/maest_audio_int8.onnx
echo "fcdf35e3b8737cb0853bb83cadd7a62885f70f1afe30cde3f185e61eb06d843e  $models/maest_audio_int8.onnx" | sha256sum -c
```

Orca recognises a model file by its size and SHA-256, so the file in use
decides the model. `ORCA_EMBEDDING_MODEL=PATH` names a file in `orca-gtk`
instead; `orca-cli` takes `--embedding-model PATH` or the same variable for
`analyze-library`, `similar`, `radio`, `home` and `mixes`. The Nix package
keeps its Standard file at `share/orca/models/clap_audio_int8.onnx`, where
`orca-gtk` finds it; its `orca-cli` is given the path like any other. Each
model's embeddings are stored separately:
after a switch, analyzing the Library once measures each track with the new
model, and switching back needs no analysis. Embeddings of different models
are never compared. A build with `-Dembeddings=false` uses neither model.

Standard is Orca's 8-bit export of the audio part of
[`laion/clap-htsat-unfused`](https://huggingface.co/laion/clap-htsat-unfused),
whose weights are published as Apache-2.0; `scripts/embedding/export_model.py`
writes it. Large is Orca's 8-bit export of
[`mtg-upf/discogs-maest-30s-pw-129e`](https://huggingface.co/mtg-upf/discogs-maest-30s-pw-129e)
by the Music Technology Group, Universitat Pompeu Fabra, licensed
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
(non-commercial, attribution, share-alike); `scripts/embedding/export_maest.py`
writes it. Large is only ever downloaded, never bundled.

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
- [Roadmap](docs/roadmap.md): releases, feature status and the 1.0 gates.
- [Releasing](docs/releasing.md): versioning and the release procedure.
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
checks a change must pass and the dependency policy. Report vulnerabilities as
[SECURITY.md](SECURITY.md) describes.

## License

Orca is licensed under the [Mozilla Public License 2.0](LICENSE). Applications
under any licence may embed `liborca`; changes to Orca's own files are shared
under the same terms.

Orca's dependencies are chosen on technical merit, and GPL, LGPL and AGPL
dependencies are allowed; a binary that contains one carries that licence's
terms. `liborca` compiles in Apple's ALAC decoder and Ittiam's libxaac
(Apache-2.0), Chromaprint (MIT) with KissFFT (BSD-3-Clause) and the reference
QOA decoder (MIT). `zig build` installs their licence and notice files under
`share/doc/orca/licenses`; distribute that directory with any binary. The
system libraries Orca links, mpg123 (LGPL-2.1) among them, are distributed
under their own licences. The fonts `orca-gtk` bundles use the SIL Open Font
License, installed beside them.

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
