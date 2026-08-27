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

/* nanosleep under -std=c11 */
#define _POSIX_C_SOURCE 200809L

#include "orca.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Which output this test opens.
 *
 * Device 0 is the server default, which on a developer's machine is their
 * actual speakers - so `zig build test` used to be audible every single run,
 * which on a machine somebody is working at is unacceptable.
 *
 * Selection order:
 *   1. ORCA_TEST_DEVICE, if set, names an orca device id explicitly.
 *   2. Otherwise a sink published by scripts/silent-sink.sh, found by name.
 *      This is the case that matters: it makes `zig build test` silent with
 *      no ceremony, for anyone who has ever run that script.
 *   3. Otherwise device 0, because a CI host has no silent sink and the test
 *      must still exercise a real output rather than skipping.
 *
 * A null sink is a real PipeWire sink, so this weakens nothing: quantum
 * negotiation, render callbacks and underrun accounting all still run. */
#define SILENT_SINK_PREFIX "Orca Silent Test Sink"

struct silent_device_search {
    uint64_t id;
    int found;
};

static void note_silent_device(void *context, const orca_device_view *device) {
    struct silent_device_search *search = context;
    size_t prefix_length = sizeof(SILENT_SINK_PREFIX) - 1;
    if (search->found) return;
    if (device->name.length < prefix_length) return;
    if (memcmp(device->name.pointer, SILENT_SINK_PREFIX, prefix_length) != 0) return;
    search->id = device->id;
    search->found = 1;
}

static uint64_t test_device_id(orca_runtime *runtime) {
    struct silent_device_search search;
    const char *configured = getenv("ORCA_TEST_DEVICE");
    if (configured != 0 && configured[0] != 0) {
        return (uint64_t)strtoull(configured, 0, 10);
    }

    search.id = 0;
    search.found = 0;
    if (orca_enumerate_output_devices(runtime, &search, note_silent_device) ==
            ORCA_STATUS_OK &&
        search.found) {
        printf("routing playback at silent device %llu\n",
               (unsigned long long)search.id);
        return search.id;
    }

    printf("no silent sink found; opening the default output (this is audible)\n");
    return 0;
}

static void sleep_ms(long milliseconds) {
    struct timespec duration;
    duration.tv_sec = milliseconds / 1000;
    duration.tv_nsec = (milliseconds % 1000) * 1000000L;
    nanosleep(&duration, 0);
}

struct track_capture {
    uint32_t count;
    int64_t first_playable_id;
    uint32_t with_duration;
    uint32_t with_artist;
};

static void capture_track(void *context, const orca_track_view *track) {
    struct track_capture *capture = context;
    capture->count += 1;
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

int main(void) {
    orca_runtime *runtime = orca_runtime_create();
    if (runtime == 0) return 1;

    orca_handle library;
    if (orca_library_open(runtime, "file:orca-c-smoke?mode=memory&cache=shared", &library) !=
        ORCA_STATUS_OK)
        return 8;

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

    /* ---- roots and scanning as a job ---- */
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
    int settled = 0;
    for (int elapsed = 0; elapsed < 60000; elapsed += 10) {
        settled = job_settled(runtime, scan_job, &scan_state, 0);
        if (settled != 0) break;
        sleep_ms(10);
    }
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
    settled = 0;
    for (int elapsed = 0; elapsed < 60000; elapsed += 10) {
        settled = job_settled(runtime, projection_job, &projection_state, 0);
        if (settled != 0) break;
        sleep_ms(10);
    }
    if (settled != 1) return 32;
    if (projection_state != ORCA_JOB_SUCCEEDED) return 33;

    /* ---- the property backfill as a job ---- */
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
    settled = 0;
    for (int elapsed = 0; elapsed < 60000; elapsed += 10) {
        settled = job_settled(runtime, backfill_job, &backfill_state, 1);
        if (settled != 0) break;
        sleep_ms(10);
    }
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
    settled = 0;
    for (int elapsed = 0; elapsed < 60000; elapsed += 10) {
        settled = job_settled(runtime, backfill_job, &backfill_state, 1);
        if (settled != 0) break;
        sleep_ms(10);
    }
    if (settled != 1) return 145;
    if (backfill_state != ORCA_JOB_SUCCEEDED) return 146;
    if (orca_library_scan_stats(runtime, backfill_job, &backfill_stats) != ORCA_STATUS_OK)
        return 147;
    if (backfill_stats.files_seen == 0) return 148;
    if (backfill_stats.changed == 0) return 149;

    /* ---- the extended track view ---- */
    struct track_capture capture;
    memset(&capture, 0, sizeof capture);
    if (orca_library_query_tracks(runtime, library, 0, 0, 512, 0, &capture, capture_track) !=
        ORCA_STATUS_OK)
        return 34;
    if (capture.count == 0) return 35;
    if (capture.with_duration == 0) return 36; /* decoded properties reached the view */
    if (capture.with_artist == 0) return 37;
    if (capture.first_playable_id == 0) return 38;


    /* ---- browsing: artists -> that artist's releases -> that release's
     * tracks, which is the path an album view walks ---- */
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

    /* ---- transport ---- */
    orca_handle player;
    if (orca_player_create(runtime, &player) != ORCA_STATUS_OK) return 2;

    /* INVERTED, and this is the milestone: a Player with no playable source
     * and no attached output must be REJECTED, not reported as PLAYING. */
    if (orca_player_play(runtime, player) != ORCA_STATUS_INVALID_STATE) return 3;
    orca_player_state_snapshot snapshot;
    if (orca_player_snapshot(runtime, player, &snapshot) != ORCA_STATUS_OK) return 4;
    if (snapshot.state != ORCA_TRANSPORT_STOPPED) return 5;

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
    if (orca_player_open_default_output(runtime, player, test_device_id(runtime), &zone) !=
        ORCA_STATUS_OK)
        return 42;

    if (orca_player_set_volume(runtime, player, 0.25f) != ORCA_STATUS_OK) return 43;
    float volume = 0;
    if (orca_player_volume(runtime, player, &volume) != ORCA_STATUS_OK) return 44;
    if (volume < 0.24f || volume > 0.26f) return 45;
    if (orca_player_set_repeat(runtime, player, ORCA_REPEAT_ALL) != ORCA_STATUS_OK) return 46;
    if (orca_player_set_repeat(runtime, player, 9) != ORCA_STATUS_INVALID_ARGUMENT) return 47;
    if (orca_player_set_shuffle(runtime, player, 0) != ORCA_STATUS_OK) return 48;

    /* Play by id, through the control lane, correlated by request id. */
    uint64_t request_id = 0;
    if (orca_player_play_track(runtime, player, capture.first_playable_id, &request_id) !=
        ORCA_STATUS_OK)
        return 49;
    if (request_id == 0) return 50;

    int completed = 0;
    uint8_t outcome = 255;
    for (int elapsed = 0; elapsed < 5000 && !completed; elapsed += 10) {
        if (orca_runtime_pump(runtime) != ORCA_STATUS_OK) return 51;
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
        if (!completed) sleep_ms(10);
    }
    if (!completed) return 53;
    if (outcome != ORCA_OUTCOME_TRACK_PLAYING) return 54;

    orca_player_status status;
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
    for (int elapsed = 0; elapsed < 4000; elapsed += 20) {
        if (orca_runtime_pump(runtime) != ORCA_STATUS_OK) return 69;
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
        sleep_ms(20);
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

    /* ---- position is anchored to the audible entry, not to the epoch ---- */
    /* Two copies of one entry, so both report the same duration and the only
     * thing that can push position past the end is the queue advancing. A
     * gapless advance deliberately keeps a single epoch, so a position derived
     * from frames-since-epoch alone would keep climbing straight through the
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
        int settled_ms = 0;
        for (int elapsed = 0; elapsed < 3000; elapsed += 20) {
            if (orca_runtime_pump(runtime) != ORCA_STATUS_OK) return 92;
            for (;;) {
                orca_event event;
                uint32_t remaining = 0;
                if (orca_runtime_poll_event(runtime, &event, &remaining) != ORCA_STATUS_OK)
                    return 93;
                if (event.kind == ORCA_EVENT_NONE) break;
            }
            if (orca_player_status_get(runtime, player, &status) != ORCA_STATUS_OK) return 94;
            if (status.duration_ms > 0 && status.position_ms > status.duration_ms + 100)
                past_end = 1;
            if (status.queue_index == 1) advanced = 1;
            if (status.position_ms == last_position) {
                settled_ms += 20;
            } else {
                last_position = status.position_ms;
                settled_ms = 0;
            }
            /* The whole queue has played out once the second entry is current
             * and the clock has stopped moving. */
            if (advanced && settled_ms >= 300) break;
            sleep_ms(20);
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

    if (orca_zone_destroy(runtime, zone) != ORCA_STATUS_OK) return 89;
    if (orca_player_destroy(runtime, player) != ORCA_STATUS_OK) return 6;
    if (orca_player_snapshot(runtime, player, &snapshot) != ORCA_STATUS_STALE_HANDLE) return 7;
    if (orca_library_close(runtime, library) != ORCA_STATUS_OK) return 90;

    orca_runtime_destroy(runtime);
    return 0;
}
