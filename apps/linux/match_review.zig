//! The Match Review page: one album beside its best MusicBrainz release,
//! field by field and track by track, with the fields to take chosen one at
//! a time. liborca compares them on a loader thread and applies the chosen
//! set; this only lays them out.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const jobs = @import("jobs.zig");
const matches = @import("matches.zig");
const submissions = @import("submissions.zig");
const window = @import("window.zig");
const page_ui = @import("page.zig");

const App = app.App;
const Field = liborca.ReleaseField;

const separator = " · ";
const release_url = "https://musicbrainz.org/release/";
const cover_pixels: c_int = 72;
const window_size: u32 = 100;
const number_width: c_int = 34;
const delta_width: c_int = 60;
const status_width: c_int = 230;
const apply_tooltip = "Take the checked fields into Orca's library; no file is written";

pub const Entry = struct {
    release_id: i64,
    /// Null while the release a Track's release ID names is not read.
    confidence: ?f32,
    from_tags: bool = false,
};

const Tracklist = union(enum) {
    none,
    aligned: liborca.ReleaseAlignment,
    not_read,
    too_large,

    fn deinit(self: *Tracklist) void {
        if (self.* == .aligned) self.aligned.deinit();
        self.* = .none;
    }
};

const Primary = enum { apply, mark, unmark };

pub const Scope = struct {
    bucket: matches.Bucket = .needs_review,
    confident_at: f32 = 0.9,
    filter: matches.Filter = .{},
};

const Loader = struct {
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    waker: liborca.HostWaker,
    scope: Scope,
    generation: u32,
    index: usize,
    release_id: ?i64,
    windowed: bool = false,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    window: ?liborca.ReleaseMatchPage = null,
    window_offset: usize = 0,
    total: u64 = 0,
    diff: ?liborca.ReleaseMatchDiff = null,
    tracklist: Tracklist = .none,

    fn run(self: *Loader) void {
        if (self.release_id == null) {
            self.windowed = true;
            self.readWindow();
        }
        if (self.release_id) |release_id| {
            self.diff = self.runtime.libraryReleaseMatchDiff(self.library, std.heap.smp_allocator, release_id, null) catch null;
            if (self.diff) |diff| self.tracklist = self.readTracklist(release_id, diff.release_mbid);
        }
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn readTracklist(self: *Loader, release_id: i64, release_mbid: []const u8) Tracklist {
        const alignment = self.runtime.libraryReleaseAlignment(self.library, std.heap.smp_allocator, release_id, release_mbid) catch |err| return switch (err) {
            error.NoReleaseTracklist => .not_read,
            error.ReleaseTooLarge => .too_large,
            else => .none,
        };
        return .{ .aligned = alignment };
    }

    fn readWindow(self: *Loader) void {
        const filter = self.scope.filter.text();
        const counts = self.runtime.libraryReleaseMatchCounts(self.library, self.scope.confident_at, filter) catch return;
        self.total = switch (self.scope.bucket) {
            .confident => counts.confident,
            .needs_review => counts.needs_review,
            .unmatched => counts.unmatched,
            .reviewed => counts.reviewed,
        };
        if (self.total == 0) return;
        self.index = @min(self.index, self.total - 1);
        self.window_offset = self.index / window_size * window_size;
        const offset = std.math.cast(u32, self.window_offset) orelse return;
        const page = self.runtime.libraryReleaseMatchPage(self.library, std.heap.smp_allocator, self.scope.bucket, self.scope.confident_at, filter, window_size, offset) catch return;
        self.window = page;
        if (page.items.len == 0) return;
        self.index = @min(self.index, self.window_offset + page.items.len - 1);
        self.release_id = page.items[self.index - self.window_offset].release_id;
    }

    fn destroy(self: *Loader, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.window) |*page| page.deinit();
        if (self.diff) |*diff| diff.deinit();
        self.tracklist.deinit();
        allocator.destroy(self);
    }
};

pub const State = struct {
    built: bool = false,
    scope: Scope = .{},
    entries: std.ArrayList(Entry) = .empty,
    window_offset: usize = 0,
    total: u64 = 0,
    index: usize = 0,
    diff: ?liborca.ReleaseMatchDiff = null,
    tracklist: Tracklist = .none,
    shown_release: ?i64 = null,
    primary: Primary = .apply,
    loader: ?*Loader = null,
    stale: bool = false,
    generation: u32 = 0,
    window_stale: bool = false,
    skip_release: ?i64 = null,
    checks: std.EnumArray(Field, ?*gtk.Widget) = .initFill(null),
    rows: std.EnumArray(Field, ?*gtk.Widget) = .initFill(null),
    cover: ?*gtk.Widget = null,
    title: ?*gtk.Label = null,
    summary: ?*gtk.Label = null,
    link: ?*gtk.Widget = null,
    crumb: ?*gtk.Label = null,
    position: ?*gtk.Label = null,
    previous: ?*gtk.Widget = null,
    next: ?*gtk.Widget = null,
    apply: ?*gtk.Widget = null,
    mark: ?*gtk.Widget = null,
    not_this: ?*gtk.Widget = null,
    search: ?*gtk.Widget = null,
    fields: ?*gtk.Box = null,
    tracks: ?*gtk.Box = null,
    tracks_title: ?*gtk.Label = null,
    tracks_note: ?*gtk.Label = null,
    content: ?*gtk.Widget = null,
    message: ?*gtk.Label = null,
    scroller: ?*gtk.ScrolledWindow = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.forgetShown();
        self.entries.deinit(allocator);
        self.entries = .empty;
    }

    fn freeShown(self: *State) void {
        if (self.diff) |*diff| diff.deinit();
        self.diff = null;
        self.tracklist.deinit();
    }

    fn forgetShown(self: *State) void {
        self.freeShown();
        self.shown_release = null;
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn current(self: *App) ?Entry {
    const review = &self.match_review;
    if (review.window_stale or review.index < review.window_offset) return null;
    const at = review.index - review.window_offset;
    if (at >= review.entries.items.len) return null;
    return review.entries.items[at];
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    return widget;
}

fn cell(text: [*:0]const u8, class: [*:0]const u8, width: c_int) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, widget), 1);
    if (width > 0) gtk.gtk_widget_set_size_request(widget, width, -1) else gtk.gtk_widget_set_hexpand(widget, gtk.true_);
    return widget;
}

fn append(box: *gtk.Widget, children: []const *gtk.Widget) void {
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, box), child);
}

fn fieldName(field: Field) [*:0]const u8 {
    return switch (field) {
        .album => "Album",
        .album_artist => "Album artist",
        .release_date => "Release date",
        .release_type => "Release type",
        .release_id => "Release ID",
        .genre => "Genre",
        .artwork => "Artwork",
        .track_titles => "Track titles and artists",
    };
}

fn applicable(field: Field) bool {
    return switch (field) {
        .release_type, .genre, .artwork => false,
        else => true,
    };
}

fn checkedByDefault(diff: liborca.ReleaseFieldDiff) bool {
    return diff.differs and switch (diff.field) {
        .album, .album_artist, .release_date, .release_id => true,
        else => false,
    };
}

fn artworkText(buffer: []u8, text: []const u8, size: ?liborca.ArtworkSize) [:0]const u8 {
    if (text.len == 0) return strings.terminated(buffer, "—");
    const source = text[0 .. std.mem.indexOf(u8, text, separator) orelse text.len];
    const name = if (std.mem.eql(u8, source, "Cover Art Archive") or std.mem.eql(u8, source, "fetched")) "Cover Art Archive" else "Local";
    const measured = size orelse return strings.format(buffer, "{s}" ++ separator ++ "—", .{name});
    return strings.format(buffer, "{s}" ++ separator ++ "{d} × {d}", .{ name, measured.width, measured.height });
}

fn titlesDiffer(diff: liborca.ReleaseMatchDiff) u32 {
    var count: u32 = 0;
    for (diff.tracks) |track| {
        if (track.differs) count += 1;
    }
    return count;
}

const TracksDiffer = enum { nothing, artists_only, case_only, other };

fn howTracksDiffer(diff: liborca.ReleaseMatchDiff) TracksDiffer {
    var titles_equal = true;
    var case_only = true;
    var any = false;
    for (diff.tracks) |track| {
        if (!track.differs) continue;
        any = true;
        if (!std.mem.eql(u8, track.local_title, track.candidate_title)) titles_equal = false;
        if (!std.ascii.eqlIgnoreCase(track.local_title, track.candidate_title) or
            !std.ascii.eqlIgnoreCase(track.local_artist, track.candidate_artist)) case_only = false;
    }
    if (!any) return .nothing;
    if (titles_equal) return .artists_only;
    return if (case_only) .case_only else .other;
}

fn localText(buffer: []u8, diff: liborca.ReleaseMatchDiff, each: liborca.ReleaseFieldDiff) [:0]const u8 {
    return switch (each.field) {
        .artwork => artworkText(buffer, each.local, diff.local_artwork_size),
        .release_id => if (each.local.len == 0)
            strings.terminated(buffer, "—")
        else if (std.mem.eql(u8, each.local, each.candidate))
            strings.terminated(buffer, "MusicBrainz release ID")
        else
            strings.format(buffer, "{s}…", .{each.local[0..@min(each.local.len, 8)]}),
        .track_titles => switch (titlesDiffer(diff)) {
            0 => strings.terminated(buffer, "All agree"),
            1 => strings.terminated(buffer, "1 differs"),
            else => |count| strings.format(buffer, "{d} differ", .{count}),
        },
        else => strings.terminated(buffer, if (each.local.len != 0) each.local else "—"),
    };
}

fn candidateText(buffer: []u8, diff: liborca.ReleaseMatchDiff, each: liborca.ReleaseFieldDiff) [:0]const u8 {
    return switch (each.field) {
        .artwork => artworkText(buffer, each.candidate, diff.candidate_artwork_size),
        .release_id => strings.terminated(buffer, if (each.candidate.len != 0) "MusicBrainz release ID" else "—"),
        .track_titles => strings.terminated(buffer, switch (howTracksDiffer(diff)) {
            .nothing, .other => "As released",
            .artists_only => "As credited",
            .case_only => "Capitalized as released",
        }),
        else => strings.terminated(buffer, if (each.candidate.len != 0) each.candidate else "—"),
    };
}

fn checkedFields(self: *App) liborca.ReleaseFieldSet {
    var fields: liborca.ReleaseFieldSet = .empty;
    for (std.enums.values(Field)) |field| {
        const check = self.match_review.checks.get(field) orelse continue;
        if (!applicable(field)) continue;
        if (gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, check)) != 0) fields.insert(field);
    }
    return fields;
}

fn anyDiffers(diff: liborca.ReleaseMatchDiff) bool {
    for (diff.fields) |each| if (applicable(each.field) and each.differs) return true;
    return false;
}

fn fieldsText(buffer: []u8, count: usize) [:0]const u8 {
    if (count == 1) return strings.terminated(buffer, "Apply 1 Field to Orca");
    return strings.format(buffer, "Apply {d} Fields to Orca", .{count});
}

fn showChecked(self: *App) void {
    const review = &self.match_review;
    for (std.enums.values(Field)) |field| {
        const row = review.rows.get(field) orelse continue;
        const check = review.checks.get(field) orelse continue;
        if (gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, check)) != 0)
            gtk.gtk_widget_add_css_class(row, "checked")
        else
            gtk.gtk_widget_remove_css_class(row, "checked");
    }
    const primary = review.apply orelse return;
    const count = checkedFields(self).count();
    var text_buffer: [96]u8 = undefined;
    var tooltip_buffer: [128]u8 = undefined;
    var text = fieldsText(&text_buffer, count);
    var tooltip: [:0]const u8 = apply_tooltip;
    var sensitive = count != 0 and review.diff != null;
    var offer_mark = false;
    review.primary = .apply;
    if (review.scope.bucket == .reviewed) {
        review.primary = .unmark;
        text = "Unmark Reviewed";
        tooltip = "Put this album back in the list to review";
        sensitive = review.diff != null;
        if (current(self)) |entry| if (entry.from_tags) {
            tooltip = "Your tags identify this album; remove or change a file's release ID tag to put it back in the list";
            sensitive = false;
        };
    } else switch (review.tracklist) {
        .not_read => {
            sensitive = false;
            tooltip = "Look up the release first";
        },
        .aligned => |*alignment| {
            const placement: Placement = .of(alignment);
            const total = placement.placed + placement.unplaced;
            if (placement.unplaced != 0) {
                text = strings.format(&text_buffer, "Apply {d} {s}" ++ separator ++ "{d} of {d} {s}", .{
                    count,
                    if (count == 1) "Field" else "Fields",
                    placement.placed,
                    total,
                    if (total == 1) "Track" else "Tracks",
                });
                tooltip = strings.format(&tooltip_buffer, "Album values go to every track; track values only to the {d} placed", .{placement.placed});
            } else if (review.diff) |diff| {
                if (anyDiffers(diff)) {
                    offer_mark = true;
                } else {
                    review.primary = .mark;
                    text = "Mark as Reviewed";
                    tooltip = "Nothing differs and every track is placed: take this album off the list without writing";
                    sensitive = true;
                }
            }
        },
        .too_large => {
            sensitive = false;
            tooltip = "Orca cannot align or apply a release of more than 512 tracks";
        },
        .none => {},
    }
    if (review.mark) |mark| gtk.gtk_widget_set_visible(mark, @intFromBool(offer_mark));
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, primary), text.ptr);
    gtk.gtk_widget_set_tooltip_text(primary, tooltip.ptr);
    gtk.gtk_widget_set_sensitive(primary, @intFromBool(sensitive));
}

fn checkToggled(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    showChecked(state(data));
}

fn fieldRow(self: *App, diff: liborca.ReleaseMatchDiff, each: liborca.ReleaseFieldDiff, kept: ?bool) *gtk.Widget {
    const check = gtk.gtk_check_button_new_with_label(null);
    gtk.gtk_widget_add_css_class(check, "match-review-check");
    gtk.gtk_widget_set_size_request(check, 40, -1);
    gtk.gtk_widget_set_valign(check, gtk.ALIGN_CENTER);
    var name_buffer: [48]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(check, if (applicable(each.field))
        strings.format(&name_buffer, "Adopt {s}", .{std.mem.span(fieldName(each.field))}).ptr
    else
        "Orca compares this but does not take it from a release");
    if (applicable(each.field)) {
        gtk.gtk_check_button_set_active(gtk.cast(gtk.CheckButton, check), @intFromBool(kept orelse checkedByDefault(each)));
    } else {
        gtk.gtk_widget_set_sensitive(check, gtk.false_);
    }
    _ = gtk.signalConnect(check, "toggled", gtk.callback(checkToggled), self);

    var buffer: [512]u8 = undefined;
    const name = cell(fieldName(each.field), "match-review-name", 118);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_NONE);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, name), gtk.true_);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(row, "match-review-field");
    append(row, &.{
        check,
        name,
        cell(localText(&buffer, diff, each).ptr, "match-review-local", 175),
        cell(candidateText(&buffer, diff, each).ptr, "match-review-candidate", 0),
    });
    self.match_review.checks.set(each.field, check);
    self.match_review.rows.set(each.field, row);
    return row;
}

fn heading(texts: []const [*:0]const u8, widths: []const c_int, class: [*:0]const u8) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(row, class);
    for (texts, widths) |text, width| gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell(text, "match-review-column", width));
    return row;
}

fn delta(buffer: []u8, delta_ms: ?i64) [:0]const u8 {
    const ms = delta_ms orelse return strings.terminated(buffer, "—");
    const seconds = @divFloor(ms + 500, 1000);
    if (seconds == 0) return strings.terminated(buffer, "0 s");
    const magnitude: u64 = @abs(seconds);
    return strings.format(buffer, "{s}{d} s", .{ if (seconds > 0) "+" else "−", magnitude });
}

const Placement = struct {
    placed: usize = 0,
    unplaced: usize = 0,

    fn of(alignment: *const liborca.ReleaseAlignment) Placement {
        var placement: Placement = .{ .unplaced = alignment.not_on_release.len };
        for (alignment.rows) |row| {
            if (row.track == null) continue;
            switch (row.status) {
                .paired, .automatic => placement.placed += 1,
                .suggested => placement.unplaced += 1,
                .not_in_files => {},
            }
        }
        return placement;
    }
};

const Unplaced = struct {
    alignment: *const liborca.ReleaseAlignment,
    row: usize = 0,
    other: usize = 0,

    fn next(self: *Unplaced) ?liborca.AlignedTrack {
        while (self.row < self.alignment.rows.len) {
            const row = self.alignment.rows[self.row];
            self.row += 1;
            if (row.status == .suggested) if (row.track) |track| return track;
        }
        if (self.other >= self.alignment.not_on_release.len) return null;
        defer self.other += 1;
        return self.alignment.not_on_release[self.other];
    }
};

const Choice = struct {
    self: *App,
    release_id: i64,
    track_id: i64,
    release_mbid: []u8,
    release_track_mbid: []u8,
    number: [16]u8 = undefined,
    number_len: usize = 0,
};

fn choiceOf(data: ?*anyopaque) *Choice {
    return @ptrCast(@alignCast(data.?));
}

fn freeChoice(data: ?*anyopaque) callconv(.c) void {
    const choice = choiceOf(data);
    const allocator = choice.self.allocator;
    allocator.free(choice.release_mbid);
    allocator.free(choice.release_track_mbid);
    allocator.destroy(choice);
}

fn newChoice(self: *App, alignment: *const liborca.ReleaseAlignment, track_id: i64, row: liborca.ReleaseTrackPlacement) !*Choice {
    const allocator = self.allocator;
    const choice = try allocator.create(Choice);
    errdefer allocator.destroy(choice);
    const release_mbid = try allocator.dupe(u8, alignment.release_mbid);
    errdefer allocator.free(release_mbid);
    const release_track_mbid = try allocator.dupe(u8, row.release_track_mbid);
    choice.* = .{
        .self = self,
        .release_id = alignment.release_id,
        .track_id = track_id,
        .release_mbid = release_mbid,
        .release_track_mbid = release_track_mbid,
    };
    choice.number_len = positionText(&choice.number, alignment, row.disc, row.position).len;
    return choice;
}

fn attach(widget: *gtk.Widget, choice: *Choice, handler: gtk.GCallback) void {
    gtk.g_object_set_data_full(widget, "orca-choice", choice, freeChoice);
    _ = gtk.signalConnect(widget, "clicked", handler, choice);
}

fn refused(self: *App, err: anyerror, failed: [:0]const u8) void {
    switch (err) {
        error.ReleaseTrackAlreadyPaired => self.toast("Another track already holds that release track"),
        error.TrackNotPaired => {},
        else => self.toast(failed),
    }
    matches.invalidate(self);
}

fn pairClicked(source: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const widget: *gtk.Widget = @ptrCast(@alignCast(source.?));
    if (gtk.gtk_widget_get_ancestor(widget, gtk.gtk_popover_get_type())) |popover| gtk.gtk_popover_popdown(gtk.cast(gtk.Popover, popover));
    const choice = choiceOf(data);
    const self = choice.self;
    const library = self.library orelse return;
    _ = self.runtime.libraryPairReleaseTrack(library, choice.release_id, choice.release_mbid, choice.track_id, choice.release_track_mbid) catch |err|
        return refused(self, err, "Could not pair that track");
    var buffer: [48]u8 = undefined;
    self.toast(strings.format(&buffer, "Paired with track {s}", .{choice.number[0..choice.number_len]}));
    matches.invalidate(self);
    submissions.autoStart(self);
}

fn unpairClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const choice = choiceOf(data);
    const self = choice.self;
    const library = self.library orelse return;
    self.runtime.libraryUnpairReleaseTrack(library, choice.release_id, choice.track_id) catch |err|
        return refused(self, err, "Could not unpair that track");
    self.toast("Unpaired");
    matches.invalidate(self);
}

fn positionText(buffer: []u8, alignment: *const liborca.ReleaseAlignment, disc: u32, position: u32) [:0]const u8 {
    if (alignment.medium_count > 1) return strings.format(buffer, "{d}-{d}", .{ disc, position });
    return strings.format(buffer, "{d}", .{position});
}

fn trackNumberText(buffer: []u8, track: liborca.AlignedTrack) [:0]const u8 {
    const number = track.track_number orelse return strings.terminated(buffer, "—");
    if (track.disc_number) |disc| if (disc > 1) return strings.format(buffer, "{d}-{d}", .{ disc, number });
    return strings.format(buffer, "{d}", .{number});
}

fn timeText(buffer: []u8, milliseconds: ?i64) [:0]const u8 {
    const ms = milliseconds orelse return strings.terminated(buffer, "—");
    return strings.formatMs(buffer, @intCast(@max(ms, 0)));
}

fn titleText(buffer: []u8, title: []const u8) [:0]const u8 {
    return strings.terminated(buffer, if (title.len != 0) title else "Untitled track");
}

fn writeTerm(writer: *std.Io.Writer, terms: *usize) void {
    writer.writeAll(if (terms.* == 0) separator else ", ") catch {};
    terms.* += 1;
}

fn suggestionText(buffer: []u8, alignment: *const liborca.ReleaseAlignment, row: liborca.ReleaseTrackPlacement) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writer.writeAll("Suggested") catch {};
    var terms: usize = 0;
    const evidence = row.evidence;
    if (evidence.title_equal) {
        writeTerm(&writer, &terms);
        writer.writeAll("same title") catch {};
    }
    if (evidence.length_close) if (evidence.length_delta_ms) |ms| {
        writeTerm(&writer, &terms);
        const seconds = (@abs(ms) + 500) / 1000;
        var time: [16]u8 = undefined;
        if (seconds == 0)
            writer.writeAll("same length") catch {}
        else
            writer.print("{s} {s}", .{ strings.formatMs(&time, seconds * 1000), if (ms > 0) "longer" else "shorter" }) catch {};
    };
    if (evidence.position_equal) {
        writeTerm(&writer, &terms);
        if (alignment.medium_count > 1)
            writer.print("disc {d} track {d}", .{ row.disc, row.position }) catch {}
        else
            writer.print("track {d}", .{row.position}) catch {};
    }
    return matches.finish(buffer, &writer);
}

fn timeLabel(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_widget_add_css_class(widget, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 1);
    gtk.gtk_widget_set_size_request(widget, delta_width, -1);
    return widget;
}

fn textButton(text: [*:0]const u8, tooltip: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(widget, "flat");
    gtk.gtk_widget_add_css_class(widget, "match-review-action");
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(widget, tooltip);
    return widget;
}

fn optionButton(number: [:0]const u8, title: [:0]const u8, time: [:0]const u8) *gtk.Widget {
    const position = cell(number.ptr, "match-review-number", number_width);
    gtk.gtk_widget_add_css_class(position, "numeric");
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    append(content, &.{ position, cell(title.ptr, "match-review-candidate", 240), timeLabel(time.ptr, "match-review-delta") });
    const option = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, option), content);
    gtk.gtk_widget_add_css_class(option, "flat");
    gtk.gtk_widget_add_css_class(option, "match-review-option");
    return option;
}

fn pairMenu(options: *gtk.Widget, count: usize, tooltip: [*:0]const u8) *gtk.Widget {
    const popover = gtk.gtk_popover_new();
    gtk.gtk_widget_add_css_class(popover, "match-review-pairs");
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), options);
    const menu = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_label(gtk.cast(gtk.MenuButton, menu), "Pair…");
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, menu), popover);
    gtk.gtk_widget_add_css_class(menu, "match-review-action");
    gtk.gtk_widget_set_valign(menu, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(menu, if (count == 0) "No unplaced track to pair" else tooltip);
    if (count == 0) gtk.gtk_widget_set_sensitive(menu, gtk.false_);
    return menu;
}

fn trackChoices(self: *App, alignment: *const liborca.ReleaseAlignment, row: liborca.ReleaseTrackPlacement) *gtk.Widget {
    const options = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    var count: usize = 0;
    var unplaced: Unplaced = .{ .alignment = alignment };
    var number: [16]u8 = undefined;
    var title: [512]u8 = undefined;
    var time: [16]u8 = undefined;
    while (unplaced.next()) |track| {
        const choice = newChoice(self, alignment, track.track_id, row) catch continue;
        const option = optionButton(trackNumberText(&number, track), titleText(&title, track.title), timeText(&time, track.duration_ms));
        attach(option, choice, gtk.callback(pairClicked));
        gtk.gtk_box_append(gtk.cast(gtk.Box, options), option);
        count += 1;
    }
    return pairMenu(options, count, "Pair one of your tracks with this release track");
}

fn releaseChoices(self: *App, alignment: *const liborca.ReleaseAlignment, track: liborca.AlignedTrack) *gtk.Widget {
    const options = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    var count: usize = 0;
    var number: [16]u8 = undefined;
    var title: [512]u8 = undefined;
    var time: [16]u8 = undefined;
    for (alignment.rows) |row| {
        if (row.status != .not_in_files and row.status != .suggested) continue;
        const choice = newChoice(self, alignment, track.track_id, row) catch continue;
        const length: ?i64 = if (row.length_ms) |ms| std.math.cast(i64, ms) else null;
        const option = optionButton(positionText(&number, alignment, row.disc, row.position), titleText(&title, row.title), timeText(&time, length));
        attach(option, choice, gtk.callback(pairClicked));
        gtk.gtk_box_append(gtk.cast(gtk.Box, options), option);
        count += 1;
    }
    return pairMenu(options, count, "Pair this track with one of the release's tracks");
}

fn statusCell(self: *App, alignment: *const liborca.ReleaseAlignment, row: liborca.ReleaseTrackPlacement) *gtk.Widget {
    const status = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(status, "match-review-status");
    gtk.gtk_widget_set_size_request(status, status_width, -1);
    switch (row.status) {
        .automatic => append(status, &.{ label("✓", "match-review-print"), label("Same recording", "match-review-local") }),
        .paired => {
            gtk.gtk_box_append(gtk.cast(gtk.Box, status), label("Paired", "match-review-local"));
            const track = row.track orelse return status;
            const choice = newChoice(self, alignment, track.track_id, row) catch return status;
            const unpair = textButton("Unpair", "Undo this pairing; the track gets back the values it replaced");
            attach(unpair, choice, gtk.callback(unpairClicked));
            gtk.gtk_box_append(gtk.cast(gtk.Box, status), unpair);
        },
        .suggested => {
            var buffer: [256]u8 = undefined;
            const text = suggestionText(&buffer, alignment, row);
            const chip = label(text.ptr, "chip");
            gtk.gtk_widget_add_css_class(chip, "match-review-chip");
            gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, chip), gtk.true_);
            gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, chip), gtk.WRAP_WORD);
            gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, chip), 22);
            gtk.gtk_widget_set_valign(chip, gtk.ALIGN_CENTER);
            gtk.gtk_box_append(gtk.cast(gtk.Box, status), chip);
            const track = row.track orelse return status;
            const choice = newChoice(self, alignment, track.track_id, row) catch return status;
            const confirm = textButton("Confirm", "Pair this track with the release track as suggested");
            attach(confirm, choice, gtk.callback(pairClicked));
            gtk.gtk_box_append(gtk.cast(gtk.Box, status), confirm);
        },
        .not_in_files => gtk.gtk_box_append(gtk.cast(gtk.Box, status), trackChoices(self, alignment, row)),
    }
    return status;
}

fn localArtist(self: *App, track_id: i64) ?[]const u8 {
    const diff = self.match_review.diff orelse return null;
    for (diff.tracks) |track| {
        if (track.track_id == track_id) return track.local_artist;
    }
    return null;
}

fn withCredit(title: *gtk.Widget, credit: []const u8, class: [*:0]const u8) *gtk.Widget {
    var buffer: [512]u8 = undefined;
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_add_css_class(column, "match-review-pair");
    gtk.gtk_widget_set_hexpand(column, gtk.true_);
    const line = cell(titleText(&buffer, credit).ptr, "match-review-credit", 0);
    gtk.gtk_widget_add_css_class(line, class);
    append(column, &.{ title, line });
    return column;
}

fn placementRow(self: *App, alignment: *const liborca.ReleaseAlignment, row: liborca.ReleaseTrackPlacement) *gtk.Widget {
    var buffer: [512]u8 = undefined;
    const number = cell(positionText(&buffer, alignment, row.disc, row.position).ptr, "match-review-number", number_width);
    gtk.gtk_widget_add_css_class(number, "numeric");
    var local = if (row.track) |track|
        cell(titleText(&buffer, track.title).ptr, if (std.mem.eql(u8, track.title, row.title)) "match-review-local" else "match-review-differs", 0)
    else
        cell("Not in your files", "match-review-missing", 0);
    var release = cell(titleText(&buffer, row.title).ptr, "match-review-candidate", 0);
    if (row.track) |track| if (localArtist(self, track.track_id)) |artist| if (row.artist_credit.len != 0 and !std.mem.eql(u8, artist, row.artist_credit)) {
        local = withCredit(local, artist, "match-review-differs");
        release = withCredit(release, row.artist_credit, "match-review-credit");
    };
    const time = timeLabel(delta(&buffer, if (row.track != null) row.evidence.length_delta_ms else null).ptr, "match-review-delta");
    const widget = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(widget, "match-review-track");
    append(widget, &.{ number, local, release, time, statusCell(self, alignment, row) });
    return widget;
}

fn unplacedRow(self: *App, alignment: *const liborca.ReleaseAlignment, track: liborca.AlignedTrack) *gtk.Widget {
    var buffer: [512]u8 = undefined;
    const number = cell(trackNumberText(&buffer, track).ptr, "match-review-number", number_width);
    gtk.gtk_widget_add_css_class(number, "numeric");
    const title = cell(titleText(&buffer, track.title).ptr, "match-review-local", 0);
    const time = timeLabel(timeText(&buffer, track.duration_ms).ptr, "match-review-delta");
    const status = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(status, "match-review-status");
    gtk.gtk_widget_set_size_request(status, status_width, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, status), releaseChoices(self, alignment, track));
    const widget = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(widget, "match-review-track");
    append(widget, &.{ number, title, time, status });
    return widget;
}

fn tracksHead(texts: []const [*:0]const u8, widths: []const c_int, time: [*:0]const u8) *gtk.Widget {
    const head = heading(texts, widths, "match-review-head");
    const time_label = timeLabel(time, "match-review-column");
    gtk.gtk_widget_remove_css_class(time_label, "numeric");
    const status = cell("Status", "match-review-column", status_width);
    gtk.gtk_widget_add_css_class(status, "match-review-status");
    append(head, &.{ time_label, status });
    return head;
}

fn tracksMessage(self: *App, tracks: *gtk.Box, text: [*:0]const u8, look_up: bool) void {
    const message = label(text, "match-review-note");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, message), gtk.true_);
    gtk.gtk_box_append(tracks, message);
    if (!look_up) return;
    const look = gtk.gtk_button_new_with_label("Look Up Release");
    gtk.gtk_widget_add_css_class(look, "match-again");
    gtk.gtk_widget_set_halign(look, gtk.ALIGN_START);
    gtk.gtk_widget_set_margin_top(look, 12);
    gtk.gtk_widget_set_tooltip_text(look, "Read this release's tracklist from MusicBrainz");
    _ = gtk.signalConnect(look, "clicked", gtk.callback(searchClicked), self);
    gtk.gtk_box_append(tracks, look);
}

fn showNote(self: *App, alignment: *const liborca.ReleaseAlignment) void {
    const note = self.match_review.tracks_note orelse return;
    var titles: [3][]const u8 = undefined;
    var count: usize = 0;
    var unplaced: Unplaced = .{ .alignment = alignment };
    while (unplaced.next()) |track| : (count += 1) {
        if (count < titles.len) titles[count] = track.title;
    }
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, note), @intFromBool(count != 0 and self.match_review.scope.bucket != .reviewed));
    if (count == 0) return;
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writer.writeAll("Left alone on Apply: ") catch {};
    matches.writeTitles(&writer, titles[0..@min(count, titles.len)], count) catch {};
    gtk.gtk_label_set_text(note, matches.finish(&buffer, &writer).ptr);
}

fn showTracks(self: *App) void {
    const review = &self.match_review;
    const tracks = review.tracks orelse return;
    clear(tracks);
    if (review.tracks_note) |note| gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, note), gtk.false_);
    var buffer: [64]u8 = undefined;
    const title: [:0]const u8 = switch (review.tracklist) {
        .aligned => |*alignment| strings.format(&buffer, "Tracks" ++ separator ++ "{d} of {d} placed", .{ Placement.of(alignment).placed, alignment.rows.len }),
        else => "Tracks",
    };
    if (review.tracks_title) |tracks_title| gtk.gtk_label_set_text(tracks_title, title.ptr);
    switch (review.tracklist) {
        .aligned => |*alignment| {
            gtk.gtk_box_append(tracks, tracksHead(&.{ "#", "Your file", "Release" }, &.{ number_width, 0, 0 }, "Δ time"));
            for (alignment.rows) |row| gtk.gtk_box_append(tracks, placementRow(self, alignment, row));
            if (alignment.not_on_release.len != 0) {
                const subheading = label("Not on this release" ++ separator ++ "kept as is", "match-review-heading");
                gtk.gtk_widget_add_css_class(subheading, "match-review-subheading");
                gtk.gtk_box_append(tracks, subheading);
                gtk.gtk_box_append(tracks, tracksHead(&.{ "#", "Your file" }, &.{ number_width, 0 }, "Time"));
                for (alignment.not_on_release) |track| gtk.gtk_box_append(tracks, unplacedRow(self, alignment, track));
            }
            showNote(self, alignment);
        },
        .not_read => tracksMessage(self, tracks, "Orca has not read this release's tracklist yet", true),
        .too_large => tracksMessage(self, tracks, "This release has more than 512 tracks, more than Orca can align or apply", false),
        .none => tracksMessage(self, tracks, "Orca could not read this release's tracklist", false),
    }
}

fn clear(box: *gtk.Box) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box))) |child| gtk.gtk_box_remove(box, child);
}

fn showMessage(self: *App, text: ?[*:0]const u8) void {
    const review = &self.match_review;
    if (review.content) |content| gtk.gtk_widget_set_visible(content, @intFromBool(text == null));
    const message = review.message orelse return;
    gtk.gtk_label_set_text(message, text orelse "");
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, message), @intFromBool(text != null));
}

fn showPosition(self: *App) void {
    const review = &self.match_review;
    const total = review.total;
    var buffer: [64]u8 = undefined;
    if (review.position) |position| gtk.gtk_label_set_text(position, if (total == 0)
        ""
    else
        strings.format(&buffer, "Review {d} of {d}", .{ review.index + 1, total }).ptr);
    if (review.previous) |previous| gtk.gtk_widget_set_sensitive(previous, @intFromBool(review.index > 0));
    if (review.next) |next| gtk.gtk_widget_set_sensitive(next, @intFromBool(review.index + 1 < total));
}

fn show(self: *App) void {
    const review = &self.match_review;
    if (!review.built) return;
    showPosition(self);
    const entry = current(self) orelse return showMessage(self, if (review.loader != null) "Comparing…" else "Nothing left to review.");
    const diff = review.diff orelse return showMessage(self, if (review.loader != null) "Comparing…" else "This album has no MusicBrainz candidate any more.");
    showMessage(self, null);
    var buffer: [512]u8 = undefined;

    const album = for (diff.fields) |each| {
        if (each.field == .album) break each.local;
    } else "";
    const title_text = strings.terminated(&buffer, if (album.len != 0) album else "Untitled album");
    if (review.title) |title| gtk.gtk_label_set_text(title, title_text.ptr);
    if (review.crumb) |crumb| gtk.gtk_label_set_text(crumb, title_text.ptr);
    if (review.cover) |cover| {
        art.setInitials(cover, album);
        art.show(self, cover, art.Key.release(entry.release_id, art.Size.atLeast(cover_pixels)));
    }
    if (review.summary) |summary| {
        const text = if (entry.confidence) |confidence|
            strings.format(&buffer, "Local album vs MusicBrainz candidate" ++ separator ++ "{d}% confidence" ++ separator, .{matches.percent(confidence)})
        else
            strings.terminated(&buffer, "Local album vs the release your tags name" ++ separator ++ "not yet read from MusicBrainz" ++ separator);
        gtk.gtk_label_set_text(summary, text.ptr);
    }

    var kept: std.EnumArray(Field, ?bool) = .initFill(null);
    if (review.shown_release == entry.release_id) for (std.enums.values(Field)) |field| {
        const check = review.checks.get(field) orelse continue;
        kept.set(field, gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, check)) != 0);
    };
    review.checks = .initFill(null);
    review.rows = .initFill(null);
    if (review.fields) |fields| {
        clear(fields);
        gtk.gtk_box_append(fields, heading(&.{ "Use", "Field", "Local", "MusicBrainz" }, &.{ 40, 118, 175, 0 }, "match-review-head"));
        for (diff.fields) |each| gtk.gtk_box_append(fields, fieldRow(self, diff, each, kept.get(each.field)));
    }
    review.shown_release = entry.release_id;
    showTracks(self);
    showChecked(self);
}

fn load(self: *App) void {
    const review = &self.match_review;
    const library = self.library orelse return;
    if (review.loader != null) return;
    const entry = current(self);
    const loader = self.allocator.create(Loader) catch return;
    loader.* = .{
        .runtime = self.runtime,
        .library = library,
        .waker = self.waker(),
        .scope = review.scope,
        .generation = review.generation,
        .index = review.index,
        .release_id = if (entry) |each| each.release_id else null,
    };
    loader.thread = std.Thread.spawn(.{}, Loader.run, .{loader}) catch {
        self.allocator.destroy(loader);
        return;
    };
    review.loader = loader;
    review.stale = false;
    const same = if (entry) |each| review.shown_release == each.release_id else review.window_stale;
    if (same and review.diff != null) return;
    review.forgetShown();
    show(self);
}

fn adoptWindow(self: *App, loader: *Loader) bool {
    const review = &self.match_review;
    review.entries.clearRetainingCapacity();
    review.window_offset = loader.window_offset;
    review.total = loader.total;
    review.index = loader.index;
    if (loader.window) |page| {
        review.entries.ensureTotalCapacity(self.allocator, page.items.len) catch {};
        for (page.items) |item| {
            const confidence = if (item.best) |best| best.confidence else 0;
            review.entries.append(self.allocator, .{ .release_id = item.release_id, .confidence = confidence, .from_tags = item.from_tags }) catch break;
        }
    }
    review.window_stale = false;
    if (review.total == 0 or review.entries.items.len == 0) {
        review.total = 0;
        return true;
    }
    const skip = review.skip_release orelse return true;
    review.skip_release = null;
    const entry = current(self) orelse return true;
    if (entry.release_id != skip or review.index + 1 >= review.total) return true;
    review.index += 1;
    return current(self) != null;
}

pub fn tick(self: *App) void {
    const review = &self.match_review;
    const loader = review.loader orelse return;
    if (!loader.finished.load(.acquire)) return;
    review.loader = null;
    defer loader.destroy(self.allocator);
    if (loader.generation != review.generation) return load(self);
    if (loader.windowed) {
        if (!adoptWindow(self, loader)) return load(self);
        if (review.total == 0) {
            show(self);
            if (self.current_page == .match_review) window.goTo(self, .matches);
            return;
        }
    }
    const entry = current(self);
    if (entry == null or loader.release_id == null or entry.?.release_id != loader.release_id.?) return load(self);
    review.freeShown();
    review.diff = loader.diff;
    loader.diff = null;
    review.tracklist = loader.tracklist;
    loader.tracklist = .none;
    show(self);
}

pub fn shutdown(self: *App) void {
    const review = &self.match_review;
    if (review.loader) |loader| loader.destroy(self.allocator);
    review.loader = null;
}

pub fn forgetLibrary(self: *App) void {
    shutdown(self);
    const review = &self.match_review;
    review.forgetShown();
    review.entries.clearRetainingCapacity();
    review.window_offset = 0;
    review.total = 0;
    review.index = 0;
    review.skip_release = null;
    review.stale = true;
    review.window_stale = false;
    review.generation +%= 1;
}

pub fn open(self: *App, scope: Scope, entries: []const Entry, total: u64, at: usize) void {
    const review = &self.match_review;
    review.entries.clearRetainingCapacity();
    review.entries.appendSlice(self.allocator, entries) catch return;
    review.scope = scope;
    review.window_offset = 0;
    review.total = @max(total, entries.len);
    review.index = @min(at, entries.len -| 1);
    review.window_stale = false;
    review.skip_release = null;
    review.generation +%= 1;
    review.forgetShown();
    review.stale = true;
    window.goTo(self, .match_review);
    load(self);
}

pub fn invalidate(self: *App) void {
    const review = &self.match_review;
    review.stale = true;
    review.window_stale = true;
    review.generation +%= 1;
    if (self.current_page == .match_review and review.loader == null) load(self);
}

pub fn shown(self: *App) void {
    const review = &self.match_review;
    if (review.stale or review.diff == null) load(self) else show(self);
}

fn step(self: *App, forward: bool) void {
    const review = &self.match_review;
    if (forward and review.index + 1 >= review.total) return;
    if (!forward and review.index == 0) return;
    review.index = if (forward) review.index + 1 else review.index - 1;
    review.forgetShown();
    load(self);
}

fn previousClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    step(state(data), false);
}

fn nextClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    step(state(data), true);
}

fn handled(self: *App, skip: bool) void {
    const review = &self.match_review;
    review.skip_release = if (skip) if (current(self)) |entry| entry.release_id else null else null;
    review.forgetShown();
    matches.invalidate(self);
    invalidate(self);
}

fn writeApplied(writer: *std.Io.Writer, outcome: liborca.ReleaseApplyOutcome, count: usize) std.Io.Writer.Error!void {
    if (!try matches.writeLeftAlone(writer, outcome)) {
        if (count == 1) try writer.writeAll("Applied 1 field") else try writer.print("Applied {d} fields", .{count});
        if (outcome.reviewed_release_id != null) try writer.writeAll(separator ++ "reviewed");
    }
    if (outcome.artist_ids_unknown) try writer.writeAll(separator ++ "album artist ID on the next lookup");
}

fn applyRelease(self: *App, library: liborca.LibraryHandle, entry: Entry) void {
    const fields = checkedFields(self);
    if (fields.count() == 0) return;
    const outcome = self.runtime.libraryApplyRelease(library, self.allocator, entry.release_id, fields) catch |err|
        return self.toast(if (err == error.NoReleaseTracklist) "Look up the release first" else "Could not apply the release");
    defer outcome.deinit();
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeApplied(&writer, outcome, fields.count()) catch {};
    self.toast(matches.finish(&buffer, &writer));
    matches.accepted(self);
    handled(self, true);
}

fn markReviewed(self: *App, library: liborca.LibraryHandle, entry: Entry) void {
    const release_mbid: ?[]const u8 = switch (self.match_review.tracklist) {
        .aligned => |alignment| alignment.release_mbid,
        else => null,
    };
    self.runtime.libraryMarkReleaseReviewed(library, entry.release_id, release_mbid) catch |err| {
        const message: [:0]const u8 = switch (err) {
            error.ReleaseNotPlaced => "Pair every track first",
            error.NoReleaseTracklist => "Look up the release first",
            else => "Could not mark the release as reviewed",
        };
        return self.toast(message);
    };
    self.toast("Marked as reviewed");
    matches.accepted(self);
    handled(self, true);
}

fn unmarkReviewed(self: *App, library: liborca.LibraryHandle, entry: Entry) void {
    self.runtime.libraryUnmarkReleaseReviewed(library, entry.release_id) catch |err| {
        if (err != error.ReleaseNotReviewed) return self.toast("Could not undo the review");
        return handled(self, false);
    };
    self.toast("Review undone");
    handled(self, false);
}

fn applyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const entry = current(self) orelse return;
    switch (self.match_review.primary) {
        .apply => applyRelease(self, library, entry),
        .mark => markReviewed(self, library, entry),
        .unmark => unmarkReviewed(self, library, entry),
    }
}

fn markClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const entry = current(self) orelse return;
    markReviewed(self, library, entry);
}

fn notThisClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const entry = current(self) orelse return;
    const diff = self.match_review.diff orelse return;
    self.runtime.libraryDismissReleaseCandidate(library, entry.release_id, diff.release_mbid) catch
        return self.toast("Could not dismiss the release");
    self.toast("Release dismissed");
    handled(self, false);
}

fn searchClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const entry = current(self) orelse return;
    jobs.startAlbumReidentification(self, entry.release_id);
}

fn linkClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const diff = self.match_review.diff orelse return;
    var buffer: [128]u8 = undefined;
    matches.openUrl(self, strings.printZ(&buffer, release_url ++ "{s}", .{diff.release_mbid}) catch return);
}

fn matchesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .matches);
}

fn buildTrail(self: *App) void {
    const parent = gtk.gtk_button_new_with_label("Matches");
    gtk.gtk_widget_add_css_class(parent, "flat");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    _ = gtk.signalConnect(parent, "clicked", gtk.callback(matchesClicked), self);
    const crumb_separator = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(crumb_separator, "breadcrumb-separator");
    const crumb = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(crumb, "breadcrumb-current");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, crumb), gtk.ELLIPSIZE_END);
    self.match_review.crumb = gtk.cast(gtk.Label, crumb);
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    append(crumbs, &.{ parent, crumb_separator, crumb });
    page_ui.addTrail(self, .match_review, crumbs);

    const previous = gtk.gtk_button_new_from_icon_name("orca-back-symbolic");
    gtk.gtk_widget_add_css_class(previous, "flat");
    gtk.gtk_widget_add_css_class(previous, "match-review-step");
    gtk.gtk_widget_set_tooltip_text(previous, "Previous album");
    _ = gtk.signalConnect(previous, "clicked", gtk.callback(previousClicked), self);
    const next = gtk.gtk_button_new_from_icon_name("orca-forward-symbolic");
    gtk.gtk_widget_add_css_class(next, "flat");
    gtk.gtk_widget_add_css_class(next, "match-review-step");
    gtk.gtk_widget_set_tooltip_text(next, "Next album");
    _ = gtk.signalConnect(next, "clicked", gtk.callback(nextClicked), self);
    const position = label("", "match-review-position");
    gtk.gtk_widget_add_css_class(position, "numeric");
    const end = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_set_valign(end, gtk.ALIGN_CENTER);
    append(end, &.{ previous, position, next });
    self.match_review.previous = previous;
    self.match_review.next = next;
    self.match_review.position = gtk.cast(gtk.Label, position);
    page_ui.addEnd(self, .match_review, end);
}

fn button(text: [*:0]const u8, class: [*:0]const u8, tooltip: [*:0]const u8, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const widget = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(widget, tooltip);
    _ = gtk.signalConnect(widget, "clicked", handler, self);
    return widget;
}

fn buildHeader(self: *App) *gtk.Widget {
    const review = &self.match_review;
    const cover = art.newCover(self, art.initialsPlaceholder(), cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "match-review-cover");
    gtk.gtk_widget_set_valign(cover, gtk.ALIGN_CENTER);
    review.cover = cover;

    const title = label("", "match-review-title");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    review.title = gtk.cast(gtk.Label, title);
    const summary = label("", "match-review-summary");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, summary), gtk.true_);
    review.summary = gtk.cast(gtk.Label, summary);
    const link_content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 3);
    const link_icon = gtk.gtk_image_new_from_icon_name("orca-external-link-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, link_icon), 12);
    append(link_content, &.{ gtk.gtk_label_new("Open release"), link_icon });
    const link = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, link), link_content);
    gtk.gtk_widget_add_css_class(link, "flat");
    gtk.gtk_widget_add_css_class(link, "match-review-link");
    gtk.gtk_widget_set_tooltip_text(link, "Open this release on MusicBrainz");
    _ = gtk.signalConnect(link, "clicked", gtk.callback(linkClicked), self);
    review.link = link;
    const subtitle = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    append(subtitle, &.{ summary, link });
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    append(text, &.{ title, subtitle });

    review.not_this = button("Not This Release", "match-again", "Dismiss this candidate; the album moves to Unmatched", gtk.callback(notThisClicked), self);
    review.search = button("Search MusicBrainz…", "match-again", "Search MusicBrainz for this album again, ignoring its IDs", gtk.callback(searchClicked), self);
    review.mark = button("Mark as Reviewed", "match-again", "Every track is placed: keep this album's values as they are and take it off the list without writing", gtk.callback(markClicked), self);
    gtk.gtk_widget_set_visible(review.mark.?, gtk.false_);
    review.apply = button("Apply 0 Fields to Orca", "match-review-apply", apply_tooltip, gtk.callback(applyClicked), self);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_valign(actions, gtk.ALIGN_CENTER);
    append(actions, &.{ review.not_this.?, review.search.?, review.mark.?, review.apply.? });

    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 20);
    gtk.gtk_widget_add_css_class(header, "match-review-header");
    append(header, &.{ cover, text, actions });
    return header;
}

fn section(title: *gtk.Widget, body: *gtk.Widget, width: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_add_css_class(box, "match-review-section");
    gtk.gtk_widget_set_size_request(box, width, -1);
    gtk.gtk_widget_set_hexpand(box, gtk.true_);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_START);
    append(box, &.{ title, body });
    return box;
}

fn scrollerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.match_review.scroller = null;
    self.match_review.built = false;
    self.match_review.checks = .initFill(null);
    self.match_review.rows = .initFill(null);
}

pub fn build(self: *App) *gtk.Widget {
    const review = &self.match_review;
    buildTrail(self);

    const fields = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(fields, "match-review-table");
    review.fields = gtk.cast(gtk.Box, fields);
    const tracks = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tracks, "match-review-table");
    review.tracks = gtk.cast(gtk.Box, tracks);
    const tracks_title = label("Tracks", "match-review-heading");
    review.tracks_title = gtk.cast(gtk.Label, tracks_title);
    const tracks_note = label("", "match-review-note");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, tracks_note), gtk.true_);
    gtk.gtk_widget_set_visible(tracks_note, gtk.false_);
    review.tracks_note = gtk.cast(gtk.Label, tracks_note);
    const tracks_body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    append(tracks_body, &.{ tracks_note, tracks });

    const sections = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 28);
    append(sections, &.{
        section(label("Choose what to adopt", "match-review-heading"), fields, 480),
        section(tracks_title, tracks_body, 600),
    });

    const message = label("", "match-review-message");
    review.message = gtk.cast(gtk.Label, message);
    gtk.gtk_widget_set_visible(message, gtk.false_);

    const header = buildHeader(self);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(content, &.{ header, sections });
    review.content = content;

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "match-review-page");
    gtk.gtk_widget_set_hexpand(column, gtk.true_);
    append(column, &.{ content, message });

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);
    review.scroller = gtk.cast(gtk.ScrolledWindow, scroller);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(scrollerDestroyed), self);
    review.built = true;
    const bin = page_ui.breakpointBin(scroller);
    page_ui.stackBelow(bin, "max-width: 1180px", &.{sections}, &.{});
    page_ui.stackBelow(bin, "max-width: 750px", &.{ sections, header }, &.{});
    return bin;
}
