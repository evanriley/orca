# Storage capabilities

Decoders and analyzers consume `ReadableSource`, a small capability interface
for positional reads, total size, and stable observed identity. It deliberately
does not expose path strings or filesystem handles.

`LocalFileSource` is the desktop implementation. It owns an open file, captures
size/inode/modification identity at open time, and supports offset reads without
changing shared stream position. Provider, mobile, and permission-sensitive
sources can implement the same contract without pretending to be local paths.

Container sniffing uses source bytes rather than filename extensions. The first
registry recognizes WAV, AIFF, FLAC, MP3, MP4, Opus, Vorbis, and WavPack magic.

## What sniffing guarantees

`format.detect` answers two questions together: **which container** the bytes
are, and **where its encoded stream begins**. The second is not always zero. An
ID3v2 tag says nothing about what follows it, and some taggers staple one to the
front of a FLAC stream — 104 files in the 22,060-file reference library. Reading
`ID3` as "this is MPEG audio" handed those files to the MPEG decoder, which
failed on the magic bytes, so they would neither play nor probe.

- **The tag is measured, not guessed.** The declared size is four syncsafe bytes
  at offset 6, seven significant bits each, and excludes both the ten-byte
  header and the optional ten-byte footer that flag `0x10` announces. An error
  of ten bytes still "works" for MPEG audio, which resyncs on the next frame
  header, and silently breaks every format whose magic must land on an exact
  byte.
- **Two reads, not one long one.** Detection reads 64 bytes at zero, and when
  those are an ID3v2 header, 64 more at the first byte past the tag. A tag
  carrying artwork routinely runs to hundreds of kilobytes, so the payload check
  cannot be folded into a longer first read.
- **MPEG audio stays byte zero.** If the bytes past the tag are unrecognizable,
  or are an MPEG frame header, detection reports MPEG audio starting at zero.
  That is what an ID3v2 tag fronts in all but a handful of files, and the MPEG
  decoder owns tag and frame resync across the whole file, including the
  trailing ID3v1, APEv2 and Lyrics3 tags it must exclude from the audio region.
  `sniffBytes`, which is pure over a prefix and often cannot reach past the tag,
  answers the same way.
- **Neither does the artwork reader.** `metadata/artwork.zig` resolves the
  prefix the same way before asking a container for its cover, so the 104
  ID3-fronted FLACs give up their `PICTURE` block like any other. The reference
  adversarial file carries a 216,921-byte picture block behind a 219,663-byte
  tag; read from byte zero it looks like an MPEG file with no `APIC` frame.
- **The decoder never sees the tag.** `CodecRegistry.open` and `openDetected`
  hand the codec a `source.OffsetSource` view of the suffix when detection
  reports a non-zero payload offset, and the returned Decoder owns that view for
  its whole life, releasing it strictly after the codec. `open` resolves the
  prefix as well as `openDetected` does, because the scanner opens with the
  container it already sniffed. No codec learns what a tag is.
- **Offsets do not change identity.** An `OffsetSource` shifts reads and size
  but forwards `identity` unchanged. Identity answers "which file is this and
  has it changed", which the scanner compares against `observed_files`; a view
  that reported a shortened size would make every tagged file look modified on
  every scan.
- **Seeking is in stream frames.** Because the offset lives in the source view
  rather than in a codec, every byte position a decoder computes — a FLAC
  seektable entry, an MPEG frame index — is already relative to the start of the
  stream, and a seek in a tagged file lands exactly where the same seek in the
  untagged stream does.

## Incremental scanning

The scanner recursively walks a configured root, opens candidate files through
`LocalFileSource`, and compares path plus storage identity against the
`observed_files` table. Unchanged files avoid format or metadata work. Changed
audio files commit in bounded transactions through the Library's shared write
lane; unsupported and transiently unreadable files are counted without
invalidating successful batches.

A changed audio file is also probed through the codec registry for what its
container declares — the encoding identifier that becomes `files.codec`, plus
sample rate, channels, sample width and frame count, which becomes
`files.duration_ms`. Only headers are read, never audio. Probing is on
the changed path alone: the unchanged skip is what makes a rescan of a large
library nearly free, and reopening every file would spend that. A file that
sniffs as audio and then refuses to open is recorded with no properties and the
scan continues, exactly as an unreadable tag is handled — malformed and
truncated audio is normal in a real library. A transform codec such as MPEG has
no sample width to declare, and that stays unknown rather than being invented.

The walk skips the files a tag write puts beside the music, because each is a
temporary of Orca's and a scan that recorded one would list a second Track with
the old tags:

- hidden names containing `.orca-stage-` or `.orca-restore-`;
- names from journals that predate the backup directory: those containing
  `.orca-backup-` or `.orca-stage-`, or ending in `.recovery-displaced`.

Backups live in `<database>.orca-backups`, beside the database, which the walk
reaches only if the database itself sits inside a library root. Keep the
database outside every root. [Tag-write files](metadata.md#tag-write-files)
covers the layout and the disk space backups and undo need.

Cancellation is checked before filesystem work and between entries. A cancelled
or interrupted scan is resumable by restarting it: already committed unchanged
identities are skipped, so no traversal-order checkpoint is required. Filesystem
watchers will feed the same reconciliation path as hints rather than becoming an
authoritative source of state.

## Repairing properties without a walk

The unchanged fast path has a cost, and it is not paid at scan time. A file the
scanner skips is never probed, so a library scanned before probing existed
keeps null `duration_ms`, `sample_rate` and `channels` for ever — a music
collection's bytes essentially never change, and only changed bytes are
re-read. A Track with a null duration has nothing for a transport bar to draw
against and shows no length in a listing.

`library/property_backfill.zig` is the repair, and it is the same shape as the
projection: keyed on `files.id`, no filesystem walk, reachable as a runtime job
(`Runtime.startLibraryPropertyBackfill`,
`orca_library_start_property_backfill`, `orca-cli backfill`).

- **Selection is one indexed search.** `SELECT ... WHERE files.id > ? AND
  (duration_ms IS NULL OR sample_rate IS NULL OR channels IS NULL OR codec =
  '')` is served by the partial index migration 10 creates over exactly that
  predicate. The predicate has one definition,
  `repository.incomplete_properties_predicate`, shared by the index and the
  query, because SQLite matches a partial index by expression rather than by
  meaning. The index holds only the broken rows, so it shrinks as the pass
  works and asking the question on a healthy library costs one B-tree probe
  rather than 500,000 row reads. `bit_depth` is deliberately not a term: a
  transform codec has no sample width to declare, so a null there is an answer.
- **Bounded and resumable.** One page per bounded commit, cancellation checked
  between rows, and a cancelled run still commits what it already probed. There
  is no checkpoint of its own: which rows still owe a probe is a property of
  the rows, so a second run resumes by asking the same question and getting a
  shorter answer.
- **A missing file is not a failure.** A row whose file is gone, or is not
  audio, is counted and passed over with no health issue — `locations.state`
  already models absence, and filing an issue per file would bury every real
  finding under an unmounted drive. A file that *opens* and then refuses to
  decode raises `unreadable_file`, a kind this pass owns outright so that
  clearing it later cannot erase a finding the analyzer made by decoding audio
  this pass never looked at.
- **It reprojects what it repaired.** `tracks.duration_ms` is derived from the
  file rows, so a backfill that left the Tracks reading zero would have fixed
  nothing anybody can see. Each committed batch is handed to the projection
  scoped to its own file ids, exactly as a scan batch is.
- **`--force` re-probes rows that already answer**, and is not the default. A
  probe reads what a container declares, so re-running it on a row that has an
  answer writes the same numbers; force exists for a probe implementation that
  got *better*, where a stored value is present but no longer what the current
  build would compute. A forced run is not restart-resumable, because a
  re-probed row still matches the selection.

On the 22,060-file reference library a full backfill takes about 2.8 seconds
and a second run 0.05 seconds. It used to leave 104 rows unrepaired: one FLAC
whose STREAMINFO declares `total_samples = 0`, which is honestly unknown rather
than missing, and files that begin with an ID3v2 tag in front of a stream that
is not MPEG audio — 104 of the library's `.flac` files carry one — which were
sniffed as MPEG audio and refused to decode. Container detection now resolves
the tag, so those rows probe like any other; the `total_samples = 0` row is
still honestly unknown, and a file that opens and then refuses to decode still
raises `unreadable_file`.

`library/analysis_pass.zig` is the same shape one level deeper: also keyed on
`files.id`, also a runtime job with bounded commits and no walk, but decoding
whole files rather than reading headers, which changes what "bounded" and
"resumable" have to mean. `docs/analysis.md` covers it.

Platform watcher adapters submit root-scoped hints through a bounded channel.
Unread storms coalesce to one hint per root, including explicit overflow hints;
consumers respond with normal scanner reconciliation. No watcher event directly
inserts, removes, or mutates observed state.

The Linux adapter uses nonblocking inotify and translates native changes,
queue overflow, and root move/delete events into those hints. Watcher coverage
is an acceleration only; startup/manual reconciliation remains responsible for
discovering anything not represented by a delivered native event.
