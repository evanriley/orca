# Audio analysis

`analysis/` measures what a file's audio *is*: integrated loudness (a gated
ITU-R BS.1770 mean), a ReplayGain figure derived from it, sample peak, RMS,
clipped samples, leading/trailing/total silence, a bucketed waveform, and a
temporal fingerprint with a decoded-audio hash. `analysis/service.zig` runs all
of that in one streaming pass over a `ReadableSource`, so a file is decoded
once no matter how many of those numbers a caller wants.

Two things use the result: **ReplayGain on playback**, and duplicate detection.
Neither can use a measurement that does not exist, which is what
`library/analysis_pass.zig` is for.

## The pass

`library/analysis_pass.zig` measures every file in a Library that has not been
measured yet. It is a runtime job (`OrcaRuntime.startLibraryAnalysis`,
`orca_library_start_analysis`, `orca-cli analyze-library`) built on exactly the
machinery the property backfill uses: the shared `JobWorker`, the same
cancellation token, the same job snapshot, bounded commits, and row selection
through an indexed query rather than a walk.

One difference governs the rest of the design: **the backfill reads headers,
this decodes whole files.** Probing 22,060 files takes seconds; measuring them
takes hours. Cancellation, resumption and progress are therefore load-bearing
rather than polite, and the Library's single write lane is never held across a
decode — the decode happens outside any transaction, and only the finished
measurements enter one.

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

- **Measured.** Both encoded results, the decoded-audio hash into
  `files.audio_hash` (tier 4 of the identity cascade — the only tier that
  survives Orca's own tag writes), and `corrupt_audio` cleared, all in one
  bounded transaction per batch. A file with no gateable loudness — too short,
  or silent — is still stored, so it is not re-decoded on every run; it simply
  yields no correction.
- **Declined.** Not reachable, not audio, or the identity the Library recorded
  is not the file's identity any more. Counted, no health issue:
  `locations.state` already models absence, a stale identity is a scan's job to
  repair, and filing 22,060 defects when a drive is unmounted would bury every
  real finding. The identity check happens *before* the decode, on two 64 KiB
  reads, because a stale row is selected again on every run and paying a whole
  decode to reach the same conclusion each time is the difference between an
  hour and a second on a library that has drifted.
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

### Measured cost

Fifty real files (1,322 MB, 3h 12m of audio, 46 FLAC and 4 MPEG) copied out of
the reference library, `-Doptimize=ReleaseFast`, single worker thread:

| measurement | value |
| --- | --- |
| wall clock | 27.2 s |
| per file | 0.545 s |
| throughput | 48.6 MB/s, about 424x realtime |
| stored per file | 17.6 KB (8.2 KB diagnostics, 9.3 KB fingerprint) |
| batches committed | 2 at the default batch size of 32 |

Two bounded 30-second passes over the 22,060-file reference library itself
measured 107 files, 0.561 s each and 17,614 bytes each — close enough to the
scratch corpus that the corpus is a fair sample of the library.

Extrapolating that per-file cost linearly — and it is an extrapolation, not a
measurement; nobody has run the whole thing — the reference library is about
**3.4 hours and 388 MB**, and the 500,000-file target about **78 hours and
8.8 GB**. Both figures are single-threaded; nothing here is parallel yet, and
the pass is CPU-bound in the decoder rather than in SQLite or in storage (a
49 MB 24-bit FLAC read cold off NVMe measures 665 ms, 74 MB/s). The storage
figure is dominated by the 1,024-bucket waveform and the 20 Hz fingerprint
signature stream, both of which are fixed by their encodings rather than by
this pass, and both of which are worth revisiting before anyone runs this at
half a million files.

A Debug build measures 4.72 s per file, 8.7x slower. Quote the ReleaseFast
number, and check which one `zig-out/bin/orca-cli` currently holds before
believing a timing — a plain `zig build` reinstalls the Debug binary over it.

## ReplayGain on playback

`Gain` keeps user volume and replay gain as two independent atomics whose
product the render lane reads as one number, so applying a correction never
moves the host's volume and a volume change never discards the correction.

The correction is published on the **control lane**, in `loadCursor`, at the
moment a Player opens a queue entry — the same lane that already does the file
I/O. Nothing on the render lane reads SQLite, allocates or blocks; what crosses
is the two atomics `Gain` already exposes.

- **Absence is unity, never inheritance.** An entry with no usable correction
  publishes 1.0 rather than leaving the previous entry's figure in place.
  Playing one track at another track's loudness is the exact failure the
  feature exists to prevent, and it would be silent.
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
  a limiter, because a limiter in the render lane would change the audio.
- **`ReplayGainMode` is `off` or `track`.** Album-level ReplayGain is out of
  scope and is deliberately not a third value: it needs a release-scoped
  measurement `analysis/` does not compute and a notion of "the release this
  entry belongs to" the playback queue does not carry, and naming it without
  both would apply track gain under an album label.

Measured on the reference corpus, through `orca-cli play-tracks` at a silent
PipeWire sink, with `volume=1.0`:

| track | measured | render-lane gain | effective |
| --- | --- | --- | --- |
| loudest | -6.81 LUFS | 0.275756 (-11.19 dB) | -18.00 LUFS |
| quietest | -24.11 LUFS | 1.862241 (+5.40 dB) | -18.71 LUFS |

17.30 dB apart before correction, 0.71 dB after. The quiet track's correction
is the peak cap in action: +6.11 dB was measured, +5.40 dB (`1 / 0.537`) is
applied. With the sign inverted the two would sit 33.89 dB apart, which is what
`tests/root.zig` asserts against.

### Known gap

A **gapless auto-advance** runs on the engine thread and does not pass through
`loadCursor`, so the successor entry keeps the previous entry's correction
until the next hard load (a skip, a seek that re-opens, or a new queue).
Closing it means publishing a correction per `entry_serial` and adopting it at
a block boundary — the same shape as a prepared processing chain — and is not
built.

## Duplicate detection

`fingerprint.findDuplicates` still takes `[]const Candidate` and compares every
pair, which cannot exist at 22,060 files let alone 500,000. It is deliberately
untouched. The indexed shape is: bucket by `files.audio_hash` (which the pass
now writes) for exact-audio matches, and compare temporal signatures only
within a bucket of plausible candidates — same duration to within a tolerance,
say — so the pairwise comparison is bounded by a bucket rather than by the
library.
