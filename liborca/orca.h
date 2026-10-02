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
 * The two exceptions are the wake callback of orca_runtime_set_wake_callback
 * and the credential callback of orca_runtime_set_credential_callback, which
 * liborca calls from its own threads.
 *
 * On Linux, the first Library open switches SQLite to OFD locks for the whole
 * process. Open no SQLite connection of your own before it.
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
    /* A bounded queue is full, a job holds the Library, or another process
     * holds its mutation journal. Backpressure, not failure. */
    ORCA_STATUS_BUSY = 7,
    /* No codec can read those bytes, or no backend can open that device. */
    ORCA_STATUS_UNSUPPORTED = 8,
    /* Debug builds only: called from a thread other than the owning one. */
    ORCA_STATUS_WRONG_THREAD = 9,
    /* What the call asks for was already done, such as undoing a tag write
     * that was already undone. Anything the call does regardless, like
     * re-reading the files, has been done. */
    ORCA_STATUS_ALREADY_DONE = 10,
    /* A file changed after Orca wrote it, or its backup is missing or no
     * longer the original. Orca kept every file as it found it and needs a
     * person to decide; it never claims a rollback it could not do. */
    ORCA_STATUS_NEEDS_RECONCILIATION = 11,
    /* What the call needs was deliberately deleted, such as the backups of a
     * tag write that was pruned and can no longer be undone. */
    ORCA_STATUS_GONE = 12,
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
    /* MusicBrainz and AcoustID matching, verification, and a release's
     * cover-art fetch. */
    ORCA_JOB_KIND_METADATA_LOOKUP = 6,
    /* Sending recording IDs to AcoustID. */
    ORCA_JOB_KIND_ACOUSTID_SUBMISSION = 7,
    /* Writing an approved tag-write plan to files. */
    ORCA_JOB_KIND_MUTATION = 8,
    ORCA_JOB_KIND_OTHER = 255,
} orca_job_kind;

typedef struct orca_string_view {
    const char *pointer;
    size_t length;
} orca_string_view;

/* A person's ListenBrainz feedback on a recording, kept in the Library. */
typedef enum orca_feedback {
    ORCA_FEEDBACK_NONE = 0,
    ORCA_FEEDBACK_LOVED = 1,
    ORCA_FEEDBACK_HATED = 2,
} orca_feedback;

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
    uint8_t feedback;  /* orca_feedback, of the Track's recording */
    /* `rating` is 1..100 when `has_rating` is set. */
    uint8_t has_rating;
    uint8_t rating;
    uint8_t reserved[1];
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
    /* Lowest rating first, or highest when descending; unrated Tracks last
     * either way. */
    ORCA_TRACK_SORT_RATING = 7,
    /* Most recently loved first, or least recently when descending; Tracks
     * whose recording is not loved last either way. */
    ORCA_TRACK_SORT_LOVED = 8,
} orca_track_sort;

/* One bounded, ordered, filtered request for a page of Tracks.
 *
 * `artist_id` and `release_id` are relational filters; pass -1 for "no
 * filter". Every order this produces ends in the Track id, so paging is a
 * total order: page N+1 continues exactly where page N stopped even when
 * thousands of Tracks share a title. `limit` must be between 1 and 512.
 * Nonzero `loved_only` keeps only Tracks whose recording is loved; a clear
 * not yet sent to ListenBrainz is not a love. */
typedef struct orca_track_query {
    int64_t artist_id;
    int64_t release_id;
    uint8_t sort;  /* orca_track_sort */
    uint8_t descending;
    uint8_t loved_only;
    uint8_t reserved[1];
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
    /* The album itself is loved, apart from any of its Tracks. */
    uint8_t loved;
    uint8_t reserved[2];
    orca_string_view title;
    orca_string_view album_artist;
    /* Empty when the release has no date; a date is text, not a number, so it
     * needs no has_* flag. */
    orca_string_view release_date;
} orca_release_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_release_callback)(void *context, const orca_release_view *release);

/* Every order ends in the Release id, so paging is a total order. */
typedef enum orca_release_sort {
    ORCA_RELEASE_SORT_TITLE = 0,
    /* Album artist, then oldest first within an artist: a shelf. */
    ORCA_RELEASE_SORT_ARTIST = 1,
    /* Newest first; undated Releases last. */
    ORCA_RELEASE_SORT_YEAR = 2,
    /* Most recently created first. */
    ORCA_RELEASE_SORT_RECENTLY_ADDED = 3,
    /* Most recently loved first; Releases that are not loved last. */
    ORCA_RELEASE_SORT_LOVED = 4,
} orca_release_sort;

/* One bounded, ordered request for a page of Releases. `album_artist_id` of
 * -1 lists every Release; anything else lists that Artist's. Nonzero
 * `loved_only` keeps only loved Releases. `limit` must be between 1 and
 * 512. */
typedef struct orca_release_query {
    int64_t album_artist_id;
    uint8_t sort;  /* orca_release_sort */
    uint8_t loved_only;
    uint8_t reserved[2];
    uint32_t limit;
    uint32_t offset;
} orca_release_query;

/* One bounded request for a page of Artists in sort-name order. `filter`
 * keeps the Artists whose name contains it, compared after the folding that
 * builds the sort name; an empty filter (length 0, pointer may be null)
 * keeps every Artist. `limit` must be between 1 and 512. */
typedef struct orca_artist_query {
    orca_string_view filter;
    uint32_t limit;
    uint32_t offset;
} orca_artist_query;

/* A Track with the ids it resolves to. */
typedef struct orca_track_summary_view {
    orca_track_view track;
    int64_t release_id;
    /* The credited Artist, when the projection resolved one. */
    int64_t artist_id;
    int64_t recording_id;
    uint8_t has_release_id;
    uint8_t has_artist_id;
    uint8_t has_recording_id;
    uint8_t reserved[5];
} orca_track_summary_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_track_summary_callback)(
    void *context,
    const orca_track_summary_view *summary
);

/* Where a MusicBrainz ID came from. */
typedef enum orca_id_source {
    /* The Track has no such ID. */
    ORCA_ID_SOURCE_NONE = 0,
    /* The file's tags. */
    ORCA_ID_SOURCE_TAG = 1,
    /* An accepted match, or a correction from verification. */
    ORCA_ID_SOURCE_MATCH = 2,
    /* A person's edit. */
    ORCA_ID_SOURCE_EDIT = 3,
} orca_id_source;

/*
 * Everything the Library recorded about one Track and the file it plays, as
 * the last scan saw it: the file is neither opened nor hashed. The `has_*`
 * flags distinguish "zero" from "the library does not know"; an absent text
 * is an empty string view.
 */
typedef struct orca_track_details_view {
    int64_t track_id;
    int64_t track_number;
    int64_t disc_number;
    int64_t duration_ms;
    int64_t size_bytes;
    /* Unix seconds at which the latest listen started. */
    int64_t last_played_at;
    /* Listens of the file the Track plays. */
    uint64_t play_count;
    orca_string_view title;
    orca_string_view artist;
    orca_string_view album;
    orca_string_view album_artist;
    /* The Release's date as the projection resolved it. */
    orca_string_view date;
    /* Such as "flac" or "mp3"; empty when the Track has no file or the file
     * was never probed. */
    orca_string_view codec;
    /* The uri of the best location that is not missing. */
    orca_string_view path;
    orca_string_view musicbrainz_recording_id;
    orca_string_view musicbrainz_release_id;
    orca_string_view musicbrainz_release_group_id;
    orca_string_view musicbrainz_release_track_id;
    orca_string_view musicbrainz_album_artist_id;
    uint32_t sample_rate;
    uint32_t bit_depth;
    uint32_t channels;
    /* File size over duration, so it includes tags and artwork. */
    uint32_t bitrate_kbps;
    /* Measured from the file's stored bytes: integrated loudness in LUFS, the
     * ReplayGain correction toward the analysis target in dB, and the largest
     * absolute sample, 1.0 being full scale. Valid when `has_loudness`. */
    float integrated_lufs;
    float replay_gain_db;
    float sample_peak;
    uint8_t has_track_number;
    uint8_t has_disc_number;
    uint8_t has_compilation;
    uint8_t compilation;
    /* `codec` names an encoding that discards audio; zero for an unknown
     * codec. */
    uint8_t lossy;
    uint8_t has_sample_rate;
    uint8_t has_bit_depth;
    uint8_t has_channels;
    uint8_t has_duration;
    uint8_t has_size_bytes;
    uint8_t has_bitrate_kbps;
    /* The Track has no location that is not missing. */
    uint8_t file_missing;
    /* Zero when the file has not been measured, or was measured under other
     * parameters, an older algorithm, or bytes it no longer has. */
    uint8_t has_loudness;
    uint8_t has_artwork;
    uint8_t has_last_played_at;
    uint8_t feedback;  /* orca_feedback */
    /* The feedback can be sent to ListenBrainz. */
    uint8_t feedback_syncable;
    /* `rating` is 1..100 when `has_rating` is set. */
    uint8_t has_rating;
    uint8_t rating;
    /* orca_id_source of each MusicBrainz ID; NONE when it is empty. */
    uint8_t musicbrainz_recording_id_source;
    uint8_t musicbrainz_release_id_source;
    uint8_t musicbrainz_release_group_id_source;
    uint8_t musicbrainz_release_track_id_source;
    uint8_t musicbrainz_album_artist_id_source;
    uint8_t reserved[4];
} orca_track_details_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_track_details_callback)(
    void *context,
    const orca_track_details_view *details
);

typedef struct orca_play_stats {
    /* Listens of the file the Track plays. */
    uint64_t play_count;
    /* Unix seconds at which the latest listen started, when
     * `has_last_played_at`. */
    int64_t last_played_at;
    uint8_t has_last_played_at;
    uint8_t reserved[7];
} orca_play_stats;

/* What a bulk change to Tracks or Releases did. `updated` counts the ids whose
 * stored value changed; `skipped` counts ids that name nothing in the
 * Library. An id that already had the requested value is neither. */
typedef struct orca_change_count {
    uint32_t updated;
    uint32_t skipped;
} orca_change_count;

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

/* What kind of problem a health issue reports. */
typedef enum orca_health_issue_kind {
    /* A Track lacks a title, artist or album. */
    ORCA_HEALTH_ISSUE_KIND_MISSING_METADATA = 0,
    /* A Track has no track number. */
    ORCA_HEALTH_ISSUE_KIND_MISSING_TRACK_NUMBER = 1,
    /* The album artist differs between the Tracks of one album. */
    ORCA_HEALTH_ISSUE_KIND_ALBUM_ARTIST_ANOMALY = 2,
    /* The cover is missing or unusable. */
    ORCA_HEALTH_ISSUE_KIND_ARTWORK_PROBLEM = 3,
    /* The file has not been measured for loudness yet. */
    ORCA_HEALTH_ISSUE_KIND_MISSING_ANALYSIS = 4,
    /* The audio clips. */
    ORCA_HEALTH_ISSUE_KIND_CLIPPING = 5,
    /* The audio holds a long stretch of silence. */
    ORCA_HEALTH_ISSUE_KIND_EXCESSIVE_SILENCE = 6,
    /* A measured property is implausible for the file. */
    ORCA_HEALTH_ISSUE_KIND_TECHNICAL_ANOMALY = 7,
    /* The audio would not decode all the way through. */
    ORCA_HEALTH_ISSUE_KIND_CORRUPT_AUDIO = 8,
    /* Another file holds the same audio. */
    ORCA_HEALTH_ISSUE_KIND_EXACT_DUPLICATE = 9,
    /* Another file probably holds the same recording. */
    ORCA_HEALTH_ISSUE_KIND_LIKELY_DUPLICATE = 10,
    /* The file could not be opened or would not decode, found without
     * reading all of its audio. */
    ORCA_HEALTH_ISSUE_KIND_UNREADABLE_FILE = 11,
    /* A verification proposed another recording ID for the file. */
    ORCA_HEALTH_ISSUE_KIND_RECORDING_MISMATCH = 12,
} orca_health_issue_kind;

typedef enum orca_health_severity {
    ORCA_HEALTH_SEVERITY_INFORMATION = 0,
    ORCA_HEALTH_SEVERITY_WARNING = 1,
    ORCA_HEALTH_SEVERITY_ERROR = 2,
} orca_health_severity;

/* What a host offers to resolve an issue. */
typedef enum orca_health_action {
    /* Match the Track against MusicBrainz, or edit its tags. */
    ORCA_HEALTH_ACTION_MATCH_OR_EDIT = 0,
    /* Fetch the Release's cover from the Cover Art Archive. */
    ORCA_HEALTH_ACTION_FETCH_COVER_ART = 1,
    /* Show the two files of a duplicate side by side. */
    ORCA_HEALTH_ACTION_COMPARE_DUPLICATE = 2,
    /* Review the proposed correction. */
    ORCA_HEALTH_ACTION_REVIEW_CORRECTION = 3,
    /* Show the file in the platform's file manager. */
    ORCA_HEALTH_ACTION_REVEAL_FILE = 4,
} orca_health_action;

/* One health issue with what a host needs to act on it. `track_id` is the
 * lowest-numbered Track the file backs and `release_id` that Track's
 * Release; `related_file_id` is the other file of a duplicate. Each id is 0
 * when its `has_*` flag is 0. `kind`, `severity` and `action` are
 * orca_health_issue_kind, orca_health_severity and orca_health_action. `path`
 * is empty when the file has no location on any known volume. */
typedef struct orca_health_item_view {
    int64_t file_id;
    int64_t track_id;
    int64_t release_id;
    int64_t related_file_id;
    uint8_t kind;
    uint8_t severity;
    uint8_t action;
    uint8_t has_track_id;
    uint8_t has_release_id;
    uint8_t has_related_file_id;
    uint8_t reserved[2];
    orca_string_view path;
    orca_string_view details;
} orca_health_item_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_health_item_callback)(
    void *context,
    const orca_health_item_view *item
);

/* One file as a host shows it beside an issue. A value whose `has_*` flag is 0
 * is 0. `missing` is 1 when no location of the file is present, and then
 * `has_path` is 0 and `path` is empty. `codec` is a short identifier such as
 * "flac", empty when the file was never probed. */
typedef struct orca_health_file_view {
    int64_t file_id;
    int64_t size_bytes;
    int64_t duration_ms;
    uint32_t sample_rate;
    uint32_t bit_depth;
    uint32_t channels;
    uint8_t missing;
    uint8_t has_path;
    uint8_t has_size_bytes;
    uint8_t has_duration_ms;
    uint8_t has_sample_rate;
    uint8_t has_bit_depth;
    uint8_t has_channels;
    uint8_t reserved[5];
    orca_string_view path;
    orca_string_view codec;
} orca_health_file_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_health_file_callback)(
    void *context,
    const orca_health_file_view *file
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

/* Counters the Player's engine has kept since it started. */
typedef struct orca_queue_stats {
    /* Entries the engine started by itself: an advance from the entry before,
     * or a start at the cursor of a Player that had nothing loaded. An entry
     * loaded by play, a jump or a skip is not counted. */
    uint64_t entries_started;
    /* Advances that followed the entry before without a gap. */
    uint64_t gapless_transitions;
    /* Advances that waited for the outputs to drain and reopen in the next
     * entry's format. */
    uint64_t format_switch_transitions;
    /* Entries the engine could not open and stepped past. */
    uint64_t open_failures;
    /* Entries whose decoder failed part-way. The entry is ended and the queue
     * moves on rather than stalling; a nonzero count is a real problem worth
     * surfacing. */
    uint64_t decode_errors;
} orca_queue_stats;

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
 * It is an exception to the threading contract: it is called from
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

/* ------------------------------------------------------------ providers */

/*
 * Names the host to MusicBrainz, AcoustID and ListenBrainz, in the User-Agent
 * "name/version ( contact ) liborca/<version>", and in its listen history.
 * Required before matching, AcoustID submission or scrobbling. Each string is
 * non-empty and free of control characters and parentheses, at most 256 bytes
 * together; anything else is ORCA_STATUS_INVALID_ARGUMENT. The strings are
 * copied.
 */
orca_status orca_runtime_set_client_identity(
    orca_runtime *runtime,
    const char *name,
    const char *version,
    const char *contact
);

typedef enum orca_provider_service {
    ORCA_PROVIDER_SERVICE_LISTENBRAINZ = 0,
    ORCA_PROVIDER_SERVICE_MUSICBRAINZ = 1,
    ORCA_PROVIDER_SERVICE_ACOUSTID = 2,
    ORCA_PROVIDER_SERVICE_COVER_ART_ARCHIVE = 3,
} orca_provider_service;

/*
 * Points one provider at a self-hosted or compatible server. `base_url` is
 * `https` to any host, or `http` to 127.0.0.1, [::1] or localhost only,
 * because tokens and the user's library travel in its requests; it carries no
 * user name, password, query or fragment and is at most 2048 bytes. Anything
 * else is ORCA_STATUS_INVALID_ARGUMENT and leaves the server unchanged. The
 * string is copied; NULL restores the provider's public server.
 *
 * ListenBrainz applies from each listen worker's next pass, the others to
 * jobs started afterwards. `service` is an orca_provider_service.
 */
orca_status orca_runtime_set_provider_server(
    orca_runtime *runtime,
    uint8_t service,
    const char *base_url
);

/*
 * The AcoustID application key matching and submission jobs use, unless the
 * credential callback returns one for ORCA_CREDENTIAL_SERVICE_ACOUSTID /
 * ORCA_CREDENTIAL_ACCOUNT_CLIENT_KEY. Without either, matching skips AcoustID.
 * Printable ASCII without spaces, at most 256 bytes; anything else is
 * ORCA_STATUS_INVALID_ARGUMENT. Copied; NULL clears it.
 */
orca_status orca_runtime_set_acoustid_client_key(orca_runtime *runtime, const char *key);

/* The largest secret liborca reads through the credential callback. */
#define ORCA_CREDENTIAL_MAX_BYTES 1024

/* The service and account pairs liborca asks the credential callback for. */
#define ORCA_CREDENTIAL_SERVICE_LISTENBRAINZ "org.listenbrainz"
#define ORCA_CREDENTIAL_ACCOUNT_USER_TOKEN "user-token"
#define ORCA_CREDENTIAL_SERVICE_ACOUSTID "org.acoustid"
#define ORCA_CREDENTIAL_ACCOUNT_CLIENT_KEY "client-key"
#define ORCA_CREDENTIAL_ACCOUNT_USER_KEY "user-key"

typedef enum orca_credential_result {
    ORCA_CREDENTIAL_RESULT_FOUND = 0,
    ORCA_CREDENTIAL_RESULT_NOT_FOUND = 1,
    ORCA_CREDENTIAL_RESULT_UNAVAILABLE = 2,
    ORCA_CREDENTIAL_RESULT_TOO_LARGE = 3,
} orca_credential_result;

/*
 * Credentials: liborca never stores a token or key in a Library, a log or a
 * cache key. It asks the host's secure store - Keychain, Secret Service - for
 * one each time it needs it.
 *
 * liborca calls `callback(context, service, account, buffer, capacity,
 * length)` with NUL-terminated `service` and `account`, such as
 * ORCA_CREDENTIAL_SERVICE_LISTENBRAINZ and ORCA_CREDENTIAL_ACCOUNT_USER_TOKEN.
 * The callback returns:
 *
 * - ORCA_CREDENTIAL_RESULT_FOUND after writing the secret's bytes to
 *   `buffer` and their count to `*length`. The secret is not NUL-terminated.
 * - ORCA_CREDENTIAL_RESULT_NOT_FOUND when the store holds no such secret.
 *   Scrobbling then waits for a token.
 * - ORCA_CREDENTIAL_RESULT_UNAVAILABLE when the store cannot answer, such as
 *   a locked keyring. The listen worker treats it as an error, not absence:
 *   it reports it and asks again later. AcoustID jobs treat it, and
 *   TOO_LARGE, as absence: a lookup uses the application key, and a
 *   submission reports that it needs a user key.
 * - ORCA_CREDENTIAL_RESULT_TOO_LARGE when the secret is longer than
 *   `capacity` (ORCA_CREDENTIAL_MAX_BYTES). Never truncate a secret: FOUND
 *   with `*length` above `capacity` is treated as TOO_LARGE as well.
 *
 * Any other value is treated as UNAVAILABLE. liborca zeroes `buffer` before
 * it frees it, whatever the callback returned.
 *
 * Like the wake callback, it is an exception to the threading contract: it is
 * called from liborca's worker threads - listen workers and provider jobs -
 * and from two of them at once, so it must be thread-safe. It must not call
 * any orca_* function. It may block on the secure store, which delays
 * whatever is waiting for that worker, orca_runtime_destroy included. It is
 * never called after orca_runtime_destroy has returned. `context` must stay
 * valid until then.
 *
 * Call it right after orca_runtime_create: once any worker thread exists (a
 * Player's engine, a job, a listen worker or an artwork loader) it returns
 * ORCA_STATUS_INVALID_STATE. A NULL callback removes the callback, under the
 * same rule. To have liborca read a changed token, call
 * orca_library_scrobbler_credentials_changed instead.
 */
typedef orca_credential_result (*orca_credential_fn)(
    void *context,
    const char *service,
    const char *account,
    uint8_t *buffer,
    size_t capacity,
    size_t *length
);
orca_status orca_runtime_set_credential_callback(
    orca_runtime *runtime,
    orca_credential_fn callback,
    void *context
);

/*
 * Tells the Library's listen worker the ListenBrainz token may have changed.
 * It reads and validates the token once, the next time it could make a
 * request. Call it after the host stores, replaces or deletes the token.
 */
orca_status orca_library_scrobbler_credentials_changed(orca_runtime *runtime, orca_handle library);

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
/* The same page, in the same order, as orca_library_query_health_issues, with
 * the ids and the action a host needs to resolve or dismiss each issue. It
 * supersedes orca_library_query_health_issues for hosts that act on issues.
 * Dismissed issues are not listed. `limit` is 1..512, else
 * ORCA_STATUS_INVALID_ARGUMENT. */
orca_status orca_library_query_health_items(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_health_item_callback callback
);
/* Hides one issue of a file, an orca_health_issue_kind, until the file's bytes
 * change. Dismissing an issue the file does not have still hides it should it
 * appear. An unknown `kind` is ORCA_STATUS_INVALID_ARGUMENT and a `file_id`
 * naming no file ORCA_STATUS_NOT_FOUND. */
orca_status orca_library_dismiss_health_issue(
    orca_runtime *runtime,
    orca_handle library,
    int64_t file_id,
    uint8_t kind
);
/* Shows a dismissed issue again. Restoring an issue that was not dismissed,
 * or of a file that does not exist, changes nothing and returns
 * ORCA_STATUS_OK. An unknown `kind` is ORCA_STATUS_INVALID_ARGUMENT. */
orca_status orca_library_restore_health_issue(
    orca_runtime *runtime,
    orca_handle library,
    int64_t file_id,
    uint8_t kind
);
/* Calls `callback` once with the file behind an issue as the Library last saw
 * it. ORCA_STATUS_NOT_FOUND, with the callback not called, when no file has
 * `file_id`. Reads the database alone, never the file. */
orca_status orca_library_health_file(
    orca_runtime *runtime,
    orca_handle library,
    int64_t file_id,
    void *context,
    orca_health_file_callback callback
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

/* A sorted, filtered page of Releases. `query` may not be null;
 * INVALID_ARGUMENT for a limit outside 1..512 or an unknown sort. */
orca_status orca_library_browse_releases(
    orca_runtime *runtime,
    orca_handle library,
    const orca_release_query *query,
    void *context,
    orca_release_callback callback
);
/* How many Releases orca_library_browse_releases would list for `query`.
 * Sort, limit and offset are ignored. */
orca_status orca_library_release_count_matching(
    orca_runtime *runtime,
    orca_handle library,
    const orca_release_query *query,
    uint64_t *output
);

/* A filtered page of Artists in sort-name order. `query` may not be null;
 * INVALID_ARGUMENT for a limit outside 1..512, or a null filter pointer with
 * a nonzero length. */
orca_status orca_library_browse_artists(
    orca_runtime *runtime,
    orca_handle library,
    const orca_artist_query *query,
    void *context,
    orca_artist_callback callback
);
/* How many Artists orca_library_browse_artists would list for `query`.
 * Limit and offset are ignored. */
orca_status orca_library_artist_count_matching(
    orca_runtime *runtime,
    orca_handle library,
    const orca_artist_query *query,
    uint64_t *output
);

/* Invokes the callback once with the Track and the ids it resolves to.
 * NOT_FOUND, without a callback, when no such Track exists. */
orca_status orca_library_track_get(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_track_summary_callback callback
);
/* Invokes the callback once with what the Library recorded about the Track
 * and its file. Reads the database alone. NOT_FOUND, without a callback, when
 * no such Track exists. */
orca_status orca_library_track_details(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_track_details_callback callback
);
/* How often the Track's file has been heard, and when last. A Track with no
 * file, or an unknown id, has a play count of zero. */
orca_status orca_library_track_play_stats(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    orca_play_stats *output
);
/* Listens recorded since the Library was opened: one atomic load, so a host
 * may poll it every tick to learn when to reread its history. */
orca_status orca_library_listens_recorded(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t *output
);
/* Sets, or with ORCA_FEEDBACK_NONE clears, the feedback on the recordings of
 * `track_ids`: at most 512 ids; INVALID_ARGUMENT for more, for a null `ids`
 * with a nonzero `count`, and for a `feedback` that is not an orca_feedback.
 * Zero ids succeed with zero counts. The feedback is kept in the Library and
 * queued for ListenBrainz, which is sent when listens are submitted; a clear
 * is queued too, but only where an earlier love or hate had already been
 * sent. A Track whose recording has no MusicBrainz id keeps the feedback
 * locally and queues nothing. `skipped` counts ids that name no Track;
 * `updated` counts Tracks whose feedback changed, so clearing feedback that
 * was never set updates nothing. */
orca_status orca_library_set_feedback(
    orca_runtime *runtime,
    orca_handle library,
    const int64_t *track_ids,
    size_t count,
    uint8_t feedback,
    orca_change_count *output
);
/* The Track's feedback, as an orca_feedback. A Track with none, or an unknown
 * id, reports ORCA_FEEDBACK_NONE. */
orca_status orca_library_track_feedback(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    uint8_t *feedback
);
/* Rates the recordings of `track_ids`: `rating` 1..100 sets it, 0 clears it,
 * anything above 100 is INVALID_ARGUMENT. At most 512 ids; INVALID_ARGUMENT
 * for more or for a null `ids` with a nonzero `count`. Zero ids succeed with
 * zero counts. Ratings are kept in the Library; no file is written and
 * nothing is sent. `skipped` counts ids that name no Track; `updated` counts
 * Tracks that were rated, or that had a rating to clear.
 * A host showing whole stars stores N stars as N * 20 (orca-cli rate
 * --stars) and shows a rating of r as r / 20 rounded to the nearest star,
 * between 1 and 5. */
orca_status orca_library_set_rating(
    orca_runtime *runtime,
    orca_handle library,
    const int64_t *track_ids,
    size_t count,
    uint8_t rating,
    orca_change_count *output
);
/* Loves (`loved` 1) or clears (`loved` 0) whole Releases; any other value is
 * INVALID_ARGUMENT. At most 512 ids; INVALID_ARGUMENT for more or for a null
 * `ids` with a nonzero `count`. Zero ids succeed with zero counts. Album love
 * is kept in the Library only and is never sent to ListenBrainz. `skipped`
 * counts ids that name no Release; `updated` counts Releases whose love
 * changed. */
orca_status orca_library_set_release_love(
    orca_runtime *runtime,
    orca_handle library,
    const int64_t *release_ids,
    size_t count,
    uint8_t loved,
    orca_change_count *output
);
/* Files that still owe the default loudness and fingerprint measurement:
 * what orca_library_start_analysis would measure. */
orca_status orca_library_unanalyzed_count(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t *output
);

/* ------------------------------------------------------------ playlists */

/* A playlist is a name and an ordered list of entries, kept in the Library.
 * Each entry names a recording; one recording may appear several times.
 * Positions run from 0 to `entries` - 1 without gaps. A playlist holds at
 * most 10,000 entries. */
typedef struct orca_playlist_view {
    int64_t id;
    /* Sum of the lengths of the available entries. */
    int64_t duration_ms;
    /* Unix seconds. `updated_at` moves on a rename and on any entry edit. */
    int64_t created_at;
    int64_t updated_at;
    uint32_t entries;
    /* Entries whose recording still has a Track; only these play or export. */
    uint32_t available;
    orca_string_view name;
} orca_playlist_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_playlist_callback)(void *context, const orca_playlist_view *playlist);

/* One entry. It plays the Track of its recording with the lowest id; when the
 * recording has no Track left, `has_track` is 0 and `track` is zeroed. */
typedef struct orca_playlist_entry_view {
    int64_t recording_id;
    uint32_t position;
    uint8_t has_track;
    uint8_t reserved[3];
    orca_track_view track;
} orca_playlist_entry_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_playlist_entry_callback)(
    void *context,
    const orca_playlist_entry_view *entry
);

/* What orca_library_import_playlist created. */
typedef struct orca_playlist_import {
    int64_t playlist_id;
    /* Entries matched by their path to a location the Library knows. */
    uint32_t matched_by_path;
    /* Entries matched by their #EXTINF artist, title and length. */
    uint32_t matched_by_info;
    /* Entries that matched nothing and were left out. */
    uint32_t unmatched;
    uint32_t reserved;
} orca_playlist_import;

/* `line` is valid only for the duration of this callback. */
typedef void (*orca_line_callback)(void *context, orca_string_view line);

/* How orca_library_export_playlist writes each path. */
typedef enum orca_playlist_path_style {
    ORCA_PLAYLIST_PATH_ABSOLUTE = 0,
    /* Relative to the folder of the exported file. */
    ORCA_PLAYLIST_PATH_RELATIVE = 1,
} orca_playlist_path_style;

/* Playlists ordered by name. `limit` must be between 1 and 512. */
orca_status orca_library_query_playlists(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_playlist_callback callback
);
/* `name` is `name_length` bytes, not NUL-terminated, and may be NULL only when
 * `name_length` is 0. Names are trimmed of whitespace; an empty name is
 * INVALID_ARGUMENT, and one another playlist already has is INVALID_STATE. */
orca_status orca_library_create_playlist(
    orca_runtime *runtime,
    orca_handle library,
    const char *name,
    size_t name_length,
    int64_t *playlist_id
);
/* Names as for orca_library_create_playlist. NOT_FOUND for an unknown id. */
orca_status orca_library_rename_playlist(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    const char *name,
    size_t name_length
);
/* Deletes the playlist and its entries; no Track or file is touched.
 * NOT_FOUND for an unknown id. */
orca_status orca_library_delete_playlist(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id
);
/* Entries in position order. `limit` must be between 1 and 512. NOT_FOUND for
 * an unknown playlist. */
orca_status orca_library_query_playlist_entries(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_playlist_entry_callback callback
);
/* Adds the recordings of `track_ids`, in order, before position `at`, or at
 * the end when `at` is negative; `at` past the end is INVALID_ARGUMENT. At
 * most 512 ids; INVALID_ARGUMENT for more or for a null `track_ids` with a
 * nonzero `count`. In `output`, `updated` counts the entries added and
 * `skipped` the ids that name no Track or a Track with no recording. An
 * insert that would take the playlist past 10,000 entries is INVALID_STATE
 * and adds nothing. NOT_FOUND for an unknown playlist. */
orca_status orca_library_playlist_insert(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    const int64_t *track_ids,
    size_t count,
    int64_t at,
    orca_change_count *output
);
/* Removes the entries at `positions` (repeats count once) and renumbers the
 * rest. At most 512 positions; INVALID_ARGUMENT for more, for a null
 * `positions` with a nonzero `count`, and for a position past the end, which
 * removes nothing. `removed` receives the number of entries removed. */
orca_status orca_library_playlist_remove(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    const uint32_t *positions,
    size_t count,
    uint32_t *removed
);
/* Moves the entry at `from` to `to`, shifting those between. INVALID_ARGUMENT
 * when either is past the end; NOT_FOUND for an unknown playlist. */
orca_status orca_library_playlist_move(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    uint32_t from,
    uint32_t to
);
/* Creates a playlist from the M3U or M3U8 file at `path` (`path_length` bytes,
 * not NUL-terminated; relative to the working directory unless absolute).
 * Each entry is matched by path to a location the Library knows, then by its
 * #EXTINF artist, title and length; nothing is scanned, so a path the Library
 * has not seen is unmatched. The playlist is named `name` (`name_length`
 * bytes), or after the file without its extension when `name` is NULL and
 * `name_length` is 0; a taken name gets " (2)", " (3)" and so on.
 * `unmatched`, when not NULL, is called with each of the first 50 unmatched
 * lines after `output` is written. NOT_FOUND when the file does not exist;
 * INVALID_STATE for a file with no entry; INVALID_ARGUMENT for an empty
 * `path`, an empty `name`, or a file over 4 MiB or 10,000 entries, which
 * creates nothing. */
orca_status orca_library_import_playlist(
    orca_runtime *runtime,
    orca_handle library,
    const char *path,
    size_t path_length,
    const char *name,
    size_t name_length,
    orca_playlist_import *output,
    void *context,
    orca_line_callback unmatched
);
/* Writes the playlist's available entries to `path` (`path_length` bytes, not
 * NUL-terminated) as extended M3U in UTF-8, with each entry's length, artist,
 * title and the path of the location playback would open. `path_style` is an
 * orca_playlist_path_style. The file is written beside the target, synced and
 * renamed over it, so a reader sees the old file or the new one. An existing
 * file is INVALID_STATE unless `replace` is 1; `replace` above 1 is
 * INVALID_ARGUMENT. NOT_FOUND when the folder does not exist or the playlist
 * is unknown. `written` counts the entries written; `skipped` counts entries
 * with no Track and paths containing a line break. */
orca_status orca_library_export_playlist(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    const char *path,
    size_t path_length,
    uint8_t path_style,
    uint8_t replace,
    uint32_t *written,
    uint32_t *skipped
);

/* -------------------------------------------------------------- artwork */

/* What an embedded picture says it shows. */
typedef enum orca_artwork_kind {
    ORCA_ARTWORK_KIND_FRONT_COVER = 0,
    ORCA_ARTWORK_KIND_BACK_COVER = 1,
    ORCA_ARTWORK_KIND_OTHER = 2,
} orca_artwork_kind;

/* What an artwork request asks about: a Track or a Release id. */
typedef enum orca_artwork_subject {
    ORCA_ARTWORK_SUBJECT_TRACK = 0,
    ORCA_ARTWORK_SUBJECT_RELEASE = 1,
} orca_artwork_subject;

/* One cover image. `bytes` and `mime_type` are valid only for the duration of
 * the callback that receives the view; copy what you keep. `mime_type` is
 * resolved from the bytes, not from what the file claimed: "image/jpeg",
 * "image/png" and so on. `kind` is an orca_artwork_kind. */
typedef struct orca_image_view {
    const uint8_t *bytes;
    size_t length;
    orca_string_view mime_type;
    uint8_t kind;
    uint8_t reserved[7];
} orca_image_view;

typedef void (*orca_image_callback)(void *context, const orca_image_view *image);

/* One finished artwork request. `subject` is an orca_artwork_subject and
 * `subject_id` the Track or Release id it was asked for. A subject with no
 * readable cover arrives with `has_image` 0 and an `image` of length 0. */
typedef struct orca_artwork_result_view {
    uint64_t request;
    int64_t subject_id;
    uint8_t subject;
    uint8_t has_image;
    uint8_t reserved[6];
    orca_image_view image;
} orca_artwork_result_view;

/* The image is valid only for the duration of this callback. */
typedef void (*orca_artwork_result_callback)(
    void *context,
    const orca_artwork_result_view *result
);

/* Invokes the callback once with the cover embedded in the Track's file, or
 * else the one fetched for its Release. Runs on the calling thread and reads
 * the file there, so a UI thread uses orca_library_request_artwork instead.
 * NOT_FOUND, without a callback, when the Track, its file or a cover is
 * missing. */
orca_status orca_library_track_artwork(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_image_callback callback
);
/* As orca_library_track_artwork, for a Release: the cover of its first Track
 * in disc and track order that has one (at most eight files are opened), or
 * else the one fetched for the Release. An embedded cover beats a fetched
 * one. */
orca_status orca_library_release_artwork(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    void *context,
    orca_image_callback callback
);
/* Asks for the cover of a Track or Release (`subject`, an
 * orca_artwork_subject, and its `id`) without waiting for it. The lookup runs
 * on the Library's artwork thread, which is started on the first request;
 * when it finishes, liborca calls the wake callback, and the host collects
 * the result with orca_library_take_artwork after its next pump. `request`
 * receives an id that the result carries. At most 64 requests per Library
 * are outstanding, queued, in progress or finished and not yet taken
 * together; beyond that this is BUSY, and the host asks again after taking
 * results. INVALID_ARGUMENT for an unknown `subject`. */
orca_status orca_library_request_artwork(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t subject,
    int64_t id,
    uint64_t *request
);
/* A request that has not started is skipped without reading a file and never
 * arrives; one already finished still arrives from orca_library_take_artwork
 * and should be discarded. OK for any `request`, including an unknown one;
 * STALE_HANDLE for a closed Library. */
orca_status orca_library_cancel_artwork(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t request
);
/* Invokes the callback once with the oldest finished artwork request and
 * releases it. NOT_FOUND, without a callback, when none has finished. A host
 * calls this until NOT_FOUND after each wake. */
orca_status orca_library_take_artwork(
    orca_runtime *runtime,
    orca_handle library,
    void *context,
    orca_artwork_result_callback callback
);

/* ------------------------------------------------- tag edits and writes */

/* A field Orca can keep its own value for, apart from what the file says. */
typedef enum orca_metadata_field {
    ORCA_METADATA_FIELD_TITLE = 0,
    ORCA_METADATA_FIELD_ARTIST = 1,
    ORCA_METADATA_FIELD_ALBUM = 2,
    ORCA_METADATA_FIELD_TRACK_NUMBER = 3,
    ORCA_METADATA_FIELD_ALBUM_ARTIST = 4,
    ORCA_METADATA_FIELD_DISC_NUMBER = 5,
    ORCA_METADATA_FIELD_DATE = 6,
    ORCA_METADATA_FIELD_COMPILATION = 7,
    ORCA_METADATA_FIELD_MUSICBRAINZ_RECORDING_ID = 8,
    ORCA_METADATA_FIELD_MUSICBRAINZ_RELEASE_ID = 9,
    ORCA_METADATA_FIELD_MUSICBRAINZ_RELEASE_GROUP_ID = 10,
    ORCA_METADATA_FIELD_MUSICBRAINZ_RELEASE_TRACK_ID = 11,
    ORCA_METADATA_FIELD_MUSICBRAINZ_ALBUM_ARTIST_ID = 12,
} orca_metadata_field;

/* Where one of Orca's values came from. */
typedef enum orca_provenance {
    ORCA_PROVENANCE_OBSERVED_FILE = 0,
    /* An edit, from orca_library_edit_tracks. */
    ORCA_PROVENANCE_USER = 1,
    /* An accepted MusicBrainz or AcoustID match. */
    ORCA_PROVENANCE_PROVIDER = 2,
    ORCA_PROVENANCE_INFERENCE = 3,
    ORCA_PROVENANCE_ANALYSIS = 4,
} orca_provenance;

/* One change of orca_library_edit_tracks. `field` is an orca_metadata_field.
 * With `has_value` set, `value` becomes Orca's value for the field, locked so
 * that an accepted match does not replace it; with `has_value` 0, Orca's value
 * is removed and the file's own tag applies again. A value is UTF-8 of 1 to
 * 4096 bytes; a track or disc number is a decimal from 1 to 9999, a
 * compilation "0" or "1", and a MusicBrainz id a lowercase UUID. */
typedef struct orca_track_edit {
    uint8_t field;
    uint8_t has_value;
    uint8_t reserved[6];
    orca_string_view value;
} orca_track_edit;

/* `ids` is valid only for the duration of this callback. */
typedef void (*orca_id_callback)(void *context, const int64_t *ids, size_t count);

/* Sets or clears Orca's own values for the files behind 1 to 512 Tracks
 * (`ids`, `count`) and reprojects them. `edits` holds 1 to 64 changes. Only
 * the Library changes: no file is written until a tag write of them is
 * approved. An edit can move a Track to another Release or position, which
 * gives it a new id, so `callback`, unless NULL, is invoked once with the ids
 * of the Tracks the edited files back afterwards. INVALID_ARGUMENT for a bad
 * id list, an unknown field or an invalid value, and NOT_FOUND for a Track
 * with no file; both change nothing. */
orca_status orca_library_edit_tracks(
    orca_runtime *runtime,
    orca_handle library,
    const int64_t *ids,
    size_t count,
    const orca_track_edit *edits,
    size_t edit_count,
    void *context,
    orca_id_callback callback
);

/* One of Orca's values for a file. `field` is an orca_metadata_field and
 * `provenance` an orca_provenance. `locked` is set for a value no match may
 * replace, such as an edit. */
typedef struct orca_field_value_view {
    uint8_t field;
    uint8_t provenance;
    uint8_t locked;
    uint8_t reserved[5];
    orca_string_view text;
} orca_field_value_view;

/* The text is valid only for the duration of this callback. */
typedef void (*orca_field_value_callback)(void *context, const orca_field_value_view *value);

/* Invokes the callback once for each value Orca holds for the Track's first
 * file, edits and accepted matches alike, and not at all when it holds none.
 * These are Orca's values, not what the file says. NOT_FOUND for a Track with
 * no file. */
orca_status orca_library_query_track_edits(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_field_value_callback callback
);

#define ORCA_TAG_WRITE_DIGEST_BYTES 32

/* A plan's approval digest: a BLAKE3 hash of the plan id and, for each file,
 * its path, its identity when planned, and every field's value before and
 * after. A write starts only with the digest of the plan a person was shown,
 * so it writes exactly what was approved. */
typedef struct orca_tag_write_digest {
    uint8_t bytes[ORCA_TAG_WRITE_DIGEST_BYTES];
} orca_tag_write_digest;

/* One field a plan changes in one file. `field` is an orca_metadata_field and
 * `provenance` the orca_provenance of Orca's value: USER for an edit,
 * PROVIDER for an accepted match. `before` is what the file's tag says now,
 * when `has_before` is set, and `after` what the write puts there. */
typedef struct orca_tag_write_change_view {
    uint8_t field;
    uint8_t provenance;
    uint8_t has_before;
    uint8_t reserved[5];
    orca_string_view before;
    orca_string_view after;
} orca_tag_write_change_view;

/* A file the plan writes, at `path`, with its `change_count` changes. */
typedef struct orca_tag_write_file_view {
    int64_t file_id;
    orca_string_view path;
    const orca_tag_write_change_view *changes;
    size_t change_count;
} orca_tag_write_file_view;

/* A value of Orca's that the plan does not write, because the file's own tag
 * says something else (`file_value`) and Orca's value (`orca_value`) is not
 * locked. Editing the field to Orca's value locks it, and the next plan
 * writes it. */
typedef struct orca_tag_write_conflict_view {
    int64_t file_id;
    uint8_t field;
    uint8_t provenance;
    uint8_t reserved[6];
    orca_string_view path;
    orca_string_view file_value;
    orca_string_view orca_value;
} orca_tag_write_conflict_view;

/* Why a plan leaves a file out. */
typedef enum orca_tag_write_skip_reason {
    /* No location of the file is present to write to. */
    ORCA_TAG_WRITE_SKIP_MISSING = 0,
    /* Orca has no tag writer for the file's format. FLAC, MP3 and ADTS are
     * written; M4A, Ogg, WAV and AIFF are not. */
    ORCA_TAG_WRITE_SKIP_FORMAT_NOT_WRITABLE = 1,
    /* The file's bytes changed after the last scan, so the plan would describe
     * tags the file no longer has. Scan it first. */
    ORCA_TAG_WRITE_SKIP_CHANGED_SINCE_SCAN = 2,
} orca_tag_write_skip_reason;

/* A file the plan leaves out. `reason` is an orca_tag_write_skip_reason;
 * `path` is empty when the file has no present location. */
typedef struct orca_tag_write_skip_view {
    int64_t file_id;
    uint8_t reason;
    uint8_t reserved[7];
    orca_string_view path;
} orca_tag_write_skip_view;

/* A tag-write plan for a person to approve. Every array and string in it is
 * valid only for the duration of the callback. `plan_id` 0 means there is
 * nothing to write and nothing is held; any other plan is held until it is
 * started or discarded, or its Library is closed. */
typedef struct orca_tag_write_plan_view {
    uint64_t plan_id;
    orca_tag_write_digest digest;
    const orca_tag_write_file_view *files;
    size_t file_count;
    const orca_tag_write_conflict_view *conflicts;
    size_t conflict_count;
    const orca_tag_write_skip_view *skipped;
    size_t skip_count;
} orca_tag_write_plan_view;

typedef void (*orca_tag_write_plan_callback)(
    void *context,
    const orca_tag_write_plan_view *plan
);

/* Plans writing Orca's values into the tags of the files behind 1 to 512
 * Tracks and invokes the callback once with the plan. Nothing is written.
 * Planning reads each file on the calling thread. The runtime holds at most
 * eight plans; BUSY means one must be started or discarded first. Closing the
 * Library or destroying the runtime discards the plans it holds. NOT_FOUND
 * for a Track with no file. */
orca_status orca_library_plan_tag_write(
    orca_runtime *runtime,
    orca_handle library,
    const int64_t *ids,
    size_t count,
    void *context,
    orca_tag_write_plan_callback callback
);
/*
 * Approves held plan `plan_id` with the digest its view carried and starts
 * writing it as an ORCA_JOB_KIND_MUTATION job.
 *
 * At every point of a write, either a file's original bytes are in place or
 * a durable, verified copy of them is. Each step is journaled in the Library
 * before the filesystem changes: the complete replacement is staged beside
 * the file and fsynced, the original is copied to a backup under
 * `<database>.orca-backups`, fsynced and verified, and only then is the
 * replacement renamed over the file. A write interrupted by a crash is rolled
 * back as a whole when the Library is next opened, or, for a file that matches
 * neither its original nor the write, recorded as needing reconciliation with
 * every file kept. The backup stays until the write is undone or pruned.
 *
 * The job cannot be cancelled: orca_job_cancel does not stop it, and closing
 * the Library or destroying the runtime waits for it. It SUCCEEDS when every
 * file was written. It FAILS when the write did not complete, or an earlier
 * interrupted write could not be recovered first; what it had written is then
 * rolled back as recovery does. Either way the files are read again and
 * reprojected afterwards. Its
 * orca_scan_stats has `files_seen` the files planned, `changed` those
 * written, and `errors` nonzero when it failed or a file could not be read
 * again afterwards. The plan id is the group orca_library_undo_tag_write
 * takes.
 *
 * INVALID_ARGUMENT for a NULL `digest` or `job`, or a digest that is not the
 * plan's; the plan stays held and unwritten. NOT_FOUND for a plan that is not
 * held. INVALID_STATE for a Library with no database file, which has nowhere
 * to keep backups. BUSY while another write, undo or prune, in this process
 * or another, holds the Library's mutation journal; the plan stays held.
 */
orca_status orca_library_start_tag_write(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t plan_id,
    const orca_tag_write_digest *digest,
    orca_handle *job
);
/* Drops a held plan without writing anything. NOT_FOUND for a plan that is
 * not held. */
orca_status orca_library_discard_tag_write(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t plan_id
);
/*
 * Restores the files of tag write `group_id`, its plan id, from their
 * backups to their bytes before the write, on the calling thread, deletes
 * the backups, and reads the files again. Orca's values are kept, so the
 * Library still shows the edits and a later plan would write them again.
 *
 * OK when the files are restored. ALREADY_DONE when the write was already
 * undone; the files are read again all the same. NEEDS_RECONCILIATION when a
 * file changed since the write, or its backup is missing or no longer the
 * original: no such file is overwritten, and the write is recorded as needing
 * a person's decision. GONE when the write's backups were pruned; nothing
 * changes. BUSY while that write is still running, or while another write,
 * undo or prune holds the Library's mutation journal. INVALID_ARGUMENT for
 * group 0, NOT_FOUND for a group that was never written, and INVALID_STATE
 * for a write that never committed, a Library with no database file, or an
 * interrupted write whose folder is not there, most likely an unmounted
 * drive; recovery resumes once it is back.
 */
orca_status orca_library_undo_tag_write(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t group_id
);
/* Deletes the backups of every tag write whose files all committed at least
 * `older_than_s` seconds ago; 0 prunes every committed write. This forfeits
 * undo: orca_library_undo_tag_write returns GONE for a pruned write. Writes
 * needing reconciliation keep their backups, an undone write has none left,
 * and nothing is ever pruned automatically. `backups` and `bytes` receive how
 * many backups were deleted and their total size. BUSY while the Library's
 * mutation journal is held; INVALID_STATE for a Library with no database
 * file, or while an interrupted write's folder is not there. */
orca_status orca_library_prune_tag_write_backups(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t older_than_s,
    uint64_t *backups,
    uint64_t *bytes
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
/* Replaces the queue with the playlist's available entries, from the Library
 * the Player is bound to, and starts at `start`, which counts available
 * entries only. Synchronous, like orca_player_play_tracks. INVALID_STATE for
 * a Player with no Library and for a playlist with no available entry, which
 * leaves the queue as it was; NOT_FOUND for an unknown playlist;
 * INVALID_ARGUMENT for a `start` past the last available entry. */
orca_status orca_player_play_playlist(
    orca_runtime *runtime,
    orca_handle player,
    int64_t playlist_id,
    uint32_t start
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

/*
 * The Player's ten-band equalizer: peaking filters one octave apart (Q 1.41)
 * centred, from band 0 to band 9, on 31, 62, 125, 250, 500, 1000, 2000, 4000,
 * 8000 and 16000 Hz. A band at or above the source's Nyquist frequency is
 * skipped. It runs on canonical PCM before fanout, after the preamp and before
 * crossfeed and the volume, so every Zone hears the same result.
 */
#define ORCA_EQUALIZER_BANDS 10
/* Each band's gain lies in [-ORCA_EQUALIZER_MAX_GAIN_DB,
 * ORCA_EQUALIZER_MAX_GAIN_DB] dB. */
#define ORCA_EQUALIZER_MAX_GAIN_DB 12
/* The preamp lies in [ORCA_EQUALIZER_MIN_PREAMP_DB,
 * ORCA_EQUALIZER_MAX_PREAMP_DB] dB. */
#define ORCA_EQUALIZER_MIN_PREAMP_DB (-24)
#define ORCA_EQUALIZER_MAX_PREAMP_DB 12

typedef struct orca_equalizer {
    /* dB per band, indexed as listed above; 0 leaves a band flat. */
    float gains_db[ORCA_EQUALIZER_BANDS];
    /* dB applied before the bands, to leave headroom for a boost. */
    float preamp_db;
} orca_equalizer;

typedef enum orca_equalizer_preset {
    ORCA_EQUALIZER_PRESET_FLAT = 0,
    ORCA_EQUALIZER_PRESET_BASS = 1,
    ORCA_EQUALIZER_PRESET_TREBLE = 2,
    ORCA_EQUALIZER_PRESET_VOCAL = 3,
    ORCA_EQUALIZER_PRESET_LOUDNESS = 4,
} orca_equalizer_preset;

/* Writes the gains of an orca_equalizer_preset to `output`, with the preamp
 * at minus the largest boost, or 0 when no band boosts. Pure: it takes no
 * runtime, is callable from any thread, and so leaves no last error.
 * INVALID_ARGUMENT for an unknown preset or a NULL output. */
orca_status orca_equalizer_preset_get(uint8_t preset, orca_equalizer *output);

/* Turns the equalizer on with `equalizer`, or off with NULL. INVALID_ARGUMENT,
 * with the previous setting kept, when a gain or the preamp is outside its
 * range or not a finite number. An equalizer with every band and the preamp at
 * 0 is on but transparent: it is not sample processing. The engine is paused
 * while the setting is written, and applies it from its next pass. */
orca_status orca_player_set_equalizer(
    orca_runtime *runtime,
    orca_handle player,
    const orca_equalizer *equalizer
);
/* `enabled` receives 1 and `output` the setting while the equalizer is on;
 * `enabled` 0 leaves `output` zeroed. */
orca_status orca_player_equalizer(
    orca_runtime *runtime,
    orca_handle player,
    orca_equalizer *output,
    uint8_t *enabled
);

/* Stereo crossfeed, which blends some of each channel into the other for
 * headphone listening. `enabled` 0 turns it off and `amount` is ignored;
 * otherwise `amount` lies in [0, 1], and anything else, NaN included, is
 * INVALID_ARGUMENT. It applies to two-channel audio only; other layouts pass
 * through. */
orca_status orca_player_set_crossfeed(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t enabled,
    float amount
);
/* `amount` receives 0 when crossfeed is off. */
orca_status orca_player_crossfeed(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t *enabled,
    float *amount
);

typedef enum orca_sample_format {
    ORCA_SAMPLE_FORMAT_UNSIGNED_8 = 0,
    ORCA_SAMPLE_FORMAT_SIGNED_16 = 1,
    ORCA_SAMPLE_FORMAT_SIGNED_24 = 2,
    ORCA_SAMPLE_FORMAT_SIGNED_32 = 3,
    ORCA_SAMPLE_FORMAT_FLOAT_32 = 4,
    ORCA_SAMPLE_FORMAT_FLOAT_64 = 5,
} orca_sample_format;

typedef struct orca_pcm_format {
    uint32_t sample_rate;
    uint16_t channels;
    uint16_t bits_per_sample;
    uint16_t bytes_per_frame;
    uint8_t sample_format;  /* orca_sample_format */
    uint8_t reserved[1];
} orca_pcm_format;

/* Why a signal path is not bit-perfect. */
typedef enum orca_signal_reason {
    /* The equalizer, crossfeed, a volume other than 1 or a ReplayGain
     * correction changes the samples. */
    ORCA_SIGNAL_REASON_SAMPLE_PROCESSING = 0,
    /* The output, or the device behind it, runs at another rate. */
    ORCA_SIGNAL_REASON_SAMPLE_RATE_CONVERSION = 1,
    /* The output has another channel count than the source. */
    ORCA_SIGNAL_REASON_CHANNEL_LAYOUT_CONVERSION = 2,
    /* The output's sample format differs from the source's, other than an
     * exact widening of 8-, 16- or 24-bit integers to float32. */
    ORCA_SIGNAL_REASON_SAMPLE_FORMAT_CONVERSION = 3,
    /* The source's codec discarded audio before Orca decoded it. */
    ORCA_SIGNAL_REASON_LOSSY_SOURCE = 4,
} orca_signal_reason;

/* The capacity of orca_signal_path_view.reasons; more than the reasons that
 * exist today, so new ones fit without a layout change. */
#define ORCA_SIGNAL_MAX_REASONS 8

/* What the audio being heard passes through on its way to the output. */
typedef struct orca_signal_path_view {
    /* The decoder's source format, before conversion to canonical float32.
     * Valid when `has_source`; see `source_declared`. */
    orca_pcm_format source;
    /* What the output stream was opened with. Valid when `has_output`, which
     * is 0 while no output is open. */
    orca_pcm_format output;
    /* Valid when `has_equalizer`. */
    orca_equalizer equalizer;
    /* The correction applied to the audible entry in dB. Valid when
     * `has_replay_gain`, which is 0 when the correction is exactly 1. */
    float replay_gain_db;
    /* Valid when `has_crossfeed`. */
    float crossfeed;
    /* The linear gain being applied now, not the target it ramps toward. */
    float volume;
    /* The rate the output device runs at, as the backend reports it. Valid
     * when `has_device_rate`. It differs from output.sample_rate when the
     * backend resamples. */
    uint32_t device_rate;
    /* The first `reason_count` entries of `reasons` are orca_signal_reason
     * values; zero when the path is bit-perfect eligible. */
    uint32_t reason_count;
    uint8_t reasons[ORCA_SIGNAL_MAX_REASONS];
    uint8_t has_source;
    /* 0 when the decoder declared no source format: `source` then holds the
     * canonical format, and only its rate and channels are meaningful. */
    uint8_t source_declared;
    uint8_t has_output;
    uint8_t has_replay_gain;
    uint8_t has_equalizer;
    uint8_t has_crossfeed;
    uint8_t has_device_rate;
    /* 0 as soon as any reason applies. With no source or no output the
     * format conversions cannot be judged, so only sample processing
     * counts. */
    uint8_t bit_perfect_eligible;
    /* The integer source reaches float32 unchanged, which is not a reason. */
    uint8_t widened_exactly;
    uint8_t reserved[7];
    /* Canonical codec identifier of the source, such as "flac"; empty when
     * nothing is audible. */
    orca_string_view codec;
} orca_signal_path_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_signal_path_callback)(
    void *context,
    const orca_signal_path_view *signal_path
);

/* Invokes the callback once with the Player's signal path, and whether it
 * could be bit-perfect. The source, codec and ReplayGain figure are the
 * audible entry's. The engine is paused while they are read. */
orca_status orca_player_signal_path(
    orca_runtime *runtime,
    orca_handle player,
    void *context,
    orca_signal_path_callback callback
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
/* The queue's Tracks as track views, read from the Library the Player is
 * bound to, in playback order starting at position `offset`. `limit` must be
 * between 1 and 512. An entry whose Track has since left the Library is
 * skipped, so the views after it no longer line up with queue positions;
 * orca_player_query_queue gives every position. ORCA_STATUS_INVALID_STATE
 * when the Player has no Library. Strings are valid only for the callback. */
orca_status orca_player_query_queue_tracks(
    orca_runtime *runtime,
    orca_handle player,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_track_callback callback
);
/* Plays the entry at playback position `position` now: a hard switch, like a
 * skip. ORCA_STATUS_INVALID_ARGUMENT when `position` is not below the queue
 * length. */
orca_status orca_player_queue_jump(
    orca_runtime *runtime,
    orca_handle player,
    uint32_t position
);
/* Queues `ids` to play after the current entry without interrupting it. If
 * the engine has already lined up the entry after the current one -- it does
 * so a few seconds before the current one ends -- they follow that entry
 * instead. An empty queue is filled as orca_player_enqueue_tracks fills it.
 * ORCA_STATUS_INVALID_STATE when the Player has no Library. */
orca_status orca_player_queue_insert_next(
    orca_runtime *runtime,
    orca_handle player,
    const int64_t *ids,
    size_t count
);
/* Removes the entry at playback position `position`.
 * ORCA_STATUS_INVALID_STATE for the entry playing and for one the engine has
 * already lined up after it; skip past them first.
 * ORCA_STATUS_INVALID_ARGUMENT when `position` is not below the queue
 * length. */
orca_status orca_player_queue_remove(
    orca_runtime *runtime,
    orca_handle player,
    uint32_t position
);
/* Reads the engine's counters, stopping the engine while it does: call it
 * after a run or for diagnostics, never in a UI poll loop. All zero before
 * the Player has played anything. */
orca_status orca_player_queue_stats(
    orca_runtime *runtime,
    orca_handle player,
    orca_queue_stats *output
);

/* -------------------------------------------------------- devices, zones */

orca_status orca_enumerate_output_devices(
    orca_runtime *runtime,
    void *context,
    orca_device_callback callback
);

orca_status orca_zone_create(orca_runtime *runtime, orca_handle *output);
orca_status orca_zone_destroy(orca_runtime *runtime, orca_handle zone);
/* Attaching a Zone to another Player closes its output and discards the
 * previous Player's prepared audio before returning; the new Player reopens
 * the output in its own format. Attaching it to the Player it is already on
 * changes nothing. */
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
/* A Zone whose output is FAILED stays failed. Closing its output and, once its
 * status reports CLOSED, opening it again retries with fresh attempts. */
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
