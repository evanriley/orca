//! The frontend's own preferences, in `$XDG_CONFIG_HOME/orca/settings.ini`.
//!
//! Only choices a host keeps for itself live here: which output to open, the
//! ReplayGain mode, preamp, untagged-track fallback and clipping protection,
//! what happens when the queue ends, whether long tracks resume and what
//! launch restores, which equalizer runs, the graphic and parametric curves,
//! the saved parametric presets, the preset each output device switches to,
//! and crossfeed to hand the Player at launch, and
//! whether listens and the current track are submitted, how confident a match
//! Accept Confident takes, whether matching uses audio fingerprints, whether
//! the music folders are watched, whether idle maintenance runs, how many
//! files Analyze music decodes at once, which measurement set's analysis
//! banner was dismissed, whether lyrics are fetched from
//! LRCLIB, whether artist info is fetched, whether Home shows listening
//! stats, whether the queue shows what it played, what the inspector shows,
//! how albums and artists are sorted and laid out, which artists the Artists
//! page lists, which columns an album's tracks show, the volume, the log
//! level, the Appearance tab's choices, and the libraries Orca can open:
//! their names, paths, last known track counts and which one opens at launch.
//! Nothing inside a library lives here, and never the ListenBrainz token or
//! the AcoustID key, which live in the Secret Service.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const track_table = @import("track_table.zig");
const albums = @import("albums.zig");
const playlists = @import("playlists.zig");
const parametric = @import("parametric.zig");
const logging = @import("logging.zig");
const libraries = @import("libraries.zig");

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

/// The equalizer that runs: `equalizer_mode`, or for a file written before
/// there was one, `equalizer_enabled`, which meant the graphic equalizer.
fn loadEqualizerMode(keys: *gtk.GKeyFile, has_curve: bool) parametric.Mode {
    if (getString(keys, "sound", "equalizer_mode")) |value| {
        defer gtk.g_free(value);
        return std.meta.stringToEnum(parametric.Mode, std.mem.span(value)) orelse .off;
    }
    if (!has_curve) return .off;
    const enabled = getString(keys, "sound", "equalizer_enabled");
    defer if (enabled) |flag| gtk.g_free(flag);
    return if (isEnabled(if (enabled) |flag| std.mem.span(flag) else null)) .graphic else .off;
}

fn loadPresets(self: *App, keys: *gtk.GKeyFile) void {
    var count: usize = 0;
    var err: ?*gtk.GError = null;
    const list = gtk.g_key_file_get_string_list(keys, "sound", "parametric_presets", &count, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    defer gtk.g_strfreev(list);
    for (list[0..count]) |maybe_entry| {
        const entry = std.mem.span(maybe_entry orelse continue);
        const split = std.mem.indexOfScalar(u8, entry, '\n') orelse continue;
        const curve = liborca.parseEqualizerApo(entry[split + 1 ..]) catch continue;
        _ = parametric.storePreset(self, entry[0..split], curve);
    }
}

fn loadEqualizers(self: *App, keys: *gtk.GKeyFile) void {
    var has_curve = false;
    if (getString(keys, "sound", "equalizer")) |value| {
        defer gtk.g_free(value);
        if (parseEqualizer(std.mem.span(value))) |curve| {
            self.equalizer_curve = curve;
            has_curve = true;
        }
    }
    if (getString(keys, "sound", "parametric")) |value| {
        defer gtk.g_free(value);
        if (liborca.parseEqualizerApo(std.mem.span(value))) |curve| {
            self.parametric.curve = curve;
        } else |_| {}
    }
    loadPresets(self, keys);
    const mode = loadEqualizerMode(keys, has_curve);
    switch (mode) {
        .off => {},
        .graphic => self.runtime.playerSetEqualizer(self.player, self.equalizer_curve) catch {},
        .parametric => self.runtime.playerSetParametricEqualizer(self.player, self.parametric.curve) catch {},
    }
    if (mode == .parametric) self.parametric.view = .parametric;
}

fn savePresets(self: *App, keys: *gtk.GKeyFile) void {
    const editor = &self.parametric;
    if (editor.preset_count == 0) return;
    var storage: [parametric.max_presets][parametric.max_name_bytes + 1 + parametric.curve_text_bytes]u8 = undefined;
    var entries: [parametric.max_presets][*:0]const u8 = undefined;
    var count: usize = 0;
    for (editor.presets[0..editor.preset_count]) |*preset| {
        const buffer = &storage[count];
        const name = preset.name();
        @memcpy(buffer[0..name.len], name);
        buffer[name.len] = '\n';
        const text = parametric.writeCurve(buffer[name.len + 1 ..], preset.curve) orelse continue;
        buffer[name.len + 1 + text.len] = 0;
        entries[count] = @ptrCast(buffer);
        count += 1;
    }
    gtk.g_key_file_set_string_list(keys, "sound", "parametric_presets", &entries, count);
}

fn loadDevicePresets(self: *App, keys: *gtk.GKeyFile) void {
    if (getString(keys, "sound", "switch_preset_with_device")) |value| {
        defer gtk.g_free(value);
        self.parametric.switch_with_device = isEnabled(std.mem.span(value));
    }
    var count: usize = 0;
    var err: ?*gtk.GError = null;
    const list = gtk.g_key_file_get_string_list(keys, "sound", "device_presets", &count, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    defer gtk.g_strfreev(list);
    for (list[0..count]) |maybe_entry| {
        const entry = std.mem.span(maybe_entry orelse continue);
        const split = std.mem.indexOfScalar(u8, entry, '\n') orelse continue;
        _ = parametric.setDevicePreset(self, entry[0..split], entry[split + 1 ..]);
    }
}

fn saveDevicePresets(self: *App, keys: *gtk.GKeyFile) void {
    const editor = &self.parametric;
    gtk.g_key_file_set_string(keys, "sound", "switch_preset_with_device", if (editor.switch_with_device) "true" else "false");
    if (editor.device_preset_count == 0) return;
    var storage: [parametric.max_device_presets][parametric.max_device_name_bytes + 1 + parametric.max_name_bytes + 1]u8 = undefined;
    var entries: [parametric.max_device_presets][*:0]const u8 = undefined;
    for (editor.device_presets[0..editor.device_preset_count], 0..) |*entry, index| {
        entries[index] = (std.fmt.bufPrintSentinel(&storage[index], "{s}\n{s}", .{ entry.device(), entry.preset() }, 0) catch unreachable).ptr;
    }
    gtk.g_key_file_set_string_list(keys, "sound", "device_presets", &entries, editor.device_preset_count);
}

fn loadPlayback(self: *App, keys: *gtk.GKeyFile) void {
    if (getString(keys, "playback", "preamp")) |value| {
        defer gtk.g_free(value);
        if (std.fmt.parseFloat(f32, std.mem.trim(u8, std.mem.span(value), " "))) |decibels| {
            if (std.math.isFinite(decibels)) self.runtime.playerSetReplayGainPreamp(self.player, decibels) catch {};
        } else |_| {}
    }
    if (getString(keys, "playback", "untagged")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(liborca.UntaggedFallback, std.mem.span(value))) |fallback|
            self.runtime.playerSetReplayGainFallback(self.player, fallback) catch {};
    }
    if (getString(keys, "playback", "prevent_clipping")) |value| {
        defer gtk.g_free(value);
        self.runtime.playerSetPeakProtection(self.player, isEnabled(std.mem.span(value))) catch {};
    }
    if (getString(keys, "playback", "queue_end")) |value| {
        defer gtk.g_free(value);
        if (std.mem.eql(u8, std.mem.span(value), "repeat")) {
            if (self.runtime.playerSetRepeat(self.player, .all)) |_| {
                self.repeat_mode = .all;
            } else |_| {}
        }
    }
    if (getString(keys, "playback", "remember_long_position")) |value| {
        defer gtk.g_free(value);
        self.playback.remember_long_position = isEnabled(std.mem.span(value));
    }
    if (getString(keys, "playback", "on_launch")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(app.OnLaunch, std.mem.span(value))) |choice| self.playback.on_launch = choice;
    }
}

fn savePlayback(self: *App, keys: *gtk.GKeyFile) void {
    const gain = self.runtime.playerReplayGainSettings(self.player) catch liborca.ReplayGainSettings{};
    var preamp_buffer: [32]u8 = undefined;
    gtk.g_key_file_set_string(keys, "playback", "preamp", strings.format(&preamp_buffer, "{d}", .{strings.withoutNegativeZero(gain.preamp_db)}).ptr);
    gtk.g_key_file_set_string(keys, "playback", "untagged", @tagName(gain.fallback));
    gtk.g_key_file_set_string(keys, "playback", "prevent_clipping", if (gain.peak_protection) "true" else "false");
    gtk.g_key_file_set_string(keys, "playback", "queue_end", if (self.repeat_mode == .all) "repeat" else "stop");
    gtk.g_key_file_set_string(keys, "playback", "remember_long_position", if (self.playback.remember_long_position) "true" else "false");
    gtk.g_key_file_set_string(keys, "playback", "on_launch", @tagName(self.playback.on_launch));
}

fn loadCrossfeed(self: *App, text: []const u8, enabled: ?[]const u8) void {
    const amount = parseCrossfeed(text) orelse return;
    self.crossfeed_amount = amount;
    if (!isEnabled(enabled)) return;
    self.runtime.playerSetCrossfeed(self.player, amount) catch {};
}

pub const threshold_range = [2]u8{ 50, 100 };

/// A whole percentage in `threshold_range`, or null.
fn parseThreshold(text: []const u8) ?u8 {
    const percent = std.fmt.parseInt(u8, std.mem.trim(u8, text, " "), 10) catch return null;
    if (percent < threshold_range[0] or percent > threshold_range[1]) return null;
    return percent;
}

/// A thread count of at least 1, or null.
fn parseThreads(text: []const u8) ?u16 {
    const threads = std.fmt.parseInt(u16, std.mem.trim(u8, text, " "), 10) catch return null;
    return if (threads == 0) null else threads;
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

fn enableScrobbling(self: *App) void {
    const library = self.library orelse return;
    self.runtime.librarySetScrobbling(library, true, false, self.announce_now_playing) catch return;
    self.scrobbling = true;
}

pub fn reapplyScrobbling(self: *App) void {
    if (!self.scrobbling) return;
    self.scrobbling = false;
    enableScrobbling(self);
}

fn stringList(keys: *gtk.GKeyFile, group: [:0]const u8, key: [:0]const u8) ?[]?[*:0]u8 {
    var count: usize = 0;
    var err: ?*gtk.GError = null;
    const list = gtk.g_key_file_get_string_list(keys, group.ptr, key.ptr, &count, &err) orelse {
        gtk.g_clear_error(&err);
        return null;
    };
    return list[0..count];
}

fn listItem(list: ?[]?[*:0]u8, index: usize) []const u8 {
    const items = list orelse return "";
    if (index >= items.len) return "";
    return std.mem.span(items[index] orelse return "");
}

pub fn loadLibraries(self: *App) void {
    var buffer: [1024]u8 = undefined;
    const file = path(&buffer) orelse return;
    const keys = gtk.g_key_file_new();
    defer gtk.g_key_file_free(keys);
    var err: ?*gtk.GError = null;
    if (gtk.g_key_file_load_from_file(keys, file.ptr, 0, &err) == 0) {
        gtk.g_clear_error(&err);
        return;
    }
    const paths = stringList(keys, "libraries", "paths") orelse return;
    defer gtk.g_strfreev(paths.ptr);
    const names = stringList(keys, "libraries", "names");
    defer if (names) |list| gtk.g_strfreev(list.ptr);
    const tracks = stringList(keys, "libraries", "tracks");
    defer if (tracks) |list| gtk.g_strfreev(list.ptr);
    var active: usize = 0;
    if (getString(keys, "libraries", "active")) |value| {
        defer gtk.g_free(value);
        active = std.fmt.parseUnsigned(usize, std.mem.trim(u8, std.mem.span(value), " "), 10) catch 0;
    }
    for (0..paths.len) |index| {
        const library_path = listItem(paths, index);
        if (!std.fs.path.isAbsolute(library_path)) continue;
        const count = std.fmt.parseUnsigned(u64, listItem(tracks, index), 10) catch null;
        const at = libraries.append(self, listItem(names, index), library_path, count) catch break;
        if (index == active) self.libraries.chosen = at;
    }
    if (self.libraries.chosen == null and self.libraries.entries.items.len != 0) self.libraries.chosen = 0;
}

fn saveLibraries(self: *App, keys: *gtk.GKeyFile) void {
    const list = &self.libraries;
    var paths: [libraries.max_entries][*:0]const u8 = undefined;
    var names: [libraries.max_entries][*:0]const u8 = undefined;
    var tracks: [libraries.max_entries][*:0]const u8 = undefined;
    var tracks_storage: [libraries.max_entries][24]u8 = undefined;
    var count: usize = 0;
    var active: usize = 0;
    for (list.entries.items, 0..) |entry, index| {
        if (entry.transient) continue;
        if (list.chosen == index) active = count;
        paths[count] = entry.path.ptr;
        names[count] = entry.name.ptr;
        tracks[count] = if (entry.tracks) |known| strings.format(&tracks_storage[count], "{d}", .{known}).ptr else "-";
        count += 1;
    }
    if (count == 0) return;
    gtk.g_key_file_set_string_list(keys, "libraries", "paths", &paths, count);
    gtk.g_key_file_set_string_list(keys, "libraries", "names", &names, count);
    gtk.g_key_file_set_string_list(keys, "libraries", "tracks", &tracks, count);
    var active_buffer: [24]u8 = undefined;
    gtk.g_key_file_set_string(keys, "libraries", "active", strings.format(&active_buffer, "{d}", .{active}).ptr);
}

/// Applies saved choices to a newly started app.
pub fn load(self: *App) void {
    self.runtime.playerSetReplayGainFallback(self.player, .minus_6_db) catch {};
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
    loadPlayback(self, keys);
    loadEqualizers(self, keys);
    loadDevicePresets(self, keys);
    if (getString(keys, "sound", "crossfeed")) |value| {
        defer gtk.g_free(value);
        const enabled = getString(keys, "sound", "crossfeed_enabled");
        defer if (enabled) |flag| gtk.g_free(flag);
        loadCrossfeed(self, std.mem.span(value), if (enabled) |flag| std.mem.span(flag) else null);
    }
    if (getString(keys, "listening", "now_playing")) |value| {
        defer gtk.g_free(value);
        self.announce_now_playing = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "listening", "home_stats")) |value| {
        defer gtk.g_free(value);
        self.home_stats = !std.mem.eql(u8, std.mem.span(value), "false");
    }
    if (getString(keys, "listening", "scrobble")) |value| {
        defer gtk.g_free(value);
        if (std.mem.eql(u8, std.mem.span(value), "true")) enableScrobbling(self);
    }
    if (getString(keys, "matching", "accept_confidence")) |value| {
        defer gtk.g_free(value);
        if (parseThreshold(std.mem.span(value))) |percent| self.match_threshold_percent = percent;
    }
    if (getString(keys, "matching", "fingerprints")) |value| {
        defer gtk.g_free(value);
        self.match_fingerprints = isEnabled(std.mem.span(value));
    }
    if (getString(keys, "matching", "contribute")) |value| {
        defer gtk.g_free(value);
        self.contribute_acoustid = isEnabled(std.mem.span(value));
    }
    if (getString(keys, "library", "watch")) |value| {
        defer gtk.g_free(value);
        self.watch_folders = isEnabled(std.mem.span(value));
    }
    if (getString(keys, "maintenance", "enabled")) |value| {
        defer gtk.g_free(value);
        self.idle_maintenance = isEnabled(std.mem.span(value));
    }
    if (getString(keys, "library", "analysis_threads")) |value| {
        defer gtk.g_free(value);
        self.analysis_threads = parseThreads(std.mem.span(value));
    }
    if (getString(keys, "library", "fetch_artist_info")) |value| {
        defer gtk.g_free(value);
        self.fetch_artist_info = isEnabled(std.mem.span(value));
    }
    if (getString(keys, "library", "analysis_notice_dismissed")) |value| {
        defer gtk.g_free(value);
        self.analysis_notice.dismissed = std.fmt.parseUnsigned(u64, std.mem.span(value), 16) catch null;
    }
    if (getString(keys, "lyrics", "fetch")) |value| {
        defer gtk.g_free(value);
        self.lyrics.fetch = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "view", "queue_history")) |value| {
        defer gtk.g_free(value);
        self.queue.history_shown = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "view", "lyrics")) |value| {
        defer gtk.g_free(value);
        if (std.mem.eql(u8, std.mem.span(value), "true")) self.sidebar_page = .lyrics;
    }
    if (getString(keys, "view", "details")) |value| {
        defer gtk.g_free(value);
        if (std.mem.eql(u8, std.mem.span(value), "true")) self.sidebar_page = .details;
    }
    if (getString(keys, "view", "signal_path")) |value| {
        defer gtk.g_free(value);
        if (std.mem.eql(u8, std.mem.span(value), "true")) self.sidebar_page = .signal_path;
    }
    loadAppearance(self, keys);
    loadGeneral(self, keys);
    if (getString(keys, "advanced", "log_level")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(logging.Level, std.mem.span(value))) |level| logging.setLevel(level);
    }
    if (getString(keys, "view", "album_sort")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(liborca.ReleaseSort, std.mem.span(value))) |sort| self.album_sort = sort;
    }
    if (getString(keys, "view", "albums_layout")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(albums.Layout, std.mem.span(value))) |layout| self.album_layout = layout;
    }
    if (getString(keys, "view", "playlists_tab")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(playlists.Tab, std.mem.span(value))) |tab| self.playlists.tab = tab;
    }
    if (getString(keys, "view", "playlists_sort")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(liborca.PlaylistSort, std.mem.span(value))) |sort| self.playlists.sort = sort;
    }
    if (getString(keys, "view", "playlists_layout")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(albums.Layout, std.mem.span(value))) |layout| self.playlists.layout = layout;
    }
    if (getString(keys, "view", "artist_sort")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(liborca.ArtistSort, std.mem.span(value))) |sort| self.artist_sort = sort;
    }
    if (getString(keys, "view", "artists_layout")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(albums.Layout, std.mem.span(value))) |layout| self.artist_layout = layout;
    }
    if (getString(keys, "view", "artists_role")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(liborca.ArtistRole, std.mem.span(value))) |role| self.artist_info.role = role;
    }
    if (getString(keys, "view", "genre")) |value| {
        defer gtk.g_free(value);
        self.genres.selected = std.fmt.parseInt(i64, std.mem.span(value), 10) catch null;
    }
    if (getString(keys, "view", "album_cover_size") orelse getString(keys, "appearance", "album_tile")) |value| {
        defer gtk.g_free(value);
        if (parseTile(std.mem.span(value))) |pixels| self.appearance.album_grid_tile = pixels;
    }
    if (getString(keys, "view", "album_columns")) |value| {
        defer gtk.g_free(value);
        self.album_columns = albums.parseColumns(std.mem.span(value));
    }
    if (getString(keys, "view", "track_columns") orelse getString(keys, "view", "song_columns")) |value| {
        defer gtk.g_free(value);
        track_table.parseColumns(std.mem.span(value), &self.track_columns);
    }
    if (getString(keys, "view", "track_column_widths") orelse getString(keys, "view", "song_column_widths")) |value| {
        defer gtk.g_free(value);
        track_table.parseWidths(std.mem.span(value), &self.track_columns.widths);
    }
    if (getString(keys, "view", "track_columns_large")) |value| {
        defer gtk.g_free(value);
        track_table.parseColumns(std.mem.span(value), &self.track_columns_large);
    }
    if (getString(keys, "view", "track_column_widths_large")) |value| {
        defer gtk.g_free(value);
        track_table.parseWidths(std.mem.span(value), &self.track_columns_large.widths);
    }
    if (getString(keys, "playback", "volume")) |value| {
        defer gtk.g_free(value);
        if (parseVolume(std.mem.span(value))) |level|
            self.runtime.playerSetVolume(self.player, level) catch {};
    }
}

fn parseTile(text: []const u8) ?c_int {
    const pixels = std.fmt.parseInt(c_int, std.mem.trim(u8, text, " "), 10) catch return null;
    if (pixels < app.album_tile_range[0] or pixels > app.album_tile_range[1]) return null;
    return pixels;
}

fn loadAppearance(self: *App, keys: *gtk.GKeyFile) void {
    const appearance = &self.appearance;
    if (getString(keys, "appearance", "artwork")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(app.ArtworkInfluence, std.mem.span(value))) |artwork| appearance.artwork = artwork;
    }
    if (getString(keys, "appearance", "density")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(app.Density, std.mem.span(value))) |density| appearance.density = density;
    }
    if (getString(keys, "appearance", "inspector")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(app.InspectorMode, std.mem.span(value))) |mode| appearance.inspector = mode;
    } else if (getString(keys, "appearance", "inspector_open")) |value| {
        defer gtk.g_free(value);
        if (std.mem.eql(u8, std.mem.span(value), "true")) appearance.inspector = .remember;
    }
    if (getString(keys, "appearance", "display_typeface")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(app.DisplayTypeface, std.mem.span(value))) |typeface| appearance.display_typeface = typeface;
    }
    if (getString(keys, "appearance", "tabular_numerals")) |value| {
        defer gtk.g_free(value);
        appearance.tabular_numerals = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "appearance", "reduce_animation")) |value| {
        defer gtk.g_free(value);
        appearance.reduce_animation = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "appearance", "sidebar_counts")) |value| {
        defer gtk.g_free(value);
        appearance.sidebar_counts = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (appearance.inspector != .remember) self.sidebar_page = .hidden;
}

fn loadGeneral(self: *App, keys: *gtk.GKeyFile) void {
    const general = &self.general;
    if (getString(keys, "general", "launch_at_login")) |value| {
        defer gtk.g_free(value);
        general.launch_at_login = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "general", "start_page")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(app.StartPage, std.mem.span(value))) |page| general.start_page = page;
    }
    if (getString(keys, "general", "notify_tracks")) |value| {
        defer gtk.g_free(value);
        general.notify_tracks = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "general", "notify_tasks")) |value| {
        defer gtk.g_free(value);
        general.notify_tasks = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "general", "artist_name_order")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(liborca.NameOrder, std.mem.span(value))) |order| general.name_order = order;
    }
}

fn parseVolume(text: []const u8) ?f32 {
    const level = std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch return null;
    if (!(level >= 0 and level <= 1)) return null;
    return level;
}

pub fn save(self: *App) void {
    var buffer: [1024]u8 = undefined;
    const file = path(&buffer) orelse return;
    const keys = gtk.g_key_file_new();
    defer gtk.g_key_file_free(keys);
    const mode = self.runtime.playerReplayGainMode(self.player) catch .off;
    gtk.g_key_file_set_string(keys, "playback", "replay_gain", @tagName(mode));
    gtk.g_key_file_set_string(keys, "playback", "output_device", self.preferred_output.value.ptr);
    savePlayback(self, keys);
    if (self.runtime.playerVolume(self.player)) |level| {
        var volume_buffer: [32]u8 = undefined;
        gtk.g_key_file_set_string(keys, "playback", "volume", strings.format(&volume_buffer, "{d}", .{level}).ptr);
    } else |_| {}
    var equalizer_buffer: [256]u8 = undefined;
    if (formatEqualizer(&equalizer_buffer, self.equalizer_curve)) |curve|
        gtk.g_key_file_set_string(keys, "sound", "equalizer", curve.ptr);
    gtk.g_key_file_set_string(keys, "sound", "equalizer_mode", @tagName(parametric.currentMode(self)));
    var parametric_buffer: [parametric.curve_text_bytes]u8 = undefined;
    if (parametric.writeCurve(&parametric_buffer, self.parametric.curve)) |curve|
        gtk.g_key_file_set_string(keys, "sound", "parametric", curve.ptr);
    savePresets(self, keys);
    saveDevicePresets(self, keys);
    var crossfeed_buffer: [32]u8 = undefined;
    gtk.g_key_file_set_string(keys, "sound", "crossfeed", strings.format(&crossfeed_buffer, "{d}", .{self.crossfeed_amount}).ptr);
    const crossfeed_on = (self.runtime.playerCrossfeed(self.player) catch null) != null;
    gtk.g_key_file_set_string(keys, "sound", "crossfeed_enabled", if (crossfeed_on) "true" else "false");
    gtk.g_key_file_set_string(keys, "listening", "scrobble", if (self.scrobbling) "true" else "false");
    gtk.g_key_file_set_string(keys, "listening", "now_playing", if (self.announce_now_playing) "true" else "false");
    gtk.g_key_file_set_string(keys, "listening", "home_stats", if (self.home_stats) "true" else "false");
    var threshold_buffer: [8]u8 = undefined;
    gtk.g_key_file_set_string(keys, "matching", "accept_confidence", strings.format(&threshold_buffer, "{d}", .{self.match_threshold_percent}).ptr);
    gtk.g_key_file_set_string(keys, "matching", "fingerprints", if (self.match_fingerprints) "true" else "false");
    gtk.g_key_file_set_string(keys, "matching", "contribute", if (self.contribute_acoustid) "true" else "false");
    gtk.g_key_file_set_string(keys, "library", "watch", if (self.watch_folders) "true" else "false");
    if (self.analysis_threads) |threads| {
        var threads_buffer: [8]u8 = undefined;
        gtk.g_key_file_set_string(keys, "library", "analysis_threads", strings.format(&threads_buffer, "{d}", .{threads}).ptr);
    }
    gtk.g_key_file_set_string(keys, "library", "fetch_artist_info", if (self.fetch_artist_info) "true" else "false");
    if (self.analysis_notice.dismissed) |measurement_set| {
        var dismissed_buffer: [32]u8 = undefined;
        gtk.g_key_file_set_string(keys, "library", "analysis_notice_dismissed", strings.format(&dismissed_buffer, "{x:0>16}", .{measurement_set}).ptr);
    }
    gtk.g_key_file_set_string(keys, "maintenance", "enabled", if (self.idle_maintenance) "true" else "false");
    gtk.g_key_file_set_string(keys, "lyrics", "fetch", if (self.lyrics.fetch) "true" else "false");
    gtk.g_key_file_set_string(keys, "view", "queue_history", if (self.queue.history_shown) "true" else "false");
    gtk.g_key_file_set_string(keys, "view", "details", if (self.sidebar_page == .details) "true" else "false");
    gtk.g_key_file_set_string(keys, "view", "lyrics", if (self.sidebar_page == .lyrics) "true" else "false");
    gtk.g_key_file_set_string(keys, "view", "signal_path", if (self.sidebar_page == .signal_path) "true" else "false");
    gtk.g_key_file_set_string(keys, "view", "album_sort", @tagName(self.album_sort));
    gtk.g_key_file_set_string(keys, "view", "albums_layout", @tagName(self.album_layout));
    gtk.g_key_file_set_string(keys, "view", "playlists_tab", @tagName(self.playlists.tab));
    gtk.g_key_file_set_string(keys, "view", "playlists_sort", @tagName(self.playlists.sort));
    gtk.g_key_file_set_string(keys, "view", "playlists_layout", @tagName(self.playlists.layout));
    gtk.g_key_file_set_string(keys, "view", "artist_sort", @tagName(self.artist_sort));
    gtk.g_key_file_set_string(keys, "view", "artists_layout", @tagName(self.artist_layout));
    gtk.g_key_file_set_string(keys, "view", "artists_role", @tagName(self.artist_info.role));
    if (self.genres.selected) |genre| {
        var genre_buffer: [24]u8 = undefined;
        gtk.g_key_file_set_string(keys, "view", "genre", strings.format(&genre_buffer, "{d}", .{genre}).ptr);
    }
    const general = self.general;
    gtk.g_key_file_set_string(keys, "general", "launch_at_login", if (general.launch_at_login) "true" else "false");
    gtk.g_key_file_set_string(keys, "general", "start_page", @tagName(general.start_page));
    gtk.g_key_file_set_string(keys, "general", "notify_tracks", if (general.notify_tracks) "true" else "false");
    gtk.g_key_file_set_string(keys, "general", "notify_tasks", if (general.notify_tasks) "true" else "false");
    gtk.g_key_file_set_string(keys, "general", "artist_name_order", @tagName(general.name_order));
    gtk.g_key_file_set_string(keys, "advanced", "log_level", @tagName(logging.level()));
    const appearance = self.appearance;
    gtk.g_key_file_set_string(keys, "appearance", "artwork", @tagName(appearance.artwork));
    gtk.g_key_file_set_string(keys, "appearance", "density", @tagName(appearance.density));
    gtk.g_key_file_set_string(keys, "appearance", "inspector", @tagName(appearance.inspector));
    gtk.g_key_file_set_string(keys, "appearance", "display_typeface", @tagName(appearance.display_typeface));
    gtk.g_key_file_set_string(keys, "appearance", "tabular_numerals", if (appearance.tabular_numerals) "true" else "false");
    gtk.g_key_file_set_string(keys, "appearance", "reduce_animation", if (appearance.reduce_animation) "true" else "false");
    gtk.g_key_file_set_string(keys, "appearance", "sidebar_counts", if (appearance.sidebar_counts) "true" else "false");
    var album_columns_buffer: [64]u8 = undefined;
    gtk.g_key_file_set_string(keys, "view", "album_columns", albums.formatColumns(&album_columns_buffer, self.album_columns).ptr);
    var tile_buffer: [16]u8 = undefined;
    gtk.g_key_file_set_string(keys, "view", "album_cover_size", strings.format(&tile_buffer, "{d}", .{appearance.album_grid_tile}).ptr);
    var columns_buffer: [384]u8 = undefined;
    gtk.g_key_file_set_string(keys, "view", "track_columns", track_table.formatColumns(&columns_buffer, &self.track_columns).ptr);
    var widths_buffer: [384]u8 = undefined;
    gtk.g_key_file_set_string(keys, "view", "track_column_widths", track_table.formatWidths(&widths_buffer, &self.track_columns.widths).ptr);
    gtk.g_key_file_set_string(keys, "view", "track_columns_large", track_table.formatColumns(&columns_buffer, &self.track_columns_large).ptr);
    gtk.g_key_file_set_string(keys, "view", "track_column_widths_large", track_table.formatWidths(&widths_buffer, &self.track_columns_large.widths).ptr);
    saveLibraries(self, keys);
    var err: ?*gtk.GError = null;
    if (gtk.g_key_file_save_to_file(keys, file.ptr, &err) == 0) {
        gtk.g_clear_error(&err);
        self.toast("Could not save preferences");
    }
}
