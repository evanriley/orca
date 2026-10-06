# Changelog

## Unreleased

### Added

- A binary cache at [orca.cachix.org](https://orca.cachix.org) for the flake's
  package, named in the flake's `nixConfig` and filled by CI from `main`.

### Changed

- The application icon is a white "O" on the window's dark background.

### Fixed

- An AIFF whose COMM frame count exceeds its SSND data plays the frames
  present and is reported as `corrupt_audio` by analysis; an AIFF with no SSND
  chunk fails to open instead of decoding as an empty track.
- An 8-bit AIFF reports its samples as signed 8-bit (`signed_8`,
  `ORCA_SAMPLE_FORMAT_SIGNED_8`), not unsigned.
- A WAV whose data chunk ends inside a frame is reported as `corrupt_audio` by
  analysis.
- FLAC frame errors, a short final block and an MD5 mismatch are reported as
  `corrupt_audio` by analysis while playback still tolerates them.
- A Zone attached, detached, moved or destroyed while its Player's engine
  thread starts no longer returns before that engine adopts the change.
- A release ID tag alone no longer counts as a confident match. Until Orca
  reads the release a tag names and places the Track on it, the album is in
  Needs Review with no percentage, its candidate titled from the album tag, and
  Matches and Match Review say it is not yet read from MusicBrainz. Find
  Matches reads every release the tags name, including on partially tagged
  albums, and reads a release ID tag written in uppercase as the lowercase
  MusicBrainz ID. `ReleaseCandidate.confidence` is optional and
  `orca_release_match_view_v2` gains `candidate_unread`.
- A file with more than two channels is refused for playback with
  `UnsupportedChannelCount` before any output opens, including as the gapless
  next entry, and is not measured by analysis, which raises `missing_analysis`
  naming the channel count instead of storing a loudness from unweighted
  surround channels. Results a Library already stored for such a file are
  ignored for album gain and discarded by the next analysis pass.
- A search no longer reports "Found a match to review" when its proposals form
  no release candidate and the album stays Unmatched. A search of one album or
  Track names the album and the Matches tab it is ready to review in, with a
  Review button that opens it, or says "No album match found"; Find Matches
  names how many albums are ready to review. `MatchStats` gains
  `releases_to_review` (`orca_job_match_stats_v2`), and
  `libraryReleaseMatchBucket` (`orca_library_release_match_bucket`) gives one
  Release's bucket.
- Next and previous open the target entry before moving the queue. An entry
  that fails to open is stepped over, at most 8 in a row; when none opens, the
  open error is returned and the playing entry keeps playing with now-playing
  and the queue history unchanged. A queue jump to an entry that fails to open
  changes nothing.
- An output that stops consuming while its Player plays leaves the shared
  decoder after 64 engine passes, and after 2 s is lost and goes through the
  same bounded recovery as any other lost output.
- A tag write no longer replaces a read-only file. `planTagWrite` skips it
  with `file_read_only` (`ORCA_TAG_WRITE_SKIP_FILE_READ_ONLY`); a file made
  read-only after planning fails the write with `FileReadOnly`, reported as
  `file_read_only` (`ORCA_TAG_WRITE_FAILURE_FILE_READ_ONLY`), before any file
  changes; and undo refuses, changing nothing, while a file to restore is
  read-only. A rewritten or restored file keeps its exact permission bits
  instead of losing those the umask removes, such as group write.

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
