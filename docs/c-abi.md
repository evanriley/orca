# C ABI

`liborca/orca.h` exposes opaque runtime ownership, typed generational handles,
POD snapshots, and bounded callback-scoped query views. The header documents
each function. Static and shared libraries install with it.

## Conventions

- Strings and views handed to a callback are valid only during that callback. No
  SQLite row or Zig container crosses the ABI. Callbacks run on the calling
  thread before the call returns and must not re-enter the ABI.
- Every page is bounded to 512 rows. Bulk edits take at most 512 ids.
- Every function returns an `orca_status`. `orca_runtime_create` returning
  `NULL` means out of memory.
- Threading is a contract. All `orca_*` calls for one runtime come from a single
  thread, `orca_runtime_poll_event` included, which is single-consumer. Debug
  builds record the creating thread and return `ORCA_STATUS_WRONG_THREAD` on a
  violation. The runtime behind the boundary is multithreaded and its object
  pools take no lock, so a GUI timer racing `orca_runtime_destroy` is a
  use-after-free. The exceptions are the wake and credential callbacks, which
  liborca calls from its own threads.
- A host embedding liborca follows the process rules in
  [Embedding](#embedding).
- `orca_player_play` is refused unless the Player has a loaded source or a
  non-empty queue and an attached Zone: a transport that reports playing while
  nothing renders is a defect, not a state.
- Events (`orca_runtime_pump`, `orca_runtime_poll_event`) are hints and
  correlations; authoritative consumers read snapshots.

## Embedding

These rules hold for every host, through the C ABI or the Zig API.

- **SQLite locks.** On Linux, liborca replaces the `fcntl` system call of
  SQLite's `unix` VFS so every connection in the process takes open file
  description (OFD) locks. The first
  `orca_runtime_create` (Zig: `Runtime.init`) installs it. The install runs once
  per process, is thread-safe, and later runtimes and Library opens reuse it.
  Destroying a runtime never removes it, so a second runtime, created before or
  after, keeps it.
- **Install before any SQLite connection.** The host creates its first runtime
  before it opens any SQLite connection of its own. The install is refused
  when an open file descriptor of an SQLite database file exists in the
  process: liborca scans `/proc/self/fd` for the database magic. A connection
  to an in-memory database takes no file locks and does not refuse the
  install. A connection to a file never yet written holds the descriptor, but
  the file has no magic and holds no locks, so it does not refuse the install
  either. If the install is refused, liborca leaves `fcntl` unchanged for the
  life of the process, logs a warning, and every Library open fails with
  `ORCA_STATUS_INVALID_STATE` (Zig: `error.SqliteLocksNotInstalled`). The same
  failure follows when the host or another library replaces SQLite's `fcntl`
  afterwards. The host's own connections opened after the install take OFD
  locks too; in rollback-journal mode they can see spurious `SQLITE_BUSY`.
- **Destroy on the creating thread.** `orca_runtime_destroy` follows the
  threading contract like every other call. A Debug build refuses a destroy
  from another thread: it logs a warning and returns, and the runtime stays
  alive and usable on its creating thread. Release builds do not check.
- **AcoustID application key per job.** A matching or submission job resolves
  its application key once, when its AcoustID work begins: the credential
  store's `ORCA_CREDENTIAL_ACCOUNT_CLIENT_KEY` when the store holds a valid one,
  else the key set with `orca_runtime_set_acoustid_client_key` when the job was
  started or queued. Every request of that job uses it. A key set, or a stored
  key changed, while a job runs applies from the next job.

## Errors

After a call that did not return `ORCA_STATUS_OK`,
`orca_runtime_last_error(runtime)` describes it as `"<function>: <reason>"`, for
example `"orca_library_open: path is null"`. The message is for logs, not for
parsing. It is empty after a call that succeeded, holds at most 255 bytes, and
is valid until the next `orca_*` call on that runtime. A call refused with
`ORCA_STATUS_WRONG_THREAD` leaves it unchanged.

## Wakeup

A host sleeps in its own event loop and pumps when liborca wakes it.
`orca_runtime_set_wake_callback` installs the function liborca calls when the
loop should pump. `orca_runtime_pump_timeout` gives the longest the loop may
sleep without it: 0 to pump now, `ORCA_PUMP_NO_TIMEOUT` (-1) to wait for the
callback alone, otherwise at most one second while a Player bound to a Library
plays and 100 ms while a job runs. With an eventfd on Linux:

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

The callback is an exception to the threading contract:

- It is called from liborca's engine, job, listen and artwork threads, and from
  inside `orca_*` calls on the owning thread, sometimes from two threads at
  once. It only signals the host's loop and returns: no `orca_*` call, nothing
  that blocks.
- It is called at most once between two pumps; the pump clears the pending wake.
  A host reads `orca_runtime_pump_timeout` after pumping and draining events,
  immediately before it sleeps, so a wake that arrived during the pump reads as
  0.
- It is never called from an audio render callback, and never after
  `orca_runtime_destroy` returns. The `context` stays valid until then.
- `orca_runtime_set_wake_callback` returns `ORCA_STATUS_INVALID_STATE` once any
  worker thread exists (a Player's engine, a job, a listen worker or an artwork
  loader). Install it right after `orca_runtime_create`. `NULL` removes it under
  the same rule.

## Credentials

liborca keeps no token or key in a Library, a log or a cache key. It asks the
host's secure store through the credential callback
(`orca_runtime_set_credential_callback`) each time it needs one: the
ListenBrainz user token (`ORCA_CREDENTIAL_SERVICE_LISTENBRAINZ`,
`ORCA_CREDENTIAL_ACCOUNT_USER_TOKEN`) and the AcoustID user and application keys
(`ORCA_CREDENTIAL_SERVICE_ACOUSTID`, `ORCA_CREDENTIAL_ACCOUNT_USER_KEY` or
`ORCA_CREDENTIAL_ACCOUNT_CLIENT_KEY`).

The callback writes the secret into liborca's buffer of
`ORCA_CREDENTIAL_MAX_BYTES` and returns an `orca_credential_result`:

- `FOUND`, with the length written. A length above the capacity is treated as
  `TOO_LARGE`; liborca never truncates a secret.
- `NOT_FOUND` when the store holds none. That is absence: scrobbling waits for a
  token.
- `UNAVAILABLE` when the store cannot answer, such as a locked keyring, and
  `TOO_LARGE` when the secret does not fit. The listen worker treats both as
  errors: it reports the error and asks again later. AcoustID jobs treat both as
  absence: a lookup uses the application key, and a submission reports that it
  needs a user key.

liborca zeroes the buffer before freeing it. The callback is the second
exception to the threading contract:

- It is called from liborca's listen and job threads, sometimes from two at
  once, so it is thread-safe. It calls no `orca_*` function. It may block on the
  store, which delays whatever waits for that thread, `orca_runtime_destroy`
  included.
- It is never called after `orca_runtime_destroy` returns, and `context` stays
  valid until then.
- `orca_runtime_set_credential_callback` returns `ORCA_STATUS_INVALID_STATE`
  once any worker thread exists, as the wake callback does. To have liborca read
  a token the host has changed, the host calls
  `orca_library_scrobbler_credentials_changed`.

## Versions and compatibility

`orca_version()` returns liborca's version, such as `"0.1.0"`.
`ORCA_ABI_VERSION` in `orca.h` is the C ABI's version, separate from it; the
rules it follows are in [Stability](api.md#stability). The shared library's
SONAME carries the ABI version:

```text
lib/liborca.so.0.0.0
lib/liborca.so.0 -> liborca.so.0.0.0
lib/liborca.so   -> liborca.so.0
```

- A struct that needs more fields gets a `_v2` that holds the old one as `base`,
  read through a new `_v2` function; a later extension is `_v3`.
- `liborca.so` exports exactly the functions `orca.h` declares. A version script
  hides everything else, and `zig build test` fails when the two differ
  (`scripts/check-exports.sh`).
- `tests/abi/orca-VERSION.h` is the header as each release shipped it.
  `zig build test` (and `zig build abi-compat` alone) fails when `orca.h`
  changes the size, alignment or a non-reserved field offset of any struct in
  one of them, the value of any enum constant or define, or the parameters of
  any function, or when liborca stops providing one.
- The check compares layout, not meaning. A reserved field that gains a name
  keeps zero as "behave as before", and the CHANGELOG lists the change under
  Changed. A host built against the older header zeroes the field.
- `orca.h` compiles as C11 with `-Wall -Wextra -Werror -pedantic` and as C++17
  with `-Wall -Wextra -Werror`. In C++ the three `explicit` fields are named
  `explicit_`, because `explicit` is a keyword there. The layout is the same.
- `scripts/check-abi-coverage.sh`, which `zig build test` runs, fails when a
  public `Runtime` method has no C ABI path and no stated reason for having
  none; that list of reasons is the record of what the C ABI leaves out.

## Linking

`zig build` installs `lib/pkgconfig/orca.pc` beside the libraries, with the
header at `include/orca/orca.h`:

```c
#include <orca/orca.h>
```

Shared library:

```sh
cc host.c $(pkg-config --cflags --libs orca)
```

Static library. The linker prefers `liborca.so` when both libraries sit in one
directory, so `-Bstatic` selects `liborca.a`. The Nix package installs no
`liborca.a`; a static link needs a [source build](install.md#build-and-install):

```sh
cc host.c $(pkg-config --cflags orca) -Wl,-Bstatic -lorca -Wl,-Bdynamic \
  $(pkg-config --static --libs orca | sed 's/-lorca//')
```

The static link needs the libraries `orca.pc` lists: SQLite, libFLAC,
libopusfile, libvorbisfile, libsamplerate, PipeWire, `-lm` and LLVM's libc++
(`-lc++`) for the ALAC and Chromaprint code. libstdc++ does not provide the
symbols liborca uses; install `libc++` on Arch, `libcxx-devel` on Fedora or
`libc++-dev` on Debian and Ubuntu. Set `PKG_CONFIG_PATH` to the install's
`lib/pkgconfig` when it is not a system prefix.

`liborca.so` exports only `orca_` symbols. `liborca.a` also defines the global
symbols of the code compiled into it: libxaac (`ixheaacd_*`, `ixheaac_*`),
Chromaprint (`chromaprint_*` and its C++ symbols), KissFFT (`kiss_*`), QOA
(`qoa_*`) and ALAC (`BitBuffer*` and its C++ symbols). A host that links its
own copy of one of these beside `liborca.a` gets duplicate-symbol errors; link
`liborca.so` in that case.

## Surface

Each area lists its entry points; the header documents their arguments,
structs, enums and status codes. The Zig counterparts are in
[the Zig API](api.md#surface). Every page is bounded; lists in a view are valid
only inside its callback.

- Events and wakeup: `orca_runtime_pump`, `orca_runtime_poll_event` (a lossless
  completion channel and a coalescing telemetry channel) and
  `orca_runtime_pump_timeout`.
- Library and roots: `orca_library_open`, `orca_library_add_root`,
  `orca_library_remove_root`, `orca_library_query_roots_v2`,
  `orca_library_relocate_root` and `orca_library_missing_file_count`. A root
  path is absolute.
- Folders: `orca_library_query_folder` and `orca_player_play_folder`.
- Health: `orca_library_query_health_items`,
  `orca_library_query_health_items_of_kind`, `orca_library_health_summary_v2`,
  `orca_library_health_file`, `orca_library_dismiss_health_issue` and
  `orca_library_restore_health_issue`.
- Stats, cache and sources: `orca_library_stats_v2`,
  `orca_library_cache_size`, `orca_library_clear_cache` and
  `orca_provider_sources`.
- Browsing: `orca_library_browse_artists`, `orca_library_browse_releases_v2`,
  `orca_library_browse_tracks_v2`, `orca_library_artist_count_matching_v2`,
  `orca_library_release_count_matching_v2`,
  `orca_library_track_match_count_v2`, `orca_library_query_artists_v2` and
  `orca_library_artist_totals`.
- Search and details: `orca_library_search`, `orca_library_track_get`,
  `orca_library_track_details_v3`, `orca_library_track_play_stats`,
  `orca_library_track_audio_features`, `orca_library_listens_recorded`,
  `orca_library_unanalyzed_count`, `orca_library_analysis_coverage` and
  `orca_library_backfill_pending`.
- Audio embeddings: `orca_runtime_set_embedding_model_path`,
  `orca_runtime_embedding_model_state`, `orca_runtime_embedding_model`,
  `orca_library_similar_tracks` and
  `orca_runtime_start_embedding_model_download`, a Job of kind
  `ORCA_JOB_KIND_MODEL_DOWNLOAD` that belongs to no Library. It needs a client
  identity and returns `ORCA_STATUS_UNSUPPORTED` in a build with
  `-Dembeddings=false`.
- Radio and discovery: `orca_library_radio_preview`,
  `orca_library_discovery_settings`, `orca_library_set_discovery_settings` and
  `orca_library_recording_get`.
- Library Radio: `orca_player_start_radio`, `orca_player_stop_radio`,
  `orca_player_set_radio_options`, `orca_player_radio_less_like_this`,
  `orca_player_radio_undo_feedback`, `orca_player_radio_status` and
  `orca_player_radio_picks`.
- Daily Mixes: `orca_library_start_daily_mixes`, `orca_library_daily_mixes`,
  `orca_library_daily_mix_entries`, `orca_library_not_for_me`,
  `orca_library_clear_not_for_me`, `orca_library_reset_recommendations` and
  `orca_library_save_daily_mix`.
- Home page queries: `orca_library_listening_week`,
  `orca_library_recent_releases`, `orca_library_rediscover`,
  `orca_library_never_played`, `orca_library_deep_cuts`,
  `orca_library_unplayed_releases`, `orca_library_release_anniversaries`,
  `orca_library_top_artists`, `orca_library_formats`,
  `orca_library_on_this_day` and `orca_library_history_age`. Each takes `now_s`
  and `utc_offset_s` where the answer depends on the date.
- Listening: `orca_library_set_listen_policy`,
  `orca_library_set_listen_recording`, `orca_library_clear_listens`,
  `orca_library_set_feedback`, `orca_library_set_rating`,
  `orca_library_set_release_love` and `orca_library_set_artist_love`.
- Playlists: `orca_library_query_playlists`, `orca_library_create_playlist`,
  `orca_library_rename_playlist`, `orca_library_delete_playlist`,
  `orca_library_query_playlist_entries`, `orca_library_playlist_insert`,
  `orca_library_playlist_remove`, `orca_library_playlist_move`,
  `orca_library_import_playlist`, `orca_library_export_playlist` and
  `orca_player_play_playlist`.
- Artwork: `orca_library_track_artwork` and `orca_library_release_artwork` read
  on the calling thread; a UI uses `orca_library_request_artwork`,
  `orca_library_take_artwork` and `orca_library_cancel_artwork`, draining
  `take` after each wake until `ORCA_STATUS_NOT_FOUND`. At most 64 requests are
  outstanding per Library; past that a request is `ORCA_STATUS_BUSY`.
- Lyrics: `orca_library_start_lyrics`, `orca_job_lyrics_outcome` and
  `orca_job_lyrics`. The lyrics are taken once.
- Artist info: `orca_library_start_artist_info`, `orca_job_artist_info_stores`,
  `orca_job_artist_info_outcome`, `orca_library_artist_info`,
  `orca_library_artist_photo`, `orca_library_artist_links` and
  `orca_library_related_artist_photo`. The start call needs a client identity.
- Tag edits and writes: `orca_library_edit_tracks`,
  `orca_library_plan_tag_write`, `orca_library_query_tag_write_genres`,
  `orca_library_start_tag_write`, `orca_library_discard_tag_write`,
  `orca_library_undo_tag_write`, `orca_library_prune_tag_write_backups`,
  `orca_library_query_tag_write_groups`, `orca_library_query_tag_write_group`
  and `orca_library_export_tag_write_history`. An edit writes no file; a write
  needs the plan's approval digest and is a journaled
  `ORCA_JOB_KIND_MUTATION` job.
- Jobs: `orca_library_start_scan`, `orca_library_start_projection`,
  `orca_library_start_reconcile`, `orca_library_start_analysis`,
  `orca_job_snapshot_get`, `orca_job_cancel`, `orca_library_scan_stats_v3`,
  `orca_job_origin_get` and `orca_job_reconcile_root`.
- Watching and maintenance: `orca_library_watch`, `orca_library_unwatch`,
  `orca_library_watch_status` (`ORCA_STATUS_UNSUPPORTED` off Linux),
  `orca_library_set_maintenance` and `orca_library_maintenance_status`.
  Reconciles and maintenance units start from `orca_runtime_pump` as jobs the
  host never started.
- Transport and queue: `orca_player_play`, `orca_player_pause`,
  `orca_player_seek_ms`, `orca_player_next`, `orca_player_previous`,
  `orca_player_status_get_v3`, `orca_player_queue_jump`,
  `orca_player_queue_insert_next`, `orca_player_queue_remove`,
  `orca_player_queue_move`, `orca_player_query_queue_tracks`,
  `orca_player_query_queue_history` and `orca_player_save_queue_as_playlist`.
- Saved playback: `orca_player_restore_state`, `orca_player_save_state` and
  `orca_player_set_long_track_memory`.
- Sound: `orca_player_set_equalizer`, `orca_player_set_parametric_equalizer`,
  `orca_player_set_crossfeed`, `orca_player_set_replay_gain_mode`,
  `orca_player_set_replay_gain_preamp`, `orca_player_set_replay_gain_fallback`,
  `orca_player_replay_gain_settings`, `orca_player_set_peak_protection`,
  `orca_player_set_stop_after_current` and `orca_player_signal_path_v2`. A
  signal path is `bit_perfect_eligible` only when confirmed; a frontend
  presents `ORCA_SIGNAL_REASON_PATH_UNKNOWN` as unconfirmed, never as
  bit-perfect. `orca_parametric_equalizer_response`,
  `orca_parametric_equalizer_parse_apo` and
  `orca_parametric_equalizer_write_apo` take no runtime and work from any
  thread.
- Devices and Zones: `orca_enumerate_output_devices_v3`, `orca_zone_create`,
  `orca_zone_attach_player`, `orca_zone_open_output`, `orca_zone_close_output`
  and `orca_zone_status_get`. `orca_player_open_default_output` does all four
  so a single-output frontend never handles Zones.
- Providers: `orca_runtime_set_client_identity`,
  `orca_runtime_set_provider_server` (`https`, or `http` to `127.0.0.1` or
  `localhost` only; `NULL` restores the public server),
  `orca_runtime_set_acoustid_client_key` and
  `orca_runtime_set_credential_callback`.
- Scrobbling: `orca_library_set_scrobbling`, `orca_library_scrobbler_status`
  and `orca_library_scrobbler_credentials_changed`. At most one Library per
  runtime scrobbles; a second is `ORCA_STATUS_INVALID_STATE`.
- Matching: `orca_library_start_match`, `orca_library_start_cover_art_fetch`,
  `orca_job_match_stats`, `orca_job_match_stats_v2`, `orca_job_match_release`,
  `orca_library_query_match_review`, `orca_library_query_match_proposals`,
  `orca_library_accept_match`, `orca_library_dismiss_match`,
  `orca_library_accept_confident_matches`, `orca_library_apply_release`,
  `orca_library_apply_matched_release_fields`,
  `orca_library_query_release_matches_v2`,
  `orca_library_release_match_counts_v2`,
  `orca_library_release_match_bucket`, `orca_library_release_alignment`,
  `orca_library_pair_release_track`, `orca_library_unpair_release_track`,
  `orca_library_mark_release_reviewed`, `orca_library_query_correction_groups`
  and `orca_library_track_verification`. A second match job while one runs is
  `ORCA_STATUS_BUSY`. Pairing and Apply reproject, so Track and Release ids may
  change: query again. Acceptance writes the Library, never a file.
- AcoustID submission: `orca_library_start_acoustid_submission`,
  `orca_job_submission_stats`, `orca_library_acoustid_submittable_count`,
  `orca_library_acoustid_submitted_count` and
  `orca_library_query_acoustid_submittable`. It cannot run beside a matching
  job.

## Listening from a host

A host that wants listening history and scrobbling does the following:

1. Installs the credential callback ([Credentials](#credentials)) over the
   platform's secure storage. It never prompts or blocks on user interaction:
   a locked keyring reads as `UNAVAILABLE`.
2. Calls `orca_runtime_set_client_identity` to name the host in submissions.
   Scrobbling cannot be turned on before it is set; see
   [Client identity](api.md#client-identity).
3. Calls `orca_runtime_set_provider_server` only to select a self-hosted or
   compatible ListenBrainz server.
4. Calls `orca_library_set_scrobbling` (its last argument turns Now Playing on),
   `orca_library_scrobbler_credentials_changed` after the token changes, and
   `orca_library_scrobbler_status` for presentation.
5. Calls `orca_library_set_feedback` for love and hate and
   `orca_library_set_release_love` for album love, which is never sent.

The identity and the server are copied. The setters may be called at any time
and reach each listen worker on its next pass; a host that sets them before
binding a Player to a Library avoids a first pass with the defaults. Listens
are sampled while the host pumps. The Zig API takes the same steps; see
[Listening from a host](api.md#listening-from-a-host).
