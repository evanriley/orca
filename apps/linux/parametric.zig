//! The Parametric Equalizer editor on Settings › Sound: the preset and preamp
//! controls, the response graph and the filter table. It edits
//! `App.parametric.curve` and hands it to the Player whenever the equalizer
//! is in Parametric mode.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
const transport = @import("transport.zig");
const signal_path = @import("signal_path.zig");
const graph = @import("equalizer_graph.zig");

const App = app.App;
const Curve = liborca.ParametricEqualizer;
const Filter = liborca.ParametricFilter;
const Kind = liborca.ParametricFilterKind;
const max_filters = liborca.max_parametric_filters;

pub const Mode = enum { off, graphic, parametric };
pub const View = enum { graphic, parametric };

pub const max_presets = 32;
pub const max_name_bytes = 64;
pub const default_rate: u32 = 44_100;
const settle_ms: c_uint = 60;
const frequency_range = [2]f64{ 20, 20_000 };
const gain_limit_db: f64 = 24;
const q_range = [2]f32{ 0.1, 20 };
const shelf_q_range = [2]f32{ 0.3, 2 };
const preamp_range = [2]f64{ -24, 6 };
const max_file_bytes = 64 * 1024;

pub const sample_name = "HD 650";
const sample_text = @embedFile("hd650.txt");
const flat_index: c_uint = 0;
const custom_index: c_uint = 1;
const first_user_index: c_uint = 2;

const kind_order = [_]Kind{ .low_shelf, .peak, .high_shelf, .low_pass, .high_pass, .notch };
const listed_kinds = kind_order.len - 1;

const kind_labels = blk: {
    var labels: [kind_order.len + 1]?[*:0]const u8 = undefined;
    for (kind_order, 0..) |kind, index| labels[index] = signal_path.filterKindName(kind);
    labels[kind_order.len] = null;
    break :blk labels;
};

const listed_kind_labels = blk: {
    var labels: [listed_kinds + 1]?[*:0]const u8 = undefined;
    @memcpy(labels[0..listed_kinds], kind_labels[0..listed_kinds]);
    labels[listed_kinds] = null;
    break :blk labels;
};

comptime {
    std.debug.assert(kind_order.len == std.enums.values(Kind).len);
    std.debug.assert(kind_order[listed_kinds] == .notch);
}

fn kindPosition(kind: Kind) c_uint {
    return @intCast(std.mem.indexOfScalar(Kind, &kind_order, kind).?);
}

pub const max_device_presets = 16;
pub const max_device_name_bytes = 200;

/// The preset `switch_with_device` applies when the output becomes `device`.
pub const DevicePreset = struct {
    device_buffer: [max_device_name_bytes]u8 = undefined,
    device_len: u8 = 0,
    preset_buffer: [max_name_bytes]u8 = undefined,
    preset_len: u8 = 0,

    pub fn device(self: *const DevicePreset) []const u8 {
        return self.device_buffer[0..self.device_len];
    }

    pub fn preset(self: *const DevicePreset) []const u8 {
        return self.preset_buffer[0..self.preset_len];
    }
};

pub const Preset = struct {
    name_buffer: [max_name_bytes]u8 = undefined,
    name_len: u8 = 0,
    curve: Curve = .{},

    pub fn name(self: *const Preset) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
};

pub const Row = struct {
    self: *App = undefined,
    index: u8 = 0,
    widget: ?*gtk.Widget = null,
    kind: ?*gtk.Widget = null,
    frequency: ?*gtk.Widget = null,
    gain: ?*gtk.Widget = null,
    q: ?*gtk.Widget = null,
};

pub const Controls = struct {
    root: ?*gtk.Widget = null,
    preset: ?*gtk.Widget = null,
    preset_names: ?*gtk.StringList = null,
    preamp: ?*gtk.Widget = null,
    graph: ?*gtk.Widget = null,
    list: ?*gtk.Widget = null,
    add: ?*gtk.Widget = null,
};

/// The parametric curve and the editor showing it. The curve is kept while
/// another mode runs, so switching back restores it.
pub const State = struct {
    curve: Curve = .{},
    view: View = .graphic,
    presets: [max_presets]Preset = undefined,
    preset_count: u8 = 0,
    device_presets: [max_device_presets]DevicePreset = undefined,
    device_preset_count: u8 = 0,
    switch_with_device: bool = true,
    rate: u32 = default_rate,
    apply_timer: c_uint = 0,
    rebuild_idle: c_uint = 0,
    suppress: bool = false,
    drag_index: ?u8 = null,
    /// Horizontal offset from the pointer to the dot's centre, the filter's
    /// gain, then where the drag began.
    drag_origin: [4]f64 = @splat(0),
    pointer: ?[2]f64 = null,
    controls: Controls = .{},
    rows: [max_filters]Row = @splat(.{}),
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn rowOf(data: ?*anyopaque) *Row {
    return @ptrCast(@alignCast(data.?));
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

pub fn qRange(kind: Kind) [2]f32 {
    return switch (kind) {
        .low_shelf, .high_shelf => shelf_q_range,
        else => q_range,
    };
}

pub fn sampleCurve() Curve {
    return liborca.parseEqualizerApo(sample_text) catch .{};
}

pub fn currentMode(self: *App) Mode {
    if ((self.runtime.playerParametricEqualizer(self.player) catch null) != null) return .parametric;
    if ((self.runtime.playerEqualizer(self.player) catch null) != null) return .graphic;
    return .off;
}

fn sameFilter(a: Filter, b: Filter) bool {
    return a.kind == b.kind and a.frequency_hz == b.frequency_hz and a.gain_db == b.gain_db and
        a.q == b.q and a.enabled == b.enabled;
}

fn sameCurve(a: *const Curve, b: *const Curve) bool {
    if (a.count != b.count or a.preamp_db != b.preamp_db) return false;
    for (a.filterList(), b.filterList()) |left, right| {
        if (!sameFilter(left, right)) return false;
    }
    return true;
}

fn sampleIndex(self: *App) c_uint {
    return first_user_index + self.parametric.preset_count;
}

fn newPresetIndex(self: *App) c_uint {
    return sampleIndex(self) + 1;
}

fn presetCurve(self: *App, index: c_uint) ?Curve {
    const editor = &self.parametric;
    if (index == flat_index) return .{};
    if (index == custom_index) return null;
    if (index == sampleIndex(self)) return sampleCurve();
    if (index >= first_user_index and index < sampleIndex(self)) return editor.presets[index - first_user_index].curve;
    return null;
}

fn matchingPreset(self: *App) c_uint {
    const curve = &self.parametric.curve;
    const flat: Curve = .{};
    if (sameCurve(curve, &flat)) return flat_index;
    for (self.parametric.presets[0..self.parametric.preset_count], first_user_index..) |*preset, index| {
        if (sameCurve(curve, &preset.curve)) return @intCast(index);
    }
    const sample = sampleCurve();
    if (sameCurve(curve, &sample)) return sampleIndex(self);
    return custom_index;
}

fn presetLabels(self: *App, buffer: []?[*:0]const u8, names: *[max_presets][max_name_bytes + 1]u8) []?[*:0]const u8 {
    var count: usize = 0;
    buffer[count] = "Flat";
    count += 1;
    buffer[count] = "Custom";
    count += 1;
    for (self.parametric.presets[0..self.parametric.preset_count], 0..) |*preset, index| {
        @memcpy(names[index][0..preset.name_len], preset.name());
        names[index][preset.name_len] = 0;
        buffer[count] = @ptrCast(&names[index]);
        count += 1;
    }
    buffer[count] = sample_name;
    count += 1;
    buffer[count] = "New preset…";
    count += 1;
    buffer[count] = null;
    return buffer[0 .. count + 1];
}

/// Flat, the saved presets and the sample, by the names the Preset list
/// shows; a saved preset wins over a built-in of the same name.
pub fn presetNamed(self: *App, name: []const u8) ?Curve {
    for (self.parametric.presets[0..self.parametric.preset_count]) |*preset| {
        if (std.mem.eql(u8, preset.name(), name)) return preset.curve;
    }
    if (std.mem.eql(u8, name, "Flat")) return .{};
    if (std.mem.eql(u8, name, sample_name)) return sampleCurve();
    return null;
}

/// "None", Flat, the saved presets and the sample: what a device can switch to.
pub fn devicePresetLabels(self: *App, buffer: *[max_presets + 4]?[*:0]const u8, names: *[max_presets][max_name_bytes + 1]u8) []?[*:0]const u8 {
    var count: usize = 0;
    for ([_][*:0]const u8{ "None", "Flat" }) |label| {
        buffer[count] = label;
        count += 1;
    }
    for (self.parametric.presets[0..self.parametric.preset_count], 0..) |*preset, index| {
        @memcpy(names[index][0..preset.name_len], preset.name());
        names[index][preset.name_len] = 0;
        buffer[count] = @ptrCast(&names[index]);
        count += 1;
    }
    buffer[count] = sample_name;
    buffer[count + 1] = null;
    return buffer[0 .. count + 2];
}

/// The preset name at `index` of `devicePresetLabels`, or null for None.
pub fn devicePresetChoice(self: *App, index: c_uint) ?[]const u8 {
    const count = self.parametric.preset_count;
    if (index == 0 or index > count + 2) return null;
    if (index == 1) return "Flat";
    if (index == count + 2) return sample_name;
    return self.parametric.presets[index - 2].name();
}

pub fn devicePresetIndex(self: *App, name: ?[]const u8) c_uint {
    const chosen = name orelse return 0;
    const count = self.parametric.preset_count;
    for (self.parametric.presets[0..count], 0..) |*preset, index| {
        if (std.mem.eql(u8, preset.name(), chosen)) return @intCast(index + 2);
    }
    if (std.mem.eql(u8, chosen, "Flat")) return 1;
    if (std.mem.eql(u8, chosen, sample_name)) return count + 2;
    return 0;
}

/// An editable decibel value, shown as `−3.0 dB`.
pub fn decibelEntry(range: [2]f64, value: f64, label: [*:0]const u8) *gtk.Widget {
    return spinEntry(range, 0.5, 1, 7, value, .preamp, label);
}

pub fn devicePreset(self: *App, device: []const u8) ?[]const u8 {
    for (self.parametric.device_presets[0..self.parametric.device_preset_count]) |*entry| {
        if (std.mem.eql(u8, entry.device(), device)) return entry.preset();
    }
    return null;
}

/// Binds `preset` to `device`, or unbinds it for null. False when a name is
/// too long or every slot is taken.
pub fn setDevicePreset(self: *App, device: []const u8, preset: ?[]const u8) bool {
    const editor = &self.parametric;
    const entries = editor.device_presets[0..editor.device_preset_count];
    const existing = for (entries, 0..) |*entry, index| {
        if (std.mem.eql(u8, entry.device(), device)) break index;
    } else null;
    const name = preset orelse {
        const index = existing orelse return true;
        std.mem.copyForwards(DevicePreset, entries[index .. entries.len - 1], entries[index + 1 ..]);
        editor.device_preset_count -= 1;
        return true;
    };
    if (device.len == 0 or device.len > max_device_name_bytes or name.len == 0 or name.len > max_name_bytes) return false;
    const slot = if (existing) |index| &entries[index] else blk: {
        if (editor.device_preset_count == max_device_presets) return false;
        editor.device_preset_count += 1;
        break :blk &editor.device_presets[editor.device_preset_count - 1];
    };
    @memcpy(slot.device_buffer[0..device.len], device);
    slot.device_len = @intCast(device.len);
    @memcpy(slot.preset_buffer[0..name.len], name);
    slot.preset_len = @intCast(name.len);
    return true;
}

/// Runs the preset bound to `device` when presets follow the output. True
/// when it replaced the equalizer.
pub fn applyDevicePreset(self: *App, device: []const u8) bool {
    if (!self.parametric.switch_with_device) return false;
    const name = devicePreset(self, device) orelse return false;
    const curve = presetNamed(self, name) orelse return false;
    self.parametric.curve = curve;
    showCurve(self);
    setMode(self, .parametric, self.equalizer_curve);
    return true;
}

fn showPresets(self: *App) void {
    const names = self.parametric.controls.preset_names orelse return;
    var labels: [max_presets + 5]?[*:0]const u8 = undefined;
    var name_storage: [max_presets][max_name_bytes + 1]u8 = undefined;
    const list = presetLabels(self, &labels, &name_storage);
    const previous = self.parametric.suppress;
    self.parametric.suppress = true;
    defer self.parametric.suppress = previous;
    gtk.gtk_string_list_splice(names, 0, gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, names)), list.ptr);
    showMatchingPreset(self);
}

fn showMatchingPreset(self: *App) void {
    const dropdown = self.parametric.controls.preset orelse return;
    const previous = self.parametric.suppress;
    self.parametric.suppress = true;
    defer self.parametric.suppress = previous;
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, dropdown), matchingPreset(self));
}

pub fn cancelApplyTimer(self: *App) void {
    if (self.parametric.apply_timer == 0) return;
    _ = gtk.g_source_remove(self.parametric.apply_timer);
    self.parametric.apply_timer = 0;
}

/// Hands the curve to the Player when Parametric mode is on, and saves it
/// either way.
pub fn applyNow(self: *App) void {
    cancelApplyTimer(self);
    if (currentMode(self) == .parametric) {
        self.parametric.curve.validate() catch return self.toast("Could not apply the equalizer");
        self.runtime.playerSetParametricEqualizer(self.player, self.parametric.curve) catch
            return self.toast("Could not apply the equalizer");
        transport.refreshSignalPath(self);
    }
    settings.save(self);
}

fn applySettled(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.parametric.apply_timer = 0;
    applyNow(self);
    return gtk.SOURCE_REMOVE;
}

pub fn scheduleApply(self: *App) void {
    cancelApplyTimer(self);
    self.parametric.apply_timer = gtk.g_timeout_add(settle_ms, applySettled, self);
}

pub fn setMode(self: *App, mode: Mode, graphic_curve: liborca.Equalizer) void {
    cancelApplyTimer(self);
    switch (mode) {
        .off => {
            self.runtime.playerSetEqualizer(self.player, null) catch {};
            self.runtime.playerSetParametricEqualizer(self.player, null) catch {};
        },
        .graphic => self.runtime.playerSetEqualizer(self.player, graphic_curve) catch
            return self.toast("Could not apply the equalizer"),
        .parametric => {
            self.parametric.curve.validate() catch return self.toast("Could not apply the equalizer");
            self.runtime.playerSetParametricEqualizer(self.player, self.parametric.curve) catch
                return self.toast("Could not apply the equalizer");
        },
    }
    transport.refreshSignalPath(self);
    settings.save(self);
}

pub fn showRate(self: *App, path: ?liborca.SignalPath) void {
    const rate = if (path) |value| if (value.output) |output| output.sample_rate else default_rate else default_rate;
    if (rate == self.parametric.rate) return;
    self.parametric.rate = rate;
    redraw(self);
}

fn redraw(self: *App) void {
    if (self.parametric.controls.graph) |area| gtk.gtk_widget_queue_draw(area);
}

fn setSpin(spin: ?*gtk.Widget, value: f64) void {
    gtk.gtk_spin_button_set_value(gtk.cast(gtk.SpinButton, spin orelse return), value);
}

/// Brings a row's widgets in line with its filter after the graph moved it.
pub fn filterDragged(self: *App, index: u8) void {
    const editor = &self.parametric;
    const filter = editor.curve.filters[index];
    const row = &editor.rows[index];
    const previous = editor.suppress;
    editor.suppress = true;
    defer editor.suppress = previous;
    setSpin(row.frequency, filter.frequency_hz);
    setSpin(row.gain, filter.gain_db);
    setSpin(row.q, filter.q);
    showMatchingPreset(self);
}

fn showPreamp(self: *App) void {
    const previous = self.parametric.suppress;
    self.parametric.suppress = true;
    defer self.parametric.suppress = previous;
    setSpin(self.parametric.controls.preamp, strings.withoutNegativeZero(self.parametric.curve.preamp_db));
}

fn showAddButton(self: *App) void {
    const add = self.parametric.controls.add orelse return;
    gtk.gtk_widget_set_sensitive(add, boolean(self.parametric.curve.count < max_filters));
}

/// After the curve was replaced as a whole: a preset, an import or a reset.
fn showCurve(self: *App) void {
    showPreamp(self);
    rebuildRows(self);
    showMatchingPreset(self);
    redraw(self);
}

fn curveReplaced(self: *App, curve: Curve) void {
    self.parametric.curve = curve;
    showCurve(self);
    applyNow(self);
}

fn edited(self: *App) void {
    showMatchingPreset(self);
    redraw(self);
}

const Display = enum(usize) { frequency = 1, decibels, q, preamp };

fn displayOf(data: ?*anyopaque) Display {
    return @fromBackingInt(@intCast(@intFromPtr(data.?)));
}

fn displayData(display: Display) *anyopaque {
    return @ptrFromInt(@backingInt(display));
}

fn displayText(buffer: []u8, display: Display, value: f64) ?[:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    const shown = strings.withoutNegativeZero(@floatCast(value));
    (switch (display) {
        .frequency => signal_path.writeFilterFrequency(&writer, shown),
        .decibels, .preamp => writeTenths(&writer, shown, " dB"),
        .q => writer.print("{d:.2}", .{shown}),
    }) catch return null;
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn writeTenths(writer: *std.Io.Writer, value: f32, unit: []const u8) std.Io.Writer.Error!void {
    const tenths = @round(value * 10);
    if (tenths < 0) try writer.writeAll(signal_path.minus);
    if (tenths > 0) try writer.writeByte('+');
    try writer.print("{d:.1}{s}", .{ @abs(tenths) / 10, unit });
}

fn spinValue(spin: ?*anyopaque) f64 {
    return gtk.gtk_spin_button_get_value(gtk.cast(gtk.SpinButton, spin));
}

fn spinOutput(spin: ?*anyopaque, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    var buffer: [32]u8 = undefined;
    const text = displayText(&buffer, displayOf(data), spinValue(spin)) orelse return gtk.false_;
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, spin), text.ptr);
    return gtk.true_;
}

/// A number with an optional unit: `1.2 kHz`, `1.2k`, `80 Hz`, `-3 dB`.
fn parseQuantity(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    var end: usize = 0;
    while (end < trimmed.len and (std.ascii.isDigit(trimmed[end]) or trimmed[end] == '.' or
        trimmed[end] == '-' or trimmed[end] == '+')) end += 1;
    var value = std.fmt.parseFloat(f64, trimmed[0..end]) catch {
        if (std.mem.startsWith(u8, trimmed, signal_path.minus)) {
            const rest = parseQuantity(trimmed[signal_path.minus.len..]) orelse return null;
            return -rest;
        }
        return null;
    };
    const unit = std.mem.trim(u8, trimmed[end..], " \t");
    if (unit.len != 0 and (unit[0] == 'k' or unit[0] == 'K')) value *= 1000;
    return value;
}

/// Text still showing the current value keeps it, so leaving a spin whose
/// display rounds, such as 3270 Hz shown as 3.3 kHz, does not change it.
fn quantityInput(spin: ?*anyopaque, value: *f64, data: ?*anyopaque) callconv(.c) c_int {
    const text = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, spin)));
    const current = spinValue(spin);
    var buffer: [32]u8 = undefined;
    if (displayText(&buffer, displayOf(data), current)) |shown| {
        if (std.mem.eql(u8, shown, text)) {
            value.* = current;
            return gtk.true_;
        }
    }
    value.* = parseQuantity(text) orelse return gtk.INPUT_ERROR;
    return gtk.true_;
}

fn hideSpinButtons(spin: *gtk.Widget) void {
    var child = gtk.gtk_widget_get_first_child(spin);
    while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
        if (std.mem.eql(u8, std.mem.span(gtk.gtk_widget_get_css_name(widget)), "button"))
            gtk.gtk_widget_set_visible(widget, gtk.false_);
    }
}

fn spinEntry(
    range: [2]f64,
    step: f64,
    digits: c_uint,
    width_chars: c_int,
    value: f64,
    display: Display,
    label: [*:0]const u8,
) *gtk.Widget {
    const widget = gtk.gtk_spin_button_new_with_range(range[0], range[1], step);
    gtk.gtk_spin_button_set_digits(gtk.cast(gtk.SpinButton, widget), digits);
    gtk.gtk_spin_button_set_numeric(gtk.cast(gtk.SpinButton, widget), gtk.false_);
    gtk.gtk_editable_set_width_chars(gtk.cast(gtk.Editable, widget), width_chars);
    gtk.gtk_editable_set_alignment(gtk.cast(gtk.Editable, widget), 1);
    gtk.gtk_widget_add_css_class(widget, "peq-spin");
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, widget), gtk.ACCESSIBLE_PROPERTY_LABEL, label, @as(c_int, -1));
    _ = gtk.signalConnect(widget, "output", gtk.callback(spinOutput), displayData(display));
    _ = gtk.signalConnect(widget, "input", gtk.callback(quantityInput), displayData(display));
    gtk.gtk_spin_button_set_value(gtk.cast(gtk.SpinButton, widget), value);
    hideSpinButtons(widget);
    return widget;
}

fn textLabel(text: [*:0]const u8, width: c_int, css_class: ?[*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    gtk.gtk_widget_set_size_request(widget, width, -1);
    if (css_class) |name| gtk.gtk_widget_add_css_class(widget, name);
    return widget;
}

fn cell(child: *gtk.Widget, width: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_size_request(box, width, -1);
    gtk.gtk_widget_set_valign(child, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_halign(child, gtk.ALIGN_END);
    gtk.gtk_widget_set_hexpand(child, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), child);
    gtk.gtk_widget_set_hexpand(box, gtk.false_);
    return box;
}

const Column = enum { index, kind, frequency, gain, q, enabled, menu };

const column_widths = std.EnumArray(Column, c_int).init(.{
    .index = 22,
    .kind = 104,
    .frequency = 96,
    .gain = 84,
    .q = 60,
    .enabled = 52,
    .menu = 30,
});

fn tableHeader() *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(box, "peq-header");
    const titles = std.EnumArray(Column, [*:0]const u8).init(.{
        .index = "#",
        .kind = "TYPE",
        .frequency = "FREQUENCY",
        .gain = "GAIN",
        .q = "Q",
        .enabled = "ON",
        .menu = "",
    });
    for (std.enums.values(Column)) |column| {
        const heading = textLabel(titles.get(column), column_widths.get(column), null);
        switch (column) {
            .index => {},
            .kind => gtk.gtk_widget_set_hexpand(heading, gtk.true_),
            else => gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 1),
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), heading);
    }
    return box;
}

fn addAction(group: *gtk.GSimpleActionGroup, name: [*:0]const u8, handler: gtk.GCallback, data: *anyopaque, enabled: bool) void {
    const action = gtk.g_simple_action_new(name, null).?;
    gtk.g_simple_action_set_enabled(action, boolean(enabled));
    _ = gtk.signalConnect(action, "activate", handler, data);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
    gtk.g_object_unref(action);
}

fn rowMenu(row_widget: *gtk.Widget, row: *Row) *gtk.Widget {
    const count = row.self.parametric.curve.count;
    const group = gtk.g_simple_action_group_new();
    addAction(group, "duplicate", gtk.callback(duplicateActivated), row, count < max_filters);
    addAction(group, "up", gtk.callback(moveUpActivated), row, row.index > 0);
    addAction(group, "down", gtk.callback(moveDownActivated), row, row.index + 1 < count);
    addAction(group, "remove", gtk.callback(removeActivated), row, true);
    gtk.gtk_widget_insert_action_group(row_widget, "filter", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);
    const model = gtk.g_menu_new();
    gtk.g_menu_append(model, "Duplicate", "filter.duplicate");
    gtk.g_menu_append(model, "Move Up", "filter.up");
    gtk.g_menu_append(model, "Move Down", "filter.down");
    gtk.g_menu_append(model, "Remove", "filter.remove");
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, button), "view-more-horizontal-symbolic");
    gtk.gtk_menu_button_set_menu_model(gtk.cast(gtk.MenuButton, button), gtk.cast(gtk.GMenuModel, model));
    gtk.g_object_unref(model);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "peq-row-menu");
    gtk.gtk_widget_set_tooltip_text(button, "Filter actions");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, "Filter actions", @as(c_int, -1));
    return button;
}

fn buildRow(self: *App, index: u8, filter: Filter) *gtk.Widget {
    const row = &self.parametric.rows[index];
    row.* = .{ .self = self, .index = index };
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(box, "peq-row");

    var number: [8]u8 = undefined;
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), textLabel(strings.printZ(&number, "{d}", .{index + 1}) catch "", column_widths.get(.index), "peq-index"));

    const kind = gtk.gtk_drop_down_new_from_strings(if (filter.kind == .notch) &kind_labels else &listed_kind_labels);
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, kind), kindPosition(filter.kind));
    gtk.gtk_widget_add_css_class(kind, "peq-type");
    gtk.gtk_widget_set_size_request(kind, column_widths.get(.kind), -1);
    gtk.gtk_widget_set_hexpand(kind, gtk.true_);
    gtk.gtk_widget_set_halign(kind, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(kind, gtk.ALIGN_CENTER);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, kind), gtk.ACCESSIBLE_PROPERTY_LABEL, "Type", @as(c_int, -1));
    _ = gtk.signalConnect(kind, "notify::selected", gtk.callback(kindChanged), row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), kind);
    row.kind = kind;

    const frequency = spinEntry(frequency_range, 1, 1, 8, filter.frequency_hz, .frequency, "Frequency");
    _ = gtk.signalConnect(frequency, "value-changed", gtk.callback(frequencyChanged), row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cell(frequency, column_widths.get(.frequency)));
    row.frequency = frequency;

    const gain = spinEntry(.{ -gain_limit_db, gain_limit_db }, 0.1, 1, 7, filter.gain_db, .decibels, "Gain");
    gtk.gtk_widget_set_sensitive(gain, boolean(filter.usesGain()));
    _ = gtk.signalConnect(gain, "value-changed", gtk.callback(gainChanged), row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cell(gain, column_widths.get(.gain)));
    row.gain = gain;

    const range = qRange(filter.kind);
    const q = spinEntry(.{ range[0], range[1] }, 0.05, 2, 4, filter.q, .q, "Q");
    _ = gtk.signalConnect(q, "value-changed", gtk.callback(qChanged), row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cell(q, column_widths.get(.q)));
    row.q = q;

    const enabled = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(gtk.cast(gtk.Switch, enabled), boolean(filter.enabled));
    gtk.gtk_widget_add_css_class(enabled, "peq-switch");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, enabled), gtk.ACCESSIBLE_PROPERTY_LABEL, "Enabled", @as(c_int, -1));
    _ = gtk.signalConnect(enabled, "notify::active", gtk.callback(enabledChanged), row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cell(enabled, column_widths.get(.enabled)));

    const list_row = gtk.gtk_list_box_row_new();
    gtk.gtk_list_box_row_set_activatable(gtk.cast(gtk.ListBoxRow, list_row), gtk.false_);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, list_row), box);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cell(rowMenu(list_row, row), column_widths.get(.menu)));
    if (!filter.enabled) gtk.gtk_widget_add_css_class(list_row, "peq-off");
    row.widget = list_row;
    return list_row;
}

fn rebuildRows(self: *App) void {
    const editor = &self.parametric;
    const list = editor.controls.list orelse return;
    const previous = editor.suppress;
    editor.suppress = true;
    defer editor.suppress = previous;
    gtk.gtk_list_box_remove_all(gtk.cast(gtk.ListBox, list));
    editor.rows = @splat(.{});
    for (editor.curve.filterList(), 0..) |filter, index|
        gtk.gtk_list_box_append(gtk.cast(gtk.ListBox, list), buildRow(self, @intCast(index), filter));
    gtk.gtk_widget_set_visible(list, boolean(editor.curve.count != 0));
    showAddButton(self);
}

fn rebuildLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.parametric.rebuild_idle = 0;
    rebuildRows(self);
    return gtk.SOURCE_REMOVE;
}

/// A row's menu acts from inside the row, so the table is rebuilt once the
/// menu has closed rather than under it.
fn structureChanged(self: *App) void {
    edited(self);
    applyNow(self);
    if (self.parametric.rebuild_idle == 0) self.parametric.rebuild_idle = gtk.g_idle_add(rebuildLater, self);
}

fn rowFilter(row: *Row) ?*Filter {
    const editor = &row.self.parametric;
    if (editor.suppress or row.index >= editor.curve.count) return null;
    return &editor.curve.filters[row.index];
}

fn kindChanged(dropdown: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const filter = rowFilter(row) orelse return;
    const self = row.self;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, dropdown));
    if (selected >= kind_order.len) return;
    const kind = kind_order[selected];
    filter.kind = kind;
    const range = qRange(kind);
    filter.q = std.math.clamp(filter.q, range[0], range[1]);
    if (!filter.usesGain()) filter.gain_db = 0;
    {
        const previous = self.parametric.suppress;
        self.parametric.suppress = true;
        defer self.parametric.suppress = previous;
        if (row.q) |q| {
            gtk.gtk_spin_button_set_range(gtk.cast(gtk.SpinButton, q), range[0], range[1]);
            gtk.gtk_spin_button_set_value(gtk.cast(gtk.SpinButton, q), filter.q);
        }
        if (row.gain) |gain| {
            gtk.gtk_spin_button_set_value(gtk.cast(gtk.SpinButton, gain), filter.gain_db);
            gtk.gtk_widget_set_sensitive(gain, boolean(filter.usesGain()));
        }
    }
    edited(self);
    applyNow(self);
}

fn frequencyChanged(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const filter = rowFilter(row) orelse return;
    filter.frequency_hz = @floatCast(spinValue(widget));
    edited(row.self);
    scheduleApply(row.self);
}

fn gainChanged(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const filter = rowFilter(row) orelse return;
    if (!filter.usesGain()) return;
    filter.gain_db = @floatCast(@round(spinValue(widget) * 10) / 10);
    edited(row.self);
    scheduleApply(row.self);
}

fn qChanged(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const filter = rowFilter(row) orelse return;
    const range = qRange(filter.kind);
    filter.q = std.math.clamp(@as(f32, @floatCast(@round(spinValue(widget) * 100) / 100)), range[0], range[1]);
    edited(row.self);
    scheduleApply(row.self);
}

fn enabledChanged(toggle: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const filter = rowFilter(row) orelse return;
    filter.enabled = gtk.gtk_switch_get_active(gtk.cast(gtk.Switch, toggle)) != 0;
    if (row.widget) |widget| {
        if (filter.enabled) gtk.gtk_widget_remove_css_class(widget, "peq-off") else gtk.gtk_widget_add_css_class(widget, "peq-off");
    }
    edited(row.self);
    applyNow(row.self);
}

fn duplicateActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const self = row.self;
    const curve = &self.parametric.curve;
    if (row.index >= curve.count) return;
    if (curve.count == max_filters) return self.toast("A parametric equalizer has at most 16 filters");
    std.mem.copyBackwards(Filter, curve.filters[row.index + 1 .. curve.count + 1], curve.filters[row.index..curve.count]);
    curve.count += 1;
    structureChanged(self);
}

fn swap(self: *App, first: usize) void {
    const curve = &self.parametric.curve;
    if (first + 1 >= curve.count) return;
    std.mem.swap(Filter, &curve.filters[first], &curve.filters[first + 1]);
    structureChanged(self);
}

fn moveUpActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    if (row.index == 0) return;
    swap(row.self, row.index - 1);
}

fn moveDownActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    swap(row.self, row.index);
}

fn removeActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(data);
    const self = row.self;
    const curve = &self.parametric.curve;
    if (row.index >= curve.count) return;
    std.mem.copyForwards(Filter, curve.filters[row.index .. curve.count - 1], curve.filters[row.index + 1 .. curve.count]);
    curve.count -= 1;
    structureChanged(self);
}

fn addClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const curve = &self.parametric.curve;
    if (curve.count >= max_filters) return;
    curve.filters[curve.count] = .{ .kind = .peak, .frequency_hz = 1000, .gain_db = 0, .q = 1.0 };
    curve.count += 1;
    rebuildRows(self);
    edited(self);
    applyNow(self);
}

fn presetChanged(dropdown: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.parametric.suppress) return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, dropdown));
    if (selected == newPresetIndex(self)) {
        showMatchingPreset(self);
        return askPresetName(self);
    }
    const curve = presetCurve(self, selected) orelse return;
    curveReplaced(self, curve);
}

fn preampChanged(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.parametric.suppress) return;
    self.parametric.curve.preamp_db = @floatCast(@round(spinValue(widget) * 10) / 10);
    edited(self);
    scheduleApply(self);
}

fn nudgePreamp(self: *App, step: f64) void {
    const preamp = self.parametric.controls.preamp orelse return;
    setSpin(preamp, spinValue(preamp) + step);
}

fn preampDown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    nudgePreamp(state(data), -0.5);
}

fn preampUp(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    nudgePreamp(state(data), 0.5);
}

fn errorText(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.UnsupportedFilterType => "a filter type Orca does not run; it runs PK, PEQ, LS, LSC, HS, HSC, LP, HP and NO",
        error.TooManyFilters => "a parametric equalizer has at most 16 filters",
        error.FilterFrequencyOutOfRange => "a filter's Fc must be 20 to 20000 Hz",
        error.FilterGainOutOfRange => "a filter's Gain must be within 24 dB",
        error.FilterQOutOfRange => "a filter's Q must be 0.1 to 20, or 0.3 to 2 on a shelf",
        error.ParametricPreampOutOfRange => "the Preamp lines must add up to -24 to +6 dB",
        else => "not EqualizerAPO text Orca reads: Preamp: and Filter: lines, blank lines and # comments only",
    };
}

/// The first line whose addition makes the text unreadable, for any reason
/// but the preamp sum, which only the whole file decides.
pub fn failingLine(text: []const u8) ?usize {
    var end: usize = 0;
    var line: usize = 1;
    while (end <= text.len) : (line += 1) {
        const next = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
        _ = liborca.parseEqualizerApo(text[0..next]) catch |err| switch (err) {
            error.ParametricPreampOutOfRange => {},
            else => return line,
        };
        end = next + 1;
    }
    return null;
}

fn importText(self: *App, text: []const u8) void {
    const curve = liborca.parseEqualizerApo(text) catch |err| {
        var buffer: [256]u8 = undefined;
        const message = if (failingLine(text)) |line|
            strings.printZ(&buffer, "Line {d}: {s}", .{ line, errorText(err) }) catch "Could not import that preset"
        else
            strings.printZ(&buffer, "Could not import: {s}", .{errorText(err)}) catch "Could not import that preset";
        return self.toast(message);
    };
    curveReplaced(self, curve);
}

fn importChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_open_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const path_pointer = raw_path orelse return self.toast("That file is not on the local filesystem");
    defer gtk.g_free(path_pointer);
    const text = std.Io.Dir.cwd().readFileAlloc(self.io, std.mem.span(path_pointer), self.allocator, .limited(max_file_bytes)) catch |read_error|
        return self.toast(switch (read_error) {
            error.StreamTooLong => "That file is larger than 64 KiB",
            else => "Could not read that file",
        });
    defer self.allocator.free(text);
    importText(self, text);
}

fn textFilter() *gtk.FileFilter {
    const filter = gtk.gtk_file_filter_new();
    gtk.gtk_file_filter_set_name(filter, "EqualizerAPO (*.txt)");
    gtk.gtk_file_filter_add_suffix(filter, "txt");
    return filter;
}

fn importClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Import Preset");
    const filter = textFilter();
    if (gtk.g_list_store_new(gtk.gtk_file_filter_get_type())) |filters| {
        gtk.g_list_store_append(filters, filter);
        gtk.gtk_file_dialog_set_filters(dialog, gtk.cast(gtk.ListModel, filters));
        gtk.g_object_unref(filters);
    }
    gtk.gtk_file_dialog_set_default_filter(dialog, filter);
    gtk.g_object_unref(filter);
    gtk.gtk_file_dialog_open(dialog, self.window, null, importChosen, self);
    gtk.g_object_unref(dialog);
}

pub fn writeCurve(buffer: []u8, curve: Curve) ?[:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    liborca.writeEqualizerApo(&writer, curve) catch return null;
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

pub const curve_text_bytes = 128 + max_filters * 96;

fn exportChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_save_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const path_pointer = raw_path orelse return self.toast("That file is not on the local filesystem");
    defer gtk.g_free(path_pointer);
    var buffer: [curve_text_bytes]u8 = undefined;
    const text = writeCurve(&buffer, self.parametric.curve) orelse return self.toast("Could not export the equalizer");
    if (gtk.g_file_set_contents(path_pointer, text.ptr, @intCast(text.len), &err) == 0) {
        gtk.g_clear_error(&err);
        return self.toast("Could not write that file");
    }
    self.toast("Exported the equalizer");
}

pub fn chooseExport(self: *App) void {
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Export Equalizer");
    gtk.gtk_file_dialog_set_initial_name(dialog, "Equalizer.txt");
    gtk.gtk_file_dialog_save(dialog, self.window, null, exportChosen, self);
    gtk.g_object_unref(dialog);
}

const NameRequest = struct {
    self: *App,
    entry: *gtk.Widget,
};

pub fn askPresetName(self: *App) void {
    const request = self.allocator.create(NameRequest) catch return self.toast("Out of memory");
    const entry = gtk.gtk_entry_new();
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), "Name");
    gtk.gtk_entry_set_activates_default(gtk.cast(gtk.Entry, entry), gtk.true_);
    request.* = .{ .self = self, .entry = entry };
    const dialog = adw.adw_alert_dialog_new("Save as Preset", "Keeps these filters and preamp under a name in the Preset list.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, entry);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "save", "Save");
    adw.adw_alert_dialog_set_response_appearance(alert, "save", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "save");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(nameResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
    _ = gtk.g_idle_add(focusLater, gtk.g_object_ref(entry));
}

fn focusLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const entry = gtk.cast(gtk.Widget, data.?);
    defer gtk.g_object_unref(entry);
    if (gtk.gtk_widget_get_root(entry) != null) _ = gtk.gtk_widget_grab_focus(entry);
    return gtk.SOURCE_REMOVE;
}

/// Stores `curve` under `name`, replacing a preset of that name. False when
/// the name is empty or too long, or no slot is free.
pub fn storePreset(self: *App, name: []const u8, curve: Curve) bool {
    const editor = &self.parametric;
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_name_bytes) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null) return false;
    const slot = for (editor.presets[0..editor.preset_count]) |*preset| {
        if (std.mem.eql(u8, preset.name(), trimmed)) break preset;
    } else blk: {
        if (editor.preset_count == max_presets) return false;
        editor.preset_count += 1;
        break :blk &editor.presets[editor.preset_count - 1];
    };
    @memcpy(slot.name_buffer[0..trimmed.len], trimmed);
    slot.name_len = @intCast(trimmed.len);
    slot.curve = curve;
    return true;
}

fn nameResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *NameRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer self.allocator.destroy(request);
    if (!std.mem.eql(u8, std.mem.span(response), "save")) return;
    const name = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, request.entry)));
    if (std.mem.trim(u8, name, " \t").len == 0) return self.toast("A preset needs a name");
    if (!storePreset(self, name, self.parametric.curve))
        return self.toast("Could not save that preset: at most 32 presets, names up to 64 bytes");
    showPresets(self);
    settings.save(self);
}

fn exportClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    chooseExport(state(data));
}

fn fileButton(label: [*:0]const u8, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_add_css_class(button, "peq-file");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(button, "clicked", handler, self);
    return button;
}

/// The Preset and Preamp controls, then Import and Export, which wrap below
/// them as the card narrows.
fn controlRow(self: *App) *gtk.Widget {
    const editor = &self.parametric;
    const wrap = adw.adw_wrap_box_new();
    gtk.gtk_widget_add_css_class(wrap, "peq-controls");
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, wrap), 12);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, wrap), 10);
    adw.adw_wrap_box_set_justify(gtk.cast(adw.WrapBox, wrap), adw.JUSTIFY_SPREAD);
    adw.adw_wrap_box_set_justify_last_line(gtk.cast(adw.WrapBox, wrap), gtk.true_);

    const settings_group = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, settings_group), textLabel("Preset", -1, "peq-label"));
    var labels: [max_presets + 5]?[*:0]const u8 = undefined;
    var name_storage: [max_presets][max_name_bytes + 1]u8 = undefined;
    const names = gtk.gtk_string_list_new(presetLabels(self, &labels, &name_storage).ptr);
    const preset = gtk.gtk_drop_down_new(gtk.cast(gtk.ListModel, names), null);
    gtk.gtk_widget_add_css_class(preset, "settings-select");
    gtk.gtk_widget_add_css_class(preset, "peq-preset");
    gtk.gtk_widget_set_valign(preset, gtk.ALIGN_CENTER);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, preset), gtk.ACCESSIBLE_PROPERTY_LABEL, "Preset", @as(c_int, -1));
    gtk.gtk_box_append(gtk.cast(gtk.Box, settings_group), preset);
    editor.controls.preset = preset;
    editor.controls.preset_names = names;
    showMatchingPreset(self);
    _ = gtk.signalConnect(preset, "notify::selected", gtk.callback(presetChanged), self);

    const preamp_label = textLabel("Preamp", -1, "peq-label");
    gtk.gtk_widget_set_margin_start(preamp_label, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, settings_group), preamp_label);
    const preamp = spinEntry(preamp_range, 0.5, 1, 7, strings.withoutNegativeZero(editor.curve.preamp_db), .preamp, "Preamp");
    gtk.gtk_widget_add_css_class(preamp, "peq-preamp");
    _ = gtk.signalConnect(preamp, "value-changed", gtk.callback(preampChanged), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, settings_group), preamp);
    editor.controls.preamp = preamp;
    for ([_]struct { [*:0]const u8, [*:0]const u8, gtk.GCallback }{
        .{ "orca-minus-symbolic", "Lower preamp", gtk.callback(preampDown) },
        .{ "orca-plus-symbolic", "Raise preamp", gtk.callback(preampUp) },
    }) |button_info| {
        const button = gtk.gtk_button_new_from_icon_name(button_info[0]);
        gtk.gtk_widget_add_css_class(button, "peq-step");
        gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
        gtk.gtk_widget_set_tooltip_text(button, button_info[1]);
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, button_info[1], @as(c_int, -1));
        _ = gtk.signalConnect(button, "clicked", button_info[2], self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, settings_group), button);
    }
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, wrap), settings_group);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), fileButton("Import…", gtk.callback(importClicked), self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), fileButton("Export…", gtk.callback(exportClicked), self));
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, wrap), actions);
    return wrap;
}

fn filterTable(self: *App) *gtk.Widget {
    const table = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(table, "peq-table");
    gtk.gtk_box_append(gtk.cast(gtk.Box, table), tableHeader());
    const list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(list, "peq-list");
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
    gtk.gtk_list_box_set_tab_behavior(gtk.cast(gtk.ListBox, list), gtk.LIST_TAB_ITEM);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, list), gtk.ACCESSIBLE_PROPERTY_LABEL, "Filters", @as(c_int, -1));
    gtk.gtk_box_append(gtk.cast(gtk.Box, table), list);
    self.parametric.controls.list = list;

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_AUTOMATIC, gtk.POLICY_NEVER);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), table);
    gtk.gtk_widget_add_css_class(scroller, "peq-table-scroller");
    return scroller;
}

/// The editor below the Equalizer card's header in Parametric mode.
pub fn build(self: *App) *gtk.Widget {
    const root = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 14);
    gtk.gtk_widget_add_css_class(root, "peq");
    self.parametric.controls = .{ .root = root };
    gtk.gtk_box_append(gtk.cast(gtk.Box, root), controlRow(self));
    const area = graph.new(self);
    self.parametric.controls.graph = area;
    gtk.gtk_box_append(gtk.cast(gtk.Box, root), area);
    gtk.gtk_box_append(gtk.cast(gtk.Box, root), filterTable(self));

    const add = gtk.gtk_button_new_with_label("Add Filter");
    gtk.gtk_widget_add_css_class(add, "peq-file");
    gtk.gtk_widget_add_css_class(add, "peq-add");
    gtk.gtk_widget_set_halign(add, gtk.ALIGN_START);
    _ = gtk.signalConnect(add, "clicked", gtk.callback(addClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, root), add);
    self.parametric.controls.add = add;
    rebuildRows(self);
    return root;
}

/// When the Settings page is left: applies a pending edit and forgets the
/// widgets GTK is about to destroy.
pub fn leave(self: *App) void {
    const editor_state = &self.parametric;
    if (editor_state.rebuild_idle != 0) {
        _ = gtk.g_source_remove(editor_state.rebuild_idle);
        editor_state.rebuild_idle = 0;
    }
    if (editor_state.apply_timer != 0) applyNow(self);
    editor_state.drag_index = null;
    editor_state.pointer = null;
    editor_state.controls = .{};
    editor_state.rows = @splat(.{});
}

pub fn deinit(self: *App) void {
    if (self.parametric.apply_timer != 0) _ = gtk.g_source_remove(self.parametric.apply_timer);
    if (self.parametric.rebuild_idle != 0) _ = gtk.g_source_remove(self.parametric.rebuild_idle);
}
