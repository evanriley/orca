# Metadata layers

Orca keeps three concepts separate:

- `ObservedFileMetadata` records what a source file currently says.
- `OrcaMetadata` records preferred values, user edits, locks, and accepted
  provider matches without mutating that file.
- `EffectiveMetadata` is a resolved view under an explicit preference policy.

Every value carries provenance. A user-locked Orca value outranks automatic
resolution even when the general policy prefers file tags.

Format readers and writers terminate at this boundary. The ID3v1/v1.1 mapping
is deliberately conservative: text that cannot be represented without loss is
rejected. The native FLAC writer maps canonical fields to Vorbis comments,
preserves unknown comments and metadata blocks, and leaves audio frames
byte-for-byte unchanged. Format-specific genre numbers, fixed-width storage,
and comment keys do not define the canonical metadata model.

Scanner observations are persisted in `observed_file_tags`, one row per
`files` row, with genres in `observed_file_genres`, and are updated in the same
bounded transaction as the file row. They do not update Track metadata and
never cause a source-file write.

## Library edits

`Runtime.libraryEditTracks` sets or clears Orca's own values for Tracks without
touching their files. A set value is a locked `user` value in
`orca_metadata_values` on every file the Track resolves to (its preferred file
and every other encoding of its recording), so it outranks the files' tags and
survives rescans; a cleared value lets the tags apply again. The edited files
are reprojected before the call returns, which moves a Track to another Release
or Artist when the edit says so. Editable fields are title, artist, album, album
artist, track number, disc number, date and compilation, the fields the
projection groups and orders by, and the MusicBrainz recording, release,
release-group, release-track and album-artist IDs, which must be lowercase
UUIDs; `metadata.Field` appends new ones, because
`orca_metadata_values.field` stores them by number. `orca-cli edit` and the
`orca-gtk` tag editor drive it; the recording ID is `--recording-id` there,
and the editor's MusicBrainz Recording field for a single track.

Writing those values back into the files is a separate, explicit mutation; see
below.

## MusicBrainz recording IDs

A file's MusicBrainz recording ID is what its listens and its recording's love
and hate are sent to ListenBrainz under. Orca can hold one of its own in
`orca_metadata_values` (`metadata.Field.musicbrainz_recording_id`), beside the
one the file's tag carries. The ID in effect is:

1. a locked Orca value: a user's own edit, or an accepted correction;
2. else the file's tag, when it is not empty;
3. else an unlocked Orca value, which is an accepted match.

`repository.effectiveRecordingMbid` states that order once in SQL, and the
listen subject and the three feedback queries all use it.
`TrackRepository.recordingMbid` applies `metadata.resolveValue` under
`prefer_file` to the same values, which is the same order, for
`TrackDetails.musicbrainz_recording_id` and its source: `tag`, `match` or
`edit`. `orca-cli track` prints both. A file that gains a tag on a rescan
therefore uses the tag at once, and matching does not search for it. A
recording ID from an accepted match or an edit may be sent to AcoustID with
the file's fingerprint, and a tag Orca did not write never is; see
[providers.md](providers.md#acoustid-submission).

The projection does not read the recording ID. A tag write stores it under
the write rule in
[Writing tags back](#writing-tags-back): FLAC as `MUSICBRAINZ_TRACKID`, MP3
and ADTS as a `UFID` frame owned by `http://musicbrainz.org`, as Picard does.

### Accepting a match

A match is an `identification_proposals` row from the matching job described
in [providers.md](providers.md#matching).
`IdentificationProposalRepository.acceptProposal` does all of this in one
transaction:

1. Reads the proposal. One that no longer exists is refused with
   `error.UnknownIdentificationProposal`, and one that is not pending with
   `error.StaleIdentificationProposal`.
2. Parses its payload and checks its recording ID. Either failing is
   `error.InvalidProposalPayload`, and nothing is written.
3. Refuses a proposal in an album group with `error.ProposalInGroup`.
4. Stores the recording ID as an unlocked `provider` value for the file,
   and the title and artist, the release track's when the proposal was
   looked up on its release, else the recording's, on every file of the
   Track (`tracks.fileIds`), as edits do. A correction stores them locked;
   see [Corrections](#corrections).
5. Marks the proposal accepted and dismisses the file's other pending
   proposals.
6. Applies the consensus of the Release the Track belongs to, below.

Every value goes through the same upsert: a locked value is kept, a value
equal to the stored one keeps its `written_at` and is not counted, an empty
value is never stored, a MusicBrainz ID must be a lowercase UUID, and a value
is cut to 4096 bytes on a character boundary. `values_written` counts every
value stored on any file, the Release's other files included. No media file
is written.

`Runtime.libraryAcceptMatch` and `libraryAcceptConfidentMatches` then
reproject the files given values before they return, as edits do, so a Track
can move to a Release with a new id. A frontend holding a Release id
reloads it after an accept.

#### Release consensus

`IdentificationProposalRepository.applyReleaseConsensus(release_id)` stores
a MusicBrainz release's album-level values once the whole Orca Release
agrees on it. It holds when every Track of the Release has a play file that
names the same release R, either by an accepted proposal looked up on R or
by an observed `MUSICBRAINZ_ALBUMID` of R; a file whose location is missing
counts. A Release of more than 512 Tracks never reaches consensus. When it
holds, every file of every Track accepted on R gets R's album, album artist,
date, disc and track numbers (positions on R), and the release,
release-group, release-track and album-artist IDs, the last only when the
release credits one artist; a release credited to Various Artists
(`89ad4ac3-39f7-470e-963a-56509c546377`) adds `compilation=1`. A Track that
names R only by its tag gets nothing new. Running it again stores nothing.

An accept applies it in its own transaction; bulk acceptance applies it once
per Release it touched before each commit; Match Album applies it at its
end. `Runtime.libraryApplyMatchedRelease` and `orca-cli apply-release` apply
it to a Release that came to agree without an accept, such as after an edit
moved a stray file out of it.

The projection resolves a Release's MusicBrainz release ID from the Orca
value and the tag under `prefer_file`, so an accepted release ID keys the
Release. When a reprojection leaves a Release without Tracks, its fetched
cover moves to the Release that took most of them, unless that one has a
cover of its own.

#### Corrections

A pending proposal is a correction when its file has a recording ID in
effect and the proposal names another. It is computed, never stored:
`MatchProposal.corrects` is the ID it would replace. A
[verification](providers.md#verification) proposes corrections, and so can a
re-identify. Accepting one stores its values as locked `provider` values, so
they outrank the file's tags, a tag write writes them over the tags, and
`TrackDetails` still names their source `match`:

- the recording ID on the file, over any value, a user's own locked edit
  included, since accepting it is the user's explicit choice;
- the title and artist on every file of the Track, over an unlocked value or
  a locked `provider` value, so a title or artist the user set is kept;
- for a proposal in an album group, also the track and disc numbers and the
  release-track ID, under the same rule.

No album, release or release-group ID is written. The same equality,
empty-value, ID and length rules as an accept apply. Bulk acceptance never
takes a correction. A group is accepted only whole,
`IdentificationProposalRepository.acceptCorrectionGroup` accepting every
pending member in one transaction and applying the consensus of each Release
it touched, because the projection re-seats a file whose track number
another holds, so half a swap of positions would scramble the album.
`dismissCorrectionGroup` dismisses every pending member. An unknown group is
`error.UnknownCorrectionGroup`, one with no pending member
`error.StaleCorrectionGroup`. A correction is undone by clearing the fields
it set, as Clear in Edit Tags and `orca-cli edit --clear=FIELD` do.

#### Bulk acceptance

`acceptConfident` accepts at most one pending proposal per file, in commits
of at most 512, and passes over a proposal whose payload or recording ID it
cannot read or that is in an album group. A file with a recording ID in
effect is left out, since its proposals are corrections. It returns the number accepted, the values stored, and the
files accepted or given a value. Of the file's proposals that reach the given confidence, those
found by AcoustID with a fingerprint score of at least 0.9 are backed by the
file's own audio. When any is, the first of them in this order is accepted:

1. the higher percent, `floor(confidence × 100)` as the Matches page shows it;
2. the track number of the Track that plays the file, when both are known;
3. found by MusicBrainz too;
4. the higher MusicBrainz score, an unknown one lowest;
5. the length closest to the Track's, when known, an unknown one last;
6. the lowest recording ID.

A text-only rival, such as a live version of the song, never blocks such a
match, and AcoustID naming several MusicBrainz recordings of the same audio
still yields one. When none is backed, the file's most confident proposal is
accepted only when it reaches the given confidence and shows a higher percent
than every other pending proposal of the file. A file accepted at one
confidence is therefore accepted at every lower one. `confidentCount` runs
the same selection, so it is what `acceptConfident` accepts.

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

- **The media type comes from the bytes, not from the claim.** Real files
  declare `image/jpg`, which is not a media type, or nothing at all, or an empty
  declaration in front of an animated GIF. `EmbeddedImage.mime_type` is what the
  magic bytes say; a payload that matches none of PNG, JPEG, GIF, WebP or BMP is
  refused as `UnrecognizedArtworkImage` rather than passed to a platform image
  decoder. `Artwork.mime_type`, being an observation, still records the claim.
- **Bounded at 12 MiB, checked against the declaration.** The whole image is
  held in memory at once, so `model.max_image_bytes` is compared with the length
  a container declares *before* anything is allocated to honour it. The value
  sits below both containers' own ceilings — a FLAC `PICTURE` length is 24 bits
  and `id3v2.max_tag_bytes` is 16 MiB — because a bound above them could never
  fire, and above every honest cover.
- **Read from the file, never stored in the Library.** Storing images in the
  Library would multiply its size by orders of magnitude, for data that already
  exists on disk and would go stale the moment a file is re-tagged. Reading on
  demand costs one open and one read, and it is right by construction — a track
  whose stored observation predates the current reader still yields its cover,
  because the row is not consulted.
  The one image the Library does store is a cover fetched from the Cover Art
  Archive for a Release none of whose files has one (`release_artwork`), since
  it exists nowhere on disk; an embedded cover always wins over it. See
  [providers.md](providers.md#cover-art-archive).
- **liborca keeps no image cache.** `Runtime.libraryRequestArtwork` queues a
  request on the Library's artwork loader (`core/artwork.zig`), which reads
  covers on its own thread with at most `artwork.capacity` requests
  outstanding; the host collects results with `Runtime.libraryTakeArtwork`.
  Keeping decoded images is the host's concern: `orca-gtk` holds a bounded set
  of textures in `apps/linux/art.zig`.

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

Reachable as `Runtime.libraryTrackArtwork` and
`Runtime.libraryReleaseArtwork`, and from `orca-cli artwork DATABASE
(--track=ID | --release=ID) [--out=PATH]`.

## Lyrics

A Track's lyrics are read on demand from its file and from a sidecar beside
it, and, when a lyrics job is asked to fetch, from LRCLIB. They are never
scanned and never written to a file; only LRCLIB's answers are kept in the
Library ([providers.md](providers.md#lrclib)). `metadata/lyrics.zig` holds
the model, `metadata/lrc.zig` the one parser every text source goes through,
`library/lyrics_lookup.zig` the sidecar and the choice between local
sources, and `core/lyrics_fetch.zig` the choice between those and LRCLIB.

### Sources

| Source | Where |
| --- | --- |
| Sidecar | the file's path with its extension replaced by `.lrc`, case kept |
| ID3v2 (MP3, ADTS, FLAC behind ID3) | `SYLT`, else the first non-empty `USLT` |
| Vorbis comment (FLAC, Ogg Vorbis, Opus) | `LYRICS`, else `UNSYNCEDLYRICS` |
| MP4 | `©lyr` |

`SYLT` is read only with millisecond timestamps (format 2) and content type
lyrics (1); its own times are used, and one leading newline per entry is
dropped. `USLT`, comments and `©lyr` are parsed as LRC. ID3v2 text in any of
its four encodings is read, and the frame's language becomes
`Lyrics.language`, with `XXX` read as none. WAV and AIFF are not read for
lyrics. A sidecar named with another case, such as `Song.LRC` for
`Song.flac`, is not found on a case-sensitive filesystem.

### Choice order

1. A synced sidecar.
2. Synced lyrics in the file.
3. Synced lyrics from LRCLIB.
4. A plain sidecar.
5. Plain lyrics in the file.
6. Plain lyrics from LRCLIB.
7. An instrumental from LRCLIB, with no lines.

LRCLIB's lyrics are the ones fetched or kept for the Track's current title,
artist, album and duration. A job that does not fetch still uses kept ones.

### LRC rules

- A line starts with one or more `[m:ss]`, `[mm:ss.f]`, `[mm:ss.ff]` or
  `[mm:ss.fff]` stamps; each stamp makes one line with the same text. A stamp
  with 60 or more seconds drops its line.
- `<mm:ss.xx>` word stamps are removed from the text.
- `[offset:N]` shifts every line to `start - N` milliseconds, clamped at 0: a
  positive offset makes lines show earlier.
- Other `[key:value]` ID tags and lines starting with `#` are skipped.
- A UTF-8 byte order mark and CRLF line ends are accepted.
- Text with any stamped line is synced, and its unstamped rows are dropped;
  otherwise every row is a plain line. Text with only tags is no lyrics.

### Bounds

A source over 512 KiB, with more than 4096 lines, or whose text is not UTF-8
is treated as having no lyrics. A malformed or unreadable tag reads as none;
only running out of memory is an error.

### Reaching it

`Runtime.startTrackLyrics` reads, and with `fetch` asks LRCLIB, on a job
worker. Once the job finishes, `Runtime.jobLyricsOutcome` says where lyrics
were found or why none were (see
[providers.md](providers.md#lrclib)), and `Runtime.jobTakeLyrics` moves the
`Lyrics` to the caller; lyrics nobody takes are freed with the job.
`Lyrics.lineAt(position_ms)` is the synced line being heard.
`orca-cli lyrics DATABASE TRACK_ID [--fetch]` prints them, and
`orca-cli play-tracks --lyrics` prints each line as playback reaches it.

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
time is still detected. The mutation journal persists the full identity, so
recovery compares the same `FileIdentity` an in-process check does; see
[database.md](database.md).

Every action of a group is journaled before any filesystem work begins, and
journal writes raise SQLite durability for their own transaction, so a group is
always discoverable after a crash. Moves reject collisions and use the same
operation journal.

### The journal lock

One holder at a time owns a Library's mutation journal: the holder of an
exclusive advisory lock (`flock`) on `<database>.orca-journal.lock`
(`metadata.JournalLock`). The operating system releases it when its process
exits in any way, and a process that is paused, however long, keeps it, which
a lease in the database could not promise. It is taken without waiting, and
held only for the duration of one of these:

- `LibraryDatabase.open`, for recovery and the migrations between its two
  recovery passes.
- A tag write, from `Runtime.startTagWrite` until the plan has executed; the
  files are re-observed after it is released.
- `Runtime.undoTagWrite`, until the group is undone; the files are re-observed
  after it is released.
- `Runtime.pruneTagWriteBackups`.

A write, undo or prune that finds the lock held returns
`error.MutationInProgress` and changes nothing; a refused write's plan stays
pending. Once it holds the lock, it first runs recovery
(`LibraryDatabase.recoverPendingMutations`), because a holder that exited
since the Library was opened may have left work unfinished; a write does this
on its job's thread. If that recovery fails, the operation fails with its error
and journals nothing of its own. An open that finds the lock held leaves the
journal alone, because its rows belong to a writer that is still alive: it sets
`LibraryDatabase.recovery_deferred`, which the next recovery clears, and
returns `error.MutationInProgress` instead if the Library still needs a
migration. Each acquisition opens the file anew, so two acquisitions in one
process exclude each other as two processes do. A Library with no database
file has no lock file: tag writes, undo and pruning return
`error.NoBackupDirectory`, and its open runs no recovery, since nothing it
journals can outlive its process.

**Never delete the lock file.** A process that opened it before the deletion
still holds its lock, and the next process creates a new file and locks that,
so both would own the journal.

### Tag-write files

A tag write to `Album/01.flac` in plan 7, action 0, uses three files and the
Library's journal lock. Only the backup outlives the write, and it lives outside
the music folders:

| File | Path | Exists |
| --- | --- | --- |
| Stage | `Album/.01.flac.orca-stage-7-0` | until the write commits |
| Backup | `<database>.orca-backups/7/0-01.flac` | until undone or pruned |
| Restore | `Album/.01.flac.orca-restore-7-0` | during an undo |
| Journal lock | `<database>.orca-journal.lock` | always; never delete it |

`<database>` is the absolute path of the Library's database file, so the
journaled backup path does not depend on the working directory. A Library with
no database file, such as an in-memory one, has no backup directory:
`Runtime.startTagWrite` returns `error.NoBackupDirectory` and the executor
refuses before touching any file.

A write runs in three steps, and at every point either the original is in place
or a durable, verified copy of it exists:

1. Build the complete replacement at the stage, and fsync it and its directory.
2. Copy the original into the backup directory with its modification time, fsync
   the copy and every directory created for it, and verify that the copy's
   identity is the original's.
3. Revalidate the file's identity, rename the stage onto it, and fsync the
   directory.

The backup is a copy rather than a rename, so it may sit on another disk:
backups use space on the database's disk until they are undone or pruned. A
disk that fills during the copy fails the write at step 2 with the file
untouched.

### Undo

Logical groups undo in reverse action order. `undoGroup` starts from the
states of the group's operations:

- Every operation `committed`: a fresh undo, below.
- Some operation `undoing`, none `planned`, `staged` or `failed`: an undo that
  was interrupted. It finishes the way recovery does, operation by operation
  as the [Recovery](#recovery) table decides.
- Every operation `rolled_back`: `error.MutationGroupAlreadyUndone`.
- Otherwise, with an operation `needs_reconciliation`:
  `error.MutationNeedsReconciliation`; with none,
  `error.MutationGroupNotCommitted`.

Before a fresh undo changes any file, it checks every operation of the group:

- A write whose backup was pruned returns `error.TagWriteBackupPruned`.
- A file that changed since the write, or a backup that is missing or no longer
  has the original's identity, records `needs_reconciliation` and returns
  `error.MutationNeedsReconciliation`.

It then journals its intent: every operation of the group becomes `undoing` in
one durable transaction, or none does. A crash or an error from here on leaves
the group nonterminal, so the next undo or the next open finishes it; an
operation never returns to `committed`.

Each file is then restored: its backup is copied to the restore file with the
original's modification time, fsynced and verified, the file is revalidated
against the write's result, and the restore file is renamed onto it. The
backup is deleted, the plan directory and the backup directory are removed
once empty, and the operation becomes `rolled_back`. An undo needs free space
for one file on the music disk; if the copy fails, the file is untouched and
the operation stays `undoing`.

### Recovery

`LibraryDatabase.open` runs journal recovery before the Library is returned to
the caller — after the journal table exists and before any later migration
rewrites what a nonterminal operation refers to — and again after the
migrations, and refuses to open at all if recovery cannot reach a terminal
state. Both passes run only under the [journal lock](#the-journal-lock).

Recovery drives every group with a `planned`, `staged`, `failed` or `undoing`
operation to terminal states. It first marks the group's `committed`
operations `undoing`, in one transaction, so a crash during recovery leaves
the group discoverable, then unwinds it in reverse action order. A `failed`
operation becomes `rolled_back` and keeps the error its write journaled;
an operation rolled back from any other state records `recovered`. A tag
write being written or being undone is decided by identity alone:

| Found | Action | Result |
| --- | --- | --- |
| File is the original | delete stage, restore file and backup | `rolled_back` |
| Nothing was staged | delete a torn stage | `rolled_back` |
| File is the result, backup is the original | restore as an undo does | `rolled_back` |
| File is the result, backup missing or damaged | keep every file | `needs_reconciliation` |
| File's folder missing, as on an unmounted drive | keep every file | refuses to open; retried at the next open |
| File missing or matching neither | keep every file | `needs_reconciliation` |

An `undoing` operation reaches those rows from each point an undo can stop at:

| Undo stopped | Found | Result |
| --- | --- | --- |
| Before its restore, or during the restore copy | file is the result | restored, `rolled_back` |
| After the restore rename, or after deleting the backup | file is the original | `rolled_back` |
| After the file changed externally | file matches neither | `needs_reconciliation`, every file kept |

Journal records from before the backup directory existed name a stage and a
backup beside the music (`Album/01.flac.orca-stage-7-0`,
`Album/01.flac.orca-backup-7-0`), and may leave
`<stage>.recovery-displaced`. Recovery, undo and pruning follow the journaled
paths, so they handle those records too, and recovery deletes a leftover
`.recovery-displaced` file. Orca removes directories only inside the backup
directory, never a music folder.

### Pruning backups

`Runtime.pruneTagWriteBackups(library, io, older_than_s)` deletes the backups
of every group whose operations are all `committed` and were last updated at
least `older_than_s` seconds ago; zero prunes every committed group. A group
being undone is not all `committed` and keeps its backups. It returns
a `PruneSummary` with the number of backups pruned and their bytes. Each backup
file is deleted before its journal path is cleared, so a prune that is
interrupted finishes on the next run. A pruned write cannot be undone. Groups
awaiting reconciliation keep their backups, and nothing prunes automatically.

```sh
orca-cli prune-backups DATABASE [--older-than=DAYS]
```

## Writing tags back

`Runtime.planTagWrite` compares each Track file's Orca values with its observed
tags and seals a `MutationPlan` of the values to write. It writes nothing. A
value is written only when it is the one in effect, so a file's own tag is
never replaced by an automatic value:

- A locked value, which is a user's edit or an accepted correction, is
  written when it differs from the file's tag.
- An unlocked value, such as an accepted match, is written only when the file
  has no tag for its field.
- An unlocked value that differs from the file's tag is a conflict. It is
  listed in `TagWritePlan.conflicts` with both values and not written; the
  file's other changes are. Editing the field locks the user's choice, which
  the next write applies.

The returned `TagWritePlan` lists each file's changes with the provenance of
Orca's value (`user` for an edit, `provider` for a match), the conflicts, the
files it left out and why, and the plan's ID and digest:

- `missing`: no present location to write to.
- `format_not_writable`: no writer for the sniffed format yet. FLAC, MP3 and
  ADTS are written; M4A, Ogg, WAV and AIFF are not, and neither is a FLAC
  stream behind a leading ID3v2 tag.
- `changed_since_scan`: the file's identity no longer matches the last scan,
  so the plan would describe tags the file no longer has. Rescan first.
- `folder_not_writable`: Orca cannot create files in the file's folder, which
  the write needs for its staged copy. The file's own permissions do not
  matter, since the staged copy replaces it by a rename. C value
  `ORCA_TAG_WRITE_SKIP_FOLDER_NOT_WRITABLE` (3).

The runtime holds at most eight plans awaiting approval.
`Runtime.startTagWrite` approves one by its ID and digest and executes it as a
`mutation` Job; a digest that does not match, or a journal lock held
elsewhere (`error.MutationInProgress`), leaves the plan unwritten and
pending.
`Runtime.discardTagWrite` drops one. The Job cannot be cancelled once started,
because a journaled group commits or rolls back as a whole. When it ends, every
file in the plan is re-observed and reprojected, so the library reads what the
files now say. The plan ID is the journal group, and
`Runtime.undoTagWrite(group)` restores those files' previous bytes and
re-observes them; for a group already undone, such as one whose interrupted
undo recovery finished, it re-observes them and returns
`error.MutationGroupAlreadyUndone`. Orca's values survive both directions: after a write the
library still holds the locked edit, and after an undo it still shows it.

A write that fails rolls its group back as recovery does and ends the Job
`failed`. `Runtime.jobTagWriteFailure(job)` then returns a `TagWriteFailure`:
the file it stopped at, that file's index in the plan's actions, and a
`TagWriteFailureReason` (`permission_denied`, `read_only_file_system`,
`no_space`, `changed_since_plan` when the file's identity no longer matched
the plan, or `other`). It returns null while the Job runs, after it
succeeded, or when it failed before reaching a file, such as in recovery, and
`error.NotATagWriteJob` for a Job of another kind. The C ABI's
`orca_job_tag_write_failure` fills an `orca_tag_write_failure` and returns
`ORCA_STATUS_NOT_FOUND` for null and `ORCA_STATUS_INVALID_ARGUMENT` for a Job
of another kind. `orca-cli write-tags` prints it as
`failed<TAB>FILE_ID<TAB>REASON<TAB>PATH` before exiting with an error.
A plan writes one present location of each file. A file held at several
paths is byte-identical copies, so writing one copy splits it off into a file
of its own that carries Orca's values, and the copies left behind keep the
shared file (see [database.md](database.md#identity)).
When a write commits, each value it wrote is marked with
`orca_metadata_values.written_at` on the file its path holds after the
re-observation; changing the value clears the mark. The
mark keeps a recording ID that Orca wrote into a file eligible for AcoustID
submission, since the file's tag then holds Orca's choice.

Writers keep what they do not understand:

- ID3v2 keeps the file's version (2.3 or 2.4), copies unchanged frames verbatim,
  keeps a `n/total` total, and updates an existing ID3v1 trailer. A file with no
  ID3v2 tag gets a 2.4 one. A recording ID replaces only the MusicBrainz `UFID`
  and the `TXXX` frames the reader takes one from (`MusicBrainz Track Id`,
  `MUSICBRAINZ_TRACKID`). The release, release-group, release-track and
  album-artist IDs are written as `TXXX` frames under Picard's descriptions,
  `MusicBrainz Album Id`, `MusicBrainz Release Group Id`,
  `MusicBrainz Release Track Id` and `MusicBrainz Album Artist Id`, and each
  replaces only the `TXXX` frames under that description or its Vorbis
  spelling, such as `MUSICBRAINZ_ALBUMID`, in any case. Other `UFID` owners
  and `TXXX` descriptions are kept byte for byte. In 2.3 a `TXXX` frame is
  UTF-16 with a byte-order mark on each string; in 2.4 it is UTF-8.
- Vorbis comments in FLAC match fields by the same aliases and canonical values
  the reader uses, so a write never duplicates a field under another spelling.
  The release-level IDs are `MUSICBRAINZ_ALBUMID`,
  `MUSICBRAINZ_RELEASEGROUPID`, `MUSICBRAINZ_RELEASETRACKID` and
  `MUSICBRAINZ_ALBUMARTISTID`. A write replaces every entry under the key, in
  any case, with one.
- The audio bytes are copied unchanged; only the tag region is rewritten.

From the command line, `orca-cli write-tags DATABASE IDS` prints the plan,
each change labelled `edit` or `match`, a `conflict` line per conflict, and
the digest; `orca-cli write-tags DATABASE IDS --approve=DIGEST` replans and
writes it if the digest still matches, `orca-cli undo-tags DATABASE GROUP`
undoes it or prints `group GROUP was already undone`, and `orca-cli prune-backups DATABASE` deletes the backups that make
undo possible; see [Pruning backups](#pruning-backups).
In `orca-gtk`, Write Tags to Files… on a track or album menu, and Save and
Write to Files… in Edit Tags, show the plan and write it once confirmed.
