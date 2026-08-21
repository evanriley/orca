#include "orca.h"
#include "mpris.h"

#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

enum { ORCA_PAGE_SIZE = 256 };

typedef struct app_state {
    orca_runtime *runtime;
    orca_handle library;
    orca_handle player;
    gboolean has_library;
    GtkStringList *strings;
    GtkLabel *page_label;
    char *query;
    uint32_t offset;
    orca_mpris mpris;
} app_state;

static void append_track(void *context, const orca_track_view *track) {
    GtkStringList *strings = context;
    char *title = g_strndup(track->title.pointer, track->title.length);
    char *artist = g_strndup(track->album_artist.pointer, track->album_artist.length);
    char *label = g_strdup_printf("%s — %s", title, artist);
    gtk_string_list_append(strings, label);
    g_free(label);
    g_free(artist);
    g_free(title);
}

static void reload(app_state *state) {
    while (g_list_model_get_n_items(G_LIST_MODEL(state->strings)) > 0)
        gtk_string_list_remove(state->strings, 0);
    if (!state->has_library) {
        gtk_string_list_append(state->strings, "Set ORCA_LIBRARY to an Orca SQLite library path");
        return;
    }
    if (orca_library_query_tracks(state->runtime, state->library,
            state->query, strlen(state->query), ORCA_PAGE_SIZE, state->offset,
            state->strings, append_track) != ORCA_STATUS_OK)
        gtk_string_list_append(state->strings, "Unable to query the library");
    guint visible = g_list_model_get_n_items(G_LIST_MODEL(state->strings));
    char *page = g_strdup_printf("Tracks %u–%u", state->offset + 1, state->offset + visible);
    gtk_label_set_text(state->page_label, page);
    g_free(page);
}

static void setup_list_item(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data) {
    (void)factory;
    (void)data;
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_list_item_set_child(item, label);
}

static void bind_list_item(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data) {
    (void)factory;
    (void)data;
    GtkStringObject *value = GTK_STRING_OBJECT(gtk_list_item_get_item(item));
    gtk_label_set_text(GTK_LABEL(gtk_list_item_get_child(item)),
        gtk_string_object_get_string(value));
}

static void search_changed(GtkSearchEntry *entry, gpointer data) {
    app_state *state = data;
    g_free(state->query);
    state->query = g_strdup(gtk_editable_get_text(GTK_EDITABLE(entry)));
    state->offset = 0;
    reload(state);
}

static void previous_page(GtkButton *button, gpointer data) {
    (void)button;
    app_state *state = data;
    state->offset = state->offset > ORCA_PAGE_SIZE ?
        state->offset - ORCA_PAGE_SIZE : 0;
    reload(state);
}

static void next_page(GtkButton *button, gpointer data) {
    (void)button;
    app_state *state = data;
    state->offset += ORCA_PAGE_SIZE;
    reload(state);
}

static void toggle_playback(GtkButton *button, gpointer data) {
    (void)button;
    app_state *state = data;
    orca_mpris_toggle(&state->mpris);
}

static void activate(GtkApplication *application, gpointer data) {
    app_state *state = data;
    GtkWidget *window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(window), "Orca");
    gtk_window_set_default_size(GTK_WINDOW(window), 960, 640);
    GtkWidget *layout = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(layout, 12);
    gtk_widget_set_margin_bottom(layout, 12);
    gtk_widget_set_margin_start(layout, 12);
    gtk_widget_set_margin_end(layout, 12);
    GtkWidget *search = gtk_search_entry_new();
    gtk_widget_set_tooltip_text(search, "Search tracks");
    gtk_box_append(GTK_BOX(layout), search);

    state->strings = gtk_string_list_new(NULL);
    GtkSelectionModel *selection = GTK_SELECTION_MODEL(
        gtk_single_selection_new(G_LIST_MODEL(state->strings)));
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect(factory, "setup", G_CALLBACK(setup_list_item), NULL);
    g_signal_connect(factory, "bind", G_CALLBACK(bind_list_item), NULL);
    GtkWidget *list = gtk_list_view_new(selection, factory);
    gtk_widget_set_vexpand(list, TRUE);
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), list);
    gtk_box_append(GTK_BOX(layout), scroller);

    GtkWidget *controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *previous = gtk_button_new_with_label("Previous");
    GtkWidget *next = gtk_button_new_with_label("Next");
    GtkWidget *play = gtk_button_new_with_label("Play / Pause");
    gtk_widget_set_tooltip_text(play, "Toggle playback");
    gtk_box_append(GTK_BOX(controls), previous);
    gtk_box_append(GTK_BOX(controls), next);
    state->page_label = GTK_LABEL(gtk_label_new(""));
    gtk_box_append(GTK_BOX(controls), GTK_WIDGET(state->page_label));
    gtk_box_append(GTK_BOX(controls), play);
    gtk_box_append(GTK_BOX(layout), controls);
    g_signal_connect(search, "search-changed", G_CALLBACK(search_changed), state);
    g_signal_connect(previous, "clicked", G_CALLBACK(previous_page), state);
    g_signal_connect(next, "clicked", G_CALLBACK(next_page), state);
    g_signal_connect(play, "clicked", G_CALLBACK(toggle_playback), state);
    gtk_window_set_child(GTK_WINDOW(window), layout);
    reload(state);
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    app_state state = {0};
    state.runtime = orca_runtime_create();
    if (state.runtime == NULL) return 1;
    if (orca_player_create(state.runtime, &state.player) != ORCA_STATUS_OK) {
        orca_runtime_destroy(state.runtime);
        return 2;
    }
    state.query = g_strdup("");
    const char *library_path = getenv("ORCA_LIBRARY");
    state.has_library = library_path != NULL &&
        orca_library_open(state.runtime, library_path, &state.library) == ORCA_STATUS_OK;
    GtkApplication *application = gtk_application_new(
        "org.orca_music.Orca", G_APPLICATION_DEFAULT_FLAGS);
    orca_mpris_init(&state.mpris, state.runtime, state.player, G_APPLICATION(application));
    g_signal_connect(application, "activate", G_CALLBACK(activate), &state);
    int status = g_application_run(G_APPLICATION(application), argc, argv);
    orca_mpris_deinit(&state.mpris);
    g_object_unref(application);
    if (state.has_library) (void)orca_library_close(state.runtime, state.library);
    (void)orca_player_destroy(state.runtime, state.player);
    orca_runtime_destroy(state.runtime);
    g_free(state.query);
    return status;
}
