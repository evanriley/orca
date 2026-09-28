//! The frontend's own preferences, in `$XDG_CONFIG_HOME/orca/settings.ini`.
//!
//! Only choices a host keeps for itself live here: which output to open, and
//! the ReplayGain mode, equalizer and crossfeed to hand the Player at launch.
//! Nothing about the library does.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");

const App = app.App;

fn path(buffer: []u8) ?[:0]const u8 {
    const config = std.mem.span(gtk.g_get_user_config_dir());
    const directory = std.fmt.bufPrintSentinel(buffer, "{s}/orca", .{config}, 0) catch return null;
    _ = gtk.g_mkdir_with_parents(directory.ptr, 0o700);
    return std.fmt.bufPrintSentinel(buffer, "{s}/orca/settings.ini", .{config}, 0) catch null;
}

/// `g1,...,g10:preamp` in decibels, or null when the text is anything else.
fn parseEqualizer(text: []const u8) ?liborca.Equalizer {
    const split = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    var curve: liborca.Equalizer = .{
        .preamp_db = std.fmt.parseFloat(f32, std.mem.trim(u8, text[split + 1 ..], " ")) catch return null,
    };
    var bands = std.mem.splitScalar(u8, text[0..split], ',');
    for (&curve.gains_db) |*gain_db| {
        const band = bands.next() orelse return null;
        gain_db.* = std.fmt.parseFloat(f32, std.mem.trim(u8, band, " ")) catch return null;
    }
    if (bands.next() != null) return null;
    return curve;
}

fn formatEqualizer(buffer: []u8, curve: liborca.Equalizer) ?[:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    for (curve.gains_db, 0..) |gain_db, index| {
        writer.print("{s}{d}", .{
            if (index == 0) "" else ",",
            strings.withoutNegativeZero(gain_db),
        }) catch return null;
    }
    writer.print(":{d}", .{strings.withoutNegativeZero(curve.preamp_db)}) catch return null;
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn parseCrossfeed(text: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch null;
}

fn loadEqualizer(self: *App, text: []const u8, enabled: ?[]const u8) void {
    const curve = parseEqualizer(text) orelse return;
    self.equalizer_curve = curve;
    if (!isEnabled(enabled)) return;
    self.runtime.playerSetEqualizer(self.player, curve) catch {};
}

fn loadCrossfeed(self: *App, text: []const u8, enabled: ?[]const u8) void {
    const amount = parseCrossfeed(text) orelse return;
    self.crossfeed_amount = amount;
    if (!isEnabled(enabled)) return;
    self.runtime.playerSetCrossfeed(self.player, amount) catch {};
}

fn isEnabled(flag: ?[]const u8) bool {
    return std.mem.eql(u8, flag orelse return true, "true");
}

fn getString(keys: *gtk.GKeyFile, group: [:0]const u8, key: [:0]const u8) ?[*:0]u8 {
    var err: ?*gtk.GError = null;
    return gtk.g_key_file_get_string(keys, group.ptr, key.ptr, &err) orelse {
        gtk.g_clear_error(&err);
        return null;
    };
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
    if (getString(keys, "sound", "equalizer")) |value| {
        defer gtk.g_free(value);
        const enabled = getString(keys, "sound", "equalizer_enabled");
        defer if (enabled) |flag| gtk.g_free(flag);
        loadEqualizer(self, std.mem.span(value), if (enabled) |flag| std.mem.span(flag) else null);
    }
    if (getString(keys, "sound", "crossfeed")) |value| {
        defer gtk.g_free(value);
        const enabled = getString(keys, "sound", "crossfeed_enabled");
        defer if (enabled) |flag| gtk.g_free(flag);
        loadCrossfeed(self, std.mem.span(value), if (enabled) |flag| std.mem.span(flag) else null);
    }
    if (gtk.g_key_file_get_string(keys, "view", "details", &err)) |value| {
        defer gtk.g_free(value);
        self.details_visible = std.mem.eql(u8, std.mem.span(value), "true");
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
    var equalizer_buffer: [256]u8 = undefined;
    if (formatEqualizer(&equalizer_buffer, self.equalizer_curve)) |curve|
        gtk.g_key_file_set_string(keys, "sound", "equalizer", curve.ptr);
    const equalizer_on = (self.runtime.playerEqualizer(self.player) catch null) != null;
    gtk.g_key_file_set_string(keys, "sound", "equalizer_enabled", if (equalizer_on) "true" else "false");
    var crossfeed_buffer: [32]u8 = undefined;
    gtk.g_key_file_set_string(keys, "sound", "crossfeed", strings.format(&crossfeed_buffer, "{d}", .{self.crossfeed_amount}).ptr);
    const crossfeed_on = (self.runtime.playerCrossfeed(self.player) catch null) != null;
    gtk.g_key_file_set_string(keys, "sound", "crossfeed_enabled", if (crossfeed_on) "true" else "false");
    gtk.g_key_file_set_string(keys, "view", "details", if (self.details_visible) "true" else "false");
    var err: ?*gtk.GError = null;
    if (gtk.g_key_file_save_to_file(keys, file.ptr, &err) == 0) {
        gtk.g_clear_error(&err);
        self.toast("Could not save preferences");
    }
}
