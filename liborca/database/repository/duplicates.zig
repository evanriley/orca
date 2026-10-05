const std = @import("std");
const content_hash = @import("../../storage/content_hash.zig");

/// One file a duplicate scan will examine, and the two keys it can be
/// bucketed by.
///
/// Both are nullable and both nulls mean something the scan must report rather
/// than swallow: no `audio_hash` means the analysis pass has never decoded
/// this file, so nothing can be said about what it sounds like; no
/// `duration_ms` means no scan or probe has ever established how long it is,
/// so it cannot be placed in a duration window.
pub const DuplicateCandidate = struct {
    id: i64,
    audio_hash: ?[32]u8,
    /// `fingerprint.AudioHashTier` of `audio_hash`; only tier 1 is evidence of
    /// exact audio.
    audio_hash_tier: ?u8 = null,
    duration_ms: ?i64,
    /// The content hash the Library recorded, which is the key its stored
    /// fingerprint is filed under. Null for a file whose bytes no analysis or
    /// scan has hashed whole.
    source_identity: ?content_hash.Digest,
};

/// A file inside a duplicate scan's plausible bucket, with everything needed
/// to compare against it: its stored fingerprint is keyed on
/// `source_identity`, and `audio_hash` says whether the exact bucket has
/// already accounted for it.
pub const DuplicatePeer = struct {
    id: i64,
    source_identity: ?content_hash.Digest,
    audio_hash: ?[32]u8,
    audio_hash_tier: ?u8 = null,
};

pub const DuplicateCandidatePage = struct {
    allocator: std.mem.Allocator,
    items: []DuplicateCandidate,

    pub fn deinit(self: DuplicateCandidatePage) void {
        self.allocator.free(self.items);
    }
};
