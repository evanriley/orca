//! The Matches page: how each album lines up with its best MusicBrainz
//! release, in tabs by confidence, with why, and the album corrections still
//! to review. liborca weighs the candidates on a loader thread; this only
//! words them.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const jobs = @import("jobs.zig");
const details = @import("details.zig");
const health = @import("health.zig");
const window = @import("window.zig");
const secret = @import("secret.zig");
const tags = @import("tags.zig");
const page_ui = @import("page.zig");
const match_review = @import("match_review.zig");

const App = app.App;

pub const Bucket = liborca.ReleaseMatchBucket;
const Field = liborca.ReleaseField;

const separator = " · ";
const recording_url = "https://musicbrainz.org/recording/";
const list_limit: u32 = 100;
const content_width: c_int = 1080;
const cover_pixels: c_int = 48;

pub const Detail = struct {
    evidence: ?liborca.MatchEvidence = null,
    diff: ?liborca.ReleaseMatchDiff = null,

    fn deinit(self: *Detail) void {
        if (self.diff) |*diff| diff.deinit();
        self.* = .{};
    }
};

const Loader = struct {
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    waker: liborca.HostWaker,
    bucket: Bucket,
    confident_at: f32,
    filter: Filter,
    with_page: bool,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    counts: ?liborca.ReleaseMatchCounts = null,
    filtered_counts: ?liborca.ReleaseMatchCounts = null,
    groups: ?liborca.CorrectionGroupPage = null,
    page: ?liborca.ReleaseMatchPage = null,
    details: []Detail = &.{},

    fn run(self: *Loader) void {
        const filter = self.filter.text();
        self.counts = self.runtime.libraryReleaseMatchCounts(self.library, self.confident_at, null) catch null;
        if (filter != null) self.filtered_counts = self.runtime.libraryReleaseMatchCounts(self.library, self.confident_at, filter) catch null;
        self.groups = self.runtime.libraryCorrectionGroups(self.library, std.heap.smp_allocator, app.page_size, 0) catch null;
        if (self.with_page) {
            self.page = self.runtime.libraryReleaseMatchPage(self.library, std.heap.smp_allocator, self.bucket, self.confident_at, filter, list_limit, 0) catch null;
            if (self.page) |page| self.readDetails(page.items);
        }
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn readDetails(self: *Loader, items: []const liborca.ReleaseMatchItem) void {
        const read = std.heap.smp_allocator.alloc(Detail, items.len) catch return;
        for (items, read) |item, *detail| {
            detail.* = .{};
            const best = item.best orelse continue;
            detail.evidence = self.runtime.libraryReleaseMatchEvidence(self.library, item.release_id, best.release_mbid) catch null;
            detail.diff = self.runtime.libraryReleaseMatchDiff(self.library, std.heap.smp_allocator, item.release_id, best.release_mbid) catch null;
        }
        self.details = read;
    }

    fn destroy(self: *Loader, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.groups) |*groups| groups.deinit();
        if (self.page) |*page| page.deinit();
        freeDetails(self.details);
        allocator.destroy(self);
    }
};

fn freeDetails(read: []Detail) void {
    for (read) |*detail| detail.deinit();
    if (read.len != 0) std.heap.smp_allocator.free(read);
}

const Want = enum { none, counts, page };

pub const Filter = struct {
    buffer: [liborca.max_search_text]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Filter) ?[]const u8 {
        return if (self.len == 0) null else self.buffer[0..self.len];
    }

    fn set(self: *Filter, value: []const u8) void {
        self.len = @min(value.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], value[0..self.len]);
    }

    fn eql(self: *const Filter, other: *const Filter) bool {
        return std.mem.eql(u8, self.buffer[0..self.len], other.buffer[0..other.len]);
    }
};

const Tab = struct {
    button: ?*gtk.Widget = null,
    count: ?*gtk.Label = null,
};

pub const State = struct {
    built: bool = false,
    stale: bool = true,
    counts_stale: bool = true,
    counts: ?liborca.ReleaseMatchCounts = null,
    filter: Filter = .{},
    filtered_counts: ?liborca.ReleaseMatchCounts = null,
    group_count: u64 = 0,
    bucket: Bucket = .needs_review,
    page: ?liborca.ReleaseMatchPage = null,
    details: []Detail = &.{},
    expanded: ?i64 = null,
    loader: ?*Loader = null,
    wanted: Want = .none,
    tabs: std.EnumArray(Bucket, Tab) = .initFill(.{}),
    list: ?*gtk.Box = null,
    empty: ?*gtk.Label = null,
    note: ?*gtk.Label = null,
    corrections: ?*gtk.ListBox = null,
    corrections_box: ?*gtk.Widget = null,
    scroller: ?*gtk.ScrolledWindow = null,
    content: ?*gtk.Widget = null,
    search: ?*gtk.Widget = null,

    pub fn deinit(self: *State) void {
        if (self.page) |*page| page.deinit();
        self.page = null;
        freeDetails(self.details);
        self.details = &.{};
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

/// Confidence as a whole percentage, rounded down so a match shown at P% is
/// one accepted at P%.
pub fn percent(confidence: f32) u32 {
    return @intFromFloat(@floor(std.math.clamp(confidence, 0, 1) * 100));
}

pub fn thresholdFraction(self: *const App) f32 {
    return @as(f32, @floatFromInt(self.match_threshold_percent)) / 100;
}

/// "Title — Artist credit".
pub fn writeHeading(writer: *std.Io.Writer, proposal: liborca.MatchProposal) std.Io.Writer.Error!void {
    try writer.writeAll(if (proposal.title.len != 0) proposal.title else "Unknown title");
    if (proposal.artist.len != 0) try writer.print(" — {s}", .{proposal.artist});
}

fn sourceName(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "musicbrainz")) return "MusicBrainz";
    if (std.mem.eql(u8, provider, "acoustid")) return "AcoustID";
    if (std.mem.eql(u8, provider, "musicbrainz+acoustid")) return "MusicBrainz + AcoustID";
    return provider;
}

pub fn writeRelease(writer: *std.Io.Writer, proposal: liborca.MatchProposal) std.Io.Writer.Error!void {
    const album = proposal.release_title orelse proposal.album;
    if (album.len != 0) try writer.print(separator ++ "{s}", .{album});
    if (proposal.release_date) |date| try writer.print(separator ++ "{s}", .{date});
}

pub fn writeSource(writer: *std.Io.Writer, proposal: liborca.MatchProposal) std.Io.Writer.Error!void {
    try writer.writeAll(sourceName(proposal.provider));
    if (proposal.acoustid_score) |score| try writer.print(separator ++ "fingerprint {d}%", .{percent(score)});
}

fn finish(buffer: []u8, writer: *const std.Io.Writer) [:0]const u8 {
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn refused(self: *App, err: anyerror, fallback: [:0]const u8) void {
    if (err == error.StaleIdentificationProposal or err == error.UnknownIdentificationProposal) {
        self.toast("That match was already handled");
        return changed(self);
    }
    if (err == error.ProposalInGroup) {
        self.toast("Accept or dismiss it with its album in Matches");
        return changed(self);
    }
    self.toast(fallback);
}

fn changed(self: *App) void {
    invalidate(self);
    details.invalidate(self);
    self.requestTick();
}

/// An accept can regroup albums under new Release ids, so every page that
/// shows one is rebuilt.
pub fn accepted(self: *App) void {
    jobs.reloadLibraryViews(self);
    tags.popPages(self);
    details.invalidate(self);
    self.requestTick();
}

pub fn accept(self: *App, track_id: i64, proposal_id: i64) void {
    _ = track_id;
    const library = self.library orelse return;
    const acceptance = self.runtime.libraryAcceptMatch(library, proposal_id) catch |err|
        return refused(self, err, "Could not save that match");
    self.toast(if (acceptance.values_written == 0) "Kept your values" else "Match saved");
    accepted(self);
}

pub fn dismiss(self: *App, track_id: i64, proposal_id: i64) void {
    _ = track_id;
    const library = self.library orelse return;
    self.runtime.libraryDismissMatch(library, proposal_id) catch |err|
        return refused(self, err, "Could not dismiss that match");
    changed(self);
}

fn launched(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_uri_launcher_launch_finish(gtk.cast(gtk.UriLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open MusicBrainz");
}

pub fn openUrl(self: *App, url: [:0]const u8) void {
    const launcher = gtk.gtk_uri_launcher_new(url.ptr);
    gtk.gtk_uri_launcher_launch(launcher, self.window, null, launched, self);
    gtk.g_object_unref(launcher);
}

pub fn openRecording(self: *App, recording_mbid: []const u8) void {
    var buffer: [128]u8 = undefined;
    openUrl(self, strings.printZ(&buffer, recording_url ++ "{s}", .{recording_mbid}) catch return);
}

fn freeText(text: ?*anyopaque) callconv(.c) void {
    gtk.g_free(text);
}

pub fn linkButton(recording_mbid: []const u8) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label("MusicBrainz");
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, "Open this recording on MusicBrainz");
    setRecording(button, recording_mbid);
    return button;
}

pub fn setRecording(button: *gtk.Widget, recording_mbid: []const u8) void {
    gtk.g_object_set_data_full(button, "orca-recording", gtk.g_strndup(recording_mbid.ptr, recording_mbid.len), freeText);
}

pub fn recordingOf(button: ?*anyopaque) ?[]const u8 {
    const text: [*:0]const u8 = @ptrCast(gtk.g_object_get_data(button.?, "orca-recording") orelse return null);
    return std.mem.span(text);
}

pub fn showAcoustIdKey(self: *App, presence: secret.Presence) void {
    self.acoustid_key_stored = presence == .stored;
}

fn groupOf(button: ?*anyopaque) ?i64 {
    const stored = gtk.g_object_get_data(button.?, "orca-group") orelse return null;
    return @intCast(@intFromPtr(stored));
}

fn groupRefused(self: *App, err: anyerror, fallback: [:0]const u8) void {
    if (err == error.StaleCorrectionGroup or err == error.UnknownCorrectionGroup) {
        self.toast("That correction was already handled");
        return changed(self);
    }
    self.toast(fallback);
}

/// The Tracks a correction group would change, for the tag write offered
/// once it is accepted.
fn groupTracks(self: *App, library: liborca.LibraryHandle, group_id: i64, tracks: *std.ArrayList(i64)) void {
    var page = self.runtime.libraryCorrectionGroups(library, self.allocator, app.page_size, 0) catch return;
    defer page.deinit();
    for (page.items) |group| {
        if (group.group_id != group_id) continue;
        for (group.proposals) |member| if (member.track_id) |id| tracks.append(self.allocator, id) catch return;
    }
}

fn acceptGroupClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const group_id = groupOf(button) orelse return;
    var tracks: std.ArrayList(i64) = .empty;
    defer tracks.deinit(self.allocator);
    groupTracks(self, library, group_id, &tracks);
    const acceptance = self.runtime.libraryAcceptCorrectionGroup(library, group_id) catch |err|
        return groupRefused(self, err, "Could not save the correction");
    var buffer: [64]u8 = undefined;
    self.toast(if (acceptance.accepted == 1)
        "Corrected 1 track"
    else
        strings.format(&buffer, "Corrected {f} tracks", .{strings.grouped(acceptance.accepted)}));
    accepted(self);
    if (acceptance.values_written != 0 and tracks.items.len != 0) tags.confirmWrite(self, tracks.items);
}

fn dismissGroupClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    self.runtime.libraryDismissCorrectionGroup(library, groupOf(button) orelse return) catch |err|
        return groupRefused(self, err, "Could not dismiss the correction");
    self.toast("Correction dismissed");
    changed(self);
}

fn widen(number: ?u32) ?i64 {
    return if (number) |value| value else null;
}

fn writePosition(writer: *std.Io.Writer, disc_number: ?i64, track_number: ?i64) std.Io.Writer.Error!void {
    const track = track_number orelse return;
    if (disc_number) |disc| if (disc > 1) return writer.print(" ({d}-{d})", .{ disc, track });
    try writer.print(" ({d})", .{track});
}

fn correctionMemberRow(member: liborca.CorrectionGroupMember) *gtk.Widget {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writer.writeAll(if (member.title.len != 0) member.title else "Unknown title") catch {};
    writePosition(&writer, member.disc_number, member.track_number) catch {};
    writer.print(" → {s}", .{if (member.proposed_title.len != 0) member.proposed_title else "Unknown title"}) catch {};
    writePosition(&writer, widen(member.proposed_disc_number), widen(member.proposed_track_number)) catch {};
    const text = finish(&buffer, &writer);
    const row = adw.adw_action_row_new();
    adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, row), gtk.false_);
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), text.ptr);
    adw.adw_action_row_set_title_lines(gtk.cast(adw.ActionRow, row), 2);
    var tooltip_buffer: [160]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(row, strings.format(&tooltip_buffer, "{s}\nReplaces {s}", .{
        member.recording_mbid,
        member.corrects orelse "nothing",
    }).ptr);
    return row;
}

fn groupButton(text: [*:0]const u8, group_id: i64, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const widget = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    gtk.g_object_set_data(widget, "orca-group", @ptrFromInt(@as(usize, @intCast(group_id))));
    _ = gtk.signalConnect(widget, "clicked", handler, self);
    return widget;
}

fn correctionGroupRow(self: *App, group: liborca.CorrectionGroup) *gtk.Widget {
    const row = adw.adw_expander_row_new();
    adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, row), gtk.false_);
    var title_buffer: [512]u8 = undefined;
    const title = strings.format(&title_buffer, "{s}{s}{s}", .{
        if (group.album.len != 0) group.album else "Unknown album",
        if (group.album_artist.len != 0) " — " else "",
        group.album_artist,
    });
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), title.ptr);
    var subtitle_buffer: [128]u8 = undefined;
    const count = group.proposals.len;
    adw.adw_expander_row_set_subtitle(gtk.cast(adw.ExpanderRow, row), if (count == 1)
        "1 track is identified as another track of this album"
    else
        strings.format(&subtitle_buffer, "{d} tracks are identified as other tracks of this album", .{count}).ptr);
    adw.adw_expander_row_set_title_lines(gtk.cast(adw.ExpanderRow, row), 1);
    const accept_button = groupButton("Accept All", group.group_id, gtk.callback(acceptGroupClicked), self);
    gtk.gtk_widget_set_tooltip_text(accept_button, "Record every track's corrected recording, title and position");
    gtk.gtk_widget_add_css_class(accept_button, "suggested-action");
    const dismiss_button = groupButton("Dismiss All", group.group_id, gtk.callback(dismissGroupClicked), self);
    adw.adw_expander_row_add_suffix(gtk.cast(adw.ExpanderRow, row), accept_button);
    adw.adw_expander_row_add_suffix(gtk.cast(adw.ExpanderRow, row), dismiss_button);
    for (group.proposals) |member|
        adw.adw_expander_row_add_row(gtk.cast(adw.ExpanderRow, row), correctionMemberRow(member));
    return row;
}

fn showCorrections(self: *App, groups: ?liborca.CorrectionGroupPage) void {
    const matches = &self.matches;
    const list = matches.corrections orelse return;
    gtk.gtk_list_box_remove_all(list);
    const listed = if (groups) |page| page.items else &.{};
    for (listed) |group| gtk.gtk_list_box_append(list, correctionGroupRow(self, group));
    if (matches.corrections_box) |box| gtk.gtk_widget_set_visible(box, @intFromBool(listed.len != 0));
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    return widget;
}

fn cell(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, widget), 1);
    gtk.gtk_widget_set_hexpand(widget, gtk.true_);
    return widget;
}

fn append(box: *gtk.Widget, children: []const *gtk.Widget) void {
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, box), child);
}

pub fn iconLabelButton(icon: [*:0]const u8, text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const image = gtk.gtk_image_new_from_icon_name(icon);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(content, gtk.ALIGN_CENTER);
    append(content, &.{ image, gtk.gtk_label_new(text) });
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, class);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}

const Row = struct {
    self: *App,
    release_id: i64,
    artist: ?*gtk.Label = null,
    candidate: ?*gtk.Label = null,
    evidence: ?*gtk.Revealer = null,
};

fn rowOf(data: ?*anyopaque) *Row {
    return @ptrCast(@alignCast(data.?));
}

fn freeRow(data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    row.self.allocator.destroy(row);
}

const Shown = struct {
    item: liborca.ReleaseMatchItem,
    detail: ?*const Detail,
};

fn shownItem(self: *App, release_id: i64) ?Shown {
    const page = self.matches.page orelse return null;
    for (page.items, 0..) |item, index| {
        if (item.release_id != release_id) continue;
        return .{ .item = item, .detail = if (index < self.matches.details.len) &self.matches.details[index] else null };
    }
    return null;
}

fn fieldDiff(diff: liborca.ReleaseMatchDiff, field: Field) ?liborca.ReleaseFieldDiff {
    for (diff.fields) |each| if (each.field == field) return each;
    return null;
}

fn year(date: []const u8) []const u8 {
    return date[0..@min(date.len, 4)];
}

fn artistText(buffer: []u8, item: liborca.ReleaseMatchItem, open: bool) [:0]const u8 {
    const artist = if (item.artist.len != 0) item.artist else "Unknown artist";
    if (!open) return strings.terminated(buffer, artist);
    return strings.format(buffer, "{s}" ++ separator ++ "{d} local {s}", .{ artist, item.track_count, if (item.track_count == 1) "track" else "tracks" });
}

fn candidateText(buffer: []u8, item: liborca.ReleaseMatchItem, open: bool) [:0]const u8 {
    const best = item.best orelse return strings.terminated(buffer, "No candidate");
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writer.writeAll(if (best.title.len != 0) best.title else "Untitled release") catch {};
    if (best.date) |date| if (date.len != 0) writer.print(separator ++ "{s}", .{if (open) date else year(date)}) catch {};
    if (open) if (best.track_count) |count| writer.print(separator ++ "{d} {s}", .{ count, if (count == 1) "track" else "tracks" }) catch {};
    return finish(buffer, &writer);
}

fn showOpen(row: *Row, open: bool) void {
    const listed = shownItem(row.self, row.release_id) orelse return;
    var buffer: [512]u8 = undefined;
    if (row.artist) |artist| gtk.gtk_label_set_text(artist, artistText(&buffer, listed.item, open).ptr);
    if (row.candidate) |candidate| gtk.gtk_label_set_text(candidate, candidateText(&buffer, listed.item, open).ptr);
    if (row.evidence) |evidence| gtk.gtk_revealer_set_reveal_child(evidence, @intFromBool(open));
}

fn toggleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const self = row.self;
    const evidence = row.evidence orelse return;
    const open = gtk.gtk_revealer_get_reveal_child(evidence) == 0;
    if (open) collapseOthers(self, row.release_id);
    self.matches.expanded = if (open) row.release_id else null;
    showOpen(row, open);
}

fn collapseOthers(self: *App, release_id: i64) void {
    const list = self.matches.list orelse return;
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list));
    while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
        const data = gtk.g_object_get_data(widget, "orca-match-row") orelse continue;
        const row = rowOf(data);
        if (row.release_id != release_id) showOpen(row, false);
    }
}

fn acceptedFields(diff: ?liborca.ReleaseMatchDiff) liborca.ReleaseFieldSet {
    var fields: liborca.ReleaseFieldSet = .initOne(.release_id);
    const read = diff orelse return fields;
    for ([_]Field{ .album, .album_artist, .release_date }) |field| {
        const each = fieldDiff(read, field) orelse continue;
        if (each.differs) fields.insert(field);
    }
    return fields;
}

fn acceptClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const self = row.self;
    const library = self.library orelse return;
    const listed = shownItem(self, row.release_id) orelse return;
    const diff = if (listed.detail) |detail| detail.diff else null;
    const written = self.runtime.libraryApplyMatchedRelease(library, row.release_id, acceptedFields(diff)) catch
        return self.toast("Could not accept that release");
    if (written == 0) return self.toast("Every track must be on the release first: review it to see which are not");
    self.toast("Release accepted");
    accepted(self);
}

fn reviewClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const self = row.self;
    const page = self.matches.page orelse return;
    var entries: std.ArrayList(match_review.Entry) = .empty;
    defer entries.deinit(self.allocator);
    var at: usize = 0;
    for (page.items) |item| {
        if (item.release_id == row.release_id) at = entries.items.len;
        const confidence = if (item.best) |best| best.confidence else 0;
        entries.append(self.allocator, .{ .release_id = item.release_id, .confidence = confidence }) catch return;
    }
    const bucket = self.matches.bucket;
    const total: u64 = if (tabCounts(self)) |counts| switch (bucket) {
        .confident => counts.confident,
        .needs_review => counts.needs_review,
        .unmatched => counts.unmatched,
    } else entries.items.len;
    match_review.open(self, .{ .bucket = bucket, .confident_at = thresholdFraction(self), .filter = self.matches.filter }, entries.items, total, at);
}

fn searchClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    jobs.startAlbumReidentification(row.self, row.release_id);
}

fn actionButton(text: [*:0]const u8, tooltip: [*:0]const u8, handler: gtk.GCallback, row: *Row) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(button, "match-button");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    _ = gtk.signalConnect(button, "clicked", handler, row);
    return button;
}

fn evidenceLine(agrees: bool, name: [*:0]const u8, value: [:0]const u8) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name(if (agrees) "orca-check-symbolic" else "orca-alert-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 15);
    gtk.gtk_widget_add_css_class(icon, if (agrees) "match-agrees" else "match-differs");
    const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(line, "match-evidence-line");
    const value_label = label(value.ptr, "match-evidence-value");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, value_label), gtk.ELLIPSIZE_END);
    append(line, &.{ icon, label(name, "match-evidence-name"), value_label });
    return line;
}

fn diffValues(buffer: []u8, diff: ?liborca.ReleaseMatchDiff, field: Field, fallback: []const u8) [:0]const u8 {
    const read = diff orelse return strings.terminated(buffer, fallback);
    const each = fieldDiff(read, field) orelse return strings.terminated(buffer, fallback);
    if (!each.differs) return strings.terminated(buffer, if (each.local.len != 0) each.local else fallback);
    return strings.format(buffer, "{s} vs {s}", .{
        if (each.local.len != 0) each.local else "none",
        each.candidate,
    });
}

fn explanation(buffer: []u8, evidence: liborca.MatchEvidence, diff: ?liborca.ReleaseMatchDiff) [:0]const u8 {
    const tracks_agree = evidence.tracks != 0 and evidence.fingerprints_matched == evidence.tracks and evidence.durations_within_1s;
    if (tracks_agree and evidence.artist_agrees and evidence.title_agrees and !evidence.date_agrees) {
        const dates = if (diff) |read| fieldDiff(read, .release_date) else null;
        const later = if (dates) |each| std.mem.order(u8, each.candidate, each.local) == .gt else true;
        return strings.format(
            buffer,
            "Tracks, durations and fingerprints agree, but the candidate is {s} edition with a different date. Review lets you take its IDs without its date.",
            .{if (later) "a later" else "an earlier"},
        );
    }
    return strings.terminated(buffer, evidence.note.slice());
}

fn evidenceView(item: liborca.ReleaseMatchItem, detail: ?*const Detail) ?*gtk.Widget {
    const read = detail orelse return null;
    const evidence = read.evidence orelse return null;
    const lines = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(lines, "match-evidence-list");
    var buffer: [512]u8 = undefined;
    const fingerprints = evidence.tracks != 0 and evidence.fingerprints_matched == evidence.tracks;
    gtk.gtk_box_append(gtk.cast(gtk.Box, lines), evidenceLine(fingerprints, "AcoustID fingerprints", strings.format(&buffer, "{d} of {d} tracks", .{ evidence.fingerprints_matched, evidence.tracks })));
    gtk.gtk_box_append(gtk.cast(gtk.Box, lines), evidenceLine(evidence.durations_within_1s, "Track durations", if (evidence.durations_within_1s) "within 1 s" else "not all within 1 s"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, lines), evidenceLine(evidence.artist_agrees, if (evidence.artist_agrees) "Artist" else "Artist differs", diffValues(&buffer, read.diff, .album_artist, item.artist)));
    gtk.gtk_box_append(gtk.cast(gtk.Box, lines), evidenceLine(evidence.title_agrees, if (evidence.title_agrees) "Album title" else "Album title differs", diffValues(&buffer, read.diff, .album, item.title)));
    gtk.gtk_box_append(gtk.cast(gtk.Box, lines), evidenceLine(evidence.date_agrees, if (evidence.date_agrees) "Release date" else "Release date differs", diffValues(&buffer, read.diff, .release_date, "unknown")));

    const sentence = label(explanation(&buffer, evidence, read.diff).ptr, "match-explanation");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, sentence), gtk.true_);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, sentence), 54);
    gtk.gtk_widget_set_size_request(sentence, 360, -1);
    gtk.gtk_widget_set_valign(sentence, gtk.ALIGN_START);
    const view = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 40);
    gtk.gtk_widget_add_css_class(view, "match-evidence");
    append(view, &.{ lines, sentence });
    return view;
}

fn matchRow(self: *App, item: liborca.ReleaseMatchItem, detail: ?*const Detail) ?*gtk.Widget {
    const row = self.allocator.create(Row) catch return null;
    row.* = .{ .self = self, .release_id = item.release_id };
    const open = self.matches.expanded == item.release_id;
    var buffer: [512]u8 = undefined;

    const cover = art.newCover(self, art.initialsPlaceholder(), cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "match-cover");
    art.setInitials(cover, item.title);
    art.show(self, cover, art.Key.release(item.release_id, art.Size.atLeast(cover_pixels)));

    const title = cell(strings.terminated(&buffer, if (item.title.len != 0) item.title else "Untitled album").ptr, "match-title");
    const artist = cell(artistText(&buffer, item, open).ptr, "match-artist");
    row.artist = gtk.cast(gtk.Label, artist);
    const album = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_valign(album, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(album, gtk.true_);
    append(album, &.{ title, artist });

    const candidate = cell(candidateText(&buffer, item, open).ptr, if (item.best == null) "match-candidate-none" else "match-candidate");
    row.candidate = gtk.cast(gtk.Label, candidate);
    const best = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_valign(best, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(best, gtk.true_);
    append(best, &.{ cell("Best candidate", "match-caption"), candidate });

    const confidence = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 5);
    gtk.gtk_widget_set_size_request(confidence, 150, -1);
    gtk.gtk_widget_set_valign(confidence, gtk.ALIGN_CENTER);
    if (item.best) |candidate_release| {
        const value = label(strings.format(&buffer, "{d}% confidence", .{percent(candidate_release.confidence)}).ptr, "match-confidence");
        gtk.gtk_widget_add_css_class(value, "numeric");
        const bar = gtk.gtk_progress_bar_new();
        gtk.gtk_widget_add_css_class(bar, "match-bar");
        gtk.gtk_progress_bar_set_fraction(gtk.cast(gtk.ProgressBar, bar), std.math.clamp(candidate_release.confidence, 0, 1));
        append(confidence, &.{ value, bar });
    }

    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 18);
    append(content, &.{ cover, album, best, confidence });
    const toggle = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, toggle), content);
    gtk.gtk_widget_add_css_class(toggle, "flat");
    gtk.gtk_widget_add_css_class(toggle, "match-toggle");
    gtk.gtk_widget_set_hexpand(toggle, gtk.true_);
    gtk.gtk_widget_set_tooltip_text(toggle, "Show why");
    _ = gtk.signalConnect(toggle, "clicked", gtk.callback(toggleClicked), row);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_valign(actions, gtk.ALIGN_CENTER);
    if (item.best != null) {
        append(actions, &.{
            actionButton("Accept", "Take this release's IDs, and its album, album artist and date where they differ", gtk.callback(acceptClicked), row),
            actionButton("Review", "Choose what to take from this release", gtk.callback(reviewClicked), row),
        });
    } else {
        gtk.gtk_box_append(gtk.cast(gtk.Box, actions), actionButton("Search", "Search MusicBrainz for this album again", gtk.callback(searchClicked), row));
    }

    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 18);
    gtk.gtk_widget_add_css_class(header, "match-header");
    append(header, &.{ toggle, actions });

    const widget = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(widget, "match-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, widget), header);
    if (evidenceView(item, detail)) |view| {
        const revealer = gtk.gtk_revealer_new();
        gtk.gtk_revealer_set_child(gtk.cast(gtk.Revealer, revealer), view);
        gtk.gtk_revealer_set_reveal_child(gtk.cast(gtk.Revealer, revealer), @intFromBool(open));
        row.evidence = gtk.cast(gtk.Revealer, revealer);
        gtk.gtk_box_append(gtk.cast(gtk.Box, widget), revealer);
    } else {
        gtk.gtk_widget_set_can_target(toggle, gtk.false_);
        gtk.gtk_widget_set_focusable(toggle, gtk.false_);
    }
    gtk.g_object_set_data_full(widget, "orca-match-row", row, freeRow);
    return widget;
}

fn tabClicked(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const button: *gtk.Widget = @ptrCast(@alignCast(widget.?));
    if (gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) == 0) return;
    for (std.enums.values(Bucket)) |bucket| {
        const tab = self.matches.tabs.get(bucket).button orelse continue;
        if (tab != button or bucket == self.matches.bucket) continue;
        self.matches.bucket = bucket;
        self.matches.expanded = null;
        self.matches.stale = true;
        request(self, .page);
        return;
    }
}

fn bucketName(bucket: Bucket) [*:0]const u8 {
    return switch (bucket) {
        .confident => "Confident",
        .needs_review => "Needs Review",
        .unmatched => "Unmatched",
    };
}

fn tabButton(self: *App, bucket: Bucket, group: ?*gtk.Widget) *gtk.Widget {
    const count = label("", "match-tab-count");
    gtk.gtk_widget_add_css_class(count, "numeric");
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    append(content, &.{ gtk.gtk_label_new(bucketName(bucket)), count });
    const button = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, "match-tab");
    if (group) |first| gtk.gtk_toggle_button_set_group(gtk.cast(gtk.ToggleButton, button), gtk.cast(gtk.ToggleButton, first));
    if (bucket == self.matches.bucket) gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, button), gtk.true_);
    _ = gtk.signalConnect(button, "toggled", gtk.callback(tabClicked), self);
    self.matches.tabs.set(bucket, .{ .button = button, .count = gtk.cast(gtk.Label, count) });
    return button;
}

fn filterChanged(entry: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const text = std.mem.trim(u8, std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry))), " \t");
    const matches = &self.matches;
    if (std.mem.eql(u8, text, matches.filter.buffer[0..matches.filter.len])) return;
    matches.filter.set(text);
    matches.filtered_counts = null;
    matches.expanded = null;
    matches.stale = true;
    request(self, .page);
}

fn buildSearch(self: *App) *gtk.Widget {
    const entry = gtk.gtk_search_entry_new();
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), "Search matches…");
    gtk.gtk_search_entry_set_search_delay(gtk.cast(gtk.SearchEntry, entry), app.search_delay_ms);
    if (gtk.gtk_widget_get_first_child(entry)) |icon| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, icon), "orca-search-symbolic");
    if (gtk.gtk_widget_get_last_child(entry)) |icon| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, icon), "orca-close-symbolic");
    _ = gtk.signalConnect(entry, "search-changed", gtk.callback(filterChanged), self);
    self.matches.search = entry;
    const hint = gtk.gtk_label_new("Ctrl F");
    gtk.gtk_widget_add_css_class(hint, "keycap-hint");
    gtk.gtk_widget_set_halign(hint, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(hint, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_can_target(hint, gtk.false_);
    const field = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(field, "library-search");
    gtk.gtk_widget_set_valign(field, gtk.ALIGN_CENTER);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, field), entry);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, field), hint);
    return field;
}

pub fn focusSearch(self: *App) bool {
    const entry = self.matches.search orelse return false;
    return gtk.gtk_widget_grab_focus(entry) != 0;
}

fn matchAgainClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startMatching(state(data));
}

fn scrollerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.matches.scroller = null;
    self.matches.content = null;
    self.matches.built = false;
}

fn fluidApplied(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const content = state(data).matches.content orelse return;
    gtk.gtk_widget_set_size_request(content, -1, -1);
    gtk.gtk_widget_set_hexpand(content, gtk.true_);
}

fn fluidUnapplied(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const content = state(data).matches.content orelse return;
    gtk.gtk_widget_set_size_request(content, content_width, -1);
    gtk.gtk_widget_set_hexpand(content, gtk.false_);
}

pub fn build(self: *App) *gtk.Widget {
    const matches = &self.matches;
    const title = page_ui.title("Matches");
    gtk.gtk_widget_add_css_class(title.widget, "matches-title");
    gtk.gtk_label_set_text(title.meta, "How your albums line up with MusicBrainz releases, and why.");
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, title.meta), "numeric");
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, title.meta), "matches-summary");
    const again = iconLabelButton("orca-refresh-symbolic", "Match Again", "match-again");
    gtk.gtk_widget_set_tooltip_text(again, "Search MusicBrainz again for every track without a recording ID");
    _ = gtk.signalConnect(again, "clicked", gtk.callback(matchAgainClicked), self);
    title.add(again);

    const tabs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(tabs, "match-tabs");
    var first: ?*gtk.Widget = null;
    for (std.enums.values(Bucket)) |bucket| {
        const button = tabButton(self, bucket, first);
        if (first == null) first = button;
        gtk.gtk_box_append(gtk.cast(gtk.Box, tabs), button);
    }

    const corrections = gtk.gtk_list_box_new();
    matches.corrections = gtk.cast(gtk.ListBox, corrections);
    gtk.gtk_list_box_set_selection_mode(matches.corrections.?, gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(corrections, "boxed-list");
    gtk.gtk_widget_add_css_class(corrections, "match-list");
    const corrections_box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(corrections_box, "match-corrections");
    matches.corrections_box = corrections_box;
    append(corrections_box, &.{ label("Album corrections", "match-section"), corrections });
    gtk.gtk_widget_set_visible(corrections_box, gtk.false_);

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(list, "match-rows");
    matches.list = gtk.cast(gtk.Box, list);
    const empty = label("", "match-empty");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, empty), gtk.true_);
    matches.empty = gtk.cast(gtk.Label, empty);
    const note = label("", "match-note");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, note), gtk.true_);
    matches.note = gtk.cast(gtk.Label, note);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(content, "matches-body");
    gtk.gtk_widget_set_size_request(content, content_width, -1);
    gtk.gtk_widget_set_hexpand(content, gtk.false_);
    append(content, &.{ title.widget, tabs, corrections_box, list, empty, note });
    matches.content = content;
    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), content_width);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), content_width);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);

    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    const column = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    append(column, &.{ clamp, spacer });

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);
    matches.scroller = gtk.cast(gtk.ScrolledWindow, scroller);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(scrollerDestroyed), self);

    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), scroller);
    if (adw.adw_breakpoint_condition_parse("max-width: 1140px")) |condition| {
        const breakpoint = adw.adw_breakpoint_new(condition);
        _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(fluidApplied), self);
        _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(fluidUnapplied), self);
        adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
    }

    page_ui.addEnd(self, .matches, buildSearch(self));
    matches.built = true;
    return bin;
}

pub fn tabCounts(self: *App) ?liborca.ReleaseMatchCounts {
    return if (self.matches.filter.len != 0) self.matches.filtered_counts else self.matches.counts;
}

fn showCounts(self: *App) void {
    const matches = &self.matches;
    const counts = tabCounts(self) orelse return;
    var buffer: [32]u8 = undefined;
    for (std.enums.values(Bucket)) |bucket| {
        const count_label = matches.tabs.get(bucket).count orelse continue;
        const count = switch (bucket) {
            .confident => counts.confident,
            .needs_review => counts.needs_review,
            .unmatched => counts.unmatched,
        };
        gtk.gtk_label_set_text(count_label, strings.format(&buffer, "{f}", .{strings.grouped(count)}).ptr);
    }
    updateCount(self);
}

pub fn updateCount(self: *App) void {
    const badge = self.matches_count orelse return;
    const counts = self.matches.counts orelse {
        request(self, .counts);
        return;
    };
    const total = counts.needs_review + self.matches.group_count;
    var buffer: [24]u8 = undefined;
    const text: [:0]const u8 = if (total == 0) "" else strings.printZ(&buffer, "{f}", .{strings.grouped(total)}) catch "";
    gtk.gtk_label_set_text(badge, text.ptr);
}

pub fn unmatchedCount(self: *App) ?u64 {
    if (self.matches.counts_stale) request(self, .counts);
    const counts = self.matches.counts orelse return null;
    return counts.unmatched;
}

fn emptyText(bucket: Bucket, filtered: bool) [*:0]const u8 {
    if (filtered) return "No album here matches your search.";
    return switch (bucket) {
        .confident => "No album matches a MusicBrainz release with confidence yet.",
        .needs_review => "No album needs review.",
        .unmatched => "Every album has a MusicBrainz candidate.",
    };
}

fn showList(self: *App) void {
    const matches = &self.matches;
    const list = matches.list orelse return;
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list))) |child| gtk.gtk_box_remove(list, child);
    const items = if (matches.page) |page| page.items else &.{};
    for (items, 0..) |item, index| {
        const detail: ?*const Detail = if (index < matches.details.len) &matches.details[index] else null;
        const row = matchRow(self, item, detail) orelse continue;
        gtk.gtk_box_append(list, row);
    }
    if (matches.empty) |empty| {
        gtk.gtk_label_set_text(empty, emptyText(matches.bucket, matches.filter.len != 0));
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, empty), @intFromBool(items.len == 0));
    }
    const total: u64 = if (tabCounts(self)) |counts| switch (matches.bucket) {
        .confident => counts.confident,
        .needs_review => counts.needs_review,
        .unmatched => counts.unmatched,
    } else items.len;
    if (matches.note) |note| {
        var buffer: [160]u8 = undefined;
        const text: [:0]const u8 = if (total > items.len)
            strings.format(&buffer, "Showing the first {f} of {f}. orca-cli matches --releases lists them all.", .{
                strings.grouped(items.len),
                strings.grouped(total),
            })
        else
            "";
        gtk.gtk_label_set_text(note, text.ptr);
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, note), @intFromBool(text.len != 0));
    }
}

fn request(self: *App, want: Want) void {
    const matches = &self.matches;
    const library = self.library orelse return;
    if (matches.loader != null) {
        if (@intFromEnum(want) > @intFromEnum(matches.wanted)) matches.wanted = want;
        return;
    }
    matches.wanted = .none;
    const loader = self.allocator.create(Loader) catch return;
    loader.* = .{
        .runtime = self.runtime,
        .library = library,
        .waker = self.waker(),
        .bucket = matches.bucket,
        .confident_at = thresholdFraction(self),
        .filter = matches.filter,
        .with_page = want == .page,
    };
    matches.counts_stale = false;
    if (want == .page) matches.stale = false;
    loader.thread = std.Thread.spawn(.{}, Loader.run, .{loader}) catch {
        self.allocator.destroy(loader);
        matches.counts_stale = true;
        if (want == .page) matches.stale = true;
        return;
    };
    matches.loader = loader;
}

pub fn tick(self: *App) void {
    const matches = &self.matches;
    const loader = matches.loader orelse return;
    if (!loader.finished.load(.acquire)) return;
    matches.loader = null;
    defer loader.destroy(self.allocator);

    const unmatched_before = if (matches.counts) |counts| counts.unmatched else null;
    if (loader.counts) |counts| matches.counts = counts;
    const current_filter = loader.filter.eql(&matches.filter);
    if (current_filter) matches.filtered_counts = loader.filtered_counts;
    matches.group_count = if (loader.groups) |groups| groups.items.len else 0;
    showCounts(self);
    if (matches.built) showCorrections(self, loader.groups);
    if (loader.with_page and loader.bucket == matches.bucket and current_filter) {
        matches.deinit();
        matches.page = loader.page;
        matches.details = loader.details;
        loader.page = null;
        loader.details = &.{};
        showList(self);
    }
    const unmatched_after = if (matches.counts) |counts| counts.unmatched else null;
    if (unmatched_before != unmatched_after) health.reload(self);

    const wanted = matches.wanted;
    matches.wanted = .none;
    if (wanted == .page or (matches.stale and self.current_page == .matches)) {
        request(self, .page);
    } else if (wanted == .counts or matches.counts_stale) {
        request(self, .counts);
    }
}

pub fn shutdown(self: *App) void {
    if (self.matches.loader) |loader| loader.destroy(self.allocator);
    self.matches.loader = null;
}

pub fn reveal(self: *App, track_id: i64) void {
    _ = track_id;
    window.goTo(self, .matches);
}

pub fn showBucket(self: *App, bucket: Bucket) void {
    const matches = &self.matches;
    if (bucket != matches.bucket) {
        matches.bucket = bucket;
        matches.expanded = null;
        matches.stale = true;
        if (matches.tabs.get(bucket).button) |button| gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, button), gtk.true_);
    }
    window.goTo(self, .matches);
    shown(self);
}

pub fn invalidate(self: *App) void {
    self.matches.stale = true;
    self.matches.counts_stale = true;
    match_review.invalidate(self);
    request(self, if (self.current_page == .matches) .page else .counts);
}

pub fn shown(self: *App) void {
    if (self.matches.stale) request(self, .page);
}
