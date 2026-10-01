#ifndef ORCA_H
#define ORCA_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Stability.
 *
 * liborca is pre-1.0. This C ABI is versioned by ORCA_ABI_VERSION and by the
 * shared library's SONAME, liborca.so.ORCA_ABI_VERSION. Within one ABI
 * version:
 *
 * - functions are only added, never removed or changed;
 * - a reserved field gains a meaning only as an addition for which zero keeps
 *   the old behaviour;
 * - enum values are only added.
 *
 * Anything else raises ORCA_ABI_VERSION. The ABI version is separate from the
 * product version orca_version reports.
 *
 * liborca's Zig API may break in any minor release; CHANGELOG.md records each
 * break.
 */
#define ORCA_ABI_VERSION 0

/*
 * Threading contract.
 *
 * Every orca_* function must be called from ONE thread for the lifetime of a
 * given orca_runtime, including orca_runtime_create and orca_runtime_destroy.
 * orca_runtime_poll_event is part of that contract: it is single-consumer.
 *
 * This is not advisory. liborca is genuinely multithreaded behind the
 * boundary - each Player runs a decode engine thread, each scan runs a
 * registered worker - and the runtime's object pools take no lock. A debug
 * build records the calling thread on the first call and returns
 * ORCA_STATUS_WRONG_THREAD for any call from another one.
 *
 * Callbacks are invoked on the calling thread, before the function returns.
 * Every orca_string_view handed to a callback is valid only for the duration
 * of that callback: copy what you need. Re-entering the ABI from inside a
 * callback is not supported.
 *
 * The one exception is the wake callback of orca_runtime_set_wake_callback,
 * which liborca also calls from its own threads.
 */

typedef struct orca_runtime orca_runtime;

typedef enum orca_status {
    ORCA_STATUS_OK = 0,
    ORCA_STATUS_INVALID_ARGUMENT = 1,
    ORCA_STATUS_RUNTIME_NOT_RUNNING = 2,
    ORCA_STATUS_STALE_HANDLE = 3,
    ORCA_STATUS_OUT_OF_MEMORY = 4,
    /* The object exists but cannot do that right now: a Player with no source
     * or no output, a Zone an engine already owns, a Library-less Player. */
    ORCA_STATUS_INVALID_STATE = 5,
    /* No such Track, root, or file behind a Track. */
    ORCA_STATUS_NOT_FOUND = 6,
    /* A bounded queue is full. Backpressure, not failure. */
    ORCA_STATUS_BUSY = 7,
    /* No codec can read those bytes, or no backend can open that device. */
    ORCA_STATUS_UNSUPPORTED = 8,
    /* Debug builds only: called from a thread other than the owning one. */
    ORCA_STATUS_WRONG_THREAD = 9,
    ORCA_STATUS_INTERNAL = 255,
} orca_status;

typedef struct orca_handle {
    uint32_t index;
    uint32_t generation;
} orca_handle;

typedef enum orca_transport_state {
    ORCA_TRANSPORT_STOPPED = 0,
    ORCA_TRANSPORT_PLAYING = 1,
    ORCA_TRANSPORT_PAUSED = 2,
} orca_transport_state;

typedef enum orca_repeat_mode {
    ORCA_REPEAT_OFF = 0,
    ORCA_REPEAT_ALL = 1,
    ORCA_REPEAT_ONE = 2,
} orca_repeat_mode;

typedef enum orca_render_policy {
    ORCA_RENDER_POLICY_ROBUST = 0,
    ORCA_RENDER_POLICY_INTERACTIVE = 1,
} orca_render_policy;

typedef enum orca_output_state {
    ORCA_OUTPUT_CLOSED = 0,
    ORCA_OUTPUT_OPENING = 1,
    ORCA_OUTPUT_ACTIVE = 2,
    ORCA_OUTPUT_LOST = 3,
    ORCA_OUTPUT_RECOVERING = 4,
    ORCA_OUTPUT_FAILED = 5,
} orca_output_state;

typedef enum orca_job_state {
    ORCA_JOB_QUEUED = 0,
    ORCA_JOB_RUNNING = 1,
    ORCA_JOB_CANCELLING = 2,
    ORCA_JOB_CANCELLED = 3,
    ORCA_JOB_SUCCEEDED = 4,
    ORCA_JOB_FAILED = 5,
} orca_job_state;

typedef enum orca_job_kind {
    ORCA_JOB_KIND_SCAN = 0,
    ORCA_JOB_KIND_PROJECTION = 1,
    ORCA_JOB_KIND_PROPERTY_BACKFILL = 2,
    ORCA_JOB_KIND_ANALYSIS = 3,
    ORCA_JOB_KIND_DUPLICATE_SCAN = 4,
    ORCA_JOB_KIND_RECONCILE = 5,
    ORCA_JOB_KIND_OTHER = 255,
} orca_job_kind;

typedef struct orca_string_view {
    const char *pointer;
    size_t length;
} orca_string_view;

/* The `has_*` flags distinguish "zero" from "the library does not know". */
typedef struct orca_track_view {
    int64_t id;
    int64_t duration_ms;
    int64_t track_number;
    int64_t disc_number;
    uint8_t has_duration;
    uint8_t has_track_number;
    uint8_t has_disc_number;
    /* The Track resolves to a file with a location that is not missing. */
    uint8_t has_file;
    uint8_t reserved[4];
    orca_string_view title;
    orca_string_view artist;
    orca_string_view album;
    orca_string_view album_artist;
} orca_track_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_track_callback)(void *context, const orca_track_view *track);

typedef enum orca_track_sort {
    /* Insertion order. The cheapest listing there is. */
    ORCA_TRACK_SORT_ID = 0,
    ORCA_TRACK_SORT_ARTIST = 1,
    ORCA_TRACK_SORT_ALBUM = 2,
    ORCA_TRACK_SORT_TITLE = 3,
    /* Disc, then track number: the order an album is listened to. */
    ORCA_TRACK_SORT_TRACK_NUMBER = 4,
    ORCA_TRACK_SORT_DURATION = 5,
    ORCA_TRACK_SORT_DATE_ADDED = 6,
} orca_track_sort;

/* One bounded, ordered, filtered request for a page of Tracks.
 *
 * `artist_id` and `release_id` are relational filters; pass -1 for "no
 * filter". Every order this produces ends in the Track id, so paging is a
 * total order: page N+1 continues exactly where page N stopped even when
 * thousands of Tracks share a title. `limit` must be between 1 and 512. */
typedef struct orca_track_query {
    int64_t artist_id;
    int64_t release_id;
    uint8_t sort;
    uint8_t descending;
    uint8_t reserved[2];
    uint32_t limit;
    uint32_t offset;
} orca_track_query;

typedef struct orca_artist_view {
    int64_t id;
    uint32_t release_count;
    uint32_t track_count;
    orca_string_view name;
    /* The folded key the listing is ordered by: lowercased, whitespace
     * collapsed, a leading English article dropped. Display `name`. */
    orca_string_view sort_name;
} orca_artist_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_artist_callback)(void *context, const orca_artist_view *artist);

typedef struct orca_release_view {
    int64_t id;
    int64_t album_artist_id;
    int64_t disc_count;
    /* Summed over the Tracks that declare a duration. */
    int64_t total_duration_ms;
    uint32_t track_count;
    uint8_t has_album_artist_id;
    uint8_t has_disc_count;
    uint8_t is_compilation;
    uint8_t reserved[3];
    orca_string_view title;
    orca_string_view album_artist;
    /* Empty when the release has no date; a date is text, not a number, so it
     * needs no has_* flag. */
    orca_string_view release_date;
} orca_release_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_release_callback)(void *context, const orca_release_view *release);

typedef struct orca_health_issue_view {
    uint8_t kind;
    uint8_t severity;
    uint8_t reserved[6];
    orca_string_view path;
    orca_string_view details;
} orca_health_issue_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_health_issue_callback)(
    void *context,
    const orca_health_issue_view *issue
);

typedef struct orca_root_view {
    int64_t id;
    int64_t volume_id;
    uint8_t enabled;
    uint8_t reserved[7];
    orca_string_view path;
} orca_root_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_root_callback)(void *context, const orca_root_view *root);

typedef struct orca_device_view {
    uint64_t id;
    orca_string_view name;
} orca_device_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_device_callback)(void *context, const orca_device_view *device);

typedef struct orca_queue_entry_view {
    /* Position in playback order, so a shuffled queue reads in the order it
     * will actually be heard. */
    uint32_t position;
    uint8_t is_current;
    uint8_t reserved[3];
    int64_t track_id;
} orca_queue_entry_view;

typedef void (*orca_queue_entry_callback)(
    void *context,
    const orca_queue_entry_view *entry
);

/* The audible entry, resolved against the Library the Player is bound to. */
typedef struct orca_now_playing_view {
    int64_t track_id;
    int64_t duration_ms;
    uint8_t has_duration;
    uint8_t reserved[7];
    orca_string_view title;
    orca_string_view artist;
    orca_string_view album;
    orca_string_view album_artist;
} orca_now_playing_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_now_playing_callback)(
    void *context,
    const orca_now_playing_view *now_playing
);

typedef struct orca_player_status {
    uint8_t transport;  /* orca_transport_state */
    uint8_t repeat;     /* orca_repeat_mode */
    uint8_t shuffle;
    uint8_t has_track;
    /* Transport epoch. Bumped by every seek and stop; audio prepared under an
     * older epoch is discarded rather than played. */
    uint32_t epoch;
    /* Derived from the packed epoch+frames atomic the render callback writes,
     * never from the event stream. Zero when nothing is loaded. */
    uint64_t position_ms;
    uint64_t duration_ms;
    /* The AUDIBLE entry, which during a gapless transition is not the entry
     * the decoder has reached. */
    int64_t track_id;
    uint32_t queue_length;
    uint32_t queue_index;
    float volume;
    uint8_t reserved[4];
} orca_player_status;

typedef struct orca_zone_status {
    uint8_t output_state;  /* orca_output_state */
    uint8_t reserved[3];
    uint32_t recovery_attempts;
    uint32_t backend_quantum_frames;
    uint32_t rendered_entry_serial;
    uint64_t underruns;
    uint64_t dropped_returns;
} orca_zone_status;

typedef struct orca_job_snapshot {
    uint8_t kind;   /* orca_job_kind */
    uint8_t state;  /* orca_job_state */
    /* Zero for a scan. A filesystem walk has no honest denominator until it
     * has finished walking, and Orca does not invent one. A property backfill
     * does have one before it starts - how many rows still owe a probe is one
     * indexed count - so it reports a total and a host may show a fraction. */
    uint8_t has_total;
    uint8_t reserved[5];
    uint64_t completed_units;
    uint64_t total_units;
} orca_job_snapshot;

/* Mirrors the scanner's own result, plus what the projection made of it. */
typedef struct orca_scan_stats {
    uint64_t files_seen;
    uint64_t changed;
    uint64_t unchanged;
    uint64_t unsupported;
    uint64_t errors;
    uint64_t batches_committed;
    uint64_t folders_visited;
    uint64_t files_projected;
    uint64_t tracks_written;
    uint64_t releases_written;
    uint8_t cancelled;
    uint8_t reserved[7];
} orca_scan_stats;

typedef struct orca_scan_options {
    /* Rows per bounded commit. Zero selects the default. */
    uint32_t batch_size;
    uint8_t reserved[4];
} orca_scan_options;

typedef struct orca_analysis_options {
    /*
     * Files per selected page and per bounded commit. Zero selects the
     * default, which is far smaller than a scan's: one unit of this job's work
     * is a whole file decoded end to end, and a batch is what an interrupted
     * run throws away.
     */
    uint32_t batch_size;
    /*
     * Files decoded at once, each on its own thread. Zero selects
     * orca_analysis_default_threads(). A batch is shared between at most this
     * many threads, so more threads than batch_size gain nothing.
     */
    uint16_t threads;
    uint8_t reserved[2];
} orca_analysis_options;

typedef struct orca_duplicate_scan_options {
    /* Files per selected page and per bounded commit. Zero selects the
     * default. Far larger than the analysis job's, because a unit of work here
     * is a handful of indexed lookups rather than a file decoded end to end -
     * this pass opens no files at all. */
    uint32_t batch_size;
    uint8_t reserved[4];
} orca_duplicate_scan_options;

typedef struct orca_backfill_options {
    /* Rows per selected page and per bounded commit. Zero selects the
     * default. Capped at 512, the bound every repository page shares. */
    uint32_t batch_size;
    /*
     * Nonzero re-probes rows that ALREADY declare properties.
     *
     * Off is the right default: a probe reads what a container declares, so
     * running it again on a row that has an answer reads the same bytes and
     * writes the same numbers. Force exists for the one case the default
     * cannot serve - a probe implementation that got better, where a stored
     * value is present but no longer what this build would compute. A forced
     * run is NOT restart-resumable: a re-probed row still matches, so an
     * interrupted one starts over rather than resuming.
     */
    uint8_t force;
    uint8_t reserved[3];
} orca_backfill_options;

/* ---------------------------------------------------------------- events */

typedef enum orca_event_kind {
    ORCA_EVENT_NONE = 0,
    /* A command submitted through the control lane finished. */
    ORCA_EVENT_COMMAND_COMPLETED = 1,
    /* Coalesced hint. Authoritative progress comes from orca_job_snapshot. */
    ORCA_EVENT_JOB_PROGRESS = 2,
    ORCA_EVENT_JOB_FINISHED = 3,
    /* Coalesced hint. Authoritative position comes from orca_player_status. */
    ORCA_EVENT_PLAYER_POSITION = 4,
    /* Coalesced hint. A reconcile the Library's watcher started recorded or
     * marked missing a file; reread what is shown from the Library. */
    ORCA_EVENT_LIBRARY_CHANGED = 5,
} orca_event_kind;

typedef enum orca_outcome_kind {
    ORCA_OUTCOME_LIBRARY_CREATED = 0,
    ORCA_OUTCOME_PLAYER_CREATED = 1,
    ORCA_OUTCOME_ZONE_CREATED = 2,
    ORCA_OUTCOME_JOB_STARTED = 3,
    ORCA_OUTCOME_JOB_CANCELLATION_REQUESTED = 4,
    ORCA_OUTCOME_TRACK_PLAYING = 5,
    ORCA_OUTCOME_JOB_FINISHED = 6,
    ORCA_OUTCOME_FAILED = 255,
} orca_outcome_kind;

typedef enum orca_failure {
    ORCA_FAILURE_RUNTIME_NOT_RUNNING = 0,
    ORCA_FAILURE_STALE_HANDLE = 1,
    ORCA_FAILURE_OUT_OF_MEMORY = 2,
    ORCA_FAILURE_INVALID_TRANSITION = 3,
    ORCA_FAILURE_PLAYER_NOT_BOUND = 4,
    ORCA_FAILURE_TRACK_HAS_NO_FILE = 5,
    ORCA_FAILURE_TRACK_FILE_MISSING = 6,
    ORCA_FAILURE_CODEC_UNAVAILABLE = 7,
    ORCA_FAILURE_QUEUE_FULL = 8,
    ORCA_FAILURE_NOT_PLAYABLE = 9,
    ORCA_FAILURE_INTERNAL = 255,
} orca_failure;

typedef struct orca_command_completed_event {
    uint64_t request_id;
    uint8_t outcome;  /* orca_outcome_kind */
    uint8_t failure;  /* orca_failure, when outcome == ORCA_OUTCOME_FAILED */
    uint8_t reserved[6];
    /* The object the outcome refers to. Zeroed when there is none. */
    orca_handle object;
} orca_command_completed_event;

typedef struct orca_job_progress_event {
    orca_handle job;
    uint8_t has_total;
    uint8_t reserved[7];
    uint64_t completed_units;
    uint64_t total_units;
} orca_job_progress_event;

typedef struct orca_job_finished_event {
    orca_handle job;
    uint8_t state;  /* orca_job_state */
    uint8_t reserved[7];
} orca_job_finished_event;

typedef struct orca_player_position_event {
    orca_handle player;
    uint32_t reserved;
    uint64_t frames;
} orca_player_position_event;

typedef struct orca_library_changed_event {
    orca_handle library;
} orca_library_changed_event;

/* A named extern union rather than opaque a/b/c fields: it is ABI-stable,
 * imports cleanly into Swift, and keeps the header self-documenting. */
typedef union orca_event_payload {
    orca_command_completed_event command_completed;
    orca_job_progress_event job_progress;
    orca_job_finished_event job_finished;
    orca_player_position_event player_position;
    orca_library_changed_event library_changed;
} orca_event_payload;

typedef struct orca_event {
    uint8_t kind;  /* orca_event_kind */
    uint8_t reserved[7];
    orca_event_payload payload;
} orca_event;

/* -------------------------------------------------------------- runtime */

/* liborca's version, such as "0.2.0". Static storage; callable from any
 * thread. */
const char *orca_version(void);

/* The caller owns the returned runtime and must destroy it exactly once.
 * NULL means out of memory. */
orca_runtime *orca_runtime_create(void);
void orca_runtime_destroy(orca_runtime *runtime);

/*
 * Why the most recent call on `runtime` failed, as "<function>: <reason>", for
 * logs and bug reports rather than for parsing. Empty after a call that
 * returned ORCA_STATUS_OK, and for a NULL runtime. At most 255 bytes, longer
 * messages truncated; NUL-terminated. Valid until the next orca_* call on
 * `runtime`.
 *
 * A call refused with ORCA_STATUS_WRONG_THREAD does not change it.
 */
const char *orca_runtime_last_error(const orca_runtime *runtime);

/* Drives the serialized control lane: executes submitted commands and joins
 * background workers that have finished. Call it before polling events. */
orca_status orca_runtime_pump(orca_runtime *runtime);

/* Single-consumer. Returns ORCA_EVENT_NONE in `event->kind` when the channels
 * are empty. `remaining`, when non-null, receives how many events are still
 * queued after this one. */
orca_status orca_runtime_poll_event(
    orca_runtime *runtime,
    orca_event *event,
    uint32_t *remaining
);

/*
 * Wakeup: a host sleeps in its own event loop until liborca has something for
 * it, instead of pumping on a timer.
 *
 * liborca calls `callback(context)` when the host should pump: after a
 * command is submitted, and when a Player, Zone, job, listen or scrobbler
 * changes in a way the host did not cause. It is called at most once between
 * two calls to orca_runtime_pump.
 *
 * It is the one exception to the threading contract: it is called from
 * liborca's own threads, and from inside other orca_* calls on the owning
 * thread, sometimes from two threads at once. It must only signal the host's
 * loop - write to an eventfd or a pipe, CFRunLoopSourceSignal and
 * CFRunLoopWakeUp, notify a condition variable - and return. It must not call
 * any orca_* function and must not block. It is never called from an audio render callback, and never after
 * orca_runtime_destroy has returned. `context` must stay valid until then.
 *
 * Call it right after orca_runtime_create: once any worker thread exists (a
 * Player's engine, a job, a listen worker or an artwork loader) it returns
 * ORCA_STATUS_INVALID_STATE. A NULL callback removes the callback, under the
 * same rule.
 */
typedef void (*orca_wake_fn)(void *context);
orca_status orca_runtime_set_wake_callback(orca_runtime *runtime, orca_wake_fn callback, void *context);

#define ORCA_PUMP_NO_TIMEOUT (-1)

/*
 * How long the host may wait for the wake callback before pumping anyway:
 * 0 to pump now, ORCA_PUMP_NO_TIMEOUT to wait for the callback alone.
 * Otherwise at most 1000 ms while a Player bound to a Library plays, since
 * its listens must be sampled (its position wakes usually pump sooner), and
 * at most 100 ms while a job runs, so its progress can be read.
 *
 * Read it after pumping and draining events, immediately before waiting. A
 * host whose wake primitive does not count wakes, such as a flag or a
 * condition variable, must read it to avoid losing a wake that arrived while
 * it was pumping.
 */
orca_status orca_runtime_pump_timeout(orca_runtime *runtime, int64_t *timeout_ms);

/* -------------------------------------------------------------- library */

orca_status orca_library_open(
    orca_runtime *runtime,
    const char *path,
    orca_handle *output
);
orca_status orca_library_close(orca_runtime *runtime, orca_handle library);
orca_status orca_library_track_count(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t *output
);
/* `limit` must be between 1 and 512, keeping frontend models virtualized. */
orca_status orca_library_query_tracks(
    orca_runtime *runtime,
    orca_handle library,
    const char *query,
    size_t query_length,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_track_callback callback
);
orca_status orca_library_health_issue_count(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t *output
);
orca_status orca_library_query_health_issues(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_health_issue_callback callback
);


/* ------------------------------------------------------------- browsing */

/* The browse model: Artists, the Releases filed under one, and the Tracks on
 * one Release or by one Artist. All three are bounded, caller-driven pages
 * with an explicit, total order - liborca owns browse semantics, a frontend
 * owns only how the rows look. */

orca_status orca_library_artist_count(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t *output
);
/* Artists in sort-name order. `limit` must be between 1 and 512. */
orca_status orca_library_query_artists(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_artist_callback callback
);
/* Invokes the callback once, or not at all if no such Artist exists. */
orca_status orca_library_artist_get(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    void *context,
    orca_artist_callback callback
);

orca_status orca_library_release_count(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t *output
);
/* Releases in title order. `album_artist_id` of -1 lists every Release;
 * anything else lists that Artist's. `limit` must be between 1 and 512. */
orca_status orca_library_query_releases(
    orca_runtime *runtime,
    orca_handle library,
    int64_t album_artist_id,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_release_callback callback
);
/* Invokes the callback once, or not at all if no such Release exists. */
orca_status orca_library_release_get(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    void *context,
    orca_release_callback callback
);

/* A sorted, filtered page of Tracks. This is what an album view and an artist
 * view are built from. `query` may not be null. */
orca_status orca_library_browse_tracks(
    orca_runtime *runtime,
    orca_handle library,
    const orca_track_query *query,
    void *context,
    orca_track_callback callback
);
/* How many Tracks the filters in `query` match, so a host can size a
 * scrollbar without walking the listing. Sort, limit and offset are ignored. */
orca_status orca_library_track_match_count(
    orca_runtime *runtime,
    orca_handle library,
    const orca_track_query *query,
    uint64_t *output
);

/* Registering a root is an explicit user action: it is the one path allowed to
 * persist a volume identifier at a mount root. */
orca_status orca_library_add_root(
    orca_runtime *runtime,
    orca_handle library,
    const char *path,
    int64_t *root_id
);
/* Forgets a root and every file, Track, Release and Artist that exists only
 * under it; files on disk are untouched. NOT_FOUND for an unknown root, BUSY
 * while a job is running on the library. */
orca_status orca_library_remove_root(
    orca_runtime *runtime,
    orca_handle library,
    int64_t root_id
);
/* `limit` must be between 1 and 512. */
orca_status orca_library_query_roots(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_root_callback callback
);

/*
 * Starts a scan on a registered background worker and returns immediately.
 * `root_id` of -1 walks every enabled root. `options` may be null.
 *
 * The scan PROJECTS AS IT COMMITS: each bounded batch hands its file ids to
 * the projection, exactly as `orca-cli scan` does, because a scan whose
 * results are not projected has not made the library browsable. Use
 * orca_library_start_projection for the other direction - reprojecting an
 * already-scanned library after a metadata change, with no filesystem walk.
 */
orca_status orca_library_start_scan(
    orca_runtime *runtime,
    orca_handle library,
    int64_t root_id,
    const orca_scan_options *options,
    orca_handle *job
);
orca_status orca_library_start_projection(
    orca_runtime *runtime,
    orca_handle library,
    orca_handle *job
);

/*
 * Starts a reconcile of one registered root: walks `count` directories under
 * it, each relative to the root ("Artist/Album", no leading or trailing
 * slash, no "." or ".." component), or the whole root when `count` is zero,
 * and marks missing only the files under what it walked. `directories` may
 * be null when `count` is zero. The strings need not outlive the call.
 *
 * INVALID_ARGUMENT for a directory not in that form, BUSY while a scan or
 * reconcile of the library runs. Its stats are read through
 * orca_library_scan_stats, with a scan's meaning.
 *
 * No scan or reconcile walks a root whose path now resolves to another
 * volume than the one recorded when it was added, as the empty mount point
 * of an unmounted drive does: the job fails, counts an error, and marks
 * nothing missing.
 */
orca_status orca_library_start_reconcile(
    orca_runtime *runtime,
    orca_handle library,
    int64_t root_id,
    const char *const *directories,
    size_t count,
    orca_handle *job
);

/* ------------------------------------------------------------- watching */

typedef enum orca_watch_state {
    /* Not watched, or the watcher stopped on an error. */
    ORCA_WATCH_STATE_OFF = 0,
    ORCA_WATCH_STATE_WATCHING = 1,
    /* Watching, but a root is unavailable or the watch limit was reached. */
    ORCA_WATCH_STATE_DEGRADED = 2,
    /* No watcher on this platform. */
    ORCA_WATCH_STATE_UNSUPPORTED = 3,
} orca_watch_state;

/* Zero in a field selects its default. */
typedef struct orca_watch_options {
    /* A root's changes are reconciled once it has been quiet this long.
     * Default 2000. */
    uint32_t quiet_ms;
    /* ...or once this long has passed since its first unreconciled change.
     * Default 30000; at least quiet_ms. */
    uint32_t max_delay_ms;
    /* How often a root the watch limit left partly unwatched is reconciled
     * whole, and an unavailable root is tried again. Default 900000. */
    uint32_t degraded_rescan_ms;
    uint8_t reserved[4];
} orca_watch_options;

typedef struct orca_watch_status {
    uint8_t state;  /* orca_watch_state */
    /* fs.inotify.max_user_watches was reached; see roots_degraded. */
    uint8_t watch_limit_reached;
    uint8_t reconcile_pending;
    uint8_t reconcile_running;
    uint32_t roots_watched;
    /* Deleted, moved, unmounted, on another volume than the one recorded, or
     * not watchable. Tried again every degraded_rescan_ms. */
    uint32_t roots_unavailable;
    /* Partly unwatched because the watch limit was reached. Reconciled whole
     * every degraded_rescan_ms while they stay so. */
    uint32_t roots_degraded;
    uint64_t directories_watched;
} orca_watch_status;

/*
 * Watches every enabled root of the Library and reconciles what changes under
 * them on background jobs that orca_runtime_pump starts. Each reports
 * ORCA_EVENT_JOB_FINISHED like any job, and one that recorded or marked
 * missing a file also posts ORCA_EVENT_LIBRARY_CHANGED. Arming
 * reconciles each root whole. A scan, reconcile or tag write the host starts
 * pre-empts a running automatic reconcile. `options` may be null.
 *
 * UNSUPPORTED where there is no watcher (only Linux has one), INVALID_STATE
 * for a Library already watched, INVALID_ARGUMENT for inconsistent options.
 */
orca_status orca_library_watch(
    orca_runtime *runtime,
    orca_handle library,
    const orca_watch_options *options
);
/* Stops watching and joins the watcher and any reconcile it started. */
orca_status orca_library_unwatch(orca_runtime *runtime, orca_handle library);
orca_status orca_library_watch_status(
    orca_runtime *runtime,
    orca_handle library,
    orca_watch_status *output
);

/*
 * Starts the property backfill: re-reads the headers of `files` rows whose
 * declared audio properties are missing, and reprojects each repaired batch.
 *
 * The reprojection is part of the job rather than a step the caller sequences:
 * a Track's duration is DERIVED from its file row, so a backfill that repaired
 * the files and left the Tracks reading zero would have fixed nothing anybody
 * can see. `options` may be null.
 *
 * Progress and results are read through orca_job_snapshot_get and
 * orca_library_scan_stats. In those stats `files_seen` counts rows examined,
 * `changed` rows repaired, `errors` files that opened and would not decode,
 * and `unsupported` files that are not reachable or are not audio - the last
 * of which is not a failure of the pass.
 */
orca_status orca_library_start_property_backfill(
    orca_runtime *runtime,
    orca_handle library,
    const orca_backfill_options *options,
    orca_handle *job
);

/*
 * Starts the library-wide analysis: decodes every file the Library has not
 * measured yet and stores its loudness, peak, clipping, silence, waveform,
 * temporal fingerprint and, unless the audio is too short, its AcoustID
 * fingerprint. This is what makes ReplayGain on playback possible; without it
 * every track plays at unity. `options` may be null.
 *
 * Each batch's files are decoded by up to `options->threads` threads at once.
 *
 * It decodes whole files, so it is slow by nature and is expected to be
 * stopped and started again: orca_job_cancel takes effect inside a file, the
 * batch already measured is still committed, and a later run selects only what
 * is left. There is no force mode - a stored result carries its algorithm
 * version, its parameters and the identity of the bytes it was taken from, so
 * every reason to measure a file again is already a reason it gets selected.
 *
 * Progress and results are read through orca_job_snapshot_get and
 * orca_library_scan_stats. In those stats `files_seen` counts files carried to
 * a commit, `changed` files that yielded a loudness figure, `unchanged` files
 * measured with no gateable loudness, `errors` files that opened and would not
 * decode, and `unsupported` files that are not reachable, are not audio, or
 * whose recorded identity no longer matches the bytes on disk - the last of
 * which is a scan's job to repair, not this pass's.
 */
orca_status orca_library_start_analysis(
    orca_runtime *runtime,
    orca_handle library,
    const orca_analysis_options *options,
    orca_handle *job
);

/* The machine's logical processors, at least 1: the most analysis threads
 * that can each have a processor of their own. Callable from any thread. */
uint16_t orca_analysis_available_threads(void);

/* What orca_analysis_options.threads = 0 selects: one fewer than
 * orca_analysis_available_threads(), and at least 1. Callable from any
 * thread. */
uint16_t orca_analysis_default_threads(void);

/*
 * Starts the duplicate scan: reports every file whose audio the Library also
 * holds somewhere else. `options` may be null.
 *
 * It compares measurements the analysis job stored rather than reading files,
 * through two indexes - equal decoded-audio hash for the certain case, and a
 * duration window inside which temporal fingerprints are compared for the
 * probable one - so a full run over a measured library takes seconds where the
 * analysis itself takes hours.
 *
 * Findings are recorded as library health issues, readable through
 * orca_library_query_health_issues: kind 9 is the certain finding and kind 10
 * the probable one. Both kinds are REWRITTEN for every file examined, so a second run converges on the same
 * rows rather than doubling them, and a duplicate that has since been deleted
 * stops being reported.
 *
 * Progress and results are read through orca_job_snapshot_get and
 * orca_library_scan_stats. In those stats `files_seen` counts rows examined,
 * `changed` files given a finding, `unchanged` files compared and matched by
 * nothing, `errors` files whose stored fingerprint would not decode, and
 * `unsupported` files nothing could be said about because they have never been
 * analyzed or never been probed - which is the number that says whether a
 * "no duplicates" answer means anything. `tracks_written` and
 * `releases_written` carry the exact and likely finding counts, `folders_
 * visited` the buckets that hit the per-candidate comparison cap, and
 * `files_projected` the fingerprint comparisons performed.
 */
orca_status orca_library_start_duplicate_scan(
    orca_runtime *runtime,
    orca_handle library,
    const orca_duplicate_scan_options *options,
    orca_handle *job
);

orca_status orca_job_cancel(orca_runtime *runtime, orca_handle job);
orca_status orca_job_snapshot_get(
    orca_runtime *runtime,
    orca_handle job,
    orca_job_snapshot *output
);
/* Live while the job runs, and retained for a bounded number of finished jobs
 * afterwards, so a host can read the stats of the scan that just ended. */
orca_status orca_library_scan_stats(
    orca_runtime *runtime,
    orca_handle job,
    orca_scan_stats *output
);

/* --------------------------------------------------------------- player */

orca_status orca_player_create(orca_runtime *runtime, orca_handle *output);
orca_status orca_player_destroy(orca_runtime *runtime, orca_handle player);

/* Binds the Player's queue to a Library, opening the independent read-only
 * connection its entries are resolved through. Required before play/enqueue. */
orca_status orca_player_set_library(
    orca_runtime *runtime,
    orca_handle player,
    orca_handle library
);

/* Rejected unless the Player has something to play and somewhere to play it:
 * a loaded source or a non-empty queue, and at least one attached Zone. */
orca_status orca_player_play(orca_runtime *runtime, orca_handle player);
orca_status orca_player_pause(orca_runtime *runtime, orca_handle player);
/* Stops the transport and releases its decoders. Queue entries and cursor
 * survive, so stop-then-play resumes the same queue at the same place. */
orca_status orca_player_stop(orca_runtime *runtime, orca_handle player);

/* Submits a play-track command to the control lane and returns immediately.
 * The outcome arrives as ORCA_EVENT_COMMAND_COMPLETED with this request id
 * after orca_runtime_pump has executed it. */
orca_status orca_player_play_track(
    orca_runtime *runtime,
    orca_handle player,
    int64_t track_id,
    uint64_t *request_id
);
/* Replaces the queue with `ids` and starts at `start`. Synchronous. */
orca_status orca_player_play_tracks(
    orca_runtime *runtime,
    orca_handle player,
    const int64_t *ids,
    size_t count,
    uint32_t start
);
/* Appends. An idle Player starts on the first new entry. */
orca_status orca_player_enqueue_tracks(
    orca_runtime *runtime,
    orca_handle player,
    const int64_t *ids,
    size_t count
);
/* A user skip is a hard switch: prepared audio is discarded rather than
 * drained. `moved` receives 0 at the end of a queue that is not repeating. */
orca_status orca_player_next(orca_runtime *runtime, orca_handle player, uint8_t *moved);
/* Past three seconds this restarts the current entry instead of moving back. */
orca_status orca_player_previous(orca_runtime *runtime, orca_handle player, uint8_t *moved);
orca_status orca_player_clear_queue(orca_runtime *runtime, orca_handle player);
orca_status orca_player_set_repeat(orca_runtime *runtime, orca_handle player, uint8_t mode);
orca_status orca_player_set_shuffle(orca_runtime *runtime, orca_handle player, uint8_t enabled);
/* Linear, 0 to 4. Applied to canonical PCM once, before fanout, so every Zone
 * hears the same level, and it survives a stop/start. */
orca_status orca_player_set_volume(orca_runtime *runtime, orca_handle player, float linear);
orca_status orca_player_volume(orca_runtime *runtime, orca_handle player, float *output);

typedef enum orca_replay_gain_mode {
    /* No loudness correction. Every entry plays at the volume set above. */
    ORCA_REPLAY_GAIN_OFF = 0,
    /* Each entry is corrected by its own measured loudness, when the Library
     * holds a measurement that still describes the file. Album-level
     * ReplayGain is not offered: it needs a release-scoped measurement Orca
     * does not compute, and naming it here would apply track gain under an
     * album label. */
    ORCA_REPLAY_GAIN_TRACK = 1,
} orca_replay_gain_mode;

/* Takes effect as soon as the audio already decoded ahead of the listener
 * drains -- a fraction of a second, not the rest of the track. The level steps
 * rather than ramping when it does, which is the answer to an explicit
 * request. Defaults to TRACK. */
orca_status orca_player_set_replay_gain_mode(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t mode
);
orca_status orca_player_replay_gain_mode(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t *output
);
/* What the audio currently audible is being multiplied by: volume times the
 * loudness correction of the entry actually being heard. Equal to the volume
 * when there is no correction, so the two differing is what "ReplayGain is
 * doing something" looks like. The correction is applied to the samples as the
 * entry is decoded, so this reports rather than drives it. */
orca_status orca_player_effective_gain(
    orca_runtime *runtime,
    orca_handle player,
    float *output
);

orca_status orca_player_seek(
    orca_runtime *runtime,
    orca_handle player,
    uint64_t frame,
    uint64_t *generation
);
orca_status orca_player_seek_ms(
    orca_runtime *runtime,
    orca_handle player,
    uint64_t milliseconds,
    uint64_t *epoch
);

orca_status orca_player_status_get(
    orca_runtime *runtime,
    orca_handle player,
    orca_player_status *output
);
/* The callback runs zero times when nothing is playing. Strings are valid only
 * for its duration. */
orca_status orca_player_now_playing(
    orca_runtime *runtime,
    orca_handle player,
    void *context,
    orca_now_playing_callback callback
);
/* `limit` must be between 1 and 512. Entries arrive in playback order. */
orca_status orca_player_query_queue(
    orca_runtime *runtime,
    orca_handle player,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_queue_entry_callback callback
);

/* -------------------------------------------------------- devices, zones */

orca_status orca_enumerate_output_devices(
    orca_runtime *runtime,
    void *context,
    orca_device_callback callback
);

orca_status orca_zone_create(orca_runtime *runtime, orca_handle *output);
orca_status orca_zone_destroy(orca_runtime *runtime, orca_handle zone);
orca_status orca_zone_attach_player(
    orca_runtime *runtime,
    orca_handle zone,
    orca_handle player
);
orca_status orca_zone_detach(orca_runtime *runtime, orca_handle zone);
/* Device id 0 delegates to the server default. `latency_frames` of 0 asks the
 * backend for one render block. Stream creation happens on the Zone's own
 * lane, never on the caller's thread. */
orca_status orca_zone_open_output(
    orca_runtime *runtime,
    orca_handle zone,
    uint64_t device_id,
    uint8_t policy,
    uint32_t latency_frames
);
orca_status orca_zone_close_output(orca_runtime *runtime, orca_handle zone);
orca_status orca_zone_status_get(
    orca_runtime *runtime,
    orca_handle zone,
    orca_zone_status *output
);

/* Creates a Zone, attaches it, and opens its output, in one control-lane
 * action. A single-output frontend never has to know Zones exist; `zone_out`
 * may be null if it does not want the handle. */
orca_status orca_player_open_default_output(
    orca_runtime *runtime,
    orca_handle player,
    uint64_t device_id,
    orca_handle *zone_out
);

#ifdef __cplusplus
}
#endif

#endif
