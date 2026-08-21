#ifndef ORCA_MPRIS_H
#define ORCA_MPRIS_H

#include "orca.h"
#include <gio/gio.h>

typedef struct orca_mpris {
    orca_runtime *runtime;
    orca_handle player;
    GApplication *application;
    GDBusConnection *connection;
    GDBusNodeInfo *node;
    guint owner_id;
    guint root_registration;
    guint player_registration;
} orca_mpris;

void orca_mpris_init(
    orca_mpris *mpris,
    orca_runtime *runtime,
    orca_handle player,
    GApplication *application
);
void orca_mpris_deinit(orca_mpris *mpris);
void orca_mpris_toggle(orca_mpris *mpris);

#endif
