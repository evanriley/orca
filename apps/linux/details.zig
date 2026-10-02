//! The inspector: a panel beside the Songs list and beside an album's tracks
//! that shows one Track's details, the playing Track's lyrics, or the playing
//! audio's signal path.
//!
//! liborca answers `libraryTrackDetails` and `playerSignalPath`; this only
//! words the answers. The panels share one mode, kept on the `App`: hidden,
//! details, lyrics or signal path. Each panel queries details only when the
//! Track it shows changes, and is handed the signal path whenever
//! `transport.refreshSignalPath` reads it.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
const signal_path = @import("signal_path.zig");
const song_table = @import("song_table.zig");
const matches = @import("matches.zig");
const jobs = @import("jobs.zig");
const ratings = @import("ratings.zig");
const lyrics = @import("lyrics.zig");
const transport = @import("transport.zig");

const App = app.App;

const panel_min_width: f64 = 300;
const panel_max_width: f64 = 320;
const separator = " · ";
const minus = "−";

pub const panel_limit = app.open_album_page_limit + app.open_artist_page_limit + 3;
const proposal_slots = 3;

/// Where a panel finds the Track it shows when nobody has chosen one.
pub const Source = union(enum) {
    selection: *gtk.SelectionModel,
    /// An album page: the row last chosen, else the playing Track if it is one
    /// of these.
    ids: []const i64,
};

const Row = struct {
    root: *gtk.Widget,
    value: *gtk.Label,
};

const Proposal = struct {
    root: *gtk.Widget,
    title: *gtk.Label,
    subtitle: *gtk.Label,
    accept: *gtk.Widget,
    dismiss: *gtk.Widget,
};

pub const Panel = struct {
    self: *App,
    source: Source,
    split: *gtk.Widget,
    root: *gtk.Widget,
    toggles: *gtk.Widget,
    details_toggle: *gtk.Widget,
    lyrics_toggle: *gtk.Widget,
    signal_path_toggle: *gtk.Widget,
    lyrics: lyrics.View = undefined,
    placeholder: *gtk.Widget,
    content: *gtk.Widget,
    title: *gtk.Widget,
    artist: *gtk.Widget,
    album: *gtk.Widget,
    audio_section: *gtk.Widget,
    codec_line: Row,
    format_line: Row,
    bitrate_line: Row,
    duration_line: Row,
    loudness_missing: Row,
    integrated_row: Row,
    peak_row: Row,
    replay_gain_row: Row,
    musicbrainz_row: Row,
    recording_row: Row,
    match_status: Row,
    acoustid_row: Row,
    release_id_row: Row,
    release_group_id_row: Row,
    release_track_id_row: Row,
    album_artist_id_row: Row,
    proposals: [proposal_slots]Proposal,
    proposal_ids: [proposal_slots]i64 = @splat(0),
    recording_link: *gtk.Widget,
    review_button: *gtk.Widget,
    find_button: *gtk.Widget,
    verify_button: *gtk.Widget,
    metadata_section: *gtk.Widget,
    album_artist_row: Row,
    date_row: Row,
    track_row: Row,
    disc_row: Row,
    compilation_row: Row,
    feedback_row: Row,
    rating_stars: *gtk.Widget,
    plays_row: Row,
    last_played_row: Row,
    size_line: Row,
    path_label: *gtk.Label,
    copy_button: *gtk.Widget,
    signal_status: *gtk.Label,
    signal_verdict: *gtk.Widget,
    signal_dot: *gtk.Widget,
    signal_verdict_label: *gtk.Label,
    signal_flow: *gtk.Widget,
    signal_note: *gtk.Widget,
    /// The Track on screen, and whether that is stale since the library changed.
    shown: ?i64 = null,
    stale: bool = false,
    chosen: ?i64 = null,
    path: ?[:0]u8 = null,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn panelData(data: ?*anyopaque) *Panel {
    return @ptrCast(@alignCast(data.?));
}

pub fn shownMode(self: *const App) app.Sidebar {
    if (self.window_narrow and !self.inspector_overlaid) return .hidden;
    return self.sidebar_page;
}

pub fn setNarrow(self: *App, narrow: bool) void {
    self.window_narrow = narrow;
    self.inspector_overlaid = false;
    applyVisibility(self);
}

pub fn toggle(self: *App) void {
    showSidebar(self, if (shownMode(self) == .details) .hidden else .details);
}

pub fn showSidebar(self: *App, sidebar: app.Sidebar) void {
    if (sidebar == shownMode(self)) return;
    if (sidebar == .hidden and self.window_narrow) {
        self.inspector_overlaid = false;
    } else {
        self.inspector_overlaid = true;
        if (sidebar != self.sidebar_page) {
            self.sidebar_page = sidebar;
            settings.save(self);
        }
    }
    applyVisibility(self);
}

pub fn revealSignalPath(self: *App) bool {
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        if (gtk.gtk_widget_get_mapped(panel.split) == 0) continue;
        showSidebar(self, .signal_path);
        return true;
    }
    return false;
}

fn pageName(mode: app.Sidebar) [*:0]const u8 {
    return switch (mode) {
        .hidden, .details => "details",
        .lyrics => "lyrics",
        .signal_path => "signal_path",
    };
}

pub fn applyVisibility(self: *App) void {
    const mode = shownMode(self);
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        showMode(panel, mode);
        update(panel);
    }
    lyrics.sync(self);
    if (mode == .signal_path) transport.refreshSignalPath(self);
}

fn showMode(panel: *Panel, mode: app.Sidebar) void {
    const split = gtk.cast(adw.OverlaySplitView, panel.split);
    if (mode != .hidden) gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, panel.root), pageName(mode));
    adw.adw_overlay_split_view_set_collapsed(split, boolean(panel.self.window_narrow));
    adw.adw_overlay_split_view_set_show_sidebar(split, boolean(mode != .hidden));
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, panel.details_toggle), boolean(mode == .details));
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, panel.lyrics_toggle), boolean(mode == .lyrics));
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, panel.signal_path_toggle), boolean(mode == .signal_path));
}

fn detailsToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    sidebarToggled(state(data), button, .details);
}

fn lyricsToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    sidebarToggled(state(data), button, .lyrics);
}

fn signalPathToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    sidebarToggled(state(data), button, .signal_path);
}

fn sidebarToggled(self: *App, button: ?*anyopaque, sidebar: app.Sidebar) void {
    const active = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0;
    if (active == (shownMode(self) == sidebar)) return;
    showSidebar(self, if (active) sidebar else .hidden);
}

fn sidebarShownChanged(split: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const shown = adw.adw_overlay_split_view_get_show_sidebar(gtk.cast(adw.OverlaySplitView, split)) != 0;
    if (!shown and shownMode(panel.self) != .hidden) showSidebar(panel.self, .hidden);
}

/// The library changed under the panels: what they show may no longer be true.
pub fn invalidate(self: *App) void {
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        panel.stale = true;
        update(panel);
    }
}

pub fn tick(self: *App) void {
    const library = self.library orelse return;
    const recorded = self.runtime.libraryListensRecorded(library) catch return;
    if (recorded == self.seen_recorded_listens) return;
    self.seen_recorded_listens = recorded;
    invalidate(self);
}

/// The playing Track changed.
pub fn trackChanged(self: *App) void {
    for (self.details_panels) |maybe| update(maybe orelse continue);
}

pub fn selectionChanged(model: ?*anyopaque, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    for (state(data).details_panels) |maybe| {
        const panel = maybe orelse continue;
        switch (panel.source) {
            .selection => |selection| if (@as(?*anyopaque, selection) == model) update(panel),
            .ids => {},
        }
    }
}

pub fn choose(panel: *Panel, track_id: i64) void {
    panel.chosen = track_id;
    update(panel);
}

fn wantedTrack(panel: *Panel) ?i64 {
    const self = panel.self;
    switch (panel.source) {
        .selection => |selection| return song_table.firstSelected(selection) orelse self.shown_track_id,
        .ids => |ids| {
            if (panel.chosen) |chosen| return chosen;
            const playing = self.shown_track_id orelse return null;
            for (ids) |id| if (id == playing) return playing;
            return null;
        },
    }
}

fn update(panel: *Panel) void {
    if (shownMode(panel.self) != .details) return;
    const wanted = wantedTrack(panel);
    if (!panel.stale and optionalEql(wanted, panel.shown)) return;
    panel.stale = false;
    panel.shown = wanted;
    show(panel, wanted);
}

fn show(panel: *Panel, track_id: ?i64) void {
    const self = panel.self;
    const library = self.library orelse return showPlaceholder(panel);
    const id = track_id orelse return showPlaceholder(panel);
    const details = (self.runtime.libraryTrackDetails(library, id) catch null) orelse
        return showPlaceholder(panel);
    defer details.deinit();
    populate(panel, details);
    gtk.gtk_widget_set_visible(panel.placeholder, gtk.false_);
    gtk.gtk_widget_set_visible(panel.content, gtk.true_);
}

fn showPlaceholder(panel: *Panel) void {
    gtk.gtk_widget_set_visible(panel.placeholder, gtk.true_);
    gtk.gtk_widget_set_visible(panel.content, gtk.false_);
    setPath(panel, null);
}

/// Draws `path`, as `transport.refreshSignalPath` read it, in every panel;
/// null when it could not be read. `playerSignalPath` pauses the engine
/// briefly, so the panels never read it themselves.
pub fn showSignalPath(self: *App, path: ?liborca.SignalPath) void {
    if (shownMode(self) != .signal_path) return;
    for (self.details_panels) |maybe| drawSignalPath(maybe orelse continue, path);
}

fn drawSignalPath(panel: *Panel, maybe_path: ?liborca.SignalPath) void {
    const flow = gtk.cast(gtk.Box, panel.signal_flow);
    while (gtk.gtk_widget_get_first_child(panel.signal_flow)) |child| gtk.gtk_box_remove(flow, child);
    const path = maybe_path orelse return showSignalStatus(panel, "Signal path unavailable");
    var stage_buffer: [signal_path.max_stages]signal_path.Stage = undefined;
    const stages = signal_path.stages(path, &stage_buffer);
    if (stages.len == 0) return showSignalStatus(panel, signal_path.nothing_playing);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, panel.signal_status), gtk.false_);
    gtk.gtk_widget_set_visible(panel.signal_note, gtk.true_);

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeVerdict(&writer, path) catch {};
    const verdict = finish(&buffer, &writer);
    gtk.gtk_label_set_text(panel.signal_verdict_label, verdict.ptr);
    gtk.gtk_widget_set_visible(panel.signal_verdict, boolean(verdict.len != 0));
    if (path.bit_perfect_eligible)
        gtk.gtk_widget_add_css_class(panel.signal_dot, "bit-perfect")
    else
        gtk.gtk_widget_remove_css_class(panel.signal_dot, "bit-perfect");

    for (stages, 0..) |stage, index| {
        writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
        signal_path.writeStage(&writer, path, stage) catch {};
        gtk.gtk_box_append(flow, stageRow(stage, finish(&buffer, &writer), index + 1 < stages.len));
    }
}

fn showSignalStatus(panel: *Panel, text: [*:0]const u8) void {
    gtk.gtk_label_set_text(panel.signal_status, text);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, panel.signal_status), gtk.true_);
    gtk.gtk_widget_set_visible(panel.signal_verdict, gtk.false_);
    gtk.gtk_widget_set_visible(panel.signal_note, gtk.false_);
}

fn stageIcon(stage: signal_path.Stage) [*:0]const u8 {
    return switch (stage) {
        .source => "audio-x-generic-symbolic",
        .replay_gain => "multimedia-volume-control-symbolic",
        .equalizer => "emblem-system-symbolic",
        .crossfeed => "audio-headphones-symbolic",
        .volume => "audio-volume-high-symbolic",
        .output => "audio-card-symbolic",
        .device => "audio-speakers-symbolic",
    };
}

fn stageRow(stage: signal_path.Stage, detail: [:0]const u8, followed: bool) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name(stageIcon(stage));
    gtk.gtk_widget_add_css_class(icon, "signal-node");
    gtk.gtk_widget_set_halign(icon, gtk.ALIGN_CENTER);
    const rail = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(rail, "signal-rail");
    gtk.gtk_widget_set_halign(rail, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_vexpand(rail, gtk.true_);
    gtk.gtk_widget_set_visible(rail, boolean(followed));
    const track = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, track), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, track), rail);

    const title = gtk.gtk_label_new(signal_path.stageTitle(stage).ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_add_css_class(title, "signal-stage");
    const value = gtk.gtk_label_new(detail.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, value), gtk.true_);
    gtk.gtk_widget_add_css_class(value, "meta");
    gtk.gtk_widget_add_css_class(value, "numeric");
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(text, "signal-text");
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), value);

    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_vexpand(row, gtk.false_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), track);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), text);
    return row;
}

fn populate(panel: *Panel, details: liborca.TrackDetails) void {
    var buffer: [1024]u8 = undefined;

    setLabel(panel.title, if (details.title.len != 0) details.title else "Unknown title", &buffer);
    setLabel(panel.artist, details.artist, &buffer);
    setLabel(panel.album, details.album, &buffer);

    var any_audio = false;
    any_audio = setRow(panel.codec_line, codecText(&buffer, details.codec)) or any_audio;
    any_audio = setRow(panel.format_line, formatText(&buffer, details)) or any_audio;
    any_audio = setRow(panel.bitrate_line, bitrateText(&buffer, details.bitrate_kbps)) or any_audio;
    const duration_text: ?[:0]const u8 = if (details.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&buffer, @intCast(ms)) else null)
    else
        null;
    any_audio = setRow(panel.duration_line, duration_text) or any_audio;
    gtk.gtk_widget_set_visible(panel.audio_section, boolean(any_audio));

    populateLoudness(panel, details.loudness);

    var size_buffer: [64]u8 = undefined;
    const size_text: ?[:0]const u8 = if (details.size_bytes) |bytes| sizeText(&size_buffer, bytes) else null;
    _ = setRow(panel.size_line, size_text);
    if (details.path) |path| {
        const text = strings.terminated(&buffer, path);
        gtk.gtk_label_set_text(panel.path_label, text.ptr);
        gtk.gtk_widget_set_tooltip_text(gtk.cast(gtk.Widget, panel.path_label), text.ptr);
        setPath(panel, path);
    } else {
        gtk.gtk_label_set_text(panel.path_label, "File missing");
        gtk.gtk_widget_set_tooltip_text(gtk.cast(gtk.Widget, panel.path_label), null);
        setPath(panel, null);
    }
    gtk.gtk_widget_set_visible(panel.copy_button, boolean(panel.path != null));

    _ = setRow(panel.feedback_row, feedbackText(&buffer, details));
    ratings.show(panel.rating_stars, details.rating);

    var plays_buffer: [24]u8 = undefined;
    _ = setRow(panel.plays_row, strings.printZ(&plays_buffer, "{d}", .{details.play_count}) catch null);
    _ = setRow(panel.last_played_row, lastPlayedText(&buffer, details.last_played_at));

    var any_tag = false;
    any_tag = setRow(panel.album_artist_row, optionalText(&buffer, details.album_artist)) or any_tag;
    any_tag = setRow(panel.date_row, if (details.date) |date| optionalText(&buffer, date) else null) or any_tag;
    var track_buffer: [24]u8 = undefined;
    var disc_buffer: [24]u8 = undefined;
    any_tag = setRow(panel.track_row, numberText(&track_buffer, details.track_number)) or any_tag;
    any_tag = setRow(panel.disc_row, numberText(&disc_buffer, details.disc_number)) or any_tag;
    const compilation: ?[:0]const u8 = if (details.compilation) |flag| (if (flag) "Yes" else "No") else null;
    any_tag = setRow(panel.compilation_row, compilation) or any_tag;
    gtk.gtk_widget_set_visible(panel.metadata_section, boolean(any_tag));

    setIdRow(panel.release_id_row, details.musicbrainz_release_id, details.musicbrainz_release_id_source);
    setIdRow(panel.release_group_id_row, details.musicbrainz_release_group_id, details.musicbrainz_release_group_id_source);
    setIdRow(panel.release_track_id_row, details.musicbrainz_release_track_id, details.musicbrainz_release_track_id_source);
    setIdRow(panel.album_artist_id_row, details.musicbrainz_album_artist_id, details.musicbrainz_album_artist_id_source);
    populateRecording(panel, details);
}

fn populateLoudness(panel: *Panel, loudness: ?liborca.TrackLoudness) void {
    var buffer: [64]u8 = undefined;
    const measured = loudness orelse {
        _ = setRow(panel.loudness_missing, "Not measured");
        for ([_]Row{ panel.integrated_row, panel.peak_row, panel.replay_gain_row }) |row| _ = setRow(row, null);
        return;
    };
    _ = setRow(panel.loudness_missing, null);
    _ = setRow(panel.integrated_row, decibelText(&buffer, measured.integrated_lufs, false, " LUFS"));
    const peak: ?[:0]const u8 = if (measured.sample_peak > 0)
        decibelText(&buffer, 20 * std.math.log10(measured.sample_peak), true, " dBFS")
    else
        minus ++ "∞ dBFS";
    _ = setRow(panel.peak_row, peak);
    _ = setRow(panel.replay_gain_row, decibelText(&buffer, measured.replay_gain_db, true, " dB"));
}

fn setIdRow(row: Row, id: ?[]const u8, source: ?liborca.RecordingIdSource) void {
    var buffer: [64]u8 = undefined;
    if (!setRow(row, if (id) |text| strings.terminated(&buffer, text) else null)) return;
    var tooltip_buffer: [128]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(row.root, strings.format(&tooltip_buffer, "{s}\n{s}", .{ id.?, sourceText(source) }).ptr);
}

fn sourceText(source: ?liborca.RecordingIdSource) [:0]const u8 {
    return switch (source orelse return "") {
        .tag => "From tags",
        .match => "Matched",
        .edit => "Set by you",
    };
}

fn populateRecording(panel: *Panel, details: liborca.TrackDetails) void {
    for (panel.proposals) |proposal| gtk.gtk_widget_set_visible(proposal.root, gtk.false_);
    for ([_]*gtk.Widget{ panel.review_button, panel.find_button, panel.verify_button }) |button|
        gtk.gtk_widget_set_visible(button, gtk.false_);
    _ = setRow(panel.acoustid_row, null);
    var buffer: [256]u8 = undefined;
    if (details.musicbrainz_recording_id) |recording_mbid| {
        const source = sourceText(details.musicbrainz_recording_id_source);
        _ = setRow(panel.musicbrainz_row, if (source.len != 0) source else "Identified");
        const text = strings.terminated(&buffer, recording_mbid);
        _ = setRow(panel.recording_row, text);
        gtk.gtk_widget_set_tooltip_text(panel.recording_row.root, text.ptr);
        _ = setRow(panel.match_status, null);
        matches.setRecording(panel.recording_link, recording_mbid);
        gtk.gtk_widget_set_visible(panel.recording_link, gtk.true_);
        populateVerification(panel, details.track_id);
        return;
    }
    _ = setRow(panel.musicbrainz_row, "Not identified");
    _ = setRow(panel.recording_row, null);
    gtk.gtk_widget_set_visible(panel.recording_link, gtk.false_);
    const self = panel.self;
    const searching = self.task == .matching and self.match_task_mode != .verify and self.match_task_track == details.track_id;
    const library = self.library orelse return;
    const proposals = self.runtime.libraryMatchProposals(library, details.track_id, proposal_slots + 1) catch null;
    defer if (proposals) |page| page.deinit();
    const pending = if (proposals) |page| page.items else &.{};
    const status: ?[:0]const u8 = if (searching)
        (if (self.match_fingerprints) "Searching MusicBrainz and AcoustID…" else "Searching MusicBrainz…")
    else if (pending.len == 0 and self.unmatched_track == details.track_id)
        "No match found"
    else
        null;
    _ = setRow(panel.match_status, status);
    const shown = @min(pending.len, proposal_slots);
    for (pending[0..shown], panel.proposals[0..shown], 0..) |proposal, widgets, slot| {
        showProposal(widgets, proposal);
        panel.proposal_ids[slot] = proposal.id;
    }
    gtk.gtk_widget_set_visible(panel.review_button, boolean(pending.len > proposal_slots));
    gtk.gtk_widget_set_visible(panel.find_button, boolean(pending.len == 0 and !searching));
}

fn populateVerification(panel: *Panel, track_id: i64) void {
    const self = panel.self;
    if (self.task == .matching and self.match_task_mode == .verify and self.match_task_track == track_id) {
        _ = setRow(panel.acoustid_row, "Checking…");
        return;
    }
    const library = self.library orelse return;
    const verification = (self.runtime.libraryTrackVerification(library, self.allocator, track_id) catch null) orelse {
        gtk.gtk_widget_set_visible(panel.verify_button, gtk.true_);
        return;
    };
    defer verification.deinit();
    var buffer: [128]u8 = undefined;
    _ = setRow(panel.acoustid_row, strings.format(&buffer, "{s}{s}{s}", .{
        switch (verification.outcome) {
            .agrees => "Verified",
            .disagrees => "Hears a different recording",
            .unconfirmed => "Could not confirm",
            .no_fingerprint => "Could not fingerprint",
        },
        if (verification.stale) separator ++ "out of date" else "",
        if (verification.dismissed) separator ++ "suggestion dismissed" else "",
    }));
    gtk.gtk_widget_set_visible(panel.verify_button, boolean(verification.stale));
}

fn showProposal(widgets: Proposal, proposal: liborca.MatchProposal) void {
    var title_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(title_buffer[0 .. title_buffer.len - 1]);
    matches.writeHeading(&writer, proposal) catch {};
    const title = finish(&title_buffer, &writer);
    gtk.gtk_label_set_text(widgets.title, title.ptr);
    var subtitle_buffer: [512]u8 = undefined;
    writer = std.Io.Writer.fixed(subtitle_buffer[0 .. subtitle_buffer.len - 1]);
    const album = proposal.release_title orelse proposal.album;
    if (album.len != 0) writer.print("{s}" ++ separator, .{album}) catch {};
    if (proposal.release_date) |date| writer.print("{s}" ++ separator, .{date}) catch {};
    if (proposal.duration_ms) |milliseconds| {
        var length_buffer: [32]u8 = undefined;
        writer.print("{s}" ++ separator, .{strings.formatMs(&length_buffer, milliseconds)}) catch {};
    }
    writer.print("{d}%", .{matches.percent(proposal.confidence)}) catch {};
    const subtitle = finish(&subtitle_buffer, &writer);
    gtk.gtk_label_set_text(widgets.subtitle, subtitle.ptr);
    var source_buffer: [96]u8 = undefined;
    writer = std.Io.Writer.fixed(source_buffer[0 .. source_buffer.len - 1]);
    matches.writeSource(&writer, proposal) catch {};
    const source = finish(&source_buffer, &writer);
    var tooltip_buffer: [1024]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(widgets.root, strings.format(&tooltip_buffer, "{s}\n{s}\nFrom {s}", .{ title, subtitle, source }).ptr);
    gtk.gtk_widget_set_visible(widgets.root, gtk.true_);
}

fn setPath(panel: *Panel, path: ?[]const u8) void {
    const allocator = panel.self.allocator;
    if (panel.path) |old| allocator.free(old);
    panel.path = if (path) |value| allocator.dupeZ(u8, value) catch null else null;
}

fn optionalEql(a: ?i64, b: ?i64) bool {
    if (a) |left| return left == (b orelse return false);
    return b == null;
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

fn optionalText(buffer: []u8, text: []const u8) ?[:0]const u8 {
    return if (text.len == 0) null else strings.terminated(buffer, text);
}

fn numberText(buffer: []u8, value: ?i64) ?[:0]const u8 {
    const number = value orelse return null;
    return strings.printZ(buffer, "{d}", .{number}) catch null;
}

fn sizeText(buffer: []u8, bytes: i64) ?[:0]const u8 {
    const text = gtk.g_format_size(@intCast(@max(bytes, 0)));
    defer gtk.g_free(text);
    return strings.printZ(buffer, "{s}", .{std.mem.span(text)}) catch null;
}

fn finish(buffer: []u8, writer: *const std.Io.Writer) [:0]const u8 {
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn codecText(buffer: []u8, codec: []const u8) ?[:0]const u8 {
    if (codec.len == 0) return null;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeCodecName(&writer, codec) catch {};
    return finish(buffer, &writer);
}

fn formatText(buffer: []u8, details: liborca.TrackDetails) ?[:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeFormat(&writer, details) catch {};
    if (writer.end == 0) return null;
    return finish(buffer, &writer);
}

fn writeFormat(writer: *std.Io.Writer, details: liborca.TrackDetails) std.Io.Writer.Error!void {
    var first = true;
    if (!details.lossy) if (details.bit_depth) |depth| {
        try writer.print("{d}-bit", .{depth});
        first = false;
    };
    if (details.sample_rate) |rate| {
        if (!first) try writer.writeAll(separator);
        try signal_path.writeRate(writer, rate);
        first = false;
    }
    if (details.channels) |channels| {
        if (!first) try writer.writeAll(separator);
        switch (channels) {
            1 => try writer.writeAll("Mono"),
            2 => try writer.writeAll("Stereo"),
            else => try writer.print("{d} channels", .{channels}),
        }
    }
}

fn bitrateText(buffer: []u8, bitrate_kbps: ?u32) ?[:0]const u8 {
    const kbps = bitrate_kbps orelse return null;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    strings.writeGrouped(&writer, kbps) catch {};
    writer.writeAll(" kbps") catch {};
    return finish(buffer, &writer);
}

fn feedbackText(buffer: []u8, details: liborca.TrackDetails) [:0]const u8 {
    const word: []const u8 = switch (details.feedback) {
        .none => return "None",
        .loved => "Loved",
        .hated => "Disliked",
    };
    if (details.feedback_syncable) return strings.terminated(buffer, word);
    return strings.format(buffer, "{s}\nWon't sync to ListenBrainz: no recording ID", .{word});
}

fn lastPlayedText(buffer: []u8, unix_seconds: ?i64) [:0]const u8 {
    const seconds = unix_seconds orelse return "Never";
    const played = gtk.g_date_time_new_from_unix_local(seconds) orelse return "Never";
    defer gtk.g_date_time_unref(played);
    const now = gtk.g_date_time_new_now_local() orelse return "Recently";
    defer gtk.g_date_time_unref(now);
    const yesterday = gtk.g_date_time_add_days(now, -1);
    defer if (yesterday) |value| gtk.g_date_time_unref(value);

    const day = formatted(played, "%F") orelse return "Recently";
    defer gtk.g_free(day);
    const clock = formatted(played, "%R") orelse return "Recently";
    defer gtk.g_free(clock);
    if (sameDay(day, now)) return strings.format(buffer, "Today, {s}", .{std.mem.span(clock)});
    if (yesterday) |value| {
        if (sameDay(day, value)) return strings.format(buffer, "Yesterday, {s}", .{std.mem.span(clock)});
    }
    const date = formatted(played, "%-d %b %Y") orelse return "Recently";
    defer gtk.g_free(date);
    return strings.format(buffer, "{s}, {s}", .{ std.mem.span(date), std.mem.span(clock) });
}

fn formatted(moment: *gtk.GDateTime, pattern: [*:0]const u8) ?[*:0]u8 {
    return gtk.g_date_time_format(moment, pattern);
}

fn sameDay(day: [*:0]const u8, moment: *gtk.GDateTime) bool {
    const other = formatted(moment, "%F") orelse return false;
    defer gtk.g_free(other);
    return std.mem.eql(u8, std.mem.span(day), std.mem.span(other));
}

fn decibelText(buffer: []u8, value: f32, comptime signed: bool, unit: []const u8) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeDecibels(&writer, value, signed) catch {};
    writer.writeAll(unit) catch {};
    return finish(buffer, &writer);
}

fn writeDecibels(writer: *std.Io.Writer, value: f32, comptime signed: bool) std.Io.Writer.Error!void {
    const tenths = @round(value * 10) / 10;
    if (tenths == 0) return writer.writeAll("0.0");
    const sign: []const u8 = if (tenths < 0) minus else if (signed) "+" else "";
    try writer.print("{s}{d:.1}", .{ sign, @abs(tenths) });
}

fn setLabel(label: *gtk.Widget, text: []const u8, buffer: []u8) void {
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), strings.terminated(buffer, text).ptr);
    gtk.gtk_widget_set_visible(label, boolean(text.len != 0));
}

/// Shows `text` as the row's value, or hides the row when there is none.
fn setRow(row: Row, text: ?[:0]const u8) bool {
    const value = text orelse {
        gtk.gtk_widget_set_visible(row.root, gtk.false_);
        return false;
    };
    gtk.gtk_label_set_text(row.value, value.ptr);
    gtk.gtk_widget_set_visible(row.root, gtk.true_);
    return true;
}

fn newKey(key: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(key);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_widget_set_valign(label, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(label, "inspector-key");
    return label;
}

fn newRow(key: [*:0]const u8) Row {
    const value = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value), 1.0);
    gtk.gtk_label_set_justify(gtk.cast(gtk.Label, value), gtk.JUSTIFY_RIGHT);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, value), gtk.true_);
    gtk.gtk_widget_set_hexpand(value, gtk.true_);
    gtk.gtk_widget_add_css_class(value, "inspector-value");
    gtk.gtk_widget_add_css_class(value, "numeric");
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "inspector-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), newKey(key));
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), value);
    return .{ .root = row, .value = gtk.cast(gtk.Label, value) };
}

fn newIdRow(key: [*:0]const u8) Row {
    const row = newRow(key);
    gtk.gtk_label_set_wrap(row.value, gtk.false_);
    gtk.gtk_label_set_ellipsize(row.value, gtk.ELLIPSIZE_MIDDLE);
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, row.value), "tech");
    gtk.gtk_widget_set_visible(row.root, gtk.false_);
    return row;
}

fn newLine(css_class: ?[*:0]const u8) Row {
    const label = newLabel(css_class);
    gtk.gtk_widget_add_css_class(label, "inspector-line");
    return .{ .root = label, .value = gtk.cast(gtk.Label, label) };
}

fn newSection(heading: [*:0]const u8, children: []const *gtk.Widget) *gtk.Widget {
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_add_css_class(section, "inspector-section");
    const title = gtk.gtk_label_new(heading);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_add_css_class(title, "inspector-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), title);
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, section), child);
    return section;
}

fn newLabel(css_class: ?[*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
    if (css_class) |name| gtk.gtk_widget_add_css_class(label, name);
    return label;
}

fn copyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const path = panel.path orelse return;
    gtk.gdk_clipboard_set_text(gtk.gtk_widget_get_clipboard(panel.copy_button), path.ptr);
    panel.self.toast("Path copied");
}

fn recordingLinkClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    matches.openRecording(panelData(data).self, matches.recordingOf(button) orelse return);
}

fn slotOf(button: ?*anyopaque) usize {
    return @intFromPtr(gtk.g_object_get_data(button.?, "orca-slot"));
}

fn proposalAcceptClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    matches.accept(panel.self, panel.shown orelse return, panel.proposal_ids[slotOf(button)]);
}

fn proposalDismissClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    matches.dismiss(panel.self, panel.shown orelse return, panel.proposal_ids[slotOf(button)]);
}

fn reviewAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    matches.reveal(panel.self, panel.shown orelse return);
}

fn verifyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    jobs.startTrackVerification(panel.self, panel.shown orelse return);
}

fn findMatchClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    jobs.startTrackMatching(panel.self, panel.shown orelse return);
}

fn starClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    ratings.changeTrack(panel.self, panel.shown orelse return, ratings.chosen(button));
}

fn iconButton(icon: [*:0]const u8, tooltip: [*:0]const u8, slot: usize) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    gtk.g_object_set_data(button, "orca-slot", @ptrFromInt(slot));
    return button;
}

fn newProposal(slot: usize) Proposal {
    const title = newLabel(null);
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, title), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    const subtitle = newLabel("tech");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, subtitle), gtk.false_);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, subtitle), gtk.ELLIPSIZE_END);
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), subtitle);
    const accept = iconButton("object-select-symbolic", "Accept", slot);
    const dismiss = iconButton("window-close-symbolic", "Dismiss", slot);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(row, "inspector-proposal");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), text);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), accept);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), dismiss);
    gtk.gtk_widget_set_visible(row, gtk.false_);
    return .{
        .root = row,
        .title = gtk.cast(gtk.Label, title),
        .subtitle = gtk.cast(gtk.Label, subtitle),
        .accept = accept,
        .dismiss = dismiss,
    };
}

fn actionButton(label: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "inspector-action");
    gtk.gtk_widget_set_visible(button, gtk.false_);
    return button;
}

fn modeToggle(icon: [*:0]const u8, tooltip: [*:0]const u8, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const button = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), icon);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    gtk.gtk_widget_add_css_class(button, "flat");
    _ = gtk.signalConnect(button, "toggled", handler, self);
    return button;
}

fn scrolled(child: *gtk.Widget) *gtk.Widget {
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), child);
    return scroller;
}

fn destroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const self = panel.self;
    for (&self.details_panels) |*slot| {
        if (slot.* == panel) slot.* = null;
    }
    setPath(panel, null);
    panel.lyrics.deinit();
    self.allocator.destroy(panel);
}

fn newPanel(self: *App, source: Source, page_content: *gtk.Widget) ?*Panel {
    const slot = for (&self.details_panels) |*candidate| {
        if (candidate.* == null) break candidate;
    } else return null;
    const panel = self.allocator.create(Panel) catch return null;

    const details_toggle = modeToggle("sidebar-show-right-symbolic", "Inspector", gtk.callback(detailsToggled), self);
    const lyrics_toggle = modeToggle("media-view-subtitles-symbolic", "Lyrics", gtk.callback(lyricsToggled), self);
    const signal_path_toggle = modeToggle("network-cellular-signal-excellent-symbolic", "Signal Path", gtk.callback(signalPathToggled), self);
    const toggles = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(toggles, "linked");
    gtk.gtk_widget_add_css_class(toggles, "inspector-toggles");
    for ([_]*gtk.Widget{ details_toggle, lyrics_toggle, signal_path_toggle }) |button|
        gtk.gtk_box_append(gtk.cast(gtk.Box, toggles), button);

    const title = newLabel("inspector-title");
    const artist = newLabel("meta");
    const album = newLabel("meta");
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(heading, "inspector-header");
    for ([_]*gtk.Widget{ title, artist, album }) |label| gtk.gtk_box_append(gtk.cast(gtk.Box, heading), label);

    const codec_line = newLine("inspector-value");
    const format_line = newLine("inspector-value");
    gtk.gtk_widget_add_css_class(format_line.root, "numeric");
    const bitrate_line = newLine("inspector-value");
    gtk.gtk_widget_add_css_class(bitrate_line.root, "numeric");
    const duration_line = newLine("inspector-value");
    gtk.gtk_widget_add_css_class(duration_line.root, "numeric");
    const loudness_missing = newLine("inspector-key");
    const integrated_row = newRow("Integrated");
    const peak_row = newRow("Sample peak");
    const replay_gain_row = newRow("ReplayGain");

    const musicbrainz_row = newRow("MusicBrainz");
    const recording_row = newIdRow("Recording");
    const match_status = newLine("meta");
    const acoustid_row = newRow("AcoustID");
    gtk.gtk_widget_set_visible(acoustid_row.root, gtk.false_);
    const release_id_row = newIdRow("Release");
    const release_group_id_row = newIdRow("Release group");
    const release_track_id_row = newIdRow("Release track");
    const album_artist_id_row = newIdRow("Album artist");
    var proposals: [proposal_slots]Proposal = undefined;
    for (&proposals, 0..) |*proposal, index| proposal.* = newProposal(index);
    const recording_link = matches.linkButton("");
    gtk.gtk_widget_add_css_class(recording_link, "inspector-action");
    const review_button = actionButton("Review All");
    const find_button = actionButton("Find Match");
    const verify_button = actionButton("Verify");
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(actions, "inspector-actions");
    for ([_]*gtk.Widget{ recording_link, review_button, find_button, verify_button }) |button|
        gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);

    const album_artist_row = newRow("Album artist");
    const date_row = newRow("Date");
    const track_row = newRow("Track");
    const disc_row = newRow("Disc");
    const compilation_row = newRow("Compilation");

    const feedback_row = newRow("Feedback");
    const rating_stars = ratings.newStars(gtk.callback(starClicked), panel);
    gtk.gtk_widget_set_hexpand(rating_stars, gtk.true_);
    gtk.gtk_widget_set_halign(rating_stars, gtk.ALIGN_END);
    const rating_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(rating_row, "inspector-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, rating_row), newKey("Rating"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, rating_row), rating_stars);
    const plays_row = newRow("Plays");
    const last_played_row = newRow("Last played");

    const size_line = newLine("inspector-value");
    gtk.gtk_widget_add_css_class(size_line.root, "numeric");
    const path_label = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, path_label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, path_label), gtk.ELLIPSIZE_MIDDLE);
    gtk.gtk_widget_set_hexpand(path_label, gtk.true_);
    gtk.gtk_widget_add_css_class(path_label, "tech");
    const copy_button = gtk.gtk_button_new_from_icon_name("edit-copy-symbolic");
    gtk.gtk_widget_set_valign(copy_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(copy_button, "flat");
    gtk.gtk_widget_set_tooltip_text(copy_button, "Copy path");
    const path_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, path_row), path_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, path_row), copy_button);

    const audio_section = newSection("Audio", &.{ codec_line.root, format_line.root, bitrate_line.root, duration_line.root });
    const loudness_section = newSection("Loudness", &.{ loudness_missing.root, integrated_row.root, peak_row.root, replay_gain_row.root });
    const identity_section = newSection("Identity", &.{
        musicbrainz_row.root,
        recording_row.root,
        match_status.root,
        acoustid_row.root,
        release_id_row.root,
        release_group_id_row.root,
        release_track_id_row.root,
        album_artist_id_row.root,
        proposals[0].root,
        proposals[1].root,
        proposals[2].root,
        actions,
    });
    const metadata_section = newSection("Metadata", &.{ album_artist_row.root, date_row.root, track_row.root, disc_row.root, compilation_row.root });
    const history_section = newSection("History", &.{ feedback_row.root, rating_row, plays_row.root, last_played_row.root });
    const file_section = newSection("File", &.{ size_line.root, path_row });

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_visible(content, gtk.false_);
    for ([_]*gtk.Widget{ heading, audio_section, loudness_section, identity_section, metadata_section, history_section, file_section }) |section|
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), section);

    const placeholder = gtk.gtk_label_new("Select a song to see its details.");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, placeholder), gtk.true_);
    gtk.gtk_widget_add_css_class(placeholder, "dim-label");
    gtk.gtk_widget_set_margin_top(placeholder, 24);

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(body, "inspector-body");
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), placeholder);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), content);

    const signal_title = newLabel("inspector-title");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, signal_title), "Signal Path");
    const signal_status = newLabel("dim-label");
    gtk.gtk_widget_set_margin_top(signal_status, 12);
    const signal_dot = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(signal_dot, "signal-dot");
    gtk.gtk_widget_set_valign(signal_dot, gtk.ALIGN_START);
    const signal_verdict_label = newLabel("inspector-value");
    gtk.gtk_widget_set_hexpand(signal_verdict_label, gtk.true_);
    const signal_verdict = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(signal_verdict, "signal-verdict");
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_verdict), signal_dot);
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_verdict), signal_verdict_label);
    const signal_flow = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(signal_flow, "signal-flow");
    const signal_note = newLabel("tech");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, signal_note), signal_path.pipewire_hedge);
    const signal_body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(signal_body, "inspector-body");
    for ([_]*gtk.Widget{ signal_title, signal_status, signal_verdict, signal_flow, signal_note }) |widget|
        gtk.gtk_box_append(gtk.cast(gtk.Box, signal_body), widget);

    const root = gtk.gtk_stack_new();
    gtk.gtk_widget_add_css_class(root, "inspector");
    gtk.gtk_widget_set_vexpand(root, gtk.true_);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, root), scrolled(body), "details");

    const split = adw.adw_overlay_split_view_new();
    const split_view = gtk.cast(adw.OverlaySplitView, split);
    adw.adw_overlay_split_view_set_sidebar_position(split_view, gtk.PACK_END);
    adw.adw_overlay_split_view_set_pin_sidebar(split_view, gtk.true_);
    adw.adw_overlay_split_view_set_enable_show_gesture(split_view, gtk.false_);
    adw.adw_overlay_split_view_set_min_sidebar_width(split_view, panel_min_width);
    adw.adw_overlay_split_view_set_max_sidebar_width(split_view, panel_max_width);
    gtk.gtk_widget_set_hexpand(page_content, gtk.true_);
    adw.adw_overlay_split_view_set_content(split_view, page_content);
    adw.adw_overlay_split_view_set_sidebar(split_view, root);

    panel.* = .{
        .self = self,
        .source = source,
        .split = split,
        .root = root,
        .toggles = toggles,
        .details_toggle = details_toggle,
        .lyrics_toggle = lyrics_toggle,
        .signal_path_toggle = signal_path_toggle,
        .placeholder = placeholder,
        .content = content,
        .title = title,
        .artist = artist,
        .album = album,
        .audio_section = audio_section,
        .codec_line = codec_line,
        .format_line = format_line,
        .bitrate_line = bitrate_line,
        .duration_line = duration_line,
        .loudness_missing = loudness_missing,
        .integrated_row = integrated_row,
        .peak_row = peak_row,
        .replay_gain_row = replay_gain_row,
        .musicbrainz_row = musicbrainz_row,
        .recording_row = recording_row,
        .match_status = match_status,
        .acoustid_row = acoustid_row,
        .release_id_row = release_id_row,
        .release_group_id_row = release_group_id_row,
        .release_track_id_row = release_track_id_row,
        .album_artist_id_row = album_artist_id_row,
        .proposals = proposals,
        .recording_link = recording_link,
        .review_button = review_button,
        .find_button = find_button,
        .verify_button = verify_button,
        .metadata_section = metadata_section,
        .album_artist_row = album_artist_row,
        .date_row = date_row,
        .track_row = track_row,
        .disc_row = disc_row,
        .compilation_row = compilation_row,
        .feedback_row = feedback_row,
        .rating_stars = rating_stars,
        .plays_row = plays_row,
        .last_played_row = last_played_row,
        .size_line = size_line,
        .path_label = gtk.cast(gtk.Label, path_label),
        .copy_button = copy_button,
        .signal_status = gtk.cast(gtk.Label, signal_status),
        .signal_verdict = signal_verdict,
        .signal_dot = signal_dot,
        .signal_verdict_label = gtk.cast(gtk.Label, signal_verdict_label),
        .signal_flow = signal_flow,
        .signal_note = signal_note,
    };
    _ = gtk.signalConnect(copy_button, "clicked", gtk.callback(copyClicked), panel);
    _ = gtk.signalConnect(recording_link, "clicked", gtk.callback(recordingLinkClicked), panel);
    for (proposals) |proposal| {
        _ = gtk.signalConnect(proposal.accept, "clicked", gtk.callback(proposalAcceptClicked), panel);
        _ = gtk.signalConnect(proposal.dismiss, "clicked", gtk.callback(proposalDismissClicked), panel);
    }
    _ = gtk.signalConnect(review_button, "clicked", gtk.callback(reviewAllClicked), panel);
    _ = gtk.signalConnect(find_button, "clicked", gtk.callback(findMatchClicked), panel);
    _ = gtk.signalConnect(verify_button, "clicked", gtk.callback(verifyClicked), panel);
    panel.lyrics.init(self);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, root), panel.lyrics.root, "lyrics");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, root), scrolled(signal_body), "signal_path");
    _ = gtk.signalConnect(root, "destroy", gtk.callback(destroyed), panel);
    _ = gtk.signalConnect(split, "notify::show-sidebar", gtk.callback(sidebarShownChanged), panel);
    slot.* = panel;

    const mode = shownMode(self);
    showMode(panel, mode);
    update(panel);
    if (mode == .signal_path) transport.refreshSignalPath(self);
    return panel;
}

pub const Placed = struct {
    widget: *gtk.Widget,
    panel: ?*Panel,
};

/// `content` with an inspector at its end, and the inspector's mode toggles at
/// the end of `header`. Without a free panel slot, `content` alone.
pub fn besideContent(self: *App, header: *gtk.Widget, content: *gtk.Widget, source: Source) Placed {
    const panel = newPanel(self, source, content) orelse return .{ .widget = content, .panel = null };
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), panel.toggles);
    return .{ .widget = panel.split, .panel = panel };
}
