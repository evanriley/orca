const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

pub const OrcaMetadataInput = struct {
    file_id: i64,
    field: metadata.Field,
    value: []const u8,
    provenance: metadata.Provenance,
    locked: bool = false,
};

pub const FieldValue = struct {
    field: metadata.Field,
    text: []u8,
    provenance: metadata.Provenance,
    locked: bool,
};

pub const FieldValuePage = struct {
    allocator: std.mem.Allocator,
    items: []FieldValue,

    pub fn deinit(self: *FieldValuePage) void {
        for (self.items) |item| self.allocator.free(item.text);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const StoredMetadataValue = struct {
    text: []u8,
    provenance: metadata.Provenance,
    locked: bool,

    pub fn deinit(self: StoredMetadataValue, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const OrcaMetadataRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *OrcaMetadataRepository, input: OrcaMetadataInput) !void {
        if (input.file_id == 0 or input.value.len == 0 or input.provenance == .observed_file)
            return error.InvalidOrcaMetadata;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(file_id, field) DO UPDATE SET
            \\    value=excluded.value,
            \\    provenance=excluded.provenance,
            \\    locked=excluded.locked,
            \\    updated_at=excluded.updated_at,
            \\    written_at=CASE WHEN orca_metadata_values.value=excluded.value
            \\        THEN orca_metadata_values.written_at END
            \\WHERE orca_metadata_values.locked=0 OR excluded.provenance=?6;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindInt64(2, @intFromEnum(input.field));
        try statement.bindText(3, input.value);
        try statement.bindInt64(4, @intFromEnum(input.provenance));
        try statement.bindInt64(5, @intFromBool(input.locked));
        try statement.bindInt64(6, @intFromEnum(metadata.Provenance.user));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Records that a tag write put `value` into the file, unless Orca's
    /// value has changed since the write was planned.
    pub fn markWritten(self: *OrcaMetadataRepository, file_id: i64, field: metadata.Field, value: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE orca_metadata_values SET written_at=unixepoch()
            \\WHERE file_id=?1 AND field=?2 AND value=?3;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(field));
        try statement.bindText(3, value);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Drops Orca's value for one field, so the file's own tag applies again.
    pub fn remove(self: *OrcaMetadataRepository, file_id: i64, field: metadata.Field) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "DELETE FROM orca_metadata_values WHERE file_id=?1 AND field=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(field));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Every field Orca holds a value for on one file, in field order.
    pub fn values(
        self: *const OrcaMetadataRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !FieldValuePage {
        var statement = try self.db.prepare(
            \\SELECT field, value, provenance, locked FROM orca_metadata_values
            \\WHERE file_id=?1 ORDER BY field;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        var items: std.ArrayList(FieldValue) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.text);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const field = std.enums.fromInt(metadata.Field, statement.columnInt64(0)) orelse continue;
            const provenance = std.enums.fromInt(metadata.Provenance, statement.columnInt64(2)) orelse
                return error.InvalidStoredProvenance;
            const text = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(text);
            try items.append(allocator, .{
                .field = field,
                .text = text,
                .provenance = provenance,
                .locked = statement.columnInt64(3) != 0,
            });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    pub fn get(
        self: *const OrcaMetadataRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        field: metadata.Field,
    ) !?StoredMetadataValue {
        var statement = try self.db.prepare(
            \\SELECT value, provenance, locked FROM orca_metadata_values
            \\WHERE file_id=?1 AND field=?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(field));
        if (try statement.step() != .row) return null;
        const provenance = std.enums.fromInt(
            metadata.Provenance,
            statement.columnInt64(1),
        ) orelse return error.InvalidStoredProvenance;
        return .{
            .text = try allocator.dupe(u8, statement.columnText(0)),
            .provenance = provenance,
            .locked = statement.columnInt64(2) != 0,
        };
    }
};
