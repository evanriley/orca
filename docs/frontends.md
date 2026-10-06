# Native frontend boundary

This file covers how a native frontend or other host reaches liborca: the C ABI
in `liborca/orca.h`, the Linux GTK frontend, and the Zig calls a host makes for
listening history. First-party applications are thin clients of `liborca`. They
own windows, accessibility, and native event loops; library, transport,
metadata, and mutation semantics remain in the core.

## C ABI

`liborca/orca.h` exposes opaque runtime ownership, typed generational handles,
POD snapshots, and bounded callback-scoped query views. The header documents
each function. Static and shared libraries install with it.

### Conventions

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

### Embedding

These rules hold for every host, through the C ABI or the Zig API.

- **SQLite locks.** On Linux, liborca replaces the `fcntl` system call of
  SQLite's `unix` VFS so every connection in the process takes open file
  description (OFD) locks; see
  [database.md](database.md#process-wide-lock-replacement). The first
  `orca_runtime_create` (Zig: `Runtime.init`) installs it. The install runs once
  per process, is thread-safe, and later runtimes and Library opens reuse it.
  Destroying a runtime never removes it, so a second runtime, created before or
  after, keeps it.
- **Install before any SQLite connection.** The host creates its first runtime
  before it opens any SQLite connection of its own. If a connection is open
  when the install runs, liborca leaves `fcntl` unchanged for the life of the
  process, logs a warning, and every Library open fails with
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

### Errors

After a call that did not return `ORCA_STATUS_OK`,
`orca_runtime_last_error(runtime)` describes it as `"<function>: <reason>"`, for
example `"orca_library_open: path is null"`. The message is for logs, not for
parsing. It is empty after a call that succeeded, holds at most 255 bytes, and
is valid until the next `orca_*` call on that runtime. A call refused with
`ORCA_STATUS_WRONG_THREAD` leaves it unchanged.

### Wakeup

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

[control-plane.md](control-plane.md#waking-the-host) lists what wakes the host
and what the timeout covers.

### Credentials

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

### Versions and compatibility

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
- `tests/abi/orca-0.1.0.h` is the baseline header. `zig build test` (and `zig
  build abi-compat` alone) fails when `orca.h` changes the size, alignment or a
  non-reserved field offset of any struct in it, the value of any of its enum
  constants or defines, or the parameters of any of its functions, or when
  liborca stops providing one of them (`tests/abi/compat.zig`).
- `scripts/check-abi-coverage.sh`, which `zig build test` runs, fails when a
  public `Runtime` method has no C ABI path and no stated reason for having
  none. Its list of reasons is the record of what the C ABI leaves out.

### Linking

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
directory, so `-Bstatic` selects `liborca.a`:

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

### Surface

Each area lists its main entry points. Details, structs and enums are in the
header; the Zig counterparts are in [api.md](api.md#surface).

- Library and roots: `orca_library_open`, `orca_library_add_root`,
  `orca_library_remove_root`, `orca_library_query_roots_v2`,
  `orca_library_relocate_root`, `orca_library_missing_file_count`. A root path
  is absolute. Removing a root also forgets the Recordings only its files held,
  with their loves, ratings, play counts and playlist entries; listens stay.
  Relocating keeps ids and the undo of tag writes and returns the reconcile job
  it starts. A bad path or a nested root is `ORCA_STATUS_INVALID_ARGUMENT`, an
  unknown root `ORCA_STATUS_NOT_FOUND`, a held journal, another process walking
  the Library or an unfinished tag write `ORCA_STATUS_BUSY`, and one awaiting
  reconciliation `ORCA_STATUS_NEEDS_RECONCILIATION`.
- Folders: `orca_library_query_folder` (path relative to the root, `""` for the
  root; a `.`, `..` or empty component, a leading `/` or a NUL is
  `ORCA_STATUS_INVALID_ARGUMENT`; images are `ORCA_FOLDER_ENTRY_KIND_IMAGE` with
  no ids) and `orca_player_play_folder` (`ORCA_STATUS_INVALID_STATE` without a
  bound Library).
- Health: `orca_library_query_health_items`,
  `orca_library_query_health_items_of_kind`, `orca_library_health_summary_v2`,
  `orca_library_health_file`, `orca_library_dismiss_health_issue`,
  `orca_library_restore_health_issue`. Dismissing hides an issue until its
  file's bytes change; summaries leave dismissed issues out.
- Stats, cache and sources: `orca_library_stats_v2`, `orca_library_cache_size`,
  `orca_library_clear_cache`, `orca_provider_sources`.
- Browsing: `orca_library_browse_artists`, `orca_library_browse_releases_v2`,
  `orca_library_browse_tracks_v2` with `orca_library_artist_count_matching_v2`,
  `orca_library_release_count_matching_v2` and
  `orca_library_track_match_count_v2`, `orca_library_query_artists_v2`,
  `orca_library_artist_totals`. Track `text` searches by relevance and the count
  call rejects non-empty `text` with `ORCA_STATUS_INVALID_ARGUMENT`.
- Search and details: `orca_library_search` (hits grouped by kind, at most 50
  per kind through `orca_search_limits`, text at most 256 bytes),
  `orca_library_track_get`, `orca_library_track_details_v3`,
  `orca_library_track_play_stats`, `orca_library_listens_recorded`,
  `orca_library_unanalyzed_count`, `orca_library_backfill_pending`.
- Listen settings: `orca_library_set_listen_policy`,
  `orca_library_set_listen_recording`, `orca_library_clear_listens` (keeps
  ratings and loves).
- Love and ratings: `orca_library_set_feedback`, `orca_library_set_rating` (1 to
  100, 0 clears), `orca_library_set_release_love`,
  `orca_library_set_artist_love`. Release and artist love are never sent.
- Playlists: `orca_library_query_playlists`, `orca_library_create_playlist`,
  `orca_library_rename_playlist`, `orca_library_delete_playlist`,
  `orca_library_query_playlist_entries`, `orca_library_playlist_insert`,
  `orca_library_playlist_remove`, `orca_library_playlist_move`,
  `orca_library_import_playlist`, `orca_library_export_playlist`
  (`ORCA_STATUS_INVALID_STATE` for an existing file unless `replace`),
  `orca_player_play_playlist`.
- Artwork: `orca_library_track_artwork`, `orca_library_release_artwork` read on
  the calling thread; a UI uses `orca_library_request_artwork`,
  `orca_library_take_artwork` and `orca_library_cancel_artwork`. The host drains
  `take` after each wake until `ORCA_STATUS_NOT_FOUND`. At most 64 requests are
  outstanding per Library, finished ones not yet taken included; past that a
  request is `ORCA_STATUS_BUSY`.
- Lyrics: `orca_library_start_lyrics`, `orca_job_lyrics_outcome`,
  `orca_job_lyrics`. The lyrics are taken once; a second call is
  `ORCA_STATUS_NOT_FOUND`.
- Artist info: `orca_library_start_artist_info`, `orca_job_artist_info_stores`,
  `orca_job_artist_info_outcome`, `orca_library_artist_info`,
  `orca_library_artist_photo`, `orca_library_artist_links`,
  `orca_library_related_artist_photo`. Both start calls need a client identity.
  See [providers.md](providers.md#artist-info).
- Tag edits and writes: `orca_library_edit_tracks` (at most 64 fields of at most
  512 Tracks, locked as the user's; no file is written),
  `orca_library_plan_tag_write`, `orca_library_query_tag_write_genres`,
  `orca_library_start_tag_write` (needs the plan's approval digest; an
  uncancellable `ORCA_JOB_KIND_MUTATION` job with a journaled backup),
  `orca_library_discard_tag_write`, `orca_library_undo_tag_write`
  (`ORCA_STATUS_ALREADY_DONE`, `ORCA_STATUS_NEEDS_RECONCILIATION`, or
  `ORCA_STATUS_GONE` after `orca_library_prune_tag_write_backups`),
  `orca_library_query_tag_write_groups`, `orca_library_query_tag_write_group`,
  `orca_library_export_tag_write_history`. A Library with no database file
  refuses writes with `ORCA_STATUS_INVALID_STATE`. See
  [metadata.md](metadata.md).
- Jobs: `orca_library_start_scan`, `orca_library_start_projection`,
  `orca_library_start_reconcile`, `orca_library_start_analysis`,
  `orca_job_snapshot_get`, `orca_job_cancel`, `orca_library_scan_stats_v3`,
  `orca_job_origin_get`, `orca_job_reconcile_root`. Scan progress has `has_total
  = 0` until the count of files is done. See [analysis.md](analysis.md#threads).
- Watching: `orca_library_watch`, `orca_library_unwatch`,
  `orca_library_watch_status`; `ORCA_STATUS_UNSUPPORTED` off Linux. Reconciles
  start from `orca_runtime_pump`, report `ORCA_EVENT_JOB_FINISHED` with handles
  the host never started, and one that recorded or marked missing a file posts
  `ORCA_EVENT_LIBRARY_CHANGED`. See [storage.md](storage.md#watching-roots).
- Events: `orca_runtime_pump`, `orca_runtime_poll_event` (lossless completion
  channel and coalescing telemetry channel, one tagged POD with a named `extern
  union`), `orca_runtime_pump_timeout`.
- Transport and queue: `orca_player_play`, `orca_player_pause`,
  `orca_player_seek_ms`, `orca_player_next`, `orca_player_previous`,
  `orca_player_status_get_v3` (one lock-free read; position from the audible
  entry, never the decode cursor), `orca_player_queue_jump`,
  `orca_player_queue_insert_next`, `orca_player_queue_remove`,
  `orca_player_queue_move`, `orca_player_query_queue_tracks`,
  `orca_player_query_queue_history`, `orca_player_save_queue_as_playlist`.
  `orca_player_query_queue_tracks` calls back once per queue position from
  `offset`, reading each entry from the Library it was queued from, and
  `orca_player_query_queue_history` once per history entry from `offset`. An
  entry whose Track left its Library, or whose Library is closed, sets
  `orca_track_view.removed` and carries only its `id`. The entry playing and
  the one lined up after it cannot be removed or moved
  (`ORCA_STATUS_INVALID_STATE`). A Track on an unavailable root fails with
  `ORCA_FAILURE_TRACK_FOLDER_UNAVAILABLE`.
- Saved playback: `orca_player_restore_state`, `orca_player_save_state`,
  `orca_player_set_long_track_memory`. After either state call the runtime saves
  the queue every 30 seconds from `orca_runtime_pump` while playing and in
  `orca_runtime_destroy`.
- Sound: `orca_player_set_equalizer`, `orca_player_set_parametric_equalizer`,
  `orca_player_set_crossfeed`, `orca_player_set_replay_gain_mode`,
  `orca_player_set_replay_gain_preamp`, `orca_player_set_replay_gain_fallback`,
  `orca_player_replay_gain_settings`, `orca_player_set_peak_protection`,
  `orca_player_set_stop_after_current`, `orca_player_signal_path_v2`. The
  parametric equalizer and the ten-band one exclude each other. A signal path
  is `bit_perfect_eligible` only when it is confirmed;
  `ORCA_SIGNAL_REASON_PATH_UNKNOWN` marks one with no declared source format,
  no open output, or a device that has not reported its rate or format, and a
  frontend presents it as unconfirmed, never as bit-perfect.
  `ORCA_SIGNAL_REASON_SAMPLE_PROCESSING` can stand while every setting reads
  neutral, until audio processed under earlier settings has played. The
  `orca_parametric_equalizer_response`, `orca_parametric_equalizer_parse_apo`
  and `orca_parametric_equalizer_write_apo` calls take no runtime and work from
  any thread; the `ORCA_PARAMETRIC_*` defines state the ranges.
- Devices and Zones: `orca_enumerate_output_devices_v3`, Zone calls
  `orca_zone_create`, `orca_zone_attach_player`, `orca_zone_open_output`,
  `orca_zone_close_output` and `orca_zone_status_get`, and
  `orca_player_open_default_output`, which does all four so a single-output
  frontend never handles Zones.
- Providers: `orca_runtime_set_client_identity`,
  `orca_runtime_set_provider_server` (`https`, or `http` to `127.0.0.1` or
  `localhost` only; `NULL` restores the public server),
  `orca_runtime_set_acoustid_client_key`,
  `orca_runtime_set_credential_callback`.
- Scrobbling: `orca_library_set_scrobbling`, `orca_library_scrobbler_status`,
  `orca_library_scrobbler_credentials_changed`. At most one Library per runtime
  scrobbles; a second is `ORCA_STATUS_INVALID_STATE`. See [Listening from a
  host](#listening-from-a-host).
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
  `orca_library_mark_release_reviewed`, `orca_library_query_correction_groups`,
  `orca_library_track_verification`. A second match job while one runs is
  `ORCA_STATUS_BUSY`. `orca_release_match_view_v2.candidate_unread` is 1 while
  the best candidate is a release a Track's release ID names and Orca has not
  read; the item is then in `ORCA_RELEASE_MATCH_BUCKET_NEEDS_REVIEW` with
  `confidence` 0, which is no measure, and `candidate_title` is the
  Release's title. Without a tracklist snapshot, an already paired release
  track or a Release not wholly placed the calls return
  `ORCA_STATUS_INVALID_STATE`; a Release past 512 Tracks is
  `ORCA_STATUS_UNSUPPORTED`; an unknown id is `ORCA_STATUS_NOT_FOUND`; an unpair
  or unmark with nothing to remove is `ORCA_STATUS_ALREADY_DONE`. Pairing and
  Apply reproject, so Track and Release ids may change: query again. Acceptance
  writes the library, never a file.
- AcoustID submission: `orca_library_start_acoustid_submission`,
  `orca_job_submission_stats`, `orca_library_acoustid_submittable_count`,
  `orca_library_acoustid_submitted_count`,
  `orca_library_query_acoustid_submittable`. It cannot run beside a matching
  job. A missing user key is `ORCA_SUBMISSION_OUTCOME_NEEDS_USER_KEY`; a
  credential callback answering `UNAVAILABLE` or `TOO_LARGE` is
  `ORCA_SUBMISSION_OUTCOME_CREDENTIAL_UNAVAILABLE`.
- Idle maintenance: `orca_library_set_maintenance`,
  `orca_library_maintenance_status`. Units start from `orca_runtime_pump` as
  `ORCA_JOB_KIND_METADATA_LOOKUP` jobs the host never started. See
  [control-plane.md](control-plane.md#idle-maintenance).

## orca-gtk

`orca-gtk` is the Linux frontend: a Zig client of liborca's public Zig API on
GTK 4 (4.18 or newer) and libadwaita (1.8 or newer), both bound by hand in
`apps/linux/gtk.zig` and `apps/linux/adw.zig`. Every liborca call happens on the
GTK main thread, from a signal handler or the tick, which pumps the runtime when
liborca's waker writes the app's eventfd or the `nextPumpTimeoutMs` timeout
expires. The application id is `org.orca_music.Orca`. The appearance is dark
only, forced through libadwaita's style manager over `apps/linux/style.css`.

The signal path views word liborca's verdict and never make their own. A path
whose only reason is `path_unknown` reads Unconfirmed, not Bit-perfect.
Processing that stands after every setting returned to neutral reads as
processed audio still playing. While a view is on screen and playback runs, it
re-reads the path every 250 ms until that processing clears. It also re-reads
it up to eight times after an output starts or the popover opens while the
device has not reported its rate or format.

The Queue page shows an entry whose Track left the Library as "Removed from
library", dimmed, in its own position in Up Next and History, and Now Playing
does the same in its Up Next list. Its Up Next menu offers only Remove from
Queue and Save Queue as Playlist…; it has no Track menu, Play Next or Love, and
activating it does not play.

Run it from the tree:

```sh
zig build run-linux                                   # the active library in settings.ini
ORCA_LIBRARY=/path/to/library.db zig build run-linux  # another library, for this run only
```

### Installed files

`zig build` installs `orca-gtk` and, under the prefix:

- `share/applications/org.orca_music.Orca.desktop` and the application icon
  `share/icons/hicolor/scalable/apps/org.orca_music.Orca.svg`;
- the interface's symbolic icons in `share/icons/hicolor/scalable/actions`;
- Geist, Geist Mono and Newsreader in `share/orca/fonts`, each beside its SIL
  Open Font License text (`*-OFL.txt`). `orca-gtk` registers them with Pango
  from `<exe dir>/../share/orca/fonts`; when they are missing it logs a warning
  and uses system fonts;
- the third-party licence texts in `share/doc/orca/licenses`.

`orca-gtk` finds fonts, icons and licences relative to its executable, so an
install keeps `bin` and `share` under one prefix.
`zig build -Dgtk=false` builds neither `orca-gtk` nor these files, for systems
whose GTK, libadwaita or Pango is older than `orca-gtk` needs.

### Libraries and settings

`$XDG_CONFIG_HOME/orca/settings.ini` holds only the frontend's own choices.
Nothing inside a library is kept there, and secrets live in the Secret Service.
Its `[libraries]` group lists the libraries `orca-gtk` can open: `paths` and
`names` are parallel string lists, `tracks` the last known track count of each
(`-` when unknown), and `active` the index opened at launch. A library's name
lives in this list; liborca knows only the open database. With no list yet, the
first launch lists `$XDG_DATA_HOME/orca/library.db` as Main and creates its
folder. When the active library's file is gone, the launch opens the first
listed library that still exists, and Settings names the one it could not open.

When no library is open, because the active one is corrupt, made by a newer
Orca or unreadable, every page except Settings shows the failure in place of
its content: the library's name, the reason, and Choose Library… and Create
Library…, which open the Libraries dialog and the new-library file dialog.
Settings stays reachable and its Libraries card repeats the failure. Add Music
Folder, Scan Library and the palette's library commands are unavailable until
a library opens.

`ORCA_LIBRARY` overrides the list for one run: its library is active and listed
as from `ORCA_LIBRARY`, but it is never saved and the saved `active` stays as it
was, unless the user switches to a listed library during the run.

Switching libraries while the runtime lives follows the order in [Replacing the
open Library](api.md#replacing-the-open-library).

Other environment variables are development aids: `ORCA_OUTPUT_DEVICE` pins an
output device id from `orca-cli devices`, which overrides the device drop-down;
`ORCA_GTK_DEBUG` takes a comma-separated list of `art`, `frames` and `reveal`;
and `ORCA_LISTENBRAINZ_URL`, `ORCA_MUSICBRAINZ_URL`, `ORCA_ACOUSTID_URL`,
`ORCA_COVERARTARCHIVE_URL` and `ORCA_LRCLIB_URL` point a provider at another
server, such as a local mock.

### Secrets

Provider credentials live in the desktop's Secret Service through libsecret
(`apps/linux/secret.zig`): the ListenBrainz user token and the AcoustID user
key, under the schema `org.orca.ListenBrainz` with `service` and `account`
attributes. They are stored nowhere else. libsecret is LGPL, so it is linked
into this frontend only. Worker threads search the Secret Service without
unlocking it, so a locked keyring reads as no credential; saving, removing and
checking a credential run on the main loop, where an unlock prompt is
acceptable. See [Listening from a host](#listening-from-a-host).

### Desktop integration

- MPRIS: `orca-gtk` owns `org.mpris.MediaPlayer2.orca` on the session bus and
  serves `org.mpris.MediaPlayer2` and `org.mpris.MediaPlayer2.Player`
  (`apps/linux/mpris.zig`).
- Open at login writes `$XDG_CONFIG_HOME/autostart/org.orca_music.Orca.desktop`.

### Screenshots

`scripts/headless-gui.sh` screenshots `orca-gtk` at 1440x900 without putting a
window on the desktop. It runs `orca-gtk` in a private headless sway session
with a private `XDG_RUNTIME_DIR`, a private D-Bus daemon, scratch `HOME` and XDG
directories, every provider URL pointed at a closed local port, and output
pinned to `scripts/silent-sink.sh 1`. It aborts unless that device is the
virtual Orca Silent Test Sink. On exit it signals only the processes it started,
after checking that `/proc/PID/environ` carries its runtime directory, and
reports any other process left there.

```sh
zig build
scripts/headless-gui.sh albums /tmp/albums.png
scripts/headless-gui.sh albums /tmp/palette.png key:ctrl+k type:scan wait:500
```

The first argument is the page (`albums`, `artists`, `tracks`, `genres`,
`folders`, `loved`, `playlists`, `now-playing`, `queue`, `health`, `matches` or
`settings`). The steps after the output path (`key:`, `type:`, `move:`,
`click:`, `dclick:`, `rclick:`, `drag:`, `scroll:`, `wait:`, `shot:`, `tree:`,
`log:`, `db:` and `close`) run in order; the header of the script documents
each. The PNG is written once two consecutive frames match.

The library is `ORCA_LIBRARY` when set, else `fixtures/library/design.db`, which
`scripts/design-fixture.sh` builds when missing or when this build cannot
open it. The app opens a copy named `Main.db`, so a run never changes it. With
`ORCA_HEADLESS_LIBRARY=settings` and `ORCA_HEADLESS_CONFIG`, the app opens in place the library that directory's
`orca/settings.ini` chooses, and the `db:` step is refused. Settings start empty
and are discarded with the session; set `ORCA_HEADLESS_CONFIG` to a directory to
keep them as `XDG_CONFIG_HOME` across runs. `ORCA_HEADLESS_TMPDIR` (default
`/tmp`) holds the runtime directory; a path inside the user's runtime directory,
or one too long for a Wayland socket, is refused.

## Listening from a host

A host that wants listening history and scrobbling calls, on the Zig API:

- `Runtime.setCredentialStore` with a `CredentialStore` over the platform's
  secure storage. `get` receives the service and account
  (`listenbrainz_token_service`, `listenbrainz_token_account`) and returns an
  owned copy of the token, or null. It runs on a listen worker's thread, so the
  store is safe to call from there. It never prompts or blocks on user
  interaction: a locked keyring reads as no token, and the worker's shutdown
  waits for the call to return.
- `Runtime.setClientIdentity` to name the host in submissions and in the
  history. Scrobbling cannot be turned on before it is set; see [Client
  identity](api.md#client-identity).
- `Runtime.setListenBrainzServer` only to select a self-hosted or compatible
  server.
- `Runtime.librarySetScrobbling` (its last argument turns Now Playing on),
  `libraryScrobblerCredentialsChanged` after the token changes, and
  `libraryScrobblerStatus` for presentation.
- `Runtime.librarySetFeedback` and `libraryTrackFeedback` for love and hate,
  which `TrackSummary.feedback` and `TrackDetails.feedback` also report.
- `Runtime.librarySetReleaseLove` for album love, which `ReleaseSummary.loved`
  reports. `ReleaseQuery.loved_only` with `ReleaseSort.loved`, and
  `TrackQuery.loved_only` with `TrackSort.loved`, list what is loved. Album love
  is never sent.

The identity and the server are copied. The store's context is borrowed and
outlives the runtime. The setters may be called at any time and reach each
listen worker on its next pass; a host that sets them before binding a Player to
a Library avoids a first pass with the defaults. Listens are sampled inside
`processNextCommand`, so a host pumps it as it already does. The C ABI covers
the same steps: the credential callback ([Credentials](#credentials)),
`orca_runtime_set_client_identity`, `orca_runtime_set_provider_server`,
`orca_library_set_scrobbling`, `orca_library_scrobbler_credentials_changed`,
`orca_library_scrobbler_status`, `orca_library_set_feedback` and
`orca_library_set_release_love`. [providers.md](providers.md) describes what a
listen is and what is sent.
