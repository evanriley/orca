#include "orca.h"

static void count_track(void *context, const orca_track_view *track) {
    uint32_t *count = context;
    if (track->title.pointer != 0) *count += 1;
}

static void count_issue(void *context, const orca_health_issue_view *issue) {
    uint32_t *count = context;
    if (issue->path.pointer != 0) *count += 1;
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
    uint64_t health_count = 1;
    if (orca_library_health_issue_count(runtime, library, &health_count) != ORCA_STATUS_OK) return 14;
    if (health_count != 0) return 15;
    if (orca_library_query_health_issues(runtime, library, 64, 0, &visited, count_issue) != ORCA_STATUS_OK) return 16;
    if (visited != 0) return 17;
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
