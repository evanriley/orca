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

    /* Bounds are part of the contract, not a suggestion. */
    if (orca_library_query_tracks(runtime, library, 0, 0, 0, 0, 0, capture_track) !=
        ORCA_STATUS_INVALID_ARGUMENT)
        return 15;
    if (orca_library_query_tracks(runtime, library, 0, 0, 513, 0, 0, capture_track) !=
        ORCA_STATUS_INVALID_ARGUMENT)
        return 16;

    int64_t root_id = 0;
    if (orca_library_add_root(runtime, library, "fixtures/audio", &root_id) != ORCA_STATUS_OK)
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

    orca_handle zone;
    if (orca_player_open_default_output(runtime, player, device_id, &zone) !=
        ORCA_STATUS_OK)
        return 42;

    if (orca_player_set_volume(runtime, player, 0.25f) != ORCA_STATUS_OK) return 43;
    float volume = 0;
    if (orca_player_volume(runtime, player, &volume) != ORCA_STATUS_OK) return 44;
    if (volume < 0.24f || volume > 0.26f) return 45;
    /* Loudness correction is on by default and a host can turn it off. An
     * unrecognized mode is refused rather than silently taken for one of the
     * two that exist. */
    uint8_t replay_gain_mode = 255;
    if (orca_player_replay_gain_mode(runtime, player, &replay_gain_mode) != ORCA_STATUS_OK)
        return 165;
    if (replay_gain_mode != ORCA_REPLAY_GAIN_TRACK) return 166;
    if (orca_player_set_replay_gain_mode(runtime, player, 7) != ORCA_STATUS_INVALID_ARGUMENT)
        return 167;
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
