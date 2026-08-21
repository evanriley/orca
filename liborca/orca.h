#ifndef ORCA_H
#define ORCA_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct orca_runtime orca_runtime;

typedef enum orca_status {
    ORCA_STATUS_OK = 0,
    ORCA_STATUS_INVALID_ARGUMENT = 1,
    ORCA_STATUS_RUNTIME_NOT_RUNNING = 2,
    ORCA_STATUS_STALE_HANDLE = 3,
    ORCA_STATUS_OUT_OF_MEMORY = 4,
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

typedef struct orca_track_view {
    int64_t id;
    orca_string_view title;
    orca_string_view album;
    orca_string_view album_artist;
} orca_track_view;

/* String views are valid only for the duration of this callback. */
typedef void (*orca_track_callback)(void *context, const orca_track_view *track);

/* The caller owns the returned runtime and must destroy it exactly once. */
orca_runtime *orca_runtime_create(void);
void orca_runtime_destroy(orca_runtime *runtime);

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

orca_status orca_player_create(orca_runtime *runtime, orca_handle *output);
orca_status orca_player_destroy(orca_runtime *runtime, orca_handle player);
orca_status orca_player_play(orca_runtime *runtime, orca_handle player);
orca_status orca_player_pause(orca_runtime *runtime, orca_handle player);
orca_status orca_player_stop(orca_runtime *runtime, orca_handle player);
orca_status orca_player_seek(
    orca_runtime *runtime,
    orca_handle player,
    uint64_t frame,
    uint64_t *generation
);
orca_status orca_player_snapshot(
    orca_runtime *runtime,
    orca_handle player,
    orca_player_state_snapshot *output
);

#ifdef __cplusplus
}
#endif

#endif
