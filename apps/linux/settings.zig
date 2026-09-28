//! The frontend's own preferences, in `$XDG_CONFIG_HOME/orca/settings.ini`.
//!
//! Only presentation choices a host keeps for itself live here: which output
//! to open, and which ReplayGain mode to hand the Player at launch. Nothing
//! about the library does.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");

const App = app.App;

fn path(buffer: []u8) ?[:0]const u8 {
    const config = std.mem.span(gtk.g_get_user_config_dir());
    const directory = std.fmt.bufPrintSentinel(buffer, "{s}/orca", .{config}, 0) catch return null;
    _ = gtk.g_mkdir_with_parents(directory.ptr, 0o700);
    return std.fmt.bufPrintSentinel(buffer, "{s}/orca/settings.ini", .{config}, 0) catch null;
}

/// Applies saved choices to a newly started app.
pub fn load(self: *App) void {
    var buffer: [1024]u8 = undefined;
    const file = path(&buffer) orelse return;
    const keys = gtk.g_key_file_new();
    defer gtk.g_key_file_free(keys);
    var err: ?*gtk.GError = null;
    if (gtk.g_key_file_load_from_file(keys, file.ptr, 0, &err) == 0) {
        gtk.g_clear_error(&err);
        return;
    }
    if (gtk.g_key_file_get_string(keys, "playback", "replay_gain", &err)) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(liborca.ReplayGainMode, std.mem.span(value))) |mode|
            self.runtime.playerSetReplayGainMode(self.player, mode) catch {};
    } else gtk.g_clear_error(&err);
    if (gtk.g_key_file_get_string(keys, "playback", "output_device", &err)) |value| {
        defer gtk.g_free(value);
        self.preferred_output.set(self.allocator, std.mem.span(value));
    } else gtk.g_clear_error(&err);
}

pub fn save(self: *App) void {
    var buffer: [1024]u8 = undefined;
    const file = path(&buffer) orelse return;
    const keys = gtk.g_key_file_new();
    defer gtk.g_key_file_free(keys);
    const mode = self.runtime.playerReplayGainMode(self.player) catch .off;
    gtk.g_key_file_set_string(keys, "playback", "replay_gain", @tagName(mode));
    gtk.g_key_file_set_string(keys, "playback", "output_device", self.preferred_output.value.ptr);
    var err: ?*gtk.GError = null;
    if (gtk.g_key_file_save_to_file(keys, file.ptr, &err) == 0) {
        gtk.g_clear_error(&err);
        self.toast("Could not save preferences");
    }
}
