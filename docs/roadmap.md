# Roadmap

What Orca does today, what must hold before the public preview and 1.0, and
what is deferred. "Works" means reachable from `orca-cli` or `orca-gtk`
through the public runtime path, per the rule in
[architecture.md](architecture.md).

## Status

Released `0.8.1`. `orca-gtk` is a daily-usable player on Linux: a
designed libadwaita frontend, gapless playback between entries of one format,
output at each source's sample rate, live equalizer and crossfeed, tag
editing with undo, track details, lyrics that follow playback, a local
play history, star ratings, album and artist love, playlists with M3U import
and export, smart playlists, a command palette, browsing by genre and by
folder, artist and release info, ListenBrainz scrobbling, MusicBrainz and AcoustID matching with
review, AcoustID submission and verification, actionable Health, idle
maintenance, and watching of the music folders, so new, changed and
removed files show up without a rescan. `liborca` builds for aarch64
macOS; there is no macOS app, audio output or filesystem watcher.

Features are frozen until 1.0. The work is the [release gates](#release-gates)
below: a public preview released as 0.9.0, then 1.0.

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
- No scan or reconcile walks a root whose path now lies on another volume
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
  recovery never touches another process's write in progress.
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
  ListenBrainz, MusicBrainz and AcoustID are stored in the Library, so they persist across restarts and bind every
  process using it, and a per-service lease lets one process at a time talk
  to each service; another gets `ProviderBusy` without sending. See
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
  [playlists.md](playlists.md).
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
  key from `ORCA_ACOUSTID_USER_KEY`; `orca-gtk` sends them from the Matches
  page's Submit to AcoustID, with the key saved in Settings > Library. See
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
  cancellable jobs.
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
  Library in `orca-gtk`. See [control-plane.md](control-plane.md#idle-maintenance).

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
  and album and artist love, playlists and smart playlists with M3U import
  and export, Health actions,
  MusicBrainz and AcoustID matching, verification and corrections, AcoustID
  submission, ListenBrainz scrobbling, idle maintenance, provider servers
  and a credential callback for the host's secure storage.
  `tests/c_abi_layout.zig` checks every struct and enum value against the
  Zig side, and `tests/abi/compat.zig` checks `orca.h` against the released
  0.8.1 header.

### Builds

- Linux x86_64, and a static `liborca` for aarch64 macOS (`zig build lib
  -Dtarget=aarch64-macos`).
- CI (`.github/workflows/test.yml`): `zig build test` against a private
  PipeWire and WirePlumber, `zig fmt --check`, the aarch64 macOS
  cross-build, `nix flake check` (package build, NixOS module and the
  installed tree), and `zig build package-check` against the fetched Zig
  package. A `required` job fails when any of them fails.

## Built but not reachable

These exist with tests, but no client can use them yet. Each needs a runtime
entry point and a client before it counts as working.

- File moves through the journaled `MutationPlan` executor. Tag writes are
  reachable; moves are not.

## Release gates

Each gate states the defect or requirement, the result that must be observable
and how it is checked. A gate closes when its check passes and the entry is
removed.

### Before the public preview

- Quick hashes only nominate candidates. Two files of the same length whose
  first and last 64 KiB are equal merge into one File in the scanner
  (`liborca/database/repository/files.zig`) and `duplicate_pass.zig` calls
  them exact copies. A change confined to the middle of a file, with its size
  and first and last 64 KiB unchanged, keeps its quick hash, so analysis and
  the identity cascade still treat it as the old bytes. A merge or an exact
  verdict requires a full-content comparison. Checked by tests with files that
  differ only in the middle.
- Root paths are sound. A root path is stored as given: neither `orca-cli
  add-root` nor `orca_library_add_root` makes it absolute or refuses a
  relative one, and an absolute playlist export from a relative root writes
  lines that do not resolve; relative roots are made absolute or refused.
  Removing a root leaves its recordings, and their love and hate, ratings and
  playlist entries, in the Library; rescanning the folder creates new
  recordings, so those entries show as unavailable; removing a root must
  distinguish forgetting from relocating. `orca-cli analyze PATH` records the
  location's identity without reading its tags, so the next scan skips the
  path and its tags are never observed; the tags must show. Checked by tests
  of each case through `orca-cli` and the C ABI.
- The Library schema starts over. The migrations to schema 55 served one
  Library; once the gates above that change stored data are closed, they are
  replaced by one baseline schema, and a Library from an earlier release is
  refused with a message to create it again. Checked by opening a fresh
  Library and a 0.8.1 one.
- Publication. The GitHub items: the `required` CI job passing on GitHub and
  made required by branch protection, private vulnerability reporting turned
  on for `SECURITY.md`, Dependabot and pinact for pinned actions, the provider
  User-Agent contact switched to the repository URL, and the README's flake
  snippets checked from outside the repository.

### Before 1.0

- Providers take turns. A second job or process that wants a service in use
  fails with `error.ProviderBusy` instead of waiting its turn, so artist
  information fails while matching runs. Every request opens a new
  connection. Back-off a provider asks for stays as it is. Checked by tests
  with an injected clock.
- Signal path truth. Unknown device details must not produce an unqualified
  bit-perfect verdict: zero known reasons currently means eligible, and a
  channel mismatch is not checked. A float32-to-integer device path is not by
  itself sample loss. The report must describe the audio actually playing,
  not settings applied to future blocks: `playerSignalPath` describes the
  current DSP settings while audio processed under earlier settings is still
  queued, so it can report bit-perfect output for up to a pipe's worth of
  processed audio. Checked by signal path tests with unknown device details,
  and by a settings change under playback.
- Gapless transitions inside one 256-frame block apply the successor's
  identity and position anchor at its first frame, not the block's. Checked
  by an engine test with a boundary mid-block.
- More than two channels are refused for playback and loudness analysis with
  a clear error until [full multichannel support](#later) lands. Checked by
  playing and analysing a six-channel file.
- Malformed input is reported. An AIFF whose COMM frame count exceeds its SSND
  data, or with no SSND, is reported damaged; an 8-bit AIFF reports its sample
  format correctly; a WAV with a data chunk that is not a whole number of
  frames is reported; tolerant FLAC playback (errors discarded, MD5 off, short
  final block accepted) does not clear `corrupt_audio` in analysis. Checked
  by fixtures for each.
- Player lifecycle. `playerNext` and `playerPrevious` move the queue before
  opening the target, so a target that fails to open leaves now-playing on it
  while the previous entry keeps playing. A Zone whose stream stays active but
  stops calling back after decoding finished blocks draining for ever. A Zone
  attached, detached or moved while its Player's engine thread is starting can
  return before that engine adopts the change. Once every Zone has failed
  with its recovery attempts used, the engine stops pumping and the Player
  never drains, so a host that waits for the drain waits for ever; `orca-cli`
  checks the Zone instead. A device-0 output lost after it opened resets its
  recovery count on each reopen and retries without end. Each must have a
  defined result, checked by a test of each.
- Match Review can finish every release. Release review without guessing: once
  a release is chosen, apply its release-level values (album, album artist,
  date, type, release ID) to every Track, and track titles and recording IDs
  only to Tracks aligned by recording ID; let the user pair each remaining
  Track with one of the release's tracks by hand; offer Mark as Reviewed when
  nothing differs; name the unaligned Tracks when Apply refuses. Aligning by
  position, title or duration automatically is rejected: a wrong pairing
  would lock a wrong recording ID and reach AcoustID submissions and
  ListenBrainz. This covers two defects. Applying a reviewed release
  (`apply-release`, Match Review's Apply) writes nothing unless every Track
  holds an accepted or pending proposal enriched on that release, or a tag
  naming it. Tracks are placed on a release only by recording ID, and
  MusicBrainz often lists the same song on an EP or single as a separate
  recording, so an album whose files are all on the release can stay partly
  aligned through any number of re-identifications; orca-gtk then reports
  only "Every track must be on the release first", without naming the Tracks.
  No action sets a Track's release, and the metadata editor sets only a
  recording ID, which matching then treats as confirmed and stores no
  proposal for. A Release whose tags already name its MusicBrainz release is
  listed for review with that release as a 100% candidate, but the release is
  never looked up, so Match Review shows no MusicBrainz values and Apply
  writes nothing; the only way off the list is Not This Release, which says
  the opposite. Checked by a review of a release with unaligned Tracks, and
  of an already-tagged release, through `orca-cli` and `orca-gtk`.
- `orca-gtk` shows a Library that fails to open. It ignores one that fails to
  open, including one with a newer schema, and shows the welcome page.
  Checked by launching against such a Library.
- `write-tags` on a read-only file follows a stated policy. It rewrites a file
  whose permissions make it read-only. Checked by a test of the stated
  policy.
- Queue pages keep queue positions. `playerQueueTracks` and
  `orca_player_query_queue_tracks` skip a queue entry whose Track was removed
  from the Library, contrary to the comment in `core/runtime_status.zig` that
  it keeps its place, so a page's row `n` is then not queue position
  `offset + n`. Checked by a page over a queue with a removed Track.
- Embedding is specified. The SQLite unix-VFS lock replacement on Linux
  (`liborca/database/sqlite_locks.zig`) is process-wide; its initialization
  contract is documented and enforced. `orca_runtime_destroy` skips the Debug
  wrong-thread check; document or fix. Whether the AcoustID application key
  is snapshotted per job or per request is specified. Checked by tests and
  by [frontends.md](frontends.md) stating each.
- Compatibility promises for 1.0 are written separately for the Zig API, the
  C ABI and the Library schema. Schema upgrades from the public preview are
  tested. A GTK launch, open, play and close smoke test runs on a private
  display in CI. A release candidate passes an acceptance period with no open
  data-loss, memory-corruption, wrong-song or unintended-output defect.

## Releases

Orca follows [Semantic Versioning](https://semver.org). Before 1.0, a
release bumps the minor version when it contains a breaking change to the
Zig API, the C ABI or the Library schema, and the patch version otherwise.
The public preview is released as 0.9.0; 1.0 follows the
[Before 1.0](#before-10) gates.

Every change adds its entry to the Unreleased section of `CHANGELOG.md` in
the same commit: features, fixes, refactors, removals and breaking changes
alike.

To release:

1. Rename the Unreleased section of `CHANGELOG.md` to the version and date,
   and state the Library schema version it ships.
2. Set `.version` in `build.zig.zon`.
3. Commit, and tag the commit `vX.Y.Z`.
4. Update Orca's application entry on the AcoustID website to the new
   version. Every lookup and submission sends the version as
   `clientversion`, and the registered details should match what the
   service receives.

## Known issues

Small defects that are not yet scheduled:

- A file that leaves a Release loses its Track id when another folder on that
  Release projects first and one of its files now states the old position:
  that folder prunes the Track, and the leaving file gets a new one.
- A FLAC seek past the end of the stream fails as a decode error, while WAV
  clamps to the last frame; the other decoders are unchecked.
- A `technical_anomaly` Health issue for a displaced track position is
  never cleared once the position is fixed; only dismissing it hides it.
- `orca-cli` exits 0 after printing usage for a wrong argument count.
- A tag write that fails before it reaches a file, such as when its
  backup directory already exists, records no `TagWriteFailure`, so
  `orca-cli` and `orca-gtk` fall back to a message without a reason.

- `orca-cli` runs every command but `duplicates` and `analyze-library` on an
  arena, so a cold scan holds memory for every file until it exits.
- The scanner skips symbolic links to files without counting them.
- On a volume with no filesystem UUID, such as NFS, SMB or tmpfs, adding a
  root writes `.orca-volume-id` at the mount point.
- On macOS, which has no OFD locks, opening and closing a Library's
  database, `-wal` or `-shm` file from another part of the same process
  drops SQLite's POSIX locks on it. A second Orca process can then
  check-point and delete the WAL under the first, and the first process's
  later writes are lost. Linux uses OFD locks; see
  [database.md](database.md#concurrency).
- Ratings are neither read from nor written to tags (POPM, FMPS_RATING).
- When `orca-gtk` starts on Now Playing, the cover-tinted backdrop is
  sometimes not drawn, and is still missing seconds later; it was missing
  in 10 of 20 headless starts. The race is likely in `updateBackdrop`
  and `sourcePainted` in `apps/linux/art.zig`.
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
  `pkgs` when its `zig` is 0.16, and document `inputs.nixpkgs.follows` and
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

- More identification sources. ListenBrainz's `/1/metadata/lookup` would
  match what MusicBrainz and AcoustID miss, 50 songs per request, but needs
  the user's token and must share the listen worker's gateway.
- Fewer provider requests. Cover candidates learn an image's dimensions
  without downloading it in full; matching combines MusicBrainz recording
  searches instead of one per track; artist information overlaps its
  requests to different services.
- Tag writers for the remaining formats. FLAC, MP3 and ADTS are written; M4A,
  Ogg, WAV, AIFF and FLAC with a leading ID3 tag are reported as not
  writable.
- An optional fixed output rate with a band-limited resampler, for devices
  held at another rate and for gapless playback across sample-rate changes.
  Output at the source rate stays the default, since it is the only path that
  can be bit-perfect. A Resampler quality setting (Highest or Fast, used only
  when the device cannot match the source) arrives with it.
- Full multichannel support, required eventually. Canonical PCM carries a
  channel count but no layout: Vorbis and FLAC order multichannel audio
  differently, the PipeWire stream gets no channel positions, and loudness
  weights every channel 1.0. The channel layout is carried through decode;
  analysis applies BS.1770 channel weights and excludes the LFE channel; DSP
  and PipeWire channel positions follow the layout. Until then more than two
  channels are refused (see [Before 1.0](#before-10)).
- Reading `REPLAYGAIN_TRACK_*` and `REPLAYGAIN_ALBUM_*` tags from files; a
  figure comes only from Orca's own analysis.
- Exact album loudness: the album figure is a duration-weighted energy mean
  of the Tracks' gated loudness, which differs from BS.1770 gating over the
  album's merged blocks. Per-file gated-block counts cannot reproduce album-wide gating, which
  depends on the album's loudness distribution; exactness needs each file's
  block-energy distribution ([analysis.md](analysis.md#album-replaygain)).
- Batched Track inserts for the first scan.
- `orca-cli tracks --filter` and a text `TrackQuery` rank every match by
  bm25 before the page is cut, about 83 ms at 500,000 Tracks.
- Tracks within a search tier are ordered by id, not by relevance.
- The genre totals triggers cost about 7 µs per `track_genres` row, which
  took the 500,000-Track benchmark's insert from 3.8 s to 10.3 s.
- The output kind is unknown for device id 0, the system default, and for
  any sink past the 64th PipeWire discovers.
- Folders that hold only images, such as a `Scans/` folder of booklet pages,
  in `orca-cli folders` and the Folders page. The scanner records images
  only in folders that hold audio, so such a folder has no entry to list.
- `orca-gtk`'s Settings equalizer band captions are written in
  `preferences.zig` rather than taken from `equalizer_band_frequencies_hz`.
- macOS: a macOS app with a CoreAudio output behind the same backend contract
  and a filesystem watcher (FSEvents) behind the same `library/watch.zig`
  contract. There is none today: `liborca` compiles for macOS but cannot play
  there, and `libraryWatch` returns `error.WatchingUnsupported`. The macOS
  POSIX-lock write-loss Known issue must be fixed first.
- Opt-in per write: embedding a Release's fetched cover only in files with no
  embedded picture, as one front cover, stored once per plan and referenced
  by digest from each action rather than copied into every action. In
  `orca-gtk` it brings an Embed artwork when writing setting (Ask each time,
  Always, Never) on Settings › Library, Artwork Review's option to embed
  the chosen cover the next time tags are written, Write to Files' Artwork
  replaced card and Front cover rows, and Front cover rows in Change
  History.
- Opt-in writing of the AcoustID track ID (`ACOUSTID_ID`, `TXXX:Acoustid
  Id`) for matches accepted with a fingerprint, never the fingerprint
  itself.
- Similar artists in the details sidebar for a track, album or artist, from
  ListenBrainz's `labs.api.listenbrainz.org/similar-artists` (no account or
  token; only the seed artist's MusicBrainz ID leaves the machine), cached for
  a week to match its weekly refresh, with artists already in the library
  marked. The endpoint is experimental and takes a required `algorithm` name
  that may change, so a failed lookup hides the list rather than erroring.
- A release calendar: new and upcoming releases by artists in the library,
  from ListenBrainz's `/1/explore/fresh-releases` filtered locally by owned
  artist MusicBrainz IDs, fetched at most daily.
- Radio and mixes from the library, in the manner of Plexamp: a queue that
  keeps extending from a seed track, album or artist, scored in `liborca` from
  local data only — shared artist, tags, genre and era, play history and
  feedback — optionally boosted by cached ListenBrainz similar-artist data.
- The C ABI for what only the Zig API offers, each named with its reason in
  `scripts/check-abi-coverage.sh`: a host-supplied audio output
  (`setOutputFactory`), Zone policy and render strategy (`setZonePolicy`,
  `zoneRenderStrategy`), playing a file outside a Library
  (`playerLoadFile`), drain detection (`playerDrained`), one-file analysis
  on the caller's thread (`libraryAnalyzeFile`) and re-analysis
  (`libraryReanalyzeFile`), a Track's fingerprint
  (`libraryTrackFingerprint`), the Albums letter index
  (`libraryReleaseLetterIndex`) and filtered totals
  (`libraryReleaseQueryTotals`, `libraryTrackQueryTotals`), a listing's
  playable ids from a row (`libraryTrackQueryPlayableIds`), with the
  `added_after`, `name_order`, `codec` and `max_sample_rate` query fields they
  share with the pages; also `TrackSummary`'s `integrated_lufs`,
  `bitrate_kbps`, `path` and `album_artist_id` and the `loudness`, `bitrate`,
  `path`, `album_artist` and `genre` Track sorts; an Artist's release groups
  outside the library (`libraryArtistElsewhere`, `ElsewhereRelease`) and
  their covers (the `release_group` artwork subject, which
  `orca_library_request_artwork` refuses as unsupported), its origin (`ArtistInfoRecord.origin`) and the album-artist role filter
  (`ArtistQuery.role`); Track and Release pages, totals and counts read off
  the host's thread (`libraryRequestBrowse`, `libraryCancelBrowse`,
  `libraryTakeBrowse`); a playlist's codecs and analysis counts
  (`libraryPlaylistFormats`), its Artist count (`PlaylistSummary.artist_count`)
  and a smart playlist preview with its length and a sample
  (`librarySmartPlaylistPreview`), and new random orders
  (`libraryReshufflePlaylists`); a search hit's detail fields, its reason
  hits (`SearchHit.reason`, which `orca_library_search` leaves out) and the
  hit to feature (`SearchResults.top`); the roots offline now and what they
  leave unable to play (`libraryAvailability`, `libraryReleasesAvailable`),
  and a root's `volume` and `last_seen_at`; a selection's shared, mixed and
  edited field values and its cover (`libraryTrackFieldStates`), and the tag
  block a tag write replaces in each file (`TagWriteFile.format`); a
  Release's cover art candidates and chosen covers
  (`startCoverArtCandidates`, `libraryCoverArtCandidates`,
  `libraryUseCoverArtCandidate`, `librarySetReleaseArtwork`,
  `libraryStoredReleaseArtwork`, `libraryClearReleaseArtwork`), what an
  `artwork_problem` issue found (`libraryArtworkProblem`), the albums with
  artwork problems (`libraryArtworkProblemReleasePage`,
  `libraryArtworkProblemReleaseCount`), a candidates
  Job's counts (`MatchStats.cover_art_candidates`), and the metadata
  consistency pass and its issues (`startLibraryConsistencyPass`,
  `libraryMetadataIssueCount`, `libraryMetadataIssuePage`,
  `libraryApplyMetadataIssue`, `libraryApplyMetadataIssues`,
  `librarySkipMetadataIssue`, `libraryMetadataIssueStatus`); and fields the
  existing views leave out: where lyrics came from and their offset
  (`Lyrics.source_name`, `Lyrics.offset_ms`, absent from
  `orca_lyrics_view`), a duplicate copy's tagged date and track numbers
  (`DuplicateCopy.tagged_date`, `tagged_track_number`,
  `tagged_track_total`), and a folder entry's status, type and image role
  (`FolderEntry.status`, `mime`, `artwork_role`). The command lane (`submit`,
  `processNextCommand`) stays behind `orca_runtime_pump` and the
  request-correlated functions that use it.
- A light theme and a System theme that follows the desktop. `orca-gtk`
  defines dark tokens only.
- Accent colour choices, as a fixed table of derived token sets.
- Last.fm scrobbling as a second destination beside ListenBrainz, with its
  account in Settings › Listening.
- Exclusive output and an ALSA direct-hardware backend, which bypass the
  system mixer. They land with the macOS backend.
- Device hardware volume: setting the volume on the DAC so the signal stays
  bit-perfect.
- Spectral transcode detection, as a Suspicious transcodes category on
  Audio Problems with the cutoff and a spectrum graph. KissFFT is already
  compiled with Chromaprint.
- Moving a file to the system trash as a journaled `MutationPlan` action,
  for removing a duplicate copy after Merge Metadata, with trash rows in
  Activity and Change History.
- Writing the chosen cover into the album folder as `cover.jpg`.
- A frosted background for the Activity popover, as the command palette
  and search have. A popover is its own surface, so the window behind it
  cannot be snapshotted the way an overlay's can.
- A database change log with inverse payloads, so Change History can undo
  Orca-only edits: metadata edits, accepted matches, chosen covers,
  playlist reorders and removed folders, each with an Undo Orca Edit Only
  action, and Undo on Activity's applied-metadata rows.
- True-peak measurement, 4× oversampled, in a new column filled by
  re-analysis and shown in the album inspector.
- Crossfade, never applied between gapless album tracks.
- Convolution DSP for room correction and headphone targets from impulse
  responses.
- Customizable keyboard shortcuts. The shortcuts dialog lists the fixed
  set.
- Localisation, with a Language setting.
- Editing lyrics from Now Playing.
- Automatic update checks and a release channel (Stable, Preview). Orca is
  installed from the Nix flake.
- Listening history retention. Settings › Listening's Keep history for is
  fixed at Forever.
- Starting a waiting Job ahead of the running one (Start now in Activity).
  The runtime has no call that reorders its Jobs.
- Song credits from MusicBrainz recording relationships: performers,
  composers and producers.
- Lyrics from a WAV or AIFF file's `id3 ` chunk (`USLT`, `SYLT`), and plain
  lyrics from a sidecar `.txt`. A `.txt` needs a rule for telling lyrics from
  the other text files that sit in album folders.
- A terminal client built on the Zig API.
- Conversion and encoding. In `orca-gtk`: a Convert dialog, Convert… in the
  album inspector, and Converted rows in Activity.
- Synchronized multi-zone playback with drift correction. In `orca-gtk`: a
  Play in several rooms block in the output picker, which turns lossless
  and exclusive output off, and an Experimental section in Settings ›
  Advanced with a Multi-zone output switch.
- Secure, verified CD ripping. In `orca-gtk`: a Rip page, an Audio CD group
  under Devices in the sidebar, and Ripped CD rows in Activity.
- Windows, then iOS and Android.
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
