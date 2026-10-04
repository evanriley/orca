//! Hand-written GTK4 / GLib / GObject bindings.
//!
//! `@cImport` does not exist in this Zig, `translate-C` drowns in glib's
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

pub const gboolean = c_int;
pub const GType = usize;
pub const true_: gboolean = 1;
pub const false_: gboolean = 0;

/// `g_signal_connect` is a macro; `g_signal_connect_data` is the real symbol,
/// and every handler reaches it as this type-erased pointer.
pub const GCallback = *const fn () callconv(.c) void;

pub inline fn callback(handler: anytype) GCallback {
    return switch (@typeInfo(@TypeOf(handler))) {
        .pointer => @ptrCast(handler),
        else => @ptrCast(&handler),
    };
}

/// GTK's `GTK_WIDGET()` and friends are checked casts around a plain pointer
/// cast. Without the macros this is the cast, and the checking is the porter's.
pub inline fn cast(comptime T: type, pointer: anytype) *T {
    return @ptrCast(pointer);
}

pub const Widget = opaque {};
pub const Window = opaque {};
pub const Application = opaque {};
pub const GApplication = opaque {};
pub const GNotification = opaque {};
pub const GAction = opaque {};
pub const GSimpleAction = opaque {};
pub const GActionMap = opaque {};
pub const Label = opaque {};
pub const Image = opaque {};
pub const GdkPaintable = opaque {};
pub const GdkTexture = opaque {};
pub const GdkPixbuf = opaque {};
pub const GBytes = opaque {};
pub const Accessible = opaque {};
pub const GInputStream = opaque {};
pub const Button = opaque {};
pub const ToggleButton = opaque {};
pub const LinkButton = opaque {};
pub const CheckButton = opaque {};
pub const MenuButton = opaque {};
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
pub const WindowHandle = opaque {};
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
pub const CenterBox = opaque {};
pub const Picture = opaque {};
pub const AspectFrame = opaque {};
pub const Stack = opaque {};
pub const ListBox = opaque {};
pub const ListBoxRow = opaque {};
pub const Revealer = opaque {};
pub const CssProvider = opaque {};
pub const GdkDisplay = opaque {};
pub const IconTheme = opaque {};
pub const PangoFontMap = opaque {};
pub const GMenu = opaque {};
pub const GMenuModel = opaque {};
pub const Actionable = opaque {};
pub const GTask = opaque {};
pub const GridView = opaque {};
pub const Overlay = opaque {};
pub const FlowBox = opaque {};
pub const FlowBoxChild = opaque {};
pub const GestureSingle = opaque {};
pub const Orientable = opaque {};
pub const Gesture = opaque {};
pub const GdkClipboard = opaque {};
pub const Switch = opaque {};
pub const Settings = opaque {};
pub const Grid = opaque {};
pub const LayoutManager = opaque {};
pub const LayoutChild = opaque {};
pub const GridLayoutChild = opaque {};
pub const UriLauncher = opaque {};
pub const FileLauncher = opaque {};
pub const GSimpleActionGroup = opaque {};
pub const GActionGroup = opaque {};
pub const FileFilter = opaque {};
pub const Entry = opaque {};

pub const GKeyFile = opaque {};
pub extern fn g_key_file_new() *GKeyFile;
pub extern fn g_key_file_free(key_file: *GKeyFile) void;
pub extern fn g_key_file_load_from_file(key_file: *GKeyFile, file: [*:0]const u8, flags: c_uint, err: *?*GError) gboolean;
pub extern fn g_key_file_save_to_file(key_file: *GKeyFile, file: [*:0]const u8, err: *?*GError) gboolean;
pub extern fn g_key_file_get_string(key_file: *GKeyFile, group: [*:0]const u8, key: [*:0]const u8, err: *?*GError) ?[*:0]u8;
pub extern fn g_key_file_set_string(key_file: *GKeyFile, group: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) void;
pub extern fn g_get_user_config_dir() [*:0]const u8;

pub const Rectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };

pub const ORIENTATION_HORIZONTAL: c_int = 0;
pub const ORIENTATION_VERTICAL: c_int = 1;

pub const ALIGN_FILL: c_int = 0;
pub const ALIGN_START: c_int = 1;
pub const ALIGN_END: c_int = 2;
pub const ALIGN_CENTER: c_int = 3;
pub const ALIGN_BASELINE_FILL: c_int = 4;

pub const PACK_END: c_int = 1;

pub const JUSTIFY_RIGHT: c_int = 1;
pub const JUSTIFY_CENTER: c_int = 2;

pub const ELLIPSIZE_NONE: c_int = 0;
pub const ELLIPSIZE_START: c_int = 1;
pub const ELLIPSIZE_MIDDLE: c_int = 2;
pub const ELLIPSIZE_END: c_int = 3;
pub const WRAP_WORD: c_int = 0;
pub const WRAP_WORD_CHAR: c_int = 2;

pub const PHASE_NONE: c_int = 0;
pub const PHASE_CAPTURE: c_int = 1;
pub const PHASE_BUBBLE: c_int = 2;
pub const PHASE_TARGET: c_int = 3;

pub const KEY_space: c_uint = 0x020;
pub const KEY_1: c_uint = 0x031;
pub const KEY_5: c_uint = 0x035;
pub const KEY_L: c_uint = 0x04c;
pub const KEY_l: c_uint = 0x06c;
pub const MODIFIER_SHIFT: c_uint = 1 << 0;
pub const MODIFIER_CONTROL: c_uint = 1 << 2;
pub const MODIFIER_ALT: c_uint = 1 << 3;

pub const POS_RIGHT: c_int = 1;
pub const POS_TOP: c_int = 2;
pub const POS_BOTTOM: c_int = 3;

pub const INVALID_LIST_POSITION: c_uint = 0xffffffff;

pub const SORT_ASCENDING: c_int = 0;
pub const SORT_DESCENDING: c_int = 1;

pub const APPLICATION_DEFAULT_FLAGS: c_uint = 0;
pub const BUS_TYPE_SESSION: c_int = 2;
pub const BUS_NAME_OWNER_FLAGS_NONE: c_uint = 0;

pub const OVERFLOW_HIDDEN: c_int = 1;
pub const CONTENT_FIT_COVER: c_int = 2;
pub const CONNECT_SWAPPED: c_uint = 2;
pub const POLICY_AUTOMATIC: c_int = 1;
pub const POLICY_NEVER: c_int = 2;
pub const POLICY_EXTERNAL: c_int = 3;

pub const SELECTION_NONE: c_int = 0;
pub const SELECTION_SINGLE: c_int = 1;
pub const LIST_TAB_ITEM: c_int = 1;
pub const LIST_SCROLL_NONE: c_int = 0;
pub const EVENT_CONTROLLER_SCROLL_VERTICAL: c_int = 1;
pub const SCROLL_UNIT_WHEEL: c_int = 0;
pub const STACK_TRANSITION_CROSSFADE: c_int = 1;
pub const REVEALER_TRANSITION_SLIDE_UP: c_int = 4;
pub const REVEALER_TRANSITION_SLIDE_DOWN: c_int = 5;
pub const STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;
pub const LICENSE_MPL_2_0: c_int = 17;
pub const KEY_Left: c_uint = 0xff51;
pub const KEY_Right: c_uint = 0xff53;
pub const KEY_Delete: c_uint = 0xffff;
pub const KEY_Up: c_uint = 0xff52;
pub const KEY_BackSpace: c_uint = 0xff08;
pub const KEY_Down: c_uint = 0xff54;
pub const KEY_Home: c_uint = 0xff50;
pub const KEY_End: c_uint = 0xff57;
pub const KEY_Return: c_uint = 0xff0d;
pub const KEY_KP_Enter: c_uint = 0xff8d;
pub const KEY_ISO_Enter: c_uint = 0xfe34;
pub const KEY_Escape: c_uint = 0xff1b;
pub const KEY_KP_Delete: c_uint = 0xff9f;
pub const KEY_Menu: c_uint = 0xff67;
pub const KEY_F10: c_uint = 0xffc7;
pub const ACTION_MOVE: c_int = 1 << 1;
pub const EVENT_SEQUENCE_CLAIMED: c_int = 1;
pub const EVENT_SEQUENCE_DENIED: c_int = 2;
pub const SOURCE_REMOVE: gboolean = 0;
pub const SOURCE_CONTINUE: gboolean = 1;

/// `G_VARIANT_TYPE("...")` is a cast of the type string itself.
pub inline fn variantType(comptime text: [:0]const u8) *const GVariantType {
    return @ptrCast(text.ptr);
}

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
pub const GInterfaceInfo = extern struct {
    interface_init: ?*const fn (*anyopaque, ?*anyopaque) callconv(.c) void = null,
    interface_finalize: ?*anyopaque = null,
    interface_data: ?*anyopaque = null,
};
pub extern fn g_type_add_interface_static(instance_type: GType, interface_type: GType, info: *const GInterfaceInfo) void;

/// `struct _GListModelInterface`: the `GTypeInterface` header, then the three
/// methods a list model implements.
pub const ListModelInterface = extern struct {
    g_type: GType,
    g_instance_type: GType,
    get_item_type: ?*const fn (*ListModel) callconv(.c) GType,
    get_n_items: ?*const fn (*ListModel) callconv(.c) c_uint,
    get_item: ?*const fn (*ListModel, c_uint) callconv(.c) ?*anyopaque,
};
pub extern fn g_list_model_get_type() GType;
pub extern fn g_object_new_with_properties(
    object_type: GType,
    n_properties: c_uint,
    names: ?[*]const [*:0]const u8,
    values: ?*const anyopaque,
) ?*GObject;
pub extern fn g_object_ref(object: ?*anyopaque) ?*anyopaque;
pub extern fn g_object_ref_sink(object: ?*anyopaque) ?*anyopaque;
pub extern fn g_object_unref(object: ?*anyopaque) void;

pub extern fn g_signal_connect_data(
    instance: ?*anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: GCallback,
    data: ?*anyopaque,
    destroy_data: ?*anyopaque,
    connect_flags: c_uint,
) c_ulong;

pub extern fn g_signal_connect_object(
    instance: ?*anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: GCallback,
    gobject: ?*anyopaque,
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

/// `struct _GValue`: a type tag and two words of payload.
pub const GValue = extern struct {
    g_type: GType = 0,
    data: [2]u64 = @splat(0),
};

/// `G_TYPE_BOOLEAN`, the fundamental type number 5 shifted by
/// `G_TYPE_FUNDAMENTAL_SHIFT`.
pub const G_TYPE_BOOLEAN: GType = 5 << 2;
pub const G_TYPE_INT: GType = 6 << 2;
pub const G_TYPE_UINT: GType = 7 << 2;

pub extern fn g_value_init(value: *GValue, g_type: GType) *GValue;
pub extern fn g_value_set_boolean(value: *GValue, v_boolean: gboolean) void;
pub extern fn g_value_set_int(value: *GValue, v_int: c_int) void;
pub extern fn g_value_set_uint(value: *GValue, v_uint: c_uint) void;
pub extern fn g_value_get_uint(value: *const GValue) c_uint;
pub extern fn g_value_set_enum(value: *GValue, v_enum: c_int) void;
pub extern fn gtk_orientation_get_type() GType;
pub extern fn g_value_unset(value: *GValue) void;

pub extern fn g_free(memory: ?*anyopaque) void;
pub extern fn g_format_size(size: u64) [*:0]u8;
pub extern fn g_strndup(str: [*]const u8, n: usize) ?[*:0]u8;
pub extern fn g_markup_escape_text(text: [*]const u8, length: isize) [*:0]u8;
pub extern fn g_get_user_data_dir() [*:0]const u8;
pub extern fn g_mkdir_with_parents(pathname: [*:0]const u8, mode: c_int) c_int;
pub extern fn g_get_user_cache_dir() [*:0]const u8;
pub extern fn g_get_user_state_dir() [*:0]const u8;
pub extern fn g_log_set_debug_enabled(enabled: gboolean) void;
pub extern fn g_file_set_contents(
    filename: [*:0]const u8,
    contents: [*]const u8,
    length: isize,
    err: *?*GError,
) c_int;
pub extern fn g_unlink(filename: [*:0]const u8) c_int;
pub extern fn g_filename_to_uri(filename: [*:0]const u8, hostname: ?[*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_app_info_launch_default_for_uri(uri: [*:0]const u8, context: ?*anyopaque, err: ?*?*GError) c_int;
pub extern fn g_get_monotonic_time() i64;
pub extern fn g_get_user_special_dir(directory: c_int) ?[*:0]const u8;
pub extern fn g_get_home_dir() ?[*:0]const u8;
pub extern fn g_get_user_name() [*:0]const u8;

pub const GDateTime = opaque {};
pub extern fn g_date_time_new_now_local() ?*GDateTime;
pub extern fn g_date_time_new_from_unix_local(t: i64) ?*GDateTime;
pub extern fn g_date_time_new_local(year: c_int, month: c_int, day: c_int, hour: c_int, minute: c_int, seconds: f64) ?*GDateTime;
pub extern fn g_date_time_to_unix(datetime: *GDateTime) i64;
pub extern fn g_date_time_add_days(datetime: *GDateTime, days: c_int) ?*GDateTime;
pub extern fn g_date_time_format(datetime: *GDateTime, format: [*:0]const u8) ?[*:0]u8;
pub extern fn g_date_time_unref(datetime: *GDateTime) void;
pub extern fn g_date_time_difference(end: *GDateTime, begin: *GDateTime) i64;
pub extern fn g_utf8_casefold(text: [*]const u8, length: isize) ?[*:0]u8;
pub extern fn g_utf8_strup(text: [*]const u8, length: isize) ?[*:0]u8;

pub extern fn gtk_link_button_new_with_label(uri: [*:0]const u8, label: [*:0]const u8) *Widget;
pub extern fn gtk_link_button_set_uri(button: *LinkButton, uri: [*:0]const u8) void;
pub extern fn g_timeout_add(
    interval: c_uint,
    function: *const fn (?*anyopaque) callconv(.c) gboolean,
    data: ?*anyopaque,
) c_uint;
pub extern fn g_source_remove(tag: c_uint) gboolean;
pub const IO_IN: c_uint = 1;
pub extern fn g_unix_fd_add(
    fd: c_int,
    condition: c_uint,
    function: *const fn (c_int, c_uint, ?*anyopaque) callconv(.c) gboolean,
    data: ?*anyopaque,
) c_uint;
pub extern fn g_clear_error(err: *?*GError) void;

pub extern fn g_list_model_get_n_items(list: ?*ListModel) c_uint;
pub extern fn g_list_model_items_changed(list: *ListModel, position: c_uint, removed: c_uint, added: c_uint) void;
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
pub extern fn g_list_store_append(store: *ListStore, item: *anyopaque) void;

pub extern fn g_simple_action_new(name: [*:0]const u8, parameter_type: ?*const GVariantType) ?*GSimpleAction;
pub extern fn g_simple_action_new_stateful(name: [*:0]const u8, parameter_type: ?*const GVariantType, state: *GVariant) ?*GSimpleAction;
pub extern fn g_simple_action_set_enabled(action: *GSimpleAction, enabled: gboolean) void;
pub extern fn g_simple_action_set_state(action: *GSimpleAction, value: *GVariant) void;
pub extern fn g_action_map_add_action(action_map: *GActionMap, action: *GAction) void;
pub extern fn g_action_map_lookup_action(action_map: *GActionMap, action_name: [*:0]const u8) ?*GAction;
pub extern fn g_simple_action_group_new() *GSimpleActionGroup;
pub extern fn gtk_widget_insert_action_group(widget: *Widget, name: [*:0]const u8, group: ?*GActionGroup) void;
pub extern fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*]const ?[*:0]const u8) c_int;
pub extern fn g_application_quit(application: *GApplication) void;
pub extern fn g_application_activate(application: *GApplication) void;
pub extern fn g_application_send_notification(application: *GApplication, id: ?[*:0]const u8, notification: *GNotification) void;
pub extern fn g_notification_new(title: [*:0]const u8) *GNotification;
pub extern fn g_notification_set_body(notification: *GNotification, body: ?[*:0]const u8) void;

pub extern fn g_file_get_path(file: *GFile) ?[*:0]u8;
pub extern fn g_file_new_for_path(path: [*:0]const u8) *GFile;
pub extern fn g_file_query_exists(file: *GFile, cancellable: ?*GCancellable) gboolean;
pub extern fn g_menu_new() *GMenu;
pub extern fn g_menu_model_get_n_items(model: *GMenuModel) c_int;
pub extern fn g_menu_append(menu: *GMenu, label: ?[*:0]const u8, detailed_action: ?[*:0]const u8) void;
pub extern fn g_menu_append_section(menu: *GMenu, label: ?[*:0]const u8, section: *GMenuModel) void;
pub extern fn g_menu_append_submenu(menu: *GMenu, label: ?[*:0]const u8, submenu: *GMenuModel) void;

// A cover arrives from liborca as caller-owned encoded bytes, and has to
// become something a widget can draw without ever touching the filesystem.
// The stream and the *scaled* decode are what keep a pathological image from
// turning a 12 MiB JPEG into hundreds of megabytes of pixels.

/// Borrows `data` rather than copying it. The borrow is sound only because
/// the decode is synchronous and the GBytes is dropped before the borrowed
/// buffer is.
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
pub extern fn gdk_texture_get_width(texture: *GdkTexture) c_int;
pub extern fn gdk_texture_get_height(texture: *GdkTexture) c_int;
pub const GdkFrameClock = opaque {};
pub extern fn gtk_widget_get_frame_clock(widget: *Widget) ?*GdkFrameClock;
pub extern fn gdk_texture_download(texture: *GdkTexture, data: [*]u8, stride: usize) void;
pub const MEMORY_B8G8R8A8_PREMULTIPLIED: c_int = 0;
pub extern fn gdk_memory_texture_new(width: c_int, height: c_int, format: c_int, bytes: *GBytes, stride: usize) *GdkTexture;
pub extern fn g_bytes_new(data: ?*const anyopaque, size: usize) *GBytes;
pub extern fn gdk_pixbuf_new_subpixbuf(src: *GdkPixbuf, x: c_int, y: c_int, width: c_int, height: c_int) *GdkPixbuf;
pub const INTERP_BILINEAR: c_int = 2;
pub extern fn gdk_pixbuf_scale_simple(src: *GdkPixbuf, width: c_int, height: c_int, interp: c_int) ?*GdkPixbuf;
pub extern fn gdk_pixbuf_get_pixels(pixbuf: *GdkPixbuf) [*]u8;
pub extern fn gdk_pixbuf_get_width(pixbuf: *GdkPixbuf) c_int;
pub extern fn gdk_pixbuf_get_height(pixbuf: *GdkPixbuf) c_int;
pub extern fn gdk_pixbuf_get_rowstride(pixbuf: *GdkPixbuf) c_int;
pub extern fn gdk_pixbuf_get_n_channels(pixbuf: *GdkPixbuf) c_int;

pub const TaskThreadFunc = *const fn (*GTask, ?*anyopaque, ?*anyopaque, ?*GCancellable) callconv(.c) void;
pub extern fn g_task_new(
    source_object: ?*anyopaque,
    cancellable: ?*GCancellable,
    callback: ?*const fn (?*GObject, *GAsyncResult, ?*anyopaque) callconv(.c) void,
    callback_data: ?*anyopaque,
) *GTask;
pub extern fn g_task_set_task_data(task: *GTask, task_data: ?*anyopaque, destroy: ?*anyopaque) void;
pub extern fn g_task_get_task_data(task: *GTask) ?*anyopaque;
pub extern fn g_task_run_in_thread(task: *GTask, task_func: TaskThreadFunc) void;
pub extern fn g_task_return_pointer(task: *GTask, result: ?*anyopaque, destroy: ?*anyopaque) void;
pub extern fn g_task_propagate_pointer(task: *GTask, err: *?*GError) ?*anyopaque;

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
pub extern fn gtk_widget_set_halign(widget: *Widget, alignment: c_int) void;
pub extern fn gtk_widget_set_name(widget: *Widget, name: [*:0]const u8) void;
pub extern fn gtk_widget_get_name(widget: *Widget) [*:0]const u8;
pub extern fn gtk_list_box_row_new() *Widget;
pub extern fn gtk_list_box_row_set_child(row: *ListBoxRow, child: ?*Widget) void;
pub extern fn gtk_list_box_row_set_activatable(row: *ListBoxRow, activatable: gboolean) void;
pub extern fn gtk_button_new() *Widget;
pub extern fn gtk_button_set_child(button: *Button, child: ?*Widget) void;
pub extern fn gtk_button_get_child(button: *Button) ?*Widget;
pub extern fn gtk_widget_set_overflow(widget: *Widget, overflow: c_int) void;
pub extern fn gtk_widget_grab_focus(widget: *Widget) gboolean;
pub const DIR_TAB_FORWARD: c_int = 0;
pub extern fn gtk_widget_child_focus(widget: *Widget, direction: c_int) gboolean;
pub extern fn gtk_widget_get_root(widget: *Widget) ?*Widget;
pub extern fn gtk_widget_get_scale_factor(widget: *Widget) c_int;
pub extern fn gtk_widget_is_ancestor(widget: *Widget, ancestor: *Widget) gboolean;
pub extern fn gtk_window_get_focus(window: *Window) ?*Widget;
pub extern fn gtk_widget_get_ancestor(widget: *Widget, widget_type: GType) ?*Widget;
pub extern fn gtk_editable_get_type() GType;
pub extern fn gtk_popover_get_type() GType;
pub extern fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: GType) gboolean;
pub extern fn gtk_css_provider_new() *CssProvider;
pub extern fn gtk_css_provider_load_from_string(provider: *CssProvider, string: [*:0]const u8) void;
pub extern fn gdk_display_get_default() ?*GdkDisplay;
pub extern fn gtk_style_context_add_provider_for_display(
    display: *GdkDisplay,
    provider: *CssProvider,
    priority: c_uint,
) void;
pub extern fn gtk_icon_theme_get_for_display(display: *GdkDisplay) *IconTheme;
pub extern fn gtk_icon_theme_add_search_path(theme: *IconTheme, path: [*:0]const u8) void;
pub extern fn pango_cairo_font_map_get_default() *PangoFontMap;
pub const PangoAttrList = opaque {};
pub const PangoAttribute = opaque {};
pub extern fn pango_attr_list_new() *PangoAttrList;
pub extern fn pango_attr_list_unref(list: *PangoAttrList) void;
pub extern fn pango_attr_list_insert(list: *PangoAttrList, attribute: *PangoAttribute) void;
pub extern fn pango_attr_letter_spacing_new(letter_spacing: c_int) *PangoAttribute;
pub extern fn gtk_label_set_attributes(label: *Label, attributes: ?*PangoAttrList) void;
pub extern fn pango_font_map_add_font_file(fontmap: *PangoFontMap, filename: [*:0]const u8, err: *?*GError) gboolean;
pub const PANGO_SCALE: c_int = 1024;
pub const PangoLayout = opaque {};
pub extern fn gtk_widget_create_pango_layout(widget: *Widget, text: ?[*:0]const u8) *PangoLayout;
pub extern fn pango_layout_set_width(layout: *PangoLayout, width: c_int) void;
pub extern fn pango_layout_get_line_count(layout: *PangoLayout) c_int;
pub const PANGO_WRAP_WORD: c_int = 0;
pub extern fn pango_layout_set_height(layout: *PangoLayout, height: c_int) void;
pub extern fn pango_layout_set_wrap(layout: *PangoLayout, wrap: c_int) void;
pub extern fn pango_layout_set_ellipsize(layout: *PangoLayout, ellipsize: c_int) void;
pub extern fn pango_layout_set_text(layout: *PangoLayout, text: [*]const u8, length: c_int) void;
pub extern fn pango_layout_is_ellipsized(layout: *PangoLayout) gboolean;
pub extern fn gtk_widget_add_tick_callback(
    widget: *Widget,
    callback: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) gboolean,
    data: ?*anyopaque,
    notify: ?*const fn (?*anyopaque) callconv(.c) void,
) c_uint;
pub extern fn gtk_center_box_new() *Widget;
pub extern fn gtk_center_box_set_start_widget(box: *CenterBox, child: ?*Widget) void;
pub extern fn gtk_center_box_set_center_widget(box: *CenterBox, child: ?*Widget) void;
pub extern fn gtk_center_box_set_end_widget(box: *CenterBox, child: ?*Widget) void;
pub extern fn gtk_picture_new() *Widget;
pub extern fn gtk_aspect_frame_new(xalign: f32, yalign: f32, ratio: f32, obey_child: gboolean) *Widget;
pub extern fn gtk_aspect_frame_set_child(frame: *AspectFrame, child: ?*Widget) void;
pub extern fn gtk_picture_set_paintable(picture: *Picture, paintable: ?*GdkPaintable) void;
pub extern fn gtk_image_get_paintable(image: *Image) ?*GdkPaintable;
pub extern fn gtk_picture_set_content_fit(picture: *Picture, content_fit: c_int) void;
pub extern fn gtk_picture_set_can_shrink(picture: *Picture, can_shrink: gboolean) void;
pub extern fn gtk_stack_new() *Widget;
pub extern fn gtk_stack_add_named(stack: *Stack, child: *Widget, name: [*:0]const u8) ?*anyopaque;
pub extern fn gtk_stack_set_hhomogeneous(stack: *Stack, hhomogeneous: gboolean) void;
pub extern fn gtk_stack_set_vhomogeneous(stack: *Stack, vhomogeneous: gboolean) void;
pub extern fn gtk_stack_set_visible_child_name(stack: *Stack, name: [*:0]const u8) void;
pub extern fn gtk_stack_set_transition_type(stack: *Stack, transition: c_int) void;
pub extern fn gtk_stack_get_child_by_name(stack: *Stack, name: [*:0]const u8) ?*Widget;
pub extern fn gtk_stack_get_visible_child_name(stack: *Stack) ?[*:0]const u8;
pub extern fn gtk_grid_view_new(model: ?*SelectionModel, factory: ?*ListItemFactory) *Widget;
pub extern fn gtk_grid_view_set_max_columns(view: *GridView, columns: c_uint) void;
pub extern fn gtk_grid_view_set_min_columns(view: *GridView, columns: c_uint) void;
pub extern fn gtk_grid_view_set_tab_behavior(view: *GridView, behavior: c_int) void;
pub extern fn gtk_grid_view_set_single_click_activate(view: *GridView, single: gboolean) void;
pub extern fn gtk_overlay_new() *Widget;
pub extern fn gtk_overlay_set_child(overlay: *Overlay, child: ?*Widget) void;
pub extern fn gtk_overlay_add_overlay(overlay: *Overlay, widget: *Widget) void;
pub extern fn gtk_overlay_set_measure_overlay(overlay: *Overlay, widget: *Widget, measure: gboolean) void;
pub extern fn gtk_orientable_set_orientation(orientable: *Orientable, orientation: c_int) void;

pub extern fn gtk_list_box_new() *Widget;
pub extern fn gtk_list_box_append(box: *ListBox, child: *Widget) void;
pub extern fn gtk_list_box_remove_all(box: *ListBox) void;
pub extern fn gtk_list_box_set_selection_mode(box: *ListBox, mode: c_int) void;
pub extern fn gtk_list_box_row_get_index(row: *ListBoxRow) c_int;
pub extern fn gtk_list_box_set_activate_on_single_click(box: *ListBox, single: gboolean) void;
pub extern fn gtk_list_box_unselect_all(box: *ListBox) void;
pub extern fn gtk_list_box_select_row(box: *ListBox, row: ?*ListBoxRow) void;
pub extern fn gtk_list_box_get_row_at_index(box: *ListBox, index: c_int) ?*ListBoxRow;
pub extern fn gtk_list_box_set_tab_behavior(box: *ListBox, behavior: c_int) void;
pub extern fn gtk_revealer_new() *Widget;
pub extern fn gtk_revealer_set_child(revealer: *Revealer, child: ?*Widget) void;
pub extern fn gtk_revealer_set_reveal_child(revealer: *Revealer, reveal: gboolean) void;
pub extern fn gtk_revealer_get_reveal_child(revealer: *Revealer) gboolean;
pub extern fn gtk_revealer_set_transition_type(revealer: *Revealer, transition: c_int) void;
pub extern fn gtk_actionable_set_action_name(actionable: *Actionable, action_name: ?[*:0]const u8) void;
pub extern fn gtk_popover_popdown(popover: *Popover) void;
pub extern fn gtk_popover_set_default_widget(popover: *Popover, widget: ?*Widget) void;
pub extern fn gtk_menu_button_set_menu_model(button: *MenuButton, menu_model: ?*GMenuModel) void;
pub extern fn gtk_menu_button_set_primary(button: *MenuButton, primary: gboolean) void;
pub extern fn gtk_toggle_button_set_active(button: *ToggleButton, active: gboolean) void;
pub extern fn gtk_label_set_wrap(label: *Label, wrap: gboolean) void;
pub extern fn gtk_label_set_wrap_mode(label: *Label, wrap_mode: c_int) void;
pub extern fn gtk_label_set_lines(label: *Label, lines: c_int) void;
pub extern fn gtk_label_set_markup(label: *Label, markup: [*:0]const u8) void;
pub extern fn gtk_label_set_justify(label: *Label, justify: c_int) void;
pub extern fn gtk_label_set_selectable(label: *Label, selectable: gboolean) void;
pub extern fn gtk_widget_set_cursor_from_name(widget: *Widget, name: ?[*:0]const u8) void;
pub extern fn gtk_gesture_click_new() *EventController;
pub extern fn gtk_gesture_single_set_button(gesture: *GestureSingle, button: c_uint) void;
pub extern fn gtk_gesture_set_state(gesture: *Gesture, state: c_int) gboolean;
pub extern fn gtk_event_controller_get_widget(controller: *EventController) *Widget;
pub extern fn gtk_event_controller_get_current_event(controller: *EventController) ?*anyopaque;
pub extern fn gdk_event_get_surface(event: *anyopaque) ?*anyopaque;
pub extern fn gtk_native_get_surface(native: *anyopaque) ?*anyopaque;
pub extern fn gtk_widget_pick(widget: *Widget, x: f64, y: f64, flags: c_int) ?*Widget;
pub extern fn gtk_popover_menu_new_from_model(model: ?*GMenuModel) *Widget;
pub extern fn gtk_popover_set_pointing_to(popover: *Popover, rect: *const Rectangle) void;
pub extern fn gtk_popover_set_has_arrow(popover: *Popover, has_arrow: gboolean) void;
pub extern fn gtk_popover_popup(popover: *Popover) void;
pub extern fn gtk_popover_present(popover: *Popover) void;
pub extern fn gtk_popover_set_autohide(popover: *Popover, autohide: gboolean) void;
pub extern fn gtk_popover_set_position(popover: *Popover, position: c_int) void;
pub extern fn gtk_popover_set_offset(popover: *Popover, x_offset: c_int, y_offset: c_int) void;
pub extern fn gtk_widget_has_focus(widget: *Widget) gboolean;
pub extern fn gtk_widget_queue_resize(widget: *Widget) void;
pub extern fn gtk_widget_set_parent(widget: *Widget, parent: *Widget) void;
pub extern fn gtk_widget_unparent(widget: *Widget) void;
pub extern fn gtk_widget_get_parent(widget: *Widget) ?*Widget;
pub extern fn gtk_widget_get_css_name(widget: *Widget) [*:0]const u8;
pub extern fn gtk_list_view_set_single_click_activate(view: *ListView, single: gboolean) void;
pub extern fn gtk_selection_model_is_selected(model: *SelectionModel, position: c_uint) gboolean;
pub extern fn gtk_selection_model_select_item(model: *SelectionModel, position: c_uint, unselect_rest: gboolean) gboolean;
pub extern fn gtk_flow_box_new() *Widget;
pub extern fn gtk_flow_box_append(box: *FlowBox, child: *Widget) void;
pub extern fn gtk_flow_box_remove_all(box: *FlowBox) void;
pub extern fn gtk_flow_box_set_selection_mode(box: *FlowBox, mode: c_int) void;
pub extern fn gtk_flow_box_set_homogeneous(box: *FlowBox, homogeneous: gboolean) void;
pub extern fn gtk_flow_box_set_max_children_per_line(box: *FlowBox, count: c_uint) void;
pub extern fn gtk_flow_box_set_min_children_per_line(box: *FlowBox, count: c_uint) void;
pub extern fn gtk_flow_box_set_activate_on_single_click(box: *FlowBox, single: gboolean) void;
pub extern fn gtk_flow_box_set_column_spacing(box: *FlowBox, spacing: c_uint) void;
pub extern fn gtk_flow_box_set_row_spacing(box: *FlowBox, spacing: c_uint) void;
pub extern fn gtk_flow_box_child_get_index(child: *FlowBoxChild) c_int;
pub extern fn gtk_flow_box_child_get_child(child: *FlowBoxChild) ?*Widget;
pub extern fn g_object_set_data(object: *anyopaque, key: [*:0]const u8, data: ?*anyopaque) void;
pub extern fn g_object_get_data(object: *anyopaque, key: [*:0]const u8) ?*anyopaque;
pub extern fn g_object_set_data_full(
    object: *anyopaque,
    key: [*:0]const u8,
    data: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) void;
pub extern fn g_idle_add(function: *const fn (?*anyopaque) callconv(.c) gboolean, data: ?*anyopaque) c_uint;
pub extern fn gtk_style_context_remove_provider_for_display(display: *GdkDisplay, provider: *CssProvider) void;
pub extern fn gtk_widget_set_visible(widget: *Widget, visible: gboolean) void;
pub const ACCESSIBLE_PROPERTY_LABEL: c_int = 4;
pub extern fn gtk_accessible_update_property(accessible: *Accessible, first_property: c_int, ...) void;
pub const ACCESSIBLE_STATE_EXPANDED: c_int = 3;
pub extern fn gtk_accessible_update_state(accessible: *Accessible, first_state: c_int, ...) void;
pub extern fn gtk_widget_get_clipboard(widget: *Widget) *GdkClipboard;
pub extern fn gdk_clipboard_set_text(clipboard: *GdkClipboard, text: [*:0]const u8) void;
pub extern fn gtk_widget_get_visible(widget: *Widget) gboolean;
pub extern fn gtk_widget_get_mapped(widget: *Widget) gboolean;

/// `graphene_rect_t`: an origin point and a size, four floats.
pub const Rect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};
pub extern fn gtk_widget_compute_bounds(widget: *Widget, target: *Widget, out_bounds: *Rect) gboolean;
pub extern fn gtk_widget_set_focus_on_click(widget: *Widget, focus_on_click: gboolean) void;
pub extern fn gtk_widget_set_can_focus(widget: *Widget, can_focus: gboolean) void;
pub extern fn gtk_widget_set_focusable(widget: *Widget, focusable: gboolean) void;
pub extern fn gtk_widget_set_sensitive(widget: *Widget, sensitive: gboolean) void;
pub extern fn gtk_widget_set_opacity(widget: *Widget, opacity: f64) void;
pub extern fn gtk_widget_set_margin_start(widget: *Widget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_end(widget: *Widget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_top(widget: *Widget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(widget: *Widget, margin: c_int) void;
pub extern fn gtk_widget_add_css_class(widget: *Widget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_remove_css_class(widget: *Widget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_has_css_class(widget: *Widget, css_class: [*:0]const u8) gboolean;
pub extern fn gtk_widget_activate_action_variant(widget: *Widget, name: [*:0]const u8, args: ?*GVariant) gboolean;
pub extern fn gtk_widget_add_controller(widget: *Widget, controller: *EventController) void;
pub extern fn gtk_widget_get_first_child(widget: *Widget) ?*Widget;
pub extern fn gtk_widget_set_can_target(widget: *Widget, can_target: gboolean) void;
pub extern fn gtk_widget_get_width(widget: *Widget) c_int;
pub extern fn gtk_widget_get_height(widget: *Widget) c_int;
pub extern fn gtk_widget_get_next_sibling(widget: *Widget) ?*Widget;

pub extern fn gtk_header_bar_new() *Widget;
pub extern fn gtk_header_bar_pack_start(bar: *HeaderBar, child: *Widget) void;
pub extern fn gtk_header_bar_pack_end(bar: *HeaderBar, child: *Widget) void;
pub extern fn gtk_header_bar_set_title_widget(bar: *HeaderBar, title_widget: ?*Widget) void;

pub extern fn gtk_button_new_with_label(label: [*:0]const u8) *Widget;
pub extern fn gtk_button_set_label(button: *Button, label: [*:0]const u8) void;
pub extern fn gtk_button_new_from_icon_name(icon_name: ?[*:0]const u8) *Widget;
pub extern fn gtk_button_get_icon_name(button: *Button) ?[*:0]const u8;
pub extern fn gtk_button_set_icon_name(button: *Button, icon_name: [*:0]const u8) void;
pub extern fn gtk_toggle_button_new() *Widget;
pub extern fn gtk_toggle_button_get_active(button: *ToggleButton) gboolean;
pub extern fn gtk_toggle_button_set_group(button: *ToggleButton, group: ?*ToggleButton) void;
pub extern fn gtk_check_button_new_with_label(label: ?[*:0]const u8) *Widget;
pub extern fn gtk_check_button_get_active(button: *CheckButton) gboolean;
pub extern fn gtk_check_button_set_active(button: *CheckButton, active: gboolean) void;
pub extern fn gtk_check_button_set_group(button: *CheckButton, group: ?*CheckButton) void;
pub extern fn gtk_menu_button_new() *Widget;
pub extern fn gtk_menu_button_set_icon_name(button: *MenuButton, icon_name: [*:0]const u8) void;
pub extern fn gtk_menu_button_set_label(button: *MenuButton, label: [*:0]const u8) void;
pub extern fn gtk_menu_button_set_popover(button: *MenuButton, popover: ?*Widget) void;
pub extern fn gtk_menu_button_set_child(button: *MenuButton, child: ?*Widget) void;
pub extern fn gtk_menu_button_set_always_show_arrow(button: *MenuButton, always_show_arrow: gboolean) void;

pub extern fn gtk_search_entry_new() *Widget;
pub extern fn gtk_search_entry_set_placeholder_text(
    entry: *SearchEntry,
    text: ?[*:0]const u8,
) void;
pub extern fn gtk_search_entry_set_search_delay(entry: *SearchEntry, delay: c_uint) void;
pub extern fn gtk_editable_get_text(editable: *Editable) [*:0]const u8;
pub extern fn gtk_editable_set_text(editable: *Editable, text: [*:0]const u8) void;
pub extern fn gtk_editable_set_position(editable: *Editable, position: c_int) void;
pub extern fn gtk_editable_set_width_chars(editable: *Editable, n_chars: c_int) void;
pub extern fn gtk_editable_set_alignment(editable: *Editable, xalign: f32) void;

pub extern fn gtk_image_new() *Widget;
pub extern fn gtk_image_new_from_icon_name(icon_name: ?[*:0]const u8) *Widget;
pub extern fn gtk_image_set_from_icon_name(image: *Image, icon_name: ?[*:0]const u8) void;
pub extern fn gtk_image_set_from_paintable(image: *Image, paintable: ?*GdkPaintable) void;
pub extern fn gtk_image_set_pixel_size(image: *Image, pixel_size: c_int) void;

pub extern fn gtk_label_new(text: ?[*:0]const u8) *Widget;
pub extern fn gtk_label_set_text(label: *Label, text: [*:0]const u8) void;
pub extern fn gtk_label_get_text(label: *Label) [*:0]const u8;
pub extern fn gtk_label_set_xalign(label: *Label, xalign: f32) void;
pub extern fn gtk_label_set_ellipsize(label: *Label, mode: c_int) void;
pub extern fn gtk_label_set_max_width_chars(label: *Label, n_chars: c_int) void;

pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) *Widget;
pub extern fn gtk_box_append(box: *Box, child: *Widget) void;
pub extern fn gtk_box_prepend(box: *Box, child: *Widget) void;
pub extern fn gtk_box_remove(box: *Box, child: *Widget) void;
pub extern fn gtk_box_insert_child_after(box: *Box, child: *Widget, sibling: ?*Widget) void;
pub extern fn gtk_box_set_homogeneous(box: *Box, homogeneous: gboolean) void;
pub extern fn gtk_box_set_spacing(box: *Box, spacing: c_int) void;
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
pub extern fn gtk_scrolled_window_set_policy(window: *ScrolledWindow, hscrollbar_policy: c_int, vscrollbar_policy: c_int) void;
pub extern fn gtk_scrolled_window_set_propagate_natural_height(window: *ScrolledWindow, propagate: gboolean) void;
pub extern fn gtk_scrolled_window_set_max_content_height(window: *ScrolledWindow, height: c_int) void;
pub extern fn gtk_scrolled_window_set_min_content_height(window: *ScrolledWindow, height: c_int) void;
pub extern fn gtk_scrolled_window_get_vadjustment(window: *ScrolledWindow) *Adjustment;
pub extern fn gtk_scrolled_window_get_hadjustment(window: *ScrolledWindow) *Adjustment;

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
pub extern fn gtk_scale_set_digits(scale: *Scale, digits: c_int) void;
pub extern fn gtk_scale_add_mark(scale: *Scale, value: f64, position: c_int, markup: ?[*:0]const u8) void;
pub extern fn gtk_range_set_inverted(range: *Range, setting: gboolean) void;
pub extern fn gtk_range_set_value(range: *Range, value: f64) void;
pub extern fn gtk_range_get_value(range: *Range) f64;

pub extern fn gtk_progress_bar_new() *Widget;
pub extern fn gtk_progress_bar_set_fraction(bar: *ProgressBar, fraction: f64) void;
pub extern fn gtk_progress_bar_pulse(bar: *ProgressBar) void;
pub extern fn gtk_progress_bar_set_pulse_step(bar: *ProgressBar, fraction: f64) void;

pub extern fn gtk_window_handle_new() *Widget;
pub extern fn gtk_window_handle_set_child(handle: *WindowHandle, child: ?*Widget) void;

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
pub extern fn gtk_drop_down_new_from_strings(strings: [*]const ?[*:0]const u8) *Widget;
pub extern fn gtk_drop_down_get_selected(drop_down: *DropDown) c_uint;
pub extern fn gtk_drop_down_set_selected(drop_down: *DropDown, position: c_uint) void;

pub extern fn gtk_multi_selection_new(model: ?*ListModel) *SelectionModel;
pub extern fn gtk_single_selection_new(model: ?*ListModel) *SingleSelection;
pub extern fn gtk_single_selection_get_selected(selection: *SingleSelection) c_uint;
pub extern fn gtk_single_selection_set_selected(selection: *SingleSelection, position: c_uint) void;
pub extern fn gtk_single_selection_set_autoselect(selection: *SingleSelection, autoselect: gboolean) void;
pub extern fn gtk_single_selection_set_can_unselect(selection: *SingleSelection, can_unselect: gboolean) void;
pub extern fn gtk_no_selection_new(model: ?*ListModel) *SelectionModel;
pub extern fn gtk_selection_model_get_selection(model: *SelectionModel) *Bitset;
pub extern fn gtk_selection_model_set_selection(model: *SelectionModel, selected: *Bitset, mask: *Bitset) gboolean;
pub extern fn gtk_bitset_copy(bitset: *Bitset) *Bitset;
pub extern fn gtk_bitset_new_range(start: c_uint, n_items: c_uint) *Bitset;

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
pub extern fn gtk_column_view_set_tab_behavior(view: *ColumnView, behavior: c_int) void;
pub extern fn gtk_column_view_append_column(view: *ColumnView, column: *ColumnViewColumn) void;
pub extern fn gtk_column_view_get_sorter(view: *ColumnView) ?*Sorter;
pub extern fn gtk_column_view_set_show_column_separators(view: *ColumnView, show: gboolean) void;
pub extern fn gtk_column_view_set_reorderable(view: *ColumnView, reorderable: gboolean) void;
pub extern fn gtk_column_view_get_columns(view: *ColumnView) *ListModel;
pub extern fn gtk_column_view_column_new(
    title: ?[*:0]const u8,
    factory: ?*ListItemFactory,
) *ColumnViewColumn;
pub extern fn gtk_column_view_insert_column(view: *ColumnView, position: c_uint, column: *ColumnViewColumn) void;
pub extern fn gtk_column_view_column_set_resizable(column: *ColumnViewColumn, resizable: gboolean) void;
pub extern fn gtk_column_view_column_set_expand(column: *ColumnViewColumn, expand: gboolean) void;
pub extern fn gtk_column_view_column_set_fixed_width(column: *ColumnViewColumn, width: c_int) void;
pub extern fn gtk_column_view_column_set_sorter(column: *ColumnViewColumn, sorter: ?*Sorter) void;
pub extern fn gtk_column_view_column_set_visible(column: *ColumnViewColumn, visible: gboolean) void;
pub extern fn gtk_column_view_column_get_fixed_width(column: *ColumnViewColumn) c_int;
pub extern fn gtk_column_view_column_set_header_menu(column: *ColumnViewColumn, menu: ?*GMenuModel) void;
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
pub extern fn gtk_list_item_get_position(item: *ListItem) c_uint;
pub extern fn gtk_list_item_set_activatable(item: *ListItem, activatable: gboolean) void;
pub extern fn gtk_list_item_set_selectable(item: *ListItem, selectable: gboolean) void;
pub extern fn gtk_widget_remove_tick_callback(widget: *Widget, id: c_uint) void;
pub extern fn gtk_list_view_new(model: ?*SelectionModel, factory: ?*ListItemFactory) *Widget;
pub extern fn gtk_list_view_set_tab_behavior(view: *ListView, behavior: c_int) void;
pub extern fn gtk_list_view_scroll_to(view: *ListView, position: c_uint, flags: c_int, scroll: ?*anyopaque) void;

pub const TreeListModel = opaque {};
pub const TreeListRow = opaque {};
pub const TreeExpander = opaque {};
pub extern fn gtk_tree_list_model_new(
    root: *ListModel,
    passthrough: gboolean,
    autoexpand: gboolean,
    create_func: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*ListModel,
    user_data: ?*anyopaque,
    user_destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) *TreeListModel;
pub extern fn gtk_tree_list_model_get_row(model: *TreeListModel, position: c_uint) ?*TreeListRow;
pub extern fn gtk_tree_list_row_get_item(row: *TreeListRow) ?*anyopaque;
pub extern fn gtk_tree_list_row_get_depth(row: *TreeListRow) c_uint;
pub extern fn gtk_tree_list_row_set_expanded(row: *TreeListRow, expanded: gboolean) void;
pub extern fn gtk_tree_expander_new() *Widget;
pub extern fn gtk_tree_expander_set_child(expander: *TreeExpander, child: ?*Widget) void;
pub extern fn gtk_tree_expander_set_list_row(expander: *TreeExpander, row: ?*TreeListRow) void;
pub extern fn gtk_list_box_set_header_func(
    box: *ListBox,
    update_header: ?*const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) void;
pub extern fn gtk_list_box_row_set_header(row: *ListBoxRow, header: ?*Widget) void;
pub extern fn gtk_list_box_row_get_header(row: *ListBoxRow) ?*Widget;

/// A NULL `sort_func` makes every element compare equal, which is what a column
/// needs to be clickable without a sort model behind it.
pub extern fn gtk_custom_sorter_new(
    sort_func: ?*const anyopaque,
    user_data: ?*anyopaque,
    user_destroy: ?*anyopaque,
) *Sorter;

pub extern fn gtk_event_controller_key_new() *EventController;
pub extern fn gtk_event_controller_focus_new() *EventController;
pub extern fn gtk_drag_source_new() *EventController;
pub extern fn gtk_drag_source_set_actions(source: *EventController, actions: c_int) void;
pub extern fn gtk_drag_source_set_icon(source: *EventController, paintable: ?*GdkPaintable, hot_x: c_int, hot_y: c_int) void;
pub extern fn gtk_drop_target_new(g_type: GType, actions: c_int) *EventController;
pub extern fn gdk_content_provider_new_for_value(value: *const GValue) *GObject;
pub extern fn gtk_widget_paintable_new(widget: ?*Widget) *GdkPaintable;
pub extern fn gtk_event_controller_scroll_new(flags: c_int) *EventController;
pub extern fn gtk_event_controller_scroll_get_unit(controller: *EventController) c_int;
pub extern fn gtk_event_controller_set_propagation_phase(
    controller: *EventController,
    phase: c_int,
) void;

pub const AsyncReadyCallback = *const fn (?*GObject, *GAsyncResult, ?*anyopaque) callconv(.c) void;

pub extern fn gtk_uri_launcher_new(uri: ?[*:0]const u8) *UriLauncher;
pub extern fn gtk_uri_launcher_launch(
    launcher: *UriLauncher,
    parent: ?*Window,
    cancellable: ?*GCancellable,
    callback: ?AsyncReadyCallback,
    data: ?*anyopaque,
) void;
pub extern fn gtk_uri_launcher_launch_finish(launcher: *UriLauncher, result: *GAsyncResult, err: *?*GError) gboolean;

pub extern fn gtk_file_launcher_new(file: ?*GFile) *FileLauncher;
pub extern fn gtk_file_launcher_open_containing_folder(
    launcher: *FileLauncher,
    parent: ?*Window,
    cancellable: ?*GCancellable,
    callback: ?AsyncReadyCallback,
    data: ?*anyopaque,
) void;
pub extern fn gtk_file_launcher_open_containing_folder_finish(launcher: *FileLauncher, result: *GAsyncResult, err: *?*GError) gboolean;
pub extern fn gtk_file_launcher_launch(
    launcher: *FileLauncher,
    parent: ?*Window,
    cancellable: ?*GCancellable,
    callback: ?AsyncReadyCallback,
    data: ?*anyopaque,
) void;
pub extern fn gtk_file_launcher_launch_finish(launcher: *FileLauncher, result: *GAsyncResult, err: *?*GError) gboolean;

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

pub extern fn gtk_file_dialog_set_initial_name(dialog: *FileDialog, name: ?[*:0]const u8) void;
pub extern fn gtk_file_dialog_set_filters(dialog: *FileDialog, filters: ?*ListModel) void;
pub extern fn gtk_file_dialog_set_default_filter(dialog: *FileDialog, filter: ?*FileFilter) void;
pub extern fn gtk_file_dialog_open(
    dialog: *FileDialog,
    parent: ?*Window,
    cancellable: ?*GCancellable,
    ready: ?AsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_file_dialog_open_finish(dialog: *FileDialog, result: *GAsyncResult, err: *?*GError) ?*GFile;
pub extern fn gtk_file_dialog_save(
    dialog: *FileDialog,
    parent: ?*Window,
    cancellable: ?*GCancellable,
    ready: ?AsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_file_dialog_save_finish(dialog: *FileDialog, result: *GAsyncResult, err: *?*GError) ?*GFile;

pub extern fn gtk_file_filter_get_type() GType;
pub extern fn gtk_file_filter_new() *FileFilter;
pub extern fn gtk_file_filter_set_name(filter: *FileFilter, name: ?[*:0]const u8) void;
pub extern fn gtk_file_filter_add_suffix(filter: *FileFilter, suffix: [*:0]const u8) void;

pub extern fn gtk_entry_new() *Widget;
pub extern fn gtk_entry_set_activates_default(entry: *Entry, setting: gboolean) void;
pub extern fn gtk_entry_set_placeholder_text(entry: *Entry, text: ?[*:0]const u8) void;
pub extern fn gtk_entry_set_visibility(entry: *Entry, visible: gboolean) void;

pub extern fn gtk_switch_new() *Widget;
pub extern fn gtk_switch_get_active(self: *Switch) gboolean;
pub extern fn gtk_switch_set_active(self: *Switch, is_active: gboolean) void;

pub extern fn gtk_grid_new() *Widget;
pub extern fn gtk_grid_attach(grid: *Grid, child: *Widget, column: c_int, row: c_int, width: c_int, height: c_int) void;
pub extern fn gtk_grid_set_column_homogeneous(grid: *Grid, homogeneous: gboolean) void;
pub extern fn gtk_grid_set_column_spacing(grid: *Grid, spacing: c_uint) void;
pub extern fn gtk_grid_set_row_spacing(grid: *Grid, spacing: c_uint) void;
pub extern fn gtk_widget_get_layout_manager(widget: *Widget) ?*LayoutManager;
pub extern fn gtk_layout_manager_get_layout_child(manager: *LayoutManager, child: *Widget) *LayoutChild;
pub const CustomMeasure = *const fn (widget: *Widget, orientation: c_int, for_size: c_int, minimum: *c_int, natural: *c_int, minimum_baseline: *c_int, natural_baseline: *c_int) callconv(.c) void;
pub const CustomAllocate = *const fn (widget: *Widget, width: c_int, height: c_int, baseline: c_int) callconv(.c) void;
pub extern fn gtk_custom_layout_new(request_mode: ?*const anyopaque, measure: CustomMeasure, allocate: CustomAllocate) *LayoutManager;
pub extern fn gtk_widget_set_layout_manager(widget: *Widget, layout_manager: ?*LayoutManager) void;
pub extern fn gtk_widget_measure(widget: *Widget, orientation: c_int, for_size: c_int, minimum: ?*c_int, natural: ?*c_int, minimum_baseline: ?*c_int, natural_baseline: ?*c_int) void;
pub extern fn gtk_widget_size_allocate(widget: *Widget, allocation: *const Rectangle, baseline: c_int) void;
pub extern fn gtk_grid_layout_child_set_row(child: *GridLayoutChild, row: c_int) void;
pub extern fn gtk_grid_layout_child_set_column(child: *GridLayoutChild, column: c_int) void;
pub extern fn gtk_grid_layout_child_set_column_span(child: *GridLayoutChild, span: c_int) void;

pub extern fn gtk_settings_get_default() ?*Settings;
pub extern fn gtk_settings_reset_property(settings: *Settings, name: [*:0]const u8) void;
pub extern fn g_object_set(object: *anyopaque, first_property_name: [*:0]const u8, ...) void;

pub const DrawingArea = opaque {};
pub const StyleContext = opaque {};
pub const SpinButton = opaque {};
pub const Cairo = opaque {};
pub const CairoPattern = opaque {};
pub const GdkRGBA = extern struct { red: f32, green: f32, blue: f32, alpha: f32 };
pub const DrawFunc = *const fn (?*DrawingArea, *Cairo, c_int, c_int, ?*anyopaque) callconv(.c) void;

pub extern fn gtk_drawing_area_new() *Widget;
pub extern fn gtk_drawing_area_set_content_height(area: *DrawingArea, height: c_int) void;
pub extern fn gtk_drawing_area_set_draw_func(
    area: *DrawingArea,
    draw_func: ?DrawFunc,
    user_data: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) void;
pub extern fn gtk_widget_queue_draw(widget: *Widget) void;
pub extern fn gtk_widget_get_color(widget: *Widget, color: *GdkRGBA) void;
pub extern fn gtk_widget_get_style_context(widget: *Widget) *StyleContext;
pub extern fn gtk_style_context_lookup_color(context: *StyleContext, name: [*:0]const u8, color: *GdkRGBA) c_int;
pub extern fn gtk_gesture_drag_new() *EventController;
pub extern fn gtk_gesture_drag_get_start_point(gesture: *Gesture, x: ?*f64, y: ?*f64) gboolean;
pub extern fn gtk_event_controller_motion_new() *EventController;

pub extern fn cairo_save(cr: *Cairo) void;
pub extern fn cairo_restore(cr: *Cairo) void;
pub extern fn cairo_set_source_rgba(cr: *Cairo, red: f64, green: f64, blue: f64, alpha: f64) void;
pub extern fn cairo_set_source(cr: *Cairo, source: *CairoPattern) void;
pub extern fn cairo_set_line_width(cr: *Cairo, width: f64) void;
pub extern fn cairo_set_dash(cr: *Cairo, dashes: ?[*]const f64, num_dashes: c_int, offset: f64) void;
pub extern fn cairo_new_path(cr: *Cairo) void;
pub extern fn cairo_move_to(cr: *Cairo, x: f64, y: f64) void;
pub extern fn cairo_line_to(cr: *Cairo, x: f64, y: f64) void;
pub extern fn cairo_close_path(cr: *Cairo) void;
pub extern fn cairo_arc(cr: *Cairo, xc: f64, yc: f64, radius: f64, angle1: f64, angle2: f64) void;
pub extern fn cairo_rectangle(cr: *Cairo, x: f64, y: f64, width: f64, height: f64) void;
pub extern fn cairo_clip(cr: *Cairo) void;
pub extern fn cairo_stroke(cr: *Cairo) void;
pub extern fn cairo_stroke_preserve(cr: *Cairo) void;
pub extern fn cairo_fill(cr: *Cairo) void;
pub extern fn cairo_pattern_create_linear(x0: f64, y0: f64, x1: f64, y1: f64) *CairoPattern;
pub extern fn cairo_pattern_add_color_stop_rgba(pattern: *CairoPattern, offset: f64, red: f64, green: f64, blue: f64, alpha: f64) void;
pub extern fn cairo_pattern_destroy(pattern: *CairoPattern) void;
pub extern fn pango_layout_get_pixel_size(layout: *PangoLayout, width: ?*c_int, height: ?*c_int) void;
pub extern fn pango_cairo_show_layout(cr: *Cairo, layout: *PangoLayout) void;

pub extern fn gtk_spin_button_new_with_range(min: f64, max: f64, step: f64) *Widget;
pub extern fn gtk_spin_button_set_digits(spin_button: *SpinButton, digits: c_uint) void;
pub extern fn gtk_spin_button_get_value(spin_button: *SpinButton) f64;
pub extern fn gtk_spin_button_set_value(spin_button: *SpinButton, value: f64) void;
pub extern fn gtk_spin_button_set_range(spin_button: *SpinButton, min: f64, max: f64) void;
pub extern fn gtk_spin_button_set_numeric(spin_button: *SpinButton, numeric: gboolean) void;
pub const INPUT_ERROR: c_int = -1;

pub extern fn g_key_file_set_string_list(
    key_file: *GKeyFile,
    group: [*:0]const u8,
    key: [*:0]const u8,
    list: [*]const [*:0]const u8,
    length: usize,
) void;
pub extern fn g_key_file_get_string_list(
    key_file: *GKeyFile,
    group: [*:0]const u8,
    key: [*:0]const u8,
    length: *usize,
    err: *?*GError,
) ?[*]?[*:0]u8;
pub extern fn g_strfreev(str_array: ?[*]?[*:0]u8) void;

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
    std.debug.assert(@sizeOf(GValue) == 24);
    std.debug.assert(@sizeOf(GInterfaceInfo) == 24);
    std.debug.assert(@offsetOf(ListModelInterface, "get_item") == 32);
}
pub extern fn gtk_editable_set_max_width_chars(editable: *Editable, n_chars: c_int) void;
pub extern fn gtk_widget_get_last_child(widget: *Widget) ?*Widget;
pub const GMenuItem = opaque {};
pub extern fn g_menu_item_new(label: ?[*:0]const u8, detailed_action: ?[*:0]const u8) *GMenuItem;
pub extern fn g_menu_item_set_attribute_value(item: *GMenuItem, attribute: [*:0]const u8, value: ?*GVariant) void;
pub extern fn g_menu_append_item(menu: *GMenu, item: *GMenuItem) void;
pub extern fn g_menu_insert_section(menu: *GMenu, position: c_int, label: ?[*:0]const u8, section: *GMenuModel) void;
pub extern fn gtk_window_set_focus(window: *Window, focus: ?*Widget) void;
