//! MPRIS2 over GDBus.
//!
//! Every property here is read from an authoritative snapshot at the moment it
//! is asked for — `playerStatus` for transport, position, duration, volume and
//! queue shape, `playerNowPlaying` plus `libraryTrackSummary` for the audible
//! entry. None of it is reconstructed from the event stream, which carries
//! coalescing hints.
//!
//! Every GVariant here is assembled from the non-variadic primitives
//! (`g_variant_new_array`, `_dict_entry`, `_variant`, `_tuple`). `g_variant_new`
//! and `g_variant_get` are format-string varargs and are deliberately not bound.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");

const introspection_xml =
    "<node>" ++
    " <interface name='org.mpris.MediaPlayer2'>" ++
    "  <method name='Raise'/><method name='Quit'/>" ++
    "  <property name='CanQuit' type='b' access='read'/>" ++
    "  <property name='CanRaise' type='b' access='read'/>" ++
    "  <property name='HasTrackList' type='b' access='read'/>" ++
    "  <property name='Identity' type='s' access='read'/>" ++
    "  <property name='DesktopEntry' type='s' access='read'/>" ++
    "  <property name='SupportedUriSchemes' type='as' access='read'/>" ++
    "  <property name='SupportedMimeTypes' type='as' access='read'/>" ++
    " </interface>" ++
    " <interface name='org.mpris.MediaPlayer2.Player'>" ++
    "  <method name='Next'/><method name='Previous'/><method name='Pause'/>" ++
    "  <method name='PlayPause'/><method name='Stop'/><method name='Play'/>" ++
    "  <method name='Seek'><arg name='Offset' type='x' direction='in'/></method>" ++
    "  <method name='SetPosition'>" ++
    "   <arg name='TrackId' type='o' direction='in'/>" ++
    "   <arg name='Position' type='x' direction='in'/>" ++
    "  </method>" ++
    "  <property name='PlaybackStatus' type='s' access='read'/>" ++
    "  <property name='LoopStatus' type='s' access='read'/>" ++
    "  <property name='Shuffle' type='b' access='read'/>" ++
    "  <property name='Metadata' type='a{sv}' access='read'/>" ++
    "  <property name='Volume' type='d' access='readwrite'/>" ++
    "  <property name='Position' type='x' access='read'/>" ++
    "  <property name='Rate' type='d' access='read'/>" ++
    "  <property name='MinimumRate' type='d' access='read'/>" ++
    "  <property name='MaximumRate' type='d' access='read'/>" ++
    "  <property name='CanGoNext' type='b' access='read'/>" ++
    "  <property name='CanGoPrevious' type='b' access='read'/>" ++
    "  <property name='CanPlay' type='b' access='read'/>" ++
    "  <property name='CanPause' type='b' access='read'/>" ++
    "  <property name='CanSeek' type='b' access='read'/>" ++
    "  <property name='CanControl' type='b' access='read'/>" ++
    " </interface>" ++
    "</node>";

/// The audible entry resolved to a Track summary, caller-owned. Shared with the
/// transport, which needs exactly the same two-step resolve.
pub const NowPlaying = struct {
    allocator: std.mem.Allocator,
    summary: liborca.TrackSummary,

    pub fn deinit(self: NowPlaying) void {
        self.summary.deinit(self.allocator);
    }
};

pub fn nowPlaying(
    runtime: *liborca.Runtime,
    player: liborca.PlayerHandle,
) ?NowPlaying {
    const current = (runtime.playerNowPlaying(player) catch return null) orelse return null;
    const summary = (runtime.libraryTrackSummary(current.library, current.track_id) catch
        return null) orelse return null;
    return .{ .allocator = runtime.allocator, .summary = summary };
}

pub const Mpris = struct {
    runtime: ?*liborca.Runtime = null,
    /// The track whose cover is currently on disk, and the `file://` URL of
    /// it. Remembered even when that track has no cover, so a metadata read —
    /// which a controller may do often — does not re-open the audio file every
    /// time to learn the same "no" again.
    /// The `std.Io` its Library was opened with, needed to read a cover file.
    io: std.Io = undefined,
    art_track_id: ?i64 = null,
    art_url: ?[:0]u8 = null,
    art_path: ?[:0]u8 = null,
    player: liborca.PlayerHandle = .{ .index = 0, .generation = 0 },
    application: ?*gtk.GApplication = null,
    request_tick: ?liborca.HostWaker = null,
    connection: ?*gtk.GDBusConnection = null,
    node: ?*gtk.GDBusNodeInfo = null,
    owner_id: c_uint = 0,
    root_registration: c_uint = 0,
    player_registration: c_uint = 0,

    fn requestTick(self: *Mpris) void {
        const waker = self.request_tick orelse return;
        waker.wake_fn(waker.context);
    }

    fn status(self: *Mpris) ?liborca.PlayerStatus {
        const runtime = self.runtime orelse return null;
        return runtime.playerStatus(self.player) catch null;
    }

    fn playbackStatus(self: *Mpris) [:0]const u8 {
        const snapshot = self.status() orelse return "Stopped";
        return switch (snapshot.transport) {
            .playing => "Playing",
            .paused => "Paused",
            .stopped => "Stopped",
        };
    }

    fn buildMetadata(self: *Mpris) *gtk.GVariant {
        const runtime = self.runtime orelse return emptyDict();
        const current = nowPlaying(runtime, self.player) orelse return emptyDict();
        defer current.deinit();
        const summary = current.summary;

        // Seven at most: trackid, length, title, artist, album, albumArtist,
        // artUrl.
        var children: [7]*gtk.GVariant = undefined;
        var count: usize = 0;

        var path_buffer: [96]u8 = undefined;
        const path = strings.printZ(
            &path_buffer,
            "/org/orca_music/Orca/Track/{d}",
            .{summary.id},
        ) catch "/org/orca_music/Orca/Track/0";
        children[count] = entry("mpris:trackid", gtk.g_variant_new_object_path(path.ptr));
        count += 1;

        if (summary.duration_ms) |duration| {
            if (duration > 0) {
                children[count] = entry("mpris:length", gtk.g_variant_new_int64(duration * 1000));
                count += 1;
            }
        }
        if (textVariant(runtime.allocator, summary.title)) |value| {
            children[count] = entry("xesam:title", value);
            count += 1;
        }
        if (strvVariant(runtime.allocator, summary.artist)) |value| {
            children[count] = entry("xesam:artist", value);
            count += 1;
        }
        if (textVariant(runtime.allocator, summary.album)) |value| {
            children[count] = entry("xesam:album", value);
            count += 1;
        }
        if (strvVariant(runtime.allocator, summary.album_artist)) |value| {
            children[count] = entry("xesam:albumArtist", value);
            count += 1;
        }
        if (self.artUrlFor(runtime, summary.id)) |url| {
            children[count] = entry("mpris:artUrl", gtk.g_variant_new_string(url.ptr));
            count += 1;
        }
        return gtk.g_variant_new_array(gtk.variantType("{sv}"), &children, count);
    }

    /// From the sniffed MIME type, never from what a tag claimed: the reader
    /// already refuses bytes it cannot identify, so this is the truth.
    fn extensionFor(mime_type: []const u8) []const u8 {
        if (std.mem.eql(u8, mime_type, "image/jpeg")) return ".jpg";
        if (std.mem.eql(u8, mime_type, "image/png")) return ".png";
        if (std.mem.eql(u8, mime_type, "image/gif")) return ".gif";
        if (std.mem.eql(u8, mime_type, "image/webp")) return ".webp";
        return ".img";
    }

    /// Emits PropertiesChanged for the properties a controller caches. Called
    /// when the transport or the audible entry changes — never on a timer,
    /// because Position is deliberately not a cached property in MPRIS.
    pub fn notify(self: *Mpris) void {
        const connection = self.connection orelse return;
        var changed: [6]*gtk.GVariant = undefined;
        var count: usize = 0;
        changed[count] = entry(
            "PlaybackStatus",
            gtk.g_variant_new_string(self.playbackStatus().ptr),
        );
        count += 1;
        changed[count] = entry("Metadata", self.buildMetadata());
        count += 1;
        if (self.status()) |snapshot| {
            changed[count] = entry("Volume", gtk.g_variant_new_double(snapshot.volume));
            count += 1;
            changed[count] = entry(
                "CanGoNext",
                gtk.g_variant_new_boolean(boolean(snapshot.queue_length > 0)),
            );
            count += 1;
            changed[count] = entry(
                "CanGoPrevious",
                gtk.g_variant_new_boolean(boolean(snapshot.queue_length > 0)),
            );
            count += 1;
            changed[count] = entry(
                "CanSeek",
                gtk.g_variant_new_boolean(boolean(snapshot.duration_ms > 0)),
            );
            count += 1;
        }
        const body: [3]*gtk.GVariant = .{
            gtk.g_variant_new_string("org.mpris.MediaPlayer2.Player"),
            gtk.g_variant_new_array(gtk.variantType("{sv}"), &changed, count),
            gtk.g_variant_new_array(gtk.variantType("s"), null, 0),
        };
        _ = gtk.g_dbus_connection_emit_signal(
            connection,
            null,
            "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            gtk.g_variant_new_tuple(&body, body.len),
            null,
        );
    }

    pub fn toggle(self: *Mpris) void {
        const runtime = self.runtime orelse return;
        const snapshot = self.status() orelse return;
        if (snapshot.transport == .playing)
            runtime.pausePlayer(self.player) catch {}
        else
            runtime.playPlayer(self.player) catch {};
        self.notify();
        self.requestTick();
    }

    fn emitSeeked(self: *Mpris) void {
        const connection = self.connection orelse return;
        const snapshot = self.status() orelse return;
        const body: [1]*gtk.GVariant = .{
            gtk.g_variant_new_int64(@as(i64, @intCast(snapshot.position_ms)) * 1000),
        };
        _ = gtk.g_dbus_connection_emit_signal(
            connection,
            null,
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
            "Seeked",
            gtk.g_variant_new_tuple(&body, body.len),
            null,
        );
    }

    fn seekToUs(self: *Mpris, microseconds: i64) void {
        const runtime = self.runtime orelse return;
        const milliseconds: u64 = if (microseconds <= 0)
            0
        else
            @intCast(@divTrunc(microseconds, 1000));
        _ = runtime.playerSeekMs(self.player, milliseconds) catch return;
        self.emitSeeked();
        self.requestTick();
    }

    /// MPRIS carries a *URL*, not bytes, so a cover has to exist as a file for
    /// any other client to read. One file at a time, replaced when the track
    /// changes and removed on shutdown, in the user's cache directory where a
    /// discardable derived artifact belongs.
    ///
    /// The name carries the track id so the URL changes with the track:
    /// controllers cache by URL, and a stable path would leave the previous
    /// cover on screen.
    fn artUrlFor(self: *Mpris, runtime: *liborca.Runtime, track_id: i64) ?[:0]const u8 {
        if (self.art_track_id) |cached| {
            if (cached == track_id) return self.art_url;
        }
        self.releaseArt();
        self.art_track_id = track_id;

        const library = (runtime.playerLibrary(self.player) catch return null) orelse
            return null;
        const cover = (runtime.libraryTrackArtwork(library, self.io, track_id) catch
            return null) orelse return null;
        defer cover.deinit();

        const allocator = runtime.allocator;
        const directory = std.fmt.allocPrintSentinel(
            allocator,
            "{s}/orca",
            .{std.mem.span(gtk.g_get_user_cache_dir())},
            0,
        ) catch return null;
        defer allocator.free(directory);
        if (gtk.g_mkdir_with_parents(directory.ptr, 0o700) != 0) return null;

        const path = std.fmt.allocPrintSentinel(
            allocator,
            "{s}/now-playing-{d}{s}",
            .{ directory, track_id, extensionFor(cover.mime_type) },
            0,
        ) catch return null;
        var err: ?*gtk.GError = null;
        if (gtk.g_file_set_contents(
            path.ptr,
            cover.bytes.ptr,
            @intCast(cover.bytes.len),
            &err,
        ) == 0) {
            gtk.g_clear_error(&err);
            allocator.free(path);
            return null;
        }
        const url = std.fmt.allocPrintSentinel(allocator, "file://{s}", .{path}, 0) catch {
            _ = gtk.g_unlink(path.ptr);
            allocator.free(path);
            return null;
        };
        self.art_path = path;
        self.art_url = url;
        return url;
    }

    fn releaseArt(self: *Mpris) void {
        const runtime = self.runtime orelse return;
        if (self.art_path) |path| {
            _ = gtk.g_unlink(path.ptr);
            runtime.allocator.free(path);
            self.art_path = null;
        }
        if (self.art_url) |url| {
            runtime.allocator.free(url);
            self.art_url = null;
        }
        self.art_track_id = null;
    }

    pub fn init(
        self: *Mpris,
        runtime: *liborca.Runtime,
        player: liborca.PlayerHandle,
        application: *gtk.GApplication,
        io: std.Io,
        request_tick: liborca.HostWaker,
    ) void {
        self.* = .{
            .runtime = runtime,
            .player = player,
            .application = application,
            .io = io,
            .request_tick = request_tick,
        };
        var err: ?*gtk.GError = null;
        self.connection = gtk.g_bus_get_sync(gtk.BUS_TYPE_SESSION, null, &err);
        if (self.connection == null) {
            gtk.g_clear_error(&err);
            return;
        }
        self.node = gtk.g_dbus_node_info_new_for_xml(introspection_xml, &err);
        const node = self.node orelse {
            gtk.g_clear_error(&err);
            gtk.g_object_unref(self.connection);
            self.connection = null;
            return;
        };
        const connection = self.connection.?;
        if (node.interfaces[0]) |root_interface| {
            self.root_registration = gtk.g_dbus_connection_register_object(
                connection,
                "/org/mpris/MediaPlayer2",
                root_interface,
                &vtable,
                self,
                null,
                &err,
            );
        }
        if (node.interfaces[1]) |player_interface| {
            self.player_registration = gtk.g_dbus_connection_register_object(
                connection,
                "/org/mpris/MediaPlayer2",
                player_interface,
                &vtable,
                self,
                null,
                &err,
            );
        }
        if (err != null) gtk.g_clear_error(&err);
        self.owner_id = gtk.g_bus_own_name_on_connection(
            connection,
            "org.mpris.MediaPlayer2.orca",
            gtk.BUS_NAME_OWNER_FLAGS_NONE,
            null,
            null,
            null,
            null,
        );
    }

    pub fn deinit(self: *Mpris) void {
        // The cover file is a derived artifact of this process's now-playing
        // state; leaving it in the cache directory would outlive its meaning.
        self.releaseArt();
        if (self.owner_id != 0) gtk.g_bus_unown_name(self.owner_id);
        if (self.connection) |connection| {
            if (self.root_registration != 0)
                _ = gtk.g_dbus_connection_unregister_object(connection, self.root_registration);
            if (self.player_registration != 0)
                _ = gtk.g_dbus_connection_unregister_object(connection, self.player_registration);
        }
        if (self.node) |node| gtk.g_dbus_node_info_unref(node);
        if (self.connection) |connection| gtk.g_object_unref(connection);
        self.* = .{};
    }
};

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

fn entry(key: [*:0]const u8, value: *gtk.GVariant) *gtk.GVariant {
    return gtk.g_variant_new_dict_entry(
        gtk.g_variant_new_string(key),
        gtk.g_variant_new_variant(value),
    );
}

fn emptyDict() *gtk.GVariant {
    // An empty Metadata dict with no trackid is what MPRIS means by "nothing is
    // playing"; a fabricated entry would be worse.
    return gtk.g_variant_new_array(gtk.variantType("{sv}"), null, 0);
}

/// `g_variant_new_string` copies, so the terminated duplicate only has to
/// outlive the call.
fn textVariant(allocator: std.mem.Allocator, text: []const u8) ?*gtk.GVariant {
    if (text.len == 0) return null;
    const terminated = allocator.dupeSentinel(u8, text, 0) catch return null;
    defer allocator.free(terminated);
    return gtk.g_variant_new_string(terminated.ptr);
}

fn strvVariant(allocator: std.mem.Allocator, text: []const u8) ?*gtk.GVariant {
    if (text.len == 0) return null;
    const terminated = allocator.dupeSentinel(u8, text, 0) catch return null;
    defer allocator.free(terminated);
    const list: [1]?[*:0]const u8 = .{terminated.ptr};
    return gtk.g_variant_new_strv(&list, list.len);
}

fn self_from(data: ?*anyopaque) *Mpris {
    return @ptrCast(@alignCast(data.?));
}

fn playerMethod(mpris: *Mpris, method: []const u8, parameters: *gtk.GVariant) void {
    const runtime = mpris.runtime orelse return;
    if (std.mem.eql(u8, method, "Play")) {
        runtime.playPlayer(mpris.player) catch {};
    } else if (std.mem.eql(u8, method, "Pause")) {
        runtime.pausePlayer(mpris.player) catch {};
    } else if (std.mem.eql(u8, method, "Stop")) {
        runtime.stopPlayer(mpris.player) catch {};
    } else if (std.mem.eql(u8, method, "PlayPause")) {
        mpris.toggle();
        return;
    } else if (std.mem.eql(u8, method, "Next")) {
        _ = runtime.playerNext(mpris.player) catch {};
    } else if (std.mem.eql(u8, method, "Previous")) {
        _ = runtime.playerPrevious(mpris.player) catch {};
    } else if (std.mem.eql(u8, method, "Seek")) {
        const offset = childInt64(parameters, 0);
        const snapshot = mpris.status() orelse return;
        mpris.seekToUs(@as(i64, @intCast(snapshot.position_ms)) * 1000 + offset);
        return;
    } else if (std.mem.eql(u8, method, "SetPosition")) {
        // Argument 0 is the track object path, which this player does not use to
        // discriminate: the audible entry is authoritative.
        mpris.seekToUs(childInt64(parameters, 1));
        return;
    } else {
        return;
    }
    mpris.notify();
    mpris.requestTick();
}

fn childInt64(parameters: *gtk.GVariant, index: usize) i64 {
    const child = gtk.g_variant_get_child_value(parameters, index);
    defer gtk.g_variant_unref(child);
    return gtk.g_variant_get_int64(child);
}

fn methodCall(
    _: *gtk.GDBusConnection,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    method_name: ?[*:0]const u8,
    parameters: *gtk.GVariant,
    invocation: *gtk.GDBusMethodInvocation,
    data: ?*anyopaque,
) callconv(.c) void {
    const mpris = self_from(data);
    const interface = std.mem.span(interface_name orelse "");
    const method = std.mem.span(method_name orelse "");
    if (std.mem.eql(u8, interface, "org.mpris.MediaPlayer2")) {
        if (mpris.application) |application| {
            if (std.mem.eql(u8, method, "Quit"))
                gtk.g_application_quit(application)
            else if (std.mem.eql(u8, method, "Raise"))
                gtk.g_application_activate(application);
        }
    } else {
        playerMethod(mpris, method, parameters);
    }
    gtk.g_dbus_method_invocation_return_value(invocation, null);
}

fn getProperty(
    _: *gtk.GDBusConnection,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    property_name: ?[*:0]const u8,
    _: ?*?*gtk.GError,
    data: ?*anyopaque,
) callconv(.c) ?*gtk.GVariant {
    const mpris = self_from(data);
    const interface = std.mem.span(interface_name orelse "");
    const property = std.mem.span(property_name orelse "");
    if (std.mem.eql(u8, interface, "org.mpris.MediaPlayer2")) {
        if (std.mem.eql(u8, property, "CanQuit")) return gtk.g_variant_new_boolean(gtk.true_);
        if (std.mem.eql(u8, property, "CanRaise")) return gtk.g_variant_new_boolean(gtk.true_);
        if (std.mem.eql(u8, property, "HasTrackList"))
            return gtk.g_variant_new_boolean(gtk.false_);
        if (std.mem.eql(u8, property, "Identity")) return gtk.g_variant_new_string("Orca");
        if (std.mem.eql(u8, property, "DesktopEntry")) return gtk.g_variant_new_string("orca");
        return gtk.g_variant_new_strv(null, 0);
    }
    if (std.mem.eql(u8, property, "PlaybackStatus"))
        return gtk.g_variant_new_string(mpris.playbackStatus().ptr);
    if (std.mem.eql(u8, property, "Metadata")) return mpris.buildMetadata();
    if (std.mem.eql(u8, property, "Rate") or
        std.mem.eql(u8, property, "MinimumRate") or
        std.mem.eql(u8, property, "MaximumRate")) return gtk.g_variant_new_double(1.0);

    const snapshot = mpris.status();
    if (std.mem.eql(u8, property, "Position")) return gtk.g_variant_new_int64(
        if (snapshot) |value| @as(i64, @intCast(value.position_ms)) * 1000 else 0,
    );
    if (std.mem.eql(u8, property, "Volume")) return gtk.g_variant_new_double(
        if (snapshot) |value| value.volume else 1.0,
    );
    if (std.mem.eql(u8, property, "LoopStatus")) {
        const value = snapshot orelse return gtk.g_variant_new_string("None");
        return gtk.g_variant_new_string(switch (value.repeat) {
            .all => "Playlist",
            .one => "Track",
            .off => "None",
        });
    }
    if (std.mem.eql(u8, property, "Shuffle")) return gtk.g_variant_new_boolean(
        boolean(if (snapshot) |value| value.shuffle else false),
    );
    if (std.mem.eql(u8, property, "CanGoNext") or std.mem.eql(u8, property, "CanGoPrevious"))
        return gtk.g_variant_new_boolean(
            boolean(if (snapshot) |value| value.queue_length > 0 else false),
        );
    if (std.mem.eql(u8, property, "CanSeek")) return gtk.g_variant_new_boolean(
        boolean(if (snapshot) |value| value.duration_ms > 0 else false),
    );
    if (std.mem.eql(u8, property, "CanPlay") or
        std.mem.eql(u8, property, "CanPause") or
        std.mem.eql(u8, property, "CanControl")) return gtk.g_variant_new_boolean(gtk.true_);
    return gtk.g_variant_new_boolean(gtk.false_);
}

fn setProperty(
    _: *gtk.GDBusConnection,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
    property_name: ?[*:0]const u8,
    value: *gtk.GVariant,
    _: ?*?*gtk.GError,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    const mpris = self_from(data);
    const runtime = mpris.runtime orelse return gtk.false_;
    const property = std.mem.span(property_name orelse "");
    if (!std.mem.eql(u8, property, "Volume")) return gtk.false_;
    const requested = std.math.clamp(gtk.g_variant_get_double(value), 0.0, 4.0);
    runtime.playerSetVolume(mpris.player, @floatCast(requested)) catch return gtk.false_;
    mpris.notify();
    mpris.requestTick();
    return gtk.true_;
}

const vtable: gtk.GDBusInterfaceVTable = .{
    .method_call = methodCall,
    .get_property = getProperty,
    .set_property = setProperty,
};
