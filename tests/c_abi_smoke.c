/*
 * The C ABI driven the way a frontend drives it: open a library, register a
 * root, scan it as a background job, wait for the job, query the projected
 * tracks, open a default output, play a track, watch the transport move, and
 * shut down cleanly.
 *
 * This test exists to prove the boundary WORKS, not that it compiles. It runs
 * from the repository root and scans `fixtures/audio`, which holds short
 * (~0.2 s) reference files, so it neither needs a temp corpus nor renders for
 * minutes. It tolerates a machine with no audio server: everything up to and
 * including play/pause/seek/next is asserted unconditionally, and only the
 * "position actually advanced" claim is conditional on an output reaching
 * ORCA_OUTPUT_ACTIVE.
 */

/* pipe, poll and clock_gettime under -std=c11 */
#define _POSIX_C_SOURCE 200809L

#include "orca.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define SMOKE_FAIL()                                                              \
    do {                                                                          \
        fprintf(stderr, "c-abi-smoke: check failed at %s:%d\n", __FILE__, __LINE__); \
        return 1;                                                                 \
    } while (0)
#define SMOKE_CHECK(condition)        \
    do {                              \
        if (!(condition)) SMOKE_FAIL(); \
    } while (0)

/* Which output this test opens.
 *
 * Device 0 is the server default, which on a developer's machine is their
 * actual speakers, and a test run must never be audible.
 *
 * Selection order:
 *   1. ORCA_TEST_DEVICE, if set, names an orca device id explicitly.
 *   2. Otherwise argv[1] names a file holding the device id that
 *      scripts/silent-sink.sh printed; `zig build test` passes it.
 *   3. Otherwise, on Linux, the test fails rather than open the default
 *      output.
 *   4. Otherwise device 0: liborca has no output backend there.
 *
 * A null sink is a real PipeWire sink, so this weakens nothing: quantum
 * negotiation, render callbacks and underrun accounting all still run. */
static int read_device_id_file(const char *path, uint64_t *device_id) {
    char text[32];
    FILE *file = fopen(path, "r");
    if (file == 0) {
        fprintf(stderr, "c-abi-smoke: cannot open device id file %s: %s\n", path,
                strerror(errno));
        return -1;
    }
    size_t length = fread(text, 1, sizeof text - 1, file);
    fclose(file);
    text[length] = 0;

    char *cursor = text;
    while (isspace((unsigned char)*cursor)) cursor += 1;
    char *end = cursor;
    errno = 0;
    unsigned long long parsed = strtoull(cursor, &end, 10);
    int digits_read = end != cursor && isdigit((unsigned char)*cursor);
    while (isspace((unsigned char)*end)) end += 1;
    if (!digits_read || errno != 0 || *end != 0) {
        fprintf(stderr,
                "c-abi-smoke: device id file %s holds \"%s\", expected one decimal "
                "device id as printed by scripts/silent-sink.sh\n",
                path, text);
        return -1;
    }
    *device_id = (uint64_t)parsed;
    return 0;
}

static int test_device_id(int argc, char **argv, uint64_t *device_id) {
    const char *configured = getenv("ORCA_TEST_DEVICE");
    if (configured != 0 && configured[0] != 0) {
        *device_id = (uint64_t)strtoull(configured, 0, 10);
        return 0;
    }
    if (argc > 1) return read_device_id_file(argv[1], device_id);
#ifdef __linux__
    fprintf(stderr,
            "c-abi-smoke: no silent output given; refusing to open the default output, "
            "which is audible. Pass the file holding scripts/silent-sink.sh's device id "
            "as the first argument, set ORCA_TEST_DEVICE, or run under "
            "scripts/headless-audio.sh zig build test\n");
    return -1;
#else
    *device_id = 0;
    return 0;
#endif
}

/* The host's loop sleeps on a self-pipe, as a GUI main loop sleeps on an
 * eventfd, and the wake callback writes one byte to it. */
static int wake_pipe[2] = {-1, -1};
static atomic_uint wake_calls;
static atomic_int runtime_destroyed;

static void on_wake(void *context) {
    (void)context;
    if (atomic_load(&runtime_destroyed)) abort();
    atomic_fetch_add(&wake_calls, 1);
    const char byte = 1;
    if (write(wake_pipe[1], &byte, 1) < 0 && errno != EAGAIN) abort();
}

static int open_wake_pipe(void) {
    if (pipe(wake_pipe) != 0) return -1;
    for (int end = 0; end < 2; end += 1) {
        int flags = fcntl(wake_pipe[end], F_GETFL);
        if (flags < 0 || fcntl(wake_pipe[end], F_SETFL, flags | O_NONBLOCK) != 0) return -1;
    }
    return 0;
}

static void drain_wake_pipe(void) {
    char bytes[64];
    while (read(wake_pipe[0], bytes, sizeof bytes) > 0) {
    }
}

static long now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/* One turn of a host's loop: sleep until the wake callback fires or the pump
 * timeout passes, but not past `deadline`, then pump. Returns 1 when told to
 * wait for the callback alone and none came before `deadline`, 0 when it
 * pumped otherwise, -1 when a call failed. */
static int wait_for_runtime(orca_runtime *runtime, long deadline) {
    int64_t timeout = 0;
    if (orca_runtime_pump_timeout(runtime, &timeout) != ORCA_STATUS_OK) return -1;
    long remaining = deadline - now_ms();
    if (remaining < 0) remaining = 0;
    long wait = remaining;
    if (timeout != ORCA_PUMP_NO_TIMEOUT && timeout < remaining) wait = (long)timeout;
    struct pollfd wake;
    wake.fd = wake_pipe[0];
    wake.events = POLLIN;
    wake.revents = 0;
    int ready = poll(&wake, 1, (int)wait);
    if (ready < 0 && errno != EINTR) return -1;
    drain_wake_pipe();
    if (orca_runtime_pump(runtime) != ORCA_STATUS_OK) return -1;
    return ready == 0 && timeout == ORCA_PUMP_NO_TIMEOUT ? 1 : 0;
}

static int drain_events(orca_runtime *runtime) {
    for (;;) {
        orca_event event;
        if (orca_runtime_poll_event(runtime, &event, 0) != ORCA_STATUS_OK) return -1;
        if (event.kind == ORCA_EVENT_NONE) return 0;
    }
}

struct track_capture {
    uint32_t count;
    int64_t first_playable_id;
    uint32_t with_duration;
    uint32_t with_artist;
    uint32_t with_feedback;
    uint32_t with_rating;
};

static void capture_track(void *context, const orca_track_view *track) {
    struct track_capture *capture = context;
    capture->count += 1;
    if (track->feedback != ORCA_FEEDBACK_NONE) capture->with_feedback += 1;
    if (track->has_rating) capture->with_rating += 1;
    if (track->has_duration && track->duration_ms > 0) capture->with_duration += 1;
    if (track->artist.length != 0) capture->with_artist += 1;
    if (track->has_file && capture->first_playable_id == 0)
        capture->first_playable_id = track->id;
}

struct artist_capture {
    uint32_t count;
    int64_t first_id;
    uint32_t with_name;
    uint32_t with_tracks;
    int sorted;
    char previous[256];
};

static void capture_artist(void *context, const orca_artist_view *artist) {
    struct artist_capture *capture = context;
    char current[256];
    size_t length = artist->sort_name.length;
    if (length >= sizeof current) length = sizeof current - 1;
    memcpy(current, artist->sort_name.pointer, length);
    current[length] = 0;
    if (capture->count != 0 && strcmp(capture->previous, current) > 0) capture->sorted = 0;
    memcpy(capture->previous, current, length + 1);

    capture->count += 1;
    if (artist->name.length != 0) capture->with_name += 1;
    if (artist->track_count != 0) capture->with_tracks += 1;
    if (capture->first_id == 0 && artist->track_count != 0) capture->first_id = artist->id;
}

struct release_capture {
    uint32_t count;
    int64_t first_id;
    uint32_t with_tracks;
    int64_t longest_ms;
};

static void capture_release(void *context, const orca_release_view *release) {
    struct release_capture *capture = context;
    capture->count += 1;
    if (release->track_count != 0) capture->with_tracks += 1;
    if (release->total_duration_ms > capture->longest_ms)
        capture->longest_ms = release->total_duration_ms;
    if (capture->first_id == 0 && release->track_count != 0) capture->first_id = release->id;
}

struct artist_name {
    uint32_t count;
    char name[256];
};

static void capture_artist_name(void *context, const orca_artist_view *artist) {
    struct artist_name *capture = context;
    if (capture->count == 0 && artist->name.length < sizeof capture->name) {
        memcpy(capture->name, artist->name.pointer, artist->name.length);
        capture->name[artist->name.length] = 0;
    }
    capture->count += 1;
}

struct summary_capture {
    uint32_t count;
    int64_t track_id;
    uint8_t has_release_id;
};

static void capture_summary(void *context, const orca_track_summary_view *summary) {
    struct summary_capture *capture = context;
    capture->count += 1;
    capture->track_id = summary->track.id;
    capture->has_release_id = summary->has_release_id;
}

struct details_capture {
    uint32_t count;
    int is_flac;
    uint8_t has_sample_rate;
    uint8_t file_missing;
};

static void capture_details(void *context, const orca_track_details_view *details) {
    struct details_capture *capture = context;
    capture->count += 1;
    capture->is_flac =
        details->codec.length == 4 && memcmp(details->codec.pointer, "flac", 4) == 0;
    capture->has_sample_rate = details->has_sample_rate && details->sample_rate > 0;
    capture->file_missing = details->file_missing;
}

struct facts_capture {
    uint32_t count;
    uint32_t with_facts;
    uint32_t played;
    uint32_t explicit_count;
    int64_t explicit_id;
    uint32_t lossless;
    uint32_t lossy;
    uint32_t with_rate;
};

static int codec_is(orca_string_view codec, const char *name) {
    return codec.length == strlen(name) && memcmp(codec.pointer, name, codec.length) == 0;
}

static void capture_facts(void *context, const orca_track_summary_view *summary,
                          const orca_track_facts_view *facts) {
    struct facts_capture *capture = context;
    capture->count += 1;
    if (codec_is(facts->codec, "flac") || codec_is(facts->codec, "alac") ||
        codec_is(facts->codec, "pcm") || codec_is(facts->codec, "pcm_float"))
        capture->lossless += 1;
    else if (facts->codec.length > 0)
        capture->lossy += 1;
    if (facts->sample_rate > 0) capture->with_rate += 1;
    if (facts->codec.length > 0 && facts->sample_rate > 0 && facts->has_added_at &&
        facts->has_track_total && facts->track_total > 0 && facts->has_disc_total)
        capture->with_facts += 1;
    if (facts->play_count != 0 || facts->has_last_played_at) capture->played += 1;
    if (facts->explicit == ORCA_EXPLICIT_EXPLICIT) {
        capture->explicit_count += 1;
        capture->explicit_id = summary->track.id;
    }
}

struct extra_capture {
    uint32_t count;
    uint8_t explicit;
    uint8_t has_track_total;
    uint8_t has_added_at;
    uint8_t has_modified_at;
};

static void capture_extra(void *context, const orca_track_details_view *details,
                          const orca_track_details_extra_view *extra) {
    (void)details;
    struct extra_capture *capture = context;
    capture->count += 1;
    capture->explicit = extra->explicit;
    capture->has_track_total = extra->has_track_total;
    capture->has_added_at = extra->has_added_at;
    capture->has_modified_at = extra->has_modified_at;
}

/* Records the disc/track pair of every row, in arrival order, so the album
 * order the repository promises can be checked rather than assumed. */
struct order_capture {
    uint32_t count;
    int ordered;
    int64_t previous_disc;
    int64_t previous_number;
    int64_t ids[64];
};

static void capture_order(void *context, const orca_track_view *track) {
    struct order_capture *capture = context;
    int64_t disc = track->has_disc_number ? track->disc_number : 1;
    int64_t number = track->has_track_number ? track->track_number : 2147483647;
    if (capture->count != 0) {
        if (disc < capture->previous_disc) capture->ordered = 0;
        if (disc == capture->previous_disc && number < capture->previous_number)
            capture->ordered = 0;
    }
    capture->previous_disc = disc;
    capture->previous_number = number;
    if (capture->count < 64) capture->ids[capture->count] = track->id;
    capture->count += 1;
}

static void count_issue(void *context, const orca_health_issue_view *issue) {
    uint32_t *count = context;
    if (issue->path.pointer != 0) *count += 1;
}

static void count_root(void *context, const orca_root_view *root) {
    uint32_t *count = context;
    if (root->path.length != 0 && root->enabled) *count += 1;
}

static void count_device(void *context, const orca_device_view *device) {
    uint32_t *count = context;
    (void)device;
    *count += 1;
}

struct device_kind_search {
    uint64_t id;
    uint32_t count;
    uint8_t kind;
    int found;
};

static void find_device_kind(void *context, const orca_device_view_v2 *device) {
    struct device_kind_search *search = context;
    search->count += 1;
    if (device->base.id != search->id) return;
    search->found = device->base.name.length != 0;
    search->kind = device->kind;
}

struct queue_capture {
    uint32_t count;
    uint32_t current_seen;
};

static void capture_queue_entry(void *context, const orca_queue_entry_view *entry) {
    struct queue_capture *capture = context;
    capture->count += 1;
    if (entry->is_current) capture->current_seen += 1;
}

struct now_playing_capture {
    uint32_t count;
    int64_t track_id;
    size_t title_length;
};

static void capture_now_playing(void *context, const orca_now_playing_view *view) {
    struct now_playing_capture *capture = context;
    capture->count += 1;
    capture->track_id = view->track_id;
    capture->title_length = view->title.length;
}

/* Pumps the control lane and drains events, reporting whether the named job
 * reached a terminal state. */
static int job_settled(orca_runtime *runtime, orca_handle job, uint8_t *state,
                       uint8_t expect_total) {
    orca_job_snapshot snapshot;
    if (orca_runtime_pump(runtime) != ORCA_STATUS_OK) return -1;
    for (;;) {
        orca_event event;
        uint32_t remaining = 0;
        if (orca_runtime_poll_event(runtime, &event, &remaining) != ORCA_STATUS_OK) return -1;
        if (event.kind == ORCA_EVENT_NONE) break;
        if (event.kind == ORCA_EVENT_JOB_FINISHED &&
            event.payload.job_finished.job.index == job.index &&
            event.payload.job_finished.job.generation == job.generation) {
            *state = event.payload.job_finished.state;
            return 1;
        }
        if (remaining == 0) break;
    }
    if (orca_job_snapshot_get(runtime, job, &snapshot) != ORCA_STATUS_OK) return -1;
    /* A filesystem walk must not invent a denominator; a backfill, which knows
     * how many rows still owe a probe before it starts, must publish one. */
    if ((snapshot.has_total != 0) != (expect_total != 0)) return -1;
    if (snapshot.state == ORCA_JOB_SUCCEEDED || snapshot.state == ORCA_JOB_FAILED ||
        snapshot.state == ORCA_JOB_CANCELLED) {
        *state = snapshot.state;
        return 1;
    }
    return 0;
}

/* Waits for the job the way a host does: woken by liborca, never sleeping on a
 * timer. A job still running keeps the pump timeout finite, so a wait for the
 * callback alone that times out is a lost wake. */
static int await_job(orca_runtime *runtime, orca_handle job, uint8_t *state,
                     uint8_t expect_total, long limit_ms) {
    long deadline = now_ms() + limit_ms;
    for (;;) {
        int settled = job_settled(runtime, job, state, expect_total);
        if (settled != 0) return settled;
        if (now_ms() >= deadline) return 0;
        if (wait_for_runtime(runtime, deadline) != 0) return -1;
    }
}

static int copy_file(const char *source, const char *destination) {
    char buffer[65536];
    FILE *input = fopen(source, "rb");
    if (input == 0) return -1;
    FILE *output = fopen(destination, "wb");
    if (output == 0) {
        fclose(input);
        return -1;
    }
    int result = 0;
    size_t length;
    while ((length = fread(buffer, 1, sizeof buffer, input)) > 0) {
        if (fwrite(buffer, 1, length, output) != length) result = -1;
    }
    if (ferror(input)) result = -1;
    fclose(input);
    if (fclose(output) != 0) result = -1;
    return result;
}

/* Pumps like a host until the watcher's reconcile reports that `library`
 * changed, or `deadline` passes. */
static int await_library_changed(orca_runtime *runtime, orca_handle library, long deadline) {
    for (;;) {
        for (;;) {
            orca_event event;
            if (orca_runtime_poll_event(runtime, &event, 0) != ORCA_STATUS_OK) return -1;
            if (event.kind == ORCA_EVENT_NONE) break;
            if (event.kind == ORCA_EVENT_LIBRARY_CHANGED &&
                event.payload.library_changed.library.index == library.index &&
                event.payload.library_changed.library.generation == library.generation)
                return 1;
        }
        if (now_ms() >= deadline) return 0;
        if (wait_for_runtime(runtime, deadline) < 0) return -1;
    }
}

struct edit_capture {
    uint32_t count;
    uint8_t feedback;
    uint8_t has_rating;
    uint8_t rating;
    uint8_t loved;
};

static void capture_edit_track(void *context, const orca_track_summary_view *summary) {
    struct edit_capture *capture = context;
    capture->count += 1;
    capture->feedback = summary->track.feedback;
    capture->has_rating = summary->track.has_rating;
    capture->rating = summary->track.rating;
}

static void capture_edit_release(void *context, const orca_release_view *release) {
    struct edit_capture *capture = context;
    capture->count += 1;
    capture->loved = release->loved;
}

static int track_edit_state(orca_runtime *runtime, orca_handle library, int64_t track_id,
                            struct edit_capture *state) {
    memset(state, 0, sizeof *state);
    SMOKE_CHECK(orca_library_track_get(runtime, library, track_id, state,
                                       capture_edit_track) == ORCA_STATUS_OK);
    SMOKE_CHECK(state->count == 1);
    return 0;
}

/* Feedback, ratings and album love through the same boundary a host uses,
 * ending with the Library as it started so later checks still see no loved
 * Track or Release. */
static int library_edits_smoke(orca_runtime *runtime, orca_handle library, int64_t track_id,
                               int64_t release_id) {
    const int64_t tracks[2] = {track_id, 999999999};
    orca_change_count change;
    struct edit_capture state;
    uint8_t feedback = 0xff;

    memset(&change, 0xff, sizeof change);
    SMOKE_CHECK(orca_library_set_feedback(runtime, library, tracks, 2, ORCA_FEEDBACK_LOVED,
                                          &change) == ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1 && change.skipped == 1);
    SMOKE_CHECK(track_edit_state(runtime, library, track_id, &state) == 0);
    SMOKE_CHECK(state.feedback == ORCA_FEEDBACK_LOVED);
    SMOKE_CHECK(orca_library_track_feedback(runtime, library, track_id, &feedback) ==
                    ORCA_STATUS_OK &&
                feedback == ORCA_FEEDBACK_LOVED);

    SMOKE_CHECK(orca_library_set_feedback(runtime, library, tracks, 1, ORCA_FEEDBACK_HATED,
                                          &change) == ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1 && change.skipped == 0);
    SMOKE_CHECK(orca_library_track_feedback(runtime, library, track_id, &feedback) ==
                    ORCA_STATUS_OK &&
                feedback == ORCA_FEEDBACK_HATED);
    SMOKE_CHECK(orca_library_set_feedback(runtime, library, tracks, 1, ORCA_FEEDBACK_NONE,
                                          &change) == ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1);
    SMOKE_CHECK(orca_library_track_feedback(runtime, library, track_id, &feedback) ==
                    ORCA_STATUS_OK &&
                feedback == ORCA_FEEDBACK_NONE);
    SMOKE_CHECK(orca_library_set_feedback(runtime, library, tracks, 1, 9, &change) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_set_feedback(runtime, library, 0, 0, ORCA_FEEDBACK_LOVED,
                                          &change) == ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 0 && change.skipped == 0);

    SMOKE_CHECK(orca_library_set_rating(runtime, library, tracks, 2, 80, &change) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1 && change.skipped == 1);
    SMOKE_CHECK(track_edit_state(runtime, library, track_id, &state) == 0);
    SMOKE_CHECK(state.has_rating == 1 && state.rating == 80);
    SMOKE_CHECK(orca_library_set_rating(runtime, library, tracks, 1, 101, &change) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_set_rating(runtime, library, tracks, 1, 0, &change) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1);
    SMOKE_CHECK(track_edit_state(runtime, library, track_id, &state) == 0);
    SMOKE_CHECK(state.has_rating == 0);

    const int64_t releases[2] = {release_id, 999999999};
    SMOKE_CHECK(orca_library_set_release_love(runtime, library, releases, 2, 1, &change) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1 && change.skipped == 1);
    memset(&state, 0, sizeof state);
    SMOKE_CHECK(orca_library_release_get(runtime, library, release_id, &state,
                                         capture_edit_release) == ORCA_STATUS_OK);
    SMOKE_CHECK(state.count == 1 && state.loved == 1);
    orca_release_query query;
    memset(&query, 0, sizeof query);
    query.album_artist_id = -1;
    query.loved_only = 1;
    query.limit = 512;
    struct edit_capture listed;
    memset(&listed, 0, sizeof listed);
    uint64_t matching = 0;
    SMOKE_CHECK(orca_library_browse_releases(runtime, library, &query, &listed,
                                             capture_edit_release) == ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 1 && listed.loved == 1);
    SMOKE_CHECK(orca_library_release_count_matching(runtime, library, &query, &matching) ==
                    ORCA_STATUS_OK &&
                matching == 1);
    SMOKE_CHECK(orca_library_set_release_love(runtime, library, releases, 1, 2, &change) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_set_release_love(runtime, library, releases, 1, 0, &change) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1);
    SMOKE_CHECK(orca_library_release_count_matching(runtime, library, &query, &matching) ==
                    ORCA_STATUS_OK &&
                matching == 0);
    return 0;
}

struct genre_capture {
    uint32_t count;
    int64_t id;
    uint32_t track_count;
    int64_t wanted;
    int found;
    char names[4][32];
    orca_release_facts_view facts;
};

static void capture_genre(void *context, const orca_genre_view *genre) {
    struct genre_capture *capture = context;
    capture->count += 1;
    capture->id = genre->id;
    capture->track_count = genre->track_count;
}

static void capture_genre_name(void *context, const orca_string_view *name) {
    struct genre_capture *capture = context;
    if (capture->count < 4 && name->length < sizeof capture->names[0]) {
        memcpy(capture->names[capture->count], name->pointer, name->length);
        capture->names[capture->count][name->length] = 0;
    }
    capture->count += 1;
}

static void capture_genre_count(void *context, const orca_genre_count_view *genre) {
    struct genre_capture *capture = context;
    capture->count += 1;
    if (genre->id == capture->wanted && genre->track_count >= 1) capture->found = 1;
}

static void capture_genre_track(void *context, const orca_track_summary_view *summary,
                                const orca_track_facts_view *facts) {
    (void)facts;
    struct genre_capture *capture = context;
    capture->count += 1;
    if (summary->track.id == capture->wanted) capture->found = 1;
}

static void capture_genre_release(void *context, const orca_release_view *release,
                                  const orca_release_facts_view *facts) {
    struct genre_capture *capture = context;
    capture->count += 1;
    if (release->id == capture->wanted) {
        capture->found = 1;
        capture->facts = *facts;
        capture->facts.codec.pointer = 0;
        capture->facts.release_type.pointer = 0;
    }
}

struct search_capture {
    uint32_t count;
    uint32_t genres;
    int64_t genre_id;
    int ordered;
    int last_kind;
    char title[32];
};

static void capture_search_hit(void *context, const orca_search_hit_view *hit) {
    struct search_capture *capture = context;
    capture->count += 1;
    if ((int)hit->kind < capture->last_kind) capture->ordered = 0;
    capture->last_kind = hit->kind;
    if (hit->kind == ORCA_SEARCH_KIND_GENRE) {
        capture->genres += 1;
        capture->genre_id = hit->id;
        if (hit->title.length < sizeof capture->title) {
            memcpy(capture->title, hit->title.pointer, hit->title.length);
            capture->title[hit->title.length] = 0;
        }
    }
}

static uint64_t count_releases(orca_runtime *runtime, orca_handle library,
                               const orca_release_query_v2 *query) {
    uint64_t total = UINT64_MAX;
    if (orca_library_release_count_matching_v2(runtime, library, query, &total) !=
        ORCA_STATUS_OK)
        return UINT64_MAX;
    return total;
}

static void capture_genre_artist(void *context, const orca_artist_view_v2 *artist) {
    (void)artist;
    struct genre_capture *capture = context;
    capture->count += 1;
}

static void capture_first_artist(void *context, const orca_artist_view_v2 *artist) {
    orca_artist_view *first = context;
    if (first->id == 0) *first = artist->base;
}

static void capture_genre_artwork(void *context, const int64_t *ids, size_t count) {
    struct genre_capture *capture = context;
    capture->count += (uint32_t)count;
    for (size_t index = 0; index < count; index += 1)
        if (ids[index] == capture->wanted) capture->found = 1;
}

static void capture_summary_release(void *context, const orca_track_summary_view *summary) {
    int64_t *release_id = context;
    *release_id = summary->has_release_id ? summary->release_id : -1;
}

static int find_genre(orca_runtime *runtime, orca_handle library, const char *filter,
                      struct genre_capture *found) {
    orca_genre_query query;
    memset(&query, 0, sizeof query);
    query.filter.pointer = filter;
    query.filter.length = strlen(filter);
    query.sort = ORCA_GENRE_SORT_TRACK_COUNT;
    query.limit = 512;
    memset(found, 0, sizeof *found);
    SMOKE_CHECK(orca_library_query_genres(runtime, library, &query, found, capture_genre) ==
                ORCA_STATUS_OK);
    return 0;
}

/* Genres a user sets through the boundary fold the way a file's do, reach every
 * genre listing and filter, and clearing them restores the Track's own. */
static int genre_smoke(orca_runtime *runtime, orca_handle library, int64_t track_id) {
    const int64_t tracks[1] = {track_id};
    const orca_string_view names[3] = {
        {"Hip-Hop", 7},
        {"hip hop", 7},
        {"Orca Smoke Genre", 16},
    };
    struct genre_capture capture;

    SMOKE_CHECK(orca_library_set_track_genres(runtime, library, tracks, 1, names, 3) ==
                ORCA_STATUS_OK);
    memset(&capture, 0, sizeof capture);
    SMOKE_CHECK(orca_library_track_genres(runtime, library, track_id, &capture,
                                          capture_genre_name) == ORCA_STATUS_OK);
    SMOKE_CHECK(capture.count == 2);
    SMOKE_CHECK(strcmp(capture.names[0], "Hip Hop") == 0);
    SMOKE_CHECK(strcmp(capture.names[1], "Orca Smoke Genre") == 0);

    struct genre_capture genre;
    SMOKE_CHECK(find_genre(runtime, library, "orca smoke", &genre) == 0);
    SMOKE_CHECK(genre.count == 1 && genre.track_count == 1);
    uint64_t total = 0;
    SMOKE_CHECK(orca_library_genre_count(runtime, library, "orca-smoke", 10, &total) ==
                    ORCA_STATUS_OK &&
                total == 1);
    memset(&capture, 0, sizeof capture);
    SMOKE_CHECK(orca_library_genre_get(runtime, library, genre.id, &capture, capture_genre) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(capture.count == 1 && capture.id == genre.id);

    orca_track_query_v2 track_query;
    memset(&track_query, 0, sizeof track_query);
    track_query.genre_id = genre.id;
    track_query.has_genre_id = 1;
    track_query.sort = ORCA_TRACK_SORT_TITLE;
    track_query.limit = 512;
    memset(&capture, 0, sizeof capture);
    capture.wanted = track_id;
    SMOKE_CHECK(orca_library_browse_tracks_v2(runtime, library, &track_query, &capture,
                                              capture_genre_track) == ORCA_STATUS_OK);
    SMOKE_CHECK(capture.count == 1 && capture.found);
    track_query.text.pointer = "\"(*";
    track_query.text.length = 3;
    memset(&capture, 0, sizeof capture);
    SMOKE_CHECK(orca_library_browse_tracks_v2(runtime, library, &track_query, &capture,
                                              capture_genre_track) == ORCA_STATUS_OK);
    SMOKE_CHECK(capture.count == 0);
    track_query.text.pointer = "zzzqqq NEAR";
    track_query.text.length = 11;
    memset(&capture, 0, sizeof capture);
    SMOKE_CHECK(orca_library_browse_tracks_v2(runtime, library, &track_query, &capture,
                                              capture_genre_track) == ORCA_STATUS_OK);
    SMOKE_CHECK(capture.count == 0);
    SMOKE_CHECK(orca_library_track_match_count_v2(runtime, library, &track_query, &total) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    struct search_capture search;
    memset(&search, 0, sizeof search);
    search.ordered = 1;
    SMOKE_CHECK(orca_library_search(runtime, library, "orca SMOKE", 10, NULL, &search,
                                    capture_search_hit) == ORCA_STATUS_OK);
    SMOKE_CHECK(search.ordered && search.genres == 1 && search.genre_id == genre.id);
    SMOKE_CHECK(strcmp(search.title, "Orca Smoke Genre") == 0);
    orca_search_limits limits;
    memset(&limits, 0, sizeof limits);
    limits.genres = 1;
    memset(&search, 0, sizeof search);
    SMOKE_CHECK(orca_library_search(runtime, library, "smok", 4, &limits, &search,
                                    capture_search_hit) == ORCA_STATUS_OK);
    SMOKE_CHECK(search.count == 1 && search.genre_id == genre.id);
    memset(&search, 0, sizeof search);
    SMOKE_CHECK(orca_library_search(runtime, library, "\"NEAR\" OR (*", 12, NULL, &search,
                                    capture_search_hit) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_search(runtime, library, NULL, 0, NULL, &search,
                                    capture_search_hit) == ORCA_STATUS_OK);
    limits.tracks = 51;
    SMOKE_CHECK(orca_library_search(runtime, library, "smoke", 5, &limits, &search,
                                    capture_search_hit) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_search(runtime, library, NULL, 1, NULL, &search,
                                    capture_search_hit) == ORCA_STATUS_INVALID_ARGUMENT);

    int64_t release_id = -1;
    SMOKE_CHECK(orca_library_track_get(runtime, library, track_id, &release_id,
                                       capture_summary_release) == ORCA_STATUS_OK);
    if (release_id >= 0) {
        orca_release_query_v2 release_query;
        memset(&release_query, 0, sizeof release_query);
        release_query.genre_id = genre.id;
        release_query.has_genre_id = 1;
        release_query.limit = 512;
        memset(&capture, 0, sizeof capture);
        capture.wanted = release_id;
        SMOKE_CHECK(orca_library_browse_releases_v2(runtime, library, &release_query, &capture,
                                                    capture_genre_release) == ORCA_STATUS_OK);
        SMOKE_CHECK(capture.count == 1 && capture.found);
        uint64_t releases = 0;
        SMOKE_CHECK(orca_library_release_count_matching_v2(runtime, library, &release_query,
                                                           &releases) == ORCA_STATUS_OK &&
                    releases == 1);
        SMOKE_CHECK(capture.facts.codec.length > 0 && capture.facts.max_sample_rate > 0);

        orca_release_query_v2 filtered = release_query;
        filtered.lossless_only = 1;
        SMOKE_CHECK(count_releases(runtime, library, &filtered) == capture.facts.lossless);
        filtered = release_query;
        filtered.high_resolution_only = 1;
        SMOKE_CHECK(count_releases(runtime, library, &filtered) ==
                    (capture.facts.max_sample_rate > 48000 || capture.facts.max_bit_depth > 16));
        filtered = release_query;
        filtered.needs_review_only = 1;
        SMOKE_CHECK(count_releases(runtime, library, &filtered) ==
                    (capture.facts.pending_reviews > 0));
        filtered = release_query;
        filtered.has_year_min = 1;
        filtered.year_min = 9999;
        SMOKE_CHECK(count_releases(runtime, library, &filtered) == 0);
        filtered = release_query;
        filtered.artwork = ORCA_RELEASE_ARTWORK_PRESENT;
        uint64_t with_cover = count_releases(runtime, library, &filtered);
        filtered.artwork = ORCA_RELEASE_ARTWORK_ABSENT;
        uint64_t without_cover = count_releases(runtime, library, &filtered);
        SMOKE_CHECK(with_cover <= 1 && without_cover <= 1 && with_cover + without_cover == 1);
        filtered.artwork = 3;
        SMOKE_CHECK(orca_library_release_count_matching_v2(runtime, library, &filtered,
                                                           &releases) ==
                    ORCA_STATUS_INVALID_ARGUMENT);
        filtered = release_query;
        uint64_t kinds = 0;
        for (uint8_t kind = ORCA_RELEASE_KIND_ALBUM; kind <= ORCA_RELEASE_KIND_OTHER; kind += 1) {
            filtered.kind = kind;
            kinds += count_releases(runtime, library, &filtered);
        }
        SMOKE_CHECK(kinds == 1);
        filtered.kind = ORCA_RELEASE_KIND_ALBUM;
        SMOKE_CHECK(count_releases(runtime, library, &filtered) ==
                    (capture.facts.release_type.length == 0 ||
                     (capture.facts.release_type.length == 5 &&
                      memcmp(capture.facts.release_type.pointer, "album", 5) == 0)));
        filtered.kind = ORCA_RELEASE_KIND_OTHER + 1;
        SMOKE_CHECK(orca_library_release_count_matching_v2(runtime, library, &filtered,
                                                           &releases) ==
                    ORCA_STATUS_INVALID_ARGUMENT);
        filtered = release_query;
        filtered.text.pointer = "zzzqqq";
        filtered.text.length = 6;
        SMOKE_CHECK(count_releases(runtime, library, &filtered) == 0);
        filtered.text.pointer = "- (";
        filtered.text.length = 3;
        SMOKE_CHECK(count_releases(runtime, library, &filtered) == 1);
        filtered.text.pointer = NULL;
        SMOKE_CHECK(orca_library_release_count_matching_v2(runtime, library, &filtered,
                                                           &releases) ==
                    ORCA_STATUS_INVALID_ARGUMENT);
        filtered = release_query;
        filtered.sort = ORCA_RELEASE_SORT_MOST_PLAYED;
        memset(&capture, 0, sizeof capture);
        capture.wanted = release_id;
        SMOKE_CHECK(orca_library_browse_releases_v2(runtime, library, &filtered, &capture,
                                                    capture_genre_release) == ORCA_STATUS_OK);
        SMOKE_CHECK(capture.count == 1 && capture.found);

        memset(&capture, 0, sizeof capture);
        capture.wanted = genre.id;
        SMOKE_CHECK(orca_library_release_genres(runtime, library, release_id, 16, &capture,
                                                capture_genre_count) == ORCA_STATUS_OK);
        SMOKE_CHECK(capture.found);

        filtered = release_query;
        filtered.artwork = ORCA_RELEASE_ARTWORK_PRESENT;
        struct genre_capture covered;
        memset(&covered, 0, sizeof covered);
        covered.wanted = release_id;
        SMOKE_CHECK(orca_library_browse_releases_v2(runtime, library, &filtered, &covered,
                                                    capture_genre_release) == ORCA_STATUS_OK);
        memset(&capture, 0, sizeof capture);
        capture.wanted = release_id;
        SMOKE_CHECK(orca_library_genre_artwork(runtime, library, genre.id, 4, &capture,
                                               capture_genre_artwork) == ORCA_STATUS_OK);
        SMOKE_CHECK(capture.count == covered.count && capture.found == covered.found);
    }

    orca_artist_query_v2 artist_query;
    memset(&artist_query, 0, sizeof artist_query);
    artist_query.genre_id = genre.id;
    artist_query.has_genre_id = 1;
    artist_query.sort = ORCA_ARTIST_SORT_TRACK_COUNT;
    artist_query.limit = 512;
    memset(&capture, 0, sizeof capture);
    SMOKE_CHECK(orca_library_query_artists_v2(runtime, library, &artist_query, &capture,
                                              capture_genre_artist) == ORCA_STATUS_OK);
    uint64_t artists = 0;
    SMOKE_CHECK(orca_library_artist_count_matching_v2(runtime, library, &artist_query,
                                                      &artists) == ORCA_STATUS_OK &&
                artists == capture.count);

    orca_artist_view newest;
    memset(&newest, 0, sizeof newest);
    artist_query.sort = ORCA_ARTIST_SORT_RECENTLY_ADDED;
    SMOKE_CHECK(orca_library_query_artists_v2(runtime, library, &artist_query, &newest,
                                              capture_first_artist) == ORCA_STATUS_OK);
    SMOKE_CHECK(newest.id != 0);
    orca_artist_totals totals;
    memset(&totals, 0xff, sizeof totals);
    SMOKE_CHECK(orca_library_artist_totals(runtime, library, newest.id, &totals) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(totals.release_count + totals.appearance_count == newest.release_count &&
                totals.track_count == newest.track_count && totals.duration_ms > 0);
    orca_release_query_v2 appearances;
    memset(&appearances, 0, sizeof appearances);
    appearances.appearing_artist_id = newest.id;
    appearances.has_appearing_artist_id = 1;
    appearances.limit = 512;
    SMOKE_CHECK(count_releases(runtime, library, &appearances) == totals.appearance_count);
    orca_release_query_v2 own;
    memset(&own, 0, sizeof own);
    own.album_artist_id = newest.id;
    own.has_album_artist_id = 1;
    own.own_releases_only = 1;
    own.limit = 512;
    SMOKE_CHECK(count_releases(runtime, library, &own) == totals.release_count);
    own.own_releases_only = 0;
    SMOKE_CHECK(count_releases(runtime, library, &own) == newest.release_count);
    SMOKE_CHECK(orca_library_artist_totals(runtime, library, 999999999, &totals) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_artist_totals(runtime, library, newest.id, NULL) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    const orca_string_view blank[1] = {{" - ", 3}};
    SMOKE_CHECK(orca_library_set_track_genres(runtime, library, tracks, 1, blank, 1) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    const int64_t missing[1] = {999999999};
    SMOKE_CHECK(orca_library_set_track_genres(runtime, library, missing, 1, names, 1) ==
                ORCA_STATUS_NOT_FOUND);

    SMOKE_CHECK(orca_library_set_track_genres(runtime, library, tracks, 1, 0, 0) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(find_genre(runtime, library, "orca smoke", &genre) == 0);
    SMOKE_CHECK(genre.count == 0);
    return 0;
}

struct queued_tracks {
    uint32_t count;
    int64_t ids[8];
    char titles[8][128];
};

static void capture_queued_track(void *context, const orca_track_view *track) {
    struct queued_tracks *capture = context;
    if (capture->count < 8) {
        size_t length = track->title.length;
        if (length >= sizeof capture->titles[0]) length = sizeof capture->titles[0] - 1;
        memcpy(capture->titles[capture->count], track->title.pointer, length);
        capture->titles[capture->count][length] = 0;
        capture->ids[capture->count] = track->id;
        capture->count += 1;
    }
}

static void collect_playable(void *context, const orca_track_view *track) {
    if (track->has_file) capture_queued_track(context, track);
}

struct queue_order {
    uint32_t count;
    uint32_t current_position;
    int64_t ids[8];
};

static void capture_queue_order(void *context, const orca_queue_entry_view *entry) {
    struct queue_order *capture = context;
    if (entry->is_current) capture->current_position = entry->position;
    if (capture->count < 8) capture->ids[capture->count] = entry->track_id;
    capture->count += 1;
}

static int queue_order_is(orca_runtime *runtime, orca_handle player, const int64_t *expected,
                          uint32_t count, uint32_t current) {
    struct queue_order order;
    memset(&order, 0, sizeof order);
    order.current_position = 9999;
    SMOKE_CHECK(orca_player_query_queue(runtime, player, 512, 0, &order, capture_queue_order) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(order.count == count && order.current_position == current);
    for (uint32_t i = 0; i < count; i += 1) SMOKE_CHECK(order.ids[i] == expected[i]);
    return 0;
}

static const char *title_of(const struct queued_tracks *library_tracks, int64_t id) {
    for (uint32_t i = 0; i < library_tracks->count; i += 1)
        if (library_tracks->ids[i] == id) return library_tracks->titles[i];
    return "";
}

struct history_capture {
    uint32_t count;
    int64_t ids[8];
    int64_t ended_at[8];
    uint8_t reasons[8];
};

static void capture_history(void *context, const orca_track_summary_view *summary,
                            int64_t ended_at, uint8_t reason) {
    struct history_capture *capture = context;
    if (capture->count < 8) {
        capture->ids[capture->count] = summary->track.id;
        capture->ended_at[capture->count] = ended_at;
        capture->reasons[capture->count] = reason;
    }
    capture->count += 1;
}

struct saved_entries {
    uint32_t count;
    int64_t ids[8];
};

static void capture_saved_entry(void *context, const orca_playlist_entry_view *entry) {
    struct saved_entries *capture = context;
    if (capture->count < 8) capture->ids[capture->count] = entry->has_track ? entry->track.id : 0;
    capture->count += 1;
}

static int queue_smoke(orca_runtime *runtime, orca_handle library, orca_handle player) {
    struct queued_tracks playable;
    memset(&playable, 0, sizeof playable);
    SMOKE_CHECK(orca_library_query_tracks(runtime, library, 0, 0, 512, 0, &playable,
                                          collect_playable) == ORCA_STATUS_OK);
    SMOKE_CHECK(playable.count >= 4);
    int64_t *ids = playable.ids;

    SMOKE_CHECK(orca_player_set_repeat(runtime, player, ORCA_REPEAT_ONE) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_play_tracks(runtime, player, ids, 3, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_stop(runtime, player) == ORCA_STATUS_OK);

    SMOKE_CHECK(orca_player_queue_insert_next(runtime, player, 0, 1) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_queue_insert_next(runtime, player, &ids[3], 1) == ORCA_STATUS_OK);
    int64_t inserted[4] = {ids[0], ids[3], ids[1], ids[2]};
    SMOKE_CHECK(queue_order_is(runtime, player, inserted, 4, 0) == 0);

    SMOKE_CHECK(orca_player_queue_move(runtime, player, 3, 1) == ORCA_STATUS_OK);
    int64_t moved_order[4] = {ids[0], ids[2], ids[3], ids[1]};
    SMOKE_CHECK(queue_order_is(runtime, player, moved_order, 4, 0) == 0);
    SMOKE_CHECK(orca_player_queue_move(runtime, player, 1, 3) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_queue_move(runtime, player, 2, 2) == ORCA_STATUS_OK);
    SMOKE_CHECK(queue_order_is(runtime, player, inserted, 4, 0) == 0);
    SMOKE_CHECK(orca_player_queue_move(runtime, player, 0, 4) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_queue_move(runtime, player, 4, 0) == ORCA_STATUS_INVALID_ARGUMENT);

    struct queued_tracks listed;
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_player_query_queue_tracks(runtime, player, 512, 0, &listed,
                                               capture_queued_track) == ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 4);
    for (uint32_t i = 0; i < 4; i += 1) {
        SMOKE_CHECK(listed.ids[i] == inserted[i]);
        SMOKE_CHECK(listed.titles[i][0] != 0);
        SMOKE_CHECK(strcmp(listed.titles[i], title_of(&playable, inserted[i])) == 0);
    }
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_player_query_queue_tracks(runtime, player, 1, 1, &listed,
                                               capture_queued_track) == ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 1 && listed.ids[0] == ids[3]);
    SMOKE_CHECK(orca_player_query_queue_tracks(runtime, player, 0, 0, &listed,
                                               capture_queued_track) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_player_queue_remove(runtime, player, 2) == ORCA_STATUS_OK);
    int64_t removed[3] = {ids[0], ids[3], ids[2]};
    SMOKE_CHECK(queue_order_is(runtime, player, removed, 3, 0) == 0);
    SMOKE_CHECK(orca_player_queue_remove(runtime, player, 3) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_queue_jump(runtime, player, 3) == ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_player_queue_jump(runtime, player, 1) == ORCA_STATUS_OK);
    orca_player_status status;
    struct now_playing_capture playing;
    int reflected = 0;
    long deadline = now_ms() + 3000;
    while (!reflected && now_ms() < deadline) {
        SMOKE_CHECK(wait_for_runtime(runtime, now_ms() + 10) >= 0);
        SMOKE_CHECK(drain_events(runtime) == 0);
        SMOKE_CHECK(orca_player_status_get(runtime, player, &status) == ORCA_STATUS_OK);
        memset(&playing, 0, sizeof playing);
        SMOKE_CHECK(orca_player_now_playing(runtime, player, &playing, capture_now_playing) ==
                    ORCA_STATUS_OK);
        reflected = status.queue_index == 1 && status.track_id == ids[3] &&
                    status.transport == ORCA_TRANSPORT_PLAYING && playing.count == 1 &&
                    playing.track_id == ids[3];
    }
    SMOKE_CHECK(reflected);
    SMOKE_CHECK(orca_player_queue_remove(runtime, player, 1) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(orca_player_queue_move(runtime, player, 1, 0) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(queue_order_is(runtime, player, removed, 3, 1) == 0);

    orca_queue_stats stats;
    memset(&stats, 0, sizeof stats);
    deadline = now_ms() + 3000;
    while (stats.entries_started == 0 && now_ms() < deadline) {
        SMOKE_CHECK(wait_for_runtime(runtime, now_ms() + 10) >= 0);
        SMOKE_CHECK(drain_events(runtime) == 0);
        SMOKE_CHECK(orca_player_queue_stats(runtime, player, &stats) == ORCA_STATUS_OK);
    }
    SMOKE_CHECK(stats.entries_started >= 1);
    SMOKE_CHECK(stats.open_failures == 0 && stats.decode_errors == 0);
    SMOKE_CHECK(orca_player_queue_stats(runtime, player, 0) == ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_player_set_repeat(runtime, player, ORCA_REPEAT_OFF) == ORCA_STATUS_OK);

    uint8_t moved = 0;
    SMOKE_CHECK(orca_player_next(runtime, player, &moved) == ORCA_STATUS_OK && moved == 1);
    struct history_capture history;
    memset(&history, 0, sizeof history);
    SMOKE_CHECK(orca_player_query_queue_history(runtime, player, 512, 0, &history,
                                                capture_history) == ORCA_STATUS_OK);
    SMOKE_CHECK(history.count >= 1);
    SMOKE_CHECK(history.ids[0] == ids[3]);
    SMOKE_CHECK(history.reasons[0] == ORCA_QUEUE_HISTORY_REASON_SKIPPED);
    SMOKE_CHECK(history.ended_at[0] > 0);
    SMOKE_CHECK(orca_player_query_queue_history(runtime, player, 0, 0, &history,
                                                capture_history) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_query_queue_history(runtime, player, 8, 0, &history, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    int64_t saved_id = 0;
    SMOKE_CHECK(orca_player_save_queue_as_playlist(runtime, player, "smoke queue", 11, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_save_queue_as_playlist(runtime, player, 0, 3, &saved_id) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_save_queue_as_playlist(runtime, player, "smoke queue", 11,
                                                   &saved_id) == ORCA_STATUS_OK);
    struct saved_entries saved;
    memset(&saved, 0, sizeof saved);
    SMOKE_CHECK(orca_library_query_playlist_entries(runtime, library, saved_id, 512, 0, &saved,
                                                    capture_saved_entry) == ORCA_STATUS_OK);
    SMOKE_CHECK(saved.count == 1 && saved.ids[0] == ids[2]);
    SMOKE_CHECK(orca_player_save_queue_as_playlist(runtime, player, "smoke queue", 11,
                                                   &saved_id) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(orca_library_delete_playlist(runtime, library, saved_id) == ORCA_STATUS_OK);

    SMOKE_CHECK(orca_player_clear_queue_history(runtime, player) == ORCA_STATUS_OK);
    memset(&history, 0, sizeof history);
    SMOKE_CHECK(orca_player_query_queue_history(runtime, player, 512, 0, &history,
                                                capture_history) == ORCA_STATUS_OK);
    SMOKE_CHECK(history.count == 0);
    return 0;
}

struct track_ids {
    uint32_t count;
    int64_t ids[64];
};

static void collect_playable_ids(void *context, const orca_track_view *track) {
    struct track_ids *capture = context;
    if (track->has_file && capture->count < 64) {
        capture->ids[capture->count] = track->id;
        capture->count += 1;
    }
}

static void capture_is_flac(void *context, const orca_track_details_view *details) {
    int *is_flac = context;
    *is_flac = details->codec.length == 4 && memcmp(details->codec.pointer, "flac", 4) == 0;
}

struct signal_path_capture {
    uint32_t count;
    orca_signal_path_view view;
    char codec[16];
};

static void capture_signal_path(void *context, const orca_signal_path_view *signal_path) {
    struct signal_path_capture *capture = context;
    capture->count += 1;
    capture->view = *signal_path;
    size_t length = signal_path->codec.length;
    if (length >= sizeof capture->codec) length = sizeof capture->codec - 1;
    memcpy(capture->codec, signal_path->codec.pointer, length);
    capture->codec[length] = 0;
}

static int has_reason(const orca_signal_path_view *signal_path, uint8_t reason) {
    for (uint32_t i = 0; i < signal_path->reason_count && i < ORCA_SIGNAL_MAX_REASONS; i += 1)
        if (signal_path->reasons[i] == reason) return 1;
    return 0;
}

static int read_signal_path(orca_runtime *runtime, orca_handle player,
                            struct signal_path_capture *capture) {
    memset(capture, 0, sizeof *capture);
    SMOKE_CHECK(orca_player_signal_path(runtime, player, capture, capture_signal_path) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(capture->count == 1);
    return 0;
}

static int dsp_smoke(orca_runtime *runtime, orca_handle library, orca_handle player) {
    struct track_ids playable;
    memset(&playable, 0, sizeof playable);
    SMOKE_CHECK(orca_library_query_tracks(runtime, library, 0, 0, 512, 0, &playable,
                                          collect_playable_ids) == ORCA_STATUS_OK);
    int64_t flac_id = 0;
    for (uint32_t i = 0; i < playable.count && flac_id == 0; i += 1) {
        int is_flac = 0;
        SMOKE_CHECK(orca_library_track_details(runtime, library, playable.ids[i], &is_flac,
                                               capture_is_flac) == ORCA_STATUS_OK);
        if (is_flac) flac_id = playable.ids[i];
    }
    SMOKE_CHECK(flac_id != 0);

    orca_equalizer bass;
    SMOKE_CHECK(orca_equalizer_preset_get(ORCA_EQUALIZER_PRESET_BASS, &bass) == ORCA_STATUS_OK);
    SMOKE_CHECK(bass.gains_db[0] == 6.0f && bass.preamp_db == -6.0f);
    SMOKE_CHECK(orca_equalizer_preset_get(9, &bass) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_set_equalizer(runtime, player, &bass) == ORCA_STATUS_OK);
    orca_equalizer read_back;
    uint8_t enabled = 0;
    SMOKE_CHECK(orca_player_equalizer(runtime, player, &read_back, &enabled) == ORCA_STATUS_OK);
    SMOKE_CHECK(enabled == 1 && memcmp(&read_back, &bass, sizeof bass) == 0);
    orca_equalizer too_loud = bass;
    too_loud.gains_db[4] = 13.0f;
    SMOKE_CHECK(orca_player_set_equalizer(runtime, player, &too_loud) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_player_set_crossfeed(runtime, player, 1, 0.5f) == ORCA_STATUS_OK);
    float amount = 0;
    SMOKE_CHECK(orca_player_crossfeed(runtime, player, &enabled, &amount) == ORCA_STATUS_OK);
    SMOKE_CHECK(enabled == 1 && amount == 0.5f);
    SMOKE_CHECK(orca_player_set_crossfeed(runtime, player, 1, 1.5f) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_crossfeed(runtime, player, &enabled, &amount) == ORCA_STATUS_OK);
    SMOKE_CHECK(enabled == 1 && amount == 0.5f);

    SMOKE_CHECK(orca_player_set_repeat(runtime, player, ORCA_REPEAT_ONE) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_play_tracks(runtime, player, &flac_id, 1, 0) == ORCA_STATUS_OK);
    struct signal_path_capture path;
    long deadline = now_ms() + 3000;
    int heard = 0;
    while (!heard && now_ms() < deadline) {
        SMOKE_CHECK(wait_for_runtime(runtime, now_ms() + 10) >= 0);
        SMOKE_CHECK(drain_events(runtime) == 0);
        SMOKE_CHECK(read_signal_path(runtime, player, &path) == 0);
        heard = path.view.has_source && path.view.has_output && path.view.has_device_quantum &&
                strcmp(path.codec, "flac") == 0;
    }
    SMOKE_CHECK(heard);
    SMOKE_CHECK(path.view.device_quantum_frames != 0);
    SMOKE_CHECK(path.view.output_kind == ORCA_DEVICE_KIND_VIRTUAL);
    SMOKE_CHECK(path.view.has_equalizer == 1);
    SMOKE_CHECK(memcmp(&path.view.equalizer, &bass, sizeof bass) == 0);
    SMOKE_CHECK(path.view.has_crossfeed == 1 && path.view.crossfeed == 0.5f);
    SMOKE_CHECK(path.view.bit_perfect_eligible == 0);
    SMOKE_CHECK(has_reason(&path.view, ORCA_SIGNAL_REASON_SAMPLE_PROCESSING));
    SMOKE_CHECK(!has_reason(&path.view, ORCA_SIGNAL_REASON_LOSSY_SOURCE));
    SMOKE_CHECK(path.view.source.sample_rate != 0 && path.view.output.sample_rate != 0);

    SMOKE_CHECK(orca_player_set_equalizer(runtime, player, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_equalizer(runtime, player, &read_back, &enabled) == ORCA_STATUS_OK);
    SMOKE_CHECK(enabled == 0 && read_back.preamp_db == 0.0f);
    SMOKE_CHECK(orca_player_set_crossfeed(runtime, player, 0, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_volume(runtime, player, 1.0f) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_replay_gain_mode(runtime, player, ORCA_REPLAY_GAIN_OFF) ==
                ORCA_STATUS_OK);
    deadline = now_ms() + 3000;
    int unprocessed = 0;
    while (!unprocessed && now_ms() < deadline) {
        SMOKE_CHECK(wait_for_runtime(runtime, now_ms() + 10) >= 0);
        SMOKE_CHECK(drain_events(runtime) == 0);
        SMOKE_CHECK(read_signal_path(runtime, player, &path) == 0);
        unprocessed = path.view.has_source &&
                      !has_reason(&path.view, ORCA_SIGNAL_REASON_SAMPLE_PROCESSING);
    }
    SMOKE_CHECK(unprocessed);
    SMOKE_CHECK(path.view.has_equalizer == 0 && path.view.has_crossfeed == 0);
    SMOKE_CHECK(path.view.has_replay_gain == 0 && path.view.volume == 1.0f);
    SMOKE_CHECK(path.view.replay_gain_source == ORCA_GAIN_SOURCE_NONE);
    SMOKE_CHECK(path.view.has_replay_gain_track == 0);
    SMOKE_CHECK(strcmp(path.codec, "flac") == 0);

    SMOKE_CHECK(orca_player_set_volume(runtime, player, 0.25f) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_repeat(runtime, player, ORCA_REPEAT_OFF) == ORCA_STATUS_OK);
    return 0;
}

static const char parametric_apo[] =
    "# a correction\r\n"
    "Preamp: -3 dB\r\n"
    "Filter 1: ON LSC Fc 105 Hz Gain 3.0 dB Q 0.71\r\n"
    "Filter 2: ON PK Fc 1000 Hz Gain -2.0 dB Q 1.41\r\n"
    "Filter 3: ON PK Fc 3000 Hz Gain 2.5 dB Q 2.0\r\n"
    "Filter 4: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.71\r\n";

static const char parametric_apo_written[] =
    "Preamp: -3 dB\n"
    "Filter 1: ON LSC Fc 105 Hz Gain 3 dB Q 0.71\n"
    "Filter 2: ON PK Fc 1000 Hz Gain -2 dB Q 1.41\n"
    "Filter 3: ON PK Fc 3000 Hz Gain 2.5 dB Q 2\n"
    "Filter 4: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.71\n";

static int parametric_smoke(orca_runtime *runtime, orca_handle library, orca_handle player) {
    orca_parametric_equalizer correction;
    memset(&correction, 0xff, sizeof correction);
    SMOKE_CHECK(orca_parametric_equalizer_parse_apo(parametric_apo, sizeof parametric_apo - 1,
                                                    &correction) == ORCA_STATUS_OK);
    SMOKE_CHECK(correction.count == 4 && correction.preamp_db == -3.0f);
    SMOKE_CHECK(correction.filters[0].kind == ORCA_PARAMETRIC_FILTER_LOW_SHELF);
    SMOKE_CHECK(correction.filters[1].kind == ORCA_PARAMETRIC_FILTER_PEAK);
    SMOKE_CHECK(correction.filters[3].kind == ORCA_PARAMETRIC_FILTER_HIGH_SHELF);
    SMOKE_CHECK(correction.filters[1].enabled == 1 && correction.filters[1].frequency_hz == 1000.0f);
    SMOKE_CHECK(correction.filters[1].gain_db == -2.0f && correction.filters[1].q == 1.41f);
    SMOKE_CHECK(correction.filters[4].kind == 0 && correction.filters[4].frequency_hz == 0.0f);

    orca_parametric_equalizer untouched = correction;
    const char unsupported[] = "Filter 1: ON BP Fc 1000 Hz Q 1";
    SMOKE_CHECK(orca_parametric_equalizer_parse_apo(unsupported, sizeof unsupported - 1,
                                                    &untouched) == ORCA_STATUS_UNSUPPORTED);
    const char malformed[] = "Filter 1: ON PK Fc 1000 Hz Gain 30 dB Q 1";
    SMOKE_CHECK(orca_parametric_equalizer_parse_apo(malformed, sizeof malformed - 1,
                                                    &untouched) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(memcmp(&untouched, &correction, sizeof correction) == 0);

    size_t written = 0;
    SMOKE_CHECK(orca_parametric_equalizer_write_apo(&correction, 0, 0, &written) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(written == sizeof parametric_apo_written - 1);
    char text[512];
    SMOKE_CHECK(orca_parametric_equalizer_write_apo(&correction, text, sizeof text, &written) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(written == sizeof parametric_apo_written - 1);
    SMOKE_CHECK(memcmp(text, parametric_apo_written, written) == 0);
    orca_parametric_equalizer reread;
    SMOKE_CHECK(orca_parametric_equalizer_parse_apo(text, written, &reread) == ORCA_STATUS_OK);
    SMOKE_CHECK(memcmp(&reread, &correction, sizeof correction) == 0);

    const float frequencies[3] = {1000.0f, 105.0f, 10000.0f};
    float gains[3] = {0, 0, 0};
    SMOKE_CHECK(orca_parametric_equalizer_response(&correction, 44100, frequencies, gains, 3) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(gains[0] > -4.97f && gains[0] < -4.87f);
    SMOKE_CHECK(gains[1] > -1.56f && gains[1] < -1.46f);
    SMOKE_CHECK(gains[2] > -3.76f && gains[2] < -3.66f);
    SMOKE_CHECK(orca_parametric_equalizer_response(&correction, 0, frequencies, gains, 3) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    struct track_ids playable;
    memset(&playable, 0, sizeof playable);
    SMOKE_CHECK(orca_library_query_tracks(runtime, library, 0, 0, 512, 0, &playable,
                                          collect_playable_ids) == ORCA_STATUS_OK);
    int64_t flac_id = 0;
    for (uint32_t i = 0; i < playable.count && flac_id == 0; i += 1) {
        int is_flac = 0;
        SMOKE_CHECK(orca_library_track_details(runtime, library, playable.ids[i], &is_flac,
                                               capture_is_flac) == ORCA_STATUS_OK);
        if (is_flac) flac_id = playable.ids[i];
    }
    SMOKE_CHECK(flac_id != 0);

    orca_equalizer bass;
    SMOKE_CHECK(orca_equalizer_preset_get(ORCA_EQUALIZER_PRESET_BASS, &bass) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_equalizer(runtime, player, &bass) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_parametric_equalizer(runtime, player, &correction) ==
                ORCA_STATUS_OK);
    orca_parametric_equalizer read_back;
    uint8_t has = 0;
    SMOKE_CHECK(orca_player_parametric_equalizer_get(runtime, player, &read_back, &has) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(has == 1 && memcmp(&read_back, &correction, sizeof correction) == 0);
    orca_equalizer graphic;
    uint8_t enabled = 1;
    SMOKE_CHECK(orca_player_equalizer(runtime, player, &graphic, &enabled) == ORCA_STATUS_OK);
    SMOKE_CHECK(enabled == 0);

    orca_parametric_equalizer rejected = correction;
    rejected.filters[2].q = 0.0f;
    SMOKE_CHECK(orca_player_set_parametric_equalizer(runtime, player, &rejected) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    rejected = correction;
    rejected.filters[2].kind = 9;
    SMOKE_CHECK(orca_player_set_parametric_equalizer(runtime, player, &rejected) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    rejected = correction;
    rejected.count = ORCA_PARAMETRIC_MAX_FILTERS + 1;
    SMOKE_CHECK(orca_player_set_parametric_equalizer(runtime, player, &rejected) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_parametric_equalizer_get(runtime, player, &read_back, &has) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(has == 1 && memcmp(&read_back, &correction, sizeof correction) == 0);

    SMOKE_CHECK(orca_player_set_repeat(runtime, player, ORCA_REPEAT_ONE) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_play_tracks(runtime, player, &flac_id, 1, 0) == ORCA_STATUS_OK);
    struct signal_path_capture path;
    long deadline = now_ms() + 3000;
    int heard = 0;
    while (!heard && now_ms() < deadline) {
        SMOKE_CHECK(wait_for_runtime(runtime, now_ms() + 10) >= 0);
        SMOKE_CHECK(drain_events(runtime) == 0);
        SMOKE_CHECK(read_signal_path(runtime, player, &path) == 0);
        heard = path.view.has_source && path.view.has_output && strcmp(path.codec, "flac") == 0;
    }
    SMOKE_CHECK(heard);
    SMOKE_CHECK(path.view.has_parametric == 1 && path.view.has_equalizer == 0);
    SMOKE_CHECK(memcmp(&path.view.parametric, &correction, sizeof correction) == 0);
    SMOKE_CHECK(has_reason(&path.view, ORCA_SIGNAL_REASON_SAMPLE_PROCESSING));

    SMOKE_CHECK(orca_player_set_equalizer(runtime, player, &bass) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_parametric_equalizer_get(runtime, player, &read_back, &has) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(has == 0 && read_back.count == 0 && read_back.preamp_db == 0.0f);
    SMOKE_CHECK(read_signal_path(runtime, player, &path) == 0);
    SMOKE_CHECK(path.view.has_parametric == 0 && path.view.has_equalizer == 1);

    SMOKE_CHECK(orca_player_set_equalizer(runtime, player, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_parametric_equalizer(runtime, player, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_repeat(runtime, player, ORCA_REPEAT_OFF) == ORCA_STATUS_OK);
    return 0;
}

struct playlist_capture {
    uint32_t count;
    int64_t id;
    uint32_t entries;
    uint32_t available;
    int64_t created_at;
    char name[64];
};

static void capture_playlist(void *context, const orca_playlist_view *playlist) {
    struct playlist_capture *capture = context;
    capture->count += 1;
    capture->id = playlist->id;
    capture->entries = playlist->entries;
    capture->available = playlist->available;
    capture->created_at = playlist->created_at;
    size_t length = playlist->name.length;
    if (length >= sizeof capture->name) length = sizeof capture->name - 1;
    memcpy(capture->name, playlist->name.pointer, length);
    capture->name[length] = 0;
}

struct entry_capture {
    uint32_t count;
    uint32_t positions[8];
    uint8_t has_track[8];
    int64_t track_ids[8];
    char titles[8][128];
};

static void capture_playlist_entry(void *context, const orca_playlist_entry_view *entry) {
    struct entry_capture *capture = context;
    if (capture->count < 8) {
        uint32_t i = capture->count;
        capture->positions[i] = entry->position;
        capture->has_track[i] = entry->has_track;
        capture->track_ids[i] = entry->track.id;
        size_t length = entry->track.title.length;
        if (length >= sizeof capture->titles[0]) length = sizeof capture->titles[0] - 1;
        memcpy(capture->titles[i], entry->track.title.pointer, length);
        capture->titles[i][length] = 0;
    }
    capture->count += 1;
}

struct line_capture {
    uint32_t count;
    char line[256];
};

static void capture_line(void *context, orca_string_view line) {
    struct line_capture *capture = context;
    capture->count += 1;
    size_t length = line.length;
    if (length >= sizeof capture->line) length = sizeof capture->line - 1;
    memcpy(capture->line, line.pointer, length);
    capture->line[length] = 0;
}

static int playlist_titles_are(orca_runtime *runtime, orca_handle library, int64_t playlist_id,
                               const char *const *expected, uint32_t count,
                               struct entry_capture *entries) {
    memset(entries, 0, sizeof *entries);
    SMOKE_CHECK(orca_library_query_playlist_entries(runtime, library, playlist_id, 512, 0,
                                                    entries, capture_playlist_entry) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(entries->count == count);
    for (uint32_t i = 0; i < count; i += 1) {
        SMOKE_CHECK(entries->positions[i] == i && entries->has_track[i] == 1);
        SMOKE_CHECK(strcmp(entries->titles[i], expected[i]) == 0);
    }
    return 0;
}

static int write_text_file(const char *path, const char *text) {
    FILE *file = fopen(path, "w");
    if (file == 0) return -1;
    size_t length = strlen(text);
    int failed = fwrite(text, 1, length, file) != length;
    if (fclose(file) != 0) failed = 1;
    return failed ? -1 : 0;
}

static int read_text_file(const char *path, char *buffer, size_t capacity) {
    FILE *file = fopen(path, "r");
    if (file == 0) return -1;
    size_t length = fread(buffer, 1, capacity - 1, file);
    fclose(file);
    buffer[length] = 0;
    return 0;
}

static int playlist_files_smoke(orca_runtime *runtime, orca_handle library, int64_t playlist_id,
                                const char *directory, uint32_t available) {
    char exported[128];
    char bogus[128];
    char empty[128];
    snprintf(exported, sizeof exported, "%s/Smoke.m3u8", directory);
    snprintf(bogus, sizeof bogus, "%s/bogus.m3u", directory);
    snprintf(empty, sizeof empty, "%s/empty.m3u", directory);

    uint32_t written = 0;
    uint32_t skipped = 9;
    SMOKE_CHECK(orca_library_export_playlist(runtime, library, playlist_id, exported,
                                             strlen(exported), ORCA_PLAYLIST_PATH_ABSOLUTE, 0,
                                             &written, &skipped) == ORCA_STATUS_OK);
    SMOKE_CHECK(written == available && skipped == 0);
    char contents[8192];
    SMOKE_CHECK(read_text_file(exported, contents, sizeof contents) == 0);
    SMOKE_CHECK(strncmp(contents, "#EXTM3U", 7) == 0);
    SMOKE_CHECK(strstr(contents, "fixtures/audio/") != 0);
    SMOKE_CHECK(orca_library_export_playlist(runtime, library, playlist_id, exported,
                                             strlen(exported), ORCA_PLAYLIST_PATH_ABSOLUTE, 0,
                                             &written, &skipped) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(orca_library_export_playlist(runtime, library, playlist_id, exported,
                                             strlen(exported), ORCA_PLAYLIST_PATH_ABSOLUTE, 1,
                                             &written, &skipped) == ORCA_STATUS_OK);
    SMOKE_CHECK(written == available);

    orca_playlist_import imported;
    struct line_capture lines;
    memset(&imported, 0, sizeof imported);
    memset(&lines, 0, sizeof lines);
    SMOKE_CHECK(orca_library_import_playlist(runtime, library, exported, strlen(exported),
                                             "Smoke import", 12, &imported, &lines,
                                             capture_line) == ORCA_STATUS_OK);
    SMOKE_CHECK(imported.playlist_id > 0 && imported.playlist_id != playlist_id);
    SMOKE_CHECK(imported.matched_by_path == written && imported.matched_by_info == 0);
    SMOKE_CHECK(imported.unmatched == 0 && lines.count == 0);
    struct playlist_capture listed;
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_query_playlists(runtime, library, 1, 0, &listed, capture_playlist) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 1 && listed.id == imported.playlist_id);
    SMOKE_CHECK(strcmp(listed.name, "Smoke import") == 0 && listed.entries == written);

    const char *missing_line = "/nonexistent/orca-c-smoke/missing.flac";
    char m3u[256];
    snprintf(m3u, sizeof m3u, "#EXTM3U\n%s\n", missing_line);
    SMOKE_CHECK(write_text_file(bogus, m3u) == 0);
    orca_playlist_import unmatched;
    memset(&unmatched, 0, sizeof unmatched);
    memset(&lines, 0, sizeof lines);
    SMOKE_CHECK(orca_library_import_playlist(runtime, library, bogus, strlen(bogus), 0, 0,
                                             &unmatched, &lines, capture_line) == ORCA_STATUS_OK);
    SMOKE_CHECK(unmatched.unmatched == 1 && unmatched.matched_by_path == 0);
    SMOKE_CHECK(lines.count == 1 && strcmp(lines.line, missing_line) == 0);
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_query_playlists(runtime, library, 1, 0, &listed, capture_playlist) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(listed.id == unmatched.playlist_id && strcmp(listed.name, "bogus") == 0);
    SMOKE_CHECK(listed.entries == 0);

    SMOKE_CHECK(write_text_file(empty, "#EXTM3U\n") == 0);
    SMOKE_CHECK(orca_library_import_playlist(runtime, library, empty, strlen(empty), 0, 0,
                                             &unmatched, 0, 0) == ORCA_STATUS_INVALID_STATE);

    SMOKE_CHECK(orca_library_delete_playlist(runtime, library, imported.playlist_id) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_delete_playlist(runtime, library, unmatched.playlist_id) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(unlink(exported) == 0 && unlink(bogus) == 0 && unlink(empty) == 0);
    return 0;
}

static int playlist_play_smoke(orca_runtime *runtime, orca_handle player, int64_t playlist_id,
                               int64_t first_track_id) {
    SMOKE_CHECK(orca_player_set_repeat(runtime, player, ORCA_REPEAT_ONE) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_play_playlist(runtime, player, playlist_id, 0) == ORCA_STATUS_OK);
    orca_player_status status;
    struct now_playing_capture playing;
    int reflected = 0;
    long deadline = now_ms() + 3000;
    while (!reflected && now_ms() < deadline) {
        SMOKE_CHECK(wait_for_runtime(runtime, now_ms() + 10) >= 0);
        SMOKE_CHECK(drain_events(runtime) == 0);
        SMOKE_CHECK(orca_player_status_get(runtime, player, &status) == ORCA_STATUS_OK);
        memset(&playing, 0, sizeof playing);
        SMOKE_CHECK(orca_player_now_playing(runtime, player, &playing, capture_now_playing) ==
                    ORCA_STATUS_OK);
        reflected = status.queue_index == 0 && status.queue_length == 4 &&
                    playing.count == 1 && playing.track_id == first_track_id;
    }
    SMOKE_CHECK(reflected);
    SMOKE_CHECK(orca_player_play_playlist(runtime, player, playlist_id, 4) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_stop(runtime, player) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_repeat(runtime, player, ORCA_REPEAT_OFF) == ORCA_STATUS_OK);
    return 0;
}

struct titled_tracks {
    uint32_t count;
    int64_t ids[64];
    char titles[64][128];
};

static void collect_titled(void *context, const orca_track_view *track) {
    struct titled_tracks *capture = context;
    if (!track->has_file || capture->count >= 64) return;
    size_t length = track->title.length;
    if (length >= sizeof capture->titles[0]) length = sizeof capture->titles[0] - 1;
    memcpy(capture->titles[capture->count], track->title.pointer, length);
    capture->titles[capture->count][length] = 0;
    capture->ids[capture->count] = track->id;
    capture->count += 1;
}

struct playlist_facts_capture {
    uint32_t count;
    int64_t id;
    uint32_t entries;
    uint8_t pinned;
    uint8_t loved;
    uint8_t kind;
    uint8_t tag_count;
    char description[64];
};

static void capture_playlist_facts(void *context, const orca_playlist_view *playlist,
                                   const orca_playlist_facts_view *facts) {
    struct playlist_facts_capture *capture = context;
    capture->count += 1;
    capture->id = playlist->id;
    capture->entries = playlist->entries;
    capture->pinned = facts->pinned;
    capture->loved = facts->loved;
    capture->kind = facts->kind;
    capture->tag_count = facts->tag_count;
    size_t length = facts->description.length;
    if (length >= sizeof capture->description) length = sizeof capture->description - 1;
    memcpy(capture->description, facts->description.pointer, length);
    capture->description[length] = 0;
}

struct text_capture {
    uint32_t count;
    char values[8][64];
};

static void capture_text(void *context, const orca_string_view *value) {
    struct text_capture *capture = context;
    if (capture->count < 8 && value->length < sizeof capture->values[0]) {
        memcpy(capture->values[capture->count], value->pointer, value->length);
        capture->values[capture->count][value->length] = 0;
    }
    capture->count += 1;
}

static int playlist_metadata_smoke(orca_runtime *runtime, orca_handle library, int64_t playlist_id) {
    orca_string_view tags[2] = {{"focus", 5}, {"lofi", 4}};
    orca_playlist_update update;
    memset(&update, 0, sizeof update);
    update.description = (orca_string_view){"For work", 8};
    update.tags = tags;
    update.tag_count = 2;
    update.has_description = 1;
    update.has_pinned = 1;
    update.pinned = 1;
    update.has_loved = 1;
    update.loved = 1;
    update.has_tags = 1;
    SMOKE_CHECK(orca_library_update_playlist(runtime, library, playlist_id, &update) ==
                ORCA_STATUS_OK);

    orca_playlist_query query;
    memset(&query, 0, sizeof query);
    query.limit = 512;
    query.sort = ORCA_PLAYLIST_SORT_RECENTLY_UPDATED;
    query.pinned_only = 1;
    struct playlist_facts_capture listed;
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_query_playlists_v2(runtime, library, &query, &listed,
                                                capture_playlist_facts) == ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 1 && listed.id == playlist_id && listed.pinned == 1);
    SMOKE_CHECK(listed.loved == 1 && listed.kind == ORCA_PLAYLIST_KIND_MANUAL);
    SMOKE_CHECK(listed.tag_count == 2 && strcmp(listed.description, "For work") == 0);
    uint64_t count = 0;
    SMOKE_CHECK(orca_library_playlist_count(runtime, library, &query, &count) == ORCA_STATUS_OK);
    SMOKE_CHECK(count == 1);

    struct text_capture texts;
    memset(&texts, 0, sizeof texts);
    SMOKE_CHECK(orca_library_playlist_tags(runtime, library, playlist_id, &texts, capture_text) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(texts.count == 2 && strcmp(texts.values[0], "focus") == 0 &&
                strcmp(texts.values[1], "lofi") == 0);
    memset(&texts, 0, sizeof texts);
    SMOKE_CHECK(orca_library_playlist_genres(runtime, library, playlist_id, &texts, capture_text) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(texts.count <= 3);

    const char *rules = "{\"v\":1,\"rules\":[{\"field\":\"title\",\"op\":\"is_set\"}],"
                        "\"sort\":{\"field\":\"title\"},\"limit\":3}";
    SMOKE_CHECK(orca_library_smart_playlist_count(runtime, library, rules, strlen(rules), &count) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(count == 3);
    const char *unknown = "{\"v\":1,\"rules\":[{\"field\":\"mood\",\"op\":\"is_set\"}]}";
    int64_t smart_id = 0;
    SMOKE_CHECK(orca_library_create_smart_playlist(runtime, library, "Smart smoke", 11, unknown,
                                                   strlen(unknown), &smart_id) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_create_smart_playlist(runtime, library, "Smart smoke", 11, rules,
                                                   strlen(rules), &smart_id) == ORCA_STATUS_OK);
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_playlist_get(runtime, library, smart_id, &listed,
                                          capture_playlist_facts) == ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 1 && listed.kind == ORCA_PLAYLIST_KIND_SMART && listed.entries == 3);
    struct entry_capture entries;
    memset(&entries, 0, sizeof entries);
    SMOKE_CHECK(orca_library_query_playlist_entries(runtime, library, smart_id, 8, 0, &entries,
                                                    capture_playlist_entry) == ORCA_STATUS_OK);
    SMOKE_CHECK(entries.count == 3 && entries.has_track[0] && entries.has_track[2]);
    memset(&texts, 0, sizeof texts);
    SMOKE_CHECK(orca_library_smart_playlist_rules(runtime, library, smart_id, &texts,
                                                  capture_text) == ORCA_STATUS_OK);
    SMOKE_CHECK(texts.count == 1);
    SMOKE_CHECK(orca_library_smart_playlist_rules(runtime, library, playlist_id, &texts,
                                                  capture_text) == ORCA_STATUS_INVALID_STATE);
    const char *all = "{\"v\":1,\"rules\":[{\"field\":\"title\",\"op\":\"is_set\"}],\"limit\":1}";
    SMOKE_CHECK(orca_library_set_smart_playlist_rules(runtime, library, smart_id, all,
                                                      strlen(all)) == ORCA_STATUS_OK);
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_playlist_get(runtime, library, smart_id, &listed,
                                          capture_playlist_facts) == ORCA_STATUS_OK);
    SMOKE_CHECK(listed.entries == 1);
    int64_t one = entries.track_ids[0];
    orca_change_count change;
    SMOKE_CHECK(orca_library_playlist_insert(runtime, library, smart_id, &one, 1, -1, &change) ==
                ORCA_STATUS_INVALID_STATE);

    query.pinned_only = 0;
    query.has_kind = 1;
    query.kind = ORCA_PLAYLIST_KIND_SMART;
    SMOKE_CHECK(orca_library_playlist_count(runtime, library, &query, &count) == ORCA_STATUS_OK);
    SMOKE_CHECK(count == 1);
    SMOKE_CHECK(orca_library_delete_playlist(runtime, library, smart_id) == ORCA_STATUS_OK);
    return 0;
}
struct folder_capture {
    uint32_t count;
    uint32_t folders;
    uint32_t images;
    uint32_t tracks;
    int64_t track_ids[512];
    char first_name[64];
};

static void capture_folder_entry(void *context, const orca_folder_entry_view *entry) {
    struct folder_capture *capture = context;
    if (capture->count == 0) {
        size_t length = entry->name.length < 63 ? entry->name.length : 63;
        memcpy(capture->first_name, entry->name.pointer, length);
        capture->first_name[length] = 0;
    }
    capture->count += 1;
    if (entry->kind == ORCA_FOLDER_ENTRY_KIND_FOLDER) capture->folders += 1;
    if (entry->kind == ORCA_FOLDER_ENTRY_KIND_IMAGE) capture->images += 1;
    if (entry->kind != ORCA_FOLDER_ENTRY_KIND_FILE || !entry->has_file_id || entry->file_count != 1)
        return;
    if (!entry->has_track_id) return;
    for (uint32_t i = 0; i < capture->tracks; i += 1)
        if (capture->track_ids[i] == entry->track_id) return;
    if (capture->tracks < 512) capture->track_ids[capture->tracks++] = entry->track_id;
}

static int folder_smoke(orca_runtime *runtime, orca_handle library, orca_handle player,
                        int64_t root_id) {
    static struct folder_capture root;
    memset(&root, 0, sizeof root);
    SMOKE_CHECK(orca_library_query_folder(runtime, library, root_id, "", 0, 512, 0, &root,
                                          capture_folder_entry) == ORCA_STATUS_OK);
    SMOKE_CHECK(root.count > 2 && root.folders == 0 && root.images == 0 && root.tracks > 2);
    SMOKE_CHECK(strcmp(root.first_name, "cbr-noxing-reference.mp3") == 0);

    static struct folder_capture paged;
    memset(&paged, 0, sizeof paged);
    SMOKE_CHECK(orca_library_query_folder(runtime, library, root_id, 0, 0, 1, 1, &paged,
                                          capture_folder_entry) == ORCA_STATUS_OK);
    SMOKE_CHECK(paged.count == 1 && strcmp(paged.first_name, "cbr-noxing-reference.mp3") != 0);
    SMOKE_CHECK(orca_library_query_folder(runtime, library, root_id, "", 0, 0, 0, &paged,
                                          capture_folder_entry) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_folder(runtime, library, root_id, "../x", 4, 512, 0, &paged,
                                          capture_folder_entry) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_folder(runtime, library, 999999, "", 0, 512, 0, &paged,
                                          capture_folder_entry) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_query_folder(runtime, library, root_id, "", 0, 512, 0, &paged, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_player_play_folder(runtime, player, root_id, "none", 4, 0) ==
                ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(orca_player_play_folder(runtime, player, root_id, "/abs", 4, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_player_play_folder(runtime, player, root_id, "", 0, 0) == ORCA_STATUS_OK);
    orca_player_status status;
    SMOKE_CHECK(orca_player_status_get(runtime, player, &status) == ORCA_STATUS_OK);
    SMOKE_CHECK(status.queue_length == root.tracks);
    SMOKE_CHECK(orca_player_clear_queue(runtime, player) == ORCA_STATUS_OK);
    return 0;
}

static int playlist_smoke(orca_runtime *runtime, orca_handle library, orca_handle player) {
    static struct titled_tracks playable;
    memset(&playable, 0, sizeof playable);
    SMOKE_CHECK(orca_library_query_tracks(runtime, library, 0, 0, 512, 0, &playable,
                                          collect_titled) == ORCA_STATUS_OK);
    int64_t picked[4];
    const char *titles[4];
    uint32_t distinct = 0;
    for (uint32_t i = 0; i < playable.count && distinct < 4; i += 1) {
        int seen = 0;
        for (uint32_t j = 0; j < distinct; j += 1)
            if (strcmp(titles[j], playable.titles[i]) == 0) seen = 1;
        if (seen || playable.titles[i][0] == 0) continue;
        picked[distinct] = playable.ids[i];
        titles[distinct] = playable.titles[i];
        distinct += 1;
    }
    SMOKE_CHECK(distinct == 4);

    int64_t playlist_id = 0;
    SMOKE_CHECK(orca_library_create_playlist(runtime, library, "Smoke", 5, &playlist_id) ==
                ORCA_STATUS_OK);
    struct playlist_capture listed;
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_query_playlists(runtime, library, 512, 0, &listed, capture_playlist) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 1 && listed.id == playlist_id && listed.entries == 0);
    SMOKE_CHECK(strcmp(listed.name, "Smoke") == 0 && listed.created_at > 1600000000);
    SMOKE_CHECK(orca_library_create_playlist(runtime, library, "Smoke", 5, &playlist_id) ==
                ORCA_STATUS_INVALID_STATE);

    orca_change_count change;
    SMOKE_CHECK(orca_library_playlist_insert(runtime, library, playlist_id, &picked[1], 3, -1,
                                             &change) == ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 3 && change.skipped == 0);
    int64_t with_unknown[2] = {picked[0], 999999999};
    SMOKE_CHECK(orca_library_playlist_insert(runtime, library, playlist_id, with_unknown, 2, 0,
                                             &change) == ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1 && change.skipped == 1);
    struct entry_capture entries;
    const char *inserted[4] = {titles[0], titles[1], titles[2], titles[3]};
    SMOKE_CHECK(playlist_titles_are(runtime, library, playlist_id, inserted, 4, &entries) == 0);
    int64_t first_track_id = entries.track_ids[0];

    SMOKE_CHECK(orca_library_playlist_move(runtime, library, playlist_id, 0, 3) == ORCA_STATUS_OK);
    const char *moved[4] = {titles[1], titles[2], titles[3], titles[0]};
    SMOKE_CHECK(playlist_titles_are(runtime, library, playlist_id, moved, 4, &entries) == 0);
    SMOKE_CHECK(orca_library_playlist_move(runtime, library, playlist_id, 3, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(playlist_titles_are(runtime, library, playlist_id, inserted, 4, &entries) == 0);
    SMOKE_CHECK(orca_library_playlist_move(runtime, library, playlist_id, 0, 4) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_library_playlist_insert(runtime, library, playlist_id, &picked[0], 1, 4,
                                             &change) == ORCA_STATUS_OK);
    uint32_t removed = 0;
    uint32_t last[2] = {4, 4};
    SMOKE_CHECK(orca_library_playlist_remove(runtime, library, playlist_id, last, 2, &removed) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(removed == 1);
    SMOKE_CHECK(playlist_titles_are(runtime, library, playlist_id, inserted, 4, &entries) == 0);

    SMOKE_CHECK(orca_library_rename_playlist(runtime, library, playlist_id, " Smoke renamed ", 15) ==
                ORCA_STATUS_OK);
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_query_playlists(runtime, library, 512, 0, &listed, capture_playlist) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 1 && strcmp(listed.name, "Smoke renamed") == 0);
    SMOKE_CHECK(listed.entries == 4 && listed.available == 4);
    SMOKE_CHECK(playlist_metadata_smoke(runtime, library, playlist_id) == 0);

    char directory[] = ".zig-cache/tmp/orca-c-smoke-playlist-XXXXXX";
    SMOKE_CHECK(mkdir(".zig-cache/tmp", 0700) == 0 || errno == EEXIST);
    SMOKE_CHECK(mkdtemp(directory) != 0);
    int files_failed = playlist_files_smoke(runtime, library, playlist_id, directory, 4);
    rmdir(directory);
    SMOKE_CHECK(files_failed == 0);

    SMOKE_CHECK(playlist_play_smoke(runtime, player, playlist_id, first_track_id) == 0);

    SMOKE_CHECK(orca_library_delete_playlist(runtime, library, playlist_id) == ORCA_STATUS_OK);
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_query_playlists(runtime, library, 512, 0, &listed, capture_playlist) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 0);
    SMOKE_CHECK(orca_library_delete_playlist(runtime, library, playlist_id) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_query_playlist_entries(runtime, library, playlist_id, 8, 0, &entries,
                                                    capture_playlist_entry) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_player_play_playlist(runtime, player, playlist_id, 0) ==
                ORCA_STATUS_NOT_FOUND);
    return 0;
}

struct image_capture {
    uint32_t count;
    size_t length;
    int magic_matches;
    uint8_t kind;
};

static int image_magic_matches(const orca_image_view *image) {
    static const uint8_t png[4] = {0x89, 'P', 'N', 'G'};
    static const uint8_t jpeg[3] = {0xff, 0xd8, 0xff};
    if (image->mime_type.length == 9 && memcmp(image->mime_type.pointer, "image/png", 9) == 0)
        return image->length >= 4 && memcmp(image->bytes, png, 4) == 0;
    if (image->mime_type.length == 10 && memcmp(image->mime_type.pointer, "image/jpeg", 10) == 0)
        return image->length >= 3 && memcmp(image->bytes, jpeg, 3) == 0;
    return 0;
}

static void capture_image(void *context, const orca_image_view *image) {
    struct image_capture *capture = context;
    capture->count += 1;
    capture->length = image->length;
    capture->magic_matches = image_magic_matches(image);
    capture->kind = image->kind;
}

struct artwork_result_capture {
    uint32_t count;
    uint64_t request;
    int64_t subject_id;
    uint8_t subject;
    uint8_t has_image;
    int magic_matches;
};

static void capture_artwork_result(void *context, const orca_artwork_result_view *result) {
    struct artwork_result_capture *capture = context;
    capture->count += 1;
    capture->request = result->request;
    capture->subject_id = result->subject_id;
    capture->subject = result->subject;
    capture->has_image = result->has_image;
    capture->magic_matches = result->has_image && image_magic_matches(&result->image);
}

static void capture_release_id(void *context, const orca_track_summary_view *summary) {
    int64_t *release_id = context;
    *release_id = summary->has_release_id ? summary->release_id : -1;
}

static int64_t titled_track(const struct titled_tracks *tracks, const char *title) {
    for (uint32_t i = 0; i < tracks->count; i += 1)
        if (strcmp(tracks->titles[i], title) == 0) return tracks->ids[i];
    return 0;
}

struct health_capture {
    uint32_t count;
    uint32_t consistent;
    int64_t first_file_id;
    uint8_t first_kind;
    uint8_t first_action;
    int64_t watch_file_id;
    uint8_t watch_kind;
    uint32_t listed;
};

static int health_action_fits(const orca_health_item_view *item) {
    switch (item->kind) {
    case ORCA_HEALTH_ISSUE_KIND_MISSING_METADATA:
    case ORCA_HEALTH_ISSUE_KIND_MISSING_TRACK_NUMBER:
    case ORCA_HEALTH_ISSUE_KIND_ALBUM_ARTIST_ANOMALY:
        return item->action == ORCA_HEALTH_ACTION_MATCH_OR_EDIT;
    case ORCA_HEALTH_ISSUE_KIND_ARTWORK_PROBLEM:
        return item->action == ORCA_HEALTH_ACTION_MATCH_OR_EDIT ||
               item->action == ORCA_HEALTH_ACTION_FETCH_COVER_ART;
    case ORCA_HEALTH_ISSUE_KIND_EXACT_DUPLICATE:
    case ORCA_HEALTH_ISSUE_KIND_LIKELY_DUPLICATE:
        return item->action == ORCA_HEALTH_ACTION_COMPARE_DUPLICATE;
    case ORCA_HEALTH_ISSUE_KIND_RECORDING_MISMATCH:
        return item->action == ORCA_HEALTH_ACTION_REVIEW_CORRECTION;
    default:
        return item->action == ORCA_HEALTH_ACTION_REVEAL_FILE;
    }
}

static void collect_health_item(void *context, const orca_health_item_view *item) {
    struct health_capture *capture = context;
    if (capture->count == 0) {
        capture->first_file_id = item->file_id;
        capture->first_kind = item->kind;
        capture->first_action = item->action;
    }
    if (item->file_id > 0 && item->severity <= ORCA_HEALTH_SEVERITY_ERROR &&
        health_action_fits(item) && item->has_track_id == (item->track_id > 0) &&
        item->has_related_file_id == (item->related_file_id > 0))
        capture->consistent += 1;
    if (item->file_id == capture->watch_file_id && item->kind == capture->watch_kind)
        capture->listed += 1;
    capture->count += 1;
}

struct health_file_capture {
    uint32_t count;
    orca_health_file_view view;
    char codec[16];
    char path[512];
};

static void capture_health_file(void *context, const orca_health_file_view *file) {
    struct health_file_capture *capture = context;
    capture->count += 1;
    capture->view = *file;
    size_t codec = file->codec.length < sizeof capture->codec - 1 ? file->codec.length
                                                                  : sizeof capture->codec - 1;
    memcpy(capture->codec, file->codec.pointer, codec);
    capture->codec[codec] = 0;
    size_t path = file->path.length < sizeof capture->path - 1 ? file->path.length
                                                               : sizeof capture->path - 1;
    memcpy(capture->path, file->path.pointer, path);
    capture->path[path] = 0;
}

static int health_items_collect(orca_runtime *runtime, orca_handle library,
                                struct health_capture *capture, int64_t watch_file_id,
                                uint8_t watch_kind) {
    memset(capture, 0, sizeof *capture);
    capture->watch_file_id = watch_file_id;
    capture->watch_kind = watch_kind;
    SMOKE_CHECK(orca_library_query_health_items(runtime, library, 512, 0, capture,
                                                collect_health_item) == ORCA_STATUS_OK);
    return 0;
}

struct health_summary_capture {
    uint32_t kinds;
    uint64_t total;
    uint64_t watch_count;
    uint8_t watch_kind;
    uint32_t ordered;
    uint8_t previous_severity;
};

static void collect_health_summary(void *context, const orca_health_kind_summary_view *summary) {
    struct health_summary_capture *capture = context;
    if (capture->kinds == 0 || summary->severity <= capture->previous_severity)
        capture->ordered += 1;
    capture->previous_severity = summary->severity;
    if (summary->kind == capture->watch_kind) capture->watch_count = summary->count;
    capture->total += summary->count;
    capture->kinds += 1;
}

static int health_summary_collect(orca_runtime *runtime, orca_handle library,
                                  struct health_summary_capture *capture, uint8_t watch_kind) {
    memset(capture, 0, sizeof *capture);
    capture->watch_kind = watch_kind;
    SMOKE_CHECK(orca_library_health_summary(runtime, library, capture,
                                            collect_health_summary) == ORCA_STATUS_OK);
    SMOKE_CHECK(capture->ordered == capture->kinds);
    return 0;
}

struct health_summary_v2_capture {
    uint64_t total;
    uint64_t files;
    uint32_t consistent;
    uint32_t kinds;
};

static void collect_health_summary_v2(void *context,
                                      const orca_health_kind_summary_view_v2 *summary) {
    struct health_summary_v2_capture *capture = context;
    if (summary->files == summary->base.count) capture->consistent += 1;
    capture->total += summary->base.count;
    capture->files += summary->files;
    capture->kinds += 1;
}

static int health_summary_v2_smoke(orca_runtime *runtime, orca_handle library,
                                   const struct health_summary_capture *summary) {
    struct health_summary_v2_capture sized;
    memset(&sized, 0, sizeof sized);
    SMOKE_CHECK(orca_library_health_summary_v2(runtime, library, &sized,
                                               collect_health_summary_v2) == ORCA_STATUS_OK);
    SMOKE_CHECK(sized.kinds == summary->kinds && sized.total == summary->total);
    SMOKE_CHECK(sized.files == summary->total && sized.consistent == sized.kinds);
    SMOKE_CHECK(orca_library_health_summary_v2(runtime, library, &sized, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    return 0;
}

static int library_stats_smoke(orca_runtime *runtime, orca_handle library) {
    orca_library_stats_view stats;
    SMOKE_CHECK(orca_library_stats(runtime, library, 0) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_stats(runtime, library, &stats) == ORCA_STATUS_OK);
    uint64_t artists = 0, releases = 0, tracks = 0;
    SMOKE_CHECK(orca_library_artist_count(runtime, library, &artists) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_release_count(runtime, library, &releases) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_track_count(runtime, library, &tracks) == ORCA_STATUS_OK);
    SMOKE_CHECK(stats.artists == artists && stats.releases == releases && stats.tracks == tracks);
    SMOKE_CHECK(stats.files > 0 && stats.total_bytes > 0 && stats.total_duration_ms > 0);
    SMOKE_CHECK(stats.has_last_scan_finished_at == 1 && stats.last_scan_finished_at > 0);
    SMOKE_CHECK(stats.has_last_analysis_at == 1 || stats.last_analysis_at == 0);
    return 0;
}

struct provider_source_capture {
    size_t count;
    int first_is_musicbrainz;
};

static void collect_provider_source(void *context, const orca_provider_source_view *source) {
    struct provider_source_capture *capture = context;
    if (capture->count == 0) {
        static const char expected[] = "MusicBrainz";
        capture->first_is_musicbrainz = source->id == ORCA_PROVIDER_SOURCE_MUSICBRAINZ &&
                                        source->name.length == sizeof expected - 1 &&
                                        memcmp(source->name.pointer, expected, sizeof expected - 1) == 0;
    }
    capture->count += 1;
}

static int provider_sources_smoke(orca_runtime *runtime) {
    struct provider_source_capture capture;
    memset(&capture, 0, sizeof capture);
    SMOKE_CHECK(orca_provider_sources(runtime, &capture, 0) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_provider_sources(runtime, &capture, collect_provider_source) == ORCA_STATUS_OK);
    SMOKE_CHECK(capture.count == 9 && capture.first_is_musicbrainz);
    return 0;
}

static int health_kind_collect(orca_runtime *runtime, orca_handle library,
                               struct health_capture *capture, uint8_t kind,
                               int64_t watch_file_id) {
    memset(capture, 0, sizeof *capture);
    capture->watch_file_id = watch_file_id;
    capture->watch_kind = kind;
    SMOKE_CHECK(orca_library_query_health_items_of_kind(runtime, library, kind, 512, 0, capture,
                                                        collect_health_item) == ORCA_STATUS_OK);
    return 0;
}

static int health_kind_smoke(orca_runtime *runtime, orca_handle library, uint64_t total,
                             int64_t file_id, uint8_t kind) {
    struct health_summary_capture summary;
    SMOKE_CHECK(health_summary_collect(runtime, library, &summary, kind) == 0);
    SMOKE_CHECK(summary.total == total && summary.kinds > 0 && summary.watch_count > 0);
    SMOKE_CHECK(health_summary_v2_smoke(runtime, library, &summary) == 0);
    uint64_t of_kind = summary.watch_count;

    struct health_capture items;
    SMOKE_CHECK(health_kind_collect(runtime, library, &items, kind, file_id) == 0);
    SMOKE_CHECK(items.count == of_kind && items.consistent == items.count);
    SMOKE_CHECK(items.listed == 1 && items.first_kind == kind);

    SMOKE_CHECK(orca_library_query_health_items_of_kind(runtime, library, 200, 1, 0, &items,
                                                        collect_health_item) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_health_items_of_kind(runtime, library, kind, 0, 0, &items,
                                                        collect_health_item) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_health_items_of_kind(runtime, library, kind, 513, 0, &items,
                                                        collect_health_item) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_health_items_of_kind(runtime, library, kind, 1, 0, &items,
                                                        0) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_health_summary(runtime, library, &summary, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_library_dismiss_health_issue(runtime, library, file_id, kind) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(health_summary_collect(runtime, library, &summary, kind) == 0);
    SMOKE_CHECK(summary.total == total - 1 && summary.watch_count == of_kind - 1);
    SMOKE_CHECK(health_kind_collect(runtime, library, &items, kind, file_id) == 0);
    SMOKE_CHECK(items.count == of_kind - 1 && items.listed == 0);

    SMOKE_CHECK(orca_library_restore_health_issue(runtime, library, file_id, kind) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(health_summary_collect(runtime, library, &summary, kind) == 0);
    SMOKE_CHECK(summary.total == total && summary.watch_count == of_kind);
    SMOKE_CHECK(health_kind_collect(runtime, library, &items, kind, file_id) == 0);
    SMOKE_CHECK(items.count == of_kind && items.listed == 1);
    return 0;
}

static int health_smoke(orca_runtime *runtime, orca_handle library) {
    uint64_t total = 0;
    SMOKE_CHECK(orca_library_health_issue_count(runtime, library, &total) == ORCA_STATUS_OK);
    SMOKE_CHECK(total > 0 && total <= 512);

    struct health_capture items;
    SMOKE_CHECK(health_items_collect(runtime, library, &items, 0, 0) == 0);
    SMOKE_CHECK(items.count == total);
    SMOKE_CHECK(items.consistent == items.count);
    int64_t file_id = items.first_file_id;
    uint8_t kind = items.first_kind;
    SMOKE_CHECK(file_id > 0);

    SMOKE_CHECK(orca_library_query_health_items(runtime, library, 0, 0, &items,
                                                collect_health_item) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_health_items(runtime, library, 513, 0, &items,
                                                collect_health_item) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_health_items(runtime, library, 1, 0, &items, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_library_dismiss_health_issue(runtime, library, file_id, 200) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_restore_health_issue(runtime, library, file_id, 200) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_dismiss_health_issue(runtime, library, 999999, kind) ==
                ORCA_STATUS_NOT_FOUND);

    SMOKE_CHECK(orca_library_dismiss_health_issue(runtime, library, file_id, kind) ==
                ORCA_STATUS_OK);
    uint64_t after = 0;
    SMOKE_CHECK(orca_library_health_issue_count(runtime, library, &after) == ORCA_STATUS_OK);
    SMOKE_CHECK(after == total - 1);
    SMOKE_CHECK(health_items_collect(runtime, library, &items, file_id, kind) == 0);
    SMOKE_CHECK(items.count == total - 1 && items.listed == 0);

    SMOKE_CHECK(orca_library_restore_health_issue(runtime, library, file_id, kind) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_health_issue_count(runtime, library, &after) == ORCA_STATUS_OK);
    SMOKE_CHECK(after == total);
    SMOKE_CHECK(health_items_collect(runtime, library, &items, file_id, kind) == 0);
    SMOKE_CHECK(items.count == total && items.listed == 1);

    SMOKE_CHECK(health_kind_smoke(runtime, library, total, file_id, kind) == 0);

    struct health_file_capture file;
    memset(&file, 0, sizeof file);
    SMOKE_CHECK(orca_library_health_file(runtime, library, file_id, &file,
                                         capture_health_file) == ORCA_STATUS_OK);
    SMOKE_CHECK(file.count == 1 && file.view.file_id == file_id);
    SMOKE_CHECK(file.view.has_path == 1 && file.view.missing == 0 && file.path[0] != 0);
    SMOKE_CHECK(file.codec[0] != 0);
    SMOKE_CHECK(file.view.has_size_bytes == 1 && file.view.size_bytes > 0);

    memset(&file, 0, sizeof file);
    SMOKE_CHECK(orca_library_health_file(runtime, library, 999999, &file,
                                         capture_health_file) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(file.count == 0);
    SMOKE_CHECK(orca_library_health_file(runtime, library, file_id, &file, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    return 0;
}

static int artwork_smoke(orca_runtime *runtime, orca_handle library) {
    static struct titled_tracks tracks;
    memset(&tracks, 0, sizeof tracks);
    SMOKE_CHECK(orca_library_query_tracks(runtime, library, 0, 0, 512, 0, &tracks,
                                          collect_titled) == ORCA_STATUS_OK);
    int64_t covered = titled_track(&tracks, "covered-reference");
    int64_t coverless = titled_track(&tracks, "WAV Reference");
    SMOKE_CHECK(covered > 0 && coverless > 0);

    struct image_capture image;
    memset(&image, 0, sizeof image);
    SMOKE_CHECK(orca_library_track_artwork(runtime, library, covered, &image, capture_image) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(image.count == 1 && image.length > 0 && image.magic_matches);
    SMOKE_CHECK(image.kind == ORCA_ARTWORK_KIND_FRONT_COVER);
    memset(&image, 0, sizeof image);
    SMOKE_CHECK(orca_library_track_artwork(runtime, library, coverless, &image, capture_image) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(image.count == 0);

    int64_t covered_release = -1;
    SMOKE_CHECK(orca_library_track_get(runtime, library, covered, &covered_release,
                                       capture_release_id) == ORCA_STATUS_OK);
    SMOKE_CHECK(covered_release > 0);
    SMOKE_CHECK(orca_library_release_artwork(runtime, library, covered_release, &image,
                                             capture_image) == ORCA_STATUS_OK);
    SMOKE_CHECK(image.count == 1 && image.length > 0 && image.magic_matches);

    uint64_t covered_request = 0;
    uint64_t coverless_request = 0;
    SMOKE_CHECK(orca_library_request_artwork(runtime, library, ORCA_ARTWORK_SUBJECT_TRACK, covered,
                                             &covered_request) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_request_artwork(runtime, library, ORCA_ARTWORK_SUBJECT_TRACK,
                                             coverless, &coverless_request) == ORCA_STATUS_OK);
    SMOKE_CHECK(covered_request != coverless_request);
    SMOKE_CHECK(orca_library_request_artwork(runtime, library, 3, covered, &covered_request) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_cancel_artwork(runtime, library, 999999) == ORCA_STATUS_OK);

    struct artwork_result_capture results[2];
    memset(results, 0, sizeof results);
    uint32_t taken = 0;
    long deadline = now_ms() + 5000;
    while (taken < 2) {
        orca_status status = orca_library_take_artwork(runtime, library, &results[taken],
                                                       capture_artwork_result);
        if (status == ORCA_STATUS_OK) {
            taken += 1;
            continue;
        }
        SMOKE_CHECK(status == ORCA_STATUS_NOT_FOUND);
        SMOKE_CHECK(now_ms() < deadline);
        SMOKE_CHECK(wait_for_runtime(runtime, deadline) >= 0);
        SMOKE_CHECK(drain_events(runtime) == 0);
    }
    struct artwork_result_capture extra;
    memset(&extra, 0, sizeof extra);
    SMOKE_CHECK(orca_library_take_artwork(runtime, library, &extra, capture_artwork_result) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(extra.count == 0);

    const struct artwork_result_capture *with_cover =
        results[0].request == covered_request ? &results[0] : &results[1];
    const struct artwork_result_capture *without_cover =
        results[0].request == covered_request ? &results[1] : &results[0];
    SMOKE_CHECK(with_cover->request == covered_request && with_cover->count == 1);
    SMOKE_CHECK(with_cover->has_image == 1 && with_cover->magic_matches);
    SMOKE_CHECK(with_cover->subject == ORCA_ARTWORK_SUBJECT_TRACK &&
                with_cover->subject_id == covered);
    SMOKE_CHECK(without_cover->request == coverless_request && without_cover->count == 1);
    SMOKE_CHECK(without_cover->has_image == 0 && without_cover->subject_id == coverless);
    return 0;
}

struct lyrics_capture {
    uint32_t count;
    uint8_t source;
    uint8_t kind;
    size_t line_count;
    int64_t first_start_ms;
    int first_text_matches;
};

static void capture_lyrics(void *context, const orca_lyrics_view *lyrics) {
    static const char first_synced[] = "One second in";
    struct lyrics_capture *capture = context;
    capture->count += 1;
    capture->source = lyrics->source;
    capture->kind = lyrics->kind;
    capture->line_count = lyrics->line_count;
    if (lyrics->line_count == 0) return;
    capture->first_start_ms = lyrics->lines[0].start_ms;
    capture->first_text_matches =
        lyrics->lines[0].text.length == sizeof first_synced - 1 &&
        memcmp(lyrics->lines[0].text.pointer, first_synced, sizeof first_synced - 1) == 0;
}

static int read_track_lyrics(orca_runtime *runtime, orca_handle library, int64_t track_id,
                             struct lyrics_capture *capture) {
    orca_handle job;
    uint8_t state = ORCA_JOB_RUNNING;
    uint8_t outcome = ORCA_LYRICS_OUTCOME_NOT_REQUESTED;
    SMOKE_CHECK(orca_library_start_lyrics(runtime, library, track_id, 0, &job) == ORCA_STATUS_OK);
    SMOKE_CHECK(await_job(runtime, job, &state, 0, 60000) == 1 && state == ORCA_JOB_SUCCEEDED);
    SMOKE_CHECK(orca_job_lyrics_outcome(runtime, job, &outcome) == ORCA_STATUS_OK);
    SMOKE_CHECK(outcome == ORCA_LYRICS_OUTCOME_LOCAL);
    memset(capture, 0, sizeof *capture);
    SMOKE_CHECK(orca_job_lyrics(runtime, job, capture, capture_lyrics) == ORCA_STATUS_OK);
    SMOKE_CHECK(capture->count == 1);
    struct lyrics_capture again;
    memset(&again, 0, sizeof again);
    SMOKE_CHECK(orca_job_lyrics(runtime, job, &again, capture_lyrics) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(again.count == 0);
    return 0;
}

static int lyrics_smoke(orca_runtime *runtime, orca_handle library) {
    static struct titled_tracks tracks;
    memset(&tracks, 0, sizeof tracks);
    SMOKE_CHECK(orca_library_query_tracks(runtime, library, 0, 0, 512, 0, &tracks,
                                          collect_titled) == ORCA_STATUS_OK);
    int64_t synced = titled_track(&tracks, "chromaprint-test");
    int64_t plain = titled_track(&tracks, "Plain M4A");
    SMOKE_CHECK(synced > 0 && plain > 0);

    struct lyrics_capture lyrics;
    SMOKE_CHECK(read_track_lyrics(runtime, library, synced, &lyrics) == 0);
    SMOKE_CHECK(lyrics.source == ORCA_LYRICS_SOURCE_SIDECAR);
    SMOKE_CHECK(lyrics.kind == ORCA_LYRICS_KIND_SYNCED);
    SMOKE_CHECK(lyrics.line_count == 4);
    SMOKE_CHECK(lyrics.first_start_ms == 1000 && lyrics.first_text_matches);

    SMOKE_CHECK(read_track_lyrics(runtime, library, plain, &lyrics) == 0);
    SMOKE_CHECK(lyrics.source == ORCA_LYRICS_SOURCE_EMBEDDED);
    SMOKE_CHECK(lyrics.kind == ORCA_LYRICS_KIND_PLAIN);
    SMOKE_CHECK(lyrics.line_count == 2 && lyrics.first_start_ms == -1);

    orca_handle job;
    SMOKE_CHECK(orca_library_start_lyrics(runtime, library, synced, 2, &job) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    return 0;
}

struct artist_smoke_capture {
    uint32_t count;
    int64_t first_id;
    uint8_t loved;
    uint8_t has_photo;
    uint8_t outcome;
    uint8_t has_info;
    uint8_t has_listeners;
    size_t link_count;
    size_t related_count;
    uint8_t has_release_info;
};

static void capture_smoke_artist(void *context, const orca_artist_view_v2 *artist) {
    struct artist_smoke_capture *capture = context;
    if (capture->count == 0) {
        capture->first_id = artist->base.id;
        capture->loved = artist->loved;
        capture->has_photo = artist->has_photo;
    }
    capture->count += 1;
}

static void capture_smoke_artist_info(void *context, const orca_artist_info_view *info) {
    struct artist_smoke_capture *capture = context;
    capture->has_info = 1;
    capture->outcome = info->outcome;
    capture->has_listeners = info->has_listeners;
}

static void capture_smoke_related_artists(void *context, const orca_related_artist_view *artists, size_t count) {
    (void)artists;
    struct artist_smoke_capture *capture = context;
    capture->related_count = count;
}

static void capture_smoke_related_photo_info(void *context, const orca_related_artist_photo_info_view *info) {
    (void)info;
    int *calls = context;
    *calls += 1;
}

static void capture_smoke_release_info(void *context, const orca_release_info_view *info) {
    (void)info;
    struct artist_smoke_capture *capture = context;
    capture->has_release_info = 1;
}

static void capture_smoke_artist_links(void *context, const orca_artist_link_view *links, size_t count) {
    (void)links;
    struct artist_smoke_capture *capture = context;
    capture->link_count = count;
}

static int artist_photo_smoke(orca_runtime *runtime, orca_handle library, int64_t artist, uint8_t has_photo) {
    struct image_capture photo;
    memset(&photo, 0, sizeof photo);
    SMOKE_CHECK(orca_library_artist_photo(runtime, library, artist, &photo, capture_image) ==
                (has_photo ? ORCA_STATUS_OK : ORCA_STATUS_NOT_FOUND));
    uint64_t request = 0;
    SMOKE_CHECK(orca_library_request_artwork(runtime, library, ORCA_ARTWORK_SUBJECT_ARTIST, artist, &request) ==
                ORCA_STATUS_OK);
    struct artwork_result_capture result;
    memset(&result, 0, sizeof result);
    long deadline = now_ms() + 5000;
    for (;;) {
        orca_status status = orca_library_take_artwork(runtime, library, &result, capture_artwork_result);
        if (status == ORCA_STATUS_OK) break;
        SMOKE_CHECK(status == ORCA_STATUS_NOT_FOUND);
        SMOKE_CHECK(now_ms() < deadline);
        SMOKE_CHECK(wait_for_runtime(runtime, deadline) >= 0);
        SMOKE_CHECK(drain_events(runtime) == 0);
    }
    SMOKE_CHECK(result.request == request && result.subject == ORCA_ARTWORK_SUBJECT_ARTIST &&
                result.subject_id == artist);
    SMOKE_CHECK(result.has_image == has_photo);
    return 0;
}

static int artist_smoke(orca_runtime *runtime, orca_handle library) {
    orca_artist_query_v2 query;
    memset(&query, 0, sizeof query);
    query.limit = 512;
    struct artist_smoke_capture all;
    memset(&all, 0, sizeof all);
    SMOKE_CHECK(orca_library_query_artists_v2(runtime, library, &query, &all, capture_smoke_artist) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(all.count > 0 && all.loved == 0);
    int64_t artist = all.first_id;
    SMOKE_CHECK(artist_photo_smoke(runtime, library, artist, all.has_photo) == 0);

    const int64_t artists[2] = {artist, 999999999};
    orca_change_count change;
    SMOKE_CHECK(orca_library_set_artist_love(runtime, library, artists, 2, 1, &change) == ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1 && change.skipped == 1);
    uint8_t loved = 0;
    SMOKE_CHECK(orca_library_artist_loved(runtime, library, artist, &loved) == ORCA_STATUS_OK && loved == 1);
    query.loved_only = 1;
    query.sort = ORCA_ARTIST_SORT_RECENTLY_LOVED;
    struct artist_smoke_capture listed;
    memset(&listed, 0, sizeof listed);
    SMOKE_CHECK(orca_library_query_artists_v2(runtime, library, &query, &listed, capture_smoke_artist) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(listed.count == 1 && listed.first_id == artist && listed.loved == 1);
    uint64_t matching = 0;
    SMOKE_CHECK(orca_library_artist_count_matching_v2(runtime, library, &query, &matching) == ORCA_STATUS_OK &&
                matching == 1);
    query.loved_only = 2;
    SMOKE_CHECK(orca_library_query_artists_v2(runtime, library, &query, &listed, capture_smoke_artist) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_set_artist_love(runtime, library, artists, 1, 0, &change) == ORCA_STATUS_OK);
    SMOKE_CHECK(change.updated == 1);

    struct artist_smoke_capture info;
    memset(&info, 0, sizeof info);
    SMOKE_CHECK(orca_library_artist_info(runtime, library, artist, &info, capture_smoke_artist_info) ==
                    ORCA_STATUS_NOT_FOUND &&
                info.has_info == 0);

    orca_artist_info_options options;
    memset(&options, 0, sizeof options);
    options.offline = 1;
    orca_handle job;
    SMOKE_CHECK(orca_runtime_set_client_identity(runtime, "Orca C Smoke", "1.0", "https://orca.invalid") ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_start_artist_info(runtime, library, 999999999, &options, &job) ==
                ORCA_STATUS_NOT_FOUND);
    options.language.pointer = "EN";
    options.language.length = 2;
    SMOKE_CHECK(orca_library_start_artist_info(runtime, library, artist, &options, &job) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    options.language.pointer = "de";
    SMOKE_CHECK(orca_library_start_artist_info(runtime, library, artist, &options, &job) == ORCA_STATUS_OK);
    uint8_t state = ORCA_JOB_RUNNING;
    SMOKE_CHECK(await_job(runtime, job, &state, 0, 60000) == 1 && state == ORCA_JOB_SUCCEEDED);
    uint8_t outcome = ORCA_ARTIST_INFO_OUTCOME_NOT_REQUESTED;
    SMOKE_CHECK(orca_job_artist_info_outcome(runtime, job, &outcome) == ORCA_STATUS_OK);
    SMOKE_CHECK(outcome == ORCA_ARTIST_INFO_OUTCOME_NO_MUSICBRAINZ_ID);
    SMOKE_CHECK(orca_job_lyrics_outcome(runtime, job, &outcome) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_artist_info(runtime, library, artist, &info, capture_smoke_artist_info) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(info.has_info == 1 && info.outcome == ORCA_ARTIST_INFO_OUTCOME_NO_MUSICBRAINZ_ID);
    SMOKE_CHECK(info.has_listeners == 0);
    info.link_count = 99;
    SMOKE_CHECK(orca_library_artist_links(runtime, library, artist, &info, capture_smoke_artist_links) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(info.link_count == 0);
    info.related_count = 99;
    SMOKE_CHECK(orca_library_related_artists(runtime, library, artist, &info, capture_smoke_related_artists) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(info.related_count == 0);
    struct image_capture related_photo;
    memset(&related_photo, 0, sizeof related_photo);
    static const char related_mbid[] = "cccccccc-0000-4000-8000-000000000003";
    SMOKE_CHECK(orca_library_related_artist_photo(runtime, library, related_mbid, sizeof related_mbid - 1,
                                                  &related_photo, capture_image) == ORCA_STATUS_NOT_FOUND &&
                related_photo.count == 0);
    SMOKE_CHECK(orca_library_related_artist_photo(runtime, library, NULL, 1, &related_photo, capture_image) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    int related_photo_info_calls = 0;
    SMOKE_CHECK(orca_library_related_artist_photo_info(runtime, library, related_mbid, sizeof related_mbid - 1,
                                                       &related_photo_info_calls, capture_smoke_related_photo_info) ==
                    ORCA_STATUS_NOT_FOUND &&
                related_photo_info_calls == 0);
    SMOKE_CHECK(orca_library_related_artist_photo_info(runtime, library, related_mbid, sizeof related_mbid - 1,
                                                       &related_photo_info_calls, NULL) == ORCA_STATUS_INVALID_ARGUMENT);

    orca_release_info_options release_options;
    memset(&release_options, 0, sizeof release_options);
    release_options.offline = 1;
    SMOKE_CHECK(orca_library_start_release_info(runtime, library, 999999999, &release_options, &job) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_release_info(runtime, library, 999999999, &info, capture_smoke_release_info) ==
                    ORCA_STATUS_NOT_FOUND &&
                info.has_release_info == 0);

    orca_genre_fill fill;
    memset(&fill, 0, sizeof fill);
    SMOKE_CHECK(orca_library_genre_fill(runtime, library, &fill) == ORCA_STATUS_OK && fill.musicbrainz == 1);
    fill.musicbrainz = 0;
    SMOKE_CHECK(orca_library_set_genre_fill(runtime, library, &fill) == ORCA_STATUS_OK);
    fill.musicbrainz = 1;
    SMOKE_CHECK(orca_library_genre_fill(runtime, library, &fill) == ORCA_STATUS_OK && fill.musicbrainz == 0);
    orca_genre_fill_options fill_options;
    memset(&fill_options, 0, sizeof fill_options);
    fill_options.limit = 1;
    fill_options.offline = 1;
    SMOKE_CHECK(orca_library_start_genre_fill(runtime, library, &fill_options, &job) == ORCA_STATUS_OK);
    state = ORCA_JOB_RUNNING;
    SMOKE_CHECK(await_job(runtime, job, &state, 0, 60000) == 1 && state == ORCA_JOB_SUCCEEDED);
    outcome = ORCA_ARTIST_INFO_OUTCOME_NOT_REQUESTED;
    SMOKE_CHECK(orca_job_release_info_outcome(runtime, job, &outcome) == ORCA_STATUS_OK);
    SMOKE_CHECK(outcome != ORCA_ARTIST_INFO_OUTCOME_NOT_REQUESTED);
    fill.musicbrainz = 1;
    SMOKE_CHECK(orca_library_set_genre_fill(runtime, library, &fill) == ORCA_STATUS_OK);
    return 0;
}

/* Watches a root in a temporary directory, adds an album to it, and waits
 * for the Library to change without any scan being started. */
static int watch_smoke(orca_runtime *runtime) {
    char root[] = ".zig-cache/tmp/orca-c-smoke-watch-XXXXXX";
    char album[sizeof root + 16];
    char track[sizeof album + 16];
    if (mkdir(".zig-cache/tmp", 0700) != 0 && errno != EEXIST) return 210;
    if (mkdtemp(root) == 0) return 211;
    snprintf(album, sizeof album, "%s/Album", root);
    snprintf(track, sizeof track, "%s/one.flac", album);
    int result = 0;

    orca_handle library;
    if (orca_library_open(runtime, "file:orca-c-smoke-watch?mode=memory&cache=shared",
                          &library) != ORCA_STATUS_OK) {
        rmdir(root);
        return 212;
    }
    int64_t root_id = 0;
    orca_watch_options options;
    memset(&options, 0, sizeof options);
    options.quiet_ms = 50;
    orca_watch_status watch_status;
    orca_status watched = ORCA_STATUS_INTERNAL;
    if (orca_library_add_root(runtime, library, root, &root_id) != ORCA_STATUS_OK) {
        result = 213;
        goto close;
    }
    watched = orca_library_watch(runtime, library, &options);
    if (watched == ORCA_STATUS_UNSUPPORTED) {
        if (orca_library_watch_status(runtime, library, &watch_status) != ORCA_STATUS_OK ||
            watch_status.state != ORCA_WATCH_STATE_UNSUPPORTED)
            result = 214;
        goto close;
    }
    if (watched != ORCA_STATUS_OK) {
        result = 215;
        goto close;
    }
    if (orca_library_watch(runtime, library, 0) != ORCA_STATUS_INVALID_STATE) {
        result = 216;
        goto unwatch;
    }

    long deadline = now_ms() + 10000;
    memset(&watch_status, 0, sizeof watch_status);
    while (watch_status.roots_watched != 1) {
        if (now_ms() >= deadline) {
            result = 217;
            goto unwatch;
        }
        if (wait_for_runtime(runtime, now_ms() + 10) < 0 || drain_events(runtime) != 0 ||
            orca_library_watch_status(runtime, library, &watch_status) != ORCA_STATUS_OK) {
            result = 218;
            goto unwatch;
        }
    }
    if (watch_status.state != ORCA_WATCH_STATE_WATCHING) {
        result = 219;
        goto unwatch;
    }

    uint64_t before = 0;
    if (orca_library_track_count(runtime, library, &before) != ORCA_STATUS_OK) {
        result = 220;
        goto unwatch;
    }
    if (mkdir(album, 0700) != 0 || copy_file("fixtures/audio/tagged-reference.flac", track) != 0) {
        result = 221;
        goto unwatch;
    }
    if (await_library_changed(runtime, library, now_ms() + 10000) != 1) {
        result = 222;
        goto unwatch;
    }
    uint64_t after = 0;
    if (orca_library_track_count(runtime, library, &after) != ORCA_STATUS_OK || after <= before) {
        result = 223;
        goto unwatch;
    }

    const char *directories[1] = {"Album"};
    const char *escaping[1] = {"../Album"};
    orca_handle reconcile_job;
    if (orca_library_start_reconcile(runtime, library, root_id, escaping, 1, &reconcile_job) !=
        ORCA_STATUS_INVALID_ARGUMENT) {
        result = 224;
        goto unwatch;
    }
    if (orca_library_start_reconcile(runtime, library, root_id, directories, 1,
                                     &reconcile_job) != ORCA_STATUS_OK) {
        result = 225;
        goto unwatch;
    }
    orca_job_snapshot reconcile_snapshot;
    if (orca_job_snapshot_get(runtime, reconcile_job, &reconcile_snapshot) != ORCA_STATUS_OK ||
        reconcile_snapshot.kind != ORCA_JOB_KIND_RECONCILE) {
        result = 226;
        goto unwatch;
    }
    uint8_t reconcile_state = ORCA_JOB_RUNNING;
    if (await_job(runtime, reconcile_job, &reconcile_state, 0, 60000) != 1 ||
        reconcile_state != ORCA_JOB_SUCCEEDED) {
        result = 227;
        goto unwatch;
    }
    orca_scan_stats reconcile_stats;
    if (orca_library_scan_stats(runtime, reconcile_job, &reconcile_stats) != ORCA_STATUS_OK ||
        reconcile_stats.files_seen != 1 || reconcile_stats.unchanged != 1) {
        result = 228;
        goto unwatch;
    }

    if (orca_library_watch_status(runtime, library, &watch_status) != ORCA_STATUS_OK ||
        watch_status.state != ORCA_WATCH_STATE_WATCHING || watch_status.roots_watched != 1 ||
        watch_status.directories_watched != 2 || watch_status.roots_unavailable != 0 ||
        watch_status.roots_degraded != 0) {
        result = 229;
        goto unwatch;
    }

unwatch:
    if (orca_library_unwatch(runtime, library) != ORCA_STATUS_OK && result == 0) result = 230;
    if (orca_library_watch_status(runtime, library, &watch_status) != ORCA_STATUS_OK ||
        watch_status.state != ORCA_WATCH_STATE_OFF) {
        if (result == 0) result = 231;
    }
close:
    if (drain_events(runtime) != 0 && result == 0) result = 232;
    if (orca_library_close(runtime, library) != ORCA_STATUS_OK && result == 0) result = 233;
    unlink(track);
    rmdir(album);
    rmdir(root);
    return result;
}

struct tag_track_capture {
    uint32_t count;
    int64_t id;
    char title[128];
};

static void capture_tag_track(void *context, const orca_track_view *track) {
    struct tag_track_capture *capture = context;
    capture->count += 1;
    capture->id = track->id;
    size_t length = track->title.length < sizeof capture->title - 1 ? track->title.length
                                                                     : sizeof capture->title - 1;
    memcpy(capture->title, track->title.pointer, length);
    capture->title[length] = 0;
}

static int tag_track(orca_runtime *runtime, orca_handle library, struct tag_track_capture *track) {
    memset(track, 0, sizeof *track);
    SMOKE_CHECK(orca_library_query_tracks(runtime, library, 0, 0, 512, 0, track,
                                          capture_tag_track) == ORCA_STATUS_OK);
    SMOKE_CHECK(track->count == 1 && track->id > 0);
    return 0;
}

struct edited_ids_capture {
    uint32_t calls;
    size_t count;
    int64_t first;
};

static void capture_edited_ids(void *context, const int64_t *ids, size_t count) {
    struct edited_ids_capture *capture = context;
    capture->calls += 1;
    capture->count = count;
    capture->first = count != 0 ? ids[0] : 0;
}

static int set_title(orca_runtime *runtime, orca_handle library, int64_t track_id,
                     const char *title, int64_t *edited_id) {
    orca_track_edit edit;
    memset(&edit, 0, sizeof edit);
    edit.field = ORCA_METADATA_FIELD_TITLE;
    edit.has_value = 1;
    edit.value.pointer = title;
    edit.value.length = strlen(title);
    struct edited_ids_capture edited;
    memset(&edited, 0, sizeof edited);
    SMOKE_CHECK(orca_library_edit_tracks(runtime, library, &track_id, 1, &edit, 1, &edited,
                                         capture_edited_ids) == ORCA_STATUS_OK);
    SMOKE_CHECK(edited.calls == 1 && edited.count == 1 && edited.first > 0);
    *edited_id = edited.first;
    return 0;
}

struct field_value_capture {
    uint32_t count;
    uint8_t field;
    uint8_t provenance;
    uint8_t locked;
    char text[128];
};

static void capture_field_value(void *context, const orca_field_value_view *value) {
    struct field_value_capture *capture = context;
    capture->count += 1;
    capture->field = value->field;
    capture->provenance = value->provenance;
    capture->locked = value->locked;
    size_t length = value->text.length < sizeof capture->text - 1 ? value->text.length
                                                                  : sizeof capture->text - 1;
    memcpy(capture->text, value->text.pointer, length);
    capture->text[length] = 0;
}

struct tag_plan_capture {
    uint32_t calls;
    uint64_t plan_id;
    orca_tag_write_digest digest;
    int64_t file_id;
    size_t file_count;
    size_t change_count;
    size_t conflict_count;
    size_t skip_count;
    uint8_t field;
    uint8_t provenance;
    uint8_t has_before;
    char before[128];
    char after[128];
    char path[512];
};

static void copy_view(char *destination, size_t capacity, orca_string_view view) {
    size_t length = view.length < capacity - 1 ? view.length : capacity - 1;
    memcpy(destination, view.pointer, length);
    destination[length] = 0;
}

static void capture_tag_plan(void *context, const orca_tag_write_plan_view *plan) {
    struct tag_plan_capture *capture = context;
    capture->calls += 1;
    capture->plan_id = plan->plan_id;
    capture->digest = plan->digest;
    capture->file_count = plan->file_count;
    capture->conflict_count = plan->conflict_count;
    capture->skip_count = plan->skip_count;
    capture->change_count = 0;
    for (size_t i = 0; i < plan->file_count; i += 1)
        capture->change_count += plan->files[i].change_count;
    if (plan->file_count != 0) capture->file_id = plan->files[0].file_id;
    if (plan->file_count == 0 || plan->files[0].change_count == 0) return;
    const orca_tag_write_change_view *change = &plan->files[0].changes[0];
    capture->field = change->field;
    capture->provenance = change->provenance;
    capture->has_before = change->has_before;
    copy_view(capture->before, sizeof capture->before, change->before);
    copy_view(capture->after, sizeof capture->after, change->after);
    copy_view(capture->path, sizeof capture->path, plan->files[0].path);
}

static int plan_tags(orca_runtime *runtime, orca_handle library, int64_t track_id,
                     struct tag_plan_capture *plan) {
    memset(plan, 0, sizeof *plan);
    SMOKE_CHECK(orca_library_plan_tag_write(runtime, library, &track_id, 1, plan,
                                            capture_tag_plan) == ORCA_STATUS_OK);
    SMOKE_CHECK(plan->calls == 1);
    SMOKE_CHECK(plan->conflict_count == 0 && plan->skip_count == 0);
    return 0;
}

struct tag_genres_capture {
    uint32_t calls;
    int64_t file_id;
    size_t before_count;
    size_t after_count;
    char after[2][64];
};

static void capture_tag_genres(void *context, const orca_tag_write_genres_view *genres) {
    struct tag_genres_capture *capture = context;
    capture->calls += 1;
    capture->file_id = genres->file_id;
    capture->before_count = genres->before_count;
    capture->after_count = genres->after_count;
    for (size_t i = 0; i < genres->after_count && i < 2; i += 1)
        copy_view(capture->after[i], sizeof capture->after[i], genres->after[i]);
}

static int tag_write_genre_steps(orca_runtime *runtime, orca_handle library, int64_t track_id) {
    static const char listed[] = "Smoke Shoegaze; Smoke Dream Pop";
    const orca_string_view names[1] = {{listed, sizeof listed - 1}};
    SMOKE_CHECK(orca_library_set_track_genres(runtime, library, &track_id, 1, names, 1) ==
                ORCA_STATUS_OK);
    struct tag_plan_capture plan;
    if (plan_tags(runtime, library, track_id, &plan) != 0) return 1;
    SMOKE_CHECK(plan.plan_id != 0 && plan.file_count == 1 && plan.change_count == 0);

    struct tag_genres_capture genres;
    memset(&genres, 0, sizeof genres);
    SMOKE_CHECK(orca_library_query_tag_write_genres(runtime, library, plan.plan_id, plan.file_id,
                                                    &genres, capture_tag_genres) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(genres.calls == 1 && genres.file_id == plan.file_id);
    SMOKE_CHECK(genres.before_count == 0 && genres.after_count == 2);
    SMOKE_CHECK(strcmp(genres.after[0], "Smoke Shoegaze") == 0);
    SMOKE_CHECK(strcmp(genres.after[1], "Smoke Dream Pop") == 0);
    SMOKE_CHECK(orca_library_query_tag_write_genres(runtime, library, plan.plan_id,
                                                    plan.file_id + 1000, &genres,
                                                    capture_tag_genres) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_query_tag_write_genres(runtime, library, plan.plan_id, plan.file_id,
                                                    &genres, 0) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(genres.calls == 1);

    SMOKE_CHECK(orca_library_discard_tag_write(runtime, library, plan.plan_id) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_query_tag_write_genres(runtime, library, plan.plan_id, plan.file_id,
                                                    &genres, capture_tag_genres) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(genres.calls == 1);
    SMOKE_CHECK(orca_library_set_track_genres(runtime, library, &track_id, 1, 0, 0) ==
                ORCA_STATUS_OK);
    struct tag_plan_capture cleared;
    if (plan_tags(runtime, library, track_id, &cleared) != 0) return 1;
    SMOKE_CHECK(cleared.plan_id == 0 && cleared.file_count == 0);
    return 0;
}

static int read_file_bytes(const char *path, unsigned char *buffer, size_t capacity,
                           size_t *length) {
    FILE *file = fopen(path, "rb");
    if (file == 0) return -1;
    *length = fread(buffer, 1, capacity, file);
    int failed = ferror(file) || !feof(file);
    fclose(file);
    return failed ? -1 : 0;
}

static int file_is(const char *path, const unsigned char *expected, size_t expected_length) {
    static unsigned char bytes[1 << 20];
    size_t length = 0;
    if (read_file_bytes(path, bytes, sizeof bytes, &length) != 0) return -1;
    return length == expected_length && memcmp(bytes, expected, length) == 0;
}

static int write_tags(orca_runtime *runtime, orca_handle library,
                      const struct tag_plan_capture *plan) {
    orca_handle job;
    SMOKE_CHECK(orca_library_start_tag_write(runtime, library, plan->plan_id, &plan->digest,
                                             &job) == ORCA_STATUS_OK);
    orca_job_snapshot snapshot;
    SMOKE_CHECK(orca_job_snapshot_get(runtime, job, &snapshot) == ORCA_STATUS_OK);
    SMOKE_CHECK(snapshot.kind == ORCA_JOB_KIND_MUTATION);
    SMOKE_CHECK(snapshot.has_total == 1 && snapshot.total_units == plan->file_count);
    uint8_t state = ORCA_JOB_RUNNING;
    SMOKE_CHECK(await_job(runtime, job, &state, 1, 60000) == 1);
    SMOKE_CHECK(state == ORCA_JOB_SUCCEEDED);
    orca_scan_stats stats;
    SMOKE_CHECK(orca_library_scan_stats(runtime, job, &stats) == ORCA_STATUS_OK);
    SMOKE_CHECK(stats.files_seen == plan->file_count && stats.changed == plan->file_count);
    SMOKE_CHECK(stats.errors == 0);
    SMOKE_CHECK(orca_library_start_tag_write(runtime, library, plan->plan_id, &plan->digest,
                                             &job) == ORCA_STATUS_NOT_FOUND);
    return 0;
}

static int remove_tree(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0) return errno == ENOENT ? 0 : -1;
    if (!S_ISDIR(info.st_mode)) return unlink(path);
    DIR *directory = opendir(path);
    if (directory == 0) return -1;
    int result = 0;
    struct dirent *entry;
    while ((entry = readdir(directory)) != 0) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        char child[1024];
        if (snprintf(child, sizeof child, "%s/%s", path, entry->d_name) >= (int)sizeof child) {
            result = -1;
            continue;
        }
        if (remove_tree(child) != 0) result = -1;
    }
    closedir(directory);
    if (rmdir(path) != 0) result = -1;
    return result;
}

static int coverless_release_steps(orca_runtime *runtime, const char *root,
                                   orca_handle *library, int *library_open) {
    char music[1024];
    char song[1024];
    SMOKE_CHECK(snprintf(music, sizeof music, "%s/music", root) < (int)sizeof music);
    SMOKE_CHECK(snprintf(song, sizeof song, "%s/song.wav", music) < (int)sizeof song);
    SMOKE_CHECK(mkdir(music, 0700) == 0);
    SMOKE_CHECK(copy_file("fixtures/audio/tagged-reference.wav", song) == 0);
    SMOKE_CHECK(orca_library_open(runtime, "file:orca-c-smoke-coverless?mode=memory&cache=shared",
                                  library) == ORCA_STATUS_OK);
    *library_open = 1;
    int64_t root_id = 0;
    SMOKE_CHECK(orca_library_add_root(runtime, *library, music, &root_id) == ORCA_STATUS_OK);
    orca_handle scan_job;
    SMOKE_CHECK(orca_library_start_scan(runtime, *library, root_id, 0, &scan_job) ==
                ORCA_STATUS_OK);
    uint8_t scan_state = ORCA_JOB_RUNNING;
    SMOKE_CHECK(await_job(runtime, scan_job, &scan_state, 0, 60000) == 1);
    SMOKE_CHECK(scan_state == ORCA_JOB_SUCCEEDED);

    static struct titled_tracks tracks;
    memset(&tracks, 0, sizeof tracks);
    SMOKE_CHECK(orca_library_query_tracks(runtime, *library, 0, 0, 512, 0, &tracks,
                                          collect_titled) == ORCA_STATUS_OK);
    SMOKE_CHECK(tracks.count == 1);
    int64_t release_id = -1;
    SMOKE_CHECK(orca_library_track_get(runtime, *library, tracks.ids[0], &release_id,
                                       capture_release_id) == ORCA_STATUS_OK);
    SMOKE_CHECK(release_id > 0);
    struct image_capture image;
    memset(&image, 0, sizeof image);
    SMOKE_CHECK(orca_library_release_artwork(runtime, *library, release_id, &image,
                                             capture_image) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(image.count == 0);
    return 0;
}

static int coverless_release_smoke(orca_runtime *runtime) {
    char relative[] = ".zig-cache/tmp/orca-c-smoke-coverless-XXXXXX";
    SMOKE_CHECK(mkdir(".zig-cache/tmp", 0700) == 0 || errno == EEXIST);
    SMOKE_CHECK(mkdtemp(relative) != 0);
    char root[1024];
    int failed = getcwd(root, sizeof root - sizeof relative - 1) == 0;
    if (!failed) {
        strcat(root, "/");
        strcat(root, relative);
    }
    orca_handle library;
    int library_open = 0;
    if (!failed && coverless_release_steps(runtime, root, &library, &library_open) != 0) failed = 1;
    if (library_open && orca_library_close(runtime, library) != ORCA_STATUS_OK) failed = 1;
    if (drain_events(runtime) != 0) failed = 1;
    if (remove_tree(relative) != 0) failed = 1;
    SMOKE_CHECK(failed == 0);
    return 0;
}

static int tag_write_steps(orca_runtime *runtime, const char *root, orca_handle *library,
                           int *library_open) {
    char music[1024];
    char song[1024];
    char database[1024];
    SMOKE_CHECK(snprintf(music, sizeof music, "%s/music", root) < (int)sizeof music);
    SMOKE_CHECK(snprintf(song, sizeof song, "%s/song.flac", music) < (int)sizeof song);
    SMOKE_CHECK(snprintf(database, sizeof database, "%s/library.db", root) < (int)sizeof database);
    SMOKE_CHECK(mkdir(music, 0700) == 0);
    SMOKE_CHECK(copy_file("fixtures/audio/tagged-reference.flac", song) == 0);
    static unsigned char original[1 << 16];
    size_t original_length = 0;
    SMOKE_CHECK(read_file_bytes(song, original, sizeof original, &original_length) == 0);
    SMOKE_CHECK(original_length > 0);

    SMOKE_CHECK(orca_library_open(runtime, database, library) == ORCA_STATUS_OK);
    *library_open = 1;
    int64_t root_id = 0;
    SMOKE_CHECK(orca_library_add_root(runtime, *library, music, &root_id) == ORCA_STATUS_OK);
    orca_handle scan_job;
    SMOKE_CHECK(orca_library_start_scan(runtime, *library, root_id, 0, &scan_job) ==
                ORCA_STATUS_OK);
    uint8_t scan_state = ORCA_JOB_RUNNING;
    SMOKE_CHECK(await_job(runtime, scan_job, &scan_state, 0, 60000) == 1);
    SMOKE_CHECK(scan_state == ORCA_JOB_SUCCEEDED);
    struct tag_track_capture track;
    if (tag_track(runtime, *library, &track) != 0) return 1;
    char original_title[128];
    memcpy(original_title, track.title, sizeof original_title);
    SMOKE_CHECK(original_title[0] != 0);

    orca_track_edit edits[65];
    memset(edits, 0, sizeof edits);
    for (size_t i = 0; i < 65; i += 1) {
        edits[i].field = ORCA_METADATA_FIELD_TITLE;
        edits[i].has_value = 1;
        edits[i].value.pointer = "Unused";
        edits[i].value.length = 6;
    }
    struct edited_ids_capture refused;
    memset(&refused, 0, sizeof refused);
    edits[0].field = 13;
    SMOKE_CHECK(orca_library_edit_tracks(runtime, *library, &track.id, 1, edits, 1, &refused,
                                         capture_edited_ids) == ORCA_STATUS_INVALID_ARGUMENT);
    edits[0].field = ORCA_METADATA_FIELD_COMPILATION;
    SMOKE_CHECK(orca_library_edit_tracks(runtime, *library, &track.id, 1, edits, 1, &refused,
                                         capture_edited_ids) == ORCA_STATUS_INVALID_ARGUMENT);
    edits[0].field = ORCA_METADATA_FIELD_TITLE;
    SMOKE_CHECK(orca_library_edit_tracks(runtime, *library, &track.id, 1, edits, 0, &refused,
                                         capture_edited_ids) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_edit_tracks(runtime, *library, &track.id, 1, edits, 65, &refused,
                                         capture_edited_ids) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(refused.calls == 0);

    const char *written_title = "Smoke Written Title";
    int64_t track_id = 0;
    if (set_title(runtime, *library, track.id, written_title, &track_id) != 0) return 1;
    struct field_value_capture value;
    memset(&value, 0, sizeof value);
    SMOKE_CHECK(orca_library_query_track_edits(runtime, *library, track_id, &value,
                                               capture_field_value) == ORCA_STATUS_OK);
    SMOKE_CHECK(value.count == 1 && value.field == ORCA_METADATA_FIELD_TITLE);
    SMOKE_CHECK(value.provenance == ORCA_PROVENANCE_USER && value.locked == 1);
    SMOKE_CHECK(strcmp(value.text, written_title) == 0);

    struct tag_plan_capture plan;
    if (plan_tags(runtime, *library, track_id, &plan) != 0) return 1;
    SMOKE_CHECK(plan.plan_id != 0 && plan.file_count == 1 && plan.change_count == 1);
    SMOKE_CHECK(plan.field == ORCA_METADATA_FIELD_TITLE &&
                plan.provenance == ORCA_PROVENANCE_USER);
    SMOKE_CHECK(plan.has_before == 1 && strcmp(plan.before, original_title) == 0);
    SMOKE_CHECK(strcmp(plan.after, written_title) == 0);
    size_t path_length = strlen(plan.path);
    SMOKE_CHECK(path_length > 10 && strcmp(plan.path + path_length - 10, "/song.flac") == 0);

    orca_tag_write_digest wrong = plan.digest;
    wrong.bytes[0] ^= 1;
    orca_handle job;
    SMOKE_CHECK(orca_library_start_tag_write(runtime, *library, plan.plan_id, &wrong, &job) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_start_tag_write(runtime, *library, plan.plan_id, 0, &job) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(file_is(song, original, original_length) == 1);

    if (write_tags(runtime, *library, &plan) != 0) return 1;
    SMOKE_CHECK(file_is(song, original, original_length) == 0);
    struct tag_plan_capture written;
    if (plan_tags(runtime, *library, track_id, &written) != 0) return 1;
    SMOKE_CHECK(written.plan_id == 0 && written.file_count == 0);
    if (tag_track(runtime, *library, &track) != 0) return 1;
    SMOKE_CHECK(strcmp(track.title, written_title) == 0);
    track_id = track.id;

    SMOKE_CHECK(orca_library_undo_tag_write(runtime, *library, plan.plan_id) == ORCA_STATUS_OK);
    SMOKE_CHECK(file_is(song, original, original_length) == 1);
    if (tag_track(runtime, *library, &track) != 0) return 1;
    SMOKE_CHECK(strcmp(track.title, written_title) == 0);
    track_id = track.id;
    SMOKE_CHECK(orca_library_undo_tag_write(runtime, *library, plan.plan_id) ==
                ORCA_STATUS_ALREADY_DONE);
    SMOKE_CHECK(orca_library_undo_tag_write(runtime, *library, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_undo_tag_write(runtime, *library, plan.plan_id + 1000) ==
                ORCA_STATUS_NOT_FOUND);

    struct tag_plan_capture again;
    if (plan_tags(runtime, *library, track_id, &again) != 0) return 1;
    SMOKE_CHECK(again.plan_id != 0 && again.plan_id != plan.plan_id);
    SMOKE_CHECK(again.has_before == 1 && strcmp(again.before, original_title) == 0);
    uint64_t backups = 99;
    uint64_t bytes = 99;
    SMOKE_CHECK(orca_library_prune_tag_write_backups(runtime, *library, 0, &backups, &bytes) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(backups == 0 && bytes == 0);
    if (write_tags(runtime, *library, &again) != 0) return 1;
    SMOKE_CHECK(orca_library_prune_tag_write_backups(runtime, *library, 0, 0, &bytes) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_prune_tag_write_backups(runtime, *library, 0, &backups, &bytes) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(backups == 1 && bytes == original_length);
    SMOKE_CHECK(orca_library_undo_tag_write(runtime, *library, again.plan_id) == ORCA_STATUS_GONE);
    SMOKE_CHECK(file_is(song, original, original_length) == 0);

    if (tag_track(runtime, *library, &track) != 0) return 1;
    if (tag_write_genre_steps(runtime, *library, track.id) != 0) return 1;
    if (set_title(runtime, *library, track.id, "Smoke Discarded Title", &track_id) != 0) return 1;
    struct tag_plan_capture discarded;
    if (plan_tags(runtime, *library, track_id, &discarded) != 0) return 1;
    SMOKE_CHECK(discarded.plan_id != 0 && discarded.has_before == 1);
    SMOKE_CHECK(strcmp(discarded.before, written_title) == 0);
    SMOKE_CHECK(orca_library_discard_tag_write(runtime, *library, discarded.plan_id) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_discard_tag_write(runtime, *library, discarded.plan_id) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_start_tag_write(runtime, *library, discarded.plan_id,
                                             &discarded.digest, &job) == ORCA_STATUS_NOT_FOUND);

    struct tag_plan_capture held;
    if (plan_tags(runtime, *library, track_id, &held) != 0) return 1;
    SMOKE_CHECK(held.plan_id != 0);
    *library_open = 0;
    SMOKE_CHECK(orca_library_close(runtime, *library) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_open(runtime, database, library) == ORCA_STATUS_OK);
    *library_open = 1;
    SMOKE_CHECK(orca_library_start_tag_write(runtime, *library, held.plan_id, &held.digest,
                                             &job) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_discard_tag_write(runtime, *library, held.plan_id) ==
                ORCA_STATUS_NOT_FOUND);
    memset(&value, 0, sizeof value);
    SMOKE_CHECK(orca_library_query_track_edits(runtime, *library, track_id, &value,
                                               capture_field_value) == ORCA_STATUS_OK);
    SMOKE_CHECK(value.count == 1 && strcmp(value.text, "Smoke Discarded Title") == 0);
    SMOKE_CHECK(file_is(song, original, original_length) == 0);
    return 0;
}

static int tag_write_smoke(orca_runtime *runtime, orca_handle library) {
    uint64_t backups = 0;
    uint64_t bytes = 0;
    SMOKE_CHECK(orca_library_undo_tag_write(runtime, library, 1) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(orca_library_prune_tag_write_backups(runtime, library, 0, &backups, &bytes) ==
                ORCA_STATUS_INVALID_STATE);

    char relative[] = ".zig-cache/tmp/orca-c-smoke-tags-XXXXXX";
    SMOKE_CHECK(mkdir(".zig-cache/tmp", 0700) == 0 || errno == EEXIST);
    SMOKE_CHECK(mkdtemp(relative) != 0);
    char root[1024];
    int failed = getcwd(root, sizeof root - sizeof relative - 1) == 0;
    if (!failed) {
        strcat(root, "/");
        strcat(root, relative);
    }
    orca_handle tag_library;
    int library_open = 0;
    if (!failed && tag_write_steps(runtime, root, &tag_library, &library_open) != 0) failed = 1;
    if (library_open && orca_library_close(runtime, tag_library) != ORCA_STATUS_OK) failed = 1;
    if (drain_events(runtime) != 0) failed = 1;
    if (remove_tree(relative) != 0) failed = 1;
    SMOKE_CHECK(failed == 0);
    return 0;
}

static orca_credential_result smoke_credential(void *context, const char *service, const char *account,
                                               uint8_t *buffer, size_t capacity, size_t *length) {
    (void)context;
    (void)service;
    (void)account;
    (void)buffer;
    (void)capacity;
    *length = 0;
    return ORCA_CREDENTIAL_RESULT_NOT_FOUND;
}

static int provider_settings_steps(orca_runtime *runtime) {
    SMOKE_CHECK(orca_runtime_set_credential_callback(runtime, smoke_credential, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_set_credential_callback(runtime, 0, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_set_credential_callback(runtime, smoke_credential, 0) == ORCA_STATUS_OK);

    SMOKE_CHECK(orca_runtime_set_client_identity(runtime, "Orca C Smoke", "1.0", "https://orca.invalid") ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_set_client_identity(runtime, 0, "1.0", "https://orca.invalid") ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_runtime_set_client_identity(runtime, "Player (beta)", "1.0", "https://orca.invalid") ==
                ORCA_STATUS_INVALID_ARGUMENT);

    static const char *const accepted[] = {
        "https://lb.example.org",
        "http://127.0.0.1:8080",
        "http://[::1]:8080",
        "http://localhost:8080",
    };
    for (uint8_t service = ORCA_PROVIDER_SERVICE_LISTENBRAINZ; service <= ORCA_PROVIDER_SERVICE_COVER_ART_ARCHIVE;
         service++) {
        SMOKE_CHECK(orca_runtime_set_provider_server(runtime, service, accepted[service]) == ORCA_STATUS_OK);
        SMOKE_CHECK(orca_runtime_set_provider_server(runtime, service, "http://127.0.0.1@example.org") ==
                    ORCA_STATUS_INVALID_ARGUMENT);
        SMOKE_CHECK(strcmp(orca_runtime_last_error(runtime), "orca_runtime_set_provider_server: InvalidServerUrl") == 0);
        SMOKE_CHECK(orca_runtime_set_provider_server(runtime, service, "http://example.org") ==
                    ORCA_STATUS_INVALID_ARGUMENT);
        SMOKE_CHECK(orca_runtime_set_provider_server(runtime, service, 0) == ORCA_STATUS_OK);
    }
    for (uint8_t service = ORCA_PROVIDER_SERVICE_WIKIDATA; service <= ORCA_PROVIDER_SERVICE_WIKIPEDIA; service++) {
        SMOKE_CHECK(orca_runtime_set_provider_server(runtime, service, "http://127.0.0.1:8080") == ORCA_STATUS_OK);
        SMOKE_CHECK(orca_runtime_set_provider_server(runtime, service, "http://example.org") ==
                    ORCA_STATUS_INVALID_ARGUMENT);
        SMOKE_CHECK(orca_runtime_set_provider_server(runtime, service, 0) == ORCA_STATUS_OK);
    }
    SMOKE_CHECK(orca_runtime_set_provider_server(runtime, 99, "https://example.org") == ORCA_STATUS_INVALID_ARGUMENT);

    SMOKE_CHECK(orca_runtime_set_acoustid_client_key(runtime, "smoke-key") == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_set_acoustid_client_key(runtime, "with space") == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_runtime_set_acoustid_client_key(runtime, 0) == ORCA_STATUS_OK);
    return 0;
}

static int provider_work_steps(orca_runtime *runtime) {
    orca_handle library;
    SMOKE_CHECK(orca_library_open(runtime, "file:orca-c-smoke-providers?mode=memory&cache=shared", &library) ==
                ORCA_STATUS_OK);
    orca_handle player;
    SMOKE_CHECK(orca_player_create(runtime, &player) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_set_credential_callback(runtime, 0, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_player_set_library(runtime, player, library) == ORCA_STATUS_OK);

    SMOKE_CHECK(orca_runtime_set_credential_callback(runtime, smoke_credential, 0) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(strcmp(orca_runtime_last_error(runtime), "orca_runtime_set_credential_callback: WorkersRunning") == 0);
    SMOKE_CHECK(orca_runtime_set_credential_callback(runtime, 0, 0) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(orca_runtime_set_provider_server(runtime, ORCA_PROVIDER_SERVICE_LISTENBRAINZ, "http://127.0.0.1:9") ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_set_provider_server(runtime, ORCA_PROVIDER_SERVICE_LISTENBRAINZ, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_scrobbler_credentials_changed(runtime, library) == ORCA_STATUS_OK);
    return 0;
}

static int provider_smoke(orca_runtime *runtime, orca_handle library) {
    orca_runtime *fresh = orca_runtime_create();
    SMOKE_CHECK(fresh != 0);
    int failed = provider_settings_steps(fresh) != 0 || provider_work_steps(fresh) != 0;
    orca_runtime_destroy(fresh);
    SMOKE_CHECK(failed == 0);

    SMOKE_CHECK(orca_library_scrobbler_credentials_changed(runtime, library) == ORCA_STATUS_OK);
    orca_handle stale = library;
    stale.generation += 1;
    SMOKE_CHECK(orca_library_scrobbler_credentials_changed(runtime, stale) == ORCA_STATUS_STALE_HANDLE);
    return 0;
}

struct match_smoke_count {
    int calls;
};

static void count_match_proposal(void *context, const orca_match_proposal_view *proposal) {
    (void)proposal;
    ((struct match_smoke_count *)context)->calls += 1;
}

static void count_match_review(void *context, const orca_match_review_view *item) {
    (void)item;
    ((struct match_smoke_count *)context)->calls += 1;
}

static void count_track_verification(void *context, const orca_track_verification_view *verification) {
    (void)verification;
    ((struct match_smoke_count *)context)->calls += 1;
}

static void count_correction_group(void *context, const orca_correction_group_view *group) {
    (void)group;
    ((struct match_smoke_count *)context)->calls += 1;
}

static int matching_option_steps(orca_runtime *runtime, int64_t release_id) {
    orca_handle library;
    SMOKE_CHECK(orca_library_open(runtime, "file:orca-c-smoke-matching?mode=memory&cache=shared", &library) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_set_client_identity(runtime, "Orca C Smoke", "1.0", "https://orca.invalid") ==
                ORCA_STATUS_OK);
    orca_handle job;
    orca_match_options options;
    memset(&options, 0, sizeof options);
    options.has_track_id = 1;
    options.has_release_id = 1;
    options.release_id = release_id;
    SMOKE_CHECK(orca_library_start_match(runtime, library, &options, &job) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(strcmp(orca_runtime_last_error(runtime), "orca_library_start_match: InvalidMatchRequest") == 0);
    memset(&options, 0, sizeof options);
    options.mode = 3;
    SMOKE_CHECK(orca_library_start_match(runtime, library, &options, &job) == ORCA_STATUS_INVALID_ARGUMENT);
    options.mode = ORCA_MATCH_MODE_REIDENTIFY;
    SMOKE_CHECK(orca_library_start_match(runtime, library, &options, &job) == ORCA_STATUS_INVALID_ARGUMENT);
    options.mode = ORCA_MATCH_MODE_VERIFY;
    SMOKE_CHECK(orca_library_start_match(runtime, library, &options, &job) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(strcmp(orca_runtime_last_error(runtime), "orca_library_start_match: AcoustIdRequired") == 0);
    memset(&options, 0, sizeof options);
    options.has_release_id = 1;
    options.release_id = 999999999;
    SMOKE_CHECK(orca_library_start_match(runtime, library, &options, &job) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_start_cover_art_fetch(runtime, library, 999999999, &job) == ORCA_STATUS_NOT_FOUND);
    return 0;
}

static int matching_smoke(orca_runtime *runtime, orca_handle library, int64_t track_id, int64_t release_id) {
    orca_handle job;
    memset(&job, 0, sizeof job);
    SMOKE_CHECK(orca_library_start_match(runtime, library, 0, &job) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(strcmp(orca_runtime_last_error(runtime), "orca_library_start_match: ClientIdentityRequired") == 0);
    SMOKE_CHECK(orca_library_start_cover_art_fetch(runtime, library, release_id, &job) ==
                ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(orca_job_match_stats(runtime, job, 0) == ORCA_STATUS_INVALID_ARGUMENT);

    uint64_t count = 0;
    SMOKE_CHECK(orca_library_unidentified_count(runtime, library, &count) == ORCA_STATUS_OK);
    SMOKE_CHECK(count > 0);
    count = 1;
    SMOKE_CHECK(orca_library_match_review_count(runtime, library, &count) == ORCA_STATUS_OK);
    SMOKE_CHECK(count == 0);
    count = 1;
    SMOKE_CHECK(orca_library_confident_match_count(runtime, library, 0.9f, &count) == ORCA_STATUS_OK);
    SMOKE_CHECK(count == 0);
    SMOKE_CHECK(orca_library_confident_match_count(runtime, library, 1.5f, &count) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    orca_confident_acceptance confident;
    SMOKE_CHECK(orca_library_accept_confident_matches(runtime, library, 0.9f, &confident) == ORCA_STATUS_OK);
    SMOKE_CHECK(confident.accepted == 0 && confident.values_written == 0);

    struct match_smoke_count calls = {0};
    SMOKE_CHECK(orca_library_query_match_review(runtime, library, 0, 0, &calls, count_match_review) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_match_review(runtime, library, 512, 0, &calls, count_match_review) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_query_match_proposals(runtime, library, track_id, &calls, count_match_proposal) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_query_correction_groups(runtime, library, 512, 0, &calls, count_correction_group) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_track_verification(runtime, library, track_id, &calls, count_track_verification) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(calls.calls == 0);

    orca_match_acceptance acceptance;
    SMOKE_CHECK(orca_library_accept_match(runtime, library, 999999999, &acceptance) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_dismiss_match(runtime, library, 999999999) == ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_accept_correction_group(runtime, library, 999999999, &confident) ==
                ORCA_STATUS_NOT_FOUND);
    SMOKE_CHECK(orca_library_dismiss_correction_group(runtime, library, 999999999) == ORCA_STATUS_NOT_FOUND);
    uint32_t values_written = 1;
    SMOKE_CHECK(orca_library_apply_matched_release(runtime, library, release_id, &values_written) == ORCA_STATUS_OK);
    SMOKE_CHECK(values_written == 0);

    orca_runtime *fresh = orca_runtime_create();
    SMOKE_CHECK(fresh != 0);
    int failed = matching_option_steps(fresh, release_id) != 0;
    orca_runtime_destroy(fresh);
    SMOKE_CHECK(failed == 0);
    return 0;
}

static void count_acoustid_submittable(void *context, const orca_acoustid_submittable_view *item) {
    (void)item;
    ((struct match_smoke_count *)context)->calls += 1;
}

static int acoustid_submission_smoke(orca_runtime *runtime, orca_handle library) {
    orca_handle job;
    memset(&job, 0, sizeof job);
    SMOKE_CHECK(orca_library_start_acoustid_submission(runtime, library, 0) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_start_acoustid_submission(runtime, library, &job) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(strcmp(orca_runtime_last_error(runtime),
                       "orca_library_start_acoustid_submission: ClientIdentityRequired") == 0);
    SMOKE_CHECK(orca_job_submission_stats(runtime, job, 0) == ORCA_STATUS_INVALID_ARGUMENT);

    uint64_t count = 1;
    SMOKE_CHECK(orca_library_acoustid_submittable_count(runtime, library, 0) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_acoustid_submittable_count(runtime, library, &count) == ORCA_STATUS_OK);
    SMOKE_CHECK(count == 0);

    struct match_smoke_count calls = {0};
    SMOKE_CHECK(orca_library_query_acoustid_submittable(runtime, library, 0, 0, &calls,
                                                        count_acoustid_submittable) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_acoustid_submittable(runtime, library, 0, 513, &calls,
                                                        count_acoustid_submittable) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_acoustid_submittable(runtime, library, 0, 10, &calls, 0) ==
                ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_query_acoustid_submittable(runtime, library, 0, 512, &calls,
                                                        count_acoustid_submittable) == ORCA_STATUS_OK);
    SMOKE_CHECK(calls.calls == 0);
    return 0;
}

struct scrobbler_capture {
    int calls;
    orca_scrobbler_status_view view;
    size_t user_name_length;
    size_t last_error_length;
};

static void capture_scrobbler_status(void *context, const orca_scrobbler_status_view *status) {
    struct scrobbler_capture *capture = context;
    capture->calls += 1;
    capture->view = *status;
    capture->user_name_length = status->user_name.length;
    capture->last_error_length = status->last_error.length;
}

static int read_scrobbler(orca_runtime *runtime, orca_handle library, struct scrobbler_capture *capture) {
    memset(capture, 0, sizeof *capture);
    SMOKE_CHECK(orca_library_scrobbler_status(runtime, library, capture, capture_scrobbler_status) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(capture->calls == 1);
    return 0;
}

static int scrobbling_library_steps(orca_runtime *runtime) {
    orca_handle first;
    orca_handle second;
    SMOKE_CHECK(orca_library_open(runtime, "file:orca-c-smoke-scrobble-first?mode=memory&cache=shared", &first) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_open(runtime, "file:orca-c-smoke-scrobble-second?mode=memory&cache=shared", &second) ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_set_client_identity(runtime, "Orca C Smoke", "1.0", "https://orca.invalid") ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, first, 1, 1, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, second, 1, 1, 0) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(strcmp(orca_runtime_last_error(runtime), "orca_library_set_scrobbling: ScrobblingEnabledElsewhere") ==
                0);
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, first, 0, 0, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, second, 1, 1, 0) == ORCA_STATUS_OK);
    return 0;
}

static int scrobbling_smoke(orca_runtime *runtime, orca_handle library) {
    struct scrobbler_capture capture;
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, library, 1, 1, 0) == ORCA_STATUS_INVALID_STATE);
    SMOKE_CHECK(strcmp(orca_runtime_last_error(runtime), "orca_library_set_scrobbling: ClientIdentityRequired") == 0);
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, library, 2, 1, 0) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, library, 1, 2, 0) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, library, 1, 1, 2) == ORCA_STATUS_INVALID_ARGUMENT);
    SMOKE_CHECK(orca_library_scrobbler_status(runtime, library, 0, 0) == ORCA_STATUS_INVALID_ARGUMENT);

    uint64_t recorded = 0;
    SMOKE_CHECK(orca_library_listens_recorded(runtime, library, &recorded) == ORCA_STATUS_OK);
    if (read_scrobbler(runtime, library, &capture) != 0) return 1;
    SMOKE_CHECK(capture.view.enabled == 0 && capture.view.state == ORCA_SCROBBLER_STATE_DISABLED);
    SMOKE_CHECK(capture.view.recorded_total == recorded);
    SMOKE_CHECK(capture.view.pending == 0 && capture.view.delivered_total == 0);

    SMOKE_CHECK(orca_runtime_set_client_identity(runtime, "Orca C Smoke", "1.0", "https://orca.invalid") ==
                ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, library, 1, 1, 0) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_library_scrobbler_credentials_changed(runtime, library) == ORCA_STATUS_OK);
    if (read_scrobbler(runtime, library, &capture) != 0) return 1;
    SMOKE_CHECK(capture.view.enabled == 1);
    SMOKE_CHECK(capture.view.state == ORCA_SCROBBLER_STATE_IDLE || capture.view.state == ORCA_SCROBBLER_STATE_OFFLINE);
    SMOKE_CHECK(capture.view.pending == 0 && capture.view.delivered_total == 0);
    SMOKE_CHECK(capture.view.recorded_total == recorded && capture.view.dropped == 0);
    SMOKE_CHECK(capture.user_name_length == 0 && capture.last_error_length == 0);

    orca_handle stale = library;
    stale.generation += 1;
    SMOKE_CHECK(orca_library_set_scrobbling(runtime, stale, 1, 1, 0) == ORCA_STATUS_STALE_HANDLE);
    SMOKE_CHECK(orca_library_scrobbler_status(runtime, stale, &capture, capture_scrobbler_status) ==
                ORCA_STATUS_STALE_HANDLE);

    SMOKE_CHECK(orca_library_set_scrobbling(runtime, library, 0, 0, 0) == ORCA_STATUS_OK);
    if (read_scrobbler(runtime, library, &capture) != 0) return 1;
    SMOKE_CHECK(capture.view.enabled == 0 && capture.view.state == ORCA_SCROBBLER_STATE_DISABLED);
    SMOKE_CHECK(capture.view.delivered_total == 0 && capture.last_error_length == 0);

    orca_runtime *fresh = orca_runtime_create();
    SMOKE_CHECK(fresh != 0);
    int failed = scrobbling_library_steps(fresh) != 0;
    orca_runtime_destroy(fresh);
    SMOKE_CHECK(failed == 0);
    return 0;
}

static int read_maintenance(orca_runtime *runtime, orca_handle library, orca_maintenance_status *status) {
    memset(status, 0xff, sizeof *status);
    SMOKE_CHECK(orca_library_maintenance_status(runtime, library, status) == ORCA_STATUS_OK);
    return 0;
}

static int maintenance_library_steps(orca_runtime *runtime) {
    orca_handle library;
    SMOKE_CHECK(orca_library_open(runtime, "file:orca-c-smoke-maintenance?mode=memory&cache=shared", &library) ==
                ORCA_STATUS_OK);
    orca_maintenance_status status;
    orca_maintenance_options options;
    memset(&options, 0, sizeof options);
    options.enabled = 1;
    SMOKE_CHECK(orca_library_set_maintenance(runtime, library, &options) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_pump(runtime) == ORCA_STATUS_OK);
    if (read_maintenance(runtime, library, &status) != 0) return 1;
    SMOKE_CHECK(status.enabled == 1 && status.state == ORCA_MAINTENANCE_STATE_BLOCKED);
    SMOKE_CHECK(status.has_blocked == 1 && status.blocked == ORCA_MAINTENANCE_BLOCK_CLIENT_IDENTITY_REQUIRED);
    SMOKE_CHECK(status.has_next_due_ms == 1 && status.next_due_ms <= 300000);
    SMOKE_CHECK(status.has_last == 0 && status.units_run == 0);
    SMOKE_CHECK(orca_library_set_maintenance(runtime, library, 0) == ORCA_STATUS_OK);
    if (read_maintenance(runtime, library, &status) != 0) return 1;
    SMOKE_CHECK(status.enabled == 0 && status.state == ORCA_MAINTENANCE_STATE_OFF);
    return 0;
}

static int host_job_origin_is(orca_runtime *runtime, orca_handle job, int64_t root_id, uint8_t has_root_id) {
    uint8_t origin = 255;
    SMOKE_CHECK(orca_job_origin_get(runtime, job, &origin) == ORCA_STATUS_OK);
    SMOKE_CHECK(origin == ORCA_JOB_ORIGIN_HOST);
    int64_t reconciled = -1;
    uint8_t has_reconciled = 255;
    SMOKE_CHECK(orca_job_reconcile_root(runtime, job, &reconciled, &has_reconciled) == ORCA_STATUS_OK);
    SMOKE_CHECK(has_reconciled == has_root_id && reconciled == root_id);
    uint8_t state = ORCA_JOB_RUNNING;
    SMOKE_CHECK(await_job(runtime, job, &state, 0, 60000) == 1 && state == ORCA_JOB_SUCCEEDED);
    SMOKE_CHECK(orca_job_origin_get(runtime, job, &origin) == ORCA_STATUS_OK && origin == ORCA_JOB_ORIGIN_HOST);
    return 0;
}

static int maintenance_smoke(orca_runtime *runtime, orca_handle library, int64_t root_id) {
    orca_maintenance_status status;
    if (read_maintenance(runtime, library, &status) != 0) return 1;
    SMOKE_CHECK(status.enabled == 0 && status.state == ORCA_MAINTENANCE_STATE_OFF);
    SMOKE_CHECK(status.has_blocked == 0 && status.has_next_due_ms == 0 && status.has_last == 0);
    SMOKE_CHECK(status.units_run == 0 && status.last_stats.verified == 0);
    SMOKE_CHECK(orca_library_maintenance_status(runtime, library, 0) == ORCA_STATUS_INVALID_ARGUMENT);

    orca_maintenance_options options;
    memset(&options, 0, sizeof options);
    options.enabled = 2;
    SMOKE_CHECK(orca_library_set_maintenance(runtime, library, &options) == ORCA_STATUS_INVALID_ARGUMENT);
    options.enabled = 1;
    SMOKE_CHECK(orca_library_set_maintenance(runtime, library, &options) == ORCA_STATUS_OK);
    SMOKE_CHECK(orca_runtime_pump(runtime) == ORCA_STATUS_OK);
    if (read_maintenance(runtime, library, &status) != 0) return 1;
    SMOKE_CHECK(status.enabled == 1 && status.state == ORCA_MAINTENANCE_STATE_BLOCKED);
    SMOKE_CHECK(status.has_blocked == 1 && status.blocked == ORCA_MAINTENANCE_BLOCK_ACOUSTID_REQUIRED);
    SMOKE_CHECK(orca_library_set_maintenance(runtime, library, 0) == ORCA_STATUS_OK);
    if (read_maintenance(runtime, library, &status) != 0) return 1;
    SMOKE_CHECK(status.enabled == 0 && status.state == ORCA_MAINTENANCE_STATE_OFF);

    orca_handle job;
    SMOKE_CHECK(orca_library_start_scan(runtime, library, root_id, 0, &job) == ORCA_STATUS_OK);
    if (host_job_origin_is(runtime, job, 0, 0) != 0) return 1;
    SMOKE_CHECK(orca_library_start_reconcile(runtime, library, root_id, 0, 0, &job) == ORCA_STATUS_OK);
    if (host_job_origin_is(runtime, job, root_id, 1) != 0) return 1;
    SMOKE_CHECK(drain_events(runtime) == 0);

    uint8_t origin = 0;
    SMOKE_CHECK(orca_job_origin_get(runtime, job, 0) == ORCA_STATUS_INVALID_ARGUMENT);
    orca_handle stale = job;
    stale.generation += 1;
    SMOKE_CHECK(orca_job_origin_get(runtime, stale, &origin) == ORCA_STATUS_STALE_HANDLE);
    stale = library;
    stale.generation += 1;
    SMOKE_CHECK(orca_library_maintenance_status(runtime, stale, &status) == ORCA_STATUS_STALE_HANDLE);

    orca_runtime *fresh = orca_runtime_create();
    SMOKE_CHECK(fresh != 0);
    int failed = maintenance_library_steps(fresh) != 0;
    orca_runtime_destroy(fresh);
    SMOKE_CHECK(failed == 0);
    return 0;
}

int main(int argc, char **argv) {
    uint64_t device_id = 0;
    if (test_device_id(argc, argv, &device_id) != 0) return 234;
    printf("routing playback at device %llu\n", (unsigned long long)device_id);
    if (orca_version()[0] == 0) return 186;
    orca_runtime *runtime = orca_runtime_create();
    if (runtime == 0) return 1;
    if (orca_runtime_last_error(runtime)[0] != 0) return 187;
    if (open_wake_pipe() != 0) return 191;
    if (orca_runtime_set_wake_callback(runtime, on_wake, 0) != ORCA_STATUS_OK) return 192;

    orca_handle library;
    if (orca_library_open(runtime, "/nonexistent/orca-c-smoke/library.db", &library) ==
        ORCA_STATUS_OK)
        return 188;
    printf("failed open reports: %s\n", orca_runtime_last_error(runtime));
    if (strncmp(orca_runtime_last_error(runtime), "orca_library_open: ", 19) != 0 ||
        orca_runtime_last_error(runtime)[19] == 0)
        return 189;
    if (orca_library_open(runtime, "file:orca-c-smoke?mode=memory&cache=shared", &library) !=
        ORCA_STATUS_OK)
        return 8;
    if (orca_runtime_last_error(runtime)[0] != 0) return 190;

    uint64_t track_count = 1;
    if (orca_library_track_count(runtime, library, &track_count) != ORCA_STATUS_OK) return 9;
    if (track_count != 0) return 10;

    uint64_t health_count = 1;
    if (orca_library_health_issue_count(runtime, library, &health_count) != ORCA_STATUS_OK)
        return 11;
    if (health_count != 0) return 12;
    uint32_t issues = 0;
    if (orca_library_query_health_issues(runtime, library, 64, 0, &issues, count_issue) !=
        ORCA_STATUS_OK)
        return 13;
    if (issues != 0) return 14;
    struct health_summary_capture empty_summary;
    if (health_summary_collect(runtime, library, &empty_summary, 0) != 0) return 14;
    if (empty_summary.kinds != 0) return 14;

    /* Bounds are part of the contract, not a suggestion. */
    if (orca_library_query_tracks(runtime, library, 0, 0, 0, 0, 0, capture_track) !=
        ORCA_STATUS_INVALID_ARGUMENT)
        return 15;
    if (orca_library_query_tracks(runtime, library, 0, 0, 513, 0, 0, capture_track) !=
        ORCA_STATUS_INVALID_ARGUMENT)
        return 16;

    int64_t root_id = 0;
    char fixtures[4096];
    if (getcwd(fixtures, sizeof fixtures - 16) == 0) return 17;
    strcat(fixtures, "/fixtures/audio");
    if (orca_library_add_root(runtime, library, fixtures, &root_id) != ORCA_STATUS_OK)
        return 17;
    if (root_id <= 0) return 18;
    uint32_t roots = 0;
    if (orca_library_query_roots(runtime, library, 64, 0, &roots, count_root) != ORCA_STATUS_OK)
        return 19;
    if (roots != 1) return 20;

    orca_handle scan_job;
    orca_scan_options scan_options;
    memset(&scan_options, 0, sizeof scan_options);
    scan_options.batch_size = 16;
    if (orca_library_start_scan(runtime, library, root_id, &scan_options, &scan_job) !=
        ORCA_STATUS_OK)
        return 21;

    /* start_scan is nonblocking: this loop is the proof, because the job is
     * still running on its own worker while this thread polls. */
    uint8_t scan_state = ORCA_JOB_RUNNING;
    int settled = await_job(runtime, scan_job, &scan_state, 0, 60000);
    if (settled != 1) return 22;
    if (scan_state != ORCA_JOB_SUCCEEDED) return 23;

    orca_scan_stats stats;
    if (orca_library_scan_stats(runtime, scan_job, &stats) != ORCA_STATUS_OK) return 24;
    if (stats.files_seen == 0) return 25;
    if (stats.changed == 0) return 26;
    if (stats.cancelled != 0) return 27;
    /* The scan projects as it commits: a scan that leaves no tracks behind has
     * not made the library browsable. */
    if (stats.tracks_written == 0) return 28;

    if (orca_library_track_count(runtime, library, &track_count) != ORCA_STATUS_OK) return 29;
    if (track_count == 0) return 30;

    /* A standalone reprojection is the other direction: no filesystem walk. */
    orca_handle projection_job;
    if (orca_library_start_projection(runtime, library, &projection_job) != ORCA_STATUS_OK)
        return 31;
    uint8_t projection_state = ORCA_JOB_RUNNING;
    settled = await_job(runtime, projection_job, &projection_state, 0, 60000);
    if (settled != 1) return 32;
    if (projection_state != ORCA_JOB_SUCCEEDED) return 33;

    /* The scan above already probed every fixture, so a default backfill has
     * nothing to repair and must say so rather than reopening the library. A
     * forced one re-probes them all, which is the difference the flag names. */
    orca_handle backfill_job;
    orca_backfill_options backfill_options;
    memset(&backfill_options, 0, sizeof backfill_options);
    backfill_options.batch_size = 16;
    if (orca_library_start_property_backfill(runtime, library, &backfill_options,
                                             &backfill_job) != ORCA_STATUS_OK)
        return 139;
    uint8_t backfill_state = ORCA_JOB_RUNNING;
    settled = await_job(runtime, backfill_job, &backfill_state, 1, 60000);
    if (settled != 1) return 140;
    if (backfill_state != ORCA_JOB_SUCCEEDED) return 141;
    orca_scan_stats backfill_stats;
    if (orca_library_scan_stats(runtime, backfill_job, &backfill_stats) != ORCA_STATUS_OK)
        return 142;
    if (backfill_stats.changed != 0) return 143;

    backfill_options.force = 1;
    if (orca_library_start_property_backfill(runtime, library, &backfill_options,
                                             &backfill_job) != ORCA_STATUS_OK)
        return 144;
    backfill_state = ORCA_JOB_RUNNING;
    settled = await_job(runtime, backfill_job, &backfill_state, 1, 60000);
    if (settled != 1) return 145;
    if (backfill_state != ORCA_JOB_SUCCEEDED) return 146;
    if (orca_library_scan_stats(runtime, backfill_job, &backfill_stats) != ORCA_STATUS_OK)
        return 147;
    if (backfill_stats.files_seen == 0) return 148;
    if (backfill_stats.changed == 0) return 149;

    /* Nothing has been measured yet, so this has an honest total before it
     * starts and must measure every fixture. A second run must then find
     * nothing left: the selection is keyed on the results themselves, so a
     * file that has been measured stops being selected without any flag. */
    orca_handle analysis_job;
    orca_analysis_options analysis_options;
    memset(&analysis_options, 0, sizeof analysis_options);
    analysis_options.batch_size = 4;
    analysis_options.threads = 2;
    if (orca_analysis_available_threads() == 0) return 203;
    if (orca_analysis_default_threads() == 0) return 204;
    if (orca_analysis_default_threads() > orca_analysis_available_threads()) return 205;
    uint64_t unanalyzed = 0;
    if (orca_library_unanalyzed_count(runtime, library, &unanalyzed) != ORCA_STATUS_OK ||
        unanalyzed == 0 || unanalyzed != stats.files_seen - stats.unsupported - stats.errors)
        return 97;
    if (orca_library_start_analysis(runtime, library, &analysis_options, &analysis_job) !=
        ORCA_STATUS_OK)
        return 150;
    orca_job_snapshot analysis_planned;
    if (orca_job_snapshot_get(runtime, analysis_job, &analysis_planned) != ORCA_STATUS_OK)
        return 151;
    if (analysis_planned.kind != ORCA_JOB_KIND_ANALYSIS) return 152;
    if (analysis_planned.has_total == 0) return 153;
    if (analysis_planned.total_units == 0) return 154;
    if (analysis_planned.total_units != unanalyzed) return 98;
    uint8_t analysis_state = ORCA_JOB_RUNNING;
    settled = await_job(runtime, analysis_job, &analysis_state, 1, 120000);
    if (settled != 1) return 155;
    if (analysis_state != ORCA_JOB_SUCCEEDED) return 156;
    orca_scan_stats analysis_stats;
    if (orca_library_scan_stats(runtime, analysis_job, &analysis_stats) != ORCA_STATUS_OK)
        return 157;
    if (analysis_stats.files_seen == 0) return 158;
    if (analysis_stats.changed == 0) return 159;

    if (orca_library_start_analysis(runtime, library, &analysis_options, &analysis_job) !=
        ORCA_STATUS_OK)
        return 160;
    analysis_state = ORCA_JOB_RUNNING;
    settled = await_job(runtime, analysis_job, &analysis_state, 1, 120000);
    if (settled != 1) return 161;
    if (analysis_state != ORCA_JOB_SUCCEEDED) return 162;
    if (orca_library_scan_stats(runtime, analysis_job, &analysis_stats) != ORCA_STATUS_OK)
        return 163;
    if (analysis_stats.files_seen != 0) return 164;
    if (orca_library_unanalyzed_count(runtime, library, &unanalyzed) != ORCA_STATUS_OK ||
        unanalyzed != 0)
        return 99;

    /* The fixtures were just measured, so this can actually compare them. Its
     * denominator is every file in the Library, because it examines every row
     * -- including the ones no analysis reached, which it reports as
     * uncomparable rather than quietly counting as unique. Running it twice
     * must leave the same health rows behind, not twice as many. */
    orca_handle duplicate_job;
    orca_duplicate_scan_options duplicate_options;
    memset(&duplicate_options, 0, sizeof duplicate_options);
    duplicate_options.batch_size = 8;
    if (orca_library_start_duplicate_scan(runtime, library, &duplicate_options,
                                          &duplicate_job) != ORCA_STATUS_OK)
        return 170;
    orca_job_snapshot duplicate_planned;
    if (orca_job_snapshot_get(runtime, duplicate_job, &duplicate_planned) != ORCA_STATUS_OK)
        return 171;
    if (duplicate_planned.kind != ORCA_JOB_KIND_DUPLICATE_SCAN) return 172;
    if (duplicate_planned.has_total == 0) return 173;
    if (duplicate_planned.total_units == 0) return 174;
    uint8_t duplicate_state = ORCA_JOB_RUNNING;
    settled = await_job(runtime, duplicate_job, &duplicate_state, 1, 60000);
    if (settled != 1) return 175;
    if (duplicate_state != ORCA_JOB_SUCCEEDED) return 176;
    orca_scan_stats duplicate_stats;
    if (orca_library_scan_stats(runtime, duplicate_job, &duplicate_stats) != ORCA_STATUS_OK)
        return 177;
    if (duplicate_stats.files_seen == 0) return 178;
    /* files_seen accounts for every row exactly once, in exactly one bucket. */
    if (duplicate_stats.files_seen != duplicate_stats.tracks_written +
                                          duplicate_stats.releases_written +
                                          duplicate_stats.unchanged +
                                          duplicate_stats.unsupported +
                                          duplicate_stats.errors)
        return 179;
    uint64_t issues_after_first = 0;
    if (orca_library_health_issue_count(runtime, library, &issues_after_first) !=
        ORCA_STATUS_OK)
        return 180;

    if (orca_library_start_duplicate_scan(runtime, library, &duplicate_options,
                                          &duplicate_job) != ORCA_STATUS_OK)
        return 181;
    duplicate_state = ORCA_JOB_RUNNING;
    settled = await_job(runtime, duplicate_job, &duplicate_state, 1, 60000);
    if (settled != 1) return 182;
    if (duplicate_state != ORCA_JOB_SUCCEEDED) return 183;
    uint64_t issues_after_second = 0;
    if (orca_library_health_issue_count(runtime, library, &issues_after_second) !=
        ORCA_STATUS_OK)
        return 184;
    if (issues_after_second != issues_after_first) return 185;

    int watch_result = watch_smoke(runtime);
    if (watch_result != 0) return watch_result;

    struct track_capture capture;
    memset(&capture, 0, sizeof capture);
    if (orca_library_query_tracks(runtime, library, 0, 0, 512, 0, &capture, capture_track) !=
        ORCA_STATUS_OK)
        return 34;
    if (capture.count == 0) return 35;
    if (capture.with_duration == 0) return 36; /* decoded properties reached the view */
    if (capture.with_artist == 0) return 37;
    if (capture.first_playable_id == 0) return 38;
    /* Nothing has loved or rated a recording yet. */
    if (capture.with_feedback != 0 || capture.with_rating != 0) return 206;

    uint64_t artist_count = 0;
    if (orca_library_artist_count(runtime, library, &artist_count) != ORCA_STATUS_OK) return 100;
    if (artist_count == 0) return 101;
    uint64_t release_count = 0;
    if (orca_library_release_count(runtime, library, &release_count) != ORCA_STATUS_OK) return 102;
    if (release_count == 0) return 103;
    if (library_stats_smoke(runtime, library) != 0) return 1;
    if (provider_sources_smoke(runtime) != 0) return 1;

    /* Bounds are part of the contract here too. */
    if (orca_library_query_artists(runtime, library, 0, 0, 0, capture_artist) !=
        ORCA_STATUS_INVALID_ARGUMENT)
        return 104;
    if (orca_library_query_releases(runtime, library, -1, 513, 0, 0, capture_release) !=
        ORCA_STATUS_INVALID_ARGUMENT)
        return 105;

    struct artist_capture artists;
    memset(&artists, 0, sizeof artists);
    artists.sorted = 1;
    if (orca_library_query_artists(runtime, library, 512, 0, &artists, capture_artist) !=
        ORCA_STATUS_OK)
        return 106;
    if (artists.count == 0) return 107;
    if (artists.with_name != artists.count) return 108;
    if (!artists.sorted) return 109; /* sort_name order, not insertion order */
    if (artists.with_tracks == 0) return 110;
    if (artists.first_id == 0) return 111;

    /* One artist by id, through the same view. */
    struct artist_capture one_artist;
    memset(&one_artist, 0, sizeof one_artist);
    one_artist.sorted = 1;
    if (orca_library_artist_get(runtime, library, artists.first_id, &one_artist,
                                capture_artist) != ORCA_STATUS_OK)
        return 112;
    if (one_artist.count != 1) return 113;
    /* A missing artist is zero callbacks, not an error. */
    memset(&one_artist, 0, sizeof one_artist);
    if (orca_library_artist_get(runtime, library, 9999999, &one_artist, capture_artist) !=
        ORCA_STATUS_OK)
        return 114;
    if (one_artist.count != 0) return 115;

    struct release_capture releases;
    memset(&releases, 0, sizeof releases);
    if (orca_library_query_releases(runtime, library, artists.first_id, 512, 0, &releases,
                                    capture_release) != ORCA_STATUS_OK)
        return 116;
    if (releases.count == 0) return 117; /* the artist listing must reach an album */
    if (releases.first_id == 0) return 118;
    if (releases.longest_ms <= 0) return 119; /* durations really summed */

    struct release_capture one_release;
    memset(&one_release, 0, sizeof one_release);
    if (orca_library_release_get(runtime, library, releases.first_id, &one_release,
                                 capture_release) != ORCA_STATUS_OK)
        return 120;
    if (one_release.count != 1) return 121;

    /* The album view: this release's tracks, in disc-then-track order. */
    orca_track_query browse;
    memset(&browse, 0, sizeof browse);
    browse.artist_id = -1;
    browse.release_id = releases.first_id;
    browse.sort = ORCA_TRACK_SORT_TRACK_NUMBER;
    browse.limit = 512;
    struct order_capture album;
    memset(&album, 0, sizeof album);
    album.ordered = 1;
    if (orca_library_browse_tracks(runtime, library, &browse, &album, capture_order) !=
        ORCA_STATUS_OK)
        return 122;
    if (album.count == 0) return 123;
    if (!album.ordered) return 124;

    uint64_t matched = 0;
    if (orca_library_track_match_count(runtime, library, &browse, &matched) != ORCA_STATUS_OK)
        return 125;
    if (matched != album.count) return 126;

    /* The artist view: every track by that artist, by title, and its reverse.
     * Reversing must reverse the whole listing, tiebreaker included. */
    browse.artist_id = artists.first_id;
    browse.release_id = -1;
    browse.sort = ORCA_TRACK_SORT_TITLE;
    struct order_capture ascending;
    memset(&ascending, 0, sizeof ascending);
    ascending.ordered = 1;
    if (orca_library_browse_tracks(runtime, library, &browse, &ascending, capture_order) !=
        ORCA_STATUS_OK)
        return 127;
    if (ascending.count == 0) return 128;
    if (ascending.count > 64) return 129; /* the fixture corpus is small */

    browse.descending = 1;
    struct order_capture descending;
    memset(&descending, 0, sizeof descending);
    descending.ordered = 1;
    if (orca_library_browse_tracks(runtime, library, &browse, &descending, capture_order) !=
        ORCA_STATUS_OK)
        return 130;
    if (descending.count != ascending.count) return 131;
    for (uint32_t i = 0; i < ascending.count; i += 1) {
        if (ascending.ids[i] != descending.ids[descending.count - 1 - i]) return 132;
    }

    /* Paging that order two rows at a time must reproduce it exactly: no row
     * twice, none skipped, even where titles tie. */
    browse.descending = 0;
    browse.limit = 2;
    uint32_t walked = 0;
    for (uint32_t offset = 0; offset < ascending.count; offset += 2) {
        struct order_capture step;
        memset(&step, 0, sizeof step);
        step.ordered = 1;
        browse.offset = offset;
        if (orca_library_browse_tracks(runtime, library, &browse, &step, capture_order) !=
            ORCA_STATUS_OK)
            return 133;
        for (uint32_t i = 0; i < step.count; i += 1) {
            if (walked >= ascending.count) return 134;
            if (step.ids[i] != ascending.ids[walked]) return 135;
            walked += 1;
        }
    }
    if (walked != ascending.count) return 136;

    /* A sort byte this build does not know is refused, not defaulted. */
    memset(&browse, 0, sizeof browse);
    browse.artist_id = -1;
    browse.release_id = -1;
    browse.sort = 99;
    browse.limit = 8;
    if (orca_library_browse_tracks(runtime, library, &browse, &album, capture_order) !=
        ORCA_STATUS_INVALID_ARGUMENT)
        return 137;
    if (orca_library_browse_tracks(runtime, library, 0, &album, capture_order) !=
        ORCA_STATUS_INVALID_ARGUMENT)
        return 138;

    /* Every release order lists every Release once; nothing is loved yet. */
    orca_release_query release_query;
    memset(&release_query, 0, sizeof release_query);
    release_query.album_artist_id = -1;
    release_query.limit = 512;
    for (uint8_t sort = ORCA_RELEASE_SORT_TITLE; sort <= ORCA_RELEASE_SORT_LOVED; sort += 1) {
        release_query.sort = sort;
        struct release_capture sorted;
        memset(&sorted, 0, sizeof sorted);
        if (orca_library_browse_releases(runtime, library, &release_query, &sorted,
                                         capture_release) != ORCA_STATUS_OK ||
            sorted.count != release_count)
            return 207;
        uint64_t release_matches = 0;
        if (orca_library_release_count_matching(runtime, library, &release_query,
                                                &release_matches) != ORCA_STATUS_OK ||
            release_matches != release_count)
            return 208;
    }
    release_query.loved_only = 1;
    struct release_capture loved_releases;
    memset(&loved_releases, 0, sizeof loved_releases);
    uint64_t loved_release_count = 1;
    if (orca_library_browse_releases(runtime, library, &release_query, &loved_releases,
                                     capture_release) != ORCA_STATUS_OK ||
        loved_releases.count != 0 ||
        orca_library_release_count_matching(runtime, library, &release_query,
                                            &loved_release_count) != ORCA_STATUS_OK ||
        loved_release_count != 0)
        return 209;
    release_query.sort = 99;
    if (orca_library_browse_releases(runtime, library, &release_query, &loved_releases,
                                     capture_release) != ORCA_STATUS_INVALID_ARGUMENT ||
        orca_library_release_count_matching(runtime, library, 0, &loved_release_count) !=
            ORCA_STATUS_INVALID_ARGUMENT)
        return 241;

    /* Filtering artists by a scanned artist's name finds it; nonsense finds
     * none. */
    struct artist_name first_artist;
    memset(&first_artist, 0, sizeof first_artist);
    if (orca_library_artist_get(runtime, library, artists.first_id, &first_artist,
                                capture_artist_name) != ORCA_STATUS_OK ||
        first_artist.count != 1)
        return 242;
    orca_artist_query artist_query;
    memset(&artist_query, 0, sizeof artist_query);
    artist_query.filter.pointer = first_artist.name;
    artist_query.filter.length = strlen(first_artist.name);
    artist_query.limit = 512;
    struct artist_capture filtered;
    memset(&filtered, 0, sizeof filtered);
    filtered.sorted = 1;
    uint64_t artist_matches = 0;
    if (orca_library_browse_artists(runtime, library, &artist_query, &filtered,
                                    capture_artist) != ORCA_STATUS_OK ||
        filtered.count == 0 ||
        orca_library_artist_count_matching(runtime, library, &artist_query, &artist_matches) !=
            ORCA_STATUS_OK ||
        artist_matches != filtered.count)
        return 242;
    artist_query.filter.pointer = "zzqx-no-such-artist";
    artist_query.filter.length = strlen(artist_query.filter.pointer);
    memset(&filtered, 0, sizeof filtered);
    if (orca_library_browse_artists(runtime, library, &artist_query, &filtered,
                                    capture_artist) != ORCA_STATUS_OK ||
        filtered.count != 0 ||
        orca_library_artist_count_matching(runtime, library, &artist_query, &artist_matches) !=
            ORCA_STATUS_OK ||
        artist_matches != 0)
        return 243;

    struct summary_capture summary;
    memset(&summary, 0, sizeof summary);
    if (orca_library_track_get(runtime, library, capture.first_playable_id, &summary,
                               capture_summary) != ORCA_STATUS_OK ||
        summary.count != 1 || summary.track_id != capture.first_playable_id ||
        summary.has_release_id != 1)
        return 244;
    memset(&summary, 0, sizeof summary);
    if (orca_library_track_get(runtime, library, 999999999, &summary, capture_summary) !=
            ORCA_STATUS_NOT_FOUND ||
        summary.count != 0)
        return 245;

    /* A FLAC fixture's details come from what the scan recorded. */
    memset(&browse, 0, sizeof browse);
    browse.artist_id = -1;
    browse.release_id = -1;
    browse.limit = 64;
    struct order_capture every_track;
    memset(&every_track, 0, sizeof every_track);
    if (orca_library_browse_tracks(runtime, library, &browse, &every_track, capture_order) !=
            ORCA_STATUS_OK ||
        every_track.count == 0 || every_track.count > 64)
        return 246;
    struct details_capture flac;
    memset(&flac, 0, sizeof flac);
    for (uint32_t i = 0; i < every_track.count && !flac.is_flac; i += 1) {
        memset(&flac, 0, sizeof flac);
        if (orca_library_track_details(runtime, library, every_track.ids[i], &flac,
                                       capture_details) != ORCA_STATUS_OK ||
            flac.count != 1)
            return 246;
    }
    if (!flac.is_flac || !flac.has_sample_rate || flac.file_missing != 0) return 247;
    memset(&flac, 0, sizeof flac);
    if (orca_library_track_details(runtime, library, 999999999, &flac, capture_details) !=
            ORCA_STATUS_NOT_FOUND ||
        flac.count != 0)
        return 248;

    /* Nothing has been played yet. */
    orca_play_stats play_stats;
    memset(&play_stats, 0xff, sizeof play_stats);
    if (orca_library_track_play_stats(runtime, library, capture.first_playable_id,
                                      &play_stats) != ORCA_STATUS_OK ||
        play_stats.play_count != 0 || play_stats.has_last_played_at != 0)
        return 249;
    uint64_t listens = 1;
    if (orca_library_listens_recorded(runtime, library, &listens) != ORCA_STATUS_OK ||
        listens != 0)
        return 250;

    /* Rating and love orders list every Track; no Track is loved yet. */
    browse.limit = 512;
    uint64_t track_matches = 0;
    for (uint8_t sort = ORCA_TRACK_SORT_RATING; sort <= ORCA_TRACK_SORT_LOVED; sort += 1) {
        browse.sort = sort;
        struct track_capture sorted_tracks;
        memset(&sorted_tracks, 0, sizeof sorted_tracks);
        if (orca_library_browse_tracks(runtime, library, &browse, &sorted_tracks,
                                       capture_track) != ORCA_STATUS_OK ||
            sorted_tracks.count != capture.count)
            return 251;
    }
    browse.loved_only = 1;
    if (orca_library_track_match_count(runtime, library, &browse, &track_matches) !=
            ORCA_STATUS_OK ||
        track_matches != 0)
        return 251;

    /* Every Track carries its file's facts; nothing is played, and the two
     * explicit fixtures say so. */
    orca_track_query_v2 facts_query;
    memset(&facts_query, 0, sizeof facts_query);
    facts_query.sort = ORCA_TRACK_SORT_PLAY_COUNT;
    facts_query.descending = 1;
    facts_query.limit = 512;
    struct facts_capture facts;
    memset(&facts, 0, sizeof facts);
    if (orca_library_browse_tracks_v2(runtime, library, &facts_query, &facts, capture_facts) !=
            ORCA_STATUS_OK ||
        facts.count != capture.count || facts.with_facts == 0 || facts.played != 0 ||
        facts.explicit_count != 2)
        return 252;
    for (uint8_t sort = ORCA_TRACK_SORT_LAST_PLAYED; sort <= ORCA_TRACK_SORT_YEAR; sort += 1) {
        facts_query.sort = sort;
        struct facts_capture sorted_facts;
        memset(&sorted_facts, 0, sizeof sorted_facts);
        if (orca_library_browse_tracks_v2(runtime, library, &facts_query, &sorted_facts,
                                          capture_facts) != ORCA_STATUS_OK ||
            sorted_facts.count != capture.count)
            return 253;
    }
    facts_query.has_genre_id = 1;
    facts_query.genre_id = 999999999;
    struct facts_capture genre_facts;
    memset(&genre_facts, 0, sizeof genre_facts);
    if (orca_library_browse_tracks_v2(runtime, library, &facts_query, &genre_facts,
                                      capture_facts) != ORCA_STATUS_OK ||
        genre_facts.count != 0 ||
        orca_library_browse_tracks_v2(runtime, library, 0, &facts, capture_facts) !=
            ORCA_STATUS_INVALID_ARGUMENT)
        return 254;

    /* Each filter keeps the Tracks the unfiltered facts say it should, and
     * the v2 count agrees with the listing. */
    struct {
        uint8_t format;
        uint8_t explicit_only;
        uint32_t min_sample_rate;
        uint8_t has_year_min;
        int32_t year_min;
        uint32_t expected;
    } filters[] = {
        {ORCA_TRACK_FORMAT_LOSSLESS, 0, 0, 0, 0, facts.lossless},
        {ORCA_TRACK_FORMAT_LOSSY, 0, 0, 0, 0, facts.lossy},
        {ORCA_TRACK_FORMAT_ANY, 1, 0, 0, 0, 2},
        {ORCA_TRACK_FORMAT_ANY, 0, 1, 0, 0, facts.with_rate},
        {ORCA_TRACK_FORMAT_ANY, 0, 0, 1, 10000, 0},
    };
    if (facts.lossless == 0 || facts.lossy == 0) return 257;
    for (size_t index = 0; index < sizeof filters / sizeof filters[0]; index += 1) {
        memset(&facts_query, 0, sizeof facts_query);
        facts_query.sort = ORCA_TRACK_SORT_TITLE;
        facts_query.limit = 512;
        facts_query.format = filters[index].format;
        facts_query.explicit_only = filters[index].explicit_only;
        facts_query.min_sample_rate = filters[index].min_sample_rate;
        facts_query.has_year_min = filters[index].has_year_min;
        facts_query.year_min = filters[index].year_min;
        struct facts_capture filtered;
        memset(&filtered, 0, sizeof filtered);
        uint64_t filtered_count = 0;
        if (orca_library_browse_tracks_v2(runtime, library, &facts_query, &filtered,
                                          capture_facts) != ORCA_STATUS_OK ||
            orca_library_track_match_count_v2(runtime, library, &facts_query, &filtered_count) !=
                ORCA_STATUS_OK ||
            filtered_count != filtered.count || filtered.count != filters[index].expected)
            return 257;
    }
    facts_query.format = 3;
    uint64_t rejected_count = 0;
    if (orca_library_browse_tracks_v2(runtime, library, &facts_query, &facts, capture_facts) !=
            ORCA_STATUS_INVALID_ARGUMENT ||
        orca_library_track_match_count_v2(runtime, library, &facts_query, &rejected_count) !=
            ORCA_STATUS_INVALID_ARGUMENT ||
        orca_library_track_match_count_v2(runtime, library, 0, &rejected_count) !=
            ORCA_STATUS_INVALID_ARGUMENT)
        return 258;
    struct extra_capture extra;
    memset(&extra, 0, sizeof extra);
    if (orca_library_track_details_v2(runtime, library, facts.explicit_id, &extra,
                                      capture_extra) != ORCA_STATUS_OK ||
        extra.count != 1 || extra.explicit != ORCA_EXPLICIT_EXPLICIT ||
        !extra.has_track_total || !extra.has_added_at || !extra.has_modified_at)
        return 255;
    memset(&extra, 0, sizeof extra);
    if (orca_library_track_details_v2(runtime, library, 999999999, &extra, capture_extra) !=
            ORCA_STATUS_NOT_FOUND ||
        extra.count != 0)
        return 256;

    if (library_edits_smoke(runtime, library, capture.first_playable_id, releases.first_id) != 0)
        return 1;
    if (genre_smoke(runtime, library, capture.first_playable_id) != 0) return 1;

    orca_handle player;
    if (orca_player_create(runtime, &player) != ORCA_STATUS_OK) return 2;

    /* A Player with no playable source and no attached output must be
     * rejected, not reported as PLAYING. */
    if (orca_player_play(runtime, player) != ORCA_STATUS_INVALID_STATE) return 3;
    orca_player_status status;
    if (orca_player_status_get(runtime, player, &status) != ORCA_STATUS_OK) return 4;
    if (status.transport != ORCA_TRANSPORT_STOPPED) return 5;

    /* Nor can it enqueue before it knows which Library ids belong to. */
    int64_t ids[1];
    ids[0] = capture.first_playable_id;
    if (orca_player_enqueue_tracks(runtime, player, ids, 1) != ORCA_STATUS_INVALID_STATE)
        return 39;
    if (orca_player_set_library(runtime, player, library) != ORCA_STATUS_OK) return 40;

    uint32_t devices = 0;
    if (orca_enumerate_output_devices(runtime, &devices, count_device) != ORCA_STATUS_OK)
        return 41;
    struct device_kind_search kind_search = {.id = device_id};
    if (orca_enumerate_output_devices_v2(runtime, &kind_search, find_device_kind) !=
            ORCA_STATUS_OK ||
        orca_enumerate_output_devices_v2(runtime, 0, 0) != ORCA_STATUS_INVALID_ARGUMENT)
        return 259;
    if (device_id != 0 && (!kind_search.found || kind_search.kind != ORCA_DEVICE_KIND_VIRTUAL))
        return 260;

    orca_handle zone;
    if (orca_player_open_default_output(runtime, player, device_id, &zone) !=
        ORCA_STATUS_OK)
        return 42;

    if (orca_player_set_volume(runtime, player, 0.25f) != ORCA_STATUS_OK) return 43;
    float volume = 0;
    if (orca_player_volume(runtime, player, &volume) != ORCA_STATUS_OK) return 44;
    if (volume < 0.24f || volume > 0.26f) return 45;
    /* Loudness correction is on by default and a host can switch it to album
     * or off. An unrecognized mode is refused rather than silently taken for
     * one of the three that exist. */
    uint8_t replay_gain_mode = 255;
    if (orca_player_replay_gain_mode(runtime, player, &replay_gain_mode) != ORCA_STATUS_OK)
        return 165;
    if (replay_gain_mode != ORCA_REPLAY_GAIN_TRACK) return 166;
    if (orca_player_set_replay_gain_mode(runtime, player, 7) != ORCA_STATUS_INVALID_ARGUMENT)
        return 167;
    if (orca_player_set_replay_gain_mode(runtime, player, ORCA_REPLAY_GAIN_ALBUM) !=
        ORCA_STATUS_OK)
        return 261;
    if (orca_player_replay_gain_mode(runtime, player, &replay_gain_mode) != ORCA_STATUS_OK)
        return 262;
    if (replay_gain_mode != ORCA_REPLAY_GAIN_ALBUM) return 263;
    if (orca_player_set_replay_gain_mode(runtime, player, ORCA_REPLAY_GAIN_OFF) !=
        ORCA_STATUS_OK)
        return 168;
    if (orca_player_replay_gain_mode(runtime, player, &replay_gain_mode) != ORCA_STATUS_OK)
        return 169;
    if (replay_gain_mode != ORCA_REPLAY_GAIN_OFF) return 170;

    if (orca_player_set_repeat(runtime, player, ORCA_REPEAT_ALL) != ORCA_STATUS_OK) return 46;
    if (orca_player_set_repeat(runtime, player, 9) != ORCA_STATUS_INVALID_ARGUMENT) return 47;
    if (orca_player_set_shuffle(runtime, player, 0) != ORCA_STATUS_OK) return 48;

    /* Play by id, through the control lane, correlated by request id. The
     * submission itself wakes the host. */
    unsigned wakes_before_play = atomic_load(&wake_calls);
    uint64_t request_id = 0;
    if (orca_player_play_track(runtime, player, capture.first_playable_id, &request_id) !=
        ORCA_STATUS_OK)
        return 49;
    if (request_id == 0) return 50;

    int completed = 0;
    uint8_t outcome = 255;
    long play_deadline = now_ms() + 5000;
    while (!completed && now_ms() < play_deadline) {
        if (wait_for_runtime(runtime, play_deadline) != 0) return 51;
        for (;;) {
            orca_event event;
            uint32_t remaining = 0;
            if (orca_runtime_poll_event(runtime, &event, &remaining) != ORCA_STATUS_OK) return 52;
            if (event.kind == ORCA_EVENT_NONE) break;
            if (event.kind == ORCA_EVENT_COMMAND_COMPLETED &&
                event.payload.command_completed.request_id == request_id) {
                completed = 1;
                outcome = event.payload.command_completed.outcome;
                break;
            }
        }
    }
    if (!completed) return 53;
    if (outcome != ORCA_OUTCOME_TRACK_PLAYING) return 54;
    if (atomic_load(&wake_calls) == wakes_before_play) return 193;
    /* Engine and listen worker threads now read the callback without a lock. */
    if (orca_runtime_set_wake_callback(runtime, on_wake, 0) != ORCA_STATUS_INVALID_STATE)
        return 194;

    /* Correction is off for this Player, so the render lane's multiplier is
     * exactly the volume the host set. Anything else here would mean an
     * unrequested correction had reached the audio. */
    float effective_gain = 0;
    if (orca_player_effective_gain(runtime, player, &effective_gain) != ORCA_STATUS_OK)
        return 171;
    if (effective_gain < 0.2499f || effective_gain > 0.2501f) return 172;

    if (orca_player_status_get(runtime, player, &status) != ORCA_STATUS_OK) return 55;
    if (status.transport != ORCA_TRANSPORT_PLAYING) return 56;
    if (status.has_track == 0) return 57;
    if (status.track_id != capture.first_playable_id) return 58;
    if (status.queue_length != 1) return 59;
    if (status.repeat != ORCA_REPEAT_ALL) return 60;
    if (status.duration_ms == 0) return 61;

    struct now_playing_capture playing;
    memset(&playing, 0, sizeof playing);
    if (orca_player_now_playing(runtime, player, &playing, capture_now_playing) !=
        ORCA_STATUS_OK)
        return 62;
    if (playing.count != 1) return 63;
    if (playing.track_id != capture.first_playable_id) return 64;
    if (playing.title_length == 0) return 65;

    struct queue_capture queued;
    memset(&queued, 0, sizeof queued);
    if (orca_player_query_queue(runtime, player, 512, 0, &queued, capture_queue_entry) !=
        ORCA_STATUS_OK)
        return 66;
    if (queued.count != 1) return 67;
    if (queued.current_seen != 1) return 68;

    /* Position only advances when audio is actually rendering. On a machine
     * with no audio server the Zone never reaches ACTIVE, and the claim is
     * skipped rather than faked. */
    int rendered = 0;
    int saw_position_event = 0;
    long render_deadline = now_ms() + 4000;
    while (now_ms() < render_deadline) {
        if (wait_for_runtime(runtime, render_deadline) != 0) return 69;
        for (;;) {
            orca_event event;
            uint32_t remaining = 0;
            if (orca_runtime_poll_event(runtime, &event, &remaining) != ORCA_STATUS_OK) return 70;
            if (event.kind == ORCA_EVENT_NONE) break;
            if (event.kind == ORCA_EVENT_PLAYER_POSITION) saw_position_event = 1;
        }
        if (orca_player_status_get(runtime, player, &status) != ORCA_STATUS_OK) return 71;
        if (status.position_ms > 0) rendered = 1;
        /* Position hints are coalesced and published on a 100 ms cadence, so
         * the loop keeps running past the first moved sample to see one. */
        if (rendered && saw_position_event) break;
    }

    orca_zone_status zone_status;
    if (orca_zone_status_get(runtime, zone, &zone_status) != ORCA_STATUS_OK) return 72;
    if (!rendered && zone_status.output_state == ORCA_OUTPUT_ACTIVE) {
        /* An active output that never moved the clock is a real failure. */
        return 73;
    }
    if (rendered && !saw_position_event) {
        /* Telemetry is coalesced, not dropped: audio that played must have
         * produced at least one position hint. */
        return 74;
    }

    orca_handle second_player;
    if (orca_player_create(runtime, &second_player) != ORCA_STATUS_OK) return 235;
    if (orca_zone_attach_player(runtime, zone, second_player) != ORCA_STATUS_OK) return 236;
    if (orca_zone_status_get(runtime, zone, &zone_status) != ORCA_STATUS_OK) return 237;
    if (zone_status.output_state == ORCA_OUTPUT_ACTIVE) return 238;
    if (orca_zone_attach_player(runtime, zone, player) != ORCA_STATUS_OK) return 239;
    if (orca_player_destroy(runtime, second_player) != ORCA_STATUS_OK) return 240;

    if (orca_player_pause(runtime, player) != ORCA_STATUS_OK) return 75;
    if (orca_player_status_get(runtime, player, &status) != ORCA_STATUS_OK) return 76;
    if (status.transport != ORCA_TRANSPORT_PAUSED) return 77;

    uint64_t epoch_before = status.epoch;
    uint64_t epoch_after = 0;
    if (orca_player_seek_ms(runtime, player, 50, &epoch_after) != ORCA_STATUS_OK) return 78;
    if (epoch_after <= epoch_before) return 79;

    uint8_t moved = 9;
    /* One entry, repeat all: next wraps back onto the same entry. */
    if (orca_player_next(runtime, player, &moved) != ORCA_STATUS_OK) return 80;
    if (moved != 1) return 81;

    if (orca_player_set_repeat(runtime, player, ORCA_REPEAT_OFF) != ORCA_STATUS_OK) return 82;
    if (orca_player_next(runtime, player, &moved) != ORCA_STATUS_OK) return 83;
    if (moved != 0) return 84;

    /* Position is anchored to the audible entry, not to the epoch. Two copies
     * of one entry, so both report the same duration and the only thing that
     * can push position past the end is the queue advancing. A gapless advance
     * deliberately keeps a single epoch, so a position derived from
     * frames-since-epoch alone would keep climbing straight through the
     * second entry. Conditional on audio really rendering, like the claim
     * above: with no audio server nothing ever advances. */
    if (rendered) {
        int64_t pair[2];
        pair[0] = capture.first_playable_id;
        pair[1] = capture.first_playable_id;
        if (orca_player_play_tracks(runtime, player, pair, 2, 0) != ORCA_STATUS_OK) return 91;
        int advanced = 0;
        int past_end = 0;
        uint64_t last_position = 0;
        long gapless_deadline = now_ms() + 3000;
        long last_moved = now_ms();
        while (now_ms() < gapless_deadline) {
            /* A clock that has stopped for good wakes nobody, so each wait
             * ends where the position would count as settled. */
            long settle_at = last_moved + 300;
            if (wait_for_runtime(runtime, settle_at < gapless_deadline ? settle_at
                                                                       : gapless_deadline) < 0)
                return 92;
            if (drain_events(runtime) != 0) return 93;
            if (orca_player_status_get(runtime, player, &status) != ORCA_STATUS_OK) return 94;
            if (status.duration_ms > 0 && status.position_ms > status.duration_ms + 100)
                past_end = 1;
            if (status.queue_index == 1) advanced = 1;
            if (status.position_ms != last_position) {
                last_position = status.position_ms;
                last_moved = now_ms();
            }
            /* The whole queue has played out once the second entry is current
             * and the clock has stopped moving. */
            if (advanced && now_ms() - last_moved >= 300) break;
        }
        /* Elapsed time that runs past the end of the track it belongs to is
         * exactly what a transport bar cannot survive. */
        if (past_end) return 95;
        if (!advanced) return 96;
    }

    if (queue_smoke(runtime, library, player) != 0) return 1;
    if (dsp_smoke(runtime, library, player) != 0) return 1;
    if (parametric_smoke(runtime, library, player) != 0) return 1;
    if (playlist_smoke(runtime, library, player) != 0) return 1;
    if (folder_smoke(runtime, library, player, root_id) != 0) return 1;
    if (artwork_smoke(runtime, library) != 0) return 1;
    if (lyrics_smoke(runtime, library) != 0) return 1;
    if (coverless_release_smoke(runtime) != 0) return 1;
    if (health_smoke(runtime, library) != 0) return 1;
    if (tag_write_smoke(runtime, library) != 0) return 1;
    if (provider_smoke(runtime, library) != 0) return 1;
    if (matching_smoke(runtime, library, capture.first_playable_id, releases.first_id) != 0) return 1;
    if (acoustid_submission_smoke(runtime, library) != 0) return 1;
    if (scrobbling_smoke(runtime, library) != 0) return 1;
    if (maintenance_smoke(runtime, library, root_id) != 0) return 1;
    if (artist_smoke(runtime, library) != 0) return 1;

    if (orca_player_clear_queue(runtime, player) != ORCA_STATUS_OK) return 85;
    if (orca_player_status_get(runtime, player, &status) != ORCA_STATUS_OK) return 86;
    if (status.queue_length != 0) return 87;
    if (status.transport != ORCA_TRANSPORT_STOPPED) return 88;

    /* Idle costs nothing. With the queue cleared, an output still open, and
     * engine and listen worker threads alive, liborca asks for no timeout and
     * wakes the host not once. A failure here is a wake leaking from some
     * thread, not a timing margin to widen. */
    long settle_deadline = now_ms() + 300;
    while (now_ms() < settle_deadline) {
        if (wait_for_runtime(runtime, settle_deadline) < 0) return 195;
        if (drain_events(runtime) != 0) return 196;
    }
    if (orca_runtime_pump(runtime) != ORCA_STATUS_OK) return 197;
    if (drain_events(runtime) != 0) return 198;
    drain_wake_pipe();
    unsigned wakes_when_idle = atomic_load(&wake_calls);
    int64_t idle_timeout = 0;
    if (orca_runtime_pump_timeout(runtime, &idle_timeout) != ORCA_STATUS_OK) return 199;
    if (idle_timeout != ORCA_PUMP_NO_TIMEOUT) return 200;
    struct pollfd idle_wake;
    idle_wake.fd = wake_pipe[0];
    idle_wake.events = POLLIN;
    idle_wake.revents = 0;
    if (poll(&idle_wake, 1, 300) != 0) return 201;
    if (atomic_load(&wake_calls) != wakes_when_idle) return 202;

    if (orca_zone_destroy(runtime, zone) != ORCA_STATUS_OK) return 89;
    if (orca_player_destroy(runtime, player) != ORCA_STATUS_OK) return 6;
    if (orca_player_status_get(runtime, player, &status) != ORCA_STATUS_STALE_HANDLE) return 7;
    if (orca_library_close(runtime, library) != ORCA_STATUS_OK) return 90;

    orca_runtime_destroy(runtime);
    atomic_store(&runtime_destroyed, 1);
    close(wake_pipe[0]);
    close(wake_pipe[1]);
    return 0;
}
