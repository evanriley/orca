# Metadata layers

Orca keeps three concepts separate:

- `ObservedFileMetadata` records what a source file currently says.
- `OrcaMetadata` records preferred values, user edits, locks, and later provider
  proposals without mutating that file.
- `EffectiveMetadata` is a resolved view under an explicit preference policy.

Every value carries provenance. A user-locked Orca value outranks automatic
resolution even when the general policy prefers file tags.

Format readers and writers terminate at this boundary. The ID3v1/v1.1 mapping
is deliberately conservative: text that cannot be represented without loss is
rejected. The native FLAC writer maps canonical fields to Vorbis comments,
preserves unknown comments and metadata blocks, and leaves audio frames
byte-for-byte unchanged. Format-specific genre numbers, fixed-width storage,
and comment keys do not define the canonical metadata model.

Scanner observations are persisted in `observed_file_metadata`, keyed to the
physical observed file record and updated in the same bounded transaction. They
do not update Track metadata and never cause a source-file write.

## File mutation

File writes and moves only execute from an explicitly approved immutable
`MutationPlan`. Every action records source identity and intended after-identity
in SQLite before the filesystem changes. Tag writes create and fsync a complete
same-filesystem stage, retain the exact original as a journaled backup, and can
be undone after validating the current after-state. Moves reject collisions and
use the same operation journal.

Logical groups undo in reverse action order. Startup recovery converges planned
and staged operations toward the original state. If the target has changed
externally, Orca retains every file, records `needs_reconciliation`, and refuses
to claim that rollback succeeded.
