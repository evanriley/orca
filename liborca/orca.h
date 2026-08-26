#ifndef ORCA_H
#define ORCA_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

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
    ORCA_JOB_KIND_OTHER = 255,
} orca_job_kind;

/* Kept for source compatibility with the pre-0.2 boundary. New code wants
 * orca_player_status, which carries transport, queue and timeline together. */
typedef struct orca_player_state_snapshot {
    uint8_t state;
    uint8_t reserved[7];
    uint64_t generation;
    uint64_t position_frames;
} orca_player_state_snapshot;

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
     * has finished walking, and Orca does not invent one. */
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

/* A named extern union rather than opaque a/b/c fields: it is ABI-stable,
 * imports cleanly into Swift, and keeps the header self-documenting. */
typedef union orca_event_payload {
    orca_command_completed_event command_completed;
    orca_job_progress_event job_progress;
    orca_job_finished_event job_finished;
    orca_player_position_event player_position;
} orca_event_payload;

typedef struct orca_event {
    uint8_t kind;  /* orca_event_kind */
    uint8_t reserved[7];
    orca_event_payload payload;
} orca_event;

/* -------------------------------------------------------------- runtime */

/* The caller owns the returned runtime and must destroy it exactly once. */
orca_runtime *orca_runtime_create(void);
void orca_runtime_destroy(orca_runtime *runtime);

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

/* Registering a root is an explicit user action: it is the one path allowed to
 * persist a volume identifier at a mount root. */
orca_status orca_library_add_root(
    orca_runtime *runtime,
    orca_handle library,
    const char *path,
    int64_t *root_id
);
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

orca_status orca_player_snapshot(
    orca_runtime *runtime,
    orca_handle player,
    orca_player_state_snapshot *output
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
