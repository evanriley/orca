# Changelog

## 0.1.0 - 2026-10-06

The first public release. Ships Library schema version 1.
[What works today](docs/roadmap.md#works-today) has the full list.

### Added

- `liborca`, the engine: a Zig library with a public Zig API
  ([api.md](docs/api.md)) and a C ABI (`orca.h`, `liborca.so.0`, `orca.pc`;
  [frontends.md](docs/frontends.md)).
- `orca-cli`, a command-line client of the whole engine
  ([cli.md](docs/cli.md)).
- `orca-gtk`, a GTK4 and libadwaita player for Linux.
- A Library in SQLite: incremental, resumable scanning of music folders,
  identity that survives moves and unmounted drives, filesystem watching,
  folder browsing, search, genres, stats and Health issues with an action
  for each.
- Decoding of FLAC, MP3, ALAC and AAC in MP4, ADTS AAC, Ogg Opus, Ogg Vorbis,
  WAV, AIFF and QOA, and reading of their tags and cover art.
- Gapless PipeWire playback at each source's sample rate, with a queue,
  ReplayGain, a graphic and a parametric equalizer, crossfeed, output device
  selection and a signal-path report.
- Tag writes to FLAC, MP3 and ADTS through an approved, journaled plan, with
  undo and crash recovery.
- Analysis: loudness, peaks, silence, waveforms, Chromaprint fingerprints and
  duplicate detection.
- Identification: MusicBrainz and AcoustID matching with review, Match Album
  and Match Review, verification and corrections, re-identification, Cover
  Art Archive covers and AcoustID submission.
- Listening: a local play history, ratings, love for songs, albums and
  artists, playlists and smart playlists with M3U import and export, lyrics
  from tags, `.lrc` files and LRCLIB, and ListenBrainz scrobbling and Now
  Playing.
- Artist and release info from MusicBrainz, Wikidata, Wikimedia Commons,
  Wikipedia and ListenBrainz.
- Builds with Zig 0.17 against system libraries found through pkg-config
  (`-Dgtk=false` leaves out `orca-gtk`), and a Nix flake for x86_64 Linux
  with a package, a NixOS module, a Home Manager module and an overlay.
