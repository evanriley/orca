//! The frontend's own preferences, in `$XDG_CONFIG_HOME/orca/settings.ini`.
//!
//! Only choices a host keeps for itself live here: which output to open, the
//! ReplayGain mode, which equalizer runs, the graphic and parametric curves,
//! the saved parametric presets and crossfeed to hand the Player at launch, and
//! whether listens and the current track are submitted, how confident a match
//! Accept Confident takes, whether matching uses audio fingerprints, whether
//! the music folders are watched, whether idle maintenance runs, how many
//! files Measure Loudness decodes at once, whether lyrics are fetched from
//! LRCLIB, whether artist info is fetched, whether the queue shows what it
//! played, what the inspector shows, how albums and artists are sorted and
//! laid out, which columns an album's tracks show, the volume, and the
//! Appearance tab's choices.
//! Nothing about the library does, and never the ListenBrainz token
//! or the AcoustID key, which live in the Secret Service.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const track_table = @import("track_table.zig");
const albums = @import("albums.zig");
const playlists = @import("playlists.zig");
const parametric = @import("parametric.zig");

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
    loadEqualizers(self, keys);
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
    if (getString(keys, "view", "album_sort")) |value| {
        defer gtk.g_free(value);
        if (std.meta.stringToEnum(liborca.ReleaseSort, std.mem.span(value))) |sort| {
            self.album_sort = sort;
            if (sort != .recently_added) self.album_shelf_sort = sort;
        }
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
        self.track_columns.columns = track_table.parseColumns(std.mem.span(value));
    }
    if (getString(keys, "view", "track_column_widths") orelse getString(keys, "view", "song_column_widths")) |value| {
        defer gtk.g_free(value);
        track_table.parseWidths(std.mem.span(value), &self.track_columns.widths);
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
    if (getString(keys, "appearance", "inspector_open")) |value| {
        defer gtk.g_free(value);
        appearance.inspector_open = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "appearance", "reduce_animation")) |value| {
        defer gtk.g_free(value);
        appearance.reduce_animation = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (getString(keys, "appearance", "sidebar_counts")) |value| {
        defer gtk.g_free(value);
        appearance.sidebar_counts = std.mem.eql(u8, std.mem.span(value), "true");
    }
    if (appearance.inspector_open and self.sidebar_page == .hidden) self.sidebar_page = .details;
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
    var crossfeed_buffer: [32]u8 = undefined;
    gtk.g_key_file_set_string(keys, "sound", "crossfeed", strings.format(&crossfeed_buffer, "{d}", .{self.crossfeed_amount}).ptr);
    const crossfeed_on = (self.runtime.playerCrossfeed(self.player) catch null) != null;
    gtk.g_key_file_set_string(keys, "sound", "crossfeed_enabled", if (crossfeed_on) "true" else "false");
    gtk.g_key_file_set_string(keys, "listening", "scrobble", if (self.scrobbling) "true" else "false");
    gtk.g_key_file_set_string(keys, "listening", "now_playing", if (self.announce_now_playing) "true" else "false");
    var threshold_buffer: [8]u8 = undefined;
    gtk.g_key_file_set_string(keys, "matching", "accept_confidence", strings.format(&threshold_buffer, "{d}", .{self.match_threshold_percent}).ptr);
    gtk.g_key_file_set_string(keys, "matching", "fingerprints", if (self.match_fingerprints) "true" else "false");
    gtk.g_key_file_set_string(keys, "library", "watch", if (self.watch_folders) "true" else "false");
    if (self.analysis_threads) |threads| {
        var threads_buffer: [8]u8 = undefined;
        gtk.g_key_file_set_string(keys, "library", "analysis_threads", strings.format(&threads_buffer, "{d}", .{threads}).ptr);
    }
    gtk.g_key_file_set_string(keys, "library", "fetch_artist_info", if (self.fetch_artist_info) "true" else "false");
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
    if (self.genres.selected) |genre| {
        var genre_buffer: [24]u8 = undefined;
        gtk.g_key_file_set_string(keys, "view", "genre", strings.format(&genre_buffer, "{d}", .{genre}).ptr);
    }
    const appearance = self.appearance;
    gtk.g_key_file_set_string(keys, "appearance", "artwork", @tagName(appearance.artwork));
    gtk.g_key_file_set_string(keys, "appearance", "density", @tagName(appearance.density));
    gtk.g_key_file_set_string(keys, "appearance", "inspector_open", if (appearance.inspector_open) "true" else "false");
    gtk.g_key_file_set_string(keys, "appearance", "reduce_animation", if (appearance.reduce_animation) "true" else "false");
    gtk.g_key_file_set_string(keys, "appearance", "sidebar_counts", if (appearance.sidebar_counts) "true" else "false");
    var album_columns_buffer: [64]u8 = undefined;
    gtk.g_key_file_set_string(keys, "view", "album_columns", albums.formatColumns(&album_columns_buffer, self.album_columns).ptr);
    var tile_buffer: [16]u8 = undefined;
    gtk.g_key_file_set_string(keys, "view", "album_cover_size", strings.format(&tile_buffer, "{d}", .{appearance.album_grid_tile}).ptr);
    var columns_buffer: [256]u8 = undefined;
    gtk.g_key_file_set_string(keys, "view", "track_columns", track_table.formatColumns(&columns_buffer, self.track_columns.columns).ptr);
    var widths_buffer: [256]u8 = undefined;
    gtk.g_key_file_set_string(keys, "view", "track_column_widths", track_table.formatWidths(&widths_buffer, &self.track_columns.widths).ptr);
    var err: ?*gtk.GError = null;
    if (gtk.g_key_file_save_to_file(keys, file.ptr, &err) == 0) {
        gtk.g_clear_error(&err);
        self.toast("Could not save preferences");
    }
}
