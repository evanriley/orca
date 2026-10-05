const std = @import("std");
const released = @import("orca_h_released");
const current = @import("orca_h");

const released_header = "tests/abi/orca-0.8.1.h";

fn isOrcaName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "orca_") or std.mem.startsWith(u8, name, "ORCA_");
}

fn isReservedField(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "reserved");
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
            for (released_struct.fields) |field| {
                if (isReservedField(field.name)) continue;
                const field_path = path ++ "." ++ field.name;
                if (!@hasField(Current, field.name)) {
                    problems = problems ++ field_path ++ ": removed\n";
                    continue;
                }
                const released_offset = @offsetOf(Released, field.name);
                const current_offset = @offsetOf(Current, field.name);
                if (released_offset != current_offset) {
                    problems = problems ++ std.fmt.comptimePrint(
                        "{s}: offsetof was {d}, is now {d}\n",
                        .{ field_path, released_offset, current_offset },
                    );
                }
                problems = problems ++ compareTypes(field.type, @FieldType(Current, field.name), field_path);
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
            for (released_union.fields) |field| {
                const field_path = path ++ "." ++ field.name;
                if (!@hasField(Current, field.name)) {
                    problems = problems ++ field_path ++ ": removed\n";
                    continue;
                }
                problems = problems ++ compareTypes(field.type, @FieldType(Current, field.name), field_path);
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
                released_pointer.is_const != current_pointer.is_const)
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
            if (released_fn.params.len != current_fn.params.len) {
                return std.fmt.comptimePrint(
                    "{s}: took {d} parameters, now takes {d}\n",
                    .{ path, released_fn.params.len, current_fn.params.len },
                );
            }
            var problems: []const u8 = "";
            for (released_fn.params, current_fn.params, 0..) |released_param, current_param, index| {
                problems = problems ++ compareTypes(
                    released_param.type.?,
                    current_param.type.?,
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

const incompatibilities = blk: {
    @setEvalBranchQuota(10_000_000);
    var problems: []const u8 = "";
    for (@typeInfo(released).@"struct".decls) |decl| {
        if (!isOrcaName(decl.name)) continue;
        if (!@hasDecl(current, decl.name)) {
            problems = problems ++ decl.name ++ ": removed from orca.h\n";
            continue;
        }
        const released_decl = @field(released, decl.name);
        const current_decl = @field(current, decl.name);
        const Released = @TypeOf(released_decl);
        if (Released == type) {
            problems = problems ++ compareTypes(released_decl, current_decl, decl.name);
        } else if (@typeInfo(Released) == .@"fn") {
            problems = problems ++ compareTypes(Released, @TypeOf(current_decl), decl.name);
        } else {
            problems = problems ++ compareValues(released_decl, current_decl, decl.name);
        }
    }
    break :blk problems;
};

const released_function_names = blk: {
    @setEvalBranchQuota(10_000_000);
    var names: []const []const u8 = &.{};
    for (@typeInfo(released).@"struct".decls) |decl| {
        if (isOrcaName(decl.name) and @typeInfo(@TypeOf(@field(released, decl.name))) == .@"fn") {
            names = names ++ .{decl.name};
        }
    }
    break :blk names;
};

test "released header: every struct, constant and function keeps its layout and value" {
    if (incompatibilities.len != 0) {
        std.debug.print("orca.h is incompatible with {s}:\n{s}", .{ released_header, incompatibilities });
        return error.AbiIncompatible;
    }
}

test "released header: every function it declares is still linked from liborca" {
    var linked: usize = 0;
    inline for (released_function_names) |name| {
        const address: *const volatile anyopaque = @ptrCast(&@field(released, name));
        if (@intFromPtr(address) != 0) linked += 1;
    }
    try std.testing.expectEqual(released_function_names.len, linked);
    try std.testing.expect(linked > 0);
}
