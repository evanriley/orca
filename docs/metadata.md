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

## Cover art

Artwork is two questions, and they are answered in two places.

*Does this file have a cover, and how big is it* is an **observation**. The
scanner records `artwork_mime_type`, `artwork_byte_size` and `artwork_kind` in
`observed_file_tags` from the same tag read that produces every other observed
field, and it never reads the image.

*Give me the cover* is a **fetch**. `metadata/artwork.zig` sniffs the container,
steps over a leading ID3v2 tag through the same `OffsetSource` view the codec
registry uses, and hands the request to `id3v2.readPicture` or
`vorbis_comment.readPicture`. `APIC` frame flags and `PICTURE` block layouts
terminate in those two readers exactly as tag parsing does; what leaves them is
bytes, a media type and an `ArtworkKind`. Within a file the first front cover
wins, and with no front cover present the first usable picture is taken — the
same preference the observation records, so the fetch cannot hand back a
different picture from the one the scan described.

Both halves of each reader parse the frame or block through one function, so an
observation and a fetch cannot disagree about which bytes are the image.

- **The media type comes from the bytes, not from the claim.** 93 files in the
  22,060-file reference library declare `image/jpg`, which is not a media type,
  24 declare nothing at all, and one album's covers are 5.3 MB animated GIFs
  behind an empty declaration. `EmbeddedImage.mime_type` is what the magic bytes
  say; a payload that matches none of PNG, JPEG, GIF, WebP or BMP is refused as
  `UnrecognizedArtworkImage` rather than passed to a platform image decoder.
  `Artwork.mime_type`, being an observation, still records the claim.
- **Bounded at 12 MiB, checked against the declaration.** The whole image is
  held in memory at once, so `model.max_image_bytes` is compared with the length
  a container declares *before* anything is allocated to honour it. The value
  sits below both containers' own ceilings — a FLAC `PICTURE` length is 24 bits
  and `id3v2.max_tag_bytes` is 16 MiB — because a bound above them could never
  fire, and above every honest cover: the largest in the reference library is
  11.29 MiB, the median is 157 KB.
- **Read from the file, never stored and not cached.** 19,031 of the reference
  library's 22,060 files carry a readable cover, totalling 6.09 GB. Storing
  decoded images in the Library would multiply its size by roughly two hundred,
  for data that already exists on disk and would go stale the moment a file is
  re-tagged. Reading on demand costs one open and one read, and it is right by
  construction — a track whose stored observation predates the current reader
  still yields its cover, because the row is not consulted.
- **There is no cache yet, deliberately.** A bounded per-Release cache is the
  obvious next step and is measurably cheaper than a per-Track one, since an
  album's tracks share one cover. It is not here because nothing needs it: the
  only consumer is the now-playing widget, which loads one image per track
  change — minutes apart. Adding a correct, bounded, invalidated cache with no
  caller is precisely the shape of defect this codebase is recovering from. Add
  it with the grid view that needs it.

### What a Release's artwork is

**The cover of its first track, in listening order, that has one.** Real tag
data disagrees within an album, so the rule has to choose, and it is chosen to
be stable, cheap and unsurprising:

- Candidates are ordered by disc, then track number, then `tracks.id` — the
  unique order `tracks_position` already enforces — so the same Release answers
  the same way on every run.
- Candidates are restricted to files the last scan *observed* artwork in, which
  is what makes a Release with no covers cost one indexed query and zero file
  opens. The observation selects; it does not decide, because the bytes are
  still read from the file.
- At most eight candidates are opened. That bound is only reached when a
  Release's leading tracks each declare a cover that no longer reads.

A majority vote or "the largest image" would both have to open every file in
the Release, and both would change their answer when one track is re-tagged.

Reachable as `OrcaRuntime.libraryTrackArtwork` and
`OrcaRuntime.libraryReleaseArtwork`, and from `orca-cli artwork DATABASE
(--track=ID | --release=ID) [--out=PATH]`.

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
