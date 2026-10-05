//! "Open Orca at login": the XDG autostart entry in
//! `$XDG_CONFIG_HOME/autostart/org.orca_music.Orca.desktop`.

const std = @import("std");
const gtk = @import("gtk.zig");

const entry =
    \\[Desktop Entry]
    \\Type=Application
    \\Name=Orca
    \\Comment=Play and organize the music files you own
    \\Exec=orca-gtk
    \\Icon=org.orca_music.Orca
    \\Terminal=false
    \\X-GNOME-Autostart-enabled=true
    \\
;

fn entryPath(buffer: []u8) ?[:0]const u8 {
    const config = std.mem.span(gtk.g_get_user_config_dir());
    const directory = std.fmt.bufPrintSentinel(buffer, "{s}/autostart", .{config}, 0) catch return null;
    if (gtk.g_mkdir_with_parents(directory.ptr, 0o755) != 0) return null;
    return std.fmt.bufPrintSentinel(buffer, "{s}/autostart/org.orca_music.Orca.desktop", .{config}, 0) catch null;
}

pub fn set(enabled: bool) bool {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = entryPath(&buffer) orelse return false;
    if (!enabled) return gtk.g_unlink(file.ptr) == 0 or std.c._errno().* == @backingInt(std.posix.E.NOENT);
    var err: ?*gtk.GError = null;
    if (gtk.g_file_set_contents(file.ptr, entry.ptr, entry.len, &err) != 0) return true;
    gtk.g_clear_error(&err);
    return false;
}
