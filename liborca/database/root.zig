pub const library = @import("library.zig");
pub const migrations = @import("migrations.zig");
pub const repository = @import("repository.zig");
pub const sqlite = @import("sqlite.zig");

pub const LibraryDatabase = library.LibraryDatabase;
pub const TrackInput = repository.TrackInput;
pub const TrackPage = repository.TrackPage;
pub const TrackRepository = repository.TrackRepository;
pub const ObservedFileInput = repository.ObservedFileInput;
pub const ObservedFileRepository = repository.ObservedFileRepository;
pub const OrcaMetadataInput = repository.OrcaMetadataInput;
pub const OrcaMetadataRepository = repository.OrcaMetadataRepository;
pub const MutationJournalRepository = repository.MutationJournalRepository;
pub const MutationOperationInput = repository.MutationOperationInput;
pub const MutationState = repository.MutationState;
pub const AnalysisCacheKey = repository.AnalysisCacheKey;
pub const AnalysisCacheRepository = repository.AnalysisCacheRepository;

test {
    _ = @import("library.zig");
    _ = @import("migrations.zig");
    _ = @import("repository.zig");
    _ = @import("sqlite.zig");
}
