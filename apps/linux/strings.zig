//! Small formatting helpers shared by the frontend.
//!
//! GTK takes NUL-terminated strings everywhere, so every label the app renders
//! is formatted into a caller-owned buffer with a sentinel. Nothing here knows
//! anything about liborca.

const std = @import("std");

/// `std.fmt.bufPrint` with a NUL sentinel: the form every `gtk_*_set_text` call
/// needs.
pub fn printZ(buffer: []u8, comptime pattern: []const u8, args: anytype) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buffer, pattern, args, 0);
}

/// Formats milliseconds as `m:ss`, the transport's only time format.
pub fn formatMs(buffer: []u8, milliseconds: u64) [:0]const u8 {
    const total = milliseconds / 1000;
    return printZ(buffer, "{d}:{d:0>2}", .{ total / 60, total % 60 }) catch "";
}

/// `text` NUL-terminated in `buffer`, or empty if it does not fit.
pub fn terminated(buffer: []u8, text: []const u8) [:0]const u8 {
    return printZ(buffer, "{s}", .{text}) catch "";
}

/// `printZ`, or empty if the result does not fit.
pub fn format(buffer: []u8, comptime pattern: []const u8, args: anytype) [:0]const u8 {
    return printZ(buffer, pattern, args) catch "";
}

/// `-0.0` formats as `-0`, which is never what a gain label or a settings file
/// should say.
pub fn withoutNegativeZero(value: f32) f32 {
    return if (value == 0) 0 else value;
}
