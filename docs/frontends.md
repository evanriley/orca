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
  add/remove/query.
- **Folders.** `orca_library_query_folder` pages one folder of a root as
  `orca_folder_entry_view` values: subfolders first, with file and Track
  counts and duration counted through every folder below, then files with
  their file id and, when `has_track_id` is set, the Track. The path is
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
  the audible entry, never the decode cursor.
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
  or unknown), Zone create/attach/open/close/status, and
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

- The sidebar (`AdwSidebar`) opens with the Orca wordmark and the main menu,
  then lists the pages in sections: Library (Albums, Artists, Tracks, Genres, Folders, Loved),
  Collection (Playlists), Playback
  (Now Playing, and Queue with its length) and Library Tools (Health and
  Matches, each with its count). Settings is pinned at its foot, above the
  scan progress shown while a scan runs.
- **Albums** is a grid of covers with each album's title, artist and year,
  paged 512 Releases at a time. Its title row shows `N albums`, a Sort by
  menu (artist, title, year or recently added, saved as `[view] album_sort`),
  a Filters button and a Grid / List switch (saved as `[view] albums_layout`).
  A Search albums field under the title sets `ReleaseQuery.text`, so the
  search combines with the chip and the filters, and the count is
  `libraryReleaseCountMatching` of the whole query. Chips under it choose All Albums, Recently Added (the newest Releases
  first), Loved, High Resolution (above 48 kHz or 16 bits) or Needs Review
  (a pending match or correction); they are radio buttons and one Tab stop,
  Left and Right moving between them. The Filters popover sets a genre (every
  genre, listed 512 at a time), a year range, Any or Lossless only, and
  whether the album has artwork, applied with Apply and reset with Clear;
  the button reads `Filters • N` while N are set. Every chip and filter is a
  field of `ReleaseQuery`, so liborca filters and counts. The grid takes the
  column count whose covers come nearest the chosen tile size (177 px by
  default) and grows or shrinks the covers so the columns fill the row,
  never fewer than two or more than sixteen. An
  album without a cover shows its initials, and an explicit album an E
  badge at the cover's bottom-left. Hovering or focusing a tile
  shows a play button on the cover, which plays the album, and a more button
  after the artist, which opens the album menu; the selected tile is
  outlined. The list shows 44 px rows of a small cover, title, artist, year,
  track count, minutes, format (`FLAC 16/44.1`, or `Mixed`), a heart that
  loves the album and a more button.
  Activating an album opens its page: the cover beside an overline naming
  the release type, else COMPILATION for a compilation and ALBUM otherwise,
  the title, the artist as a link and a line of year, its top one or two genres joined by ` / `,
  track count and minutes, then the album's description from
  `Runtime.libraryReleaseInfo`, at most 520 px wide and three lines, with a
  More link, shown when the text wraps past three lines at the width it is
  given, that shows the rest, and under it its source and licence. With no
  description stored the page starts `Runtime.startReleaseInfoFetch` once per album per session and
  shows the description when the job ends. Then come Play, Shuffle, a heart
  in the love colour that loves the album (Love Album, Remove Album Love)
  and a more button with the album menu; the page opens with focus on Play.
  Behind them the cover is drawn blurred and darkened, fading into the page;
  an album without a cover has no backdrop. Its tracks follow by disc under
  a # / Title / clock header, one thin-ruled row each: the playing track
  shows a play mark in place of its number and an accent title, and the more
  button with the track menu shows on the hovered, selected and playing row.
  A button in the header chooses extra columns, Rating, Format and Sample
  rate, saved as `[view] album_columns`. A narrow window shrinks the grid and
  stacks the album page's cover above its title.
- **Artists** is every Artist as a grid of round 150 px photos or as flush
  rows, chosen by a grid and list switch saved as `[view] artists_layout`.
  Each shows the Artist's photo when artist info stored one, otherwise their
  first album's cover, otherwise their initials, then their name and
  `N albums • N tracks`. A Sort by menu orders them by Name, Most tracks,
  Recently loved or Recently added, the Artist whose newest release, filed
  under them or appeared on, came latest first (`ArtistSort`, saved as
  `[view] artist_sort`); a Search
  artists field under the title filters by name through the query, and an
  empty library or search shows a status page. Opened from a genre's Top
  Artists, the page also shows a `Genre: Name` chip beside the search that
  scopes the query to that genre (`ArtistQuery.genre_id`) until its × is
  clicked. The grid keeps at least two
  columns and shrinks its tiles to fit a 560 px window. An artist opens a
  page whose hero lays a 300 by 330 px photo, fading right and down, over a
  blurred copy of it: the Artist's photo, otherwise their most played
  album's cover, otherwise their initials. Beside it sit an Artist overline,
  their name, their top three genres joined by accent dots
  (`libraryArtistGenres`), the first four lines of the stored biography,
  which open the inspector, then Play, Shuffle, a heart that loves the
  Artist (`librarySetArtistLove`) and a more button. A column at the end
  shows their ListenBrainz listener count, when known, as `9.0K` or `3.2M`,
  then their release and track counts and the time their tracks fill in the
  library, all from `libraryArtistTotals`. A `Photo: credit • licence` line under the hero links to the
  photo's page. Below sit Top Tracks, their five most played tracks, or by
  rating while none has been played, each with its cover, an E badge when
  explicit, a heart, duration and more button, with See All opening Tracks
  scoped to the artist sorted by plays; Albums, EPs & Singles and
  Appearances, each a wrapping grid of up to eight releases, newest first,
  under a heading with its count, whose release opens its page in place.
  Albums are the releases filed under the Artist, which
  `ReleaseQuery.album_artist_id` with `own_releases_only` selects, whose type is
  album or compilation or unknown (`ReleaseQuery.release_kind` `.album`), EPs &
  Singles those of type EP or single (`.ep_or_single`), and Appearances the
  releases with a track credited to them that are filed under another
  artist (`ReleaseQuery.appearing_artist_id`); a row with nothing in it is
  left out. The hero's cover falls back to their most played or first
  release, taken from their own releases before any they appear on. Each
  row's See All opens Albums scoped to the Artist and that kind, under the
  same query, shown as a `Name • Albums` (or `EPs & Singles`, `Appearances`) chip
  beside the Albums search that combines with the search, shelves and
  filters in the query until its × is clicked. Related Artists shows up to
  six round tiles from `libraryRelatedArtists`, each name under the photo,
  wrapping between words onto at most two lines and then ellipsized. A related artist in the library
  opens their page; one outside it shows initials and opens their
  MusicBrainz page in the browser. Opening an Artist without stored info
  starts an artist info Job (`startArtistInfoFetch`) once a session while
  Preferences' Fetch artist info switch, saved as
  `[library] fetch_artist_info`, is on; when it finishes the photo,
  biography, listeners, credit and related artists refresh in place.
  Activating a track plays the artist's tracks in album order from it, and
  the inspector shows the selected track, otherwise the Artist. A window too
  narrow for the full header stacks the hero and the two sections and lays
  the stats out in a row; a narrow window hides the stats.
- **Tracks** is the track list. Its header carries its own search,
  `Search tracks, artists, albums…` with a Ctrl F hint, in place of the
  library search, and a Filters menu: Genre, a Year range, Format (Any,
  Lossless, Lossy), a minimum sample rate, Loved only and Explicit only,
  with Clear Filters. Every filter is part of the liborca query, with or
  without search text, and the Genre list holds every genre, read 512 at a
  time each time the menu opens. The Filters button turns accent while any
  filter is set, and filters are not saved. The title row shows the exact
  count from liborca, or while searching `N matching`, the loaded rows with
  a `+` while more remain, then a Sort by menu (Default, Title, Artist, Album, Track Number, Date
  Added, Last Played, Play Count, Rating, Loved, Year, Duration; dates,
  counts, ratings and years newest or highest first), kept in step with the
  column headers and not saved, and a linked List / Browse switch, Browse
  showing the Artist and Album panes. The list pages 512 rows at a time from
  liborca as it scrolls, and a header click re-queries in the engine's order
  rather than sorting loaded rows; the sorted column's title is
  highlighted. Under an uppercase header each track is one thin-ruled row:
  the playing track shows a play mark in place of its number and an accent
  title, an explicit track shows an E badge after its title, its heart sits
  in its own column, its rating stars show on hover and once rated, and
  hovering a row shows a ••• button with the track menu. The ••• at the
  header's end, and every column title's menu, choose the columns: Artist,
  Album, Loved, Rating, Date Added, Year, Last Played, Plays, Duration,
  Format, Codec, Bit Depth and Sample Rate; # and Title always show. The
  default is Artist, Album, Loved, Date Added, Duration and Format. The
  choice is saved as `[view] track_columns` (a comma list of those names in
  snake case) and dragged widths as `[view] track_column_widths`
  (`name:pixels` pairs); the older `song_columns` and `song_column_widths` keys are read when these are absent; column order is not saved. A narrow window drops
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
- **Genres** opens with a large Genres title and a tagline, then a strip of
  165 by 128 px genre tiles, most tracks first, read from
  `libraryGenrePage` 512 at a time as the strip scrolls. Each tile's
  backdrop is a darkened two by two mosaic of covers from
  `libraryGenreArtwork` (one cover when the genre has fewer than four), with
  the name and track count at its bottom-left; the selected tile has an
  accent outline. The strip scrolls sideways, also with a vertical wheel,
  and is one Tab stop, Left and Right moving the selection. The selected
  genre is saved as `[view] genre`; the genre with the most tracks is shown
  when none is saved. Below it a GENRE overline, the genre's name and a line of
  its track, album and artist counts and total time from `libraryGenre`,
  then Play, Shuffle and a more button whose Create Smart Playlist saves a
  smart playlist of the rule `genre is Name`. Play and Shuffle queue the
  genre's playable tracks in Top Tracks order, at most
  `max_playlist_entries`.
  Three cards follow: Albums, the genre's four most played albums, each
  opening its album page in place; Top Artists, the five of its artists with
  the most tracks in the whole library; and Top Tracks, its five most played tracks, or by rating
  while none has been played, each with a cover, a heart and duration, a
  track playing the genre in that order from it. Each card's See All opens the matching
  page scoped to the genre: Albums through its genre filter, Artists through
  its genre chip, Tracks through its Genre filter in the card's sort. The
  cards stack below 1300 px and the artist and track cards stack too below
  720 px, so the page fits a 560 px window. A library with no genres shows a
  status page whose Fill missing genres from MusicBrainz opens Settings ›
  Library.
- **Folders** browses the library as it lies on disk. The header's
  breadcrumb reads `Folders › root › folder › …`, the root named by the last
  component of its path, and every segment but the last opens that level.
  A 280 px pane on the left lists the roots, each expanding lazily into its
  folders (`libraryFolderPage`, folders only), with the open folder
  selected; selecting a folder opens it. A window narrower than 900 px hides
  the pane. Above the content sit a Files / Library switch, Play and Shuffle,
  which play the folder and every folder under it
  (`playerPlayFolder`), and a count such as `12 folders • 148 files`, the
  files counting those in subfolders. Files lists 36 px rows, 512 at a time
  as it scrolls: folders first with their file count and total duration,
  activated to open them, then files with the file name, the track's title
  beside it when it differs, the format and the duration; below 700 px of
  content width the format (and a folder's file count) is hidden and the
  name takes the row's width before the title beside it. Activating a file
  plays this folder's tracks, without subfolders, in file order from it. A
  file's more button, or a right click, offers Show in Files, Play, Add to
  Queue and Edit Metadata…. Library shows the tracks of files directly in
  this folder, not in its subfolders, grouped by album under a 48 px cover,
  album title and artist and year, in disc and track order, as the album
  page lists them. A folder without audio shows `No audio files here.`, and
  a library without roots shows the welcome page. Each list is one Tab
  stop, and Backspace or Alt+Up opens the parent folder.
- **Loved** opens with a large Loved title, a tagline and a short
  description, Play, Shuffle and a more button, then a mosaic of up to four
  loved album covers (taken from loved albums first, then from the albums of
  loved tracks; one cover when there are fewer than four) and the counts of
  loved tracks, albums and artists. The mosaic goes first as the page narrows,
  then the counts. Play queues every playable loved track, most recently loved
  first, Shuffle does the same with shuffle on, and the more button opens the
  track menu for those tracks. Three underlined tabs follow: Loved Tracks, the
  Tracks list's table of loved tracks, most recently loved first and paged 512
  at a time, with the inspector for the selected track. Its columns are the
  row's position (#), a small cover, Title, Artist, Album, Duration under a
  clock, the heart, Rating, Last Played and a ••• button with the track menu
  on every row; the covers go when the table is narrow, and Album, Rating and
  Last Played as on Tracks. Last Played reads Today, Yesterday or
  `3 days ago` up to six days, then the date, with the full date and
  time in its tooltip; Loved Albums, the Albums grid of loved albums; and Loved
  Artists, a grid of round artist tiles, most recently loved first, each with
  the Artist's stored photo or its initials, its name and its album and track
  counts. The page never fetches a photo; `orca-cli artist-info --fetch`
  stores one. An album or Artist opens its page in place, a right click on an
  Artist opens the artist menu, and a track plays on activation. The page is
  read again each time it is shown, so a heart cleared on it leaves its row
  in place until then.
- **Playlists** opens with its title block, New Smart Playlist and
  Import… beside it, and the header's Search playlists entry and New
  Playlist. Tabs (All Playlists, Created by Me, Smart Playlists; one Tab
  stop, Left and Right move between them) choose which playlists both
  sections show. Pinned shows the four most recently updated pinned
  playlists, with Show all when there are more. All Playlists shows the
  count, a type menu (All Types, Playlists, Smart Playlists), a Sort by menu
  (Recently Updated, Name, Recently Created, Most Tracks) and a Grid or List
  switch; the tab, sort and layout are kept in the settings file. liborca
  filters, sorts and counts every section (`libraryPlaylistPage`,
  `libraryPlaylistCount`); the search matches names case-insensitively.
  A card shows a mosaic of the first four distinct album covers among the
  playlist's tracks, or for a smart playlist a tile whose icon follows the
  field its first rule tests (loved, dates, rating, play count), then the
  name with a pin when pinned, Smart Playlist, By You or Imported, the
  track count and length with how many tracks are unavailable, and when it
  was last updated (relative within 30 days, a date after that). The list
  shows the same in rows. Hovering or focusing a card shows a play button;
  its more button and right click open Play, Shuffle, Pin or Unpin, Love or
  Remove Love, Edit Rules… (smart) or Edit Details…, Rename…, Export… and
  Delete…. Edit Details… sets the description and up to eight
  comma-separated tags through `libraryUpdatePlaylist`. With no playlists
  the page offers Import…, New Smart Playlist and New Playlist.

  A playlist's page shows its mosaic or smart tile beside a Playlist or
  Smart Playlist overline, the name in capitals, a line of who made it, the
  track count, length and how many tracks are unavailable, and the
  description, then Play, Shuffle, a heart for playlist love, Edit Rules
  for a smart playlist and the playlist menu. Below 900sp the heading
  stacks the art above the name. The tracks follow in the Tracks list's
  table, numbered by their position in the playlist; below 900sp it drops
  its album and the other columns a narrow window drops on Tracks. Activating a track plays the
  playlist from it; its menu adds Remove from Playlist, Move Up and Move
  Down on a manual playlist. An
  entry whose recording has no track left reads Not in your library, is
  dimmed and does not play. While no track is selected the inspector shows
  the playlist: its name, Created by, Details (tracks, unavailable,
  duration, mixed artists, top genres, created, last updated), the
  description and the tags.

  The **Smart Playlist editor** (New Smart Playlist, Edit Rules) is a dialog
  with the name, a root group (Match all or any of the following rules),
  its rules and nested groups, each with Add Rule and Add Group, down to
  four levels, then Order by, Descending and Limit to. A rule is a field, a
  comparison fitting the field's type and a value: text, a number, a
  `YYYY-MM-DD` date, or Yes or No. The editor writes version 1 rules JSON
  (`docs/playlists.md`) and, a quarter of a second after the last change,
  asks `librarySmartPlaylistCount` how many tracks match; when liborca rejects
  the rules, the line shows its reason instead. Create saves with
  `libraryCreateSmartPlaylist` and opens the new playlist; Save on an
  existing one uses `librarySetSmartPlaylistRules`. Opening it on a smart
  playlist reads `librarySmartPlaylistRules` back into the groups.
- **Now Playing** is the audible track's cover, large, over a blurred and
  darkened copy of it, with a Now Playing overline, the title in serif, the
  artist and the album with its year as links, a heart, a more button with
  the track menu, a seek bar and the transport. Clicking the title opens its
  album. Its transport and seek bar are a second set of the player bar's,
  refreshed from the same tick, so both show the same state and either can
  drive playback. Under the transport sit three centred lyric lines: the
  previous line dimmed, the line being heard, and the next. Plain lyrics
  show their first three lines, the page looks lyrics up itself when the
  track changes, the space collapses when the track has none, and clicking
  the lines opens the Lyrics inspector. A 340 px column at the end holds
  Up Next, five queue entries from the audible one with Clear and View Full
  Queue, and Track Info (title, artist, album, date, genre, track number as
  "1 of 16", disc number only when the disc total is above one, and format
  as "FLAC 16-bit / 44.1 kHz"), whose more button opens the track
  inspector. An inspector mode replaces that column; below 900sp the page
  shows only the centre column. With nothing playing it shows a large
  glyph, Nothing playing and Pick an album or press Play. Clicking the
  cover in the player bar opens it.
- **Queue** is the Player's queue as the engine resolves it, under the page
  title, the track count (and length when the whole queue is shown) and Save
  as Playlist… and Clear buttons, in three sections. Now Playing is the
  audible entry on an accent tint: cover, title in the accent colour, artist
  and album, heart and duration. Up Next lists the entries after it with
  their count and length: on hover a drag handle, then the number, a
  thumbnail, the title and artist on one line, the heart, the duration and,
  on hover, a remove button. Activating an entry plays it, and Delete
  removes the focused one. Dragging an entry onto another, or Play Next
  and Play Later in its menu, moves it with `playerQueueMove`; when the
  engine refuses with `QueueEntryInUse`, because the entry or the target is
  already lined up, a toast says so and the page reloads unchanged.
  Previously Played lists `playerQueueHistoryTracks`, newest first, with
  when each was played; it is shown until Hide, which `settings.ini`
  remembers, and Clear History calls
  `playerClearQueueHistory`. Save as Playlist… asks for a name, calls
  `playerSaveQueueAsPlaylist` (the audible entry and everything after it)
  and opens the new playlist.

- **Health** lists what liborca found wrong with the library, with a count in
  the sidebar. The page, titled Library Health, opens with the issue count,
  the same `libraryHealthIssueCount` as the sidebar badge,
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
- The player bar spans the window in three parts. On the left: the cover, the
  title, and the artist and album on one line. In the centre: shuffle,
  previous, play, next and repeat over the seek bar, with elapsed and total
  time in tabular figures. On the right: a button with the codec, the source
  rate and whether the output runs at that rate (such as
  `FLAC • 44.1 kHz • Native`, or `Resampled`; hidden while nothing plays),
  which opens the signal path; under it, what changes the samples, read from
  the same signal path (`RG −3.1 dB •` while ReplayGain is applied, `DSP •`
  while the equalizer or crossfeed changes the signal), then the output
  device's name, which opens the device list; a
  volume slider, whose level is saved as `[playback] volume` once it settles;
  and the queue. Each control is built once and only made insensitive or
  hidden as the state changes, and the three groups fill the bar's height,
  so Tab visits the left group, then the centre, then the right, whether or
  not anything plays. A heart beside the title loves the audible
  track and, pressed again, removes the love; it is read when the audible track
  changes and after any change. Below the 900sp breakpoint the format line
  and what changes the samples are hidden, the device name becomes an icon
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

Each page's header bar is flat and carries no title. A page pushed onto
another, such as an album or artist page, shows a breadcrumb at its start
whose first part returns to the page it was opened from (Albums › ABBA); a
playlist's reads Playlists › its name. The breadcrumb is the only back
control; Alt+← and the mouse back button also return. At the end of every
header sits the library search, `Search your library…` with a Ctrl K hint,
followed by the page's inspector toggles. Below the 900sp breakpoint the
entry becomes a search button that does the same as Ctrl+K. Ctrl+F focuses
the current page's own search (Albums, Artists, Playlists), and on any other
page opens Tracks and focuses its search.

**Command palette.** Focusing the library search, or Ctrl+K, opens a
popover up to 640 × 480 px under it, kept inside the window. Where the header
shows a search button, or on Tracks and the Playlists overview, the popover
carries its own entry. Typed
text goes to `Runtime.librarySearch` (`orca-cli search`) 120 ms after the last
keystroke, and the hits are shown in groups, Tracks, Albums, Artists,
Playlists and Genres, in liborca's order within each; the frontend filters
nothing itself. Text starting with `>` lists only commands; other text also
lists, under Commands, every command whose words each query word begins: Go
to each sidebar page, Open Settings › each tab, Scan library, Analyze
library, Find duplicates, the three inspector toggles, Play/Pause, Next,
Previous, Shuffle on/off, Repeat mode and Save queue as playlist, each with its
shortcut. Each command calls the handler its button or menu item uses. Empty
text shows the last five opened results, kept in memory only. The first row
is selected; Up and Down move, Enter opens (a track plays; an album, artist
or playlist opens its page; a genre opens on Genres), Shift+Enter plays
instead of opening (an artist still opens), and Escape closes. Below
the header, the sidebar's pages open with a title block: the page name in
Newsreader, its count beneath it, and the page's own actions at the end
of that row. Album, artist and playlist pages have their own heading instead.

Below 900sp the album, artist and playlist headings and the Settings columns
stack vertically, the player bar tightens, and a header's actions wrap onto a
second line when they do not fit. Below 760sp the sidebar collapses behind a
back button, the browse panes hide, page titles shrink, and the player bar
stays tightened. Every page fits a 560 px window. Messages are toasts. Shortcuts are listed in the
shortcuts dialog (Ctrl+?); Space and Ctrl+←/→ are handled by a bubble-phase key
controller rather than application accelerators, so a focused search box keeps
them.

**Edit Tags** edits one track or many; a field the selection disagrees on is
marked mixed and left alone unless filled in, and clearing a field returns it
to what the file says. Save changes the library only. Save and Write to Files
plans the write with `Runtime.planTagWrite`, shows each file's changes and any
files skipped, and runs the approved plan as a job; the toast when it finishes
offers Undo (`undoTagWrite`). `libraryEditTracks` returns the Tracks the edited
files back afterwards, because an edit that moves a track to another album
gives it a new id.

**Settings** is a page, opened from the sidebar's foot, the main menu or
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
  grid size (`album_tile`, 112 to 220 px, saved 400 ms after the slider
  stops, on leaving Settings, or on quitting, whichever comes first), Density (`density=comfortable|compact`; compact shortens queue and
  album list rows), Inspector open by default (`inspector_open`, opens the
  details panel at launch) and Reduce animation (`reduce_animation`, which
  turns off `gtk-enable-animations`).
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
Up Next column and shows the playing track.
Three linked toggles at the end of the header show it in one of three modes,
or hide it: the track inspector (`Ctrl+I`), lyrics (`Ctrl+Shift+L`) and the
signal path (`Ctrl+Shift+S`). The mode is shared by every page and saved as `[view] details`,
`lyrics` or `signal_path`; it starts hidden. Below the 1100sp breakpoint the
inspector is laid over the page instead of beside it and starts closed; a
mode opens it, and clicking beside it or Escape closes it without changing
the saved mode. Below 760sp the toggles also become one Panels menu with the
same three modes. The inspector's scrolling area is not a Tab stop. The Tracks inspector shows the first selected track, otherwise
the playing one, and the Loved inspector the selected loved track, otherwise
the playing one; an album page's inspector shows its selected track, otherwise
the playing track when it belongs to the album, otherwise the album: its
title, an Album subtitle, an Overview (artist, date, genres, tracks, duration
and format), Identity (whether a MusicBrainz release is matched, once release
info is stored) and its Description. An artist page's inspector shows the
Artist until a track is selected or the biography is clicked: their name, an
Artist subtitle, an Overview (genres one per line, years active, total
albums and tracks, and how many tracks are in the library), the full Biography with its
licence and a Read more link, Links from `libraryArtistLinks`, each opening
in the browser, and a button that fetches the info again. On an album page a click or
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
Metadata (album artist, album, date, genre, track and disc number as "1 of 13",
compilation, explicit when known, play count and last play in local time,
read again whenever `Runtime.libraryListensRecorded` reports a newly
recorded listen) and File (folder, file name, size, modified and added in
local time, with a copy button for the path in its heading). A track total
counted from the album's tracks rather than read from a tag says so in a
tooltip.

The output is opened on first play, not at launch. `ORCA_OUTPUT_DEVICE` pins it
to an orca device id, overriding the device list; see
[Testing playback without making noise](../CLAUDE.md).

Covers go through `apps/linux/art.zig`. A widget asks for a cover while it is
bound and forgets it when unbound; the frontend asks liborca's artwork loader
(`Runtime.libraryRequestArtwork`) and collects results on its tick, then
decodes each on a GTask thread through `gdk_pixbuf_new_from_stream_at_scale` at
one of three sizes (128, 400 or 960 pixels), so an 11 MiB JPEG never
materializes at full resolution and never decodes on the main thread. Up to
600 decoded covers are kept, least recently used first out; a request for a
widget that scrolled away is cancelled before liborca reads a file. The app
allocates from `std.heap.smp_allocator`: covers are freed as they are
replaced, which an arena would never do.

The frontend owns `org.mpris.MediaPlayer2.orca` on the session bus when one is
available. MPRIS methods invoke the same Player handle, and `PlaybackStatus` is
read from and signaled from authoritative snapshots.

`nix build` installs `share/applications/org.orca_music.Orca.desktop`, the
icon and the two heart icons, so the package can be installed like any desktop
application. At startup `orca-gtk` adds `<exe dir>/../share/icons` to the icon
theme's search path, so the heart icons resolve when `zig-out/bin/orca-gtk`
runs directly, without `XDG_DATA_DIRS`.

The app has its own look rather than the system's: it forces libadwaita's dark
scheme, and `apps/linux/style.css` defines Orca's palette as CSS variables and
maps libadwaita's colour variables onto them, so stock widgets match. The
interface is set in Geist and display titles in Newsreader; Geist Mono is
bundled for monospace text. All are under the SIL Open Font License,
installed with their licences to `share/orca/fonts`, and registered with Pango from
`<exe dir>/../share/orca/fonts` before the window is built; if they are
missing, `orca-gtk` logs a warning and uses system fonts.

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
