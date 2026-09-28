//! `orca-gtk`: the native GTK4 frontend, in Zig, against liborca's Zig-facing
//! API.
//!
//! The frontend owns windows, widgets and the event loop and nothing else.
//! Every music, library, audio and job semantic belongs to `liborca`, and this
//! process reaches it by calling `OrcaRuntime` methods directly — real Zig
//! types, real optionals, caller-owned pages — rather than through the C ABI
//! the SwiftUI client needs.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const mpris = @import("mpris.zig");
const jobs = @import("jobs.zig");
const track_model = @import("track_model.zig");
const browse_model = @import("browse_model.zig");
const browse = @import("browse.zig");
const transport = @import("transport.zig");
const queue = @import("queue.zig");
const window = @import("window.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const menu = @import("menu.zig");
const health = @import("health.zig");
const preferences = @import("preferences.zig");
const settings = @import("settings.zig");
const tags = @import("tags.zig");
const art = @import("art.zig");

const stylesheet = @embedFile("style.css");

const App = app.App;

fn failureText(failure: liborca.Failure) [:0]const u8 {
    return switch (failure) {
        .track_has_no_file => "That track has no file",
        .track_file_missing => "That track's file is missing",
        .codec_unavailable => "No codec can read that file",
        .player_not_bound => "No library is open",
        .not_playable => "That track is not playable",
        else => "Playback failed",
    };
}

/// One tick drives the whole boundary from the GTK main thread: it executes the
/// control lane, drains the event channels, then refreshes transport and scan
/// presentation from authoritative snapshots. Nothing here runs on a worker —
/// the runtime owns exactly one calling thread, and this is it.
fn tick(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *App = @ptrCast(@alignCast(data.?));
    // Bounded: one pump drains at most the command queue's capacity, so a burst
    // of submissions can never trap the event loop in here.
    var executed: usize = 0;
    while (executed < 256 and self.runtime.processNextCommand()) executed += 1;
    self.runtime.reapFinishedJobs();

    while (self.runtime.pollEvent()) |event| {
        if (self.pending_play_request != 0 and event.request_id == self.pending_play_request) {
            self.pending_play_request = 0;
            switch (event.outcome) {
                .failed => |failure| self.toast(failureText(failure)),
                else => {},
            }
        }
    }
    // Coalesced position and progress hints. Authoritative state is read from
    // snapshots below, so these are drained rather than interpreted.
    while (self.runtime.pollTelemetry()) |_| {}

    art.tick(self);
    transport.tick(self);
    queue.tick(self);
    jobs.tick(self);
    return gtk.SOURCE_CONTINUE;
}

fn activate(application: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    if (self.window) |existing| {
        gtk.gtk_window_present(existing);
        return;
    }
    if (gtk.gdk_display_get_default()) |display| {
        const provider = gtk.gtk_css_provider_new();
        gtk.gtk_css_provider_load_from_string(provider, stylesheet);
        gtk.gtk_style_context_add_provider_for_display(
            display,
            provider,
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        gtk.g_object_unref(provider);
    }
    _ = window.build(self, gtk.cast(gtk.Application, application));
    transport.refreshDevices(self);
    // The output is opened on first play, not here. Opening it at launch held
    // the user's default sink for as long as the window was open, whether or
    // not they ever played anything -- it shows up in their mixer, and on a
    // device that only allows one client it locks everything else out. The
    // play path already calls `ensureOutput`, so nothing is lost but the
    // device grab, and a machine with no audio server still reports honestly
    // at the point a play is attempted rather than at startup.
    browse.reload(self);
    self.reload();
    albums.reload(self);
    artists.reload(self);
    health.reload(self);
    if (self.library == null) self.toast("The library could not be opened");
    gtk.gtk_window_present(self.window.?);
}

fn activatePlayPause(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    transport.toggle(@ptrCast(@alignCast(data.?)));
}

fn activateAddFolder(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.chooseFolder(@ptrCast(@alignCast(data.?)));
}

fn activateRescan(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.rescan(@ptrCast(@alignCast(data.?)));
}

fn activateSearch(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.focusSearch(@ptrCast(@alignCast(data.?)));
}

fn activateShowQueue(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.showPage(@ptrCast(@alignCast(data.?)), .queue);
}

fn activateContextPlay(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    menu.play(@ptrCast(@alignCast(data.?)));
}

fn activateContextPlayNext(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    menu.playNext(@ptrCast(@alignCast(data.?)));
}

fn activateContextEnqueue(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    menu.enqueue(@ptrCast(@alignCast(data.?)));
}

fn activateContextRemove(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    menu.remove(@ptrCast(@alignCast(data.?)));
}

fn activateContextShowAlbum(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    window.showAlbum(self, self.context.release_id orelse return);
}

fn activateContextShowArtist(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    window.showArtist(self, self.context.artist_id orelse return);
}

fn activatePreferences(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    preferences.present(@ptrCast(@alignCast(data.?)));
}

fn activateUndoTags(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    tags.undoLastWrite(@ptrCast(@alignCast(data.?)));
}

fn activateContextEditTags(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    tags.edit(self, self.context.tracks.items);
}

fn activateQuit(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    const application = self.application orelse return;
    gtk.g_application_quit(gtk.cast(gtk.GApplication, application));
}

fn activateAbout(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    const dialog = adw.adw_about_dialog_new();
    const about = gtk.cast(adw.AboutDialog, dialog);
    var buffer: [64]u8 = undefined;
    const version = liborca.version;
    const text = strings.printZ(&buffer, "{d}.{d}.{d}{s}{s}", .{
        version.major,
        version.minor,
        version.patch,
        if (version.pre != null) "-" else "",
        version.pre orelse "",
    }) catch "";
    adw.adw_about_dialog_set_application_name(about, "Orca");
    adw.adw_about_dialog_set_application_icon(about, application_id);
    adw.adw_about_dialog_set_version(about, text.ptr);
    adw.adw_about_dialog_set_developer_name(about, "The Orca developers");
    adw.adw_about_dialog_set_comments(about, "A music player for the files you own.");
    adw.adw_about_dialog_set_license_type(about, gtk.LICENSE_MPL_2_0);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

fn activateShortcuts(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    const dialog = adw.adw_shortcuts_dialog_new();
    const shortcuts = gtk.cast(adw.ShortcutsDialog, dialog);
    const sections = [_]struct { title: [*:0]const u8, items: []const [2][*:0]const u8 }{
        .{ .title = "Playback", .items = &.{
            .{ "Play / Pause", "space" },
            .{ "Next Track", "<Control>Right" },
            .{ "Previous Track", "<Control>Left" },
        } },
        .{ .title = "Library", .items = &.{
            .{ "Search", "<Control>f" },
            .{ "Show Queue", "<Control>l" },
            .{ "Add Music Folder", "<Control>o" },
        } },
        .{ .title = "General", .items = &.{
            .{ "Preferences", "<Control>comma" },
            .{ "Keyboard Shortcuts", "<Control>question" },
            .{ "Quit", "<Control>q" },
        } },
    };
    for (sections) |entry| {
        const section = adw.adw_shortcuts_section_new(entry.title);
        for (entry.items) |item| adw.adw_shortcuts_section_add(section, adw.adw_shortcuts_item_new(item[0], item[1]));
        adw.adw_shortcuts_dialog_add(shortcuts, section);
    }
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

const application_id = "org.orca_music.Orca";

fn addAction(
    application: *gtk.Application,
    name: [*:0]const u8,
    handler: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    accelerator: ?[*:0]const u8,
    self: *App,
) void {
    const action = gtk.g_simple_action_new(name, null).?;
    _ = gtk.signalConnect(action, "activate", gtk.callback(handler), self);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, application), gtk.cast(gtk.GAction, action));
    gtk.g_object_unref(action);
    const key = accelerator orelse return;
    var detailed: [64]u8 = undefined;
    const full = strings.printZ(&detailed, "app.{s}", .{std.mem.span(name)}) catch return;
    const accelerators: [2]?[*:0]const u8 = .{ key, null };
    gtk.gtk_application_set_accels_for_action(application, full.ptr, &accelerators);
}

/// The library lives in the platform data directory unless `ORCA_LIBRARY` names
/// one, so "open the app and add my music" needs no file-dialog ceremony and no
/// environment variable. `ORCA_LIBRARY` still wins, for development.
fn resolveLibraryPath(
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
) ?[:0]u8 {
    if (environ.get("ORCA_LIBRARY")) |configured| {
        if (configured.len != 0) return allocator.dupeSentinel(u8, configured, 0) catch null;
    }
    const data_dir = std.mem.span(gtk.g_get_user_data_dir());
    const directory = std.fmt.allocPrintSentinel(allocator, "{s}/orca", .{data_dir}, 0) catch return null;
    defer allocator.free(directory);
    if (gtk.g_mkdir_with_parents(directory.ptr, 0o700) != 0) return null;
    return std.fmt.allocPrintSentinel(allocator, "{s}/library.db", .{directory}, 0) catch null;
}

/// `ORCA_OUTPUT_DEVICE` names an orca device id from `orca-cli devices`, and
/// overrides the device dropdown when set.
///
/// It exists because device 0 means "system default", which on the machine
/// this is developed on is the user's speakers, and an automated run that
/// plays to them is unacceptable. `scripts/silent-sink.sh` prints an id to put
/// here. Like `ORCA_LIBRARY` this is a development affordance, not
/// configuration: a person chooses their output from the dropdown.
fn resolvePinnedOutput(environ: *std.process.Environ.Map) ?u64 {
    const configured = environ.get("ORCA_OUTPUT_DEVICE") orelse return null;
    if (configured.len == 0) return null;
    return std.fmt.parseInt(u64, configured, 10) catch null;
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = std.heap.smp_allocator;
    track_model.allocator = allocator;
    browse_model.allocator = allocator;

    var runtime: liborca.Runtime = .init(allocator);
    var self: App = .{
        .allocator = allocator,
        .io = init.io,
        .runtime = &runtime,
    };
    defer self.deinit();

    self.player = runtime.createPlayer() catch {
        runtime.deinit();
        return 2;
    };

    self.library_path = resolveLibraryPath(allocator, init.environ_map);
    self.pinned_output_device = resolvePinnedOutput(init.environ_map);
    if (self.library_path) |path| {
        if (runtime.openLibrary(init.io, path)) |library| {
            self.library = library;
            runtime.playerBindLibrary(self.player, library, init.io) catch {};
            settings.load(&self);
        } else |_| {}
    }

    const application: *gtk.Application = @ptrCast(adw.adw_application_new(
        application_id,
        gtk.APPLICATION_DEFAULT_FLAGS,
    ) orelse {
        runtime.deinit();
        return 1;
    });
    self.application = application;
    const g_application = gtk.cast(gtk.GApplication, application);

    // Space and Ctrl+arrows are deliberately NOT application accelerators.
    // GTK matches those before the focused widget sees the key, so they would
    // steal every space typed into a search box and its word movement. The
    // window's bubble-phase key controller handles them instead.
    addAction(application, "play-pause", activatePlayPause, null, &self);
    addAction(application, "add-folder", activateAddFolder, "<Control>o", &self);
    addAction(application, "rescan", activateRescan, null, &self);
    addAction(application, "search", activateSearch, "<Control>f", &self);
    addAction(application, "show-queue", activateShowQueue, "<Control>l", &self);
    addAction(application, "shortcuts", activateShortcuts, "<Control>question", &self);
    addAction(application, "about", activateAbout, null, &self);
    addAction(application, "quit", activateQuit, "<Control>q", &self);
    addAction(application, "preferences", activatePreferences, "<Control>comma", &self);
    addAction(application, "undo-tags", activateUndoTags, null, &self);
    addAction(application, "ctx-edit-tags", activateContextEditTags, null, &self);
    addAction(application, "ctx-play", activateContextPlay, null, &self);
    addAction(application, "ctx-play-next", activateContextPlayNext, null, &self);
    addAction(application, "ctx-enqueue", activateContextEnqueue, null, &self);
    addAction(application, "ctx-remove", activateContextRemove, null, &self);
    addAction(application, "ctx-show-album", activateContextShowAlbum, null, &self);
    addAction(application, "ctx-show-artist", activateContextShowArtist, null, &self);

    self.mpris.init(&runtime, self.player, g_application, self.io);
    _ = gtk.signalConnect(application, "activate", gtk.callback(activate), &self);
    const tick_source = gtk.g_timeout_add(app.tick_ms, tick, &self);

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var argv = try init.arena.allocator().alloc(?[*:0]const u8, arguments.len + 1);
    for (arguments, 0..) |argument, index| argv[index] = argument.ptr;
    argv[arguments.len] = null;
    const status = gtk.g_application_run(g_application, @intCast(arguments.len), argv.ptr);

    // Tear the timer down before the runtime: a GUI timer racing runtime
    // destruction is a real use-after-free, not a theoretical one.
    _ = gtk.g_source_remove(tick_source);
    self.mpris.deinit();
    gtk.g_object_unref(application);
    if (self.zone) |zone| runtime.destroyZone(zone) catch {};
    runtime.destroyPlayer(self.player) catch {};
    if (self.library) |library| runtime.destroyLibrary(library) catch {};
    runtime.deinit();
    return @intCast(status);
}
