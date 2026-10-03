//! What every content page shares: a flat header bar that carries the library
//! search and the page's controls, with a breadcrumb on a pushed page, and the
//! title block that opens the content with the page's name and its count.

const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const palette = @import("palette.zig");

const App = app.App;

pub const Header = struct {
    bar: *gtk.Widget,
    end: *gtk.Box,

    pub fn add(self: Header, control: *gtk.Widget) void {
        gtk.gtk_box_append(self.end, control);
    }
};

pub fn header(self: *App) Header {
    return headerWith(librarySearch(self));
}

/// A header whose search field is the page's own rather than the library's.
pub fn headerWith(search: *gtk.Widget) Header {
    const bar = adw.adw_header_bar_new();
    adw.adw_header_bar_set_show_title(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    gtk.gtk_widget_add_css_class(bar, "page-header");
    const end = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, end), search);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, bar), end);
    return .{ .bar = bar, .end = gtk.cast(gtk.Box, end) };
}

pub const Trail = struct {
    header: Header,
    current: *gtk.Label,
};

pub fn pushedHeader(self: *App, navigation: *adw.NavigationView, current: [*:0]const u8) Header {
    return pushedTrail(self, navigation, current).header;
}

pub fn pushedTrail(self: *App, navigation: *adw.NavigationView, current: [*:0]const u8) Trail {
    const parent: [*:0]const u8 = if (adw.adw_navigation_view_get_visible_page(navigation)) |visible|
        adw.adw_navigation_page_get_title(visible)
    else
        "";
    const up = gtk.gtk_button_new_with_label(parent);
    gtk.gtk_widget_add_css_class(up, "flat");
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, up), "navigation.pop");
    const pushed = trail(self, up, current);
    adw.adw_header_bar_set_show_back_button(gtk.cast(adw.HeaderBar, pushed.header.bar), gtk.false_);
    return pushed;
}

pub fn sectionHeader(self: *App, section: [*:0]const u8, current: [*:0]const u8) Trail {
    return trail(self, gtk.gtk_label_new(section), current);
}

fn trail(self: *App, parent: *gtk.Widget, current: [*:0]const u8) Trail {
    const bar = header(self);
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    const separator = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(separator, "breadcrumb-separator");
    const here = gtk.gtk_label_new(current);
    gtk.gtk_widget_add_css_class(here, "breadcrumb-current");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, here), gtk.ELLIPSIZE_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, crumbs), parent);
    gtk.gtk_box_append(gtk.cast(gtk.Box, crumbs), separator);
    gtk.gtk_box_append(gtk.cast(gtk.Box, crumbs), here);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar.bar), crumbs);
    return .{ .header = bar, .current = gtk.cast(gtk.Label, here) };
}

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn librarySearch(self: *App) *gtk.Widget {
    const entry = gtk.gtk_search_entry_new();
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), "Search your library…");
    gtk.gtk_widget_set_hexpand(entry, gtk.true_);
    const field = searchField(entry, "Ctrl K");

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
    showSearch(gtk.cast(gtk.Stack, switcher), self.header_compact);
    palette.attach(self, switcher, entry);
    for (&self.header_searches) |*slot| {
        if (slot.* != null) continue;
        slot.* = gtk.cast(gtk.Stack, switcher);
        _ = gtk.signalConnect(switcher, "destroy", gtk.callback(searchDestroyed), self);
        break;
    }
    return switcher;
}

/// `entry` with the `shortcut` hint over its end.
pub fn searchField(entry: *gtk.Widget, shortcut: [*:0]const u8) *gtk.Widget {
    const hint = gtk.gtk_label_new(shortcut);
    gtk.gtk_widget_add_css_class(hint, "keycap-hint");
    gtk.gtk_widget_set_halign(hint, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(hint, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_can_target(hint, gtk.false_);
    const field = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(field, "library-search");
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, field), entry);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, field), hint);
    return field;
}

fn showSearch(switcher: *gtk.Stack, compact: bool) void {
    gtk.gtk_stack_set_visible_child_name(switcher, if (compact) "icon" else "entry");
}

pub fn setCompact(self: *App, compact: bool) void {
    self.header_compact = compact;
    for (self.header_searches) |maybe| showSearch(maybe orelse continue, compact);
}

fn searchDestroyed(switcher: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    for (&state(data).header_searches) |*slot| {
        if (@as(?*anyopaque, slot.*) == switcher) slot.* = null;
    }
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
