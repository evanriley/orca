# Audio analysis

This file covers what `analysis/` measures and stores, the library-wide
analysis pass, ReplayGain on playback, duplicate detection, the metadata
consistency pass and the health issue kinds.

`analysis/service.zig` measures a file in one streaming pass over a
`ReadableSource`, so a file is decoded once however many numbers a caller
wants: integrated loudness (a gated ITU-R BS.1770 mean summing every channel's
K-weighted energy with weight 1.0), a ReplayGain figure derived from it, sample
peak, RMS, clipped samples, leading, trailing and total silence, a bucketed
waveform, a temporal fingerprint with a decoded-audio hash, and the AcoustID
fingerprint. `library/analysis_pass.zig` measures every file in a Library, so
ReplayGain on playback and duplicate detection always have a measurement.
Only mono and stereo are measured: a file with more than two channels fails
with `UnsupportedChannelCount`, because equal channel weights would misstate a
surround layout's loudness.

## AcoustID fingerprints

`analysis/chromaprint.zig` computes the fingerprint AcoustID matches on, as
`fpcalc` does: the first 120 s of a file, decoded by Orca's codecs, mixed to
mono, resampled to 11,025 Hz by libsamplerate (`resampler.SampleRate`,
`sinc_fastest`), converted to 16-bit and fed to Chromaprint's default algorithm
(`TEST2`) behind `chromaprint_shim.c`. The result is Chromaprint's compressed,
base64 fingerprint and the whole file's length; a shorter file is fingerprinted
whole. Chromaprint is built without its own LGPL resampler; see
[architecture.md](architecture.md#dependencies-and-licences). A decode error
while reading the window fails the fingerprint; nothing is cached or sent and
it is tried again next time. A unit test holds Orca's fingerprint of
`fixtures/audio/fingerprint-reference.mp3` to at least 95 % bit agreement with
`fpcalc`'s.

A fingerprint is stored in `analysis_results` as kind 3, `orca.chromaprint`
version 1, under a parameter hash of the algorithm, the converter and the window
length, and the content hash of the bytes it was taken from. The stored result
is the length in milliseconds (8 bytes, little-endian) followed by the
fingerprint. `chromaprint.Analyzer` takes it from audio fed a chunk at a time,
so the analysis service takes it in the same decode as everything else, and
matching and AcoustID submission find it stored instead of decoding again. Audio
too short to fingerprint is measured without one. Matching and submission
fingerprint files the pass has not reached as they need them;
`Runtime.libraryTrackFingerprint` and `orca-cli fingerprint` take one for a
single Track.

## The pass

`library/analysis_pass.zig` measures every file in a Library that has not been
measured. It is a runtime job (`Runtime.startLibraryAnalysis`,
`orca_library_start_analysis`, `orca-cli analyze-library`) on the machinery the
[property backfill](storage.md#repairing-properties-without-a-walk) uses: the
shared `JobWorker`, cancellation token, job snapshot, bounded commits and
indexed row selection. The decode runs outside any transaction; only finished
measurements enter one, so the Library's write lane is never held across a
decode.

### What "already analyzed" means

The selection key is the analysis cache key minus the file, for each of the two
measurements the pass stores, the diagnostics and the temporal fingerprint
(`analysis.service.analysisSelectors`):

```
kind, algorithm_id, algorithm_version, parameter_hash   +   source_identity
```

A file owes work when, for either measurement, no `analysis_results` row exists
under that key with `source_identity = files.content_hash` and
`files.content_hash_algorithm = 1`. A file with no recorded content hash always
owes work. A changed byte stream (a scan that sees a changed inode, size or
mtime forgets the content hash), algorithm version or parameter hash therefore
re-selects the file, and there is no force mode. `analysis_results` is
`WITHOUT ROWID` keyed on those six columns, so no further index is needed.
`repository.unanalyzed_predicate` is the one definition shared by the page
query and the count that gives the job its denominator.

### Outcomes

A batch commits in one bounded transaction.

Measured files store the encoded diagnostics and temporal fingerprint; the
AcoustID fingerprint unless the audio is too short; the decoded-audio hash in
`files.audio_hash` with its tier in `files.audio_hash_tier` (the only identity
rung that survives Orca's own tag writes; see
[the audio hash](#the-audio-hash)); `corrupt_audio` cleared; and `clipping`,
`excessive_silence` and `missing_analysis` raised or cleared. A file with no
gateable loudness (too short or silent) is still stored so it is not decoded
every run; it yields no correction and raises `missing_analysis`. A file with
more than two channels stores nothing, raises `missing_analysis` with details
naming the channel count, clears `corrupt_audio`, `clipping` and
`excessive_silence`, and is counted with the declined files. The channel check
runs before the cache lookup, so a stored result is never reused for such a
file. A file recorded with more than two channels that still holds results,
as a Library analysed before the limit holds them, is selected by the pass,
which deletes all its results (and with them its `file_loudness` row) in the
same transaction. Results are
keyed by the content hash of the bytes decoded, taken in a second sequential
read beside the decode, and the same transaction records that hash on the file
(see [database.md](database.md#schema)).

A file is declined when it is not reachable, is not audio, or lacks the
identity the Library recorded: the quick hash differs, the content hash read is
not the recorded one, or, with none recorded, the inode, size or mtime differs
from the location's. The checks repeat under the write lane, so a scan that
recorded other bytes meanwhile declines the file instead of keying results to
them. A declined file is counted and raises no health issue; repairing a stale
identity is a scan's job. The first check runs before the decode, on two 64 KiB
reads.

A file that a codec claims but cannot open or decode raises `corrupt_audio` and
clears the pass's other three kinds. So does a file that decodes to its end
past damage its decoder reports through `Decoder.damage`: an AIFF whose COMM
declares more frames than SSND holds, a WAV data chunk that ends inside a frame,
or a FLAC stream with frame errors, a short final block or an MD5 mismatch.
Playback of the same file continues. The issue's details name the error or the
damage, and the file stays unanalysed, so every pass decodes it again. The pass never raises `unreadable_file`, which
belongs to the property backfill.

### Threads

Batch size defaults to 32 (the backfill's is 256). The cursor is a `files.id`,
so a declined file is not served again within a run, and a run that stops
resumes by asking the same question; there is no checkpoint.

A batch's files are decoded by `min(threads, files in the batch)` threads: the
job's own thread and helpers started for that batch. Each thread claims the
next file, measures it with its own `std.Io` and keeps the result in that
file's slot; the job's thread joins the helpers and commits the slots in
`files.id` order in one transaction. No helper touches SQLite, and the thread
count does not change the results.

`AnalysisRequest.threads`, `orca_analysis_options.threads` and
`orca-cli analyze-library --threads=N` set the count. Unset (zero in the C ABI)
takes `analysisDefaultThreads()`: one fewer than `analysisAvailableThreads()`,
at least 1. There is no upper limit, but more than 32 threads needs a larger
`batch_size`.

- One thread, or a batch of one file, starts no helper; a helper that fails to
  start leaves its share to the others.
- Cancellation stops every thread from claiming another file. Measured files
  are committed; a file abandoned mid-decode or never claimed is selected again
  next run.
- Any other error, such as out of memory, fails the batch and commits nothing
  of it.
- Progress counts each file as its thread finishes it.

`orca-cli analyze-library` builds its runtime on `std.heap.smp_allocator`
because the process arena would keep every decoded file's buffers until the run
ends.

## ReplayGain on playback

The correction is a property of the audio, not of the Player. Each
`SourceSession` carries the linear corrections for the bytes it decodes, track
and album (`EntryReplayGain`), and scales the frames it produces by the one the
mode selects; `Gain` is user volume only. `TrackSourceOpener.openTrack` is the
only place a queue entry becomes audio and so the only place the correction is
attached ([audio-engine.md](audio-engine.md#replaygain) explains why). An entry
with no usable correction carries 1.

The lookup is keyed on the file's recorded content hash, and only while the
opened file still has the quick hash the file records and the inode, size and
mtime its location records (`AnalysisCacheRepository.vouchedContentHash`). A
file edited since the last scan plays at unity rather than at a correction
measured from audio it no longer contains. The Player asks for the measurement
made under the default `diagnostics.Parameters`, which the pass produces; the
target LUFS is one of those parameters, so a measurement under others is not
adopted. No reader observes a file's `REPLAYGAIN_*` tags, so a file Orca has
not analysed plays at the untagged fallback in every mode.

The opener reads SQLite and two 64 KiB file ranges on whichever lane opens the
entry (the control lane for a hard load, the engine thread for an
auto-advance), never in the render callback.

### Modes and settings

`ReplayGainMode` is `off`, `track`, `album` or `smart`. `smart` takes the album
correction while the entry before or after it in playback order belongs to the
same Release, and the track correction otherwise. `off` is exactly 1: the
multiply is skipped. The mode is a Player atomic read per canonical block, so a
change takes effect as already decoded audio drains, and the level steps rather
than ramps.

`ReplayGainSettings.preamp_db` (clamped to ±15 dB) is added to every measured
correction before the peak cap. `ReplayGainSettings.fallback` sets the level of
an entry with no usable measurement: `as_is` (unity, the default) or
`minus_6_db`; the preamp does not apply to it. A boost is capped at `1 / peak`
while `ReplayGainSettings.peak_protection` is on (the default), lowering the
correction rather than limiting the audio. `SignalPath.peak_limited` says when
the cap lowered the audible correction.

### Album ReplayGain

`album` corrects every Track of a Release by the same figure, so levels within
an album stay as mastered. `TrackSourceOpener.openTrack` computes it at open
from one bounded statement over the entry's Release
(`AnalysisCacheRepository.visitReleaseMembers`); nothing is cached per Release,
so re-analysing or moving a Track cannot leave a stale figure. A member whose
file is recorded with more than two channels reads as having no stored
measurement, whatever is stored for it.

The album's integrated loudness is a duration-weighted energy mean,
`10·log10(Σ dᵢ·10^(Lᵢ/10) / Σ dᵢ)`, over the Tracks' integrated loudness `Lᵢ`
and durations `dᵢ`; the album gain is the canonical target (-18 LUFS) minus it.
The mean approximates BS.1770 gating over merged blocks, which would need every
block's energy while the stored result keeps only each file's gated loudness.
For a Release with long quiet or silent passages it reads louder than exact
gating. The boost cap uses the largest Track peak in the Release, so no Track
clips.

An entry plays at its own track correction, and `SignalPath.replay_gain_source`
is `track_fallback`, when its Release has a Track with no stored measurement
for its recorded bytes, a Track with no duration, more than 512 Tracks, or no
Release. A Track measured with no gated loudness adds no energy or duration but
still counts toward the peak. The entry's own measurement is keyed on the bytes
opened; every other member's is keyed on `files.content_hash`, because checking
every file of an album at each open would cost a disc's worth of reads.

`SignalPath` carries the applied gain (`replay_gain_db`), its source
(`replay_gain_source`: `none`, `track`, `album` or `track_fallback`) and, for an
album correction, the track correction it replaced (`replay_gain_track_db`).
`playerEffectiveGain` / `orca_player_effective_gain` reports volume times the
correction of the entry being heard, resolved through the same `entry_serial`
as identity, duration and position. It reports and does not drive.

## Duplicate detection

`library/duplicate_pass.zig` reports every file whose audio the Library also
holds elsewhere. It is a runtime job (`Runtime.startLibraryDuplicateScan`,
`orca_library_start_duplicate_scan`, `orca-cli duplicates`) on the same
`JobWorker` machinery as the analysis pass. It opens no files: it compares what
the analysis pass stored through indexed lookups and stored-fingerprint
comparisons. `fingerprint.classifyDuplicate` is the only pairwise comparison in
the codebase.

### What the three findings mean

Each finding states only what was proven. A file gets the strongest that
holds, and at most one: `exact_duplicate` outranks `identical_audio`, which
outranks `likely_duplicate`. Both members of a pair are reported.

`exact_duplicate` (warning): the same bytes are stored more than once, by the
full-content BLAKE3-256 hash. It holds when one `files` row has a second
`present` location (the scanner resolves a byte-identical copy to the existing
row by quick and content hash; a copy whose bytes change leaves for a file of
its own, see [database.md](database.md#identity)), or when two `files` rows
record the same `content_hash` with `content_hash_algorithm` 1.

`identical_audio` (warning): different bytes, the same audio, meaning two
`files` rows with equal tier-1 `audio_hash` (see
[the audio hash](#the-audio-hash)), such as a WAV and the FLAC made from it,
whatever the container, width or tags. Keeping either copy loses no audio.
Equal tier-2 hashes are `likely_duplicate`.

`likely_duplicate` (information): the audio resembles another file's above a
similarity threshold, or two lossy or float decodes hash alike. The claim can
be wrong, so the message carries the match percentage. It catches a lossy
transcode of a master, which hashes differently.

### Similarity threshold

The threshold is 0.985 (`likely_threshold` in `library/duplicate_pass.zig`,
which records the measurements behind it). Unrelated music already agrees on
most coarse bins, so the usable band is the top two percent of the scale. The
line sits above unrelated tracks of the same length and above a track's own
instrumental cut, and below transcodes of one master; between about 0.96 and
0.985 the fingerprint cannot separate a transcode from an unrelated track of
the same length.

### Bounds

Candidates are bucketed by indexed lookups (`files_content_hash`,
`files_audio_hash` and `files_duration ON files(duration_ms, id)`), none a
scan. Plausible buckets use duration within `duration_tolerance_ms` (250 ms),
which covers codec padding and encoder delay. A bucket holds at most
`max_bucket_peers` (64) files, so work per file is constant; a bucket that hits
the cap is counted (`truncated_buckets`). At most two decoded fingerprints are
resident at a time. Batches are 256 files in one transaction, with a `files.id`
cursor.

The pass is restartable, not incremental: duplication is a relation between
rows, so adding or deleting one file can change another's status. A cancelled
run keeps committed batches and the next run starts from the beginning.

A file has no `audio_hash` until the analysis pass reaches it, and cannot be
compared. The pass counts these files as uncomparable and prints the count; a
run with no findings and a large count means the library is not measured. No
health issue is filed per uncomparable file.

Every examined file has all three of this pass's kinds rewritten, present or
absent, so a changed copy loses `exact_duplicate` as it gains `identical_audio`.
This is replace-by-file narrowed to the pass's own kinds: `replaceFile` would
erase other passes' findings. Recording is an upsert on `(file_id, kind)`.
`orca-cli duplicates` builds its runtime on `std.heap.smp_allocator`, because
an arena would keep one fingerprint per comparison for the whole run.

### The audio hash

`files.audio_hash` is an ORAH version 2 digest taken by
`analysis.fingerprint.AudioHasher` in the same decode as the temporal
fingerprint:

```
BLAKE3( header || BLAKE3(samples) )

header (21 bytes, little-endian):
  "ORAH"  u16 version = 2  u8 tier  u32 sample_rate  u8 channels
  u8 layout = 0 (interleaved, source order)  u64 frames
```

The header commits to the samples' digest because the frame count is known only
at the end. Streams that differ in rate, channels, tier or length never share a
hash. The tier is stored in `files.audio_hash_tier`:

| tier | samples hashed | sources |
| --- | --- | --- |
| 1, lossless integer | each sample as an `i32` left-justified in 32 bits | FLAC, ALAC, integer WAV, integer AIFF and AIFC |
| 2, decoded float | the bits of each decoded `f32` | float WAV and AIFF, MP3/MP2/MP1, AAC, Opus, Vorbis, QOA |

Tier 1 reads the source's integers through `Decoder.readFramesI32`, so the hash
is exact at any width, and left-justification makes the container width
irrelevant: 16-bit audio in FLAC, a 16-bit WAV and a 24-bit WAV hash
identically. The effective width is kept in the stored fingerprint result.
Tier 2 is one decoder's rendering, so equal tier-2 hashes support only
`likely_duplicate`. Hashes of different tiers never compare equal.

The hash travels in the temporal fingerprint result (`ORFP` version 2;
`fingerprint_algorithm_version` is 3 in `analysis/service.zig`). A tier-1 hash
is a function of the audio because the lossless decoders return the integers
the file encodes, and FLAC decodes bit-exactly through libFLAC (see
[architecture.md](architecture.md#flac)). Equal audio says nothing about equal
bytes, so only the content hash makes `exact_duplicate`.

### Groups

`Runtime.libraryDuplicateGroupPage` (`orca-cli duplicates DATABASE --groups`)
joins the visible `exact_duplicate`, `identical_audio` and `likely_duplicate`
issues into groups: files linked by an issue, directly or through another file,
form one group, and a file held at several present locations is a group on its
own. A group's id is its lowest file id; grouping is computed on each read and
stores nothing. Issues naming a file that no longer exists are left out.

`DuplicateGroup` carries the suggested copy's title and artist, `copies` (each
further location of a file counting as one), `same_recording` (every file is an
encoding of one recording, so the copies share one play count and rating),
`similarity` (the lowest score among `likely_duplicate` links, 1 for exact and
identical-audio links), `verdict` and `bytes_redundant`, what removing every
copy but the suggested one frees. `verdict`, a `DuplicateVerdict`, is the
weakest kind among the group's links; the C ABI carries it as an
`orca_health_issue_kind` in `orca_duplicate_group_view.verdict`.
`libraryDuplicateGroupTotals` sums the groups and their bytes. It keeps the same
copy as [By kind](#by-kind) but can still differ from it: By kind groups the
links of one kind at a time, while a group joins files across kinds and through
other files.

`Runtime.libraryDuplicateGroup` (`orca-cli duplicates DATABASE --group=ID`)
returns a group's files, the suggested copy first: the lossless over the lossy,
then the higher sample rate, the higher bit depth and the larger file, then the
location its details show, by library root path, volume and path compared
byte-wise, so the order does not depend on the order files were scanned; the
lower file id decides only when those agree too. Each `DuplicateCopy` holds the
lowest Track id the file backs, that Track's `TrackDetails` with this file's format, size, path and loudness,
the number of playlists holding its recording, and its present locations.

Three actions resolve a group. None writes, moves or deletes a file.

- Keep Both (`libraryKeepBoth`, `orca-cli keep-both DATABASE FILE_ID FILE_ID`)
  dismisses the duplicate issues of two files of one group.
- Ignore (`libraryIgnoreDuplicateGroup`, `orca-cli ignore-duplicate DATABASE
  GROUP_ID`) dismisses the duplicate issues of every file of the group.
- Merge Metadata Only (`libraryMergeDuplicateMetadata`, `orca-cli
  merge-duplicate DATABASE KEEP FROM`) gives Track KEEP what Track FROM has and
  KEEP lacks, in one transaction, then reprojects KEEP's files when a value
  changed. Orca values of FROM fill each of KEEP's files that has none for the
  field; a value FROM has locked replaces one KEEP has not locked; a value KEEP
  has locked stays. FROM's user genres replace KEEP's when KEEP has none.
  FROM's rating and feedback are copied only between different recordings and
  only when KEEP's recording has none; copied feedback is queued for
  ListenBrainz. Listens stay with their recording. Merging does not dismiss the
  group.

Dismissals follow [Dismissals](#dismissals).

## Metadata consistency

The consistency pass (`library/consistency_pass.zig`) finds where a Release's
Tracks disagree about its metadata and stores each disagreement as a reviewable
issue in `metadata_proposals`. It reads effective values (a locked Orca value,
then the file's tag, then an unlocked Orca value), user and file genres, and
the values of accepted MusicBrainz matches. It writes no metadata and no file.

`Runtime.startLibraryConsistencyPass` (`orca-cli consistency DATABASE`, or
`orca-cli jobs DATABASE --start=consistency`) runs it as a Job of kind
`consistency`, walking Releases by id in batches of
`ConsistencyRequest.batch_size` (128 by default, at most 512), one transaction
per batch. Its history entry reads `N releases, N metadata issues` and is
listed under the `analysis` history filter.

| Category | Field | Raised when |
| --- | --- | --- |
| `album_artist` | album artist | the Tracks state more than one album artist |
| `dates` | date | more than one date, a date that is not `YYYY`, `YYYY-MM` or `YYYY-MM-DD`, or some state a date and others none |
| `track_numbering` | track number | a disc's Tracks repeat a number or one states none |
| `genre_variants` | genre | the Tracks spell one genre (one `genre_alias` key) more than one way; one issue per genre |
| `musicbrainz_differs` | album, album artist or date | the Tracks agree on a value that differs from the MusicBrainz release their accepted matches name |

The MusicBrainz release is the one most of the Release's accepted matches name.
`musicbrainz_differs` is not raised for the album artist or date when that
field already has an `album_artist` or `dates` issue.

Each issue has options, the values to choose between, and proposals, the Tracks
each option changes. Options are ordered with the MusicBrainz value first, then,
in a `dates` issue whose other dates are less precise forms of one date, that
precise date, then by the number of Tracks stating each. Each option stores that
count and a support text (`N tracks`, `1 track · TITLE`,
`N tracks · MusicBrainz agrees`, `MusicBrainz`, `Year of the dates stated` for a
`dates` issue whose dates are all invalid, `N tracks renumbered`). The single
option of a `track_numbering` issue, `Next free numbers`, keeps the first Track
holding a number on each disc, in path order, and gives every repeat or missing
number the lowest number the disc does not hold. Proposals are listed against
the first option, leave out Tracks whose value is locked, and number at most 512
per issue.

A run replaces the open issues of every Release it examines. An issue's
fingerprint hashes its category, field, genre key and each member file's
current value. A skipped issue (`librarySkipMetadataIssue`,
`orca-cli skip-issue`) stays skipped while a run finds the same fingerprint,
and is raised again as open once the values change. Issue ids are never reused.

`libraryApplyMetadataIssue` (`orca-cli apply-issue DATABASE GROUP
(--option=ID | --custom=TEXT) [--tracks=IDS]`) recomputes the Release's issue
and refuses with `IssueOutOfDate` when its fingerprint changed since the run.
It then writes the chosen value through `libraryEditTracks`, the path
`orca-cli edit` uses: a locked user value per changed Track, reprojected. A
Track whose value is locked keeps it. A genre issue replaces the variant in
each Track's user genres and renames the genre. A custom value must be a valid
date for `dates` and fold to the issue's genre for `genre_variants`;
`track_numbering` takes none. It returns the number of Tracks changed and marks
the issue applied. No media file is written; `write-tags` does that.

`libraryApplyMetadataIssues` applies several issues, each with its own choice
and optionally the only Tracks it changes. It checks every issue before it
changes any: one that is not open (`IssueNotOpen`), out of date, named twice
(`InvalidIssueSelection`), given no Tracks (`NoTracksChosen`) or a Track it does
not cover (`TrackNotInIssue`) leaves them all open. Each issue is checked
against the Release as it was before any changed, because an album or album
artist fix can regroup a Release.

`libraryMetadataIssueCount` and `libraryMetadataIssuePage` count and page open
issues by category and Release through `metadata_proposals_groups`, a partial
index. A page's groups also carry the gap, `missing`, `precision` and
`case_only`. `libraryMetadataIssueStatus` returns the open issues by category,
the Releases they are on, when the pass last succeeded and `stale`: the pass
never ran, or a scan that changed files completed after it.
`orca-cli health --summary` ends with `metadata_issues N`.

## Health issues

`library_health_issues` holds at most one row per file and kind. Each kind has
one owning pass, which records or clears only its own kinds inside its own
write transaction (`recordLocked`, `clearLocked`, `settleLocked`);
`replaceFile` would erase other passes' findings, so production code never
calls it. The rules live in `analysis/health.zig`.

| Kind | Severity | Owner | Raised when |
| --- | --- | --- | --- |
| `missing_metadata` | warning | projection | the effective title, artist or album is blank, judged before the file name stands in for a title |
| `missing_track_number` | information | projection | the file has no track number and was given a synthetic position |
| `album_artist_anomaly` | information | projection | the file has an album but no album artist |
| `artwork_problem` | information | projection | the file has no embedded cover and its Release has no fetched cover |
| `technical_anomaly` | warning | projection | the file's track number is held by another recording |
| `missing_analysis` | information | analysis pass | the audio is too short or silent for an integrated loudness, or has more than two channels |
| `clipping` | warning | analysis pass | see [Clipping](#clipping) |
| `excessive_silence` | warning | analysis pass | more than a fifth of the decoded frames are silent |
| `corrupt_audio` | error | analysis pass | the file would not decode, or decoded past damage |
| `exact_duplicate` | warning | duplicate pass | see [Duplicate detection](#duplicate-detection) |
| `identical_audio` | warning | duplicate pass | see [Duplicate detection](#duplicate-detection) |
| `likely_duplicate` | information | duplicate pass | see [Duplicate detection](#duplicate-detection) |
| `unreadable_file` | warning | property backfill | the file could not be opened or its header would not read |
| `recording_mismatch` | warning | verification | AcoustID hears another recording and a correction was proposed |

The projection settles its kinds for every file it projects: an issue is
recorded while its condition holds and deleted once it does not, and a file
with an `unreadable_file` issue loses them all. A file not analysed yet has no
row; the analysis job's count of files still owing work says that. The
duplicate kinds name the other file in `related_file_id`, which becomes null
when that file is deleted; the issue stays. A copy at a second location of one
file has no related file.

`recording_mismatch` is raised by `recordVerifications` in the transaction that
stores the verification, only when the outcome is `disagrees` and a pending
correction remains, so `review_correction` always has one. A file whose
recording ID is the user's locked edit gets none, nor does one whose correction
was dismissed or accepted. Any other outcome clears it, as does accepting a
proposal of the file and dismissing its last pending one.

### Clipping

A sample is at full scale when its magnitude is at least `1 - 1/32768`. A clip
is a run of at least three consecutive full-scale samples in one channel; a
single one is a peak. Runs carry across decode blocks, and samples of different
channels never join a run. `clipped_samples` counts only samples inside runs,
and the details read `N clipped runs (M samples at full scale)`.

### Dismissals

`Runtime.libraryDismissHealthIssue` (`orca-cli health-dismiss`) hides one kind
on one file. `health_dismissals` keeps the file's `quick_hash` at the time, and
the page and count leave out an issue whose dismissal holds the hash the file
still has, so the issue shows again once the file's bytes change. A file never
hashed is dismissed under a null hash and stays hidden. The issue row is
untouched, and `libraryRestoreHealthIssue` (`orca-cli health-restore`) drops the
dismissal. Deleting an issue keeps its dismissal, so an issue raised again
while the file keeps that hash stays hidden. A dismissal goes with its file.

### By kind

`Runtime.libraryHealthSummary` (`orca-cli health --summary`) returns a
`HealthSummary`: one `HealthKindSummary` per kind with at least one
non-dismissed issue, holding its count, highest severity, `files` and their
summed `bytes`, ordered by severity then kind. The counts sum to
`libraryHealthIssueCount`. For the duplicate kinds, `bytes` is what removing the
redundant copies would free: the kept copy is the one Duplicates suggests
keeping (see [Duplicate detection](#duplicate-detection)), taken within the
groups the links of that kind make, and a duplicate held as a second
location of one file row counts its size once per present location beyond the
first. `libraryHealthIssuePageOfKind`
(`orca-cli health --kind=KIND`) pages the issues of one kind in the order of
`libraryHealthIssuePage`. `libraryArtworkProblemReleasePage` and
`libraryArtworkProblemReleaseCount`
(`orca-cli health --kind=artwork_problem --albums`) page and count Releases with
visible `artwork_problem` issues, each once with its worst problem (a missing
front, then a conflict, then an undersized cover), its details and how many of
its files have one. A file's Release is that of the lowest Track id it backs.

### Actions

`HealthIssue` names the lowest Track id the file backs (`track_id`), that
Track's Release (`release_id`), and `action`, what a host offers to resolve it.
`Runtime.libraryHealthFile` returns the file's path, codec, format, size and
length, and whether every location is missing, for `reveal_file`.

| Action | Kinds |
| --- | --- |
| `match_or_edit` | `missing_metadata`, `missing_track_number`, `album_artist_anomaly`; `artwork_problem` when the Release has no MusicBrainz release ID |
| `fetch_cover_art` | `artwork_problem` when the Release has a MusicBrainz release ID, tagged or named by its accepted matches |
| `compare_duplicate` | `exact_duplicate`, `identical_audio`, `likely_duplicate` |
| `review_correction` | `recording_mismatch` |
| `reveal_file` | every other kind |

Storing a fetched cover (`ReleaseArtworkRepository.put` with an image) clears
`artwork_problem` for every file of the Release's Tracks in the same
transaction. A recorded miss clears nothing.
