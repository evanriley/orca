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
const strings = @import("strings.zig");
const app = @import("app.zig");
const mpris = @import("mpris.zig");
const scan = @import("scan.zig");
const track_model = @import("track_model.zig");
const browse_model = @import("browse_model.zig");
const browse = @import("browse.zig");
const transport = @import("transport.zig");
const window = @import("window.zig");

const App = app.App;

fn failureText(failure: liborca.core.control.Failure) [:0]const u8 {
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
            self.setStatus(switch (event.outcome) {
                .failed => |failure| failureText(failure),
                else => "Playing",
            });
        }
    }
    // Coalesced position and progress hints. Authoritative state is read from
    // snapshots below, so these are drained rather than interpreted.
    while (self.runtime.pollTelemetry()) |_| {}

    transport.tick(self);
    scan.tick(self);
    return gtk.SOURCE_CONTINUE;
}

fn activate(application: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    if (self.window) |existing| {
        gtk.gtk_window_present(existing);
        return;
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
    if (self.library != null) {
        if (self.library_path) |path| {
            var buffer: [1024]u8 = undefined;
            if (strings.printZ(&buffer, "Orca — {s}", .{path})) |title| {
                gtk.gtk_window_set_title(self.window.?, title.ptr);
            } else |_| {}
        }
    }
    gtk.gtk_window_present(self.window.?);
}

fn activatePlayPause(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    transport.toggle(@ptrCast(@alignCast(data.?)));
}

fn activateAddFolder(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    scan.chooseFolder(@ptrCast(@alignCast(data.?)));
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
    const directory = allocator.printSentinel("{s}/orca", .{data_dir}, 0) catch return null;
    defer allocator.free(directory);
    if (gtk.g_mkdir_with_parents(directory.ptr, 0o700) != 0) return null;
    return allocator.printSentinel("{s}/library.db", .{directory}, 0) catch null;
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
    const allocator = init.arena.allocator();
    track_model.allocator = allocator;
    browse_model.allocator = allocator;

    var runtime: liborca.OrcaRuntime = .init(allocator);
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
        } else |_| {}
    }

    const application = gtk.gtk_application_new(
        "org.orca_music.Orca",
        gtk.APPLICATION_DEFAULT_FLAGS,
    ) orelse {
        runtime.deinit();
        return 1;
    };
    self.application = application;
    const g_application = gtk.cast(gtk.GApplication, application);

    const play_pause = gtk.g_simple_action_new("play-pause", null).?;
    _ = gtk.signalConnect(play_pause, "activate", gtk.callback(activatePlayPause), &self);
    gtk.g_action_map_add_action(
        gtk.cast(gtk.GActionMap, application),
        gtk.cast(gtk.GAction, play_pause),
    );
    gtk.g_object_unref(play_pause);

    const add_folder = gtk.g_simple_action_new("add-folder", null).?;
    _ = gtk.signalConnect(add_folder, "activate", gtk.callback(activateAddFolder), &self);
    gtk.g_action_map_add_action(
        gtk.cast(gtk.GActionMap, application),
        gtk.cast(gtk.GAction, add_folder),
    );
    gtk.g_object_unref(add_folder);

    // Space is deliberately NOT an application accelerator. GTK matches those
    // before the focused widget sees the key, so a bare `space` accel steals
    // every space typed into the search entry. The window installs a
    // bubble-phase key controller instead, which only runs if the focused widget
    // declined the key — so typing works and space still toggles playback
    // everywhere else.
    const folder_accelerators: [2]?[*:0]const u8 = .{ "<Control>o", null };
    gtk.gtk_application_set_accels_for_action(
        application,
        "app.add-folder",
        &folder_accelerators,
    );

    self.mpris.init(&runtime, self.player, g_application, self.io);
    _ = gtk.signalConnect(application, "activate", gtk.callback(activate), &self);
    const tick_source = gtk.g_timeout_add(app.tick_ms, tick, &self);

    const arguments = try init.minimal.args.toSlice(allocator);
    var argv = try allocator.alloc(?[*:0]const u8, arguments.len + 1);
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
