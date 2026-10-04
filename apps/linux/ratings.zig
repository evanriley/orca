//! Star ratings: five stars on every track row, and the
//! one place a rating change is applied and shown.
//!
//! The rating belongs to liborca and is kept per recording; this only asks for
//! it and repaints what displays it. A star row is a box of five buttons that
//! remembers how many stars it shows, so a click needs nothing but the button
//! to know what it asks for.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const feedback = @import("feedback.zig");

const App = app.App;

const star_count = 5;
const star_step: u8 = liborca.max_rating / star_count;
const star_icon = "orca-star-symbolic";
const star_pixels: c_int = 14;
const change_batch = 512;

const star_labels = [star_count][*:0]const u8{
    "Rate 1 star",
    "Rate 2 stars",
    "Rate 3 stars",
    "Rate 4 stars",
    "Rate 5 stars",
};

/// Five star buttons, each calling `handler` with itself and `data` when
/// clicked. `chosen` turns that button into the rating it asks for.
pub fn newStars(handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "rating-stars");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    for (star_labels, 1..) |label, number| {
        const image = gtk.gtk_image_new_from_icon_name(star_icon);
        gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), star_pixels);
        const button = gtk.gtk_button_new();
        gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), image);
        gtk.gtk_widget_add_css_class(button, "flat");
        gtk.gtk_widget_add_css_class(button, "star");
        gtk.gtk_widget_set_focus_on_click(button, gtk.false_);
        gtk.gtk_widget_set_tooltip_text(button, label);
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, label, @as(c_int, -1));
        gtk.g_object_set_data(button, "orca-star", @ptrFromInt(number));
        _ = gtk.signalConnect(button, "clicked", handler, data);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    }
    return box;
}

/// Stars on a track row: faint until the row is hovered or the track is rated.
pub fn newRowStars(handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const box = newStars(handler, data);
    gtk.gtk_widget_add_css_class(box, "row-stars");
    return box;
}

pub fn setStarSize(stars: *gtk.Widget, pixels: c_int) void {
    var button = gtk.gtk_widget_get_first_child(stars);
    while (button) |star| : (button = gtk.gtk_widget_get_next_sibling(star)) {
        const image = gtk.gtk_button_get_child(gtk.cast(gtk.Button, star)) orelse continue;
        gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), pixels);
    }
}

fn starsFor(rating: ?u8) usize {
    const value = rating orelse return 0;
    return std.math.clamp((@as(usize, value) + star_step / 2) / star_step, 1, star_count);
}

pub fn show(stars: *gtk.Widget, rating: ?u8) void {
    const filled = starsFor(rating);
    gtk.g_object_set_data(stars, "orca-stars-shown", @ptrFromInt(filled));
    if (filled != 0)
        gtk.gtk_widget_add_css_class(stars, "rated")
    else
        gtk.gtk_widget_remove_css_class(stars, "rated");
    var button = gtk.gtk_widget_get_first_child(stars);
    var number: usize = 1;
    while (button) |star| : ({
        button = gtk.gtk_widget_get_next_sibling(star);
        number += 1;
    }) {
        if (number <= filled)
            gtk.gtk_widget_add_css_class(star, "filled")
        else
            gtk.gtk_widget_remove_css_class(star, "filled");
    }
}

/// The star row a star button belongs to.
pub fn starsOf(button: ?*anyopaque) ?*gtk.Widget {
    return gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, button orelse return null));
}

/// What a click on `button` asks for: its number of stars, or no rating when
/// that is what the row already shows.
pub fn chosen(button: ?*anyopaque) ?u8 {
    const star = button orelse return null;
    const number = @intFromPtr(gtk.g_object_get_data(star, "orca-star"));
    const stars = starsOf(star) orelse return null;
    const shown = @intFromPtr(gtk.g_object_get_data(stars, "orca-stars-shown"));
    if (number == 0 or number == shown) return null;
    return @intCast(number * star_step);
}

/// The rating a context menu's "N Stars" item sets; zero clears.
pub fn menuRating(stars: i64) ?u8 {
    if (stars <= 0 or stars > star_count) return null;
    return @intCast(stars * star_step);
}

pub fn change(self: *App, targets: []const feedback.Target, value: ?u8) void {
    const library = self.library orelse return;
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(self.allocator);
    for (targets) |target| ids.append(self.allocator, target.track_id) catch return self.toast("Out of memory");
    var changed: feedback.Recordings = .empty;
    defer changed.deinit(self.allocator);
    var failed = false;
    var start: usize = 0;
    while (start < ids.items.len) : (start += change_batch) {
        const end = @min(start + change_batch, ids.items.len);
        _ = self.runtime.librarySetRating(library, ids.items[start..end], value) catch {
            failed = true;
            break;
        };
        for (targets[start..end]) |target| {
            const recording = target.recording_id orelse continue;
            changed.put(self.allocator, recording, {}) catch return self.toast("Out of memory");
        }
    }
    if (failed) self.toast("Could not save that rating");
    if (changed.count() == 0) {
        if (!failed and targets.len != 0) self.toast("Nothing was changed");
        return;
    }
    feedback.repaintLists(self, &changed, .{ .rating = value });
}
