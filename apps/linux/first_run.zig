const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const jobs = @import("jobs.zig");
const settings = @import("settings.zig");
const watching = @import("watching.zig");
const preferences = @import("preferences.zig");
const window = @import("window.zig");

const App = app.App;

const found_slots = 14;
const found_columns = 7;
const tile_pixels: c_int = 132;
const problem_rows = 5;
const refresh_interval_us: i64 = 1_000_000;
const user_directory_music: c_int = 3;

const Step = enum { folders, identify, listen };

const Flow = enum { idle, scanning, analyzing, done };

const Estimate = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    token: liborca.CancellationToken = .{},
    path: []u8,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    truncated: std.atomic.Value(bool) = .init(false),
    audio_files: std.atomic.Value(u64) = .init(0),

    fn run(self: *Estimate) void {
        const result = liborca.estimateAudioFiles(
            self.threaded.io(),
            std.heap.smp_allocator,
            self.path,
            &self.token,
            liborca.estimate_default_limit,
        );
        if (result) |estimate| {
            self.audio_files.store(estimate.audio_files, .release);
            self.truncated.store(estimate.truncated, .release);
        } else |_| self.failed.store(true, .release);
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn destroy(self: *Estimate, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        self.threaded.deinit();
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

const Folder = struct {
    path: [:0]u8,
    row: *gtk.Widget,
    remove: *gtk.Widget,
    detail: *gtk.Label,
    estimate: ?*Estimate,
    shown: bool = false,
};

const Stage = struct {
    mark: *gtk.Widget,
    title: *gtk.Label,
    detail: *gtk.Label,
};

const Slot = struct {
    button: *gtk.Widget,
    cover: *gtk.Widget,
    title: *gtk.Label,
    artist: *gtk.Label,
    release_id: ?i64 = null,
};

pub const State = struct {
    shell: ?*gtk.Stack = null,
    steps: ?*gtk.Stack = null,
    folder_list: ?*gtk.Box = null,
    add_label: ?*gtk.Label = null,
    scan_button: ?*gtk.Widget = null,
    watch_switch: ?*gtk.Switch = null,
    folders: std.ArrayList(Folder) = .empty,
    retiring: std.ArrayList(*Estimate) = .empty,

    flow: Flow = .idle,
    hidden: bool = false,
    analyze: bool = true,
    scan_job: ?liborca.JobHandle = null,
    analysis_job: ?liborca.JobHandle = null,
    refreshed_us: i64 = 0,
    shown_albums: u64 = std.math.maxInt(u64),

    progress_title: ?*gtk.Label = null,
    progress_eta: ?*gtk.Label = null,
    progress_bar: ?*gtk.ProgressBar = null,
    current_path: ?*gtk.Label = null,
    pause_button: ?*gtk.Button = null,
    stages: [4]Stage = undefined,
    problems: ?*gtk.Widget = null,
    problems_title: ?*gtk.Label = null,
    problems_list: ?*gtk.Box = null,
    found_count: ?*gtk.Label = null,
    slots: [found_slots]Slot = undefined,

    analyze_switch: ?*gtk.Switch = null,
    analysis_text: ?*gtk.Label = null,
    analysis_bar: ?*gtk.ProgressBar = null,
    skip_button: ?*gtk.Button = null,
    listen_numbers: [3]?*gtk.Label = @splat(null),
    listen_note: ?*gtk.Label = null,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0.0);
    return widget;
}

fn icon(name: [*:0]const u8, pixels: c_int, class: ?[*:0]const u8) *gtk.Widget {
    const image = gtk.gtk_image_new_from_icon_name(name);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), pixels);
    if (class) |name_class| gtk.gtk_widget_add_css_class(image, name_class);
    return image;
}

fn box(orientation: c_int, spacing: c_int, class: ?[*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_box_new(orientation, spacing);
    if (class) |name| gtk.gtk_widget_add_css_class(widget, name);
    return widget;
}

fn append(parent: *gtk.Widget, children: []const *gtk.Widget) void {
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, parent), child);
}

fn button(text: [*:0]const u8, class: [*:0]const u8, handler: anytype, self: *App) *gtk.Widget {
    const widget = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(widget, "clicked", gtk.callback(handler), self);
    return widget;
}

fn toggle(active: bool, accessible: [*:0]const u8, handler: anytype, self: *App) *gtk.Widget {
    const widget = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(gtk.cast(gtk.Switch, widget), boolean(active));
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(widget, "first-run-switch");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, widget), gtk.ACCESSIBLE_PROPERTY_LABEL, accessible, @as(c_int, -1));
    _ = gtk.signalConnect(widget, "notify::active", gtk.callback(handler), self);
    return widget;
}

fn switchRow(title: [*:0]const u8, detail: [*:0]const u8, control: *gtk.Widget) *gtk.Widget {
    const text = box(gtk.ORIENTATION_VERTICAL, 3, null);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    append(text, &.{ label(title, "first-run-option"), label(detail, "first-run-hint") });
    const row = box(gtk.ORIENTATION_HORIZONTAL, 16, "first-run-option-row");
    append(row, &.{ text, control });
    return row;
}

fn progressBar(class: [*:0]const u8) *gtk.ProgressBar {
    const bar = gtk.gtk_progress_bar_new();
    gtk.gtk_widget_add_css_class(bar, class);
    return gtk.cast(gtk.ProgressBar, bar);
}

fn grouped(buffer: []u8, value: u64) [:0]const u8 {
    return strings.format(buffer, "{f}", .{strings.grouped(value)});
}

fn rounded(value: u64) u64 {
    if (value >= 1000) return value / 100 * 100;
    if (value >= 100) return value / 10 * 10;
    return value;
}

fn plural(count: u64, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

pub fn wrap(self: *App, main: *gtk.Widget) *gtk.Widget {
    const shell = gtk.gtk_stack_new();
    self.first_run.shell = gtk.cast(gtk.Stack, shell);
    gtk.gtk_stack_set_transition_type(self.first_run.shell.?, gtk.STACK_TRANSITION_CROSSFADE);
    _ = gtk.gtk_stack_add_named(self.first_run.shell.?, main, "main");
    _ = gtk.gtk_stack_add_named(self.first_run.shell.?, buildFirstRun(self), "first-run");
    gtk.gtk_stack_set_visible_child_name(self.first_run.shell.?, "main");
    return shell;
}

fn showShell(self: *App, name: [*:0]const u8) void {
    const shell = self.first_run.shell orelse return;
    gtk.gtk_stack_set_visible_child_name(shell, name);
}

fn showStep(self: *App, step: Step) void {
    const steps = self.first_run.steps orelse return;
    gtk.gtk_stack_set_visible_child_name(steps, @tagName(step));
    showShell(self, "first-run");
}

pub fn startIfEmpty(self: *App) void {
    const library = self.library orelse return;
    const roots = self.runtime.libraryRootPage(library, 1, 0) catch return;
    defer roots.deinit();
    if (roots.items.len != 0) return;
    if (self.first_run.folders.items.len == 0) suggestMusicFolder(self);
    if (self.first_run.watch_switch) |control| gtk.gtk_switch_set_active(control, boolean(self.watch_folders));
    showStep(self, .folders);
}

fn suggestMusicFolder(self: *App) void {
    const music = gtk.g_get_user_special_dir(user_directory_music) orelse return;
    const path = std.mem.span(music);
    const home = if (gtk.g_get_home_dir()) |value| std.mem.span(value) else "";
    if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), std.mem.trimEnd(u8, home, "/"))) return;
    var directory = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch return;
    directory.close(self.io);
    addFolder(self, path);
}

fn stepIndicator(current: Step) *gtk.Widget {
    const names = [_][*:0]const u8{ "1 · Folders", "2 · Scan", "3 · Identify (optional)", "4 · Listen" };
    const reached: usize = switch (current) {
        .folders => 0,
        .identify => 2,
        .listen => 3,
    };
    const row = box(gtk.ORIENTATION_HORIZONTAL, 8, "first-run-steps");
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, row), gtk.true_);
    for (names, 0..) |name, index| {
        const step = box(gtk.ORIENTATION_VERTICAL, 8, "first-run-step");
        const bar = box(gtk.ORIENTATION_HORIZONTAL, 0, "first-run-step-bar");
        const text = label(name, "first-run-step-label");
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, text), gtk.ELLIPSIZE_END);
        if (index <= reached) gtk.gtk_widget_add_css_class(step, "reached");
        if (index == reached) gtk.gtk_widget_add_css_class(step, "current");
        append(step, &.{ bar, text });
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), step);
    }
    return row;
}

fn heading(title: [*:0]const u8, subtitle: *gtk.Widget) *gtk.Widget {
    const block = box(gtk.ORIENTATION_VERTICAL, 18, null);
    const name = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(name, "first-run-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, name), gtk.true_);
    gtk.gtk_label_set_justify(gtk.cast(gtk.Label, name), gtk.JUSTIFY_CENTER);
    gtk.gtk_widget_add_css_class(subtitle, "first-run-subtitle");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, subtitle), gtk.true_);
    gtk.gtk_label_set_justify(gtk.cast(gtk.Label, subtitle), gtk.JUSTIFY_CENTER);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, subtitle), 0.5);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, subtitle), 46);
    gtk.gtk_widget_set_halign(subtitle, gtk.ALIGN_CENTER);
    append(block, &.{ name, subtitle });
    return block;
}

fn footer(note: *gtk.Widget, action: *gtk.Widget) *gtk.Widget {
    const row = box(gtk.ORIENTATION_HORIZONTAL, 16, "first-run-footer");
    gtk.gtk_widget_set_hexpand(note, gtk.true_);
    append(row, &.{ note, action });
    return row;
}

fn noteLabel(text: [*:0]const u8) struct { widget: *gtk.Widget, text: *gtk.Label } {
    const row = box(gtk.ORIENTATION_HORIZONTAL, 8, "first-run-note");
    const words = label(text, "first-run-note-text");
    append(row, &.{ icon("orca-check-symbolic", 15, "first-run-note-icon"), words });
    return .{ .widget = row, .text = gtk.cast(gtk.Label, words) };
}

fn stepPage(current: Step, top: *gtk.Widget, card: *gtk.Widget, bottom: *gtk.Widget) *gtk.Widget {
    const column = box(gtk.ORIENTATION_VERTICAL, 32, "first-run-column");
    append(column, &.{ top, stepIndicator(current), card, bottom });
    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 600);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), 600);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), column);
    gtk.gtk_widget_set_valign(clamp, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_vexpand(clamp, gtk.true_);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), clamp);
    return scroller;
}

fn buildFirstRun(self: *App) *gtk.Widget {
    const steps = gtk.gtk_stack_new();
    self.first_run.steps = gtk.cast(gtk.Stack, steps);
    gtk.gtk_stack_set_transition_type(self.first_run.steps.?, gtk.STACK_TRANSITION_CROSSFADE);
    gtk.gtk_widget_add_css_class(steps, "first-run");
    _ = gtk.gtk_stack_add_named(self.first_run.steps.?, buildFolders(self), @tagName(Step.folders));
    _ = gtk.gtk_stack_add_named(self.first_run.steps.?, buildIdentify(self), @tagName(Step.identify));
    _ = gtk.gtk_stack_add_named(self.first_run.steps.?, buildListen(self), @tagName(Step.listen));
    return steps;
}

fn buildFolders(self: *App) *gtk.Widget {
    const top = heading("Welcome to Orca", gtk.gtk_label_new("Point Orca at your music. It reads your files and never changes them unless you ask."));

    const list = box(gtk.ORIENTATION_VERTICAL, 8, "first-run-folders");
    self.first_run.folder_list = gtk.cast(gtk.Box, list);
    const add_content = box(gtk.ORIENTATION_HORIZONTAL, 8, null);
    const add_text = gtk.gtk_label_new("Add Folder…");
    self.first_run.add_label = gtk.cast(gtk.Label, add_text);
    append(add_content, &.{ icon("orca-plus-symbolic", 15, null), add_text });
    const add = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, add), add_content);
    gtk.gtk_widget_add_css_class(add, "first-run-add");
    gtk.gtk_widget_set_halign(add, gtk.ALIGN_START);
    _ = gtk.signalConnect(add, "clicked", gtk.callback(addClicked), self);
    const watch = toggle(self.watch_folders, "Watch for changes", watchSwitched, self);
    self.first_run.watch_switch = gtk.cast(gtk.Switch, watch);
    const card = box(gtk.ORIENTATION_VERTICAL, 14, "first-run-card");
    append(card, &.{
        label("Where does your music live?", "first-run-card-title"),
        list,
        add,
        switchRow("Watch for changes", "New and edited files appear automatically", watch),
    });

    const scan = button("Scan My Music", "first-run-primary", scanClicked, self);
    gtk.gtk_widget_set_sensitive(scan, gtk.false_);
    self.first_run.scan_button = scan;
    const note = noteLabel("No audio setup needed. Orca picks safe defaults.");
    return stepPage(.folders, top, card, footer(note.widget, scan));
}

fn buildIdentify(self: *App) *gtk.Widget {
    const top = heading("Measure your music", gtk.gtk_label_new("Orca can measure each file’s loudness so albums play at an even volume, and find duplicate copies. It runs in the background while you listen."));
    const analyze = toggle(true, "Analyze my music", analyzeSwitched, self);
    self.first_run.analyze_switch = gtk.cast(gtk.Switch, analyze);
    const text = label("Waiting to start", "first-run-progress-text");
    self.first_run.analysis_text = gtk.cast(gtk.Label, text);
    const bar = progressBar("first-run-bar");
    self.first_run.analysis_bar = bar;
    const progress = box(gtk.ORIENTATION_VERTICAL, 10, "first-run-progress");
    append(progress, &.{ text, gtk.cast(gtk.Widget, bar) });
    const card = box(gtk.ORIENTATION_VERTICAL, 14, "first-run-card");
    const option = switchRow("Analyze my music", "Loudness for even volume, fingerprints for duplicates", analyze);
    gtk.gtk_widget_add_css_class(option, "first");
    append(card, &.{ option, progress });
    const skip = button("Skip", "first-run-secondary", skipClicked, self);
    self.first_run.skip_button = gtk.cast(gtk.Button, skip);
    const note = noteLabel("Analysis keeps running if you skip ahead.");
    return stepPage(.identify, top, card, footer(note.widget, skip));
}

fn buildListen(self: *App) *gtk.Widget {
    const top = heading("Ready to listen", gtk.gtk_label_new("Your library is built. Everything Orca found is in Albums."));
    const numbers = box(gtk.ORIENTATION_HORIZONTAL, 16, "first-run-numbers");
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, numbers), gtk.true_);
    for ([_][*:0]const u8{ "Albums", "Artists", "Tracks" }, 0..) |name, index| {
        const value = label("0", "first-run-number");
        self.first_run.listen_numbers[index] = gtk.cast(gtk.Label, value);
        const cell = box(gtk.ORIENTATION_VERTICAL, 4, null);
        append(cell, &.{ value, label(name, "first-run-hint") });
        gtk.gtk_box_append(gtk.cast(gtk.Box, numbers), cell);
    }
    const card = box(gtk.ORIENTATION_VERTICAL, 14, "first-run-card");
    append(card, &.{numbers});
    const note = noteLabel("");
    self.first_run.listen_note = note.text;
    const open = button("Start Listening", "first-run-primary", listenClicked, self);
    return stepPage(.listen, top, card, footer(note.widget, open));
}

fn addFolder(self: *App, path: []const u8) void {
    const first = &self.first_run;
    for (first.folders.items) |folder| if (std.mem.eql(u8, folder.path, path)) return;
    const list = first.folder_list orelse return;
    const owned = self.allocator.dupeSentinel(u8, path, 0) catch return;
    const detail = label("Counting audio files…", "first-run-hint");
    const path_label = label(owned.ptr, "first-run-path");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, path_label), gtk.ELLIPSIZE_MIDDLE);
    const text = box(gtk.ORIENTATION_VERTICAL, 2, null);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    append(text, &.{ path_label, detail });
    const remove = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, remove), icon("orca-close-symbolic", 14, null));
    gtk.gtk_widget_add_css_class(remove, "first-run-remove");
    gtk.gtk_widget_set_valign(remove, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(remove, "Remove folder");
    _ = gtk.signalConnect(remove, "clicked", gtk.callback(removeClicked), self);
    const row = box(gtk.ORIENTATION_HORIZONTAL, 12, "first-run-folder");
    append(row, &.{ icon("orca-folders-symbolic", 18, "first-run-folder-icon"), text, remove });
    first.folders.append(self.allocator, .{
        .path = owned,
        .row = row,
        .remove = remove,
        .detail = gtk.cast(gtk.Label, detail),
        .estimate = startEstimate(self, owned),
    }) catch {
        self.allocator.free(owned);
        return;
    };
    gtk.gtk_box_append(list, row);
    if (first.folders.items[first.folders.items.len - 1].estimate == null)
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, detail), "");
    syncFolders(self);
}

fn startEstimate(self: *App, path: []const u8) ?*Estimate {
    const estimate = self.allocator.create(Estimate) catch return null;
    estimate.* = .{
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(estimate);
            return null;
        },
        .waker = self.waker(),
    };
    estimate.token.io = estimate.threaded.io();
    estimate.thread = std.Thread.spawn(.{}, Estimate.run, .{estimate}) catch {
        estimate.destroy(self.allocator);
        return null;
    };
    return estimate;
}

fn retire(self: *App, estimate: *Estimate) void {
    estimate.token.cancel();
    self.first_run.retiring.append(self.allocator, estimate) catch {};
}

fn syncFolders(self: *App) void {
    const first = &self.first_run;
    const any = first.folders.items.len != 0;
    if (first.add_label) |text| gtk.gtk_label_set_text(text, if (any) "Add Another Folder…" else "Add Folder…");
    if (first.scan_button) |scan| gtk.gtk_widget_set_sensitive(scan, boolean(any and self.library != null));
}

fn showEstimates(self: *App) void {
    for (self.first_run.folders.items) |*folder| {
        if (folder.shown) continue;
        const estimate = folder.estimate orelse continue;
        if (!estimate.finished.load(.acquire)) continue;
        folder.shown = true;
        var buffer: [96]u8 = undefined;
        const audio_files = estimate.audio_files.load(.acquire);
        const text: [:0]const u8 = if (estimate.failed.load(.acquire))
            "Orca cannot read this folder"
        else if (estimate.truncated.load(.acquire))
            strings.format(&buffer, "More than {f} audio files found", .{strings.grouped(audio_files)})
        else if (audio_files == 0)
            "No audio files found yet"
        else if (audio_files == rounded(audio_files))
            strings.format(&buffer, "{f} audio {s} found", .{ strings.grouped(audio_files), plural(audio_files, "file", "files") })
        else
            strings.format(&buffer, "About {f} audio files found", .{strings.grouped(rounded(audio_files))});
        gtk.gtk_label_set_text(folder.detail, text.ptr);
    }
}

fn removeClicked(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const first = &self.first_run;
    for (first.folders.items, 0..) |folder, index| {
        if (@as(?*anyopaque, folder.remove) != widget) continue;
        if (folder.estimate) |estimate| retire(self, estimate);
        if (first.folder_list) |list| gtk.gtk_box_remove(list, folder.row);
        self.allocator.free(folder.path);
        _ = first.folders.orderedRemove(index);
        break;
    }
    syncFolders(self);
}

fn folderChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const folder = gtk.gtk_file_dialog_select_folder_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(folder);
    gtk.g_object_unref(folder);
    const path = raw_path orelse return self.toast("That folder is not on the local filesystem");
    defer gtk.g_free(path);
    addFolder(self, std.mem.span(path));
}

fn addClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Add Music Folder");
    gtk.gtk_file_dialog_select_folder(dialog, self.window, null, folderChosen, self);
    gtk.g_object_unref(dialog);
}

fn watchSwitched(control: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = gtk.gtk_switch_get_active(gtk.cast(gtk.Switch, control)) != 0;
    if (enabled == self.watch_folders) return;
    self.watch_folders = enabled;
    if (watching.apply(self) == .failed) {
        self.watch_folders = !enabled;
        gtk.gtk_switch_set_active(gtk.cast(gtk.Switch, control), boolean(self.watch_folders));
        return self.toast(if (enabled) "Could not watch the music folders" else "Could not stop watching the music folders");
    }
    settings.save(self);
    self.requestTick();
}

fn scanClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    var added: usize = 0;
    for (self.first_run.folders.items) |folder| {
        _ = self.runtime.libraryAddRoot(library, self.io, folder.path) catch {
            var buffer: [320]u8 = undefined;
            self.toast(strings.format(&buffer, "Could not add {s}", .{folder.path}));
            continue;
        };
        added += 1;
    }
    preferences.refreshLibrary(self);
    if (added == 0) return;
    const job = jobs.scanLibrary(self) orelse return;
    const first = &self.first_run;
    first.flow = .scanning;
    first.hidden = false;
    first.scan_job = job;
    first.refreshed_us = 0;
    first.shown_albums = std.math.maxInt(u64);
    resetScanPage(self);
    showShell(self, "main");
    window.goTo(self, .scan);
}

fn analyzeSwitched(control: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const first = &self.first_run;
    first.analyze = gtk.gtk_switch_get_active(gtk.cast(gtk.Switch, control)) != 0;
    if (first.analyze) {
        if (first.analysis_job == null and first.flow == .analyzing) first.analysis_job = jobs.analyzeLibrary(self);
    } else if (first.analysis_job) |job| {
        self.runtime.cancelJob(job) catch {};
        first.analysis_job = null;
    }
    showAnalysis(self);
}

fn skipClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    showListen(state(data));
}

fn listenClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    finish(self);
    showShell(self, "main");
    window.goTo(self, .albums);
}

fn hideClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.first_run.hidden = true;
    window.goTo(self, .albums);
}

fn pauseClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const job = self.first_run.scan_job orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch return;
    if (snapshot.paused)
        self.runtime.resumeJob(job) catch return self.toast("Could not resume the scan")
    else
        self.runtime.pauseJob(job) catch return self.toast("The scan cannot be paused right now");
    refreshScan(self, true);
    self.requestTick();
}

fn reviewClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .health);
}

fn slotClicked(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    for (self.first_run.slots) |slot| {
        if (@as(?*anyopaque, slot.button) != widget) continue;
        const release_id = slot.release_id orelse return;
        return window.showAlbum(self, release_id);
    }
}

fn finish(self: *App) void {
    const first = &self.first_run;
    first.flow = .idle;
    first.scan_job = null;
    first.analysis_job = null;
    for (first.folders.items) |folder| {
        if (folder.estimate) |estimate| retire(self, estimate);
        if (first.folder_list) |list| gtk.gtk_box_remove(list, folder.row);
        self.allocator.free(folder.path);
    }
    first.folders.clearRetainingCapacity();
    syncFolders(self);
}

fn buildStage(self: *App, index: usize, title: [*:0]const u8, detail: [*:0]const u8) *gtk.Widget {
    const mark = box(gtk.ORIENTATION_HORIZONTAL, 0, "scan-stage-mark");
    const check = icon("orca-check-symbolic", 13, null);
    gtk.gtk_widget_set_halign(check, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_halign(mark, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(mark, gtk.ALIGN_START);
    append(mark, &.{check});
    const name = label(title, "scan-stage-title");
    const subtitle = label(detail, "scan-stage-detail");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, subtitle), gtk.true_);
    const text = box(gtk.ORIENTATION_VERTICAL, 2, null);
    append(text, &.{ name, subtitle });
    const row = box(gtk.ORIENTATION_HORIZONTAL, 10, "scan-stage");
    append(row, &.{ mark, text });
    self.first_run.stages[index] = .{ .mark = mark, .title = gtk.cast(gtk.Label, name), .detail = gtk.cast(gtk.Label, subtitle) };
    return row;
}

fn buildSlot(self: *App, index: usize) *gtk.Widget {
    const cover = art.newCover(self, art.initialsPlaceholder(), tile_pixels);
    gtk.gtk_widget_add_css_class(cover, "scan-cover");
    const title = label("", "scan-tile-title");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    const artist = label("", "scan-tile-artist");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, artist), gtk.ELLIPSIZE_END);
    const content = box(gtk.ORIENTATION_VERTICAL, 9, null);
    const text = box(gtk.ORIENTATION_VERTICAL, 4, null);
    append(text, &.{ title, artist });
    append(content, &.{ cover, text });
    gtk.gtk_widget_set_size_request(content, tile_pixels, -1);
    const slot = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, slot), content);
    gtk.gtk_widget_add_css_class(slot, "scan-tile");
    gtk.gtk_widget_set_sensitive(slot, gtk.false_);
    _ = gtk.signalConnect(slot, "clicked", gtk.callback(slotClicked), self);
    self.first_run.slots[index] = .{
        .button = slot,
        .cover = cover,
        .title = gtk.cast(gtk.Label, title),
        .artist = gtk.cast(gtk.Label, artist),
    };
    return slot;
}

pub fn buildScan(self: *App) *gtk.Widget {
    const first = &self.first_run;
    const title = gtk.gtk_label_new("Building your library");
    gtk.gtk_widget_add_css_class(title, "display-page");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0);
    const tagline = label("You can start listening now. Albums appear as Orca finds them.", "scan-tagline");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, tagline), gtk.true_);
    const words = box(gtk.ORIENTATION_VERTICAL, 6, null);
    gtk.gtk_widget_set_hexpand(words, gtk.true_);
    append(words, &.{ title, tagline });
    const pause = button("Pause", "scan-button", pauseClicked, self);
    first.pause_button = gtk.cast(gtk.Button, pause);
    const hide = button("Hide", "scan-button", hideClicked, self);
    gtk.gtk_widget_add_css_class(hide, "plain");
    const actions = box(gtk.ORIENTATION_HORIZONTAL, 10, null);
    gtk.gtk_widget_set_valign(actions, gtk.ALIGN_END);
    append(actions, &.{ pause, hide });
    const header = box(gtk.ORIENTATION_HORIZONTAL, 24, null);
    append(header, &.{ words, actions });

    const progress_title = label("Finding files", "scan-progress-title");
    gtk.gtk_widget_set_hexpand(progress_title, gtk.true_);
    first.progress_title = gtk.cast(gtk.Label, progress_title);
    const eta = label("", "scan-eta");
    first.progress_eta = gtk.cast(gtk.Label, eta);
    const summary = box(gtk.ORIENTATION_HORIZONTAL, 16, null);
    append(summary, &.{ progress_title, eta });
    const bar = progressBar("scan-bar");
    first.progress_bar = bar;
    const current = label("", "scan-current-text");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, current), gtk.ELLIPSIZE_MIDDLE);
    gtk.gtk_widget_set_hexpand(current, gtk.true_);
    first.current_path = gtk.cast(gtk.Label, current);
    const current_row = box(gtk.ORIENTATION_HORIZONTAL, 8, "scan-current");
    append(current_row, &.{ icon("orca-file-symbolic", 14, null), current });
    const stages = box(gtk.ORIENTATION_HORIZONTAL, 14, "scan-stages");
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, stages), gtk.true_);
    append(stages, &.{
        buildStage(self, 0, "Discover files", ""),
        buildStage(self, 1, "Read tags & build albums", ""),
        buildStage(self, 2, "Loudness analysis", "Runs after the scan, in the background"),
        buildStage(self, 3, "Match with MusicBrainz", "Optional · uses AcoustID"),
    });
    const card = box(gtk.ORIENTATION_VERTICAL, 16, "scan-card");
    append(card, &.{ summary, gtk.cast(gtk.Widget, bar), current_row, stages });

    const problems_title = label("", "scan-section-title");
    gtk.gtk_widget_set_hexpand(problems_title, gtk.true_);
    first.problems_title = gtk.cast(gtk.Label, problems_title);
    const review = button("Review later in Library Health", "scan-link", reviewClicked, self);
    const problems_header = box(gtk.ORIENTATION_HORIZONTAL, 16, null);
    append(problems_header, &.{ problems_title, review });
    const problems_list = box(gtk.ORIENTATION_VERTICAL, 0, null);
    first.problems_list = gtk.cast(gtk.Box, problems_list);
    const problems = box(gtk.ORIENTATION_VERTICAL, 8, null);
    append(problems, &.{ problems_header, problems_list });
    gtk.gtk_widget_set_visible(problems, gtk.false_);
    first.problems = problems;

    const found_title = label("Found so far", "scan-section-title");
    const found_count = label("", "scan-found-count");
    first.found_count = gtk.cast(gtk.Label, found_count);
    const found_header = box(gtk.ORIENTATION_HORIZONTAL, 10, null);
    append(found_header, &.{ found_title, found_count });
    const grid = gtk.gtk_flow_box_new();
    const flow = gtk.cast(gtk.FlowBox, grid);
    gtk.gtk_flow_box_set_selection_mode(flow, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_homogeneous(flow, gtk.true_);
    gtk.gtk_flow_box_set_max_children_per_line(flow, found_columns);
    gtk.gtk_flow_box_set_min_children_per_line(flow, 1);
    gtk.gtk_flow_box_set_column_spacing(flow, 20);
    gtk.gtk_flow_box_set_row_spacing(flow, 22);
    gtk.gtk_widget_add_css_class(grid, "scan-found");
    gtk.gtk_widget_set_halign(grid, gtk.ALIGN_START);
    for (0..found_slots) |index| gtk.gtk_flow_box_append(flow, buildSlot(self, index));
    const found = box(gtk.ORIENTATION_VERTICAL, 14, null);
    append(found, &.{ found_header, grid });

    const column = box(gtk.ORIENTATION_VERTICAL, 26, "scan-body");
    append(column, &.{ header, card, problems, found });
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);
    gtk.gtk_widget_add_css_class(scroller, "scan-page");
    return scroller;
}

fn resetScanPage(self: *App) void {
    const first = &self.first_run;
    for (&first.slots) |*slot| clearSlot(self, slot);
    if (first.problems) |problems| gtk.gtk_widget_set_visible(problems, gtk.false_);
    refreshScan(self, true);
}

const Mark = enum { waiting, running, done };

fn setStage(stage: Stage, mark: Mark, detail: [:0]const u8) void {
    for ([_]Mark{ .waiting, .running, .done }) |each| {
        if (each == mark)
            gtk.gtk_widget_add_css_class(stage.mark, @tagName(each))
        else
            gtk.gtk_widget_remove_css_class(stage.mark, @tagName(each));
    }
    if (mark == .waiting)
        gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, stage.title), "waiting")
    else
        gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, stage.title), "waiting");
    if (gtk.gtk_widget_get_first_child(stage.mark)) |check| gtk.gtk_widget_set_visible(check, boolean(mark == .done));
    gtk.gtk_label_set_text(stage.detail, detail.ptr);
}

fn etaText(buffer: []u8, remaining_ms: u64) [:0]const u8 {
    if (remaining_ms < std.time.ms_per_min) return "Less than a minute left";
    const minutes = std.math.divCeil(u64, remaining_ms, std.time.ms_per_min) catch unreachable;
    if (minutes == 1) return "About 1 minute left";
    if (minutes < 60) return strings.format(buffer, "About {d} minutes left", .{minutes});
    const hours = minutes / 60 + @intFromBool(minutes % 60 >= 30);
    return strings.format(buffer, "About {d} {s} left", .{ hours, plural(hours, "hour", "hours") });
}

fn refreshScan(self: *App, force: bool) void {
    const first = &self.first_run;
    const job = first.scan_job orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch return;
    const stats = self.runtime.jobScanStats(job) catch return;
    const now = gtk.g_get_monotonic_time();
    const total = snapshot.total_units;
    var buffer: [160]u8 = undefined;
    var detail_buffer: [160]u8 = undefined;

    if (first.pause_button) |pause| gtk.gtk_button_set_label(pause, if (snapshot.paused) "Resume" else "Pause");
    const seen = if (total) |known| @min(snapshot.completed_units, known) else snapshot.completed_units;

    const title: [:0]const u8 = switch (stats.stage) {
        .discover => "Finding files",
        .read_tags => if (total) |known|
            strings.format(&buffer, "Reading files · {f} of {f}", .{ strings.grouped(seen), strings.grouped(known) })
        else
            strings.format(&buffer, "Reading files · {f}", .{strings.grouped(seen)}),
        .done => "Finishing up",
    };
    if (first.progress_title) |text| gtk.gtk_label_set_text(text, title.ptr);

    var eta_buffer: [64]u8 = undefined;
    const eta: [:0]const u8 = eta: {
        if (snapshot.paused) break :eta "Paused";
        if (stats.stage != .read_tags) break :eta "";
        const remaining_ms = snapshot.estimated_remaining_ms orelse break :eta "";
        if (remaining_ms == 0) break :eta "";
        break :eta etaText(&eta_buffer, remaining_ms);
    };
    if (first.progress_eta) |text| gtk.gtk_label_set_text(text, eta.ptr);
    if (first.progress_bar) |bar| gtk.gtk_progress_bar_set_fraction(bar, if (total) |known|
        if (known == 0) 0 else @as(f64, @floatFromInt(seen)) / @as(f64, @floatFromInt(known))
    else
        0);
    if (first.current_path) |text| {
        const path = stats.current_path.slice();
        gtk.gtk_label_set_text(text, strings.terminated(&buffer, path).ptr);
    }

    const discovered: [:0]const u8 = if (total) |known|
        strings.format(&detail_buffer, "{f} {s}", .{ strings.grouped(known), plural(known, "file", "files") })
    else
        "Counting files…";
    setStage(first.stages[0], if (stats.stage == .discover) .running else .done, discovered);
    const albums_text: [:0]const u8 = if (total) |known|
        strings.format(&buffer, "{f} of {f} · {f} {s}", .{ strings.grouped(seen), strings.grouped(known), strings.grouped(stats.albums_found), plural(stats.albums_found, "album", "albums") })
    else
        strings.format(&buffer, "{f} files · {f} {s}", .{ strings.grouped(seen), strings.grouped(stats.albums_found), plural(stats.albums_found, "album", "albums") });
    setStage(first.stages[1], switch (stats.stage) {
        .discover => .waiting,
        .read_tags => .running,
        .done => .done,
    }, albums_text);
    setStage(first.stages[2], if (first.analysis_job != null) .running else .waiting, "Runs after the scan, in the background");
    setStage(first.stages[3], .waiting, "Optional · uses AcoustID");

    if (first.found_count) |text| gtk.gtk_label_set_text(text, strings.format(&buffer, "{f} {s}", .{ strings.grouped(stats.albums_found), plural(stats.albums_found, "album", "albums") }).ptr);
    if (!force and now - first.refreshed_us < refresh_interval_us) return;
    first.refreshed_us = now;
    refreshProblems(self);
    if (stats.albums_found != first.shown_albums) {
        first.shown_albums = stats.albums_found;
        refreshFound(self);
        window.refreshCounts(self);
    }
}

fn clearSlot(self: *App, slot: *Slot) void {
    if (slot.release_id == null) return;
    slot.release_id = null;
    art.forget(self, slot.cover);
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, slot.cover), "placeholder");
    art.setInitials(slot.cover, "");
    gtk.gtk_label_set_text(slot.title, "");
    gtk.gtk_label_set_text(slot.artist, "");
    gtk.gtk_widget_set_sensitive(slot.button, gtk.false_);
}

fn refreshFound(self: *App) void {
    const library = self.library orelse return;
    const page = self.runtime.libraryReleasePage(library, .{ .sort = .recently_added, .limit = found_slots }) catch return;
    defer page.deinit();
    var buffer: [512]u8 = undefined;
    for (&self.first_run.slots, 0..) |*slot, index| {
        if (index >= page.items.len) {
            clearSlot(self, slot);
            continue;
        }
        const release = page.items[index];
        if (slot.release_id == release.id) continue;
        slot.release_id = release.id;
        art.setInitials(slot.cover, release.title);
        art.show(self, slot.cover, art.Key.release(release.id, art.Size.atLeast(tile_pixels)));
        gtk.gtk_label_set_text(slot.title, strings.terminated(&buffer, release.title).ptr);
        gtk.gtk_label_set_text(slot.artist, strings.terminated(&buffer, release.album_artist).ptr);
        gtk.gtk_widget_set_sensitive(slot.button, gtk.true_);
    }
}

fn shortPath(path: []const u8) []const u8 {
    var slashes: usize = 0;
    var index = path.len;
    while (index > 0) : (index -= 1) {
        if (path[index - 1] != '/') continue;
        slashes += 1;
        if (slashes == 2) return path[index - 1 ..];
    }
    return path;
}

fn refreshProblems(self: *App) void {
    const library = self.library orelse return;
    const first = &self.first_run;
    const list = first.problems_list orelse return;
    const page = self.runtime.libraryHealthIssuePageOfKind(library, .unreadable_file, problem_rows, 0) catch return;
    defer page.deinit();
    if (first.problems) |problems| gtk.gtk_widget_set_visible(problems, boolean(page.items.len != 0));
    if (page.items.len == 0) return;
    var count: u64 = page.items.len;
    const summary = self.runtime.libraryHealthSummary(library) catch null;
    if (summary) |value| for (value.items()) |kind| {
        if (kind.kind == .unreadable_file) count = kind.count;
    };
    var buffer: [512]u8 = undefined;
    if (first.problems_title) |text| gtk.gtk_label_set_text(text, strings.format(&buffer, "{f} {s} couldn’t be read", .{ strings.grouped(count), plural(count, "file", "files") }).ptr);
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list))) |child| gtk.gtk_box_remove(list, child);
    for (page.items) |issue| {
        const short = shortPath(issue.path);
        const path = label(strings.format(&buffer, "{s}{s}", .{ if (short.len < issue.path.len) "…" else "", short }).ptr, "scan-problem-path");
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, path), gtk.ELLIPSIZE_START);
        gtk.gtk_widget_set_hexpand(path, gtk.true_);
        gtk.gtk_widget_set_tooltip_text(path, strings.terminated(&buffer, issue.path).ptr);
        const reason = label(strings.terminated(&buffer, issue.details).ptr, "scan-problem-reason");
        const row = box(gtk.ORIENTATION_HORIZONTAL, 16, "scan-problem");
        append(row, &.{ path, reason });
        gtk.gtk_box_append(list, row);
    }
}

fn showAnalysis(self: *App) void {
    const first = &self.first_run;
    var buffer: [160]u8 = undefined;
    const text: [:0]const u8, const fraction: f64 = progress: {
        if (!first.analyze) break :progress .{ "Analysis is off. You can run it later from Library Health.", 0 };
        const job = first.analysis_job orelse break :progress .{ "Waiting to start", 0 };
        const snapshot = self.runtime.jobSnapshotSynced(job) catch break :progress .{ "", 0 };
        if (snapshot.state == .queued or snapshot.state == .waiting) break :progress .{ "Starts when the scan finishes", 0 };
        const total = snapshot.total_units orelse break :progress .{ "Measuring files", 0 };
        if (total == 0) break :progress .{ "Every file is measured", 1 };
        const done = @min(snapshot.completed_units, total);
        break :progress .{
            strings.format(&buffer, "Measuring {f} of {f} files", .{ strings.grouped(done), strings.grouped(total) }),
            @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(total)),
        };
    };
    if (first.analysis_text) |label_widget| gtk.gtk_label_set_text(label_widget, text.ptr);
    if (first.analysis_bar) |bar| {
        gtk.gtk_progress_bar_set_fraction(bar, fraction);
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, bar), boolean(first.analyze));
    }
    if (first.skip_button) |skip| {
        gtk.gtk_button_set_label(skip, if (first.analyze) "Skip" else "Continue");
        const widget = gtk.cast(gtk.Widget, skip);
        if (first.analyze) {
            gtk.gtk_widget_remove_css_class(widget, "first-run-primary");
            gtk.gtk_widget_add_css_class(widget, "first-run-secondary");
        } else {
            gtk.gtk_widget_remove_css_class(widget, "first-run-secondary");
            gtk.gtk_widget_add_css_class(widget, "first-run-primary");
        }
    }
}

fn showListen(self: *App) void {
    const first = &self.first_run;
    first.flow = .done;
    var buffer: [32]u8 = undefined;
    if (self.library) |library| if (self.runtime.libraryStats(library)) |stats| {
        for ([_]u64{ stats.releases, stats.artists, stats.tracks }, first.listen_numbers) |value, number| {
            if (number) |text| gtk.gtk_label_set_text(text, grouped(&buffer, value).ptr);
        }
    } else |_| {};
    const analyzing = first.analysis_job != null and jobs.active(self, .analysis);
    if (first.listen_note) |note| gtk.gtk_label_set_text(note, if (analyzing)
        "Loudness analysis continues in the background."
    else if (self.watch_folders)
        "Orca keeps watching your folders for changes."
    else
        "Rescan any time from Settings.");
    showStep(self, .listen);
}

fn ended(state_value: liborca.JobState) bool {
    return switch (state_value) {
        .succeeded, .failed, .cancelled => true,
        else => false,
    };
}

fn scanEnded(self: *App, succeeded: bool) void {
    const first = &self.first_run;
    first.scan_job = null;
    if (!succeeded) {
        first.flow = .idle;
        return;
    }
    first.flow = .analyzing;
    if (first.analyze) first.analysis_job = jobs.analyzeLibrary(self);
    if (first.analyze_switch) |control| gtk.gtk_switch_set_active(control, boolean(first.analyze));
    if (first.hidden or self.current_page != .scan) {
        finish(self);
        return;
    }
    showAnalysis(self);
    showStep(self, .identify);
}

fn reapRetired(self: *App) void {
    const retiring = &self.first_run.retiring;
    var index: usize = 0;
    while (index < retiring.items.len) {
        const estimate = retiring.items[index];
        if (!estimate.finished.load(.acquire)) {
            index += 1;
            continue;
        }
        estimate.destroy(self.allocator);
        _ = retiring.swapRemove(index);
    }
}

pub fn tick(self: *App) void {
    const first = &self.first_run;
    reapRetired(self);
    showEstimates(self);
    switch (first.flow) {
        .idle, .done => {},
        .scanning => {
            const job = first.scan_job orelse return;
            const snapshot = self.runtime.jobSnapshotSynced(job) catch return scanEnded(self, false);
            if (ended(snapshot.state)) {
                refreshScan(self, true);
                return scanEnded(self, snapshot.state == .succeeded);
            }
            if (self.current_page == .scan) refreshScan(self, false);
        },
        .analyzing => {
            showAnalysis(self);
            const job = first.analysis_job orelse return;
            const snapshot = self.runtime.jobSnapshotSynced(job) catch return;
            if (ended(snapshot.state)) {
                first.analysis_job = null;
                showListen(self);
            }
        },
    }
}

/// Joins the folder estimates. They write the wake eventfd when they finish,
/// so this runs before main closes it.
pub fn shutdown(self: *App) void {
    const first = &self.first_run;
    for (first.folders.items) |folder| {
        if (folder.estimate) |estimate| {
            estimate.token.cancel();
            estimate.destroy(self.allocator);
        }
        self.allocator.free(folder.path);
    }
    first.folders.clearAndFree(self.allocator);
    for (first.retiring.items) |estimate| {
        estimate.token.cancel();
        estimate.destroy(self.allocator);
    }
    first.retiring.clearAndFree(self.allocator);
}

pub fn forgetLibrary(self: *App) void {
    const first = &self.first_run;
    finish(self);
    for (first.retiring.items) |estimate| estimate.destroy(self.allocator);
    first.retiring.clearRetainingCapacity();
    first.hidden = false;
    first.shown_albums = std.math.maxInt(u64);
    resetScanPage(self);
    showShell(self, "main");
}
