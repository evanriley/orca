//! The Matches page: the Tracks MusicBrainz or AcoustID proposed recordings
//! for, each beside its best proposal, to accept or dismiss, and the
//! submission of accepted matches to AcoustID. liborca finds, orders, records
//! and submits the matches; this only words them.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const details = @import("details.zig");
const window = @import("window.zig");
const secret = @import("secret.zig");

const App = app.App;

const separator = " · ";
const length_tolerance_ms: u64 = 10_000;
const recording_url = "https://musicbrainz.org/recording/";

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const RowInfo = struct {
    self: *App,
    track_id: i64,
    duration_ms: ?i64,
    filled: bool = false,
};

fn rowInfo(data: ?*anyopaque) *RowInfo {
    return @ptrCast(@alignCast(data.?));
}

/// Confidence as a whole percentage, rounded down so a match shown at P% is
/// one Accept Confident at P% takes.
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

pub fn writeSource(writer: *std.Io.Writer, proposal: liborca.MatchProposal) std.Io.Writer.Error!void {
    try writer.writeAll(sourceName(proposal.provider));
    if (proposal.acoustid_score) |score| try writer.print(separator ++ "fingerprint {d}%", .{percent(score)});
}

fn finish(buffer: []u8, writer: *const std.Io.Writer) [:0]const u8 {
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn lengthDiffers(track_ms: ?i64, proposal_ms: ?u64) bool {
    const track = std.math.cast(u64, track_ms orelse return false) orelse return false;
    const proposal = proposal_ms orelse return false;
    const difference = if (track > proposal) track - proposal else proposal - track;
    return difference > length_tolerance_ms;
}

pub fn updateCount(self: *App) void {
    const library = self.library orelse return;
    const total = self.runtime.libraryMatchReviewCount(library) catch return;
    const label = self.matches_count orelse return;
    var buffer: [24]u8 = undefined;
    const text: [:0]const u8 = if (total == 0) "" else strings.printZ(&buffer, "{f}", .{strings.grouped(total)}) catch "";
    gtk.gtk_label_set_text(label, text.ptr);
}

fn refused(self: *App, err: anyerror, fallback: [:0]const u8) void {
    if (err == error.StaleIdentificationProposal or err == error.UnknownIdentificationProposal) {
        self.toast("That match was already handled");
        return changed(self);
    }
    self.toast(fallback);
}

fn changed(self: *App) void {
    reload(self);
    details.invalidate(self);
    self.requestTick();
}

pub fn accept(self: *App, track_id: i64, proposal_id: i64) void {
    const library = self.library orelse return;
    self.matches_open_track = track_id;
    const acceptance = self.runtime.libraryAcceptMatch(library, proposal_id) catch |err|
        return refused(self, err, "Could not save that match");
    self.toast(if (acceptance.values_written == 0) "Kept your recording ID" else "Recording ID saved");
    changed(self);
}

pub fn dismiss(self: *App, track_id: i64, proposal_id: i64) void {
    const library = self.library orelse return;
    self.matches_open_track = track_id;
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

/// Opens the recording's MusicBrainz page in the browser.
pub fn openRecording(self: *App, recording_mbid: []const u8) void {
    var buffer: [128]u8 = undefined;
    const url = strings.printZ(&buffer, recording_url ++ "{s}", .{recording_mbid}) catch return;
    const launcher = gtk.gtk_uri_launcher_new(url.ptr);
    gtk.gtk_uri_launcher_launch(launcher, self.window, null, launched, self);
    gtk.g_object_unref(launcher);
}

fn freeText(text: ?*anyopaque) callconv(.c) void {
    gtk.g_free(text);
}

/// A flat "MusicBrainz" button holding `recording_mbid`, for a "clicked"
/// handler to pass to `openRecording`.
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

fn proposalOf(button: ?*anyopaque) ?i64 {
    const stored = gtk.g_object_get_data(button.?, "orca-proposal") orelse return null;
    return @intCast(@intFromPtr(stored));
}

fn acceptClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const info = rowInfo(data);
    accept(info.self, info.track_id, proposalOf(button) orelse return);
}

fn dismissClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const info = rowInfo(data);
    dismiss(info.self, info.track_id, proposalOf(button) orelse return);
}

fn linkClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    openRecording(rowInfo(data).self, recordingOf(button) orelse return);
}

fn findClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startMatching(state(data));
}

fn noConfidentText(buffer: []u8, self: *const App) [:0]const u8 {
    return strings.format(buffer, "No song has exactly one match scoring {d}% or more", .{self.match_threshold_percent});
}

fn acceptConfidentClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    var buffer: [256]u8 = undefined;
    const count = self.runtime.libraryConfidentMatchCount(library, thresholdFraction(self)) catch
        return self.toast("Could not count the confident matches");
    if (count == 0) return self.toast(noConfidentText(&buffer, self));
    const heading = if (count == 1)
        strings.format(&buffer, "Accept 1 match?", .{})
    else
        strings.format(&buffer, "Accept {f} matches?", .{strings.grouped(count)});
    var body_buffer: [256]u8 = undefined;
    const body = strings.format(
        &body_buffer,
        "Each song has exactly one match scoring {d}% or more. This records MusicBrainz recording IDs in your library and never changes your files.",
        .{self.match_threshold_percent},
    );
    const dialog = adw.adw_alert_dialog_new(heading.ptr, body.ptr);
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "accept", "Accept");
    adw.adw_alert_dialog_set_response_appearance(alert, "accept", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "cancel");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(acceptConfidentResponse), self);
    adw.adw_dialog_present(dialog, gtk.cast(gtk.Widget, button));
}

fn acceptConfidentResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (!std.mem.eql(u8, std.mem.span(response), "accept")) return;
    const library = self.library orelse return;
    const accepted = self.runtime.libraryAcceptConfidentMatches(library, thresholdFraction(self)) catch
        return self.toast("Could not accept the matches");
    var buffer: [64]u8 = undefined;
    self.toast(if (accepted == 1)
        "Accepted 1 match"
    else
        strings.format(&buffer, "Accepted {f} matches", .{strings.grouped(accepted)}));
    changed(self);
}

pub fn showAcoustIdKey(self: *App, presence: secret.Presence) void {
    self.acoustid_key_stored = presence == .stored;
    const library = self.library orelse return;
    showSubmit(self, library);
}

fn acoustIdKeyChecked(presence: secret.Presence, data: ?*anyopaque) void {
    showAcoustIdKey(state(data), presence);
}

pub fn checkAcoustIdKey(self: *App) void {
    secret.check(liborca.acoustid_credential_service, liborca.acoustid_user_key_account, .report, acoustIdKeyChecked, self) catch {};
}

fn showSubmit(self: *App, library: liborca.LibraryHandle) void {
    const submit = self.matches_submit_button orelse return;
    const count = if (self.acoustid_key_stored) self.runtime.libraryAcoustIdSubmittableCount(library) catch 0 else 0;
    gtk.gtk_widget_set_visible(submit, if (count == 0) gtk.false_ else gtk.true_);
    if (count == 0) return;
    var buffer: [64]u8 = undefined;
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, submit), strings.format(&buffer, "Submit to AcoustID ({f})", .{strings.grouped(count)}).ptr);
}

fn submitClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const count = self.runtime.libraryAcoustIdSubmittableCount(library) catch
        return self.toast("Could not count the songs to submit");
    if (count == 0) {
        showSubmit(self, library);
        return self.toast("Nothing to submit");
    }
    var buffer: [160]u8 = undefined;
    const heading = if (count == 1)
        strings.format(&buffer, "Send audio fingerprints and recording IDs for 1 song to AcoustID?", .{})
    else
        strings.format(&buffer, "Send audio fingerprints and recording IDs for {f} songs to AcoustID?", .{strings.grouped(count)});
    const dialog = adw.adw_alert_dialog_new(
        heading.ptr,
        "This helps others identify the same recordings. Only matches you accepted or IDs you set are sent, never IDs already in your files' tags.",
    );
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "send", "Send");
    adw.adw_alert_dialog_set_response_appearance(alert, "send", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "cancel");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(submitResponse), self);
    adw.adw_dialog_present(dialog, gtk.cast(gtk.Widget, button));
}

fn submitResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    if (!std.mem.eql(u8, std.mem.span(response), "send")) return;
    jobs.startSubmission(state(data));
}

fn newLabel(text: [:0]const u8, css_class: ?[*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0.0);
    if (css_class) |name| gtk.gtk_widget_add_css_class(widget, name);
    return widget;
}

fn proposalButton(text: [*:0]const u8, tooltip: [*:0]const u8, proposal_id: i64, handler: gtk.GCallback, info: *RowInfo) *gtk.Widget {
    const widget = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(widget, tooltip);
    gtk.g_object_set_data(widget, "orca-proposal", @ptrFromInt(@as(usize, @intCast(proposal_id))));
    _ = gtk.signalConnect(widget, "clicked", handler, info);
    return widget;
}

/// "Title — Artist credit · Album · #3 · 4:19 · 92% · AcoustID · fingerprint
/// 98%" with Accept, Dismiss and a link to the recording. The length is flagged when it is far from the
/// Track's.
fn proposalRow(info: *RowInfo, proposal: liborca.MatchProposal) *gtk.Widget {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeHeading(&writer, proposal) catch {};
    if (proposal.album.len != 0) writer.print(separator ++ "{s}", .{proposal.album}) catch {};
    if (proposal.track_number) |number| writer.print(separator ++ "#{d}", .{number}) catch {};
    const text = finish(&buffer, &writer);
    const heading = newLabel(text, null);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, heading), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_tooltip_text(heading, text.ptr);

    const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(line, gtk.true_);
    gtk.gtk_widget_set_valign(line, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), heading);
    if (proposal.duration_ms) |milliseconds| {
        var length_buffer: [32]u8 = undefined;
        gtk.gtk_box_append(gtk.cast(gtk.Box, line), newLabel(separator, null));
        const length = newLabel(strings.formatMs(&length_buffer, milliseconds), "numeric");
        if (lengthDiffers(info.duration_ms, milliseconds)) {
            gtk.gtk_widget_add_css_class(length, "warning");
            gtk.gtk_widget_set_tooltip_text(length, "Differs from your file by more than 10 seconds");
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, line), length);
    }
    var percent_buffer: [16]u8 = undefined;
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), newLabel(strings.format(&percent_buffer, separator ++ "{d}%", .{percent(proposal.confidence)}), "numeric"));
    var source_buffer: [96]u8 = undefined;
    var source_writer = std.Io.Writer.fixed(source_buffer[0 .. source_buffer.len - 1]);
    source_writer.writeAll(separator) catch {};
    writeSource(&source_writer, proposal) catch {};
    const source_text = finish(&source_buffer, &source_writer);
    const source = newLabel(source_text, "dim-label");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, source), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_tooltip_text(source, source_text[separator.len..].ptr);
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), source);

    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_add_css_class(row, "match-proposal");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), line);
    const accept_button = proposalButton("Accept", "Record this recording ID", proposal.id, gtk.callback(acceptClicked), info);
    gtk.gtk_widget_add_css_class(accept_button, "suggested-action");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), accept_button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), proposalButton("Dismiss", "Not this recording", proposal.id, gtk.callback(dismissClicked), info));
    const link = linkButton(proposal.recording_mbid);
    _ = gtk.signalConnect(link, "clicked", gtk.callback(linkClicked), info);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), link);
    return row;
}

fn fill(expander: *gtk.Widget, info: *RowInfo) void {
    if (info.filled) return;
    info.filled = true;
    const self = info.self;
    const library = self.library orelse return;
    var proposals = self.runtime.libraryMatchProposals(library, info.track_id, app.page_size) catch
        return self.toast("Could not read the matches");
    defer proposals.deinit();
    for (proposals.items) |proposal|
        adw.adw_expander_row_add_row(gtk.cast(adw.ExpanderRow, expander), proposalRow(info, proposal));
}

fn expandedChanged(expander: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = gtk.cast(gtk.Widget, expander);
    if (adw.adw_expander_row_get_expanded(gtk.cast(adw.ExpanderRow, row)) == 0) return;
    fill(row, rowInfo(data));
}

fn rowDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const info = rowInfo(data);
    info.self.allocator.destroy(info);
}

fn reviewRow(self: *App, item: liborca.MatchReviewItem) ?*gtk.Widget {
    const info = self.allocator.create(RowInfo) catch return null;
    info.* = .{ .self = self, .track_id = item.track_id, .duration_ms = item.duration_ms };
    const row = adw.adw_expander_row_new();
    _ = gtk.signalConnect(row, "destroy", gtk.callback(rowDestroyed), info);
    adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, row), gtk.false_);

    var title_buffer: [512]u8 = undefined;
    const title = strings.format(&title_buffer, "{s}{s}{s}", .{
        if (item.title.len != 0) item.title else "Unknown title",
        if (item.artist.len != 0) " — " else "",
        item.artist,
    });
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), title.ptr);

    var subtitle_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(subtitle_buffer[0 .. subtitle_buffer.len - 1]);
    if (item.album.len != 0) writer.print("{s}" ++ separator, .{item.album}) catch {};
    if (item.duration_ms) |milliseconds| if (std.math.cast(u64, milliseconds)) |length| {
        var length_buffer: [32]u8 = undefined;
        writer.print("{s}" ++ separator, .{strings.formatMs(&length_buffer, length)}) catch {};
    };
    writer.print("best {d}%", .{percent(item.best.confidence)}) catch {};
    const subtitle = finish(&subtitle_buffer, &writer);
    adw.adw_expander_row_set_subtitle(gtk.cast(adw.ExpanderRow, row), subtitle.ptr);
    adw.adw_expander_row_set_title_lines(gtk.cast(adw.ExpanderRow, row), 1);
    adw.adw_expander_row_set_subtitle_lines(gtk.cast(adw.ExpanderRow, row), 1);

    var tooltip_buffer: [1024]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(row, strings.format(&tooltip_buffer, "{s}\n{s}", .{ title, subtitle }).ptr);
    _ = gtk.signalConnect(row, "notify::expanded", gtk.callback(expandedChanged), info);
    return row;
}

pub fn build(self: *App) *gtk.Widget {
    const list = gtk.gtk_list_box_new();
    self.matches_list = gtk.cast(gtk.ListBox, list);
    gtk.gtk_list_box_set_selection_mode(self.matches_list.?, gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(list, "boxed-list");
    const note = gtk.gtk_label_new("");
    self.matches_note = gtk.cast(gtk.Label, note);
    gtk.gtk_widget_add_css_class(note, "dim-label");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, note), gtk.true_);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_add_css_class(content, "album-page");
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), note);
    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 1000);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), clamp);

    const empty = adw.adw_status_page_new();
    self.matches_empty = gtk.cast(adw.StatusPage, empty);
    const find_empty = gtk.gtk_button_new_with_label("Find Matches");
    self.matches_empty_button = find_empty;
    gtk.gtk_widget_set_halign(find_empty, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(find_empty, "pill");
    gtk.gtk_widget_add_css_class(find_empty, "suggested-action");
    gtk.gtk_widget_set_tooltip_text(find_empty, "About one song a second");
    _ = gtk.signalConnect(find_empty, "clicked", gtk.callback(findClicked), self);
    adw.adw_status_page_set_child(self.matches_empty.?, find_empty);

    const body = gtk.gtk_stack_new();
    self.matches_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.matches_body.?, scroller, "list");
    _ = gtk.gtk_stack_add_named(self.matches_body.?, empty, "empty");

    const header = adw.adw_header_bar_new();
    const title = adw.adw_window_title_new("Matches", "");
    self.matches_title = gtk.cast(adw.WindowTitle, title);
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), title);
    const find = gtk.gtk_button_new_with_label("Find Matches");
    gtk.gtk_widget_set_tooltip_text(find, "About one song a second");
    _ = gtk.signalConnect(find, "clicked", gtk.callback(findClicked), self);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), find);
    const accept_confident = gtk.gtk_button_new_with_label("Accept Confident");
    self.matches_accept_button = accept_confident;
    _ = gtk.signalConnect(accept_confident, "clicked", gtk.callback(acceptConfidentClicked), self);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), accept_confident);
    const submit = gtk.gtk_button_new_with_label("Submit to AcoustID");
    self.matches_submit_button = submit;
    gtk.gtk_widget_set_tooltip_text(submit, "Send the matches you accepted to AcoustID");
    gtk.gtk_widget_set_visible(submit, gtk.false_);
    _ = gtk.signalConnect(submit, "clicked", gtk.callback(submitClicked), self);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), submit);
    checkAcoustIdKey(self);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), body);
    return view;
}

fn showEmpty(self: *App, unidentified: u64) void {
    const page = self.matches_empty orelse return;
    if (unidentified == 0) {
        adw.adw_status_page_set_icon_name(page, "emblem-ok-symbolic");
        adw.adw_status_page_set_title(page, "Every song has a recording ID");
        adw.adw_status_page_set_description(page, null);
    } else {
        adw.adw_status_page_set_icon_name(page, "system-search-symbolic");
        adw.adw_status_page_set_title(page, "No matches to review");
        adw.adw_status_page_set_description(page, if (self.match_fingerprints)
            "Finding matches sends song titles, artists and album names to MusicBrainz, and a fingerprint of each song's audio to AcoustID. Nothing is sent until you start it."
        else
            "Finding matches sends song titles, artists and album names to MusicBrainz. Nothing is sent until you start it.");
    }
    if (self.matches_empty_button) |find| gtk.gtk_widget_set_visible(find, if (unidentified == 0) gtk.false_ else gtk.true_);
}

fn showAcceptConfident(self: *App, library: liborca.LibraryHandle) void {
    const accept_confident = self.matches_accept_button orelse return;
    const count = self.runtime.libraryConfidentMatchCount(library, thresholdFraction(self)) catch 0;
    var buffer: [128]u8 = undefined;
    const tooltip = if (count == 0)
        noConfidentText(&buffer, self)
    else
        strings.format(&buffer, "Accept each song's only match scoring {d}% or more", .{self.match_threshold_percent});
    gtk.gtk_widget_set_tooltip_text(accept_confident, tooltip.ptr);
    gtk.gtk_widget_set_sensitive(accept_confident, if (count == 0) gtk.false_ else gtk.true_);
}

fn focusOpenRow(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const row = self.matches_focus_row orelse return gtk.SOURCE_REMOVE;
    self.matches_focus_row = null;
    _ = gtk.gtk_widget_grab_focus(row);
    return gtk.SOURCE_REMOVE;
}

/// Shows the page with `track_id`'s row open, when it is on the page.
pub fn reveal(self: *App, track_id: i64) void {
    self.matches_open_track = track_id;
    window.showPage(self, .matches);
    reload(self);
}

pub fn reload(self: *App) void {
    const list = self.matches_list orelse return;
    self.matches_focus_row = null;
    gtk.gtk_list_box_remove_all(list);
    const library = self.library orelse return;
    updateCount(self);
    showAcceptConfident(self, library);
    showSubmit(self, library);
    const total = self.runtime.libraryMatchReviewCount(library) catch 0;
    const unidentified = self.runtime.libraryUnidentifiedCount(library) catch 0;
    var buffer: [256]u8 = undefined;
    if (self.matches_title) |title| {
        const text = strings.format(&buffer, "{f} {s} to review" ++ separator ++ "{f} not identified", .{
            strings.grouped(total),
            if (total == 1) "song" else "songs",
            strings.grouped(unidentified),
        });
        adw.adw_window_title_set_subtitle(title, text.ptr);
    }
    if (total == 0) showEmpty(self, unidentified);
    if (self.matches_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "list");

    var page = self.runtime.libraryMatchReviewPage(library, app.page_size, 0) catch return;
    defer page.deinit();
    for (page.items) |item| {
        const row = reviewRow(self, item) orelse continue;
        gtk.gtk_list_box_append(list, row);
        if (item.track_id != self.matches_open_track) continue;
        adw.adw_expander_row_set_expanded(gtk.cast(adw.ExpanderRow, row), gtk.true_);
        self.matches_focus_row = row;
        _ = gtk.g_idle_add(focusOpenRow, self);
    }
    if (self.matches_note) |note| {
        const text: [:0]const u8 = if (total > page.items.len)
            strings.format(&buffer, "Showing the first {f} of {f}. orca-cli matches lists them per song.", .{
                strings.grouped(page.items.len),
                strings.grouped(total),
            })
        else
            "";
        gtk.gtk_label_set_text(note, text.ptr);
    }
}
