# Roadmap

What Orca does today, what must hold before 1.0, and what is deferred.
"Works" means reachable from `orca-cli` or `orca-gtk` through the public
runtime path, per the rule in [architecture.md](architecture.md).

## Status

`orca-gtk` is a daily-usable player on Linux: a designed libadwaita frontend,
gapless playback between entries of one format, output at each source's sample
rate, live equalizer and crossfeed, tag editing with undo, track details,
lyrics that follow playback, a local play history, star ratings, album and
artist love, playlists with M3U import and export, smart playlists, a command
palette, browsing by genre and by folder, artist and release info,
ListenBrainz scrobbling, MusicBrainz and AcoustID matching with review,
AcoustID submission and verification, actionable Health, idle maintenance, and
watching of the music folders, so new, changed and removed files show up
without a rescan. `liborca` builds for aarch64
macOS; there is no macOS app, audio output or filesystem watcher.

Features are frozen until 1.0. The work is the [release gates](#release-gates)
below.

`liborca` is usable as a library for others: the SONAME `liborca.so.0`
versioned by `ORCA_ABI_VERSION`, `orca_version`, an installed `orca.pc`,
exports limited to the functions `orca.h` declares, a last-error message for C
callers, a stability statement in `orca.h` and [api.md](api.md), a provider
identity the host must supply, and a wake callback with a pump timeout, which
`orca-gtk` sleeps on instead of polling. `scripts/check-abi-coverage.sh`
names each `Runtime` method the C ABI does not reach and why.

## Works today

### Library

- Incremental, restart-resumable scanning of library roots. Unchanged files
  are skipped by path and storage identity; commits are bounded and
  cancellable.
- File and Location identity keyed by stable volume identifiers (filesystem
  UUID, including device-mapper volumes, or a persisted volume marker).
- Projection into artists, releases, recordings and tracks, with bounded
  browse pages by artist, release, track and genre. Releases filter by
  format, review state, year, artwork and type, and Tracks by year, format,
  sample rate and parental advisory, each with an exact count.
- One search over Artists, Releases, Tracks, Playlists and genres, each word
  a word prefix with no query syntax, Tracks ranked by where the words
  match. Reachable through `Runtime.librarySearch`, `orca_library_search`,
  `orca-cli search` and the command palette in `orca-gtk`.
- Genres from file tags, with spellings folded together and user genres that
  outrank tags, with Track, Release and Artist counts kept in
  `genre_totals`. Reachable through `orca-cli genres` and `genre`, tag write
  for FLAC, MP3 and ADTS, and the Genres page in `orca-gtk`.
- Browsing by folder: a root's subfolders with totals counted through
  everything below, and its files, and playing a folder recursively.
  Reachable through `libraryFolderPage`, `orca_library_query_folder`,
  `orca-cli folders` and `play-folder`, and the Folders page in `orca-gtk`.
- Library stats (counts, bytes, duration, last scan and analysis) and
  Health totals per kind. Reachable through `libraryStats`,
  `orca_library_stats`, `orca-cli stats` and `health --summary`, and the
  Health page in `orca-gtk`.
- Artist and release info, fetched on a job and kept in the Library: an
  Artist's photo, biography, years active, links, listeners and related
  artists, a Release's description, and MusicBrainz genres for Tracks with
  none, from MusicBrainz, Wikidata, Wikimedia Commons, Wikipedia and
  ListenBrainz. Reachable through `orca-cli artist-info`, `release-info`,
  `related` and `genre-fill`, the C ABI, and the Artist and album pages in
  `orca-gtk`. See [providers.md](providers.md).
- Property backfill for rows scanned before audio properties were recorded.
- Folder-scoped reconciles, and filesystem watching on Linux (inotify) that
  reconciles what changes under each root, reconciles roots the watch limit
  left partly unwatched every 15 minutes, and tries unavailable roots again
  on the same interval. Reachable through `orca-cli reconcile` and `watch`,
  the `orca-gtk` preference "Watch folders for changes" (on by default), and
  the C ABI.
- No scan or reconcile walks a root whose path lies on another volume
  than the one recorded, so an unmounted drive's files are never marked
  missing.
- Byte-identical copies share one File until one of them changes; a changed
  copy becomes a File of its own, keeping Orca's values and locks, and hard
  links stay one File.
- Embedded cover art extraction.

### Formats

- Decoding: FLAC (libFLAC), MP3 (vendored minimp3 with Xing/LAME gapless
  trimming), ALAC and AAC in MP4 (Apple's reference decoder and libxaac, with
  edit-list gapless trimming), raw AAC in ADTS, Ogg Opus (libopusfile), Ogg
  Vorbis (libvorbisfile), WAV including `WAVE_FORMAT_EXTENSIBLE`, AIFF and
  uncompressed AIFC, QOA (the reference decoder).
- Tags and cover art: ID3v1 and ID3v2 (MP3, ADTS, and the ID3 chunk of WAV and
  AIFF), WAV `LIST`/`INFO`, Vorbis comments and pictures in FLAC and Ogg, and
  iTunes atoms in MP4.

### Playback

- A runtime-owned Player and Zone object graph with PipeWire output.
- A gapless queue with repeat, shuffle, next, previous, seek, pause and
  volume. A format change between entries reopens the output at the new
  format, and each stream asks PipeWire for its source's sample rate; the
  signal path reports the rate the device actually runs at.
- Per-entry ReplayGain from analysis results, by track or by album. An album
  figure is worked out when an entry opens from the Release's stored
  measurements, and a Release that is not fully measured plays at track
  gain.
- A ten-band equalizer with presets, stereo crossfeed, and a signal-path
  report of the source, each processing stage, the output stream and whether
  the path could be bit-perfect up to PipeWire: exact widening of a source of
  24 bits or fewer to float is, a lossy source, a 32-bit integer or 64-bit
  float source and any gain that is not exactly 1 are not
  (`orca-cli play-tracks --eq --crossfeed`).
- A parametric equalizer of up to 16 peak, shelf, pass and notch filters and
  a preamp, with EqualizerAPO import and export, through liborca, the C ABI
  and `orca-cli` (`play-tracks --peq`, `peq-check`, `peq-response`).
- Output device selection, with each device's kind (USB, PCI, Bluetooth,
  HDMI or virtual) and the signal path's block size.
- Queue history, moving a queue entry and saving the queue as a playlist,
  through `orca-cli play-tracks`, the C ABI and the Queue page in
  `orca-gtk`.
- Tag write-back for FLAC, MP3 and ADTS from an approved plan, with undo.
  One process at a time owns a Library's mutation journal through a lock
  file; an undo interrupted by a crash is finished by the next open, and
  recovery never touches another process's write in progress. A read-only
  file is never written or restored over, and a rewritten file keeps its
  permission bits.
- Track details: format, file, loudness, tags and MusicBrainz recording ID
  with its source for one Track (`orca-cli track`), and the inspector in
  `orca-gtk`.

### Listening

- A local play history: every listen (a track of 30 s or more, heard for half
  its length or four minutes) is recorded in the Library and kept forever.
  Play count, counted per recording, and last play appear in `orca-cli
  track`, in the `orca-gtk` inspector and as sortable Tracks columns.
  `orca-cli play-tracks` records listens too.
- ListenBrainz scrobbling, off until enabled: a leased, restart-safe queue, a
  gateway that identifies Orca, spaces requests and honours `429`, and a token
  held in the Secret Service (`orca-gtk` Settings > Listening) or read from
  `ORCA_LISTENBRAINZ_TOKEN` (`orca-cli scrobble`). See
  [providers.md](providers.md).
- Provider blocks, backoffs, quota windows and request spacing for
  ListenBrainz, MusicBrainz and AcoustID are stored in the Library, so they
  persist across restarts and bind every process using it. A per-service
  lease lets one request at a time talk to each service; other jobs and
  processes wait their turn and get `ProviderBusy` without sending only when
  the service stays held past their wait. See
  [providers.md](providers.md#rules-toward-providers).
- Love and hate for songs, kept in the Library per recording and sent to
  ListenBrainz while scrobbling for recordings with a MusicBrainz recording
  ID, from the file's tags or an accepted match. `orca-gtk` has a heart in the
  player bar, a heart button on every song row and context menu entries, and
  its inspector says when a love cannot sync; `orca-cli feedback` sets
  it.
- Love for albums, kept in the Library per Release and never sent, since
  ListenBrainz feedback takes recordings only: `orca-cli love-release` and
  `releases --loved`, and in `orca-gtk` a heart on the album page, Love Album
  in album menus, and a Loved page of loved songs, albums and artists.
- Love for artists, kept in the Library and never sent: `orca-cli
  love-artist`, `artists --loved` and `--sort loved`, and a love button on
  the Artist page in `orca-gtk`.
- Now Playing, off until enabled: the playing track is announced to
  ListenBrainz after 10 s (`orca-gtk` Settings > Listening).
- Star ratings, kept in the Library per recording: `orca-cli rate`, a sort
  by rating, and stars on every song row, in the inspector and in song
  menus in `orca-gtk`.
- Playlists of up to 10,000 songs, kept per recording so edits do not break
  them, with M3U and M3U8 import and export, a description, a pin, a love
  and up to eight tags, and smart playlists whose version 1 rules JSON lists
  the Tracks it matches each time it is read. Reachable through the
  `orca-cli playlist*` and `smart-playlist-*` commands and `play-tracks
  --playlist`, and in `orca-gtk` through the Playlists page, playlist pages,
  the Smart Playlist editor and Add to Playlist on song and album menus. See
  [cli.md](cli.md#playlists-and-ratings).
- Lyrics, plain and synced, from the file's tags (ID3v2 `USLT` and `SYLT`,
  Vorbis comment `LYRICS` and `UNSYNCEDLYRICS`, MP4 `©lyr`) and a sidecar
  `.lrc`, then, opt-in, from LRCLIB by title, artist, album and duration;
  fetched lyrics are cached in the Library and never written to a file.
  `orca-cli lyrics` and `play-tracks --lyrics`, and in `orca-gtk` the
  inspector's Lyrics mode and the lines under Now Playing's transport, which
  highlight the line being heard, with fetching off until enabled (Settings
  > Listening).

### Identification

- MusicBrainz matching: a cancellable job searches MusicBrainz for every Track
  whose file has no recording ID, one request a second with answers cached for
  30 days, and stores reviewable proposals. Accepting one records the recording
  ID in the Library, so loves and listens can be sent under it, and a tag write
  stores it in files that have none; bulk acceptance of confident matches is an
  explicit action. Reachable through `orca-cli match`, `matches`,
  `accept-match`, `dismiss-match` and `accept-matches`, and in `orca-gtk`
  through the Matches page, the inspector's MusicBrainz section (with a
  single-song Find Match) and the confidence threshold in Settings. See
  [providers.md](providers.md#matching).
- AcoustID matching: the same job fingerprints each file with Chromaprint and
  looks up to 20 fingerprints at a time on AcoustID, merging both services'
  candidates into one proposal per recording; each service is asked once per
  file. Reachable through `orca-cli match` (`--no-fingerprints` leaves it
  out), `matches` and `fingerprint`, and in `orca-gtk` through Find Matches
  (Settings > Library > Match by audio fingerprint turns it off), with
  each proposal's source and AcoustID score on the Matches page and in the
  inspector.
- Match Album and cover art: a matching job scoped to one Release searches
  its Tracks, accepts its confident matches, and fetches its front cover from
  the Cover Art Archive when none of its files carries one, keeping the cover
  in the Library. Reachable through `orca-cli match --release=ID
  --accept-min-score=SCORE --cover-art`, `cover-art` and `artwork`, and in
  `orca-gtk` through Match Album and Fetch Cover Art on an album's menu. See
  [providers.md](providers.md#cover-art-archive).
- Applying matches: an accepted match stores its title and artist on every
  file of the Track, and once every Track of a Release names one MusicBrainz
  release, its album, album artist, date, disc and track numbers and
  release, release-group, release-track and album-artist IDs, as unlocked
  provider values that tag writes store where the files have none. Matching
  looks up the best release of each search, and Match Album points the
  album's matches at the release most of them list. Reachable through
  `orca-cli accept-match`, `accept-matches`, `apply-release`, `matches`,
  `track` and `match --release=ID`, and in `orca-gtk` through the Matches
  page and the inspector. See
  [metadata.md](metadata.md#release-consensus).
- Verification: a matching job in `verify` mode checks each identified
  file's recording ID against what AcoustID hears in its fingerprint, one
  Release at a time, and keeps the outcome per file until its bytes or its
  recording ID change. A file that disagrees is proposed what AcoustID
  hears; when the Release's tagged release lists those recordings, its
  files' corrections form one album correction with their positions, which
  is accepted or dismissed whole. An accepted correction is stored locked,
  so it outranks the file's tag and a tag write stores it. Reachable through
  `orca-cli verify`, `corrections`, `accept-correction`,
  `dismiss-correction` and `track`, and in `orca-gtk` through Verify and
  Verify Album on song and album menus, the Matches page's Corrections and
  the inspector. See [providers.md](providers.md#verification) and
  [metadata.md](metadata.md#corrections).
- Re-identify: a matching job in `reidentify` mode searches one Track or
  Release again, ignoring the recording ID in effect and earlier searches.
  Reachable through `orca-cli match --track=ID|--release=ID --reidentify`
  and Re-identify on song and album menus in `orca-gtk`.
- Match Album's release vote breaks a tie the files' tags leave open for an
  official release, then the one with as many tracks as the album, then the
  earliest date.
- AcoustID submission: `orca-cli submit-acoustid` sends the fingerprints of
  files whose recording ID came from an edit or from a match accepted one at
  a time that AcoustID did not propose, once per file and ID, with the user
  key from `ORCA_ACOUSTID_USER_KEY`; `orca-gtk` sends them from Settings >
  Library > Identification, with the key saved there: Submit Now, or by
  itself after each confirmation and every 15 minutes with Contribute to
  AcoustID on, which is off by default. The command palette's Submit to
  AcoustID does the same as Submit Now. See
  [providers.md](providers.md#acoustid-submission).
- Provider sources: a fixed list of the services Orca takes data from, each
  with its URL, what it supplies and its licence, so every frontend credits
  the same sources. Reachable through `Runtime.providerSources`,
  `orca_provider_sources` and `orca-cli sources`.

### Analysis

- Loudness and ReplayGain, peaks, silence, waveform and a temporal
  fingerprint, cached by algorithm version and parameters.
- AcoustID fingerprints (Chromaprint over libsamplerate), cached per file.
- Library-wide analysis on a pool of threads, taking each file's AcoustID
  fingerprint in the same decode, and indexed duplicate detection, as
  cancellable jobs. Each duplicate gets the strongest verdict that holds:
  the same bytes, the same lossless audio, or matching fingerprints.
- Library health issues, each naming the action that resolves it (match or
  edit tags, fetch cover art, compare duplicates, review a correction, reveal
  the file); a dismissed issue stays hidden until its file's bytes change.
  Reachable through `orca-cli health`, `health-dismiss` and `health-restore`,
  and the Health page in `orca-gtk`. Clipping counts runs of at least three
  samples at full scale.
- Idle maintenance: while no Player plays and no other Job runs, one bounded
  unit at a time verifies an album's recording IDs against AcoustID, within
  the provider rate limits and leases; findings land in Health. Off until
  enabled, through `orca-cli watch --maintenance[=MS]` or Settings >
  Library in `orca-gtk`. See
  [control-plane.md](control-plane.md#idle-maintenance).

### Clients

- `orca-cli`: scan, folder estimates, browse, search, library edits, tag
  write-back with its change history, undo and backup pruning, analysis,
  duplicate groups and merges, metadata consistency issues, Health, artwork
  and cover art candidates, queue playback and resume, `feedback`, ratings,
  playlists and smart playlists with M3U import and export, folders, root
  relocation and availability, genres, lyrics, artist and release info,
  Jobs with pause, history and retry, `scrobble`, MusicBrainz and AcoustID
  matching with release review, fingerprints and AcoustID submission.
- `orca-gtk`: a dark libadwaita window with the bundled Newsreader, Geist and
  Geist Mono fonts. Its sidebar opens Albums, Artists, Tracks, Genres,
  Folders, Loved, Playlists, Now Playing, Queue, Health, Matches and
  Settings. Album, artist and playlist pages, Edit Metadata, Write to Files
  and the Smart Playlist editor open over them. Health leads to Duplicates,
  Audio Problems, Artwork Review and Metadata Issues; Matches to Match
  Review; the activity popover to Activity and Change History. First Run and
  Scan cover an empty library. Settings has eight tabs, among them a
  parametric equalizer editor and the data sources Orca credits. Around the
  pages: a top bar with Back, Forward, a trail and the library search, a
  search overlay and command palette, an inspector with track, lyrics and
  signal path modes, context menus, a player bar with cover art, format,
  output picker and volume, a banner for offline music folders, toasts, a
  shortcuts dialog and MPRIS. It plays, loves and rates, keeps playlists,
  submits listens to ListenBrainz, resumes the queue at launch and opens
  more than one library.
- C ABI (`liborca/orca.h`), exercised end to end by `tests/c_abi_smoke.c`,
  with `liborca.so.0` exporting exactly its functions and `orca.pc` for
  pkg-config: browsing, search, folders, genres and track details, playback
  with queue edits and history, the equalizer, parametric equalizer,
  crossfeed and the signal path, artwork and cover fetches, lyrics, artist
  and release info, provider sources, library stats,
  library edits, tag writes, undo and backup pruning, love and hate, ratings
  and album and artist love, playlists and smart playlists with M3U import and
  export, Health actions, MusicBrainz and AcoustID matching, verification and
  corrections, AcoustID submission, ListenBrainz scrobbling, idle maintenance,
  provider servers and a credential callback for the host's secure storage.
  `tests/c_abi_layout.zig` checks every struct and enum value against the
  Zig side, and `tests/abi/compat.zig` checks `orca.h` against the 0.1.0
  header.

### Builds

- Linux x86_64, and a static `liborca` for aarch64 macOS (`zig build lib
  -Dtarget=aarch64-macos`). `zig build -Dgtk=false` builds without `orca-gtk`
  where GTK 4.18, libadwaita 1.8 or Pango 1.56 is not available.
- CI (`.github/workflows/test.yml`): `zig build test` against a private
  PipeWire and WirePlumber, `zig build fuzz`, `zig fmt --check`, a pinact
  check that every action is pinned to the commit its version comment names,
  the aarch64 macOS cross-build, `nix flake check` (package build, NixOS
  module and the installed tree), `zig build package-check` against the
  fetched Zig package, and a build and test run with the official Zig release
  against the libraries of Debian 13 (with `-Dgtk=false`) and Fedora 43. A
  `required` job fails when any of them fails. A change that touches only
  `docs/`, `orca-design/` or Markdown files skips the test, cross-build,
  package and distribution jobs, and the `nix` job takes the package from the
  cache because its build source excludes them. On pushes to `main`, the `nix`
  job uploads the package to the [orca.cachix.org](https://orca.cachix.org)
  binary cache. Dependabot proposes action updates weekly, a week after their
  release.

## Built but not reachable

These exist with tests, but no client can use them yet. Each needs a runtime
entry point and a client before it counts as working.

- File moves through the journaled `MutationPlan` executor. Tag writes are
  reachable; moves are not.

## Release gates

Each gate states the defect or requirement, the result that must be observable
and how it is checked. A gate closes when its check passes and the entry is
removed.

### Before 1.0

- Compatibility promises for 1.0 are written separately for the Zig API, the
  C ABI and the Library schema. Schema upgrades from 0.1.0 are
  tested. A GTK launch, open, play and close smoke test runs on a private
  display in CI. A release candidate passes an acceptance period with no open
  data-loss, memory-corruption, wrong-song or unintended-output defect.

### Defects to fix before 1.0

Fixed before 1.0. Each fix adds a test that fails without it, or a headless
screenshot for a display-only defect, and removes its entry.

- A FLAC seek past the end of the stream fails as a decode error, while WAV
  clamps to the last frame; the other decoders are unchecked.
- A tag write that fails before it reaches a file, such as when its
  backup directory already exists, records no `TagWriteFailure`, so
  `orca-cli` and `orca-gtk` fall back to a message without a reason.
- `orca-cli` runs every command but `duplicates` and `analyze-library` on an
  arena, so a cold scan holds memory for every file until it exits.
- The scanner skips symbolic links to files without counting them.
- Among duplicate copies of the same format, sample rate, bit depth and
  size, Duplicates suggests keeping the one the scanner found first, which
  depends on the order the filesystem lists the folder.
- A release ID tag that names a release MusicBrainz does not return is
  looked up again on every match run of the Library.
- On a volume with no filesystem UUID, such as NFS, SMB or tmpfs, adding a
  root writes `.orca-volume-id` at the mount point.
- When `orca-gtk` starts on Now Playing, the cover-tinted backdrop is
  sometimes not drawn, and stays missing. The race is likely in
  `updateBackdrop` and `sourcePainted` in `apps/linux/art.zig`.
- On the Match Review page, the Best candidate and confidence columns start
  at a different position on each row. `matchRow` in
  `apps/linux/matches.zig` splits each row's width between two expanding
  boxes, and the width left over depends on that row's action buttons, such
  as Accept or "Review · 1 track needs pairing".
- A file whose fingerprint fails, and a Track without a title or artist that
  MusicBrainz cannot search, are examined again by every matching run. A
  failed fingerprint is decoded again.
- Undecodable files are examined again by every analysis run: a library of
  WavPack or APE files pays two 64 KiB reads per file per run.
- Matching has no offline setting, and `orca-gtk` has none for scrobbling.
  Without a network, matching uses cached answers and stops at the first
  Track it has none for.
- Listens carry `submission_client` but not `media_player`.
- MusicBrainz finds nothing for a Track whose artist tag joins several
  artists with commas, such as "Pa Salieu, Black Sherif"; AcoustID can still
  match it by fingerprint.
- An AcoustID candidate without a title is scored on length and fingerprint
  alone, so for a tagged Track it can rank level with a candidate whose title
  and artist match. Several recording IDs sharing one AcoustID fingerprint
  rank by how closely their artist credit matches the Track's.
- The NixOS and Home Manager modules default `programs.orca.package` to the
  build from Orca's pinned nixpkgs. NixOS loads the host's GPU drivers from
  `/run/opengl-driver` into the app, and those need a glibc at least as new
  as the one they were built against. A system newer than Orca's
  `flake.lock` therefore leaves `orca-gtk` without a Vulkan device, and GTK
  renders in software. To examine: build the default from the consumer's
  `pkgs` when it has `zig_0_17`, and document `inputs.nixpkgs.follows` and
  nixGL for `nix run` outside NixOS.
- Re-identifying a Release turns its pending album correction into
  single-file corrections, which can then be accepted one at a time and
  leave the album's positions half-moved until the rest are accepted.
- In a Release of more than 512 Tracks, verified a page at a time, a file
  that still disagrees is checked again only while the Release has a stale
  file left when its page is reached, though the job's total counted it.
- `zig build pipewire-live-smoke` opens the first device on the user's
  PipeWire server rather than a silent sink.
- A credential store that is unavailable, or a credential too large for the
  C ABI's buffer, stops the listen worker with an error, while AcoustID
  lookups take it as no key (they fall back to the application key) and a
  submission as no user key (`needs_user_key`). Whether AcoustID should fail
  instead is undecided.
- `scripts/headless-gui.sh` reuses a `fixtures/library/design.db` that this
  build cannot open, such as one built before the schema was squashed, so
  every headless GUI run fails to open its library.
- Queue history skips Tracks that left the Library, so history positions
  shift; the queue row menu offers Track actions, such as Play Next, on a
  removed row; and whether a queued Track is always looked up in the Library
  that holds it is unchecked.
- A loudness result stored for a file whose channel count is unknown is used
  for album gain and never checked again, though the file may have more than
  two channels.
- Untested: the AcoustID key read once per job on the submission path, and
  gapless identity at the successor's first frame after a re-seek other than
  a user seek, such as an output reopen.
- Not checked on screen: the Player paused after every output failed, the
  match result toasts and the read-only tag write dialogs in `orca-gtk`.
- A pause resets an output's stall count, so a stuck output can cost the
  other outputs up to 128 ms after resume.
- Recovery that finishes an interrupted undo does not check that the files it
  restores are writable.
- The check for SQLite connections open before the lock replacement is
  installed reads SQLite's memory accounting. It sees nothing when SQLite is
  built without memory statistics, and refuses a host that holds SQLite
  memory with no connection open.

## Releases

Orca follows [Semantic Versioning](https://semver.org). Before 1.0, a
release bumps the minor version when it contains a breaking change to the
Zig API, the C ABI or the Library schema, and the patch version otherwise.
1.0 follows the [Before 1.0](#before-10) gates.

Every change adds its entry to the Unreleased section of `CHANGELOG.md` in
the same commit: features, fixes, refactors, removals and breaking changes
alike.

To release:

1. Rename the Unreleased section of `CHANGELOG.md` to the version and date,
   and state the Library schema version it ships.
2. Set `.version` in `build.zig.zon`.
3. Commit, and tag the commit with a signed, annotated `vX.Y.Z` tag whose
   message is that version's section of `CHANGELOG.md`:

   ```sh
   version=X.Y.Z
   { printf 'Orca %s\n\n' "$version"
     awk -v v="$version" '$1 == "##" { p = ($2 == v); next } p' CHANGELOG.md
   } | git tag -s "v$version" --cleanup=whitespace -F -
   ```

   `--cleanup=whitespace` keeps the `###` headings, which the default
   cleanup removes as comments.
4. Update Orca's application entry on the AcoustID website to the new
   version. Every lookup and submission sends the version as
   `clientversion`, and the registered details should match what the
   service receives.

## Known issues

Small defects that are not yet scheduled:

- On macOS, which has no OFD locks, opening and closing a Library's
  database, `-wal` or `-shm` file from another part of the same process
  drops SQLite's POSIX locks on it. A second Orca process can then
  check-point and delete the WAL under the first, and the first process's
  later writes are lost. Linux uses OFD locks; see
  [database.md](database.md#concurrency).

## Deferred formats

The formats above cover nearly every library. These wait until after 1.0, and
are sniffed or not recognized until then:

- WavPack, Monkey's Audio (APE), TTA and Musepack.
- DSD (DSF and DFF), which also needs DSD-to-PCM conversion or native DSD
  output.
- WMA.
- FLAC in Ogg, Matroska and WebM audio, and FLAC or Opus inside MP4.
- Fixtures for HE-AAC and for the `iTunSMPB` gapless fallback, which are
  implemented but cannot be produced with FFmpeg; they wait for real files.

## Later

- Ratings read from and written to tags (POPM, FMPS_RATING).
- More identification sources: ListenBrainz's `/1/metadata/lookup` would match
  what MusicBrainz and AcoustID miss, but needs the user's token and must share
  the listen worker's gateway.
- Fewer provider requests: cover candidates that learn an image's dimensions
  without downloading it, MusicBrainz recording searches combined across
  tracks, and artist information that overlaps requests to different services.
- Tag writers for the remaining formats. FLAC, MP3 and ADTS are written; M4A,
  Ogg, WAV, AIFF and FLAC with a leading ID3 tag are reported as not writable.
- An optional fixed output rate with a band-limited resampler, for devices
  held at another rate and for gapless playback across sample-rate changes,
  with a Resampler quality setting. Output at the source rate stays the
  default, since only that path can be bit-perfect.
- Full multichannel support. Canonical PCM carries a channel count but no
  layout, so decode, loudness analysis (BS.1770 channel weights, LFE excluded),
  DSP and PipeWire channel positions need one. Until then playback and
  loudness analysis refuse a file with more than two channels
  (`UnsupportedChannelCount`).
- Reading `REPLAYGAIN_TRACK_*` and `REPLAYGAIN_ALBUM_*` tags from files. A
  figure comes only from Orca's own analysis.
- Exact album loudness from each file's block-energy distribution instead of
  a duration-weighted mean of the Tracks' loudness
  ([analysis.md](analysis.md#album-replaygain)).
- Batched Track inserts for the first scan.
- Tracks within a search tier ordered by relevance instead of id, and a text
  `TrackQuery` that ranks by bm25 only for the page it returns.
- The output kind for device id 0, the system default, and for any sink past
  the 64th PipeWire discovers.
- Folders that hold only images in `orca-cli folders` and the Folders page.
  The scanner records images only in folders that hold audio.
- `orca-gtk` Settings equalizer band captions taken from
  `equalizer_band_frequencies_hz` instead of `preferences.zig`.
- macOS: an app with a CoreAudio output behind the backend contract and an
  FSEvents watcher behind `library/watch.zig`. `liborca` compiles for macOS
  but cannot play there, and `libraryWatch` returns
  `error.WatchingUnsupported`. The macOS POSIX-lock Known issue is fixed
  first.
- Opt-in embedding of a Release's fetched cover, only in files with no
  embedded picture, stored once per plan and referenced by digest from each
  action, with an Embed artwork when writing setting in Settings > Library.
- Opt-in writing of the AcoustID track ID (`ACOUSTID_ID`, `TXXX:Acoustid Id`)
  for matches accepted with a fingerprint, never the fingerprint itself.
- Similar artists in the details sidebar from ListenBrainz's
  `labs.api.listenbrainz.org/similar-artists` (no token; only the seed
  artist's MusicBrainz ID leaves the machine), cached for a week. The
  endpoint is experimental, so a failed lookup hides the list.
- A release calendar of new and upcoming releases by artists in the library,
  from ListenBrainz's `/1/explore/fresh-releases`, fetched at most daily.
- Radio and mixes from the library: a queue that keeps extending from a seed
  track, album or artist, scored in `liborca` from local data only (shared
  artist, tags, genre, era, play history and feedback), optionally boosted by
  cached ListenBrainz similar-artist data.
- C ABI functions for what only the Zig API offers. Each is named with its
  reason in `scripts/check-abi-coverage.sh`; the command lane (`submit`,
  `processNextCommand`) stays behind `orca_runtime_pump`.
- A light theme and a System theme that follows the desktop. `orca-gtk`
  defines dark tokens only.
- Accent colour choices, as a fixed table of derived token sets.
- Last.fm scrobbling as a second destination beside ListenBrainz.
- Exclusive output and an ALSA direct-hardware backend that bypass the system
  mixer, with the macOS backend.
- Device hardware volume, setting the volume on the DAC so the signal stays
  bit-perfect.
- Spectral transcode detection as a Suspicious transcodes category on Audio
  Problems, with the cutoff and a spectrum graph.
- Moving a file to the system trash as a journaled `MutationPlan` action, to
  remove a duplicate copy after Merge Metadata.
- Writing the chosen cover into the album folder as `cover.jpg`.
- A frosted background for the Activity popover. A popover is its own
  surface, so the window behind it cannot be snapshotted as an overlay's can.
- A database change log with inverse payloads, so Change History can undo
  Orca-only edits: metadata edits, accepted matches, chosen covers, playlist
  reorders and removed folders.
- True-peak measurement, 4x oversampled, in a column filled by re-analysis.
- Crossfade, never applied between gapless album tracks.
- Convolution DSP for room correction and headphone targets from impulse
  responses.
- Customizable keyboard shortcuts. The shortcuts dialog lists a fixed set.
- Localisation, with a Language setting.
- Editing lyrics from Now Playing.
- Automatic update checks and a release channel (Stable, Preview).
- Listening history retention. Settings > Listening's Keep history for is
  fixed at Forever.
- Starting a waiting Job ahead of the running one. The runtime has no call
  that reorders its Jobs.
- Song credits from MusicBrainz recording relationships: performers,
  composers and producers.
- Lyrics from a WAV or AIFF file's `id3 ` chunk and plain lyrics from a
  sidecar `.txt`, which needs a rule for telling lyrics from the other text
  files in album folders.
- A terminal client built on the Zig API.
- Conversion and encoding, with a Convert dialog and Converted rows in
  Activity in `orca-gtk`.
- Synchronized multi-zone playback with drift correction, with a Play in
  several rooms block in the output picker and a Multi-zone output switch in
  Settings > Advanced.
- Secure, verified CD ripping, with a Rip page and Ripped CD rows in
  Activity.
- Windows.
- Streaming sources and cross-device sync.
- Audio-feature similarity for radio, analysed from the audio itself. The
  extractor and any models must be permissively licensed; Essentia's code is
  AGPL and its models are non-commercial.

## Not planned

- Preserving file modification dates on tag writes: it would hide the
  write from the incremental scan.
- A DAW, plugin host, or arbitrary DSP graph.
- A required FFmpeg dependency.
- A custom database engine, TLS stack or cryptography.
