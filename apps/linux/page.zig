//! What every content page shares: the window's one top bar — Back and
//! Forward, the trail to the page showing, the library search and the showing
//! page's panel toggles — and the title block that opens the content with the
//! page's name and its count.

const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const palette = @import("palette.zig");
const window = @import("window.zig");

const App = app.App;

pub const Bar = struct {
    back: ?*gtk.Widget = null,
    forward: ?*gtk.Widget = null,
    trail: ?*gtk.Stack = null,
    parent: ?*gtk.Widget = null,
    separator: ?*gtk.Widget = null,
    current: ?*gtk.Label = null,
    search: ?*gtk.Stack = null,
    entry: ?*gtk.Widget = null,
    panels: ?*gtk.Stack = null,
};

const no_panel = "none";

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn historyButton(icon: [*:0]const u8, label: [*:0]const u8, tooltip: [*:0]const u8, clicked: gtk.GCallback, self: *App) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_add_css_class(button, "flat");
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
    self.top_bar.separator = separator;
    self.top_bar.current = gtk.cast(gtk.Label, current);
    return trail;
}

fn buildSearch(self: *App) *gtk.Widget {
    const entry = gtk.gtk_search_entry_new();
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), "Search your library…");
    gtk.gtk_search_entry_set_search_delay(gtk.cast(gtk.SearchEntry, entry), app.search_delay_ms);
    gtk.gtk_widget_set_hexpand(entry, gtk.true_);
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

    const button = gtk.gtk_button_new_from_icon_name("system-search-symbolic");
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

fn buildPanelSlot(self: *App) *gtk.Widget {
    const slot = gtk.gtk_stack_new();
    gtk.gtk_stack_set_hhomogeneous(gtk.cast(gtk.Stack, slot), gtk.true_);
    gtk.gtk_widget_set_valign(slot, gtk.ALIGN_CENTER);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, slot), gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0), no_panel);
    self.top_bar.panels = gtk.cast(gtk.Stack, slot);
    return slot;
}

pub fn build(self: *App) *gtk.Widget {
    const bar = adw.adw_header_bar_new();
    adw.adw_header_bar_set_show_title(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    gtk.gtk_widget_add_css_class(bar, "page-header");
    const back = historyButton("go-previous-symbolic", "Back", "Back (Alt+Left)", gtk.callback(backClicked), self);
    const forward = historyButton("go-next-symbolic", "Forward", "Forward (Alt+Right)", gtk.callback(forwardClicked), self);
    self.top_bar.back = back;
    self.top_bar.forward = forward;
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), back);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), forward);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), buildTrail(self));
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, bar), buildPanelSlot(self));
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, bar), buildSearch(self));
    return bar;
}

pub fn addTrail(self: *App, page: window.Page, crumbs: *gtk.Widget) void {
    const trail = self.top_bar.trail orelse return;
    _ = gtk.gtk_stack_add_named(trail, crumbs, page.name());
}

pub fn adoptPanelControls(self: *App, controls: *gtk.Widget, owner: *gtk.Widget) void {
    const slot = self.top_bar.panels orelse return;
    _ = gtk.gtk_stack_add_child(slot, controls);
    _ = gtk.signalConnect(owner, "destroy", gtk.callback(ownerDestroyed), gtk.g_object_ref(controls));
}

fn ownerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const controls = gtk.cast(gtk.Widget, data.?);
    defer gtk.g_object_unref(controls);
    if (gtk.gtk_widget_get_parent(controls)) |slot| gtk.gtk_stack_remove(gtk.cast(gtk.Stack, slot), controls);
}

pub fn refresh(self: *App) void {
    const bar = &self.top_bar;
    if (bar.back) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(window.canGoBack(self)));
    if (bar.forward) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(window.canGoForward(self)));
    showTrail(self);
    showPanelControls(self);
}

fn showTrail(self: *App) void {
    const bar = &self.top_bar;
    const trail = bar.trail orelse return;
    const page = self.current_page;
    if (gtk.gtk_stack_get_child_by_name(trail, page.name()) != null) {
        gtk.gtk_stack_set_visible_child_name(trail, page.name());
        return;
    }
    gtk.gtk_stack_set_visible_child_name(trail, "trail");
    var parent: ?[*:0]const u8 = null;
    var current = page.title();
    if (window.pushedPage(self, page)) |pushed| {
        current = adw.adw_navigation_page_get_title(pushed);
        const navigation = window.pageNavigation(self, page).?;
        parent = if (adw.adw_navigation_view_get_previous_page(navigation, pushed)) |previous|
            adw.adw_navigation_page_get_title(previous)
        else
            page.title();
    }
    if (bar.parent) |button| {
        if (parent) |text| gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), text);
        gtk.gtk_widget_set_visible(button, @intFromBool(parent != null));
    }
    if (bar.separator) |separator| gtk.gtk_widget_set_visible(separator, @intFromBool(parent != null));
    if (bar.current) |label| gtk.gtk_label_set_text(label, current);
}

fn showPanelControls(self: *App) void {
    const slot = self.top_bar.panels orelse return;
    const content = window.visibleContent(self);
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        const shown = content orelse break;
        if (panel.split != shown and gtk.gtk_widget_is_ancestor(panel.split, shown) == 0) continue;
        const controls = gtk.gtk_widget_get_parent(panel.toggles) orelse continue;
        if (gtk.gtk_widget_get_parent(controls) != gtk.cast(gtk.Widget, slot)) continue;
        return gtk.gtk_stack_set_visible_child(slot, controls);
    }
    gtk.gtk_stack_set_visible_child_name(slot, no_panel);
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
