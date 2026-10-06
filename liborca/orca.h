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
     * holds its mutation journal or is walking it. Backpressure, not failure. */
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
     * person to decide; it never claims a rollback it could not do. Also a
     * Release whose values differ from the release a person would mark it
     * reviewed against. */
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

/* What orca_player_restore_state does with the saved queue: load it paused,
 * load it and play, or leave the Player as it is. */
typedef enum orca_restore_mode {
    ORCA_RESTORE_MODE_PAUSED = 0,
    ORCA_RESTORE_MODE_PLAYING = 1,
    ORCA_RESTORE_MODE_NONE = 2,
} orca_restore_mode;

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
    /* Held at its next cancellation poll by orca_job_pause or
     * orca_library_pause_jobs; it keeps its thread until resumed or
     * cancelled. */
    ORCA_JOB_PAUSED = 6,
    /* In its Library's waiting queue behind the Job holding the slot. */
    ORCA_JOB_WAITING = 7,
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
    /* Reading a Track's lyrics, and fetching them from LRCLIB. */
    ORCA_JOB_KIND_LYRICS = 9,
    /* Fetching an Artist's photo, biography, years active and links. */
    ORCA_JOB_KIND_ARTIST_INFO = 10,
    /* Release descriptions, or genres filled from MusicBrainz:
     * orca_library_start_release_info and orca_library_start_genre_fill. */
    ORCA_JOB_KIND_RELEASE_INFO = 11,
    /* Finding where a Release's tracks disagree about its metadata. The
     * ABI cannot start this Job yet; a history entry can name it. */
    ORCA_JOB_KIND_CONSISTENCY = 12,
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

/* How long a play must be heard before it is kept as a listen. Only
 * ORCA_LISTEN_POLICY_HALF_OR_FOUR_MINUTES is ListenBrainz's rule: half the
 * track or four minutes, of a track of at least 30 seconds. A listen kept
 * under another policy that falls short of that rule is never sent. */
typedef enum orca_listen_policy {
    ORCA_LISTEN_POLICY_HALF_OR_FOUR_MINUTES = 0,
    ORCA_LISTEN_POLICY_THIRTY_SECONDS = 1,
    ORCA_LISTEN_POLICY_FULL_TRACK = 2,
} orca_listen_policy;

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
    /* 1 when the view is a queue entry whose Track was removed from the
     * Library: only `id` is set and every other field is zero. */
    uint8_t removed;
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
    /* Fewest plays of the Track's recording first, or most when descending;
     * every file of the recording counts. */
    ORCA_TRACK_SORT_PLAY_COUNT = 9,
    /* Least recently played first, or most recently when descending; Tracks
     * never played last either way. */
    ORCA_TRACK_SORT_LAST_PLAYED = 10,
    /* Oldest Release year first, or newest when descending; undated Tracks
     * last either way. */
    ORCA_TRACK_SORT_YEAR = 11,
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

/* Which Tracks orca_track_query_v2 keeps by the codec of the file each
 * plays. A Track whose file has no known codec is neither lossless nor
 * lossy. */
typedef enum orca_track_format {
    ORCA_TRACK_FORMAT_ANY = 0,
    ORCA_TRACK_FORMAT_LOSSLESS = 1,
    ORCA_TRACK_FORMAT_LOSSY = 2,
} orca_track_format;

/* orca_track_query with `has_*` flags in place of negative ids, and filters
 * that combine with AND. A nonzero `has_genre_id` keeps only the Tracks that
 * carry `genre_id`. `year_min` and `year_max`, each read when its `has_*`
 * flag is nonzero, bound the year of the Release's date inclusively and
 * leave out undated Tracks. A nonzero `min_sample_rate` keeps the Tracks
 * whose file runs at that many hertz or more; `explicit_only` those whose
 * advisory is ORCA_EXPLICIT_EXPLICIT. A nonempty `text` (the pointer may be
 * null when its length is 0) keeps the Tracks whose title, artist, album or
 * album artist holds a word beginning with each of its words, case and
 * diacritics ignored, and lists them by relevance in place of `sort`. A track search
 * has no count: orca_library_track_match_count_v2 refuses a nonempty
 * `text`. */
typedef struct orca_track_query_v2 {
    int64_t artist_id;
    int64_t release_id;
    int64_t genre_id;
    int32_t year_min;
    int32_t year_max;
    uint32_t min_sample_rate;
    uint8_t sort;  /* orca_track_sort */
    uint8_t descending;
    uint8_t loved_only;
    uint8_t has_artist_id;
    uint8_t has_release_id;
    uint8_t has_genre_id;
    uint8_t has_year_min;
    uint8_t has_year_max;
    uint8_t format;  /* orca_track_format */
    uint8_t explicit_only;
    uint8_t reserved[2];
    uint32_t limit;
    uint32_t offset;
    orca_string_view text;
} orca_track_query_v2;

/* A recording's parental advisory, as its files' tags state it. */
typedef enum orca_explicit {
    /* No file states an advisory. */
    ORCA_EXPLICIT_UNKNOWN = 0,
    /* A file states that there is none. */
    ORCA_EXPLICIT_NONE = 1,
    ORCA_EXPLICIT_EXPLICIT = 2,
    /* An edited version of explicit content. */
    ORCA_EXPLICIT_CLEAN = 3,
} orca_explicit;

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

/* An Artist with whether the user loved it (orca_library_set_artist_love)
 * and whether the Library stores a photo of it, which
 * orca_library_request_artwork returns for ORCA_ARTWORK_SUBJECT_ARTIST. */
typedef struct orca_artist_view_v2 {
    orca_artist_view base;
    uint8_t loved;
    uint8_t has_photo;
    uint8_t reserved[6];
} orca_artist_view_v2;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_artist_v2_callback)(void *context, const orca_artist_view_v2 *artist);

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
    /* orca_explicit: EXPLICIT when any Track is; else CLEAN, then NONE. */
    uint8_t explicit;
    uint8_t reserved[1];
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
    /* Most listens of the Tracks' recordings first. */
    ORCA_RELEASE_SORT_MOST_PLAYED = 5,
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

/* Which Releases orca_release_query_v2 keeps by cover: one embedded in a
 * Track's file or fetched from the Cover Art Archive. */
typedef enum orca_release_artwork {
    ORCA_RELEASE_ARTWORK_ANY = 0,
    ORCA_RELEASE_ARTWORK_PRESENT = 1,
    ORCA_RELEASE_ARTWORK_ABSENT = 2,
} orca_release_artwork;

/* Which Releases orca_release_query_v2 keeps by release type, the
 * MusicBrainz primary type from the files' tags or, failing those, from
 * orca_library_release_info_fetch. ALBUM keeps "album" and "compilation",
 * and a Release whose type is unknown; EP_OR_SINGLE keeps "ep" and "single";
 * OTHER keeps every other type. */
typedef enum orca_release_kind {
    ORCA_RELEASE_KIND_ANY = 0,
    ORCA_RELEASE_KIND_ALBUM = 1,
    ORCA_RELEASE_KIND_EP_OR_SINGLE = 2,
    ORCA_RELEASE_KIND_OTHER = 3,
} orca_release_kind;

/* orca_release_query with `has_*` flags in place of negative ids, and
 * filters that combine with AND. A nonzero
 * `has_genre_id` keeps the Releases with at least one Track that carries
 * `genre_id`. `high_resolution_only` keeps those with a Track whose file is
 * above 48 kHz or 16 bits; `needs_review_only` those whose
 * orca_release_facts_view `pending_reviews` is nonzero; `lossless_only`
 * those whose every Track plays a lossless file. `year_min` and `year_max`,
 * each read when its `has_*` flag is nonzero, bound the year of the release
 * date inclusively and leave out undated Releases. A nonempty `text` (the
 * pointer may be null when its length is 0) keeps the Releases whose title
 * or album artist holds a word beginning with each of its words, as
 * orca_library_search matches them, in the order `sort` gives; the count
 * honours it. A nonzero `has_appearing_artist_id` keeps the Releases with a
 * Track credited to `appearing_artist_id` that are not filed under that
 * Artist as album artist: the Releases they appear on. With
 * `has_album_artist_id`, a nonzero `own_releases_only` keeps only the
 * Releases filed under `album_artist_id` as album artist, leaving out those
 * the Artist only appears on; without it, the flag does nothing. */
typedef struct orca_release_query_v2 {
    int64_t album_artist_id;
    int64_t genre_id;
    int32_t year_min;
    int32_t year_max;
    uint8_t sort;  /* orca_release_sort */
    uint8_t loved_only;
    uint8_t has_album_artist_id;
    uint8_t has_genre_id;
    uint8_t high_resolution_only;
    uint8_t needs_review_only;
    uint8_t lossless_only;
    uint8_t has_year_min;
    uint8_t has_year_max;
    uint8_t artwork;  /* orca_release_artwork */
    uint8_t kind;  /* orca_release_kind */
    uint8_t has_appearing_artist_id;
    uint8_t own_releases_only;
    uint8_t reserved[3];
    uint32_t limit;
    uint32_t offset;
    orca_string_view text;
    int64_t appearing_artist_id;
} orca_release_query_v2;

/* What orca_release_view leaves out, read from the files its Tracks play. */
typedef struct orca_release_facts_view {
    /* The codec every Track's file shares, such as "flac"; "mixed" when they
     * differ; empty when none was probed. */
    orca_string_view codec;
    /* Such as "album"; empty when unknown. */
    orca_string_view release_type;
    /* The highest among the files; zero when unknown. */
    uint32_t max_sample_rate;
    uint32_t max_bit_depth;
    /* Tracks with a pending match outside an album group, plus album groups
     * with a pending correction of one of the Tracks. */
    uint32_t pending_reviews;
    /* Every Track plays a file in a lossless codec. */
    uint8_t lossless;
    uint8_t reserved[3];
} orca_release_facts_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_release_facts_callback)(
    void *context,
    const orca_release_view *release,
    const orca_release_facts_view *facts
);

/* Every order ends in the Artist id, so paging is a total order. */
typedef enum orca_artist_sort {
    /* By sort name. */
    ORCA_ARTIST_SORT_NAME = 0,
    /* Most Tracks first, counting every Track the Artist has, not only those
     * in a filtered genre. */
    ORCA_ARTIST_SORT_TRACK_COUNT = 1,
    /* Most recently loved first, then the Artists not loved. */
    ORCA_ARTIST_SORT_RECENTLY_LOVED = 2,
    /* The Artist whose newest Release, in ORCA_RELEASE_SORT_RECENTLY_ADDED's
     * order, came latest first; Artists with no Release last. */
    ORCA_ARTIST_SORT_RECENTLY_ADDED = 3,
} orca_artist_sort;

/* orca_artist_query with a genre filter and a sort. A nonzero `has_genre_id`
 * keeps the Artists credited on a Track that carries `genre_id`, as the
 * Track's artist or as its Release's album artist. `loved_only` 1 keeps the
 * Artists the user loved; any value but 0 or 1 is INVALID_ARGUMENT. */
typedef struct orca_artist_query_v2 {
    orca_string_view filter;
    int64_t genre_id;
    uint32_t limit;
    uint32_t offset;
    uint8_t sort;  /* orca_artist_sort */
    uint8_t has_genre_id;
    uint8_t loved_only;
    uint8_t reserved[5];
} orca_artist_query_v2;

/* Every order ends in the genre id, so paging is a total order. */
typedef enum orca_genre_sort {
    ORCA_GENRE_SORT_NAME = 0,
    /* Most Tracks first. */
    ORCA_GENRE_SORT_TRACK_COUNT = 1,
} orca_genre_sort;

/* One bounded request for a page of genres. `filter` keeps the genres whose
 * folded name contains it: case, spaces, hyphens, slashes and dots are
 * ignored, so "hip hop" finds "Hip-Hop" and "Alternative Hip Hop". An empty
 * filter (length 0, pointer may be null) keeps every genre. `limit` must be
 * between 1 and 512. */
typedef struct orca_genre_query {
    orca_string_view filter;
    uint32_t limit;
    uint32_t offset;
    uint8_t sort;  /* orca_genre_sort */
    uint8_t reserved[7];
} orca_genre_query;

/* A genre that at least one Track carries. Every count is over those
 * Tracks. */
typedef struct orca_genre_view {
    int64_t id;
    /* Summed over the Tracks that declare a duration. */
    int64_t total_duration_ms;
    uint32_t track_count;
    uint32_t release_count;
    /* Track artists and the album artists of those Tracks' Releases. */
    uint32_t artist_count;
    uint8_t reserved[4];
    orca_string_view name;
} orca_genre_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_genre_callback)(void *context, const orca_genre_view *genre);

/* What an orca_search_hit_view names; hits arrive in this order. */
typedef enum orca_search_kind {
    ORCA_SEARCH_KIND_ARTIST = 0,
    ORCA_SEARCH_KIND_RELEASE = 1,
    ORCA_SEARCH_KIND_TRACK = 2,
    ORCA_SEARCH_KIND_PLAYLIST = 3,
    ORCA_SEARCH_KIND_GENRE = 4,
} orca_search_kind;

/* The most hits of each kind orca_library_search returns, each at most 50. */
typedef struct orca_search_limits {
    uint8_t artists;
    uint8_t releases;
    uint8_t tracks;
    uint8_t playlists;
    uint8_t genres;
    uint8_t reserved[3];
} orca_search_limits;

typedef struct orca_search_hit_view {
    /* The id of the Artist, Release, Track, Playlist or genre `kind` names. */
    int64_t id;
    /* Its name or title. */
    orca_string_view title;
    /* A Release's album artist; a Track's artist and album, space separated;
     * a Playlist's description; empty for an Artist or a genre. */
    orca_string_view subtitle;
    /* Lower is more relevant; comparable only within one kind of one search.
     * For a Track, 0 when every word is a whole word of the title, 1 when
     * every word begins a word of the title, 2 otherwise; for any other kind,
     * bm25 over title and subtitle, title weighted higher. */
    float rank;
    uint8_t kind;  /* orca_search_kind */
    uint8_t reserved[3];
} orca_search_hit_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_search_hit_callback)(void *context, const orca_search_hit_view *hit);

/* A genre and how many of a Release's or an Artist's Tracks carry it. */
typedef struct orca_genre_count_view {
    int64_t id;
    uint32_t track_count;
    uint8_t reserved[4];
    orca_string_view name;
} orca_genre_count_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_genre_count_callback)(void *context, const orca_genre_count_view *genre);

/* `value` is valid only for the duration of this callback. */
typedef void (*orca_string_callback)(void *context, const orca_string_view *value);

/* `ids` is valid only for the duration of this callback. */
typedef void (*orca_id_callback)(void *context, const int64_t *ids, size_t count);

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

/* What orca_track_summary_view leaves out, read from the file the Track
 * plays and its recording's listens. */
typedef struct orca_track_facts_view {
    /* Such as "flac" or "mp3"; empty when the file was never probed. */
    orca_string_view codec;
    /* Unix seconds at which a scan first saw the file. */
    int64_t added_at;
    /* Unix seconds at which the latest listen of the recording started. */
    int64_t last_played_at;
    /* Listens of the Track's recording, through any of its files. */
    uint64_t play_count;
    /* As the file states it; otherwise the number of the Release's Tracks on
     * the disc. */
    int64_t track_total;
    /* As the file states it; otherwise the Release's disc count. */
    int64_t disc_total;
    /* Zero when unknown. */
    uint32_t sample_rate;
    uint32_t bit_depth;
    /* The first four digits of the Release's date. */
    int32_t year;
    /* `codec` names an encoding that discards audio; zero for an unknown
     * codec. */
    uint8_t lossy;
    uint8_t explicit;  /* orca_explicit */
    uint8_t has_added_at;
    uint8_t has_last_played_at;
    uint8_t has_track_total;
    uint8_t has_disc_total;
    uint8_t has_year;
    uint8_t reserved[5];
} orca_track_facts_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_track_summary_facts_callback)(
    void *context,
    const orca_track_summary_view *summary,
    const orca_track_facts_view *facts
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
    /* Listens of the Track's recording, through any of its files. */
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

/* What orca_track_details_view leaves out. */
typedef struct orca_track_details_extra_view {
    int64_t track_total;
    int64_t disc_total;
    /* Unix seconds at which a scan first saw the file. */
    int64_t added_at;
    /* Unix seconds of the file's modification time as the last scan saw it. */
    int64_t modified_at;
    uint8_t has_track_total;
    uint8_t has_disc_total;
    uint8_t has_added_at;
    uint8_t has_modified_at;
    /* No file states the total: it is the number of the Release's Tracks on
     * the disc. */
    uint8_t track_total_inferred;
    uint8_t explicit;  /* orca_explicit */
    uint8_t reserved[2];
} orca_track_details_extra_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_track_details_v2_callback)(
    void *context,
    const orca_track_details_view *details,
    const orca_track_details_extra_view *extra
);

/* The composer and comment: a locked edit, else the file's tag, else an
 * unlocked edit. Empty when none states one. */
typedef struct orca_track_details_text_view {
    orca_string_view composer;
    orca_string_view comment;
} orca_track_details_text_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_track_details_v3_callback)(
    void *context,
    const orca_track_details_view *details,
    const orca_track_details_extra_view *extra,
    const orca_track_details_text_view *text
);

typedef struct orca_play_stats {
    /* Listens of the Track's recording, through any of its files. */
    uint64_t play_count;
    /* Unix seconds at which the latest listen started, when
     * `has_last_played_at`. */
    int64_t last_played_at;
    uint8_t has_last_played_at;
    uint8_t reserved[7];
} orca_play_stats;

typedef struct orca_artist_totals {
    /* Summed over the Tracks `track_count` counts; a Track with no known
     * duration adds 0. */
    uint64_t duration_ms;
    /* The Releases filed under the Artist as album artist, as
     * orca_release_query_v2 `own_releases_only` keeps them. Unlike
     * orca_artist_view `release_count`, it leaves out `appearance_count`. */
    uint32_t release_count;
    uint32_t track_count;
    /* The Releases orca_release_query_v2 `appearing_artist_id` keeps. */
    uint32_t appearance_count;
    uint8_t reserved[4];
} orca_artist_totals;

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
    /* The same bytes are in the library more than once: at a second location
     * of the file, or in another file with the same full-content hash. */
    ORCA_HEALTH_ISSUE_KIND_EXACT_DUPLICATE = 9,
    /* Another file probably holds the same recording. */
    ORCA_HEALTH_ISSUE_KIND_LIKELY_DUPLICATE = 10,
    /* The file could not be opened or would not decode, found without
     * reading all of its audio. */
    ORCA_HEALTH_ISSUE_KIND_UNREADABLE_FILE = 11,
    /* A verification proposed another recording ID for the file. */
    ORCA_HEALTH_ISSUE_KIND_RECORDING_MISMATCH = 12,
    /* Another file holds the same lossless audio in different bytes. */
    ORCA_HEALTH_ISSUE_KIND_IDENTICAL_AUDIO = 13,
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

/* The visible issues of one kind: how many there are, and the highest
 * severity among them. `kind` and `severity` are orca_health_issue_kind and
 * orca_health_severity. */
typedef struct orca_health_kind_summary_view {
    uint64_t count;
    uint8_t kind;
    uint8_t severity;
    uint8_t reserved[6];
} orca_health_kind_summary_view;

typedef void (*orca_health_kind_summary_callback)(
    void *context,
    const orca_health_kind_summary_view *summary
);

/* A kind's summary with the files that have such an issue and their summed
 * size. A file has at most one issue of a kind, so `files` equals
 * `base.count`. For ORCA_HEALTH_ISSUE_KIND_EXACT_DUPLICATE,
 * ORCA_HEALTH_ISSUE_KIND_IDENTICAL_AUDIO and
 * ORCA_HEALTH_ISSUE_KIND_LIKELY_DUPLICATE, `bytes` counts only the redundant
 * copies, what removing them would free: of a kept copy and two duplicates of
 * 10 MB each, 20 MB. */
typedef struct orca_health_kind_summary_view_v2 {
    orca_health_kind_summary_view base;
    uint64_t files;
    uint64_t bytes;
} orca_health_kind_summary_view_v2;

typedef void (*orca_health_kind_summary_v2_callback)(
    void *context,
    const orca_health_kind_summary_view_v2 *summary
);

/* The size of a Library at a glance. `artists`, `releases` and `tracks` equal
 * the unfiltered counts; `files` and `total_bytes` cover the files with a
 * location that is not missing; `total_duration_ms` sums the Tracks'
 * durations. `last_scan_finished_at` is when the latest completed scan
 * finished and `last_analysis_at` when the latest analysis measurement was
 * stored, both in Unix seconds; each is 0 when its `has_*` flag is 0. */
typedef struct orca_library_stats_view {
    uint64_t artists;
    uint64_t releases;
    uint64_t tracks;
    uint64_t files;
    uint64_t total_bytes;
    uint64_t total_duration_ms;
    int64_t last_scan_finished_at;
    int64_t last_analysis_at;
    uint8_t has_last_scan_finished_at;
    uint8_t has_last_analysis_at;
    uint8_t reserved[6];
} orca_library_stats_view;

/* orca_library_stats_view with the last duplicate scan and the listen count.
 * `last_duplicate_scan_at` is when the latest duplicate scan a host started
 * succeeded, in Unix seconds, as the Job history records it; 0 when
 * `has_last_duplicate_scan_at` is 0. `listens` counts the local play history. */
typedef struct orca_library_stats_view_v2 {
    orca_library_stats_view base;
    int64_t last_duplicate_scan_at;
    uint64_t listens;
    uint8_t has_last_duplicate_scan_at;
    uint8_t reserved[7];
} orca_library_stats_view_v2;

/* The bytes of provider data a Library keeps. `artwork_bytes`: Cover Art
 * Archive covers of Releases and release groups. `photo_bytes`: Wikimedia
 * Commons photos of Artists and related artists. `lyrics_bytes`: LRCLIB
 * lyrics. `info_bytes`: artist and release descriptions, links, related
 * artists and release groups. */
typedef struct orca_cache_size {
    uint64_t artwork_bytes;
    uint64_t photo_bytes;
    uint64_t lyrics_bytes;
    uint64_t info_bytes;
} orca_cache_size;

/* A service Orca takes data from, so every host credits the same sources. */
typedef enum orca_provider_source_id {
    ORCA_PROVIDER_SOURCE_MUSICBRAINZ = 0,
    ORCA_PROVIDER_SOURCE_MUSICBRAINZ_GENRES = 1,
    ORCA_PROVIDER_SOURCE_COVER_ART_ARCHIVE = 2,
    ORCA_PROVIDER_SOURCE_ACOUSTID = 3,
    ORCA_PROVIDER_SOURCE_LISTENBRAINZ = 4,
    ORCA_PROVIDER_SOURCE_LRCLIB = 5,
    ORCA_PROVIDER_SOURCE_WIKIDATA = 6,
    ORCA_PROVIDER_SOURCE_WIKIMEDIA_COMMONS = 7,
    ORCA_PROVIDER_SOURCE_WIKIPEDIA = 8,
} orca_provider_source_id;

/* One provider: `id` is an orca_provider_source_id, `supplies` says what Orca
 * takes from it, and `licence` names the terms its data is under.
 * `licence_url` is empty when the licence has no single page, as for
 * Wikimedia Commons, whose photos each carry their own. */
typedef struct orca_provider_source_view {
    uint8_t id;
    uint8_t reserved[7];
    orca_string_view name;
    orca_string_view url;
    orca_string_view supplies;
    orca_string_view licence;
    orca_string_view licence_url;
} orca_provider_source_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_provider_source_callback)(
    void *context,
    const orca_provider_source_view *source
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

/* Files the duplicate scan found to be copies of one another. `id` is the
 * group's lowest file id, the same on every read while its duplicate issues
 * are unchanged. `title` and `artist` are the suggested copy's Track's, or
 * its path and an empty artist when it backs none. `copies` counts each
 * further location of a file as a copy. `same_recording` is 1 when every
 * copy is an encoding of one recording, so they share one play count and
 * rating. `similarity`, 0..1, is how alike the least alike copies sound, 1
 * for exact copies and identical audio; valid when `has_similarity`.
 * `verdict` is the orca_health_issue_kind every copy is proven to share, the
 * weakest of the group's links: ORCA_HEALTH_ISSUE_KIND_EXACT_DUPLICATE (the
 * same bytes), ORCA_HEALTH_ISSUE_KIND_IDENTICAL_AUDIO (the same audio) or
 * ORCA_HEALTH_ISSUE_KIND_LIKELY_DUPLICATE (matching fingerprints). It is 0,
 * never a duplicate kind, from a liborca that predates the field.
 * `bytes_redundant` is what removing every copy but the suggested one would
 * free. */
typedef struct orca_duplicate_group_view {
    int64_t id;
    uint64_t bytes_redundant;
    uint32_t copies;
    float similarity;
    uint8_t same_recording;
    uint8_t has_similarity;
    uint8_t verdict;  /* orca_health_issue_kind */
    uint8_t reserved[5];
    orca_string_view title;
    orca_string_view artist;
} orca_duplicate_group_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_duplicate_group_callback)(
    void *context,
    const orca_duplicate_group_view *group
);

typedef struct orca_duplicate_group_totals {
    uint64_t groups;
    /* The summed `bytes_redundant` of every group. */
    uint64_t bytes;
} orca_duplicate_group_totals;

/* One file of a duplicate group. `track_id` is the lowest-numbered Track the
 * file backs, valid when `has_track_id`. `suggested_keep` is 1 for exactly
 * one copy of a group: lossless over lossy, then the higher sample rate, the
 * higher bit depth, then the larger file. `playlist_count` counts the
 * playlists holding the file's recording; `locations` the file's locations
 * that are not missing, at least 1. */
typedef struct orca_duplicate_copy_view {
    int64_t file_id;
    int64_t track_id;
    uint64_t playlist_count;
    uint32_t locations;
    uint8_t has_track_id;
    uint8_t suggested_keep;
    uint8_t reserved[2];
} orca_duplicate_copy_view;

/* `details` is the Track as this file describes it, its format, size, path
 * and loudness being this file's; null when the file backs no Track. String
 * views are valid only for the duration of this callback. */
typedef void (*orca_duplicate_copy_callback)(
    void *context,
    const orca_duplicate_copy_view *copy,
    const orca_track_details_view *details
);

/* What orca_library_merge_duplicate_metadata changed. `track_id` is the kept
 * Track's id afterwards: a new id when a copied value moved it to another
 * Release. `values` counts Orca value rows written. `genres` is 1 when the
 * other Track's user genres replaced the kept Track's, which had none of its
 * own. */
typedef struct orca_duplicate_merge {
    int64_t track_id;
    uint32_t values;
    uint8_t rating;
    uint8_t feedback;
    uint8_t genres;
    uint8_t reserved[1];
} orca_duplicate_merge;

typedef struct orca_root_view {
    int64_t id;
    int64_t volume_id;
    uint8_t enabled;
    uint8_t reserved[7];
    orca_string_view path;
} orca_root_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_root_callback)(void *context, const orca_root_view *root);

/* orca_root_view with the root's Tracks. `available` is 1 when the root's
 * directory can be listed and lies on the volume it was bound to.
 * `track_count` counts the Tracks whose preferred file has a location under
 * the root, and `unavailable_tracks` those of them with no location that is
 * not missing; while the root is unavailable it equals `track_count`. */
typedef struct orca_root_view_v2 {
    orca_root_view base;
    uint64_t track_count;
    uint64_t unavailable_tracks;
    uint8_t available;
    uint8_t reserved[7];
} orca_root_view_v2;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_root_v2_callback)(void *context, const orca_root_view_v2 *root);

typedef enum orca_folder_entry_kind {
    ORCA_FOLDER_ENTRY_KIND_FOLDER = 0,
    ORCA_FOLDER_ENTRY_KIND_FILE = 1,
    ORCA_FOLDER_ENTRY_KIND_IMAGE = 2,
} orca_folder_entry_kind;

typedef struct orca_folder_entry_view {
    /* The Track whose preferred file this is; files only. */
    int64_t track_id;
    /* Files only. */
    int64_t file_id;
    /* A folder's counts and duration cover every file below it, at any
     * depth; a file's describe that file. */
    int64_t total_duration_ms;
    uint32_t file_count;
    uint32_t track_count;
    uint8_t kind;  /* orca_folder_entry_kind */
    uint8_t has_track_id;
    uint8_t has_file_id;
    uint8_t reserved[5];
    /* The last path component, as stored. */
    orca_string_view name;
} orca_folder_entry_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_folder_entry_callback)(void *context, const orca_folder_entry_view *entry);

typedef struct orca_device_view {
    uint64_t id;
    orca_string_view name;
} orca_device_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_device_callback)(void *context, const orca_device_view *device);

/* How an output is attached, as far as the platform says. */
typedef enum orca_device_kind {
    ORCA_DEVICE_KIND_UNKNOWN = 0,
    ORCA_DEVICE_KIND_USB = 1,
    ORCA_DEVICE_KIND_PCI = 2,
    ORCA_DEVICE_KIND_BLUETOOTH = 3,
    ORCA_DEVICE_KIND_HDMI = 4,
    /* A software sink with no hardware behind it. */
    ORCA_DEVICE_KIND_VIRTUAL = 5,
} orca_device_kind;

typedef struct orca_device_view_v2 {
    orca_device_view base;
    /* An orca_device_kind value. */
    uint8_t kind;
    uint8_t reserved[7];
} orca_device_view_v2;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_device_v2_callback)(void *context, const orca_device_view_v2 *device);

/* Whether an output is ready, as the platform's audio server says. */
typedef enum orca_device_state {
    /* Running, or idle and open. */
    ORCA_DEVICE_STATE_ACTIVE = 0,
    /* Suspended: the device may stay closed until something plays to it. */
    ORCA_DEVICE_STATE_SUSPENDED = 1,
    /* In error, or reporting no state. */
    ORCA_DEVICE_STATE_UNAVAILABLE = 2,
} orca_device_state;

/* Bits of orca_device_view_v3.bit_depths. Float32 counts as 32. */
#define ORCA_DEVICE_BIT_DEPTH_16 1
#define ORCA_DEVICE_BIT_DEPTH_24 2
#define ORCA_DEVICE_BIT_DEPTH_32 4

typedef struct orca_device_view_v3 {
    orca_device_view_v2 base;
    /* Zero when the audio server did not report the output's capabilities
     * within 500 ms; the fields below are then zero. */
    uint8_t has_capabilities;
    /* An orca_device_state value. */
    uint8_t state;
    /* ORCA_DEVICE_BIT_DEPTH_* bits. */
    uint8_t bit_depths;
    uint8_t channels_max;
    /* The lowest and highest sample rates the output accepts. */
    uint32_t rate_min_hz;
    uint32_t rate_max_hz;
    uint8_t reserved[4];
} orca_device_view_v3;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_device_v3_callback)(void *context, const orca_device_view_v3 *device);

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

/* Why a queue history entry stopped playing. */
typedef enum orca_queue_history_reason {
    /* It played to its end, or the Player ran out of queue. */
    ORCA_QUEUE_HISTORY_REASON_FINISHED = 0,
    /* Next, previous or a jump moved to another entry. */
    ORCA_QUEUE_HISTORY_REASON_SKIPPED = 1,
    /* Playing new Tracks or clearing the queue replaced it. */
    ORCA_QUEUE_HISTORY_REASON_REPLACED = 2,
} orca_queue_history_reason;

/* `ended_at` is Unix milliseconds; `reason` is an orca_queue_history_reason.
 * String views are valid only for the duration of this callback. */
typedef void (*orca_queue_history_callback)(
    void *context,
    const orca_track_summary_view *summary,
    int64_t ended_at,
    uint8_t reason
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

/* Why a queue entry could not be opened. FOLDER_UNAVAILABLE: the root folder
 * or the volume it is on is not there, so the file is not marked missing.
 * FILE_MISSING: the root is there and the file is not. */
typedef enum orca_playback_failure {
    ORCA_PLAYBACK_FAILURE_FILE_MISSING = 0,
    ORCA_PLAYBACK_FAILURE_FOLDER_UNAVAILABLE = 1,
    ORCA_PLAYBACK_FAILURE_CODEC_UNAVAILABLE = 2,
    ORCA_PLAYBACK_FAILURE_DECODE_ERROR = 3,
    ORCA_PLAYBACK_FAILURE_UNSUPPORTED_CHANNELS = 4,
} orca_playback_failure;

/* orca_player_status with the last entry the Player could not open. Playback
 * moves past such an entry; the failure stays until an entry opened after it
 * is audible. `failure_track_id` and `failure_reason` are 0 when
 * `has_failure` is 0. */
typedef struct orca_player_status_v2 {
    orca_player_status base;
    int64_t failure_track_id;
    uint8_t has_failure;
    uint8_t failure_reason;  /* orca_playback_failure */
    uint8_t reserved[6];
} orca_player_status_v2;

/* orca_player_status_v2 with where the audible entry resumed when it began
 * part way through: a restored queue's position or a long Track's remembered
 * one. `resumed_from_ms` is 0 when `has_resumed` is 0. */
typedef struct orca_player_status_v3 {
    orca_player_status_v2 base;
    uint64_t resumed_from_ms;
    uint8_t has_resumed;
    uint8_t reserved[7];
} orca_player_status_v3;

/* What orca_player_restore_state restored. `index` is the playback position
 * of the entry the queue resumes at and `position_ms` where in it, 0 from its
 * start. `skipped_missing` counts saved entries left out because neither
 * their Track nor another Track of their Recording is left. */
typedef struct orca_restore_outcome {
    uint32_t entries;
    uint32_t index;
    uint64_t position_ms;
    uint32_t skipped_missing;
    uint8_t reserved[4];
} orca_restore_outcome;

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
    /* Zero for a scan or reconcile while it counts the files its walk will
     * reach; one from then on, with `total_units` that count and
     * `completed_units` the files walked. A property backfill knows its total
     * before it starts - how many rows still owe a probe is one indexed count. */
    uint8_t has_total;
    uint8_t reserved[5];
    uint64_t completed_units;
    uint64_t total_units;
} orca_job_snapshot;

typedef enum orca_scan_stage {
    ORCA_SCAN_STAGE_DISCOVER = 0,
    ORCA_SCAN_STAGE_READ_TAGS = 1,
    ORCA_SCAN_STAGE_DONE = 2,
} orca_scan_stage;

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

/*
 * orca_scan_stats with where the job is.
 *
 * `stage` is an orca_scan_stage. A scan or reconcile is DISCOVER until its
 * walk starts and READ_TAGS while it walks; every job is DONE once its worker
 * has finished, and other jobs report DISCOVER until then. `albums_found`
 * counts the distinct Releases the job's projection wrote that still exist.
 * `current_path` holds `current_path_length` bytes of UTF-8, not
 * NUL-terminated: the file a scan or reconcile is reading during READ_TAGS,
 * and empty otherwise.
 */
typedef struct orca_scan_stats_v2 {
    orca_scan_stats base;
    uint64_t albums_found;
    uint8_t stage;  /* orca_scan_stage */
    uint8_t reserved[1];
    uint16_t current_path_length;
    uint8_t reserved2[4];
    char current_path[512];
} orca_scan_stats_v2;

/* How many audio files a folder holds; see orca_estimate_audio_files. */
typedef struct orca_folder_estimate {
    uint64_t audio_files;
    uint8_t truncated;
    uint8_t reserved[7];
} orca_folder_estimate;

typedef struct orca_scan_options {
    /* Rows per bounded commit. Zero selects the default. */
    uint32_t batch_size;
    /*
     * Nonzero reads every file again, even one whose path and identity are
     * unchanged. Files, Tracks and their ids are kept.
     */
    uint8_t reprobe_all;
    uint8_t reserved[3];
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

/* What orca_library_start_property_backfill could repair now. `files` counts
 * the files that declare no duration, sample rate, channels or codec, less
 * those missing, on an offline root, in a format no codec decodes, or already
 * found unreadable with the bytes they have; `covers` the embedded covers,
 * folder images and kept covers not yet measured, less embedded covers of
 * files missing or on an offline root and folder images on an offline root.
 * The backfill itself still examines what these leave out. */
typedef struct orca_backfill_pending {
    uint64_t files;
    uint64_t covers;
} orca_backfill_pending;

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
    ORCA_FAILURE_TRACK_FOLDER_UNAVAILABLE = 10,
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
 * NULL means out of memory. On Linux the first runtime in the process switches
 * SQLite to OFD locks; create it before opening any SQLite connection of your
 * own, or every orca_library_open returns ORCA_STATUS_INVALID_STATE. */
orca_runtime *orca_runtime_create(void);
/* Call it on the runtime's creating thread. A Debug build ignores a call from
 * another thread and leaves the runtime alive. */
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
    ORCA_PROVIDER_SERVICE_LRCLIB = 4,
    ORCA_PROVIDER_SERVICE_WIKIDATA = 5,
    /* The Commons API; its images come from upload.wikimedia.org, or from a
     * loopback server's own host. */
    ORCA_PROVIDER_SERVICE_WIKIMEDIA_COMMONS = 6,
    /* One server for every Wikipedia language. NULL asks
     * https://{language}.wikipedia.org. */
    ORCA_PROVIDER_SERVICE_WIKIPEDIA = 7,
    /* The ListenBrainz Labs API that related artists come from. */
    ORCA_PROVIDER_SERVICE_LISTENBRAINZ_LABS = 8,
} orca_provider_service;

/*
 * Points one provider at a self-hosted or compatible server. `base_url` is
 * `https` to any host name, or `http` to 127.0.0.1 or localhost only,
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
 * ORCA_STATUS_INVALID_ARGUMENT. Copied; NULL clears it. A job resolves its key
 * once, when its AcoustID work begins, so a change applies from the next job.
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

/*
 * Sends this Library's listens and feedback to ListenBrainz, or stops sending
 * them. Listens are recorded in the Library either way; one recorded while
 * scrobbling is off is never sent later. `offline` keeps listens queued
 * without making any request, and `now_playing` also announces the playing
 * track. Each flag is 0 or 1; anything else is ORCA_STATUS_INVALID_ARGUMENT.
 *
 * At most one Library per runtime scrobbles: enabling a second one returns
 * ORCA_STATUS_INVALID_STATE ("ScrobblingEnabledElsewhere") until the first is
 * disabled or closed. Enabling also needs orca_runtime_set_client_identity
 * first ("ClientIdentityRequired", INVALID_STATE), and a Library whose
 * database the runtime has already closed is INVALID_STATE. Enabling starts
 * the Library's listen worker; the token comes from the credential callback
 * (ORCA_CREDENTIAL_SERVICE_LISTENBRAINZ / ORCA_CREDENTIAL_ACCOUNT_USER_TOKEN)
 * and the server from orca_runtime_set_provider_server.
 */
orca_status orca_library_set_scrobbling(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t enabled,
    uint8_t offline,
    uint8_t now_playing
);

typedef enum orca_scrobbler_state {
    /* Scrobbling is off for this Library. */
    ORCA_SCROBBLER_STATE_DISABLED = 0,
    ORCA_SCROBBLER_STATE_IDLE = 1,
    /* The credential callback has no ListenBrainz token. */
    ORCA_SCROBBLER_STATE_NEEDS_TOKEN = 2,
    ORCA_SCROBBLER_STATE_VALIDATING = 3,
    /* ListenBrainz refused the token; see last_error. */
    ORCA_SCROBBLER_STATE_INVALID_TOKEN = 4,
    ORCA_SCROBBLER_STATE_SUBMITTING = 5,
    /* A request failed; the next is at next_attempt_at. */
    ORCA_SCROBBLER_STATE_BACKING_OFF = 6,
    /* ListenBrainz asked Orca to wait; see blocked_until. */
    ORCA_SCROBBLER_STATE_RATE_LIMITED = 7,
    /* Listens are waiting while scrobbling is offline. */
    ORCA_SCROBBLER_STATE_OFFLINE = 8,
    /* Another Orca process sharing the database holds ListenBrainz. */
    ORCA_SCROBBLER_STATE_BUSY = 9,
} orca_scrobbler_state;

typedef struct orca_scrobbler_status_view {
    /* Unix seconds; valid when has_next_attempt_at is 1. */
    int64_t next_attempt_at;
    /* When ListenBrainz accepts requests again, in Unix seconds, while this
     * Library records it refusing them; valid when has_blocked_until is 1. */
    int64_t blocked_until;
    /* Queued listens not yet delivered or rejected. */
    uint64_t pending;
    uint64_t feedback_pending;
    uint64_t delivered_total;
    /* Listens recorded since the Library was opened. */
    uint64_t recorded_total;
    /* Listens heard since the Library was opened and not recorded. */
    uint64_t dropped;
    uint8_t enabled;
    /* An orca_scrobbler_state. */
    uint8_t state;
    uint8_t has_next_attempt_at;
    uint8_t has_blocked_until;
    uint8_t reserved[4];
    /* The ListenBrainz user the token belongs to; empty until validated. */
    orca_string_view user_name;
    /* Why the last request or token lookup failed; empty when none did. */
    orca_string_view last_error;
} orca_scrobbler_status_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_scrobbler_status_callback)(
    void *context,
    const orca_scrobbler_status_view *status
);

/*
 * Invokes the callback once with the scrobbler's last published state. A
 * Library whose listen worker is not running reports the queue counts from
 * its database, reading it at most once a second, and starts nothing, so a
 * host may call this on each tick. A NULL callback is
 * ORCA_STATUS_INVALID_ARGUMENT.
 */
orca_status orca_library_scrobbler_status(
    orca_runtime *runtime,
    orca_handle library,
    void *context,
    orca_scrobbler_status_callback callback
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
/* The page of orca_library_query_health_items holding only issues of `kind`,
 * an orca_health_issue_kind, in the same order. An unknown `kind` is
 * ORCA_STATUS_INVALID_ARGUMENT, and so is a `limit` outside 1..512. */
orca_status orca_library_query_health_items_of_kind(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t kind,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_health_item_callback callback
);
/* Calls `callback` once for each kind with at least one issue that is not
 * dismissed, highest severity first, then in orca_health_issue_kind order.
 * An empty Library calls it never. Its counts sum to
 * orca_library_health_issue_count. */
orca_status orca_library_health_summary(
    orca_runtime *runtime,
    orca_handle library,
    void *context,
    orca_health_kind_summary_callback callback
);
/* orca_library_health_summary with each kind's files and bytes. */
orca_status orca_library_health_summary_v2(
    orca_runtime *runtime,
    orca_handle library,
    void *context,
    orca_health_kind_summary_v2_callback callback
);
/* Fills `output` with the Library's counts, sizes, and last scan and analysis
 * times. A null `output` is ORCA_STATUS_INVALID_ARGUMENT. */
orca_status orca_library_stats(
    orca_runtime *runtime,
    orca_handle library,
    orca_library_stats_view *output
);
/* orca_library_stats with the last duplicate scan and the listen count. */
orca_status orca_library_stats_v2(
    orca_runtime *runtime,
    orca_handle library,
    orca_library_stats_view_v2 *output
);
/* Fills `output` with the bytes of fetched provider data the Library keeps.
 * A null `output` is ORCA_STATUS_INVALID_ARGUMENT. */
orca_status orca_library_cache_size(
    orca_runtime *runtime,
    orca_handle library,
    orca_cache_size *output
);
/* Deletes fetched covers, artist and related artist photos, LRCLIB lyrics and
 * artist and release info, all fetched again when next wanted. Embedded and
 * folder artwork and local lyrics stay. `cleared`, which may be null,
 * receives what they held. */
orca_status orca_library_clear_cache(
    orca_runtime *runtime,
    orca_handle library,
    orca_cache_size *cleared
);
/* Calls `callback` once per provider Orca takes data from, in
 * orca_provider_source_id order. The list is fixed and needs no Library. A
 * null `callback` is ORCA_STATUS_INVALID_ARGUMENT. */
orca_status orca_provider_sources(
    orca_runtime *runtime,
    void *context,
    orca_provider_source_callback callback
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
/* Calls `callback` once per duplicate group, ordered by id. Dismissed
 * duplicate issues form no group. `limit` is 1..512, else
 * ORCA_STATUS_INVALID_ARGUMENT. */
orca_status orca_library_query_duplicate_groups(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_duplicate_group_callback callback
);
/* Fills `output` with the number of duplicate groups and their redundant
 * bytes. A null `output` is ORCA_STATUS_INVALID_ARGUMENT. */
orca_status orca_library_duplicate_group_totals(
    orca_runtime *runtime,
    orca_handle library,
    orca_duplicate_group_totals *output
);
/* Calls `callback` once per copy of group `group_id`, the suggested copy
 * first. `group`, which may be null, receives the group's row with empty
 * string views. ORCA_STATUS_NOT_FOUND, with the callback not called, when no
 * group has that id. */
orca_status orca_library_query_duplicate_group(
    orca_runtime *runtime,
    orca_handle library,
    int64_t group_id,
    orca_duplicate_group_view *group,
    void *context,
    orca_duplicate_copy_callback callback
);
/* Dismisses the duplicate issues of both files, until either file's bytes
 * change. Neither file is touched. ORCA_STATUS_INVALID_ARGUMENT when the two
 * files are not in one group. */
orca_status orca_library_keep_both_duplicates(
    orca_runtime *runtime,
    orca_handle library,
    int64_t file_id,
    int64_t other_file_id
);
/* Dismisses the duplicate issues of every file of group `group_id`.
 * ORCA_STATUS_NOT_FOUND when no group has that id. */
orca_status orca_library_ignore_duplicate_group(
    orca_runtime *runtime,
    orca_handle library,
    int64_t group_id
);
/* In one transaction, gives Track `keep_track_id` the Orca values, user
 * genres, rating and feedback of Track `from_track_id` that it lacks. A value
 * locked on the kept Track always stays, as do its user genres; a value
 * locked on the other replaces an unlocked one.
 * The rating and feedback are copied only when the two are different
 * recordings and the kept one has none; listens stay with their recording.
 * No file is written or moved. `output` may be null. The same Track twice is
 * ORCA_STATUS_INVALID_ARGUMENT; an unknown Track ORCA_STATUS_NOT_FOUND. */
orca_status orca_library_merge_duplicate_metadata(
    orca_runtime *runtime,
    orca_handle library,
    int64_t keep_track_id,
    int64_t from_track_id,
    orca_duplicate_merge *output
);
/* Calls `callback` with the name of each manual playlist holding file
 * `file_id`'s recording, by name, at most 512. ORCA_STATUS_NOT_FOUND, with the
 * callback not called, when no file has that id. */
orca_status orca_library_duplicate_copy_playlists(
    orca_runtime *runtime,
    orca_handle library,
    int64_t file_id,
    void *context,
    orca_string_callback callback
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

/* The Artist's release, track and appearance counts and summed duration.
 * NOT_FOUND for an unknown Artist. */
orca_status orca_library_artist_totals(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    orca_artist_totals *output
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
/* orca_library_browse_tracks with each Track's ids and facts. `query` may not
 * be null; INVALID_ARGUMENT for a limit outside 1..512, an unknown sort, an
 * unknown format, a null text pointer with a nonzero length, or text over
 * 256 bytes. */
orca_status orca_library_browse_tracks_v2(
    orca_runtime *runtime,
    orca_handle library,
    const orca_track_query_v2 *query,
    void *context,
    orca_track_summary_facts_callback callback
);
/* How many Tracks the filters in `query` match, so a host can size a
 * scrollbar without walking the listing. Sort, limit and offset are ignored. */
orca_status orca_library_track_match_count(
    orca_runtime *runtime,
    orca_handle library,
    const orca_track_query *query,
    uint64_t *output
);
/* How many Tracks orca_library_browse_tracks_v2 would list for `query`.
 * Sort, limit and offset are ignored. A track search has no count:
 * INVALID_ARGUMENT for a nonempty `text`. */
orca_status orca_library_track_match_count_v2(
    orca_runtime *runtime,
    orca_handle library,
    const orca_track_query_v2 *query,
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

/* orca_library_browse_releases with `has_*` flags, the filters of
 * orca_release_query_v2, and each Release's facts. INVALID_ARGUMENT for a
 * limit outside 1..512, an unknown sort, an unknown artwork filter, a null
 * text pointer with a nonzero length, or text over 256 bytes. */
orca_status orca_library_browse_releases_v2(
    orca_runtime *runtime,
    orca_handle library,
    const orca_release_query_v2 *query,
    void *context,
    orca_release_facts_callback callback
);
/* How many Releases orca_library_browse_releases_v2 would list for `query`.
 * Sort, limit and offset are ignored. */
orca_status orca_library_release_count_matching_v2(
    orca_runtime *runtime,
    orca_handle library,
    const orca_release_query_v2 *query,
    uint64_t *output
);

/* orca_library_browse_artists with a genre filter and a sort. `query` may not
 * be null; INVALID_ARGUMENT for a limit outside 1..512, an unknown sort, or
 * a null filter pointer with a nonzero length. */
orca_status orca_library_query_artists_v2(
    orca_runtime *runtime,
    orca_handle library,
    const orca_artist_query_v2 *query,
    void *context,
    orca_artist_v2_callback callback
);
/* How many Artists orca_library_query_artists_v2 would list for `query`.
 * Sort, limit and offset are ignored. */
orca_status orca_library_artist_count_matching_v2(
    orca_runtime *runtime,
    orca_handle library,
    const orca_artist_query_v2 *query,
    uint64_t *output
);

/* A page of the genres that some Track carries. A Track's genres come from
 * its file's tags, split where one value lists several ("Rock, Pop") and
 * folded so that spellings of one genre ("Hip-Hop", "hip hop",
 * "Hip Hop/Rap") are one, unless the user set them with
 * orca_library_set_track_genres. `query` may not be null; INVALID_ARGUMENT
 * for a limit outside 1..512, an unknown sort, or a null filter pointer with
 * a nonzero length. */
orca_status orca_library_query_genres(
    orca_runtime *runtime,
    orca_handle library,
    const orca_genre_query *query,
    void *context,
    orca_genre_callback callback
);
/* The Artists, Releases, Tracks, Playlists and genres where every
 * whitespace-separated word of `text` (`text_length` bytes; the pointer may
 * be null when it is 0) begins a word of the title or subtitle, case and
 * diacritics ignored. No character of `text` is query syntax: quotes, `*`,
 * `-`, brackets and words such as OR and NEAR are matched as text. Hits come
 * grouped by kind in orca_search_kind order, most relevant first within a
 * kind, up to that kind's cap in `limits`; a null `limits` means 5 Artists,
 * 5 Releases, 8 Tracks, 4 Playlists and 3 genres. Text with no word invokes
 * no callback. INVALID_ARGUMENT for text over 256 bytes or a cap over 50. */
orca_status orca_library_search(
    orca_runtime *runtime,
    orca_handle library,
    const char *text,
    size_t text_length,
    const orca_search_limits *limits,
    void *context,
    orca_search_hit_callback callback
);
/* How many genres orca_library_query_genres would list for `filter`
 * (`filter_length` bytes; the pointer may be null when it is 0). */
orca_status orca_library_genre_count(
    orca_runtime *runtime,
    orca_handle library,
    const char *filter,
    size_t filter_length,
    uint64_t *output
);
/* Invokes the callback once. NOT_FOUND, without a callback, when no Track
 * carries the genre. */
orca_status orca_library_genre_get(
    orca_runtime *runtime,
    orca_handle library,
    int64_t genre_id,
    void *context,
    orca_genre_callback callback
);
/* Invokes the callback once per genre of the Track, in the order its tags or
 * the user gave them; not at all for a Track with none. */
orca_status orca_library_track_genres(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_string_callback callback
);
/* Up to `limit` (1..512) genres of the Release's Tracks, most Tracks first. */
orca_status orca_library_release_genres(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    uint32_t limit,
    void *context,
    orca_genre_count_callback callback
);
/* Up to `limit` (1..512) genres of the Tracks an Artist is credited on, as
 * the Track's artist or its Release's album artist, most Tracks first. */
orca_status orca_library_artist_genres(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    uint32_t limit,
    void *context,
    orca_genre_count_callback callback
);
/* Gives each of 1 to 512 Tracks (`ids`, `count`) exactly `names` as its
 * genres, which then outrank its file's tags on every later scan. A name that
 * lists several genres with commas or semicolons ("Rock, Pop") gives each.
 * `name_count` 0 restores the genres the file's tags state. Kept in the
 * Library until orca_library_plan_tag_write writes them into the files.
 * INVALID_ARGUMENT for a name that is blank once split and folded, or for
 * more than 16 genres; NOT_FOUND when a Track does not exist, changing
 * nothing. */
orca_status orca_library_set_track_genres(
    orca_runtime *runtime,
    orca_handle library,
    const int64_t *ids,
    size_t count,
    const orca_string_view *names,
    size_t name_count
);
/* Invokes the callback once with up to `limit` (1..512) ids of the Releases
 * whose Tracks carry the genre and that have a cover, most played first,
 * for a cover mosaic. */
orca_status orca_library_genre_artwork(
    orca_runtime *runtime,
    orca_handle library,
    int64_t genre_id,
    uint32_t limit,
    void *context,
    orca_id_callback callback
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
/* orca_library_track_details with the totals, advisory and file dates. */
orca_status orca_library_track_details_v2(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_track_details_v2_callback callback
);
/* orca_library_track_details_v2 with the composer and comment. */
orca_status orca_library_track_details_v3(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_track_details_v3_callback callback
);
/* How often the Track's recording has been heard through any of its files,
 * and when last. A Track with no recording, or an unknown id, has a play
 * count of zero. */
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
/* Keeps the Library's orca_listen_policy. INVALID_ARGUMENT for a value that
 * is not one. */
orca_status orca_library_set_listen_policy(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t policy
);
/* The Library's orca_listen_policy; ORCA_LISTEN_POLICY_HALF_OR_FOUR_MINUTES
 * unless set. */
orca_status orca_library_listen_policy(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t *output
);
/* `enabled` 0 keeps no listens, so none is sent either; 1, the default, keeps
 * them. INVALID_ARGUMENT for any other value. */
orca_status orca_library_set_listen_recording(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t enabled
);
orca_status orca_library_listen_recording(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t *output
);
/* Deletes every local listen and every listen waiting to be sent, and with
 * them every play count. Ratings, loves and feedback stay. `removed`, which
 * may be null, receives how many listens went. */
orca_status orca_library_clear_listens(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t *removed
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
/* Loves (`loved` 1) or clears (`loved` 0) Artists, under the same rules as
 * orca_library_set_release_love. Artist love is kept in the Library only and
 * is never sent to ListenBrainz. */
orca_status orca_library_set_artist_love(
    orca_runtime *runtime,
    orca_handle library,
    const int64_t *artist_ids,
    size_t count,
    uint8_t loved,
    orca_change_count *output
);
/* Writes 1 to `output` when the user loved the Artist, else 0; an id that
 * names no Artist is 0. */
orca_status orca_library_artist_loved(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    uint8_t *output
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
    /* Unix seconds. `updated_at` moves on a rename, an entry edit, a rules
     * change and a description or tag change. */
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
 * when either is past the end; NOT_FOUND for an unknown playlist. Insert,
 * remove and move on a smart playlist are INVALID_STATE. */
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

/* A manual playlist holds the entries the user placed; a smart playlist's
 * entries are the Tracks its rules match each time it is read, one per
 * recording, and cannot be edited by position. */
typedef enum orca_playlist_kind {
    ORCA_PLAYLIST_KIND_MANUAL = 0,
    ORCA_PLAYLIST_KIND_SMART = 1,
} orca_playlist_kind;

typedef enum orca_playlist_creator {
    ORCA_PLAYLIST_CREATOR_USER = 0,
    /* Created by orca_library_import_playlist. */
    ORCA_PLAYLIST_CREATOR_IMPORTED = 1,
} orca_playlist_creator;

/* Every order ends in the playlist id, so paging is a total order. */
typedef enum orca_playlist_sort {
    ORCA_PLAYLIST_SORT_NAME = 0,
    /* Most recently updated first. */
    ORCA_PLAYLIST_SORT_RECENTLY_UPDATED = 1,
    /* Most recently created first. */
    ORCA_PLAYLIST_SORT_CREATED = 2,
    /* Manual playlists by entry count, most first, then smart playlists by
     * name. */
    ORCA_PLAYLIST_SORT_ENTRIES = 3,
} orca_playlist_sort;

/* One bounded request for a page of playlists. `filter` keeps the playlists
 * whose name contains it, ignoring ASCII case; empty (length 0, pointer may
 * be null) keeps every playlist. `kind` and `creator` filter only when their
 * `has_` flag is 1. `limit` must be between 1 and 512. */
typedef struct orca_playlist_query {
    orca_string_view filter;
    uint32_t limit;
    uint32_t offset;
    uint8_t sort;  /* orca_playlist_sort */
    uint8_t has_kind;
    uint8_t kind;  /* orca_playlist_kind */
    uint8_t pinned_only;
    uint8_t has_creator;
    uint8_t creator;  /* orca_playlist_creator */
    uint8_t reserved[2];
} orca_playlist_query;

/* What orca_playlist_view leaves out. For a smart playlist, the view's
 * `entries`, `available` and `duration_ms` are its rules evaluated now. */
typedef struct orca_playlist_facts_view {
    orca_string_view description;
    uint8_t pinned;
    uint8_t loved;
    uint8_t kind;  /* orca_playlist_kind */
    uint8_t creator;  /* orca_playlist_creator */
    /* The available entries name more than one Artist. */
    uint8_t mixed_artists;
    /* Read the tags with orca_library_playlist_tags. */
    uint8_t tag_count;
    uint8_t reserved[2];
} orca_playlist_facts_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_playlist_v2_callback)(
    void *context,
    const orca_playlist_view *playlist,
    const orca_playlist_facts_view *facts
);

/* Each string is `_length` bytes, not NUL-terminated; a field changes only
 * when its `has_` flag is 1. The description is trimmed and at most 4096
 * bytes. `tags` replaces every tag: each is trimmed, non-empty and at most 64
 * bytes, repeats are kept once, and at most 8 remain; `tags` may be NULL only
 * when `tag_count` is 0. */
typedef struct orca_playlist_update {
    orca_string_view description;
    const orca_string_view *tags;
    size_t tag_count;
    uint8_t has_description;
    uint8_t has_pinned;
    uint8_t pinned;
    uint8_t has_loved;
    uint8_t loved;
    uint8_t has_tags;
    uint8_t reserved[2];
} orca_playlist_update;

/* A page of playlists as `query` asks. A smart playlist whose stored rules
 * no longer compile fails the page with INTERNAL. */
orca_status orca_library_query_playlists_v2(
    orca_runtime *runtime,
    orca_handle library,
    const orca_playlist_query *query,
    void *context,
    orca_playlist_v2_callback callback
);
/* How many playlists `query` selects, ignoring its sort, limit and offset. */
orca_status orca_library_playlist_count(
    orca_runtime *runtime,
    orca_handle library,
    const orca_playlist_query *query,
    uint64_t *output
);
/* One playlist, as orca_library_query_playlists_v2 reports it. NOT_FOUND for
 * an unknown id. */
orca_status orca_library_playlist_get(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    void *context,
    orca_playlist_v2_callback callback
);
/* The playlist's tags in the order they were given. NOT_FOUND for an unknown
 * id. */
orca_status orca_library_playlist_tags(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    void *context,
    orca_string_callback callback
);
/* The genres the most available entries carry, most first, at most three.
 * NOT_FOUND for an unknown id. */
orca_status orca_library_playlist_genres(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    void *context,
    orca_string_callback callback
);
/* Changes the description, pin, love or tags; the Library keeps them and no
 * file is written. Only a description or tag change moves `updated_at`. A
 * bad value is INVALID_ARGUMENT; NOT_FOUND for an unknown id. */
orca_status orca_library_update_playlist(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    const orca_playlist_update *update
);
/* Creates a smart playlist named as for orca_library_create_playlist, whose
 * rules are the JSON `rules` (`rules_length` bytes, version 1, described in
 * docs/api.md). Rules that do not parse, name an unknown field or operator,
 * or nest too deep are INVALID_ARGUMENT, and nothing is stored. */
orca_status orca_library_create_smart_playlist(
    orca_runtime *runtime,
    orca_handle library,
    const char *name,
    size_t name_length,
    const char *rules,
    size_t rules_length,
    int64_t *playlist_id
);
/* Replaces a smart playlist's rules, checked as on create. INVALID_STATE for
 * a manual playlist; NOT_FOUND for an unknown id. */
orca_status orca_library_set_smart_playlist_rules(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    const char *rules,
    size_t rules_length
);
/* A smart playlist's rules as stored. INVALID_STATE for a manual playlist;
 * NOT_FOUND for an unknown id. */
orca_status orca_library_smart_playlist_rules(
    orca_runtime *runtime,
    orca_handle library,
    int64_t playlist_id,
    void *context,
    orca_string_callback callback
);
/* How many Tracks `rules` matches now, up to its limit, without storing
 * anything. Rules are checked as on create. */
orca_status orca_library_smart_playlist_count(
    orca_runtime *runtime,
    orca_handle library,
    const char *rules,
    size_t rules_length,
    uint64_t *output
);

/* -------------------------------------------------------------- artwork */

/* What an embedded picture says it shows. */
typedef enum orca_artwork_kind {
    ORCA_ARTWORK_KIND_FRONT_COVER = 0,
    ORCA_ARTWORK_KIND_BACK_COVER = 1,
    ORCA_ARTWORK_KIND_OTHER = 2,
} orca_artwork_kind;

/* What an artwork request asks about: a Track, a Release or an Artist id. An
 * Artist's image is the photo stored by its artist info. */
typedef enum orca_artwork_subject {
    ORCA_ARTWORK_SUBJECT_TRACK = 0,
    ORCA_ARTWORK_SUBJECT_RELEASE = 1,
    ORCA_ARTWORK_SUBJECT_ARTIST = 2,
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
 * `subject_id` the Track, Release or Artist id it was asked for. A subject
 * with no readable cover or stored photo arrives with `has_image` 0 and an
 * `image` of length 0. */
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
/* Asks for the cover of a Track or Release, or the photo of an Artist
 * (`subject`, an orca_artwork_subject, and its `id`) without waiting for
 * it. The lookup runs
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

/* --------------------------------------------------------------- lyrics */

/* Pass to orca_library_start_lyrics to ask LRCLIB. */
#define ORCA_LYRICS_FETCH 1

/* Where a lyrics job found a Track's lyrics, or why it found none. LOCAL: the
 * Track's sidecar or file. FETCHED: LRCLIB answered now. CACHED: an answer
 * LRCLIB gave earlier for the same title, artist, album and duration is kept.
 * CACHED_MISS: LRCLIB had none for them less than 7 days ago, so it was not
 * asked. NOT_FOUND: no lyrics anywhere asked, or no such Track. NO_METADATA:
 * the Track has no title or no artist to ask LRCLIB with. REFUSED: LRCLIB's
 * answer was a redirect, a 4xx other than 404, or a body that is not a record
 * of at most 512 KiB. UNAVAILABLE: LRCLIB could not be reached or is backing
 * off. BUSY: another Orca process holds LRCLIB. NOT_REQUESTED: the job has
 * not finished. With ORCA_LYRICS_FETCH the outcome is what asking LRCLIB came
 * to, even when the Track's own plain lyrics are the ones returned; LOCAL
 * then means its own synced lyrics made asking needless. */
typedef enum orca_lyrics_outcome {
    ORCA_LYRICS_OUTCOME_LOCAL = 0,
    ORCA_LYRICS_OUTCOME_FETCHED = 1,
    ORCA_LYRICS_OUTCOME_CACHED = 2,
    ORCA_LYRICS_OUTCOME_CACHED_MISS = 3,
    ORCA_LYRICS_OUTCOME_NOT_FOUND = 4,
    ORCA_LYRICS_OUTCOME_NO_METADATA = 5,
    ORCA_LYRICS_OUTCOME_REFUSED = 6,
    ORCA_LYRICS_OUTCOME_UNAVAILABLE = 7,
    ORCA_LYRICS_OUTCOME_BUSY = 8,
    ORCA_LYRICS_OUTCOME_CANCELLED = 9,
    ORCA_LYRICS_OUTCOME_NOT_REQUESTED = 10,
} orca_lyrics_outcome;

/* SIDECAR: a `.lrc` file beside the Track's file with its base name.
 * EMBEDDED: the file's tags (ID3v2 SYLT or USLT, Vorbis comment LYRICS or
 * UNSYNCEDLYRICS, MP4 ©lyr). LRCLIB: an answer from LRCLIB. */
typedef enum orca_lyrics_source {
    ORCA_LYRICS_SOURCE_SIDECAR = 0,
    ORCA_LYRICS_SOURCE_EMBEDDED = 1,
    ORCA_LYRICS_SOURCE_LRCLIB = 2,
} orca_lyrics_source;

/* SYNCED lines carry start times; PLAIN lines do not. INSTRUMENTAL is
 * LRCLIB's word that the Track has no words, with no lines. */
typedef enum orca_lyrics_kind {
    ORCA_LYRICS_KIND_SYNCED = 0,
    ORCA_LYRICS_KIND_PLAIN = 1,
    ORCA_LYRICS_KIND_INSTRUMENTAL = 2,
} orca_lyrics_kind;

/* One line. `start_ms` is where it starts in the Track, or -1 for plain
 * lyrics. Synced lines come in start order. */
typedef struct orca_lyrics_line {
    int64_t start_ms;
    orca_string_view text;
} orca_lyrics_line;

/* A Track's lyrics. `source` is an orca_lyrics_source and `kind` an
 * orca_lyrics_kind. `language` is a lower-case ISO 639-2 code when the
 * source names one, else empty. `lines` holds `line_count` lines, at most
 * 4096. Every string and the `lines` array are valid only for the duration of
 * the callback that receives the view; copy what you keep. */
typedef struct orca_lyrics_view {
    uint8_t source;
    uint8_t kind;
    uint8_t reserved[6];
    orca_string_view language;
    const orca_lyrics_line *lines;
    size_t line_count;
} orca_lyrics_view;

typedef void (*orca_lyrics_callback)(void *context, const orca_lyrics_view *lyrics);

/*
 * Starts reading a Track's lyrics as an ORCA_JOB_KIND_LYRICS job and returns
 * immediately: a synced `.lrc` sidecar beside its file, else synced lyrics in
 * the file, else synced lyrics from LRCLIB, else plain lyrics from the
 * sidecar, the file, then LRCLIB, else LRCLIB's word that the Track is
 * instrumental. Nothing is written to a file.
 *
 * LRCLIB is asked only with ORCA_LYRICS_FETCH in `flags`, which a host leaves
 * off until the person turns it on, and only with the Track's title, artist,
 * album and duration. Without it, only an answer the Library already keeps
 * for those values is used. LRCLIB grants use of its API but not of the
 * lyrics: rights to the words stay with their owners, and the host answers
 * for showing or keeping them.
 *
 * INVALID_ARGUMENT for an unknown bit in `flags`. INVALID_STATE with
 * ORCA_LYRICS_FETCH and no client identity (orca_runtime_set_client_identity).
 * A Track that does not exist is not an error: its job finishes with
 * ORCA_LYRICS_OUTCOME_NOT_FOUND.
 */
orca_status orca_library_start_lyrics(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    uint8_t flags,
    orca_handle *job
);

/* Writes the lyrics job's orca_lyrics_outcome to `outcome`;
 * ORCA_LYRICS_OUTCOME_NOT_REQUESTED until it finishes. INVALID_ARGUMENT for a
 * job of another kind, STALE_HANDLE for an unknown job. */
orca_status orca_job_lyrics_outcome(
    orca_runtime *runtime,
    orca_handle job,
    uint8_t *outcome
);

/* Invokes the callback once with the lyrics a finished lyrics job found, and
 * releases them: the job hands its lyrics over once, so a second call is
 * NOT_FOUND. NOT_FOUND, without a callback, also while the job runs and when
 * it found none. INVALID_ARGUMENT for a job of another kind, STALE_HANDLE for
 * an unknown job. */
orca_status orca_job_lyrics(
    orca_runtime *runtime,
    orca_handle job,
    void *context,
    orca_lyrics_callback callback
);

/* ---------------------------------------------------------- artist info */

/* What an artist info job came to: the first step that failed, else how the
 * info was found. NOT_REQUESTED: the job has not finished. FETCHED: every
 * service asked answered. CACHED: info fetched less than 30 days ago for the
 * same MusicBrainz artist ID is kept, and nothing was asked.
 * NO_MUSICBRAINZ_ID: the Artist has none, so only a local image was looked
 * for. OFFLINE: only the local image and answers already cached were used.
 * NOT_FOUND: no such Artist. REFUSED: a service's answer was a 4xx, a
 * redirect off the service, or a body Orca does not accept. UNAVAILABLE: a
 * service could not be reached or is backing off. BUSY: another Orca process
 * holds one of the services. CANCELLED: the job was cancelled, and nothing
 * was kept. Otherwise what the steps before a failure found is kept. */
typedef enum orca_artist_info_outcome {
    ORCA_ARTIST_INFO_OUTCOME_NOT_REQUESTED = 0,
    ORCA_ARTIST_INFO_OUTCOME_FETCHED = 1,
    ORCA_ARTIST_INFO_OUTCOME_CACHED = 2,
    ORCA_ARTIST_INFO_OUTCOME_NO_MUSICBRAINZ_ID = 3,
    ORCA_ARTIST_INFO_OUTCOME_OFFLINE = 4,
    ORCA_ARTIST_INFO_OUTCOME_NOT_FOUND = 5,
    ORCA_ARTIST_INFO_OUTCOME_REFUSED = 6,
    ORCA_ARTIST_INFO_OUTCOME_UNAVAILABLE = 7,
    ORCA_ARTIST_INFO_OUTCOME_BUSY = 8,
    ORCA_ARTIST_INFO_OUTCOME_CANCELLED = 9,
} orca_artist_info_outcome;

/* LOCAL: an image in the Artist's folder (artist.jpg, artist.png,
 * folder.jpg, thumb.jpg or fanart.jpg). COMMONS: a Wikimedia Commons image,
 * shown with its licence and credit. */
typedef enum orca_artist_photo_source {
    ORCA_ARTIST_PHOTO_SOURCE_LOCAL = 0,
    ORCA_ARTIST_PHOTO_SOURCE_COMMONS = 1,
} orca_artist_photo_source;

typedef enum orca_artist_link_kind {
    ORCA_ARTIST_LINK_KIND_OFFICIAL = 0,
    ORCA_ARTIST_LINK_KIND_WIKIPEDIA = 1,
    ORCA_ARTIST_LINK_KIND_WIKIDATA = 2,
    ORCA_ARTIST_LINK_KIND_MUSICBRAINZ = 3,
    ORCA_ARTIST_LINK_KIND_DISCOGS = 4,
    ORCA_ARTIST_LINK_KIND_LASTFM = 5,
    ORCA_ARTIST_LINK_KIND_BANDCAMP = 6,
    ORCA_ARTIST_LINK_KIND_SOUNDCLOUD = 7,
    ORCA_ARTIST_LINK_KIND_YOUTUBE = 8,
    ORCA_ARTIST_LINK_KIND_SPOTIFY = 9,
    ORCA_ARTIST_LINK_KIND_APPLE_MUSIC = 10,
    ORCA_ARTIST_LINK_KIND_TIDAL = 11,
    ORCA_ARTIST_LINK_KIND_DEEZER = 12,
    ORCA_ARTIST_LINK_KIND_INSTAGRAM = 13,
    ORCA_ARTIST_LINK_KIND_X = 14,
    ORCA_ARTIST_LINK_KIND_FACEBOOK = 15,
    ORCA_ARTIST_LINK_KIND_TIKTOK = 16,
    ORCA_ARTIST_LINK_KIND_OTHER = 17,
} orca_artist_link_kind;

/* `language` is the Wikipedia whose article is the biography, falling back to
 * English: a code such as "en", "de" or "zh-yue"; empty means "en". `force` 1
 * fetches again even when the kept info is recent, and prefers a Commons
 * photo to a local image. `offline` 1 makes no request and uses only the
 * local image and answers already cached. `include_releases` 1 then fetches
 * the info of each of the Artist's Releases with a MusicBrainz release ID,
 * at most 64, as orca_library_start_release_info does, stopping at the
 * first Release a service could not answer. */
typedef struct orca_artist_info_options {
    orca_string_view language;
    uint8_t force;
    uint8_t offline;
    uint8_t include_releases;
    uint8_t reserved[5];
} orca_artist_info_options;

/* What the Library keeps for an Artist. `fetched_at` is Unix seconds.
 * `begin_year` and `end_year` are valid when their `has_` flag is 1; `ended`
 * is 1 when MusicBrainz says the Artist ended. `photo_source` is an
 * orca_artist_photo_source when `has_photo` is 1; a COMMONS photo carries
 * `photo_url` (its Commons page), `photo_licence` (such as "CC BY 2.0"),
 * `photo_licence_url` and `photo_credit` (plain text), which a host shows
 * with it. `biography` is the lead of the Artist's Wikipedia article,
 * `biography_licence` "CC BY-SA 4.0", shown with a link to `biography_url`.
 * `outcome` is the orca_artist_info_outcome of the fetch that kept this.
 * `listeners`, valid when `has_listeners` is 1, is how many ListenBrainz
 * users listened to the Artist, refreshed at most weekly.
 * Absent strings are empty. Every string is valid only for the duration of
 * the callback. */
typedef struct orca_artist_info_view {
    int64_t fetched_at;
    int32_t begin_year;
    int32_t end_year;
    uint8_t has_begin_year;
    uint8_t has_end_year;
    uint8_t ended;
    uint8_t has_photo;
    uint8_t photo_source;
    uint8_t has_biography;
    uint8_t outcome;
    uint8_t has_listeners;
    orca_string_view musicbrainz_artist_id;
    orca_string_view wikidata_id;
    orca_string_view artist_type;
    orca_string_view biography;
    orca_string_view biography_url;
    orca_string_view biography_licence;
    orca_string_view biography_language;
    orca_string_view photo_url;
    orca_string_view photo_licence;
    orca_string_view photo_licence_url;
    orca_string_view photo_credit;
    int64_t listeners;
} orca_artist_info_view;

typedef void (*orca_artist_info_callback)(void *context, const orca_artist_info_view *info);

/* `kind` is an orca_artist_link_kind. */
typedef struct orca_artist_link_view {
    uint8_t kind;
    uint8_t reserved[7];
    orca_string_view url;
} orca_artist_link_view;

/* `links` holds `count` links, at most 64, valid only for the duration of the
 * callback. */
typedef void (*orca_artist_links_callback)(
    void *context,
    const orca_artist_link_view *links,
    size_t count
);

/*
 * Starts fetching an Artist's info as an ORCA_JOB_KIND_ARTIST_INFO job and
 * returns immediately. The photo is an image in the Artist's folder, else the
 * Wikimedia Commons image that the Artist's Wikidata item or MusicBrainz
 * names; the biography is the lead of its Wikipedia article; years active,
 * type and links come from MusicBrainz. Everything is kept in the Library;
 * nothing is written to a file. Only an Artist with a MusicBrainz artist ID
 * is looked up online.
 *
 * `options` may not be null. INVALID_ARGUMENT for a malformed language or a
 * flag other than 0 or 1, NOT_FOUND for an unknown Artist, INVALID_STATE
 * without a client identity (orca_runtime_set_client_identity).
 */
orca_status orca_library_start_artist_info(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    const orca_artist_info_options *options,
    orca_handle *job
);

/* Writes the artist info job's orca_artist_info_outcome to `outcome`;
 * ORCA_ARTIST_INFO_OUTCOME_NOT_REQUESTED until it finishes. INVALID_ARGUMENT
 * for a job of another kind, STALE_HANDLE for an unknown job. */
orca_status orca_job_artist_info_outcome(
    orca_runtime *runtime,
    orca_handle job,
    uint8_t *outcome
);

/* Writes to `stores` how many times the artist info job has stored part of
 * what it found, while it runs: the Artist's info first, then its listeners
 * and related artists, then their photos, then the covers of its albums
 * and EPs. INVALID_ARGUMENT for a job of
 * another kind, STALE_HANDLE for an unknown job. */
orca_status orca_job_artist_info_stores(
    orca_runtime *runtime,
    orca_handle job,
    uint32_t *stores
);

/* Invokes the callback once with what the Library keeps for the Artist.
 * NOT_FOUND, without a callback, when nothing was ever fetched for it. */
orca_status orca_library_artist_info(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    void *context,
    orca_artist_info_callback callback
);

/* Invokes the callback once with the Artist's kept photo; its `kind` is
 * ORCA_ARTWORK_KIND_OTHER. NOT_FOUND, without a callback, when there is none. */
orca_status orca_library_artist_photo(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    void *context,
    orca_image_callback callback
);

/* Invokes the callback once with the Artist's kept links, by kind and then
 * URL; `count` is 0 when there are none. */
orca_status orca_library_artist_links(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    void *context,
    orca_artist_links_callback callback
);

/* An artist ListenBrainz Labs finds similar, `score` higher for more
 * similar. `library_artist_id`, valid when `has_library_artist_id` is 1, is
 * the Library Artist with that MusicBrainz artist ID, or else that name.
 * `has_photo` is 1 when a photo is kept: for a Library Artist the one
 * orca_library_artist_photo reads, otherwise the one
 * orca_library_related_artist_photo reads by `mbid`. */
typedef struct orca_related_artist_view {
    orca_string_view name;
    orca_string_view mbid;
    int64_t library_artist_id;
    uint8_t has_library_artist_id;
    uint8_t has_photo;
    uint8_t reserved[2];
    uint32_t score;
} orca_related_artist_view;

/* `artists` holds `count` related artists, most similar first, at most 12,
 * valid only for the duration of the callback. */
typedef void (*orca_related_artists_callback)(
    void *context,
    const orca_related_artist_view *artists,
    size_t count
);

/* Invokes the callback once with the Artist's kept related artists, which
 * orca_library_start_artist_info fetches; `count` is 0 when there are none. */
orca_status orca_library_related_artists(
    orca_runtime *runtime,
    orca_handle library,
    int64_t artist_id,
    void *context,
    orca_related_artists_callback callback
);

/* Invokes the callback once with the photo kept for the related artist
 * outside the Library whose MusicBrainz artist ID is `musicbrainz_artist_id`
 * (`musicbrainz_artist_id_length` bytes, compared without case);
 * orca_library_start_artist_info fetches it. Its `kind` is
 * ORCA_ARTWORK_KIND_OTHER. NOT_FOUND, without a callback, when none is kept,
 * including when the artist was found to have none. Reads only the Library;
 * it never fetches. */
orca_status orca_library_related_artist_photo(
    orca_runtime *runtime,
    orca_handle library,
    const char *musicbrainz_artist_id,
    size_t musicbrainz_artist_id_length,
    void *context,
    orca_image_callback callback
);

/* Where a related artist's kept photo came from and the credit a host shows
 * with it. `fetched_at` is Unix seconds. `photo_source` is an
 * orca_artist_photo_source, always COMMONS: `photo_url` is the photo's
 * Commons page, `photo_licence` its licence (such as "CC BY 2.0"),
 * `photo_licence_url` the licence's page and `photo_credit` its author as
 * plain text. Absent strings are empty. Every string is valid only for the
 * duration of the callback. */
typedef struct orca_related_artist_photo_info_view {
    int64_t fetched_at;
    uint8_t photo_source;
    uint8_t reserved[7];
    orca_string_view photo_url;
    orca_string_view photo_licence;
    orca_string_view photo_licence_url;
    orca_string_view photo_credit;
} orca_related_artist_photo_info_view;

typedef void (*orca_related_artist_photo_info_callback)(
    void *context,
    const orca_related_artist_photo_info_view *info
);

/* Invokes the callback once with the source and credit of the photo
 * orca_library_related_artist_photo returns for `musicbrainz_artist_id`
 * (`musicbrainz_artist_id_length` bytes, compared without case). NOT_FOUND,
 * without a callback, when no photo is kept. Reads only the Library. */
orca_status orca_library_related_artist_photo_info(
    orca_runtime *runtime,
    orca_handle library,
    const char *musicbrainz_artist_id,
    size_t musicbrainz_artist_id_length,
    void *context,
    orca_related_artist_photo_info_callback callback
);

/* ---------------------------------------------------------- release info */

typedef enum orca_release_description_source {
    ORCA_RELEASE_DESCRIPTION_SOURCE_WIKIPEDIA = 0,
} orca_release_description_source;

/* `language` is the Wikipedia whose article is the description, falling back
 * to English; empty means "en". `force` 1 fetches again even when the kept
 * info is recent. `offline` 1 makes no request and uses only answers already
 * cached. */
typedef struct orca_release_info_options {
    orca_string_view language;
    uint8_t force;
    uint8_t offline;
    uint8_t reserved[6];
} orca_release_info_options;

/* What the Library keeps for a Release. `fetched_at` is Unix seconds.
 * `description` is the lead of the Wikipedia article on the Release's
 * release group, valid when `has_description` is 1, with `description_source`
 * an orca_release_description_source and `description_licence`
 * "CC BY-SA 4.0", shown with a link to `description_url`. `outcome` is the
 * orca_artist_info_outcome of the fetch that kept this. Absent strings are
 * empty. Every string is valid only for the duration of the callback. */
typedef struct orca_release_info_view {
    int64_t fetched_at;
    uint8_t has_description;
    uint8_t description_source;
    uint8_t outcome;
    uint8_t reserved[5];
    orca_string_view description;
    orca_string_view description_url;
    orca_string_view description_licence;
    orca_string_view description_language;
    orca_string_view musicbrainz_release_id;
    orca_string_view musicbrainz_release_group_id;
} orca_release_info_view;

typedef void (*orca_release_info_callback)(void *context, const orca_release_info_view *info);

/*
 * Starts fetching a Release's description as an ORCA_JOB_KIND_RELEASE_INFO
 * job and returns immediately. MusicBrainz names the release group, whose
 * Wikidata item, or failing that its Wikipedia link, names the article.
 * Unless orca_library_set_genre_fill turned it off, the release group's
 * MusicBrainz genres go on the Release's Tracks with no genre from a file or
 * an edit. Kept in the Library; nothing is written to a file.
 *
 * `options` may not be null. INVALID_ARGUMENT for a malformed language or a
 * flag other than 0 or 1, NOT_FOUND for an unknown Release, INVALID_STATE
 * without a client identity.
 */
orca_status orca_library_start_release_info(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    const orca_release_info_options *options,
    orca_handle *job
);

/* Writes the release info job's orca_artist_info_outcome to `outcome`;
 * ORCA_ARTIST_INFO_OUTCOME_NOT_REQUESTED until it finishes. INVALID_ARGUMENT
 * for a job of another kind, STALE_HANDLE for an unknown job. */
orca_status orca_job_release_info_outcome(
    orca_runtime *runtime,
    orca_handle job,
    uint8_t *outcome
);

/* Invokes the callback once with what the Library keeps for the Release.
 * NOT_FOUND, without a callback, when nothing was ever fetched for it. */
orca_status orca_library_release_info(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    void *context,
    orca_release_info_callback callback
);

/* ------------------------------------------------------------ genre fill */

/* `musicbrainz` 1 lets artist and release info fetches fill genres from
 * MusicBrainz, licensed CC BY-NC-SA 3.0, for Tracks with none; a host shows
 * that credit beside them. On unless turned off. */
typedef struct orca_genre_fill {
    uint8_t musicbrainz;
    uint8_t reserved[7];
} orca_genre_fill;

/* `limit` is the most Releases asked about, 1 to 512. `offline` 1 makes no
 * request and uses only answers already cached. */
typedef struct orca_genre_fill_options {
    uint32_t limit;
    uint8_t offline;
    uint8_t reserved[3];
} orca_genre_fill_options;

/* Keeps the Library's genre fill setting. INVALID_ARGUMENT for a flag other
 * than 0 or 1. */
orca_status orca_library_set_genre_fill(
    orca_runtime *runtime,
    orca_handle library,
    const orca_genre_fill *fill
);

orca_status orca_library_genre_fill(
    orca_runtime *runtime,
    orca_handle library,
    orca_genre_fill *fill
);

/*
 * Fills genres from MusicBrainz, whatever orca_library_set_genre_fill says,
 * for Releases with a MusicBrainz release ID and a Track with no genre, as an
 * ORCA_JOB_KIND_RELEASE_INFO job that keeps no description; its snapshot's
 * completed_units counts the Releases asked about. INVALID_ARGUMENT for a
 * limit outside 1 to 512, INVALID_STATE without a client identity.
 */
orca_status orca_library_start_genre_fill(
    orca_runtime *runtime,
    orca_handle library,
    const orca_genre_fill_options *options,
    orca_handle *job
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
    /* "1" explicit, "2" clean, "0" neither: the ITUNESADVISORY values. */
    ORCA_METADATA_FIELD_EXPLICIT = 13,
    ORCA_METADATA_FIELD_COMPOSER = 14,
    ORCA_METADATA_FIELD_COMMENT = 15,
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
 * its path, its identity when planned, every field's value before and after,
 * and its genres before and after when the write replaces them. A write
 * starts only with the digest of the plan a person was shown, so it writes
 * exactly what was approved. */
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

/* A file the plan writes, at `path`, with its `change_count` changes. A
 * change of the file's genres is read separately, with
 * orca_library_query_tag_write_genres, so a file whose only change is its
 * genres has a `change_count` of 0. */
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
    /* Orca cannot create files in the file's folder, which a write needs for
     * its staged copy. Check the folder's permissions. */
    ORCA_TAG_WRITE_SKIP_FOLDER_NOT_WRITABLE = 3,
    /* The file is read-only: no write permission bit is set, or the process
     * may not write it. Orca does not change a file made read-only. */
    ORCA_TAG_WRITE_SKIP_FILE_READ_ONLY = 4,
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
 * rolled back as recovery does, and orca_job_tag_write_failure says which
 * file it stopped at and why. Either way the files are read again and
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

/* Why a tag write failed at a file. */
typedef enum orca_tag_write_failure_reason {
    /* Orca may not create or replace files in the file's folder or in the
     * Library's backup directory. */
    ORCA_TAG_WRITE_FAILURE_PERMISSION_DENIED = 0,
    /* The file, or the Library's backup directory, is on a read-only file
     * system. */
    ORCA_TAG_WRITE_FAILURE_READ_ONLY_FILE_SYSTEM = 1,
    /* The disk had no room for the staged copy or the backup. */
    ORCA_TAG_WRITE_FAILURE_NO_SPACE = 2,
    /* The file changed after the plan was made, so the plan no longer
     * describes it. Plan the write again. */
    ORCA_TAG_WRITE_FAILURE_CHANGED_SINCE_PLAN = 3,
    ORCA_TAG_WRITE_FAILURE_OTHER = 4,
    /* The file is read-only: no write permission bit is set, or the process
     * may not write it. Orca does not change a file made read-only. */
    ORCA_TAG_WRITE_FAILURE_FILE_READ_ONLY = 5,
} orca_tag_write_failure_reason;

/* The file a failed tag write stopped at: `action_index` is its position
 * among the plan's files, and `reason` an orca_tag_write_failure_reason. */
typedef struct orca_tag_write_failure {
    int64_t file_id;
    uint32_t action_index;
    uint8_t reason;
    uint8_t reserved[3];
} orca_tag_write_failure;

/* Fills `out` with the file a finished, failed tag write job stopped at and
 * why. NOT_FOUND while the job runs, after it succeeded, or when it failed
 * before reaching a file, such as when an earlier interrupted write could
 * not be recovered. INVALID_ARGUMENT for a NULL `out` or a job that is not
 * an ORCA_JOB_KIND_MUTATION job. */
orca_status orca_job_tag_write_failure(
    orca_runtime *runtime,
    orca_handle job,
    orca_tag_write_failure *out
);
/* Drops a held plan without writing anything. NOT_FOUND for a plan that is
 * not held. */
orca_status orca_library_discard_tag_write(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t plan_id
);

/* The genres a held plan writes into file `file_id`: `before` are the
 * genres the file's tag holds now, in order, and `after` the user's genres
 * the write replaces them with, in order and never empty. */
typedef struct orca_tag_write_genres_view {
    int64_t file_id;
    const orca_string_view *before;
    size_t before_count;
    const orca_string_view *after;
    size_t after_count;
} orca_tag_write_genres_view;

typedef void (*orca_tag_write_genres_callback)(
    void *context,
    const orca_tag_write_genres_view *genres
);

/* Invokes the callback once with the genres held plan `plan_id` writes into
 * file `file_id`, one of the files its orca_tag_write_plan_view listed. Call
 * it after orca_library_plan_tag_write returns, not from its callback.
 * NOT_FOUND, without a callback, for a plan that is not held, a file the
 * plan does not write, or a file whose genres it leaves alone.
 * INVALID_ARGUMENT for a NULL callback. */
orca_status orca_library_query_tag_write_genres(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t plan_id,
    int64_t file_id,
    void *context,
    orca_tag_write_genres_callback callback
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

/* What became of a tag write, as its journal records it. */
typedef enum orca_tag_write_group_state {
    /* Every file was written. */
    ORCA_TAG_WRITE_GROUP_STATE_APPLIED = 0,
    /* An undo was interrupted; orca_library_undo_tag_write finishes it. */
    ORCA_TAG_WRITE_GROUP_STATE_UNDOING = 1,
    /* orca_library_undo_tag_write restored every file. */
    ORCA_TAG_WRITE_GROUP_STATE_UNDONE = 2,
    /* The write or its undo was interrupted and recovery restored every
     * file. */
    ORCA_TAG_WRITE_GROUP_STATE_ROLLED_BACK = 3,
    /* A file could not be written; the files already written were restored. */
    ORCA_TAG_WRITE_GROUP_STATE_FAILED = 4,
    /* A file or backup changed outside Orca; see orca_library_undo_tag_write. */
    ORCA_TAG_WRITE_GROUP_STATE_NEEDS_RECONCILIATION = 5,
} orca_tag_write_group_state;

/* A tag write in the change history. `group_id` is the group
 * orca_library_undo_tag_write takes; `written_at` is when it was planned to
 * run, in Unix seconds. `title` is the Release title its files share, empty
 * when they span several or none. `can_undo` is 1 when
 * orca_library_undo_tag_write would run it: every file written and every
 * backup kept, or an undo to finish. It is read from the journal alone, so an
 * undo of a file changed since can still return NEEDS_RECONCILIATION.
 * `expired` is 1 when the write's backups were pruned. */
typedef struct orca_tag_write_group_view {
    uint64_t group_id;
    int64_t written_at;
    uint64_t file_count;
    uint8_t state; /* orca_tag_write_group_state */
    uint8_t can_undo;
    uint8_t expired;
    uint8_t reserved[5];
    orca_string_view title;
} orca_tag_write_group_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_tag_write_group_callback)(
    void *context,
    const orca_tag_write_group_view *group
);

/* The finished tag writes of `library`, newest first; writes still running
 * are left out. INVALID_ARGUMENT for a `limit` outside 1...512. */
orca_status orca_library_query_tag_write_groups(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_tag_write_group_callback callback
);

typedef enum orca_tag_write_diff_subject {
    /* `field` names the tag. */
    ORCA_TAG_WRITE_DIFF_SUBJECT_FIELD = 0,
    ORCA_TAG_WRITE_DIFF_SUBJECT_GENRES = 1,
    /* The file or its backup could not be read: the backup was pruned or
     * consumed by an undo, or the file is gone. `restores` and `current` are
     * empty. */
    ORCA_TAG_WRITE_DIFF_SUBJECT_UNKNOWN = 2,
} orca_tag_write_diff_subject;

/* One tag a write changed in `file`. `restores` is the backup's value, which
 * an undo puts back; `current` is the file's value now. Either is empty when
 * the tag is absent; genres are joined with "; ". */
typedef struct orca_tag_write_diff_view {
    uint8_t subject; /* orca_tag_write_diff_subject */
    uint8_t field;   /* orca_metadata_field, when `subject` is FIELD */
    uint8_t reserved[6];
    orca_string_view file;
    orca_string_view restores;
    orca_string_view current;
} orca_tag_write_diff_view;

/* `diffs` holds at most 512 rows, whole files only, in action order;
 * `more_files` counts the changed files left out. `field_count` counts every
 * changed tag of every file, those left out included. */
typedef struct orca_tag_write_group_detail_view {
    orca_tag_write_group_view group;
    const orca_tag_write_diff_view *diffs;
    size_t diff_count;
    uint64_t more_files;
    uint64_t field_count;
} orca_tag_write_group_detail_view;

/* String views and `diffs` are valid only for the duration of this callback. */
typedef void (*orca_tag_write_group_detail_callback)(
    void *context,
    const orca_tag_write_group_detail_view *detail
);

/* Reads every file of tag write `group_id` and its backup, on the calling
 * thread, and compares their tags. Nothing is written. NOT_FOUND for a group
 * that is not a finished tag write. */
orca_status orca_library_query_tag_write_group(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t group_id,
    void *context,
    orca_tag_write_group_detail_callback callback
);

/* Writes every tag write group, newest first, to `path` (`path_length` bytes,
 * not NUL-terminated), one line each in the form of `orca-cli changes`. The
 * file appears complete and synced or not at all. An existing file is
 * INVALID_STATE unless `replace` is 1; `replace` above 1 is INVALID_ARGUMENT.
 * NOT_FOUND when the folder does not exist. `exported` counts the groups
 * written. */
orca_status orca_library_export_tag_write_history(
    orca_runtime *runtime,
    orca_handle library,
    const char *path,
    size_t path_length,
    uint8_t replace,
    uint64_t *exported
);

/* Registering a root is an explicit user action: it is the one path allowed to
 * persist a volume identifier at a mount root. INVALID_ARGUMENT when `path` is
 * empty or not absolute; a frontend resolves a relative path itself. */
orca_status orca_library_add_root(
    orca_runtime *runtime,
    orca_handle library,
    const char *path,
    int64_t *root_id
);
/* Forgets a root and every file, Track, Release and Artist that exists only
 * under it, and every Recording no file elsewhere holds, with its loves,
 * ratings, play counts and playlist entries; listen history stays without its
 * Recording. Files on disk are untouched. NOT_FOUND for an unknown root, BUSY
 * while a job is running on the library. */
orca_status orca_library_remove_root(
    orca_runtime *runtime,
    orca_handle library,
    int64_t root_id
);
/* Moves root `root_id` to `path`, bound to the volume `path` is on now, and
 * keeps the root's id, every File, Track and location under it, and the undo
 * of every tag write there; then starts a whole-root reconcile Job and returns
 * it in `job`. INVALID_ARGUMENT when `path` is not absolute or not a readable
 * directory, is inside or holds another root or files of another root, or is
 * inside or holds the root's old folder while that still exists; NOT_FOUND for an
 * unknown root; BUSY while a job is running on the library, another runtime
 * or process is walking it, a tag write holds the library's journal, or one
 * under the root is unfinished;
 * NEEDS_RECONCILIATION when one under the root needs reconciliation. */
orca_status orca_library_relocate_root(
    orca_runtime *runtime,
    orca_handle library,
    int64_t root_id,
    const char *path,
    orca_handle *job
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
/* orca_library_query_roots with each root's availability and Track counts.
 * `limit` must be between 1 and 512. */
orca_status orca_library_query_roots_v2(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_root_v2_callback callback
);
/* How many Tracks have no present or unverified copy of their preferred
 * file, as scans and playback last recorded it; nothing on disk is read. */
orca_status orca_library_missing_file_count(
    orca_runtime *runtime,
    orca_handle library,
    uint64_t *count
);
/* One page of the folder `path` below root `root_id`: subfolders, then files.
 * `path` is relative to the root, `/`-separated, and empty for the root
 * itself; a path with an empty, `.` or `..` component, a leading `/` or a NUL
 * is INVALID_ARGUMENT, and an unknown root NOT_FOUND. Missing files are left
 * out. `limit` must be between 1 and 512. */
orca_status orca_library_query_folder(
    orca_runtime *runtime,
    orca_handle library,
    int64_t root_id,
    const char *path,
    size_t path_length,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_folder_entry_callback callback
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
 * INVALID_ARGUMENT for a directory not in that form. Started while another
 * job holds the library's slot, it is ORCA_JOB_WAITING until that one ends.
 * Its stats are read through orca_library_scan_stats, with a scan's meaning.
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

/* ------------------------------------------------------------- matching */

/* What a matching job does with the Tracks in scope. SEARCH looks up those
 * with no recording ID that a provider in scope has not answered for;
 * REIDENTIFY looks up every one again, confirming the recording it is
 * identified as rather than proposing it; VERIFY checks each file's recording
 * ID against what AcoustID hears in its fingerprint and searches nothing. */
typedef enum orca_match_mode {
    ORCA_MATCH_MODE_SEARCH = 0,
    ORCA_MATCH_MODE_REIDENTIFY = 1,
    ORCA_MATCH_MODE_VERIFY = 2,
} orca_match_mode;

/* Whether AcoustID took part in a matching job, and why not. OFF: the job
 * was asked for no fingerprints. INVALID_CLIENT_KEY: AcoustID refused the
 * application key and the job went on without it. */
typedef enum orca_acoustid_use {
    ORCA_ACOUSTID_USE_SEARCHED = 0,
    ORCA_ACOUSTID_USE_OFF = 1,
    ORCA_ACOUSTID_USE_NO_CLIENT_KEY = 2,
    ORCA_ACOUSTID_USE_INVALID_CLIENT_KEY = 3,
} orca_acoustid_use;

/* The service another Orca process was talking to when the job needed it. */
typedef enum orca_busy_service {
    ORCA_BUSY_SERVICE_NONE = 0,
    ORCA_BUSY_SERVICE_MUSICBRAINZ = 1,
    ORCA_BUSY_SERVICE_ACOUSTID = 2,
} orca_busy_service;

/* What a job did about a Release's front cover. EMBEDDED: a file of the
 * Release carries one, so nothing was fetched. CACHED: a cover fetched
 * earlier for the same release ID is kept. CACHED_MISS: the Cover Art Archive
 * had none less than 30 days ago, so it was not asked. NOT_FOUND: it has none.
 * NO_RELEASE_ID: neither a tag nor an accepted match gives the Release a
 * MusicBrainz release ID. REFUSED: the archive's answer was a redirect off
 * the archive, another 4xx, or a body that is not a JPEG or PNG of at most
 * 4 MiB. BUSY: another Orca process holds the archive. FOLDER: a front cover
 * image in the Release's folder is shown before a fetched one, so nothing was
 * fetched. CHOSEN: a person chose the Release's front cover, so nothing was
 * fetched. PARTIAL: a candidates fetch stored the release's own candidates
 * but could not read its release group's index. */
typedef enum orca_cover_art_outcome {
    ORCA_COVER_ART_OUTCOME_NOT_REQUESTED = 0,
    ORCA_COVER_ART_OUTCOME_EMBEDDED = 1,
    ORCA_COVER_ART_OUTCOME_FETCHED = 2,
    ORCA_COVER_ART_OUTCOME_CACHED = 3,
    ORCA_COVER_ART_OUTCOME_CACHED_MISS = 4,
    ORCA_COVER_ART_OUTCOME_NOT_FOUND = 5,
    ORCA_COVER_ART_OUTCOME_NO_RELEASE_ID = 6,
    ORCA_COVER_ART_OUTCOME_REFUSED = 7,
    ORCA_COVER_ART_OUTCOME_UNAVAILABLE = 8,
    ORCA_COVER_ART_OUTCOME_BUSY = 9,
    ORCA_COVER_ART_OUTCOME_CANCELLED = 10,
    ORCA_COVER_ART_OUTCOME_FOLDER = 11,
    ORCA_COVER_ART_OUTCOME_CHOSEN = 12,
    ORCA_COVER_ART_OUTCOME_PARTIAL = 13,
} orca_cover_art_outcome;

/* How a file's recording ID compared with what AcoustID heard in its
 * fingerprint. */
typedef enum orca_verification_outcome {
    ORCA_VERIFICATION_OUTCOME_AGREES = 0,
    ORCA_VERIFICATION_OUTCOME_DISAGREES = 1,
    ORCA_VERIFICATION_OUTCOME_UNCONFIRMED = 2,
    ORCA_VERIFICATION_OUTCOME_NO_FINGERPRINT = 3,
} orca_verification_outcome;

/*
 * Options for orca_library_start_match. A zero field keeps its default, so a
 * zero-initialised struct is a whole-library search with fingerprints.
 *
 * `batch_size`: Tracks per committed batch, 0 for 64. `limit`, with
 * `has_limit`: examine at most this many Tracks. `mode` is an
 * orca_match_mode. `track_id` (with `has_track_id`) or `release_id` (with
 * `has_release_id`) narrows the job to one Track or one Release's Tracks;
 * not both. `skip_fingerprints` set: no fingerprint and no AcoustID lookup.
 * With `release_id` only: `accept_minimum_confidence` (with
 * `has_accept_minimum_confidence`, greater than 0 and at most 1) then accepts
 * the Release's matches orca_library_accept_confident_matches would accept at
 * that confidence, and `cover_art` then fetches its front cover as
 * orca_library_start_cover_art_fetch does.
 */
typedef struct orca_match_options {
    uint32_t batch_size;
    uint32_t limit;
    int64_t track_id;
    int64_t release_id;
    float accept_minimum_confidence;
    uint8_t mode;
    uint8_t has_limit;
    uint8_t has_track_id;
    uint8_t has_release_id;
    uint8_t skip_fingerprints;
    uint8_t has_accept_minimum_confidence;
    uint8_t cover_art;
    uint8_t reserved[5];
} orca_match_options;

/*
 * Starts a MusicBrainz and AcoustID matching job, of kind
 * ORCA_JOB_KIND_METADATA_LOOKUP, and returns immediately. `options` may be
 * NULL for a whole-library search with fingerprints. The job stores
 * reviewable proposals in the Library; it writes no file and accepts nothing
 * unless `accept_minimum_confidence` asks it to. Fingerprints and AcoustID
 * need the AcoustID application key or a credential callback; without them
 * the job searches MusicBrainz alone. Requests go out at most one a second
 * per service. Its counts are read with orca_job_match_stats.
 *
 * While an idle-maintenance unit runs, returns OK with a job that stays
 * ORCA_JOB_WAITING: the unit is cancelled, and the job starts from a later
 * orca_runtime_pump once it has stopped. INVALID_STATE without a
 * client identity (orca_runtime_set_client_identity), and for VERIFY without
 * AcoustID. INVALID_ARGUMENT for an unknown mode, both `track_id` and
 * `release_id`, REIDENTIFY without either or with
 * `accept_minimum_confidence`, `accept_minimum_confidence` or `cover_art`
 * without `release_id` or with VERIFY, or a confidence outside (0, 1].
 * NOT_FOUND for an unknown Release. BUSY while another matching job of the
 * runtime runs or is queued, or an AcoustID submission runs.
 */
orca_status orca_library_start_match(
    orca_runtime *runtime,
    orca_handle library,
    const orca_match_options *options,
    orca_handle *job
);

/*
 * Starts fetching the Release's front cover from the Cover Art Archive and
 * returns immediately. The job's kind is ORCA_JOB_KIND_METADATA_LOOKUP, and
 * `cover_art` in its orca_match_stats says what it did. A fetched cover is
 * stored in the Library, never in a file, and orca_library_release_artwork
 * returns it. Statuses as orca_library_start_match: INVALID_STATE without a
 * client identity, NOT_FOUND for an unknown Release, BUSY while a matching
 * job runs or is queued, and OK with a waiting job while an idle-maintenance
 * unit stops.
 */
orca_status orca_library_start_cover_art_fetch(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    orca_handle *job
);

/*
 * What a matching job or cover fetch did so far. `requests` and `cache_hits`
 * are MusicBrainz's. `confirmed` counts Tracks a REIDENTIFY found again as
 * the recording they are identified as; `verified` the files a VERIFY stored
 * an outcome for, split into `agreed`, `disagreed` and `unconfirmed`;
 * `skipped` the files it passed over for having no quick hash.
 * `correction_groups` counts album groups of corrections it formed, and
 * `accepted` the matches it accepted. `acoustid` is an orca_acoustid_use,
 * `busy` an orca_busy_service and `cover_art` an orca_cover_art_outcome.
 */
typedef struct orca_match_stats {
    uint64_t tracks_examined;
    uint64_t matched;
    uint64_t unmatched;
    uint64_t insufficient_evidence;
    uint64_t refused;
    uint64_t proposals_stored;
    uint64_t confirmed;
    uint64_t verified;
    uint64_t agreed;
    uint64_t disagreed;
    uint64_t unconfirmed;
    uint64_t skipped;
    uint64_t correction_groups;
    uint64_t requests;
    uint64_t cache_hits;
    uint64_t fingerprinted;
    uint64_t fingerprint_cache_hits;
    uint64_t fingerprint_failures;
    uint64_t acoustid_requests;
    uint64_t acoustid_cache_hits;
    uint64_t acoustid_refused;
    uint64_t accepted;
    uint8_t acoustid;
    uint8_t busy;
    uint8_t cover_art;
    uint8_t cancelled;
    uint8_t reserved[4];
} orca_match_stats;

/* All zero, with `acoustid` OFF, for a queued job or a job of another kind.
 * STALE_HANDLE for an unknown job. */
orca_status orca_job_match_stats(
    orca_runtime *runtime,
    orca_handle job,
    orca_match_stats *output
);

/* orca_match_stats with `releases_to_review`: the Releases holding a Track
 * the job matched that, when its searches ended and before it accepted
 * anything, were in the CONFIDENT or NEEDS_REVIEW bucket. 0 until then. */
typedef struct orca_match_stats_v2 {
    orca_match_stats base;
    uint64_t releases_to_review;
} orca_match_stats_v2;

/* orca_job_match_stats with `releases_to_review`. */
orca_status orca_job_match_stats_v2(
    orca_runtime *runtime,
    orca_handle job,
    orca_match_stats_v2 *output
);

/* The Release that holds most of a finished Match Album's files, with
 * `has_release_id` 1: the files of the album's Tracks when the job started,
 * so a host can follow an album that accepting a release ID moved to a new
 * Release id. The same id when the album kept its key. `has_release_id` 0
 * and `release_id` 0 while the job runs or is queued, for a job that is not
 * a release-scoped search or re-identify, and when no Release holds the
 * files. STALE_HANDLE for an unknown job. */
orca_status orca_job_match_release(
    orca_runtime *runtime,
    orca_handle job,
    int64_t *release_id,
    uint8_t *has_release_id
);

/*
 * A pending proposal of a recording for a file. `confidence` is 0 to 1;
 * `provider` is "musicbrainz" or "acoustid". `title`, `artist` and `album`
 * are what accepting would give the Track; the `track_*` and `release_*`
 * fields are the proposed release's own, each with its `has_*` flag.
 * `musicbrainz_score` is 0 to 100 and `acoustid_score` 0 to 1. `corrects`,
 * with `has_corrects`, is the recording ID in effect that accepting would
 * replace; a proposal without it is not a correction. Every string view is
 * valid only for the duration of the callback.
 */
typedef struct orca_match_proposal_view {
    int64_t id;
    uint64_t duration_ms;
    orca_string_view provider;
    orca_string_view recording_mbid;
    orca_string_view title;
    orca_string_view artist;
    orca_string_view album;
    orca_string_view release_mbid;
    orca_string_view track_title;
    orca_string_view track_artist;
    orca_string_view release_title;
    orca_string_view release_artist;
    orca_string_view release_date;
    orca_string_view release_group_mbid;
    orca_string_view release_track_mbid;
    orca_string_view corrects;
    float confidence;
    float acoustid_score;
    uint32_t track_number;
    uint32_t disc_number;
    uint8_t musicbrainz_score;
    uint8_t has_track_number;
    uint8_t has_disc_number;
    uint8_t has_release_mbid;
    uint8_t has_duration_ms;
    uint8_t has_musicbrainz_score;
    uint8_t has_acoustid_score;
    uint8_t has_track_title;
    uint8_t has_track_artist;
    uint8_t has_release_title;
    uint8_t has_release_artist;
    uint8_t has_release_date;
    uint8_t has_release_group_mbid;
    uint8_t has_release_track_mbid;
    uint8_t has_corrects;
    uint8_t reserved[1];
} orca_match_proposal_view;

typedef void (*orca_match_proposal_callback)(void *context, const orca_match_proposal_view *proposal);

/* Invokes the callback once per pending proposal for the Track's file, best
 * first, at most 512. An unknown Track has none. */
orca_status orca_library_query_match_proposals(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_match_proposal_callback callback
);

/* `values_written` counts every value stored, on any file, the Release's
 * other files included. */
typedef struct orca_match_acceptance {
    int64_t file_id;
    uint32_t values_written;
    uint8_t reserved[4];
} orca_match_acceptance;

/* `values_written` counts every value stored, on any file. */
typedef struct orca_confident_acceptance {
    uint64_t accepted;
    uint64_t values_written;
} orca_confident_acceptance;

/*
 * Accepts the proposal: its recording ID, title and artist, and its
 * release's values once every Track of the Release names it, become Orca's
 * values for the file, and the file is reprojected. A correction's recording
 * ID is stored locked. Only the Library changes; no file is written, and a
 * locked value of the user's is kept. NOT_FOUND for an unknown proposal;
 * INVALID_STATE for one already accepted or dismissed, or one that belongs to
 * an album group of corrections (orca_library_accept_correction_group).
 */
orca_status orca_library_accept_match(
    orca_runtime *runtime,
    orca_handle library,
    int64_t proposal_id,
    orca_match_acceptance *output
);
/* Dismisses the proposal. Statuses as orca_library_accept_match. */
orca_status orca_library_dismiss_match(orca_runtime *runtime, orca_handle library, int64_t proposal_id);

/* A Track with pending proposals: its own tags beside its best proposal, and
 * how many it has. Valid only for the duration of the callback. */
typedef struct orca_match_review_view {
    int64_t track_id;
    int64_t duration_ms;
    uint32_t proposal_count;
    uint8_t has_duration_ms;
    uint8_t reserved[3];
    orca_string_view title;
    orca_string_view artist;
    orca_string_view album;
    orca_match_proposal_view best;
} orca_match_review_view;

typedef void (*orca_match_review_callback)(void *context, const orca_match_review_view *item);

/* Invokes the callback for a page of Tracks with pending proposals, by
 * artist, album and position. `limit` is 1 to 512, else INVALID_ARGUMENT. */
orca_status orca_library_query_match_review(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_match_review_callback callback
);
/* How many Tracks orca_library_query_match_review lists. */
orca_status orca_library_match_review_count(orca_runtime *runtime, orca_handle library, uint64_t *count);
/* Tracks a matching job with fingerprints would search: no recording ID,
 * and not yet answered for by MusicBrainz, or by AcoustID when a key is
 * set. */
orca_status orca_library_unidentified_count(orca_runtime *runtime, orca_handle library, uint64_t *count);
/* How many matches orca_library_accept_confident_matches would accept now
 * at `minimum_confidence`: per file, the best proposal at least that
 * confident that its fingerprint backs, or else its most confident one when
 * that reaches `minimum_confidence` and shows a higher percent than every
 * other; never a correction. `minimum_confidence` is greater than 0 and at
 * most 1; 0, a negative value, more than 1 or NaN is INVALID_ARGUMENT. */
orca_status orca_library_confident_match_count(
    orca_runtime *runtime,
    orca_handle library,
    float minimum_confidence,
    uint64_t *count
);
/* Accepts the matches orca_library_confident_match_count counts, as
 * orca_library_accept_match does, in the Library only. The files it changed
 * are not returned: requery what the host shows. */
orca_status orca_library_accept_confident_matches(
    orca_runtime *runtime,
    orca_handle library,
    float minimum_confidence,
    orca_confident_acceptance *output
);
/* Stores what the MusicBrainz release a Release's accepted matches agree on
 * says, when every Track names it, and reprojects: for a Release that came
 * to agree without an accept, after an edit moved a stray file out or a
 * rescan. `values_written` receives how many values were stored, 0 when the
 * Tracks do not agree. NOT_FOUND for an unknown Release; reprojecting can
 * give the Release a new id. */
orca_status orca_library_apply_matched_release(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    uint32_t *values_written
);

/* A value Match Review compares between a Release and a MusicBrainz release.
 * Bit `1u << field` selects it for orca_library_apply_matched_release_fields.
 * RELEASE_ID covers the release, release group and album artist IDs on every
 * Track, and the release track and recording IDs and the track and disc
 * numbers on a placed Track; TRACK_TITLES a placed Track's title and artist.
 * RELEASE_TYPE, GENRE and ARTWORK are compared but never stored. */
typedef enum orca_release_field {
    ORCA_RELEASE_FIELD_ALBUM = 0,
    ORCA_RELEASE_FIELD_ALBUM_ARTIST = 1,
    ORCA_RELEASE_FIELD_RELEASE_DATE = 2,
    ORCA_RELEASE_FIELD_RELEASE_TYPE = 3,
    ORCA_RELEASE_FIELD_RELEASE_ID = 4,
    ORCA_RELEASE_FIELD_GENRE = 5,
    ORCA_RELEASE_FIELD_ARTWORK = 6,
    ORCA_RELEASE_FIELD_TRACK_TITLES = 7
} orca_release_field;

/* Stores the fields whose bits are set in `fields` of the Release's best
 * candidate's tracklist snapshot, locked, so they outrank the files' own
 * tags; the other values and their provenance stay. The release's own values
 * go to every Track with a file; a Track placed on a release track by
 * recording ID or by a pairing also takes that release track's values, and
 * with RELEASE_ID the pending proposal that placed it is accepted. A user
 * lock wins and no file is written. `values_written` counts the values
 * stored; it is 0 without a candidate, before a lookup snapshotted its
 * tracklist, or for a Release of more than 512 Tracks. A bit past
 * TRACK_TITLES is INVALID_ARGUMENT. */
orca_status orca_library_apply_matched_release_fields(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    uint32_t fields,
    uint32_t *values_written
);

/* Where a Release stands against MusicBrainz. CONFIDENT: its best candidate
 * is at least `confident_at` and is not dismissed. NEEDS_REVIEW: a candidate
 * exists below that. UNMATCHED: there is none. REVIEWED: a person's review of
 * its best candidate still holds, as orca_library_mark_release_reviewed
 * describes, or its tags identify it, as orca_release_match_view
 * `from_tags` describes; such a Release is in no other bucket. */
typedef enum orca_release_match_bucket {
    ORCA_RELEASE_MATCH_BUCKET_CONFIDENT = 0,
    ORCA_RELEASE_MATCH_BUCKET_NEEDS_REVIEW = 1,
    ORCA_RELEASE_MATCH_BUCKET_UNMATCHED = 2,
    ORCA_RELEASE_MATCH_BUCKET_REVIEWED = 3
} orca_release_match_bucket;

/* A Release beside its best MusicBrainz release candidate: the release its
 * Tracks are named on, by release ID, accepted match or proposal, that has
 * the highest mean per-Track confidence. A release a Track's release ID
 * names counts toward `confidence` only once Orca read it and the alignment
 * with its snapshot places the Track. Until Orca read it, it is the best
 * candidate, in NEEDS_REVIEW, with `confidence` 0 and `candidate_title`
 * the Release's own title; orca_release_match_view_v2 tells this apart.
 * The candidate fields are empty and `has_best` 0 for an unmatched Release. `from_tags` is 1 for a REVIEWED
 * Release no person reviewed: every Track's file has a release ID tag
 * naming the best candidate, and the alignment with its tracklist snapshot
 * places every Track by recording ID or by a pairing. Valid only for the
 * duration of the callback. */
typedef struct orca_release_match_view {
    int64_t release_id;
    uint32_t track_count;
    uint8_t bucket;
    uint8_t has_best;
    uint8_t has_candidate_track_count;
    uint8_t from_tags;
    orca_string_view title;
    orca_string_view artist;
    orca_string_view release_mbid;
    orca_string_view candidate_title;
    orca_string_view candidate_date;
    uint32_t candidate_track_count;
    float confidence;
} orca_release_match_view;

typedef void (*orca_release_match_callback)(void *context, const orca_release_match_view *item);

/* Invokes the callback for a page of the Releases in `bucket`, an
 * orca_release_match_bucket, by album artist and title. `confident_at` is
 * greater than 0 and at most 1, and `limit` 1 to 512; otherwise
 * INVALID_ARGUMENT. Weighing every Release, a page costs a walk of the
 * Library. */
orca_status orca_library_query_release_matches(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t bucket,
    float confident_at,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_release_match_callback callback
);

typedef struct orca_release_match_counts {
    uint64_t confident;
    uint64_t needs_review;
    uint64_t unmatched;
} orca_release_match_counts;

/* How many Releases each bucket of orca_library_query_release_matches holds.
 * A reviewed Release is counted in none of them. */
orca_status orca_library_release_match_counts(
    orca_runtime *runtime,
    orca_handle library,
    float confident_at,
    orca_release_match_counts *output
);

/* Why a Release is, or is not, a MusicBrainz release. `fingerprints_matched`
 * counts Tracks AcoustID heard on it at 0.9 or more; `durations_within_1s`
 * is set when each compared Track is within a second of its recording; the
 * artist and title agree when nearly equal ignoring case and spacing, the
 * date only when the same text. `note` says it in a sentence. Valid only for
 * the duration of the callback. */
typedef struct orca_match_evidence_view {
    uint32_t fingerprints_matched;
    uint32_t tracks;
    uint8_t durations_within_1s;
    uint8_t artist_agrees;
    uint8_t title_agrees;
    uint8_t date_agrees;
    uint8_t reserved[4];
    orca_string_view note;
} orca_match_evidence_view;

typedef void (*orca_match_evidence_callback)(void *context, const orca_match_evidence_view *evidence);

/* The evidence for the Release against `release_mbid`, a NUL-terminated
 * MusicBrainz release ID, or its best candidate when NULL. NOT_FOUND for an
 * unknown Release or one with no candidate; INVALID_ARGUMENT for an ID that
 * is not a MusicBrainz ID. */
orca_status orca_library_release_match_evidence(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    const char *release_mbid,
    void *context,
    orca_match_evidence_callback callback
);

/* One orca_release_field beside the candidate's. `differs` is set when the
 * candidate has a value that is not the local one. */
typedef struct orca_release_field_diff_view {
    uint8_t field;
    uint8_t differs;
    uint8_t reserved[6];
    orca_string_view local;
    orca_string_view candidate;
} orca_release_field_diff_view;

/* A Track beside its track on the candidate: `candidate_title` and
 * `candidate_artist` are empty and `has_delta_ms` 0 when the release does
 * not name it. `local_artist` and `candidate_artist` are the Track's and the
 * release track's artist credits; `differs` is 1 when storing the release
 * track's title and artist credit would change the Track's, which the
 * TRACK_TITLES field counts. `delta_ms` is the recording's duration less the
 * Track's. */
typedef struct orca_release_track_alignment_view {
    int64_t track_id;
    int64_t delta_ms;
    uint32_t position;
    uint8_t has_delta_ms;
    uint8_t fingerprint;
    uint8_t differs;
    uint8_t reserved[1];
    orca_string_view local_title;
    orca_string_view candidate_title;
    orca_string_view local_artist;
    orca_string_view candidate_artist;
} orca_release_track_alignment_view;

/* Every orca_release_field in order, then every Track; `aligned` counts the
 * Tracks the release names. Valid only for the duration of the callback. */
typedef struct orca_release_match_diff_view {
    orca_string_view release_mbid;
    const orca_release_field_diff_view *fields;
    size_t field_count;
    const orca_release_track_alignment_view *tracks;
    size_t track_count;
    uint32_t aligned;
    uint8_t reserved[4];
} orca_release_match_diff_view;

typedef void (*orca_release_match_diff_callback)(void *context, const orca_release_match_diff_view *diff);

/* The Release's values beside a candidate's, `release_mbid` as
 * orca_library_release_match_evidence. Statuses as it. */
orca_status orca_library_release_match_diff(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    const char *release_mbid,
    void *context,
    orca_release_match_diff_callback callback
);

/* Marks `release_mbid` as not the Release ("Not This Release"): it is no
 * longer a candidate for it. A Release of more Tracks than one page is never
 * a candidate. NOT_FOUND for an unknown Release; INVALID_ARGUMENT for an ID
 * that is not a MusicBrainz ID. */
orca_status orca_library_dismiss_release_candidate(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    const char *release_mbid
);

/* orca_release_match_view with how many of the Release's Tracks the
 * alignment with its best candidate's tracklist snapshot places:
 * `placed` by recording ID or by a pairing, `needs_pairing` only suggested
 * or on no release track. `has_placement` is 0, and both counts 0, without a
 * candidate, before a lookup snapshotted its tracklist, or for a Release of
 * more than 512 Tracks. `candidate_unread` is 1 when a Track's release ID
 * names the best candidate and Orca has not read the release from
 * MusicBrainz: its confidence is unknown, and `base.confidence` is 0.
 * Valid only for the duration of the callback. */
typedef struct orca_release_match_view_v2 {
    orca_release_match_view base;
    uint32_t placed;
    uint32_t needs_pairing;
    uint8_t has_placement;
    uint8_t candidate_unread;
    uint8_t reserved[6];
} orca_release_match_view_v2;

typedef void (*orca_release_match_v2_callback)(void *context, const orca_release_match_view_v2 *item);

/* orca_library_query_release_matches with each Release's placement counts,
 * so a Matches page takes one call. `filter`, NUL-terminated or NULL for
 * every Release, keeps the Releases whose title or album artist has a word
 * starting with each of its words; at most 256 bytes, else INVALID_ARGUMENT.
 * Weighing every Release, a page costs a walk of the Library; each item with
 * a candidate then costs one Release read, snapshot read and pairings read
 * and an alignment. */
orca_status orca_library_query_release_matches_v2(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t bucket,
    float confident_at,
    const char *filter,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_release_match_v2_callback callback
);

/* orca_release_match_counts with how many Releases are in the REVIEWED
 * bucket. */
typedef struct orca_release_match_counts_v2 {
    orca_release_match_counts base;
    uint64_t reviewed;
} orca_release_match_counts_v2;

/* How many Releases each bucket of orca_library_query_release_matches_v2
 * holds under `filter`, as it takes it. */
orca_status orca_library_release_match_counts_v2(
    orca_runtime *runtime,
    orca_handle library,
    float confident_at,
    const char *filter,
    orca_release_match_counts_v2 *output
);

/* The orca_release_match_bucket that
 * orca_library_query_release_matches_v2 lists the Release in against
 * `confident_at`, so a host can say where a finished search left an album.
 * NOT_FOUND for an unknown Release. */
orca_status orca_library_release_match_bucket(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    float confident_at,
    uint8_t *bucket
);

/* How a release track of an alignment has its Track. PAIRED: a person paired
 * them. AUTOMATIC: the release track lists a recording ID the Track holds.
 * SUGGESTED: at least two of the title, length and position agree and the
 * pair is the best for both; a person confirms it by pairing. NOT_IN_FILES:
 * no Track is on it. */
typedef enum orca_placement_status {
    ORCA_PLACEMENT_STATUS_PAIRED = 0,
    ORCA_PLACEMENT_STATUS_AUTOMATIC = 1,
    ORCA_PLACEMENT_STATUS_SUGGESTED = 2,
    ORCA_PLACEMENT_STATUS_NOT_IN_FILES = 3
} orca_placement_status;

/* Where the recording ID that placed an AUTOMATIC Track came from: the
 * file's recording ID in effect (its tag or a value a person set), an
 * accepted match, or a pending one. NONE for every other status. */
typedef enum orca_recording_source {
    ORCA_RECORDING_SOURCE_NONE = 0,
    ORCA_RECORDING_SOURCE_IN_EFFECT = 1,
    ORCA_RECORDING_SOURCE_ACCEPTED_MATCH = 2,
    ORCA_RECORDING_SOURCE_PENDING_MATCH = 3
} orca_recording_source;

/* A Track of the Release as an alignment shows it. A number or duration is 0
 * when its `has_` flag is 0. */
typedef struct orca_aligned_track_view {
    int64_t track_id;
    int64_t duration_ms;
    uint32_t track_number;
    uint32_t disc_number;
    uint8_t has_duration_ms;
    uint8_t has_track_number;
    uint8_t has_disc_number;
    uint8_t reserved[5];
    orca_string_view title;
} orca_aligned_track_view;

/* One release track and the Track on it. `status` is an
 * orca_placement_status and `recording_source` an orca_recording_source.
 * `track` is zero and `has_track` 0 for NOT_IN_FILES. The evidence flags say
 * what agrees between the Track and the release track: the normalized
 * titles, the lengths within two seconds, and the disc (1 when unset) and
 * track number. `length_delta_ms` is the Track's length less the release
 * track's when both are known. */
typedef struct orca_release_track_placement_view {
    uint32_t disc;
    uint32_t position;
    uint64_t length_ms;
    int64_t length_delta_ms;
    uint8_t has_length_ms;
    uint8_t status;
    uint8_t recording_source;
    uint8_t has_track;
    uint8_t title_equal;
    uint8_t length_close;
    uint8_t position_equal;
    uint8_t has_length_delta_ms;
    orca_string_view title;
    orca_string_view artist_credit;
    orca_string_view recording_mbid;
    orca_string_view release_track_mbid;
    orca_aligned_track_view track;
} orca_release_track_placement_view;

/* A Release laid against one MusicBrainz release's tracklist snapshot.
 * `rows` holds one view per release track in disc then position order;
 * `not_on_release` the Tracks placed on no release track and suggested for
 * none, in disc, track number, then Track ID order. The status counts sum to
 * `row_count`. `release_date` and `release_group_mbid` are empty when the
 * release has none; `fetched_at` is when the snapshot was taken, in Unix
 * seconds. Everything is valid only for the duration of the callback. */
typedef struct orca_release_alignment_view {
    int64_t release_id;
    int64_t fetched_at;
    uint32_t medium_count;
    uint32_t paired;
    uint32_t automatic;
    uint32_t suggested;
    uint32_t not_in_files;
    uint8_t reserved[4];
    orca_string_view release_mbid;
    orca_string_view title;
    orca_string_view artist_credit;
    orca_string_view release_date;
    orca_string_view release_group_mbid;
    const orca_release_track_placement_view *rows;
    size_t row_count;
    const orca_aligned_track_view *not_on_release;
    size_t not_on_release_count;
} orca_release_alignment_view;

typedef void (*orca_release_alignment_callback)(void *context, const orca_release_alignment_view *alignment);

/* Invokes the callback once with the Release laid against `release_mbid`, a
 * NUL-terminated MusicBrainz release ID, or its best candidate when NULL.
 * NOT_FOUND for an unknown Release or one with no candidate;
 * INVALID_ARGUMENT for an ID that is not a MusicBrainz ID; INVALID_STATE
 * before a lookup snapshotted the release's tracklist, which a release-scoped
 * orca_library_start_match does; UNSUPPORTED for a Release of more than 512
 * Tracks. */
orca_status orca_library_release_alignment(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    const char *release_mbid,
    void *context,
    orca_release_alignment_callback callback
);

/* How a pairing was made: a person confirmed the suggestion the alignment
 * showed, or chose the release track by hand. */
typedef enum orca_pairing_origin {
    ORCA_PAIRING_ORIGIN_CONFIRMED_SUGGESTION = 0,
    ORCA_PAIRING_ORIGIN_BY_HAND = 1
} orca_pairing_origin;

/* Pairs a Track of the Release with the release track `release_track_mbid`
 * of `release_mbid`, or of the best candidate when NULL, both NUL-terminated,
 * replacing the Track's pairing on that release. Every file of the Track
 * takes the release track's recording ID and release-track ID as locked
 * values in the Library; no media file is written, and the Track may get a
 * new id. `origin` receives an orca_pairing_origin. NOT_FOUND for an unknown
 * Release, one with no candidate, a Track not on the Release or a release
 * track the snapshot does not list; INVALID_ARGUMENT for an ID that is not a
 * MusicBrainz ID; INVALID_STATE before a lookup snapshotted the tracklist or
 * when another Track holds the release track; UNSUPPORTED for a Release of
 * more than 512 Tracks. */
orca_status orca_library_pair_release_track(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    const char *release_mbid,
    int64_t track_id,
    const char *release_track_mbid,
    uint8_t *origin
);

/* Removes the Track's pairing on the Release and puts back the values it
 * replaced where its files still hold the pairing's values. ALREADY_DONE
 * when the Track has no pairing there. */
orca_status orca_library_unpair_release_track(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    int64_t track_id
);

/* A pairing of one of a Release's Tracks. `origin` is an
 * orca_pairing_origin and `created_at` Unix seconds. `in_snapshot` is 0 when
 * the release's snapshot no longer lists the release track; an alignment
 * then ignores the pairing, and `disc` and `position` are 0 with
 * `has_position` 0. Valid only for the duration of the callback. */
typedef struct orca_release_track_pairing_view {
    int64_t release_id;
    int64_t track_id;
    int64_t created_at;
    uint32_t disc;
    uint32_t position;
    uint8_t origin;
    uint8_t in_snapshot;
    uint8_t has_position;
    uint8_t reserved[5];
    orca_string_view release_mbid;
    orca_string_view release_track_mbid;
    orca_string_view recording_mbid;
} orca_release_track_pairing_view;

typedef void (*orca_release_track_pairing_callback)(void *context, const orca_release_track_pairing_view *pairing);

/* Invokes the callback for every pairing of the Release's Tracks, on any
 * release, by release MBID, then disc and position, unlisted release tracks
 * last; at most 512. An unknown Release has none. */
orca_status orca_library_query_release_track_pairings(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    void *context,
    orca_release_track_pairing_callback callback
);

/* Why an Apply gave a Track none of its release track's values: the
 * alignment places it on no release track or only suggests one, or it has no
 * file to store values on. */
typedef enum orca_left_alone_reason {
    ORCA_LEFT_ALONE_REASON_NOT_PLACED = 0,
    ORCA_LEFT_ALONE_REASON_NO_PLAY_FILE = 1
} orca_left_alone_reason;

/* A Track an Apply left alone. `reason` is an orca_left_alone_reason. */
typedef struct orca_left_alone_track_view {
    int64_t track_id;
    uint8_t reason;
    uint8_t reserved[7];
    orca_string_view title;
} orca_left_alone_track_view;

/* What an Apply stored. `values_written` counts values; `track_values` the
 * Tracks with a file the alignment placed, which took their release track's
 * values; `release_values_only` the other Tracks with a file, which took the
 * release's own values only. `left_alone` lists every Track given no release
 * track values, in the alignment's Track order. `artist_ids_unknown` is set
 * when the snapshot predates Orca keeping the release's artist IDs, so the
 * album artist ID and compilation flag were left alone until a lookup
 * replaces it. An Apply that left no Track alone marks the Release as
 * reviewed, whichever fields it stored and whatever values still differ:
 * `reviewed_release_id` is its id after reprojection, with
 * `has_reviewed_release_id` set. Everything is valid only for the duration
 * of the callback. */
typedef struct orca_release_apply_view {
    int64_t reviewed_release_id;
    uint32_t values_written;
    uint32_t track_values;
    uint32_t release_values_only;
    uint8_t artist_ids_unknown;
    uint8_t has_reviewed_release_id;
    uint8_t reserved[2];
    orca_string_view release_mbid;
    const orca_left_alone_track_view *left_alone;
    size_t left_alone_count;
} orca_release_apply_view;

typedef void (*orca_release_apply_callback)(void *context, const orca_release_apply_view *outcome);

/* A person's Apply in Match Review: stores the fields whose bits are set in
 * `fields`, as orca_library_apply_matched_release_fields does, and invokes
 * the callback once with what it stored. Unplaced Tracks never refuse an
 * Apply. A bit past TRACK_TITLES or an ID that is not a MusicBrainz ID is
 * INVALID_ARGUMENT; NOT_FOUND for an unknown Release or one with no
 * candidate; INVALID_STATE before a lookup snapshotted the tracklist;
 * UNSUPPORTED for a Release of more than 512 Tracks. Reprojecting can give
 * the Release and its Tracks new ids. */
orca_status orca_library_apply_release(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    uint32_t fields,
    void *context,
    orca_release_apply_callback callback
);

/* Marks the Release as reviewed against `release_mbid`, NUL-terminated, or
 * its best candidate when NULL, whatever values still differ from it: it
 * moves to the REVIEWED bucket while that release stays its best candidate
 * and its Tracks, their values and the snapshot stay as they were.
 * INVALID_STATE unless every Track has a file and is placed, or before a
 * lookup snapshotted the tracklist. NOT_FOUND, INVALID_ARGUMENT and
 * UNSUPPORTED as orca_library_release_alignment. */
orca_status orca_library_mark_release_reviewed(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id,
    const char *release_mbid
);

/* Forgets the Release's review, holding or not, so it returns to the bucket
 * its best candidate puts it in. NOT_FOUND for an unknown Release;
 * ALREADY_DONE when it has no review, as for a Release only its tags
 * identify; removing or changing a file's release ID tag returns that one. */
orca_status orca_library_unmark_release_reviewed(
    orca_runtime *runtime,
    orca_handle library,
    int64_t release_id
);

/* A recording AcoustID heard in a fingerprint, with its score from 0 to 1. */
typedef struct orca_heard_recording_view {
    orca_string_view mbid;
    float score;
    uint8_t reserved[4];
} orca_heard_recording_view;

/*
 * A Track's file's last verification. `outcome` is an
 * orca_verification_outcome, `verified_at` Unix seconds, `recording_mbid` the
 * recording ID in effect when it was verified, and `heard` the recordings
 * AcoustID heard, strongest first, at most 8. `stale` is set when the file's
 * bytes or its recording ID changed since; `dismissed` when the strongest
 * recording heard has a dismissed proposal on the file. Everything is valid
 * only for the duration of the callback.
 */
typedef struct orca_track_verification_view {
    int64_t verified_at;
    orca_string_view recording_mbid;
    const orca_heard_recording_view *heard;
    size_t heard_count;
    uint8_t outcome;
    uint8_t stale;
    uint8_t dismissed;
    uint8_t reserved[5];
} orca_track_verification_view;

typedef void (*orca_track_verification_callback)(void *context, const orca_track_verification_view *verification);

/* Invokes the callback once with the Track's verification. NOT_FOUND,
 * without a callback, when the Track was never verified or does not exist. */
orca_status orca_library_track_verification(
    orca_runtime *runtime,
    orca_handle library,
    int64_t track_id,
    void *context,
    orca_track_verification_callback callback
);

/* A pending correction of an album group beside its file's Track as it is.
 * `track_id` (with `has_track_id`) is the lowest-numbered Track that plays
 * the file. `corrects` is the recording ID accepting replaces. */
typedef struct orca_correction_member_view {
    int64_t proposal_id;
    int64_t track_id;
    int64_t file_id;
    int64_t track_number;
    int64_t disc_number;
    orca_string_view title;
    orca_string_view proposed_title;
    orca_string_view recording_mbid;
    orca_string_view corrects;
    uint32_t proposed_track_number;
    uint32_t proposed_disc_number;
    uint8_t has_track_id;
    uint8_t has_track_number;
    uint8_t has_disc_number;
    uint8_t has_proposed_track_number;
    uint8_t has_proposed_disc_number;
    uint8_t has_corrects;
    uint8_t reserved[2];
} orca_correction_member_view;

/* Corrections a verification proposed for one Release's files, accepted or
 * dismissed only together. `release_id` is the Release of the first member's
 * Track. `members` holds at most 512 and, like every string view, is valid
 * only for the duration of the callback. */
typedef struct orca_correction_group_view {
    int64_t group_id;
    int64_t release_id;
    uint8_t has_release_id;
    uint8_t reserved[7];
    orca_string_view album;
    orca_string_view album_artist;
    const orca_correction_member_view *members;
    size_t member_count;
} orca_correction_group_view;

typedef void (*orca_correction_group_callback)(void *context, const orca_correction_group_view *group);

/* Invokes the callback for a page of pending album groups of corrections.
 * `limit` is 1 to 512, else INVALID_ARGUMENT. */
orca_status orca_library_query_correction_groups(
    orca_runtime *runtime,
    orca_handle library,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_correction_group_callback callback
);
/* Accepts every pending correction of the group in one transaction, each
 * recording ID stored locked, and reprojects the files; only the Library
 * changes. NOT_FOUND for an unknown group; INVALID_STATE for one already
 * accepted or dismissed. */
orca_status orca_library_accept_correction_group(
    orca_runtime *runtime,
    orca_handle library,
    int64_t group_id,
    orca_confident_acceptance *output
);
/* Dismisses every pending correction of the group. Statuses as
 * orca_library_accept_correction_group. */
orca_status orca_library_dismiss_correction_group(orca_runtime *runtime, orca_handle library, int64_t group_id);

/* ------------------------------------------------------ AcoustID submission */

/* Why an AcoustID submission job stopped. Every outcome but COMPLETED and
 * CANCELLED leaves the job FAILED, with nothing from the failed request
 * marked sent. NEEDS_CLIENT_KEY: no application key is set. NEEDS_USER_KEY:
 * the credential callback has none for ORCA_CREDENTIAL_SERVICE_ACOUSTID /
 * ORCA_CREDENTIAL_ACCOUNT_USER_KEY, or its answer was UNAVAILABLE or
 * TOO_LARGE. INVALID_CLIENT_KEY and INVALID_USER_KEY: AcoustID refused the
 * key. UNAVAILABLE: AcoustID did not answer after retries. BUSY: another Orca
 * process holds AcoustID. */
typedef enum orca_submission_outcome {
    ORCA_SUBMISSION_OUTCOME_COMPLETED = 0,
    ORCA_SUBMISSION_OUTCOME_CANCELLED = 1,
    ORCA_SUBMISSION_OUTCOME_NEEDS_CLIENT_KEY = 2,
    ORCA_SUBMISSION_OUTCOME_INVALID_CLIENT_KEY = 3,
    ORCA_SUBMISSION_OUTCOME_NEEDS_USER_KEY = 4,
    ORCA_SUBMISSION_OUTCOME_INVALID_USER_KEY = 5,
    ORCA_SUBMISSION_OUTCOME_UNAVAILABLE = 6,
    ORCA_SUBMISSION_OUTCOME_BUSY = 7,
} orca_submission_outcome;

/*
 * Starts sending AcoustID the fingerprints of files whose recording ID a
 * person chose, through an accepted match or an edit, and returns
 * immediately. The job's kind is ORCA_JOB_KIND_ACOUSTID_SUBMISSION, and its
 * counts are read with orca_job_submission_stats. IDs read from a file's
 * tags are never sent, and a file is sent once per ID. A file whose length is
 * far from its recording's is sent as metadata instead of the ID. It needs
 * the AcoustID application key and the user's key, which liborca reads
 * through the credential callback. It writes no file.
 *
 * While an idle-maintenance unit runs, returns OK with a job that stays
 * ORCA_JOB_WAITING until the unit has stopped. INVALID_STATE without a client
 * identity. BUSY while a matching job or another submission runs or is
 * queued.
 */
orca_status orca_library_start_acoustid_submission(
    orca_runtime *runtime,
    orca_handle library,
    orca_handle *job
);

/*
 * What an AcoustID submission job did so far. `files_examined` counts the
 * submittable files it went through, `submitted` those AcoustID accepted,
 * `sent_as_metadata` those of them sent as metadata rather than the ID,
 * `rejected` the files in batches AcoustID refused, which stay unsent, and
 * `requests` its submit requests.
 * `outcome` is an orca_submission_outcome: COMPLETED while the job runs.
 */
typedef struct orca_submission_stats {
    uint64_t files_examined;
    uint64_t submitted;
    uint64_t sent_as_metadata;
    uint64_t fingerprinted;
    uint64_t fingerprint_cache_hits;
    uint64_t fingerprint_failures;
    uint64_t rejected;
    uint64_t requests;
    uint8_t outcome;
    uint8_t reserved[7];
} orca_submission_stats;

/* All zero for a queued job or a job of another kind. STALE_HANDLE for an
 * unknown job. */
orca_status orca_job_submission_stats(
    orca_runtime *runtime,
    orca_handle job,
    orca_submission_stats *output
);

/* How many files a submission would send now, fingerprints permitting. */
orca_status orca_library_acoustid_submittable_count(orca_runtime *runtime, orca_handle library, uint64_t *count);

/* A file whose chosen recording ID has not been sent to AcoustID. Each
 * optional value has a `has_*` flag and reads 0 when absent; `path` is empty
 * without `has_path`. `recording_length_ms` is the accepted match's
 * recording length. Valid only for the duration of the callback. */
typedef struct orca_acoustid_submittable_view {
    int64_t file_id;
    int64_t track_id;
    int64_t track_number;
    int64_t disc_number;
    int64_t duration_ms;
    int64_t size_bytes;
    uint64_t recording_length_ms;
    uint32_t year;
    uint8_t has_track_number;
    uint8_t has_disc_number;
    uint8_t has_year;
    uint8_t has_duration_ms;
    uint8_t has_recording_length_ms;
    uint8_t has_path;
    uint8_t reserved[2];
    orca_string_view recording_mbid;
    orca_string_view title;
    orca_string_view artist;
    orca_string_view album;
    orca_string_view album_artist;
    orca_string_view codec;
    orca_string_view path;
} orca_acoustid_submittable_view;

typedef void (*orca_acoustid_submittable_callback)(void *context, const orca_acoustid_submittable_view *item);

/* Invokes the callback for up to `limit` submittable files with a file_id
 * above `cursor`, by file_id. Pass 0 for the first page, then the last
 * file_id seen; fewer than `limit` items is the last page. `limit` is 1 to
 * 512, else INVALID_ARGUMENT. */
orca_status orca_library_query_acoustid_submittable(
    orca_runtime *runtime,
    orca_handle library,
    int64_t cursor,
    uint32_t limit,
    void *context,
    orca_acoustid_submittable_callback callback
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

/* ----------------------------------------------------- idle maintenance */

/* Zero in a field selects its default. */
typedef struct orca_maintenance_options {
    /* The time between one unit's end and the next one's start. Default
     * 300000 (five minutes). */
    uint32_t interval_ms;
    /* 1 turns maintenance on, 0 off. */
    uint8_t enabled;
    uint8_t reserved[3];
} orca_maintenance_options;

typedef enum orca_maintenance_state {
    ORCA_MAINTENANCE_STATE_OFF = 0,
    /* Enabled; the next unit is due in `next_due_ms`. */
    ORCA_MAINTENANCE_STATE_WAITING = 1,
    ORCA_MAINTENANCE_STATE_RUNNING = 2,
    /* Enabled, but the last unit could not start or stopped for `blocked`. */
    ORCA_MAINTENANCE_STATE_BLOCKED = 3,
} orca_maintenance_state;

/* Why units do not run. CLIENT_IDENTITY_REQUIRED: no
 * orca_runtime_set_client_identity. ACOUSTID_REQUIRED: neither an AcoustID
 * application key nor a credential callback, or AcoustID refused the key.
 * PROVIDER_BUSY: a provider's backoff is recorded, or another Orca process
 * holds it. */
typedef enum orca_maintenance_block {
    ORCA_MAINTENANCE_BLOCK_CLIENT_IDENTITY_REQUIRED = 0,
    ORCA_MAINTENANCE_BLOCK_ACOUSTID_REQUIRED = 1,
    ORCA_MAINTENANCE_BLOCK_PROVIDER_BUSY = 2,
} orca_maintenance_block;

/*
 * A Library's maintenance schedule. `next_due_ms` counts from now and is set
 * only while WAITING or BLOCKED (`has_next_due_ms`). `blocked` is an
 * orca_maintenance_block when `has_blocked` is set; a WAITING schedule may
 * carry one from its last attempt. `has_last` says a unit has finished:
 * `last_state` is its orca_job_state, `last_stats` its counts as
 * orca_job_match_stats reports them, and `last_release_id` the Release it
 * verified, unset (`has_last_release_id` 0) for a unit of Tracks on no
 * Release. Unset fields are zero.
 */
typedef struct orca_maintenance_status {
    uint64_t next_due_ms;
    uint64_t units_run;
    int64_t last_release_id;
    orca_match_stats last_stats;
    uint8_t enabled;
    uint8_t state;  /* orca_maintenance_state */
    uint8_t blocked;  /* orca_maintenance_block */
    uint8_t has_blocked;
    uint8_t has_next_due_ms;
    uint8_t has_last;
    uint8_t has_last_release_id;
    uint8_t last_state;  /* orca_job_state */
} orca_maintenance_status;

/*
 * Turns idle maintenance on or off for the Library. While on,
 * orca_runtime_pump verifies the Library's recording IDs against AcoustID a
 * unit at a time, while no Player plays and no other job runs: the next
 * Release every `interval_ms`, or at most twenty Tracks on no Release once
 * none is left. Each unit is an ORCA_JOB_KIND_METADATA_LOOKUP job with origin
 * ORCA_JOB_ORIGIN_MAINTENANCE that reports ORCA_EVENT_JOB_FINISHED like any
 * job, and its findings land in Health. Enabling makes a unit due at once;
 * enabling again changes the interval and makes a unit due at once;
 * disabling cancels a running unit. `options` may be NULL, which turns
 * maintenance off. One unit runs per runtime at a time. Nothing is saved:
 * a host enables it again after opening the Library.
 *
 * INVALID_ARGUMENT for `enabled` other than 0 or 1. INVALID_STATE for a
 * Library with no database.
 */
orca_status orca_library_set_maintenance(
    orca_runtime *runtime,
    orca_handle library,
    const orca_maintenance_options *options
);
orca_status orca_library_maintenance_status(
    orca_runtime *runtime,
    orca_handle library,
    orca_maintenance_status *output
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
 * of which is not a failure of the pass. It then measures the covers left
 * unmeasured: each counts in `files_seen`, one measured or found unreadable
 * in `changed`, and one whose file is unreachable or changed in
 * `unsupported`.
 */
orca_status orca_library_start_property_backfill(
    orca_runtime *runtime,
    orca_handle library,
    const orca_backfill_options *options,
    orca_handle *job
);
/* Writes what a property backfill could repair now, checking which roots are
 * offline on the calling thread. A host starts one when either count is
 * nonzero and no scan is running. */
orca_status orca_library_backfill_pending(
    orca_runtime *runtime,
    orca_handle library,
    orca_backfill_pending *output
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
 * It compares hashes and measurements the Library stored rather than reading
 * files, through indexes - equal full-content hash and equal lossless audio
 * hash for the certain cases, and a duration window inside which temporal
 * fingerprints are compared for the probable one - so a full run over a measured library takes seconds where the
 * analysis itself takes hours.
 *
 * Findings are recorded as library health issues, readable through
 * orca_library_query_health_issues: kind 9 (EXACT_DUPLICATE) says the same
 * bytes are held twice, kind 13 (IDENTICAL_AUDIO) that different bytes hold
 * the same lossless audio, and kind 10 (LIKELY_DUPLICATE) that fingerprints
 * match. A file gets at most one, the strongest. All three kinds are
 * REWRITTEN for every file examined, so a second run converges on the same
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
 * `releases_written` carry the exact and likely finding counts, so `changed`
 * less both is the identical-audio count; `folders_visited` the buckets that
 * hit the per-candidate comparison cap, and
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
/* orca_library_scan_stats with the stage, Releases found and current file. */
orca_status orca_library_scan_stats_v2(
    orca_runtime *runtime,
    orca_handle job,
    orca_scan_stats_v2 *output
);

/*
 * Counts the audio files under `path`, a folder not yet added to any Library,
 * by each file's first bytes rather than its name, on the calling thread. It
 * stops at `limit` audio files, zero selecting 100000, and then sets
 * `truncated`: the folder holds at least that many. It reads nothing past a
 * file's header and writes nothing.
 */
orca_status orca_estimate_audio_files(
    orca_runtime *runtime,
    const char *path,
    uint32_t limit,
    orca_folder_estimate *output
);

/* Who started a job. WATCHER: a reconcile orca_library_watch started.
 * MAINTENANCE: a unit of idle maintenance (orca_library_set_maintenance). */
typedef enum orca_job_origin {
    ORCA_JOB_ORIGIN_HOST = 0,
    ORCA_JOB_ORIGIN_WATCHER = 1,
    ORCA_JOB_ORIGIN_MAINTENANCE = 2,
} orca_job_origin;

/* Writes the job's orca_job_origin. STALE_HANDLE for an unknown job, or one
 * finished so long ago that it is no longer retained. */
orca_status orca_job_origin_get(
    orca_runtime *runtime,
    orca_handle job,
    uint8_t *origin
);
/* The root a reconcile job walks, with `has_root_id` 1; `has_root_id` 0 and
 * `root_id` 0 for a job of another kind or a queued one. STALE_HANDLE as
 * orca_job_origin_get. */
orca_status orca_job_reconcile_root(
    orca_runtime *runtime,
    orca_handle job,
    int64_t *root_id,
    uint8_t *has_root_id
);

/* What orca_job_snapshot leaves out. `started_at` is Unix seconds, with
 * `has_started_at` 0 while the job waits. `estimated_remaining_ms` comes from
 * the rate over the last ten seconds of progress, so `has_estimated_
 * remaining_ms` is 0 until ten seconds of it, while paused, and for a job with
 * no total. `current_item` is the path or title being worked on and `detail`
 * a note such as "14 threads"; either may be empty. */
typedef struct orca_job_details {
    int64_t started_at;
    uint64_t estimated_remaining_ms;
    uint8_t has_started_at;
    uint8_t paused;
    uint8_t has_estimated_remaining_ms;
    uint8_t reserved[5];
    orca_string_view current_item;
    orca_string_view detail;
} orca_job_details;

typedef void (*orca_job_details_callback)(
    void *context,
    const orca_job_details *details
);

/* Calls `callback` once with the job's details. STALE_HANDLE as
 * orca_job_origin_get. */
orca_status orca_job_details_get(
    orca_runtime *runtime,
    orca_handle job,
    void *context,
    orca_job_details_callback callback
);

/* Holds a running job at its next cancellation poll, between provider
 * requests; it keeps its thread, and orca_job_cancel still stops it. A paused
 * job stays paused. INVALID_STATE for a job that is waiting, cancelling or
 * finished, or of a kind that never polls: a tag write, a projection, and the
 * one-item fetches. */
orca_status orca_job_pause(orca_runtime *runtime, orca_handle job);
/* A running job stays running. Resuming one job of a paused Library leaves
 * the rest held. INVALID_STATE as orca_job_pause. */
orca_status orca_job_resume(orca_runtime *runtime, orca_handle job);

/* Pauses every pausable job of the Library, whoever started it, and holds its
 * waiting jobs, watcher reconciles and maintenance until
 * orca_library_resume_jobs. A job started while paused waits. */
orca_status orca_library_pause_jobs(orca_runtime *runtime, orca_handle library);
orca_status orca_library_resume_jobs(orca_runtime *runtime, orca_handle library);
orca_status orca_library_jobs_paused(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t *paused
);

/* One Library runs one scan, reconcile, backfill, analysis, duplicate scan,
 * tag write, match, cover fetch, submission or genre fill at a time. A host job
 * of those kinds started while the slot is held is created ORCA_JOB_WAITING
 * and starts in order on a later orca_runtime_pump. At most
 * ORCA_MAX_WAITING_JOBS wait across the runtime; one more is BUSY. */
#define ORCA_MAX_WAITING_JOBS 32

/* `after` is the job this one starts behind, with `has_after` 0 for the job
 * holding the slot. */
typedef struct orca_queued_job_view {
    orca_handle job;
    orca_handle after;
    uint8_t kind;  /* orca_job_kind */
    uint8_t has_after;
    uint8_t reserved[6];
} orca_queued_job_view;

typedef void (*orca_queued_job_callback)(
    void *context,
    const orca_queued_job_view *job
);

/* The job holding the Library's slot, then the jobs waiting for it in the
 * order they start. */
orca_status orca_library_query_job_queue(
    orca_runtime *runtime,
    orca_handle library,
    void *context,
    orca_queued_job_callback callback
);

typedef enum orca_job_history_filter {
    ORCA_JOB_HISTORY_ALL = 0,
    /* Scans, reconciles, projections and backfills. */
    ORCA_JOB_HISTORY_SCANS = 1,
    /* Analyses and duplicate scans. */
    ORCA_JOB_HISTORY_ANALYSIS = 2,
    /* Tag writes. */
    ORCA_JOB_HISTORY_FILE_CHANGES = 3,
    /* Failed and cancelled jobs. */
    ORCA_JOB_HISTORY_PROBLEMS = 4,
} orca_job_history_filter;

/* A finished host job of the kinds the queue holds, as its Library recorded
 * it. Times are Unix seconds. `error_text` is empty when it succeeded;
 * `summary` reads as "2,847 files · 3 changed". `undo_group_id` is the group
 * orca_library_undo_tag_write takes, for a tag write that succeeded.
 * `retryable` 1: orca_library_retry_job starts it again. */
typedef struct orca_job_history_view {
    int64_t id;
    int64_t started_at;
    int64_t finished_at;
    uint64_t completed_units;
    uint64_t total_units;
    uint64_t undo_group_id;
    uint8_t kind;   /* orca_job_kind */
    uint8_t state;  /* orca_job_state */
    uint8_t has_total;
    uint8_t has_undo_group_id;
    uint8_t retryable;
    uint8_t reserved[3];
    orca_string_view error_text;
    orca_string_view summary;
} orca_job_history_view;

typedef void (*orca_job_history_callback)(
    void *context,
    const orca_job_history_view *entry
);

/* Newest first; the newest thousand are kept. INVALID_ARGUMENT for an unknown
 * `filter` or a `limit` outside 1...512. */
orca_status orca_library_query_job_history(
    orca_runtime *runtime,
    orca_handle library,
    uint8_t filter,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_job_history_callback callback
);

/* Starts the recorded job's request again, as its start function would, and
 * writes the new job. NOT_FOUND for an unknown `history_id`; INVALID_STATE for
 * an entry whose `retryable` is 0. */
orca_status orca_library_retry_job(
    orca_runtime *runtime,
    orca_handle library,
    int64_t history_id,
    orca_handle *job
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
/* Replaces the queue with every Track whose preferred file lies below the
 * folder `path` (relative to root `root_id`, empty for the root), each once,
 * in path order, at most 10000, from the Library the Player is bound to, and
 * sets shuffle to `shuffle` (0 or 1) before starting at the first. Synchronous,
 * like orca_player_play_tracks. INVALID_STATE for a Player with no Library and
 * for a folder with no Track, which leaves the queue as it was; NOT_FOUND for
 * an unknown root; INVALID_ARGUMENT for a path with an empty, `.` or `..`
 * component, a leading `/` or a NUL. */
orca_status orca_player_play_folder(
    orca_runtime *runtime,
    orca_handle player,
    int64_t root_id,
    const char *path,
    size_t path_length,
    uint8_t shuffle
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
     * holds a measurement that still describes the file. */
    ORCA_REPLAY_GAIN_TRACK = 1,
    /* Each entry is corrected by its Release's loudness, so the levels within
     * an album stay as mastered. The album figure is worked out when the entry
     * is opened, from the measurements of every Track of the Release: their
     * integrated loudness averaged in energy, weighted by duration, with the
     * loudest Track's sample peak as the album peak. An entry whose Release
     * has an unmeasured Track, a Track with no duration or more than 512
     * Tracks, or that has no Release, falls back to its own track correction,
     * and the signal path reports ORCA_GAIN_SOURCE_TRACK_FALLBACK. */
    ORCA_REPLAY_GAIN_ALBUM = 2,
    /* ALBUM while the entry before or after it in playback order is filed
     * under the same Release, TRACK otherwise: an album played through keeps
     * its levels, a shuffled mix is evened out per track. Decided per entry
     * as it opens and again whenever the queue is reordered or shuffled. */
    ORCA_REPLAY_GAIN_SMART = 3,
} orca_replay_gain_mode;

/* What an entry with no usable measurement plays at while correction is on. */
typedef enum orca_untagged_fallback {
    ORCA_UNTAGGED_MINUS_6_DB = 0,
    ORCA_UNTAGGED_AS_IS = 1,
} orca_untagged_fallback;

/* Every ReplayGain choice of a Player. */
typedef struct orca_replay_gain_settings {
    /* Added to every measured correction before peak protection. */
    float preamp_db;
    uint8_t mode;             /* orca_replay_gain_mode */
    uint8_t fallback;         /* orca_untagged_fallback */
    uint8_t peak_protection;  /* 1 caps each correction at 1 / peak */
    uint8_t reserved[1];
} orca_replay_gain_settings;

/* Which correction orca_signal_path_view.replay_gain_db is. */
typedef enum orca_gain_source {
    /* No measured correction applies: ReplayGain is off, or the entry is
     * unmeasured and plays at the untagged fallback. */
    ORCA_GAIN_SOURCE_NONE = 0,
    /* The entry's own, under ORCA_REPLAY_GAIN_TRACK. */
    ORCA_GAIN_SOURCE_TRACK = 1,
    /* The entry's Release's, under ORCA_REPLAY_GAIN_ALBUM or SMART. */
    ORCA_GAIN_SOURCE_ALBUM = 2,
    /* The entry's own, under ORCA_REPLAY_GAIN_ALBUM or SMART, because its
     * Release has no album figure. */
    ORCA_GAIN_SOURCE_TRACK_FALLBACK = 3,
} orca_gain_source;

/* Takes effect as soon as the audio already decoded ahead of the listener
 * drains -- a fraction of a second, not the rest of the track, in every
 * mode, as do the preamp, fallback and peak protection below. The level steps rather than ramping when it does, which is the answer
 * to an explicit request. Defaults to TRACK. */
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
/* Clamped to -15..15 dB; NaN is 0. Not applied to the untagged fallback.
 * Defaults to 0. */
orca_status orca_player_set_replay_gain_preamp(
    orca_runtime *runtime,
    orca_handle player,
    float decibels
);
/* An orca_untagged_fallback value. Defaults to ORCA_UNTAGGED_AS_IS. */
orca_status orca_player_set_replay_gain_fallback(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t fallback
);
/* 1 caps every correction at 1 / the measured peak, so a boost never drives
 * the entry past full scale; 0 lets the boost through. Defaults to 1. */
orca_status orca_player_set_peak_protection(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t enabled
);
orca_status orca_player_replay_gain_settings(
    orca_runtime *runtime,
    orca_handle player,
    orca_replay_gain_settings *output
);
/* 1 stops the transport when the entry being heard ends, then reads 0 again;
 * the following entry is not started until the next play. Arming it after
 * the engine has begun decoding the following entry re-opens the audible one
 * at the heard position, with a short gap. */
orca_status orca_player_set_stop_after_current(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t enabled
);
orca_status orca_player_stop_after_current(
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
 * 0 is on but transparent: it is not sample processing. Turning it on turns
 * the parametric equalizer off. The engine is paused while the setting is
 * written, and applies it from its next pass. */
orca_status orca_player_set_equalizer(
    orca_runtime *runtime,
    orca_handle player,
    const orca_equalizer *equalizer
);
/* `enabled` receives 1 and `output` the setting while the equalizer is on;
 * `enabled` 0 leaves `output` zeroed. It is 0 while the parametric equalizer
 * is on. */
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

/*
 * The Player's parametric equalizer: up to ORCA_PARAMETRIC_MAX_FILTERS
 * biquads applied in order after a preamp, in the place of the ten-band
 * equalizer. A Player runs one or the other: turning either on turns the
 * other off. A filter at or above 0.45 of the playing audio's sample rate is
 * left out, as the ten-band equalizer leaves out bands at or above Nyquist.
 */
#define ORCA_PARAMETRIC_MAX_FILTERS 16
/* Each filter's frequency lies in [ORCA_PARAMETRIC_MIN_FREQUENCY_HZ,
 * ORCA_PARAMETRIC_MAX_FREQUENCY_HZ] Hz. */
#define ORCA_PARAMETRIC_MIN_FREQUENCY_HZ 20
#define ORCA_PARAMETRIC_MAX_FREQUENCY_HZ 20000
/* A peak's or shelf's gain lies in [-ORCA_PARAMETRIC_MAX_GAIN_DB,
 * ORCA_PARAMETRIC_MAX_GAIN_DB] dB; the other kinds ignore it, though it is
 * still checked. */
#define ORCA_PARAMETRIC_MAX_GAIN_DB 24
/* Q lies in [ORCA_PARAMETRIC_MIN_Q, ORCA_PARAMETRIC_MAX_Q], and a shelf's in
 * [ORCA_PARAMETRIC_MIN_SHELF_Q, ORCA_PARAMETRIC_MAX_SHELF_Q]. */
#define ORCA_PARAMETRIC_MIN_Q 0.1f
#define ORCA_PARAMETRIC_MAX_Q 20.0f
#define ORCA_PARAMETRIC_MIN_SHELF_Q 0.3f
#define ORCA_PARAMETRIC_MAX_SHELF_Q 2.0f
/* The preamp lies in [ORCA_PARAMETRIC_MIN_PREAMP_DB,
 * ORCA_PARAMETRIC_MAX_PREAMP_DB] dB. */
#define ORCA_PARAMETRIC_MIN_PREAMP_DB (-24)
#define ORCA_PARAMETRIC_MAX_PREAMP_DB 6

typedef enum orca_parametric_filter_kind {
    ORCA_PARAMETRIC_FILTER_PEAK = 0,
    /* Shelves take Q, not slope: Q 0.707 is the plain shelf. */
    ORCA_PARAMETRIC_FILTER_LOW_SHELF = 1,
    ORCA_PARAMETRIC_FILTER_HIGH_SHELF = 2,
    ORCA_PARAMETRIC_FILTER_LOW_PASS = 3,
    ORCA_PARAMETRIC_FILTER_HIGH_PASS = 4,
    ORCA_PARAMETRIC_FILTER_NOTCH = 5,
} orca_parametric_filter_kind;

typedef struct orca_parametric_filter {
    uint8_t kind;  /* orca_parametric_filter_kind */
    /* 0 keeps the filter in the list without applying it. */
    uint8_t enabled;
    uint8_t reserved[2];
    float frequency_hz;
    float gain_db;
    float q;
} orca_parametric_filter;

typedef struct orca_parametric_equalizer {
    /* The first `count` entries apply, in order; the rest are ignored. */
    orca_parametric_filter filters[ORCA_PARAMETRIC_MAX_FILTERS];
    uint8_t count;
    uint8_t reserved[3];
    /* dB applied before the filters, to leave headroom for a boost. */
    float preamp_db;
} orca_parametric_equalizer;

/* Turns the parametric equalizer on with `equalizer`, turning the ten-band
 * equalizer off, or turns it off with NULL. INVALID_ARGUMENT, with the
 * previous setting kept, for an unknown kind, a count above
 * ORCA_PARAMETRIC_MAX_FILTERS, or a value outside its range or not a finite
 * number. One that changes nothing, a zero preamp and every enabled filter a
 * peak or shelf at 0 dB, is on but is not sample processing. The engine is
 * paused while the setting is written, and applies it from its next pass. */
orca_status orca_player_set_parametric_equalizer(
    orca_runtime *runtime,
    orca_handle player,
    const orca_parametric_equalizer *equalizer
);
/* `has` receives 1 and `output` the setting while the parametric equalizer
 * is on; `has` 0 leaves `output` zeroed. */
orca_status orca_player_parametric_equalizer_get(
    orca_runtime *runtime,
    orca_handle player,
    orca_parametric_equalizer *output,
    uint8_t *has
);

/* Writes to `gains_db[i]` the gain in dB, preamp included, that `equalizer`
 * applies at `frequencies_hz[i]` when the audio runs at `sample_rate`, for
 * the `count` entries of each array. Filters at or above 0.45 of
 * `sample_rate` and disabled filters are left out, as on a Player. The
 * equalizer is checked as on orca_player_set_parametric_equalizer, and a
 * `sample_rate` of 0 is INVALID_ARGUMENT. Pure: it takes no runtime, is
 * callable from any thread, and so leaves no last error. */
orca_status orca_parametric_equalizer_response(
    const orca_parametric_equalizer *equalizer,
    uint32_t sample_rate,
    const float *frequencies_hz,
    float *gains_db,
    size_t count
);

/* Reads EqualizerAPO text (`length` bytes, UTF-8, LF or CRLF) into `output`:
 * `Preamp: N dB` lines, which add up, and `Filter N: ON|OFF TYPE Fc N Hz
 * [Gain N dB] [Q N | BW Oct N]` lines, where TYPE is PK, PEQ, LS, LSC, HS,
 * HSC, LP, HP or NO. A missing Q is 0.707; a bandwidth in octaves converts to
 * Q. Blank lines and lines starting with `#` are skipped. UNSUPPORTED for a
 * filter type Orca does not run; INVALID_ARGUMENT for any other line, more
 * than ORCA_PARAMETRIC_MAX_FILTERS filters, or a value outside its range.
 * `output` is untouched on failure. Pure, as orca_parametric_equalizer_response. */
orca_status orca_parametric_equalizer_parse_apo(
    const char *text,
    size_t length,
    orca_parametric_equalizer *output
);

/* Writes `equalizer` as EqualizerAPO text that orca_parametric_equalizer_parse_apo
 * reads back to the same filters: a `Preamp:` line, then one `Filter` line per
 * filter with the shelves as LSC and HSC. `written` receives the text's length
 * in bytes; there is no terminating NUL. When it exceeds `capacity`, nothing
 * is written and the result is INVALID_ARGUMENT, so a call with `capacity` 0
 * learns the length. The equalizer is checked as on
 * orca_player_set_parametric_equalizer. Pure, as
 * orca_parametric_equalizer_response. */
orca_status orca_parametric_equalizer_write_apo(
    const orca_parametric_equalizer *equalizer,
    char *buffer,
    size_t capacity,
    size_t *written
);

typedef enum orca_sample_format {
    ORCA_SAMPLE_FORMAT_UNSIGNED_8 = 0,
    ORCA_SAMPLE_FORMAT_SIGNED_16 = 1,
    ORCA_SAMPLE_FORMAT_SIGNED_24 = 2,
    ORCA_SAMPLE_FORMAT_SIGNED_32 = 3,
    ORCA_SAMPLE_FORMAT_FLOAT_32 = 4,
    ORCA_SAMPLE_FORMAT_FLOAT_64 = 5,
    ORCA_SAMPLE_FORMAT_SIGNED_8 = 6,
} orca_sample_format;

typedef struct orca_pcm_format {
    uint32_t sample_rate;
    uint16_t channels;
    uint16_t bits_per_sample;
    uint16_t bytes_per_frame;
    uint8_t sample_format;  /* orca_sample_format */
    uint8_t reserved[1];
} orca_pcm_format;

/* The sample format an output device node runs at. UNKNOWN when the node is
 * suspended, virtual, has not reported it yet, or the backend is not
 * PipeWire; orca_device_format's other fields are then 0. */
typedef enum orca_device_sample_format {
    ORCA_DEVICE_SAMPLE_FORMAT_UNKNOWN = 0,
    ORCA_DEVICE_SAMPLE_FORMAT_SIGNED_16 = 1,
    ORCA_DEVICE_SAMPLE_FORMAT_SIGNED_24 = 2,
    ORCA_DEVICE_SAMPLE_FORMAT_SIGNED_24_32 = 3,
    ORCA_DEVICE_SAMPLE_FORMAT_SIGNED_32 = 4,
    ORCA_DEVICE_SAMPLE_FORMAT_FLOAT_32 = 5,
} orca_device_sample_format;

typedef struct orca_device_format {
    uint32_t sample_rate;
    uint16_t channels;
    uint8_t bits_per_sample;
    uint8_t sample_format;  /* orca_device_sample_format */
} orca_device_format;

/* Why a signal path is not bit-perfect. */
typedef enum orca_signal_reason {
    /* Either equalizer, crossfeed, a volume other than 1 or a ReplayGain
     * correction changes the samples, or audio one of them changed is still
     * queued for the output after the setting was turned off. */
    ORCA_SIGNAL_REASON_SAMPLE_PROCESSING = 0,
    /* The output, or the device behind it, runs at another rate. */
    ORCA_SIGNAL_REASON_SAMPLE_RATE_CONVERSION = 1,
    /* The output, or the device behind it, has another channel count than
     * the source. */
    ORCA_SIGNAL_REASON_CHANNEL_LAYOUT_CONVERSION = 2,
    /* The output's sample format differs from the source's, other than an
     * exact widening of 8-, 16- or 24-bit integers to float32, or the
     * device's format cannot hold every source value: fewer bits than an
     * integer source, or an integer format for a float or 32-bit source. */
    ORCA_SIGNAL_REASON_SAMPLE_FORMAT_CONVERSION = 3,
    /* The source's codec discarded audio before Orca decoded it. */
    ORCA_SIGNAL_REASON_LOSSY_SOURCE = 4,
    /* The path cannot be confirmed: nothing is audible, the source declares
     * no sample format, no output is open, or the device has not reported
     * its rate or its format. */
    ORCA_SIGNAL_REASON_PATH_UNKNOWN = 5,
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
    /* The correction applied to the audible entry in dB, after peak
     * protection; `replay_gain_source` says which one it is. Valid when
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
    /* 1 only when no reason applies, which needs a declared source format,
     * an open output, and a device that reported its rate and its format;
     * without any of those ORCA_SIGNAL_REASON_PATH_UNKNOWN applies. */
    uint8_t bit_perfect_eligible;
    /* The integer source reaches float32 unchanged, which is not a reason. */
    uint8_t widened_exactly;
    /* An orca_device_kind value for the open output's device. Unknown while
     * no output is open, when the platform does not say, and for device 0,
     * the server's default, which names no device. */
    uint8_t output_kind;
    uint8_t has_device_quantum;
    /* An orca_gain_source value. */
    uint8_t replay_gain_source;
    /* Frames the output device asks for per period, as the backend last
     * reported it. Valid when `has_device_quantum`. */
    uint32_t device_quantum_frames;
    /* Canonical codec identifier of the source, such as "flac"; empty when
     * nothing is audible. */
    orca_string_view codec;
} orca_signal_path_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_signal_path_callback)(
    void *context,
    const orca_signal_path_view *signal_path
);

/* orca_signal_path_view with the parametric equalizer, the ReplayGain
 * settings and the device's own format. */
typedef struct orca_signal_path_view_v2 {
    orca_signal_path_view base;
    /* Valid when `has_parametric`, which is 0 whenever `base.has_equalizer`
     * is 1. */
    orca_parametric_equalizer parametric;
    uint8_t has_parametric;
    uint8_t has_replay_gain_track;
    uint8_t reserved[2];
    /* The entry's own track correction in dB, which an album correction
     * replaced. Valid when `has_replay_gain_track`, which is 1 only when
     * `base.replay_gain_source` is ORCA_GAIN_SOURCE_ALBUM and the entry is
     * measured. */
    float replay_gain_track_db;
    /* The ReplayGain settings the correction was worked out with. */
    float preamp_db;
    uint8_t peak_protection;
    uint8_t fallback;  /* orca_untagged_fallback */
    /* 1 when peak protection lowered the audible entry's correction. */
    uint8_t peak_limited;
    uint8_t reserved2[1];
    /* The format the output device itself runs at, after the server converts
     * the float32 stream; all zero while unknown. A rate other than
     * base.output.sample_rate, another channel count, or a format that cannot
     * hold every source value is a further conversion; an unknown format
     * makes the path unknown. */
    orca_device_format device_format;
} orca_signal_path_view_v2;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_signal_path_v2_callback)(
    void *context,
    const orca_signal_path_view_v2 *signal_path
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
/* orca_player_signal_path with orca_signal_path_view_v2. */
orca_status orca_player_signal_path_v2(
    orca_runtime *runtime,
    orca_handle player,
    void *context,
    orca_signal_path_v2_callback callback
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
orca_status orca_player_status_get_v2(
    orca_runtime *runtime,
    orca_handle player,
    orca_player_status_v2 *output
);
orca_status orca_player_status_get_v3(
    orca_runtime *runtime,
    orca_handle player,
    orca_player_status_v3 *output
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
 * between 1 and 512. The view of call `n` is queue position `offset + n`; an
 * entry whose Track was removed from the Library has `removed` set and only
 * its `id`. ORCA_STATUS_INVALID_STATE when the Player has no Library.
 * Strings are valid only for the callback. */
orca_status orca_player_query_queue_tracks(
    orca_runtime *runtime,
    orca_handle player,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_track_callback callback
);
/* The last 100 entries this Player stopped playing, newest first, starting
 * `offset` entries back. `limit` must be between 1 and 512. Stop leaves no
 * entry, since the entry stays current. The history is held in memory only,
 * so a new runtime starts with none, and it never records a listen. An entry
 * whose Library is closed or whose Track has left it is skipped. */
orca_status orca_player_query_queue_history(
    orca_runtime *runtime,
    orca_handle player,
    uint32_t limit,
    uint32_t offset,
    void *context,
    orca_queue_history_callback callback
);
orca_status orca_player_clear_queue_history(orca_runtime *runtime, orca_handle player);
/* Creates a playlist named as for orca_library_create_playlist, holding the
 * current entry and every entry after it in playback order, in the Library
 * the Player is bound to. ORCA_STATUS_INVALID_STATE when the Player has no
 * Library, the queue has no current entry, or the name is taken. */
orca_status orca_player_save_queue_as_playlist(
    orca_runtime *runtime,
    orca_handle player,
    const char *name,
    size_t name_length,
    int64_t *playlist_id
);
/* Saves the queue, its position, repeat and shuffle into the Library the
 * Player is bound to; entries from other Libraries are left out. From then on
 * the runtime saves it again every 30 seconds while it plays (from
 * orca_runtime_pump), when the Player is destroyed, bound to another
 * Library or its Library is closed, and in orca_runtime_destroy before any
 * Player is torn down.
 * ORCA_STATUS_INVALID_STATE when the Player has no Library. */
orca_status orca_player_save_state(orca_runtime *runtime, orca_handle player);
/* Replaces the queue with the one last saved into the Player's Library and
 * loads its current entry at the saved position, then pauses or plays it as
 * `mode` (orca_restore_mode) says. A saved entry whose Track is gone resolves
 * to another Track of its Recording, or is skipped and counted. Every field
 * of `outcome` is 0 when nothing was saved or with ORCA_RESTORE_MODE_NONE.
 * Any mode makes the runtime save this Player's state from then on, as
 * orca_player_save_state does. `outcome` may be NULL. */
orca_status orca_player_restore_state(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t mode,
    orca_restore_outcome *outcome
);
/* With `enabled`, Tracks longer than `threshold_ms` resume where they were
 * last left and forget it once they play to their end; with `enabled` 0 none
 * do. On, at 20 minutes, until set. */
orca_status orca_player_set_long_track_memory(
    orca_runtime *runtime,
    orca_handle player,
    uint8_t enabled,
    uint64_t threshold_ms
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
/* Moves the entry at playback position `from` so that it plays at position
 * `to`, both in playback order. Under shuffle only the shuffled order
 * changes: turning shuffle off afterwards restores list order. `from` equal
 * to `to` does nothing.
 * ORCA_STATUS_INVALID_STATE for the entries orca_player_queue_remove refuses,
 * and for a `to` between the entry playing and the one the engine has
 * already lined up after it.
 * ORCA_STATUS_INVALID_ARGUMENT when either position is not below the queue
 * length. */
orca_status orca_player_queue_move(
    orca_runtime *runtime,
    orca_handle player,
    uint32_t from,
    uint32_t to
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
/* orca_enumerate_output_devices with each device's kind. */
orca_status orca_enumerate_output_devices_v2(
    orca_runtime *runtime,
    void *context,
    orca_device_v2_callback callback
);
/* orca_enumerate_output_devices_v2 with each device's capabilities and state. */
orca_status orca_enumerate_output_devices_v3(
    orca_runtime *runtime,
    void *context,
    orca_device_v3_callback callback
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
