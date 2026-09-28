//! Add Music Folder, rescanning, and the scan status at the foot of the
//! sidebar.
//!
//! A filesystem walk has no honest denominator until it has finished walking,
//! so a spinner and the file counts are shown rather than a fabricated
//! percentage.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const browse = @import("browse.zig");
const albums = @import("albums.zig");

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
    const card = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(card, "scan-status");
    const spinner = adw.adw_spinner_new();
    gtk.gtk_widget_set_size_request(spinner, 16, 16);
    gtk.gtk_widget_set_valign(spinner, gtk.ALIGN_CENTER);
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const label = gtk.gtk_label_new("Scanning…");
    self.scan_label = gtk.cast(gtk.Label, label);
    gtk.gtk_label_set_xalign(self.scan_label.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.scan_label.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, "heading");
    const detail = gtk.gtk_label_new("");
    self.scan_detail = gtk.cast(gtk.Label, detail);
    gtk.gtk_label_set_xalign(self.scan_detail.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.scan_detail.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(detail, "caption");
    gtk.gtk_widget_add_css_class(detail, "dim-label");
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), detail);
    const cancel = gtk.gtk_button_new_from_icon_name("process-stop-symbolic");
    gtk.gtk_widget_set_tooltip_text(cancel, "Stop scanning");
    gtk.gtk_widget_add_css_class(cancel, "flat");
    gtk.gtk_widget_add_css_class(cancel, "circular");
    gtk.gtk_widget_set_valign(cancel, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(cancel, "clicked", gtk.callback(cancelClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), spinner);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), labels);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), cancel);

    const revealer = gtk.gtk_revealer_new();
    self.scan_revealer = gtk.cast(gtk.Revealer, revealer);
    gtk.gtk_revealer_set_transition_type(self.scan_revealer.?, gtk.REVEALER_TRANSITION_SLIDE_UP);
    gtk.gtk_revealer_set_child(self.scan_revealer.?, card);
    return revealer;
}

fn showScanning(self: *App, visible: bool) void {
    if (self.scan_revealer) |revealer|
        gtk.gtk_revealer_set_reveal_child(revealer, if (visible) gtk.true_ else gtk.false_);
}

fn startScan(self: *App, root_id: ?i64) void {
    const library = self.library orelse return;
    const job = self.runtime.startLibraryScan(library, .{ .root_id = root_id }) catch {
        self.toast("Could not start the scan");
        return;
    };
    self.scan_job = job;
    self.scanning = true;
    showScanning(self, true);
    if (self.scan_label) |label| gtk.gtk_label_set_text(label, "Scanning your music");
    if (self.scan_detail) |label| gtk.gtk_label_set_text(label, "Starting…");
    self.updateTracksBody();
}

/// Walks every enabled root again. Unchanged files cost a stat each, so this
/// is how new and changed files are picked up until watching arrives.
pub fn rescan(self: *App) void {
    if (self.library == null) return;
    if (self.scanning) {
        self.toast("A scan is already running");
        return;
    }
    startScan(self, null);
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
        self.toast("That folder is not on the local filesystem");
        return;
    };
    defer gtk.g_free(path_pointer);
    const path = std.mem.span(path_pointer);
    const library = self.library orelse return;
    // Registering a root is the explicit user action the boundary reserves for
    // persisting a volume identity at a mount point.
    const binding = self.runtime.libraryAddRoot(library, self.io, path) catch {
        self.toast("Could not add that folder to the library");
        return;
    };
    startScan(self, binding.root_id);
}

pub fn chooseFolder(self: *App) void {
    if (self.library == null) {
        self.toast("No library is open");
        return;
    }
    if (self.scanning) {
        self.toast("A scan is already running");
        return;
    }
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Add Music Folder");
    gtk.gtk_file_dialog_select_folder(dialog, self.window, null, folderChosen, self);
    gtk.g_object_unref(dialog);
}

fn writeStats(self: *App, stats: liborca.ScanStats) void {
    const label = self.scan_detail orelse return;
    var buffer: [160]u8 = undefined;
    const text = strings.printZ(&buffer, "{d} files · {d} new", .{
        stats.files_seen,
        stats.changed,
    }) catch return;
    gtk.gtk_label_set_text(label, text.ptr);
}

pub fn tick(self: *App) void {
    if (!self.scanning) return;
    const job = self.scan_job orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch {
        self.scanning = false;
        showScanning(self, false);
        return;
    };

    if (self.runtime.jobScanStats(job)) |stats| {
        writeStats(self, stats);
        if (self.loaded_rows == 0 and stats.tracks_written != 0) {
            browse.reload(self);
            self.reload();
            albums.reload(self);
        }
    } else |_| {}

    switch (snapshot.state) {
        .succeeded, .failed, .cancelled => {},
        else => return,
    }

    self.scanning = false;
    showScanning(self, false);
    // A scan projects as it commits, so by the time it finishes the tracks are
    // already browsable: refilling the browser and the page is all that is left
    // to do. The scope resets because the shelves it named have just changed.
    browse.reload(self);
    self.reload();
    albums.reload(self);
    if (snapshot.state == .succeeded) {
        if (self.runtime.jobScanStats(job)) |stats| {
            var buffer: [160]u8 = undefined;
            self.toast(if (stats.changed == 0)
                "Your library is up to date"
            else
                strings.printZ(&buffer, "{d} new or changed files added", .{stats.changed}) catch
                    "Scan complete");
        } else |_| self.toast("Scan complete");
    } else {
        self.toast(if (snapshot.state == .cancelled) "Scan stopped" else "The scan failed");
    }
}
