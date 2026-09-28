//! Cover textures: asked of liborca's artwork loader, decoded at a bounded size
//! on a GTask thread, and kept in a bounded cache.
//!
//! Finding and reading a cover is the engine's; turning encoded bytes into a
//! texture is presentation, and it is the expensive half — a 6 MiB JPEG costs
//! tens of milliseconds to decode even scaled — so it never runs on the main
//! thread. The decode thread touches only its own job and GLib, never liborca.
//!
//! A cover widget is a `GtkStack` of a "placeholder" child and an "art" child
//! holding a `GtkImage`. Widgets register the cover they want while they are
//! bound and forget it when unbound, so a cover that arrives late lands in
//! whatever is showing it now and a scrolled-past request is cancelled.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");

const App = app.App;

pub const Size = enum(u8) {
    /// Queue rows and the player bar.
    thumb,
    /// Album grid tiles and album pages.
    tile,
    /// Now Playing.
    large,

    fn pixels(self: Size) c_int {
        return switch (self) {
            .thumb => 128,
            .tile => 400,
            .large => 960,
        };
    }
};

pub const Kind = enum(u8) { track, release };

pub const Key = struct {
    kind: Kind,
    id: i64,
    size: Size,

    pub fn release(id: i64, size: Size) Key {
        return .{ .kind = .release, .id = id, .size = size };
    }

    pub fn track(id: i64, size: Size) Key {
        return .{ .kind = .track, .id = id, .size = size };
    }

    fn subject(self: Key) liborca.ArtworkSubject {
        return switch (self.kind) {
            .track => .{ .track = self.id },
            .release => .{ .release = self.id },
        };
    }
};

/// The average colour of a large cover, for tinting what surrounds it.
pub const Tint = struct { red: u8, green: u8, blue: u8 };

const Entry = struct {
    /// Null when the subject has no readable cover.
    texture: ?*gtk.GdkTexture,
    tint: ?Tint,
    used: u64,
};

const Binding = struct {
    stack: *gtk.Stack,
    key: Key,
};

/// Covers kept decoded. A grid screen is a few dozen, and a tile texture is
/// about 640 KB, so this is a few hundred MB at worst and a few screens of
/// scrolling back.
const max_entries = 600;
/// Decodes in flight at once. Each holds a whole encoded cover in memory.
const max_decodes = 4;

const Decode = struct {
    key: Key,
    image: liborca.EmbeddedImage,
    texture: ?*gtk.GdkTexture = null,
    tint: ?Tint = null,
};

pub const Cache = struct {
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    /// Keys asked of liborca, by request id, and the reverse.
    requests: std.AutoHashMapUnmanaged(u64, Key) = .empty,
    pending: std.AutoHashMapUnmanaged(Key, u64) = .empty,
    /// Keys wanted while liborca's queue was full, asked for again on the tick.
    backlog: std.ArrayList(Key) = .empty,
    /// Encoded covers waiting for a decode slot.
    waiting: std.ArrayList(Decode) = .empty,
    decoding: std.AutoHashMapUnmanaged(Key, void) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    clock: u64 = 0,
    /// Called on the main thread when a cover finishes, for widgets that are
    /// not registered bindings (the Now Playing tint).
    on_ready: ?*const fn (*App, Key) void = null,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        var entries = self.entries.valueIterator();
        while (entries.next()) |entry| if (entry.texture) |texture| gtk.g_object_unref(texture);
        self.entries.deinit(allocator);
        self.requests.deinit(allocator);
        self.pending.deinit(allocator);
        self.backlog.deinit(allocator);
        for (self.waiting.items) |job| job.image.deinit();
        self.waiting.deinit(allocator);
        self.decoding.deinit(allocator);
        self.bindings.deinit(allocator);
    }
};

fn coverDestroyed(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    forget(@ptrCast(@alignCast(data.?)), gtk.cast(gtk.Widget, widget));
}

/// Builds an empty cover widget: `placeholder` shown until `show` finds art.
/// It unregisters itself when destroyed.
pub fn newCover(self: *App, placeholder: *gtk.Widget, pixels: c_int) *gtk.Widget {
    const stack = gtk.gtk_stack_new();
    _ = gtk.signalConnect(stack, "destroy", gtk.callback(coverDestroyed), self);
    gtk.gtk_widget_add_css_class(stack, "cover");
    gtk.gtk_widget_set_overflow(stack, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_size_request(stack, pixels, pixels);
    gtk.gtk_widget_set_halign(stack, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(stack, gtk.ALIGN_CENTER);
    const image = gtk.gtk_image_new();
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), pixels);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), placeholder, "placeholder");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), image, "art");
    gtk.gtk_stack_set_transition_type(gtk.cast(gtk.Stack, stack), gtk.STACK_TRANSITION_CROSSFADE);
    return stack;
}

/// A placeholder icon for covers of tracks.
pub fn iconPlaceholder(pixels: c_int) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("audio-x-generic-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), @divTrunc(pixels, 2));
    gtk.gtk_widget_add_css_class(icon, "cover-placeholder");
    return icon;
}

/// A placeholder for an album: its initials on a colour chosen from its title,
/// so a grid of albums without covers still reads as distinct albums.
pub fn initialsPlaceholder() *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(label, "cover-initials");
    return label;
}

pub fn setInitials(stack_widget: *gtk.Widget, title: []const u8) void {
    const stack = gtk.cast(gtk.Stack, stack_widget);
    const label = gtk.gtk_stack_get_child_by_name(stack, "placeholder") orelse return;
    var buffer: [16]u8 = undefined;
    var length: usize = 0;
    var words = std.mem.tokenizeAny(u8, title, " \t-_/.&()[]");
    while (words.next()) |word| {
        if (length >= 2) break;
        const first = std.unicode.utf8ByteSequenceLength(word[0]) catch 1;
        if (first > word.len or length + first > buffer.len - 1) break;
        @memcpy(buffer[length..][0..first], word[0..first]);
        if (first == 1) buffer[length] = std.ascii.toUpper(buffer[length]);
        length += first;
    }
    buffer[length] = 0;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), @ptrCast(&buffer));
    const palette = [_][*:0]const u8{ "tile-0", "tile-1", "tile-2", "tile-3", "tile-4", "tile-5" };
    const chosen = std.hash.Wyhash.hash(0, title) % palette.len;
    for (palette, 0..) |class, index| {
        if (index == chosen)
            gtk.gtk_widget_add_css_class(stack_widget, class)
        else
            gtk.gtk_widget_remove_css_class(stack_widget, class);
    }
}

fn paint(stack: *gtk.Stack, texture: ?*gtk.GdkTexture) void {
    const image = gtk.gtk_stack_get_child_by_name(stack, "art") orelse return;
    if (texture) |present| {
        gtk.gtk_image_set_from_paintable(gtk.cast(gtk.Image, image), gtk.cast(gtk.GdkPaintable, present));
        gtk.gtk_stack_set_visible_child_name(stack, "art");
    } else {
        gtk.gtk_image_set_from_paintable(gtk.cast(gtk.Image, image), null);
        gtk.gtk_stack_set_visible_child_name(stack, "placeholder");
    }
}

/// Shows `key`'s cover in `stack_widget` now if it is cached, and when it
/// arrives if not. Replaces whatever the widget was registered for.
pub fn show(self: *App, stack_widget: *gtk.Widget, key: Key) void {
    const stack = gtk.cast(gtk.Stack, stack_widget);
    forget(self, stack_widget);
    const cache = &self.art;
    if (cache.entries.getPtr(key)) |entry| {
        cache.clock += 1;
        entry.used = cache.clock;
        paint(stack, entry.texture);
        return;
    }
    paint(stack, null);
    cache.bindings.append(self.allocator, .{ .stack = stack, .key = key }) catch return;
    want(self, key);
}

/// The widget no longer shows a cover. A request nobody else is waiting for
/// is cancelled.
pub fn forget(self: *App, stack_widget: *gtk.Widget) void {
    const cache = &self.art;
    const stack = gtk.cast(gtk.Stack, stack_widget);
    var index: usize = 0;
    while (index < cache.bindings.items.len) {
        const binding = cache.bindings.items[index];
        if (binding.stack != stack) {
            index += 1;
            continue;
        }
        _ = cache.bindings.swapRemove(index);
        if (!isWanted(cache, binding.key)) abandon(self, binding.key);
    }
}

/// The cached cover's tint, if its large decode has finished.
pub fn tintOf(self: *App, key: Key) ?Tint {
    const entry = self.art.entries.get(key) orelse return null;
    return entry.tint;
}

/// Asks for a cover no widget is bound to, so `on_ready` hears of it.
pub fn prefetch(self: *App, key: Key) bool {
    if (self.art.entries.contains(key)) return true;
    want(self, key);
    return false;
}

fn isWanted(cache: *const Cache, key: Key) bool {
    for (cache.bindings.items) |binding| {
        if (std.meta.eql(binding.key, key)) return true;
    }
    return false;
}

fn want(self: *App, key: Key) void {
    const cache = &self.art;
    if (cache.pending.contains(key) or cache.decoding.contains(key)) return;
    for (cache.backlog.items) |queued| if (std.meta.eql(queued, key)) return;
    const library = self.library orelse return;
    const request = self.runtime.libraryRequestArtwork(library, self.io, key.subject()) catch {
        cache.backlog.append(self.allocator, key) catch {};
        return;
    };
    cache.pending.put(self.allocator, key, request) catch return;
    cache.requests.put(self.allocator, request, key) catch {};
}

fn abandon(self: *App, key: Key) void {
    const cache = &self.art;
    for (cache.backlog.items, 0..) |queued, index| {
        if (std.meta.eql(queued, key)) {
            _ = cache.backlog.swapRemove(index);
            return;
        }
    }
    const request = cache.pending.get(key) orelse return;
    const library = self.library orelse return;
    self.runtime.libraryCancelArtwork(library, request);
    _ = cache.pending.remove(key);
    _ = cache.requests.remove(request);
}

fn remember(self: *App, key: Key, texture: ?*gtk.GdkTexture, tint: ?Tint) void {
    const cache = &self.art;
    if (cache.entries.count() >= max_entries) evictOldest(cache);
    cache.clock += 1;
    cache.entries.put(self.allocator, key, .{ .texture = texture, .tint = tint, .used = cache.clock }) catch {
        if (texture) |present| gtk.g_object_unref(present);
        return;
    };
    for (cache.bindings.items) |binding| {
        if (std.meta.eql(binding.key, key)) paint(binding.stack, texture);
    }
    if (cache.on_ready) |notify| notify(self, key);
}

fn evictOldest(cache: *Cache) void {
    var oldest: ?Key = null;
    var oldest_used: u64 = std.math.maxInt(u64);
    var iterator = cache.entries.iterator();
    while (iterator.next()) |item| {
        if (item.value_ptr.used < oldest_used) {
            oldest_used = item.value_ptr.used;
            oldest = item.key_ptr.*;
        }
    }
    const key = oldest orelse return;
    const removed = cache.entries.fetchRemove(key) orelse return;
    if (removed.value.texture) |texture| gtk.g_object_unref(texture);
}

/// Drains finished requests and retries the backlog. Called on the app tick.
pub fn tick(self: *App) void {
    const library = self.library orelse return;
    const cache = &self.art;
    while (self.runtime.libraryTakeArtwork(library)) |result| {
        const key = cache.requests.get(result.request) orelse {
            if (result.image) |image| image.deinit();
            continue;
        };
        _ = cache.requests.remove(result.request);
        _ = cache.pending.remove(key);
        const image = result.image orelse {
            remember(self, key, null, null);
            continue;
        };
        cache.waiting.append(self.allocator, .{ .key = key, .image = image }) catch {
            image.deinit();
            continue;
        };
    }
    startDecodes(self);
    var retries = cache.backlog.items.len;
    while (retries != 0 and cache.backlog.items.len != 0) : (retries -= 1) {
        const key = cache.backlog.orderedRemove(0);
        want(self, key);
        if (!cache.pending.contains(key)) break;
    }
}

fn startDecodes(self: *App) void {
    const cache = &self.art;
    while (cache.decoding.count() < max_decodes and cache.waiting.items.len != 0) {
        const next = cache.waiting.orderedRemove(0);
        const job = self.allocator.create(Decode) catch {
            next.image.deinit();
            continue;
        };
        job.* = next;
        cache.decoding.put(self.allocator, job.key, {}) catch {};
        const task = gtk.g_task_new(null, null, decoded, self);
        gtk.g_task_set_task_data(task, job, null);
        gtk.g_task_run_in_thread(task, decodeInThread);
        gtk.g_object_unref(task);
    }
}

fn decodeInThread(task: *gtk.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*gtk.GCancellable) callconv(.c) void {
    const job: *Decode = @ptrCast(@alignCast(data.?));
    const bytes = job.image.bytes;
    const borrowed = gtk.g_bytes_new_static(bytes.ptr, bytes.len);
    defer gtk.g_bytes_unref(borrowed);
    const stream = gtk.g_memory_input_stream_new_from_bytes(borrowed);
    defer gtk.g_object_unref(stream);
    var err: ?*gtk.GError = null;
    const pixels = job.key.size.pixels();
    if (gtk.gdk_pixbuf_new_from_stream_at_scale(stream, pixels, pixels, gtk.true_, null, &err)) |pixbuf| {
        defer gtk.g_object_unref(pixbuf);
        job.texture = gtk.gdk_texture_new_for_pixbuf(pixbuf);
        if (job.key.size == .large) job.tint = averageColour(pixbuf);
    } else gtk.g_clear_error(&err);
    gtk.g_task_return_pointer(task, job, null);
}

/// The mean colour of every eighth pixel in each direction, which is plenty
/// for a background wash.
fn averageColour(pixbuf: *gtk.GdkPixbuf) Tint {
    const width: usize = @intCast(gtk.gdk_pixbuf_get_width(pixbuf));
    const height: usize = @intCast(gtk.gdk_pixbuf_get_height(pixbuf));
    const stride: usize = @intCast(gtk.gdk_pixbuf_get_rowstride(pixbuf));
    const channels: usize = @intCast(gtk.gdk_pixbuf_get_n_channels(pixbuf));
    const data = gtk.gdk_pixbuf_get_pixels(pixbuf);
    var sums: [3]u64 = .{ 0, 0, 0 };
    var count: u64 = 0;
    var y: usize = 0;
    while (y < height) : (y += 8) {
        var x: usize = 0;
        while (x < width) : (x += 8) {
            const pixel = data + y * stride + x * channels;
            sums[0] += pixel[0];
            sums[1] += pixel[1];
            sums[2] += pixel[2];
            count += 1;
        }
    }
    if (count == 0) return .{ .red = 128, .green = 128, .blue = 128 };
    return .{
        .red = @intCast(sums[0] / count),
        .green = @intCast(sums[1] / count),
        .blue = @intCast(sums[2] / count),
    };
}

fn decoded(_: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    var err: ?*gtk.GError = null;
    const pointer = gtk.g_task_propagate_pointer(gtk.cast(gtk.GTask, result), &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const job: *Decode = @ptrCast(@alignCast(pointer));
    defer self.allocator.destroy(job);
    job.image.deinit();
    _ = self.art.decoding.remove(job.key);
    remember(self, job.key, job.texture, job.tint);
    startDecodes(self);
}
