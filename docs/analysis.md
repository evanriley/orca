# Audio analysis

`analysis/` measures what a file's audio *is*: integrated loudness (a gated
ITU-R BS.1770 mean, summing every channel's K-weighted energy with weight
1.0), a ReplayGain figure derived from it, sample peak, RMS,
clipped samples, leading/trailing/total silence, a bucketed waveform, a
temporal fingerprint with a decoded-audio hash, and the AcoustID fingerprint.
`analysis/service.zig` runs all of that in one streaming pass over a
`ReadableSource`, so a file is decoded once no matter how many of those
numbers a caller wants.

Two things use the result: **ReplayGain on playback**, and duplicate detection.
Neither can use a measurement that does not exist, which is what
`library/analysis_pass.zig` is for.

## AcoustID fingerprints

`analysis/chromaprint.zig` computes the fingerprint AcoustID matches on, the
way `fpcalc` does: the first 120 s of a file, decoded by Orca's codecs, mixed
to mono, resampled to 11,025 Hz by libsamplerate (`resampler.SampleRate`,
`sinc_fastest`), converted to 16-bit and fed to Chromaprint's default
algorithm (`TEST2`) behind `chromaprint_shim.c`. The result is Chromaprint's
compressed, base64 fingerprint and the whole file's length; a file shorter
than 120 s is fingerprinted whole. Chromaprint is built without its own
resampler, which is LGPL and accepts only 11,025 Hz input; see
[architecture.md](architecture.md#dependencies-and-licences).

- **No partial fingerprints.** Any decode error while reading the window fails
  the fingerprint. Nothing is cached or sent for that file, and it is tried
  again next time.
- **Cached per file.** A fingerprint is stored in `analysis_results` as kind 3,
  `orca.chromaprint` version 1, under a parameter hash of the algorithm, the
  libsamplerate converter and the window length, and the content hash of the
  bytes it was taken from. Changing any of them takes a new fingerprint. The
  stored result is the length in milliseconds (8 bytes, little-endian)
  followed by the fingerprint.
- **Agreement with `fpcalc`.** A unit test holds Orca's fingerprint of
  the generated reference recording (`fixtures/audio/fingerprint-reference.mp3`)
  to at least 95 % bit agreement with `fpcalc`'s
  (`fixtures/audio/fingerprint-reference.fpcalc.txt`).

`chromaprint.Analyzer` takes the fingerprint from audio fed to it a chunk at a
time, so the analysis service takes it in the same decode as everything else
and the analysis pass stores it where a standalone fingerprint is cached:
matching and AcoustID submission then find it there instead of decoding the
file again. Audio too
short to fingerprint is measured without one. The service feeds the analyzer
the chunks a standalone fingerprint reads, and a unit test holds the two
fingerprints of `fixtures/audio/fingerprint-reference.mp3` byte-identical.

Matching and AcoustID submission take the fingerprints the pass has not stored
yet as they need them; `Runtime.libraryTrackFingerprint` and
`orca-cli fingerprint` take one for a single Track.

## The pass

`library/analysis_pass.zig` measures every file in a Library that has not been
measured yet. It is a runtime job (`Runtime.startLibraryAnalysis`,
`orca_library_start_analysis`, `orca-cli analyze-library`) built on exactly the
machinery the property backfill uses: the shared `JobWorker`, the same
cancellation token, the same job snapshot, bounded commits, and row selection
through an indexed query rather than a walk.

One difference governs the rest of the design: **the backfill reads headers,
this decodes whole files.** A probe reads a header; a measurement decodes every
sample, so a library-wide run is long. Cancellation, resumption and progress are
therefore load-bearing rather than polite, and the Library's single write lane
is never held across a decode — the decode happens outside any transaction, and
only the finished measurements enter one.

### What "already analyzed" means

The selection key is the analysis cache key itself, minus the file, for each
of the two measurements the pass stores — the diagnostics and the temporal
fingerprint (`analysis.service.analysisSelectors`):

```
kind, algorithm_id, algorithm_version, parameter_hash   +   source_identity
```

A file still owes work when, for either measurement, no `analysis_results` row
exists for it under that key with `source_identity = files.content_hash` and
`files.content_hash_algorithm = 1`. A file with no content hash recorded always
owes work. Bumping either algorithm's version therefore re-selects every file.
That key is the right one because it *already* encodes every reason a stored
measurement stops counting, and a marker column on `files` would be a second
source of truth free to disagree with the results it claims to describe:

- the bytes changed — `source_identity` no longer matches, because a scan that
  sees a file's inode, size or mtime change without hashing it forgets the
  content hash;
- the algorithm changed — `algorithm_version` no longer matches;
- the parameters changed — `parameter_hash` no longer matches.

`analysis_results` is `WITHOUT ROWID` with exactly those six columns as its
primary key, so each candidate row costs at most two full-prefix B-tree probes
and no index had to be invented. `EXPLAIN QUERY PLAN` on the page query:

```
|--SEARCH files USING INTEGER PRIMARY KEY (rowid>?)
|--CORRELATED SCALAR SUBQUERY 2
|  `--SEARCH analysis_results USING COVERING INDEX analysis_results_current
|     (file_id=? AND kind=? AND algorithm_id=? AND algorithm_version=?
|      AND parameter_hash=? AND source_identity=?)
|--CORRELATED SCALAR SUBQUERY 3
|  `--SEARCH analysis_results USING COVERING INDEX analysis_results_current
|     (file_id=? AND kind=? AND algorithm_id=? AND algorithm_version=?
|      AND parameter_hash=? AND source_identity=?)
`--CORRELATED SCALAR SUBQUERY 1
   `--SEARCH locations USING INDEX locations_file (file_id=?)
```

The predicate has one definition, `repository.unanalyzed_predicate`, shared by
the page query, the count that gives the job its denominator, and the plan test
that asserts none of it is a table scan.

There is **no force mode**, and that is the difference from the backfill. A
backfill needs one because a re-probe writes the same numbers and so cannot be
told apart from a stale value; an analysis result carries its algorithm
version, its parameters and the identity of the bytes it was taken from, so
every reason to measure a file again is already a reason the selection sees it.

### Outcomes

- **Measured.** The encoded diagnostics and temporal fingerprint, the AcoustID
  fingerprint unless the audio is too short for one, the decoded-audio hash
  into `files.audio_hash` and its tier into `files.audio_hash_tier` (tier 4 of
  the identity cascade — the only tier that survives Orca's own tag writes;
  see [the audio hash](#the-audio-hash)), `corrupt_audio` cleared and `clipping`,
  `excessive_silence` and `missing_analysis` raised or cleared, all in one
  bounded transaction per batch. A file with no gateable loudness — too short,
  or silent — is still stored, so it is not re-decoded on every run; it
  yields no correction and raises `missing_analysis`. Every result is keyed by
  the content hash of the bytes decoded, taken in a second sequential read of
  the whole file beside the decode, and the same transaction records that hash
  on the file (see [database.md](database.md#schema)).
- **Declined.** Not reachable, not audio, or the identity the Library recorded
  is not the file's identity any more: the quick hash differs, the content hash
  read is not the one the file records, or, with none recorded, the inode, size
  or mtime read is not what the location records. The same checks run again
  under the write lane, so a scan that recorded other bytes meanwhile declines
  the file rather than keying its results to them. Counted, no health issue:
  `locations.state` already models absence, a stale identity is a scan's job to
  repair, and filing a defect for every file on an unmounted drive would bury
  every real finding. The identity check happens *before* the decode, on two
  64 KiB reads, because a stale row is selected again on every run and paying a
  whole decode to reach the same conclusion each time would make a drifted
  library as expensive as an unmeasured one.
- **Corrupt.** A file that opened and would not decode raises `corrupt_audio`
  and clears the pass's other three kinds, which describe audio it could not
  read.
  Not `unreadable_file`: that kind belongs to the property backfill, and the
  split is deliberate in both directions — a header-only pass must not be able
  to clear a finding made by reading audio it never looked at, and a pass that
  decoded the whole stream owns the kind that says the stream is bad.

### Bounds

Batch size defaults to 32 rather than the backfill's 256. A batch is the unit
of work an interrupted run throws away, and here one unit is a whole file
decoded end to end. The cursor is a `files.id`, so a file this run declined
does not make the next page re-serve it, and a run that stops resumes by asking
the same question and getting a shorter answer — there is no checkpoint of its
own.

`orca-cli analyze-library` builds its runtime on `std.heap.smp_allocator`
rather than on the process arena: the arena would keep every decoded file's
buffers until the run ends.

### Threads

A batch's files are decoded by `min(threads, files in the batch)` threads at
once: the job's own thread and helpers it starts for that batch. Each thread
claims the next file of the batch, measures it with its own `std.Io`, and
keeps the result in that file's slot. The job's thread then joins every helper
and commits the slots in `files.id` order in one transaction, exactly as one
thread would. No helper touches SQLite.

- `AnalysisRequest.threads` sets the count; `orca_analysis_options.threads`
  and `orca-cli analyze-library --threads=N` reach it. Unset (zero in the C
  ABI) takes `analysisDefaultThreads()`: one fewer than
  `analysisAvailableThreads()`, the logical processors, and at least 1, so
  playback keeps a processor. There is no upper limit, but a batch is all the
  work there is to share, so more than 32 threads needs a larger
  `batch_size`.
- One thread, or a batch of one file, starts no helper. A helper that fails to
  start leaves its share to the threads that did.
- Cancellation stops every thread from claiming another file. Files already
  measured are committed; a file abandoned mid-decode or never claimed is not
  counted, and the next run selects it again.
- Any other error, such as running out of memory, fails the batch: every
  thread is joined and nothing of the batch is committed.
- Progress counts each file as its thread finishes it.
- The thread count does not change the results: a unit test holds a
  four-thread run's `analysis_results` rows and audio hashes byte-identical to
  a one-thread run's.

## ReplayGain on playback

The correction is a property of the **audio**, not of the Player. Each
`SourceSession` carries the linear corrections for the bytes it is decoding,
track and album (`EntryReplayGain`), and scales the frames it produces by the
one the mode selects. `Gain` is user volume and nothing else.

That placement is the whole design, and it follows from where a gapless
transition puts the audio. During one, the render pipe holds prepared blocks
belonging to two entries at the same time, so a single Player-level multiplier
is wrong for one of them for the entire lookahead window, and for a whole track
when nothing corrects it afterwards. A value published per *block* and keyed on
`entry_serial` is closer but still not right: `SourceQueue.readFrames` fills one
canonical block from two decoders across the boundary, so up to 256 frames of
every transition would carry the neighbour's correction. A value applied per
decode cannot, because the decoder that produced the frames is the one that owns
the figure.

- **One attachment point.** `TrackSourceOpener.openTrack` is the only place a
  queue entry becomes audio, so it is the only place the correction is
  attached. A hard load, a gapless auto-advance, a deferred format switch and a
  seek that re-opens the audible entry all go through it. Nothing publishes a
  correction, so nothing can forget to.
- **Absence is unity, never inheritance.** An entry with no usable correction
  carries 1. Playing one track at another track's loudness is the exact failure
  the feature exists to prevent, and it would be silent.
- **Provenance is checked against the bytes, not the row.** The lookup is keyed
  on the file's recorded content hash, and only while the file just opened
  still has the quick hash the file records and the inode, size and mtime its
  location records (`AnalysisCacheRepository.vouchedContentHash`), because the
  Library's record is only as fresh as the last scan. A file edited since then
  plays at unity instead of at a correction measured from audio it no longer
  contains. That costs one extra open, a stat and two 64 KiB reads per track
  load, against a decode of the whole file; hashing the whole file would read
  it all before the first frame plays.
- **Canonical parameters only.** The Player asks for the measurement made under
  the default `diagnostics.Parameters`, which is what the pass produces. A
  library measured under other parameters is a different measurement and is not
  adopted — the target LUFS is one of those parameters, so adopting an
  arbitrary one would apply a correction toward a target nobody chose.
- **A boost is capped at `1 / peak`.** Bringing a quiet track up only as far as
  its headroom allows is a deliberate quietening of the correction rather than
  a limiter, because a limiter would change the audio rather than its level.
  The session keeps the uncapped gain and the peak, and the cap is applied at
  decode while `ReplayGainSettings.peak_protection` is on (the default);
  `SignalPath.peak_limited` says when it lowered the audible correction.
- **`ReplayGainMode` is `off`, `track`, `album` or `smart`.** Album correction
  is described below. `smart` takes the album correction while the entry
  before or after it in playback order belongs to the same Release, and the
  track correction otherwise, so an album played through keeps its levels and
  a shuffled mix is levelled per track.
- **Preamp and fallback.** `ReplayGainSettings.preamp_db` (clamped to ±15 dB)
  is added to every measured correction before the peak cap.
  `ReplayGainSettings.fallback` sets the level of an entry with no usable
  measurement: `as_is` (unity, the default) or `minus_6_db`. The preamp does
  not apply to the fallback.
- **Only Orca's own measurements are used.** No reader observes a file's
  `REPLAYGAIN_*` tags, so a file Orca has not analysed plays at the untagged
  fallback in every mode.

### Album ReplayGain

`album` corrects every Track of a Release by the same figure, so the levels
within an album stay as mastered.

- **Computed at open, never stored.** `TrackSourceOpener.openTrack` works the
  album figure out as it attaches the track figure, from one bounded statement
  over the entry's Release (`AnalysisCacheRepository.visitReleaseMembers`).
  Nothing is cached per Release, so re-analysing a Track or moving it to
  another Release cannot leave a stale album figure behind: the next open of
  any Track of the Release uses the new measurements. There is no schema
  change.
- **Loudness: a duration-weighted energy mean.** The album's integrated
  loudness is `10·log10(Σ dᵢ·10^(Lᵢ/10) / Σ dᵢ)` over the Tracks' integrated
  loudness `Lᵢ` and durations `dᵢ`; the album gain is the canonical target
  (−18 LUFS) minus it. Exact BS.1770 gating over the album's merged 400 ms
  blocks would need every block's energy, and the stored result keeps only
  each file's gated loudness. Measured on synthetic Releases, the mean is
  0.007 LU from exact gating for steady material and 1.88 LU louder for a
  Release with long quiet or silent passages, which the per-file relative
  gates exclude and the album's gate would not; for the fixture files as one
  Release the difference is 0.78 LU.
- **Peak: the largest Track peak.** The boost cap uses the loudest Track's
  sample peak, so no Track of the album clips.
- **Fallback is visible.** An entry whose Release has a Track with no stored
  measurement for its recorded bytes, a Track with no duration, more than 512
  Tracks, or that has no Release, plays at its own track correction, and
  `SignalPath.replay_gain_source` is `track_fallback`. A Track measured with
  no gated loudness (too short or too quiet) adds no energy and no duration
  but still counts toward the peak.
- **Whose measurement.** The entry's own measurement is keyed on the bytes just
  opened, as in track mode. Every other member's is keyed on
  `files.content_hash`, because checking every file of the album at each open
  would cost a disc's worth of reads per track.
- **What a host sees.** `SignalPath` carries the applied gain
  (`replay_gain_db`), its source (`replay_gain_source`: `none`, `track`,
  `album` or `track_fallback`) and, for an album correction, the entry's own
  track correction it replaced (`replay_gain_track_db`).

### Where each lane's work happens

The opener reads SQLite, including the Release statement in album mode, and two
64 KiB file ranges. That happens on whichever
lane opens the entry — the control lane for a hard load, the **engine thread**
for an auto-advance. Both already resolve a Location and open a file there, and
opening is not the decode path: it happens once per entry, and it is
emphatically not the render callback, which still only copies prepared blocks.
Pre-resolving corrections on the control lane instead would mean guessing which
entry auto-advance is about to pick, which repeat and shuffle make unknowable
until it picks it.

### Turning it off

The mode is a Player atomic that the decode lane reads per canonical block,
rather than something baked into a session when it is opened. Baking it in
would mean a host that turns correction off heard nothing change until the next
track — up to several minutes of a control that appears not to work. Reading it
per block instead means the change takes effect as the audio already decoded
ahead of the listener drains, a fraction of a second.

The cost is disclosed rather than hidden: the level then *steps* rather than
ramping, by however much the entry was being corrected. That step is the answer
to an explicit request, and it is the smaller of the two problems. `off` is
exactly 1 — the multiply is skipped entirely, not multiplied by a float that
happens to be one.

### What a host sees

`playerEffectiveGain` / `orca_player_effective_gain` reports volume times the
correction of the entry actually being *heard*, resolved through the same
`entry_serial` that identity, duration and position resolve through, so all
four describe one entry. It reports rather than drives: nothing multiplies by
it.

`tests/root.zig` plays a loud and a quiet fixture through the runtime and
asserts that both land within 1 dB of the target after correction, which is the
check that catches a correction applied with the wrong sign.

## Duplicate detection

`library/duplicate_pass.zig` reports every file whose audio the Library also
holds somewhere else. It is a runtime job (`Runtime.startLibraryDuplicateScan`,
`orca_library_start_duplicate_scan`, `orca-cli duplicates`) on the same
`JobWorker` machinery as the scan, the projection, the property backfill and
the analysis pass: the same cancellation token, the same job snapshot, bounded
commits, and row selection through an indexed query.

`fingerprint.classifyDuplicate` is the only pairwise comparison in the
codebase; the pass decides which pairs are worth handing it, and never holds
every fingerprint at once.

**This pass opens no files.** Everything it compares, the analysis pass already
measured and stored, so a run costs indexed lookups and stored-fingerprint
comparisons rather than decodes, and asking the question a second time does not
mean measuring the library a second time.

### What the three findings mean

Each finding states only what was proven. A file gets the strongest that
holds, and at most one.

- **`exact_duplicate`** (warning) — the same bytes are stored more than once,
  and a person can act on it without listening to anything. It rests on the
  full-content BLAKE3-256 hash, never on the quick hash or the audio:
  1. one `files` row with a second `present` location. A byte-identical copy
     is not a second `files` row, because the scanner's identity cascade
     resolves it by quick hash, confirmed by content hash, to the row that
     already exists; the Library models it as one file at two present
     locations, so no amount of comparing rows could ever find it. A copy
     whose bytes change leaves for a file of its own (see
     [database.md](database.md#identity)). Or
  2. two `files` rows recording the same `files.content_hash` with
     `content_hash_algorithm` 1, such as two copies changed the same way in
     one scan batch.
- **`identical_audio`** (warning) — different bytes, the same audio: two
  `files` rows whose `files.audio_hash` is equal and of tier 1, lossless
  integer samples (see [the audio hash](#the-audio-hash)). A WAV and the FLAC
  made from it, or an ALAC and a FLAC of one master, whatever the container,
  the width or the tags claim. It is a warning like `exact_duplicate` because
  it is as certain: keeping either copy loses no audio. Equal tier-2 hashes
  are reported as `likely_duplicate` instead.
- **`likely_duplicate`** (information) — the audio only *resembles* another
  file's, above a similarity threshold, or two lossy or float decodes hash
  alike, and the claim will sometimes be wrong. It is worth making because it
  catches the case the certain tests structurally cannot: a lossy transcode of
  the same master decodes to different samples and so hashes differently,
  while remaining the same recording twice on disk. The message carries the
  match percentage, because a claim that can be wrong should travel with the
  number behind it.

The threshold is **0.985**, and it is measured rather than chosen; the
figures behind it are on `likely_threshold` in
`library/duplicate_pass.zig`. The fingerprint's floor for *unrelated* music is
not zero: four coarse bins per 50 ms block agree by chance most of the time, so
the usable band is the top two percent of the scale. 0.985 is the widest gap in
that band: above unrelated tracks of the same length and above a track's own
instrumental or karaoke cut, below transcodes of one master.

The margin above the line is thinner than the margin below it. Dense
electronic material transcodes further from its own fingerprint than pop
masters do, and a real FLAC-and-MP3 pair can score within 0.001 of the line. If
the pass misses a known transcode, this is the number to revisit; between about
0.96 and 0.985 the fingerprint stops separating a transcode from an unrelated
track of the same length.

`exact` outranks `identical` and `identical` outranks `likely` rather than
accompanying them. They are strengths of one claim, and telling somebody a
file is both certainly and probably a duplicate of something helps them
decide nothing.

### The four indexed queries

| question | query | plan |
| --- | --- | --- |
| which file next | `files.id > ?` | `SEARCH files USING INTEGER PRIMARY KEY (rowid>?)` |
| same-bytes bucket | `content_hash = ? AND content_hash_algorithm = 1` | `SEARCH files USING INDEX files_content_hash (content_hash=?)` |
| same-audio bucket | `audio_hash = ? AND audio_hash_tier = 1` | `SEARCH files USING INDEX files_audio_hash (audio_hash=?)` |
| plausible bucket | `duration_ms BETWEEN ? AND ?` | `SEARCH files USING INDEX files_duration (duration_ms>? AND duration_ms<?)` |

None of the four is a scan. `files_content_hash` serves the same-bytes
bucket, `files_audio_hash` the same-audio bucket and
`files_duration ON files(duration_ms, id)` the plausible one.

Duration is the bucket key for the plausible half because length is the
cheapest necessary condition for two files being the same recording and the
only one an index can answer. The default tolerance is **±250 ms**: two
encodings of one master differ only by codec padding — an MPEG encoder's delay
and its final partial frame come to a few tens of milliseconds — so a quarter
of a second is generous for the case that exists to catch, while a wider window
finds the same matches after comparing proportionally more files and eventually
starts admitting genuinely different recordings that happen to run the same
length.

### Bounds

A bucket holds at most **`max_bucket_peers` = 64** files, which is what turns
O(n²) into O(n): the work is bounded by a constant per file rather than by the
size of the library. At most **two decoded fingerprints are resident at any
moment** — the candidate's and the one peer being compared against it. A bucket
that hits the cap is *counted* (`truncated_buckets`), because some pairs inside
it went uncompared and a scan that quietly stopped looking would be the same lie
of omission as the one below.

Batches are 256 files and commit in one transaction, and the cursor is a
`files.id`.

The pass is **restartable rather than incremental**, and that is a property of
the question rather than a shortcut. Whether a file is a duplicate is a
relation between rows: adding one file can make an existing file a duplicate
and deleting one can stop it being one, so there is no subset of rows that
still owes work and nothing to resume *from*. A cancelled run keeps every
batch it committed; the next run examines the library again from the start.

### A file with no measurement

Most of a library carries no `audio_hash` until the analysis pass has reached
it, and nothing can be said about such a file: it cannot be compared, and it
cannot be found as somebody else's duplicate either. Reporting "no duplicates"
over such a library would be a lie of omission, so those files are counted as
**uncomparable** and the count is printed on its own line. A zero-finding run
with a large uncomparable count means *not measured*, not *no duplicates*.

No health issue is filed per uncomparable file. The count already says it, and
one fresh defect per file on an unanalyzed library would bury every real
finding — the same argument the analysis pass makes about absent files.

### Re-running

Every examined file has **all three** of this pass's kinds rewritten, present
or absent, so a file whose copy now holds other bytes of the same audio loses
its `exact_duplicate` as it gains `identical_audio`. That is
`library_health_issues`' replace-by-file semantic narrowed to the three kinds
this pass owns: `replaceFile` would also erase the corruption and
metadata findings other passes made, and an insert-only pass would let a
duplicate that has since been deleted keep its report for ever. Recording is an
upsert on `(file_id, kind)`, so a second run converges on the same rows rather
than doubling them.

Both members of a pair are reported, because either is the one somebody might
delete.

### The audio hash

`files.audio_hash` is an ORAH version 2 digest, taken by
`analysis.fingerprint.AudioHasher` in the same decode as the temporal
fingerprint:

```
BLAKE3( header || BLAKE3(samples) )

header (21 bytes, little-endian):
  "ORAH"  u16 version = 2  u8 tier  u32 sample_rate  u8 channels
  u8 layout = 0 (interleaved, source order)  u64 frames
```

The frame count is known only when the stream ends, so the header commits to
the digest of the samples rather than preceding them. Two streams that differ
in sample rate, channel count, tier or length never share a hash, whatever
their samples.

The tier says what the samples are, and is stored in `files.audio_hash_tier`:

| tier | samples hashed | sources |
| --- | --- | --- |
| 1, lossless integer | each sample as an `i32` left-justified in 32 bits, little-endian | FLAC, ALAC, integer WAV, integer AIFF and AIFC |
| 2, decoded float | the bits of each decoded `f32`, little-endian | float WAV and AIFF, MP3/MP2/MP1, AAC, Opus, Vorbis, QOA |

Tier 1 reads the source's own integers through `Decoder.readFramesI32`, so the
hash is exact at any width: two 32-bit samples one LSB apart hash differently
although they narrow to the same `f32`. Left-justification makes the container
width irrelevant, so 16-bit audio in FLAC, in a 16-bit WAV and in a 24-bit WAV
hashes identically. The effective width — 32 minus the trailing zero bits
common to every sample, 16 for 16-bit audio in a 24-bit container — is kept in
the stored fingerprint result.

Tier 2 is one decoder's rendering. A lossy stream decodes differently in
another decoder or another decoder version, and a float source has no integer
form to compare, so equal tier-2 hashes support only `likely_duplicate`.
Hashes of different tiers never compare equal.

The audio hash travels in the temporal fingerprint result (`ORFP` version 2,
which refuses version 1). `fingerprint_algorithm_version` 3 marks the change, so
every file measured under an earlier version is selected and measured again.

### The identical-audio test and decoding

The identical-audio test holds because a tier-1 `files.audio_hash` is a
function of the audio: the lossless decoders return the integers the file
encodes, and FLAC decodes bit-exactly through libFLAC (see
[codecs.md](codecs.md#flac)). Two lossless files holding identical PCM at the
same rate and channel count hash identically whatever their container, width
or encoder settings, and are reported as `identical_audio`. Equal audio says
nothing about equal bytes, so only the content hash makes `exact_duplicate`.

### Groups

`Runtime.libraryDuplicateGroupPage` (`orca-cli duplicates DATABASE
--groups`) joins the visible `exact_duplicate`, `identical_audio` and
`likely_duplicate` issues into groups: files linked by an issue, directly or through another file, are
one group, and a file held at several present locations is a group on its
own. A group's id is its lowest file id, so it is the same on every read
while its issues are unchanged; grouping runs over the visible issues on each
read and stores nothing. Issues naming a file that no longer exists are left
out.

`DuplicateGroup` carries the suggested copy's title and artist, `copies`
(each further location of a file counting as one), `same_recording` (every
file is an encoding of one recording, so the copies share one play count and
rating), `similarity`, `verdict` and `bytes_redundant`, what removing every
copy but the suggested one frees. `similarity` is the lowest score among the
group's `likely_duplicate` links, 1 for exact and identical-audio links, read
from `library_health_issues.similarity`; it is null when a link was recorded
before that column existed. `verdict`, a `DuplicateVerdict`, is the weakest
kind among the group's links, so it states what holds for every copy: a
group joined by one `exact_duplicate` and one `likely_duplicate` link is
`likely_duplicate`. The C ABI carries it as an `orca_health_issue_kind` in
`orca_duplicate_group_view.verdict`. `libraryDuplicateGroupTotals` sums the groups
and their bytes. Those bytes can differ from the duplicate bytes of
[By kind](#by-kind), which counts the lowest-numbered file as the kept copy
rather than the suggested one.

`Runtime.libraryDuplicateGroup` (`orca-cli duplicates DATABASE --group=ID`)
returns a group's files, the suggested copy first. Each `DuplicateCopy` holds
the lowest Track id the file backs, that Track's `TrackDetails` with this
file's format, size, path and loudness, the number of playlists holding its
recording, and its present locations. The suggested copy is the lossless one
over the lossy, then the higher sample rate, the higher bit depth and the
larger file, and the lower file id on a tie.

### Resolving a group

Three actions resolve a group. None writes, moves or deletes a file.

- **Keep Both** (`libraryKeepBoth`, `orca-cli keep-both DATABASE FILE_ID
  FILE_ID`) dismisses the duplicate issues of two files of one group.
- **Ignore** (`libraryIgnoreDuplicateGroup`, `orca-cli ignore-duplicate
  DATABASE GROUP_ID`) dismisses the duplicate issues of every file of the
  group.
- **Merge Metadata Only** (`libraryMergeDuplicateMetadata`, `orca-cli
  merge-duplicate DATABASE KEEP FROM`) gives Track KEEP what Track FROM has
  and KEEP lacks, in one transaction on the write lane, then reprojects KEEP's
  files when a value changed. Orca values of FROM's file fill each of KEEP's
  files that has no value for the field, and a value FROM has locked replaces
  one KEEP has not; a value KEEP has locked always stays. FROM's user genres
  replace KEEP's genres when KEEP has no user genres. FROM's rating and
  feedback are copied only when the two Tracks are different recordings and
  KEEP's recording has none; copied feedback is queued for ListenBrainz.
  Listens stay with their recording. Merging does not dismiss the group.

Dismissals follow [Dismissals](#dismissals): an issue shows again once the
file's bytes change. Moving a copy to the trash is not offered.

### Memory

`orca-cli duplicates` builds its runtime on `std.heap.smp_allocator` rather
than on the process arena most subcommands use. The pass frees each
fingerprint as soon as it has been compared, and an arena does not honour that:
it would keep one fingerprint per comparison for the length of the run.

## Metadata consistency

The consistency pass (`library/consistency_pass.zig`) finds where a
Release's Tracks disagree about its metadata and stores each disagreement
as a reviewable issue in `metadata_proposals`. It reads effective values (a
locked Orca value, then the file's tag, then an unlocked Orca value), the
user and file genres, and the values of accepted MusicBrainz matches. It
writes no metadata and no file: applying an issue is a separate, explicit
step.

`Runtime.startLibraryConsistencyPass` (`orca-cli consistency DATABASE`, or
`orca-cli jobs DATABASE --start=consistency`) runs it as a Job of kind
`consistency`. It walks Releases by id in batches of
`ConsistencyRequest.batch_size` (128 by default, at most 512), one
transaction per batch on the write lane, checks for cancellation and pause
between batches, and reports Releases examined against the Release count.
Its history entry reads `N releases, N metadata issues` and is listed under
the `analysis` history filter.

### Categories

| Category | Field | Raised when |
| --- | --- | --- |
| `album_artist` | album artist | the Tracks state more than one album artist |
| `dates` | date | the Tracks state more than one date, a date that is not `YYYY`, `YYYY-MM` or `YYYY-MM-DD`, or some state a date and others none |
| `track_numbering` | track number | a disc's Tracks repeat a number or one states none |
| `genre_variants` | genre | the Tracks spell one genre (one `genre_alias` key) more than one way; one issue per genre |
| `musicbrainz_differs` | album, album artist or date | the Tracks agree on a value that differs from the MusicBrainz release their accepted matches name |

The MusicBrainz release is the one most of the Release's accepted matches
name, with its title, artist and date from the match payload.
`musicbrainz_differs` is not raised for the album artist or date when that
field already has an `album_artist` or `dates` issue.

### Options and support

Each issue has options, the values to choose between, and proposals, the
Tracks each option changes. Options are ordered with the MusicBrainz value
first, then, in a `dates` issue whose other dates are all less precise forms
of one date (`2016` and `2016-08` of `2016-08-20`), that precise date, then
by the Tracks stating each, most first. Each option stores the count of
Tracks stating it. Its support text says why it is offered:

- `N tracks`: the Tracks stating it.
- `1 track · TITLE`: the one Track stating it, by title, outside
  `track_numbering` issues.
- `N tracks · MusicBrainz agrees`: as well, the MusicBrainz release states it.
- `MusicBrainz`: only the MusicBrainz release states it.
- `Year of the dates stated`: a `dates` issue whose dates are all invalid
  offers the year found in them.
- `N tracks renumbered`: the single option of a `track_numbering` issue,
  `Next free numbers`. On each disc, in path order, the first Track holding a
  number keeps it, and every repeat or missing number takes the lowest number
  no Track of the disc holds. The issue records the gap: the lowest such
  number below the highest number the disc states, as 6 when a repeated 5
  is followed by 7.

Proposals are listed against the first option and leave out Tracks whose
value is locked, at most 512 per issue.

### Re-running, skipping and applying

A run replaces the open issues of every Release it examines, so a Release
that is consistent now has none. An issue's fingerprint hashes its category,
field, genre key and each member file's current value. A skipped issue
(`librarySkipMetadataIssue`, `orca-cli skip-issue`) stays skipped while a run
finds the same fingerprint, and is dropped, and raised again as open, once
the values change. Issue ids are never reused.

`libraryApplyMetadataIssue` (`orca-cli apply-issue DATABASE GROUP
(--option=ID | --custom=TEXT) [--tracks=IDS]`) first recomputes the
Release's issue and refuses with `IssueOutOfDate` when its fingerprint
changed since the run. It then writes the chosen value through `libraryEditTracks`, the path
`orca-cli edit` uses: a locked user value per changed Track, reprojected. A
Track whose value is locked keeps it. A genre issue replaces the variant in
each Track's user genres and renames the genre. A custom value must be a
valid date for `dates` and fold to the issue's genre for `genre_variants`;
`track_numbering` takes none. It returns the number of Tracks changed and
marks the issue applied. No media file is written; `write-tags` does that.

`libraryApplyMetadataIssues` applies several issues, each with its own
choice and, optionally, the only Tracks it changes; the others keep their
values and the issue is still marked applied. It checks every issue before
it changes any: one that is not open (`IssueNotOpen`), out of date, named
twice (`InvalidIssueSelection`), given no Tracks (`NoTracksChosen`) or a
Track it does not cover (`TrackNotInIssue`) leaves them all open. Each issue
is checked against the Release as it was before any of them changed, which
matters because an album or album artist fix can regroup a Release.

`libraryMetadataIssueCount` counts the open issues, of one category or all,
and `libraryMetadataIssuePage` pages them, by category and Release. Both use
`metadata_proposals_groups`, a partial index over the issue rows. A page's
groups also carry the gap, `missing` (the changes to a Track with no
value), `precision` (a precise-date `dates` issue) and `case_only` (options
that differ only in letter case, as a title MusicBrainz capitalises
differently). `libraryMetadataIssueStatus` returns the open issues by
category, the Releases they are on, when the pass last succeeded (from the
Job history) and `stale`: the pass never ran, or a scan that changed files
completed after it; a scan that found nothing new leaves the issues current.
`orca-cli health --summary` ends with `metadata_issues N`.

## Health issues

`library_health_issues` holds at most one row per file and kind. Each kind has
one owning pass, which records or clears only its own kinds, inside its own
write transaction, with `recordLocked`, `clearLocked` or `settleLocked`.
`replaceFile` would erase other passes' findings, so production code never
calls it. The rules and their wording live in `analysis/health.zig`.

| Kind | Severity | Owner | Raised when |
| --- | --- | --- | --- |
| `missing_metadata` | warning | projection | the effective title, artist or album is blank, judged before the file name stands in for a missing title |
| `missing_track_number` | information | projection | the file has no track number and was given a synthetic position |
| `album_artist_anomaly` | information | projection | the file has an album but no album artist |
| `artwork_problem` | information | projection | the file has no embedded cover and its Release has no fetched cover |
| `technical_anomaly` | warning | projection | the file's track number is held by another recording |
| `missing_analysis` | information | analysis pass | the measured audio is too short or silent for an integrated loudness |
| `clipping` | warning | analysis pass | one channel has a run of at least three consecutive samples at full scale; see [Clipping](#clipping) |
| `excessive_silence` | warning | analysis pass | more than a fifth of the decoded frames are silent |
| `corrupt_audio` | error | analysis pass | the file opened and would not decode |
| `exact_duplicate` | warning | duplicate pass | see [Duplicate detection](#duplicate-detection) |
| `likely_duplicate` | information | duplicate pass | see [Duplicate detection](#duplicate-detection) |
| `identical_audio` | warning | duplicate pass | see [Duplicate detection](#duplicate-detection) |
| `unreadable_file` | warning | property backfill | the file could not be opened or its header would not read |
| `recording_mismatch` | warning | verification | AcoustID hears another recording and a correction was proposed; the details name the recording heard and its score |

A file not analysed yet has no row: the analysis job's own count of files still
owing work says that.

`exact_duplicate`, `identical_audio` and `likely_duplicate` name the other
file in `related_file_id`, which becomes null when that file is deleted; the
issue stays. A copy at a second location of one file has no other file, so
that `exact_duplicate` has no related file.

`recording_mismatch` is raised by `recordVerifications` in the transaction
that stores the verification, only when the outcome is `disagrees` and the
verification left a pending correction, so `review_correction` always has
one to review. A file whose recording ID is the user's locked edit gets none,
nor does a file whose correction was already dismissed or accepted. Any other
outcome clears it. Accepting a proposal of the file, alone, in bulk or in an
album group, clears it in the same transaction, and dismissing one clears it
once the file has no pending proposal left.

### Clipping

A sample is at full scale when its magnitude is at least `1 - 1/32768`, so
16-bit PCM's positive limit, 32767, counts as well as its negative limit. A
clip is a run of at least three consecutive full-scale samples in one
channel: a single full-scale sample is a peak, not clipping. Runs carry
across decode blocks, and samples in different channels of interleaved audio
never join one run. `clipped_samples` counts only the samples inside such
runs, and the details read `N clipped runs (M samples at full scale)`.

### Dismissals

`Runtime.libraryDismissHealthIssue` (`orca-cli health-dismiss`) hides one
kind on one file. `health_dismissals` keeps the file's `quick_hash` at the
time, and the page and count leave out an issue whose dismissal holds the
hash the file still has, so the issue shows again once the file's bytes
change. A file never hashed is dismissed under a null hash and stays hidden.
The issue row itself is untouched: its owning pass still records and clears
it. `libraryRestoreHealthIssue` (`orca-cli health-restore`) drops the
dismissal. A dismissal goes with its file.

### By kind

`Runtime.libraryHealthSummary` (`orca-cli health --summary`) returns a
`HealthSummary`: one `HealthKindSummary` per kind with at least one issue
that is not dismissed, holding its count, the highest severity among
those issues, its `files` and their summed size in `bytes`, highest
severity first and then in kind order. The counts sum to
`libraryHealthIssueCount`, and an empty Library has an empty summary. A
file has at most one issue of a kind, so `files` equals the count.

For `exact_duplicate`, `identical_audio` and `likely_duplicate`, `bytes` is
what removing the redundant copies would free, not the size of every file
in the group: a kept copy and two duplicates of 10 MB each report 20 MB. The kept copy is
the lowest-numbered file of a group: a file counts when a lower-numbered
file is linked to it by an issue of the same kind, as its related file or
naming it as theirs. A duplicate held as a second location of one file row
has no related file, and counts its size once per present location beyond
the first. The links are read whether or not an issue is dismissed; only
issues that are not dismissed are summed. The duplicate bytes run one
further query per duplicate kind, through `library_health_by_related`.
`libraryHealthIssuePageOfKind` (`orca-cli health --kind=KIND`) pages the
issues of one kind in the order of `libraryHealthIssuePage`. Both leave out
dismissed issues as the page and count do, and both reach the kind through
`library_health_by_kind`: the page searches it for one kind, and the summary
scans it once, as the count does.
`libraryArtworkProblemReleasePage` and `libraryArtworkProblemReleaseCount`
(`orca-cli health --kind=artwork_problem --albums`) page and count the
Releases with visible `artwork_problem` issues instead, by title, each once
with its worst problem (a missing front, then a conflict, then an
undersized cover), that problem's details and how many of its files have
one. A file's Release is that of the lowest Track id it backs, as for
`HealthIssue.release_id`.

### Actions

`HealthIssue` names the lowest Track id the file backs (`track_id`), that
Track's Release (`release_id`), and `action`, what a host offers to resolve
the issue. `Runtime.libraryHealthFile` returns the file's path, codec,
format, size and length, and whether every location is missing, for
`reveal_file`.

| Action | Kinds |
| --- | --- |
| `match_or_edit` | `missing_metadata`, `missing_track_number`, `album_artist_anomaly`; `artwork_problem` when the Release has no MusicBrainz release ID |
| `fetch_cover_art` | `artwork_problem` when the Release has a MusicBrainz release ID, tagged or named by its accepted matches |
| `compare_duplicate` | `exact_duplicate`, `identical_audio`, `likely_duplicate` |
| `review_correction` | `recording_mismatch` |
| `reveal_file` | every other kind |

Storing a fetched cover (`ReleaseArtworkRepository.put` with an image, used by
every cover-art fetch) clears `artwork_problem` for every file of the
Release's Tracks in the same transaction. A recorded miss clears nothing.
