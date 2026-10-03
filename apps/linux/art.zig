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

pub const Kind = enum(u8) { track, release, artist, related };

pub const Key = struct {
    kind: Kind,
    id: i64,
    size: Size,
    mbid: [36]u8 = @splat(0),

    pub fn release(id: i64, size: Size) Key {
        return .{ .kind = .release, .id = id, .size = size };
    }

    pub fn track(id: i64, size: Size) Key {
        return .{ .kind = .track, .id = id, .size = size };
    }

    pub fn artist(id: i64, size: Size) Key {
        return .{ .kind = .artist, .id = id, .size = size };
    }

    pub fn related(mbid: []const u8, size: Size) Key {
        var key: Key = .{ .kind = .related, .id = 0, .size = size };
        const length = @min(mbid.len, key.mbid.len);
        @memcpy(key.mbid[0..length], mbid[0..length]);
        return key;
    }

    fn subject(self: Key) ?liborca.ArtworkSubject {
        return switch (self.kind) {
            .track => .{ .track = self.id },
            .release => .{ .release = self.id },
            .artist => .{ .artist = self.id },
            .related => null,
        };
    }
};

const backdrop_pixels: usize = 64;
const backdrop_blur_radius: usize = 2;
const backdrop_blur_passes: usize = 3;
const backdrop_brightness_percent: u32 = 50;

/// A small, blurred copy of `texture` to draw scaled up behind a page. Under
/// the cairo renderer a CSS blur of the full cover costs a third of a core
/// while scrolling.
pub fn blurredBackdrop(allocator: std.mem.Allocator, texture: *gtk.GdkTexture) ?*gtk.GdkTexture {
    const source_width: usize = @intCast(@max(gtk.gdk_texture_get_width(texture), 0));
    const source_height: usize = @intCast(@max(gtk.gdk_texture_get_height(texture), 0));
    if (source_width == 0 or source_height == 0) return null;
    const source = allocator.alloc(u8, source_width * source_height * 4) catch return null;
    defer allocator.free(source);
    gtk.gdk_texture_download(texture, source.ptr, source_width * 4);

    const longest = @max(source_width, source_height);
    const width = @max(1, source_width * backdrop_pixels / longest);
    const height = @max(1, source_height * backdrop_pixels / longest);
    const pixels = allocator.alloc([4]u8, width * height) catch return null;
    defer allocator.free(pixels);
    const scratch = allocator.alloc([4]u8, width * height) catch return null;
    defer allocator.free(scratch);
    downscale(source, source_width, source_height, pixels, width, height);
    for (0..backdrop_blur_passes) |_| {
        boxBlur(pixels, scratch, width, height, 1, width);
        boxBlur(scratch, pixels, height, width, width, 1);
    }
    for (pixels) |*pixel| {
        for (pixel[0..3]) |*channel| channel.* = @intCast(@as(u32, channel.*) * backdrop_brightness_percent / 100);
    }

    const bytes = gtk.g_bytes_new(pixels.ptr, pixels.len * 4);
    defer gtk.g_bytes_unref(bytes);
    return gtk.gdk_memory_texture_new(
        @intCast(width),
        @intCast(height),
        gtk.MEMORY_B8G8R8A8_PREMULTIPLIED,
        bytes,
        width * 4,
    );
}

fn downscale(source: []const u8, source_width: usize, source_height: usize, target: [][4]u8, width: usize, height: usize) void {
    for (0..height) |y| {
        const top = y * source_height / height;
        const bottom = @max(top + 1, (y + 1) * source_height / height);
        for (0..width) |x| {
            const left = x * source_width / width;
            const right = @max(left + 1, (x + 1) * source_width / width);
            var sums: [4]u32 = @splat(0);
            for (top..bottom) |row| {
                for (left..right) |column| {
                    const pixel = source[(row * source_width + column) * 4 ..][0..4];
                    for (&sums, pixel) |*sum, channel| sum.* += channel;
                }
            }
            const count: u32 = @intCast((bottom - top) * (right - left));
            for (&target[y * width + x], sums) |*channel, sum| channel.* = @intCast(sum / count);
        }
    }
}

fn boxBlur(source: []const [4]u8, target: [][4]u8, length: usize, lines: usize, step: usize, line_step: usize) void {
    const window: u32 = backdrop_blur_radius * 2 + 1;
    for (0..lines) |line| {
        const start = line * line_step;
        for (0..length) |position| {
            var sums: [4]u32 = @splat(0);
            for (0..window) |offset| {
                const sample = std.math.clamp(position + offset, backdrop_blur_radius, length - 1 + backdrop_blur_radius) - backdrop_blur_radius;
                for (&sums, source[start + sample * step]) |*sum, channel| sum.* += channel;
            }
            for (&target[start + position * step], sums) |*channel, sum| channel.* = @intCast(sum / window);
        }
    }
}

const Entry = struct {
    /// Null when the subject has no readable cover.
    texture: ?*gtk.GdkTexture,
    used: u64,
};

const Binding = struct {
    stack: *gtk.Stack,
    key: Key,
    fallback: ?Key = null,
    request_key: bool = true,
};

pub const ArtistPhoto = enum { stored, absent, unknown };

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

pub fn newFillingCover(self: *App, placeholder: *gtk.Widget) *gtk.Widget {
    const stack = gtk.gtk_stack_new();
    _ = gtk.signalConnect(stack, "destroy", gtk.callback(coverDestroyed), self);
    gtk.gtk_widget_set_overflow(stack, gtk.OVERFLOW_HIDDEN);
    const picture = gtk.gtk_picture_new();
    gtk.gtk_picture_set_can_shrink(gtk.cast(gtk.Picture, picture), gtk.true_);
    gtk.gtk_picture_set_content_fit(gtk.cast(gtk.Picture, picture), gtk.CONTENT_FIT_COVER);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), placeholder, "placeholder");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), picture, "art");
    gtk.g_object_set_data(stack, picture_key, picture);
    return stack;
}

const picture_key = "orca-picture";

/// A placeholder icon for covers of tracks.
pub fn iconPlaceholder(pixels: c_int) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("audio-x-generic-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), @divTrunc(pixels, 2));
    gtk.gtk_widget_add_css_class(icon, "cover-placeholder");
    return icon;
}

/// A placeholder for an album: its initials on a neutral surface, so a grid of
/// albums without covers still reads as distinct albums.
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
}

fn paint(stack: *gtk.Stack, texture: ?*gtk.GdkTexture) void {
    if (gtk.g_object_get_data(stack, picture_key)) |picture| {
        gtk.gtk_picture_set_paintable(gtk.cast(gtk.Picture, picture), if (texture) |present| gtk.cast(gtk.GdkPaintable, present) else null);
        gtk.gtk_stack_set_visible_child_name(stack, if (texture != null) "art" else "placeholder");
        return;
    }
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
    forget(self, stack_widget);
    const binding: Binding = .{ .stack = gtk.cast(gtk.Stack, stack_widget), .key = key };
    self.art.bindings.append(self.allocator, binding) catch return paint(binding.stack, null);
    paintBinding(self, binding);
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
        if (binding.fallback) |fallback| {
            if (!isWanted(cache, fallback)) abandon(self, fallback);
        }
    }
}

pub fn clear(self: *App, stack_widget: *gtk.Widget) void {
    forget(self, stack_widget);
    paint(gtk.cast(gtk.Stack, stack_widget), null);
}

/// Drops a Release's cached covers and asks again for each one a widget
/// shows, so a cover fetched since replaces the placeholder.
pub fn refreshRelease(self: *App, release_id: i64) void {
    inline for (comptime std.enums.values(Size)) |size| refresh(self, Key.release(release_id, size));
    var tracks: std.ArrayList(Key) = .empty;
    defer tracks.deinit(self.allocator);
    var keys = self.art.entries.keyIterator();
    while (keys.next()) |key| if (key.kind == .track) tracks.append(self.allocator, key.*) catch break;
    for (tracks.items) |key| refresh(self, key);
}

pub fn refreshArtist(self: *App, artist_id: i64) void {
    inline for (comptime std.enums.values(Size)) |size| refresh(self, Key.artist(artist_id, size));
}

fn refresh(self: *App, key: Key) void {
    const cache = &self.art;
    if (cache.entries.fetchRemove(key)) |removed| {
        if (removed.value.texture) |texture| gtk.g_object_unref(texture);
    }
    if (cache.pending.fetchRemove(key)) |pending| {
        _ = cache.requests.remove(pending.value);
        if (self.library) |library| self.runtime.libraryCancelArtwork(library, pending.value);
    }
    if (isWanted(cache, key)) want(self, key);
}

pub fn showArtist(self: *App, stack_widget: *gtk.Widget, artist_id: i64, photo: ArtistPhoto, fallback_release: ?i64, size: Size) void {
    forget(self, stack_widget);
    const cache = &self.art;
    const binding: Binding = .{
        .stack = gtk.cast(gtk.Stack, stack_widget),
        .key = Key.artist(artist_id, size),
        .fallback = if (fallback_release) |release_id| Key.release(release_id, size) else null,
        .request_key = photo != .absent,
    };
    cache.bindings.append(self.allocator, binding) catch return paint(binding.stack, null);
    paintBinding(self, binding);
}

fn paintBinding(self: *App, binding: Binding) void {
    const cache = &self.art;
    if (cache.entries.getPtr(binding.key)) |entry| {
        touch(cache, entry);
        if (entry.texture) |texture| return paint(binding.stack, texture);
    } else if (binding.request_key) {
        paint(binding.stack, null);
        return want(self, binding.key);
    }
    const fallback = binding.fallback orelse return paint(binding.stack, null);
    if (cache.entries.getPtr(fallback)) |entry| {
        touch(cache, entry);
        return paint(binding.stack, entry.texture);
    }
    paint(binding.stack, null);
    want(self, fallback);
}

fn touch(cache: *Cache, entry: *Entry) void {
    cache.clock += 1;
    entry.used = cache.clock;
}

pub fn showRelated(self: *App, stack_widget: *gtk.Widget, mbid: []const u8, size: Size) bool {
    const key = Key.related(mbid, size);
    show(self, stack_widget, key);
    const entry = self.art.entries.get(key) orelse return true;
    return entry.texture != null;
}

fn isWanted(cache: *const Cache, key: Key) bool {
    for (cache.bindings.items) |binding| {
        if (std.meta.eql(binding.key, key)) return true;
        if (binding.fallback) |fallback| if (std.meta.eql(fallback, key)) return true;
    }
    return false;
}

fn want(self: *App, key: Key) void {
    const cache = &self.art;
    if (cache.pending.contains(key) or cache.decoding.contains(key)) return;
    for (cache.backlog.items) |queued| if (std.meta.eql(queued, key)) return;
    const library = self.library orelse return;
    const subject = key.subject() orelse return wantRelatedPhoto(self, library, key);
    const request = self.runtime.libraryRequestArtwork(library, self.io, subject) catch {
        cache.backlog.append(self.allocator, key) catch {};
        return;
    };
    cache.pending.put(self.allocator, key, request) catch return;
    cache.requests.put(self.allocator, request, key) catch {};
}

fn wantRelatedPhoto(self: *App, library: liborca.LibraryHandle, key: Key) void {
    const cache = &self.art;
    for (cache.waiting.items) |job| if (std.meta.eql(job.key, key)) return;
    const photo = self.runtime.libraryRelatedArtistPhoto(library, std.mem.sliceTo(&key.mbid, 0)) catch null;
    const image = photo orelse return remember(self, key, null);
    cache.waiting.append(self.allocator, .{ .key = key, .image = image }) catch return image.deinit();
    startDecodes(self);
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

fn remember(self: *App, key: Key, texture: ?*gtk.GdkTexture) void {
    const cache = &self.art;
    if (cache.entries.count() >= max_entries) evictOldest(cache);
    cache.clock += 1;
    cache.entries.put(self.allocator, key, .{ .texture = texture, .used = cache.clock }) catch {
        if (texture) |present| gtk.g_object_unref(present);
        return;
    };
    for (cache.bindings.items) |binding| {
        const fallback_matches = if (binding.fallback) |fallback| std.meta.eql(fallback, key) else false;
        if (std.meta.eql(binding.key, key) or fallback_matches) paintBinding(self, binding);
    }
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
            remember(self, key, null);
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
    if (job.key.kind == .artist or job.key.kind == .related) {
        job.texture = squareTexture(stream, pixels);
    } else if (gtk.gdk_pixbuf_new_from_stream_at_scale(stream, pixels, pixels, gtk.true_, null, &err)) |pixbuf| {
        defer gtk.g_object_unref(pixbuf);
        job.texture = gtk.gdk_texture_new_for_pixbuf(pixbuf);
    } else gtk.g_clear_error(&err);
    gtk.g_task_return_pointer(task, job, null);
}

fn squareTexture(stream: *gtk.GInputStream, pixels: c_int) ?*gtk.GdkTexture {
    var err: ?*gtk.GError = null;
    const bound = pixels * 3;
    const pixbuf = gtk.gdk_pixbuf_new_from_stream_at_scale(stream, bound, bound, gtk.true_, null, &err) orelse {
        gtk.g_clear_error(&err);
        return null;
    };
    defer gtk.g_object_unref(pixbuf);
    const width = gtk.gdk_pixbuf_get_width(pixbuf);
    const height = gtk.gdk_pixbuf_get_height(pixbuf);
    const side = @min(width, height);
    const square = gtk.gdk_pixbuf_new_subpixbuf(pixbuf, @divTrunc(width - side, 2), @divTrunc(height - side, 2), side, side);
    defer gtk.g_object_unref(square);
    const scaled = gtk.gdk_pixbuf_scale_simple(square, pixels, pixels, gtk.INTERP_BILINEAR) orelse return null;
    defer gtk.g_object_unref(scaled);
    return gtk.gdk_texture_new_for_pixbuf(scaled);
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
    remember(self, job.key, job.texture);
    startDecodes(self);
}
