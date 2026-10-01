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
  libsamplerate converter and the window length, and the quick hash of the
  bytes it was taken from. Changing any of them takes a new fingerprint. The
  stored result is the length in milliseconds (8 bytes, little-endian)
  followed by the fingerprint.
- **Agreement with `fpcalc`.** A unit test holds Orca's fingerprint of
  Chromaprint's own test recording (`fixtures/audio/chromaprint-test.mp3`) to
  at least 95 % bit agreement with `fpcalc`'s
  (`fixtures/audio/chromaprint-test.fpcalc.txt`).

`chromaprint.Analyzer` takes the fingerprint from audio fed to it a chunk at a
time, so the analysis service takes it in the same decode as everything else
and the analysis pass stores it where a standalone fingerprint is cached:
matching and AcoustID submission then find it there instead of decoding the
file again. Audio too
short to fingerprint is measured without one. The service feeds the analyzer
the chunks a standalone fingerprint reads, and a unit test holds the two
fingerprints of `fixtures/audio/chromaprint-test.mp3` byte-identical.

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

The selection key is the analysis cache key itself, minus the file:

```
kind, algorithm_id, algorithm_version, parameter_hash   +   source_identity
```

A file still owes work when no `analysis_results` row exists for it under that
key with `source_identity = files.quick_hash`. That key is the right one
because it *already* encodes every reason a stored measurement stops counting,
and a marker column on `files` would be a second source of truth free to
disagree with the results it claims to describe:

- the bytes changed — `source_identity` no longer matches;
- the algorithm changed — `algorithm_version` no longer matches;
- the parameters changed — `parameter_hash` no longer matches.

`analysis_results` is `WITHOUT ROWID` with exactly those six columns as its
primary key, so each candidate row costs one full-prefix B-tree probe and no
index had to be invented. `EXPLAIN QUERY PLAN` on the page query:

```
|--SEARCH files USING INTEGER PRIMARY KEY (rowid>?)
|--CORRELATED SCALAR SUBQUERY 2
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
  into `files.audio_hash` (tier 4 of the identity cascade — the only tier that
  survives Orca's own tag writes), and `corrupt_audio` cleared, all in one
  bounded transaction per batch. A file with no gateable loudness — too short,
  or silent — is still stored, so it is not re-decoded on every run; it simply
  yields no correction.
- **Declined.** Not reachable, not audio, or the identity the Library recorded
  is not the file's identity any more. Counted, no health issue:
  `locations.state` already models absence, a stale identity is a scan's job to
  repair, and filing a defect for every file on an unmounted drive would bury
  every real finding. The identity check happens *before* the decode, on two
  64 KiB reads, because a stale row is selected again on every run and paying a
  whole decode to reach the same conclusion each time would make a drifted
  library as expensive as an unmeasured one.
- **Corrupt.** A file that opened and would not decode raises `corrupt_audio`.
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
`SourceSession` carries the linear correction measured from the bytes it is
decoding, and scales the frames it produces by it. `Gain` is user volume and
nothing else.

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
  on the quick hash of the file that was just opened, not on
  `files.quick_hash`, because the Library's record is only as fresh as the last
  scan. A file edited since then plays at unity instead of at a correction
  measured from audio it no longer contains. That costs one extra open and two
  64 KiB reads per track load, against a decode of the whole file.
- **Canonical parameters only.** The Player asks for the measurement made under
  the default `diagnostics.Parameters`, which is what the pass produces. A
  library measured under other parameters is a different measurement and is not
  adopted — the target LUFS is one of those parameters, so adopting an
  arbitrary one would apply a correction toward a target nobody chose.
- **A boost is capped at `1 / peak`.** Bringing a quiet track up only as far as
  its headroom allows is a deliberate quietening of the correction rather than
  a limiter, because a limiter would change the audio rather than its level.
- **`ReplayGainMode` is `off` or `track`.** Album-level ReplayGain is out of
  scope and is deliberately not a third value: it needs a release-scoped
  measurement `analysis/` does not compute and a notion of "the release this
  entry belongs to" the playback queue does not carry, and naming it without
  both would apply track gain under an album label.

### Where each lane's work happens

The opener reads SQLite and two 64 KiB file ranges. That happens on whichever
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

### What the two findings mean

- **`exact_duplicate`** — Orca holds this audio at more than one place, and a
  person can act on it without listening to anything. Two sources, and the
  second one is not optional: a *byte-identical copy is not a second `files`
  row*, because the scanner's identity cascade resolves it by quick hash to the
  row that already exists. The Library models it as one file at two present
  locations, so no amount of comparing rows could ever find it. A copy whose
  bytes change leaves for a file of its own, so it is no longer reported as a
  copy of the file it left (see
  [database.md](database.md#identity)).
  1. one `files` row with a second `present` location, or
  2. two `files` rows whose `files.audio_hash` — BLAKE3 over the decoded
     samples — is byte-identical. Same audio, whatever the container, the
     bitrate or the tags claim.
- **`likely_duplicate`** — the audio only *resembles* another file's, above a
  similarity threshold, and the claim will sometimes be wrong. It is worth
  making because it catches the case the exact test structurally cannot: a
  lossy transcode of the same master decodes to different samples and so
  hashes differently, while remaining the same recording twice on disk. The
  message carries the match percentage, because a claim that can be wrong
  should travel with the number behind it.

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

`exact` outranks `likely` rather than accompanying it. They are two strengths
of one claim, and telling somebody a file is both certainly and probably a
duplicate of something helps them decide nothing.

### The three indexed queries

| question | query | plan |
| --- | --- | --- |
| which file next | `files.id > ?` | `SEARCH files USING INTEGER PRIMARY KEY (rowid>?)` |
| certain bucket | `audio_hash = ?` | `SEARCH files USING COVERING INDEX files_audio_hash (audio_hash=?)` |
| plausible bucket | `duration_ms BETWEEN ? AND ?` | `SEARCH files USING INDEX files_duration (duration_ms>? AND duration_ms<?)` |

None of the three is a scan. `files_audio_hash` serves the certain bucket and
`files_duration ON files(duration_ms, id)` (migration 13) the plausible one.

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

No health issue is filed per uncomparable file. `missing_analysis` already
means that, and one fresh defect per file on an unanalyzed library would bury
every real finding — the same argument the analysis pass makes about absent
files.

### Re-running

Every examined file has **both** of this pass's kinds rewritten, present or
absent. That is `library_health_issues`' replace-by-file semantic narrowed to
the two kinds this pass owns: `replaceFile` would also erase the corruption and
metadata findings other passes made, and an insert-only pass would let a
duplicate that has since been deleted keep its report for ever. Recording is an
upsert on `(file_id, kind)`, so a second run converges on the same rows rather
than doubling them.

Both members of a pair are reported, because either is the one somebody might
delete.

### The exact test and decoding

The exact test holds because `files.audio_hash` is a function of the audio: the
lossless decoders return exactly the samples the file encodes, and FLAC decodes
bit-exactly through libFLAC (see [codecs.md](codecs.md#flac)). Two lossless
files holding identical PCM hash identically whatever their container or encoder
settings, and are reported as `exact_duplicate`.

### Memory

`orca-cli duplicates` builds its runtime on `std.heap.smp_allocator` rather
than on the process arena most subcommands use. The pass frees each
fingerprint as soon as it has been compared, and an arena does not honour that:
it would keep one fingerprint per comparison for the length of the run.
