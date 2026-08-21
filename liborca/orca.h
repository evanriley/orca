#ifndef ORCA_H
#define ORCA_H

#include <stdint.h>

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

/* The caller owns the returned runtime and must destroy it exactly once. */
orca_runtime *orca_runtime_create(void);
void orca_runtime_destroy(orca_runtime *runtime);

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
