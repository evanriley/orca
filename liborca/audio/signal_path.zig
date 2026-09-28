const pcm = @import("pcm.zig");
const processing = @import("processing.zig");
const resampler_api = @import("resampler.zig");
const zone = @import("zone.zig");

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
        direct_rt_eligible: bool = true,
        nodes_truncated: bool = false,
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

        pub fn applyAlgorithmicLatency(self: *const Self, latency: *zone.Latency) void {
            latency.dsp_frames = self.algorithmic_latency_frames;
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
    return inspectWithResampler(capacity, source, output, player_nodes, zone_nodes, null);
}

pub fn inspectWithResampler(
    comptime capacity: usize,
    source: pcm.Format,
    output: pcm.Format,
    player_nodes: []const processing.Processor,
    zone_nodes: []const processing.Processor,
    resampler: ?resampler_api.Metadata,
) Report(capacity) {
    var report: Report(capacity) = .{};
    report.addNodes(.player, player_nodes);
    report.addNodes(.zone, zone_nodes);
    if (resampler) |metadata| {
        if (report.node_count < capacity) {
            report.nodes[report.node_count] = .{
                .scope = .zone,
                .name = metadata.name,
                .changes_samples = true,
                .realtime_safe = metadata.realtime_safe,
                .algorithmic_latency_frames = metadata.algorithmic_latency_frames,
            };
            report.node_count += 1;
        } else report.nodes_truncated = true;
        report.algorithmic_latency_frames +|= metadata.algorithmic_latency_frames;
        report.direct_rt_eligible = report.direct_rt_eligible and metadata.realtime_safe;
        report.addReason(.sample_rate_conversion);
    }
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

    var linear = try resampler_api.Linear.init(48_000, 96_000, 2);
    const resampled = inspectWithResampler(
        2,
        format,
        .{
            .sample_format = .float_32,
            .channels = 2,
            .sample_rate = 96_000,
            .bits_per_sample = 32,
            .bytes_per_frame = 8,
        },
        &.{},
        &.{},
        linear.resampler().metadata,
    );
    try std.testing.expectEqual(@as(u32, 1), resampled.algorithmic_latency_frames);
    try std.testing.expectEqual(@as(usize, 1), resampled.reason_count);
    var latency: zone.Latency = .{
        .requested_frames = 128,
        .backend_quantum_frames = 128,
        .render_ahead_frames = 128,
        .dsp_frames = 0,
        .hardware_frames = 64,
        .graph_rate_hz = null,
    };
    resampled.applyAlgorithmicLatency(&latency);
    try std.testing.expectEqual(@as(u32, 1), latency.dsp_frames);
    try std.testing.expectEqual(@as(u64, 193), latency.knownTotalFrames());
}
