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
  add/remove/query. `orca_library_query_roots_v2` calls back with an
  `orca_root_view_v2`, which adds whether the root is `available`, its
  `track_count` and its `unavailable_tracks`.
  `orca_library_relocate_root` moves a root to a new path, keeping its ids
  and the undo of its tag writes, and returns the reconcile job it starts; a
  path that is not a readable directory, or is nested with another root, its
  files or the root's old directory while that still exists, is
  `ORCA_STATUS_INVALID_ARGUMENT`, an unknown root `ORCA_STATUS_NOT_FOUND`, a
  held journal or an unfinished tag write under the root `ORCA_STATUS_BUSY`,
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
  analysis times, each with a `has_*` flag.
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
  counted, the advisory, and the dates the file was added and modified. `orca_library_track_play_stats`,
  `orca_library_listens_recorded` and `orca_library_unanalyzed_count` are
  plain reads.
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
  needs a client identity. Once it finishes, `orca_job_artist_info_outcome`
  reports an `orca_artist_info_outcome`. `orca_library_artist_info` calls back
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
- **Jobs.** `orca_library_start_scan` registers a background worker and returns
  immediately; `orca_job_snapshot_get`, `orca_job_cancel` and
  `orca_library_scan_stats` observe it. Scan progress is a count of files
  processed with `has_total = 0` — a walk has no honest denominator until it has
  finished. A scan projects as it commits;
  `orca_library_start_projection` reprojects without a walk.
  `orca_library_start_reconcile` walks only the given directories of one
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
- **Parametric equalizer.** `orca_player_set_parametric_equalizer` turns it
  on with an `orca_parametric_equalizer` of up to 16 `orca_parametric_filter`s
  and a preamp, turning the ten-band equalizer off, or off with NULL;
  `orca_player_parametric_equalizer_get` reads it back, and the signal path
  carries it as `parametric` with `has_parametric`. The `ORCA_PARAMETRIC_*`
  defines state the ranges. Three calls take no runtime and work from any
  thread: `orca_parametric_equalizer_response` fills the gain in dB at a
  caller's frequencies for a curve view, `orca_parametric_equalizer_parse_apo`
  reads EqualizerAPO text, and `orca_parametric_equalizer_write_apo` writes it
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
  another server: `https`, or `http` to `127.0.0.1`, `[::1]` or `localhost`
  only, copied, and `NULL` restores the public one.
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
  accept changed the album's key. A second match while one runs is `ORCA_STATUS_BUSY`.
  `orca_library_query_match_review` pages the Tracks with proposals, best
  first, and `orca_library_query_match_proposals` lists one Track's;
  `orca_library_accept_match` and `orca_library_dismiss_match` act on one,
  `orca_library_confident_match_count` and
  `orca_library_accept_confident_matches` on every file's best above a
  confidence in (0, 1], and `orca_library_apply_matched_release` applies a
  Release whose Tracks came to agree. `orca_library_track_verification` hands
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
zig build run-linux                                   # library in $XDG_DATA_HOME/orca
ORCA_LIBRARY=/path/to/library.db zig build run-linux  # another library
```

The window is an `AdwNavigationSplitView`:

- The sidebar is 216 px of buttons, one per page, under the Orca wordmark,
  in groups: Library (Albums, Artists, Tracks, Genres, Folders, Loved),
  Collection (Playlists), Playback (Now Playing, and Queue with its
  length), Library Tools (Health, and Matches with its count) and
  Settings. With Show counts in sidebar on, Albums, Artists and Tracks show
  the library's totals from `Runtime.libraryStats`. While a job runs or
  waits, an activity card at the foot reads `1 task running` or
  `1 task waiting`, with the percent and a 3 px bar when the job has a
  total and a pulsing bar when it has none, such as a scan; pressing it
  opens the job's progress and Stop in a popover.
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
  folds it again. Then come Play, a dark Shuffle, a heart that loves the
  Artist (`librarySetArtistLove`) and a more button. Below, Top
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
  library`, shows the release groups `libraryArtistElsewhere` lists as
  dimmed tiles marked `No local files`, captioned with the other artists
  credited and the year, such as `with Kaytranada · 2023`, each opening its
  MusicBrainz page in the browser. A tile shows the release group's kept
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
  all lyrics turns the column into 380 px with Up Next, Lyrics and Info
  tabs: Lyrics scrolls the whole lyrics with the current line bright and a
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

- **Health** lists what liborca found wrong with the library. The page,
  titled Library Health, opens with the issue count
  (`libraryHealthIssueCount`),
  a Find Duplicates button and the library's album, track and artist counts
  (`libraryReleaseCount`, `libraryTrackCount`, `libraryArtistCount`), then a
  card per kind of issue in `libraryHealthSummary`'s order: a symbolic icon
  tinted by the kind's highest severity, the kind's name and a one-line
  explanation, its file count and, for `recording_mismatch`, Review, which
  opens Matches. Expanding a card pages
  that kind's issues (`libraryHealthIssuePageOfKind`) 512 at a time, with
  Show more while more remain; each row names the file, the issue's details
  and its folder. Open cards, how many issues each has loaded and the scroll
  position are kept across reloads. Each row offers the issue's
  `HealthAction`: Fix, a menu of Match and Edit Tags; Fetch Cover; Compare,
  a dialog of the duplicate's two files (`libraryHealthFile`) side by side,
  each with Reveal, that deletes nothing (a second location of the same
  file, which has no `related_file_id`, is described instead of shown);
  Review, which opens the
  correction in Matches; or Show in Files, which opens the file's folder
  and says "File not found" when the file is gone. Dismiss hides the issue
  until its file changes (`libraryDismissHealthIssue`), with Undo
  (`libraryRestoreHealthIssue`). A card above the kinds offers Analyse while
  `libraryUnanalyzedCount` is above zero and no analysis runs. The page
  reloads when matching, analysis or duplicate finding finishes.
- **Matches** lists the tracks with MusicBrainz or AcoustID proposals
  awaiting review (`libraryMatchReviewPage`), with their count in the
  sidebar, as a card of flush rows under the page title. Each row shows
  the track's own title, artist, album and length and its best proposal's
  score; expanding it lists every proposal with its album and release date,
  the looked-up release's when there is one, its
  source (MusicBrainz, AcoustID or MusicBrainz + AcoustID) and AcoustID's
  fingerprint score when there is one, Accept, Dismiss and a MusicBrainz
  button that opens the recording's page in the browser. Accept toasts
  "Match saved", or "Kept your values" when every value was locked or
  already held. An accept can regroup albums, so the library pages reload
  and album and artist pages go back to their lists, as after an edit. An AcoustID
  proposal without a title reads Unknown title. A proposal more than 10 s
  longer or shorter than the track shows its length in the warning colour.
  Find Matches starts the matching job, which shares the status card and,
  unless Match by audio fingerprint is off in Settings, also asks
  AcoustID by fingerprint with the application key the app sets at startup.
  Accept Confident asks first, then accepts each track's best proposal at or
  above the threshold set in Settings (90% by default,
  `[matching] accept_confidence` in `settings.ini`). With nothing to review
  the page offers Find Matches, or says every track has a recording ID.

  **Corrections**, a card above the tracks that is hidden when there are
  none, lists the album groups a verification proposed
  (`libraryCorrectionGroups`): each names the album and artist and,
  expanded, every track's current title
  and position beside the proposed ones. Accept All
  (`libraryAcceptCorrectionGroup`) and Dismiss All
  (`libraryDismissCorrectionGroup`) take the whole group; the tracks in a
  group are not listed among the tracks to review. A proposal that would
  replace the recording ID in effect says "replaces" and the start of that
  ID beside its source. Accepting a correction, alone or with Accept All,
  opens the tag-write preview for the corrected tracks when the accept
  changed their values.

  Submit to AcoustID (N) appears when an AcoustID key is saved and
  `libraryAcoustIdSubmittableCount` is above zero. It asks first, then runs
  `startAcoustIdSubmission` as a job on the status card, and the count is
  read again when it finishes. A missing or refused key, or an unreachable
  AcoustID, is reported in a toast; nothing is marked sent.

Right-clicking a track, an album (tile, cover or title), an artist (row or
avatar), a queue entry, or the playing track's cover in Now Playing and the
player bar opens a menu: Play, Play Next, Add to Queue, Love, Dislike, Edit
Tags…, Show Album and Show Artist, as far as they apply; queue entries offer
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
  (such as `FLAC · 44.1 kHz · Native`; `DSP` while the equalizer or
  crossfeed changes the signal, else `Resampled` when the output runs at
  another rate, `Native` on a bit-perfect path; hidden while nothing
  plays), which opens the signal path; under it the output device's name
  and a chevron, which opens the device list; a 76 px
  volume slider, whose knob shows on hover or focus and whose level is saved as `[playback] volume` once it settles;
  and the queue. Each control is built once and only made insensitive or
  hidden as the state changes, and the three groups fill the bar's height,
  so Tab visits the left group, then the centre, then the right, whether or
  not anything plays. A heart beside the title loves the audible
  track and, pressed again, removes the love; it is read when the audible track
  changes and after any change. Below the 900sp breakpoint the signal icon
  is hidden, the device name becomes an icon
  that opens the same device list,
  and the volume slider moves into a popover behind the speaker button.

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
Dismiss, each naming its source and AcoustID score in its tooltip, and Review all when there are more, which opens the Matches page at
that track; with no proposals it offers Find Match, which searches for that
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
playlist's reads Playlists › its name. The breadcrumb is the only back
control; Alt+← and the mouse back button also return. The header has no
window controls: Ctrl+Q quits and the compositor closes the window. At its
end sits only the library search, a 300 px field with a magnifier and a
Ctrl K hint. Its placeholder names what the page's own search covers
(`Search albums, artists or genres…`, `Search artists…`,
`Search tracks, artists, albums…`, `Search genres…`, `Search playlists…`,
`Search settings…`) and reads `Search your library…` everywhere else.
Below the 900sp breakpoint the
entry becomes a search button that does the same as Ctrl+K. Ctrl+F focuses
the field, or opens Search where the header shows a search button. On Albums,
Artists, Tracks, Genres and Playlists its text filters that page; elsewhere
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
stays tightened. Every page fits a 560 px window. Messages are toasts. Shortcuts are listed in the
shortcuts dialog (Ctrl+?). Space, Ctrl+←/→, L (love the playing track) and
1 to 5 (rate it) are handled by window key controllers rather than
application accelerators, and the plain keys do nothing while a dialog is
open or a text field or popover has focus, so a focused search box keeps
them. Ctrl+Shift+R scans the library. The window title names the page:
`Orca — Albums`, a pushed page's own title, or `Orca — Settings · Advanced`.

**Edit Tags** edits one track or many; a field the selection disagrees on is
marked mixed and left alone unless filled in, and clearing a field returns it
to what the file says. Save changes the library only. Save and Write to Files
plans the write with `Runtime.planTagWrite`, shows each file's changes and any
files skipped, and runs the approved plan as a job; the toast when it finishes
offers Undo (`undoTagWrite`). `libraryEditTracks` returns the Tracks the edited
files back afterwards, because an edit that moves a track to another album
gives it a new id.

**Settings** is a page, opened from the sidebar, the command palette or
Ctrl+,. Under its title a pill tab bar switches between seven tabs; it is one
Tab stop, Left and Right move between tabs, and it shows icons only when the
page is narrower than 1040sp or the window narrower than 900sp. Each tab is a
scrolling set of cards in two columns, which stack into one when the page is
narrower than 1260sp or the window narrower than 900sp:

- General: Artist Info, with Fetch artist info (`[library] fetch_artist_info`).
- Library: Music Folders, a list of roots that scrolls past six, each with a
  menu of Rescan (a scan of that root), Show in Files and Remove, then Add
  Folder, Rescan All Folders and Watch folders for changes; Maintenance with
  loudness measurement, analysis threads, duplicate finding, idle maintenance
  and Fill missing genres from MusicBrainz (`setGenreFill`, kept in the
  Library); AcoustID.
- Playback: ReplayGain (Off, Track or Album, saved as `[playback]
  replay_gain`), a note that gapless playback is always on, and the output
  device.
- Sound: the equalizer, graphic or parametric, and beside it Output Device,
  Crossfeed and Audio Information. Output Device re-reads the outputs each
  time the tab is shown, as the player bar's menu does when it opens, and
  both lists stay in step.
- Listening: ListenBrainz, and Fetch lyrics from LRCLIB, saved as
  `[lyrics] fetch=true|false`.
- Appearance: presentation only, saved in `[appearance]`. Artwork influence
  (`artwork=subtle|off`; off hides the cover tint behind album pages), Album
  grid size (saved as `[view] album_cover_size` with the Albums page's Cover
  size, 400 ms after either slider stops, on leaving Settings, or on
  quitting, whichever comes first; the older `[appearance] album_tile` is read
  when it is absent), Density (`density=comfortable|compact`; compact shortens queue and
  album list rows), Inspector open by default (`inspector_open`, opens the
  details panel at launch), Reduce animation (`reduce_animation`, which
  turns off `gtk-enable-animations`) and Show counts in sidebar
  (`sidebar_counts`, off by default).
- Advanced: a full-width Data sources card, one row per
  `Runtime.providerSources()` entry (what it supplies, its licence as a link
  when it has a licence page, and a link to the site); the MusicBrainz genres
  row shows only while Fill missing genres from MusicBrainz is on, and follows
  that switch at once. Below it, the library database path with Copy, About
  (Orca's version and the audio backend) and Copy diagnostics, which copies
  Orca's version, the library's totals and the signal path as text.

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
library. Automatic reconciles never take the status card, which follows only
jobs this frontend started, and a Rescan or other job started from the
frontend pre-empts a running one. Scans, measurement, duplicate finding, tag writes,
matching and AcoustID submission share the status card at the foot of the
sidebar, one at a time. ReplayGain
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
output menu; choosing in either updates the other. Audio Information shows
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

The Library tab's **AcoustID** card holds Match by audio fingerprint, on
by default, which is `MatchRequest.fingerprints` for Find Matches and Find
Match and is saved as `[matching] fingerprints=true|false`. Below it, Your
AcoustID key always shows, reading "Saved in your keyring" with Remove or "No
key saved"; under it the key field, titled Add key or Replace key, has a
show-key toggle and Save. A successful save clears the field and turns the
toggle off, hiding the field again. It has the same Unlock and storage rules as the
ListenBrainz token below, stored under `acoustid_credential_service` /
`acoustid_user_key_account`. Its stored
state is found without unlocking the keyring, so opening Settings never
prompts; a locked keyring reads "Keyring locked" until Unlock is chosen.
Get your token links to AcoustID's API key page. The Matches page
finds whether a key is saved the same way at startup, and again after each
save and remove.

The **Listening** tab holds the ListenBrainz settings, laid out like the
AcoustID card. Submit listens calls `Runtime.librarySetScrobbling`. User token
always shows, reading "Saved in your keyring" with Remove or "No token saved";
under it the token field, titled Add token or Replace token, has a show-token
toggle and a Save button, enabled while the field has text; Enter in the
field saves too. Get your token links to https://listenbrainz.org/settings/.
The token is stored in the Secret Service through libsecret
(`apps/linux/secret.zig`) and never in `settings.ini` or the Library. Saving
clears the field, turns the toggle off and calls
`libraryScrobblerCredentialsChanged`; Remove deletes the token and calls
`libraryScrobblerCredentialsChanged`. The stored state is found the first time the
tab is shown after Settings opens, and again after each save and remove, by an asynchronous search
that reads no secret; it may prompt to unlock the keyring. A keyring that stays
locked reads "Keyring locked", with an Unlock button that searches again.
Saving, removing and searching are asynchronous, so a prompt cannot freeze the
window.
The status row is rewritten from `libraryScrobblerStatus` on the tick while
Settings is showing: connected with the user name and the number of listens
waiting and, when there are any, the loves and dislikes waiting to sync, token
rejected, waiting after a rate limit or outage, offline, or not connected.
Listens are always recorded locally; the card says so. Show what I'm playing
now is the Now Playing argument of `librarySetScrobbling`; it is off by default
and insensitive while Submit listens is off. `[listening]
scrobble=true|false` and `now_playing=true|false` are saved and re-applied at
launch. `ORCA_LISTENBRAINZ_URL` selects another server, for a self-hosted
instance or a local mock; `ORCA_MUSICBRAINZ_URL` and `ORCA_ACOUSTID_URL` do
the same for matching and submission.

The **signal path** sheet opens with a verdict card: Bit-perfect, Native
sample rate or Resampled 44.1 → 96 kHz, then what changes the samples (gain
adjusted, DSP active, volume), over the chain from the source format through
the 32-bit float engine to the output device. Five stages follow on a rail,
each with an icon, a short tag and two or three lines: Source (title, artist
and album, format), ReplayGain / Gain (Track or Album ReplayGain by the
correction applied, the applied gain, `−3.1 dB (from −6.2 dB)` when an album
gain replaced a different track gain, `No album gain for this Track` on a
fallback, and the volume), DSP (the equalizer and crossfeed, or No processing), Engine / System
(32-bit float, and whether Orca resamples) and Output (the device, its rate
and format). Output's tag says how the device is attached: USB, PCI,
Bluetooth, HDMI or Virtual, and nothing when liborca does not know. Each
stage's chevron reveals its technical detail; the Engine and Output details
carry the transport and stream counters (`playerSnapshot`, `zoneStats`),
read when the sheet is drawn and when the detail is revealed, and the
Engine's leads with the device's block size from the signal path
(`Block size 256 frames`) once the stream has run. Clicking the verdict card shows or hides every stage's
detail. A footer says "Everything is working as intended." or names the
reasons the path is not bit-perfect, and adds that PipeWire's own volume and
resampling are not visible to Orca. The player bar's format button opens it
in the inspector's Signal Path mode on a page with an inspector, and in a
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
[Testing playback without making noise](../CLAUDE.md).

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
| `key:SPEC` | One key with modifiers: `key:Return`, `key:ctrl+k` |
| `type:TEXT` | Types `TEXT` |
| `move:X,Y` | Moves the pointer, in output pixels |
| `click:X,Y` | Moves the pointer there and left-clicks |
| `rclick:X,Y` | Moves the pointer there and right-clicks |
| `scroll:N` | `N` wheel steps; positive scrolls down |
| `wait:MS` | Waits `MS` milliseconds |

The script waits until two consecutive frames match before writing the PNG.

The library is `ORCA_LIBRARY` when set, else `fixtures/library/design.db`,
which `scripts/design-fixture.sh` builds when it is missing; the app opens a
copy, so a run never changes it. Run `scripts/design-fixture.sh` inside the dev
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
  `HOME` and XDG config, data and cache directories;
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

## macOS SwiftUI

`apps/macos` is a Swift Package that links `zig-out/lib/liborca` through a
systemLibrary modulemap (`Sources/COrca`). It is **not built or tested against
the current C ABI**, and liborca has no macOS audio output, so it cannot play;
both are listed under [Later](roadmap.md#later). `tests/c_abi_smoke.c` is what
exercises the C ABI in the meantime.

The client's design stays within the boundary: it requests 256-row pages,
inside the ABI's 512-row bound, shows them in a SwiftUI `List`, mirrors Player
snapshots through `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, and
imports no Zig, SQLite, codec or audio layout. File import, URL drops,
notifications, accessibility labels, menus and keyboard shortcuts are
presentation-only platform concerns.
