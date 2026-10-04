const std = @import("std");
const database = @import("../database/root.zig");
const file_mutation = @import("../metadata/file_mutation.zig");
const m3u = @import("../library/m3u.zig");
const runtime = @import("runtime.zig");

const path = std.Io.Dir.path;

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;
const PlayerHandle = runtime.PlayerHandle;
const PlaylistEntryPage = runtime.PlaylistEntryPage;
const PlaylistInsertion = runtime.PlaylistInsertion;
const PlaylistPage = runtime.PlaylistPage;
const PlaylistQuery = runtime.PlaylistQuery;
const PlaylistSummary = runtime.PlaylistSummary;
const PlaylistUpdate = runtime.PlaylistUpdate;
const PlaylistFormats = runtime.PlaylistFormats;
const SmartPlaylistPreview = runtime.SmartPlaylistPreview;
const Evaluation = @import("../library/smart_playlist.zig").Evaluation;
const RatingChange = runtime.RatingChange;
const ReleaseLoveChange = runtime.ReleaseLoveChange;

pub fn librarySetRating(
    self: *OrcaRuntime,
    library: LibraryHandle,
    track_ids: []const i64,
    rating: ?u8,
) !RatingChange {
    return (try runtime.libraryDatabase(self, library)).ratings.set(track_ids, rating);
}

pub fn librarySetReleaseLove(
    self: *OrcaRuntime,
    library: LibraryHandle,
    release_ids: []const i64,
    loved: bool,
) !ReleaseLoveChange {
    return (try runtime.libraryDatabase(self, library)).release_loves.set(release_ids, loved);
}

pub fn libraryPlaylists(self: *OrcaRuntime, library: LibraryHandle, limit: u32, offset: u32) !PlaylistPage {
    return (try runtime.libraryDatabase(self, library)).playlists.list(self.allocator, limit, offset, evaluation(self));
}

fn evaluation(self: *OrcaRuntime) Evaluation {
    const seed = self.playlist_shuffle_seed orelse drawShuffleSeed(self);
    return .{ .now = std.Io.Clock.real.now(self.control_threaded.io()).toSeconds(), .seed = seed };
}

fn drawShuffleSeed(self: *OrcaRuntime) u64 {
    var bytes: [8]u8 = undefined;
    self.control_threaded.io().random(&bytes);
    const seed = std.mem.readInt(u64, &bytes, .little);
    self.playlist_shuffle_seed = seed;
    return seed;
}

pub fn libraryReshufflePlaylists(self: *OrcaRuntime) void {
    _ = drawShuffleSeed(self);
}

pub fn libraryPlaylistPage(self: *OrcaRuntime, library: LibraryHandle, query: PlaylistQuery) !PlaylistPage {
    return (try runtime.libraryDatabase(self, library)).playlists.page(self.allocator, query, evaluation(self));
}

pub fn libraryPlaylistCount(self: *OrcaRuntime, library: LibraryHandle, query: PlaylistQuery) !u64 {
    return (try runtime.libraryDatabase(self, library)).playlists.pageCount(query);
}

pub fn libraryPlaylist(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64) !PlaylistSummary {
    return (try runtime.libraryDatabase(self, library)).playlists.summary(self.allocator, playlist_id, evaluation(self));
}

pub fn libraryUpdatePlaylist(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64, change: PlaylistUpdate) !void {
    return (try runtime.libraryDatabase(self, library)).playlists.update(playlist_id, change);
}

pub fn libraryCreateSmartPlaylist(self: *OrcaRuntime, library: LibraryHandle, name: []const u8, rules_json: []const u8) !i64 {
    return (try runtime.libraryDatabase(self, library)).playlists.createSmart(self.allocator, name, rules_json);
}

pub fn librarySetSmartPlaylistRules(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64, rules_json: []const u8) !void {
    return (try runtime.libraryDatabase(self, library)).playlists.setRules(self.allocator, playlist_id, rules_json);
}

pub fn librarySmartPlaylistRules(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64) !?[]u8 {
    return (try runtime.libraryDatabase(self, library)).playlists.rules(self.allocator, playlist_id);
}

pub fn libraryPlaylistTags(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64) ![][]u8 {
    return (try runtime.libraryDatabase(self, library)).playlists.tags(self.allocator, playlist_id);
}

pub fn librarySmartPlaylistCount(self: *OrcaRuntime, library: LibraryHandle, rules_json: []const u8) !u64 {
    return (try runtime.libraryDatabase(self, library)).playlists.smartCount(self.allocator, rules_json, evaluation(self));
}

pub fn librarySmartPlaylistPreview(
    self: *OrcaRuntime,
    library: LibraryHandle,
    allocator: std.mem.Allocator,
    rules_json: []const u8,
    sample_limit: u32,
) !SmartPlaylistPreview {
    return (try runtime.libraryDatabase(self, library)).playlists.smartPreview(allocator, rules_json, sample_limit, evaluation(self));
}

pub fn libraryPlaylistFormats(self: *OrcaRuntime, library: LibraryHandle, allocator: std.mem.Allocator, playlist_id: i64) !PlaylistFormats {
    return (try runtime.libraryDatabase(self, library)).playlists.formats(allocator, playlist_id, evaluation(self));
}

pub fn libraryCreatePlaylist(self: *OrcaRuntime, library: LibraryHandle, name: []const u8) !i64 {
    return (try runtime.libraryDatabase(self, library)).playlists.create(name);
}

pub fn libraryRenamePlaylist(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64, name: []const u8) !void {
    return (try runtime.libraryDatabase(self, library)).playlists.rename(playlist_id, name);
}

pub fn libraryDeletePlaylist(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64) !void {
    return (try runtime.libraryDatabase(self, library)).playlists.delete(playlist_id);
}

pub fn libraryPlaylistEntries(
    self: *OrcaRuntime,
    library: LibraryHandle,
    playlist_id: i64,
    limit: u32,
    offset: u32,
) !PlaylistEntryPage {
    return (try runtime.libraryDatabase(self, library)).playlists.entries(self.allocator, playlist_id, limit, offset, evaluation(self));
}

pub fn libraryPlaylistInsert(
    self: *OrcaRuntime,
    library: LibraryHandle,
    playlist_id: i64,
    track_ids: []const i64,
    at: ?u32,
) !PlaylistInsertion {
    return (try runtime.libraryDatabase(self, library)).playlists.insert(playlist_id, track_ids, at);
}

pub fn libraryPlaylistRemove(
    self: *OrcaRuntime,
    library: LibraryHandle,
    playlist_id: i64,
    positions: []const u32,
) !u32 {
    return (try runtime.libraryDatabase(self, library)).playlists.remove(playlist_id, positions);
}

pub fn libraryPlaylistMove(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64, from: u32, to: u32) !void {
    return (try runtime.libraryDatabase(self, library)).playlists.move(playlist_id, from, to);
}

pub fn playerPlayPlaylist(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    io: std.Io,
    playlist_id: i64,
    start: u32,
) !void {
    const track_ids = try (try runtime.libraryDatabase(self, library)).playlists.trackIds(self.allocator, playlist_id, evaluation(self));
    defer self.allocator.free(track_ids);
    if (track_ids.len == 0) return error.PlaylistEmpty;
    return self.playerPlayTracks(player, library, io, track_ids, start);
}

pub const max_reported_unmatched = 50;

pub const PlaylistImport = struct {
    allocator: std.mem.Allocator,
    playlist_id: i64,
    matched_by_path: u32,
    matched_by_info: u32,
    unmatched: u32,
    unmatched_lines: [][]u8,

    pub fn deinit(self: PlaylistImport) void {
        for (self.unmatched_lines) |line| self.allocator.free(line);
        self.allocator.free(self.unmatched_lines);
    }
};

pub const PlaylistPathStyle = enum { absolute, relative };

pub const PlaylistExportOptions = struct {
    paths: PlaylistPathStyle,
    replace: bool,
};

pub const PlaylistExport = struct {
    written: u32,
    skipped: u32,
};

const MatchSource = enum { path, info };

const Match = struct {
    recording_id: i64,
    source: MatchSource,
};

pub fn libraryImportPlaylist(
    self: *OrcaRuntime,
    library: LibraryHandle,
    io: std.Io,
    playlist_path: []const u8,
    name: ?[]const u8,
) !PlaylistImport {
    const allocator = self.allocator;
    const library_database = try runtime.libraryDatabase(self, library);
    const absolute_path = try absolutePath(allocator, io, playlist_path);
    defer allocator.free(absolute_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, absolute_path, allocator, .limited(m3u.max_bytes + 1)) catch |err|
        return if (err == error.StreamTooLong) error.PlaylistTooLarge else err;
    defer allocator.free(bytes);
    const parsed = try m3u.parse(allocator, bytes);
    defer parsed.deinit(allocator);
    if (parsed.entries.len == 0) return error.PlaylistEmpty;

    const base_directory = path.dirnamePosix(absolute_path) orelse "/";
    var recording_ids: std.ArrayList(i64) = try .initCapacity(allocator, parsed.entries.len);
    defer recording_ids.deinit(allocator);
    var unmatched_lines: std.ArrayList([]u8) = .empty;
    defer {
        for (unmatched_lines.items) |line| allocator.free(line);
        unmatched_lines.deinit(allocator);
    }
    var matched_by_path: u32 = 0;
    var matched_by_info: u32 = 0;
    var unmatched: u32 = 0;
    var by_credit: ?database.RecordingsByCredit = null;
    defer if (by_credit) |*index| index.deinit();
    for (parsed.entries) |entry| {
        const match = try matchEntry(allocator, &library_database.playlists, &by_credit, base_directory, entry) orelse {
            unmatched += 1;
            if (unmatched_lines.items.len < max_reported_unmatched) {
                const line = try allocator.dupe(u8, entry.location);
                errdefer allocator.free(line);
                try unmatched_lines.append(allocator, line);
            }
            continue;
        };
        recording_ids.appendAssumeCapacity(match.recording_id);
        switch (match.source) {
            .path => matched_by_path += 1,
            .info => matched_by_info += 1,
        }
    }
    const playlist_name = name orelse path.stem(absolute_path);
    const playlist_id = try library_database.playlists.createWithRecordings(allocator, playlist_name, recording_ids.items);
    return .{
        .allocator = allocator,
        .playlist_id = playlist_id,
        .matched_by_path = matched_by_path,
        .matched_by_info = matched_by_info,
        .unmatched = unmatched,
        .unmatched_lines = try unmatched_lines.toOwnedSlice(allocator),
    };
}

fn matchEntry(
    allocator: std.mem.Allocator,
    playlists: *const database.PlaylistRepository,
    by_credit: *?database.RecordingsByCredit,
    base_directory: []const u8,
    entry: m3u.Entry,
) !?Match {
    const resolved_path = switch (try m3u.resolve(allocator, base_directory, entry.location)) {
        .unsupported => return null,
        .path => |resolved| resolved,
    };
    defer allocator.free(resolved_path);
    if (try playlists.resolvePath(resolved_path)) |recording_id| return .{ .recording_id = recording_id, .source = .path };
    const info = entry.info orelse return null;
    const credit = m3u.splitArtistTitle(info.text) orelse return null;
    const recording_id = if (std.math.cast(u32, info.seconds)) |seconds|
        try playlists.resolveInfo(allocator, credit.artist, credit.title, seconds) orelse return null
    else blk: {
        if (by_credit.* == null) by_credit.* = try playlists.recordingsByCredit(allocator);
        break :blk try by_credit.*.?.lookup(allocator, credit.artist, credit.title) orelse return null;
    };
    return .{ .recording_id = recording_id, .source = .info };
}

pub fn libraryExportPlaylist(
    self: *OrcaRuntime,
    library: LibraryHandle,
    io: std.Io,
    playlist_id: i64,
    target_path: []const u8,
    options: PlaylistExportOptions,
) !PlaylistExport {
    const allocator = self.allocator;
    const library_database = try runtime.libraryDatabase(self, library);
    const rows = try library_database.playlists.exportRows(allocator, playlist_id, evaluation(self));
    defer rows.deinit();
    const absolute_path = try absolutePath(allocator, io, target_path);
    defer allocator.free(absolute_path);
    if (!options.replace) try requireAbsent(io, absolute_path);

    var entries: std.ArrayList(m3u.WriteEntry) = try .initCapacity(allocator, rows.items.len);
    defer entries.deinit(allocator);
    var skipped = rows.unavailable;
    for (rows.items) |row| {
        if (!m3u.representable(row.uri)) {
            skipped += 1;
            continue;
        }
        entries.appendAssumeCapacity(.{
            .seconds = if (row.duration_ms) |duration_ms| @divFloor(duration_ms + 500, std.time.ms_per_s) else m3u.unknown_seconds,
            .artist = row.artist,
            .title = row.title,
            .path = row.uri,
        });
    }
    const base_directory = switch (options.paths) {
        .absolute => null,
        .relative => path.dirnamePosix(absolute_path) orelse "/",
    };
    try writeAtomically(allocator, io, absolute_path, entries.items, base_directory, options.replace);
    return .{ .written = @intCast(entries.items.len), .skipped = skipped };
}

fn requireAbsent(io: std.Io, target_path: []const u8) !void {
    std.Io.Dir.cwd().access(io, target_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.PathAlreadyExists;
}

fn writeAtomically(
    allocator: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    entries: []const m3u.WriteEntry,
    base_directory: ?[]const u8,
    replace: bool,
) !void {
    const cwd = std.Io.Dir.cwd();
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.orca-tmp-{s}", .{
        target_path,
        std.fmt.bytesToHex(random_bytes, .lower),
    });
    defer allocator.free(temporary_path);
    {
        const file = try cwd.createFile(io, temporary_path, .{ .exclusive = true });
        errdefer cwd.deleteFile(io, temporary_path) catch {};
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try m3u.write(allocator, &writer.interface, entries, base_directory);
        try writer.interface.flush();
        try file.sync(io);
    }
    errdefer cwd.deleteFile(io, temporary_path) catch {};
    if (replace) {
        try cwd.rename(temporary_path, cwd, target_path, io);
    } else cwd.renamePreserve(temporary_path, cwd, target_path, io) catch |err| switch (err) {
        error.OperationUnsupported => try cwd.rename(temporary_path, cwd, target_path, io),
        else => return err,
    };
    try file_mutation.syncContainingDirectory(io, target_path);
}

fn absolutePath(allocator: std.mem.Allocator, io: std.Io, given: []const u8) ![]u8 {
    if (path.isAbsolutePosix(given)) return path.resolvePosix(allocator, &.{given});
    const current = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(current);
    return path.resolvePosix(allocator, &.{ current, given });
}
