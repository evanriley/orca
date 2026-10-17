# Orca

Orca is a local-files-first music player and library-maintenance application
for Linux. Its engine, `liborca`, is a Zig library that owns the music library,
playback, metadata, analysis and online identification; `orca-gtk` and
`orca-cli` are thin clients of it, and other applications can embed it through
its Zig API or C ABI.

Orca is pre-1.0 ([1.0 readiness](https://b.maybemaybe.lol/672513d)). A
release before 1.0 bumps the minor version when it breaks the Zig API, the
C ABI or the Library schema. Orca builds and plays on x86_64 Linux with
PipeWire; other platforms are on the roadmap.

Orca is a personal project, source available under the [MPL-2.0](LICENSE). It
takes no outside contributions. The
[GitHub repository](https://github.com/evanriley/orca) is a read-only mirror of
`orca/` in the
[`maybe` monorepo](https://code.maybemaybe.lol/maybe.git/tree/orca) and takes
no issues or pull requests. Report a serious problem, such as a security hole
or data loss, by email to
[evan@evanriley.com](mailto:evan@evanriley.com).

Orca changes music files only through a plan the user approves, journaled so
that an interrupted write is recovered and a finished one can be undone. It
contacts outside services only for features the user starts or switches on,
and sends no telemetry; [Privacy](docs/privacy.md) lists each service and what
it receives.

## Features

- **Library:** incremental, resumable scanning; files bound to their volume,
  so an unmounted drive's files are never marked missing; folder watching;
  browsing by artist, album, track, genre and folder, with one search.
- **Formats:** FLAC, MP3, AAC and ALAC in MP4, AAC in ADTS, Ogg Opus, Ogg
  Vorbis, WAV, AIFF and AIFC, and QOA, with gapless trimming.
- **Tags:** reading ID3, Vorbis comments, MP4 atoms and WAV `INFO`; writing
  FLAC, MP3 and ADTS tags from an approved plan with undo.
- **Playback:** gapless output through PipeWire at each source's own sample
  rate, ReplayGain from Orca's own analysis, a ten-band and a parametric
  equalizer, crossfeed, and a signal path that says whether playback is
  bit-perfect.
- **Listening:** local play history, star ratings, love and hate, playlists
  with M3U import and export, smart playlists, plain and synced lyrics, and
  opt-in ListenBrainz scrobbling.
- **Discovery:** Home, Daily Mixes, and Library Radio from any track, album,
  artist, genre or decade, scored from local data with a reason for each pick;
  tempo, key, energy and, with a model installed, sound similarity.
- **Identification:** MusicBrainz and AcoustID matching that proposes changes
  for review, Cover Art Archive covers, AcoustID verification and opt-in
  submission.
- **Analysis:** loudness, peaks, clipping, silence, waveforms, fingerprints and
  duplicate detection on a thread pool, with Health issues that each name
  their fix.
- **Clients:** `orca-gtk`, a libadwaita player; `orca-cli`; and `liborca` as a
  Zig API and a C ABI (`liborca.so.0`, `orca.pc`).
- **Platforms:** x86_64 Linux with PipeWire. `liborca` builds for aarch64
  macOS without audio output or folder watching.

[The roadmap](docs/roadmap.md) lists planned work and ideas; defects and
smaller enhancements are [git-bug issues](https://b.maybemaybe.lol).

## Install

```sh
nix run github:evanriley/orca
nix run github:evanriley/orca#orca-cli -- --version
```

[Install](docs/install.md) covers NixOS and Home Manager modules, the binary
cache, the runtime requirements and building from source. Radio and Daily
Mixes can rank by sound with an audio-embedding model; see
[Sound similarity](docs/sound-similarity.md).

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
- [The C ABI](docs/c-abi.md) covers `orca.h` for other languages, including
  linking through pkg-config.

## Documentation

- [Install](docs/install.md): Nix, building from source and runtime
  requirements.
- [Sound similarity](docs/sound-similarity.md): the audio-embedding models.
- [The Library](docs/library.md): the database file, upgrades, roots and
  tag writing.
- [CLI](docs/cli.md): every `orca-cli` command.
- [Privacy](docs/privacy.md): what each outside service receives.
- [Zig API](docs/api.md) and [C ABI](docs/c-abi.md): embedding `liborca`.
- [Architecture](docs/architecture.md): subsystems, dependencies and licences,
  supported formats.
- [Roadmap](docs/roadmap.md): planned work, ideas and what is not planned.
- [Releasing](docs/releasing.md): versioning and the release procedure.

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
