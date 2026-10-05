const std = @import("std");
const gtk = @import("gtk.zig");
const art = @import("art.zig");

const downscale: f32 = 4;
const blur_radius: usize = 6;
const blur_passes: usize = 3;
const saturation_percent: i32 = 140;

pub const Frost = struct {
    layer: ?*gtk.Widget = null,
    picture: ?*gtk.Widget = null,
    covered: ?*gtk.Widget = null,
    pending: ?*gtk.GdkPaintable = null,
    generation: u32 = 0,
};

const Job = struct {
    frost: *Frost,
    generation: u32,
    pixels: [][4]u8,
    width: usize,
    height: usize,
    texture: ?*gtk.GdkTexture = null,
};

pub fn newLayer(frost: *Frost, covered: *gtk.Widget) *gtk.Widget {
    const picture = gtk.gtk_picture_new();
    gtk.gtk_picture_set_can_shrink(gtk.cast(gtk.Picture, picture), gtk.true_);
    gtk.gtk_picture_set_content_fit(gtk.cast(gtk.Picture, picture), gtk.CONTENT_FIT_FILL);
    const dim = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(dim, "frost-dim");
    const layer = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(layer, "frost");
    gtk.gtk_widget_set_can_target(layer, gtk.false_);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layer), picture);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layer), dim);
    frost.layer = layer;
    frost.picture = picture;
    frost.covered = covered;
    return layer;
}

pub fn capture(frost: *Frost) void {
    release(frost);
    const covered = frost.covered orelse return;
    const paintable = gtk.gtk_widget_paintable_new(covered);
    if (render(frost, paintable)) {
        gtk.g_object_unref(paintable);
        return;
    }
    frost.pending = paintable;
    _ = gtk.signalConnect(paintable, "invalidate-contents", gtk.callback(redrawn), frost);
}

pub fn release(frost: *Frost) void {
    frost.generation +%= 1;
    if (frost.pending) |paintable| {
        frost.pending = null;
        gtk.g_object_unref(paintable);
    }
    if (frost.layer) |layer| gtk.gtk_widget_remove_css_class(layer, "ready");
    if (frost.picture) |picture| gtk.gtk_picture_set_paintable(gtk.cast(gtk.Picture, picture), null);
}

fn redrawn(paintable: *gtk.GdkPaintable, data: ?*anyopaque) callconv(.c) void {
    const frost: *Frost = @ptrCast(@alignCast(data.?));
    if (frost.pending != paintable) return;
    if (!render(frost, paintable)) return;
    frost.pending = null;
    gtk.g_object_unref(paintable);
}

fn render(frost: *Frost, paintable: *gtk.GdkPaintable) bool {
    const covered = frost.covered orelse return true;
    const width = gtk.gtk_widget_get_width(covered);
    const height = gtk.gtk_widget_get_height(covered);
    if (width <= 0 or height <= 0) return true;
    const native = gtk.gtk_widget_get_native(covered) orelse return true;
    const renderer = gtk.gtk_native_get_renderer(native) orelse return true;

    const snapshot = gtk.gtk_snapshot_new();
    gtk.gtk_snapshot_scale(snapshot, 1 / downscale, 1 / downscale);
    gtk.gdk_paintable_snapshot(paintable, snapshot, @floatFromInt(width), @floatFromInt(height));
    const node = gtk.gtk_snapshot_free_to_node(snapshot) orelse return false;
    defer gtk.gsk_render_node_unref(node);
    const viewport: gtk.Rect = .{
        .width = @ceil(@as(f32, @floatFromInt(width)) / downscale),
        .height = @ceil(@as(f32, @floatFromInt(height)) / downscale),
    };
    const texture = gtk.gsk_renderer_render_texture(renderer, node, &viewport);
    defer gtk.g_object_unref(texture);

    const small_width: usize = @intCast(@max(gtk.gdk_texture_get_width(texture), 0));
    const small_height: usize = @intCast(@max(gtk.gdk_texture_get_height(texture), 0));
    if (small_width == 0 or small_height == 0) return true;
    const allocator = std.heap.smp_allocator;
    const pixels = allocator.alloc([4]u8, small_width * small_height) catch return true;
    gtk.gdk_texture_download(texture, @ptrCast(pixels.ptr), small_width * 4);
    const job = allocator.create(Job) catch {
        allocator.free(pixels);
        return true;
    };
    job.* = .{ .frost = frost, .generation = frost.generation, .pixels = pixels, .width = small_width, .height = small_height };
    const task = gtk.g_task_new(null, null, blurred, null);
    gtk.g_task_set_task_data(task, job, null);
    gtk.g_task_run_in_thread(task, blurInThread);
    gtk.g_object_unref(task);
    return true;
}

fn blurInThread(task: *gtk.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*gtk.GCancellable) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    defer gtk.g_task_return_pointer(task, job, null);
    const scratch = std.heap.smp_allocator.alloc([4]u8, job.pixels.len) catch return;
    defer std.heap.smp_allocator.free(scratch);
    art.blur(job.pixels, scratch, job.width, job.height, blur_radius, blur_passes);
    art.saturate(job.pixels, saturation_percent);
    const bytes = gtk.g_bytes_new(job.pixels.ptr, job.pixels.len * 4);
    defer gtk.g_bytes_unref(bytes);
    job.texture = gtk.gdk_memory_texture_new(
        @intCast(job.width),
        @intCast(job.height),
        gtk.MEMORY_B8G8R8A8_PREMULTIPLIED,
        bytes,
        job.width * 4,
    );
}

fn blurred(_: ?*gtk.GObject, result: *gtk.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    const pointer = gtk.g_task_propagate_pointer(gtk.cast(gtk.GTask, result), &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const job: *Job = @ptrCast(@alignCast(pointer));
    defer {
        std.heap.smp_allocator.free(job.pixels);
        std.heap.smp_allocator.destroy(job);
    }
    const texture = job.texture orelse return;
    defer gtk.g_object_unref(texture);
    const frost = job.frost;
    if (job.generation != frost.generation) return;
    const picture = frost.picture orelse return;
    gtk.gtk_picture_set_paintable(gtk.cast(gtk.Picture, picture), gtk.cast(gtk.GdkPaintable, texture));
    if (frost.layer) |layer| gtk.gtk_widget_add_css_class(layer, "ready");
}
