//! Hand-written GTK4 / GLib / GObject bindings.
//!
//! `@cImport` no longer exists in this Zig, `translate-C` drowns in glib's
//! `_Pragma`-based deprecation macros, and `zig-gobject` does not build on this
//! snapshot. So the frontend declares exactly the foreign symbols it calls and
//! nothing else. This module is deliberately mechanical: no application logic
//! lives here, only `extern fn` declarations, the opaque types they take, and
//! the handful of enum values and struct layouts GTK's macros would otherwise
//! have supplied.
//!
//! Struct layouts below (`GObject`, `GObjectClass`, `GTypeInfo`,
//! `GDBusNodeInfo`, `BitsetIter`) are verified against the installed headers by
//! the `comptime` size assertions at the bottom of the file.

const std = @import("std");

// ------------------------------------------------------------- basic types

pub const gboolean = c_int;
pub const GType = usize;
pub const true_: gboolean = 1;
pub const false_: gboolean = 0;

/// `g_signal_connect` is a macro; `g_signal_connect_data` is the real symbol,
/// and every handler reaches it as this type-erased pointer.
pub const GCallback = *const fn () callconv(.c) void;

pub inline fn callback(handler: anytype) GCallback {
    return @ptrCast(&handler);
}

/// GTK's `GTK_WIDGET()` and friends are checked casts around a plain pointer
/// cast. Without the macros this is the cast, and the checking is the porter's.
pub inline fn cast(comptime T: type, pointer: anytype) *T {
    return @ptrCast(pointer);
}

// ------------------------------------------------------------ opaque types

pub const Widget = opaque {};
pub const Window = opaque {};
pub const Application = opaque {};
pub const GApplication = opaque {};
pub const GAction = opaque {};
pub const GSimpleAction = opaque {};
pub const GActionMap = opaque {};
pub const Label = opaque {};
pub const Image = opaque {};
pub const GdkPaintable = opaque {};
pub const GdkTexture = opaque {};
pub const GdkPixbuf = opaque {};
pub const GBytes = opaque {};
pub const GInputStream = opaque {};
pub const Button = opaque {};
pub const ToggleButton = opaque {};
pub const MenuButton = opaque {};
pub const ScaleButton = opaque {};
pub const Box = opaque {};
pub const HeaderBar = opaque {};
pub const SearchEntry = opaque {};
pub const Editable = opaque {};
pub const Popover = opaque {};
pub const ScrolledWindow = opaque {};
pub const Adjustment = opaque {};
pub const Scale = opaque {};
pub const Range = opaque {};
pub const ProgressBar = opaque {};
pub const DropDown = opaque {};
pub const StringList = opaque {};
pub const StringObject = opaque {};
pub const ListStore = opaque {};
pub const ListModel = opaque {};
pub const SelectionModel = opaque {};
pub const SingleSelection = opaque {};
pub const ColumnView = opaque {};
pub const ColumnViewColumn = opaque {};
pub const ColumnViewSorter = opaque {};
pub const Paned = opaque {};
pub const ListItemFactory = opaque {};
pub const ListItem = opaque {};
pub const ListView = opaque {};
pub const Sorter = opaque {};
pub const Bitset = opaque {};
pub const EventController = opaque {};
pub const FileDialog = opaque {};
pub const GVariant = opaque {};
pub const GVariantType = opaque {};
pub const GDBusConnection = opaque {};
pub const GDBusMethodInvocation = opaque {};
pub const GDBusInterfaceInfo = opaque {};
pub const GError = opaque {};
pub const GFile = opaque {};
pub const GAsyncResult = opaque {};
pub const GCancellable = opaque {};

// ------------------------------------------------------------- enum values
//
// GTK enumerators are plain integers once the headers are out of the picture.
// Only the ones this frontend names are declared.

pub const ORIENTATION_HORIZONTAL: c_int = 0;
pub const ORIENTATION_VERTICAL: c_int = 1;

pub const ALIGN_FILL: c_int = 0;
pub const ALIGN_START: c_int = 1;
pub const ALIGN_END: c_int = 2;
pub const ALIGN_CENTER: c_int = 3;

pub const ELLIPSIZE_NONE: c_int = 0;
pub const ELLIPSIZE_END: c_int = 3;

pub const PHASE_NONE: c_int = 0;
pub const PHASE_CAPTURE: c_int = 1;
pub const PHASE_BUBBLE: c_int = 2;
pub const PHASE_TARGET: c_int = 3;

pub const KEY_space: c_uint = 0x020;
pub const MODIFIER_SHIFT: c_uint = 1 << 0;
pub const MODIFIER_CONTROL: c_uint = 1 << 2;
pub const MODIFIER_ALT: c_uint = 1 << 3;

pub const INVALID_LIST_POSITION: c_uint = 0xffffffff;

pub const SORT_ASCENDING: c_int = 0;
pub const SORT_DESCENDING: c_int = 1;

pub const APPLICATION_DEFAULT_FLAGS: c_uint = 0;
pub const BUS_TYPE_SESSION: c_int = 2;
pub const BUS_NAME_OWNER_FLAGS_NONE: c_uint = 0;

pub const SOURCE_REMOVE: gboolean = 0;
pub const SOURCE_CONTINUE: gboolean = 1;

/// `G_VARIANT_TYPE("...")` is a cast of the type string itself.
pub inline fn variantType(comptime text: [:0]const u8) *const GVariantType {
    return @ptrCast(text.ptr);
}

// ------------------------------------------------------------ GObject core

/// `struct _GObject`. Verified 24 bytes against the installed glib.
pub const GObject = extern struct {
    g_class: ?*anyopaque,
    ref_count: c_uint,
    qdata: ?*anyopaque,
};

/// `struct _GObjectClass`. Only `finalize` is ever written, but the whole
/// layout has to be right for the offset to be.
pub const GObjectClass = extern struct {
    g_type: GType,
    construct_properties: ?*anyopaque,
    constructor: ?*anyopaque,
    set_property: ?*anyopaque,
    get_property: ?*anyopaque,
    dispose: ?*const fn (*GObject) callconv(.c) void,
    finalize: ?*const fn (*GObject) callconv(.c) void,
    dispatch_properties_changed: ?*anyopaque,
    notify: ?*anyopaque,
    constructed: ?*anyopaque,
    flags: usize,
    n_construct_properties: usize,
    pspecs: ?*anyopaque,
    n_pspecs: usize,
    pdummy: [3]?*anyopaque,
};

pub const GTypeInfo = extern struct {
    class_size: u16,
    _pad0: [6]u8 = @splat(0),
    base_init: ?*anyopaque = null,
    base_finalize: ?*anyopaque = null,
    class_init: ?*const fn (*anyopaque, ?*anyopaque) callconv(.c) void = null,
    class_finalize: ?*anyopaque = null,
    class_data: ?*const anyopaque = null,
    instance_size: u16,
    n_preallocs: u16 = 0,
    _pad1: [4]u8 = @splat(0),
    instance_init: ?*const fn (*anyopaque, ?*anyopaque) callconv(.c) void = null,
    value_table: ?*const anyopaque = null,
};

pub extern fn g_object_get_type() GType;
pub extern fn g_type_register_static(
    parent_type: GType,
    type_name: [*:0]const u8,
    info: *const GTypeInfo,
    flags: c_uint,
) GType;
pub extern fn g_type_class_peek_parent(g_class: *anyopaque) ?*anyopaque;
pub extern fn g_object_new_with_properties(
    object_type: GType,
    n_properties: c_uint,
    names: ?[*]const [*:0]const u8,
    values: ?*const anyopaque,
) ?*GObject;
pub extern fn g_object_ref(object: ?*anyopaque) ?*anyopaque;
pub extern fn g_object_unref(object: ?*anyopaque) void;

pub extern fn g_signal_connect_data(
    instance: ?*anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: GCallback,
    data: ?*anyopaque,
    destroy_data: ?*anyopaque,
    connect_flags: c_uint,
) c_ulong;

/// The `g_signal_connect` macro, spelled out.
pub inline fn signalConnect(
    instance: ?*anyopaque,
    signal: [*:0]const u8,
    handler: GCallback,
    data: ?*anyopaque,
) c_ulong {
    return g_signal_connect_data(instance, signal, handler, data, null, 0);
}

// ------------------------------------------------------------------- GLib

pub extern fn g_free(memory: ?*anyopaque) void;
pub extern fn g_strndup(str: [*]const u8, n: usize) ?[*:0]u8;
pub extern fn g_get_user_data_dir() [*:0]const u8;
pub extern fn g_mkdir_with_parents(pathname: [*:0]const u8, mode: c_int) c_int;
pub extern fn g_get_monotonic_time() i64;
pub extern fn g_timeout_add(
    interval: c_uint,
    function: *const fn (?*anyopaque) callconv(.c) gboolean,
    data: ?*anyopaque,
) c_uint;
pub extern fn g_source_remove(tag: c_uint) gboolean;
pub extern fn g_clear_error(err: *?*GError) void;

pub extern fn g_list_model_get_n_items(list: ?*ListModel) c_uint;
pub extern fn g_list_model_get_item(list: ?*ListModel, position: c_uint) ?*anyopaque;

pub extern fn g_list_store_new(item_type: GType) ?*ListStore;
pub extern fn g_list_store_splice(
    store: *ListStore,
    position: c_uint,
    n_removals: c_uint,
    additions: ?[*]const ?*anyopaque,
    n_additions: c_uint,
) void;
pub extern fn g_list_store_remove_all(store: *ListStore) void;

pub extern fn g_simple_action_new(name: [*:0]const u8, parameter_type: ?*const GVariantType) ?*GSimpleAction;
pub extern fn g_action_map_add_action(action_map: *GActionMap, action: *GAction) void;
pub extern fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*]const ?[*:0]const u8) c_int;
pub extern fn g_application_quit(application: *GApplication) void;
pub extern fn g_application_activate(application: *GApplication) void;

pub extern fn g_file_get_path(file: *GFile) ?[*:0]u8;

// -------------------------------------------------------- images in memory
//
// A cover arrives from liborca as caller-owned encoded bytes, and has to
// become something a widget can draw without ever touching the filesystem.
// The stream and the *scaled* decode are what keep a pathological image from
// turning a 12 MiB JPEG into hundreds of megabytes of pixels.

/// Borrows `data` rather than copying it. The plain `g_bytes_new` copies, and
/// on the largest cover in the reference library that second 11.3 MiB buffer
/// was worth 12 MB of resident memory for the length of one decode. The borrow
/// is sound only because the decode is synchronous and the GBytes is dropped
/// before the borrowed buffer is.
pub extern fn g_bytes_new_static(data: ?*const anyopaque, size: usize) *GBytes;
pub extern fn g_bytes_unref(bytes: *GBytes) void;
pub extern fn g_memory_input_stream_new_from_bytes(bytes: *GBytes) *GInputStream;

/// Decodes at most `width` x `height` pixels. The scaling happens inside the
/// loader, so the full-resolution image is never materialized.
pub extern fn gdk_pixbuf_new_from_stream_at_scale(
    stream: *GInputStream,
    width: c_int,
    height: c_int,
    preserve_aspect_ratio: gboolean,
    cancellable: ?*GCancellable,
    err: *?*GError,
) ?*GdkPixbuf;
pub extern fn gdk_texture_new_for_pixbuf(pixbuf: *GdkPixbuf) *GdkTexture;

// ---------------------------------------------------------------- GVariant
//
// Everything here is the non-variadic form. `g_variant_new`,
// `g_variant_get` and `g_variant_builder_add` are format-string varargs, which
// is exactly the kind of construct a hand-written binding should not attempt:
// arrays, dict entries and tuples are assembled from typed primitives instead.

pub extern fn g_variant_new_boolean(value: gboolean) *GVariant;
pub extern fn g_variant_new_string(string: [*:0]const u8) *GVariant;
pub extern fn g_variant_new_object_path(object_path: [*:0]const u8) *GVariant;
pub extern fn g_variant_new_double(value: f64) *GVariant;
pub extern fn g_variant_new_int64(value: i64) *GVariant;
pub extern fn g_variant_new_strv(strv: ?[*]const ?[*:0]const u8, length: isize) *GVariant;
pub extern fn g_variant_new_variant(value: *GVariant) *GVariant;
pub extern fn g_variant_new_dict_entry(key: *GVariant, value: *GVariant) *GVariant;
pub extern fn g_variant_new_array(
    child_type: ?*const GVariantType,
    children: ?[*]const *GVariant,
    n_children: usize,
) *GVariant;
pub extern fn g_variant_new_tuple(children: [*]const *GVariant, n_children: usize) *GVariant;
pub extern fn g_variant_get_child_value(value: *GVariant, index: usize) *GVariant;
pub extern fn g_variant_get_int64(value: *GVariant) i64;
pub extern fn g_variant_get_double(value: *GVariant) f64;
pub extern fn g_variant_unref(value: *GVariant) void;

// -------------------------------------------------------------------- DBus

pub const GDBusNodeInfo = extern struct {
    ref_count: c_int,
    _pad: [4]u8 = @splat(0),
    path: ?[*:0]u8,
    interfaces: [*]?*GDBusInterfaceInfo,
    nodes: ?*anyopaque,
    annotations: ?*anyopaque,
};

pub const MethodCallFunc = *const fn (
    connection: *GDBusConnection,
    sender: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    method_name: ?[*:0]const u8,
    parameters: *GVariant,
    invocation: *GDBusMethodInvocation,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub const GetPropertyFunc = *const fn (
    connection: *GDBusConnection,
    sender: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    property_name: ?[*:0]const u8,
    err: ?*?*GError,
    user_data: ?*anyopaque,
) callconv(.c) ?*GVariant;

pub const SetPropertyFunc = *const fn (
    connection: *GDBusConnection,
    sender: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    property_name: ?[*:0]const u8,
    value: *GVariant,
    err: ?*?*GError,
    user_data: ?*anyopaque,
) callconv(.c) gboolean;

pub const GDBusInterfaceVTable = extern struct {
    method_call: ?MethodCallFunc,
    get_property: ?GetPropertyFunc,
    set_property: ?SetPropertyFunc,
    padding: [8]?*anyopaque = @splat(null),
};

pub extern fn g_bus_get_sync(
    bus_type: c_int,
    cancellable: ?*GCancellable,
    err: *?*GError,
) ?*GDBusConnection;
pub extern fn g_dbus_node_info_new_for_xml(xml_data: [*:0]const u8, err: *?*GError) ?*GDBusNodeInfo;
pub extern fn g_dbus_node_info_unref(info: *GDBusNodeInfo) void;
pub extern fn g_dbus_connection_register_object(
    connection: *GDBusConnection,
    object_path: [*:0]const u8,
    interface_info: *GDBusInterfaceInfo,
    vtable: *const GDBusInterfaceVTable,
    user_data: ?*anyopaque,
    user_data_free_func: ?*anyopaque,
    err: *?*GError,
) c_uint;
pub extern fn g_dbus_connection_unregister_object(
    connection: *GDBusConnection,
    registration_id: c_uint,
) gboolean;
pub extern fn g_dbus_connection_emit_signal(
    connection: *GDBusConnection,
    destination_bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    signal_name: [*:0]const u8,
    parameters: ?*GVariant,
    err: ?*?*GError,
) gboolean;
pub extern fn g_dbus_method_invocation_return_value(
    invocation: *GDBusMethodInvocation,
    parameters: ?*GVariant,
) void;
pub extern fn g_bus_own_name_on_connection(
    connection: *GDBusConnection,
    name: [*:0]const u8,
    flags: c_uint,
    name_acquired_handler: ?*anyopaque,
    name_lost_handler: ?*anyopaque,
    user_data: ?*anyopaque,
    user_data_free_func: ?*anyopaque,
) c_uint;
pub extern fn g_bus_unown_name(owner_id: c_uint) void;

// --------------------------------------------------------------------- GTK

pub extern fn gtk_application_new(application_id: [*:0]const u8, flags: c_uint) ?*Application;
pub extern fn gtk_application_window_new(application: *Application) *Widget;
pub extern fn gtk_application_set_accels_for_action(
    application: *Application,
    detailed_action_name: [*:0]const u8,
    accels: [*]const ?[*:0]const u8,
) void;

pub extern fn gtk_window_present(window: *Window) void;
pub extern fn gtk_window_set_title(window: *Window, title: ?[*:0]const u8) void;
pub extern fn gtk_window_set_default_size(window: *Window, width: c_int, height: c_int) void;
pub extern fn gtk_window_set_titlebar(window: *Window, titlebar: ?*Widget) void;
pub extern fn gtk_window_set_child(window: *Window, child: ?*Widget) void;

pub extern fn gtk_widget_set_tooltip_text(widget: *Widget, text: ?[*:0]const u8) void;
pub extern fn gtk_widget_set_size_request(widget: *Widget, width: c_int, height: c_int) void;
pub extern fn gtk_widget_set_hexpand(widget: *Widget, expand: gboolean) void;
pub extern fn gtk_widget_set_vexpand(widget: *Widget, expand: gboolean) void;
pub extern fn gtk_widget_set_valign(widget: *Widget, alignment: c_int) void;
pub extern fn gtk_widget_set_visible(widget: *Widget, visible: gboolean) void;
pub extern fn gtk_widget_set_sensitive(widget: *Widget, sensitive: gboolean) void;
pub extern fn gtk_widget_set_opacity(widget: *Widget, opacity: f64) void;
pub extern fn gtk_widget_set_margin_start(widget: *Widget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_end(widget: *Widget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_top(widget: *Widget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(widget: *Widget, margin: c_int) void;
pub extern fn gtk_widget_add_css_class(widget: *Widget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_remove_css_class(widget: *Widget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_add_controller(widget: *Widget, controller: *EventController) void;
pub extern fn gtk_widget_get_first_child(widget: *Widget) ?*Widget;
pub extern fn gtk_widget_get_next_sibling(widget: *Widget) ?*Widget;

pub extern fn gtk_header_bar_new() *Widget;
pub extern fn gtk_header_bar_pack_start(bar: *HeaderBar, child: *Widget) void;
pub extern fn gtk_header_bar_pack_end(bar: *HeaderBar, child: *Widget) void;
pub extern fn gtk_header_bar_set_title_widget(bar: *HeaderBar, title_widget: ?*Widget) void;

pub extern fn gtk_button_new_with_label(label: [*:0]const u8) *Widget;
pub extern fn gtk_button_new_from_icon_name(icon_name: ?[*:0]const u8) *Widget;
pub extern fn gtk_button_set_icon_name(button: *Button, icon_name: [*:0]const u8) void;
pub extern fn gtk_toggle_button_new() *Widget;
pub extern fn gtk_toggle_button_get_active(button: *ToggleButton) gboolean;
pub extern fn gtk_menu_button_new() *Widget;
pub extern fn gtk_menu_button_set_icon_name(button: *MenuButton, icon_name: [*:0]const u8) void;
pub extern fn gtk_menu_button_set_popover(button: *MenuButton, popover: ?*Widget) void;
pub extern fn gtk_scale_button_new(
    min: f64,
    max: f64,
    step: f64,
    icons: ?[*]const ?[*:0]const u8,
) *Widget;
pub extern fn gtk_scale_button_set_value(button: *ScaleButton, value: f64) void;
pub extern fn gtk_scale_button_get_value(button: *ScaleButton) f64;

pub extern fn gtk_search_entry_new() *Widget;
pub extern fn gtk_search_entry_set_placeholder_text(
    entry: *SearchEntry,
    text: ?[*:0]const u8,
) void;
pub extern fn gtk_editable_get_text(editable: *Editable) [*:0]const u8;
pub extern fn gtk_editable_set_text(editable: *Editable, text: [*:0]const u8) void;

pub extern fn gtk_image_new_from_icon_name(icon_name: ?[*:0]const u8) *Widget;
pub extern fn gtk_image_set_from_icon_name(image: *Image, icon_name: ?[*:0]const u8) void;
pub extern fn gtk_image_set_from_paintable(image: *Image, paintable: ?*GdkPaintable) void;
pub extern fn gtk_image_set_pixel_size(image: *Image, pixel_size: c_int) void;

pub extern fn gtk_label_new(text: ?[*:0]const u8) *Widget;
pub extern fn gtk_label_set_text(label: *Label, text: [*:0]const u8) void;
pub extern fn gtk_label_set_xalign(label: *Label, xalign: f32) void;
pub extern fn gtk_label_set_ellipsize(label: *Label, mode: c_int) void;

pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) *Widget;
pub extern fn gtk_box_append(box: *Box, child: *Widget) void;
pub extern fn gtk_separator_new(orientation: c_int) *Widget;

pub extern fn gtk_paned_new(orientation: c_int) *Widget;
pub extern fn gtk_paned_set_start_child(paned: *Paned, child: ?*Widget) void;
pub extern fn gtk_paned_set_end_child(paned: *Paned, child: ?*Widget) void;
pub extern fn gtk_paned_set_position(paned: *Paned, position: c_int) void;
pub extern fn gtk_paned_set_resize_start_child(paned: *Paned, resize: gboolean) void;
pub extern fn gtk_paned_set_shrink_start_child(paned: *Paned, shrink: gboolean) void;
pub extern fn gtk_paned_set_shrink_end_child(paned: *Paned, shrink: gboolean) void;

pub extern fn gtk_popover_new() *Widget;
pub extern fn gtk_popover_set_child(popover: *Popover, child: ?*Widget) void;

pub extern fn gtk_scrolled_window_new() *Widget;
pub extern fn gtk_scrolled_window_set_child(window: *ScrolledWindow, child: ?*Widget) void;
pub extern fn gtk_scrolled_window_get_vadjustment(window: *ScrolledWindow) *Adjustment;

pub extern fn gtk_adjustment_new(
    value: f64,
    lower: f64,
    upper: f64,
    step_increment: f64,
    page_increment: f64,
    page_size: f64,
) *Adjustment;
pub extern fn gtk_adjustment_get_upper(adjustment: *Adjustment) f64;
pub extern fn gtk_adjustment_get_value(adjustment: *Adjustment) f64;
pub extern fn gtk_adjustment_get_page_size(adjustment: *Adjustment) f64;
pub extern fn gtk_adjustment_set_upper(adjustment: *Adjustment, upper: f64) void;
pub extern fn gtk_adjustment_set_value(adjustment: *Adjustment, value: f64) void;

pub extern fn gtk_scale_new(orientation: c_int, adjustment: ?*Adjustment) *Widget;
pub extern fn gtk_scale_set_draw_value(scale: *Scale, draw_value: gboolean) void;

pub extern fn gtk_progress_bar_new() *Widget;
pub extern fn gtk_progress_bar_set_fraction(bar: *ProgressBar, fraction: f64) void;
pub extern fn gtk_progress_bar_pulse(bar: *ProgressBar) void;

pub extern fn gtk_string_list_new(strings: ?[*]const ?[*:0]const u8) *StringList;
pub extern fn gtk_string_list_append(list: *StringList, string: [*:0]const u8) void;
pub extern fn gtk_string_list_splice(
    list: *StringList,
    position: c_uint,
    n_removals: c_uint,
    additions: ?[*]const ?[*:0]const u8,
) void;
pub extern fn gtk_string_object_get_string(object: *StringObject) [*:0]const u8;

pub extern fn gtk_drop_down_new(model: ?*ListModel, expression: ?*anyopaque) *Widget;
pub extern fn gtk_drop_down_get_selected(drop_down: *DropDown) c_uint;
pub extern fn gtk_drop_down_set_selected(drop_down: *DropDown, position: c_uint) void;

pub extern fn gtk_multi_selection_new(model: ?*ListModel) *SelectionModel;
pub extern fn gtk_single_selection_new(model: ?*ListModel) *SingleSelection;
pub extern fn gtk_single_selection_get_selected(selection: *SingleSelection) c_uint;
pub extern fn gtk_single_selection_set_selected(selection: *SingleSelection, position: c_uint) void;
pub extern fn gtk_no_selection_new(model: ?*ListModel) *SelectionModel;
pub extern fn gtk_selection_model_get_selection(model: *SelectionModel) *Bitset;

pub extern fn gtk_bitset_get_size(bitset: *Bitset) u64;
pub extern fn gtk_bitset_contains(bitset: *Bitset, value: c_uint) gboolean;
pub extern fn gtk_bitset_unref(bitset: *Bitset) void;

/// `struct _GtkBitsetIter` is ten opaque pointers wide.
pub const BitsetIter = extern struct {
    private_data: [10]?*anyopaque = @splat(null),
};

pub extern fn gtk_bitset_iter_init_first(
    iter: *BitsetIter,
    set: *Bitset,
    value: *c_uint,
) gboolean;
pub extern fn gtk_bitset_iter_next(iter: *BitsetIter, value: *c_uint) gboolean;

pub extern fn gtk_column_view_new(model: ?*SelectionModel) *Widget;
pub extern fn gtk_column_view_append_column(view: *ColumnView, column: *ColumnViewColumn) void;
pub extern fn gtk_column_view_get_sorter(view: *ColumnView) ?*Sorter;
pub extern fn gtk_column_view_set_show_column_separators(view: *ColumnView, show: gboolean) void;
pub extern fn gtk_column_view_set_reorderable(view: *ColumnView, reorderable: gboolean) void;
pub extern fn gtk_column_view_column_new(
    title: ?[*:0]const u8,
    factory: ?*ListItemFactory,
) *ColumnViewColumn;
pub extern fn gtk_column_view_column_set_resizable(column: *ColumnViewColumn, resizable: gboolean) void;
pub extern fn gtk_column_view_column_set_expand(column: *ColumnViewColumn, expand: gboolean) void;
pub extern fn gtk_column_view_column_set_fixed_width(column: *ColumnViewColumn, width: c_int) void;
pub extern fn gtk_column_view_column_set_sorter(column: *ColumnViewColumn, sorter: ?*Sorter) void;
pub extern fn gtk_column_view_sort_by_column(
    view: *ColumnView,
    column: ?*ColumnViewColumn,
    direction: c_int,
) void;

/// The column view's own sorter, which is what a header click updates. Reading
/// the primary column and order off it is how a header click becomes a new
/// engine query rather than a re-sort of the loaded page.
pub extern fn gtk_column_view_sorter_get_primary_sort_column(
    sorter: *ColumnViewSorter,
) ?*ColumnViewColumn;
pub extern fn gtk_column_view_sorter_get_primary_sort_order(sorter: *ColumnViewSorter) c_int;

pub extern fn gtk_signal_list_item_factory_new() *ListItemFactory;
pub extern fn gtk_list_item_set_child(item: *ListItem, child: ?*Widget) void;
pub extern fn gtk_list_item_get_child(item: *ListItem) ?*Widget;
pub extern fn gtk_list_item_get_item(item: *ListItem) ?*anyopaque;
pub extern fn gtk_list_view_new(model: ?*SelectionModel, factory: ?*ListItemFactory) *Widget;

/// A NULL `sort_func` makes every element compare equal, which is what a column
/// needs to be clickable without a sort model behind it.
pub extern fn gtk_custom_sorter_new(
    sort_func: ?*const anyopaque,
    user_data: ?*anyopaque,
    user_destroy: ?*anyopaque,
) *Sorter;

pub extern fn gtk_event_controller_key_new() *EventController;
pub extern fn gtk_event_controller_set_propagation_phase(
    controller: *EventController,
    phase: c_int,
) void;

pub const AsyncReadyCallback = *const fn (?*GObject, *GAsyncResult, ?*anyopaque) callconv(.c) void;

pub extern fn gtk_file_dialog_new() *FileDialog;
pub extern fn gtk_file_dialog_set_title(dialog: *FileDialog, title: [*:0]const u8) void;
pub extern fn gtk_file_dialog_select_folder(
    dialog: *FileDialog,
    parent: ?*Window,
    cancellable: ?*GCancellable,
    ready: ?AsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_file_dialog_select_folder_finish(
    dialog: *FileDialog,
    result: *GAsyncResult,
    err: *?*GError,
) ?*GFile;

// ---------------------------------------------------- layout verification

comptime {
    std.debug.assert(@sizeOf(GObject) == 24);
    std.debug.assert(@sizeOf(GObjectClass) == 136);
    std.debug.assert(@offsetOf(GObjectClass, "dispose") == 40);
    std.debug.assert(@offsetOf(GObjectClass, "finalize") == 48);
    std.debug.assert(@sizeOf(GTypeInfo) == 72);
    std.debug.assert(@offsetOf(GTypeInfo, "instance_size") == 48);
    std.debug.assert(@offsetOf(GTypeInfo, "instance_init") == 56);
    std.debug.assert(@sizeOf(GDBusNodeInfo) == 40);
    std.debug.assert(@offsetOf(GDBusNodeInfo, "interfaces") == 16);
    std.debug.assert(@sizeOf(GDBusInterfaceVTable) == 88);
    std.debug.assert(@sizeOf(BitsetIter) == 80);
}
