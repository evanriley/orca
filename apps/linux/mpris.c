#include "mpris.h"

#include <string.h>

static const char introspection_xml[] =
    "<node>"
    " <interface name='org.mpris.MediaPlayer2'>"
    "  <method name='Raise'/><method name='Quit'/>"
    "  <property name='CanQuit' type='b' access='read'/>"
    "  <property name='CanRaise' type='b' access='read'/>"
    "  <property name='HasTrackList' type='b' access='read'/>"
    "  <property name='Identity' type='s' access='read'/>"
    "  <property name='DesktopEntry' type='s' access='read'/>"
    "  <property name='SupportedUriSchemes' type='as' access='read'/>"
    "  <property name='SupportedMimeTypes' type='as' access='read'/>"
    " </interface>"
    " <interface name='org.mpris.MediaPlayer2.Player'>"
    "  <method name='Next'/><method name='Previous'/><method name='Pause'/>"
    "  <method name='PlayPause'/><method name='Stop'/><method name='Play'/>"
    "  <property name='PlaybackStatus' type='s' access='read'/>"
    "  <property name='Metadata' type='a{sv}' access='read'/>"
    "  <property name='Volume' type='d' access='read'/>"
    "  <property name='Position' type='x' access='read'/>"
    "  <property name='CanGoNext' type='b' access='read'/>"
    "  <property name='CanGoPrevious' type='b' access='read'/>"
    "  <property name='CanPlay' type='b' access='read'/>"
    "  <property name='CanPause' type='b' access='read'/>"
    "  <property name='CanSeek' type='b' access='read'/>"
    "  <property name='CanControl' type='b' access='read'/>"
    " </interface>"
    "</node>";

static const char *playback_status(orca_mpris *mpris) {
    orca_player_state_snapshot snapshot;
    if (orca_player_snapshot(mpris->runtime, mpris->player, &snapshot) != ORCA_STATUS_OK)
        return "Stopped";
    if (snapshot.state == ORCA_TRANSPORT_PLAYING) return "Playing";
    if (snapshot.state == ORCA_TRANSPORT_PAUSED) return "Paused";
    return "Stopped";
}

static void emit_status(orca_mpris *mpris) {
    if (mpris->connection == NULL) return;
    GVariantBuilder changed;
    GVariantBuilder invalidated;
    g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&changed, "{sv}", "PlaybackStatus",
        g_variant_new_string(playback_status(mpris)));
    g_variant_builder_init(&invalidated, G_VARIANT_TYPE("as"));
    g_dbus_connection_emit_signal(mpris->connection, NULL,
        "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        g_variant_new("(sa{sv}as)", "org.mpris.MediaPlayer2.Player",
            &changed, &invalidated), NULL);
}

static void set_transport(orca_mpris *mpris, const char *method) {
    if (strcmp(method, "Play") == 0)
        (void)orca_player_play(mpris->runtime, mpris->player);
    else if (strcmp(method, "Pause") == 0)
        (void)orca_player_pause(mpris->runtime, mpris->player);
    else if (strcmp(method, "Stop") == 0)
        (void)orca_player_stop(mpris->runtime, mpris->player);
    else if (strcmp(method, "PlayPause") == 0) {
        orca_mpris_toggle(mpris);
        return;
    }
    emit_status(mpris);
}

static void method_call(
    GDBusConnection *connection,
    const char *sender,
    const char *object_path,
    const char *interface_name,
    const char *method_name,
    GVariant *parameters,
    GDBusMethodInvocation *invocation,
    gpointer data
) {
    (void)connection; (void)sender; (void)object_path; (void)parameters;
    orca_mpris *mpris = data;
    if (strcmp(interface_name, "org.mpris.MediaPlayer2") == 0) {
        if (strcmp(method_name, "Quit") == 0) g_application_quit(mpris->application);
        else if (strcmp(method_name, "Raise") == 0) g_application_activate(mpris->application);
    } else {
        set_transport(mpris, method_name);
    }
    g_dbus_method_invocation_return_value(invocation, NULL);
}

static GVariant *get_property(
    GDBusConnection *connection,
    const char *sender,
    const char *object_path,
    const char *interface_name,
    const char *property_name,
    GError **error,
    gpointer data
) {
    (void)connection; (void)sender; (void)object_path; (void)error;
    orca_mpris *mpris = data;
    if (strcmp(interface_name, "org.mpris.MediaPlayer2") == 0) {
        if (strcmp(property_name, "CanQuit") == 0) return g_variant_new_boolean(TRUE);
        if (strcmp(property_name, "CanRaise") == 0) return g_variant_new_boolean(TRUE);
        if (strcmp(property_name, "HasTrackList") == 0) return g_variant_new_boolean(FALSE);
        if (strcmp(property_name, "Identity") == 0) return g_variant_new_string("Orca");
        if (strcmp(property_name, "DesktopEntry") == 0) return g_variant_new_string("orca");
        return g_variant_new_strv(NULL, 0);
    }
    if (strcmp(property_name, "PlaybackStatus") == 0)
        return g_variant_new_string(playback_status(mpris));
    if (strcmp(property_name, "Metadata") == 0) {
        GVariantBuilder metadata;
        g_variant_builder_init(&metadata, G_VARIANT_TYPE("a{sv}"));
        return g_variant_builder_end(&metadata);
    }
    if (strcmp(property_name, "Volume") == 0) return g_variant_new_double(1.0);
    if (strcmp(property_name, "Position") == 0) return g_variant_new_int64(0);
    if (strcmp(property_name, "CanPlay") == 0 ||
        strcmp(property_name, "CanPause") == 0 ||
        strcmp(property_name, "CanControl") == 0)
        return g_variant_new_boolean(TRUE);
    return g_variant_new_boolean(FALSE);
}

static const GDBusInterfaceVTable vtable = {
    .method_call = method_call,
    .get_property = get_property,
};

void orca_mpris_init(
    orca_mpris *mpris,
    orca_runtime *runtime,
    orca_handle player,
    GApplication *application
) {
    *mpris = (orca_mpris){
        .runtime = runtime,
        .player = player,
        .application = application,
    };
    GError *error = NULL;
    mpris->connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (mpris->connection == NULL) {
        g_clear_error(&error);
        return;
    }
    mpris->node = g_dbus_node_info_new_for_xml(introspection_xml, &error);
    if (mpris->node == NULL) {
        g_clear_error(&error);
        g_clear_object(&mpris->connection);
        return;
    }
    mpris->root_registration = g_dbus_connection_register_object(mpris->connection,
        "/org/mpris/MediaPlayer2", mpris->node->interfaces[0], &vtable,
        mpris, NULL, &error);
    mpris->player_registration = g_dbus_connection_register_object(mpris->connection,
        "/org/mpris/MediaPlayer2", mpris->node->interfaces[1], &vtable,
        mpris, NULL, &error);
    if (error != NULL) g_clear_error(&error);
    mpris->owner_id = g_bus_own_name_on_connection(mpris->connection,
        "org.mpris.MediaPlayer2.orca", G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
}

void orca_mpris_deinit(orca_mpris *mpris) {
    if (mpris->owner_id != 0) g_bus_unown_name(mpris->owner_id);
    if (mpris->connection != NULL && mpris->root_registration != 0)
        g_dbus_connection_unregister_object(mpris->connection, mpris->root_registration);
    if (mpris->connection != NULL && mpris->player_registration != 0)
        g_dbus_connection_unregister_object(mpris->connection, mpris->player_registration);
    if (mpris->node != NULL) g_dbus_node_info_unref(mpris->node);
    g_clear_object(&mpris->connection);
}

void orca_mpris_toggle(orca_mpris *mpris) {
    orca_player_state_snapshot snapshot;
    if (orca_player_snapshot(mpris->runtime, mpris->player, &snapshot) != ORCA_STATUS_OK)
        return;
    if (snapshot.state == ORCA_TRANSPORT_PLAYING)
        (void)orca_player_pause(mpris->runtime, mpris->player);
    else
        (void)orca_player_play(mpris->runtime, mpris->player);
    emit_status(mpris);
}
