//! Hand-written libadwaita bindings, in the same mechanical style as
//! `gtk.zig`: only the symbols the frontend calls, the opaque types they take,
//! and the enum values it names.

const gtk = @import("gtk.zig");

pub const Application = opaque {};
pub const ApplicationWindow = opaque {};
pub const NavigationSplitView = opaque {};
pub const NavigationPage = opaque {};
pub const ToolbarView = opaque {};
pub const HeaderBar = opaque {};
pub const WindowTitle = opaque {};
pub const Toast = opaque {};
pub const ToastOverlay = opaque {};
pub const StatusPage = opaque {};
pub const Sidebar = opaque {};
pub const SidebarSection = opaque {};
pub const SidebarItem = opaque {};
pub const Breakpoint = opaque {};
pub const BreakpointCondition = opaque {};
pub const Dialog = opaque {};
pub const AboutDialog = opaque {};
pub const ShortcutsDialog = opaque {};
pub const ShortcutsSection = opaque {};
pub const ShortcutsItem = opaque {};

pub const TOOLBAR_FLAT: c_int = 0;
pub const TOOLBAR_RAISED: c_int = 1;
pub const TOOLBAR_RAISED_BORDER: c_int = 2;

pub const SIDEBAR_MODE_SIDEBAR: c_int = 0;
pub const SIDEBAR_MODE_PAGE: c_int = 1;

pub extern fn adw_application_new(application_id: [*:0]const u8, flags: c_uint) ?*Application;

pub extern fn adw_application_window_new(application: *gtk.Application) *gtk.Widget;
pub extern fn adw_application_window_set_content(window: *ApplicationWindow, content: ?*gtk.Widget) void;
pub extern fn adw_application_window_add_breakpoint(window: *ApplicationWindow, breakpoint: *Breakpoint) void;

pub extern fn adw_breakpoint_condition_parse(text: [*:0]const u8) ?*BreakpointCondition;
pub extern fn adw_breakpoint_new(condition: *BreakpointCondition) *Breakpoint;
pub extern fn adw_breakpoint_add_setter(
    breakpoint: *Breakpoint,
    object: *anyopaque,
    property: [*:0]const u8,
    value: *const gtk.GValue,
) void;

pub extern fn adw_navigation_split_view_new() *gtk.Widget;
pub extern fn adw_navigation_split_view_set_sidebar(view: *NavigationSplitView, sidebar: ?*NavigationPage) void;
pub extern fn adw_navigation_split_view_set_content(view: *NavigationSplitView, content: ?*NavigationPage) void;
pub extern fn adw_navigation_split_view_set_show_content(view: *NavigationSplitView, show: gtk.gboolean) void;
pub extern fn adw_navigation_split_view_set_min_sidebar_width(view: *NavigationSplitView, width: f64) void;
pub extern fn adw_navigation_split_view_set_max_sidebar_width(view: *NavigationSplitView, width: f64) void;

pub extern fn adw_navigation_page_new(child: *gtk.Widget, title: [*:0]const u8) *NavigationPage;
pub extern fn adw_navigation_page_set_title(page: *NavigationPage, title: [*:0]const u8) void;

pub extern fn adw_toolbar_view_new() *gtk.Widget;
pub extern fn adw_toolbar_view_set_content(view: *ToolbarView, content: ?*gtk.Widget) void;
pub extern fn adw_toolbar_view_add_top_bar(view: *ToolbarView, widget: *gtk.Widget) void;
pub extern fn adw_toolbar_view_add_bottom_bar(view: *ToolbarView, widget: *gtk.Widget) void;
pub extern fn adw_toolbar_view_set_bottom_bar_style(view: *ToolbarView, style: c_int) void;

pub extern fn adw_header_bar_new() *gtk.Widget;
pub extern fn adw_header_bar_pack_start(bar: *HeaderBar, child: *gtk.Widget) void;
pub extern fn adw_header_bar_pack_end(bar: *HeaderBar, child: *gtk.Widget) void;
pub extern fn adw_header_bar_set_title_widget(bar: *HeaderBar, title_widget: ?*gtk.Widget) void;

pub extern fn adw_window_title_new(title: [*:0]const u8, subtitle: [*:0]const u8) *gtk.Widget;
pub extern fn adw_window_title_set_subtitle(title: *WindowTitle, subtitle: [*:0]const u8) void;

pub extern fn adw_toast_new(title: [*:0]const u8) *Toast;
pub extern fn adw_toast_set_timeout(toast: *Toast, seconds: c_uint) void;
pub extern fn adw_toast_overlay_new() *gtk.Widget;
pub extern fn adw_toast_overlay_set_child(overlay: *ToastOverlay, child: ?*gtk.Widget) void;
pub extern fn adw_toast_overlay_add_toast(overlay: *ToastOverlay, toast: *Toast) void;

pub extern fn adw_status_page_new() *gtk.Widget;
pub extern fn adw_status_page_set_icon_name(page: *StatusPage, icon_name: ?[*:0]const u8) void;
pub extern fn adw_status_page_set_title(page: *StatusPage, title: [*:0]const u8) void;
pub extern fn adw_status_page_set_description(page: *StatusPage, description: ?[*:0]const u8) void;
pub extern fn adw_status_page_set_child(page: *StatusPage, child: ?*gtk.Widget) void;

pub extern fn adw_spinner_new() *gtk.Widget;

pub extern fn adw_sidebar_new() *gtk.Widget;
pub extern fn adw_sidebar_append(sidebar: *Sidebar, section: *SidebarSection) void;
pub extern fn adw_sidebar_get_selected(sidebar: *Sidebar) c_uint;
pub extern fn adw_sidebar_set_selected(sidebar: *Sidebar, selected: c_uint) void;
pub extern fn adw_sidebar_set_mode(sidebar: *Sidebar, mode: c_int) void;
pub extern fn adw_sidebar_section_new() *SidebarSection;
pub extern fn adw_sidebar_section_append(section: *SidebarSection, item: *SidebarItem) void;
pub extern fn adw_sidebar_item_new(title: [*:0]const u8) *SidebarItem;
pub extern fn adw_sidebar_item_set_icon_name(item: *SidebarItem, icon_name: ?[*:0]const u8) void;
pub extern fn adw_sidebar_item_set_suffix(item: *SidebarItem, suffix: ?*gtk.Widget) void;

pub extern fn adw_dialog_present(dialog: *Dialog, parent: ?*gtk.Widget) void;

pub extern fn adw_about_dialog_new() *Dialog;
pub extern fn adw_about_dialog_set_application_name(dialog: *AboutDialog, name: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_application_icon(dialog: *AboutDialog, icon: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_version(dialog: *AboutDialog, version: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_developer_name(dialog: *AboutDialog, name: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_comments(dialog: *AboutDialog, comments: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_license_type(dialog: *AboutDialog, license: c_int) void;

pub extern fn adw_shortcuts_dialog_new() *Dialog;
pub extern fn adw_shortcuts_dialog_add(dialog: *ShortcutsDialog, section: *ShortcutsSection) void;
pub extern fn adw_shortcuts_section_new(title: ?[*:0]const u8) *ShortcutsSection;
pub extern fn adw_shortcuts_section_add(section: *ShortcutsSection, item: *ShortcutsItem) void;
pub extern fn adw_shortcuts_item_new(title: [*:0]const u8, accelerator: [*:0]const u8) *ShortcutsItem;
