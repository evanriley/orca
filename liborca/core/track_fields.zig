//! What a selection of Tracks holds in each editable field, for an editor of
//! all of them at once: the value they share, whether they disagree, and
//! whether Orca's value differs from what their files state.
//!
//! Read from the database alone, like `track_details`: no file is opened, so
//! a file that changed since the last scan is described as the scan left it.

const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const track_details = @import("track_details.zig");
const runtime_roots = @import("runtime_roots.zig");

pub const EditableField = enum {
    title,
    artist,
    album,
    album_artist,
    genre,
    date,
    track_number,
    disc_number,
    composer,
    comment,

    fn metadataField(self: EditableField) ?metadata.Field {
        return switch (self) {
            .title => .title,
            .artist => .artist,
            .album => .album,
            .album_artist => .album_artist,
            .genre => null,
            .date => .date,
            .track_number => .track_number,
            .disc_number => .disc_number,
            .composer => .composer,
            .comment => .comment,
        };
    }
};

pub const FieldState = struct {
    /// The value every Track has, or null when they disagree or none has one.
    /// Genres are joined with "; ".
    value: ?[]const u8 = null,
    /// Whether the Tracks hold different values; one with none counts as
    /// different from one with a value.
    mixed: bool = false,
    /// Whether Orca's value differs from what a Track's file states, for at
    /// least one Track: an edit or an accepted match not yet written. For
    /// genres, the user's genres differing from the file's.
    edited: bool = false,
};

pub const CoverSource = enum {
    none,
    /// The image embedded in a Track's file.
    embedded,
    /// A front cover image in the Release's folder.
    folder,
    /// The cover fetched for the Release from the Cover Art Archive.
    fetched,
};

/// The cover the first selected Track shows, in the order artwork resolves
/// it: embedded, then folder, then fetched.
pub const Cover = struct {
    source: CoverSource = .none,
    /// The folder image's file name, for a `folder` cover.
    file_name: ?[]const u8 = null,
    /// The embedded image's MIME type, for an `embedded` cover.
    mime_type: ?[]const u8 = null,
    /// How many selected Tracks show the same cover: the same folder image,
    /// the same Release's fetched cover, or an embedded image of
    /// the same type and byte size.
    tracks: u32 = 0,
};

/// Caller-owned: release with `deinit`.
pub const TrackFieldStates = struct {
    arena: *std.heap.ArenaAllocator,
    track_count: u32,
    fields: std.EnumArray(EditableField, FieldState),
    /// The disc total every Track shares, or null.
    disc_total: ?i64,
    cover: Cover,

    pub fn deinit(self: TrackFieldStates) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

const TrackCover = struct {
    source: CoverSource = .none,
    identity: []const u8 = "",
    size: u64 = 0,
    release_id: ?i64 = null,
};

pub fn load(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    track_ids: []const i64,
) !TrackFieldStates {
    if (track_ids.len == 0 or track_ids.len > database.repository.max_page) return error.InvalidTrackSelection;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    var result: TrackFieldStates = .{
        .arena = arena,
        .track_count = @intCast(track_ids.len),
        .fields = .initFill(.{}),
        .disc_total = null,
        .cover = .{},
    };
    errdefer result.deinit();
    const owned = arena.allocator();

    var scratch_arena: std.heap.ArenaAllocator = .init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var first_cover: TrackCover = .{};
    var disc_total_mixed = false;
    for (track_ids, 0..) |track_id, index| {
        _ = scratch_arena.reset(.retain_capacity);
        const details = (try track_details.load(scratch, library, track_id)) orelse return error.TrackNotFound;
        const genres = try library.genres.forTrack(scratch, track_id);
        var values: std.EnumArray(EditableField, ?[]const u8) = .initFill(null);
        values.set(.title, nonEmpty(details.title));
        values.set(.artist, nonEmpty(details.artist));
        values.set(.album, nonEmpty(details.album));
        values.set(.album_artist, nonEmpty(details.album_artist));
        values.set(.date, details.date);
        values.set(.composer, details.composer);
        values.set(.comment, details.comment);
        if (details.track_number) |number| values.set(.track_number, try std.fmt.allocPrint(scratch, "{d}", .{number}));
        if (details.disc_number) |number| values.set(.disc_number, try std.fmt.allocPrint(scratch, "{d}", .{number}));
        if (genres.items.len != 0) {
            const names = try scratch.alloc([]const u8, genres.items.len);
            for (names, genres.items) |*name, genre| name.* = genre.name;
            values.set(.genre, try std.mem.join(scratch, "; ", names));
        }

        const file_ids = try library.tracks.fileIds(scratch, track_id);
        var edited: std.EnumArray(EditableField, bool) = .initFill(false);
        var embedded: ?metadata.Artwork = null;
        for (file_ids) |file_id| {
            const stored = try library.observed_tags.get(scratch, file_id);
            const tags: metadata.ObservedTags = if (stored) |observed| observed.values else .{};
            if (embedded == null) embedded = tags.artwork;
            const orca = try library.orca_metadata.values(scratch, file_id);
            for (orca.items) |value| {
                const field = editableOf(value.field) orelse continue;
                const before = try runtime_roots.observedText(scratch, tags, value.field);
                if (before == null or !std.mem.eql(u8, before.?, value.text)) edited.set(field, true);
            }
            if (genres.items.len != 0 and genres.items[0].provenance == .user) {
                const names = try scratch.alloc([]const u8, genres.items.len);
                for (names, genres.items) |*name, genre| name.* = genre.name;
                if (!try runtime_roots.sameGenres(scratch, tags.genres, names)) edited.set(.genre, true);
            }
        }

        for (std.enums.values(EditableField)) |field| {
            const state = result.fields.getPtr(field);
            if (edited.get(field)) state.edited = true;
            const value = values.get(field);
            if (index == 0) {
                state.value = if (value) |text| try owned.dupe(u8, text) else null;
            } else if (!state.mixed and !optionalEql(state.value, value)) {
                state.mixed = true;
                state.value = null;
            }
        }
        if (index == 0) {
            result.disc_total = details.disc_total;
        } else if (!disc_total_mixed and result.disc_total != details.disc_total) {
            disc_total_mixed = true;
            result.disc_total = null;
        }

        const summary = (try library.tracks.byId(scratch, track_id)) orelse return error.TrackNotFound;
        const cover = try trackCover(scratch, library, track_id, summary.release_id, embedded);
        if (index == 0) {
            first_cover = .{
                .source = cover.source,
                .identity = try owned.dupe(u8, cover.identity),
                .size = cover.size,
                .release_id = cover.release_id,
            };
            result.cover = .{
                .source = cover.source,
                .file_name = if (cover.source == .folder) std.Io.Dir.path.basename(first_cover.identity) else null,
                .mime_type = if (cover.source == .embedded) first_cover.identity else null,
            };
        }
        if (cover.source != .none and sameCover(first_cover, cover)) result.cover.tracks += 1;
    }
    return result;
}

fn trackCover(
    scratch: std.mem.Allocator,
    library: *database.LibraryDatabase,
    track_id: i64,
    release_id: ?i64,
    embedded: ?metadata.Artwork,
) !TrackCover {
    if (embedded) |artwork| return .{ .source = .embedded, .identity = artwork.mime_type, .size = artwork.byte_size };
    const images = try library.locations.trackReleaseFrontImages(scratch, track_id, 1);
    if (images.len != 0) return .{ .source = .folder, .identity = images[0] };
    const release = release_id orelse return .{};
    const fetched = try library.release_artwork.get(release) orelse return .{};
    if (!fetched.has_image) return .{};
    return .{ .source = .fetched, .release_id = release };
}

fn sameCover(first: TrackCover, other: TrackCover) bool {
    if (first.source != other.source) return false;
    return switch (first.source) {
        .none => false,
        .embedded => first.size == other.size and std.mem.eql(u8, first.identity, other.identity),
        .folder => std.mem.eql(u8, first.identity, other.identity),
        .fetched => first.release_id == other.release_id,
    };
}

fn editableOf(field: metadata.Field) ?EditableField {
    for (std.enums.values(EditableField)) |editable| {
        if (editable.metadataField() == field) return editable;
    }
    return null;
}

fn nonEmpty(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}
