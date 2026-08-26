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
`MutationPlan`. A plan deep-copies every action, path, change and value into
plan-owned storage at construction and seals that copy with a BLAKE3 content
digest; approval names the digest as well as the plan ID, and `beginExecution`
reverifies the seal. A caller therefore cannot preview one plan and execute
another through an alias it still holds.

Identity is `(size, modified_ns, quick_hash)`, where `quick_hash` is the
storage-wide definition — BLAKE3 over (first 64 KiB ‖ last 64 KiB ‖ size), in
`storage/quick_hash.zig` — so a same-size edit that preserves the modification
time is still detected. The mutation journal can persist only size and
modification time under the current schema, so recovery compares
`FileIdentity.Journaled`; in-process checks always compare the full identity.

Every action of a group is journaled before any filesystem work begins, and
journal writes raise SQLite durability for their own transaction, so a group is
always discoverable after a crash. Tag writes create and fsync a complete
same-filesystem stage, fsync the containing directory, and revalidate the source
identity immediately before the rename; both rename boundaries fsync the
directories they change, so the namespace can never lag the committed journal.
The exact original is retained as a journaled backup. Moves reject collisions and
use the same operation journal.

Logical groups undo in reverse action order. `LibraryDatabase.open` runs journal
recovery before the Library is returned to the caller — after the journal table
exists and before any later migration rewrites what a nonterminal operation
refers to — and refuses to open at all if recovery cannot reach a terminal state.
Recovery converges planned, staged, failed and interrupted-rollback operations
toward the original state. `rolled_back` is only recorded when the original file
is provably back in place or when nothing was ever staged; otherwise, and
whenever the target has changed externally, Orca retains every file, records
`needs_reconciliation`, and refuses to claim that rollback succeeded.
