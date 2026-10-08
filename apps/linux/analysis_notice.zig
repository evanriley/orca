//! The banner that asks the user to analyze again when Orca has started
//! measuring something the Library's analyzed files lack. liborca reports the
//! coverage; this file shows it and remembers which measurement set the user
//! dismissed.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const radio = @import("radio.zig");
const settings = @import("settings.zig");
const analysis_title = @import("analysis_title.zig");

const App = app.App;

pub const State = struct {
    coverage: ?liborca.AnalysisCoverage = null,
    dismissed: ?u64 = null,
    pending: c_uint = 0,
    holder: ?*gtk.Widget = null,
    banner: ?*adw.Banner = null,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

/// Reads the coverage again once the main loop is idle, so opening a Library
/// draws first.
pub fn refresh(self: *App) void {
    if (self.analysis_notice.pending == 0) self.analysis_notice.pending = gtk.g_idle_add(read, self);
}

fn read(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const notice = &self.analysis_notice;
    notice.pending = 0;
    const library = self.library orelse return gtk.SOURCE_REMOVE;
    const coverage = self.runtime.libraryAnalysisCoverage(library) catch |err| {
        std.log.warn("Could not read which files need analysis ({t})", .{err});
        return gtk.SOURCE_REMOVE;
    };
    const lacked = lacksFeatures(self);
    notice.coverage = coverage;
    show(self);
    if (lacksFeatures(self) != lacked) radio.invalidate(self);
    return gtk.SOURCE_REMOVE;
}

pub fn shutdown(self: *App) void {
    if (self.analysis_notice.pending != 0) _ = gtk.g_source_remove(self.analysis_notice.pending);
    self.analysis_notice.pending = 0;
}

pub fn forgetLibrary(self: *App) void {
    shutdown(self);
    self.analysis_notice.coverage = null;
    show(self);
}

/// Whether the Library has files without tempo, key and energy, or null
/// before the first read.
pub fn lacksFeatures(self: *const App) ?bool {
    const coverage = self.analysis_notice.coverage orelse return null;
    return coverage.never_analyzed != 0 or coverage.missing.features;
}

fn wanted(self: *const App) ?liborca.AnalysisCoverage {
    const notice = &self.analysis_notice;
    const coverage = notice.coverage orelse return null;
    if (coverage.outdated == 0) return null;
    if (notice.dismissed == coverage.measurement_set) return null;
    if (jobs.active(self, .analysis)) return null;
    return switch (self.current_page) {
        .now_playing, .scan => null,
        else => coverage,
    };
}

/// The banner is hidden on pages drawn edge to edge, like the offline one.
pub fn show(self: *App) void {
    const holder = self.analysis_notice.holder orelse return;
    const coverage = wanted(self) orelse return gtk.gtk_widget_set_visible(holder, gtk.false_);
    var buffer: [256]u8 = undefined;
    adw.adw_banner_set_title(self.analysis_notice.banner.?, analysis_title.text(&buffer, coverage.missing).ptr);
    gtk.gtk_widget_set_visible(holder, gtk.true_);
}

pub fn build(self: *App) *gtk.Widget {
    const notice = &self.analysis_notice;
    const banner = adw.adw_banner_new("");
    notice.banner = gtk.cast(adw.Banner, banner);
    gtk.gtk_widget_add_css_class(banner, "analysis-banner");
    adw.adw_banner_set_button_label(notice.banner.?, "Analyze");
    adw.adw_banner_set_revealed(notice.banner.?, gtk.true_);
    _ = gtk.signalConnect(banner, "button-clicked", gtk.callback(analyzeClicked), self);

    const close = gtk.gtk_button_new_from_icon_name("orca-close-symbolic");
    gtk.gtk_widget_add_css_class(close, "flat");
    gtk.gtk_widget_add_css_class(close, "analysis-banner-close");
    gtk.gtk_widget_set_halign(close, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(close, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(close, "Dismiss");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, close), gtk.ACCESSIBLE_PROPERTY_LABEL, "Dismiss", @as(c_int, -1));
    _ = gtk.signalConnect(close, "clicked", gtk.callback(dismissClicked), self);

    const holder = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, holder), banner);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, holder), close);
    gtk.gtk_widget_set_visible(holder, gtk.false_);
    notice.holder = holder;
    return holder;
}

fn analyzeClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startAnalysis(state(data));
}

fn dismissClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const coverage = self.analysis_notice.coverage orelse return;
    self.analysis_notice.dismissed = coverage.measurement_set;
    settings.save(self);
    show(self);
}
