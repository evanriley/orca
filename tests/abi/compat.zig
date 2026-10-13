const std = @import("std");
const current = @import("orca_h");

const baselines = .{
    .{ "0.1.0", @import("orca_h_0_1_0") },
    .{ "0.2.0", @import("orca_h_0_2_0") },
    .{ "0.3.0", @import("orca_h_0_3_0") },
    .{ "0.4.0", @import("orca_h_0_4_0") },
};

const renamed_reserved_fields = [_][]const u8{
    "orca_track_view.reserved",
    "orca_track_summary_view.track.reserved",
    "orca_playlist_entry_view.track.reserved",
    "orca_release_field_diff_view.reserved",
    "orca_radio_options.reserved",
    "orca_radio_status_view.options.reserved",
};

fn isOrcaName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "orca_") or std.mem.startsWith(u8, name, "ORCA_");
}

fn isReservedField(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "reserved");
}

fn isListedRename(comptime field_path: []const u8) bool {
    for (renamed_reserved_fields) |listed| {
        if (std.mem.eql(u8, listed, field_path)) return true;
    }
    return false;
}

fn isNamedAggregate(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"opaque" => T != anyopaque,
        else => false,
    };
}

fn unqualifiedName(comptime T: type) []const u8 {
    const name = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

fn compareTypes(comptime Released: type, comptime Current: type, comptime path: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    if (Released == Current) return "";
    const released_info = @typeInfo(Released);
    const current_info = @typeInfo(Current);
    if (std.meta.activeTag(released_info) != std.meta.activeTag(current_info)) {
        return std.fmt.comptimePrint("{s}: was {s}, is now {s}\n", .{ path, @typeName(Released), @typeName(Current) });
    }
    switch (released_info) {
        .@"struct" => |released_struct| {
            var problems: []const u8 = "";
            if (@sizeOf(Released) != @sizeOf(Current)) {
                problems = problems ++ std.fmt.comptimePrint(
                    "{s}: sizeof was {d}, is now {d}\n",
                    .{ path, @sizeOf(Released), @sizeOf(Current) },
                );
            }
            if (@alignOf(Released) != @alignOf(Current)) {
                problems = problems ++ std.fmt.comptimePrint(
                    "{s}: alignof was {d}, is now {d}\n",
                    .{ path, @alignOf(Released), @alignOf(Current) },
                );
            }
            for (released_struct.field_names, released_struct.field_types) |field_name, FieldType| {
                const field_path = path ++ "." ++ field_name;
                if (isReservedField(field_name)) {
                    if (!@hasField(Current, field_name) and !isListedRename(field_path)) {
                        problems = problems ++ field_path ++ ": reserved field renamed or removed; list it in renamed_reserved_fields once it gains a meaning for which zero keeps the old behaviour\n";
                    }
                    continue;
                }
                if (!@hasField(Current, field_name)) {
                    problems = problems ++ field_path ++ ": removed\n";
                    continue;
                }
                const released_offset = @offsetOf(Released, field_name);
                const current_offset = @offsetOf(Current, field_name);
                if (released_offset != current_offset) {
                    problems = problems ++ std.fmt.comptimePrint(
                        "{s}: offsetof was {d}, is now {d}\n",
                        .{ field_path, released_offset, current_offset },
                    );
                }
                problems = problems ++ compareTypes(FieldType, @FieldType(Current, field_name), field_path);
            }
            return problems;
        },
        .int => if (@sizeOf(Released) != @sizeOf(Current) or
            released_info.int.signedness != current_info.int.signedness)
        {
            return std.fmt.comptimePrint("{s}: was {s}, is now {s}\n", .{ path, @typeName(Released), @typeName(Current) });
        },
        .float => if (@sizeOf(Released) != @sizeOf(Current)) {
            return std.fmt.comptimePrint("{s}: was {s}, is now {s}\n", .{ path, @typeName(Released), @typeName(Current) });
        },
        .@"union" => |released_union| {
            var problems: []const u8 = "";
            if (@sizeOf(Released) != @sizeOf(Current)) {
                problems = problems ++ std.fmt.comptimePrint(
                    "{s}: sizeof was {d}, is now {d}\n",
                    .{ path, @sizeOf(Released), @sizeOf(Current) },
                );
            }
            if (@alignOf(Released) != @alignOf(Current)) {
                problems = problems ++ std.fmt.comptimePrint(
                    "{s}: alignof was {d}, is now {d}\n",
                    .{ path, @alignOf(Released), @alignOf(Current) },
                );
            }
            for (released_union.field_names, released_union.field_types) |field_name, FieldType| {
                const field_path = path ++ "." ++ field_name;
                if (!@hasField(Current, field_name)) {
                    problems = problems ++ field_path ++ ": removed\n";
                    continue;
                }
                problems = problems ++ compareTypes(FieldType, @FieldType(Current, field_name), field_path);
            }
            return problems;
        },
        .array => |released_array| {
            if (released_array.len != current_info.array.len) {
                return std.fmt.comptimePrint(
                    "{s}: array length was {d}, is now {d}\n",
                    .{ path, released_array.len, current_info.array.len },
                );
            }
            return compareTypes(released_array.child, current_info.array.child, path ++ "[]");
        },
        .pointer => |released_pointer| {
            const current_pointer = current_info.pointer;
            if (released_pointer.size != current_pointer.size or
                released_pointer.attrs.@"const" != current_pointer.attrs.@"const")
            {
                return std.fmt.comptimePrint("{s}: was {s}, is now {s}\n", .{ path, @typeName(Released), @typeName(Current) });
            }
            if (released_pointer.child == anyopaque and current_pointer.child == anyopaque) return "";
            if (isNamedAggregate(released_pointer.child) and isNamedAggregate(current_pointer.child)) {
                const released_name = unqualifiedName(released_pointer.child);
                const current_name = unqualifiedName(current_pointer.child);
                if (std.mem.eql(u8, released_name, current_name)) return "";
                return std.fmt.comptimePrint("{s}: pointed to {s}, now points to {s}\n", .{ path, released_name, current_name });
            }
            return compareTypes(released_pointer.child, current_pointer.child, path ++ ".*");
        },
        .optional => |released_optional| return compareTypes(released_optional.child, current_info.optional.child, path),
        .@"fn" => |released_fn| {
            const current_fn = current_info.@"fn";
            if (released_fn.param_types.len != current_fn.param_types.len) {
                return std.fmt.comptimePrint(
                    "{s}: took {d} parameters, now takes {d}\n",
                    .{ path, released_fn.param_types.len, current_fn.param_types.len },
                );
            }
            var problems: []const u8 = "";
            for (released_fn.param_types, current_fn.param_types, 0..) |released_param, current_param, index| {
                problems = problems ++ compareTypes(
                    released_param.?,
                    current_param.?,
                    std.fmt.comptimePrint("{s}(parameter {d})", .{ path, index }),
                );
            }
            return problems ++ compareTypes(released_fn.return_type.?, current_fn.return_type.?, path ++ "(return)");
        },
        .@"opaque", .void, .bool => return "",
        else => return std.fmt.comptimePrint("{s}: unchecked type {s}\n", .{ path, @typeName(Released) }),
    }
    return "";
}

fn compareValues(comptime released_value: anytype, comptime current_value: anytype, comptime name: []const u8) []const u8 {
    const Released = @TypeOf(released_value);
    if (@typeInfo(Released) == .pointer) {
        if (std.mem.eql(u8, released_value, current_value)) return "";
        return std.fmt.comptimePrint("{s}: was \"{s}\", is now \"{s}\"\n", .{ name, released_value, current_value });
    }
    if (released_value == current_value) return "";
    return std.fmt.comptimePrint("{s}: was {d}, is now {d}\n", .{ name, released_value, current_value });
}

fn incompatibilities(comptime released: type) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var problems: []const u8 = "";
        for (@typeInfo(released).@"struct".decl_names) |decl_name| {
            if (!isOrcaName(decl_name)) continue;
            if (!@hasDecl(current, decl_name)) {
                problems = problems ++ decl_name ++ ": removed from orca.h\n";
                continue;
            }
            const released_decl = @field(released, decl_name);
            const current_decl = @field(current, decl_name);
            const Released = @TypeOf(released_decl);
            if (Released == type) {
                problems = problems ++ compareTypes(released_decl, current_decl, decl_name);
            } else if (@typeInfo(Released) == .@"fn") {
                problems = problems ++ compareTypes(Released, @TypeOf(current_decl), decl_name);
            } else {
                problems = problems ++ compareValues(released_decl, current_decl, decl_name);
            }
        }
        break :blk problems;
    };
}

fn releasedFunctionNames(comptime released: type) []const []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var names: []const []const u8 = &.{};
        for (@typeInfo(released).@"struct".decl_names) |decl_name| {
            if (isOrcaName(decl_name) and @typeInfo(@TypeOf(@field(released, decl_name))) == .@"fn") {
                names = names ++ .{decl_name};
            }
        }
        break :blk names;
    };
}

test "released headers: every struct, constant and function keeps its layout and value" {
    var incompatible = false;
    inline for (baselines) |baseline| {
        const problems = comptime incompatibilities(baseline[1]);
        if (problems.len != 0) {
            std.debug.print("orca.h is incompatible with tests/abi/orca-{s}.h:\n{s}", .{ baseline[0], problems });
            incompatible = true;
        }
    }
    if (incompatible) return error.AbiIncompatible;
}

test "released headers: every function they declare is still linked from liborca" {
    inline for (baselines) |baseline| {
        const names = comptime releasedFunctionNames(baseline[1]);
        var linked: usize = 0;
        inline for (names) |name| {
            const address: *const volatile anyopaque = @ptrCast(&@field(baseline[1], name));
            if (@intFromPtr(address) != 0) linked += 1;
        }
        try std.testing.expectEqual(names.len, linked);
        try std.testing.expect(linked > 0);
    }
}
