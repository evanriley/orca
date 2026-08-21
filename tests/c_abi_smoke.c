#include "orca.h"

static void count_track(void *context, const orca_track_view *track) {
    uint32_t *count = context;
    if (track->title.pointer != 0) *count += 1;
}

int main(void) {
    orca_runtime *runtime = orca_runtime_create();
    if (runtime == 0) return 1;
    orca_handle library;
    if (orca_library_open(runtime, "file:orca-c-smoke?mode=memory&cache=shared", &library) != ORCA_STATUS_OK) return 8;
    uint64_t track_count = 1;
    if (orca_library_track_count(runtime, library, &track_count) != ORCA_STATUS_OK) return 9;
    if (track_count != 0) return 10;
    uint32_t visited = 0;
    if (orca_library_query_tracks(runtime, library, 0, 0, 64, 0, &visited, count_track) != ORCA_STATUS_OK) return 11;
    if (visited != 0) return 12;
    if (orca_library_close(runtime, library) != ORCA_STATUS_OK) return 13;
    orca_handle player;
    if (orca_player_create(runtime, &player) != ORCA_STATUS_OK) return 2;
    if (orca_player_play(runtime, player) != ORCA_STATUS_OK) return 3;
    orca_player_state_snapshot snapshot;
    if (orca_player_snapshot(runtime, player, &snapshot) != ORCA_STATUS_OK) return 4;
    if (snapshot.state != ORCA_TRANSPORT_PLAYING) return 5;
    if (orca_player_destroy(runtime, player) != ORCA_STATUS_OK) return 6;
    if (orca_player_snapshot(runtime, player, &snapshot) != ORCA_STATUS_STALE_HANDLE) return 7;
    orca_runtime_destroy(runtime);
    return 0;
}
