const std = @import("std");
const processing = @import("processing.zig");

const slot_count = 3;
const no_reader = std.math.maxInt(u8);

/// Triple-buffered structural publication for one render lane. The control
/// lane writes only a slot that is neither active nor being read, then performs
/// one release-store. The RT lane claims and validates a slot at each block
/// boundary; it never allocates, locks, waits, or retries unboundedly.
pub fn PublishedChain(comptime capacity: usize) type {
    return struct {
        slots: [slot_count]Slot = @splat(.{}),
        active_slot: std.atomic.Value(u8) = .init(0),
        reader_slot: std.atomic.Value(u8) = .init(no_reader),
        generation: std.atomic.Value(u64) = .init(0),
        observed_generation: std.atomic.Value(u64) = .init(0),
        reset_generation: std.atomic.Value(u64) = .init(0),
        observed_reset_generation: u64 = 0,

        const Self = @This();
        const Slot = struct {
            processors: [capacity]processing.Processor = undefined,
            len: usize = 0,
            generation: u64 = 0,
        };

        pub fn publish(self: *Self, processors: []const processing.Processor) !u64 {
            if (processors.len > capacity) return error.ProcessingChainFull;
            const active = self.active_slot.load(.acquire);
            const reader = self.reader_slot.load(.acquire);
            var selected: ?u8 = null;
            for (0..slot_count) |index| {
                if (index != active and index != reader) {
                    selected = @intCast(index);
                    break;
                }
            }
            const slot_index = selected orelse return error.GraphPublicationBusy;
            const next_generation = self.generation.load(.monotonic) +% 1;
            const slot = &self.slots[slot_index];
            @memcpy(slot.processors[0..processors.len], processors);
            slot.len = processors.len;
            slot.generation = next_generation;
            self.generation.store(next_generation, .release);
            self.active_slot.store(slot_index, .release);
            return next_generation;
        }

        pub fn requestReset(self: *Self) void {
            _ = self.reset_generation.fetchAdd(1, .release);
        }

        /// Single-render-lane block operation.
        pub fn process(self: *Self, samples: []f32, frames: u32, channels: u16) void {
            // Two bounded attempts avoid waiting if the control lane publishes
            // repeatedly; a highly contended block passes through unchanged.
            var attempts: u8 = 0;
            while (attempts < 2) : (attempts += 1) {
                const slot_index = self.active_slot.load(.acquire);
                self.reader_slot.store(slot_index, .release);
                if (self.active_slot.load(.acquire) != slot_index) continue;
                const slot = &self.slots[slot_index];
                const requested_reset = self.reset_generation.load(.acquire);
                if (requested_reset != self.observed_reset_generation) {
                    for (slot.processors[0..slot.len]) |processor| processor.reset();
                    self.observed_reset_generation = requested_reset;
                }
                for (slot.processors[0..slot.len]) |processor|
                    processor.process(samples, frames, channels);
                self.observed_generation.store(slot.generation, .release);
                self.reader_slot.store(no_reader, .release);
                return;
            }
            self.reader_slot.store(no_reader, .release);
        }

        pub fn currentGeneration(self: *const Self) u64 {
            return self.generation.load(.acquire);
        }

        /// Once this reaches a publication generation, contexts referenced
        /// only by older chains may be reclaimed on the control lane.
        pub fn observedGeneration(self: *const Self) u64 {
            return self.observed_generation.load(.acquire);
        }
    };
}

test "prepared DSP chains publish at block boundaries" {
    var first: processing.Gain = .{ .linear = .init(0.5) };
    var second: processing.Gain = .{ .linear = .init(0.25) };
    var graph: PublishedChain(2) = .{};
    const first_nodes = [_]processing.Processor{first.processor()};
    try std.testing.expectEqual(@as(u64, 1), try graph.publish(&first_nodes));
    var block = [_]f32{ 1, 1 };
    graph.process(&block, 2, 1);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, &block);

    const second_nodes = [_]processing.Processor{second.processor()};
    try std.testing.expectEqual(@as(u64, 2), try graph.publish(&second_nodes));
    block = @splat(1);
    graph.process(&block, 2, 1);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25 }, &block);
    try std.testing.expectEqual(@as(u64, 2), graph.observedGeneration());
}

test "publication never overwrites a slot claimed by the render lane" {
    var graph: PublishedChain(1) = .{};
    graph.reader_slot.store(1, .release);
    _ = try graph.publish(&.{});
    try std.testing.expectEqual(@as(u8, 2), graph.active_slot.load(.acquire));
}
