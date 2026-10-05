#define _POSIX_C_SOURCE 200809L

#include "orca-0.8.1.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

_Static_assert(sizeof(orca_scan_stats) == 88, "the 0.8.1 orca_scan_stats is 88 bytes");

#define CANARY_BYTE 0xA5
#define CANARY_LENGTH 1024
#define SCAN_LIMIT_MS 60000

#define CHECK(condition)                                                              \
    do {                                                                              \
        if (!(condition)) {                                                           \
            fprintf(stderr, "abi-0.8.1-scan-stats: check failed at %s:%d: %s\n",      \
                    __FILE__, __LINE__, #condition);                                  \
            return 1;                                                                 \
        }                                                                             \
    } while (0)

static int wake_pipe[2] = {-1, -1};

static void on_wake(void *context) {
    (void)context;
    char byte = 1;
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

static long now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int pump_once(orca_runtime *runtime, long deadline) {
    int64_t timeout = 0;
    if (orca_runtime_pump_timeout(runtime, &timeout) != ORCA_STATUS_OK) return -1;
    long wait = deadline - now_ms();
    if (wait < 0) wait = 0;
    if (timeout != ORCA_PUMP_NO_TIMEOUT && timeout < wait) wait = (long)timeout;
    struct pollfd wake = {.fd = wake_pipe[0], .events = POLLIN, .revents = 0};
    if (poll(&wake, 1, (int)wait) < 0 && errno != EINTR) return -1;
    char bytes[64];
    while (read(wake_pipe[0], bytes, sizeof bytes) > 0) {
    }
    return orca_runtime_pump(runtime) == ORCA_STATUS_OK ? 0 : -1;
}

static int await_finished(orca_runtime *runtime, orca_handle job, uint8_t *state) {
    long deadline = now_ms() + SCAN_LIMIT_MS;
    for (;;) {
        orca_job_snapshot snapshot;
        if (orca_job_snapshot_get(runtime, job, &snapshot) != ORCA_STATUS_OK) return -1;
        if (snapshot.state == ORCA_JOB_SUCCEEDED || snapshot.state == ORCA_JOB_FAILED ||
            snapshot.state == ORCA_JOB_CANCELLED) {
            *state = snapshot.state;
            return 0;
        }
        if (now_ms() >= deadline) return -1;
        if (pump_once(runtime, deadline) != 0) return -1;
    }
}

struct guarded_scan_stats {
    orca_scan_stats stats;
    unsigned char canary[CANARY_LENGTH];
};
_Static_assert(offsetof(struct guarded_scan_stats, canary) == sizeof(orca_scan_stats),
               "the canary starts right after the 88-byte buffer");

static int canary_intact(const unsigned char *canary) {
    for (size_t i = 0; i < CANARY_LENGTH; i += 1)
        if (canary[i] != CANARY_BYTE) return 0;
    return 1;
}

int main(void) {
    orca_runtime *runtime = orca_runtime_create();
    CHECK(runtime != 0);
    CHECK(open_wake_pipe() == 0);
    CHECK(orca_runtime_set_wake_callback(runtime, on_wake, 0) == ORCA_STATUS_OK);

    orca_handle library;
    CHECK(orca_library_open(runtime, "file:orca-abi-0-8-1?mode=memory&cache=shared", &library) ==
          ORCA_STATUS_OK);
    char fixtures[4096];
    CHECK(getcwd(fixtures, sizeof fixtures - 16) != 0);
    strcat(fixtures, "/fixtures/audio");
    int64_t root_id = 0;
    CHECK(orca_library_add_root(runtime, library, fixtures, &root_id) == ORCA_STATUS_OK);

    orca_scan_options options;
    memset(&options, 0, sizeof options);
    orca_handle job;
    CHECK(orca_library_start_scan(runtime, library, root_id, &options, &job) == ORCA_STATUS_OK);
    uint8_t state = ORCA_JOB_RUNNING;
    CHECK(await_finished(runtime, job, &state) == 0);
    CHECK(state == ORCA_JOB_SUCCEEDED);

    struct guarded_scan_stats guarded;
    memset(&guarded, CANARY_BYTE, sizeof guarded);
    CHECK(orca_library_scan_stats(runtime, job, &guarded.stats) == ORCA_STATUS_OK);
    CHECK(canary_intact(guarded.canary));

    const orca_scan_stats *stats = &guarded.stats;
    CHECK(stats->files_seen > 0);
    CHECK(stats->changed > 0 && stats->changed <= stats->files_seen);
    CHECK(stats->unchanged <= stats->files_seen);
    CHECK(stats->tracks_written > 0);
    CHECK(stats->releases_written > 0);
    CHECK(stats->cancelled == 0);
    for (size_t i = 0; i < sizeof stats->reserved; i += 1) CHECK(stats->reserved[i] == 0);

    printf("abi-0.8.1-scan-stats: %llu files seen, %llu tracks written, canary intact\n",
           (unsigned long long)stats->files_seen, (unsigned long long)stats->tracks_written);
    orca_runtime_destroy(runtime);
    return 0;
}
