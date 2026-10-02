//! Orca's look: a forced dark scheme, its own stylesheet over libadwaita, and
//! the fonts and icons installed beside the executable.

const std = @import("std");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");

const stylesheet = @embedFile("style.css");

const font_files = [_][]const u8{ "SourceSerif4Variable-Roman.ttf", "InterVariable.ttf" };

pub fn apply(io: std.Io, display: *gtk.GdkDisplay) void {
    adw.adw_style_manager_set_color_scheme(adw.adw_style_manager_get_default(), adw.COLOR_SCHEME_FORCE_DARK);

    var exe_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &exe_buffer)) |length| {
        const exe_dir = exe_buffer[0..length];
        registerFonts(exe_dir);
        var icons_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&icons_buffer, "{s}/../share/icons", .{exe_dir}, 0)) |icons| {
            gtk.gtk_icon_theme_add_search_path(gtk.gtk_icon_theme_get_for_display(display), icons.ptr);
        } else |_| {}
    } else |err| {
        std.log.warn("Orca's fonts and icons were not loaded: the executable's directory is unknown ({t}); system fonts are used instead", .{err});
    }

    const provider = gtk.gtk_css_provider_new();
    gtk.gtk_css_provider_load_from_string(provider, stylesheet);
    gtk.gtk_style_context_add_provider_for_display(display, provider, gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    gtk.g_object_unref(provider);
}

fn registerFonts(exe_dir: []const u8) void {
    const font_map = gtk.pango_cairo_font_map_get_default();
    var missing: usize = 0;
    for (font_files) |name| {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/../share/orca/fonts/{s}", .{ exe_dir, name }, 0) catch {
            missing += 1;
            continue;
        };
        var err: ?*gtk.GError = null;
        if (gtk.pango_font_map_add_font_file(font_map, path.ptr, &err) == 0) {
            gtk.g_clear_error(&err);
            missing += 1;
        }
    }
    if (missing != 0)
        std.log.warn("{d} of Orca's fonts could not be loaded from {s}/../share/orca/fonts; system fonts are used instead. Reinstall Orca to restore them", .{ missing, exe_dir });
}
