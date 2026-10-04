//! Desktop notifications through `GNotification`, gated by the General
//! settings "Track changes" and "Library tasks".

const gtk = @import("gtk.zig");
const app = @import("app.zig");

const App = app.App;

fn send(self: *App, id: [*:0]const u8, title: [*:0]const u8, body: ?[*:0]const u8) void {
    const application = self.application orelse return;
    const notification = gtk.g_notification_new(title);
    defer gtk.g_object_unref(notification);
    if (body) |text| if (text[0] != 0) gtk.g_notification_set_body(notification, text);
    gtk.g_application_send_notification(gtk.cast(gtk.GApplication, application), id, notification);
}

pub fn trackChanged(self: *App, title: [*:0]const u8, detail: [*:0]const u8) void {
    if (!self.general.notify_tracks) return;
    send(self, "track", title, detail);
}

pub fn taskEnded(self: *App, text: [*:0]const u8) void {
    if (!self.general.notify_tasks) return;
    send(self, "task", text, null);
}
