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
};

pub fn Report(comptime capacity: usize) type {
    return struct {
        bit_perfect_eligible: bool = true,
        nodes: [capacity]Node = undefined,
        node_count: usize = 0,
        reasons: [4]Reason = undefined,
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
                }
                self.algorithmic_latency_frames +|= processor.metadata.algorithmic_latency_frames;
                if (processor.metadata.changes_samples) self.addReason(.sample_processing);
                if (processor.metadata.changes_sample_rate)
                    self.addReason(.sample_rate_conversion);
                if (processor.metadata.changes_channel_layout)
                    self.addReason(.channel_layout_conversion);
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
        report.addReason(.sample_format_conversion);
    return report;
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
