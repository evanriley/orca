# Changelog

## Unreleased

### Added

- **The orca-gtk redesign.** `orca-gtk` is rebuilt page by page to a new
  design: Albums, Artists, Tracks, Genres, Folders, Loved, Playlists, Now
  Playing and Queue; Library Health with Duplicates, Audio Problems,
  Artwork Review and Metadata Issues; Matches and Match Review; Activity
  and Change History; First Run and Scan; Edit Metadata and Write to
  Files; and Settings in eight tabs, with the bundled Newsreader, Geist and
  Geist Mono fonts. liborca and `orca-cli` gain what those pages read; the
  entries below describe each part.
- **Multiple libraries.** `orca-gtk` keeps a list of libraries, each a
  name and a database, in the `[libraries]` group of `settings.ini`
  (`paths`, `names`, `tracks`, `active`); the library a single-library
  install used becomes Main on the first launch. Settings › Advanced ›
  Libraries shows the active library, as a drop-down once there are two,
  and Manage…, a dialog listing each library's name, path, size and track
  count with Add Library… (open an existing database or create a new one),
  Rename, Remove from List, which never deletes the file, and Switch.
  Switching opens the other database first, so a missing or unreadable one
  leaves the current library open and says why in the card. It then stops
  the pages' loaders, saves the queue and position, closes the library
  through `destroyLibrary`, re-applies the watch, maintenance, scrobbling
  and long-track settings to the new one, restores its queue paused or
  not at all as On launch says, and resets every page. A relaunch opens
  the last active library; `ORCA_LIBRARY` still picks the library for one
  run without changing that choice. `scripts/headless-gui.sh` takes
  `ORCA_HEADLESS_LIBRARY=settings`, which opens the library the settings
  choose instead of a copy.
- **Metadata consistency.** A `consistency` Job finds, per Release, album
  artist spellings that disagree, mixed or invalid dates, repeated or
  missing track numbers, genre spelling variants and values that differ
  from the accepted MusicBrainz release, and stores each as an issue with
  its options, their support (`3 tracks · MusicBrainz agrees`) and the
  Tracks each changes. It runs in bounded batches with progress and pause.
  `startLibraryConsistencyPass`, `libraryMetadataIssueCount`,
  `libraryMetadataIssuePage`, `libraryApplyMetadataIssue` (locked Orca
  values through the edit path, locks kept, no file written) and
  `librarySkipMetadataIssue`; a skipped issue returns when its values
  change. `libraryApplyMetadataIssues` applies several issues, each
  optionally to some of its Tracks, after checking them all, and
  `libraryMetadataIssueStatus` counts open issues and says whether a scan
  that changed files ran since the pass. A precise date is proposed over
  its less precise forms, a date missing from some Tracks is an issue, a
  one-Track option names the Track, and numbering issues record their gap.
  Migrations 54 and 55 add `metadata_proposals`. `orca-cli consistency`, `issues`,
  `apply-issue [--tracks=IDS]`, `skip-issue` and `jobs --start=consistency`;
  `health --summary` ends with `metadata_issues N`. The C ABI reports the
  Job kind as `ORCA_JOB_KIND_CONSISTENCY`.
- **Metadata Issues page.** `orca-gtk`'s Library Health opens Metadata
  Issues from the Mismatched metadata row, which now counts open
  consistency issues. The page lists the albums by kind with what differs
  (`Saba · 2018 vs 2018-04-05`, `Noname · gap at track 6`), and shows each
  album's issues as cards: a choice of values with their support and a
  custom value, or a table of Track, Current and Proposed with a checkbox
  per Track. Apply to Orca changes the library only and Skip Album hides
  the album until its values change; both run off the main thread. When
  the metadata was never checked, or the library changed since, the page
  offers Check Metadata, which runs the `consistency` Job in the activity
  indicator. The Mismatched metadata row no longer counts the missing-tag
  and track-number health kinds; `orca-cli health` still lists them.
- **Resume playback.** liborca saves a Player's queue (up to 10,000
  entries), entry, position, repeat and shuffle in the Library:
  `playerSaveState`, then every 30 seconds from `pump` while it plays, when
  the Player leaves the Library, and at shutdown before any Player is torn
  down. `playerRestoreState` loads it back paused or playing and returns a
  `RestoreOutcome`; a saved Track that is gone resolves through its
  Recording or is skipped and counted. `playerSetLongTrackMemory` makes
  Tracks longer than a threshold (20 minutes by default) resume where they
  were left until they play to their end, and `PlayerStatus.resumed_from_ms`
  says where the audible entry resumed. Migration 53 adds `player_state`,
  `player_queue_entries` and `track_positions`. The C ABI adds
  `orca_player_save_state`, `orca_player_restore_state`,
  `orca_player_set_long_track_memory` and `orca_player_status_get_v3`.
  `orca-cli play-tracks --save-state` saves at the end, and `orca-cli
  resume DATABASE --device=ID [--play] [--limit=MS]` restores and prints the
  queue and status.
- **Resume at launch.** `orca-gtk` restores the last queue at launch as
  Settings › Playback › On launch asks: Restore queue, paused (the
  default), which shows the track and position in the player bar and opens
  no output until play; Restore and play, which opens the output as play
  does; or Start empty. Closing the window saves the queue and position
  with `playerSaveState`, and Remember position in long tracks sets
  `playerSetLongTrackMemory` to 20 minutes, or off. Play from the player
  bar or MPRIS opens the output when a restored queue has none.
  `scripts/headless-gui.sh` gains a `close` step.
- **Matches and Match Review.** `orca-gtk`'s Matches page lists albums
  by their best MusicBrainz release in Confident, Needs Review and
  Unmatched tabs with their counts, each row with its candidate, confidence
  and Accept and Review, expanding to the evidence (fingerprints,
  durations, artist, title, date) and why it scored as it did. Match
  Review sets the album's fields beside the release's, applies only the
  checked ones, dismisses the release with Not This Release or searches
  MusicBrainz again, and lists every track's local and candidate title,
  duration difference and fingerprint. Library Health reads its Unmatched
  count off the main thread, and its Review opens the Unmatched tab.
  "Search matches…" filters the tabs by album title or artist, and Review
  i of N pages through the whole tab. `libraryReleaseMatchPage` and
  `libraryReleaseMatchCounts` take a `filter`, and `orca-cli matches
  --releases` takes `--filter=TEXT`. `libraryReleaseMatchDiff` gives the
  candidate's release type from its release group ("Mixtape") and both
  covers' sizes (`ArtworkSize`), which `matches --release=ID --diff`
  prints. The page replaces the per-track proposal list and its Accept Confident and
  Submit to AcoustID buttons; Submit to AcoustID stays in the command
  palette. Each tab lists all of its albums, reading the next 100 as the
  list nears its end, and a reload after an accept or a Job keeps the
  albums already listed and the scroll position.
- **Artwork Review.** `orca-gtk` has an Artwork Review page, opened by Fix
  on Library Health's Missing artwork row or the palette's Show Artwork
  Review: the albums with missing, undersized or conflicting artwork, each
  with its local cover and its Cover Art Archive candidates, a Use as menu
  per candidate (Front, Back, Booklet, Don't use), Find Candidates, Use
  Selected Artwork, Skip and Choose Image… for a local file. The metadata
  editor's Replace… keeps a chosen image as the front cover of each
  selected Release, and Remove clears a chosen or fetched one.
  `scripts/headless-gui.sh` takes `ORCA_HEADLESS_COVERARTARCHIVE_URL` and a
  `db:PATH` step that copies the app's library.
- **Albums with artwork problems.** `libraryArtworkProblemReleasePage` and
  `libraryArtworkProblemReleaseCount` page and count the Releases with
  visible `artwork_problem` issues by title, each once with its worst
  problem and how many of its files have one; `orca-cli health
  --kind=artwork_problem --albums` prints them. Not yet in the C ABI.
- **Release match review.** `libraryReleaseMatchPage` and
  `libraryReleaseMatchCounts` sort Releases into confident, needs review and
  unmatched by their best MusicBrainz release candidate against an
  auto-accept score; `libraryReleaseMatchEvidence` says how many Tracks
  AcoustID heard on a release and whether durations, artist, title and date
  agree; `libraryReleaseMatchDiff` sets the Release's fields and Tracks
  beside the release's; `libraryDismissReleaseCandidate` marks a release as
  not the Release (migration 52, `dismissed_release_candidates`).
  `libraryApplyMatchedRelease` takes an optional `ReleaseFieldSet`: null
  applies as before; a set stores only those fields of the best candidate,
  locked so they outrank file tags, also from pending proposals on it, and
  leaves the rest and their provenance alone. The C ABI adds
  `orca_library_query_release_matches`, `orca_library_release_match_counts`,
  `orca_library_release_match_evidence`, `orca_library_release_match_diff`,
  `orca_library_dismiss_release_candidate` and
  `orca_library_apply_matched_release_fields`. `orca-cli matches --releases
  [--bucket=]`, `matches --release=ID --evidence|--diff|--dismiss=MBID` and
  `apply-release --fields=`.
- **Library Health and Audio Problems.** `orca-gtk`'s Library Health is
  an overview: when the library was last analysed with Analyze Again, a
  status card with album and track counts, and rows for Duplicates,
  Mismatched metadata, Possible clipping, Missing loudness analysis,
  Unmatched releases, Missing artwork and Missing files, each with its
  count and an action that opens Duplicates, Audio Problems, Matches or
  Folders, starts analysis or lists the files. A new Audio Problems page
  sorts clipping, decode errors, malformed headers and missing ReplayGain
  into categories, explains each and shows a card per file with Show in
  Folder, Re-analyze and Not a problem. `libraryReanalyzeFile` decodes and
  measures one file again, even when it owes nothing, and settles its
  health issues.
- **Duplicates page.** `orca-gtk`'s Compare on a Library Health duplicate
  opens a Duplicates page instead of a dialog: the groups with their copies
  and potential savings, Group N of M, a card per copy with the suggested
  one to keep, and Path, Format, Size, Duration, Album, Track, Date,
  Loudness, MusicBrainz, Plays · rating (one shared row for the same
  recording) and In playlists side by side. Merge Metadata Only, Keep Both
  and Ignore act on the group; nothing is deleted.
  `libraryDuplicateCopyPlaylists` names the playlists holding a copy's
  recording, and the C ABI adds `orca_library_duplicate_copy_playlists`.
- **Cover art candidates and artwork kinds.** `startCoverArtCandidates`
  lists up to 8 Cover Art Archive images for a Release, from its release
  and, when its files name one release group, the group's fronts, each
  measured from its full image and kept only as a thumbnail;
  `libraryUseCoverArtCandidate` fetches one again as the Release's front,
  back or booklet. When the group's index will not come, the release's own
  candidates are kept and the Job reports `partial`.
  `librarySetReleaseArtwork` and `libraryClearReleaseArtwork` set and clear
  a chosen cover, which outranks embedded, folder and fetched ones, in
  `libraryTrackFieldStates` and `orca-cli fields` too. Migration 51 keys
  `release_artwork` on `(release_id, kind)`, keeping every stored cover as a
  fetched front. Embedded covers and folder images are measured when
  scanned, and property backfill measures those observed earlier, kept
  covers included, recording one whose header will not read so it is not
  read again; an `artwork_problem` health issue now names `missing_front`,
  `conflicting` or `undersized` (under 500 px), settled from the database
  alone (`libraryArtworkProblem`). `libraryBackfillPending` counts the files
  and covers a backfill could repair, leaving out files missing, offline,
  undecodable or already found unreadable, and `orca-gtk` starts the
  backfill once per launch, outside a scan, when it counts any.
  `orca-cli cover-art --candidates` and `--use=CAA_ID[:KIND]`,
  `orca-cli artwork --set=PATH`, `--clear` and `--kind`, and
  `orca-cli health --kind=artwork_problem` reach them; the C ABI adds
  `orca_library_backfill_pending` and the `chosen` and `partial` cover
  outcomes.
- **Edit Metadata and Write to Files pages.** `orca-gtk`'s tag editor is a
  page: a checklist of the selected tracks, fields with `Mixed` placeholders
  and Edited badges, Apply to Orca, and the front cover with where it comes
  from. Write to Files previews the plan as cards and a per-file Before /
  After table with the tags' own keys, then writes it as a Job with undo
  kept. `libraryTrackFieldStates` reports the shared, mixed and edited state
  of each editable field and the cover, `TagWritePlan` files carry their
  `TagWriteFormat`, and `orca-cli fields` prints them.
- **Change History page.** `orca-gtk` lists the finished tag writes newest
  first, with their date, file count, Release title and whether they can
  still be undone, and shows the selected write's changed tags beside what
  an undo restores, loaded on a thread of its own. Undo This Change… asks
  first, then undoes the write; Export Log saves the history. Activity's
  Change History button, the activity popover's Change history and the
  command palette's Show Change History open it.
- **Exporting the change history.** `exportTagWriteHistory` writes every
  tag write's `orca-cli changes` line to a file atomically and refuses an
  existing file unless asked to replace it. `orca-cli changes --export`
  uses it, and the C ABI adds `orca_library_export_tag_write_history`.
- **Offline folder state.** `libraryAvailability` re-checks the roots and
  counts the Tracks and Releases the unavailable ones leave unable to play,
  and `libraryReleasesAvailable` answers per Release; `LibraryRoot` adds
  `volume` and `last_seen_at`. `orca-cli availability` prints them and
  `orca-cli roots` ends each line `volume= last_seen_at=`. `orca-gtk` shows
  a banner while a music folder is offline, with Try Again, Locate Folder…
  (`libraryRelocateRoot`) and a Details popover; Albums counts and dims the
  unavailable albums and badges the others "On this computer", the sidebar
  shows Folders `1 offline`, and the player bar reads `Stopped · file
  unavailable` and `No signal` after an entry fails.
- **Composer and comment.** `metadata.Field.composer` and `.comment` are
  editable (`orca-cli edit --composer= --comment=`, `--clear=composer|comment`),
  shown in `TrackDetails` and `orca-cli track`, and written back by
  `write-tags`: ID3v2 `TCOM` and an undescribed `COMM` in language `eng`,
  keeping described `COMM` frames such as `iTunNORM`; Vorbis `COMPOSER` and
  `COMMENT`, keeping `DESCRIPTION`. The readers also take Vorbis
  `DESCRIPTION` when no `COMMENT` has text and MP4 `©cmt`. Migration 50 adds
  `observed_file_tags.comment` and re-observes every present file on the next
  scan. The C ABI adds `orca_library_track_details_v3` with an
  `orca_track_details_text_view` and `ORCA_METADATA_FIELD_COMPOSER` (14) and
  `ORCA_METADATA_FIELD_COMMENT` (15).
- **Settings Library, Listening, Advanced and About.** `orca-gtk`'s Library
  tab holds Music Folders, Maintenance (Analysis threads as a stepper),
  Identification (the AcoustID key and an Accept confident matches at
  stepper) and Writing to Files. Listening connects a ListenBrainz account,
  shows the listens pending and adds Listening History: Keep listening
  history, Count a play after and Clear history. Advanced shows the audio
  engine, the database with Reveal, the cache with Clear Cache…, Operation
  history, Log level (`$XDG_STATE_HOME/orca/logs/orca.log`, Info, Debug or
  Trace), Rebuild library database and Reset all settings. About shows the
  version, output device, device formats, library, OS and supported
  formats, with Open Logs, Licenses and Copy Diagnostics, which writes the
  home directory as `~` and the user name as `[user]`.
  `ScanRequest.reprobe_all` (`orca_scan_options.reprobe_all`, `orca-cli scan
  --reprobe`) reads every file again, and `supported_formats` lists the
  formats Orca reads (`orca-cli formats`).
- **Settings Playback and Sound.** `orca-gtk`'s Playback tab holds Volume
  Leveling (ReplayGain Off, Track, Album or Smart; Preamp; Prevent clipping;
  Untagged tracks, now Use −6 dB by default), Transitions (Stop after
  current track, and When the queue ends, Stop or Repeat queue, through
  `playerSetRepeat`), Output and Resume. The Sound tab's Equalizer card
  switches Off, Graphic or Parametric; the parametric editor has a preset
  list with New preset…, Preamp steps, Import… and Export…, a labelled
  response graph and a filter table with Add Filter. Per-Device Presets
  picks a preset for each output, loaded when the output changes while
  Switch preset with device is on, and Crossfeed's Amount is Low, Medium or
  High (0.3, 0.5 or 0.7). Each is saved in `settings.ini` under
  `[playback]` and `[sound]`.
- **Settings General and Appearance.** `orca-gtk`'s Settings page has eight
  tabs (General, Library, Playback, Sound, Listening, Appearance, Advanced
  and About) under an underlined tab bar, and Search settings… filters rows
  across all of them. General holds Open Orca at login, which writes or
  removes `org.orca_music.Orca.desktop` in `$XDG_CONFIG_HOME/autostart`;
  Default page; Track changes and Library tasks notifications sent through
  `GNotification`; Sort artist names; and the Shortcuts table. Appearance
  holds Artwork influence (Off, Subtle or Expressive), Display typeface,
  Tabular numerals in tables, Density, Album grid size, Show counts in
  sidebar (now on by default), Inspector (Open on selection, Remember last
  state or Always closed) and Reduce motion. Each is saved in
  `settings.ini` and applied at launch. `ArtistQuery.name_order` sorts
  Artists by their name as written, and `orca-cli artists --sort-as-written`
  reaches it.
- **First Run and Scan pages.** `orca-gtk` opens a four-step First Run on
  a library with no roots: folders with an audio file count each, Watch for
  changes and Scan My Music; the Scan page; loudness analysis, started when
  the scan ends, with Analyze my music and Skip; and the library's counts
  with Start Listening, which opens Albums. The Scan page shows the stages,
  the file being read, the time left, the files that could not be read and
  the albums found so far, with Pause and Hide. A scan now records each file
  it cannot read as an `unreadable_file` health issue with the reason, and
  clears it once the file reads. A scan or reconcile Job now counts the
  files its walk will reach before reading any, and its Job snapshot
  reports them as `total_units`, with the files walked as
  `completed_units`, so it has a percent and an ETA like other Jobs;
  `orca-cli scan` progress lines print `total=`. The sidebar's activity
  widget reads `Scanning library` with the percent while a scan is the only
  Job.
- **Change history.** `libraryTagWriteGroupPage` lists finished tag writes
  newest first with their files, Release title, state (`applied`,
  `undoing`, `undone`, `rolled_back`, `failed`, `needs_reconciliation`) and
  whether they can be undone or expired when their backups were pruned,
  decided by the same check `undoTagWrite` runs. `libraryTagWriteGroup`
  reads one write's backups against its files and lists each changed tag,
  what an undo restores beside the value now. Both derive everything from the
  journal and only read. `orca-cli changes` lists, shows and exports them, and
  the C ABI adds `orca_library_query_tag_write_groups` and
  `orca_library_query_tag_write_group`.
- **Duplicate groups and metadata merge.** `libraryDuplicateGroupPage` and
  `libraryDuplicateGroupTotals` join duplicate issues into groups named by
  their lowest file id, each with its copies, whether they are one
  recording, their similarity and the bytes the redundant copies take.
  `libraryDuplicateGroup` lists a group's copies with their `TrackDetails`
  and playlist counts, suggesting lossless over lossy, then the higher rate
  and depth, then the larger file. `libraryMergeDuplicateMetadata` gives one
  Track the Orca values, user genres, rating and feedback another has and it
  lacks, in one transaction, never over its own locks and never writing a
  file. `libraryKeepBoth` and `libraryIgnoreDuplicateGroup` dismiss the
  issues. Schema version 49 adds `library_health_issues.similarity`.
  `orca-cli duplicates --groups`, `duplicates --group=ID`,
  `merge-duplicate`, `keep-both` and `ignore-duplicate` reach them, and the
  C ABI adds `orca_library_query_duplicate_groups`,
  `orca_library_duplicate_group_totals`,
  `orca_library_query_duplicate_group`, `orca_library_keep_both_duplicates`,
  `orca_library_ignore_duplicate_group` and
  `orca_library_merge_duplicate_metadata`.
- **Activity page.** `orca-gtk` gains an Activity page, opened from the
  command palette's Show Activity or the activity popover's View all: Now
  lists the running and waiting Jobs from `jobQueuePage` with their progress,
  time left, Pause or Resume and Stop, and History lists `jobHistoryPage`
  under All, Scans, Analysis, File changes and Problems, grouped by day, with
  durations, Undo for tag writes, Retry and Details. The sidebar's activity
  widget reads `1 task running · 65%`, `1 task running · 2 waiting` or
  `Paused · 2 waiting` and opens a popover of running, waiting and recently
  finished Jobs with Pause all; Pause All on the page pauses the Library's
  Jobs. Jobs started from the frontend now wait for the Library's slot
  instead of replacing the status card.
- **Listen policy, history clearing and cache size.** A Library keeps a
  `ListenPolicy` (`half_or_four_minutes`, ListenBrainz's rule and the
  default, `thirty_seconds` or `full_track`) and a recording switch,
  through `librarySetListenPolicy` and `librarySetListenRecording`. Schema
  version 48 adds `listens.syncable`: a listen kept under a policy that falls
  short of ListenBrainz's rule is stored with 0 and never sent.
  `libraryClearListens` deletes the history, the listens waiting to be sent
  and the play counts, and keeps ratings and loves. `LibraryStats` gains
  `last_duplicate_scan_at` and `listens`. `libraryCacheSize` and
  `libraryClearCache` measure and delete fetched covers, photos, LRCLIB
  lyrics and artist and release info, never embedded or folder artwork or
  local lyrics. `orca-cli listens` and `orca-cli cache` reach them, and
  `orca-cli stats` prints the new fields. The C ABI adds
  `orca_listen_policy`, `orca_library_set_listen_policy`,
  `orca_library_listen_policy`, `orca_library_set_listen_recording`,
  `orca_library_listen_recording`, `orca_library_clear_listens`,
  `orca_cache_size`, `orca_library_cache_size`, `orca_library_clear_cache`
  and `orca_library_stats_v2`.
- **First-run folder estimate and scan progress.** `estimateAudioFiles`
  counts the audio files under a folder not yet added, by each file's first
  bytes, up to a limit (100000 by default) past which `FolderEstimate`
  reports `truncated`; it is cancelled through a `CancellationToken`.
  `ScanStats` gains `stage` (`discover`, `read_tags`, `done`), `current_path`
  (the file a scan or reconcile is reading) and `albums_found` (distinct
  Releases written that still exist). `orca-cli estimate PATH` prints
  `audio_files=N truncated=no|yes`, and `orca-cli scan` prints `progress`
  lines with `stage=`, `files=`, `albums=` and `current=`. The C ABI appends
  `albums_found`, `stage` and `current_path` to `orca_scan_stats` and adds
  `orca_scan_stage`, `orca_folder_estimate` and `orca_estimate_audio_files`.
- **Job pause, waiting queue, history and progress telemetry.** A Library
  runs one host Job at a time; one started while another holds the slot, or
  while the Library is paused, is returned in the new `waiting` state and
  started in order by `pump`. At most 32 wait (`max_waiting_jobs`); the next
  start returns `error.JobQueueFull`. `pauseJob` and `resumeJob` hold a
  running Job at its next cancellation poll, keeping its thread and provider
  lease, and `cancelJob` wakes it within 50 ms; `pauseAll` and `resumeAll`
  hold a whole Library, its watcher reconciles and idle maintenance included.
  `jobQueuePage` lists the slot and the queue. `JobSnapshot` gains
  `started_at`, `paused`, `estimated_remaining_ms` (a rolling rate over the
  last 10 s, null before then), `current_item` and `detail`, and `pump`
  publishes `job_progress` whenever a host Job's units move. Schema version
  47 adds `job_history`, written when a Job finishes: `jobHistoryPage` reads
  it newest first through a `JobHistoryFilter`, and `jobRetry` starts a
  failed or cancelled Job's request again. `orca-cli jobs` starts, pauses,
  resumes and lists Jobs and their history, `orca-cli retry-job` retries one,
  and `orca-cli watch` takes `--pause-after` and `--resume-after`. The C ABI
  adds `ORCA_JOB_PAUSED`, `ORCA_JOB_WAITING`, `ORCA_MAX_WAITING_JOBS`,
  `orca_job_pause`, `orca_job_resume`, `orca_library_pause_jobs`,
  `orca_library_resume_jobs`, `orca_library_jobs_paused`,
  `orca_job_details_get`, `orca_library_query_job_queue`,
  `orca_library_query_job_history` and `orca_library_retry_job`.
- **Smart ReplayGain, preamp, untagged fallback and stop after current.**
  `ReplayGainMode.smart` applies the album correction while the entry before
  or after the one heard, in playback order, belongs to the same Release, and
  the track correction otherwise; it is decided again on every open, seek
  re-open, reorder and shuffle. `playerSetReplayGainPreamp` (±15 dB),
  `playerSetReplayGainFallback` (`UntaggedFallback`: `minus_6_db` or
  `as_is`), `playerSetPeakProtection` (the `1 / peak` cap, on by default) and
  `playerReplayGainSettings` cover the rest, and `SignalPath` reports
  `preamp_db`, `peak_protection`, `fallback` and `peak_limited`.
  `playerSetStopAfterCurrent` stops the transport when the entry being heard
  ends, without decoding any of the next one, then clears itself.
  `orca-cli play-tracks` takes `--replay-gain=smart`, `--preamp=DB`,
  `--untagged=-6|as-is`, `--no-peak-protection` and `--stop-after-current`,
  and its `signal:` line ends with `replay_gain_source=` and the settings.
  The C ABI adds `ORCA_REPLAY_GAIN_SMART`, `orca_untagged_fallback`,
  `orca_replay_gain_settings`, the matching `orca_player_*` setters and
  getters, and the new `orca_signal_path_view` fields at its end.
- **Playback failures, root availability and relocation.**
  `PlayerStatus.last_failure` names the last queue entry that could not be
  opened, as a `PlaybackFailure` with its Track and a reason (`file_missing`,
  `folder_unavailable`, `codec_unavailable`, `decode_error`,
  `unsupported_channels`), until an entry opened after it is heard. A Track
  whose root is unmounted or renamed fails with `TrackFolderUnavailable` and
  is no longer marked missing. `LibraryRoot` gains `available`,
  `track_count` and `unavailable_tracks`; `libraryRelocateRoot` moves a root
  to a new path in one transaction, keeping every id and the undo of its tag
  writes, refuses a path nested with another root or the old folder with
  `RootPathOverlaps`, and starts a reconcile; `libraryMissingFileCount`
  counts Tracks with no present file.
  `orca-cli play-tracks` prints `failure=TRACK_ID:REASON` and goes on to the
  next entry, `roots` appends `available= tracks= unavailable=`, `health
  --summary` adds `missing_files`, and `relocate-root DATABASE ID PATH` is
  new. The C ABI adds `orca_library_query_roots_v2`,
  `orca_library_relocate_root`, `orca_library_missing_file_count`,
  `orca_player_status_get_v2` and `ORCA_FAILURE_TRACK_FOLDER_UNAVAILABLE`.
- **Folder covers.** A Release whose files carry no cover shows the front
  image in its folder (`cover`, then `front`, then `folder`, then the
  largest), before the Cover Art Archive's, in `libraryTrackArtwork`,
  `libraryReleaseArtwork`, the artwork loader, `orca-cli artwork` and
  orca-gtk. The image is read and sniffed on every call; a deleted or
  unreadable one falls through. A folder cover counts as artwork for the
  `has_artwork` Release filter and smart playlist rule, `TrackDetails`, the
  genre artwork list and the `artwork_problem` health issue, and a cover
  fetch for such a Release sends no request and reports `folder`
  (`ORCA_COVER_ART_OUTCOME_FOLDER`, `orca-cli cover-art` `source=folder`).
  `TrackDetails.has_artwork` now also counts a fetched cover. Migration 46
  stores the flag as `releases.has_folder_cover`.
- **Output device capabilities and state.** `enumerateOutputDevices` fills
  each `Device`'s `capabilities` from PipeWire's `SPA_PARAM_EnumFormat`: the
  lowest and highest sample rate, the 16, 24 and 32-bit depths, the most
  channels, the state (`active`, `suspended` or `unavailable`) and the bus, as
  a `DeviceCapabilities`. Sinks that do not answer within 500 ms report it
  null. `orca-cli devices` appends `rates= depths= channels= state=` to each
  line, and the C ABI adds `orca_enumerate_output_devices_v3` with
  `orca_device_view_v3`, `orca_device_state` and the `ORCA_DEVICE_BIT_DEPTH_*`
  bits. `OutputFactory.discover` and its vtable now take a `DiscoveryDetail`,
  so a Zone's kind lookup skips the format round.
- **Output picker.** orca-gtk's device list is now a Play on popover with a
  refresh button: each output shows its bus icon and a note from its
  capabilities, a check marks the chosen one, and a summary gives what is
  sent, the DSP mode and what the device supports, above a volume slider and
  links to the signal path and Settings › Sound. The player bar shows the
  technology line over the device name and a chevron, and keeps the name
  below 900sp; its `DSP` now also counts ReplayGain, as the Mode line does.
  `enumerateOutputDevices` takes a `DiscoveryDetail`: `.identity` skips the
  format round, and the frontend asks for `.capabilities` only when the
  picker opens.
- **Device format in the signal path.** While a stream plays, the PipeWire
  backend follows its links to the sink node and reads that node's
  `SPA_PARAM_Format` on the loop thread, again whenever its params change,
  and publishes it through an atomic. `SignalPath` gains `device_format`, a
  `DeviceFormat` of `DeviceSampleFormat` (16, 24, 24-in-32 or 32-bit integer,
  or 32-bit float), rate and channels; it is null while the device is
  suspended, virtual or has not reported it, and on other backends. A known
  integer format adds `sample_format_conversion`, and a rate other than the
  stream's `sample_rate_conversion`. `orca-cli play-tracks` ends its
  `signal:` line with `device_format= device_bits= device_rate=`, or
  `device_format=-`. The C ABI appends `orca_device_format` to
  `orca_signal_path_view` with `orca_device_sample_format`. orca-gtk's
  Output stage shows the device's format and the float stream converted into
  it, and the closing verdict names the conversion or says the format is
  unknown.
- **Folder entries with images, status and last scan.** Scans record the
  PNG, JPEG, GIF, WebP and BMP files beside the music in `folder_images`
  (schema version 45), never as Tracks, with a role from the file name
  (`front`, `back`, `booklet`, `other`), and record when each folder was last
  walked in `folder_scans`. `FolderPage` lists images after the audio files
  as `FolderEntryKind.image` with `mime` and `artwork_role`, gives each file a
  `status` (`imported`, or `unreadable` once property backfill could not
  decode it), and carries `image_count`, `last_scanned_at` and the folder's
  Release when all its Tracks share one. `orca-cli folders DATABASE ROOT
  [PATH]` prints a `folder:` line and `kind=`, `status=` and `role=` on each
  entry; the C ABI adds `ORCA_FOLDER_ENTRY_KIND_IMAGE`.
- **Search hit detail.** Each `SearchHit` carries what a result row shows:
  an Artist's `release_count` and `track_count`, a Release's `year`,
  `artist` and `track_count`, a Track's `artist` and `duration_ms`, a
  Playlist's `track_count` and `duration_ms`, a genre's `track_count`. The
  first Artist hit adds the Playlists holding its Tracks
  (`reason = .tracks_by`, `reason_count` its entries) and its main genre
  (`main_genre_of`) within each kind's cap, and `SearchResults.top` is the
  `name` hit to feature: the first whose title holds every word whole,
  else the first. `orca-cli search` prints them and a `top` line; the C ABI
  leaves the reason hits out and does not carry the detail yet.
- Lyrics report where they came from and their `[offset:]` tag: `Lyrics.source_name` (the sidecar's file name, `embedded` or `LRCLIB`) and `Lyrics.offset_ms`, printed by `orca-cli lyrics` as `source_name=` and `offset_ms=`.
- **Playlist inspector data and richer smart playlists.** Rules gain an
  `in_playlist` field (`is`, `is_not`) that matches a manual playlist's
  Tracks and refuses a smart or missing playlist with
  `error.InvalidRulePlaylist`; a `random` sort, whose order each playlist
  keeps for the life of the runtime until `libraryReshufflePlaylists`; and `limit_hours` (1 to 10,000), which keeps the leading Tracks
  whose lengths fit, in place of `limit`. Rules stay version 1.
  `PlaylistSummary.artist_count` counts a playlist's Artists,
  `libraryPlaylistFormats` returns its codecs and how many entries are
  analyzed, and `librarySmartPlaylistPreview` returns the count, total length
  and a sample of what rules select. The C ABI does not offer the new
  methods yet. `orca-cli playlist` prints a `formats:` line, and
  `orca-cli smart-playlist-count` prints `duration_ms=` and takes
  `--sample=N`.
- **Browse queries off the host's thread.** `libraryRequestBrowse` queues a
  Track page, Track totals, a Release page or a Release count on the
  Library's browse loader, which reads on its own read-only connection and
  wakes the host when the result is ready; `libraryTakeBrowse` collects it
  and `libraryCancelBrowse` skips a request that has not started. At most 8
  requests are outstanding, the request's text is copied, and closing the
  Library or the runtime interrupts the running query and joins the loader.
  The C ABI does not offer it yet. `orca-cli tracks` and `orca-cli releases`
  take `--async`, which reads the same output through the loader.
- **Elsewhere covers and origin with its subdivision.** An artist-info fetch
  asks the Cover Art Archive for the 250-pixel front cover of the first 24
  release groups Elsewhere lists, keeps each in the new
  `release_group_covers` table (schema version 44), keeps a group without
  one as a miss for 30 days, and drops a cover once no Artist's release
  groups name its group. `ArtworkSubject.release_group` serves a kept cover
  through the artwork loader; the C ABI does not offer it yet. The origin
  now names the subdivision the area lies in, such as `Portland, Oregon`,
  through at most 3 cached MusicBrainz area lookups. `--offline` asks for
  no cover. `orca-cli artist-info --include-releases` prints `cover=yes`,
  `no` or `-` on each `elsewhere:` line, and `orca-cli release-group-cover`
  writes a kept cover to a file.
- **Artist origin, album artists and Elsewhere release groups.** An
  artist-info fetch keeps the Artist's origin (MusicBrainz's begin area,
  else its area) and, in one more MusicBrainz request, up to 100 of its
  release groups with their type, first release year and the other artists
  credited. Schema version 42 adds `artist_info.origin` and
  `artist_release_groups`. `libraryArtistElsewhere` lists the groups the
  Library does not hold, matched by release-group MusicBrainz ID, newest
  first, and `ArtistQuery.role = .album_artists` lists only the Artists a
  Release is filed under. `orca-cli artist-info` prints `origin=` and, with
  `--include-releases`, `elsewhere:` lines; `orca-cli artists` takes
  `--album-artists`.
- **Tracks at scale in orca-gtk.** From 20,000 tracks, Tracks shows its
  filters as removable tokens with `+ Filter`, the filtered count and
  duration, and Save as Smart Playlist, which saves the tokens as version 1
  rules that select the same tracks. Row numbers count from the top of the
  whole listing, and its Columns menu offers 15 columns, among them Album
  artist, Genre, Bitrate, Loudness (LUFS) and File path, which drag to
  reorder and save per view as `[view] track_columns_large` with Reset to
  default. Column order is now saved for the ordinary Tracks view too. A
  sort click no longer recounts the tracks, and the unfiltered count reads
  the tracks table directly: at 522,000 tracks a genre or bitrate sort
  click takes 54 ms instead of 152 ms and 211 ms. `libraryTrackQueryPlayableIds`
  returns up to 10,000 playable ids from an offset for play from a row.
- **Files-without-bitrate index.** Schema version 41 adds
  `files_without_bitrate`, so a bitrate-sorted Track page finds the Tracks
  without a bitrate through it instead of reading every Track.
- **Artists page redesign in orca-gtk.** Artists follows the redesign: a
  Sort by menu and an Album artists menu (All artists or Album artists,
  `ArtistQuery.role`, saved as `[view] artists_role`) beside a segmented
  grid and list switch, the count under the title with `· album artists
  only`, round photos at least 132 px wide with the name and `N albums`, a
  ringed initials monogram when there is no photo or cover, a ring on
  hover, and a note on the fallbacks at the end of the page.
- **Artist page redesign in orca-gtk.** An artist's page follows the
  redesign, in the new `apps/linux/artist_page.zig`: a round photo over its
  blurred backdrop, the name in Newsreader, genres, a biography clamped to
  three lines that end in an inline Read more, which expands it in place,
  Play, a dark Shuffle, love and more, a 380 px Top Tracks `By your plays`
  with each track's play count and the playing row tinted blue, Albums and
  Appears On grids `In your
  library`, Elsewhere tiles for the MusicBrainz release groups the library
  lacks, with their kept Cover Art Archive covers, marked `No local files`
  and captioned `with Kaytranada · 2023`, and Related Artists as round
  tiles. The artist inspector shows Overview (genres, active years,
  origin), In your library (albums, loved tracks, last played), Identity
  (MusicBrainz match and ID, photo source) and Links (MusicBrainz,
  Wikipedia, Official website).
- **Album page and track inspector redesign in orca-gtk.** An album's page
  follows the redesign: a 248 px cover over its blurred backdrop, `Album`,
  the title in 58 px Newsreader, the album artist, `2018 · Hip Hop / Rap ·
  13 tracks · 35 min`, Play, a dark Shuffle, love and more, and a table of
  `#`, Title and duration in 38 px rows with the playing row tinted and
  marked by a play glyph. The track inspector follows it too: a Track
  actions menu beside close, a 104 px label column, Loudness as
  Integrated, Sample peak and ReplayGain, Metadata as Album artist, Date,
  Genre, Track, Disc and Compilation, and File as Path (the last two
  folders), File, Size and Modified. When Orca's values differ from the
  file's tags, an `Orca metadata differs from file` card offers Compare, a
  Field / File / Orca table of the `write-tags` preview, and Write to
  File…, which opens the tag write confirmation.
- **Genres page redesign in orca-gtk.** Genres follows the redesign: a
  230 px list of genres with track counts, filtered by the header search
  (`Search genres…`), beside the selected genre with its name in
  Newsreader, `8 tracks · 4 albums · 1 artist · 13s`, Play, a dark Shuffle
  and more, six album tiles with See all N opening Albums filtered to the
  genre, Artists with round photos or initials and their track counts, and
  Representative Tracks. The strip of genre tiles, the cards and the
  Artists page's unreachable genre chip are gone.
- **Full-height inspector in orca-gtk.** The inspector runs from the top of
  the window beside the main column, which now holds the header bar and
  search, with a header of title, dim subtitle and close button, small
  capitals section headings, a 100 px label column and a width per view:
  316 px for a track or album, 300 for an artist, 290 for a playlist. The
  breadcrumb's parent is dim and its current page plain text.
- **Tracks page redesign in orca-gtk.** Tracks follows the redesign: a
  grouped `2,847 tracks` count, Sort by, Filters and Columns buttons in the
  Albums header style, Date Added newest first as the library's default
  order, a Rating column of five stars and a heart that set rating and love,
  a tinted playing row with an accent play mark, sort arrows on the sorted
  column, and a ••• menu with Play Next, Play Later, Go to Album, Go to
  Artist, Edit Metadata… and Show in Folder. Double-click or Enter plays
  the list from that row. The List/Browse switch is gone: Browse by Artist
  and Album is a toggle at the foot of the Columns menu.
  `ORCA_GTK_DEBUG=reveal` logs Show in Folder's path instead of opening a
  file manager. `scripts/headless-gui.sh` takes a `dclick:X,Y` step, and
  saves the last frame instead of failing when the window never settles.
- **Now Playing redesign in orca-gtk.** Now Playing follows the redesign:
  a 340 px cover with a soft shadow over the artwork backdrop and its
  vignette, which with the right column runs under a transparent top bar
  with the Now Playing overline and the search over the centre column and
  no back and forward buttons, a 48 px serif title, the artist,
  `ALBUM · YEAR`, a heart, five rating stars and a more button, then three
  synced lyric lines with Show all lyrics. A right column holds Up Next
  (ten rows, the playing one tinted, Clear and View Full Album) and Track
  Info (Album, Date, Genre, Track, Source); Up Next, Lyrics and Info tabs
  switch it. The Lyrics tab scrolls the whole lyrics with the current line
  bright, seeks when a synced line is clicked, and ends in a footer naming
  the source and its offset, such as `Synced · from 01 Dr. Whoever.lrc`
  and `Offset −0.2 s`. A track without a duration shows `–:––` and an
  empty seek bar.
- **Search overlay and command palette redesign in orca-gtk.** Search is
  a frosted view over the pages with All, Artists, Albums, Tracks,
  Playlists and Genres chips, a Top result card beside the Tracks, album
  tiles, Artists, and Playlists beside Genres; Enter opens and Ctrl+Enter
  plays. The command palette is a centred dialog over a dimmed window with
  Commands, Settings and Recent groups, each row's shortcut, and a footer
  of keys. Text starting with `›`, or `>` as a typed alias, in the library
  search opens the palette and no longer filters the page underneath.
- **Queue page redesign in orca-gtk.** Queue follows the redesign in a
  980 px column: the remaining track count, the time left when the whole
  queue is read, and `from` the first entry's album under the title, with
  Save as Playlist and Clear. Now Playing is a tinted card with a 56 px
  cover and `1:27 / 4:19`. Up Next rows stack title over artist, with a
  drag handle and a more button on hover; the more button and a right
  click open Play Next (Shift+Enter), Play Later, Love (L), Go to Album, Go
  to Artist, Remove from Queue (Delete) and Save Queue as Playlist…, and
  the keys act on the focused row. Previously Played rows are dimmed and
  say `6 min ago`. The sidebar's Queue badge counts the remaining tracks.
  `scripts/headless-gui.sh` takes a `drag:X1,Y1,X2,Y2` step.
- **Folders page redesign in orca-gtk.** Folders follows the redesign: a
  260 px tree of roots and folders with rotating chevrons beside a mono
  path breadcrumb whose segments open that level, a Files / Library view
  switch that opens the folder's album, and Show in File Manager. A card
  shows the album's cover and `Imported as ALBUM by ARTIST` with the album
  as a link, `13 tracks · 1 cover image · last scanned today, 10:24`, and
  Rescan Folder, which reconciles only this folder as a Job. The table
  lists Name, Kind, Length and Status: folders with their track count,
  audio files as `FLAC · 16-bit · 44.1 kHz` and `In library` or
  `Unreadable`, and images as `JPEG image` with their role. The header
  search filters the folder by name (`Search this folder…`, Ctrl+F). The
  Play and Shuffle buttons, the folder count and the Library list are gone.
- **Playlist page and inspector redesign in orca-gtk.** A playlist's page
  follows the redesign: the mosaic over its backdrop, a `Playlist` overline,
  the name in 58 px Newsreader, `By you · 12 tracks · 52 min · Updated
  today`, the description, Play, Shuffle, Reorder, Edit and more, and a
  borderless table of #, Title over artist, Album and Time. Reorder shows
  drag grips that move a row onto another. A smart playlist ordered at
  random gets Shuffle Again in its menu. The inspector shows `Playlist ·
  manual order` or `Smart playlist · N rules`, Details with Artists and
  `YYYY-MM-DD` dates, Formats (tracks per codec and how many lack
  ReplayGain analysis) and Export with Export as M3U8… and Duplicate as
  smart playlist…, which opens the Smart Playlist editor with one
  `in_playlist` rule. The editor gains a Playlist field. The page's heart
  is gone, as Love stays in its menu, and the inspector drops Created by
  and Description, which the page shows.
- **Loved page redesign in orca-gtk.** Loved follows the redesign: the
  Loved title in 56 px Newsreader, `Everything you've marked with a heart.
  Ratings are separate and live alongside.`, Play, Shuffle and more, and
  the counts of loved Tracks, Albums and Artists on the right. Tabs with
  icons choose Tracks, Albums or Artists. The Tracks table shows #, cover,
  Title with an inline heart, Artist, Album, Rating, Last Played, duration
  and •••, with no separate Loved column. The cover mosaic and tagline
  are gone. The top-bar search reads `Search loved…` and filters the
  current tab in place, while the counts keep showing every loved item.
- **Albums at scale in orca-gtk.** From 2,000 albums, Albums shows the
  library's count, artists and size, facet chips for Lossless, Added,
  Genre, Decade and More filters with an `N match` count, and, sorted by
  Artist or Title, letter sections with an A–Z scrubber, built on
  `libraryReleaseLetterIndex` and read a 512-Release page at a time.
  Recently Added is the Added chip's 30-day window. Section tiles are a
  cover and two labels under one shared hover, at most eight covers load at
  once, and glibc keeps one malloc arena, so 41,000 albums open in under
  400 MB.
- **Release name order indexes.** Schema version 39 adds
  `releases_artist_order` and `releases_title_order`, built from the same
  terms as the artist and title sorts, so a Release page in either order
  walks an index instead of sorting every Release: 22 ms to 6 ms per page
  at 512,000 Releases.
- **Letter index, added-since and codec filters, filtered totals.**
  `ReleaseQuery.added_after` keeps the Releases whose Tracks' play files
  were all first seen after a time, and `TrackQuery` adds `added_after`,
  `codec` and `max_sample_rate`. `libraryReleaseLetterIndex` returns a
  `LetterBucket` per initial (`'#'` for the rest) with its count and the
  offset where the same query's pages reach it; `ReleaseQuery.name_order`
  files the artist sort under the word after a leading "The", "A" or "An"
  unless set to `as_written`. `libraryReleaseQueryTotals` and
  `libraryTrackQueryTotals` return a query's count, album artists and
  bytes, or count and duration. `orca-cli releases` takes `--added-days`,
  `--letters` and `--totals`, and `orca-cli tracks` takes `--added-days`,
  `--codec`, `--max-rate` and `--totals`. In orca-gtk, Recently Added lists
  the albums added in the last 30 days, and Albums opens sorted by Date
  Added under All Albums.
- **Track loudness, bitrate, path and album artist.** `TrackSummary` adds
  `integrated_lufs` (the playing file's analysed loudness), `bitrate_kbps`
  (its average bitrate), `path` (its best location) and `album_artist_id`,
  and `TrackSort` adds `loudness`, `bitrate`, `path`, `album_artist` and
  `genre` (the first genre's name), each walking an index for a whole-library
  page. Schema version 40 adds `file_loudness`, kept from stored analysis
  results by triggers and backfilled, and the indexes `file_loudness_by_lufs`,
  `files_by_bitrate`, `tracks_sort_album_artist`, `genres_by_name` and
  `track_genres_first`. `orca-cli tracks` takes the new sorts and ends each
  line `lufs= kbps= path=`; smart playlists accept them as a sort.
- **The playing track, album and artist marked everywhere.** Folders,
  the search palette, album and artist grids and lists, Loved albums,
  artist pages and genre pages show the playing track, its album and its
  artist in the accent colour, with a play badge on album and artist
  tiles, and the marks follow the next track.
- **The Release a Match Album leaves an album on.**
  `Runtime.jobMatchRelease` and `orca_job_match_release` name the Release a
  finished Match Album's files are on, so a frontend can follow an album
  whose accepted release ID gave it a new id. `orca-cli match --release`
  prints it as `release=`.
- **Artist photos in listings.** `ArtistSummary` adds `has_photo`, true
  when the Library stores the Artist's photo, and `cover_release_id`, the
  Artist's first own Release in shelf order or else the first they appear
  on, so a frontend can show a photo or a fallback cover without a query
  per Artist. `ArtworkSubject.artist` loads a stored photo through the
  artwork loader, off the caller's thread. The C ABI adds `has_photo` in
  `orca_artist_view_v2`'s reserved bytes and
  `ORCA_ARTWORK_SUBJECT_ARTIST`, and `orca-cli artists` ends a line in
  `photo`.
- **Output kind and block size.** Each `Device` carries a `DeviceKind`
  (`usb`, `pci`, `bluetooth`, `hdmi`, `virtual` or `unknown`), read on
  Linux from the info of each PipeWire sink and of the device it belongs
  to; the null sink `scripts/silent-sink.sh` creates is `virtual`.
  `SignalPath` adds `output_kind`, the open device's kind, and
  `device_quantum_frames`, the frames that device asks for per period, and
  `equalizer_band_frequencies_hz` exports the ten bands' centre
  frequencies. The C ABI adds `orca_enumerate_output_devices_v2` with
  `orca_device_view_v2` and `orca_device_kind`, and `output_kind`,
  `has_device_quantum` and `device_quantum_frames` in
  `orca_signal_path_view`'s reserved bytes. `orca-cli devices` adds the
  kind as a third column.
- **Provider sources.** `providerSources` returns a fixed list of the
  services Orca takes data from, MusicBrainz and its genres, the Cover Art
  Archive, AcoustID, ListenBrainz, LRCLIB, Wikidata, Wikimedia Commons and
  Wikipedia, each a `ProviderSource` with its URL, what it supplies, its
  licence and the licence's URL, so every frontend credits the same
  sources. The C ABI adds `orca_provider_sources` with
  `orca_provider_source_view` and `orca_provider_source_id`, and `orca-cli`
  adds `sources`.
- **Folder browsing.** `libraryFolderPage` pages one folder of a root:
  subfolders first, with file and Track counts and duration counted through
  every folder below, then files with their Track ids, leaving missing files
  out. `playerPlayFolder` plays every Track below a folder, recursively in
  path order. Both read the existing `locations` index; no migration. The C
  ABI adds `orca_library_query_folder`, `orca_folder_entry_view`,
  `orca_folder_entry_kind` and `orca_player_play_folder`, and `orca-cli`
  adds `folders DATABASE [ROOT_ID [PATH]]` and `play-folder`.
- **Library stats and health sizes.** `libraryStats` returns
  `LibraryStats`: Artist, Release and Track counts, the files with a
  location that is not missing and their bytes, total duration, and when
  the last scan completed and the last analysis was stored.
  `HealthKindSummary` gains `files` and `bytes`; for `exact_duplicate` and
  `likely_duplicate`, `bytes` counts only the redundant copies, what
  removing them would free. The C ABI adds `orca_library_stats` with
  `orca_library_stats_view`, and `orca_library_health_summary_v2` with
  `orca_health_kind_summary_view_v2`. `orca-cli stats` prints the stats as
  `key=value` lines, and `health --summary` adds files and bytes after the
  count. Schema version 38 indexes `analysis_results.created_at` so the
  last analysis time is an index probe.
- **Parametric equalizer.** `playerSetParametricEqualizer` runs a
  `ParametricEqualizer` on a Player in place of the ten-band equalizer: up
  to 16 RBJ biquad filters (peak, low and high shelf, low and high pass,
  notch), each with its own frequency, gain and Q, and a preamp, applied on
  the engine thread with coefficients rebuilt off the render callback.
  Turning either equalizer on turns the other off, and a change mid-track is
  gapless. A filter that is new, of another kind, or in place of the other
  equalizer starts without history; one whose gain, frequency or Q changes
  keeps its history, so moving it does not click, and so does one whose
  neighbour is turned off or on.
  `playerParametricEqualizer` reads it back, `SignalPath` carries it
  as `parametric`, `ParametricEqualizer.response` gives its gain at any
  frequencies, and `parseEqualizerApo` and `writeEqualizerApo` read and
  write EqualizerAPO text, with a fuzz target. The C ABI adds
  `orca_player_set_parametric_equalizer`,
  `orca_player_parametric_equalizer_get`,
  `orca_parametric_equalizer_response`,
  `orca_parametric_equalizer_parse_apo`,
  `orca_parametric_equalizer_write_apo`, `orca_parametric_equalizer`,
  `orca_parametric_filter`, `orca_parametric_filter_kind`, the
  `ORCA_PARAMETRIC_*` limits, and `parametric` and `has_parametric` at the
  end of `orca_signal_path_view`. `orca-cli play-tracks` takes
  `--peq=FILE`, and `peq-check` and `peq-response` validate a file and
  print its curve. `dsp-bench` also times both equalizers.
- **Artist totals, release types and appearances.**
  `libraryArtistTotals` returns an Artist's `ArtistTotals`: own Release
  (appearances left out), Track and appearance counts and summed duration.
  Projection now fills
  `releases.release_type` from the files' tags, lowercased, and a
  release-info fetch fills it from the MusicBrainz release group's primary
  type when the tags state none. `ReleaseQuery.release_kind` filters by
  `ReleaseKind` (`album`, counting an unknown type, `ep_or_single`,
  `other`), `ReleaseQuery.appearing_artist_id` lists the Releases an Artist
  appears on without being their album artist,
  `ReleaseQuery.own_releases_only` narrows `album_artist_id` to the
  Artist's own Releases, and `ArtistSort.recently_added` orders Artists by
  their newest Release. The C ABI adds `orca_library_artist_totals`,
  `orca_artist_totals`, `orca_release_kind`, `kind`, `appearing_artist_id`
  and `own_releases_only` in `orca_release_query_v2` and
  `ORCA_ARTIST_SORT_RECENTLY_ADDED`. `orca-cli artist-info` prints a
  `totals` line, `releases` takes `--type=album|ep-single|other`,
  `--appears=ARTIST_ID` and `--own` (with `--artist`), and `artists`
  `--sort recently_added`.
- **Photos for related artists outside the Library.** An Artist fetch
  finds photos for up to 8 related artists with no library Artist, through
  MusicBrainz, Wikidata and Wikimedia Commons, and keeps them by
  MusicBrainz artist ID in the new `related_artist_photos` table (migration
  37), with a marker for an artist that has none; each is asked again after
  30 days or with `force`. Each photo keeps its Commons page, licence,
  licence URL and credit, as the Artist's own photo does.
  `RelatedArtist.has_photo` says which related artists have a photo,
  `libraryRelatedArtistPhoto` returns one and
  `libraryRelatedArtistPhotoInfo` its attribution. The C ABI adds
  `orca_library_related_artist_photo`,
  `orca_library_related_artist_photo_info` with
  `orca_related_artist_photo_info_view`, and `has_photo` in
  `orca_related_artist_view`. `orca-cli` adds
  `related-photo DATABASE MBID --out=PATH`, which also prints the licence
  and credit, and `related` lines end in `photo=yes|no`.
- **Queue history and saving the queue.** Each Player keeps its last 100
  entries that stopped playing, newest first, with when each ended and why
  (`finished`, `skipped`, `replaced`), in memory only and never as a
  listen: `playerQueueHistory`, `playerQueueHistoryTracks` and
  `playerClearQueueHistory`. `playerSaveQueueAsPlaylist` saves the current
  entry and those after it as a playlist. The C ABI adds
  `orca_player_query_queue_history`, `orca_player_clear_queue_history`,
  `orca_player_save_queue_as_playlist` and `orca_queue_history_reason`.
  `orca-cli play-tracks` takes `--print-history` and `--save-queue=NAME`.
- **Moving a queue entry.** `playerQueueMove(player, from, to)` moves an
  entry to another position in playback order under one engine stop, and
  the cursors, a held successor and every entry serial follow the entries
  they named. It refuses the entries `playerQueueRemove` refuses, and a
  position between the playing entry and the one already lined up, with
  `error.QueueEntryInUse`; under shuffle it changes only the shuffled
  order. The C ABI adds `orca_player_queue_move`, and `orca-cli play-tracks`
  takes `--move=MS:FROM:TO`, printing a `move` line with the result.
- **Library search.** `librarySearch` finds Artists, Releases, Tracks,
  Playlists and genres whose title or subtitle has a word beginning with
  each word of the text, ignoring case and diacritics, grouped by kind
  under per-kind `SearchLimits`; no character of the text is query syntax.
  A Track whose title holds every word whole comes first, then one whose
  title words begin with them, then one matching in its artist or album,
  and `SearchHit.rank` is that tier, 0 to 2; other kinds rank by bm25.
  Tracks are searched in `track_search`, updated only when a Track's
  indexed text changes, and the other kinds in the `search_index` FTS5
  table that triggers keep current (schema versions 36 and 38).
  `ReleaseQuery.text` filters Releases the same way under every other
  filter and sort. The C ABI adds `orca_library_search`,
  `orca_search_kind`, `orca_search_limits`, `orca_search_hit_view` and
  `text` in `orca_track_query_v2` and `orca_release_query_v2`.
  `orca-cli search DATABASE TEXT` prints the hits, and `releases` takes
  `--filter TEXT`.
- **Release formats, review state and filters.** `ReleaseSummary` carries
  the codec its Tracks' files share (or `mixed`), their highest sample rate
  and bit depth, whether all are lossless, `release_type` and
  `pending_reviews`. `ReleaseQuery` filters by `high_resolution_only`,
  `needs_review_only`, `lossless_only`, `year_min`, `year_max` and
  `has_artwork`, and `ReleaseSort.most_played` orders by listens. In the C
  ABI, `orca_release_query_v2` gains those filters,
  `orca_library_browse_releases_v2` passes an `orca_release_facts_view` beside
  each `orca_release_view`, and `ORCA_RELEASE_SORT_MOST_PLAYED` is new.
  `orca-cli releases` takes `--high-resolution`, `--needs-review`,
  `--lossless`, `--year-from`, `--year-to`, `--with-artwork`,
  `--without-artwork` and `--sort`, and ends each line with
  `format=FLAC 24/96`, `lossless` and `reviews=N`.
- **Playlist metadata.** A playlist has a description, a pin, a love and up
  to eight tags, and remembers whether `playlist-import` created it.
  `Runtime.libraryPlaylistPage` and `Runtime.libraryPlaylistCount` filter by
  name, kind, pin and creator and sort by name, update, creation or entries;
  `Runtime.libraryPlaylist` adds whether its entries name several Artists and
  its three most common genres, and `Runtime.libraryUpdatePlaylist` changes
  the metadata. `orca-cli playlist-update` sets it, and `orca-cli playlists`
  takes `--smart`, `--manual`, `--pinned`, `--created-by-me`, `--imported`,
  `--sort` and `--filter`. Schema version 35. The C ABI adds
  `orca_library_query_playlists_v2`, `orca_library_playlist_count`,
  `orca_library_playlist_get`, `orca_library_playlist_tags`,
  `orca_library_playlist_genres` and `orca_library_update_playlist`.
- **Smart playlists.** A smart playlist keeps version 1 rules JSON (fields
  such as title, genre, year, play count, rating, added and last played
  dates, loved and lossless, nested `all`/`any` groups, a sort and a limit)
  and lists the Tracks they match each time it is read; playback and M3U
  export take that list. Every rule value is bound as an SQL parameter.
  `Runtime.libraryCreateSmartPlaylist`, `Runtime.librarySetSmartPlaylistRules`,
  `Runtime.librarySmartPlaylistRules` and `Runtime.librarySmartPlaylistCount`
  manage them, and `orca-cli smart-playlist-create`, `smart-playlist-rules`
  and `smart-playlist-count` reach them. The C ABI adds
  `orca_library_create_smart_playlist`,
  `orca_library_set_smart_playlist_rules`,
  `orca_library_smart_playlist_rules` and
  `orca_library_smart_playlist_count`. A fuzz target replays rule seeds.
- **Track filters.** `TrackQuery` filters by `year_min`, `year_max`,
  `lossless`, `min_sample_rate` and `explicit_only`, alone or combined with
  the Artist, Release, genre and loved filters, and `libraryTrackMatchCount`
  counts them. A text search in `libraryTrackQuery` now keeps every filter,
  ordered by relevance, instead of returning `error.SearchDoesNotFilter`. In
  the C ABI, `orca_track_query_v2` gains the year range, an
  `orca_track_format`, `min_sample_rate` and `explicit_only`, and
  `orca_library_track_match_count_v2` is new. `orca-cli tracks` takes
  `--year-from`, `--year-to`, `--lossless`, `--lossy`, `--min-rate` and
  `--explicit`, and `--filter TEXT` searches with the other filters.
- **Lyrics.** `Runtime.startTrackLyrics` reads a Track's lyrics on a job
  worker: a synced `.lrc` sidecar, then synced lyrics in the file (ID3v2
  `SYLT` or `USLT`, Vorbis comment `LYRICS` or `UNSYNCEDLYRICS`, MP4
  `©lyr`), then plain lyrics from each in the same order. With `fetch` it
  also asks LRCLIB for a Track without synced lyrics of its own, sending
  only its title, artist, album and duration, and ranks the answer after
  local synced lyrics and LRCLIB's plain lyrics after local plain ones.
  Answers are kept in the Library under a digest of the query, so an edit
  asks again; a miss is asked again after 7 days. A job without `fetch`
  still uses kept answers. `Runtime.jobLyricsOutcome` returns a
  `LyricsOutcome`, `Runtime.jobTakeLyrics` the result, `Lyrics.lineAt` the
  synced line at a playback position, and `Runtime.setLrclibServer` points
  LRCLIB at another server. Schema version 31 adds `track_lyrics`. The C
  ABI's `orca_library_start_lyrics` starts an `ORCA_JOB_KIND_LYRICS` Job,
  fetching from LRCLIB with `ORCA_LYRICS_FETCH`; `orca_job_lyrics_outcome`
  reports where the lyrics came from and `orca_job_lyrics` hands them over
  once as an `orca_lyrics_view`; `ORCA_PROVIDER_SERVICE_LRCLIB` points
  LRCLIB at another server. `orca-cli lyrics DATABASE TRACK_ID [--fetch]`
  prints them, with `ORCA_LRCLIB_URL`, and `orca-cli play-tracks --lyrics`
  prints each synced line as it is heard.
- **Library Health by kind.** `Runtime.libraryHealthSummary` returns each
  kind with an issue that is not dismissed, its count and its highest
  severity, and `Runtime.libraryHealthIssuePageOfKind` pages one kind's
  issues. The C ABI has them as `orca_library_health_summary` and
  `orca_library_query_health_items_of_kind`, and `orca-cli health` takes
  `--summary` and `--kind=KIND`.
- **Track facts for song lists.** `TrackSummary` carries the playing file's
  codec, sample rate, bit depth and whether it is lossy, the date it was first
  seen, the recording's play count and last play, the parental advisory, track
  and disc totals and the Release year; `TrackDetails` adds the totals, whether
  the track total was counted, the advisory and the file's added and modified
  dates. `TrackSort` appends `play_count`, `last_played` and `year`. Play counts
  belong to the recording, so two files of one song played once each show two
  plays on both; migration 32 adds `recording_play_stats`, filled from the
  listen history. Track and disc totals come from the tags of any of the Track's
  files, else the larger of the number of Tracks on the disc and its highest
  track number, and the Release's disc count. The advisory stays unknown on
  files scanned before this version until a rescan reads them. The C ABI adds
  `orca_library_browse_tracks_v2` with an `orca_track_facts_view`,
  `orca_library_track_details_v2`, `ORCA_TRACK_SORT_PLAY_COUNT`, `LAST_PLAYED`
  and `YEAR`, `orca_explicit`, and an `explicit` byte in `orca_release_view`;
  `orca-cli tracks` prints the facts and sorts by them, and `orca-cli track`
  prints `track: n of N`, `disc: d of D`, the advisory and the file dates.
- **Genres.** Migration 33 adds `genres` and `track_genres`, filled from each
  Track's file tags, with spellings of one genre folded together (`Hip-Hop`,
  `hip hop` and `Hip-Hop/Rap` are Hip Hop) and a value that lists several split
  on commas and semicolons (`Indie Rock, Rock` is two genres; `R&B/Soul` and
  `Folk, World, & Country` stay one). `Runtime.libraryGenrePage`,
  `libraryGenreCount` and `libraryGenre` list genres with their Track, Release
  and Artist counts; `libraryTrackGenres`, `libraryReleaseGenres`,
  `libraryArtistGenres` and `libraryGenreArtwork` read them per item;
  `TrackQuery`, `ReleaseQuery` and `ArtistQuery` filter by `genre_id`, and
  `ArtistSort` orders Artists by name or Track count. `librarySetTrackGenres`
  gives Tracks user genres that outrank their tags, and `planTagWrite` writes
  them into FLAC, MP3 and ADTS files as `TagWriteFile.genres`: one `GENRE`
  comment per genre, an ID3v2.4 `TCON` with one value per genre, or a 2.3 `TCON`
  joined with `; `. `TrackDetails.genres` holds the first five. The C ABI adds
  `orca_library_query_genres`, `orca_library_genre_count`,
  `orca_library_genre_get`, `orca_library_track_genres`,
  `orca_library_release_genres`, `orca_library_artist_genres`,
  `orca_library_genre_artwork`, `orca_library_set_track_genres`,
  `orca_library_query_tag_write_genres` (a held plan's genre change for one
  file), `orca_library_browse_releases_v2`,
  `orca_library_release_count_matching_v2`, `orca_library_query_artists_v2` and
  `orca_library_artist_count_matching_v2`, and `orca_track_query_v2.genre_id`
  now filters. `orca-cli genres` and `genre` list and show them, `tracks`,
  `releases` and `artists` take `--genre ID`, `artists` takes `--sort
  name|tracks`, `edit` takes `--genre=A;B` and `--clear=genre`, `track` prints
  `genres:`, and `write-tags` prints a `genres` line for a genre change, as
  `orca-gtk`'s write confirmation shows a `Genres` line. A Track count filtered
  by genre alone counts `track_genres` rows. Each genre's Track, Release and
  Artist counts are stored in `genre_totals` (schema version 38), with two
  reference-count tables for the distinct Release and Artist counts, filled from
  the Tracks and kept exact by triggers, so `libraryGenrePage`,
  `libraryGenreCount` and `libraryGenre` read one row per genre: a page at
  500,000 Tracks takes under 1 ms. Each `track_genres` row written costs about 7
  µs more. `libraryGenreArtwork` lists only Releases with a cover.
- **Artist info.** `Runtime.startArtistInfoFetch` gathers an Artist's
  photo, biography, years active and links on a job: an image in the
  Artist's folder, then MusicBrainz, Wikidata, Wikimedia Commons and
  Wikipedia, each through its own rate-limited gateway. A Commons photo is
  kept with its licence, licence URL and plain-text credit, and a Wikipedia
  biography with its URL, language and CC BY-SA 4.0 licence; nothing is
  written to a file. A group's years active are its MusicBrainz formation
  and dissolution; anyone else's start at Wikidata's work period, else at
  their earliest Release in the Library, never at a birth date. Info is
  reused for 30 days, `offline` sends nothing, and only an Artist with a
  MusicBrainz artist ID is looked up online.
  Migration 34 adds `artist_info`, `artist_links`, `artist_loves`,
  `artist_related`, `library_settings` and `release_info`. `libraryArtistInfo`,
  `libraryArtistPhoto` and `libraryArtistLinks` read it, and
  `setWikidataServer`, `setWikimediaCommonsServer` and `setWikipediaServer`
  point it at other servers. The C ABI adds `orca_library_start_artist_info`,
  `orca_job_artist_info_outcome`, `orca_library_artist_info`,
  `orca_library_artist_photo`, `orca_library_artist_links`,
  `ORCA_JOB_KIND_ARTIST_INFO` and `ORCA_PROVIDER_SERVICE_WIKIDATA`,
  `WIKIMEDIA_COMMONS` and `WIKIPEDIA`. `orca-cli artist-info DATABASE
  ARTIST_ID [--fetch] [--force] [--offline] [--lang=xx]` prints it, with
  `ORCA_WIKIDATA_URL`, `ORCA_WIKIMEDIA_URL` and `ORCA_WIKIPEDIA_URL`, and
  `orca-cli artist-photo` saves the photo.
- **Listeners, related artists, release info and MusicBrainz genres.** Artist
  info also keeps ListenBrainz's listener count (`POST /1/popularity/artist`)
  and up to 12 related artists from ListenBrainz Labs, refreshed at most weekly,
  and `ArtistInfoOptions.include_releases` fetches the Artist's Releases too.
  `Runtime.startReleaseInfoFetch` keeps a Release's Wikipedia description, found
  through its MusicBrainz release group, and `libraryReleaseInfo` reads it.
  MusicBrainz genres (CC BY-NC-SA 3.0) go on Tracks with no genre from a file or
  an edit, as provider genres: on by default in artist and release info, turned
  off with `setGenreFill`, or run with `startGenreFill`. `libraryRelatedArtists`
  and `setListenBrainzLabsServer` are new. The C ABI adds
  `orca_library_related_artists`, `orca_library_start_release_info`,
  `orca_job_release_info_outcome`, `orca_library_release_info`,
  `orca_library_set_genre_fill`, `orca_library_genre_fill`,
  `orca_library_start_genre_fill`, `ORCA_JOB_KIND_RELEASE_INFO`,
  `ORCA_PROVIDER_SERVICE_LISTENBRAINZ_LABS`, `include_releases` in
  `orca_artist_info_options`, and `has_listeners` and `listeners` in
  `orca_artist_info_view`. `orca-cli artist-info` prints `listeners=` and
  `related:` and takes `--include-releases`; `related`, `release-info`,
  `genre-fill` and `genres --fill-from-musicbrainz` are new, `track` prints the
  genres' provenance, and `ORCA_LISTENBRAINZ_URL` and
  `ORCA_LISTENBRAINZ_LABS_URL` select the servers.
- **Artist love.** `Runtime.librarySetArtistLove` loves or clears Artists in
  the Library only, never sent; `ArtistSummary.loved`,
  `ArtistQuery.loved_only` and `ArtistSort.recently_loved` show, filter and
  order by it. The C ABI adds `orca_library_set_artist_love`,
  `orca_library_artist_loved`, `loved_only` in `orca_artist_query_v2`,
  `ORCA_ARTIST_SORT_RECENTLY_LOVED` and `orca_artist_view_v2`, which
  `orca_library_query_artists_v2` now calls back with.
  `orca-cli love-artist DATABASE IDS [--clear]` loves Artists, and
  `artists` takes `--loved` and `--sort loved`.
- **Parental advisory.** The MP4 `rtng` atom and `ITUNESADVISORY` in MP4,
  ID3v2 `TXXX` and Vorbis comments are read as `Explicit` (none, explicit or
  clean). `orca-cli edit --explicit=yes|no|clean` sets it, and `write-tags`
  writes it to FLAC and MP3 files.
- **Album ReplayGain.** `ReplayGainMode.album` corrects every Track of a
  Release by one figure: the duration-weighted energy mean of the Tracks'
  measured loudness toward −18 LUFS, capped by the largest Track peak. It
  is worked out when an entry opens, from the stored measurements, so
  re-analysis or a move to another Release takes effect at the next open;
  no migration. An entry whose Release is not fully measured, or has more
  than 512 Tracks, plays at its own track gain. `SignalPath` adds
  `replay_gain_source` (`ReplayGainSource`: `none`, `track`, `album`,
  `track_fallback`) and `replay_gain_track_db`, the track gain an album
  gain replaced. The C ABI adds `ORCA_REPLAY_GAIN_ALBUM`,
  `orca_gain_source`, and `replay_gain_source`, `has_replay_gain_track` and
  `replay_gain_track_db` in `orca_signal_path_view`'s reserved bytes.
  `orca-cli play-tracks` takes `--replay-gain=album`, and its `signal:`
  line names the source.
- **Lyrics in `orca-gtk`.** The inspector's Lyrics mode (Ctrl+Shift+L or its
  header toggle) shows the playing Track's lyrics: synced lyrics highlight the
  line being heard, dim the lines before it and keep it centred, plain lyrics
  show as selectable text, and an instrumental Track says so. Settings >
  Listening > Fetch lyrics from LRCLIB, off by default, also asks LRCLIB;
  `ORCA_LRCLIB_URL` points it at another server.
- **`orca-gtk` has a command palette.** The header search ("Search your
  library…", Ctrl+K) opens it: library results from one search grouped as
  tracks, albums, artists, playlists and genres, the last five items
  opened, and app commands; text starting with `>` lists commands only.
  Enter opens a result or plays a track, Shift+Enter plays it. Ctrl+F
  focuses the current page's own search. The header search narrows to a
  search button below 900sp, and page searches sit in their title rows.
- **`orca-gtk` has a Genres page.** A strip of genre tiles with cover
  mosaics leads to a genre hero with Play, Shuffle and Create Smart
  Playlist, and Albums, Top Artists and Top Tracks cards whose See All opens
  each page filtered to the genre; the selected genre is remembered. Albums
  gains a Search albums field that combines with its chips and Filters,
  Artists a genre chip when opened from a genre, and the Songs, Artists and
  Albums searches wait 200 ms after the last keystroke.
- **`orca-gtk` has a Folders page.** It browses the library as it lies on disk:
  a tree of the music folders beside the open folder's subfolders and files,
  with a breadcrumb back up, and Backspace or Alt+Up opens the parent folder.
  Play and Shuffle play the folder and everything under it, and activating a
  file plays the folder's songs from that file. Each file's menu offers Show in
  Files, Play, Add to Queue and Edit Metadata…, and a Library view groups the
  songs directly in the folder by album. Folders hides the format column when
  the pane is narrower than 700 px.
- **`orca-gtk` has a Smart Playlist editor.** It builds nested rule groups
  with order and limit, shows how many songs match as the rules change,
  and shows liborca's reason when rules are invalid.
- **`orca-gtk` has a parametric equalizer editor.** Settings › Sound switches
  the equalizer between Off, Graphic and Parametric. The parametric editor has
  presets (Flat, saved presets, an HD 650 sample), a preamp with Auto,
  EqualizerAPO import (naming the line it cannot read), export and Save as
  Preset; a response graph whose dots drag frequency and gain and scroll Q; and
  a table of up to 16 filters, with negative gains shown with a true minus sign.
  The mode, curve and presets are kept in `settings.ini`, and the Signal Path
  lists the filters.
- **`orca-gtk` lists Orca's data sources.** Settings › Advanced names each
  service Orca takes data from, what it supplies and its licence, with links
  to the licence and the site; the MusicBrainz genres row shows only while
  genre fill is on. An About card shows the version and the audio backend.
- **Headless screenshots of orca-gtk.** `scripts/headless-gui.sh PAGE
  OUT.png [STEP...]` opens a page of `orca-gtk` in a private headless sway
  session at 1440×900, drives it with keys, text and a virtual pointer, and
  saves a screenshot. Nothing reaches the desktop, output is pinned to the
  silent test sink, and only the processes it started are stopped.
  `scripts/design-fixture.sh` builds the library it opens,
  `fixtures/library/design.db`: 26 albums by eight artists with covers,
  three artist photos, genres and five playlists, two of them smart.
- **Keyboard actions on the selected track.** In `orca-gtk`, L, 1 to 5
  and Shift+Enter act on the selected track row of the Tracks, Loved and
  playlist tables, an album's track list, an artist's Top Tracks and a
  genre's tracks, through the row menu's Love, Rating and Play Next, before
  falling back to the playing track; a Tracks multi-selection is acted on as
  a whole. Delete removes the selected entry of a manual playlist, and smart
  playlists ignore it. In the command palette and search page, Shift+Enter
  plays a track or album result next and Ctrl+Enter plays it now.

### Changed

- **orca-gtk's Signal Path inspector follows the redesign.** A header with
  "How this track gets from file to output.", a verdict card over the chain,
  and stages on a rail that leave out what does not apply: Source,
  ReplayGain (track or album gain and peak protection), Parametric EQ (the
  saved preset's name and a table of type, frequency, gain and Q) or Graphic
  EQ, Crossfeed, Volume, Engine, System (PipeWire's rate, and whether it
  resamples) and Output. A stage that changes the samples has an accent
  node and says so. A closing card words the verdict from
  `SignalPath.reasons`, e.g. "Not bit-perfect: ReplayGain and EQ change the
  samples. Nothing is resampled between source and output." The verdict
  card no longer toggles every stage's detail; each stage does its own.
- **Smart Playlist editor redesign in orca-gtk.** The editor follows the
  new design as a page pushed in the Playlists section instead of a dialog:
  the top bar holds the breadcrumb with Cancel and Save Smart Playlist,
  both of which return to the previous page, and back and forward reach it
  like any other page. It has the name in serif, thin minus remove
  buttons (a new bundled icon), a rules card with an indented card per
  nested group, Limit to N tracks or hours selected by an order (random,
  most recently added, highest rated and others), a fixed Live updating row, and a Live preview
  of the count, length and first seven tracks from
  `librarySmartPlaylistPreview`. A loaded order left unchanged, such as a
  `random` sort, is saved exactly as read. Rules gain a `playlist_position`
  sort with a manual playlist's id in `playlist`, ordering Tracks by their
  place in it, Tracks it does not hold last; Duplicate as smart playlist…
  uses it, so the copy keeps the manual order. Rules stay version 1.
- **Playlists overview redesign in orca-gtk.** The overview follows the new
  design: "Your playlists and smart collections.", New Smart Playlist and
  New Playlist in the header (Import… moves into the New Playlist dialog),
  All, Created by Me and Smart tabs, every pinned playlist as a square
  mosaic tile with its track count and length, and All Playlists as a tile
  grid with a Recently updated sort menu and a grid or list switch. Smart
  playlist tiles show a glyph for their first rule and a summary of their
  rules, such as "Loved, never played" or "Last played over a year ago";
  other tiles show By you or Imported and when they were updated ("Updated
  last week"). Smart playlists use a new sparkle icon and Pinned a new pin
  icon, both bundled. The type menu and Show all are gone. The design
  fixture gains five smart playlists, Loved & Unplayed, 5 Stars, Recently
  Added, Hi-Res and Not Played in a Year, for ten playlists, seven smart.
- **Tracks no longer freeze on slow sorts and filters in orca-gtk.** The
  Tracks list reads its pages and its count and duration on the Library's
  browse loader instead of the main thread, so a sort by path or a broad
  search over a large library no longer stalls the window. Rows whose page
  has not arrived show blank and cannot be played, rated or opened; a new
  search or filter keeps the previous count until its totals arrive.
- **Albums read their pages off the main thread in orca-gtk.** Outside the
  letter sections, the Albums grid and list read their count and their
  pages on the Library's browse loader, keeping eight pages of 512 and
  cancelling the read of a page they drop. Albums whose page has not
  arrived show as empty tiles or rows that cannot be opened, played or
  loved, and a new sort, search or filter keeps the previous count until
  the new one arrives.
- **Smaller cover memory in orca-gtk.** orca-gtk keeps 96 MB of decoded
  covers, counted from each texture's size, instead of 600 covers of any
  size. Album grid tiles, sectioned or not, take the smallest of 128, 256 and
  400 px covers that fills the tile, and ask again when the cover size
  setting crosses one. A cover widget that is not mapped, on a hidden page,
  a hidden Grid or List layout or a grid row bound off screen, drops its
  texture and paints again from the cache when shown. On a 41,000-album
  library the Albums page sorted by Date Added peaks at 293 MB instead of
  575 MB while scrolling.
- **Matches builds when opened.** orca-gtk no longer builds the Matches
  page's rows at startup or on every library change; it marks the page stale
  and reloads it when you open it, or at once when it is already showing.
  The sidebar count stays current.
- **Newsreader, Geist and Geist Mono replace Inter and Source Serif 4.**
  `orca-gtk` sets display titles in Newsreader and the interface in Geist,
  and bundles Geist Mono, all under the SIL Open Font License and
  installed with their licences to `share/orca/fonts`.
- **orca-gtk colours come from one token block.** The stylesheet defines
  the redesign's palette once, as named colours, and every rule and the
  equaliser graph read them, so no colour is written anywhere else. The
  palette is cooler and lighter blue, popovers carry a ring and a deep
  shadow, Settings, Health and genre cards sit on the raised surface,
  smart playlist tiles and equaliser filters drop their own colours, and
  keyboard focus shows a 2 px accent ring. New type, control, spacing and
  radius classes match the design's scale.
- **orca-gtk says Tracks, not Songs.** Every label, count, tooltip, menu
  item and toast names a track, as liborca does. A settings file written
  before this release keeps its column choice: `[view] song_columns` and
  `song_column_widths` are still read when the `track_` keys are absent,
  and saving writes the `track_` keys.
- **A new orca-gtk shell.** The sidebar is the design's: the Orca
  wordmark over grouped page buttons with stroke icons, the queue length
  and match count beside their pages, and an activity card at its foot
  while a job runs, with the percent or a pulsing bar, that opens the
  job's progress. Show counts in sidebar (Settings › Appearance) adds the
  library's album, artist and track totals. The main menu is gone: Add
  music folder…, Keyboard shortcuts and About Orca are palette commands.
  The player bar is 84 px, with a 3 px seek bar, a signal icon over one
  technology line (`FLAC · 44.1 kHz · Native`, `Resampled` or `DSP`) and
  the output under it. L loves and 1 to 5 rate the playing track,
  Ctrl+Shift+R scans the library, Ctrl+Enter plays from the palette, and
  the window title names the page, as `Orca — Albums` or
  `Orca — Settings · Advanced`. `scripts/headless-gui.sh` adds `shot:` and
  `tree:` steps for screenshots and window titles mid-run.
- **A quieter orca-gtk top bar.** The header holds back, forward and the
  library search alone: the inspector toggles and window controls are
  gone (Ctrl+I, Ctrl+Shift+L and Ctrl+Shift+S still switch the inspector,
  and Ctrl+Q quits). The search is a 300 px field whose placeholder names
  what the page searches, such as `Search albums, artists or genres…` or
  `Search settings…`, and `Search your library…` elsewhere.
- **A balanced orca-gtk player bar.** Its parts take 1 : 1.5 : 1 of the
  width, so the seek bar is about 508 px at 1440 px and sits under the
  transport. The transport, volume and queue use thin stroke icons, the
  play button is 40 px, the heart follows the title, and the volume
  slider's knob shows only on hover or focus.
- **Artwork backdrops.** Album, artist and playlist pages show their cover
  blurred behind the top 600 px, fading into the page, and Now Playing
  behind the whole page under a vignette; a playlist blends its first four
  covers. The blur runs off the GTK thread and is cached with the covers,
  so reopening a page does not blur again. `ORCA_GTK_DEBUG=art` reports
  blurs and `ORCA_GTK_DEBUG=frames` frame times, and
  `scripts/headless-gui.sh` passes `ORCA_GTK_DEBUG` through and adds a
  `log:` step.
- **The redesigned Albums page.** Its title row sorts by Date Added,
  Title, Artist, Year, Loved or Most Played and carries Filters and a grid
  and list switch with the design's stroke icons. A Cover size slider
  beside the chips sets the smallest cover, 88 to 184 px, and moves with
  Settings › Appearance › Album grid size; both are saved as `[view]
  album_cover_size`, and the earlier `[appearance] album_tile` is no
  longer read. Columns sit 22 px apart and grow to fill the row. The
  playing album shows three accent bars before its title, and a hovered
  cover dims under a 44 px play button. `scripts/headless-gui.sh` keeps
  settings between runs in `ORCA_HEADLESS_CONFIG` when it is set.
- **One inspector in orca-gtk.** The Details, Lyrics and Signal Path
  panel is one window-wide sidebar, 420 px in every mode, on every page,
  so opening it, changing its mode or changing page never moves the
  content. Pages without a selection of their own show the playing
  Track, and the signal path is read once at startup instead of once per
  page.
- **One top bar in orca-gtk.** The window has a single header on every
  page: Back and Forward over a 32-entry history (also Alt+Left/Right and
  mouse buttons 8/9), a breadcrumb the showing page fills, one library
  search and the inspector toggles. The search filters Albums, Artists,
  Songs and the Playlists overview in place of their own search boxes,
  and opens the results popup elsewhere; focusing it no longer opens the
  popup, and changing page never moves focus into it.
- **Play counts are per recording.** `Runtime.libraryTrackPlayStats`,
  `TrackDetails` and `orca_library_track_play_stats` count the listens of the
  Track's recording through any of its files, no longer of the one file the
  Track plays. A Track without a recording counts no plays. Plays follow
  the file: when a file joins another recording, as two Tracks merging do,
  its listens move with it and the merged Track shows the sum.
- **Sorted song lists page from an index.** A whole-library page sorted by
  rating, love or date added, or by the new play count, last play and year
  sorts, reads only the rows up to the page from version 32's indexes; on
  500,000 Tracks a first page takes 0 to 2 ms. `TrackSort.date_added` orders
  by when the playing file was first seen, the date it shows, instead of when
  the Track row was created.
- **`orca-gtk` has its own dark look.** It forces the dark scheme, maps
  libadwaita's colours onto a grayscale palette with a restrained blue
  accent, sets the interface in Inter and album, artist and Now Playing
  titles in Source Serif 4 (both bundled, SIL Open Font License, installed to
  `share/orca/fonts`), aligns durations and counts with tabular figures, and
  draws albums without covers as initials on a neutral surface instead of a
  coloured gradient. The heart icons now resolve when `zig-out/bin/orca-gtk`
  runs without `XDG_DATA_DIRS`.
- **`orca-gtk`'s sidebar and page headers are reorganised.** The sidebar
  opens with the Orca wordmark and groups its pages under Library,
  Collection, Playback and Library Tools, with Settings pinned at its foot
  and a single Playlists page in place of each playlist. Header bars are
  flat and untitled; each page opens with a serif title and its count, and
  an album, artist or playlist page shows a breadcrumb back to where it was
  opened from, which is the only back control of a pushed page. Tracks is
  now Songs and Preferences is now Settings throughout the interface.
  Loved hearts are red, and the album sort and volume are kept in
  `settings.ini` (`[view] album_sort`, `[playback] volume`).
- **`orca-gtk` fits a 560 px window on every page.** The inspector overlays
  the page below 1100sp, and below 760sp its toggles fold into a Panels
  menu; album, artist and playlist heroes stack below 900sp, and page-title
  actions wrap. Settings stacks its columns below 1260sp and shows its tabs
  as icons below 1040sp. The Songs, Loved and playlist tables sit inside the
  page margins and drop their wide columns below 900sp, Folders gives file
  names the row at narrow widths, and album covers grow or shrink to fill
  the grid row.
- **`orca-gtk`'s keyboard focus is shorter.** In the Songs table and the
  Albums, Artists, Playlists and Queue lists, Tab visits the focused row's
  buttons and then moves on, instead of through every row; the arrow keys
  move between rows. Tab visits the player bar's controls in the same order
  whether or not anything plays, and the Now Playing empty state and
  Settings folder rows are no longer empty Tab stops.
- **`orca-gtk`'s player bar follows the new design.** It sits on the sidebar
  colour under a hairline. The left shows the cover, title, artist and album
  and the heart; the right shows the playing song's format (codec, bit depth
  and sample rate, e.g. "FLAC • 44.1 kHz • Native"), which opens the signal
  path, the output device's name, which opens the device list, an inline
  volume slider and the queue button. The signal path is no longer in the
  device list. A second line, `RG −3.1 dB • DSP •` then the output device,
  shows ReplayGain only while it is applied and DSP only while the equalizer
  or crossfeed changes the signal. When the window is narrow the format line
  and second line hide below 900sp, the device name becomes an icon and the
  volume slider moves into a popover. The play button draws its focus ring
  outside its fill, and the seek handle shows while the seek bar has keyboard
  focus.
- **`orca-gtk`'s inspector and Signal Path follow the redesign.** The
  details panel is now the inspector: flat Audio, Loudness, Identity,
  Metadata and File sections under a serif title, with track and disc as
  "1 of 13", explicit, plays, last played, modified and date added, and
  identifiers behind Show identifiers; empty sections are hidden, and
  feedback and rating stay on rows and in the context menu. The Output tag
  names how the device is attached (USB, PCI, Bluetooth, HDMI or Virtual).
  Three linked header toggles choose the track inspector, lyrics or the
  signal path, saved as before plus `[view] signal_path`; the player bar's
  format button opens the signal path on pages with an inspector. The Signal
  Path sheet has a verdict card, Source, ReplayGain / Gain, DSP, Engine and
  Output stages with expandable technical detail, and a footer naming why
  the path is not bit-perfect; the Engine detail leads with the device's
  block size, and the Gain stage names the correction applied and the track
  gain an album gain replaced, as in `−3.1 dB (from −6.2 dB)`, or says "No
  album gain for this Track" when it falls back. The Device stage shows on
  the first song played, reading the signal path once more when the output
  starts running and only while it is on screen. A narrow window lays the
  inspector over the page instead of hiding it.
- **`orca-gtk`'s Songs page follows the redesign.** It is a dense table with a
  column chooser (saved as `[view] song_columns` and `song_column_widths`), a
  highlighted sorted column, explicit badges, sorting by Date Added, Last
  Played, Play Count and Year, a Filters menu and a List/Browse switch. Every
  filter (genre, year range, lossless or lossy, minimum sample rate, Loved,
  Explicit) is part of the liborca query, also while searching, so the count is
  exact, and the Genre menu lists every genre. Narrow windows hide columns
  without forgetting which ones were chosen and narrow Title and Artist, so the
  title, artist, heart and duration fit at 560 px.
- **`orca-gtk`'s Loved page follows the redesign.** It has a hero with Play,
  Shuffle and More, a cover mosaic and counts of loved songs, albums and
  artists, underline tabs for Loved Songs, Loved Albums and the new Loved
  Artists, a cover column in the songs table, and artist photos when stored.
  Loved Songs numbers rows by position and shows Last Played, Duration under a
  clock and a ••• menu on every row. Loved shows when you last played a song as
  Today, Yesterday or 3 days ago, with the full date in its tooltip.
- **`orca-gtk`'s Now Playing follows the redesign.** Three lyric lines sit under
  the transport, the previous and next faded around the current one; the page
  looks lyrics up itself, and clicking them opens the Lyrics inspector. Up
  Next shows five rows and View Full Queue, Track Info adds Genre, "1 of 16"
  and Format, and its "…" opens the track inspector; the title opens its
  album. The inspector replaces the Up Next column rather than covering the
  page, and Now Playing has an empty state. The inspector's Metadata section
  shows the genre. The cover is large over a blurred,
  darkened copy of it, with a Now Playing overline, the title in serif, the
  artist and the album and year as links, a heart and a more button, a seek
  bar and a transport that mirrors the player bar's: both are refreshed from
  one place, so either drives playback and seeking, dragging included, and
  the other follows. Secondary and tertiary text over the covers behind
  album, artist and Now Playing headers is white at reduced opacity, and the
  tertiary text colour is lighter everywhere, so both stay above 4.5:1 on a
  light cover.
- **`orca-gtk`'s Queue page shows Now Playing, Up Next and Previously Played.**
  Previously Played shows when each song played and can be hidden, shown again
  or cleared. Up Next entries reorder by dragging, with liborca's queue move; a
  song already lined up to play cannot be moved, and the page says so. Delete
  removes the focused entry, and queue menus offer Play Next, Play Later and
  Save Queue as Playlist…, which saves the playing song and everything up next
  and opens the playlist. Rows are flush, with the position or a play mark, a
  thumbnail, the title over the artist, the heart, rating stars on hover or once
  rated, the duration and a remove button on hover, under the song count, length
  and Clear.
- **`orca-gtk`'s Albums grid and album page follow the new design.** The
  grid is denser, with each album's year under its artist, a play button and
  a more button on hover or focus, and a Sort by menu in the title row.
  Chips under the title choose All Albums, Recently Added, Loved, High
  Resolution or Needs Review, a Filters popover narrows by year, format and
  artwork, and a Grid/List switch offers a list with a column chooser, all
  backed by liborca's Release query; the grid keeps at least two columns so
  it fits a 560 px window. An Album Inspector shows the album's overview,
  MusicBrainz identity and description when no song is selected. The album
  page opens with a larger cover over a blurred, darkened copy of it, the
  release type (or Compilation, or Album) as an overline, the artist as a
  link, a meta line of year, genres, song count and length, the release's
  description from Wikipedia in three lines with More and its attribution,
  and a more button beside Play, Shuffle and
  the heart; its track list is flush with the page under a # / Title /
  duration header, marks the playing track with a play glyph and an accent
  title, and shows each row's rating stars and more button on hover. A
  narrow window stacks the album page's cover above its title.
- **`orca-gtk`'s Artists grid and Artist page follow the new design.**
  Artists shows a grid of round artist photos (or album covers, or
  initials) or a list of flush rows with a round cover thumbnail, loaded as
  each row is shown, and each artist's album and song counts. It sorts by
  name, most tracks, recently added or recently loved, with a search field
  under the title, and a genre chip when opened from a genre. The Artist
  page shows the artist's photo with its credit (else the cover of their
  most played own release), genres, a biography excerpt, a love button,
  ListenBrainz listeners, top tracks by plays, Albums, EPs & Singles and
  Appearances, and related artists; its stats come from liborca's artist
  totals, and each row's See All opens Albums scoped to the artist and
  kind, with a chip that removes the scope. A related artist's tile shows
  the photo the artist-info fetch kept, including for artists not in the
  library, with its credit and licence in the tooltip, and initials when
  there is none; related artists' names wrap between words, at most two
  lines. The page fetches artist info the first time it opens, which a
  Settings switch turns off. The inspector shows the artist's overview,
  biography and links. A narrow window hides the counts and stacks the
  sections.
- **`orca-gtk`'s Playlists pages follow the new design.** The sidebar lists
  a single Playlists page. The overview has All, Created by Me and Smart
  tabs, a Pinned section, type and sort menus (Recently Updated, Name or
  Recently Created) and a grid or list layout; each card has a mosaic of
  the playlist's first four album covers or a smart tile, its song count
  and length, pins, kind, unavailable entries and when it was updated.
  Hovering a card shows a play button and a more button with Play, Shuffle,
  Rename…, Export… and Delete…. The header has a search over playlist names,
  Import… and New Playlist; with no playlists the page offers both. A
  playlist's page opens with the mosaic over a blurred cover, a Playlist
  overline, its description, love, the song count, length and unavailable
  count, Play, Shuffle and a more button, whose menu has Pin, Love and Edit
  Details, and lists its songs in the Songs table numbered by position, with
  the inspector for the selected song, which shows the playlist's details
  and tags. A narrow window stacks the mosaic above the name.
- **`orca-gtk`'s Settings is a page following the new design.** The
  sidebar's Settings item, the main menu and Ctrl+, open it in the content
  area instead of a dialog. Seven tabs (General, Library, Playback, Sound,
  Listening, Appearance, Advanced) sit under a pill tab bar, each a set of
  cards with an icon, a title and a one-line description, in two columns or
  one when the window is narrow; the tab last open is kept until the app
  quits. Each folder has Rescan, Show in Files and Remove, with Add Folder…
  and Rescan All Folders under the list. The AcoustID key and the
  ListenBrainz token use the same card, with a link to
  listenbrainz.org/settings for the token; saving a key or token clears and
  hides the field. Playback's ReplayGain setting offers Off, Track and
  Album. Sound has an output device picker, which picks up new devices when
  the tab opens, and Audio Information beside the equalizer, which switches
  between Off, Graphic and Parametric. Appearance choices (artwork
  influence, album grid size, density, inspector, reduced animation) are
  saved in `settings.ini`; Advanced copies the database path and
  diagnostics, and an About card shows the version and the audio backend.
  An equalizer edit, a volume change or an album-size change still settling
  when Orca quits is saved and holds at the next launch.
- **`orca-gtk`'s Library Health and Matches pages follow the new design.** A
  serif header shows when the library was last analyzed, with an Analyze
  Again split button (Analyze Again, which looks for duplicates once
  analysis succeeds; Find duplicates only; Verify recording IDs). A summary
  counts the items that need attention, the same issues as the sidebar
  badge, beside album, song, artist and library-size totals. Each kind of
  issue has a card in `libraryHealthSummary`'s order, most severe and then
  most frequent first: a symbolic icon tinted by severity, the kind's name, a
  one-line explanation, its file count and one action (for recording
  mismatches, Review, which opens Matches). Expanding a card lists that
  kind's files 512 at a time with Show more, each keeping its Fix, Fetch
  Cover, Compare, Review, Show in Files and Dismiss actions. Open cards, how
  far each has loaded and the scroll position survive a reload, such as
  after a dismiss or a fix. Files not yet analyzed have their own card, with
  Analyze, in place of the banner. Kinds with no issues sit behind "Show
  kinds with no issues", and a side panel explains the opened kind. Matches
  and its Corrections are cards of flush rows under the page title.
- **Faster path sort and file filters on Tracks.** Schema version 43 adds
  `locations_held`, an index of the locations that are not missing, so a
  Track's has-file test and the path sort read no table rows. A path sort
  finds the Tracks with no held location from `files`, and a Tracks count,
  total or full-sort page filtered by codec, lossless, sample rate or date
  added, with no Artist, Release, genre or loved filter, collects the
  matching files once instead of probing one per Track. At 522,432 Tracks a
  whole-library path page takes 150 ms instead of 274 ms, and the totals for
  FLAC above 48 kHz added in the last year 61 ms instead of 238 ms. Results
  do not change.
- **Colour tokens in one place.** Every `orca-gtk` colour token is defined
  in the stylesheet's top block.

### Fixed

- **Hover and scrolling no longer restyle hidden pages.** orca-gtk kept
  every page it had built, and the views Albums, Artists, Tracks and Loved
  were not showing, visible to GTK's style system while they were off
  screen, so restyling the window walked them as well. A page or view that
  is not shown is now hidden once the crossfade to the new one ends, and
  shown again when it is selected, keeping its scroll position, selection
  and focus. Pages not yet visited are styled one per frame once the window
  is idle, so a first visit is no slower than before.
- **Settings opens at once.** orca-gtk's Settings page rebuilt all eight
  tabs on every visit, about 60 ms each time. It now builds each tab the
  first time it is selected and keeps it, along with the selected tab.
  Returning refreshes only the shown tab's values that can change elsewhere
  (output device, library folders and counts, duplicates, folder watching,
  buffer and cache size, About facts), and each other tab when it is next
  selected. Leaving still saves pending changes and applies the equalizer.

- **Page changes no longer stutter.** In orca-gtk, opening Now Playing, an
  album, an artist or a playlist, going Back from one, and scrolling an
  album page past its top each froze the window for about a quarter of a
  second, because the top bar's switch between sitting above the page and
  floating over it restyled every page, hidden ones included. The content
  now always extends under the bar, pages that sit below it take the bar's
  height as a top margin, and the bar's look over a backdrop is styled on
  the bar alone. Styles also no longer read the corner radii and transition
  timing through custom properties, which GTK re-parsed for each widget.

- **Pages fill wide windows.** In orca-gtk, Library Health, Matches, Match
  Review, Write to Files, Activity, Queue, Scan and the album and artist
  pages now fill the window to its gutters, with or without the inspector
  open, as Loved and the browse pages already did. Before, each capped its
  content at the 1440-pixel design's width, between 796 and 1224 pixels,
  and pinned it to the left, so on a wide window the rows stopped at a
  third of the width and the header's controls sat mid-page. Row columns
  keep their fixed widths and text columns share the extra room; prose
  keeps a readable measure.
- **Pages fit small screens.** orca-gtk now fits a 900-pixel-wide output,
  and no page clips at 1440 pixels with the inspector open. Before, the
  window could not be narrower than 1348 pixels, because the page stack
  sized every page to the widest one, Match Review, even while hidden. The
  stack now sizes only the page shown. When a page is too narrow for its
  side-by-side layout, the artist page stacks Top Tracks above Albums; Change History and Duplicates
  stack their list above the detail; Match Review stacks its two tables
  and then its header; and the scan page stacks its four stages. The
  About tab in Settings moves its buttons under its text when the tabs
  turn to icons.
- **Artist and album info fetches end within a minute.** An artist or
  album info Job now stops asking once a minute has passed, and each
  request's timeout ends there, so a slow or silent service can no longer
  hold the Job for many minutes. Before, a fresh artist fetch asked for
  related artists' photos and up to 24 release-group covers one after
  another with a 30-second timeout each, and orca-gtk kept the Fetch
  artist info button greyed out until all of it ended. Photos and covers
  left over are fetched the next time. A fetch that finds a service in use
  by another fetch now waits for it until that minute is up instead of
  ending at once as busy, which is what happened to an artist opened from
  one of their albums while the album's info was still being fetched.
  `--include-releases` and the genre fill keep no time limit.
- **Every route to an artist page fetches its info.** In orca-gtk, an
  artist page asks for the artist's info each session whenever fetching is
  on, not only when nothing is stored, and the inspector offers Fetch
  artist info while the stored info is a failed fetch. Before, a busy or
  failed fetch stored an empty record, and the page then neither fetched
  again nor showed the button. A failed fetch is tried again the next time
  the page opens, and a lookup that cannot start says so instead of being
  dropped.
- **Artist info shows as soon as it is stored.** An artist info Job now
  reports each part it stores (`jobArtistInfoStores`,
  `orca_job_artist_info_stores`, and `stored n= at_ms=` lines from
  `orca-cli artist-info --fetch`), and orca-gtk's artist page and
  inspector show the biography, photo, origin and links as soon as they
  arrive, within a few seconds. Before, nothing appeared until related
  artists' photos and release group covers had also been fetched, up to a
  minute later.
- **Album info is fetched again after a failed fetch.** In orca-gtk, an
  album page asks for its info each session, not only when nothing is
  stored, and asks again on the next visit after a fetch that failed.
  Before, a busy or failed fetch was never retried that session, and a
  lookup dropped because too many were running was never made. A lookup
  that cannot start now says so.
- **Lyrics fetches wait for LRCLIB.** A lyrics fetch that finds LRCLIB in
  use by another fetch waits for it for up to a minute instead of ending
  at once as busy.
- **Opening too many artist pages says so.** In orca-gtk, opening a ninth
  artist page while eight are open now says to go back and close one.
  Before, the page opened but never updated its info or playing state.
- **Shortcuts no longer highlight the sidebar.** In orca-gtk, a shortcut
  such as Ctrl+K, Ctrl+, or Escape no longer draws focus rings. Before, it
  outlined the focused sidebar item, the sidebar and the whole window. Every
  widget around the focused one matched the focus ring's style, which now
  draws the ring on the focused widget only. GTK also showed the ring whenever
  a key moved focus, so a shortcut that opened a page, the palette or a
  dialog revealed it. The window now hides the ring again for any key other
  than Tab, Shift+Tab, the arrows, Home, End, Page Up and Page Down, and
  those still show it.
- **Now Playing leaves the lyrics view.** In orca-gtk, the Up Next,
  Lyrics and Info tabs and the Clear button at the top of the Now Playing
  panel respond to clicks again. The top bar's row spanned the whole
  window over the panel and took those clicks, so after Show all lyrics
  the panel stayed on the lyrics and the three-line quote under the cover
  did not come back.
- **Album, artist and playlist pages have no top bar band.** In orca-gtk,
  an album, artist or playlist page draws its blurred backdrop to the top
  of the window, with back, forward, the breadcrumb and the search field
  over it, as the design shows, instead of under a solid bar. Once an
  album or artist page scrolls, the bar fades to the page colour so its
  controls stay legible over the content.
- **Headless GUI runs keep their state private.** `scripts/headless-gui.sh`
  sets `XDG_STATE_HOME` to a directory inside its private runtime
  directory, as it already did for `HOME` and the XDG config, data and
  cache directories, so `orca-gtk`'s log file no longer lands in the
  user's own state directory.
- **A Track keeps its id when its file moves.** When an edit, a retag,
  an accepted match or Match Album puts a file on another album or
  position that no Track holds, liborca moves its Track there instead of
  deleting it and adding a new one. The play queue, pending listens,
  lyrics and frontends holding the id keep working, and orca-gtk still
  marks the playing track after Match Album.
- **Match Album stays on the album page.** In orca-gtk, when Match Album
  gives an album a new release id, its open page rebuilds under the new
  id instead of closing, Back and Forward follow it, and its grid tile is
  replaced in place without the grid reloading.
- **Swipe back keeps Back and Forward in step.** In orca-gtk, a swipe
  back, Escape or the breadcrumb's parent button on an album, artist,
  genre or playlist page now steps back in history like the Back button:
  Forward reopens the page just left, where before it was disabled and
  Back reopened that page.
- **No warnings when closing the window.** Closing orca-gtk with the
  window's close button no longer logs GTK critical warnings: song table
  headers, grid columns, scroll restores and the playback tick stop
  touching widgets once the window is gone.
- **The inspector remembers your track on each page.** Coming back to an
  album, artist or genre page shows the track last chosen there again,
  while it is still one of the page's tracks.
- **Less redrawing while playing.** The seek slider moves only when its
  knob would move a pixel or the time shown changes, and the play button
  keeps its icon instead of resetting it every tick, so the window draws
  about 4 frames a second during playback instead of 10.
- **Fetching a cover or matching an album keeps your place.** The album
  page stays open and the Albums list keeps its scroll position; the
  fetched cover replaces the placeholder everywhere it shows, including
  pages opened before the fetch.
- **Lyrics layout warnings.** Resizing the lyrics view no longer logs
  GtkListBox allocation warnings.
- **No Show Album or Show Artist for the page already open.** The context
  menu leaves out Show Album on an album's own page and Show Artist on an
  artist's own page.
- **Context menu crash.** Choosing Show Artist, Show Album or another
  context-menu item that rebuilt the page no longer crashes orca-gtk: the
  closed menu was freed with the page before it was detached.
- **Artist photos appear everywhere once fetched.** The Artists grid and
  list, search results, genre pages and Loved show an Artist's photo as
  soon as it is fetched instead of an album cover until restart. Artist
  photos load off the GTK thread, and grid tiles no longer query the
  library for a fallback cover.
- **Space pauses in orca-gtk wherever focus is.** A focused button, row or
  tile no longer takes Space to activate itself; it toggles playback
  unless focus is in a text field, a dialog or a popover.
- **Headless test audio.** `scripts/headless-audio.sh` no longer times
  out waiting for WirePlumber: under `pipefail`, `pw-dump | grep -q`
  failed whenever `grep` exited before `pw-dump` finished writing.
- **A ten-band equalizer band turned back on no longer rings.** Turning
  bands off shortened the filter cascade but kept the history of the slots
  past its end, and a band turned on again later started from that stale
  history. A slot past the previous cascade's end now starts clear. History
  now follows the filter, not its slot, so turning one filter or band off or
  on no longer hands the filters after it their neighbour's history.
- **Track search text is no longer FTS5 syntax.** Quotes, `*`, `-`,
  brackets, `NEAR`, `OR` and column filters typed into a Track search
  (`libraryTrackQuery`, `orca-cli tracks --filter`, `orca-gtk`'s search box)
  failed the query or changed its meaning; each word now matches as the
  beginning of a word, and text with no word matches nothing.
- **A listen and the now-playing Track name the entry that was heard.**
  `playerStatus` and listen tracking paired the audible entry serial with the
  Track under the queue cursor, and `playerNowPlaying` named that Track, but
  the engine stores the cursor after the serial, so a read around a track
  change could name the entry before it and credit its listen to the wrong
  Track. The Track now comes from the serial through the queue's serial
  records; a listen sample whose serial moves while it is read is skipped.
  A hard load (start, skip, seek re-open, format switch) records the new
  serial in the queue before it becomes audible, so a read during one no
  longer names no Track.
- **Turning shuffle off no longer shows the wrong Track as playing.** Toggling
  shuffle left each serial record at its old position, so the playing entry
  resolved to whichever Track the new order put there, and the engine moved
  the cursor onto it. Records now move to their entry's new position, and
  removing an entry forgets its record.
- **An unreadable file no longer adds an untitled album.** A file with an
  `unreadable_file` issue was projected like any other, so it appeared as a
  Track on an untitled Various Artists Release in albums, artists and counts.
  It now projects no Track: it stays in Folders as unreadable and in Library
  Health, a Track it backed is pruned with any Release or Artist left empty,
  and it projects again once a scan reads its new bytes. Property backfill
  reprojects a file it finds unreadable. An existing library converges on
  the next `orca-cli project`.
- **Copies of one album in two folders no longer strand a file.** Files of
  one Release in different folders were projected folder by folder, so a file
  at a position another folder's file already held took the Track over, and
  the earlier file was left with no Track (`duplicates --group` showed
  `track=-`). Each folder's projection now positions the Release's files from
  other folders together with its own, under the rules one folder follows:
  the same performance shares the Track, its best encoding preferred, and a
  different one moves to the next free number with a `technical_anomaly`
  issue, whichever folder projects first. An existing library converges on
  the next `orca-cli project`, keeping the Track's rating.
- **orca-cli output redirected to a file follows what is there.** Standard
  output and standard error wrote at offset 0 of a regular file, so
  `{ echo header; orca-cli stats DB; } > out` lost the header and a second
  command's output overwrote the first's. Both now write at the file's
  current offset. `zig build test` checks it with
  `scripts/check-cli-stdio.sh`.
- **An MP3 comment written by ffmpeg is read.** ffmpeg stores an MP3's
  comment as a `TXXX` frame described `comment`, so those files showed none.
  With no undescribed `COMM`, the ID3v2 reader takes the comment from that
  `TXXX`, in any case; a `COMM` wins. A tag write that changes the comment
  replaces that `TXXX` with the `COMM` frame.

## 0.8.1 - 2026-10-02

Ships Library schema version 30, unchanged from 0.8.0.

### Added

- **Tag-write plans skip a file whose folder Orca cannot create files in.**
  `TagWriteSkipReason.folder_not_writable` (C
  `ORCA_TAG_WRITE_SKIP_FOLDER_NOT_WRITABLE`, 3) leaves such a file out of the
  plan, since the write needs the folder for its staged copy. `orca-cli
  write-tags` prints it as a skip, and `orca-gtk` counts skipped files by
  reason and says when every file's folder is the problem.
- **A failed tag write says which file it stopped at and why.**
  `Runtime.jobTagWriteFailure` returns a `TagWriteFailure` (file ID, action
  index, `TagWriteFailureReason`: `permission_denied`,
  `read_only_file_system`, `no_space`, `changed_since_plan` or `other`), and
  the C ABI's `orca_job_tag_write_failure` fills an `orca_tag_write_failure`.
  `orca-cli write-tags` prints a `failed` line with the file's path, and
  `orca-gtk`'s toast names the reason.

### Fixed

- **The mutation journal keeps the error a failed tag write recorded.**
  Recovery rolled a `failed` operation back with the error `recovered`,
  overwriting the real one, such as `AccessDenied`, the moment the write
  failed.
- **A failed tag write reports why.** The tag-write Job dropped the
  executor's error, so every failure read "Writing tags failed" with no cause.
- **The C ABI smoke passes whatever order a file system lists the
  fixtures in.** Its coverless Track, `Opus Reference`, is also backed by
  `covered-reference.opus`, so on tmpfs and CI it read that copy's cover. It
  now uses `WAV Reference`, and checks a coverless Release in a Library of
  its own.

## 0.8.0 - 2026-10-02

Ships Library schema version 30. Close every Orca process before upgrading.

### Added

- **Tag writes store the release, release-group, release-track and
  album-artist MusicBrainz IDs.** `metadata.Field` gains
  `musicbrainz_release_id`, `musicbrainz_release_group_id`,
  `musicbrainz_release_track_id` and `musicbrainz_album_artist_id`, which
  `libraryEditTracks` and a tag-write plan accept only as lowercase UUIDs.
  FLAC writes them as `MUSICBRAINZ_ALBUMID`, `MUSICBRAINZ_RELEASEGROUPID`,
  `MUSICBRAINZ_RELEASETRACKID` and `MUSICBRAINZ_ALBUMARTISTID`; MP3 and ADTS
  as Picard's `TXXX` frames, replacing only a `TXXX` under a description the
  reader takes the ID from and keeping every other frame byte for byte, in
  ID3v2.3 and 2.4.
- **Accepted matches store MusicBrainz's metadata.** An accept stores the
  title and artist on every file of the Track, and once every Track of a
  Release names one MusicBrainz release, by an accepted match or its tag,
  the album, album artist, date, disc and track numbers and the release,
  release-group, release-track and album-artist IDs (`compilation=1` for
  Various Artists), as unlocked provider values that keep a user's locked
  edit and that tag writes store only where a file has no tag. Accepted
  files are reprojected, so an album can regroup under a new Release id;
  its fetched cover follows it. Matching looks up the release of each
  search's best proposal (`MusicBrainz.lookUpRelease`, cached 30 days)
  before recording it, and Match Album points the album's matches at the
  release most of its files list. `Runtime.libraryApplyMatchedRelease` and
  `orca-cli apply-release` apply a Release that came to agree without an
  accept. `MatchProposal` and `orca-cli matches` carry the release's title,
  artist, date, disc and track IDs; `TrackDetails` and `orca-cli track` the
  release, release-group, release-track and album-artist IDs with their
  source; `orca-gtk` shows the album and date on the Matches page and the
  IDs in the details panel.
- **Re-identify.** `MatchRequest.mode` (`MatchMode`: `search`, `reidentify`)
  searches one Track or one Release again with `.reidentify`, ignoring the
  recording ID in effect and earlier searches. A candidate for the recording
  ID already in effect is counted in `MatchStats.confirmed` instead of being
  proposed, dismissed proposals stay dismissed, and a Release's proposals are
  aligned as Match Album aligns them. It is refused for the whole library and
  with `accept_minimum_confidence`. `orca-cli match` gains `--track=ID` and
  `--reidentify`, and prints `confirmed=` in that mode. `orca-gtk` offers
  Re-identify on a single song's menu and Re-identify Album on an album's.
- **Verification.** `MatchRequest.mode = .verify` checks each identified
  file's recording ID against what AcoustID hears in its fingerprint, one
  Release at a time: `agrees` at a score of 0.5, `disagrees` when another
  recording reaches 0.9, else `unconfirmed`, or `no_fingerprint`. Outcomes
  are stored per file in `recording_verifications` and checked again once
  the file's bytes or recording ID change. A file that disagrees is proposed
  the recordings heard, unless its ID is the user's own edit. It needs
  AcoustID (`error.AcoustIdRequired`). `MatchStats` gains `verified`,
  `agreed`, `disagreed`, `unconfirmed`, `skipped` and `correction_groups`,
  and `Runtime.libraryTrackVerification` returns a Track's outcome.
  `orca-cli verify` runs it and `track` prints the outcome. `orca-gtk`
  offers Verify on a single song's menu and Verify Album on an album's, and
  its details panel shows the outcome under the recording ID, with Verify
  while the song is unverified or its outcome is out of date.
- **Corrections.** A proposal for a file whose recording ID in effect it
  would replace is a correction, `MatchProposal.corrects` naming that ID.
  When a verified Release has a MusicBrainz release ID, the corrections of
  its files whose recording is on it form one album group with their
  positions, listed by `Runtime.libraryCorrectionGroups` and accepted or
  dismissed only whole by `libraryAcceptCorrectionGroup` and
  `libraryDismissCorrectionGroup`. `orca-cli` has `corrections`,
  `accept-correction` and `dismiss-correction`, and `matches` prints the
  replaced ID last. `orca-gtk`'s Matches page lists album groups under
  Corrections, each song's current and proposed title and position, with
  Accept All and Dismiss All, and a correction's row names the ID it
  replaces.
- **Dismissable health issues.** `Runtime.libraryDismissHealthIssue` and
  `orca-cli health-dismiss` hide one kind of issue on one file until the
  file's bytes change; `libraryRestoreHealthIssue` and `health-restore` show
  it again. The page and count leave dismissed issues out.
- **Each health issue names the action that resolves it.** `HealthIssue`
  carries `action` (`HealthAction`: `match_or_edit`, `fetch_cover_art`,
  `compare_duplicate`, `review_correction`, `reveal_file`), the lowest
  `track_id` its file backs, that Track's `release_id`, and for a duplicate
  the other file in `related_file_id`. `Runtime.libraryHealthFile` returns
  the file behind an issue (`HealthFile`). `HealthIssue`, `HealthIssueKind`,
  `HealthSeverity`, `HealthAction` and `HealthFile` are exported from
  `liborca`.
- **`recording_mismatch` health issue.** Verification raises it, as a
  warning naming the recording AcoustID heard and its score, for a file it
  leaves a pending correction for, and clears it for any other outcome; accepting
  the correction, or dismissing the file's last pending proposal, clears it.
- **`orca-gtk` acts on Health issues.** Each row offers its issue's action:
  Fix (Match or Edit Tags), Fetch Cover, Compare (the two files of a
  duplicate side by side, each with Reveal; nothing is deleted), Review (the
  correction in Matches) or Show in Files, and Dismiss with Undo. A banner
  offers Analyse while files are not analysed. Accepting a correction, alone
  or as an album group, on the Matches page offers the tag write for the
  corrected songs. The page reloads when matching, analysis or duplicate
  finding finishes.
- **Idle maintenance verifies the library.** `Runtime.libraryMaintenance`
  (`MaintenanceOptions`, off until enabled) has `pump` verify one Release's
  recording IDs, or at most 20 Tracks on no Release once every Release is
  verified, every `interval_ms` (default 5 minutes). A unit starts only while
  every Player is stopped, paused or played out and no other job runs, and
  never while AcoustID or MusicBrainz is blocked or backing off. Disagreements
  land in Health as `recording_mismatch`. `libraryMaintenanceStatus` returns
  a `MaintenanceStatus`, and `jobOrigin` says whether a job was started by
  the host, a watcher or maintenance (`JobOrigin`). A matching, cover-fetch
  or AcoustID submission job started while a unit runs cancels the unit and
  starts once the unit has finished; scans, tag writes and root removal
  never wait for a unit. `orca-cli watch --maintenance[=MS]` runs it
  headless and prints a `maintenance:` line per unit.
- **`orca-gtk` turns on idle maintenance in Preferences.** An Idle
  maintenance switch under Library > Maintenance, off by default and saved in
  `settings.ini`, needs Match by audio fingerprint; its subtitle says when the
  next album is checked, how many were, or that AcoustID is unavailable or
  busy. Health and Matches reload when a unit finishes, without a toast.
- **Album love and loved listings.** `Runtime.librarySetReleaseLove` loves
  or clears Releases and returns a `ReleaseLoveChange`; the love is stored
  in the Library's new `release_loves` table (migration 30), never in a file,
  is never sent to ListenBrainz and changes no song's feedback. It follows
  its album when a regrouping gives the Release a new id, as a fetched cover
  does. `ReleaseSummary.loved`, `ReleaseQuery.loved_only` and
  `ReleaseSort.loved` list loved albums, most recently loved first;
  `TrackQuery.loved_only` and `TrackSort.loved` do the same for loved songs,
  where a clear not yet sent is not a love. `orca-cli
  love-release DATABASE IDS [--clear]`, `releases --loved` (a loved Release
  ends in `loved`) and `tracks --loved [--sort loved]`.
- **Album love and a Loved page in `orca-gtk`.** An album page has a heart
  beside Play and Shuffle, and album menus offer Love Album or Remove Album
  Love, with their song entries renamed Love All Songs, Dislike All Songs,
  Remove Love from All Songs and Remove Dislike from All Songs. A Loved
  sidebar page switches between loved albums and loved songs, most recently
  loved first.
- **The C ABI browses by love and rating, and describes a Track.**
  `orca_track_view` gains `feedback` and `has_rating`/`rating`,
  `orca_release_view` gains `loved`, and `orca_track_query` gains
  `loved_only` and the sorts `ORCA_TRACK_SORT_RATING` and
  `ORCA_TRACK_SORT_LOVED`. `orca_library_browse_releases` and
  `orca_library_release_count_matching` take an `orca_release_query` with an
  `orca_release_sort` and `loved_only`; `orca_library_browse_artists` and
  `orca_library_artist_count_matching` take an `orca_artist_query` with a name
  filter. `orca_library_track_get` returns an `orca_track_summary_view`,
  `orca_library_track_details` an `orca_track_details_view`, and
  `orca_library_track_play_stats`, `orca_library_listens_recorded` and
  `orca_library_unanalyzed_count` the play counts, listens recorded and files
  still to analyse. `orca_job_kind` names matching, AcoustID submission
  and tag-write jobs.
- **The C ABI loves, hates and rates Tracks and loves albums.**
  `orca_library_set_feedback` and `orca_library_track_feedback` set and read
  an `orca_feedback`, `orca_library_set_rating` rates Tracks 1 to 100 or
  clears with 0, and `orca_library_set_release_love` loves or clears whole
  Releases. Each edit reports an `orca_change_count` of updated and skipped
  ids.
- **The C ABI edits the queue.** `orca_player_queue_jump` plays the entry
  at a position, `orca_player_queue_insert_next` queues Tracks to play next,
  and `orca_player_queue_remove` removes an entry, refusing the one playing
  and the one lined up after it with `ORCA_STATUS_INVALID_STATE`.
  `orca_player_query_queue_tracks` pages the queue as track views in
  playback order, and `orca_player_queue_stats` returns an
  `orca_queue_stats` of the engine's entry, transition, open-failure and
  decode-error counts.
- **The C ABI sets the equalizer and crossfeed and reports the signal
  path.** `orca_player_set_equalizer` and `orca_player_equalizer` set and read
  an `orca_equalizer` of ten band gains and a preamp, NULL turning it off;
  `orca_equalizer_preset_get` fills one from an `orca_equalizer_preset`.
  `orca_player_set_crossfeed` and `orca_player_crossfeed` set and read the
  crossfeed amount. `orca_player_signal_path` hands an
  `orca_signal_path_view` of the source and output `orca_pcm_format`s, codec,
  ReplayGain, equalizer, crossfeed, volume, device rate and the
  `orca_signal_reason`s the path is not bit-perfect.
- **The C ABI manages, imports, exports and plays playlists.**
  `orca_library_query_playlists`, `orca_library_create_playlist`,
  `orca_library_rename_playlist`, `orca_library_delete_playlist`,
  `orca_library_query_playlist_entries`, `orca_library_playlist_insert`,
  `orca_library_playlist_remove`, `orca_library_playlist_move`,
  `orca_library_import_playlist`, `orca_library_export_playlist` and
  `orca_player_play_playlist`, with `orca_playlist_view`,
  `orca_playlist_entry_view`, `orca_playlist_import`, `orca_line_callback`
  and `orca_playlist_path_style`.
- **The C ABI reads cover art.** `orca_library_track_artwork` and
  `orca_library_release_artwork` read a cover on the calling thread and hand
  an `orca_image_view` of its bytes, media type and `orca_artwork_kind`.
  `orca_library_request_artwork` asks the Library's artwork thread for a
  Track's or Release's cover by `orca_artwork_subject`, which wakes the host
  when it finishes; `orca_library_take_artwork` collects one
  `orca_artwork_result_view` per call, and `orca_library_cancel_artwork` skips
  a request not yet started.
- **The C ABI acts on health issues.** `orca_library_query_health_items`
  pages the same issues as `orca_library_query_health_issues`, which stays,
  as `orca_health_item_view`s that add the file, Track, Release and related
  file ids, the `orca_health_severity` and the `orca_health_action` that
  resolves each. `orca_library_dismiss_health_issue` hides an issue until its
  file's bytes change, `orca_library_restore_health_issue` shows it again, and
  `orca_library_health_file` describes the file behind an issue as an
  `orca_health_file_view`. `orca_health_issue_kind` names the kinds.
- **The C ABI edits and writes tags.** `orca_library_edit_tracks` sets or
  clears Orca's locked values for Tracks' files and
  `orca_library_query_track_edits` reads them. `orca_library_plan_tag_write`
  shows an `orca_tag_write_plan_view` with an approval digest,
  `orca_library_start_tag_write` writes the plan with that digest as an
  `ORCA_JOB_KIND_MUTATION` job, and `orca_library_discard_tag_write` drops it.
  `orca_library_undo_tag_write` restores the originals from their backups and
  `orca_library_prune_tag_write_backups` deletes them. New statuses
  `ORCA_STATUS_ALREADY_DONE`, `ORCA_STATUS_NEEDS_RECONCILIATION` and
  `ORCA_STATUS_GONE` report an undo already done, one a person must decide,
  and one whose backups were pruned.
- **The C ABI configures providers and reads credentials from the host.**
  `orca_runtime_set_client_identity` names the host to MusicBrainz, AcoustID
  and ListenBrainz, `orca_runtime_set_provider_server` points an
  `orca_provider_service` at another `https` or loopback server, and
  `orca_runtime_set_acoustid_client_key` sets the AcoustID application key.
  `orca_runtime_set_credential_callback` installs an `orca_credential_fn` that
  liborca's worker threads call for a token or key, which liborca never
  truncates and zeroes after use; `orca_credential_result` tells absence from
  an unavailable store. `orca_library_scrobbler_credentials_changed` has the
  listen worker read and validate a changed ListenBrainz token.
- **The C ABI matches, verifies and corrects.** `orca_library_start_match`
  takes an `orca_match_options` with an `orca_match_mode` and
  `orca_library_start_cover_art_fetch` fetches a Release's cover, both as
  `ORCA_JOB_KIND_METADATA_LOOKUP` jobs whose `orca_match_stats`
  `orca_job_match_stats` reads, with the `orca_acoustid_use`,
  `orca_busy_service` and `orca_cover_art_outcome`.
  `orca_library_query_match_review`, `orca_library_match_review_count`,
  `orca_library_unidentified_count`, `orca_library_query_match_proposals`,
  `orca_library_accept_match`, `orca_library_dismiss_match`,
  `orca_library_confident_match_count`,
  `orca_library_accept_confident_matches` and
  `orca_library_apply_matched_release` review and accept proposals;
  `orca_library_track_verification` hands an
  `orca_track_verification_view` with its `orca_verification_outcome`, and
  `orca_library_query_correction_groups`,
  `orca_library_accept_correction_group` and
  `orca_library_dismiss_correction_group` act on album groups of
  corrections.
- **The C ABI submits recording IDs to AcoustID.**
  `orca_library_start_acoustid_submission` starts an
  `ORCA_JOB_KIND_ACOUSTID_SUBMISSION` job whose `orca_submission_stats`
  `orca_job_submission_stats` reads, with its `orca_submission_outcome`.
  `orca_library_acoustid_submittable_count` counts the files it would send,
  and `orca_library_query_acoustid_submittable` pages them by file id as
  `orca_acoustid_submittable_view`s. A submission beside a matching job is
  `ORCA_STATUS_BUSY`.
- **The C ABI scrobbles to ListenBrainz.** `orca_library_set_scrobbling`
  turns sending a Library's listens and feedback on or off, offline or with
  Now Playing; a second Library while one scrobbles is
  `ORCA_STATUS_INVALID_STATE`. `orca_library_scrobbler_status` hands an
  `orca_scrobbler_status_view` of the `orca_scrobbler_state`, user name, last
  error, retry and block times and queue counts.
- **The C ABI runs idle maintenance and says who started a job.**
  `orca_library_set_maintenance` turns a Library's idle maintenance on or
  off with an `orca_maintenance_options`, and
  `orca_library_maintenance_status` hands an `orca_maintenance_status` with
  its `orca_maintenance_state`, `orca_maintenance_block` and the last unit's
  `orca_match_stats`. `orca_job_origin_get` returns a job's
  `orca_job_origin`, and `orca_job_reconcile_root` the root a reconcile job
  walks.
- **`zig build test` checks `orca.h` against liborca.** `tests/c_abi_layout.zig`
  translates the header and compares every `orca_*` struct and union with its
  `c_api.zig` counterpart: size, alignment, field count, and each field's
  offset, size and integer, float or pointer kind. Every enum constant is
  compared with the value the C API produces or accepts under the same name,
  and an extern type or constant on either side that no check covers fails
  the test.
- **`zig build test` checks that the C ABI reaches the Zig API.**
  `scripts/check-abi-coverage.sh` (`zig build abi-coverage`) fails when a
  public `Runtime` method is neither called from `liborca/c_api.zig` nor
  listed with the reason it is not, and when a listed method is gone or
  has come to be called.

### Changed

- **Library schema version 29.** Adds `health_dismissals` and
  `library_health_issues.related_file_id` with its index.
- **Breaking: `orca-cli health` prints the file id and the action.** Each
  line is `file_id severity kind action path details`, tab-separated.
- **Breaking (Zig API): `HealthIssue` gains `track_id`, `release_id`,
  `related_file_id` and `action`,** and `HealthIssueKind` gains
  `recording_mismatch`.
- **Breaking (Zig API): provider servers and the AcoustID key are copied.**
  `Runtime.setListenBrainzServer`, `setMusicBrainzServer`, `setAcoustIdServer`,
  `setCoverArtArchiveServer` and `setAcoustIdClientKey` copy their argument,
  so it no longer has to outlive the runtime, and take an optional: null
  restores the public server or clears the key. A server is at most 2048
  bytes. `setCredentialStore` takes an optional, and null removes the store.

- **Library schema version 28.** Adds `recording_verifications` and
  `identification_proposals.album_group` with its index.
- **Breaking: an accepted correction is locked.** Accepting a correction
  stores the recording ID, over any value, and the title and artist, over
  anything but a user's edit, as locked provider values that outrank the
  file's tags and that tag writes write over them. Bulk acceptance and Match
  Album never take a correction, and `libraryAcceptMatch` and
  `libraryDismissMatch` refuse a proposal in an album group with
  `error.ProposalInGroup`. The review page leaves grouped proposals out.

- **Match Album prefers the original edition in a tie.** When releases have
  as many votes and none is the Release's tagged release ID, the vote now
  goes to an `Official` release, then to one with as many tracks as the
  Release has Tracks, then to the earliest date, before the lowest ID. A
  search keeps each listed release's status, date and track count in the
  proposal payload (`ProposalPayload.release_facts`, `ReleaseFact`), and
  `MbidTally.rankedWinner` ranks with them.
- **Breaking (Zig API): bulk acceptance reports values.**
  `Runtime.libraryAcceptConfidentMatches` returns
  `ConfidentMatchAcceptance` (`accepted`, `values_written`) instead of a
  count, and `IdentificationProposalRepository.acceptConfident` returns an
  owned `ConfidentAcceptance` with the files it accepted or wrote. An
  accept's `values_written` now counts every value stored, so it is no
  longer only 0 or 1. Matching makes about one more MusicBrainz request per
  album.

- **Clipping needs a run of samples at full scale.** A `clipping` health
  issue is raised only for at least three consecutive full-scale samples in
  one channel, so a single full-scale peak is no longer clipping, and full
  scale now includes 16-bit PCM's positive limit (any magnitude of at least
  `1 - 1/32768`). The details give the clipped runs and the samples inside
  them. Diagnostics are measured again (algorithm version 4, result encoding
  version 2; `diagnostics.Result` gains `clipped_runs`), and ReplayGain is
  unavailable for a file until it is analysed again.

### Fixed

- **`orca_player_play_tracks` refuses a `start` past the end with
  `ORCA_STATUS_INVALID_ARGUMENT`.** It returned `ORCA_STATUS_INTERNAL`.
- **A command that failed internally reports `ORCA_FAILURE_INTERNAL`.** The
  C ABI sent 10, which no `orca_failure` constant names, instead of 255.
- **Health raises missing tags, album-artist, artwork, clipping, silence and
  loudness issues.** Nothing raised `missing_metadata`, `album_artist_anomaly`,
  `artwork_problem`, `clipping`, `excessive_silence` or `missing_analysis`.
  The projection now raises and clears the first three, judging a missing
  title before the file name stands in for it, and the analysis pass the
  other three; `missing_analysis` means the audio is too short or silent for
  a loudness figure, not that it was never measured. Storing a fetched cover
  clears `artwork_problem` for the Release's files. `docs/analysis.md` lists
  which pass owns each kind.
- **A second Orca process no longer deletes the WAL under a live Library on
  Linux.** Any close of the database, `-wal` or `-shm` file in the process,
  such as a GTK file dialog browsing its folder, dropped SQLite's POSIX
  locks, so another process check-pointed and deleted the WAL and later
  writes were lost without an error. liborca now switches SQLite's `unix`
  VFS to OFD locks, process-wide, before its first open.
- **A scan of a root that holds the Library no longer examines the Library's
  own files.** The database, its `-wal`, `-shm`, `-journal` and journal lock
  files, its `.orca-backups` directory and the `.orca-volume-id` marker are
  skipped, as the watcher already skipped them, and no longer count as
  unsupported files.

## 0.7.0 - 2026-10-01

Ships Library schema version 27. Close every Orca process before upgrading.

### Added

- **Star ratings.** `librarySetRating` rates the song behind each Track from
  1 to 100 or clears it, `TrackSummary.rating` and `TrackDetails.rating`
  report it, and `TrackSort.rating` sorts by it with unrated Tracks last. A
  rating belongs to the Recording, so an edit that gives a Track a new id
  keeps it. `orca-cli rate` sets it, `tracks --sort rating` sorts by it and
  `track` prints it.
- **Playlists.** Named, ordered lists of up to 10,000 songs, kept per
  Recording, with `libraryPlaylists`, `libraryCreatePlaylist`,
  `libraryRenamePlaylist`, `libraryDeletePlaylist`,
  `libraryPlaylistEntries`, `libraryPlaylistInsert`,
  `libraryPlaylistRemove`, `libraryPlaylistMove` and `playerPlayPlaylist`.
  An entry whose song has no Track is listed as unavailable and skipped when
  played. `orca-cli` has `playlists`, `playlist`, `playlist-create`,
  `-rename`, `-delete`, `-add`, `-remove`, `-move` and
  `play-tracks --playlist`. See [docs/playlists.md](docs/playlists.md).
- **M3U and M3U8 import and export.** `libraryImportPlaylist` matches each
  entry by path, relative or `file://`, then by a unique `#EXTINF` artist,
  title and length, and reports what it could not match;
  `libraryExportPlaylist` writes absolute or relative paths atomically.
  `orca-cli playlist-import` and `playlist-export` run them, and the parser
  has a fuzz target.
- **Playlists and ratings in `orca-gtk`.** Five stars on every song row, in
  the details panel and in song menus, and a Rating column on the Tracks
  page. A Playlists section in the sidebar with New Playlist and Import
  Playlist…, a page per playlist with Play, Shuffle, Move Up, Move Down,
  Remove, Rename, Export… and Delete, and Add to Playlist on song and album
  menus.

### Changed

- **Library schema version 27.** Adds `ratings`, `playlists` and
  `playlist_entries`, and the indexes `tracks_by_recording` and
  `locations_by_uri`. `tracks.rating` is dropped after each Recording's
  highest value is copied into `ratings`.

### Removed

- `TrackRepository.setRatings` and `countWithRating`, which wrote and read
  the dropped column.

## 0.6.0 - 2026-10-01

Ships Library schema version 26. Run `orca-cli analyze-library`, or Measure
Loudness in `orca-gtk` Preferences, to measure loudness and ReplayGain again,
and close every Orca process before upgrading.

### Added

- **Write Tags to Files from the context menu, with recording IDs.** A track
  or album menu in `orca-gtk` has Write Tags to Files…, which shows the plan
  and writes it once confirmed. Tag writes now store the MusicBrainz
  recording ID: FLAC as `MUSICBRAINZ_TRACKID`, MP3 and ADTS as a MusicBrainz
  `UFID` frame, replacing a legacy `TXXX:MusicBrainz Track Id` and keeping
  other `UFID` owners and `TXXX` frames byte for byte, in ID3v2.3 and 2.4.
  The Edit Tags dialog has a MusicBrainz Recording field for a single track,
  and `orca-cli edit` a `--recording-id` option.

### Changed

- **A tag write never overwrites a file's tag with an automatic value.** A
  locked value, a user's edit, is written wherever it differs from the file;
  an unlocked one, such as an accepted match, only where the file has no tag
  for its field. One that disagrees with the file's tag is reported in
  `TagWritePlan.conflicts` (`TagWriteConflict`) and not written, and each
  `TagWriteChange` carries the `provenance` of Orca's value. `orca-cli
  write-tags` labels changes `edit` or `match` and prints a `conflict` line
  per conflict; `orca-gtk`'s confirmation lists both. `isMusicBrainzId` is
  exported.
- **Library schema version 21.** `orca_metadata_values.written_at` records
  when a tag write put a value into its file, so a recording ID Orca wrote
  stays eligible for AcoustID submission; IDs Orca did not choose are still
  never sent.
- **Library schema version 22.** Files observed with a cover and no other
  tag value are re-read by the next scan, reconcile or watch pass, so a
  library scanned before the fix below gains their trailer and INFO values.
- **Library schema version 24.** `provider_state.next_request_ms` keeps the
  earliest time a service may be sent its next request, so a quota window or
  the one-request-per-second spacing outlives the job that learned it.
- **Library schema version 25.** Every present location of a File held at
  more than one path is read again by the next scan, so copies that diverged
  before the fix below become Files of their own.
- **Library schema version 26, and a journal lock.** Tag writes, undo,
  pruning and startup recovery hold an exclusive lock on
  `<database>.orca-journal.lock` and recover abandoned work before their own;
  a second holder gets `MutationInProgress` (`ORCA_STATUS_BUSY`). Mutation
  operations gain an `undoing` state, and groups left half undone are
  resumed. Close every Orca process before upgrading: an older binary takes
  no lock. Never delete the lock file.
- **A recording ID inherited from a provider match is not sent to AcoustID.**
  A provider-sourced recording ID is submittable only when the same File holds
  the accepted, individually reviewed MusicBrainz proposal for it.
- **Library schema version 23.** `files.audio_hash` is cleared unless a
  current fingerprint was measured from the file's present bytes, so stale
  hashes in an existing library stop producing exact-duplicate findings;
  `orca-cli analyze-library` measures those files again.

- **Accept Confident takes each file's best match.** Before, a file's match
  was accepted in bulk only when it was the file's one pending proposal at the
  threshold, so a text-only MusicBrainz rival such as a live version, or
  AcoustID naming several MusicBrainz recordings of the same audio, left the
  file unaccepted, and raising the threshold could accept more. Now a match
  AcoustID found with a fingerprint score of at least 0.9 wins, ties going to
  the higher percent, the Track's own track number, one MusicBrainz found too,
  the higher MusicBrainz score, the closer length and the lowest recording ID.
  Without one, the most confident match is accepted when its percent is above
  every other's. `acceptConfident`, `acceptConfidentInRelease` (Match Album)
  and `confidentCount` share the selection, and a higher threshold never
  accepts more.

### Fixed

- **Writing tags to a FLAC file with a comment block of 256 bytes or more no
  longer crashes.** The block header's length was narrowed to one byte, so a
  Debug or ReleaseSafe build panicked mid-write on nearly every real FLAC file
  and startup recovery rolled the write back.
- **Writing tags to an MP3 or ADTS file whose values were only in its ID3v1
  trailer no longer drops them from the library.** The new ID3v2 tag held only
  the written fields, such as an accepted recording ID, and a re-scan reads
  ID3v2 first, so the file lost its title, artist, album, year, track and
  genre. The trailer's values are now written into the new tag too, unless a
  change replaces them.
- **An MP3, ADTS, WAV or AIFF file whose ID3v2 tag holds only a cover shows
  its ID3v1 or `LIST`/`INFO` values.** The cover counted as a tag value, so
  the ID3v2 tag was read in preference to the trailer or INFO chunk and the
  file had no title, artist, album, year, track or genre. Such a tag now
  falls back to them and keeps its cover, and a tag write to it carries the
  trailer's values into the new tag.
- **Loudness and ReplayGain are correct for stereo files.** Integrated
  loudness averaged the channels' K-weighted energy where ITU-R BS.1770 sums
  it, so a stereo file measured 3.01 LU too quiet and was played 3.01 dB too
  loud. `diagnostics_algorithm_version` is now 3: measurements taken before
  are ignored until `orca-cli analyze-library` measures the files again, and
  until then playback applies no measured correction to them. Channels are
  summed at weight 1.0; surround weighting waits for a channel layout.
- **A file whose tags were removed loses them in the library on the next
  scan.** A rescan of changed bytes that found no tags, or could not read
  them, kept the tags observed from the old bytes. They are now cleared, as a
  fresh import of the same file would have none.
- **`zig build test` can no longer play through the speakers.** The C ABI
  smoke test fell back to the default output when the silent sink could not
  be created, and the build hid that failure. The build now creates the sink
  with the `orca-cli` it builds and hands the test its device id; on Linux the
  test fails rather than open the default output.
- **A file whose audio changed is no longer reported as an exact duplicate of
  its old audio.** A rescan of changed bytes kept `files.audio_hash`, the hash
  of the decoded audio, and the duplicate pass trusted it. A new quick hash
  now clears it until the analysis pass decodes the file again.
- **Playing a stopped queue whose current file has gone plays the next
  entry.** The engine retried the missing entry until its failure limit and
  never reached the next one. It now steps over it, as it already did for an
  entry reached by auto-advance, and an engine that gives up with nothing
  loaded goes idle instead of waking every 2 ms.
- **A provider's quota window and request spacing hold across jobs.** A
  response announcing no remaining requests, and the time of the last
  request, were kept only by the job's own Gateway, so the next matching or
  submission job could send at once. Both are now stored with the service's
  block and backoff and honoured by every later Gateway.
- **An output that failed for good no longer stops a Player's other
  outputs.** A Zone whose recovery attempts were exhausted kept its queued
  audio, so a change of sample rate or channel count waited for it for ever
  and the healthy Zones went silent, and the Player never reported its queue
  drained. Such a Zone now gives back its audio and takes no part in
  draining, and closing its output and requesting it again opens it afresh.
- **Moving a Zone to another Player no longer plays the previous Player's
  audio.** `attachZone` kept the Zone's output, queued audio and published
  position, which the new Player could take for its own. Moving a Zone now
  closes its output and forgets that state; the new Player reopens it in its
  own format. Detaching a Zone and destroying a Player forget it too.
- **A copy of a file that changes no longer rewrites its identical copies.**
  Byte-identical copies share one File, and a changed copy overwrote it, so
  the untouched copy's Track disappeared and later scans and the duplicate
  pass still treated the two as one. A copy whose bytes diverge now becomes
  a File of its own, carrying Orca's values and locks; analysis, listens and
  proposals stay with the original. Hard links stay one File. A tag write to
  one copy marks the written values on the File that holds them.
- **Opening a Library no longer rolls back another process's tag write.**
  Startup recovery treated every unfinished operation as abandoned, so any
  command opening the Library while `orca-gtk` or another `orca-cli` was
  writing undid that write and failed it. Recovery now runs only under the
  journal lock, and an open that cannot take it leaves the work alone.
- **An undo interrupted between files is finished instead of stuck.** Undo
  restored files one by one with no record of the intent, so a crash left
  the group half undone, beyond recovery and refused by `undo-tags`. The
  intent is now recorded for the whole group first, the next open or
  `undo-tags` finishes it, and `undo-tags` of a group already undone says so
  and succeeds.

## 0.5.0 - 2026-09-30

Ships Library schema version 20.

### Added

- **The analysis decodes on a pool of threads.** `AnalysisRequest.threads`
  sets how many files of a batch are decoded at once; unset, it takes
  `analysisDefaultThreads()`, one fewer than `analysisAvailableThreads()`,
  the logical processors. `orca_analysis_options.threads` (zero for the
  default), `orca_analysis_default_threads()` and
  `orca_analysis_available_threads()` reach them through the C ABI, and
  `orca-cli analyze-library --threads=N` and an Analysis threads row in
  `orca-gtk`'s Preferences, saved in `settings.ini`, set them. The stored
  results are the same at any thread count.
- **The analysis stores each file's AcoustID fingerprint.** The new streaming
  `chromaprint.Analyzer` takes it in the same decode as the loudness, so
  matching and AcoustID submission find it cached instead of decoding the
  file again. `FileAnalysis.chromaprint` holds it, null for audio too short
  to fingerprint, and `orca-cli analyze` prints `chromaprint=yes|no`.

- **Match Album and Cover Art Archive covers.** `MatchRequest.release_id`
  limits matching to one Release; with it, `accept_minimum_confidence`
  accepts that Release's confident matches and `cover_art` fetches its front
  cover. `Runtime.startReleaseCoverArtFetch` fetches the cover alone, and
  `jobMatchStats` reports `accepted` and the `CoverArtOutcome`. A cover is
  fetched only for a Release none of whose files carries one, under its
  tagged release ID or the one most of its accepted matches name, through
  `Gateway.fetch`, which follows at most two `https` redirects within
  `archive.org`. It is stored in the new `release_artwork` table, a missing
  cover for 30 days, and the artwork reads return it when no file has a
  cover. `Runtime.setCoverArtArchiveServer` and `ORCA_COVERARTARCHIVE_URL`
  select another server. `orca-cli match --release=ID
  [--accept-min-score=SCORE] [--cover-art]` and `orca-cli cover-art DATABASE
  RELEASE_ID` run them, and `orca-gtk` offers Match Album and Fetch Cover Art
  on an album's menu.

- **The flake installs Orca on NixOS and Home Manager.** `nix/package.nix`
  holds the package, `packages.orca` (also `default`) builds it, and
  `nix run` starts `orca-gtk` (`orca-cli` on macOS);
  `nix run .#orca-cli` runs the CLI. `nixosModules.default` and
  `homeModules.default` add `programs.orca.enable` and
  `programs.orca.package`, and `overlays.default` adds `pkgs.orca` built
  against the overlaid nixpkgs.
- **`nix flake check` builds the package, runs `zig fmt --check` and
  evaluates the NixOS module.**
- The dev shell provides Python, `ffprobe` and the `sqlite3` shell.

### Changed

- **Breaking (Zig API): the analysis no longer hashes the whole file.** It
  read every file a second time for a BLAKE3 hash nothing used.
  `FileAnalysis.fingerprint.source_hash` and `DuplicateKind.exact_file` are
  gone; a stored temporal fingerprint keeps its layout, with the hash's bytes
  written as zeros.
- `orca-cli analyze-library` runs on `std.heap.smp_allocator` rather than
  the process arena, which kept every decoded file's buffers until it exited.

### Fixed

- **`orca-gtk` renders on the GPU again on current NixOS.** The pinned
  nixpkgs carried glibc 2.42, older than the system's GPU drivers need, so
  the Vulkan loader rejected them and GTK drew in software: the album grid
  lagged, more so the wider the window. nixpkgs is updated to glibc 2.44.

## 0.4.0 - 2026-09-30

Ships Library schema version 19.

### Added

- **Folder-scoped reconciliation.** `Runtime.startLibraryReconcile(library,
  ReconcileRequest)` walks a registered root, or only some directories under
  it, and marks missing only files under the directories whose walk
  completed. `orca-cli reconcile DATABASE ROOT_ID [DIR...]` runs it. The job
  kind is `reconcile`.
- `ScanStats.marked_missing` counts the locations a scan or reconcile marked
  missing; `orca-cli scan` prints it as `missing=`.
- **Filesystem watching on Linux.** `Runtime.libraryWatch(library,
  WatchOptions)` watches every root of a Library with inotify and, from
  `pump`, reconciles each directory that changes once its root has been quiet
  for `quiet_ms`. A reconcile that changed the Library publishes
  `Telemetry.library_changed`. A root that is deleted, moved or unmounted is
  reported, never marked missing. `libraryUnwatch` and `libraryWatchStatus`
  complete it, `jobReconcileRoot` names a reconcile job's root, and
  `orca-cli watch DATABASE` runs it. The unconnected `RootWatcher` and
  `watch_hints.Channel` are gone.
- **Degraded and unavailable roots are retried.** A root the watch limit left
  partly unwatched is walked again and reconciled whole every
  `WatchOptions.degraded_rescan_ms` (default 15 minutes) while it stays so,
  and an unavailable root is armed again on the same interval once its path
  is back on its recorded volume. `WatchStatus.roots_degraded` counts the
  degraded roots.
- **`orca-gtk` watches the music folders.** Preferences > Library > Watch
  folders for changes, on by default and saved in `settings.ini`, watches
  the open library; the views reload when a watcher's reconcile changes it,
  and the switch's subtitle reports what is watched, what is unavailable and
  when `fs.inotify.max_user_watches` must be raised.
- **C ABI: watching and reconciling.** `orca_library_watch`,
  `orca_library_unwatch`, `orca_library_watch_status` with
  `orca_watch_options`, `orca_watch_status` and `ORCA_WATCH_STATE_*`;
  `orca_library_start_reconcile`; `ORCA_EVENT_LIBRARY_CHANGED` with an
  `orca_library_changed_event` payload; and `ORCA_JOB_KIND_RECONCILE`, which
  reconcile jobs report instead of `ORCA_JOB_KIND_OTHER`. All are additions
  within ABI version 0. `orca_scan_stats` does not carry `marked_missing`:
  the struct has no reserved room for a 64-bit field, and growing it would
  change its size.
- **Breaking (Zig API):** `Telemetry` has a `library_changed` variant, so an
  exhaustive switch over it needs an arm for it.

### Fixed

- **A scan of an unmounted drive's root no longer marks its files missing.**
  Every scan and reconcile, host-started or automatic, first checks that the
  root's path still resolves to the volume the root was recorded on; a root
  that does not is neither walked nor swept, and the job ends `failed`. A
  watched root that fails the check is reported unavailable until it is back.
  `orca-cli scan` no longer re-adds a registered root, which rebound it to
  the volume its path is on now and so bypassed the check; `orca-cli
  add-root DATABASE ROOT` rebinds a root explicitly, and
  `ScanStats.volume_changed` reports the failure.

- **Two scans of one Library could mark present files missing.** A second
  scan or reconcile of a Library while one runs is now refused with
  `error.LibraryScanRunning`, `ORCA_STATUS_BUSY` through the C ABI.

## 0.3.0 - 2026-09-30

Ships Library schema version 19.

### liborca as a library for others

- **Breaking (Zig API): the host names itself before provider work.**
  liborca no longer carries Orca's identity as a default. Until
  `Runtime.setClientIdentity` is called, `startLibraryMatching`,
  `startAcoustIdSubmission` and `librarySetScrobbling(library, true, ...)`
  return `error.ClientIdentityRequired`; turning scrobbling off and
  `libraryTrackFingerprint` need none. `setClientIdentity` copies its strings,
  so they no longer have to outlive the runtime, and refuses an identity longer
  than 256 bytes in all. `network.client.Identity.orca` is gone,
  `network.client.Config.identity` has no default, and a listen recorded before
  an identity is set has an empty `player_client`. An identity named `Orca` at
  liborca's own version sends no `liborca/x` suffix whatever its contact.
- **`orca-cli` and `orca-gtk` take their provider contact from
  `-Dprovider-contact`** (default `evan@evanriley.com`); `match`, `scrobble`,
  `submit-acoustid` and `play-tracks` identify as `Orca/<version>`.
- **Versioned shared library.** `liborca.so` has the SONAME `liborca.so.0` and
  installs as `liborca.so.0.0.0` with `liborca.so.0` and `liborca.so` links.
  The number is `ORCA_ABI_VERSION`, new in `orca.h` and separate from the
  product version.
- **`liborca.so` exports only the functions `orca.h` declares.** It exported
  1,513 symbols, among them the C shims, libxaac, Chromaprint and libc++'s
  `operator new`. A version script generated from the header hides the rest,
  a declared function liborca does not define fails the link, and the new
  `abi-exports` step in `zig build test` (`scripts/check-exports.sh`) fails
  when the exports and the header differ.
- **`orca_version()`** returns liborca's version.
- **`orca_runtime_last_error()`** describes why the last call on a runtime
  failed, as `"<function>: <reason>"`: the Zig error name, or which argument
  was refused. It was lost behind `ORCA_STATUS_INTERNAL` and
  `ORCA_STATUS_INVALID_ARGUMENT`.
- **Hosts can sleep until liborca wakes them.**
  `orca_runtime_set_wake_callback` (`Runtime.setWaker` with a `HostWaker`)
  installs a callback liborca calls, at most once between two pumps, after a
  command is submitted and when a Player's position or end of queue, a Zone's
  output state, a finished job, an artwork result, a recorded listen or the
  scrobbler status changes. `orca_runtime_pump_timeout`
  (`Runtime.nextPumpTimeoutMs`) gives how long the host may sleep without it:
  0, at most one second while a bound Player plays and 100 ms while a job
  runs, or
  `ORCA_PUMP_NO_TIMEOUT`. An idle runtime asks for no timeout and makes no
  wake. The callback is the one exception to the threading contract: it runs
  on liborca's threads, must only signal the host's loop, is never called from
  a render callback or after `orca_runtime_destroy` returns, and can be set
  only before any worker thread exists. `Runtime.pump` is the loop's pump,
  which `orca_runtime_pump` now calls.
- **`orca-gtk` sleeps until liborca wakes it.** Its 100 ms timer is gone: the
  waker writes an eventfd the GTK main loop watches, and the pump timeout is
  re-armed after each tick. An idle window makes no wakeups. Handlers that
  change what the window shows request a tick themselves, a seek drag applies
  on its own settle timer, and a context menu is re-presented on idle.
- **`lib/pkgconfig/orca.pc`** is installed, so C hosts build with
  `pkg-config --cflags --libs orca`, or `--static` for the static library and
  its dependencies, libc++ included.
- **A stability statement** in `orca.h` and `docs/api.md`: within one ABI
  version functions and enum values are only added and reserved fields gain
  zero-compatible meanings; the Zig API may break in any minor release.

### Parser hardening

- **A crafted MP4 no longer overflows the sample-table arithmetic.** Media
  time, packet lookup, chunk offsets, the edit list's conversion to media
  time, frame counts and the probe's duration are checked, and a value that
  does not fit is `error.InvalidMp4` rather than a panic in safe builds and
  undefined behaviour in `ReleaseFast`. The movie-box walk in `iso_bmff.zig`
  checks its offset arithmetic the same way.
- **Fuzz targets for every parser that reads untrusted bytes**: ID3v2, MP4
  and ISO-BMFF, Vorbis comments (FLAC, Ogg and bare), WAV, AIFF, ADTS, the
  MP3 stream reader, and the scanner's detect, probe and artwork path
  (`liborca/fuzz.zig`). `zig build test` replays their seeds, including every
  input under `fixtures/fuzz/`; `zig build fuzz --fuzz[=N]` fuzzes them. A
  single allocation above the largest designed bound fails the input.
- **WAV and AIFF size their read buffer by the frames the file holds.** A
  header declaring thousands of channels made the decoder allocate 4,096
  frames of them, 256 MiB for a 41-byte file.
- **ALAC rejects a configuration of more than 8 channels or 65,536 frames per
  packet.** The decoder's buffers were sized from the declared frame length,
  so a crafted cookie could demand gigabytes.
- **An ID3v2 tag larger than its file is rejected before its body is
  allocated.** The declared size, up to 16 MiB, was allocated first and only
  then found to be short.

### Playback engine

- **Back-to-back control calls no longer starve the engine.** A quiesce that
  came within one park interval of the previous release suspended the engine
  before it ran a pass, so a host calling `playerSignalPath`,
  `playerSetEqualizer`, `playerSetCrossfeed` or `seekPlayer` every few
  milliseconds kept the output from ever opening. A quiesce now waits for one
  full pass after a release.
- **Player status and listens no longer pair a new entry with the previous
  entry's gain, duration or position.** The engine moved the queue cursor
  before it published the audible entry's figures; it now publishes the
  position, duration and gain first and the cursor last, and a status read
  takes the cursor first.

### Providers

- **Provider rate limits survive the process** (Library schema 19). A `429`
  block and its backoff are stored per service in `provider_state`, so a
  restart or a new `orca-cli scrobble` no longer sends into a block. A listen
  that failed for a transient reason keeps its retry time in the queue
  (`next_attempt_at`) instead of being released at once.
- **One process at a time talks to each service.** A Gateway claims a
  per-service lease in `provider_leases` before each request and releases
  it when its job ends; a second claimant fails fast with
  `error.ProviderBusy`. A matching or submission job fails with the new
  `BusyService`, the listen worker reports the new `busy` state and tries
  again after the lease runs out, and `orca-cli` prints "MusicBrainz is in
  use by another Orca process" (breaking Zig API change: new enum values in
  exhaustive switches).
- **`Retry-After` is honoured uncapped, as delta-seconds or an HTTP-date, and
  on a `503`.** It was capped at an hour, its date form was ignored, and a
  `503`'s was ignored altogether.
- **Every backoff Orca chooses is jittered** by a factor between 0.5 and 1.5,
  so clients that failed together do not retry together. A server's own
  `Retry-After` is never shortened.
- **A query MusicBrainz or AcoustID refused is not sent again for 7 days.** A
  `4xx` other than `401`, `403`, `408` and `429` is cached with its status. A
  refused AcoustID lookup batch is asked again one fingerprint at a time, so
  only the bad fingerprint's refusal is cached.
- **`ScrobblerStatus.blocked_until`** reports when a stored block ends, also
  when no worker is running; `orca-cli scrobble` and `scrobble --status`
  print it.
- **AcoustID submissions only send what AcoustID does not already know.** A
  recording ID from an accepted proposal that AcoustID took part in is not
  submitted back, and neither is a text-only match accepted in bulk
  (`identification_proposals.accepted_in_bulk`). Acceptances made before
  schema 19 count as reviewed.

### Idle power

- **An idle Player makes no wakeups.** The engine thread slept 2 ms at a time
  for the Player's whole life; it now waits on a futex while there is nothing
  to do, and is woken by control calls, cancellation and PipeWire stream state
  changes. Measured on a paused and on a stopped Player: 4,882 context
  switches per 10 s before, 0 after.
- **The artwork loader waits with no timeout.** It woke every 50 ms to check
  for cancellation; a `work.Registration` now carries a waker that
  `requestCancellation` calls.

### Maintenance

- **`core/runtime.zig` is split** into `runtime_queue.zig`,
  `runtime_listens.zig`, `runtime_roots.zig`, `runtime_jobs.zig`,
  `runtime_status.zig`, `runtime_zones.zig` and `job_worker.zig`, with its
  tests in `runtime_tests.zig` and `runtime_provider_tests.zig`. `JobWorker`
  holds a tagged-union request and stats per job kind; the duplicate job's
  counts are mapped into `ScanStats` only at the public boundary, as before.
  The public API is unchanged.
- **`database/repository.zig` is split by aggregate** into
  `database/repository/`, and the column helpers copied across the library
  code live once in `database/columns.zig`.
- **One set of network test doubles** in `network/testing.zig`
  (`ScriptedTransport`, `TestClock`) replaces the copies in each provider and
  in the runtime tests.
- **`orca-cli` dispatches through a command table** with one job-option
  parser. `--help` is built from it and now lists `--volume` and
  `--set-volume`.
- **Removed:** the Last.fm adapter and `scrobble.Adapter`, the DSP graph
  (`Chain`, `PublishedChain`), `audio/transition.zig`, the `Resampler`
  interface with its linear implementation (`resampler.SampleRate` remains
  for fingerprints), `published_device_delay_frames`, and uncalled functions
  (`setEnabled`, `stampGeneration`, `jobSnapshot`, `applyAlgorithmicLatency`).
- **Comments that narrated history, and section dividers, are removed**;
  those that held an invariant state it instead.

### Documentation

- **The docs match the code.** `analysis.md` no longer describes the
  replaced FLAC decoder; `storage.md` and `metadata.md` name the current
  tables and journalled identity; `ownership.md`, `frontends.md` and
  `audio-engine.md` drop superseded stages. Measurements and reference-library
  figures are removed from the contract docs.
- **`README.md` has an Embedding section** and a complete list of
  requirements, and warns that device 0 is real hardware.

## 0.2.0 - 2026-09-29

The first tagged release. Ships Library schema version 18.

### The first release

- **The version is `0.2.0`, without `-alpha`**: a `0.x` version already makes
  no stability promise. `orca-cli --version`, the About dialog and the
  User-Agent read `0.2.0`.
- **`build.zig.zon` holds the version.** `build.zig` passes it to liborca,
  which parses `liborca.version` from it, and `flake.nix` reads it for the
  package; `liborca/version.zig` no longer writes it out.
- **`orca_player_snapshot` and `orca_player_state_snapshot` are removed**
  (breaking C ABI change). They were kept for a pre-0.2 boundary that was never
  released; `orca_player_status_get` reports the transport, queue and timeline.

### aarch64 builds and CI

- **`liborca` builds for aarch64, Apple Silicon included.** SQLite's
  `SQLITE_TRANSIENT` was built as a misaligned function pointer, which
  aarch64 rejects; text results are now copied into SQLite's allocator and
  freed with `sqlite3_free`. The `ogg` and `opus` include directories come
  from pkg-config, where only Nix's native environment used to supply them.
- **`zig build lib`** installs only the static `liborca` and
  `include/orca/orca.h`, which cross-compiles:
  `zig build lib -Dtarget=aarch64-macos`.
- **A CI workflow** (`.github/workflows/test.yml`) runs `zig build test`,
  `zig fmt --check` and the aarch64 macOS cross-build on every push to `main`
  and every pull request.
- **`scripts/headless-audio.sh CMD`** runs a command against a private
  PipeWire and WirePlumber with every hardware monitor off, so the C ABI smoke
  test has an audio server in CI without reaching real devices. The dev shell
  gains WirePlumber on Linux.

### Truthful signal-path report

- **Exact widening is bit-perfect.** An 8-, 16- or 24-bit integer source
  widened to float32 reaches the output unchanged, so FLAC, ALAC, WAV and AIFF
  are no longer reported "not bit-perfect" for it; the report marks the path
  `widened_exactly`, and `orca-cli` prints `(exact)` after the output format.
  A 32-bit integer or 64-bit float source is still a
  `sample_format_conversion`.
- **Lossy sources are not bit-perfect.** MP3, AAC, Opus, Vorbis and QOA carry
  the new reason `lossy_source`. They used to report "bit-perfect: yes"
  because a decoder that declares no source format reported the canonical
  float32 format, which matched the stream.
- **A volume ramp lands exactly on its target**, where a ramp ending on a
  block boundary stopped at 0.99999, and the report reads the gain being
  applied rather than the target, so volume 1 is bit-perfect once the ramp
  ends.
- **No bit depth for lossy sources.** `orca-cli` and `orca-gtk` print a depth
  only when the decoder declared a source format.
- **`orca-gtk` says "Bit-perfect up to PipeWire"**, with "PipeWire's own
  volume and resampling are not visible to Orca." on hover over the signal
  path, and shows the volume whenever it is not 100 %, above it included.
- `SignalPath` gains `source_declared` and `widened_exactly`, and
  `SignalPathReason` gains `lossy_source` (public API addition).

### Tag-write backups out of the music folders

- **A tag write leaves nothing beside the music.** The original is copied,
  with its modification time, fsynced and verified, into
  `<database>.orca-backups/<plan>/<action>-<name>` before the replacement is
  renamed into place. The stage is a hidden file beside the music
  (`.<name>.orca-stage-<plan>-<action>`) that exists only during the write, and
  an undo copies the backup to a hidden `.orca-restore-` file and renames it
  over the file. A rescan after a write used to list each backup as a second
  Track with the old tags, and after an undo as a `missing` one.
- **Scans skip Orca's temporaries**: hidden `.orca-stage-` and
  `.orca-restore-` files, and the `.orca-backup-`, `.orca-stage-` and
  `.recovery-displaced` names of earlier versions.
- **Schema version 18 forgets the ghost rows.** Files whose every location is
  a journaled stage or backup path go, with their Tracks and the Releases and
  Artists left without Tracks.
- **Backups can be pruned.** `Runtime.pruneTagWriteBackups` (new type
  `PruneSummary`) and `orca-cli prune-backups DATABASE [--older-than=DAYS]`
  delete the backups of fully committed writes, including backups earlier
  versions left beside the music, and print how many and their size. A pruned
  write cannot be undone: `undoTagWrite` returns `error.TagWriteBackupPruned`
  and changes nothing.
- **Undo checks every backup first.** A backup that is missing or no longer
  holds the original records `needs_reconciliation` before any file changes.
  Recovery restores from a verified backup, keeps every file when the backup is
  gone, and handles journals of both layouts. When a changed file's folder is
  missing, as on an unmounted drive, the Library refuses to open with
  `error.TagTargetUnavailable` and recovery runs again at the next open.
- **An in-memory Library cannot write tags.** `startTagWrite` returns
  `error.NoBackupDirectory`, because it has nowhere to keep the originals.
  (Breaking for hosts that wrote tags through an in-memory Library.)
- `orca-cli` and `orca-gtk` explain a pruned write and a missing backup
  directory instead of printing the error name.

### AcoustID

- **Matching fingerprints files and asks AcoustID.** A matching job
  fingerprints each Track's file (the first 120 s, decoded by Orca, resampled
  to 11,025 Hz by libsamplerate and fingerprinted by Chromaprint) and looks up
  to 20 fingerprints at a time on AcoustID, at one request a second, in a
  gzip-compressed form. Candidates from MusicBrainz and AcoustID are merged
  into one proposal per recording, named `musicbrainz`, `acoustid` or
  `musicbrainz+acoustid`; two services agreeing rank above either alone, and a
  proposal found again keeps its state, so a dismissed one stays dismissed.
  `MatchRequest.fingerprints` (default true) turns it off. `MatchStats` gains
  `fingerprinted`, `fingerprint_cache_hits`, `fingerprint_failures`,
  `acoustid_requests`, `acoustid_cache_hits`, `acoustid_refused` and
  `acoustid` (new type `AcoustIdUse`); `MatchProposal` gains
  `acoustid_score`.
- **Each service is asked once per file.** Schema version 17 adds
  `identification_searches`, recording which service has answered for which
  file, empty answers included. Matching selects a Track until every service
  in scope has answered for its file, so a rerun asks nothing already
  answered; files with MusicBrainz proposals from before count as searched by
  MusicBrainz. A Track with a pending proposal is no longer skipped when
  AcoustID has not been asked about it.
- **Application key.** `Runtime.setAcoustIdClientKey` sets the key AcoustID
  identifies the application by; `orca-cli` and `orca-gtk` set it from the new
  build option `-Dacoustid-key=` (default `AqlfLksN1K`). A `CredentialStore`
  value under `org.acoustid` / `client-key` overrides it; without a key
  AcoustID is skipped. `setAcoustIdServer` and `ORCA_ACOUSTID_URL` select
  another server.
- **Fingerprints are cached.** `analysis_results` gains kind 3,
  `orca.chromaprint`, keyed by the algorithm, the resampler and the bytes.
  A file that does not decode cleanly gets no fingerprint.
  `Runtime.libraryTrackFingerprint` (new type `TrackFingerprint`) and
  `orca-cli fingerprint DATABASE TRACK_ID` print one in `fpcalc`'s format.
- **Chosen recording IDs can be submitted.** `startAcoustIdSubmission` starts
  an `acoustid_submission` Job (new `JobKind`) that sends the fingerprints of
  files whose recording ID came from an accepted match or an edit, never a
  tagged one, once per file and ID, in batches of at most 50 items and
  900 KB, with the user key the `CredentialStore` holds under `org.acoustid`
  / `user-key`. A file more than 30 s from its recording's length is sent
  with its metadata instead of the ID. It fails with `needs_user_key` or
  `invalid_user_key` without marking anything sent, and records each
  submission ID in the new `acoustid_submissions` table.
  `jobSubmissionStats` (new types `SubmissionStats`, `SubmissionOutcome`),
  `libraryAcoustIdSubmittableCount` and `libraryAcoustIdSubmittablePage` (new
  types `AcoustIdSubmittable`, `AcoustIdSubmittablePage`) report it.
  Matching and submission cannot run at once (`error.AcoustIdBusy`).
  `orca-cli submit-acoustid DATABASE [--dry-run]` reads the key from
  `ORCA_ACOUSTID_USER_KEY`.
- **`orca-cli`**: `match` prints a line of AcoustID counters and takes
  `--no-fingerprints`; `matches` prints each proposal's source and AcoustID
  score.
- **`orca-gtk`**: Preferences > Library gains an AcoustID group with Match
  by audio fingerprint (`[matching] fingerprints` in `settings.ini`, on by
  default), the user's AcoustID key saved in the Secret Service with Save,
  Remove and Unlock, and Get a key. The Matches page shows each proposal's
  source and AcoustID score, the details panel shows them in the proposal's
  tooltip, and Submit to AcoustID (N) sends accepted matches as a job after
  asking. `ORCA_ACOUSTID_URL` selects another AcoustID server. A failed
  matching job now names MusicBrainz or AcoustID. The GTK credential store
  labels each keyring item by its service.
- **New dependencies.** Chromaprint 1.6.1 (MIT) with KissFFT (BSD-3-Clause)
  is built from source without its LGPL resampler, and a build step fails if
  a compiled source carries a GPL or LGPL notice. libsamplerate (BSD-2-Clause)
  is linked through pkg-config and exposed as `resampler.SampleRate`.

### MusicBrainz matching

- **Tracks without a MusicBrainz recording ID can be matched.**
  `Runtime.startLibraryMatching(library, MatchRequest)` starts a cancellable
  `metadata_lookup` Job that searches MusicBrainz for every Track whose file
  has no recording ID and no pending match, at one request a second, caching
  answers for 30 days, and stores the candidates Orca scores at 0.5 or above as
  proposals. At most one runs per runtime. `jobMatchStats` reports what it
  did as `MatchStats`. `libraryMatchProposals`,
  `libraryAcceptMatch`, `libraryDismissMatch` and
  `libraryAcceptConfidentMatches` review them; `setMusicBrainzServer` selects a
  mirror. New public types: `MatchRequest`, `MatchStats`, `MatchProposal`,
  `MatchProposalPage`, `MatchAcceptance`, `RecordingIdSource`.
- **An accepted match is the recording ID loves and listens are sent under.**
  `MetadataField` gains `musicbrainz_recording_id`. The ID in effect is a
  locked Orca value, else the file's tag, else an accepted match; listens,
  feedback sync and `TrackDetails.feedback_syncable` all use it.
  `TrackDetails` gains `musicbrainz_recording_id` and
  `musicbrainz_recording_id_source`. Acceptance re-reads the proposal inside
  its transaction, refuses one that is no longer pending
  (`error.StaleIdentificationProposal`) or cannot be read
  (`error.InvalidProposalPayload`), keeps a locked value, writes only the
  recording ID, and never writes a file. Tag writes leave the field out.
- **Matches can be reviewed in `orca-gtk`.** A Matches page lists the songs
  awaiting review with a count in the sidebar, each beside its best proposal
  and expanding to all of them with Accept, Dismiss and a link to the
  recording on MusicBrainz. Find Matches runs the job in the status card;
  Accept Confident asks, then takes each song's only proposal at or above a
  threshold set in Preferences (90% by default). The details panel gains a
  MusicBrainz section: the recording ID and its source, or the top proposals,
  or Find Match for that song alone. `ORCA_MUSICBRAINZ_URL` selects another
  server.
- **Review queries.** `libraryMatchReviewPage` (new types `MatchReviewPage`,
  `MatchReviewItem`), `libraryMatchReviewCount`, `libraryUnidentifiedCount`
  and `libraryConfidentMatchCount`, which counts exactly what
  `libraryAcceptConfidentMatches` would accept. `MatchRequest.track_id`
  searches one Track. `jobMatchStats` reports `matched` while the job runs.
- **`orca-cli match`, `matches`, `accept-match`, `dismiss-match` and
  `accept-matches`** drive it, with `ORCA_MUSICBRAINZ_URL` for another server;
  `orca-cli track` prints `recording id:` and its source.
- **Provider requests carry one User-Agent.** Every request also sent
  `zig/0.16.0 (std.http)` ahead of Orca's; it now sends Orca's alone.

### Listening history and ListenBrainz

- **Orca keeps a play history.** Schema version 15 adds `listens`: one row per
  heard play, kept forever, keyed on the file so it survives re-projection and
  keeps a snapshot of the title, artist and album when a folder is removed. A
  listen is a track of 30 s or more heard for half its length or four minutes;
  seeks and pauses do not count, and a queue that plays out ends its last
  listen with the whole time heard. `Runtime.libraryTrackPlayStats` and
  `TrackDetails.play_count` and `last_played_at` report it. `orca-cli track`
  prints `plays:` and `last played:`, `orca-cli play-tracks` records listens,
  and `orca-gtk`'s details panel shows a History section.
- **ListenBrainz scrobbling.** `librarySetScrobbling` sends a Library's
  listens through a leased, restart-safe queue; `libraryScrobblerStatus`
  reports state, user name, queue counts and the last error;
  `libraryScrobblerCredentialsChanged` validates a changed token once. The
  token comes from a host-supplied `CredentialStore`
  (`Runtime.setCredentialStore`), which must never prompt or block on the
  user, and is never stored in the Library. `libraryListensRecorded` is a
  cheap counter a host can poll every tick.
  `setClientIdentity` names the host, and `setListenBrainzServer` selects a
  compatible server (`https`, or `http` to `127.0.0.1`, `[::1]` and
  `localhost` only). The rules toward providers are in
  [docs/providers.md](docs/providers.md).
- **`orca-cli scrobble DATABASE [--status] [--timeout=MS]`** sends the queue
  with the token in `ORCA_LISTENBRAINZ_TOKEN` and the server in
  `ORCA_LISTENBRAINZ_URL`, prints one `scrobble:` line, and exits non-zero when
  the token is missing or rejected. It never validates the token up front: with
  nothing queued it makes no request and looks up no token, and otherwise a bad
  token shows as a refused delivery. `--status` prints the state and queue counts
  from the database, starts no worker and makes no request.
- **`orca-gtk` gets a Listening page in Preferences**: a Submit listens
  switch, a user token field stored in the Secret Service through libsecret
  (linked into `orca-gtk` only), a link to the ListenBrainz settings, and a
  status row; its lookup never unlocks the keyring. `settings.ini` saves `[listening] scrobble=true|false`, never the
  token. `ORCA_LISTENBRAINZ_URL` points the app at another server.
- **Love and dislike in `orca-gtk`.** A heart beside the title in the player
  bar loves the audible song or removes the love; loved songs show a small
  heart in the track list and on album pages; the context menu offers Love,
  Dislike, Remove Love and Remove Dislike on one song or a selection; the
  details panel has a Feedback row that says when a song has no MusicBrainz ID
  and is saved on this computer only. The Listening page shows how many loves
  and dislikes are waiting to sync. The heart icons are `orca-heart-*-symbolic`
  SVGs under `apps/linux/data`, dedicated to the public domain (CC0-1.0).
- **Now Playing in `orca-gtk`.** Preferences > Listening has Show what I'm
  playing now, off by default and available while Submit listens is on; it is
  saved as `[listening] now_playing=true|false`.
- **`orca-cli feedback DATABASE IDS (--love | --hate | --clear)`** sets
  feedback and prints how many Tracks were updated and skipped. `orca-cli track`
  prints `feedback:` and `feedback sync:`, and `scrobble` sends pending
  feedback as well as listens, reports `feedback_pending` and finishes when
  neither queue has anything left; with both empty it still makes no request
  and looks up no token. `scrobble --status` prints `feedback_pending`.
- **Love and hate for songs.** `Runtime.librarySetFeedback` marks the song
  behind each Track loved, hated or cleared, and `libraryTrackFeedback` reads
  it; `TrackSummary.feedback` and `TrackDetails.feedback` report it and
  `TrackDetails.feedback_syncable` says whether ListenBrainz can be told. The
  mark belongs to the Recording, so a FLAC and an MP3 of one song share it and
  a reprojection keeps it. While a Library scrobbles, changes are sent as
  ListenBrainz recording feedback, one request per change, only for
  Recordings with a MusicBrainz recording id, including changes made while
  scrobbling was off. `ScrobblerStatus.feedback_pending` counts the changes
  waiting. A change is sent once it has stood for 2 s, so only the final state
  goes out, and nothing if it matches what the service has; clearing a change
  the service rejected forgets it locally with no request; a change the service
  accepted but Orca could not record is not sent again, and only the local mark
  is retried, from 60 s doubling to an hour. `TrackSummary.recording_id` names
  the song behind a row.
- **Now Playing, off by default.** `librarySetScrobbling`'s new last argument
  announces the playing track to ListenBrainz once it has been heard for 10 s
  (tracks of 30 s or more): one request per track, never retried, dropped when
  the service is rate limited, offline or 60 s stale, and never ahead of a due
  batch of listens.
- **Breaking.**
  - `Runtime.librarySetScrobbling` takes a fourth argument, `now_playing`.
  - Schema version 16 adds `feedback`, keyed on the recording, and the index
    `files_by_recording ON files(recording_id)`; a database
    opened by this build is refused by earlier builds.
  - Schema version 15: a database opened by this build is refused by earlier
    builds. `scrobble_queue` gains `lease_owner` and `lease_expires_at`; queued
    rows stay pending.
  - `network.client.Config.user_agent` is replaced by `Config.identity`
    (`ClientIdentity`), and the default User-Agent is now
    `Orca/0.2.0 ( evan@evanriley.com )`.
  - `providers.scrobble.dispatchReady` and the `ListenBrainz` adapter are
    removed; `providers.listenbrainz.Delivery` replaces them.
  - `playerBindLibrary` starts the Library's listen worker and can fail doing
    so.

- **`orca-gtk` shows whether a ListenBrainz token is saved.** The token field
  no longer has an apply checkmark that looked like the token was already
  stored: it has a Save button, enabled while the field has text, and Enter
  saves too. When a token is stored, a row reads "Saved in your keyring" with a
  Remove button, and the field is titled Replace token. The stored state is
  looked up when the Listening page is first shown and after each save and
  remove, asynchronously and without reading the secret; a keyring that stays
  locked reads "Keyring locked", with an Unlock button. An empty field no longer
  removes the token; Remove does.
- **A heart on every song row in `orca-gtk`.** The Tracks list, album pages, the
  queue and the Now Playing page (the audible song and the songs up next) have a
  heart button after the title: filled and red when loved, otherwise an outline
  dimmed until the row is hovered or selected. Pressing it loves the song or
  removes the love, and a disliked song becomes loved, without playing the song
  or changing the selection. All rows of the recording, the player bar and the
  details panel update together. The queue repaints in place instead of
  rebuilding, so it keeps its scroll position.

### Daily-use fixes

- **`orca-gtk` keeps the equalizer curve and crossfeed amount while they are
  off.** `settings.ini` saves `equalizer` and `crossfeed` as values and adds
  `equalizer_enabled` and `crossfeed_enabled`; older files still load.
- **Album page rows can be selected.** A click or the arrow keys select a
  row and show it in the details panel; double-click or Enter plays from it.
- **`orca-cli` reports errors as one line**, `orca-cli: no track with that id`,
  instead of an error trace, and exits with status 1.
- **A library migrated from before file identity, on storage Orca cannot
  name, moves its root onto the root's own volume.** Without a filesystem
  UUID or a writable mount root, the root and its files used to stay on the
  shared `legacy` volume after every scan. No data was lost.

### Removing a folder forgets its tracks

- **`Runtime.libraryRemoveRoot` forgets everything that exists only under the
  root**: its files, their tags and Orca values, the Tracks they backed, and
  the Releases and Artists nothing else references. It returns `RemovedRoot`
  with the counts. Files on disk are not touched; a file also located under
  another root stays and is reprojected; the tag-write undo journal keeps its
  rows. It returns `error.LibraryJobRunning` while any job on the Library runs,
  and `error.UnknownRoot` for an unregistered id. (Breaking: it returned
  nothing.)
- **`orca-cli roots` and `orca-cli remove-root`** list the registered folders
  and forget one. `orca-gtk` asks first, then reports how many tracks left.
- `orca_library_remove_root` keeps its signature and now reports
  `ORCA_STATUS_NOT_FOUND` for an unknown root and `ORCA_STATUS_BUSY` while a
  job is running.

### Live DSP

- **A ten-band equalizer, stereo crossfeed and a signal-path report.**
  `Runtime.playerSetEqualizer`, `playerSetCrossfeed` and `playerSignalPath`
  drive a per-Player DSP chain (preamp, equalizer, crossfeed, volume) that
  runs on the engine thread and costs nothing when off;
  `orca-cli play-tracks --eq=PRESET|G1,...,G10[:PREAMP] --crossfeed=AMOUNT`
  applies it and prints the signal path.
- **`orca-gtk` gets a Sound page and a signal path.** Preferences has a Sound
  page with the ten-band equalizer, presets, preamp and crossfeed, saved in
  `settings.ini` and applied at launch; the output menu shows the signal path
  and whether it is bit-perfect.
- **Playback at the source's sample rate.** Each PipeWire stream requests
  `node.rate` at its source rate, and the signal path reports the rate the
  device runs at (`SignalPath.device_rate`), adding sample rate conversion
  when PipeWire resamples because the request was not honoured.
- **Track details.** `Runtime.libraryTrackDetails` returns a Track's format,
  file, loudness and tags; `orca-cli track DATABASE ID` prints them, and
  `orca-gtk` shows them in a panel beside the Tracks list and album pages
  (`Ctrl+I`), with the signal path for the playing track.

### A designed GTK frontend

- **`orca-gtk` is a libadwaita app.** A sidebar of pages, a full-width player
  bar with the cover, centred transport and an output menu, a queue page,
  scan progress in the sidebar, a welcome page for an empty library, toasts
  instead of a status line, a shortcuts dialog (Ctrl+?) and an About dialog.
  The window adapts below 760sp.
- **Albums**: a grid of covers sorted by artist, title, year or recently
  added, and a page per album with Play, Shuffle and its tracks by disc.
  Albums without covers show their initials on a colour of their own.
- **Now Playing**: the cover, large, on a wash of its own colour, with what
  comes next. Click the cover in the player bar to open it.
- **Queue thumbnails**, and covers everywhere load and decode off the main
  thread.
- **Artists**: every Artist, searchable, and a page per artist with their
  albums, Play and Shuffle.
- **Back goes back**: the mouse back button and Alt+← return to the page shown
  before, including from Now Playing.
- **Right-click menus on artists, album covers and titles, and the playing
  track's cover**, besides tracks, album tiles and queue entries. The track
  list's menu no longer opens a row short.
- **The playing track is marked on album pages**, and on its whole row
  wherever tracks are listed.
- **Edit Tags** from any right-click menu: one track or many, saved to the
  library, then optionally written to the files after a preview, with Undo.
- **Preferences** (Ctrl+,): music folders, loudness measurement, duplicate
  finding, ReplayGain and the output device, which are remembered.
- **Health**: the issues liborca found, with Find Duplicates.
- Scans, measurement, duplicate finding and tag writes share one progress card.
- **The queue is editable**: click an entry to play it, remove entries, and
  Play Next or Add to Queue from a right-click menu on tracks, albums and
  queue entries, which also offers Show Album and Show Artist.
- **The playing track is marked** in the track list and the queue.
- **Enter in the search box plays the results.**
- **Rescan Library** is in the main menu.
- `nix build` installs a desktop entry and an icon.
- The dev shell sets `XDG_DATA_DIRS` for the GSettings schemas GTK looks up.

### Cover art off the caller's thread

- **`Runtime.libraryRequestArtwork`** queues a cover lookup on the Library's
  artwork loader, and `libraryTakeArtwork` collects it; `libraryCancelArtwork`
  skips one not yet started. `orca-cli covers` reads a page of covers this way.
- **`ReleaseQuery.sort`** orders Releases by title, artist, year or recently
  added.
- **The queue can be edited in place**: `Runtime.playerQueueJump`,
  `playerQueueInsertNext` and `playerQueueRemove`. Play Next lands after the
  entry the engine has already lined up, if it has, and neither that entry nor
  the playing one can be removed.
- **`TrackSummary` carries `release_id` and `artist_id`.**
- **`libraryEditTracks` returns `EditedTracks`**, the Tracks the edited files
  back afterwards, since moving a track to another album gives it a new id.
  `orca-cli edit` prints them. (Breaking: it returned nothing.)
- `core/root.zig` now lists its files in a test block, so their tests run.

### Tag write-back

- **Library edits can be written into the files.** `Runtime.planTagWrite`
  previews the changes as a sealed plan, `Runtime.startTagWrite` writes it as a
  Job once approved by its digest, and `Runtime.undoTagWrite` restores the
  files' previous bytes. `orca-cli write-tags` and `orca-cli undo-tags` reach
  them. FLAC, MP3 and ADTS are written; other formats are reported as not
  writable, and files changed since their scan are left out.
- **MP3 and ADTS tags are written as ID3v2**, in the file's existing version,
  with every other frame, the cover art and the audio bytes kept. The ID3v1
  writer is gone; an existing ID3v1 trailer is updated to match.
- **FLAC comment writes match the reader.** A write used to compare field names
  and values literally, so an `ALBUMARTIST` field or a `3/12` track number was
  duplicated or refused instead of replaced.

### Library edits, and a projection that cleans up after itself

- **Tracks can be edited in the library.** `Runtime.libraryEditTracks` and
  `orca-cli edit` set title, artist, album, album artist, track, disc, date and
  compilation as locked user values; the files are never written, rescans keep
  the edit, and `--clear` returns a field to the file's own tag.
- **Retagged files no longer leave ghost tracks.** Reprojection created a new
  Track when a file's tags moved it to another album or position and left the
  old row, its Release and its Artist listed with nothing behind them. They are
  now pruned; migration 14 adds the index that keeps this cheap.

### The common formats are complete; the rest wait until after 1.0

- **WAV files written as `WAVE_FORMAT_EXTENSIBLE` open**, which is what FFmpeg
  and most DAWs write past 16-bit stereo.
- **AIFF and uncompressed AIFC decode**, including `sowt`, bit-identically to
  the FLAC they were written from.
- **WAV and AIFF carry tags and cover art** from their ID3 chunk, and WAV from
  `LIST`/`INFO` as well.
- **Ogg Opus and Vorbis files show their cover art** from
  `METADATA_BLOCK_PICTURE`.
- **Raw `.aac` (ADTS) files play** instead of being mistaken for MP3.
- WavPack, APE, TTA, Musepack, DSD, WMA and less common containers are
  deferred; `docs/roadmap.md` lists them.

### A deliberate public Zig API (breaking)

- **`liborca`'s top level is the API.** It exports `Runtime`, its handles and
  every type its methods take or return. The twelve subsystem namespaces moved
  under `liborca.internal`, which is for liborca's own tests and benchmarks.
- **`OrcaRuntime` is `Runtime`** from outside the library.
- **`Runtime.libraryDatabase` is no longer public.** The CLI used it to reach
  the database directly; `libraryUnanalyzedCount`, `libraryAnalyzeFile` and the
  existing `libraryHealthIssuePage` replace those uses. Seven test-only hooks
  (`startDummyWork`, `markZoneOutputLost`, ...) are private too.
- **`examples/embed`** depends on Orca as a Zig package and lists a library's
  tracks; `zig build test` builds it. `docs/api.md` documents embedding and the
  surface.

### QOA decodes through the reference decoder, and seeks

- **The `audiophile/qoa` package is gone.** It shipped no licence, which left
  Orca redistributing code it had no right to, and it could not seek. The
  reference `qoa.h` (MIT) is vendored behind `codec/qoa_shim.c`, as minimp3 is.
- **QOA seeks exactly.** Frames are independent and all but the last are
  full, so a seek lands on its frame by arithmetic; a sought decode equals a
  sequential one sample for sample, across a frame boundary included.

### MP4: ALAC and AAC play, scan and tag

- **ALAC decodes bit-identically** through Apple's reference decoder, built
  from source behind a C++ shim: the ALAC fixture's samples equal those of the
  FLAC it was encoded from, and seeks land on the exact frame.
- **AAC (LC, HE-AAC v1/v2, xHE-AAC) decodes through libxaac**, AOSP's
  Apache-2.0 decoder, built from its portable C sources. Against FFmpeg's decode
  of the same file the output has zero lag, the exact length and differences at
  16-bit quantization level. libxaac withholds 240 frames of the first access
  unit after init; the packet loop restores them as silence so the timeline
  stays where the sample table puts it.
- **Gapless bounds come from the edit list**, with Apple's `iTunSMPB` as a
  fallback, so a 200 ms AAC fixture carrying 1,024 frames of encoder priming
  decodes to exactly 9,600 frames.
- **iTunes tags and cover art** are read from `ilst`, including `----`
  freeform atoms for MusicBrainz identifiers.
- **Scanning MP4 costs what scanning FLAC does.** Properties come from the
  movie box rather than from an AAC decoder whose setup costs about 6 ms: a
  300-file AAC scan fell from 1.83 s to 0.14 s.
- **Files without a decoder are no longer reported as corrupt.** The analysis
  pass and property backfill filed AIFF, WavPack and any other sniffed but
  undecodable file as `corrupt_audio` or `unreadable_file` on every run.
- `zig build` installs the licence and notice files of the compiled-in
  Apache-2.0 and CC0 code under `share/doc/orca/licenses`.

### Ogg Opus and Ogg Vorbis play, scan and tag

- **Opus and Vorbis decode through libopusfile and libvorbisfile**, each behind
  a shim on the same terms as libFLAC. The libraries own the Ogg container,
  pre-skip, end trimming and sample-exact seeking, so a 200 ms Opus fixture
  whose container also carries 312 frames of encoder pre-skip decodes to
  exactly 9,600 frames, and 30-second streams report exactly 30,000 ms.
- **Tags come from the Ogg comment header** through a small page reader in
  `metadata/ogg_comment.zig` and the existing Vorbis comment parser. A comment
  packet spanning several pages is reassembled, bounded at 16 MiB.
- Scanning records `codec` as `opus` or `vorbis`, the decode rate, and no bit
  depth; analysis measures both formats and playback applies their
  ReplayGain. Embedded Ogg artwork is not read yet.

### Stable Zig, a Nix flake, and three defects the old snapshot hid

- **Orca builds with Zig 0.16.0.** The previous pin, `0.17.0-dev.1770`, is no
  longer downloadable, so the project could not be built reproducibly. The port
  is mechanical: `@backingInt`/`@fromBackingInt` became
  `@intFromEnum`/`@enumFromInt`, plus a handful of renamed `std` functions.
- **`flake.nix` provides the dev shell and a package.** `nix develop` (or
  direnv) supplies Zig, zls, pkg-config, SQLite, libFLAC, PipeWire and GTK4;
  `nix build` produces `orca-cli`, `orca-gtk`, `liborca` and `orca.h`.
- **`build.zig` no longer assumes `/usr/include`.** PipeWire and SQLite include
  paths come from `pkg-config --cflags-only-I`, so the build works on NixOS and
  on FHS distributions alike.
- **Volumes on device-mapper storage now get a stable identity.** A mount
  source such as `/dev/mapper/cryptroot` is a symlink to `/dev/dm-N`, and the
  `/dev/disk/by-uuid` lookup compared the symlink's own name, so LUKS and LVM
  volumes never matched their UUID and every Location on them was filed under
  no volume.
- **The analysis pass no longer re-measures every file.** The query selecting
  unanalyzed files bound its parameter hash as an SQLite static blob from a
  pointer into a by-value copy that died before the statement ran. The old
  compiler passed that struct by reference, which hid the defect.
- **A queue test stopped starving the engine it waited on.** It polled
  `playerQueueStats`, which pauses the engine on every call; it now polls the
  lock-free queue snapshot.

### Planning documents replaced

- `docs/architecture.md` and `docs/roadmap.md` replace the v1.0 implementation
  plan, the v0.10.0 review and the integration-recovery design. The recovery
  work those documents drove is complete; what remains is in the roadmap.

### FLAC decoding moved to libFLAC, because the pure-Zig package was not lossless

- **The pinned `audiophile/flac` dependency is gone.** It reconstructed
  mid-side stereo without restoring the low bit the encoder discards, so
  roughly half of all decoded samples came back one LSB low on the majority of
  real FLAC files. Exhaustively over 208,208 (left, right) pairs its formula is
  wrong for 50.0% of them; on ten 20-second excerpts of real music it differed
  from reference PCM on 10.2%–48.2% of samples. Inaudible at −96 dBFS, and
  fatal to `files.audio_hash`, to fingerprints, and to the one promise the
  format makes. The package ships no licence, so a corrected vendored copy was
  not an option.
- **`codec/flac_shim.c` contains libFLAC** on the same terms as `mp3_shim.c`
  and `pipewire_shim.c`. It is driven from `ReadableSource` through
  `FLAC__stream_decoder_init_stream`, so no path string or file handle is
  needed and no `FLAC__` type is visible above the shim. The same ten excerpts
  now decode bit-exactly — 0 differing samples, `max |delta| = 0` — and two
  encodings of one PCM stream at compression levels 0 and 12 decode
  identically to each other and to the WAV. Decoding is 2.7× faster: 15.7M
  frames in 0.148 s against 0.403 s, ReleaseFast.
- **`fixtures/audio/midside-reference.flac` is a regression fixture whose every
  sample has an odd `side`,** so a decoder that skips the low-bit restoration
  is wrong on 100% of them rather than 50%.
- **Stored analysis is invalidated.** `diagnostics_algorithm_version` and
  `fingerprint_algorithm_version` are both 2, so an existing library
  re-measures rather than trusting figures taken through the old decoder. Run
  `orca-cli analyze-library DATABASE`, then `orca-cli duplicates DATABASE`.

### Duplicate detection became reachable, indexed and bounded

- **`orca-cli duplicates` reports the audio a Library holds twice.** A runtime
  job (`OrcaRuntime.startLibraryDuplicateScan`,
  `orca_library_start_duplicate_scan`) on the same `JobWorker` machinery as the
  scan, the projection, the property backfill and the analysis pass: same
  cancellation token, same job snapshot, bounded commits, indexed row
  selection. Findings land in `library_health_issues` as `exact_duplicate` and
  `likely_duplicate` — two kinds that had existed, and two `analysis/health.zig`
  facts that had existed, with nothing producing either.
- **`fingerprint.findDuplicates` is gone.** It took every candidate in the
  library as one slice and compared all pairs: correct, tested, called by
  nothing, and impossible to call at 22,060 files let alone 500,000.
  `classifyDuplicate` survives it as the only pairwise comparison in the
  codebase; what changed is that an index now decides which pairs reach it.
- **Three indexed queries, no scans.** Selection walks `files` by primary key;
  the certain bucket is an equality search of `files_audio_hash`; the plausible
  bucket is a range search of `files_duration`, added by migration 13. A bucket
  holds at most 64 files, so the work is bounded by a constant per file, and at
  most two decoded fingerprints are resident at a time.
- **A file nothing has measured is counted, not silently called unique.**
  Reporting "no duplicates" over an unanalyzed library would be a lie of
  omission; 19,108 of the reference library's 22,060 rows are uncomparable
  today, and the run says so on its own line.
- **The likely threshold is 0.985, measured against the real library.**
  Constructed encodings of one master score 0.9904–1.0000 and the library's one
  real FLAC-and-MP3 pair scores 0.98511; unrelated tracks sharing a duration
  window reach 0.9590 across 11,568 real comparisons, and a track against its
  own karaoke cut reaches 0.9800. An earlier 0.95 produced 31 findings on the
  reference library, most of them unrelated tracks.
- Full run over the 22,060-file reference library (3,543 of it analyzed):
  1.30 s, 16.1 MiB peak RSS, 20,117 comparisons, five duplicate pairs and **no
  false positives** — every finding confirmed by hand against the files. One of
  them, `Roel Funcken — Nefit Kraton` against `— Scane Breitner`, is identical
  PCM under two different titles, which nothing else in the codebase could have
  found. 18,532 rows were reported uncomparable because `analyze-library` has
  not reached them. Re-running produces the same rows rather than twice as
  many, and a duplicate that has been deleted stops being reported.
- **Known limitation, recorded rather than worked around.** `codec/flac.zig`
  disagrees with the file's own PCM on 25.5% of samples (one LSB low, measured
  against ffmpeg on 18,522,000 samples), and its error pattern depends on the
  encoding, so two FLACs holding identical audio hash differently. That costs
  the exact test some findings it should make: a real byte-identical pair is
  reported as likely at 100.0% instead of exact. See `docs/analysis.md`.

### Album art became reachable, and the player shows it

- **Embedded cover art can be read, not just counted.** `observed_file_tags`
  had recorded an artwork MIME type, size and kind since the scanner existed,
  and nothing could obtain the image behind them. `metadata/artwork.zig` sniffs
  the container and dispatches to `id3v2.readPicture` or
  `vorbis_comment.readPicture`, which extract `APIC` and `PICTURE` payloads
  through the *same* frame and block parsers the observation already used — so
  an observation and a fetch cannot disagree about which bytes are the image.
  Verified byte-for-byte against an independent extractor on a real FLAC
  (254,372 bytes) and a real MP3 (422,564 bytes).
- **A leading ID3v2 tag does not hide a cover.** Artwork resolves the payload
  offset exactly as the codec registry does, so the reference library's 104
  ID3-fronted FLACs give up their `PICTURE` block. The adversarial case — a
  216,921-byte picture block behind a 219,663-byte tag — extracts to the exact
  216,870 image bytes an independent tool reports.
- **The media type is read from the bytes, not from the claim.** 93 files in
  the reference library declare `image/jpg`, 24 declare nothing, and one
  album's covers are 5.3 MB animated GIFs behind an empty declaration. A
  payload that is not a recognised image is refused rather than handed to a
  platform decoder, and the size bound — 12 MiB, below both containers'
  ceilings so it can actually fire, above the library's largest real cover of
  11.29 MiB — is checked against the declared length before anything is
  allocated to honour it.
- **Nothing is stored in the Library and nothing is cached.** 19,031 of the
  22,060 files carry a readable cover, totalling 6.09 GB; that does not belong
  in a SQLite file. Reading on demand costs one open per request, can never go
  stale — a track whose observation predates the current reader still yields
  its cover — and a whole-library audit of all 22,060 files took 6.3 seconds.
  A bounded per-Release cache is the right next step and is deliberately not
  here yet, because the one consumer loads a single image per track change.
- **A Release's artwork is its first track's, in listening order, that has
  one.** Real tag data disagrees within an album, so the rule is chosen to be
  stable across runs (the unique `tracks_position` order), cheap (candidates
  are pre-filtered by what the scan observed, so a coverless Release opens no
  files at all, and at most eight are tried), and unsurprising.
- **The GTK transport bar shows the now-playing cover.** One `GtkImage` in two
  states, refreshed only when the audible Track changes. A missing cover, a
  missing file, a refused image and an undecodable one all show the same
  placeholder. Decoding is bounded to 128 pixels inside gdk-pixbuf's scaling
  loader, because an 11.3 MiB JPEG is 3000 pixels square and encoded size says
  nothing about pixel count. Driven through the real widgets on the real
  library: 154 MB resident with all 22,060 tracks open and no cover shown,
  168 MB with an ordinary cover, 192 MB with the largest cover in the library,
  steady across eleven consecutive loads.
- **The Releases pane deliberately shows no thumbnails.** 512 covers per page
  load is 512 file opens and roughly 150 MB of encoded image on one scroll.
  `libraryReleaseArtwork` exists for when a grid view and a cache do.
- `orca-cli artwork DATABASE (--track=ID | --release=ID) [--out=PATH]`.

### Analysis became a library job, and playback started using it

- **`orca-cli analyze-library DATABASE` measures a whole Library.** Loudness,
  peak, clipping, silence, waveform and temporal fingerprint were computed only
  for one file a human named, so `Gain.setReplayGain` was called by nothing and
  a quiet track stayed quiet. `library/analysis_pass.zig` runs the same
  measurement over every file the Library has not measured yet, as a runtime
  job on the shared `JobWorker` — reachable from the Zig API, the C ABI
  (`orca_library_start_analysis`) and the CLI, with `files.audio_hash` written
  for the first time.
- **It is built to be stopped.** It decodes whole files, so a run is hours
  rather than seconds: 50 real files measured in 27.2 s (0.545 s each,
  ReleaseFast), which extrapolates to about 3.3 hours for the 22,060-file
  reference library. Cancellation is honored inside a decode, the batch already
  measured still commits, and the next run selects only the remainder — a pass
  cancelled after 11 of 50 files was followed by one that measured exactly 39.
- **"Already analyzed" is the analysis cache key, not a new flag.** The key
  already encodes every reason a measurement stops describing a file — its
  bytes, its algorithm version, its parameters — so selection is an anti-join
  against `analysis_results`' own primary key rather than a marker column free
  to disagree with the results it describes. The page query is
  `SEARCH files USING INTEGER PRIMARY KEY` plus one full-prefix covering-index
  probe per row; no new index, no table scan.
- **ReplayGain reaches the audio, and stays right across a gapless
  transition.** The correction is a property of the audio rather than of the
  Player: the session that decodes an entry carries the figure measured from
  those exact bytes and scales its own frames by it, so an entry with no
  measurement plays at unity instead of inheriting the previous one's and a
  file edited since the last scan loses a correction it no longer matches. A
  Player-level multiplier could not be right during a gapless advance — the
  pipe holds two entries' blocks at once — and neither could a per-block one,
  because a canonical block is filled from two decoders across the boundary.
  Attaching it at the single point where a queue entry becomes audio covers
  the hard load, the auto-advance, the format switch and the seek re-open
  together. On the reference corpus the loudest and quietest tracks went from
  17.30 dB apart to 0.71 dB, gaplessly as well as on a skip, with the
  transition's gapless, decode-error, open-failure and underrun counts
  unchanged. `off` and `track` reach the ABI and `orca-cli play-tracks
  --replay-gain=`, and now take effect as the decoded-ahead audio drains
  rather than at the next track; album gain is out of scope.
- **`orca-cli play-tracks` can move the volume.** `--volume=N` and
  `--set-volume=MS:N` exist so that user volume and loudness correction being
  independent is checkable from outside: changing one mid-track leaves the
  other exactly where it was.

### The library became browsable, and stopped losing 104 files

- **Tracks are connected to artists.** The projection wrote 2,474 artists and
  2,637 releases and nothing could read any of them back — no list, no page, no
  lookup by id — and there was no relational link at all: `tracks` had no
  `artist_id`, `recordings` no artist, `releases` no `album_artist_id`.
  Migration 9 adds the links and 11 re-keys them; `ArtistPage`, `ReleasePage`
  and a `TrackQuery` with seven sort keys, a direction and artist/release
  filters expose them through the runtime, the C ABI and `orca-cli artists /
  releases / tracks`. Paging is exact under ties: every `ORDER BY` ends with a
  unique tiebreaker, without which `LIMIT`/`OFFSET` silently drops and
  duplicates rows — 3,476 of 22,060 tracks share a title.
- **An artist's tracks are the ones credited to them *or* on a release they are
  the album artist of.** The narrow definition left 33 artists owning an album
  and no songs, and those are not tag defects to normalize away: a featured
  credit, a collaboration, an `&`-versus-`,` convention, or simply no `ARTIST`
  tag. Widening the definition covers all of them and guesses at nothing.
- **The key fold learned typographic punctuation.** `ALBUMARTIST` carries what
  a metadata service supplied and `ARTIST` carries what somebody typed, so
  `El‐P` (U+2010) and `El-P` were two artists — one holding every release, the
  other every track. Migration 11 merges them; **migration 12 re-keys releases
  for the same reason**, without which any reprojection built a parallel
  release beside each stale one and turned 22,060 tracks into 23,271.
- **An ID3 tag is not a format.** `sniff` answered `ID3` with `.mp3`, so 104
  genuine FLAC files in a real library were handed to the MPEG decoder and were
  **unplayable**. Detection now returns a payload offset and the codec registry
  presents the decoder an `OffsetSource`; the scanner steps the tag reader over
  it too, so those files stop scanning as untitled with no artist. MPEG
  deliberately keeps offset 0, because its decoder is defined over the whole
  file including trailing tags.
- **A FLAC that stops inside its final block is finished, not broken.** Real
  files end untidily — one of those 104 stops 2,620 frames short of the
  11,979,324 its STREAMINFO declares. That raised `OutOfSync`, which failed
  analysis outright and ended playback in a decode error. A shortfall smaller
  than one maximum block is at most the final frame; anything larger still
  errors.
- **Destroying one Player no longer tears down every other one.** It drained
  the whole work registry, cancelling every other Player's engine thread and
  every scan in flight. Registrations carry an owner tag now.
- **User volume and replay gain no longer overwrite each other.** They shared
  one stored value, so applying a loudness correction would have moved the
  host's volume slider.

### Files declare what they are, and old rows can be repaired

- **`files.codec` is written.** It was declared and then always stored as the
  empty string, so every row in a real library recorded no encoding at all. A
  probe already opens a decoder; the decoder now names its encoding through
  `codec/decoder.zig`'s `codec_id` — `pcm`, `pcm_float`, `flac`, `qoa`, `mp1`,
  `mp2`, `mp3` — and the scanner carries that into the row. It is deliberately
  **not** a synonym for `audio_format`: that names the container, which decides
  who opens a file, while `codec` names the encoding inside it, which decides
  what the bytes cost. The two diverge wherever a container is a wrapper — a
  WAV holding integer PCM or IEEE float, an MPEG stream's layer, and the
  AAC-or-ALAC and Vorbis-or-Opus cases still to come. Lossy and lossless are
  told apart by `codec_id.isLossless`, a function of the identifier rather than
  a second column that could disagree with it.
- **A property backfill, as a runtime job.** The scanner probes only files
  whose bytes changed, which is what keeps a rescan of a large library nearly
  free — and which means a library scanned before probing existed keeps null
  `duration_ms` for ever, because a music collection's bytes never change.
  `library/property_backfill.zig` repairs those rows by `files.id` with no
  filesystem walk: `OrcaRuntime.startLibraryPropertyBackfill`,
  `orca_library_start_property_backfill`, `orca-cli backfill`. Row selection is
  a search over `files_incomplete_properties`, a **partial** index (migration
  10) over exactly the incomplete rows, so it shrinks to nothing as the pass
  works. Commits are bounded, cancellation is checked between rows, and a
  cancelled run commits what it already probed — so a second run resumes with a
  shorter list rather than starting over. **Unlike a scan the job publishes a
  total**, because how many rows still owe a probe is one indexed count.
- **The backfill reprojects what it repaired.** `tracks.duration_ms` is derived
  from the file rows, so a pass that repaired `files` and left the Tracks
  reading zero would have fixed nothing a transport bar can show. Each
  committed batch is handed to the projection scoped to its own file ids,
  exactly as a scan batch is.
- **An unreadable file is not a failure of the pass.** A row whose file is gone
  or is not audio is counted and passed over with no health issue, because
  `locations.state` already models absence. A file that opens and then refuses
  to decode raises the new `unreadable_file` health issue, a kind the backfill
  owns outright so that clearing it cannot erase a `corrupt_audio` finding the
  analyzer made by decoding audio this pass never read.

### The C ABI reaches the runtime (breaking)

Until now `liborca/orca.h` exposed runtime create/destroy, library open/query,
and a Player state machine that was not connected to anything. There was no way
to load a track, attach an output, trigger a scan, read a position, or observe
an event, which is why the GTK app's play button did nothing. The boundary now
exposes the surface the frontends actually need.

- **Breaking: `orca_track_view` grew.** It now carries `artist`, `duration_ms`,
  `track_number`, `disc_number` and `has_file`, each numeric field paired with a
  `has_*` flag so "zero" and "the library does not know" stay distinguishable.
  `TrackSummary` already carried all of it. Both consumers are in-tree and there
  are no external clients, so the break was taken now rather than later.
  `orca_player_state_snapshot` is untouched; the richer transport view is a
  **new** `orca_player_status` rather than a grown struct that already shipped.
- **Scanning is a job, not a blocking call.** `orca_library_add_root`,
  `orca_library_remove_root` and `orca_library_query_roots` manage roots;
  `orca_library_start_scan` registers a `work.Registry` worker with its own
  `std.Io` and its own cancellation token and returns immediately.
  `orca_job_snapshot_get`, `orca_job_cancel` and `orca_library_scan_stats`
  observe it. **Scan progress reports `completed_units = files_processed` with
  `has_total = 0`:** a filesystem walk has no honest denominator until it has
  finished walking, and Orca does not invent one. Shutdown, `orca_library_close`
  and `orca_player_destroy` all cancel and join scan workers before anything
  they hold can be freed.
- **The scan projects as it commits**, exactly as `orca-cli scan` does, because
  a scan whose results are never projected has not made a library browsable.
  `orca_library_start_projection` is the other direction — reprojecting after a
  metadata change, with no filesystem walk. `orca-cli scan` and `project` now
  run through those same runtime jobs, so the CLI and the ABI cannot drift.
- **Events.** `orca_runtime_pump` drives the control lane;
  `orca_runtime_poll_event` drains the existing lossless completion channel and
  the existing coalescing telemetry channel into one tagged POD `orca_event`
  with a named `extern union` payload — ABI-stable, and it imports cleanly into
  Swift. Kinds: command completed, job progress, job finished, player position.
- **Transport, queue and now-playing.** `orca_player_set_library`,
  `_play_track` (through the control lane, correlated by request id),
  `_play_tracks`, `_enqueue_tracks`, `_next`, `_previous`, `_clear_queue`,
  `_set_repeat`, `_set_shuffle`, `_set_volume`, `_volume`, `_seek_ms`,
  `_status_get`, `_now_playing` and `_query_queue`. `orca_player_status`
  carries transport, repeat, shuffle, epoch, `position_ms`, `duration_ms`,
  `track_id`, `queue_length`, `queue_index` and volume in one lock-free read.
  Position is derived from the packed epoch+frames atomic the render callback
  writes, never reconstructed from events, and now-playing reports the
  **audible** entry rather than the decode cursor.
- **Devices and zones.** `orca_enumerate_output_devices`, `orca_zone_create`,
  `_destroy`, `_attach_player`, `_detach`, `_open_output`, `_close_output` and
  `_status_get`, plus `orca_player_open_default_output`, which creates,
  attaches and opens in one call so a single-output frontend never has to know
  Zones exist. Device id 0 delegates to the server default.
- **Volume is real.** A `processing.Gain` lives beside each Player, is installed
  as the engine's Player-scope processor, and applies to canonical PCM once
  before fanout, so every Zone hears the same level and a stop/start keeps it.
- **A single-thread contract that is enforced.** All `orca_*` calls for one
  runtime must come from one thread, `orca_runtime_poll_event` included. Debug
  builds record the creating thread and return `ORCA_STATUS_WRONG_THREAD` on a
  violation. This is no longer theoretical: the runtime behind the boundary is
  genuinely multithreaded and its object pools take no lock.
- **A Player with nothing to play refuses to play.** `orca_player_play` now
  requires a loaded source or a non-empty queue *and* an attached Zone. The C
  ABI smoke test asserted the opposite for as long as the defect existed; that
  assertion is now inverted, and the test drives the whole path — open, add
  root, scan as a job, wait, project, query, open a default output, play by id,
  watch the position advance, pause, seek, next, clear, shut down.
- **Position is anchored to the audible queue entry, not to the epoch.**
  `orca_player_status.position_ms` used to keep accumulating across a gapless
  auto-advance, so every entry after the first reported the sum of everything
  played before it — elapsed time past the end of the track, and a seek slider
  pinned past its maximum. A gapless transition deliberately does not bump the
  epoch, so frames-since-epoch was never the right anchor for a per-track
  position. The render callback now also publishes the frames-since-epoch value
  at which the audible entry started, packed with that entry's serial in a
  single `u64` so the control lane can detect a torn pair and discard it exactly
  as it discards a mismatched epoch. No lock, no allocation and no extra work in
  the render callback.

## 0.1.0-alpha

**Version reset.** The project was previously tagged `0.10.0`. That number, and
the release notes below it, describe subsystems that exist as tested components
but are **not reachable through the authoritative runtime or ABI path**. The
version has been reset to `0.1.0-alpha` to stop the changelog from overstating
what works.

### Added since the reset

- **A playback queue: Orca plays a song, and a list of songs.** A bounded
  `PlaybackQueue` of Library track references sits above the gapless decode
  queue, with enqueue, play-now, next, previous, stop, clear, repeat and
  shuffle. `playerPlayTrack` resolves a Track id through
  `TrackRepository.playableLocation` on an independent read-only connection,
  opens a self-contained decoder for it, and loads it on the control lane —
  never on a caller's UI thread — failing with typed reasons (`track_has_no_file`,
  `track_file_missing`, `codec_unavailable`) and marking the Location `missing`
  when the file has gone. Auto-advance primes the next entry at end-of-decode, so
  a real album plays gaplessly; a canonical format mismatch is not fatal but
  drains the pipe and reopens the Zone output at the new format, verified on
  hardware across 44.1 kHz -> 96 kHz -> 44.1 kHz. A user skip is a hard switch
  and immediate, `previous` restarts past three seconds, shuffle uses a
  permutation so `previous` keeps working, and now-playing is derived from the
  `entry_serial` the render callback publishes rather than from the decode
  cursor, which leads it by the whole render-ahead depth. `orca-cli play-tracks`
  drives all of it.
- **`playFileBlocking` is gone.** The stack-local single-Zone playback path has
  been deleted; `orca-cli play` runs through the runtime object graph, which is
  the only implementation left.

- **Scanned files carry their decoded audio properties.** A file whose bytes are
  new or changed is probed through the codec registry, and `files.sample_rate`,
  `bit_depth`, `channels` and `duration_ms` record what its container declares.
  Only headers are read, so a 22,060-file cold scan is unchanged at ~3.2 s and a
  rescan that finds nothing changed still does no format work at all. A file that
  will not open is recorded with no properties rather than failing the scan.
  Duration reaches `tracks.duration_ms` through the projection, so a Track lists
  its length. Verified against `ffprobe` on real library files: exact for every
  FLAC and every MP3 carrying a Xing/Info header, and within 0.1% on
  variable-bitrate MP3s that declare no length at all, which no reader can do
  better on without decoding.
- **`tracks.preferred_file_id` is chosen on declared properties.** Higher bit
  depth wins, then higher sample rate, then a location a scan has confirmed; the
  container ranking is now only a tiebreak between encodings that declare the
  same thing. A missing property is unknown rather than zero, so a lossy file
  with no sample width to state loses to a real 16-bit one, and a file the
  scanner could not open never outranks one it could.
- **MP3 playback.** `codec/mp3.zig` decodes MPEG Layer I/II/III through a
  vendored public-domain `minimp3` contained behind `codec/mp3_shim.c`, with
  pure-Zig Xing/Info/VBRI parsing, LAME encoder delay and padding trimming, and
  seeking that is exact for both constant-bitrate streams and variable-bitrate
  streams with a lazily built frame index. Verified against real library files:
  reported length matches `ffprobe` on every tagged file tested, and decoded
  length matches it exactly on eleven of thirteen.

### Fixed since the reset

- **File mutation is now crash-safe end to end.** Journal writes raise SQLite
  durability for their own transaction, every action of a group is journaled
  before any filesystem work, stage creation and both rename boundaries fsync the
  containing directory, `commitReplacement` revalidates source identity
  immediately before renaming, and `FileIdentity` carries a `quick_hash`
  (BLAKE3 over first 64 KiB ‖ last 64 KiB ‖ size) so a same-size edit with a
  preserved timestamp is detected. Recovery never reports `rolled_back` unless
  the original file is provably back in place; otherwise it records
  `needs_reconciliation` and retains every file.

### Errata against the release notes below

Verified against the code and by running the binaries, not inferred from docs:

- **No music can be played from the application.** Playback exists only inside
  `audio/backends/pipewire_playback.zig:playFileBlocking`, reachable solely from
  `orca-cli play FILE`. The runtime's Player is a detached state machine, no
  runtime Zone owns an output device, and `orca_player_play` only sets an enum.
- **Scanning does not produce a browsable library.** `library/scanner.zig`
  writes only `observed_files`; the `tracks`, `files`, `locations`, `artists`,
  `releases`, `recordings` and `library_roots` tables stay empty. Confirmed by
  scanning a 3-file folder and reading the resulting database.
- **Tags are not read for real-world files.** Only ID3v1 (the obsolete 128-byte
  trailer) is parsed, and only for MP3. `metadata/vorbis_comment.zig` has
  `rewrite` and `create` but **no `read`**, so FLAC tags are never extracted.
  There is no ID3v2 and no MP4 metadata support.
- **Only WAV, FLAC and QOA can be decoded.** MP3, AAC/M4A/ALAC, Opus and Vorbis
  fail with `CodecUnavailable`.
- `0.7.0`'s "immutable mutation previews" *was* inaccurate — an approved plan
  borrowed caller-owned slices and could be mutated through another alias, and
  startup journal recovery was only invoked directly by tests. **Both are now
  fixed:** a plan deep-copies and seals its actions and approval names a content
  digest, and `LibraryDatabase.open` drives every nonterminal journal record to a
  terminal state before returning, refusing to open if it cannot.
- `0.8.0`'s native frontends cannot select or play a track. The GTK list has no
  row-activation handler, MPRIS accepts Next/Previous with no behavior and
  reports empty metadata and zero position, and macOS has never been compiled.
- `0.9.0`'s claim that scheduler yields keep analysis subordinate to playback is
  unproven; there is no shared scheduler and no contended workload test.
- `0.10.0`'s scrobble queue is idempotent only for *local enqueue*. Remote
  delivery is at-least-once, and nothing connects the queue to playback events.
- Releases `0.3.0` through `0.6.0` are missing from this file entirely.

A capability is now considered done only when it is reachable from `orca-cli` or
the GUI through the public runtime/ABI path. The notes below are retained
unedited as a record of what was built, not as a statement of what works.

---

## Pre-reset 0.10.0 - 2026-08-21

Provider-assisted identification and scrobbling milestone.

- Central native HTTP gateway with bounded responses, service identification,
  serialized rate limits, retry/backoff policy, and explicit offline mode.
- Durable fresh/stale provider cache and MusicBrainz recording search with
  offline fallback.
- Credential-safe AcoustID lookup for externally generated
  Chromaprint-compatible fingerprints; secrets never enter durable cache keys.
- Multi-evidence candidate scoring and durable alternatives with explicit
  confidence instead of silent metadata replacement.
- Transactional proposal acceptance into Orca metadata that preserves user
  locks and remains separate from file mutation.
- Idempotent persistent scrobble queue with eligibility policy, retry state,
  and secure ListenBrainz and signed Last.fm adapters.

## Pre-reset 0.9.0 - 2026-08-21

Cached analysis and Library Health milestone.

- Streaming EBU-style gated loudness, ReplayGain adjustment, peak, RMS,
  clipping, silence, and fixed-size waveform summaries over native decoders.
- Portable, versioned analysis identities and result encodings with selective
  parameter, algorithm, and source-identity invalidation.
- Temporal fingerprints, decoded-audio and exact-file hashes, plus exact and
  likely duplicate classification.
- Cooperative cancellation, bounded progress, source revalidation, and
  scheduler yields that keep background work subordinate to playback.
- Indexed Library Health evaluation and bounded query APIs exposed through the
  CLI, stable C ABI, and virtualized GTK frontend.

## Pre-reset 0.8.0 - 2026-08-21

Native frontend and desktop-media integration milestone.

- Installed static/shared liborca with an opaque, C-compatible runtime,
  generational handles, POD Player snapshots, and callback-scoped query views.
- Bounded 256-row library pages shared by foreign clients without exposing
  SQLite rows or internal Zig layouts.
- Native GTK4 frontend with paged search, transport controls, file dialogs,
  drag/drop, notifications, accessibility-native widgets, and shortcuts.
- Verified MPRIS service whose controls and `PlaybackStatus` mirror the
  authoritative liborca Player.
- SwiftUI/AppKit client source over the same ABI with virtualized views, native
  interactions, Now Playing, and remote-command integration.

## Pre-reset 0.7.0 - 2026-08-21

Canonical metadata and safe file-mutation milestone.

- Separate observed, preferred Orca, and policy-resolved effective metadata
  layers with persisted provenance and user locks.
- Immutable mutation previews that require exact explicit approval before any
  external write.
- Durable operation journaling with staged after-identities, reverse-order
  grouped undo, startup recovery, and explicit reconciliation for external
  conflicts.
- Conservative, recoverable ID3v1 writes and Zig-native FLAC Vorbis-comment
  writes that preserve unknown metadata and encoded audio frames.
- Collision-safe journaled file moves with crash recovery and after-state-aware
  undo.

## Pre-reset 0.2.0 - 2026-08-21

Incremental local-library acquisition milestone.

- Path-independent local readable sources and byte-based format sniffing.
- Cancellable, restart-resumable recursive scans with bounded commits and
  unchanged-file identity checks.
- Persisted observed-file state and ID3v1 metadata kept separate from preferred
  Orca metadata.
- Shared per-Library write serialization and schema migrations through v3.
- Bounded/coalesced watcher hints plus a tested Linux inotify adapter.
- Headless durable scanning through `orca-cli scan`.

## Pre-reset 0.1.0 - 2026-08-21

First verified liborca foundation milestone.

- Reproducible Zig build, test, benchmark, CLI, and platform boundaries.
- Typed generational runtime handles and ordered, allocation-free shutdown.
- Bounded asynchronous commands, completion backpressure, coalesced telemetry,
  and common Job state/snapshots.
- Runtime-owned, independently openable SQLite libraries with transactional
  migrations, FTS5 search, typed batched repositories, WAL readers, and
  serialized writes.
- Repeatable 500,000-track persistence benchmark and concurrency coverage.
