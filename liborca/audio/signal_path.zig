const pcm = @import("pcm.zig");
const processing = @import("processing.zig");

pub const Scope = enum { player, zone };

pub const Node = struct {
    scope: Scope,
    name: []const u8,
    changes_samples: bool,
    realtime_safe: bool,
    algorithmic_latency_frames: u32,
};

pub const Reason = enum {
    sample_processing,
    sample_rate_conversion,
    channel_layout_conversion,
    sample_format_conversion,
    lossy_source,
};

pub const max_reasons = @typeInfo(Reason).@"enum".field_names.len;

pub fn Report(comptime capacity: usize) type {
    return struct {
        bit_perfect_eligible: bool = true,
        direct_rt_eligible: bool = true,
        nodes_truncated: bool = false,
        widened_exactly: bool = false,
        nodes: [capacity]Node = undefined,
        node_count: usize = 0,
        reasons: [max_reasons]Reason = undefined,
        reason_count: usize = 0,
        algorithmic_latency_frames: u32 = 0,

        const Self = @This();

        fn addNodes(self: *Self, scope: Scope, processors: []const processing.Processor) void {
            for (processors) |processor| {
                if (self.node_count < capacity) {
                    self.nodes[self.node_count] = .{
                        .scope = scope,
                        .name = processor.metadata.name,
                        .changes_samples = processor.metadata.changes_samples,
                        .realtime_safe = processor.metadata.realtime_safe,
                        .algorithmic_latency_frames = processor.metadata.algorithmic_latency_frames,
                    };
                    self.node_count += 1;
                } else self.nodes_truncated = true;
                self.algorithmic_latency_frames +|= processor.metadata.algorithmic_latency_frames;
                if (processor.metadata.changes_samples) self.addReason(.sample_processing);
                if (processor.metadata.changes_sample_rate)
                    self.addReason(.sample_rate_conversion);
                if (processor.metadata.changes_channel_layout)
                    self.addReason(.channel_layout_conversion);
                self.direct_rt_eligible = self.direct_rt_eligible and processor.metadata.realtime_safe;
            }
        }

        fn addReason(self: *Self, reason: Reason) void {
            for (self.reasons[0..self.reason_count]) |existing| {
                if (existing == reason) return;
            }
            self.reasons[self.reason_count] = reason;
            self.reason_count += 1;
            self.bit_perfect_eligible = false;
        }
    };
}

pub fn inspect(
    comptime capacity: usize,
    source: pcm.Format,
    output: pcm.Format,
    player_nodes: []const processing.Processor,
    zone_nodes: []const processing.Processor,
) Report(capacity) {
    var report: Report(capacity) = .{};
    report.addNodes(.player, player_nodes);
    report.addNodes(.zone, zone_nodes);
    if (source.sample_rate != output.sample_rate) report.addReason(.sample_rate_conversion);
    if (source.channels != output.channels) report.addReason(.channel_layout_conversion);
    if (source.sample_format != output.sample_format or
        source.bits_per_sample != output.bits_per_sample or
        source.bytes_per_frame != output.bytes_per_frame)
    {
        if (widensExactly(source.sample_format, output.sample_format))
            report.widened_exactly = true
        else
            report.addReason(.sample_format_conversion);
    }
    return report;
}

fn widensExactly(source: pcm.SampleFormat, output: pcm.SampleFormat) bool {
    if (output != .float_32) return false;
    return switch (source) {
        .unsigned_8, .signed_8, .signed_16, .signed_24 => true,
        else => false,
    };
}

test "signal path explains bit-perfect eligibility" {
    const std = @import("std");
    const format: pcm.Format = .{
        .sample_format = .float_32,
        .channels = 2,
        .sample_rate = 48_000,
        .bits_per_sample = 32,
        .bytes_per_frame = 8,
    };
    var meter: processing.Meter = .{};
    var meter_nodes = [_]processing.Processor{meter.processor()};
    const direct = inspect(2, format, format, &meter_nodes, &.{});
    try std.testing.expect(direct.bit_perfect_eligible);

    var gain: processing.Gain = .{};
    var gain_nodes = [_]processing.Processor{gain.processor()};
    const processed = inspect(2, format, format, &gain_nodes, &.{});
    try std.testing.expect(!processed.bit_perfect_eligible);
    try std.testing.expectEqualSlices(Reason, &.{.sample_processing}, processed.reasons[0..1]);
}

fn testFormat(sample_format: pcm.SampleFormat, bits_per_sample: u16, bytes_per_sample: u16) pcm.Format {
    return .{
        .sample_format = sample_format,
        .channels = 2,
        .sample_rate = 44_100,
        .bits_per_sample = bits_per_sample,
        .bytes_per_frame = 2 * bytes_per_sample,
    };
}

test "widening an integer source of 24 bits or fewer to float32 is exact and stays eligible" {
    const std = @import("std");
    const output = testFormat(.float_32, 32, 4);
    const sources = [_]pcm.Format{
        testFormat(.unsigned_8, 8, 1),
        testFormat(.signed_16, 16, 2),
        testFormat(.signed_24, 20, 3),
        testFormat(.signed_24, 24, 3),
    };
    for (sources) |source| {
        const report = inspect(1, source, output, &.{}, &.{});
        try std.testing.expect(report.bit_perfect_eligible);
        try std.testing.expect(report.widened_exactly);
        try std.testing.expectEqual(@as(usize, 0), report.reason_count);
    }
}

test "a source already in the output format is not a widening" {
    const std = @import("std");
    const format = testFormat(.float_32, 32, 4);
    const report = inspect(1, format, format, &.{}, &.{});
    try std.testing.expect(report.bit_perfect_eligible);
    try std.testing.expect(!report.widened_exactly);
}

test "a 32-bit integer or float64 source reaching float32 is a sample format conversion" {
    const std = @import("std");
    const output = testFormat(.float_32, 32, 4);
    for ([_]pcm.Format{ testFormat(.signed_32, 32, 4), testFormat(.float_64, 64, 8) }) |source| {
        const report = inspect(1, source, output, &.{}, &.{});
        try std.testing.expect(!report.bit_perfect_eligible);
        try std.testing.expect(!report.widened_exactly);
        try std.testing.expectEqualSlices(
            Reason,
            &.{.sample_format_conversion},
            report.reasons[0..report.reason_count],
        );
    }
}
