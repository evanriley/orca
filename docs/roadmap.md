# Roadmap

What Orca does today, what comes next, and what is deferred. "Works" means
reachable from `orca-cli` or `orca-gtk` through the public runtime path, per
the rule in [architecture.md](architecture.md).

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
macOS, but macOS has no audio output or filesystem watcher yet.

`liborca` is usable as a library for others: the SONAME `liborca.so.0`
versioned by `ORCA_ABI_VERSION`, `orca_version`, an installed `orca.pc`,
exports limited to the functions `orca.h` declares, a last-error message for C
callers, a stability statement in `orca.h` and [api.md](api.md), a provider
identity the host must supply, and a wake callback with a pump timeout, which
`orca-gtk` sleeps on instead of polling. The C ABI reaches everything
`orca-gtk` uses, and `scripts/check-abi-coverage.sh` names, for each
`Runtime` method it does not reach, the reason. The next milestone is
more identification sources.

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
  track`, in the `orca-gtk` inspector and as sortable Songs columns. `orca-cli play-tracks` records listens too.
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

- `orca-cli`: scan, browse, search, library edits, tag write-back, undo and
  backup pruning, analysis, duplicates, artwork, queue playback, `feedback`,
  ratings, playlists and smart playlists with M3U import and export,
  folders, genres, search, lyrics, artist and release info, `scrobble`,
  MusicBrainz and AcoustID matching, fingerprints and AcoustID submission.
- `orca-gtk`: a dark libadwaita window with Songs, Albums, Artists, Genres,
  Folders, Playlists, Loved, Queue, Now Playing, Library Health and Matches
  pages, a Settings page of eight tabs, a command palette, an inspector with
  track, lyrics and signal path modes, context menus, tag editing with
  write-back and undo (Write Tags to Files on track and album menus), a
  player bar with cover art, format, output menu and volume, job progress, a
  welcome page, toasts, a shortcuts dialog, MPRIS, Health actions and
  dismissals, an idle maintenance switch, ListenBrainz submission with play
  counts in the inspector, love and dislike, star ratings, playlists with
  M3U import and export, a Smart Playlist editor, a parametric equalizer
  editor, the data sources Orca credits, MusicBrainz and AcoustID match
  review, and AcoustID submission.
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
  Zig side.

### Builds

- Linux x86_64, and a static `liborca` for aarch64 macOS (`zig build lib
  -Dtarget=aarch64-macos`).
- CI (`.github/workflows/test.yml`): `zig build test` against a private
  PipeWire and WirePlumber, `zig fmt --check`, and the aarch64 macOS
  cross-build.

## Built but not reachable

These exist with tests, but no client can use them yet. Each needs a runtime
entry point and a client before it counts as working.

- File moves through the journaled `MutationPlan` executor. Tag writes are
  reachable; moves are not.

## Next

In priority order. Each step leaves `orca-gtk` usable every day.

1. **More identification sources.** ListenBrainz's `/1/metadata/lookup`
   would match what MusicBrainz and AcoustID miss, 50 songs per request, but
   needs the user's token and must share the listen worker's gateway.
2. **Tag writers for the remaining formats.** FLAC, MP3 and ADTS are
   written; M4A, Ogg, WAV, AIFF and FLAC with a leading ID3 tag are reported
   as not writable.
3. **An optional fixed output rate with a band-limited resampler**, for
   devices held at another rate and for gapless playback across sample-rate
   changes. Output at the source rate stays the default, since it is the
   only path that can be bit-perfect.

## Releases

Orca follows [Semantic Versioning](https://semver.org). Before 1.0, a
release bumps the minor version when it contains a breaking change to the
Zig API, the C ABI or the Library schema, and the patch version otherwise.
Each milestone in [Next](#next) ends with a release.

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

- A `technical_anomaly` Health issue for a displaced track position is
  never cleared once the position is fixed; only dismissing it hides it.
- `orca-cli` exits 0 after printing usage for a wrong argument count.
- A tag write that fails before it reaches a file, such as when its
  backup directory already exists, records no `TagWriteFailure`, so
  `orca-cli` and `orca-gtk` fall back to a message without a reason.

- An output opened for a device id PipeWire does not know, such as a stale
  one, falls back to the default sink instead of failing, so it can play on
  real hardware. The stream sets `target.object` without
  `node.dont-fallback`.
- `playerSignalPath` pauses the engine for a few milliseconds, so hosts read
  it on change, never on a tick.
- `Telemetry.job_progress` is never published, so `ORCA_EVENT_JOB_PROGRESS`
  never fires; `Runtime.publishTelemetry` has no callers.
- `orca-cli` runs every command but `duplicates` and `analyze-library` on an
  arena, so a cold scan holds memory for every file until it exits.
- `write-tags` rewrites a file whose permissions make it read-only.
- The scanner skips symbolic links to files without counting them.
- On a volume with no filesystem UUID, such as NFS, SMB or tmpfs, adding a
  root writes `.orca-volume-id` at the mount point.
- Removing a root leaves its recordings, and their love and hate, ratings
  and playlist entries, in the Library; rescanning the folder creates new
  recordings, so those entries show as unavailable.
- On macOS, which has no OFD locks, opening and closing a Library's
  database, `-wal` or `-shm` file from another part of the same process
  drops SQLite's POSIX locks on it. A second Orca process can then
  check-point and delete the WAL under the first, and the first process's
  later writes are lost. Linux uses OFD locks; see
  [database.md](database.md#concurrency).
- Ratings are neither read from nor written to tags (POPM, FMPS_RATING).
- `orca-gtk` ignores a Library that fails to open, including one with a newer
  schema, and shows the welcome page.
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
- Files in different folders at the same release position share one Track,
  and the folder projected last decides which File it prefers; the other
  File is on no Track. An undo can switch the Track between them.
- A file keeps its Track id only when it moves to a position no row holds.
  When two files of a Release swap positions, their Track ids trade files,
  so a queued id plays the other song. When numbers shift, such as 1 to 2
  and 2 to 3, the file landing on the occupied position takes that Track's
  id and the other file gets a new one. Match Album correcting track
  numbers does this. To fix: repeat the move pass until no row moves, and
  let a row leave a position another file of the Release now claims.
- `playerNext` and `playerPrevious` move the queue before opening the
  target, so a target that fails to open leaves now-playing on it while the
  previous entry keeps playing.
- `orca-cli analyze PATH` records the location's identity without reading
  its tags, so the next scan skips the path and its tags are never observed.
- A change confined to the middle of a file, with its size and first and
  last 64 KiB unchanged, keeps its quick hash, so analysis and the identity
  cascade still treat it as the old bytes.
- `playerSignalPath` describes the current DSP settings while audio
  processed under earlier settings is still queued, so it can report
  bit-perfect output for up to a pipe's worth of processed audio.
- Canonical PCM carries a channel count but no layout: Vorbis and FLAC
  order multichannel audio differently, the PipeWire stream gets no channel
  positions, and loudness weights every channel 1.0.
- A Zone whose stream stays active but stops calling back after decoding
  finished blocks draining for ever.
- A Zone attached, detached or moved while its Player's engine thread is
  starting can return before that engine adopts the change.
- Re-identifying a Release turns its pending album correction into
  single-file corrections, which can then be accepted one at a time and
  leave the album's positions half-moved until the rest are accepted.
- In a Release of more than 512 Tracks, verified a page at a time, a file
  that still disagrees is checked again only while the Release has a stale
  file left when its page is reached, though the job's total counted it.
- `zig build pipewire-live-smoke` opens the first device on the user's
  PipeWire server rather than a silent sink.
- `scripts/headless-audio.sh` fails on the development desktop with
  "wireplumber did not connect to pipewire within 5 s", before running its
  command; `scripts/headless-audio.sh true` fails the same way.
  WirePlumber's log shows only skipped optional components. Not yet
  examined; whether CI is affected is unknown.
- `playerQueueTracks` and `orca_player_query_queue_tracks` skip a queue
  entry whose Track was removed from the Library, contrary to the comment in
  `core/runtime_status.zig` that it keeps its place, so a page's row `n` is
  then not queue position `offset + n`.
- A root path is stored as given: neither `orca-cli add-root` nor
  `orca_library_add_root` makes it absolute or refuses a relative one, and
  an absolute playlist export from a relative root writes lines that do not
  resolve.
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

- The Matches page's three-bucket layout from the design concepts
  (Confident, Needs Review, Unmatched, each with its count). `orca-gtk`
  lists proposals as flush rows under the page title.
- Reading `REPLAYGAIN_TRACK_*` and `REPLAYGAIN_ALBUM_*` tags from files; a
  figure comes only from Orca's own analysis.
- Exact album loudness: the album figure is a duration-weighted energy mean
  of the Tracks' gated loudness, which differs from BS.1770 gating over the
  album's merged blocks. Storing each file's gated-block count would make it
  exact ([analysis.md](analysis.md#album-replaygain)).
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
- macOS: a CoreAudio output behind the same backend contract, and a SwiftUI
  client rebuilt against the current C ABI. `liborca` compiles for macOS;
  without this output it cannot play there.
- A macOS filesystem watcher (FSEvents) behind the same `library/watch.zig`
  contract; until then `libraryWatch` returns `error.WatchingUnsupported`
  there.
- Opt-in per write: embedding a Release's fetched cover only in files with no
  embedded picture, as one front cover, stored once per plan and referenced
  by digest from each action rather than copied into every action.
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
  `artwork_problem` issue found (`libraryArtworkProblem`) and a candidates
  Job's counts (`MatchStats.cover_art_candidates`). The command lane (`submit`,
  `processNextCommand`) stays behind `orca_runtime_pump` and the
  request-correlated functions that use it.
- Lyrics from a WAV or AIFF file's `id3 ` chunk (`USLT`, `SYLT`), and plain
  lyrics from a sidecar `.txt`. A `.txt` needs a rule for telling lyrics from
  the other text files that sit in album folders.
- A terminal client built on the Zig API.
- Conversion and encoding.
- Synchronized multi-zone playback with drift correction.
- Secure, verified CD ripping.
- Windows, then iOS and Android.
- Streaming sources and cross-device sync.
- Audio-feature similarity for radio, analysed from the audio itself. The
  extractor and any models must be permissively licensed; Essentia's code is
  AGPL and its models are non-commercial.

## Not planned

- A DAW, plugin host, or arbitrary DSP graph.
- A required FFmpeg dependency.
- A custom database engine, TLS stack or cryptography.
