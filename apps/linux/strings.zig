//! Small formatting helpers shared by the frontend.
//!
//! GTK takes NUL-terminated strings everywhere, so every label the app renders
//! is formatted into a caller-owned buffer with a sentinel. Nothing here knows
//! anything about liborca.

const std = @import("std");

/// `std.fmt.bufPrint` with a NUL sentinel: the form every `gtk_*_set_text` call
/// needs.
pub fn printZ(buffer: []u8, comptime format: []const u8, args: anytype) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buffer, format, args, 0);
}

/// Formats milliseconds as `m:ss`, the transport's only time format.
pub fn formatMs(buffer: []u8, milliseconds: u64) [:0]const u8 {
    const total = milliseconds / 1000;
    return printZ(buffer, "{d}:{d:0>2}", .{ total / 60, total % 60 }) catch "";
}
