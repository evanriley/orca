//! What every content page shares: the window's one top bar — Back and
//! Forward, the trail to the page showing and the library search — and the
//! title block that opens the content with the
//! page's name and its count.

const std = @import("std");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const palette = @import("palette.zig");
const window = @import("window.zig");
const strings = @import("strings.zig");
const preferences = @import("preferences.zig");
const nowplaying = @import("nowplaying.zig");
const radio = @import("radio.zig");
const smart_playlist_editor = @import("smart_playlist_editor.zig");
const metadata_editor = @import("metadata_editor.zig");
const write_tags = @import("write_tags.zig");

const App = app.App;

pub const side_panel_width: c_int = 388;

pub const Bar = struct {
    widget: ?*gtk.Widget = null,
    view: ?*adw.ToolbarView = null,
    back: ?*gtk.Widget = null,
    forward: ?*gtk.Widget = null,
    trail: ?*gtk.Stack = null,
    parent: ?*gtk.Widget = null,
    current: ?*gtk.Label = null,
    search: ?*gtk.Stack = null,
    entry: ?*gtk.Widget = null,
    editor_actions: ?*gtk.Widget = null,
    editor_save: ?*gtk.Widget = null,
    end: ?*gtk.Stack = null,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn historyButton(icon: [*:0]const u8, label: [*:0]const u8, tooltip: [*:0]const u8, clicked: gtk.GCallback, self: *App) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "history-button");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, label, @as(c_int, -1));
    gtk.gtk_widget_set_sensitive(button, gtk.false_);
    _ = gtk.signalConnect(button, "clicked", clicked, self);
    return button;
}

fn backClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.back(state(data));
}

fn forwardClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.forward(state(data));
}

fn parentClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.popSection(state(data));
}

fn buildTrail(self: *App) *gtk.Widget {
    const parent = gtk.gtk_button_new_with_label("");
    gtk.gtk_widget_add_css_class(parent, "flat");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    _ = gtk.signalConnect(parent, "clicked", gtk.callback(parentClicked), self);
    const separator = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(separator, "breadcrumb-separator");
    const current = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(current, "breadcrumb-current");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, current), gtk.ELLIPSIZE_END);
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    gtk.gtk_box_append(gtk.cast(gtk.Box, crumbs), parent);
    gtk.gtk_box_append(gtk.cast(gtk.Box, crumbs), separator);
    gtk.gtk_box_append(gtk.cast(gtk.Box, crumbs), current);

    const trail = gtk.gtk_stack_new();
    gtk.gtk_stack_set_hhomogeneous(gtk.cast(gtk.Stack, trail), gtk.false_);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, trail), crumbs, "trail");
    self.top_bar.trail = gtk.cast(gtk.Stack, trail);
    self.top_bar.parent = parent;
    self.top_bar.current = gtk.cast(gtk.Label, current);
    return trail;
}

fn buildSearch(self: *App) *gtk.Widget {
    const entry = gtk.gtk_search_entry_new();
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), "Search your library…");
    gtk.gtk_search_entry_set_search_delay(gtk.cast(gtk.SearchEntry, entry), app.search_delay_ms);
    if (gtk.gtk_widget_get_first_child(entry)) |icon| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, icon), "orca-search-symbolic");
    if (gtk.gtk_widget_get_last_child(entry)) |icon| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, icon), "orca-close-symbolic");
    _ = gtk.signalConnect(entry, "search-changed", gtk.callback(window.searchChanged), self);
    _ = gtk.signalConnect(entry, "activate", gtk.callback(window.searchActivated), self);
    const hint = gtk.gtk_label_new("Ctrl K");
    gtk.gtk_widget_add_css_class(hint, "keycap-hint");
    gtk.gtk_widget_set_halign(hint, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(hint, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_can_target(hint, gtk.false_);
    const field = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(field, "library-search");
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, field), entry);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, field), hint);

    const button = gtk.gtk_button_new_from_icon_name("orca-search-symbolic");
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, "Search your library");
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, button), "app.search");

    const switcher = gtk.gtk_stack_new();
    gtk.gtk_stack_set_hhomogeneous(gtk.cast(gtk.Stack, switcher), gtk.false_);
    gtk.gtk_widget_set_valign(switcher, gtk.ALIGN_CENTER);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, switcher), field, "entry");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, switcher), button, "icon");
    self.top_bar.search = gtk.cast(gtk.Stack, switcher);
    self.top_bar.entry = entry;
    showSearch(self);
    palette.attach(self, entry);
    return switcher;
}

fn editorCancelClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (metadata_editor.isShown(self)) return metadata_editor.cancelShown(self);
    smart_playlist_editor.cancelShown(self);
}

fn editorSaveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (metadata_editor.isShown(self)) return metadata_editor.applyShown(self);
    smart_playlist_editor.saveShown(self);
}

fn buildEditorActions(self: *App) *gtk.Widget {
    const cancel = gtk.gtk_button_new_with_label("Cancel");
    gtk.gtk_widget_add_css_class(cancel, "btn-secondary");
    gtk.gtk_widget_set_valign(cancel, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(cancel, "clicked", gtk.callback(editorCancelClicked), self);
    const save = gtk.gtk_button_new_with_label("Save Smart Playlist");
    gtk.gtk_widget_add_css_class(save, "btn-primary");
    gtk.gtk_widget_add_css_class(save, "smart-save");
    gtk.gtk_widget_set_valign(save, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(save, "clicked", gtk.callback(editorSaveClicked), self);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), cancel);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), save);
    gtk.gtk_widget_set_visible(actions, gtk.false_);
    self.top_bar.editor_actions = actions;
    self.top_bar.editor_save = save;
    return actions;
}

pub fn build(self: *App) *gtk.Widget {
    const bar = adw.adw_header_bar_new();
    adw.adw_header_bar_set_show_title(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    adw.adw_header_bar_set_show_start_title_buttons(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    adw.adw_header_bar_set_show_end_title_buttons(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    gtk.gtk_widget_add_css_class(bar, "page-header");
    self.top_bar.widget = bar;
    const back = historyButton("orca-back-symbolic", "Back", "Back (Alt+Left)", gtk.callback(backClicked), self);
    const forward = historyButton("orca-forward-symbolic", "Forward", "Forward (Alt+Right)", gtk.callback(forwardClicked), self);
    self.top_bar.back = back;
    self.top_bar.forward = forward;
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), back);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), forward);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), buildTrail(self));
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, bar), buildEditorActions(self));
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, bar), buildSearch(self));
    const end = gtk.gtk_stack_new();
    gtk.gtk_widget_set_visible(end, gtk.false_);
    self.top_bar.end = gtk.cast(gtk.Stack, end);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, bar), end);
    return bar;
}

pub fn breakpointBin(child: *gtk.Widget) *gtk.Widget {
    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), child);
    return bin;
}

pub fn stackBelow(bin: *gtk.Widget, condition: [*:0]const u8, stacked: []const *gtk.Widget, expanded: []const *gtk.Widget) void {
    const parsed = adw.adw_breakpoint_condition_parse(condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(parsed);
    for (stacked) |widget| {
        var value: gtk.GValue = .{};
        _ = gtk.g_value_init(&value, gtk.gtk_orientation_get_type());
        gtk.g_value_set_enum(&value, gtk.ORIENTATION_VERTICAL);
        adw.adw_breakpoint_add_setter(breakpoint, widget, "orientation", &value);
        gtk.g_value_unset(&value);
    }
    for (expanded) |widget| {
        var value: gtk.GValue = .{};
        _ = gtk.g_value_init(&value, gtk.G_TYPE_BOOLEAN);
        gtk.g_value_set_boolean(&value, gtk.true_);
        adw.adw_breakpoint_add_setter(breakpoint, widget, "vexpand", &value);
        gtk.g_value_unset(&value);
    }
    adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
}

const under_bar_key = "orca-under-bar";
const under_bar_scroller_key = "orca-under-bar-scroller";

pub fn extendUnderBar(self: *App, page_root: *gtk.Widget, scroller: ?*gtk.Widget) void {
    gtk.g_object_set_data(page_root, under_bar_key, page_root);
    const scrolls_under = scroller orelse return;
    gtk.g_object_set_data(page_root, under_bar_scroller_key, scrolls_under);
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scrolls_under));
    _ = gtk.signalConnect(adjustment, "value-changed", gtk.callback(underBarScrolled), self);
}

fn underBarScrolled(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const bar = self.top_bar.widget orelse return;
    setClass(bar, "over-scrolled", scrolledUnderBar(self));
}

fn scrolledUnderBar(self: *App) bool {
    const page_root = shownUnderBarPage(self) orelse return false;
    const scroller = gtk.g_object_get_data(page_root, under_bar_scroller_key) orelse return false;
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)) orelse return false;
    return gtk.gtk_adjustment_get_value(adjustment) > 0;
}

fn shownUnderBarPage(self: *App) ?*gtk.Widget {
    const pushed = window.pushedPage(self, self.current_page) orelse return null;
    const page_root = adw.adw_navigation_page_get_child(pushed) orelse return null;
    if (gtk.g_object_get_data(page_root, under_bar_key) == null) return null;
    return page_root;
}

fn shownPageRoot(self: *App) ?*gtk.Widget {
    if (window.pageNavigation(self, self.current_page)) |navigation| {
        const visible = adw.adw_navigation_view_get_visible_page(navigation) orelse return null;
        return adw.adw_navigation_page_get_child(visible);
    }
    const pages = self.pages orelse return null;
    return gtk.gtk_stack_get_child_by_name(pages, self.current_page.name());
}

fn setClass(widget: *gtk.Widget, class: [*:0]const u8, shown: bool) void {
    if (shown) gtk.gtk_widget_add_css_class(widget, class) else gtk.gtk_widget_remove_css_class(widget, class);
}

pub fn coverContent(self: *App, view: *adw.ToolbarView) void {
    // Toggling this restyles every page under the view (~230 ms); pages below the bar take a top margin instead.
    adw.adw_toolbar_view_set_extend_content_to_top_edge(view, gtk.true_);
    _ = gtk.signalConnect(view, "notify::top-bar-height", gtk.callback(barHeightChanged), self);
}

fn barHeightChanged(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = gtk.g_idle_add(fitLater, data);
}

fn fitLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    fitToPage(state(data));
    return gtk.SOURCE_REMOVE;
}

pub fn fitToPage(self: *App) void {
    const bar = self.top_bar.widget orelse return;
    const view = self.top_bar.view orelse return;
    const playing = self.current_page == .now_playing;
    const radio_docked = self.current_page == .queue and radio.docked(self);
    const over = playing or radio_docked or shownUnderBarPage(self) != null;
    setClass(bar, "over-page", over);
    setClass(bar, "over-scrolled", scrolledUnderBar(self));
    if (shownPageRoot(self)) |page_root|
        gtk.gtk_widget_set_margin_top(page_root, if (over) 0 else adw.adw_toolbar_view_get_top_bar_height(view));
    const view_widget = gtk.cast(gtk.Widget, view);
    radio.fitUnderBar(self, if (radio_docked) adw.adw_toolbar_view_get_top_bar_height(view) else 0);
    const panel_width = if (playing) nowplaying.panelWidth(self) else if (radio_docked) side_panel_width else 0;
    gtk.gtk_widget_set_margin_end(barRow(bar, view_widget), panel_width);
    for ([_]?*gtk.Widget{ self.top_bar.back, self.top_bar.forward }) |button|
        if (button) |history| gtk.gtk_widget_set_visible(history, @intFromBool(!playing));
    gtk.gtk_widget_set_visible(bar, @intFromBool(self.current_page != .scan));
}

// The margin goes on the toolbar view's own child: an ancestor of the bar left full width takes the Now Playing panel's clicks.
fn barRow(bar: *gtk.Widget, view: *gtk.Widget) *gtk.Widget {
    var row = bar;
    while (gtk.gtk_widget_get_parent(row)) |parent| : (row = parent) {
        if (parent == view) return row;
    }
    return bar;
}

pub fn addTrail(self: *App, page: window.Page, crumbs: *gtk.Widget) void {
    const trail = self.top_bar.trail orelse return;
    _ = gtk.gtk_stack_add_named(trail, crumbs, page.name());
}

/// Shows `widget` at the end of the bar in place of the search while `page`
/// is showing.
pub fn addEnd(self: *App, page: window.Page, widget: *gtk.Widget) void {
    const end = self.top_bar.end orelse return;
    _ = gtk.gtk_stack_add_named(end, widget, page.name());
}

fn hasEnd(self: *App) bool {
    const end = self.top_bar.end orelse return false;
    return gtk.gtk_stack_get_child_by_name(end, self.current_page.name()) != null;
}

fn showEnd(self: *App) void {
    const end = self.top_bar.end orelse return;
    // The page's own end controls do not fit beside the trail in a narrow window.
    const shown = hasEnd(self) and !self.window_narrow;
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, end), @intFromBool(shown));
    if (shown) gtk.gtk_stack_set_visible_child_name(end, self.current_page.name());
}

pub fn refresh(self: *App) void {
    const bar = &self.top_bar;
    if (bar.back) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(window.canGoBack(self)));
    if (bar.forward) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(window.canGoForward(self)));
    showTrail(self);
    showEditorActions(self);
    showEnd(self);
    showPlaceholder(self);
    showWindowTitle(self);
    fitToPage(self);
}

fn placeholder(self: *App) [*:0]const u8 {
    if (self.current_page == .settings) return "Search settings…";
    const page = window.filterTarget(self) orelse return "Search your library…";
    return switch (page) {
        .albums => "Search albums, artists or genres…",
        .artists => "Search artists…",
        .tracks => "Search tracks, artists, albums…",
        .genres => "Search genres…",
        .folders => "Search this folder…",
        .playlists => "Search playlists…",
        .loved => "Search loved…",
        else => "Search your library…",
    };
}

fn showPlaceholder(self: *App) void {
    const entry = self.top_bar.entry orelse return;
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), placeholder(self));
    const field = gtk.gtk_widget_get_parent(entry) orelse return;
    const hint = gtk.gtk_widget_get_last_child(field) orelse return;
    if (hint == entry) return;
    const in_folder = self.current_page == .folders and window.filterTarget(self) != null;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, hint), if (in_folder) "Ctrl F" else "Ctrl K");
}

pub fn showWindowTitle(self: *App) void {
    const root = self.window orelse return;
    const page = self.current_page;
    var buffer: [512]u8 = undefined;
    const text: [:0]const u8 = if (window.pushedPage(self, page)) |pushed|
        strings.printZ(&buffer, "Orca — {s}", .{adw.adw_navigation_page_get_title(pushed)}) catch "Orca"
    else if (page == .settings)
        strings.printZ(&buffer, "Orca — Settings · {s}", .{preferences.tabLabel(self.settings_page.tab)}) catch "Orca"
    else
        strings.printZ(&buffer, "Orca — {s}", .{page.windowTitle()}) catch "Orca";
    gtk.gtk_window_set_title(root, text.ptr);
}

fn showTrail(self: *App) void {
    const bar = &self.top_bar;
    const trail = bar.trail orelse return;
    const page = self.current_page;
    if (gtk.gtk_stack_get_child_by_name(trail, page.name()) != null) {
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, trail), gtk.true_);
        gtk.gtk_stack_set_visible_child_name(trail, page.name());
        return;
    }
    const pushed = window.pushedPage(self, page) orelse {
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, trail), gtk.false_);
        return;
    };
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, trail), gtk.true_);
    gtk.gtk_stack_set_visible_child_name(trail, "trail");
    const navigation = window.pageNavigation(self, page).?;
    var previous = adw.adw_navigation_view_get_previous_page(navigation, pushed);
    while (previous) |shown| {
        if (!metadata_editor.isEditorPage(shown)) break;
        previous = adw.adw_navigation_view_get_previous_page(navigation, shown);
    }
    const parent = if (previous) |shown| adw.adw_navigation_page_get_title(shown) else page.title();
    if (bar.parent) |button| gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), parent);
    if (bar.current) |label| gtk.gtk_label_set_text(label, adw.adw_navigation_page_get_title(pushed));
}

fn showEditorActions(self: *App) void {
    const metadata = metadata_editor.isShown(self);
    const editing = metadata or smart_playlist_editor.isShown(self);
    if (self.top_bar.editor_save) |save| {
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, save), if (metadata) "Apply to Orca" else "Save Smart Playlist");
    }
    if (self.top_bar.editor_actions) |actions| gtk.gtk_widget_set_visible(actions, @intFromBool(editing));
    const searching = !editing and !write_tags.isShown(self) and self.current_page != .duplicates and !hasEnd(self);
    if (self.top_bar.search) |search| gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, search), @intFromBool(searching));
}

fn showSearch(self: *App) void {
    const switcher = self.top_bar.search orelse return;
    gtk.gtk_stack_set_visible_child_name(switcher, if (self.header_compact) "icon" else "entry");
}

pub fn setCompact(self: *App, compact: bool) void {
    self.header_compact = compact;
    showSearch(self);
    showEnd(self);
}

pub const Title = struct {
    widget: *gtk.Widget,
    title: *gtk.Label,
    meta: *gtk.Label,
    end: *adw.WrapBox,

    pub fn add(self: Title, control: *gtk.Widget) void {
        adw.adw_wrap_box_append(self.end, control);
    }
};

pub fn title(text: [*:0]const u8) Title {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "page-title");
    const text_box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text_box, gtk.true_);
    const name = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(name, "display-page");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    const meta = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(meta, "meta");
    gtk.gtk_widget_add_css_class(meta, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, meta), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, meta), gtk.ELLIPSIZE_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text_box), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text_box), meta);
    const end = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, end), 8);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, end), 8);
    adw.adw_wrap_box_set_align(gtk.cast(adw.WrapBox, end), 1.0);
    gtk.gtk_widget_set_valign(end, gtk.ALIGN_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), text_box);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), end);
    return .{
        .widget = row,
        .title = gtk.cast(gtk.Label, name),
        .meta = gtk.cast(gtk.Label, meta),
        .end = gtk.cast(adw.WrapBox, end),
    };
}

pub fn withTitle(block: Title, body: *gtk.Widget) *gtk.Widget {
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), block.widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), body);
    return column;
}

pub const Scroll = struct {
    scroller: *gtk.Widget,
    value: f64,
};

fn verticalAdjustment(scroller: *gtk.Widget) ?*gtk.Adjustment {
    return gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
}

pub fn scrollOf(scroller: *gtk.Widget) Scroll {
    const adjustment = verticalAdjustment(scroller) orelse return .{ .scroller = scroller, .value = 0 };
    return .{ .scroller = scroller, .value = gtk.gtk_adjustment_get_value(adjustment) };
}

pub fn visibleScroll(body: ?*gtk.Stack) ?Scroll {
    const stack = body orelse return null;
    const name = gtk.gtk_stack_get_visible_child_name(stack) orelse return null;
    if (std.mem.eql(u8, std.mem.span(name), "empty")) return null;
    return scrollOf(gtk.gtk_stack_get_child_by_name(stack, name) orelse return null);
}

pub fn styleShownChildOnly(stack: *gtk.Stack) void {
    _ = gtk.signalConnect(stack, "notify::transition-running", gtk.callback(stackTransitionChanged), null);
    hideUnshownChildren(stack);
    _ = gtk.g_idle_add_full(gtk.PRIORITY_LOW, startStylingUnshownChildren, gtk.g_object_ref(stack), gtk.g_object_unref);
}

fn startStylingUnshownChildren(stack: ?*anyopaque) callconv(.c) gtk.gboolean {
    _ = gtk.gtk_widget_add_tick_callback(gtk.cast(gtk.Widget, stack.?), styleNextUnshownChild, null, null);
    return gtk.SOURCE_REMOVE;
}

const styling_key = "orca-styling-unshown-child";
const styling_started_key = "orca-styling-started";

fn styleNextUnshownChild(widget: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) gtk.gboolean {
    const stack = gtk.cast(gtk.Stack, widget.?);
    if (gtk.g_object_get_data(stack, styling_started_key) == null) {
        gtk.g_object_set_data(stack, styling_started_key, stack);
        return gtk.SOURCE_CONTINUE;
    }
    const styled: ?*gtk.Widget = @ptrCast(@alignCast(gtk.g_object_get_data(stack, styling_key)));
    var next = if (styled) |child| next: {
        if (child != gtk.gtk_stack_get_visible_child(stack) and gtk.gtk_stack_get_transition_running(stack) == 0)
            gtk.gtk_widget_set_visible(child, gtk.false_);
        break :next gtk.gtk_widget_get_next_sibling(child);
    } else gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, stack));
    while (next) |child| : (next = gtk.gtk_widget_get_next_sibling(child)) {
        if (gtk.gtk_widget_get_visible(child) == 0) break;
    }
    gtk.g_object_set_data(stack, styling_key, next);
    const child = next orelse return gtk.SOURCE_REMOVE;
    gtk.gtk_widget_set_visible(child, gtk.true_);
    return gtk.SOURCE_CONTINUE;
}

// gtk_stack_set_visible_child_name ignores a hidden child, so a stack set up with styleShownChildOnly would never switch.
pub fn showChild(stack: *gtk.Stack, name: [*:0]const u8) void {
    const child = gtk.gtk_stack_get_child_by_name(stack, name) orelse return;
    gtk.gtk_widget_set_visible(child, gtk.true_);
    gtk.gtk_stack_set_visible_child(stack, child);
    hideUnshownChildren(stack);
}

fn stackTransitionChanged(stack: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    hideUnshownChildren(gtk.cast(gtk.Stack, stack.?));
}

fn hideUnshownChildren(stack: *gtk.Stack) void {
    if (gtk.gtk_stack_get_transition_running(stack) != 0) return;
    const shown = gtk.gtk_stack_get_visible_child(stack);
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, stack));
    while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
        if (widget != shown) gtk.gtk_widget_set_visible(widget, gtk.false_);
    }
}

const PendingScroll = struct {
    allocator: std.mem.Allocator,
    scroll: Scroll,
};

pub fn restoreScroll(self: *App, scroll: Scroll) void {
    if (!(scroll.value > 0)) return;
    const pending = self.allocator.create(PendingScroll) catch return;
    pending.* = .{ .allocator = self.allocator, .scroll = scroll };
    _ = gtk.g_object_ref(scroll.scroller);
    _ = gtk.g_idle_add(restoreScrollIdle, pending);
}

fn restoreScrollIdle(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const pending: *PendingScroll = @ptrCast(@alignCast(data.?));
    const scroller = pending.scroll.scroller;
    if (gtk.gtk_widget_get_root(scroller) != null) if (verticalAdjustment(scroller)) |adjustment| gtk.gtk_adjustment_set_value(adjustment, pending.scroll.value);
    gtk.g_object_unref(scroller);
    pending.allocator.destroy(pending);
    return gtk.SOURCE_REMOVE;
}
