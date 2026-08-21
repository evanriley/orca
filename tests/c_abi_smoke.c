#include "orca.h"

int main(void) {
    orca_runtime *runtime = orca_runtime_create();
    if (runtime == 0) return 1;
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
