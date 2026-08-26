//! Add Music Folder, and the scan progress bar.
//!
//! A filesystem walk has no honest denominator until it has finished walking,
//! so the bar pulses and the file counts are shown rather than a fabricated
//! percentage.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");

const App = app.App;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn cancelClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (!self.scanning) return;
    const job = self.scan_job orelse return;
    self.runtime.cancelJob(job) catch return;
    if (self.scan_label) |label| gtk.gtk_label_set_text(label, "Cancelling…");
}

pub fn build(self: *App) *gtk.Widget {
    const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_margin_start(bar, 12);
    gtk.gtk_widget_set_margin_end(bar, 12);
    gtk.gtk_widget_set_margin_top(bar, 6);
    gtk.gtk_widget_set_margin_bottom(bar, 6);
    const progress = gtk.gtk_progress_bar_new();
    self.scan_progress = gtk.cast(gtk.ProgressBar, progress);
    gtk.gtk_widget_set_hexpand(progress, gtk.true_);
    gtk.gtk_widget_set_valign(progress, gtk.ALIGN_CENTER);
    const label = gtk.gtk_label_new("");
    self.scan_label = gtk.cast(gtk.Label, label);
    gtk.gtk_label_set_ellipsize(self.scan_label.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_size_request(label, 260, -1);
    gtk.gtk_label_set_xalign(self.scan_label.?, 0.0);
    const cancel = gtk.gtk_button_new_with_label("Cancel");
    _ = gtk.signalConnect(cancel, "clicked", gtk.callback(cancelClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), progress);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), cancel);
    self.scan_bar = bar;
    gtk.gtk_widget_set_visible(bar, gtk.false_);
    return bar;
}

fn startScan(self: *App, root_id: i64, path: []const u8) void {
    const library = self.library orelse return;
    const job = self.runtime.startLibraryScan(library, .{ .root_id = root_id }) catch {
        self.setStatus("Could not start the scan");
        return;
    };
    self.scan_job = job;
    self.scanning = true;
    if (self.scan_bar) |bar| gtk.gtk_widget_set_visible(bar, gtk.true_);
    if (self.scan_progress) |progress| gtk.gtk_progress_bar_set_fraction(progress, 0.0);
    if (self.scan_label) |label| gtk.gtk_label_set_text(label, "Scanning…");
    var buffer: [512]u8 = undefined;
    self.setStatus(strings.printZ(&buffer, "Scanning {s}", .{path}) catch "Scanning");
}

fn folderChosen(
    source: ?*gtk.GObject,
    result: *gtk.GAsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const folder = gtk.gtk_file_dialog_select_folder_finish(
        gtk.cast(gtk.FileDialog, source),
        result,
        &err,
    ) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(folder);
    gtk.g_object_unref(folder);
    const path_pointer = raw_path orelse {
        self.setStatus("That folder is not on the local filesystem");
        return;
    };
    defer gtk.g_free(path_pointer);
    const path = std.mem.span(path_pointer);
    const library = self.library orelse return;
    // Registering a root is the explicit user action the boundary reserves for
    // persisting a volume identity at a mount point.
    const binding = self.runtime.libraryAddRoot(library, self.io, path) catch {
        self.setStatus("Could not add that folder as a library root");
        return;
    };
    startScan(self, binding.root_id, path);
}

pub fn chooseFolder(self: *App) void {
    if (self.library == null) {
        self.setStatus("No library is open");
        return;
    }
    if (self.scanning) {
        self.setStatus("A scan is already running");
        return;
    }
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Add Music Folder");
    gtk.gtk_file_dialog_select_folder(dialog, self.window, null, folderChosen, self);
    gtk.g_object_unref(dialog);
}

fn writeStats(self: *App, stats: liborca.core.runtime.ScanStats) void {
    const label = self.scan_label orelse return;
    var buffer: [160]u8 = undefined;
    const text = strings.printZ(&buffer, "{d} files · {d} new · {d} tracks", .{
        stats.files_seen,
        stats.changed,
        stats.tracks_written,
    }) catch return;
    gtk.gtk_label_set_text(label, text.ptr);
}

pub fn tick(self: *App) void {
    if (!self.scanning) return;
    const job = self.scan_job orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch {
        self.scanning = false;
        if (self.scan_bar) |bar| gtk.gtk_widget_set_visible(bar, gtk.false_);
        return;
    };
    if (self.scan_progress) |progress| {
        // A scan has no total: the walk cannot know its own size until it has
        // finished, so the bar pulses rather than inventing a percentage.
        if (snapshot.total_units) |total| {
            if (total != 0) gtk.gtk_progress_bar_set_fraction(
                progress,
                @as(f64, @floatFromInt(snapshot.completed_units)) / @as(f64, @floatFromInt(total)),
            ) else gtk.gtk_progress_bar_pulse(progress);
        } else gtk.gtk_progress_bar_pulse(progress);
    }

    if (self.runtime.jobScanStats(job)) |stats| writeStats(self, stats) else |_| {}

    switch (snapshot.state) {
        .succeeded, .failed, .cancelled => {},
        else => return,
    }

    self.scanning = false;
    if (self.scan_bar) |bar| gtk.gtk_widget_set_visible(bar, gtk.false_);
    // A scan projects as it commits, so by the time it finishes the tracks are
    // already browsable: reloading the page is all that is left to do.
    self.reload();
    if (snapshot.state == .succeeded) {
        if (self.runtime.jobScanStats(job)) |stats| {
            var buffer: [160]u8 = undefined;
            self.setStatus(strings.printZ(
                &buffer,
                "Scanned {d} files — {d} tracks written",
                .{ stats.files_seen, stats.tracks_written },
            ) catch "Scan complete");
        } else |_| self.setStatus("Scan complete");
    } else {
        self.setStatus(if (snapshot.state == .cancelled) "Scan cancelled" else "Scan failed");
    }
}
