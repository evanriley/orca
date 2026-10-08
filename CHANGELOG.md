# Changelog

## Unreleased

### Fixed

- **`orca-gtk`'s right-hand panels share one width.** The Radio options
  panel, Now Playing (every tab) and the Daily Mix "How this mix was made"
  aside are 388 px wide like the inspector, so the page beside them no longer
  shifts between panels or tabs.
## 0.3.0 - 2026-10-08

Ships Library schema version 2; opening a 0.2.0 Library upgrades it in
place, and 0.2.0 cannot open it afterwards. The C ABI only adds.

### Added

- `orca-gtk` opens on Home: Daily Mixes with a grid of every mix, Start
  Radio from what is playing, an Artist, a genre, a decade or loved tracks,
  This week's listening chart, Jump back in, Rediscover, Never played, Deep
  cuts, Top artists, the Collection's formats and On this day. A Daily Mix
  page plays, shuffles or saves the mix, says why each Track is in it and
  removes a Track with Not for me, undone from its toast. Settings ›
  Listening adds Reset recommendations.
- Home queries: `libraryListeningWeek`, `libraryRecentReleases`,
  `libraryRediscover`, `libraryNeverPlayed`, `libraryDeepCuts`,
  `libraryTopArtists`, `libraryFormats`, `libraryOnThisDay`,
  `libraryHistoryAge`, their `orca_library_*` C ABI counterparts and
  `orca-cli home` give every number and list of the Home page as bounded,
  read-only queries taking the time and UTC offset.
- Daily Mixes: `startDailyMixes` (Job kind `daily_mixes`),
  `libraryDailyMixes`, `libraryDailyMixEntries`, `libraryNotForMe`,
  `libraryClearNotForMe`, `libraryResetRecommendations`,
  `librarySaveDailyMix`, their `orca_library_*` C ABI counterparts and
  `orca-cli mixes` make up to five genre mixes from the Artists played in the
  last 30 days and a Rarely played mix once a mix day (from 04:00 local),
  each 25 tracks within 90 minutes with true reasons, no repeats across mixes
  and counts of what was left out. Not for me hides a Recording for 90 days
  and can be undone in place; a mix saves as a playlist.
- Audio features: analysis estimates each file's tempo, key, onset rate and
  spectral centroid, and `libraryTrackAudioFeatures`,
  `orca_library_track_audio_features` and `orca-cli features` read them for a
  Track with an energy figure ranked within the Library. The next analysis run
  decodes every file once to measure them and reuses its other stored results.
  Tempo comes from a mean-removed onset autocorrelation tempogram and key from
  a harmonic pitch-salience chroma matched against the Albrecht–Shanahan
  profiles. `zig build analysis-bench` times one file's analysis.
- Radio preview: `libraryRadioPreview`, `orca_library_radio_preview` and
  `orca-cli radio` rank the Recordings a Radio from a Track, Release, Artist,
  genre, decade or loved seed would play, with true reasons and each scoring
  component, without a Player. Scoring weighs Artist, genre, tempo, key and
  energy, co-listening, era, taste and jitter, moving from close to the seed
  to exploring as `explore` rises. One pick in four at most is a Recording
  never played while played ones remain; after that never-played Recordings
  fill the rest, so a Library with little history still returns full lists.
- Library Radio: `playerStartRadio` and `orca_player_start_radio` play from a
  seed and keep 8 picks queued after the user's entries, topped up from a
  worker as tracks finish. Options can change mid-session; "less like this",
  skips within 30 seconds and undo steer the session; `playerRadio` and
  `playerRadioPicks` report its state and why each queued pick was chosen.
  With `radio.continue` on, a queue that runs out continues as a Radio from
  recent listening.
- `libraryRecordingSummary` and `orca_library_recording_get` read a
  Recording's title and artist credit; `orca-cli radio` names the Recording
  an `often_after` reason cites.
- orca-gtk Library Radio: Start Radio in the Track, album, artist and Queue
  row menus and a Radio button in the player bar; the Queue page shows the
  Radio's status, its picks with their reasons, Play next and Less like this;
  a Radio panel steers explore, focus filters, unplayed, recent-play and live
  picks and undoes feedback. Settings › Listening gains Radio & Daily Mixes
  and Show listening stats on Home.
- `scripts/headless-gui.sh` takes the output size from `ORCA_HEADLESS_SIZE`.
- Discovery settings: `libraryDiscoverySettings`,
  `setLibraryDiscoverySettings` and their C ABI counterparts read and store
  Radio auto-continue, unplayed picks, the recent-play avoid window and the
  Daily Mix count.

### Changed

- Library schema version 2. Opening a version 1 Library upgrades it in place
  in one transaction, keeping every row, and adds an index on listen time and
  tables for audio features, "Not for me" feedback and Daily Mixes. An
  upgraded Library cannot be opened by 0.2.0.

### Fixed

- A Job or query reading the Library no longer fails with an aborted
  statement when another Job runs the first missing-location sweep, cache
  clear or root removal: the scratch tables those use now exist from open
  instead of being created on the shared connection mid-read.
- The test output backend's `close` waits for a render callback in progress,
  as real backends do, so a test can no longer release an audio block twice
  when its output reopens for a new format.
- A skip, jump or other hard load no longer reports the entry it left as
  audible for one output callback. A `next` or `jump` in that window now ends
  the entry being heard in queue history, and now-playing no longer briefly
  names no Track.
- `radio.continue` no longer starts Radio after the queue it followed was
  replaced, stopped or moved off its last entry before the runtime pumped.
- A Zone whose render-ahead fills its whole block pool (a custom target above
  7936 frames, or a device quantum above 3968 frames) no longer skips audio.
  While the output held a partly played block, the engine decoded up to 8192
  frames it had no free block for and dropped them, cutting entries short and
  skipping short ones entirely.

## 0.2.0 - 2026-10-06

Ships Library schema version 1, unchanged from 0.1.0. Breaking for the Zig
API: `TagWriteFailure.file` is optional. `orca-cli` exits 2 instead of 0 on a
usage error. The C ABI only adds.

### Added

- A binary cache at [orca.cachix.org](https://orca.cachix.org) for the flake's
  package, named in the flake's `nixConfig` and filled by CI from `main`.
- `libraryAcoustIdSubmittedCount` and `orca_library_acoustid_submitted_count`
  return how many files and recording IDs AcoustID has accepted from a
  Library. Settings › Matching shows it under the AcoustID status row, and
  `orca-cli submit-acoustid` prints `submitted_total=`.

### Changed

- The application icon is a white "O" on the window's dark background.
- Embedding rules are specified and enforced. The first runtime installs the
  process-wide SQLite OFD lock replacement once and thread-safely; when SQLite
  connections were already open, or the replacement was later undone, Library
  opens fail with `ORCA_STATUS_INVALID_STATE` instead of running on POSIX
  locks. A Debug build refuses `orca_runtime_destroy` from another thread. An
  AcoustID job keeps the application key it resolved when it began.

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
- A lost output that reopens counts each reopen as a recovery attempt until it
  has played 32 blocks, or until the host closes it. A device-0 output, which
  always reopens on the default sink, now ends `failed` after its fourth loss
  without a stable interval instead of retrying without end, so its Player
  drains.
- A playing Player whose every requested output has failed with its recovery
  attempts used is paused at its position and wakes the host, instead of
  never draining while its engine woke every 2 ms. It reports `paused` and not
  drained; closing and requesting the output again, then playing, resumes it.
- When no Library opens, `orca-gtk` shows the failure in place of every page
  but Settings, instead of the empty-library welcome: the Library's name, the
  reason, with the newer-version sentence when it applies, and buttons to
  choose or create a Library. Add Music Folder, Scan Library and the
  palette's library commands are unavailable instead of answering "No
  library is open".
- A queue entry whose Track was removed from the Library keeps its row in queue
  pages, so row `n` is queue position `offset + n`. `playerQueueTracks` returns
  a `QueueTrackPage` whose rows carry the position, the Track id and a summary
  that is null for a removed Track; `orca_player_query_queue_tracks` passes such
  an entry as an `orca_track_view` with `removed` set and only `id` filled. The
  Queue page and Now Playing show it as "Removed from library", and it can be
  removed from the queue.
- A gapless successor that was primed before its predecessor's last block was
  decoded, as after a seek back inside the predecessor, becomes the
  now-playing entry at its first frame, with position counted from there, even
  when that frame falls partway through a 256-frame block. Before, the whole
  block holding the predecessor's last frame was reported as the successor's,
  so identity changed and the successor's position started counting up to one
  block early.
- The signal path reports the audio being heard. A path is bit-perfect
  eligible only when the source declares its sample format, an output is open
  and the device has reported its rate and format; otherwise it carries the
  new reason `path_unknown` (`ORCA_SIGNAL_REASON_PATH_UNKNOWN`), and
  `orca-gtk` calls it unconfirmed instead of bit-perfect. A device with a
  different channel count adds `channel_layout_conversion`. The float32 stream
  on an integer device adds `sample_format_conversion` only when the device
  cannot hold the source's values, so a 16- or 24-bit source on a 24-bit
  device stays eligible. `sample_processing` stays until audio processed under
  earlier settings has played, instead of clearing while that audio is still
  queued.
- A file that leaves a Release keeps its Track id, with its queue entries,
  lyrics and user genres, when another folder of that Release projects first
  and one of its files now states the leaving file's old position. That folder
  parks the Track instead of deleting it, and the projection run then projects
  the leaving file's folder, even when the run's scope did not include it,
  which seats the Track where the file now lands.
- A `technical_anomaly` Health issue for a displaced track position is cleared
  by the next projection that no longer displaces the file, as after a retag to
  a free number or to another album, or that finds the file unreadable,
  instead of staying until dismissed.
- `orca-cli` exits with status 2 and prints the usage to standard error when
  given no command, an unknown command or a wrong argument count, instead of
  exiting 0. `orca-cli --help` prints the usage to standard output and exits 0.
- `orca-cli` runs every command's runtime on the general-purpose allocator
  instead of the process arena, so a cold scan no longer holds memory for
  every file until it exits. In a Debug build the allocator reports leaks at
  exit.
- Every failed tag write reports a `TagWriteFailure`, including one that fails
  before reaching a file. `TagWriteFailure.file` (a `TagWriteFailureFile`) is
  null then, and `orca_tag_write_failure` has `file_id` and `action_index` 0.
  New reasons `backup_exists` (`ORCA_TAG_WRITE_FAILURE_BACKUP_EXISTS`) for a
  backup directory another write created after planning, and
  `recovery_failed` (`ORCA_TAG_WRITE_FAILURE_RECOVERY_FAILED`) for an earlier
  interrupted write that could not be finished first; a file whose format
  stopped being writable after planning reports `changed_since_plan` at that
  file. `orca-cli write-tags` prints `failed - REASON -` and `orca-gtk` names
  the reason.
- Among duplicate copies of equal format, sample rate, bit depth and size,
  Duplicates ranks and suggests keeping by location (library root path,
  volume, then path) instead of the order the scanner found them, so the
  suggestion and the copy order no longer depend on the order the filesystem
  lists a folder. The duplicate bytes of the health summary free the same
  copies, where they counted the lowest-numbered file of a group as kept.
- Seeking to or past the end of a stream no longer fails for FLAC, Ogg
  Vorbis, Opus, AIFF, QOA, MP3 and MP4 (AAC and ALAC); every decoder clamps the
  target to the stream length, as WAV does, and the next read is end of stream.
  Seeking to the end of a FLAC track, which the Player does when a seek lands
  on the last frame, no longer fails as a decode error.
- Results stored for a file with no recorded channel count no longer feed
  album gain or count as a finished measurement. The next analysis pass
  measures the file again and records its channel count, or, at more than two
  channels, discards the results and raises `missing_analysis`.
- On the Match Review page, the Best candidate and confidence columns now
  start at the same position on every row. Every row's action buttons share one
  width, so a long "Review · 3 tracks need pairing" button no longer shifts the
  columns of its row.
- Queue history keeps an entry whose Track left the Library in its place.
  `playerQueueHistoryTracks` returns a `QueueHistoryTrackPage` whose rows carry
  the position, Track id, end time, reason and a summary that is null for a
  removed Track, and `orca_player_query_queue_history` passes such an entry
  with `removed` set and only `id` filled instead of skipping it. The Queue
  page's History shows it dimmed as "Removed from library".
- Queue and history pages read each entry from the Library it was queued
  from. A Player bound to another Library keeps the earlier Library's entries,
  which were looked up in the new Library and showed another Track or none;
  an entry of a closed Library reads as removed.
- `orca-gtk` offers only Remove from Queue and Save Queue as Playlist… for an
  Up Next entry whose Track left the Library, and no menu for such an entry
  in History or as the playing row. Play Next, Play Later, Love and the album
  and artist links are gone from it, and Shift+Return and L do nothing on it.
- A Track whose file is recorded with more than two channels, or with no
  channel count, shows no loudness even when results are stored for it: the
  loudness column is empty, the loudness sort places it with the unmeasured
  Tracks, the Track details carry no loudness, and a playlist's formats count
  it as not analyzed.
- A MusicBrainz search finds a Track whose artist tag joins several artists
  with commas, such as "Pa Salieu, Black Sherif". When the whole tag finds
  nothing, the search is asked once more for a recording credited to any of
  the first eight names; an artist whose name holds commas, such as "Earth,
  Wind & Fire", still matches on the whole name in one request.
- `zig build pipewire-live-smoke` opens only the silent sink whose device id
  is given (`-- ID` or `ORCA_TEST_DEVICE`, from `scripts/silent-sink.sh`) and
  refuses a missing, unknown or non-virtual device instead of opening the
  first device on the PipeWire server.
- When the clock Zone's output is lost and another Zone takes over, playback
  resumes at the position already heard. It previously skipped the audio
  decoded ahead, which could drop the end of a track and its gapless
  transition.
- Listens and now-playing updates sent to ListenBrainz name the media player
  and its version (`media_player`, `media_player_version`), taken from the
  client identity, as well as the submission client.
- `orca-gtk` draws the cover-tinted backdrop on Now Playing even when the
  cover cache drops the cover before the backdrop is composed, which a large
  library could do at start-up, and redraws a backdrop dropped from the cache
  when its page is shown again.
- Library analysis no longer reads a file no decoder can decode, such as
  WavPack or APE, a damaged file, or a file with more than two channels, on
  every run. The verdict is stored against the file's content hash and the
  decoders that refused it, so the file is examined again only when its bytes
  change or a decoder for it is added. Such files no longer count towards the
  files left to analyze. A file that could not be read is still examined again
  on the next run.
- A scan or reconcile counts the symbolic links its walk passes over, to a
  file, a directory or nothing, in `ScanStats.symlinks_skipped`; it still does
  not follow them. `orca-cli scan`, `reconcile` and `watch` print
  `symlinks_skipped=N` and the Job's Activity summary reads "N symbolic links
  skipped" when it is not zero. C hosts read it through
  `orca_library_scan_stats_v3`.
- Matching no longer examines a Track without a title or an artist again on
  every run, or decodes again a file whose bytes could not be fingerprinted.
  The Track is passed over until its title and artist are both set, and is
  still counted in `insufficient_evidence`. The file is not offered to
  AcoustID until its bytes change. Re-identify searches and fingerprints both
  again. A file that could not be opened or read is still tried on the next
  run.
- A library match run no longer selects, counts and looks up from the cache,
  on every run, a tagged release ID that MusicBrainz does not have. The
  release is passed over while its refusal is cached for 7 days, and is asked
  again once the refusal expires, the release ID changes or its Release is
  re-identified. A lookup that failed with an outage or timeout is still
  retried on the next run.
- Adding or relocating a root on a mount with no filesystem UUID, such as NFS,
  SMB or tmpfs, no longer writes `.orca-volume-id` at the mount point. The root
  binds to its own `root:<id>` volume. A root bound to an existing marker keeps
  its volume; once the marker is gone, relocating the root to its own path
  rebinds it to `root:<id>`.
- The NixOS and Home Manager modules build the default `programs.orca.package`
  against the system's nixpkgs when it provides `zig_0_17`, so the GPU drivers
  under `/run/opengl-driver` meet a glibc at least as new as their own and
  `orca-gtk` keeps its Vulkan device. The README documents
  `inputs.orca.inputs.nixpkgs.follows` and nixGL for `nix run` outside NixOS.
- An AcoustID submission whose user key cannot be read from the credential
  store, or is too large for the C ABI's buffer, fails with the new outcome
  `credential_unavailable` (`ORCA_SUBMISSION_OUTCOME_CREDENTIAL_UNAVAILABLE`)
  instead of `needs_user_key`. `orca-gtk` and `orca-cli` report it.
- A matching or verify job that cannot reach the network no longer stops at
  the first Track without a cached answer. It sends no further request,
  matches every Track its cache answers, leaves the rest eligible for the next
  run, and ends `failed` with `unavailable` set. An outage that gives up after
  its retries still stops the job.
- `orca-gtk` says "Paused because the output device stopped working" when the
  engine pauses a Player after every output failed, and Play then requests the
  output again instead of staying paused on the failed one. Match Album with no
  match says "No album match found" instead of "No release ID to fetch its
  cover". `scripts/headless-gui.sh` points MusicBrainz and AcoustID at
  `ORCA_HEADLESS_MUSICBRAINZ_URL` and `ORCA_HEADLESS_ACOUSTID_URL` when they
  are set.
- A match candidate without a title or artist scores below one whose title
  and artist match a tagged Track, instead of being judged on its length and
  fingerprint alone. An AcoustID recording named in part under one
  fingerprint takes its title, artists, length and release groups from where
  the same answer names it in full, so recordings sharing a fingerprint rank
  on all their evidence rather than on their artist credit. AcoustID answers
  cached before this, which may lack those fields, are asked again.
- Re-identifying a Release keeps its pending album correction whole. A search
  that finds a grouped recording again leaves its proposal in the group with
  the release, positions and release values the group was formed on, and
  Match Album's release vote leaves a grouped proposal on that release, so no
  correction of the group can be accepted alone.
- Verification decides once per Release, before its first page, whether the
  Release's files that still disagree are verified again: they are when it
  has a stale or unverified file then. A Release of more than 512 Tracks
  verifies them on every page, so `verified` reaches the `total_units` the job
  counted.

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
