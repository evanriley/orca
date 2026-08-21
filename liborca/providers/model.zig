const std = @import("std");

pub const Query = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    fingerprint: ?[]const u16 = null,
    /// An externally generated Chromaprint string suitable for AcoustID.
    acoustid_fingerprint: ?[]const u8 = null,
    embedded_provider_id: ?[]const u8 = null,
};

pub const Candidate = struct {
    allocator: std.mem.Allocator,
    provider: []u8,
    provider_id: []u8,
    title: []u8,
    artist: []u8,
    album: []u8,
    duration_ms: ?u64 = null,
    track_number: ?u32 = null,
    fingerprint_similarity: ?f32 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        provider: []const u8,
        provider_id: []const u8,
        title: []const u8,
        artist: []const u8,
        album: []const u8,
    ) !Candidate {
        const owned_provider = try allocator.dupe(u8, provider);
        errdefer allocator.free(owned_provider);
        const owned_id = try allocator.dupe(u8, provider_id);
        errdefer allocator.free(owned_id);
        const owned_title = try allocator.dupe(u8, title);
        errdefer allocator.free(owned_title);
        const owned_artist = try allocator.dupe(u8, artist);
        errdefer allocator.free(owned_artist);
        return .{
            .allocator = allocator,
            .provider = owned_provider,
            .provider_id = owned_id,
            .title = owned_title,
            .artist = owned_artist,
            .album = try allocator.dupe(u8, album),
        };
    }

    pub fn deinit(self: Candidate) void {
        self.allocator.free(self.provider);
        self.allocator.free(self.provider_id);
        self.allocator.free(self.title);
        self.allocator.free(self.artist);
        self.allocator.free(self.album);
    }
};

pub const CandidateList = struct {
    allocator: std.mem.Allocator,
    items: []Candidate,

    pub fn deinit(self: CandidateList) void {
        for (self.items) |candidate| candidate.deinit();
        self.allocator.free(self.items);
    }
};

pub const Provider = struct {
    id: []const u8,
    context: *anyopaque,
    search_fn: *const fn (*anyopaque, std.mem.Allocator, Query) anyerror!CandidateList,

    pub fn search(self: Provider, allocator: std.mem.Allocator, query: Query) !CandidateList {
        return self.search_fn(self.context, allocator, query);
    }
};

pub const Confidence = enum { low, medium, high };

pub const ScoredCandidate = struct {
    candidate_index: usize,
    score: f32,
    confidence: Confidence,
};
