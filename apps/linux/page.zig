//! What every content page shares: a flat header bar that carries the page's
//! controls, with a breadcrumb on a pushed page, and the title block that
//! opens the content with the page's name and its count.

const gtk = @import("gtk.zig");
const adw = @import("adw.zig");

pub fn header() *gtk.Widget {
    const bar = adw.adw_header_bar_new();
    adw.adw_header_bar_set_show_title(gtk.cast(adw.HeaderBar, bar), gtk.false_);
    gtk.gtk_widget_add_css_class(bar, "page-header");
    return bar;
}

pub const Trail = struct {
    bar: *gtk.Widget,
    current: *gtk.Label,
};

pub fn pushedHeader(navigation: *adw.NavigationView, current: [*:0]const u8) *gtk.Widget {
    return pushedTrail(navigation, current).bar;
}

pub fn pushedTrail(navigation: *adw.NavigationView, current: [*:0]const u8) Trail {
    const parent: [*:0]const u8 = if (adw.adw_navigation_view_get_visible_page(navigation)) |visible|
        adw.adw_navigation_page_get_title(visible)
    else
        "";
    const up = gtk.gtk_button_new_with_label(parent);
    gtk.gtk_widget_add_css_class(up, "flat");
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, up), "navigation.pop");
    return trail(up, current);
}

pub fn sectionHeader(section: [*:0]const u8, current: [*:0]const u8) Trail {
    return trail(gtk.gtk_label_new(section), current);
}

fn trail(parent: *gtk.Widget, current: [*:0]const u8) Trail {
    const bar = header();
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
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, bar), crumbs);
    return .{ .bar = bar, .current = gtk.cast(gtk.Label, here) };
}

pub const Title = struct {
    widget: *gtk.Widget,
    title: *gtk.Label,
    meta: *gtk.Label,
    end: *gtk.Box,

    pub fn add(self: Title, control: *gtk.Widget) void {
        gtk.gtk_box_append(self.end, control);
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
    const end = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_valign(end, gtk.ALIGN_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), text_box);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), end);
    return .{
        .widget = row,
        .title = gtk.cast(gtk.Label, name),
        .meta = gtk.cast(gtk.Label, meta),
        .end = gtk.cast(gtk.Box, end),
    };
}

pub fn withTitle(block: Title, body: *gtk.Widget) *gtk.Widget {
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), block.widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), body);
    return column;
}
