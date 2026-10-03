//! The parametric equalizer's response graph: the filters' combined curve at
//! the output's rate, preamp aside so a peak's dot sits at its gain, and one
//! dot per enabled filter, on the curve unless it is a peak, dragged to move
//! it and scrolled to change its Q.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const parametric = @import("parametric.zig");

const App = app.App;

pub const height = 230;
const range_db: f64 = 12;
const point_count = 256;
const dot_radius: f64 = 5;
const hit_radius: f64 = 10;
const lowest_hz: f64 = 20;
const highest_hz: f64 = 20_000;
const left_margin: f64 = 48;
const right_margin: f64 = 12;
const top_margin: f64 = 8;
const bottom_margin: f64 = 24;

const decibel_marks = [_]struct { f64, [:0]const u8 }{
    .{ 12, "12 dB" },
    .{ 6, "6 dB" },
    .{ 0, "0 dB" },
    .{ -6, "-6 dB" },
    .{ -12, "-12 dB" },
};

const frequency_marks = [_]struct { f64, [:0]const u8 }{
    .{ 20, "20" },
    .{ 50, "50" },
    .{ 100, "100" },
    .{ 200, "200" },
    .{ 500, "500" },
    .{ 1000, "1k" },
    .{ 2000, "2k" },
    .{ 5000, "5k" },
    .{ 10000, "10k" },
    .{ 20000, "20k Hz" },
};

pub const dot_colors = [_][3]f64{
    rgb(0x5b9bf0),
    rgb(0x5fae7f),
    rgb(0xd9a03b),
    rgb(0xa07bd8),
    rgb(0xe0605a),
    rgb(0x49b6c2),
    rgb(0xc48ad8),
    rgb(0x8ab6f0),
};

const accent = rgb(0x5b9bf0);

fn rgb(comptime value: u24) [3]f64 {
    return .{
        @as(f64, @floatFromInt(value >> 16)) / 255,
        @as(f64, @floatFromInt((value >> 8) & 0xff)) / 255,
        @as(f64, @floatFromInt(value & 0xff)) / 255,
    };
}

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const Plot = struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,

    fn of(width: c_int, area_height: c_int) Plot {
        return .{
            .left = left_margin,
            .top = top_margin,
            .width = @max(1, @as(f64, @floatFromInt(width)) - left_margin - right_margin),
            .height = @max(1, @as(f64, @floatFromInt(area_height)) - top_margin - bottom_margin),
        };
    }

    fn ofWidget(widget: *gtk.Widget) Plot {
        return of(gtk.gtk_widget_get_width(widget), gtk.gtk_widget_get_height(widget));
    }

    fn x(self: Plot, hertz: f64) f64 {
        return self.left + self.width * @log(hertz / lowest_hz) / @log(highest_hz / lowest_hz);
    }

    fn y(self: Plot, decibels: f64) f64 {
        const clipped = std.math.clamp(decibels, -range_db, range_db);
        return self.top + self.height * (range_db - clipped) / (2 * range_db);
    }

    fn hertzAt(self: Plot, at_x: f64) f64 {
        const fraction = std.math.clamp((at_x - self.left) / self.width, 0, 1);
        return lowest_hz * std.math.pow(f64, highest_hz / lowest_hz, fraction);
    }

    fn bottom(self: Plot) f64 {
        return self.top + self.height;
    }

    fn right(self: Plot) f64 {
        return self.left + self.width;
    }
};

fn withoutPreamp(curve: liborca.ParametricEqualizer) liborca.ParametricEqualizer {
    var filters_only = curve;
    filters_only.preamp_db = 0;
    return filters_only;
}

fn curveAt(curve: liborca.ParametricEqualizer, rate: u32, hertz: f64) f64 {
    const frequencies = [1]f32{@floatCast(hertz)};
    var gains: [1]f32 = undefined;
    withoutPreamp(curve).response(rate, &frequencies, &gains);
    return gains[0];
}

fn dotCenter(plot: Plot, curve: liborca.ParametricEqualizer, rate: u32, filter: liborca.ParametricFilter) [2]f64 {
    const decibels = if (filter.kind == .peak) filter.gain_db else curveAt(curve, rate, filter.frequency_hz);
    return .{ plot.x(filter.frequency_hz), plot.y(decibels) };
}

/// The enabled filter whose dot is under the point, the nearest when dots
/// overlap.
fn filterAt(self: *App, plot: Plot, at_x: f64, at_y: f64) ?u8 {
    const editor = &self.parametric;
    var nearest: ?u8 = null;
    var nearest_distance = hit_radius;
    for (editor.curve.filterList(), 0..) |filter, index| {
        if (!filter.enabled) continue;
        const center = dotCenter(plot, editor.curve, editor.rate, filter);
        const distance = std.math.hypot(center[0] - at_x, center[1] - at_y);
        if (distance <= nearest_distance) {
            nearest = @intCast(index);
            nearest_distance = distance;
        }
    }
    return nearest;
}

fn textColor(widget: *gtk.Widget) gtk.GdkRGBA {
    var color: gtk.GdkRGBA = undefined;
    gtk.gtk_widget_get_color(widget, &color);
    return color;
}

fn setColor(cr: *gtk.Cairo, color: gtk.GdkRGBA, alpha: f64) void {
    gtk.cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha * alpha);
}

fn showText(cr: *gtk.Cairo, widget: *gtk.Widget, text: [:0]const u8, at_x: f64, at_y: f64, x_align: f64, y_align: f64) void {
    const layout = gtk.gtk_widget_create_pango_layout(widget, text.ptr);
    defer gtk.g_object_unref(layout);
    var width: c_int = 0;
    var text_height: c_int = 0;
    gtk.pango_layout_get_pixel_size(layout, &width, &text_height);
    gtk.cairo_move_to(cr, at_x - x_align * @as(f64, @floatFromInt(width)), at_y - y_align * @as(f64, @floatFromInt(text_height)));
    gtk.pango_cairo_show_layout(cr, layout);
}

fn drawGrid(cr: *gtk.Cairo, widget: *gtk.Widget, plot: Plot, color: gtk.GdkRGBA) void {
    const dash = [_]f64{ 1, 3 };
    gtk.cairo_save(cr);
    gtk.cairo_set_line_width(cr, 1);
    gtk.cairo_set_dash(cr, &dash, dash.len, 0);
    for (decibel_marks) |mark| {
        const at_y = @round(plot.y(mark[0])) + 0.5;
        setColor(cr, color, if (mark[0] == 0) 0.3 else 0.14);
        gtk.cairo_move_to(cr, plot.left, at_y);
        gtk.cairo_line_to(cr, plot.right(), at_y);
        gtk.cairo_stroke(cr);
    }
    setColor(cr, color, 0.14);
    for (frequency_marks) |mark| {
        const at_x = @round(plot.x(mark[0])) + 0.5;
        gtk.cairo_move_to(cr, at_x, plot.top);
        gtk.cairo_line_to(cr, at_x, plot.bottom());
        gtk.cairo_stroke(cr);
    }
    gtk.cairo_restore(cr);

    setColor(cr, color, 0.6);
    for (decibel_marks) |mark| showText(cr, widget, mark[1], plot.left - 8, plot.y(mark[0]), 1, 0.5);
    for (frequency_marks, 0..) |mark, index| {
        const x_align: f64 = if (index == frequency_marks.len - 1) 1 else if (index == 0) 0 else 0.5;
        const at_x = if (index == frequency_marks.len - 1) plot.right() + right_margin else plot.x(mark[0]);
        showText(cr, widget, mark[1], at_x, plot.bottom() + 6, x_align, 0);
    }
}

fn drawCurve(cr: *gtk.Cairo, plot: Plot, curve: liborca.ParametricEqualizer, rate: u32) void {
    var frequencies: [point_count]f32 = undefined;
    for (&frequencies, 0..) |*frequency, index| {
        const fraction = @as(f64, @floatFromInt(index)) / (point_count - 1);
        frequency.* = @floatCast(lowest_hz * std.math.pow(f64, highest_hz / lowest_hz, fraction));
    }
    var gains: [point_count]f32 = undefined;
    withoutPreamp(curve).response(rate, &frequencies, &gains);

    gtk.cairo_save(cr);
    gtk.cairo_rectangle(cr, plot.left, plot.top - 1, plot.width, plot.height + 2);
    gtk.cairo_clip(cr);
    gtk.cairo_new_path(cr);
    for (frequencies, gains, 0..) |frequency, gain, index| {
        const at_x = plot.x(frequency);
        const at_y = plot.y(gain);
        if (index == 0) gtk.cairo_move_to(cr, at_x, at_y) else gtk.cairo_line_to(cr, at_x, at_y);
    }
    gtk.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 1);
    gtk.cairo_set_line_width(cr, 2);
    gtk.cairo_stroke_preserve(cr);
    gtk.cairo_line_to(cr, plot.right(), plot.bottom());
    gtk.cairo_line_to(cr, plot.left, plot.bottom());
    gtk.cairo_close_path(cr);
    const fill = gtk.cairo_pattern_create_linear(0, plot.top, 0, plot.bottom());
    defer gtk.cairo_pattern_destroy(fill);
    gtk.cairo_pattern_add_color_stop_rgba(fill, 0, accent[0], accent[1], accent[2], 0.3);
    gtk.cairo_pattern_add_color_stop_rgba(fill, 1, accent[0], accent[1], accent[2], 0.03);
    gtk.cairo_set_source(cr, fill);
    gtk.cairo_fill(cr);
    gtk.cairo_restore(cr);
}

fn drawDots(cr: *gtk.Cairo, self: *App, plot: Plot) void {
    const editor = &self.parametric;
    for (editor.curve.filterList(), 0..) |filter, index| {
        if (!filter.enabled) continue;
        const center = dotCenter(plot, editor.curve, editor.rate, filter);
        const radius = if (editor.drag_index != null and editor.drag_index.? == index) dot_radius + 1.5 else dot_radius;
        const color = dot_colors[index % dot_colors.len];
        gtk.cairo_new_path(cr);
        gtk.cairo_arc(cr, center[0], center[1], radius + 1.5, 0, 2 * std.math.pi);
        gtk.cairo_set_source_rgba(cr, 0, 0, 0, 0.35);
        gtk.cairo_fill(cr);
        gtk.cairo_arc(cr, center[0], center[1], radius, 0, 2 * std.math.pi);
        gtk.cairo_set_source_rgba(cr, color[0], color[1], color[2], 1);
        gtk.cairo_fill(cr);
    }
}

fn draw(area: ?*gtk.DrawingArea, cr: *gtk.Cairo, width: c_int, area_height: c_int, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.cast(gtk.Widget, area.?);
    const plot = Plot.of(width, area_height);
    drawGrid(cr, widget, plot, textColor(widget));
    drawCurve(cr, plot, self.parametric.curve, self.parametric.rate);
    drawDots(cr, self, plot);
}

/// Three significant figures, which keeps a dragged frequency readable.
fn roundHertz(hertz: f64) f32 {
    const magnitude = std.math.pow(f64, 10, @floor(std.math.log10(hertz)) - 2);
    return @floatCast(std.math.clamp(@round(hertz / magnitude) * magnitude, lowest_hz, highest_hz));
}

fn dragBegin(gesture: ?*anyopaque, at_x: f64, at_y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, gesture));
    const index = filterAt(self, Plot.ofWidget(widget), at_x, at_y) orelse {
        _ = gtk.gtk_gesture_set_state(gtk.cast(gtk.Gesture, gesture), gtk.EVENT_SEQUENCE_DENIED);
        return;
    };
    _ = gtk.gtk_gesture_set_state(gtk.cast(gtk.Gesture, gesture), gtk.EVENT_SEQUENCE_CLAIMED);
    const plot = Plot.ofWidget(widget);
    const filter = self.parametric.curve.filters[index];
    const center = dotCenter(plot, self.parametric.curve, self.parametric.rate, filter);
    self.parametric.drag_index = index;
    self.parametric.drag_origin = .{ center[0] - at_x, filter.gain_db, at_x, at_y };
    gtk.gtk_widget_queue_draw(widget);
}

fn dragUpdate(gesture: ?*anyopaque, offset_x: f64, offset_y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = self.parametric.drag_index orelse return;
    const widget = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, gesture));
    const plot = Plot.ofWidget(widget);
    const origin = self.parametric.drag_origin;
    const filter = &self.parametric.curve.filters[index];
    filter.frequency_hz = roundHertz(plot.hertzAt(origin[2] + offset_x + origin[0]));
    if (filter.usesGain()) {
        const decibels = std.math.clamp(origin[1] - offset_y * 2 * range_db / plot.height, -range_db, range_db);
        filter.gain_db = @floatCast(@round(decibels * 10) / 10);
    }
    parametric.filterDragged(self, index);
    gtk.gtk_widget_queue_draw(widget);
}

fn dragEnd(gesture: ?*anyopaque, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.parametric.drag_index == null) return;
    self.parametric.drag_index = null;
    gtk.gtk_widget_queue_draw(gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, gesture)));
    parametric.applyNow(self);
}

fn motion(controller: ?*anyopaque, at_x: f64, at_y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.parametric.pointer = .{ at_x, at_y };
    const widget = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, controller));
    const over = filterAt(self, Plot.ofWidget(widget), at_x, at_y) != null;
    gtk.gtk_widget_set_cursor_from_name(widget, if (over or self.parametric.drag_index != null) "grab" else null);
}

fn leave(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    state(data).parametric.pointer = null;
}

fn scrolled(controller: ?*anyopaque, _: f64, delta_y: f64, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const pointer = self.parametric.pointer orelse return gtk.false_;
    const widget = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, controller));
    const index = filterAt(self, Plot.ofWidget(widget), pointer[0], pointer[1]) orelse return gtk.false_;
    const filter = &self.parametric.curve.filters[index];
    const range = parametric.qRange(filter.kind);
    const scaled = filter.q * std.math.pow(f32, 1.1, @floatCast(-delta_y));
    filter.q = std.math.clamp(@round(scaled * 100) / 100, range[0], range[1]);
    parametric.filterDragged(self, index);
    parametric.scheduleApply(self);
    gtk.gtk_widget_queue_draw(widget);
    return gtk.true_;
}

pub fn new(self: *App) *gtk.Widget {
    const area = gtk.gtk_drawing_area_new();
    gtk.gtk_widget_add_css_class(area, "peq-graph");
    gtk.gtk_widget_set_hexpand(area, gtk.true_);
    gtk.gtk_drawing_area_set_content_height(gtk.cast(gtk.DrawingArea, area), height);
    gtk.gtk_drawing_area_set_draw_func(gtk.cast(gtk.DrawingArea, area), draw, self, null);

    const drag = gtk.gtk_gesture_drag_new();
    gtk.gtk_gesture_single_set_button(gtk.cast(gtk.GestureSingle, drag), 1);
    _ = gtk.signalConnect(drag, "drag-begin", gtk.callback(dragBegin), self);
    _ = gtk.signalConnect(drag, "drag-update", gtk.callback(dragUpdate), self);
    _ = gtk.signalConnect(drag, "drag-end", gtk.callback(dragEnd), self);
    gtk.gtk_widget_add_controller(area, drag);

    const pointer = gtk.gtk_event_controller_motion_new();
    _ = gtk.signalConnect(pointer, "motion", gtk.callback(motion), self);
    _ = gtk.signalConnect(pointer, "leave", gtk.callback(leave), self);
    gtk.gtk_widget_add_controller(area, pointer);

    const wheel = gtk.gtk_event_controller_scroll_new(gtk.EVENT_CONTROLLER_SCROLL_VERTICAL);
    _ = gtk.signalConnect(wheel, "scroll", gtk.callback(scrolled), self);
    gtk.gtk_widget_add_controller(area, wheel);
    return area;
}
