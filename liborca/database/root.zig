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
pub const HealthIssueKind = repository.HealthIssueKind;
pub const HealthSeverity = repository.HealthSeverity;
pub const HealthIssueInput = repository.HealthIssueInput;
pub const HealthIssue = repository.HealthIssue;
pub const HealthIssuePage = repository.HealthIssuePage;
pub const HealthIssueRepository = repository.HealthIssueRepository;
pub const ProviderCacheEntry = repository.ProviderCacheEntry;
pub const ProviderCacheRepository = repository.ProviderCacheRepository;
pub const ScrobbleQueueEntry = repository.ScrobbleQueueEntry;
pub const ScrobbleQueueRepository = repository.ScrobbleQueueRepository;
pub const ProposalState = repository.ProposalState;
pub const IdentificationProposalInput = repository.IdentificationProposalInput;
pub const IdentificationProposal = repository.IdentificationProposal;
pub const IdentificationProposalRepository = repository.IdentificationProposalRepository;

test {
    _ = @import("library.zig");
    _ = @import("migrations.zig");
    _ = @import("repository.zig");
    _ = @import("sqlite.zig");
}
