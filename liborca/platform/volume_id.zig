const std = @import("std");

/// Crockford base32, the ULID alphabet: no I, L, O or U, so a key read off a
/// screen or a filename cannot be mistyped into a different volume.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// A ULID is 26 characters: 10 of millisecond timestamp, 16 of randomness.
pub const text_length = 26;

pub const Text = [text_length]u8;

/// Generate a ULID for a volume that has no filesystem UUID to borrow.
///
/// The timestamp half makes identifiers sort by first use, which is worth
/// having when a user is looking at a list of volumes; the random half is what
/// actually makes it unique.
pub fn generate(io: std.Io) Text {
    const nanoseconds: u96 = @intCast(@max(std.Io.Clock.real.now(io).nanoseconds, 0));
    const milliseconds: u48 = @truncate(nanoseconds / std.time.ns_per_ms);
    var randomness: [10]u8 = undefined;
    io.random(&randomness);
    return encode(milliseconds, randomness);
}

pub fn encode(milliseconds: u48, randomness: [10]u8) Text {
    var text: Text = undefined;
    var time_value = milliseconds;
    var index: usize = 10;
    while (index > 0) {
        index -= 1;
        text[index] = alphabet[@as(usize, @intCast(time_value & 0x1f))];
        time_value >>= 5;
    }
    var random_value: u80 = 0;
    for (randomness) |byte| random_value = (random_value << 8) | byte;
    index = text_length;
    while (index > 10) {
        index -= 1;
        text[index] = alphabet[@as(usize, @intCast(random_value & 0x1f))];
        random_value >>= 5;
    }
    return text;
}

test "generated volume identifiers are distinct and use the ULID alphabet" {
    const first = generate(std.testing.io);
    const second = generate(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    for (first) |character| try std.testing.expect(
        std.mem.indexOfScalar(u8, alphabet, character) != null,
    );
}

test "volume identifiers order by the millisecond they were minted" {
    const earlier = encode(1, @splat(0));
    const later = encode(2, @splat(0));
    try std.testing.expect(std.mem.lessThan(u8, &earlier, &later));
    try std.testing.expectEqualStrings("00000000020000000000000000", &later);
}
