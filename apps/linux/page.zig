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

const App = app.App;

pub const Bar = struct {
    back: ?*gtk.Widget = null,
    forward: ?*gtk.Widget = null,
    trail: ?*gtk.Stack = null,
    parent: ?*gtk.Widget = null,
    current: ?*gtk.Label = null,
    search: ?*gtk.Stack = null,
    entry: ?*gtk.Widget = null,
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

pub fn build(self: *App) *gtk.Widget {
    const bar = adw.adw_header_bar_new();
    adw.adw_header_bar_set_show_title(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    adw.adw_header_bar_set_show_start_title_buttons(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    adw.adw_header_bar_set_show_end_title_buttons(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    gtk.gtk_widget_add_css_class(bar, "page-header");
    const back = historyButton("orca-back-symbolic", "Back", "Back (Alt+Left)", gtk.callback(backClicked), self);
    const forward = historyButton("orca-forward-symbolic", "Forward", "Forward (Alt+Right)", gtk.callback(forwardClicked), self);
    self.top_bar.back = back;
    self.top_bar.forward = forward;
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), back);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), forward);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), buildTrail(self));
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, bar), buildSearch(self));
    return bar;
}

pub fn addTrail(self: *App, page: window.Page, crumbs: *gtk.Widget) void {
    const trail = self.top_bar.trail orelse return;
    _ = gtk.gtk_stack_add_named(trail, crumbs, page.name());
}

pub fn refresh(self: *App) void {
    const bar = &self.top_bar;
    if (bar.back) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(window.canGoBack(self)));
    if (bar.forward) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(window.canGoForward(self)));
    showTrail(self);
    showPlaceholder(self);
    showWindowTitle(self);
}

fn placeholder(self: *App) [*:0]const u8 {
    if (self.current_page == .settings) return "Search settings…";
    const page = window.filterTarget(self) orelse return "Search your library…";
    return switch (page) {
        .albums => "Search albums, artists or genres…",
        .artists => "Search artists…",
        .tracks => "Search tracks, artists, albums…",
        .playlists => "Search playlists…",
        else => "Search your library…",
    };
}

fn showPlaceholder(self: *App) void {
    const entry = self.top_bar.entry orelse return;
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), placeholder(self));
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
    const parent = if (adw.adw_navigation_view_get_previous_page(navigation, pushed)) |previous|
        adw.adw_navigation_page_get_title(previous)
    else
        page.title();
    if (bar.parent) |button| gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), parent);
    if (bar.current) |label| gtk.gtk_label_set_text(label, adw.adw_navigation_page_get_title(pushed));
}

fn showSearch(self: *App) void {
    const switcher = self.top_bar.search orelse return;
    gtk.gtk_stack_set_visible_child_name(switcher, if (self.header_compact) "icon" else "entry");
}

pub fn setCompact(self: *App, compact: bool) void {
    self.header_compact = compact;
    showSearch(self);
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

fn verticalAdjustment(scroller: *gtk.Widget) *gtk.Adjustment {
    return gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
}

pub fn scrollOf(scroller: *gtk.Widget) Scroll {
    return .{ .scroller = scroller, .value = gtk.gtk_adjustment_get_value(verticalAdjustment(scroller)) };
}

pub fn visibleScroll(body: ?*gtk.Stack) ?Scroll {
    const stack = body orelse return null;
    const name = gtk.gtk_stack_get_visible_child_name(stack) orelse return null;
    if (std.mem.eql(u8, std.mem.span(name), "empty")) return null;
    return scrollOf(gtk.gtk_stack_get_child_by_name(stack, name) orelse return null);
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
    if (gtk.gtk_widget_get_root(scroller) != null) gtk.gtk_adjustment_set_value(verticalAdjustment(scroller), pending.scroll.value);
    gtk.g_object_unref(scroller);
    pending.allocator.destroy(pending);
    return gtk.SOURCE_REMOVE;
}
