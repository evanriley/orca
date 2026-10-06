# Native frontend boundary

First-party graphical applications are thin clients of `liborca`. They own
windows, widgets, accessibility presentation, and native event loops; library,
transport, metadata, and mutation semantics remain in the core.

## C ABI

`liborca/orca.h` exposes opaque runtime ownership, typed generational handles,
POD snapshots, and bounded callback-scoped query views. Both static and shared
libraries install with the header. Returned string views are valid only during
their callback, so no SQLite row or Zig container crosses the ABI. Every page is
bounded to 512 rows.

**Threading is a contract, not a convention.** All `orca_*` calls for one
runtime come from a single thread, `orca_runtime_poll_event` included, which is
single-consumer. Debug builds record the creating thread and return
`ORCA_STATUS_WRONG_THREAD` on a violation. The runtime behind the boundary is
genuinely multithreaded — a decode engine per Player, a registered worker per
scan — and its object pools take no lock, so a GUI timer racing
`orca_runtime_destroy` is a real use-after-free. The two exceptions are the
wake callback and the credential callback, which liborca calls from its own
threads; see [Wakeup](#wakeup) and [Credentials](#credentials).

On Linux, liborca switches SQLite to OFD locks for the whole process on its
first database open; see [database.md](database.md#concurrency).

The boundary covers the whole engine, not a fragment of it:

- **Library and roots.** Open/close, bounded track and health pages, root
  add/remove/query. `orca_library_add_root` takes an absolute path; a frontend
  resolves a relative one itself. `orca_library_remove_root` also forgets the
  Recordings only the root's files held, with their loves, ratings, play
  counts and playlist entries; listens stay. `orca_library_query_roots_v2`
  calls back with an `orca_root_view_v2`, which adds whether the root is
  `available`, its `track_count` and its `unavailable_tracks`.
  `orca_library_relocate_root` moves a root to a new path, keeping its ids
  and the undo of its tag writes, and returns the reconcile job it starts; a
  path that is not absolute or not a readable directory, or is nested with
  another root, its files or the root's old directory while that still
  exists, is
  `ORCA_STATUS_INVALID_ARGUMENT`, an unknown root `ORCA_STATUS_NOT_FOUND`, a
  held journal, a walk of the Library in another runtime or process, or an
  unfinished tag write under the root `ORCA_STATUS_BUSY`,
  and one awaiting reconciliation `ORCA_STATUS_NEEDS_RECONCILIATION`.
  `orca_library_missing_file_count` counts the Tracks with no present file.
- **Folders.** `orca_library_query_folder` pages one folder of a root as
  `orca_folder_entry_view` values: subfolders first, with file and Track
  counts and duration counted through every folder below, then files with
  their file id and, when `has_track_id` is set, the Track, then images
  beside them as `ORCA_FOLDER_ENTRY_KIND_IMAGE`, with no ids. The path is
  relative to the root and empty for the root itself; one with a `.`, `..`
  or empty component, a leading `/` or a NUL is
  `ORCA_STATUS_INVALID_ARGUMENT`. `orca_player_play_folder` plays every
  Track below the folder, recursively in path order, from the Player's
  bound Library, returning `ORCA_STATUS_INVALID_STATE` when there is none.
- **Health.** `orca_library_query_health_items` pages the issues in the order
  of `orca_library_query_health_issues`, which stays for hosts that only
  list them, with each issue's file, Track, Release and related file ids and
  its `orca_health_action`. `orca_library_dismiss_health_issue` hides an
  issue until its file's bytes change, `orca_library_restore_health_issue`
  shows it again, and `orca_library_health_file` fills an
  `orca_health_file_view` for a Compare or Reveal dialog, or returns
  `ORCA_STATUS_NOT_FOUND`. Dismissing a file that does not exist is
  `ORCA_STATUS_NOT_FOUND`; restoring an issue that was not dismissed is
  `ORCA_STATUS_OK`. `orca_library_health_summary` calls back once per kind
  with an issue, with an `orca_health_kind_summary_view` of its count and
  highest severity, and `orca_library_query_health_items_of_kind` pages one
  kind's items in the same order; neither lists dismissed issues.
  `orca_library_health_summary_v2` calls back with an
  `orca_health_kind_summary_view_v2`, which adds each kind's `files` and
  `bytes`.
- **Library stats.** `orca_library_stats` fills an
  `orca_library_stats_view`: the Artist, Release, Track and present-file
  counts, total bytes and duration, and the last completed scan and
  analysis times, each with a `has_*` flag. `orca_library_stats_v2` fills an
  `orca_library_stats_view_v2`, which adds the last successful duplicate scan
  and the listen count.
- **Fetched cache.** `orca_library_cache_size` fills an `orca_cache_size` of
  fetched artwork, photo, lyrics and info bytes; `orca_library_clear_cache`
  deletes them and reports what they held.
- **Provider sources.** `orca_provider_sources` calls back once per
  provider, in `orca_provider_source_id` order, with an
  `orca_provider_source_view`: its id, name, URL, what it supplies, its
  licence and the licence's URL, empty when there is none. A null callback
  is `ORCA_STATUS_INVALID_ARGUMENT`.
- **Browsing.** `orca_library_browse_artists`, `orca_library_browse_releases`
  and `orca_library_browse_tracks` take a query struct: an artist name filter,
  a release sort including `ORCA_RELEASE_SORT_LOVED`, track sorts by rating
  and love, and `loved_only` for releases and tracks. Each has a
  `*_count_matching` (`orca_library_track_match_count` for tracks) that
  ignores paging. Track views carry the recording's `orca_feedback` and
  rating, and release views whether the album is loved and its
  `orca_explicit` advisory. `orca_library_query_artists_v2` takes an
  `orca_artist_query_v2` with `loved_only` and `ORCA_ARTIST_SORT_RECENTLY_LOVED`
  and calls back with an `orca_artist_view_v2`, which adds whether the
  Artist is loved and whether the Library stores its photo, which
  `orca_library_request_artwork` returns for `ORCA_ARTWORK_SUBJECT_ARTIST`. `orca_library_browse_tracks_v2` takes an
  `orca_track_query_v2`, with `has_*` flags in place of negative ids, and
  calls back with each Track's summary and an `orca_track_facts_view`: codec,
  sample rate, bit depth, date added, the recording's play count and last
  play, the advisory, track and disc totals and year. Track sorts include
  `ORCA_TRACK_SORT_PLAY_COUNT`, `LAST_PLAYED` and `YEAR`. The v2 query also
  filters by a year range (`has_year_min`, `has_year_max`), an
  `orca_track_format` (lossless or lossy play file), `min_sample_rate` and
  `explicit_only`, and `orca_library_track_match_count_v2` counts what it
  lists. Its `text` searches the Tracks under every other filter, most
  relevant first; a track search has no count, so the count call rejects a
  non-empty `text` with `ORCA_STATUS_INVALID_ARGUMENT`. `text` in
  `orca_release_query_v2` keeps the Releases whose title or album artist has
  a word beginning with each word of it, under every filter and sort, and
  `orca_library_release_count_matching_v2` honours it. Its `kind`, an
  `orca_release_kind`, keeps albums (a Release of unknown type counts as
  one), EPs and singles, or other types; a nonzero
  `has_appearing_artist_id` keeps the Releases `appearing_artist_id` is
  credited on without being their album artist. A nonzero
  `own_releases_only` with `has_album_artist_id` keeps only the Releases
  filed under that album artist, leaving out appearances.
  `ORCA_ARTIST_SORT_RECENTLY_ADDED` orders Artists by their newest Release.
  `orca_library_artist_totals` fills an `orca_artist_totals` with an
  Artist's own Release, Track and appearance counts and summed duration, or
  returns `ORCA_STATUS_NOT_FOUND`.
- **Search.** `orca_library_search` calls back once per hit with an
  `orca_search_hit_view`: an `orca_search_kind`, the id, a title, a subtitle
  and a rank (lower is more relevant: for a Track 0, 1 or 2 as every word
  is whole in the title, begins a title word, or matches elsewhere; bm25
  for any other kind). Hits come grouped by kind (Artists, Releases,
  Tracks, Playlists, genres), most relevant first, at
  most as many of each as the `orca_search_limits` caps allow (NULL for 5,
  5, 8, 4, 3; each at most 50). Text is at most 256 bytes and every word of
  it must begin a word of the title or subtitle, ignoring case and
  diacritics; no character is query syntax.
  `orca_library_track_get` adds the release, artist and recording ids;
  `orca_library_track_details` is a details view of the Track and its file,
  read from the database alone, and `orca_library_track_details_v2` adds an
  `orca_track_details_extra_view` of the totals, whether the track total was
  counted, the advisory, and the dates the file was added and modified;
  `orca_library_track_details_v3` adds an `orca_track_details_text_view` of
  the composer and comment, empty when none is stated. `orca_library_track_play_stats`,
  `orca_library_listens_recorded`, `orca_library_unanalyzed_count` and
  `orca_library_backfill_pending` (an `orca_backfill_pending` of the files
  and covers a property backfill could repair, which checks the roots'
  volumes) are plain reads.
- **Listen settings.** `orca_library_set_listen_policy` and
  `orca_library_listen_policy` keep an `orca_listen_policy`;
  `orca_library_set_listen_recording` and `orca_library_listen_recording`
  turn the play history on and off; `orca_library_clear_listens` deletes it,
  the listens waiting to be sent and the play counts, and keeps ratings and
  loves.
- **Love and ratings.** `orca_library_set_feedback` loves, hates or clears
  feedback on Tracks' recordings, kept locally and queued for ListenBrainz;
  `orca_library_track_feedback` reads it. `orca_library_set_rating` stores a
  rating of 1 to 100 (N stars as N * 20) or clears it with 0, and
  `orca_library_set_release_love` loves whole Releases and
  `orca_library_set_artist_love` whole Artists, neither sent anywhere;
  `orca_library_artist_loved` reads one Artist's. Each edit takes at most 512 ids and returns an `orca_change_count`.
- **Playlists.** `orca_library_query_playlists` pages playlists by name
  with entry counts, duration and unix-second timestamps;
  `orca_library_create_playlist`, `orca_library_rename_playlist` and
  `orca_library_delete_playlist` manage them. `orca_library_query_playlist_entries`
  lists entries as recording ids with the Track each resolves to, if any.
  `orca_library_playlist_insert`, `orca_library_playlist_remove` and
  `orca_library_playlist_move` edit the order. `orca_library_import_playlist`
  reads an M3U or M3U8 file, reporting unmatched lines through a callback, and
  `orca_library_export_playlist` writes one with absolute or relative paths,
  refusing an existing file with `ORCA_STATUS_INVALID_STATE` unless `replace`
  is set. `orca_player_play_playlist` plays a playlist's available entries
  from the Player's bound Library.
- **Artwork.** `orca_library_track_artwork` and
  `orca_library_release_artwork` hand an `orca_image_view` of the cover's
  bytes, the media type sniffed from them and its `orca_artwork_kind`, or
  return `ORCA_STATUS_NOT_FOUND`. A file's embedded cover beats one fetched
  for its Release. Both read the file on the calling thread, so a UI asks
  with `orca_library_request_artwork` instead: the Library's artwork thread
  looks the cover up, calls the wake callback when it finishes, and the host
  drains `orca_library_take_artwork`, one `orca_artwork_result_view` per
  call, until `ORCA_STATUS_NOT_FOUND` after each wake. A subject with no
  cover arrives with `has_image` 0. At most 64 requests are outstanding per
  Library, counting finished ones not yet taken; past that a request is
  `ORCA_STATUS_BUSY`. `orca_library_cancel_artwork` skips a request that has
  not started; one already finished still arrives.
- **Lyrics.** `orca_library_start_lyrics` starts an `ORCA_JOB_KIND_LYRICS`
  Job for one Track: a synced sidecar, then synced lyrics in the file, then
  plain lyrics from each. `ORCA_LYRICS_FETCH` also asks LRCLIB for a Track
  without synced lyrics of its own and needs a client identity; without it
  the Job still uses answers kept in the Library. Once the Job finishes,
  `orca_job_lyrics_outcome` reports an `orca_lyrics_outcome` and
  `orca_job_lyrics` hands an `orca_lyrics_view` of the lines, each with its
  start in milliseconds or -1 when plain. The lyrics are taken once; a
  second call, or a Job that found none, is `ORCA_STATUS_NOT_FOUND`.
- **Artist info.** `orca_library_start_artist_info` starts an
  `ORCA_JOB_KIND_ARTIST_INFO` Job for one Artist from an
  `orca_artist_info_options` (biography language, `force`, `offline`); it
  needs a client identity. While it runs, `orca_job_artist_info_stores`
  counts the times it has stored part of what it found; a host shows the
  info again when the count grows. Once it finishes,
  `orca_job_artist_info_outcome` reports an `orca_artist_info_outcome`. `orca_library_artist_info` calls back
  with an `orca_artist_info_view` of what the Library keeps: years active,
  type, IDs, the biography with its URL, licence and language, and the
  photo's source, Commons page, licence and credit, which a host shows with
  the photo. `orca_library_artist_photo` hands the photo as an
  `orca_image_view`, and `orca_library_artist_links` the links as
  `orca_artist_link_view`s. For a related artist outside the Library,
  `orca_library_related_artist_photo` hands its kept photo by MusicBrainz
  artist ID and `orca_library_related_artist_photo_info` that photo's
  source, Commons page, licence and credit as an
  `orca_related_artist_photo_info_view`. `ORCA_PROVIDER_SERVICE_WIKIDATA`,
  `ORCA_PROVIDER_SERVICE_WIKIMEDIA_COMMONS` and
  `ORCA_PROVIDER_SERVICE_WIKIPEDIA` select other servers for it. See
  [providers.md](providers.md#artist-info).
- **Tag edits and writes.** `orca_library_edit_tracks` sets or clears Orca's
  own values for up to 64 `orca_metadata_field`s of up to 512 Tracks, locked
  as the user's, and returns the ids of the Tracks the edited files back
  afterwards; `orca_library_query_track_edits` reads them back with their
  `orca_provenance`. Neither writes a file. `orca_library_plan_tag_write`
  reads the files and shows an `orca_tag_write_plan_view` of each change,
  conflict and skipped file, with an approval digest; plan id 0 means nothing
  to write. A file's genres are not among its changes:
  `orca_library_query_tag_write_genres` hands the genres a held plan replaces
  in one file and the user's it writes, or `ORCA_STATUS_NOT_FOUND` when the
  plan leaves them alone, so a client asks it for every file it shows.
  `orca_library_start_tag_write` writes a held plan only with that
  digest, as an `ORCA_JOB_KIND_MUTATION` job that cannot be cancelled and
  keeps a journaled backup of every original;
  `orca_library_discard_tag_write` drops a plan. `orca_library_undo_tag_write`
  restores the originals, or returns `ORCA_STATUS_ALREADY_DONE`,
  `ORCA_STATUS_NEEDS_RECONCILIATION` or, once
  `orca_library_prune_tag_write_backups` has deleted the backups,
  `ORCA_STATUS_GONE`. A Library with no database file has nowhere to keep
  backups and refuses writes with `ORCA_STATUS_INVALID_STATE`. See
  [metadata.md](metadata.md).
  `orca_library_query_tag_write_groups` pages the change history newest
  first: each write's `orca_tag_write_group_state`, `can_undo` and
  `expired`, read from the journal alone. `orca_library_query_tag_write_group`
  reads one write's files and backups on the calling thread and hands an
  `orca_tag_write_group_detail_view` of what an undo restores beside each
  file's value now, at most 512 rows; see
  [metadata.md](metadata.md#change-history).
  `orca_library_export_tag_write_history` writes the history to a file
  atomically, in the form of `orca-cli changes`.
- **Jobs.** `orca_library_start_scan` registers a background worker and returns
  immediately; `orca_job_snapshot_get`, `orca_job_cancel` and
  `orca_library_scan_stats` observe it. `orca_library_scan_stats_v2` returns
  those stats as `base` with the job's `orca_scan_stage`, the Releases found
  so far and the file a scan or reconcile is reading. Scan progress is the
  files walked out of the files the walk will reach, which the Job counts
  first, reading directories only; `has_total = 0` until that count is done.
  A scan projects as it commits; `orca_library_start_projection` reprojects
  without a walk. `orca_library_start_reconcile` walks only the given directories of one
  root, or the whole root when given none, and reports as
  `ORCA_JOB_KIND_RECONCILE`. `orca_library_start_analysis` measures the files
  not measured yet, `orca_analysis_options.threads` at once; zero takes
  `orca_analysis_default_threads()`, one fewer than
  `orca_analysis_available_threads()`. See
  [analysis.md](analysis.md#threads).
- **Watching.** `orca_library_watch` watches a Library's roots, with an
  `orca_watch_options` or NULL for the defaults, and returns
  `ORCA_STATUS_UNSUPPORTED` off Linux; `orca_library_unwatch` stops it and
  `orca_library_watch_status` fills an `orca_watch_status`. The reconciles it
  starts run from `orca_runtime_pump` and report `ORCA_EVENT_JOB_FINISHED`
  like any job, with handles the host never started. One that recorded or
  marked missing a file also posts `ORCA_EVENT_LIBRARY_CHANGED`, whose
  `library_changed.library` names the Library: the host rereads whatever it
  shows from that Library, once however many arrive between two drains.
  See [storage.md](storage.md#watching-roots).
- **Events.** `orca_runtime_pump` drives the control lane and
  `orca_runtime_poll_event` drains the lossless completion channel and the
  coalescing telemetry channel into a tagged POD with a named `extern union`
  payload. Events are hints and correlations; authoritative consumers read
  snapshots. `orca_runtime_set_wake_callback` and `orca_runtime_pump_timeout`
  tell the host's loop when to pump; see [Wakeup](#wakeup).
- **Transport and queue.** Play by Track id, enqueue, next/previous, clear,
  repeat, shuffle, volume, `seek_ms`, paged queue listing, and
  `orca_player_status`, which carries transport, epoch, position, duration,
  track, queue position and volume in one lock-free read. Position comes from
  the packed epoch+frames atomic the render callback writes; now-playing reports
  the audible entry, never the decode cursor. `orca_player_status_get_v2`
  fills an `orca_player_status_v2`, which adds the last entry that could not
  be opened: `has_failure`, `failure_track_id` and an `orca_playback_failure`
  reason. A Track whose root is unavailable fails with
  `ORCA_FAILURE_TRACK_FOLDER_UNAVAILABLE` on the command lane.
- **Queue edits.** `orca_player_queue_jump` plays an entry now,
  `orca_player_queue_insert_next` queues Tracks after the current entry (or
  after the one the engine has already lined up), and
  `orca_player_queue_remove` removes an entry other than those two, which it
  refuses with `ORCA_STATUS_INVALID_STATE`. `orca_player_queue_move` moves
  an entry to another position in playback order; it refuses the same
  entries, and a position between the current entry and the one lined up,
  with `ORCA_STATUS_INVALID_STATE`. `orca_player_query_queue_tracks`
  lists the queue as track views in playback order, and
  `orca_player_queue_stats` reads the engine's counters, stopping it to do
  so, for diagnostics rather than UI polling.
- **Queue history.** `orca_player_query_queue_history` lists the last 100
  entries that stopped playing, newest first, as `orca_track_summary_view`s
  with `ended_at` in Unix milliseconds and an `orca_queue_history_reason`
  (`ORCA_QUEUE_HISTORY_REASON_FINISHED`, `_SKIPPED`, `_REPLACED`).
  `orca_player_clear_queue_history` empties it. It is held in memory only.
  `orca_player_save_queue_as_playlist` saves the current entry and those
  after it as a playlist in the Player's Library.
- **Saved playback.** `orca_player_restore_state` loads the queue last saved
  into the Player's Library at its saved entry and position, paused, playing
  or not at all by `orca_restore_mode`, and fills an `orca_restore_outcome`.
  After it, or after `orca_player_save_state`, the runtime saves the queue
  every 30 seconds from `orca_runtime_pump` while it plays and in
  `orca_runtime_destroy`. `orca_player_set_long_track_memory` sets the length
  past which a Track resumes where it was left. `orca_player_status_get_v3`
  adds `resumed_from_ms` to `orca_player_status_v2`. See
  [api.md](api.md#surface).
- **Equalizer, crossfeed and signal path.** `orca_player_set_equalizer`
  turns the ten-band equalizer on with an `orca_equalizer` of band gains and
  a preamp, or off with NULL; `orca_equalizer_preset_get` fills one from an
  `orca_equalizer_preset` without a runtime. `orca_player_set_crossfeed` sets
  stereo crossfeed, and `orca_player_equalizer` and `orca_player_crossfeed`
  read both back. `orca_player_signal_path` reports the audible entry's source
  format and codec, the output and device formats, the processing applied and
  each `orca_signal_reason` the path is not bit-perfect, with the device's
  period in `device_quantum_frames` (valid when `has_device_quantum`) and how
  it is attached in `output_kind`, an `orca_device_kind`.
  `orca_player_signal_path_v2` hands an `orca_signal_path_view_v2`: that
  view as `base`, with the parametric equalizer, the ReplayGain settings,
  peak limiting and `device_format`. `device_format`, an
  `orca_device_format`, is the format the device itself runs at: an
  `orca_device_sample_format`, bits per sample, rate and channels, or
  `ORCA_DEVICE_SAMPLE_FORMAT_UNKNOWN` with every field zero while the device
  is suspended, virtual or has not reported it, and off PipeWire.
- **Parametric equalizer.** `orca_player_set_parametric_equalizer` turns it
  on with an `orca_parametric_equalizer` of up to 16 `orca_parametric_filter`s
  and a preamp, turning the ten-band equalizer off, or off with NULL;
  `orca_player_parametric_equalizer_get` reads it back, and
  `orca_signal_path_view_v2` carries it as `parametric` with
  `has_parametric`. The `ORCA_PARAMETRIC_*` defines state the ranges. Three
  calls take no runtime and work from any thread:
  `orca_parametric_equalizer_response` fills the gain in dB at a caller's
  frequencies for a curve view, `orca_parametric_equalizer_parse_apo` reads
  EqualizerAPO text, and `orca_parametric_equalizer_write_apo` writes it
  (called with capacity 0 first to learn the length).
- **Devices and Zones.** Enumeration (`orca_enumerate_output_devices_v2`
  adds each device's `orca_device_kind`: USB, PCI, Bluetooth, HDMI, virtual
  or unknown; `orca_enumerate_output_devices_v3` adds its capabilities,
  `has_capabilities` being zero when they are unknown: lowest and highest
  rate, `ORCA_DEVICE_BIT_DEPTH_*` bits, most channels and an
  `orca_device_state`), Zone create/attach/open/close/status, and
  `orca_player_open_default_output`, which creates, attaches and opens in one
  call so a single-output frontend never has to know Zones exist.
- **Providers and credentials.** `orca_runtime_set_client_identity` names the
  host to MusicBrainz, AcoustID, ListenBrainz, LRCLIB, Wikidata, Wikimedia
  Commons and Wikipedia.
  `orca_runtime_set_provider_server` points one `orca_provider_service` at
  another server: `https`, or `http` to `127.0.0.1` or `localhost` only,
  copied, and `NULL` restores the public one.
  `orca_runtime_set_acoustid_client_key` sets the AcoustID application key.
  `orca_runtime_set_credential_callback` is how liborca reads tokens and keys
  from the host's secure store, and
  `orca_library_scrobbler_credentials_changed` has a Library's listen worker
  read and validate a changed ListenBrainz token; see
  [Credentials](#credentials).
- **Scrobbling.** `orca_library_set_scrobbling` sends a Library's listens and
  feedback to ListenBrainz, or stops: `offline` keeps them queued without a
  request and `now_playing` announces the playing track. At most one Library
  per runtime scrobbles; enabling a second is `ORCA_STATUS_INVALID_STATE`.
  `orca_library_scrobbler_status` hands an `orca_scrobbler_status_view` of the
  `orca_scrobbler_state`, user name, last error and queue counts, cheap enough
  to read each tick. See [Listening from a host](#listening-from-a-host).
- **Matching, verification and corrections.** `orca_library_start_match`
  starts an `ORCA_JOB_KIND_METADATA_LOOKUP` job from an `orca_match_options`
  (NULL searches the whole library with fingerprints): an
  `orca_match_mode` of search, re-identify one Track or Release, or verify
  recording IDs against AcoustID, optionally accepting matches above a
  confidence and fetching the Release's cover.
  `orca_library_start_cover_art_fetch` fetches one Release's cover as the same
  kind of job, and `orca_job_match_stats` reads either job's
  `orca_match_stats`. `orca_job_match_release` names the Release a finished
  release-scoped match left the album's files on, which is a new id when an
  accept moved them onto a Release that already existed or split them. A second match while one runs is `ORCA_STATUS_BUSY`.
  `orca_library_query_match_review` pages the Tracks with proposals, best
  first, and `orca_library_query_match_proposals` lists one Track's;
  `orca_library_accept_match` and `orca_library_dismiss_match` act on one,
  `orca_library_confident_match_count` and
  `orca_library_accept_confident_matches` on every file's best above a
  confidence in (0, 1], and `orca_library_apply_matched_release` applies a
  Release whose Tracks came to agree; `orca_library_apply_matched_release_fields`
  stores only the `orca_release_field` bits it is given, locked, from the
  best candidate's tracklist snapshot, and stores nothing without one; an
  Apply that leaves no Track alone and no value differing takes the Release
  off the bucket pages and counts.
  `orca_library_query_release_matches` pages Releases by
  `orca_release_match_bucket` with their best MusicBrainz release,
  `orca_library_release_match_counts` counts the buckets,
  `orca_library_release_match_evidence` and `orca_library_release_match_diff`
  compare a Release with a release, and `orca_library_dismiss_release_candidate`
  marks one as not the Release. `orca_library_query_release_matches_v2` pages
  the same with an `orca_release_match_view_v2`, which adds the placement
  counts (`placed`, `needs_pairing`, `has_placement`), so a Matches page is one
  call; `orca_library_release_match_counts_v2` adds `reviewed`.
  `ORCA_RELEASE_MATCH_BUCKET_REVIEWED` lists the Releases whose review still
  holds, which no other bucket lists, and
  `orca_library_unmark_release_reviewed` forgets a review so the Release
  returns to its own bucket (`ORCA_STATUS_ALREADY_DONE` without one).
  `orca_library_release_alignment` calls back once with an
  `orca_release_alignment_view`: the release's tracklist snapshot, a row per
  release track with its `orca_placement_status`, placed Track and evidence,
  and the Tracks placed nowhere. `orca_library_pair_release_track` pairs a
  Track with a release track and returns its `orca_pairing_origin`,
  `orca_library_unpair_release_track` removes the pairing, and
  `orca_library_query_release_track_pairings` lists a Release's pairings.
  `orca_library_apply_release` applies the `orca_release_field` bits and calls
  back with an `orca_release_apply_view` naming each Track left alone and the
  reviewed Release's id when the Apply marked it reviewed.
  `orca_library_mark_release_reviewed` records a review. Without a tracklist
  snapshot these return `ORCA_STATUS_INVALID_STATE`, as does a release track
  already paired or a Release not wholly placed; a Release past 512 Tracks is
  `ORCA_STATUS_UNSUPPORTED`; an unknown Release, candidate, release track or a
  Track not on the Release is `ORCA_STATUS_NOT_FOUND`; unpairing a Track with
  no pairing is `ORCA_STATUS_ALREADY_DONE`; and marking a Release whose values
  differ from the release is `ORCA_STATUS_NEEDS_RECONCILIATION`. Pairing and
  Apply reproject, so Track and Release ids may change; query again after
  either. `orca_library_track_verification` hands
  a Track's last verification with the recordings AcoustID heard, and
  `orca_library_query_correction_groups` pages album groups of corrections
  with their members, accepted or dismissed only whole. Acceptance writes the
  library, never a file.
- **AcoustID submission.** `orca_library_start_acoustid_submission` starts an
  `ORCA_JOB_KIND_ACOUSTID_SUBMISSION` job that sends the fingerprints of files
  whose recording ID a person chose, and `orca_job_submission_stats` reads its
  `orca_submission_stats`; why it stopped is an `orca_submission_outcome`,
  and a missing user key is `ORCA_SUBMISSION_OUTCOME_NEEDS_USER_KEY`, read
  through the credential callback as `ORCA_CREDENTIAL_ACCOUNT_USER_KEY`.
  `orca_library_acoustid_submittable_count` and
  `orca_library_query_acoustid_submittable` (keyset paging after the last
  `file_id` seen) list what it would send. It cannot run beside a matching
  job.
- **Idle maintenance.** `orca_library_set_maintenance` turns a Library's
  idle maintenance on or off with an `orca_maintenance_options`, NULL turning
  it off, and `orca_library_maintenance_status` fills an
  `orca_maintenance_status`: the `orca_maintenance_state`, the
  `orca_maintenance_block` that keeps units from running, the time to the
  next unit, the units run and the last unit's `orca_job_state`, Release and
  `orca_match_stats`. Units start from `orca_runtime_pump` as
  `ORCA_JOB_KIND_METADATA_LOOKUP` jobs the host never started.
  `orca_job_origin_get` tells a host's job from a watcher's reconcile and a
  maintenance unit by its `orca_job_origin`, and `orca_job_reconcile_root`
  names the root a reconcile job walks. See
  [control-plane.md](control-plane.md#idle-maintenance).

`scripts/check-abi-coverage.sh`, which `zig build test` runs, fails when a
public `Runtime` method has no C ABI path and no stated reason for having
none. Its list of reasons is the record of what the C ABI leaves out.

`orca_player_play` is refused unless the Player has a loaded source or a
non-empty queue *and* an attached Zone: a transport that reports PLAYING while
nothing renders is a defect, not a state.

### Errors

Every function returns an `orca_status`. After a call that did not return
`ORCA_STATUS_OK`, `orca_runtime_last_error(runtime)` describes it as
`"<function>: <reason>"`, for example `"orca_library_open: path is null"` or
`"orca_player_play: PlayerHasNoSource"`. The message is for logs and bug
reports, not for parsing. It is empty after a call that succeeded, holds at
most 255 bytes, and is valid until the next `orca_*` call on that runtime. A
call refused with `ORCA_STATUS_WRONG_THREAD` leaves it unchanged.
`orca_runtime_create` returning `NULL` means out of memory.

### Wakeup

A host sleeps in its own event loop and pumps when liborca wakes it, instead of
on a timer. liborca calls the wake callback when the loop should pump, and
`orca_runtime_pump_timeout` gives the longest the loop may sleep without it:
0 to pump now, `ORCA_PUMP_NO_TIMEOUT` (-1) to wait for the callback alone, and
otherwise at most one second while a Player bound to a Library plays and
100 ms while a job runs. With an eventfd on Linux:

```c
static void wake(void *context) {
    uint64_t one = 1;
    write(*(int *)context, &one, sizeof one);
}

int wake_fd = eventfd(0, EFD_NONBLOCK);
orca_runtime *runtime = orca_runtime_create();
orca_runtime_set_wake_callback(runtime, wake, &wake_fd);

for (;;) {
    orca_runtime_pump(runtime);
    /* Drain orca_runtime_poll_event and refresh the snapshots on screen. */
    int64_t timeout_ms;
    orca_runtime_pump_timeout(runtime, &timeout_ms);
    struct pollfd ready = {.fd = wake_fd, .events = POLLIN};
    if (poll(&ready, 1, (int)timeout_ms) > 0) {
        uint64_t count;
        read(wake_fd, &count, sizeof count);
    }
}
```

`poll` takes -1 as "no timeout", so `ORCA_PUMP_NO_TIMEOUT` passes straight
through. On macOS the callback signals a `CFRunLoopSource` and calls
`CFRunLoopWakeUp`.

The callback is the one exception to the threading contract:

- It is called from liborca's engine, job, listen and artwork threads, and
  from inside `orca_*` calls on the owning thread, sometimes from two threads
  at once. It must only signal the host's loop and return: no `orca_*` call,
  nothing that blocks.
- It is called at most once between two pumps. The pump clears the pending
  wake, so a host reads `orca_runtime_pump_timeout` after pumping and draining
  events, immediately before it sleeps; a wake that arrived during the pump
  then reads as 0 rather than being lost, even when the host's wake primitive
  does not count.
- It is never called from an audio render callback, and never after
  `orca_runtime_destroy` returns, which joins every thread that calls it. The
  `context` must stay valid until then.
- `orca_runtime_set_wake_callback` returns `ORCA_STATUS_INVALID_STATE` once any
  worker thread exists — a Player's engine, a job, a listen worker or an
  artwork loader — because those threads read the callback without a lock.
  Install it right after `orca_runtime_create`. A `NULL` callback removes it
  under the same rule.

[control-plane.md](control-plane.md#waking-the-host) lists what wakes the host
and what the timeout covers.

### Credentials

liborca keeps no token or key in a Library, a log or a cache key. It asks the
host's secure store, through the credential callback, each time it needs one:
the ListenBrainz user token (`ORCA_CREDENTIAL_SERVICE_LISTENBRAINZ`,
`ORCA_CREDENTIAL_ACCOUNT_USER_TOKEN`) and the AcoustID user and application keys
(`ORCA_CREDENTIAL_SERVICE_ACOUSTID`, `ORCA_CREDENTIAL_ACCOUNT_USER_KEY` or
`ORCA_CREDENTIAL_ACCOUNT_CLIENT_KEY`).

The callback writes the secret into liborca's buffer of
`ORCA_CREDENTIAL_MAX_BYTES` and returns an `orca_credential_result`:

- `FOUND`, with the length written. A length above the capacity is treated as
  `TOO_LARGE`; liborca never truncates a secret.
- `NOT_FOUND` when the store holds none. That is absence: scrobbling waits for
  a token.
- `UNAVAILABLE` when the store cannot answer, such as a locked keyring, and
  `TOO_LARGE` when the secret does not fit. The listen worker treats both as
  errors, not absence: it reports the error and asks again later. AcoustID
  jobs treat both as absence: a lookup uses the application key, and a
  submission reports that it needs a user key.

liborca zeroes the buffer before freeing it, whatever the callback returned.

The callback is the second exception to the threading contract:

- It is called from liborca's listen and job threads, sometimes from two at
  once, so it must be thread-safe. It must not call any `orca_*` function. It
  may block on the store, which delays whatever waits for that thread,
  `orca_runtime_destroy` included.
- It is never called after `orca_runtime_destroy` returns, and `context` must
  stay valid until then.
- `orca_runtime_set_credential_callback` returns `ORCA_STATUS_INVALID_STATE`
  once any worker thread exists, as `orca_runtime_set_wake_callback` does, so a
  host installs both right after `orca_runtime_create`. To have liborca read a
  token the host has changed, it calls
  `orca_library_scrobbler_credentials_changed` instead.

### Versions

`orca_version()` returns liborca's version, such as `"0.2.0"`.
`ORCA_ABI_VERSION` in `orca.h` is the C ABI's version, which is separate from
it and follows the rules in [api.md](api.md#stability). The shared library's
SONAME carries the ABI version:

```text
lib/liborca.so.0.0.0
lib/liborca.so.0 -> liborca.so.0.0.0
lib/liborca.so   -> liborca.so.0
```

`liborca.so` exports exactly the functions `orca.h` declares; a version script
hides everything else, and `zig build test` fails when the two differ
(`scripts/check-exports.sh`).

`tests/abi/orca-0.8.1.h` is the header of the 0.8.1 release. `zig build test`
(and `zig build abi-compat` alone) fails when `orca.h` changes the size,
alignment or a non-reserved field offset of any struct in it, the value of
any of its enum constants or defines, or the parameters of any of its
functions, or when liborca stops providing one of them
(`tests/abi/compat.zig`). A client compiled against that header scans
`fixtures/audio` and checks that `orca_library_scan_stats` writes nothing past
its 88-byte struct (`tests/abi/scan_stats_0_8_1.c`). A struct that needs
more fields gets a `_v2` that holds the old one as `base`, read through a new
`_v2` function.

### Linking

`zig build` installs `lib/pkgconfig/orca.pc` beside the libraries, with the
header at `include/orca/orca.h`:

```c
#include <orca/orca.h>
```

Against the shared library:

```sh
cc host.c $(pkg-config --cflags --libs orca)
```

Against the static library, which needs its dependencies and the C++ runtime
the ALAC and Chromaprint code uses:

```sh
cc host.c $(pkg-config --static --cflags --libs orca)
```

The static link line expands to `-lorca` plus SQLite, libFLAC, libopusfile,
libvorbisfile, libsamplerate, PipeWire on Linux, `-lc++` and `-lm`. Set
`PKG_CONFIG_PATH` to the install's `lib/pkgconfig` when it is not a system
prefix.

## Linux GTK4

`orca-gtk` is a Zig client of liborca's public Zig API, built on GTK 4 and
libadwaita, both bound by hand in `apps/linux/gtk.zig` and `apps/linux/adw.zig`.
Every liborca call happens on the GTK main thread, from a signal handler or the
tick.

The tick pumps the runtime, drains events and telemetry, and refreshes the
window from snapshots. It runs when liborca's waker writes the app's eventfd,
watched with `g_unix_fd_add`, and when the `nextPumpTimeoutMs` timeout re-armed
after each tick expires. A handler whose own runtime call changes what the tick
shows, such as play, pause, a seek or a queue edit, writes the same eventfd
(`App.requestTick`), since liborca does not wake the host for the host's own
calls. An idle window makes no wakeups; a playing one ticks on each position
hint, about ten times a second, and a running job every 100 ms.

```sh
zig build run-linux                                   # the active library in settings.ini
ORCA_LIBRARY=/path/to/library.db zig build run-linux  # another library, for this run only
```

`orca-gtk` lists the libraries it can open in the `[libraries]` group of
`settings.ini`: `paths` and `names` are parallel string lists, `tracks` the
last known track count of each (`-` when not yet known), and `active` the
index of the one to open at launch. liborca knows only the database that is
open; a library's name lives in this list. With no list yet, the first
launch lists `$XDG_DATA_HOME/orca/library.db` as Main, creating its folder.
When the active library's file is gone, the launch opens the first listed
library that still exists and Settings says which it could not open.
`ORCA_LIBRARY` overrides the list for one run: its library is active and
shown in the list as from `ORCA_LIBRARY`, but it is never saved and the
saved `active` is left as it was, unless the user switches to a listed
library during the run.

Switching to another library (`apps/linux/libraries.zig`) runs on idle,
since the control that asked is rebuilt by it:

1. Open the other database with `openLibrary`. When the file is missing or
   the open fails, the current library stays open and playing, Settings
   shows the reason under the active library, and the drop-down keeps the
   current one.
2. Pop every pushed page and forget the navigation history, then stop the
   frontend's own threads: each page with a worker thread cancels it where
   it can and joins it, and its late results are dropped by a generation
   check. Pending timers and the palette's, album page's and artist page's
   requests are dropped with them.
3. Pause the Player and `playerSaveState` it into the old library, destroy
   the Zone, then `destroyLibrary`, which ends listens, cancels and joins the
   library's Jobs, drains the browse and artwork loaders, stops the watcher
   and the listen workers, and closes the database.
4. Stop the Player and clear its queue and queue history. This waits for
   step 3: while the old library is bound, `leaveLibrary` would save the
   cleared queue over the one just kept for it.
5. `playerBindLibrary` the new library; apply long-track memory, folder
   watching, maintenance and scrobbling to it; then `playerRestoreState`
   paused, or not at all when On launch is Start empty. A switch never
   resumes playing.
6. Reset filters, search, selections and the review pages, reload the
   sidebar and the browse pages, rebuild Settings, save `settings.ini`, and
   show `Switched to NAME`.

The window is an `AdwNavigationSplitView`:

- The sidebar is 216 px of buttons, one per page, under the Orca wordmark,
  in groups: Library (Albums, Artists, Tracks, Genres, Folders, Loved),
  Collection (Playlists), Playback (Now Playing, and Queue with its
  length), Library Tools (Health, and Matches with its count) and
  Settings. With Show counts in sidebar on, Albums, Artists and Tracks show
  the library's totals from `Runtime.libraryStats`. While a Job runs or
  waits, an activity widget at the foot reads `1 task running · 65%`,
  `Scanning library · 62%` when the only Job is a scan,
  `1 task running · 2 waiting` or, with the Library's Jobs paused,
  `Paused · 2 waiting`, over a 3 px bar that pulses when the running Job
  has no total, such as a scan still counting its files; it is hidden when
  nothing runs or waits.
  Pressing it opens the activity popover (see **Activity** below).
- **Albums** is a grid of covers with each album's title, artist and year.
  The grid and the list are a paged model as long as the count: the
  browse loader reads `release_count`, then a 512-Release `release_page`
  as GTK asks for a position, keeping eight pages and cancelling the read
  of a page it drops. Until its page arrives a position is an empty tile or
  row that does not respond to input, and until a new count arrives the
  previous count stays. Its title row shows `N albums`, a Sort by
  menu (Date Added, Title, Artist, Year, Loved or Most Played, saved as
  `[view] album_sort`), a Filters button and a Grid / List switch (saved as
  `[view] albums_layout`).
  A Search albums field under the title sets `ReleaseQuery.text`, so the
  search combines with the chip and the filters, and the count is the
  browse loader's `release_count` of the whole query. Chips under it choose All Albums, Recently Added (the newest Releases
  first), Loved, High Resolution (above 48 kHz or 16 bits) or Needs Review
  (a pending match or correction); they are radio buttons and one Tab stop,
  Left and Right moving between them. Beside them a Cover size slider sets
  the smallest cover, 88 to 184 px (132 px by default), saved as
  `[view] album_cover_size`; it and Settings › Appearance › Album grid size
  are one value and move together. The Filters popover sets a genre (every
  genre, listed 512 at a time), a year range, Any or Lossless only, and
  whether the album has artwork, applied with Apply and reset with Clear;
  the button reads `Filters • N` while N are set. Every chip and filter is a
  field of `ReleaseQuery`, so liborca filters and counts. The grid fits as
  many columns as covers of the chosen size allow, 22 px apart, and grows
  the covers so the columns fill the row, never fewer than two or more
  than sixteen. An
  album without a cover shows its initials, and an explicit album an E
  badge at the cover's bottom-left, and the playing track's album three
  accent bars before its title, named Now playing for screen readers.
  Hovering or focusing a tile dims the cover under a play button, which
  plays the album, and shows a more button after the artist, which opens
  the album menu; a hovered, focused or selected tile's cover is ringed. The list shows 44 px rows of a small cover, title, artist, year,
  track count, minutes, format (`FLAC 16/44.1`, or `Mixed`), a heart that
  loves the album and a more button.
  From 2,000 albums in the library the page takes its large form. The title
  row's count reads `41,206 · 3,940 artists · 9.8 TB` from
  `libraryReleaseQueryTotals`, and facet chips replace the shelf chips:
  Lossless; Added (Any time, Last 7 days, Last 30 days, Last 12 months),
  which sets `ReleaseQuery.added_after` from a cutoff fixed when the window
  is chosen; Genre; Decade (the 2020s back to the 1950s, and Before 1950),
  which sets the year range; and More filters, the Filters popover. A set
  facet is highlighted and shows its value, Lossless with an × that clears
  it, and `N match` follows the chips while any filter or search narrows
  the list. Recently Added is the Added chip's
  30-day window sorted by Date Added. Sorted by Artist or Title in the grid
  layout, the albums are a `GtkListView` of letter sections over
  `libraryReleaseLetterIndex`: a `K · 1,184 albums` header in Newsreader,
  then rows of 104 px tiles read 512 Releases a page as rows come into
  view, a few pages kept. An A–Z scrubber on the right, named Jump to letter,
  scrolls a letter's header to the top on a click or drag, shows the letter
  in a bubble while dragging and marks the letter at the top. Other sorts
  and the list layout keep the grid and list above.
  Activating an album opens its page: a 248 px cover beside an overline naming
  the release type, else COMPILATION for a compilation and ALBUM otherwise,
  the title in 58 px Newsreader, the artist as a link and a line of year, its top one or two genres joined by ` / `,
  track count and minutes separated by dim `·`, then the album's description from
  `Runtime.libraryReleaseInfo`, at most 520 px wide and three lines, with a
  More link, shown when the text wraps past three lines at the width it is
  given, that shows the rest, and under it its source and licence. With no
  description stored the page starts `Runtime.startReleaseInfoFetch` once per album per session and
  shows the description when the job ends. Then come Play, Shuffle, a heart
  in the love colour that loves the album (Love Album, Remove Album Love)
  and a more button with the album menu, both faint round buttons; the page opens with focus on Play.
  Behind the top 600 px of the page the cover's artwork backdrop scrolls
  with it, dimmer and more heavily shaded than on other pages; an album without a cover has no backdrop. Its tracks follow by disc under
  a # / Title / clock header, one 38 px row each with a rule above it: the playing track's
  row is tinted and shows a play mark in place of its number and an accent title, and the more
  button with the track menu shows on the hovered, selected and playing row.
  A track's heart shows only when it is loved or its row is hovered.
  A button in the header chooses extra columns, Rating, Format and Sample
  rate, saved as `[view] album_columns`. A narrow window shrinks the grid and
  stacks the album page's cover above its title.
- **Artists** lists every Artist, or with Album artists chosen in the menu
  beside Sort by only those a Release is filed under (`ArtistQuery.role`,
  saved as `[view] artists_role`, Album artists by default); the line under
  the title counts them, `8 artists · album artists only`. They show as a
  grid of round photos at least 132 px wide or as flush rows, chosen by a
  grid and list switch saved as `[view] artists_layout`. Each shows the
  Artist's photo when artist info stored one, otherwise their first album's
  cover, otherwise their initials in Newsreader on a ringed dark disc, then
  their name and `N albums` in the grid, `N albums • N tracks` in the list;
  a grid photo takes a ring on hover. Scrolled to the end, the page shows
  `No artist photo? Orca uses artwork from one of their albums, then a
  monochrome monogram.` A Sort by menu orders them by Name, Most tracks,
  Recently loved or Recently added, the Artist whose newest release, filed
  under them or appeared on, came latest first (`ArtistSort`, saved as
  `[view] artist_sort`); a Search
  artists field under the title filters by name through the query, and an
  empty library or search shows a status page. The grid keeps at least two
  columns and shrinks its tiles to fit a 560 px window. An artist opens a
  page, `artist_page.zig`, laid over a blurred backdrop of the hero photo
  and clamped to 1060 px. The hero shows a round 232 px photo: the
  Artist's stored photo, otherwise their most played album's cover,
  otherwise their initials. Beside it sit an Artist overline, their name in
  Newsreader, their top three genres (`libraryArtistGenres`), and the
  stored biography (`libraryArtistInfo`). A biography longer than three
  lines is cut at a word so that `… Read more` ends the third line, measured
  with Pango at the label's width and measured again when the width
  changes; the inline Read more link expands it in place to the full text
  and a `From Wikipedia · licence` credit, and a Show less link at its end
  folds it again. While an artist-info fetch for the Artist is running, a
  muted spinner and `Looking up artist info…` sit beside the genres in a
  fixed-height line, so they never move the Play row. Then come Play, a dark
  Shuffle, a heart that loves the Artist (`librarySetArtistLove`) and a more button. Below, Top
  Tracks, `By your plays`, lists up to five of their tracks with plays,
  most played first (`libraryTrackQuery` sorted by `play_count`
  descending), each with its cover, an E badge when explicit, its album and
  play count, duration and a more button; while none has been played it
  lists five by rating under `By rating`. Beside it, Albums, `In your
  library`, shows up to nine releases filed under the Artist
  (`ReleaseQuery.album_artist_id` with `own_releases_only`) in three
  columns, then Appears On up to six releases filed under another artist
  with a track credited to them (`ReleaseQuery.appearing_artist_id`); a
  section with more shows `See all N`, which opens Albums scoped to the
  Artist under a `Name • Albums` (or `Appearances`) chip beside the Albums
  search until its × is clicked. Elsewhere, `From MusicBrainz · not in your
  library`, shows the albums and EPs `libraryArtistElsewhere` lists, newest first, as
  dimmed tiles marked `No local files`, captioned with the other artists
  credited and the year, such as `with Kaytranada · 2023`, each opening its
  MusicBrainz page in the browser. One row of the first 6 is shown; with
  more, the heading carries `See all N`, which shows every one in place and
  becomes `Show fewer`, and a refresh of the page keeps the choice. Every
  tile, here and in Albums, Appears On and Related Artists, is as wide as
  its cover: a long title or caption ends in an ellipsis and never widens
  it, and the cover sits flush above its title. A tile shows the release group's kept
  Cover Art Archive cover (`ArtworkSubject.release_group`, requested only
  when `ElsewhereRelease.cover` is `kept`) under a `No local files` pill,
  otherwise a dashed frame with the label at its centre. Related
  Artists shows up to seven round tiles from `libraryRelatedArtists`, each
  with its kept photo or initials; one in the library opens their page, one
  outside it their MusicBrainz page. Opening an Artist without stored info
  starts an artist info Job (`startArtistInfoFetch`) once a session while
  Preferences' Fetch artist info switch, saved as
  `[library] fetch_artist_info`, is on; when it finishes the page refreshes
  in place. Activating a track plays the artist's tracks in album order from
  it. Top Tracks is 380 px wide, narrower only when the three album
  columns beside it would not fit, and the albums take the rest; the
  playing track's row is tinted blue with its title in the accent colour.
  A narrow window, or one too narrow for the full header, stacks the
  photo above the name and Top Tracks above the albums.
- **Tracks** is the track list. Its header carries its own search,
  `Search tracks, artists, albums…` with a Ctrl F hint, in place of the
  library search, and a Filters menu: Genre, a Year range, Format (Any,
  Lossless, Lossy), a minimum sample rate, Loved only and Explicit only,
  with Clear Filters. Every filter is part of the liborca query, with or
  without search text, and the Genre list holds every genre, read 512 at a
  time each time the menu opens. The Filters button turns accent while any
  filter is set, and filters are not saved. The title row shows the exact
  count from liborca with digit grouping (`2,847 tracks`), or while
  searching `N matching`, the loaded rows with a `+` while more remain, then
  a Sort by menu (Default, Title, Artist, Album, Track Number, Date Added,
  Last Played, Play Count, Rating, Loved, Year, Duration; dates, counts,
  ratings and years newest or highest first), kept in step with the column
  headers and not saved, Filters, and a Columns menu. The whole library
  opens sorted by Date Added, newest first. The list pages 512 rows at a time from
  liborca as it scrolls, each page and the listing's totals read on the
  Library's browse loader (`libraryRequestBrowse`) so no query runs on
  the main thread: a row whose page has not arrived shows blank and cannot
  be played, rated or opened, the 8 most recently shown pages stay cached,
  a page scrolled out of the cache before it arrives is cancelled, and a
  request the full loader refuses is asked again 25 ms later. A new search,
  filter or scope keeps the previous count and empty state until its totals
  arrive. A header click re-queries in the engine's order
  rather than sorting loaded rows; the sorted column's title is
  highlighted with an arrow for its direction. Under an uppercase header
  each track is one thin-ruled row: the playing track's row is tinted, with
  an accent play mark in place of its number and an accent title, an
  explicit track shows an E badge after its title, its heart sits in its
  own column and toggles love, and five stars set its rating with
  `librarySetRating`, dim until rated. Hovering a row, or the playing row,
  shows a ••• button whose menu has Play Next, Play Later, Go to Album, Go
  to Artist, Edit Metadata… and Show in Folder; right-click keeps the full
  track menu. Show in Folder opens the folder holding the track's file;
  under `ORCA_GTK_DEBUG=reveal` it prints `orca-gtk reveal: PATH` on stderr
  instead. Double-click or Enter plays the list from that row, at most the
  queue's 10,000 entries starting there. The Columns menu, and every
  column title's menu, choose the columns: Artist,
  Album, Loved, Rating, Date Added, Year, Last Played, Plays, Duration,
  Format, Codec, Bit Depth and Sample Rate; # and Title always show. The
  default is Artist, Album, Loved, Rating, Date Added, Duration (titled
  Time) and Format. Below the columns, the Columns menu's Browse by
  Artist and Album toggle shows the Artist and Album panes beside the list;
  it is not saved, and while the window is narrow the panes hide and the
  toggle is disabled. The
  column choice and order are saved as `[view] track_columns` (a comma list
  of those names in snake case in their order, a hidden column's name
  prefixed with `-`) and dragged widths as `[view] track_column_widths`
  (`name:pixels` pairs); the older `song_columns` and `song_column_widths`
  keys are read when these are absent. Each row of the Columns menu has a
  grip that drags the column elsewhere, and Reset to default, beside Saved
  per view, puts the view's columns, order and widths back. A narrow window drops
  every chosen column except Artist, Loved and Duration without forgetting
  the choice and narrows Title and Artist, which ellipsize, so that Title,
  Artist, the heart and Duration fit a 560 px window without saving those
  widths; the table scrolls sideways inside its own area when the rest does
  not fit. Below the 900sp breakpoint the Tracks, Loved and playlist tables
  narrow this way and the search shrinks. The tables sit inside the page's
  side margins. The Tracks,
  Artists and Albums searches query 200 ms after the last keystroke. A
  library with no tracks shows a welcome page with Add Music Folder; a scan
  in progress shows there too.
  From 20,000 tracks in the library the page takes its large form. A bar
  under the title row shows each set filter as a token, `Codec FLAC`,
  `Sample rate > 48 kHz` or `Added last 12 months`, whose × clears it, then
  `+ Filter`, which opens the Filters popover (which also offers Codec,
  Sample rate above and Added); tokens and popover share one set of
  filters. On the right, with no filter it reads `522,432 tracks`, and with
  filters the count and duration from `libraryTrackQueryTotals`, `18,772
  tracks · 61 h 14 min`, then Save as Smart Playlist while there is no
  search text or Artist or Album scope. Save writes version 1 rules from
  the tokens (`genre`, `year`, `lossless`, `codec`, `sample_rate`,
  `added_at`, `loved`, `explicit`), names the playlist after them and opens
  it, so the playlist holds what the count counted. Row numbers are the
  row's position in the whole listing. The large form has its own columns,
  saved as `[view] track_columns_large` and `track_column_widths_large`:
  Title, Artist, Album, Codec, Rate / depth and Time by default, with
  Album artist, Year, Genre, Bitrate, Plays, Rating, Loudness (LUFS), Date
  added and File path on offer. A sort click lists the same tracks in the
  new order without recounting them, and play from a row hands the queue
  at most 10,000 ids from `libraryTrackQueryPlayableIds`.
- **Artwork backdrops** sit behind the album, artist and playlist page
  headers and Now Playing, never behind the sidebar, the player bar, tables
  or Settings. The cover, or for a playlist a two by two blend of its first
  four covers, is scaled to 128 px on its long edge, blurred by three box
  passes of radius 8 and saturated by 1.25 on a worker thread, then cached
  in the artwork cache, so a page opened again reuses it. A picture fills
  the area at 60% opacity under a gradient to the page colour; Artwork
  influence Off hides it. `ORCA_GTK_DEBUG=art` prints each blur and reuse,
  and `ORCA_GTK_DEBUG=frames` each frame's paint time, on stderr; topics
  combine with commas.
- **Genres** is one scrolling page in two columns. On the left, under a
  large Genres title, a 230 px list of genres with their track counts, most
  tracks first, read from `libraryGenrePage` 512 at a time as the page
  scrolls; the selected genre is highlighted, and Up and Down move the
  selection. The header search filters the list by name. The selected genre
  is saved as `[view] genre`; the genre with the most tracks is shown when
  none is saved. On the right, a GENRE overline, the genre's name, a line of
  its track, album and artist counts and total time from `GenreSummary`,
  then Play, Shuffle and a more button whose Create Smart Playlist saves a
  smart playlist of the rule `genre is Name`. Play and Shuffle queue the
  genre's playable tracks in Representative Tracks order, at most
  `max_playlist_entries`. Albums follows: the genre's six most played albums
  as tiles with a play button, each opening its album page in place, and See
  all N, shown when the genre has more albums, opening Albums through its
  genre filter. Below it, side by side, Artists, the five of its artists
  with the most tracks in the whole library, each with a round photo or
  initials and its track count, opening the artist's page; and
  Representative Tracks, its five most played tracks, or by rating while
  none has been played, a track playing the genre in that order from it. The
  two columns stack below 890 px and Artists and Representative Tracks stack
  below 950 px. A library with no genres shows a status page whose Fill
  missing genres from MusicBrainz opens Settings › Library; a search that
  matches none shows No matching genres.
- **Folders** browses the library as it lies on disk. A 260 px tree on the
  left lists the roots, each expanding lazily into its folders
  (`libraryFolderPage`, folders only), with the open folder selected;
  selecting a folder opens it. A window narrower than 900 px hides the
  tree. The header holds a mono breadcrumb of the root's path and the
  folders below it, every segment but the last opening that level, a
  Files / Library view switch whose Library view opens the folder's
  Release (insensitive when the folder has none), and Show in File Manager,
  which opens the folder's `file://` URI with the default handler. A card
  below shows the Release's cover and `Imported as TITLE by ARTIST`, the
  title a link to the album, or the folder's name when it has no Release;
  then `N tracks · N cover images · last scanned today, 10:24`, counting
  tracks in subfolders too (`N+ tracks` while rows remain unloaded), and
  Rescan Folder, which starts a reconcile of this folder and its subfolders
  (`startLibraryReconcile` with one subtree) that shows in the sidebar's
  task widget. The table has Name, Kind, Length and Status columns over 32
  px rows, 512 loaded at a time as it scrolls: folders first, with their
  total duration and track count, activated to open them; then audio files
  with their format (`FLAC · 16-bit · 44.1 kHz`), duration and `In
  library`, `Unreadable` or `Not imported`; then images with `JPEG image`
  and their role (Front cover, Back cover, Booklet, Image). Activating a
  file plays this folder's tracks, without subfolders, in file order from
  it. A right click on a file offers Show in Files, and on a track Play,
  Add to Queue and Edit Metadata…. The header search (`Search this
  folder…`, Ctrl+F) filters the loaded rows by name, loading up to 16 pages
  first, and keeps its text across folders; a folder without entries shows
  `No audio files here.`, a search that matches none `Nothing in this
  folder matches`, and a library without roots the welcome page. Below 700
  px of content width the Kind column is hidden. Each list is one Tab stop,
  and Backspace or Alt+Up opens the parent folder.
- **Loved** opens with the Loved title, "Everything you've marked with a
  heart. Ratings are separate and live alongside.", Play, Shuffle and a more
  button, with the counts of loved Tracks, Albums and Artists on the right;
  the counts go when the page narrows. Play queues every playable loved
  track, most recently loved first, Shuffle does the same with shuffle on,
  and the more button opens the track menu for those tracks. Three tabs with
  icons follow: Tracks, the Tracks list's table of loved tracks, most
  recently loved first and paged 512 at a time, with the inspector for the
  selected track. Its columns are the row's position (#), a small cover,
  Title with the track's heart beside it, Artist, Album, Rating, Last Played,
  the duration under a clock and a ••• button with the track menu, shown on
  hover; the covers go when the table is narrow, and Album, Rating and Last
  Played as on Tracks. Last Played reads Today, Yesterday or `3 days ago` up
  to six days, then the date, with the full date and time in its tooltip;
  Albums, the Albums grid of loved albums; and Artists, a grid of round
  artist tiles, most recently loved first, each with
  the Artist's stored photo or its initials, its name and its album and track
  counts. The page never fetches a photo; `orca-cli artist-info --fetch`
  stores one. An album or Artist opens its page in place, a right click on an
  Artist opens the artist menu, and a track plays on activation. The page is
  read again each time it is shown, so a heart cleared on it leaves its row
  in place until then. The top-bar search reads `Search loved…` and filters
  the three tabs in place, while the counts keep showing every loved item;
  a tab with no match says `No matching loved tracks`, `albums` or
  `artists`.
- **Playlists** opens with its title block, "Your playlists and smart
  collections.", New Smart Playlist and New Playlist; the New Playlist
  dialog also offers Import… for an M3U file. Tabs (All, Created by Me,
  Smart; one Tab stop, Left and Right move between them) choose which
  playlists both sections show. Pinned shows every pinned playlist as a
  square tile with its name and track count and length. All Playlists has
  a sort menu (Recently updated, Name, Recently created, Most tracks) and a
  Grid or List switch; the tab, sort and layout are kept in the settings
  file. Both grids fit as many columns as the width allows, Pinned at
  196 pixels or more and All Playlists at 150, and stretch the tiles to
  fill the row. liborca filters, sorts and counts every section
  (`libraryPlaylistPage`, `libraryPlaylistCount`); the search matches
  names case-insensitively. A tile's art is the 2×2 mosaic of the first
  four distinct album covers among the playlist's tracks, one cover when
  there are fewer, or for a smart playlist a glyph that follows the field
  its first rule tests (a heart for loved, a signal for sample rate, bit
  depth, lossless or codec, a star otherwise). Below it an All Playlists
  tile shows the name, Smart playlist, By you or Imported, and for a smart
  playlist a summary of its rules, such as "Loved, never played" or
  "Sample rate above 48 kHz", or else when it was last updated ("Updated
  last week"). The summary reads `librarySmartPlaylistRules`, joins the
  first two rules with ", " (all) or " or " (any), adds "+ N more" for the
  rest, and falls back to "N rules" for a rule it has no words for. The
  list shows the same three lines in rows beside the track count, length,
  a pin and a more button. Hovering or focusing a tile outlines its art and
  shows a play button; right click, and a row's more button, open Play,
  Shuffle, Pin or Unpin, Love or Remove Love, Edit Rules… (smart) or Edit
  Details…, Rename…, Export… and Delete…. Edit Details… sets the
  description and up to eight comma-separated tags through
  `libraryUpdatePlaylist`. With no playlists the page offers Import…, New
  Smart Playlist and New Playlist.

  A playlist's page shows its mosaic or smart tile beside a Playlist or
  Smart Playlist overline, the name in 58 px serif, a line of who made it
  (By you, Imported or Smart playlist), the track count, length, how many
  tracks are unavailable and when it was last updated, joined by dots, and
  the description, then Play, Shuffle and round buttons: Reorder on a
  manual playlist, Edit Rules or Edit Details, and the playlist menu, which
  starts with Shuffle Again on a smart playlist ordered at random
  (`libraryReshufflePlaylists`). Below 900sp the heading stacks the art
  above the name. The tracks follow in a borderless table of #, Title with
  the artist beneath it, Album and Time, numbered by their position in the
  playlist; below 900sp it drops the album. Reorder shows a grip at the
  start of each row; dragging a row by its grip onto another moves it
  there (`libraryPlaylistMove`). Activating a track plays the
  playlist from it; its menu adds Remove from Playlist, Move Up and Move
  Down on a manual playlist. An entry whose recording has no track left
  reads Not in your library, is dimmed and does not play. While no track
  is selected the inspector shows the playlist: its name, a "Playlist ·
  manual order" or "Smart playlist · N rules" subtitle, Details (tracks,
  unavailable, duration, artists, created and updated, dates as
  `YYYY-MM-DD`), Formats (tracks per codec from
  `libraryPlaylistFormats`, then ReplayGain as All analyzed or N not
  analyzed), Export (Export as M3U8…, and on a manual playlist Duplicate as
  smart playlist…, which opens the Smart Playlist editor with the one rule
  Playlist is this playlist, selected by playlist order, a
  `playlist_position` sort on it, so the copy keeps the manual order) and
  the tags.

  The **Smart Playlist editor** (New Smart Playlist, Edit Rules) is a page
  pushed in the Playlists section, so the sidebar keeps Playlists selected
  and the player bar stays live. Its top bar shows the history buttons, a
  breadcrumb from the previous page's title to Edit Smart Playlist (or New
  Smart Playlist), and Cancel and Save Smart Playlist where the search
  field sits on other pages. Cancel pops back to the previous page without
  asking, and back and forward treat the editor like any other pushed
  page; a revisited editor reloads the playlist's stored rules. The page
  opens with the sparkle tile and the name in 36 px serif. The rules card
  reads Match all or any of the following rules, then one row per rule:
  field, comparison and value, a remove button (a thin minus) and an
  add-below button. A nested group is an indented card with its own Match
  all or any of. Add Rule and Add Group
  end the card; Add Group adds a group one level down with one rule, and
  rules JSON with groups up to four levels deep loads as nested cards. A
  rule's value is text, a number, a `YYYY-MM-DD` date, a count of days,
  weeks, months or years for is in the last, Yes or No in the field's
  words (Loved, Lossless), or for Playlist one of the manual playlists
  (`in_playlist`). The options card holds Limit to N tracks or hours,
  selected by an order (library order, random, most recently added,
  highest rated, most played and others), and a fixed Live updating row:
  Re-evaluates as your library and listening change, Smart playlists
  always reflect your library. The Live preview column, a quarter of a
  second after the last change, asks `librarySmartPlaylistPreview` for the
  count, total length and first seven tracks, then and N more; when liborca
  rejects the rules it shows the reason instead. An order the menu does not
  list, such as playlist order, shows as its own entry, and a loaded order
  left unchanged is saved exactly as it was read. Save creates with
  `libraryCreateSmartPlaylist`, pops the editor and opens the new playlist,
  or uses `librarySetSmartPlaylistRules`, renames an existing one and pops
  back to the previous page. Opening it on
  a smart playlist reads `librarySmartPlaylistRules` back into the cards.
- **Now Playing** is the audible track's cover, 340 px with a soft shadow,
  over its artwork backdrop filling the page under a radial vignette, with
  the title in 48 px serif, the artist and the album with its year as
  links, a heart, five rating stars and a more button with the track menu.
  Clicking the title opens its album. The transport stays in the player
  bar. Under the buttons sit three centred lyric lines: the previous line
  faded, the line being heard, and the next, then Show all lyrics. Plain
  lyrics show their first three lines, the page looks lyrics up itself
  when the track changes, and the space collapses when the track has none.
  A 340 px column at the end holds Up Next, ten queue entries from the
  audible one, the playing one tinted, with Clear and View Full Album, and
  Track Info (Album, Date, Genre, Track as "1 of 13", and Source as "FLAC
  · 16-bit · 44.1 kHz" with the path as its tooltip). The backdrop and the
  column run under the top bar, which turns transparent and ends at the
  column, so the Now Playing overline and the search sit over the centre
  column, and hides the back and forward buttons (Alt+Left and Alt+Right
  still work); every other page keeps the top bar above its content. Show
  all lyrics closes an open inspector and turns the column into 380 px with
  Up Next, Lyrics and Info tabs, keeping the three lines and hiding itself
  while the Lyrics tab shows; below 900sp it opens the Lyrics inspector
  instead. Lyrics scrolls the whole lyrics with the current line bright and a
  third of the way down, seeks to a synced line when it is clicked, and
  ends in a footer naming the source ("Synced · from 01 Dr. Whoever.lrc",
  "Synced · embedded") and its `[offset:]` ("Offset −0.2 s", left out when
  zero); Info shows Track Info alone; Up Next returns to the column. An
  inspector replaces that column; below 900sp the page shows only the
  centre column. With nothing playing it shows a large glyph, Nothing
  playing and Pick an album or press Play. Clicking the cover in the
  player bar opens it.
- **Queue** is the Player's queue as the engine resolves it, in a column at
  most 980 px wide. Under the page title are the tracks left from the
  audible entry, the time they take when the whole queue is read, and
  `from` the album of the queue's first entry, beside Save as Playlist and
  Clear. Now Playing is the audible entry on an accent-tinted card: a
  56 px cover, the title in the accent colour, artist and album, and the
  position over the duration. Up Next lists the entries after it, each a
  number and the title over the artist and its duration, with a drag
  handle and a more button on hover. Activating an entry plays it.
  The more button and a right click open its menu: Play Next, Play Later,
  Love or Remove Love, Go to Album, Go to Artist, Remove from Queue and
  Save Queue as Playlist…. On the focused entry Shift+Enter plays it next,
  L toggles its love and Delete removes it. Dragging an entry onto another, or Play Next
  and Play Later, moves it with `playerQueueMove`; when the
  engine refuses with `QueueEntryInUse`, because the entry or the target is
  already lined up, a toast says so and the page reloads unchanged.
  Previously Played lists `playerQueueHistoryTracks`, newest first and
  dimmed, with when each was played, such as `6 min ago`; it is shown until
  Hide, which `settings.ini` remembers, and Clear History calls
  `playerClearQueueHistory`. Save as Playlist asks for a name, calls
  `playerSaveQueueAsPlaylist` (the audible entry and everything after it)
  and opens the new playlist. The sidebar's Queue badge counts the tracks
  left.

- **Health** is the Library Health overview. Under the title, Last
  analyzed (`LibraryStats.last_analysis_at`) and Analyze Again, which
  starts analysis and, when it succeeds, duplicate finding. A status card
  says "Your library is in good shape." or, while
  `libraryMissingFileCount` is above zero, "Some files need attention.",
  beside the album and track counts (`libraryStats`). Seven rows follow,
  each with a tinted icon, its count, a note and an action; a chevron
  expands a row into a paragraph about it and, for rows backed by health
  kinds, their files (`libraryHealthIssuePageOfKind`, 512 at a time, Show
  more). Counts come from `libraryHealthSummary` unless noted:
  - Duplicates: `exact_duplicate`, `identical_audio` and
    `likely_duplicate`, "Potentially SIZE" from their redundant bytes;
    Review opens Duplicates.
  - Mismatched metadata: the open issues of the metadata consistency pass
    (`libraryMetadataIssueStatus`); Review opens Metadata Issues. The row
    stays open while the pass has never run or is out of date.
  - Possible clipping: `clipping`, each file as `0.0 dBFS · N samples`;
    Review opens Audio Problems at Possible clipping.
  - Missing loudness analysis: `missing_analysis` plus
    `libraryUnanalyzedCount`; Analyze starts analysis.
  - Unmatched releases: `libraryReleaseMatchCounts`' unmatched Releases;
    Review opens Matches.
  - Missing artwork: `artwork_problem`; Fix opens Artwork Review.
  - Missing files: `libraryMissingFileCount`; Locate opens Folders.

  A row with nothing to show is dimmed and its action disabled. A file's
  Dismiss hides the issue until its file changes
  (`libraryDismissHealthIssue`), with Undo (`libraryRestoreHealthIssue`).
  Open rows, how many files each has loaded and the scroll position are
  kept across reloads. The page reloads when matching, analysis or
  duplicate finding finishes.
- **Matches**, "How your albums line up with MusicBrainz releases, and
  why.", sorts Releases by their best MusicBrainz release candidate into
  four tabs, Confident, Needs Review, Unmatched and Reviewed, each with its
  count from `libraryReleaseMatchCounts`; Needs Review is shown first and
  its count is the sidebar badge, with the album corrections added. A
  Release is confident when its best candidate scores at or above the
  threshold set in Settings (90% by default, `[matching]
  accept_confidence`); a Release marked as reviewed is listed only under
  Reviewed. "Search
  matches…" in the top bar, focused by Ctrl+F, filters the tabs, their
  counts and the list by album title or artist; the badge stays unfiltered.
  Counts and the tab's Releases (`libraryReleaseMatchPage`), with each one's
  evidence and diff, are read on a loader thread, 100 at a time: the next
  100 are read and appended as the list scrolls near its end, until the tab
  has no more. Changing the tab or the filter starts again from the first
  100 at the top; a reload after an accept or a Job reads as many as are
  listed and keeps the scroll position, and a read started before a tab or
  filter change is dropped. Each row shows the cover,
  title and artist, "Best candidate" with the release's title and year, the
  confidence over a bar, and Accept and Review. Accept is offered only when
  the release tracklist is read and every Track has a place on it
  (`placement` with `needs_pairing` 0); otherwise the row offers only
  "Review · N tracks need pairing", or Review when no tracklist is read. A
  Reviewed row offers Unmark (`libraryUnmarkReleaseReviewed`, "Review
  undone") and Review. An Unmatched row has only Search, which starts a
  re-identify Job for the album. Clicking a row
  expands it to show the artist's local track count, the candidate's full
  date and track count, and the evidence (`libraryReleaseMatchEvidence`):
  AcoustID fingerprints `N of M tracks`, Track durations `within 1 s`,
  Artist, Album title and Release date, each marked agrees or differs with
  both values, beside a sentence that explains the confidence. Accept
  applies the release ID and whichever of album, album artist and release
  date differ (`libraryApplyRelease` with that `ReleaseFieldSet`) and
  toasts "Release accepted", or "Applied · left alone: A, B and N more"
  naming the Tracks it left alone.
  Match Again starts the matching Job. Library Health's Unmatched releases
  Review opens the Unmatched tab.

  **Match Review**, opened by Review, compares one Release with its best
  candidate (`libraryReleaseMatchDiff`). The top bar reads `Matches ›
  ALBUM` and `Review i of N` with previous and next over the whole tab
  under the current search, N from `libraryReleaseMatchCounts`, reading
  `libraryReleaseMatchPage` 100 Releases at a time. Under the cover and title, "Local album vs MusicBrainz candidate
  · N% confidence · Open release", the link opening the release on
  musicbrainz.org. Choose what to adopt is a table of Use, Field, Local and
  MusicBrainz for Album, Album artist, Release date, Release type, Release
  ID, Genre, Artwork and Track titles; the differing album, album artist,
  date and release ID start checked, and a checked row is tinted. Release
  type, Genre and Artwork are compared but never applied, so their Use box
  is insensitive. Artwork shows each side's source and size, "Local · 1200
  × 1200" and "Cover Art Archive · 1200 × 1200", "—" when unmeasured.
  Tracks · P of N placed aligns the release tracklist with the Tracks
  (`libraryReleaseAlignment`) in #, Your file, Release, Δ time (`0 s`,
  `+1 s`, `−1 s`) and Status, a local title that differs in the diff
  colour. Status reads ✓ Same recording for an automatic placement,
  Paired with Unpair (`libraryUnpairReleaseTrack`, "Unpaired") for one the
  user chose, a "Suggested · evidence" chip with Confirm for a suggestion,
  and "Not in your files" with a Pair… menu of the unplaced Tracks for a
  release track no file holds. Not on this release · kept as is lists the
  Tracks with no place, each with a Pair… menu of the release tracks no
  file holds. Pairing (`libraryPairReleaseTrack`) toasts "Paired with
  track N"; a release track another Track already holds reads "Another
  track already holds that release track". An empty menu is insensitive.
  Without a tracklist the section explains why and offers Look Up Release,
  which starts a re-identify Job, and Apply is insensitive; a release too
  large to align says so. The primary button reads Apply N Fields to Orca,
  or Apply N Fields · M of T Tracks when some Tracks have no place, with
  "Left alone on Apply:" naming them above the table. Apply stores only
  the checked fields (`libraryApplyRelease` with a `ReleaseFieldSet`) and
  toasts "Applied N fields", "· reviewed" when that marked the Release
  reviewed, the left-alone Tracks when any were, and "· album artist ID on
  the next lookup" when the artist IDs are not yet known. With every Track
  placed and nothing differing it reads Mark as Reviewed
  (`libraryMarkReleaseReviewed`), and on a reviewed Release Unmark
  Reviewed. Not This Release dismisses the candidate
  (`libraryDismissReleaseCandidate`), which moves the Release to Unmatched
  when it had no other, and Search MusicBrainz… starts a re-identify Job
  for the album. After Apply, Mark as Reviewed or Not This Release the
  page rereads the tab and moves on to the next Release, or back to
  Matches when the tab is empty. No media file is written.

  **Album corrections**, a section under the tabs that is hidden when
  there are none, lists the album groups a verification proposed
  (`libraryCorrectionGroups`): each names the album and artist and,
  expanded, every track's current title
  and position beside the proposed ones. Accept All
  (`libraryAcceptCorrectionGroup`) and Dismiss All
  (`libraryDismissCorrectionGroup`) take the whole group. A proposal that would
  replace the recording ID in effect says "replaces" and the start of that
  ID beside its source. Accepting a correction, alone or with Accept All,
  opens the tag-write preview for the corrected tracks when the accept
  changed their values.

Right-clicking a track, an album (tile, cover or title), an artist (row or
avatar), a queue entry, or the playing track's cover in Now Playing and the
player bar opens a menu: Play, Play Next, Add to Queue, Love, Dislike, a
Rating submenu (1 to 5 Stars, Clear Rating) for tracks, an Add to Playlist
submenu (New Playlist… and each manual playlist), Edit Tags…, Write Tags to
Files… on tracks, albums and playlists, Show Album and Show Artist, as far
as they apply; queue entries offer
Play Now, Play Next, Play Later, Remove from Queue and Save Queue as
Playlist…. A single track in the track list, an album page, the queue or
a playlist also offers Verify and Re-identify, and an album Match Album,
Verify Album, Re-identify Album and Fetch Cover Art. Verify needs Match by
audio fingerprint on in Settings. Re-identify Album accepts nothing and
fetches no cover; its proposals wait in Matches. A track with no feedback offers Love and Dislike; a loved one
offers Remove Love, a disliked one Remove Dislike. On a selection the entries
apply to every selected track. An album's menu offers Love Album or Remove
Album Love, and names its track entries Love All Tracks, Dislike All Tracks,
Remove Love from All Tracks and Remove Dislike from All Tracks; album love and
track love are independent of each other.
The playing track is marked across its whole row in the track list, on album
pages and in the queue.

Back (the mouse back button, or Alt+←) leaves an album or artist page first,
then returns to the page shown before, across the sidebar's pages: Albums, an
album, Now Playing, then Back returns to that album. On a selected row in the track list it acts on the
whole selection. Play Next and Remove go through `Runtime.playerQueueInsertNext`
and `playerQueueRemove`, so an entry the engine has already lined up is never
pulled out from under the output.
- The player bar spans the window in three parts, 1 : 1.5 : 1 with 24 px
  gaps, so the transport stays centred. On the left: the cover, the
  title, and the artist and album on one line. In the
  centre: shuffle, previous, a 40 px play button, next and repeat over the
  seek bar, with elapsed and total time in tabular figures. Its glyphs are
  Orca's own 1.6 px stroke icons, as are the volume and queue buttons'. On the right: a signal icon, then a button with
  the codec, the source rate and one verdict, read from the signal path
  (such as `FLAC · 44.1 kHz · Native`; `DSP` while ReplayGain, the
  equalizer or crossfeed changes the samples, exactly when the output
  picker's Mode line lists DSP stages, else `Resampled` when the output runs at
  another rate, `Native` on a bit-perfect path; hidden while nothing
  plays), which opens the signal path; under it the output device's name
  and a chevron, which opens the output picker; a 76 px
  volume slider, whose knob shows on hover or focus and whose level is saved as `[playback] volume` once it settles;
  and the queue. Each control is built once and only made insensitive or
  hidden as the state changes, and the three groups fill the bar's height,
  so Tab visits the left group, then the centre, then the right, whether or
  not anything plays. A heart beside the title loves the audible
  track and, pressed again, removes the love; it is read when the audible track
  changes and after any change. Below the 900sp breakpoint the signal icon
  is hidden, the device name stays and ellipsizes,
  and the volume slider moves into a popover behind the speaker button.
- The output picker is a 400 px popover titled Play on, opened a few pixels
  above the bar's top edge, with a refresh button that re-reads the outputs
  and keeps the chosen one. Each output is a row
  with an icon for its bus, its name and a note read from its
  `DeviceCapabilities`: `USB · bit-perfect capable`, `HDMI · up to 48 kHz`,
  `Bluetooth · lossy, re-encoded by the OS` in the caution colour,
  `Virtual`, or `<bus> · not responding` when the device is `unavailable`,
  which dims the row and makes it insensitive; System default, device 0,
  reads `Follows your OS output · shared mode`. A check marks the chosen
  output, and choosing another reopens the open output on it and keeps the
  picker open. Below the list a summary reads the signal path: Sending (the
  output's rate, depth and channels), Mode (`DSP:` and the active stages, such
  as `ReplayGain −6.2 dB`, or `Native` on a bit-perfect path) and Device
  supports (the reported rates and depths, such as `44.1–384 kHz ·
  16/24/32-bit`, with `As reported by the device` as its tooltip, left out
  when the device reported none). Then a volume slider with its value, and a
  footer with Signal Path, which opens the signal path inspector, and Sound
  settings, which opens Settings › Sound. Opening the picker is the only
  place the frontend asks for capabilities (`enumerateOutputDevices` with
  `.capabilities`), once per opening and once per refresh; every other
  device list asks for `.identity`.

**Love and dislike** are kept by liborca per recording (`librarySetFeedback`);
album love is kept per Release (`librarySetReleaseLove`) and changes no track.
Every track row has a heart button, in its own column in the Tracks and
Loved lists and after the title on album pages, the queue and the Now Playing page for the audible track and the tracks
up next. A loved track shows a filled heart in the accent colour; any other track shows an outline
heart, dimmed until the row is hovered or selected. Pressing the button loves
the track, or removes the love, and a disliked track becomes loved. The button
does not play the track or change the selection. The player bar's heart does the
same for the audible track. Disliked tracks have no marker on their row. The
love or dislike of a track without a MusicBrainz recording ID is saved on this
computer only.

The inspector's **Identity** section has two rows. MusicBrainz shows where
the recording ID in effect came from (From tags, Matched or Set by you) as a
link that opens the recording on MusicBrainz, or Not matched. AcoustID shows
the verification (`libraryTrackVerification`): Not checked, Matched, Hears a
different recording, Could not confirm or Could not fingerprint, with
"out of date" and "suggestion dismissed" appended when they apply. Show
identifiers reveals the recording, release, release-group, release-track and
album-artist IDs that are known, each with its source as a tooltip. A track
without a recording ID shows its top three proposals with Accept and
Dismiss, each naming its source and AcoustID score in its tooltip, and Review all when there are more, which opens the Matches page; with no proposals it offers Find Match, which searches for that
track alone. A track with a recording ID offers Verify while it is unverified
or out of date. A change made in one place repaints the others, by recording and
without a query per row: rows carry `TrackSummary.recording_id` and `feedback`,
and only those whose recording changed are replaced. The list factories connect
each button once, in setup, and read the row's track when the button is pressed.

Each page's header bar is flat, carries no title and spans the main column
only; the inspector beside it runs the full height of the window. A page pushed onto
another, such as an album or artist page, shows a breadcrumb at its start
whose first part returns to the page it was opened from (Albums › ABBA),
dimmed, and whose last part is the page in the normal text colour; a
playlist's reads Playlists › its name. Back and Forward buttons before the
trail step through the window's history, up to 32 visits; Alt+←, Alt+→
and the mouse back and forward buttons do the same. The header has no
window controls: Ctrl+Q quits and the compositor closes the window. At its
end sits only the library search, a 300 px field with a magnifier and a
Ctrl K hint. Its placeholder names what the page's own search covers
(`Search albums, artists or genres…`, `Search artists…`,
`Search tracks, artists, albums…`, `Search genres…`, `Search this folder…`,
`Search playlists…`, `Search loved…`, `Search settings…`) and reads
`Search your library…` everywhere else. Below the 900sp breakpoint the
entry becomes a search button that does the same as Ctrl+K. Ctrl+F focuses
the field, or opens Search where the header shows a search button. On Albums,
Artists, Tracks, Genres, Folders, Playlists, Loved and Settings its text
filters that page; elsewhere
typing opens Search with the text. On every page, text starting with `›`, or
`>` as a typed alias, opens the command palette with the rest. Either way the
field is cleared and the page stays unfiltered.

**Search** covers the header and the pages below it, under the sidebar,
with a frosted view. Its field (`Search your library…`) carries the hint
`↑↓ to move · ↵ to open · Ctrl ↵ to play`, and a back button and Escape
close it. Typed text goes to `Runtime.librarySearch` (`orca-cli search`)
120 ms after the last keystroke, and the frontend filters nothing itself.
Chips choose All, Artists, Albums, Tracks, Playlists or Genres; All asks for
five Tracks and liborca's default caps for the rest, a single kind for up to
50 of it. `SearchResults.top` is the Top result card, an Artist's portrait,
a cover or a kind icon with `Artist · 3 albums · 41 tracks`, beside the Tracks
(title, artist · album, length); then Albums as cover tiles
(`artist · year`), Artists, and Playlists (`Playlist · contains 6 X tracks`,
a mosaic of its covers) beside Genres (`X's main genre`). The row or tile
of what is playing is marked. Up and Down move, Enter opens (a track
plays; an album, artist or playlist opens its page; a genre opens on
Genres), Ctrl+Enter or Shift+Enter plays instead (an artist still opens).

**Command palette.** Ctrl+K, the compact header's search button or `›` in
the library search opens a 640 px dialog over a dimmed window, with a `›`
prefix, a `Type a command` field and an `esc` chip. Commands are listed in
groups: Commands (Scan library, Scan for duplicates, Show Library Health,
Measure loudness, Find matches, Verify recording IDs, Submit to AcoustID,
Add music folder…, Search library, Show each sidebar page, the three
inspector toggles, Play/Pause, Next, Previous, Shuffle on/off, Repeat mode,
Save queue as playlist, Keyboard shortcuts and About Orca), Settings (rows
such as `Scan settings · Settings › Library` and
`Scrobbling · Settings › Listening`, which open that tab), and Recent: the
last five results opened from Search, kept in memory only and listed
whatever the query, as `Play X` or `Show X`. Each row shows its shortcut, and each command calls the handler
its button or menu item uses. A command matches when each query word
begins a word of its title, subtitle or keywords. The first row is selected;
Up and Down move, Enter runs, Ctrl+Enter plays a Recent row, Escape closes,
and Backspace in an empty field switches to Search. The footer reads
`↑↓ Move ↵ Run Ctrl ↵ Play` and `Type without › to search your library`.

Below the header, the sidebar's pages open with a title block: the page name in
Newsreader, its count beneath it, and the page's own actions at the end
of that row. Album, artist and playlist pages have their own heading instead.

Below 900sp the album, artist and playlist headings and the Settings columns
stack vertically, the player bar tightens, and a header's actions wrap onto a
second line when they do not fit. Below 760sp the sidebar collapses behind a
back button, the browse panes hide, page titles shrink, and the player bar
stays tightened. Every page fits a 560 px window. Messages are toasts.
[Keyboard](#keyboard) lists the shortcuts. The window title names the page:
`Orca — Albums`, a pushed page's own title, or `Orca — Settings · Advanced`.

**Edit Metadata** (Edit Tags… in menus) is a page pushed over the current
section, or over Albums when the section has no navigation; the top bar shows
`ALBUM › Edit Metadata`, Cancel and Apply to Orca. The left column lists the
selected Tracks with check boxes, headed `13 tracks` and Select none or Select
all; Apply edits only the checked Tracks. The fields are Title, Artist, Album,
Album artist, Genre, Date, Track, Disc (`1 of 1`), Composer and Comment, plus
MusicBrainz recording for one Track, read from `libraryTrackFieldStates`. A
field the Tracks disagree on is empty with the placeholder `Mixed` and is left
alone unless typed into; a field whose library value differs from what a file
states shows an Edited badge. Genre shows its names joined with ` / `
(`Hip Hop / Rap`). Apply calls `libraryEditTracks`, and
`librarySetTrackGenres` for Genre (names split on ` / ` and `;`, so a bare
`/` as in `R&B/Soul` stays in one name), and keeps the page open
on the Tracks `libraryEditTracks` returns, because an edit that moves a track
to another album gives it a new id. The note's Write to Files… link applies,
then opens Write to Files on the checked Tracks. The Front cover column shows
the first Track's cover and where it comes from (`cover.jpg · same on all 13
tracks`, `Embedded JPEG`, `Cover Art Archive`, `Chosen cover`). Replace…
opens a file dialog and keeps the image as the front cover of every
distinct Release among the checked Tracks, as Artwork Review's Choose
Image… does. Remove is sensitive when the cover shown is chosen or fetched,
and calls `libraryClearReleaseArtwork(.front)` on each of those Releases;
embedded and folder covers stay.

**Write to Files** (Write Tags to Files… in menus, or the editor's link) plans
the write with `Runtime.planTagWrite` and shows it before anything changes, in
a column at most 1036 pixels wide: `Write tags to 13 files`, a card naming the fields that change and a card
naming the tag format (`Vorbis comments · FLAC · no audio data is touched`,
or ID3v2 for MP3 and AAC). Changes per file is a File / Field / Before /
After table of `TagWritePlan.files[].changes` and genres, the same changes
`orca-cli write-tags` previews, with Vorbis keys (`ALBUMARTIST`) for FLAC and
Ogg and field names for ID3v2, and genres joined with ` / ` where the CLI
joins them with `; `; the first two files show, then `and the same
4 changes on 11 more files · Show all 52 changes`. Conflicts and skipped
files are listed under the table. Keep original tags for undo is on and
cannot be turned off. Write 13 Files runs the plan as a `tag_write` Job with
the plan's digest; the Job shows in Activity, the finished write in Change
History, and its toast offers Undo (`undoTagWrite`). Back to Editor (Cancel
when no editor is below) discards the plan.

**First Run** fills the window, sidebar and player bar included, when the
library opened at launch has no roots. A step bar shows Folders, Scan,
Identify (optional) and Listen.

1. **Folders**, "Welcome to Orca", lists the folders to scan. The XDG music
   folder is filled in when it exists and is not the home folder; Add
   Folder… (Add Another Folder… once one is listed) opens a folder chooser,
   and × removes a row. Each row counts its audio files on its own thread with
   `estimateAudioFiles`, which reads no tags and adds nothing, and reads
   `About 2,800 audio files found`, `More than 100,000 audio files found`,
   `No audio files found yet` or `Orca cannot read this folder`. Watch for
   changes sets `[library] watch` as the Settings switch does. Scan My
   Music adds each folder with `libraryAddRoot`, starts a scan and opens the
   Scan page.
2. **Scan** is the Scan page below.
3. **Identify**, "Measure your music", opens when the scan finishes while the
   Scan page is showing. Loudness analysis (`analysis` Job) starts on its own
   when the scan ends; the Analyze my music switch cancels or restarts it, and
   the card shows `Measuring 1,952 of 3,002 files`. Skip, or Continue with the
   switch off, moves on and leaves the analysis running.
4. **Listen**, "Ready to listen", shows the Albums, Artists and Tracks counts
   from `libraryStats`; Start Listening opens Albums.

**Scan** is the page a scan started from First Run shows, "Building your
library". A card shows the stage title (`Finding files`, `Reading files ·
1,971 of 3,002`, `Finishing up`), the time left, a bar, the file being read
and four stages: Discover files, Read tags & build albums (files read and
albums found), Loudness analysis and Match with MusicBrainz, each waiting,
running or done. The files read, the total and the time left are the scan
Job snapshot's `completed_units`, `total_units` and
`estimated_remaining_ms`: the total counts every file the walk reaches,
covers included, so Discover files reads `3,302 files`, and the time left
appears once liborca has 10 s of progress to estimate from.
Below, `2 files couldn’t be read` lists the scan's `unreadable_file` health
issues with each file's last folder, name and reason, and Review later in
Library Health opens Health. Found so far shows the 14 most recently added
albums with the album count, and opens an album on click; it, the problems
and the sidebar counts, when shown, refresh once a second. Pause calls `pauseJob` and
then reads Resume (`resumeJob`), with `Paused` in place of the time left.
Hide opens Albums and leaves the scan running; the sidebar's activity widget
still shows it, and the steps after the scan are skipped. The page has no
search bar.

**Offline folder.** While a root is unavailable, a warn banner sits above
every page but Now Playing and Scan: "Your music folder isn't available"
(or "Some of your music folders aren't available"), the first offline
root's path in mono, the Tracks it leaves unable to play, and that ratings,
playlists and history are safe. The state is `libraryAvailability`, read on
a thread of its own at launch, after each library job and on Try Again, since
a hung mount can block the check; a request while one runs repeats it once
it ends. Try Again reads "Checking…" and is insensitive until the answer
arrives, then toasts "The folder is still not available" if a root is still
offline. Locate Folder… opens the folder
dialog and passes the choice to `libraryRelocateRoot`, then follows the
reconcile it starts. Details is a popover with each offline root's path,
volume and when it was last seen. Albums appends `· N unavailable` to its
count, dims each tile whose Release cannot play and badges "On this
computer" on those that can, from `libraryReleasesAvailable` per page;
Folders in the sidebar reads `N offline`. When the Player stops because an
entry failed (`PlayerStatus.last_failure`), the bar keeps that Track with
`Stopped · file unavailable`, a warn alert, a dimmed cover and an
insensitive play button, hides shuffle and repeat, and the signal path reads
`No signal`. Unavailable album tiles dim their title, artist and year
strongly and their cover lightly.

**Activity** is a page, opened from the activity popover's View all or the
command palette's Show Activity, of what the Library's Jobs are doing and
have done. Its header has Change History, which opens that page, and Pause
All, which calls `Runtime.pauseAll` or, while
`libraryJobsPaused`, reads Resume All and calls `resumeAll`. **Now** lists
`Runtime.jobQueuePage`: the Job holding the slot first, then the waiting Jobs
in the order they start. A running card shows the Job's kind, its progress
from `jobSnapshotSynced` (`212 of 327 files · 14 threads`, the detail being
liborca's, such as the provider rate limit), the percent, the estimated time
left and a bar, with Pause or Resume (`pauseJob`, `resumeJob`) and Stop
(`cancelJob`). A waiting card is outlined and reads which Job it starts
after, with a Remove from the queue button. **History** lists
`jobHistoryPage` newest first, 100 at a time with Show Older, under chips
for All, Scans, Analysis, File changes and Problems, grouped under Today,
Yesterday and dates. Each row has the finish time, a tick or a warning, the
Job's name and liborca's summary (a failure's reason first), the duration
(`instant` under a second, `—` for a Job that did not succeed), Undo for a
tag write with an undo group (`undoTagWrite`) or Retry for a retryable Job
(`jobRetry`), and Details, a popover of its start, finish, result, progress,
reason and summary. The page refreshes on each tick and rereads the history
when it is shown.

Once per launch, after the Library opens, its roots' availability is known
and no scan runs (a First Run scan finishes first), the app asks
`libraryBackfillPending` and, when it counts files or covers to repair,
starts `startLibraryPropertyBackfill`.
The Job shows in Activity like any other; when it repaired something, the
library views and Health reload.

The **activity popover**, opened from the sidebar widget, has Running,
Waiting and Recently finished sections: the running Job with its bar, time
left and Pause; the waiting Jobs and what each starts after; and the last
three history entries with how long ago they finished and their Undo or
Retry. Its footer has Pause all (or Resume all) and Change history, which
closes the popover and opens that page.

**Change History** is a page, opened from Activity, the activity popover or
the command palette's Show Change History, under the trail Activity ›
Change History. It lists `libraryTagWriteGroupPage`, up to 500 writes newest
first: each row has the time today, Yesterday or the date, `Wrote tags to N
files`, the Release title, and the state: Can undo, Expired, Undone, Rolled
back, Undoing, Failed or Needs attention. Selecting a row shows `Files on
disk · today 10:41`, the heading, `TITLE · N field changes · operation #N`
and a table of FILE, FIELD, UNDO RESTORES and CURRENT, the file's base name
on its first row only, then `and N more files with the same changes`.
`libraryTagWriteGroup` reads the write's files and backups, so the detail
loads on a thread of its own and the page shows it when the thread ends; a
selection made while one runs is loaded after it. Undo This Change… asks for confirmation and calls
`undoTagWrite`. Export Log opens a save dialog and passes the file to
`exportTagWriteHistory`, replacing a file the dialog has confirmed. The page
reloads after every library job.

**Duplicates** is a page, opened by Review on Library Health's Duplicates
row, Compare on one of its files, or the command palette's Show Duplicates,
under the trail Library
Health › Duplicates. Under its title, `N recordings appear more than once ·
potentially SIZE. Orca never deletes on its own.` sums
`libraryDuplicateGroupTotals`, and `Group N of M` with previous and next
buttons steps through the groups. The left list holds up to 512 groups of
`libraryDuplicateGroupPage`, each `TITLE` over `ARTIST · N copies`.
Selecting one reads `libraryDuplicateGroup` on the main thread and shows
the title, artist and album, the evidence from the group's `verdict`
(`Same file`, `Identical audio`, or `Fingerprints match · 99%` with the
similarity rounded down), and a card per copy, `Copy A · keep` with
Suggested on the suggested copy; picking another card's radio makes it the
kept copy. A table compares Path, Format, Size, Duration, Album, Track,
Date, Loudness, MusicBrainz (Matched or Not matched), Plays · rating, as
one shared row when the copies are the same recording, and In playlists
(`libraryDuplicateCopyPlaylists`), with values that differ from the kept
copy's coloured; duration and loudness are not. A note says why the kept
copy is suggested and what merging adds. Merge Metadata Only calls
`libraryMergeDuplicateMetadata` from each other copy's Track into the kept
one; Keep Both (Keep All with three or more copies) calls `libraryKeepBoth`
for the kept copy and each other; Ignore calls
`libraryIgnoreDuplicateGroup`. A group that is one file in several places
has a single card and offers Ignore only. No file is written or deleted.
The page reloads with Library Health.

**Audio Problems** is a page, opened by Review on Library Health's
Possible clipping row or the command palette's Show Audio Problems, under
the trail Library Health › Audio Problems. The left list holds four
categories with their counts from `libraryHealthSummary`: Possible clipping
(`clipping`), Decode errors (`corrupt_audio`), Malformed headers
(`unreadable_file`) and Missing ReplayGain (`missing_analysis`). The
selected category shows a paragraph on what the finding means and a card
per file (`libraryHealthIssuePageOfKind`, 50 first, then 512 per Show
more): the title, `ARTIST · ALBUM · FORMAT` from `libraryTrackSummary`,
the path and the issue's details. Show in Folder opens the file's folder;
Re-analyze calls `libraryReanalyzeFile` on a thread, which decodes and
measures the file again even when nothing is owed, then toasts the outcome
and reloads; Not a problem calls `libraryDismissHealthIssue`, with Undo.
Missing ReplayGain also counts files not yet analysed
(`libraryUnanalyzedCount`) with an Analyze button.

**Artwork Review** is a page, opened by Fix on Library Health's Missing
artwork row or the command palette's Show Artwork Review, under the trail
Library Health › Artwork. Under its title, `N albums with missing,
undersized or conflicting artwork.` is
`libraryArtworkProblemReleaseCount`, and the left list pages
`libraryArtworkProblemReleasePage` on a thread, 512 at a time up to 2,048
albums, each Release once with its worst problem. Each row shows the image
placeholder, the album's title and its problem: `Missing front`,
`300 × 300 · undersized` or `Embedded and folder differ`. The selected
album shows `Artist · Year · no front cover` beside its title, then two
columns. Local shows the Release's front cover from `libraryReleaseArtwork`
with its size and type, or `No artwork found · Folder and embedded tags
checked`, and Choose Image…, which opens a file dialog, reads the file on a
thread (up to `max_image_bytes`, sniffed as an image) and calls
`librarySetReleaseArtwork(.front)`. Cover Art Archive candidates lists
`libraryCoverArtCandidates` three across: a thumbnail, `1200 × 1200 · JPEG`,
the kind (`Release · approved`, `Release group`, `Back cover`, `Booklet`)
and a Use as menu of Front, Back, Booklet and Don't use. The first front
image is Front and the first back image Back; choosing a kind on one card
sets any other card holding it to Don't use. Find Candidates starts
`startCoverArtCandidates` as a Job when none are stored yet. Use Selected
Artwork runs `libraryUseCoverArtCandidate` for each chosen kind in turn,
then moves to the next album; Skip moves on without changing anything.
After either kind of change the album's tiles show the new cover and
Library Health reloads.

**Metadata Issues** is a page, opened by Review on Library Health's
Mismatched metadata row or the command palette's Show Metadata Issues, under
the trail Library Health › Metadata Issues; the sidebar keeps Health
selected. Under its title, `N inconsistencies across N albums. Fixes apply
to Orca's database; writing to files is a separate step.` comes from
`libraryMetadataIssueStatus`. A notice shows while the consistency pass has
never run or is running, the library changed since it ran, or an apply found
an album changed since it was checked; its Check Metadata (Check Again once
a pass has run) button starts the `consistency` Job and reads Checking…
while it runs. A loader thread reads the status and
`libraryMetadataIssuePage`, `app.page_size` at a time up to 2,048 issues,
into a 270 px list grouped under ALBUM ARTIST, DATES, TRACK NUMBERING,
GENRES & CAPITALIZATION and MUSICBRAINZ DIFFERS. Each row names the album
(or the genre's spellings) and what differs: `ARTIST · 2 tracks differ`,
`ARTIST · 1999 vs 2001`, `ARTIST · gap at track 4`, `3 spellings across 12
tracks`. The selected album shows its cover, title and `ARTIST · YEAR · N
tracks`, then a card per issue, titled by kind (`Album artist differs within
the album`, `Dates differ within the album`, `Track numbers repeat or are
missing`, `Genre spelled more than one way`, `Album title differs from
MusicBrainz` and others) with `N of M tracks differ` and what the fix does.
A choice between values lists each option with its support and, except for
track numbers, a `Custom value…` entry; a missing date, a precision change,
track numbering and an issue with one proposed value show a table of TRACK,
CURRENT, PROPOSED and APPLY, whose ticks pick the Tracks it changes. Apply
to Orca calls `libraryApplyMetadataIssues` on a thread for every card at
once and toasts `Updated N tracks in Orca`; Skip Album calls
`librarySkipMetadataIssue` for each of the album's issues, which hides them
until its values change. A note under the buttons says files stay untouched
until Write to Files. An issue out of date, an invalid date, a custom genre
that is not a spelling of the issue's genre, or a custom track number is
refused with a toast that says which.

**Settings** is a page, opened from the sidebar, the command palette or
Ctrl+,. Under its title an underlined tab bar switches between eight tabs;
it is one Tab stop, Left and Right move between tabs, and it shows icons
only when the page is narrower than 1040sp or the window narrower than
900sp. Each tab is a scrolling set of cards in two columns, which stack into
one when the page is narrower than 1040sp or the window narrower than 900sp.
Every choice is saved in `$XDG_CONFIG_HOME/orca/settings.ini` and applied
again at launch.

- General, saved in `[general]`:
  - Startup: Open Orca at login (`launch_at_login`) writes
    `$XDG_CONFIG_HOME/autostart/org.orca_music.Orca.desktop`, or removes it;
    when the file cannot be changed the switch turns back and a toast says
    so. Default page (`start_page=albums|artists|tracks|now_playing`) is the
    page the window opens on.
  - Notifications, sent through `GNotification`: Track changes
    (`notify_tracks`, off by default) shows the title and artist when the
    playing track changes; Library tasks (`notify_tasks`, on by default)
    repeats the toast a finished scan, analysis, duplicate search, tag write
    or failed Job shows.
  - Language & Sorting: Sort artist names (`artist_name_order=
    ignore_articles|as_written`) sets `name_order` on every `ArtistQuery` and
    `ReleaseQuery` the window makes, and reloads Artists and Albums.
  - Keyboard: Shortcuts expands to the window's shortcuts.
- Library:
  - Music Folders: a list of roots in Geist Mono that scrolls past six, each
    with a menu of Rescan (a scan of that root), Show in Files and Remove and
    a Paused or Unavailable subtitle when it applies, then Add Folder…,
    Rescan All Folders and Watch folders for changes.
  - Maintenance: Measure loudness, Analysis threads (a − and + stepper from 1
    to the available threads, saved as `[library] analysis_threads`), Find duplicates
    (with when the last search ran) and Idle maintenance.
  - Identification: MusicBrainz, always on; Match by audio fingerprint; the
    AcoustID key; Accept confident matches at, a stepper from 50% to 100%
    saved as `[matching] accept_confidence`.
  - Writing to Files: Always preview before writing tags, always on.
- Playback, saved in `[playback]`:
  - Volume Leveling: ReplayGain (`replay_gain=off|track|album|smart`; Smart
    uses album gain while a neighbour in playback order shares the Release,
    track gain otherwise), Preamp (`preamp`, −15 to +15 dB), Prevent clipping
    (`prevent_clipping`, the Player's peak protection) and Untagged tracks
    (`untagged=minus_6_db|as_is`, Use −6 dB by default).
  - Transitions: Gapless playback, always on; Stop after current track
    (`playerSetStopAfterCurrent`, not saved); When the queue ends
    (`queue_end=stop|repeat`), which sets `playerSetRepeat` to off or all and
    follows the player bar's repeat button.
  - Output: Output device, the same list as the player bar's picker, re-read
    each time the tab is shown; Match source sample rate, always on; Audio
    backend.
  - Resume: Remember position in long tracks (`remember_long_position`)
    calls `playerSetLongTrackMemory` with 20 minutes, or null when off, at
    launch and when switched. On launch
    (`on_launch=restore_paused|restore_playing|start_empty`) is applied
    once, when the window is first built: `playerRestoreState` with
    `.paused`, `.playing` or `.none`. `.none` restores nothing but still
    makes the runtime save this session, so a later launch restores what
    was played after it.
- Sound, saved in `[sound]`:
  - Equalizer: Off, Graphic or Parametric (`equalizer_mode`). Graphic shows
    the ten-band preset, preamp and sliders. Parametric shows Preset (Flat,
    the saved presets, HD 650 and New preset…, which asks for a name and
    saves the current curve), Preamp with − and + steps, Import… and
    Export… of EqualizerAPO text, the response graph, and a table of
    filters (type, frequency, gain, Q, on, and a menu to duplicate, move or
    remove one) with Add Filter. A Notch filter read from a file keeps its type; the type
    list offers Low shelf, Bell, High shelf, Low pass and High pass.
  - Per-Device Presets: a preset (None, Flat, a saved preset or HD 650)
    for the current output, System default and each other output that has
    one, in that order and rebuilt when the output or the device list
    changes; saved as `device_presets`, including those of outputs not
    shown. Switch preset with device (`switch_preset_with_device`, on by
    default) comes last. When the
    output changes and the switch is on, the new output's preset is loaded
    and the parametric equalizer turned on; None leaves the equalizer as it
    is.
  - Crossfeed: a switch (`crossfeed_enabled`) and Amount Low, Medium or
    High (`crossfeed`, 0.3, 0.5 or 0.7, handed to `playerSetCrossfeed`).
- Listening: ListenBrainz; Fetch lyrics from LRCLIB, saved as
  `[lyrics] fetch=true|false`; Artist Info, with Fetch artist info
  (`[library] fetch_artist_info`); Listening History with Keep listening
  history (`librarySetListenRecording`), Count a play after (50% or 4
  minutes, 30 seconds or The full track, `librarySetListenPolicy`), Keep
  history for (Forever) and Clear history, which asks first and calls
  `libraryClearListens`; ratings, loves and playlists are kept. All are kept
  in the Library.
- Appearance: presentation only, saved in `[appearance]`.
  - Color: Artwork influence (`artwork=off|subtle|expressive`) sets how
    strongly the cover tints the backdrop behind album, artist, playlist and
    Now Playing pages: none, 60% or 75%.
  - Type: Display typeface (`display_typeface=newsreader|interface`) sets the
    font of album, artist, playlist and Now Playing titles, Newsreader or
    Geist. Tabular numerals in tables (`tabular_numerals`, on by default)
    turns the `tnum` feature on or off in list and column views.
  - Layout: Density (`density=comfortable|compact`; compact shortens queue,
    album list and sidebar rows and narrows the album grid's gaps),
    Album grid size (saved as `[view] album_cover_size` with the Albums
    page's Cover size, 400 ms after either slider stops, on leaving Settings,
    or on quitting, whichever comes first; the older `[appearance]
    album_tile` is read when it is absent), Show counts in sidebar
    (`sidebar_counts`, on by default) and Inspector
    (`inspector=open_on_selection|remember|closed`). Open on selection
    starts with the inspector closed and opens Details when a track is
    selected; Remember last state reopens the panel that was open at quit;
    Always closed starts closed and opens only on Ctrl+I. An older
    `inspector_open=true` is read as Remember last state.
  - Motion: Reduce motion (`reduce_animation`) turns off
    `gtk-enable-animations`, which stops sliding panels and transitions.
- Advanced, subtitled "Things most people never need. Defaults are safe.":
  - Audio Engine: the backend, Buffer size (the device quantum from
    `playerSignalPath`, or Set by PipeWire) and the 32-bit float internal
    format.
  - Libraries: Active library, a value with one library and a drop-down
    with more, which switches at once; under it, when a library could not
    be opened, a warning row with the path; and Libraries with Manage…,
    which opens a dialog listing each library's name, path, size and track
    count, with Switch, Rename (at most 40 characters, unique), Remove from
    List (never the active one; the database stays on disk) and Add Library….
    Add asks to Open Existing…, which takes an SQLite database that has an
    Orca schema version or a `-wal` beside it and adds it without switching,
    or Create New…, which adds the chosen path and switches to it, creating
    the database. An added library is named after its file, with a number
    when another library has that name. The list holds at most 16 libraries.
  - Data sources: Fill missing genres from MusicBrainz (`setGenreFill`, kept
    in the Library), then one row per `Runtime.providerSources()` entry (what
    it supplies, its licence as a link when it has a licence page, and a link
    to the site); the MusicBrainz genres row shows only while the switch is
    on, and follows it at once.
  - Storage & Logs: the database path with Reveal, which opens its folder;
    the artwork and analysis cache size from `libraryCacheSize` with Clear
    Cache…, which asks first and calls `libraryClearCache`; Operation history
    with View…, which opens Change History; Log level (Info, Debug or Trace,
    saved as `[advanced] log_level`).
  - Reset: Rebuild library database asks first, then scans every root with
    `ScanRequest.reprobe_all`, reading every file again; Reset all settings
    asks first, then returns every preference to its default and turns
    scrobbling, genre filling and launch at login off. The output device,
    volume, view state and saved equalizer presets are kept, and so is
    everything in the Library.
- About: the wordmark, version, liborca version and architecture, with Open
  Logs, Licenses (`share/doc/orca/licenses` beside the binary) and Copy
  Diagnostics; key and value cards for Audio (backend, output device, the
  device's formats and the engine), Library (the active library's name,
  tracks, database and last scan)
  and System (the `PRETTY_NAME` of `os-release`, the desktop portal, not used,
  and the logs folder); chips of `supported_formats`; and a preview of what
  Copy Diagnostics puts on the clipboard: version, OS, backend, device and
  its format, buffer, DSP stages, library totals and the database path. The
  home directory is written `~`, any other path only its last component, and
  the user name `[user]`.

The log is `$XDG_STATE_HOME/orca/logs/orca.log`. Errors, warnings and info
are always written to it; Debug adds Orca's debug lines and Trace also
GLib's debug output.

The search field filters Settings while the page is shown: it hides every
row whose title and subtitle do not contain the text, ignoring case, every
card left with no row unless its own title matches, and every tab left with
no card, and moves to the first tab with a match. Clearing the field or
leaving the page shows them all again.

The tabs are built each time the page is shown and destroyed when it is left;
the open tab is kept for the session.

**Watch folders for changes**, on by default and saved in `settings.ini`,
calls `libraryWatch` with the default `WatchOptions` once the library opens
and whenever it is switched on, and `libraryUnwatch` when it is switched off.
Where watching is unsupported the switch is not shown. Its subtitle shows
`libraryWatchStatus`, refreshed on each tick while Settings is showing: how
many folders are watched and how many are unavailable, and, when the watch
limit was reached, that `fs.inotify.max_user_watches` must be raised (on
NixOS through `boot.kernel.sysctl`). **Idle maintenance**, off by default
and saved as `[maintenance] enabled`, calls `libraryMaintenance` with the
default five-minute interval, enabled only while Match by audio fingerprint is
on (the switch is insensitive otherwise). Its subtitle shows
`libraryMaintenanceStatus`: the minutes to the next unit and the units run, or
why it is blocked, kept current by a wake at least every 15 seconds while
Settings is showing. Each tick reads that status once, and when `units_run`
has grown it reloads Health and Matches without a toast. A job started from
the frontend while a unit runs is queued and shows as starting until the unit
stops. The tick rereads every library view once for each drain that brought a `Telemetry.library_changed` for the open
library. Scans, measurement, duplicate finding, tag writes, matching and
AcoustID submission share the Library's one Job slot: a Job started while
another holds it is `waiting`, shown as a waiting card on the Activity page
and in the activity popover, and starts when the Jobs before it finish. The
33rd waiting Job is refused (`error.JobQueueFull`) with a toast. ReplayGain
and the output device (by name, since device ids are renumbered between runs)
are saved in `$XDG_CONFIG_HOME/orca/settings.ini`, along with the sound
settings below. Removing a folder asks first, then forgets its tracks; the
files on disk are not touched, and it is refused while a job is running.

The **Sound** tab drives the Player's DSP chain through
`Runtime.playerSetEqualizer`, `playerSetParametricEqualizer` and
`playerSetCrossfeed`. The equalizer card's header has an Off, Graphic and
Parametric control; the two equalizers never run together, and Off keeps the
last editor showing, insensitive. The graphic equalizer has ten bands from
-12 to +12 dB, a preamp and presets (Flat, Bass, Treble, Vocal, Loudness); a
curve that matches no preset reads Custom. Crossfeed has three amounts.
Slider drags are coalesced into one apply about 60 ms after the last move,
because applying pauses the engine briefly. An edit still settling when the
app quits, to either equalizer or the volume, is saved to `settings.ini`
without being applied, so it holds at the next launch. Beside the equalizer, Output
Device is a drop-down over the same list and selection as the player bar's
output picker; choosing in either updates the other. Audio Information shows
the playing Track's format, sample rate, bit depth and channels from the
signal path, or Nothing playing.

The **Parametric Equalizer** edits up to 16 filters (`max_parametric_filters`)
and a preamp:

- Preset: Flat, Custom, the presets saved with the card menu's Save as
  Preset…, then HD 650 (sample). A curve that matches none reads Custom.
- Preamp: -24 to +6 dB in 0.5 dB steps, with − and + buttons, and Auto, which
  lowers it by the largest boost so the curve cannot clip.
- Import Preset… reads an EqualizerAPO file through `parseEqualizerApo`; a
  file Orca cannot run is refused with a toast naming the line. The card
  menu's Export… writes the curve as EqualizerAPO text, which `orca-cli
  peq-check` accepts. Reset returns to Flat.
- The graph plots the filters' combined response from 20 Hz to 20 kHz on a
  log axis over ±12 dB, at the output's sample rate, without the preamp, with
  one coloured dot per enabled filter: a peak's dot at its gain, any other
  filter's on the curve at its frequency. Dragging a dot moves its frequency
  with the pointer and its gain by the pointer's vertical travel, applied on
  release; scrolling over it changes its Q.
- The filter table is one Tab stop of 28 px rows: number, colour, name, Type,
  Freq, Gain and Q, an Enabled switch, and a menu of Duplicate, Move Up, Move
  Down and Remove. Negative gains and preamps are written with a minus sign
  (U+2212); typing either `-` or `−` is accepted. Spin edits are applied after
  the same 60 ms settle.
  Add Filter adds a peak at 1 kHz and is insensitive at 16 filters.

The card's icon is a pulse. Where the Settings tabs show icons only, the
card's mode switch and menu move under its title. Below 900 sp the card's
controls stack, and the filter table scrolls sideways inside the card rather
than the page.

Sound settings are saved in `[sound]`: `equalizer=G1,...,G10:PREAMP`,
`equalizer_mode=off|graphic|parametric`, `parametric` (the curve as
EqualizerAPO text), `parametric_presets` (a list of `NAME` and newline then
EqualizerAPO text), `crossfeed=AMOUNT` and `crossfeed_enabled=true|false`.
Curves and amount survive while the effect is off and are applied at launch.
A file with no `equalizer_mode` reads `equalizer_enabled=true` as the graphic
equalizer; one that predates the `*_enabled` keys and holds `off` leaves the
effect off with the default curve or amount.

The Library tab's **Identification** card holds Match by audio fingerprint,
on by default, which is `MatchRequest.fingerprints` for Find Matches and Find
Match and is saved as `[matching] fingerprints=true|false`. Below it, the
AcoustID key row reads "Saved in your keyring" with Replace… and Remove, or
names acoustid.org with Add…; Add… or Replace… shows the key field, titled
Add key or Replace key, with a show-key toggle and Save. A successful save
clears the field, turns the toggle off and hides it again. It has the same
Unlock and storage rules as the ListenBrainz token below, stored under
`acoustid_credential_service` / `acoustid_user_key_account`. Its stored state
is found without unlocking the keyring, so opening Settings never prompts; a
locked keyring reads "Keyring locked" until Unlock is chosen. The Matches page
finds whether a key is saved the same way at startup, and again after each
save and remove.

The **Listening** tab's ListenBrainz card starts with Account: Connect…
shows the token field, titled Paste your user token, with a show-token toggle
and a Save button, enabled while the field has text; Enter in the field saves
too. The subtitle links to https://listenbrainz.org/settings/. With a token
saved the row reads "Connected as" the user name, "Token rejected" or "Saved
in your keyring", with Disconnect. The token is stored in the Secret Service
through libsecret (`apps/linux/secret.zig`) and never in `settings.ini` or the
Library. Saving clears the field, turns the toggle off and calls
`libraryScrobblerCredentialsChanged`; Disconnect deletes the token and calls
`libraryScrobblerCredentialsChanged`. The stored state is found the first time
the tab is shown after Settings opens, and again after each save and remove,
by an asynchronous search that reads no secret; it may prompt to unlock the
keyring. A keyring that stays locked reads "Keyring locked", with an Unlock
button that searches again. Saving, removing and searching are asynchronous,
so a prompt cannot freeze the window.
Submit listens calls `Runtime.librarySetScrobbling`. Send now playing is its
Now Playing argument; it is off by default and insensitive while Submit
listens is off. Pending shows the listens waiting and, from
`libraryScrobblerStatus` on the tick while Settings is showing, why they wait
(queued, a rate limit, an outage, offline or a rejected token) and the loves
and dislikes waiting to sync. Listens are recorded locally whether or not they
are sent. `[listening] scrobble=true|false` and `now_playing=true|false` are
saved and re-applied at launch. `ORCA_LISTENBRAINZ_URL` selects another
server, for a self-hosted instance or a local mock; `ORCA_MUSICBRAINZ_URL` and
`ORCA_ACOUSTID_URL` do the same for matching and submission.

The **signal path** inspector is titled Signal Path, "How this track gets
from file to output.", with a × that closes it. A verdict card follows:
Bit-perfect, Native sample rate or Resampled 44.1 → 96 kHz, then `DSP
active` when ReplayGain or DSP changes the samples and `volume` below full
volume, over the chain from the source format through the 32-bit float
engine to the output device (`FLAC 16-bit / 44.1 kHz → 32-bit float →
Topping DX7 Pro`). The stages follow on a rail, in chain order, each with an
icon node, its name, a value and a line or two; a stage that does not apply
to the path is left out, not shown empty:

| Stage | Shown | Value | Lines |
| --- | --- | --- | --- |
| Source | always | codec | title · artist; `16-bit · 44.1 kHz · Stereo` |
| ReplayGain | gain applied or a mode on | `−5.3 dB` or None | `Track gain · peak protection on`; a missing album gain or the track gain it replaced |
| Parametric EQ | parametric mode | `4 filters` | `HD 650 preset · preamp −3.0 dB`, the preset named when the curve is a saved one |
| Graphic EQ | graphic mode | `10 bands` | the preamp, or `Flat · changes nothing` |
| Crossfeed | on | percent | |
| Volume | below full volume | percent | |
| Engine | always | output depth | `Orca audio engine · no resampling`, or the rates it resamples between |
| System | an output is open | PipeWire | the device rate, or the rates PipeWire resamples between |
| Output | an output is open | USB, PCI, Bluetooth, HDMI or Virtual | device name; the device's own format, `96 kHz · 24-bit · 2 ch`, and `Converted from Orca's 32-bit float` for an integer format, or while it is unknown what is sent, `44.1 kHz · 32-bit float · 2 ch` |

A stage that changes the samples has an accent node and a `Changes
samples` line. Clicking a stage shows or hides its detail; the equalizer
stages open with a table of type, frequency, gain and Q per filter or band,
and the others carry technical lines. The Engine and Output details carry
the transport and stream counters (`playerSnapshot`, `zoneStats`), read when
the inspector is drawn and when the detail is revealed, and the System
detail leads with the device's block size (`Block size 256 frames`) once
the stream has run and says that PipeWire's own volume and resampling are
not visible to Orca. A closing card gives the verdict in words, built from
`SignalPath.reasons`: "Bit-perfect: nothing changes the samples between
source and output.", or "Not bit-perfect:" and what changes the samples,
remixes, rounds, converts to the device's integer format ("the samples are
converted to the device's 24-bit format.") or is lossy, then where resampling
happens or "Nothing is resampled between source and output.", and "The
device's own format is unknown." while an output is open and
`SignalPath.device_format` is null. The Output stage changes the samples
when the device's format is an integer one. The player bar's format button and
the output picker's Signal Path link open it in the inspector's Signal
Path mode on a page with an inspector, and the format button opens a
popover on any other page. It comes from `Runtime.playerSignalPath`,
which pauses the engine briefly, so one read serves the format line, what
changes the samples, the popover and the inspector, and it is read only when the audible track,
ReplayGain, the equalizer, crossfeed, the volume (once the slider settles) or
the output device change, and when the popover or the Signal Path mode opens;
never on the tick.

The **inspector** sits at the end of the Tracks list, the Loved page, each
album page and playlist, and Now Playing, where it takes the place of the
Up Next column and shows the playing track. It is a column from the top of
the window to the transport bar, 316 px wide for a track or an album, 300
px for an artist, 290 px for a playlist, 380 px for lyrics and 388 px for
the signal path. Its header holds the title, a dim subtitle and a × that
closes it, and for a track a … button with the track menu before the ×; each
section has a small dim capitals heading with an icon, and its rows a 104 px
label column.
Three shortcuts, also palette commands, show it in one of three modes,
or hide it: the track inspector (`Ctrl+I`), lyrics (`Ctrl+Shift+L`) and the
signal path (`Ctrl+Shift+S`). The mode is shared by every page and saved as `[view] details`,
`lyrics` or `signal_path`; it starts hidden. Below the 1100sp breakpoint the
inspector is laid over the page instead of beside it and starts closed; a
mode opens it, and clicking beside it or Escape closes it without changing
the saved mode. The inspector's scrolling area is not a Tab stop. The Tracks inspector shows the first selected track, otherwise
the playing one, and the Loved inspector the selected loved track, otherwise
the playing one; an album page's inspector shows its selected track, otherwise
the playing track when it belongs to the album, otherwise the album: its
title, an Album subtitle, an Overview (artist, date, genres, tracks, duration
and format), Identity (whether a MusicBrainz release is matched, once release
info is stored) and its Description. An artist page's inspector shows the
Artist until a track is selected: their name, an Artist subtitle, an
Overview (genres, years active as `2014 – present`, origin as stored, and a
button that fetches the info again), In your library (albums, loved
tracks and when one of their tracks was last played), Identity (whether a
MusicBrainz artist is matched, its ID, and the photo's source: `Local ·
artist.jpg` or the provider and credit) and Links: MusicBrainz, Wikipedia
and Official website, those of them `libraryArtistLinks` lists, as plain
labels opening in the browser. On an album page a click or
the arrow keys select a row, one per page, and double-click or Enter plays
from it. The Tracks table and the Albums, Artists, Playlists and Queue lists
each take one Tab stop: Tab visits the focused row's buttons and then leaves
the list, and the arrow keys move between rows. The track inspector is filled from `Runtime.libraryTrackDetails` when
the shown track changes and when the library changes. It opens with the
track number and title, the artist and the album, then sections divided by
rules, each under an icon and a heading and hidden when it has nothing to
show: Audio (format with bit depth, sample rate, channels, bitrate,
duration), Loudness (integrated loudness, sample peak, ReplayGain), Identity
(the MusicBrainz and AcoustID rows, with the matching actions below),
Metadata (album artist, date, genre, track and disc as "1 of 13",
compilation) and File (the folder's last two components as `…/Artist/Album`
with the full folder in a tooltip, file name, size and modified in local
time, with a copy button for the path in its heading). A track total
counted from the album's tracks rather than read from a tag says so in a
tooltip. When `Runtime.planTagWrite` for the track finds something to write
or a conflict, a card under File reads `Orca metadata differs from file`
with Compare, a popover of Field / File / Orca rows holding the same changes,
genres and conflicts as `orca-cli write-tags`, and Write to File…, which
opens the tag write confirmation. Each plan is discarded once read, and
the card's answer is kept until the track, or its file's size or modified
time, changes, so other refreshes plan nothing; files
that cannot be written now show no card.

The output is opened on first play, not at launch. `ORCA_OUTPUT_DEVICE` pins it
to an orca device id, overriding the device list; see
[Testing playback without making noise](../CLAUDE.md). A paused restore at
launch loads the saved entry at its position and opens no output, so the
player bar shows the track, its position and the seek bar with nothing
held; play from the bar, the Space key or MPRIS opens the output first and
continues from that position. Restore and play opens it as play does.
Closing the window calls `playerSaveState` before the Zone and Player are
destroyed; the runtime saves again when the Player is destroyed, which
writes the same state.

Covers go through `apps/linux/art.zig`. A widget asks for a cover while it is
bound and forgets it when unbound; the frontend asks liborca's artwork loader
(`Runtime.libraryRequestArtwork`) and collects results on its tick, then
decodes each on a GTask thread through `gdk_pixbuf_new_from_stream_at_scale` at
one of four sizes (128, 256, 400 or 960 pixels), so an 11 MiB JPEG never
materializes at full resolution and never decodes on the main thread. Album
grid tiles take the smallest of 128, 256 and 400 that covers the tile in
device pixels, and ask again when the cover size setting crosses one. Up to
96 MB of decoded covers are kept, counted as four bytes per pixel, least
recently used first out; a request for a
widget that scrolled away is cancelled before liborca reads a file. A bound
widget holds its cover only while mapped: on a hidden page, a hidden layout
or a list row bound off screen it keeps its binding and drops the texture,
and it paints again from the cache when it is mapped. At most
eight covers are requested, read or decoding at once, and the rest wait
their turn, because an embedded picture is read whole. The app
allocates from `std.heap.smp_allocator`: covers are freed as they are
replaced, which an arena would never do. `main` limits glibc to one malloc
arena: with one per decoding thread, each kept the JPEG buffers it freed,
about 70 MB at startup on a 41,000-album library.

The frontend owns `org.mpris.MediaPlayer2.orca` on the session bus when one is
available. MPRIS methods invoke the same Player handle, and `PlaybackStatus` is
read from and signaled from authoritative snapshots.

`nix build` installs `share/applications/org.orca_music.Orca.desktop`, the
application icon and the bundled symbolic icons, so the package can be installed like any desktop
application. At startup `orca-gtk` adds `<exe dir>/../share/icons` to the icon
theme's search path, so the bundled icons resolve when `zig-out/bin/orca-gtk`
runs directly, without `XDG_DATA_DIRS`.

The app has its own look rather than the system's: it forces libadwaita's dark
scheme, and `apps/linux/style.css` defines Orca's palette as CSS variables and
maps libadwaita's colour variables onto them, so stock widgets match. The
interface is set in Geist and display titles in Newsreader; Geist Mono is
bundled for monospace text. All are under the SIL Open Font License,
installed with their licences to `share/orca/fonts`, and registered with Pango from
`<exe dir>/../share/orca/fonts` before the window is built; if they are
missing, `orca-gtk` logs a warning and uses system fonts.

### Keyboard

The shortcuts dialog (Ctrl+?) lists the window's shortcuts:

| Keys | Action |
| --- | --- |
| Space | Play or pause |
| Ctrl+→, Ctrl+← | Next track, previous track |
| L | Love the selected or playing track, or remove its love |
| 1 to 5 | Rate the selected or playing track |
| Shift+Enter | Play the selected track next |
| Ctrl+Enter | Play the search result now |
| Delete | Remove the selected queue or playlist entry |
| Ctrl+K | Search and commands |
| Ctrl+F | Search this page |
| Ctrl+L | Show the queue |
| Ctrl+Shift+L | Lyrics in the inspector |
| Ctrl+I | The inspector |
| Ctrl+Shift+S | Signal path in the inspector |
| Alt+←, Alt+→ | Back, forward |
| Ctrl+O | Add a music folder |
| Ctrl+Shift+R | Scan the library |
| Ctrl+, | Settings |
| Ctrl+? | Keyboard shortcuts |
| Ctrl+Q | Quit |

Space, Ctrl+←/→, L, 1 to 5 and Alt+←/→ are handled by window key
controllers rather than application accelerators. The plain keys do nothing
while a dialog is open or a text field or popover has focus, so a focused
search box keeps them.

L, 1 to 5 and Shift+Enter act on the selected track row first: in the
Tracks, Loved and playlist tables, an album's track list, an artist's Top
Tracks and a genre's tracks. They go through the same calls as the row
menu's Love, Rating and Play Next, so a multi-selection on the Tracks page
is loved, rated or played next as a whole, and L removes love only when
every selected track is already loved. With no selected row in focus, L
and 1 to 5 act on the playing track. Delete removes the selected entry of
a manual playlist through the menu's Remove from Playlist; a smart
playlist ignores it. The queue's own Delete, Shift+Enter and L are
described with the queue.

In the command palette's library search and the search page, Enter opens
the selected result, Ctrl+Enter plays it, and Shift+Enter plays a track or
album next; Shift+Enter on an artist, playlist or genre opens it. The
shortcuts cannot be rebound.

### Settings file

`$XDG_CONFIG_HOME/orca/settings.ini` holds only the frontend's own choices;
nothing inside a library is kept there, and secrets live in the Secret
Service. Its groups and keys, each described with the page or tab that sets
it:

- `[general]`: `launch_at_login`, `start_page`, `notify_tracks`, `notify_tasks`,
  `artist_name_order`.
- `[library]`: `watch`, `analysis_threads`, `fetch_artist_info`.
- `[libraries]`: `paths`, `names`, `tracks`, `active`.
- `[playback]`: `output_device`, `volume`, `replay_gain`, `preamp`, `untagged`,
  `prevent_clipping`, `queue_end`, `remember_long_position`, `on_launch`.
- `[sound]`: `equalizer_mode`, `equalizer`, `parametric`, `parametric_presets`,
  `device_presets`, `switch_preset_with_device`, `crossfeed`,
  `crossfeed_enabled`.
- `[listening]`: `scrobble`, `now_playing`.
- `[matching]`: `accept_confidence`, `fingerprints`.
- `[maintenance]`: `enabled`.
- `[lyrics]`: `fetch`.
- `[appearance]`: `artwork`, `density`, `inspector`, `display_typeface`,
  `tabular_numerals`, `reduce_animation`, `sidebar_counts`.
- `[advanced]`: `log_level`.
- `[view]`: `details`, `lyrics`, `signal_path`, `queue_history`, `album_sort`,
  `albums_layout`, `album_columns`, `album_cover_size`, `artist_sort`,
  `artists_layout`, `artists_role`, `genre`, `playlists_tab`, `playlists_sort`,
  `playlists_layout`, `track_columns`, `track_column_widths`,
  `track_columns_large`, `track_column_widths_large`.

### Screenshots

`scripts/headless-gui.sh` screenshots `orca-gtk` at 1440×900 without putting
a window on the desktop. It is how the redesign is compared with
`orca-design/screenshots`.

```sh
zig build
scripts/headless-gui.sh albums /tmp/albums.png
scripts/headless-gui.sh artists /tmp/artists.png move:800,500 scroll:3
scripts/headless-gui.sh albums /tmp/palette.png key:ctrl+k type:scan wait:500
```

The first argument is the page: `albums`, `artists`, `tracks`, `genres`,
`folders`, `loved`, `playlists`, `now-playing`, `queue`, `health`, `matches`
or `settings`. Albums is the start page and Settings opens with Ctrl+comma;
every other page is reached through the command palette's `Go to` commands,
in `show_page`, which opens the palette with Ctrl+K and types `>Show <page>`. The
steps after the output path run in order:

| Step | Effect |
| --- | --- |
| `key:SPEC` | One key with modifiers: `key:Return`, `key:ctrl+k`, `key:alt+Left` |
| `type:TEXT` | Types `TEXT` |
| `move:X,Y` | Moves the pointer, in output pixels |
| `click:X,Y` | Moves the pointer there and left-clicks |
| `dclick:X,Y` | Moves the pointer there and double-clicks |
| `rclick:X,Y` | Moves the pointer there and right-clicks |
| `drag:X1,Y1,X2,Y2` | Presses at `X1,Y1`, moves to `X2,Y2` in small steps, releases |
| `scroll:N` | `N` wheel steps; positive scrolls down |
| `wait:MS` | Waits `MS` milliseconds |
| `shot:PATH` | Saves a screenshot to `PATH` at once, without waiting to settle |
| `tree:PATH` | Saves sway's window tree, with window titles, as JSON |
| `log:PATH` | Copies `orca-gtk`'s output so far; `ORCA_GTK_DEBUG` adds its debug reports |
| `db:PATH` | Copies the app's library, with its `-wal`, to `PATH` |
| `close` | Closes the window as its close button does and waits for `orca-gtk` to exit |

The script waits until two consecutive frames match before writing the PNG.

The library is `ORCA_LIBRARY` when set, else `fixtures/library/design.db`,
which `scripts/design-fixture.sh` builds when it is missing; the app opens a
copy named `Main.db`, so a run never changes it and Settings calls it Main.
With `ORCA_HEADLESS_LIBRARY=settings`, which needs `ORCA_HEADLESS_CONFIG`,
the app gets no `ORCA_LIBRARY` and opens, in place, the library the
`[libraries]` group of that directory's `orca/settings.ini` chooses; the
`db:` step is refused then. Run `scripts/design-fixture.sh` inside the dev
shell to rebuild it after a schema change. It scans `fixtures/audio`, regroups
the Tracks into 26 albums by eight artists with `orca-cli edit`, and adds
genres, loves, ratings and ten playlists, seven of them smart, through
`orca-cli`. Covers and three artist photos are gradients generated by FFmpeg
and stored with `sqlite3`, because no command stores a local image. Six
fixture files carry an embedded cover, which wins over the generated one. The
database is ignored by git.

Settings start empty and are thrown away with the session. Set
`ORCA_HEADLESS_CONFIG` to a directory to use it as `XDG_CONFIG_HOME`
instead, so a setting changed in one run is read by the next:

```sh
ORCA_HEADLESS_CONFIG=/tmp/orca-config scripts/headless-gui.sh albums /tmp/a.png click:1395,165 wait:1000
ORCA_HEADLESS_CONFIG=/tmp/orca-config scripts/headless-gui.sh albums /tmp/b.png
```

The session is confined to a private `XDG_RUNTIME_DIR`, created under
`ORCA_HEADLESS_TMPDIR` (default `/tmp`); a path inside the user's runtime
directory, or one too long for a Wayland socket, is refused. Before starting
anything the script:

- pins output to `scripts/silent-sink.sh 1`, and aborts unless that device is
  the virtual Orca Silent Test Sink backed by `support.null-audio-sink`;
- clears `WAYLAND_DISPLAY`, `DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`,
  `SWAYSOCK` and the other session variables, and gives the app scratch
  `HOME` and XDG config, data, cache and state directories;
- points every provider URL at a closed local port.

It then starts a D-Bus daemon with an empty service directory, headless sway
(`WLR_BACKENDS=headless`), one long-lived `zwlr_virtual_pointer_v1` pointer
and `orca-gtk` with `GSK_RENDERER=cairo`. `wtype` and `grim` run only against
that compositor's socket. sway, grim, wtype, D-Bus and pywayland come from the
nixpkgs revision in `flake.lock`. On exit, including on failure or an
interrupt, the script signals only the processes it started, and only after
checking that `/proc/PID/environ` carries its runtime directory. It reports
any other process left in that directory instead of stopping it, and exits
non-zero.

## Listening from a host

A host that wants listening history and scrobbling calls, on the Zig API:

- `Runtime.setCredentialStore` with a `CredentialStore` over the platform's
  secure storage. `get` receives the service and account
  (`listenbrainz_token_service`, `listenbrainz_token_account`) and returns an
  owned copy of the token, or null. It is called on a listen worker's thread,
  never the caller's, so the store must be safe to call from there. It must
  never prompt or block on user interaction: a locked keyring reads as no
  token, and the worker's shutdown waits for the call to return. `orca-gtk`
  searches the Secret Service without unlocking it; only saving, removing or
  looking up the token from Settings, on the main loop, may show an unlock
  prompt.
- `Runtime.setClientIdentity` to name the host in submissions and in the
  history. Scrobbling cannot be turned on before it is set; see
  [Client identity](api.md#client-identity).
- `Runtime.setListenBrainzServer` only to select a self-hosted or compatible
  server.
- `Runtime.librarySetScrobbling` (its last argument turns Now Playing on),
  `libraryScrobblerCredentialsChanged` after the token changes, and
  `libraryScrobblerStatus` for presentation.
- `Runtime.librarySetFeedback` and `libraryTrackFeedback` for love and hate,
  which `TrackSummary.feedback` and `TrackDetails.feedback` also report.
  `orca-gtk` repaints the heart and the rows after each
  change rather than waiting for a reload.
- `Runtime.librarySetReleaseLove` for album love, which
  `ReleaseSummary.loved` reports; `ReleaseQuery.loved_only` with
  `ReleaseSort.loved`, and `TrackQuery.loved_only` with `TrackSort.loved`,
  list what is loved for the Loved page. Album love is never sent.

The identity and the server are copied. The store's context is borrowed and
must outlive the runtime. The setters may be called at any time
and reach each listen worker on its next pass; a host that sets them before
binding a Player to a Library avoids a first pass with the defaults. Listens are sampled inside
`processNextCommand`, so a host pumps it as it already does. The C ABI covers the
same steps: the credential callback ([Credentials](#credentials)),
`orca_runtime_set_client_identity`, `orca_runtime_set_provider_server`,
`orca_library_set_scrobbling`, `orca_library_scrobbler_credentials_changed`,
`orca_library_scrobbler_status`, `orca_library_set_feedback` and
`orca_library_set_release_love`. [providers.md](providers.md) describes what a listen is
and what is sent.
