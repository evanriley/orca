//! A packet decoder: what a container-driven `Decoder` (MP4) needs from the
//! codec inside it. Containers own framing, timing and trimming; an engine
//! only turns one packet into interleaved float frames.

pub const Engine = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// Most frames one packet can decode to; sizes the caller's buffer.
    max_packet_frames: u32,
    channels: u16,
    sample_rate: u32,
    /// Sample width of a lossless encoding, or null for a transform codec.
    bits_per_sample: ?u16,
    /// Packets that must be decoded and discarded before a seek target for
    /// the output to be correct. Transform codecs overlap adjacent packets.
    preroll_packets: u32,

    pub const VTable = struct {
        decode: *const fn (*anyopaque, []const u8, []f32) anyerror!u32,
        reset: *const fn (*anyopaque) void,
        deinit: *const fn (*anyopaque) void,
        /// Present only for a lossless integer encoding: the packet's exact
        /// samples, left-justified in 32 bits.
        decode_i32: ?*const fn (*anyopaque, []const u8, []i32) anyerror!u32 = null,
    };

    pub fn decode(self: Engine, packet: []const u8, output: []f32) !u32 {
        return self.vtable.decode(self.context, packet, output);
    }

    pub fn hasIntegerSamples(self: Engine) bool {
        return self.vtable.decode_i32 != null;
    }

    pub fn decodeI32(self: Engine, packet: []const u8, output: []i32) !u32 {
        const decode_i32 = self.vtable.decode_i32 orelse return error.NoIntegerSamples;
        return decode_i32(self.context, packet, output);
    }

    pub fn reset(self: Engine) void {
        self.vtable.reset(self.context);
    }

    pub fn deinit(self: Engine) void {
        self.vtable.deinit(self.context);
    }
};
