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
pub const NavigationView = opaque {};
pub const Clamp = opaque {};
pub const Avatar = opaque {};
pub const PreferencesDialog = opaque {};
pub const PreferencesPage = opaque {};
pub const PreferencesGroup = opaque {};
pub const PreferencesRow = opaque {};
pub const ActionRow = opaque {};
pub const SwitchRow = opaque {};
pub const ComboRow = opaque {};
pub const SpinRow = opaque {};
pub const AlertDialog = opaque {};

pub const RESPONSE_DEFAULT: c_int = 0;
pub const RESPONSE_SUGGESTED: c_int = 1;
pub const RESPONSE_DESTRUCTIVE: c_int = 2;

pub extern fn adw_preferences_dialog_new() *Dialog;
pub extern fn adw_preferences_dialog_add(dialog: *PreferencesDialog, page: *PreferencesPage) void;
pub extern fn adw_preferences_dialog_add_toast(dialog: *PreferencesDialog, toast: *Toast) void;
pub extern fn adw_preferences_page_new() *gtk.Widget;
pub extern fn adw_preferences_page_add(page: *PreferencesPage, group: *PreferencesGroup) void;
pub extern fn adw_preferences_page_set_title(page: *PreferencesPage, title: [*:0]const u8) void;
pub extern fn adw_preferences_page_set_icon_name(page: *PreferencesPage, icon_name: ?[*:0]const u8) void;
pub extern fn adw_preferences_group_new() *gtk.Widget;
pub extern fn adw_preferences_group_add(group: *PreferencesGroup, child: *gtk.Widget) void;
pub extern fn adw_preferences_group_set_title(group: *PreferencesGroup, title: [*:0]const u8) void;
pub extern fn adw_preferences_group_set_description(group: *PreferencesGroup, description: ?[*:0]const u8) void;
pub extern fn adw_preferences_row_set_title(row: *PreferencesRow, title: [*:0]const u8) void;
pub extern fn adw_action_row_new() *gtk.Widget;
pub extern fn adw_action_row_add_suffix(row: *ActionRow, widget: *gtk.Widget) void;
pub extern fn adw_action_row_add_prefix(row: *ActionRow, widget: *gtk.Widget) void;
pub extern fn adw_action_row_set_subtitle(row: *ActionRow, subtitle: [*:0]const u8) void;
pub extern fn adw_action_row_set_subtitle_lines(row: *ActionRow, lines: c_int) void;
pub extern fn adw_entry_row_new() *gtk.Widget;
pub extern fn adw_switch_row_new() *gtk.Widget;
pub extern fn adw_switch_row_get_active(row: *SwitchRow) gtk.gboolean;
pub extern fn adw_switch_row_set_active(row: *SwitchRow, active: gtk.gboolean) void;
pub extern fn adw_spin_row_new_with_range(min: f64, max: f64, step: f64) *gtk.Widget;
pub extern fn adw_spin_row_get_value(row: *SpinRow) f64;
pub extern fn adw_spin_row_set_value(row: *SpinRow, value: f64) void;
pub extern fn adw_spin_row_set_digits(row: *SpinRow, digits: c_uint) void;
pub extern fn adw_combo_row_new() *gtk.Widget;
pub extern fn adw_combo_row_set_model(row: *ComboRow, model: ?*gtk.ListModel) void;
pub extern fn adw_combo_row_get_selected(row: *ComboRow) c_uint;
pub extern fn adw_combo_row_set_selected(row: *ComboRow, position: c_uint) void;
pub extern fn adw_button_row_new() *gtk.Widget;
pub extern fn adw_button_row_set_start_icon_name(row: *gtk.Widget, icon_name: ?[*:0]const u8) void;
pub extern fn adw_alert_dialog_new(heading: ?[*:0]const u8, body: ?[*:0]const u8) *Dialog;
pub extern fn adw_alert_dialog_add_response(dialog: *AlertDialog, id: [*:0]const u8, label: [*:0]const u8) void;
pub extern fn adw_alert_dialog_set_response_appearance(dialog: *AlertDialog, response: [*:0]const u8, appearance: c_int) void;
pub extern fn adw_alert_dialog_set_default_response(dialog: *AlertDialog, response: ?[*:0]const u8) void;
pub extern fn adw_alert_dialog_set_close_response(dialog: *AlertDialog, response: [*:0]const u8) void;
pub extern fn adw_alert_dialog_set_extra_child(dialog: *AlertDialog, child: ?*gtk.Widget) void;
pub extern fn adw_dialog_new() *Dialog;
pub extern fn adw_header_bar_set_show_end_title_buttons(bar: *HeaderBar, show: gtk.gboolean) void;
pub extern fn adw_header_bar_set_show_start_title_buttons(bar: *HeaderBar, show: gtk.gboolean) void;
pub extern fn adw_dialog_set_child(dialog: *Dialog, child: ?*gtk.Widget) void;
pub extern fn adw_dialog_set_title(dialog: *Dialog, title: [*:0]const u8) void;
pub extern fn adw_dialog_set_content_width(dialog: *Dialog, width: c_int) void;
pub extern fn adw_dialog_close(dialog: *Dialog) gtk.gboolean;
pub extern fn adw_toast_set_button_label(toast: *Toast, label: ?[*:0]const u8) void;
pub extern fn adw_toast_set_action_name(toast: *Toast, action_name: ?[*:0]const u8) void;

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

pub extern fn adw_navigation_view_new() *gtk.Widget;
pub extern fn adw_navigation_view_add(view: *NavigationView, page: *NavigationPage) void;
pub extern fn adw_navigation_view_push(view: *NavigationView, page: *NavigationPage) void;
pub extern fn adw_navigation_view_pop(view: *NavigationView) gtk.gboolean;
pub extern fn adw_navigation_view_pop_to_tag(view: *NavigationView, tag: [*:0]const u8) gtk.gboolean;
pub extern fn adw_navigation_view_get_visible_page_tag(view: *NavigationView) ?[*:0]const u8;

pub extern fn adw_clamp_new() *gtk.Widget;
pub extern fn adw_clamp_set_maximum_size(clamp: *Clamp, size: c_int) void;
pub extern fn adw_clamp_set_child(clamp: *Clamp, child: ?*gtk.Widget) void;

pub extern fn adw_navigation_page_new(child: *gtk.Widget, title: [*:0]const u8) *NavigationPage;
pub extern fn adw_navigation_page_set_title(page: *NavigationPage, title: [*:0]const u8) void;
pub extern fn adw_navigation_page_set_tag(page: *NavigationPage, tag: ?[*:0]const u8) void;

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

pub extern fn adw_avatar_new(size: c_int, text: ?[*:0]const u8, show_initials: gtk.gboolean) *gtk.Widget;
pub extern fn adw_avatar_set_text(avatar: *Avatar, text: ?[*:0]const u8) void;

pub extern fn adw_sidebar_new() *gtk.Widget;
pub extern fn adw_sidebar_append(sidebar: *Sidebar, section: *SidebarSection) void;
pub extern fn adw_sidebar_get_selected(sidebar: *Sidebar) c_uint;
pub extern fn adw_sidebar_set_selected(sidebar: *Sidebar, selected: c_uint) void;
pub extern fn adw_sidebar_set_mode(sidebar: *Sidebar, mode: c_int) void;
pub extern fn adw_sidebar_section_new() *SidebarSection;
pub extern fn adw_sidebar_section_set_title(section: *SidebarSection, title: ?[*:0]const u8) void;
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
