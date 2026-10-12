const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");

const App = app.App;

pub const file_name = "clap_audio_int8.onnx";
pub const environment_variable = "ORCA_EMBEDDING_MODEL";

const user_pattern = "{s}/orca/models/" ++ file_name;
const bundled_pattern = "{s}/share/orca/models/" ++ file_name;

pub const Places = struct {
    override: ?[]const u8,
    user_data_dir: []const u8,
    executable_dir: ?[]const u8,
};

pub fn choose(buffer: []u8, places: Places, context: anytype) error{NoSpaceLeft}![]const u8 {
    if (places.override) |path| if (path.len != 0) return std.fmt.bufPrint(buffer, "{s}", .{path});
    const user = try std.fmt.bufPrint(buffer, user_pattern, .{places.user_data_dir});
    if (context.isFile(user)) return user;
    const prefix = std.fs.path.dirname(places.executable_dir orelse return user) orelse return user;
    var bundled_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bundled = std.fmt.bufPrint(&bundled_buffer, bundled_pattern, .{prefix}) catch return user;
    if (!context.isFile(bundled)) return user;
    return std.fmt.bufPrint(buffer, "{s}", .{bundled});
}

pub const Status = struct {
    title: [:0]const u8,
    subtitle: [:0]const u8,
    can_check_again: bool,
};

pub fn status(buffer: []u8, state: liborca.EmbeddingModelState, path: []const u8) Status {
    return switch (state) {
        .ready => .{ .title = "Model installed", .subtitle = terminated(buffer, path), .can_check_again = false },
        .missing => .{
            .title = "Model not installed",
            .subtitle = std.fmt.bufPrintSentinel(buffer, "Put {s} in {s}, then check again.", .{
                std.fs.path.basename(path),
                std.fs.path.dirname(path) orelse ".",
            }, 0) catch "",
            .can_check_again = true,
        },
        .wrong_file => .{ .title = "That file is not Orca's model", .subtitle = terminated(buffer, path), .can_check_again = true },
        .unusable => .{ .title = "The model could not be loaded", .subtitle = terminated(buffer, path), .can_check_again = true },
        .built_without => .{
            .title = "Not available in this build",
            .subtitle = "This build of Orca was made without ONNX Runtime.",
            .can_check_again = false,
        },
    };
}

fn terminated(buffer: []u8, text: []const u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buffer, "{s}", .{text}, 0) catch "";
}

const Files = struct {
    io: std.Io,

    pub fn isFile(self: Files, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return stat.kind == .file;
    }
};

pub fn apply(self: *App) void {
    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_dir: ?[]const u8 = if (std.process.executableDirPath(self.io, &executable_buffer)) |length|
        executable_buffer[0..length]
    else |_|
        null;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = choose(&buffer, .{
        .override = self.embedding_model_override,
        .user_data_dir = std.mem.span(gtk.g_get_user_data_dir()),
        .executable_dir = executable_dir,
    }, Files{ .io = self.io }) catch |err| {
        std.log.warn("The audio-embedding model's path is too long to use ({t})", .{err});
        return;
    };
    self.embedding_model_path.set(self.allocator, path);
    self.runtime.setEmbeddingModelPath(path) catch |err|
        std.log.warn("Could not check the audio-embedding model at {s} ({t})", .{ path, err });
}

const TestFiles = struct {
    present: []const []const u8,

    pub fn isFile(self: TestFiles, path: []const u8) bool {
        for (self.present) |candidate| if (std.mem.eql(u8, candidate, path)) return true;
        return false;
    }
};

const test_places: Places = .{ .override = null, .user_data_dir = "/data", .executable_dir = "/prefix/bin" };
const test_user = "/data/orca/models/clap_audio_int8.onnx";
const test_bundled = "/prefix/share/orca/models/clap_audio_int8.onnx";

fn expectChosen(expected: []const u8, places: Places, present: []const []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try choose(&buffer, places, TestFiles{ .present = present }));
}

test "choose_overrideSet_winsEvenWithNoFileThere" {
    var places = test_places;
    places.override = "/elsewhere/model.onnx";
    try expectChosen("/elsewhere/model.onnx", places, &.{ test_user, test_bundled });
}

test "choose_emptyOverride_isIgnored" {
    var places = test_places;
    places.override = "";
    try expectChosen(test_user, places, &.{test_user});
}

test "choose_userAndBundledPresent_prefersTheUsers" {
    try expectChosen(test_user, test_places, &.{ test_user, test_bundled });
}

test "choose_onlyBundledPresent_usesTheBundled" {
    try expectChosen(test_bundled, test_places, &.{test_bundled});
}

test "choose_nothingPresent_namesTheUsersPlace" {
    try expectChosen(test_user, test_places, &.{});
    var places = test_places;
    places.executable_dir = null;
    try expectChosen(test_user, places, &.{});
}

test "choose_pathLongerThanTheBuffer_fails" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, choose(&buffer, test_places, TestFiles{ .present = &.{} }));
}

test "status_missing_saysWhereTheFileGoes" {
    var buffer: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const row = status(&buffer, .missing, test_user);
    try std.testing.expectEqualStrings("Model not installed", row.title);
    try std.testing.expectEqualStrings("Put clap_audio_int8.onnx in /data/orca/models, then check again.", row.subtitle);
    try std.testing.expect(row.can_check_again);
    try std.testing.expectEqualStrings(
        "Put model.onnx in /elsewhere, then check again.",
        status(&buffer, .missing, "/elsewhere/model.onnx").subtitle,
    );
}

test "status_fileStates_showThePathAndOfferACheckOnlyWhenItCanHelp" {
    var buffer: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const ready = status(&buffer, .ready, test_user);
    try std.testing.expectEqualStrings("Model installed", ready.title);
    try std.testing.expectEqualStrings(test_user, ready.subtitle);
    try std.testing.expect(!ready.can_check_again);
    const wrong = status(&buffer, .wrong_file, test_user);
    try std.testing.expectEqualStrings("That file is not Orca's model", wrong.title);
    try std.testing.expectEqualStrings(test_user, wrong.subtitle);
    try std.testing.expect(wrong.can_check_again);
    const unusable = status(&buffer, .unusable, test_user);
    try std.testing.expectEqualStrings("The model could not be loaded", unusable.title);
    try std.testing.expect(unusable.can_check_again);
    const without = status(&buffer, .built_without, test_user);
    try std.testing.expectEqualStrings("Not available in this build", without.title);
    try std.testing.expectEqualStrings("This build of Orca was made without ONNX Runtime.", without.subtitle);
    try std.testing.expect(!without.can_check_again);
}
