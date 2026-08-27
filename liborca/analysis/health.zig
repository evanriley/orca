const std = @import("std");
const database = @import("../database/root.zig");
const diagnostics = @import("diagnostics.zig");

pub const Facts = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    track_number: ?u32 = null,
    artwork_present: bool = false,
    sample_rate: ?u32 = null,
    frame_count: ?u64 = null,
    audio: ?*const diagnostics.Result = null,
    corrupt_details: ?[]const u8 = null,
    exact_duplicate_path: ?[]const u8 = null,
    likely_duplicate_path: ?[]const u8 = null,
    /// How closely the likely duplicate's temporal fingerprint matched, as a
    /// percentage. A likely match is a claim that will sometimes be wrong, so
    /// the number behind it travels with it rather than being discarded at the
    /// point the claim is made.
    likely_duplicate_similarity: f32 = 0,
};

/// The one wording for each duplicate finding.
///
/// Shared by `evaluate` and by `library/duplicate_pass.zig`, which is what
/// actually produces these two kinds at library scale. Two spellings would
/// drift, and `orca-cli health` would describe the same finding two ways
/// depending on which pass filed it.
pub const exact_duplicate_details = "content also appears at {s}";
pub const likely_duplicate_details = "audio resembles {s} ({d:.1}% match)";

pub const Evaluation = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayList(database.HealthIssueInput) = .empty,
    owned_details: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Evaluation) void {
        for (self.owned_details.items) |details| self.allocator.free(details);
        self.owned_details.deinit(self.allocator);
        self.issues.deinit(self.allocator);
        self.* = undefined;
    }

    fn add(
        self: *Evaluation,
        kind: database.HealthIssueKind,
        severity: database.HealthSeverity,
        details: []const u8,
    ) !void {
        try self.issues.append(self.allocator, .{
            .kind = kind,
            .severity = severity,
            .details = details,
        });
    }

    fn addFormatted(
        self: *Evaluation,
        kind: database.HealthIssueKind,
        severity: database.HealthSeverity,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        const details = try std.fmt.allocPrint(self.allocator, format, arguments);
        errdefer self.allocator.free(details);
        try self.owned_details.append(self.allocator, details);
        try self.add(kind, severity, details);
    }
};

pub fn evaluate(allocator: std.mem.Allocator, facts: Facts) !Evaluation {
    var evaluation: Evaluation = .{ .allocator = allocator };
    errdefer evaluation.deinit();
    if (missing(facts.title) or missing(facts.artist) or missing(facts.album))
        try evaluation.add(.missing_metadata, .warning, "title, artist, or album is missing");
    if (facts.track_number == null)
        try evaluation.add(.missing_track_number, .information, "track number is missing");
    if (!missing(facts.album) and missing(facts.album_artist))
        try evaluation.add(.album_artist_anomaly, .information, "album artist is missing");
    if (!facts.artwork_present)
        try evaluation.add(.artwork_problem, .information, "artwork is missing");

    if (facts.corrupt_details) |details| {
        try evaluation.add(.corrupt_audio, .error_severity, details);
    } else if (facts.audio) |audio| {
        if (audio.clipped_samples > 0) try evaluation.addFormatted(
            .clipping,
            .warning,
            "{d} samples reach or exceed full scale",
            .{audio.clipped_samples},
        );
        if (facts.frame_count) |frames| {
            if (frames > 0 and audio.silent_frames * 5 > frames) try evaluation.addFormatted(
                .excessive_silence,
                .warning,
                "{d:.1}% of frames are silent",
                .{100 * @as(f64, @floatFromInt(audio.silent_frames)) /
                    @as(f64, @floatFromInt(frames))},
            );
        }
        if (audio.integrated_lufs == null)
            try evaluation.add(.missing_analysis, .information, "track is too short or silent for loudness analysis");
    } else {
        try evaluation.add(.missing_analysis, .information, "audio analysis has not run");
    }
    if (facts.sample_rate) |rate| if (rate < 32_000) try evaluation.addFormatted(
        .technical_anomaly,
        .information,
        "unusually low sample rate: {d} Hz",
        .{rate},
    );
    if (facts.exact_duplicate_path) |path| try evaluation.addFormatted(
        .exact_duplicate,
        .warning,
        exact_duplicate_details,
        .{path},
    );
    if (facts.likely_duplicate_path) |path| try evaluation.addFormatted(
        .likely_duplicate,
        .information,
        likely_duplicate_details,
        .{ path, facts.likely_duplicate_similarity },
    );
    return evaluation;
}

fn missing(value: ?[]const u8) bool {
    return value == null or std.mem.trim(u8, value.?, " \t\r\n").len == 0;
}

test "health evaluation persists metadata and audio diagnostics" {
    const allocator = std.testing.allocator;
    const waveform = try allocator.alloc(diagnostics.WaveformBucket, 1);
    waveform[0] = .{ .minimum = -1, .maximum = 1 };
    const audio: diagnostics.Result = .{
        .allocator = allocator,
        .integrated_lufs = -12,
        .replay_gain_db = -6,
        .sample_peak = 1.1,
        .rms = 0.2,
        .clipped_samples = 3,
        .silent_frames = 300,
        .leading_silence_frames = 100,
        .trailing_silence_frames = 200,
        .waveform = waveform,
    };
    defer audio.deinit();
    var evaluation = try evaluate(allocator, .{
        .title = "Track",
        .album = "Album",
        .frame_count = 1000,
        .sample_rate = 22_050,
        .audio = &audio,
    });
    defer evaluation.deinit();
    var library = try database.LibraryDatabase.open(
        allocator,
        std.testing.io,
        "file:orca-health-evaluator?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .size_bytes = 4096 });
    try library.health_issues.replaceFile(file_id, evaluation.issues.items);
    try std.testing.expectEqual(@as(u64, 7), try library.health_issues.count());
}

test "decoder failures become health diagnostics" {
    var evaluation = try evaluate(std.testing.allocator, .{
        .title = "Damaged track",
        .artist = "Orca",
        .album = "Generated",
        .album_artist = "Orca",
        .track_number = 1,
        .artwork_present = true,
        .corrupt_details = "decoder rejected the frame checksum",
    });
    defer evaluation.deinit();
    try std.testing.expectEqual(@as(usize, 1), evaluation.issues.items.len);
    try std.testing.expectEqual(database.HealthIssueKind.corrupt_audio, evaluation.issues.items[0].kind);
    try std.testing.expectEqual(database.HealthSeverity.error_severity, evaluation.issues.items[0].severity);
}
