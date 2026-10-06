pub const SampleFormat = enum {
    unsigned_8,
    signed_8,
    signed_16,
    signed_24,
    signed_32,
    float_32,
    float_64,
};

pub const Format = struct {
    sample_format: SampleFormat,
    channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    bytes_per_frame: u16,

    pub fn validate(self: Format) !void {
        if (self.channels == 0 or self.sample_rate == 0 or self.bytes_per_frame == 0) {
            return error.InvalidPcmFormat;
        }
    }
};
