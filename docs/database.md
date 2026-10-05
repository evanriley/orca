# Library persistence

Each `LibraryDatabase` owns one SQLite database and one serialized logical write
lane. Paths are copied at open time so the Library owns all state needed to open
independent read connections. `Runtime.openLibrary` associates that database
with a typed generational `LibraryHandle` and closes it during explicit removal
or ordered runtime shutdown.

## Identity

**`files.id` is identity.** A `file` is one encoding of some audio; a `location`
is one place that encoding can currently be found, on one `volume`. No table
outside `locations` and `mutation_operations` stores a path, so renaming, moving
or re-tagging a file never detaches the metadata, locks, analysis results or
health issues attached to it. The exception is re-tagging one of several
byte-identical copies, which splits that copy off (below).

A scan re-finds a file through a cascade, cheapest first:

1. `locations(volume_id, uri)` — the same path on the same volume.
2. `locations(volume_id, native_inode, size_bytes, modified_ns)` — a rename or
   move within one filesystem.
3. `files.quick_hash` — BLAKE3 over (first 64 KiB ‖ last 64 KiB ‖ size), from
   `storage/quick_hash.zig`, nominates; `files.content_hash` — BLAKE3-256 over
   every byte, from `storage/content_hash.zig` — confirms. Catches copies,
   cross-volume moves and restores.
4. `files.audio_hash` — over the decoded audio payload only, so a tag write
   does not change it. Written by `library/analysis_pass.zig`, which is the
   only pass that decodes a whole file, and never by a scanner. It holds for
   the bytes it was measured from: an update that records a different
   `quick_hash` clears it, and it stays NULL until the analysis pass decodes
   the new bytes. `files.audio_hash_tier` records what was hashed: 1 for a
   lossless source's integer samples, 2 for decoded float samples, NULL with
   no hash. Only equal tier-1 hashes are the same audio (see
   [analysis.md](analysis.md#the-audio-hash)).

The duplicate pass reports from the same ladder and claims only what each
rung proves: a second present location or an equal content hash is
`exact_duplicate`, the same bytes; equal tier-1 audio hashes in different
bytes are `identical_audio`; equal tier-2 hashes or matching fingerprints are
`likely_duplicate` (see
[analysis.md](analysis.md#what-the-three-findings-mean)).

**Tier 3 nominates; the content hash confirms.** Files of one size and the same
first and last 64 KiB can differ in the middle, so a quick hash alone never
joins a path to a file. A nominee — a file recording the path's quick hash — is
joined when:

- it records a `content_hash` with `content_hash_algorithm` 1 equal to the
  path's; or
- it records none, and the bytes now at one of its other `present` or
  `unverified` locations, still with the inode, size and mtime that location
  records, hash the same.

A nominee is undecided when none of those locations can be read as recorded
and something is at one of them that cannot be read or has changed since a
scan recorded it. So is every nominee past the eighth for one quick hash, and
one with no content hash and more than four other locations when none of the
first four is read as recorded. An undecided nominee is never joined, and the path becomes a file of its own unless another
nominee confirms. A join records the path's content hash on the file, as does a
new file whose bytes were hashed.

Only a path that reaches tier 3, that shares a quick hash with another path in
the same scan batch, or that changed while its file is present at another path
(below) is hashed whole; a scan with no collision reads no more than before.
`FileRepository.contentQuestion` names what a path's resolution will weigh,
and `content_measurements` reads it: the path itself, re-stat after the read so
bytes that changed during it count as unread, and the nominees' or other
copies' locations. The hashes are taken before the batch's transaction begins,
because nothing under the write lane reads a file. Inside it,
`FileRepository.resolveForBytes` re-reads the nominees and their locations and
treats one it holds no hash for as undecided, so a candidate that appeared
since makes the path a new file rather than an unproven join. The hashes are
written in the transaction that records their paths, so a cancelled or failed
batch leaves none behind. Any other path re-found through tier 1 or 2 is not
hashed, so a file re-found at an inode, size and mtime none of its locations
records forgets its content hash: it may no longer hold the bytes the hash
describes.

Known limit: a nominee with no content hash and no location left to read —
each is `missing`, or nothing is at its path — is joined on the quick hash
alone, and takes the path's content hash, when no other nominee confirms, is
undecided, or has no location left either. That is a cross-volume move or a restore whose old path is gone,
and the join keeps Orca's values and locks across it. A different file of one
size, head and tail that appears where only such a file was known joins it the
same way.

**A file is one set of bytes.** Byte-identical copies are one file at several
locations: a new path holding bytes the Library already has joins that file
through tier 3 once its content hash confirms them. A path re-found through
tier 1 or 2 whose file is still present at another path stays on that file only
when its bytes are proven to be the other path's:

- its location is `present` and still records the inode, size and mtime just
  read, so its bytes are the ones that were proven; or
- it changed or came back from `missing` or `unverified`, the file records the
  same `quick_hash`, and the path's content hash equals the file's recorded
  one (`content_hash_algorithm` 1), or, when the file records none, that of
  the first other copy read with the inode, size and mtime its location
  records.

Otherwise the path has *diverged*: the other path still holds the bytes the
file describes, so the path gets a file of its own instead of rewriting the
shared one. A changed path whose file records a different `quick_hash`
diverges without being hashed. One whose other copies cannot be read as
recorded, with no content hash on the file, diverges too: a file is never
shared without proof. A middle-only edit, which keeps the size and the first
and last 64 KiB and so the quick hash, therefore splits the edited copy off.
`FileRepository.resolveForBytes` decides this and `forkLocked` makes the new
file, in the scan batch's transaction, and `resolveOrCreateFile` applies the
same rule, so a full scan, a reconcile, a watcher pass, the re-observation after
a tag write and `orca-cli analyze PATH` agree. The other copies are read before
the transaction; inside it only a copy whose location still records the
identity it was read with counts, so a copy that changed or appeared since
leaves the path undecided and it diverges. When both copies of a file change in
one batch, the first one flushed diverges and the second, now its file's only
present path, stays. The split moves the location to the new file, copies
Orca's values and locks to it with `written_at` cleared, and re-points journal
rows that name the path. The new file takes the bytes' properties and observed
tags from the read; analysis results, the audio hash, health issues, identification
proposals and searches, AcoustID submissions and listens stay with the file the
copy left. A scan reprojects both copies' folders. Only a `present` location
counts as the other path, because a `missing` one is usually what a move left
behind, and a location on the same volume with this path's inode does not
count, because a hard link cannot hold other bytes. A file whose only present
location is this path is updated in place.

Not handled yet:

- A changed path whose new bytes equal another file's stays on its own file,
  so two files can share a `quick_hash`.
- Two copies changed in the same way end as two files with equal hashes. The
  duplicate pass reports them as `exact_duplicate`, but they are not joined.
- A tag write writes one location of a file, not every copy of it.
- An edit that keeps a path's inode, size and mtime is not seen: the scan's
  unchanged fast path skips it, and nothing re-reads it.
- A copy edited while the file's other copies are `missing` keeps the file. A
  missing copy that comes back with other bytes splits off as a new file,
  although it holds the bytes the file's earlier analysis, audio hash and
  listens describe.

Volumes are identified by a `stable_key` the platform adapter resolves — a
filesystem UUID, else an identifier persisted at the mount root, else
`root:<library_roots.id>`. `st_dev` is *not* stable across reboots or remounts
and is kept only as `locations.native_device`, a hint. Resolution lives in
`platform/volume_*.zig`; neither the scanner nor a repository knows how a volume
is named.

`locations.state` is `present`, `missing` or `unverified`. A completed,
uncancelled scan run marks locations it did not reach as `missing`; nothing
deletes a location implicitly, because an unmounted drive must not empty a
library.

A root's path is absolute: `ensureRoot` and `relocate` refuse a relative one
with `error.InvalidLibraryRoot`, and `orca-cli` resolves a relative argument
against its working directory before it calls them.

Removing a root is the one explicit path that forgets. In one transaction it
deletes the root's locations, the files that were located only under it (with
their tags, Orca values, analysis and health rows), the Tracks those files
backed, and the Releases and Artists nothing else references. It also deletes
each Recording those Tracks or files held that no remaining Track or file
holds, and with it, by `ON DELETE CASCADE`, its feedback, rating, playlist
entries and play stats; listens keep their rows with `recording_id` NULL. A
Recording already held by nothing before the removal is left alone. Nothing
on disk is touched. A file also located under another root or volume survives, and
the projection is rerun over it. Undo journal rows keep their paths and lose
only their `file_id`, so a tag write can still be undone. Every Library job
writes rows keyed by `files.id`, so the removal fails with `LibraryJobRunning`
while any job on that Library runs.

## Observation, Orca metadata, projection

`observed_file_tags` (plus `observed_file_genres`, since genre is multi-valued
in every container Orca reads) stores every field the tag readers can produce,
verbatim. `orca_metadata_values` stores preferred values, user edits, provider
proposals and locks. Neither is a Track.

**Scanner observations never update Track metadata.** A separate *projection*
fills `artists`, `releases`, `recordings` and `tracks`, and it reads
`EffectiveMetadata` — observation plus Orca overrides under an explicit policy —
not raw observations. That keeps the law intact and makes the projection
re-runnable after a user edit or a provider acceptance, not only after a scan.
`tracks.preferred_file_id` is a denormalized cache so starting playback is one
indexed lookup rather than a three-way join. Which encoding it names is decided
on declared properties: higher bit depth, then higher sample rate, then a
location a scan has confirmed, with the container ranking only as a tiebreak
between encodings that declare the same thing. A property the file does not
declare is *unknown*, never zero — so an MPEG file, which has no sample width to
state, loses to a real 16-bit encoding of the same song, and a file the scanner
could not open never outranks one it could.

`library/projection.zig` resolves a whole `(containing folder, album key)` group
at once, because the album-artist cascade asks a question about a set — *do all
the files sharing this album in this folder name one artist?* — that no per-file
pass can answer. The folder is also the unit of incremental work: a scan batch
names a handful of folders, each is one range scan of `locations(volume_id,
uri)`, and a scan that changed nothing reprojects nothing. Missing locations are
projected too, so an unmounted drive greys a Track out rather than deleting it;
`has_playable_file` and `TrackRepository.playableLocation` answer reachability.
A file with an `unreadable_file` issue is not projected: it keeps its `files`
and `locations` rows and its issue, a Track it backed is pruned like any other
the folder no longer writes, and its `missing_metadata`,
`album_artist_anomaly`, `missing_track_number` and `artwork_problem` issues are
retired. The scanner and property backfill reproject a file when they record
or clear that issue, so it projects again once its new bytes open.

Reprojecting a folder keeps each Track with its file. The run matches every
position it writes to a Track in this order: the Track whose preferred file is
one of the position's files, on any Release; otherwise a Track on the same
Release that presents the same recording; otherwise a new row. Every group in
the folder claims by file before any claims by recording, because one edit can
move a file onto another group's Release, and a Track is claimed at most once
per run. A Track whose file now projects at another position or Release moves
there and keeps its id (`Result.tracks_moved`), so a queue, a saved player
state, lyrics, user genres, a pending proposal or a frontend holding the Track
id still resolve after an edit, a scan, an accepted match, Match Album or an
undo. Ratings, feedback, playlist entries and listens follow the recording and
are not affected. A row at a target position that no file claimed is pruned,
handing its user genres to the Track its file backs now, and so is a Track
whose preferred file is in the folder but that no position claimed
(`Result.tracks_pruned`). Rows changing position are parked first with a null
track number, which `tracks_position` keeps unique by id, and are then written
by id, so files that swap or rotate positions never collide. A Release or
Artist left with nothing referencing it goes with them. Candidates are the
Tracks whose preferred file the run positions, found through
`tracks_by_preferred_file` (version 14), and those on a Release the run
writes. Everything pruned is derived and is rebuilt by the next projection, so
an id handed out for a pruned row does not come back: a client holding Release
or Artist ids, or the id of a pruned Track, must look them up again.

Two source-data defects are common enough that the projection must survive both
without losing a song. A file with no track number takes the lowest free
position on its disc and raises `missing_track_number`. A file whose stated
track number is already held by a *different* performance is re-seated the same
way and raises `technical_anomaly` — while a file at the same position that is
the *same* performance (a FLAC and an MP3 of one song, matched by MusicBrainz
recording id or folded title) shares the position and becomes one Track with two
files. A Release whose files sit in several folders is positioned as one
group: each folder's projection also reads the files of other folders that
back Tracks on that Release and still name its album, orders them all by path,
and applies the same rules, so the result does not depend on which folder
projects first and no file is left without a Track. When the files at a
position disagree on their recording, the recording the Track already presents
is kept, with its ratings and listens. Positions are never left null once a
run commits: `tracks_position` collapses a null onto `-id`, which the
projection uses only to park rows while they change places.

Artist and release keys fold case, width and whitespace. That folding is not
full NFKC plus full Unicode case folding — it covers ASCII, Latin-1, Latin
Extended-A, Greek, Cyrillic and the halfwidth/fullwidth forms, and does not
canonically compose, so a precomposed `é` and a decomposed `e`+U+0301 remain
distinct keys.

## The browse model

The library is *browsable* rather than merely listable: "what else is by this
artist" is an indexed relational query, not a scan over the denormalized
`tracks.artist` text.

`tracks.artist_id` and `releases.album_artist_id` are the relational links, and
`artists.sort_name` is the key an Artist listing orders by. All three are
written by `library/projection.zig`, and migration 9 backfills them for a
library created before version 9.

**One primary artist per Track, one album artist per Release, deliberately.**
The tag data is single-valued on ARTIST and ALBUMARTIST in essentially every
file, and splitting featured credits is a metadata problem — it needs a parser,
a provenance story and a user-visible review step — not a schema one. The
extension path is a `track_artists(track_id, artist_id, ordinal, role)` join
table *alongside* these columns, with `artist_id` staying as the primary artist
a listing files by.

`artists.sort_name` is a folded **sort key**, not a display name:
`database/text_key.zig` lowercases, collapses whitespace and drops a leading
English article, so "The Beatles" files under B and one plain index serves the
whole listing under a BINARY collation. Hosts display `artists.name`.

A Release listing sorted by `title` or `artist` leads its ORDER BY with
whether the name starts with an ASCII letter, so names that do not come
first and each initial is one contiguous run. `ReleaseRepository.letterIndex`
counts the same filtered rows per initial (`'#'` for the rest) and sums the
counts in that order, so each bucket's `first_offset` is exactly the
`offset` at which `page` reaches it. The artist
key strips a leading "The ", "A " or "An " from `releases.album_artist` in
SQL unless `ReleaseQuery.name_order` is `as_written`.

Version 39 indexes both orders on `releases`: `releases_artist_order` on the
artist sort's terms with leading articles ignored and `releases_title_order` on
the title sort's. SQLite uses an expression index only when the ORDER BY
repeats its expressions exactly, so changing `ReleaseSort.terms` for either
sort needs a migration that rebuilds its index; a releases test fails on a
fresh library when the page plan stops using them. An unfiltered page then walks the index from its offset instead of
sorting every Release: at 512,000 Releases a 512-row page by artist at offset
13,806 drops from 22 ms to 6 ms, and by title from 24 ms to 5 ms.
`letterIndex` still reads every matching Release, about 13 ms there.

### Ordering and paging

`TrackRepository.page` takes a `TrackQuery`: a sort key (`id`, `artist`,
`album`, `title`, `track_number`, `duration`, `date_added`, `rating`, `loved`,
`play_count`, `last_played`, `year`, `loudness`, `bitrate`, `path`,
`album_artist`, `genre`), a direction, and
relational filters on `artist_id`, `release_id` and `genre_id`.
`ArtistRepository.page` and `ReleaseRepository.page` are the same shape for
their own tables, and both also filter by `genre_id`; an Artist listing sorts
by `name`, `track_count` (the Tracks the Artist has in all) or
`recently_loved`, and filters by `loved_only` ([Artist info](#artist-info)). All three
return bounded, caller-owned pages of at most `columns.max_page` (512) rows and
never expose a SQLite row or statement.

**Every generated ORDER BY ends in the row's own id.** This is not decoration.
Real libraries hold many Tracks that share a title, have no artist, or sit on
multi-disc Releases; without a unique tiebreaker a LIMIT/OFFSET walk over a
column with ties is free to return one row on two pages and skip a third,
because SQLite may order equal keys differently between two evaluations of the
same statement. A descending sort reverses *every* term including the
tiebreaker, which keeps the order total and lets SQLite walk the same index
backwards.

The `id` in an ORDER BY is never named in an index. `id` is `INTEGER PRIMARY
KEY`, so it *is* the rowid and SQLite already appends it to every index entry —
`ORDER BY title COLLATE NOCASE, tracks.id` is satisfied straight out of
`tracks(title COLLATE NOCASE)` with no temp B-tree.

**A page picks its ids before it joins.** The paged statement first selects
the page's `tracks.id`s with only the join its sort reads, applies LIMIT and
OFFSET there, and joins the columns a `TrackSummary` needs for those rows
only, in the same order. A sort on a value outside `tracks` (`play_count`,
`last_played`, `rating`, `loved`, `year`, `date_added`) over the whole library
at an offset of at most 50,000 goes further: it takes the first
`limit + offset` ids of each part of the library that orders differently
(Tracks with a play-stats row, walked down `recording_play_stats_by_count`,
and Tracks without one, walked by id), so no part is read past the page. The
indexes those walks use are `recording_play_stats_by_count`,
`recording_play_stats_by_last_played`, `ratings_by_rating`, `feedback_loved`,
`releases_by_year` (on the leading four-digit year of `release_date`) and
`files_by_first_seen`, all version 32, and the version 40 indexes in
[Track facts](#track-facts). Past that offset, or with an artist,
release, genre or loved filter, the ids come from one ordered pass over the
matching Tracks.

`zig build -Doptimize=ReleaseFast bench` on 500,000 Tracks (100-row pages,
descending):

| Sort | Offset 0 | Offset 50,000 | Offset 250,000 |
| --- | --- | --- | --- |
| `title` | 0 ms | 2 ms | 8 ms |
| `play_count` | 2 ms | 128 ms | 294 ms |
| `last_played` | 0 ms | 99 ms | 301 ms |
| `rating` | 2 ms | 117 ms | 303 ms |
| `loved` | 0 ms | 101 ms | 344 ms |
| `year` | 1 ms | 54 ms | 380 ms |
| `date_added` | 1 ms | 107 ms | 571 ms |
| `loudness` | 2 ms | 236 ms | 599 ms |
| `bitrate` | 130 ms | 220 ms | 557 ms |
| `path` | 749 ms | 1,283 ms | 1,040 ms |
| `album_artist` | 1 ms | 3 ms | 13 ms |
| `genre` | 151 ms | 240 ms | 777 ms |

The last five rows are timed at the end of the run, once every file has a
size, a duration and two locations, two thirds a loudness, and every Track a
genre. `genre` at offset 0 reads every Track looking for one without a first
genre. `bitrate` read every Track the same way until version 41; its numbers
predate that index. `path` descending walks the second
location of every file, never its best one, before the first it keeps.

The value filters (`year_min`, `year_max`, `lossless`, `min_sample_rate`,
`explicit_only`) are bound parameters, each true when unset, as the Release
filters are. A page with any of them set uses one more statement per
relational filter, sort and direction, which binds the loved and genre filters
too; a page, count or search with none uses the statements it used before,
so the value filters cost an unfiltered listing nothing. The year reads the
Release's leading four-digit year, as `releases_by_year` indexes it, and the
format and sample rate filters read the Track's play file. `countMatching` and the FTS search read the same predicate text.
With value filters set (100-row pages, offset 0):

| Filter | Count | Count time | `play_count` page |
| --- | --- | --- | --- |
| 1990 to 1999 | 70,000 | 140 ms | 151 ms |
| lossless | 375,000 | 332 ms | 430 ms |
| lossy | 125,000 | 316 ms | 344 ms |
| 96 kHz and above | 50,000 | 223 ms | 234 ms |
| explicit | 45,454 | 84 ms | 87 ms |
| lossless, 96 kHz, from 1990 | 11,000 | 273 ms | 261 ms |
| loved and lossy | 17,857 | 166 ms | 158 ms |

A `title` page with a value filter stops once it has its rows (0 to 11 ms at
offset 0); a page sorted by another key, and every count, test each Track. A
search with a value filter takes 324 to 358 ms, against 279 ms without.

A `codec`, `lossless`, sample-rate or `added_after` filter reads the Track's
play file. With one of them set and no Artist, Release, genre or loved
filter, a count, a total and a page whose sort reads every row (any sort but
`id`, `artist`, `album`, `title`, `track_number`, `duration` and
`album_artist`) collect the matching Tracks once, as one non-correlated `IN`
set: the files that pass, joined to `tracks_by_preferred_file`, and for a
Track without a preferred file the file `track_play_file` falls back to.
Probing `files` once per Track instead costs a correlated subquery for each
of 500,000 Tracks. A narrower filter keeps the per-Track probe, which reads
only the Tracks the narrower filter leaves, and so does a page sorted by an
index of `tracks`, which stops once it has its rows. The set costs a pass
over every file, so a filter most files pass stays linear in the library.
The `?N IS NULL OR` form of the bound filters keeps the planner off any
index on `files.codec` or `files.sample_rate`, so the schema has none. At
522,432 Tracks, each with its own file (`orca-cli tracks`, ReleaseFast):

| Filter | Matches | Before | After |
| --- | --- | --- | --- |
| FLAC, above 48 kHz, added in the last year: totals | 26,176 | 238 ms | 61 ms |
| the same, a 512-row page and its count | 26,176 | 246 ms | 67 ms |
| the same, sorted by `date_added` descending | 26,176 | 473 ms | 128 ms |
| lossless: totals | 472,064 | 388 ms | 387 ms |
| lossy, sorted by `path`, offset 100 | 50,368 | 678 ms | 377 ms |

Every unfiltered sort is an ordered index scan, and every Artist-filtered sort
but one is an indexed SEARCH. Two cases build a temp B-tree, both over a
bounded set and both deliberate: an Artist-filtered listing sorted by artist
*name* (bounded by that Artist's Tracks), and a Release-filtered listing sorted
by anything other than disc-and-track (bounded by one Release). Indexing those
would cost seven more composite indexes on the largest table in the schema to
order at most a few dozen rows.

Per-artist counts are correlated scalar subqueries rather than a GROUP BY
join, because a join would have to aggregate the whole table before the LIMIT
could apply. Each is one covering range count over `tracks_artist` or
`releases_by_artist`.

A Release page picks its ids first, in a `MATERIALIZED` CTE, and then reads
the facts of only those Releases in one grouped pass over their Tracks
(`tracks_release`), each joined to the file it plays: Track count, duration,
explicit advisory, highest sample rate and bit depth, codec, whether all are
lossless, and whether any has a pending proposal. The exact review count, a
distinct count over Tracks and album groups, runs only for a Release with a
pending proposal. The Release filters (`high_resolution_only`,
`needs_review_only`, `lossless_only`, the year range, `has_artwork`,
`release_kind` and `appearing_artist_id`, read through `tracks_artist`) are
bound parameters, each true when unset, so one statement per sort serves
every combination; `countMatching` reads the same predicate text. With every
filter set aside, a page's cost is proportional to the Tracks on its
Releases, not to the library.

`zig build -Doptimize=ReleaseFast bench` on 500,000 Tracks over 5,000 Releases
(500 of them with 1,000 Tracks each), 100-row Release pages:

| Release page | Time |
| --- | --- |
| `title`, offset 0 (100,000 Tracks on the page) | 127 ms |
| `title`, offset 2,500 (no Tracks) | 1 ms |
| `year`, offset 0 | 17 ms |
| `most_played` | 236 ms |
| `high_resolution_only` | 152 ms |
| `needs_review_only` | 218 ms |
| `lossless_only` | 168 ms |
| a year range | 90 ms |
| without artwork | 150 ms |

A filter is an EXISTS over each candidate Release's Tracks and their files,
so a filtered page reads every Track of the Releases it passes over;
`most_played` sums `recording_play_stats` over every Release's Tracks before
it can sort.

## Schema and migrations

Schema changes are transactional and selected by `PRAGMA user_version`. Version
1 establishes separate Artist, Release, Recording, Track, File, and Location
tables; filesystem paths therefore never become musical identity. Version 8
completes that by removing the path-keyed tables that grew alongside them:
`observed_files` disappears into `files`, `locations` and `observed_file_tags`,
and analysis, health, Orca metadata and identification proposals all key on
`files.id`. Unknown newer schema versions are rejected rather than opened
destructively, and `PRAGMA foreign_key_check` runs inside the migration
transaction so a migration that would leave dangling rows rolls back instead.

`analysis_results` is `WITHOUT ROWID`, keyed on `(file_id, kind, algorithm_id,
algorithm_version, parameter_hash, source_identity)`. That key is load-bearing
beyond caching: it is also how the library-wide analysis decides which files
still owe work, because it already encodes every reason a stored measurement
stops describing a file. A marker column on `files` would be a second source of
truth free to disagree with the results it claims to describe.
`repository.unanalyzed_predicate` is the one definition of that question,
shared by the paged selection, the count that gives the job its denominator,
and the plan test that asserts neither is a table scan. See `docs/analysis.md`.

`source_identity` is the content hash (BLAKE3-256 over every byte) of the
bytes the analysis pass decoded. A result counts only while it equals
`files.content_hash` with `content_hash_algorithm` 1: the unanalyzed
predicate, the duplicate pass, `file_loudness` readers and playback's
ReplayGain all join on it. A scan that sees a path's inode, size or mtime
change without hashing it forgets the file's content hash, so a change
confined to the middle of a file, which keeps its quick hash, leaves its
results stale and the next pass measures it again. The pass records the hash it
read on the file, in the transaction that writes the results, only while the
file still records the quick hash it read and either already records that
content hash or has the location it read still recording the inode, size and
mtime it read; otherwise it writes nothing for the file. Results stored before
this were keyed by the quick hash, which hashes the first and last 64 KiB and
the size rather than the whole file, so short of a contrived file or a BLAKE3
collision it equals no content hash: those results are stale, and the next
analysis pass measures their files again. No migration rewrites them, and a
Library from an earlier release opens unchanged.

Migration 8 preserves paths that only ever appeared in `analysis_results` or
`library_health_issues` — an `orca-cli analyze` of a file no scan ever saw — by
synthesizing `files` and `locations` rows in the `unverified` state. Their old
size-and-mtime cache key is preserved as a distinguishable legacy
`source_identity` rather than being collapsed onto a hash nobody computed.
`fixtures/database/v7-library.db` is a checked-in version-7 database, generated
by `fixtures/database/v7-library.sql`, that the migration tests migrate and
assert row-for-row.

Migration 9 backfills `tracks.artist_id` and `releases.album_artist_id` by
running the *same two-step cascade* `ArtistRepository.ensureLocked` runs, in the
same order: a MusicBrainz artist id outranks the name, and only what it cannot
answer falls back to the folded key. `migrations.zig` registers
`orca_artist_key` and `orca_artist_sort_key` as SQLite functions over
`database/text_key.zig`, so the backfill executes the same Zig the projection
executes rather than a reimplementation in SQL that would be free to drift. A
Track whose artist tag is empty gets no `artist_id`: an empty name is an absent
artist rather than an artist named "". Migrating and then reprojecting a library
produces byte-identical `artist_id`, `album_artist_id` and `sort_name` columns —
the convergence `library/projection.zig` asserts on a fixture and
`migrations.artist_backfill` exists as a separate constant to make testable.

`LibraryDatabase.open` applies migrations only as far as
`migrations.journal_ready_version` (the version at which `mutation_operations`
exists), runs mutation-journal recovery, applies the remaining migrations, and
recovers again, for the rows a migration made nonterminal. A nonterminal
staged file mutation must reach a terminal state before any migration rewrites
the tables it refers to, and a Library whose journal cannot be converged is not
opened at all — the same posture as an unknown newer schema version. Recovery
and the migrations after it run only under the journal lock; see
[Concurrency](#concurrency).

`mutation_operations` keeps its paths: the subject of a filesystem operation
genuinely is a path. It also carries `file_id` and the full journaled
`FileIdentity` (size, modification time, quick hash and content hash), so
recovery compares the same identity an in-process check does: `expected_*` is
the file the plan approved, and `committed_*` the stage once it is built, then
the file once the write commits. `expected_content_hash` and
`committed_content_hash` are BLAKE3-256 over every byte. They are NULL on rows
journaled before migration 56, which are compared by the other three parts; a
stored value that is not 32 bytes fails the read rather than weakening the
check. `backup_path` is NULL once pruning
has deleted the backup; `prunableBackups` and `clearBackupPath` select and
record that. See [metadata.md](metadata.md#pruning-backups).

Migration 18 forgets the files a scan made of tag-write stages and backups that
earlier versions kept beside the music. A file goes only when every one of its
locations is a journaled `stage_path`, `backup_path` or
`stage_path || '.recovery-displaced'`; its Tracks go with it, then the Releases
and Artists left without Tracks, and journal rows that named it keep their paths
with `file_id` set to NULL, as `remove-root` leaves them.

Migration 22 sets `modified_ns` to -1 on the present locations of files whose
`observed_file_tags` row holds artwork and nothing else, with no
`observed_file_genres` rows. No file has that modification time, so the next
scan, reconcile or watch pass re-observes them: an ID3v2 tag holding only a
cover was read in preference to the file's ID3v1 trailer or `LIST`/`INFO`
chunk, and now the cover is kept on those values. File rows, quick hashes and
Orca's values are left alone.

Migration 23 sets `files.audio_hash` to NULL unless the file has an
`orca.temporal-fingerprint` version 2 row in `analysis_results` whose
`source_identity` equals the file's current `quick_hash`. Before it, a rescan
of changed bytes kept the hash of the old audio, and the duplicate pass reported
files as exact duplicates of audio they no longer held. The analysis pass
measures the cleared files again.

Migration 24 adds `provider_state.next_request_ms`, the earliest Unix
millisecond a service may next be sent a request: the minimum interval after
the last request, or the end of a quota window a response announced with
`X-RateLimit-Remaining: 0`. Before it, both lived only in the Gateway that
received them, so the next job's Gateway could send inside the window or less
than a second after the previous job's last request. Existing rows keep their
block and backoff and start with the column NULL.

Migration 25 sets `modified_ns` to -1 on every present location of a file
with more than one present location, so the next scan, reconcile or watch pass
re-observes them, as after migration 22. Before it, a copy whose bytes changed
rewrote the file it shared with an untouched copy: both paths named a file
describing the changed bytes, the untouched copy's Track disappeared, later
scans skipped it, and the duplicate pass still reported the two as exact
copies. Re-observing applies the divergence rule, so the file keeps the copy
whose bytes it records and every other copy splits off into a file of its own.

Migration 26 sets a journal operation to `undoing` (6) when it is `committed`
(2) in a group that also holds a `rolled_back` (3) operation and no `planned`,
`staged`, `failed` or `needs_reconciliation` one (0, 1, 4, 5). Before it, an
undo rolled operations back one at a time, so a crash between two files left
the group half undone in states recovery never selected, and a retried undo
refused it as not committed. The recovery pass that follows the migrations in
`LibraryDatabase.open` finishes those undos. `MutationState` values are stored
by number, so new states are appended and never reordered.

Migration 50 adds `observed_file_tags.comment`, a nullable `TEXT`, and sets
`modified_ns` to -1 on every present location, so the next scan, reconcile or
watch pass re-observes every file, as after migration 22. Until then the
column is null for every file, a tag write is refused for each one as
`changed_since_scan`, and a file's own comment cannot be replaced unseen.
`observed_file_tags.composer` was already observed and is unchanged. See
[metadata.md](metadata.md#composer-and-comment).

Migration 51 rebuilds `release_artwork` with the primary key `(release_id,
kind)` and the columns `kind`, `source`, `width` and `height`, copying every
row, null images included, as a front cover (`kind` 0) that was fetched
(`source` 2) with its bytes, release ID, MIME type and `fetched_at` unchanged.
It adds `cover_art_candidates`, the measurement columns
`observed_file_tags.artwork_width`, `artwork_height` and `artwork_hash` and
`folder_images.width`, `height` and `hash`, and three partial indexes over
the covers left unmeasured: `observed_file_tags_artwork_unmeasured`
(`artwork_byte_size > 0 AND artwork_hash IS NULL`), `folder_images_unmeasured`
(`hash IS NULL`) and `release_artwork_unmeasured` (`image IS NOT NULL AND
width IS NULL`). Every cover in a library opened at version 50 starts
unmeasured, and an unmeasured cover raises no `undersized` or `conflicting`
problem. Property backfill measures them, as described under
[Artwork problems](#artwork-problems). The rewind to version 25 rebuilds
the version-20 table from the front rows that name a release ID and drops
the rest.

Migration 52 adds `dismissed_release_candidates(release_id, musicbrainz_release_id,
dismissed_at)`, primary key `(release_id, musicbrainz_release_id)`, without
rowid: the MusicBrainz releases a Release was marked as not being ("Not This
Release"). Rows cascade with their Release, and a reprojection that leaves a
Release without Tracks hands them to the Release that took most of them when
that one has none, as it does covers and love. Existing libraries start with
none. It also adds `releases_match_order` on `(album_artist COLLATE NOCASE,
title COLLATE NOCASE)`, the order Match Review pages Releases in, so a page
reads Releases in that order from the index instead of sorting every one,
which took 0.66 s at 429,312 Releases. The rewind to version 25 drops the
table and the index.

Migration 53 adds the state a Player resumes from, described under
[Saved playback](#saved-playback): `player_state`, a single row (`id` 1)
holding the queue's `cursor`, `position_ms`, `repeat` (0 off, 1 all, 2 one),
`shuffle` and `saved_at` in Unix seconds; `player_queue_entries(position,
entry, track_id, recording_id)`, one row per entry in playback order,
`position` the primary key and both `position` and `entry` from 0 to 9999;
and `track_positions(track_id, position_ms, updated_at)`, where long Tracks
were left, cascading with their Track. Existing libraries start with none.
The rewind to version 25 drops all three.

Migration 54 adds `metadata_proposals`, the issues of the metadata
consistency pass ([analysis.md](analysis.md#metadata-consistency)). One row
per issue header (`id = group_id`, `option` and `track_id` null), per option
(`option` from 0, `proposed` the value, `reason` its support text) and per
proposal (`track_id`, `current`, `proposed`). Each row carries the issue's
`release_id`, `category` (0 to 4), `field`, `state` (0 open, 1 skipped, 2
applied), `fingerprint` and `created_at`. Rows cascade with their Release
and Track. `id` is `AUTOINCREMENT` so a replaced issue's id never names a
later one. `metadata_proposals_groups` is a partial index on `(state,
category, release_id, id) WHERE id = group_id` for the page and count;
`metadata_proposals_members` on `(group_id, option, id)` reads an issue's
rows, `metadata_proposals_release` on `(release_id, state)` serves a
Release's replacement, and `metadata_proposals_track` the Track cascade.
Existing libraries start with none. The rewind to version 25 drops the
table.

Migration 55 adds two nullable columns to `metadata_proposals`: `tracks`, an
option's count of Tracks stating its value (at least 0), and `gap`, on a
`track_numbering` header, the lowest number it fills below the disc's
highest (at least 1). Issues stored before it have neither until the pass
runs again.

Migration 56 adds `mutation_operations.expected_content_hash` and
`committed_content_hash` (described above), `files.content_hash_algorithm`
(1 for BLAKE3-256 over the whole file, NULL when `content_hash` is NULL), and
the index `files_content_hash` on `files(content_hash)`. Existing rows keep NULL
in all three columns; nothing is backfilled. The file update that records a
different `quick_hash` clears `content_hash` and `content_hash_algorithm`
together, as it clears `audio_hash`. The executor does not write
`files.content_hash`; the identity cascade records it when it hashes a path
(see [Identity](#identity)), and the analysis pass records the hash of the
bytes it decoded. Startup recovery reads the journal before this
migration runs, so `MutationJournalRepository.get` reads NULL content hashes
from a table that does not have the columns.

Migration 57 sets every `files.audio_hash` to NULL and adds
`files.audio_hash_tier INTEGER CHECK (audio_hash_tier IN (1, 2))`. The hashes
it clears covered float32 samples without the sample rate, channel count or
length, so 32-bit integer sources one LSB apart and the same samples at another
rate hashed alike. Temporal fingerprint version 3 re-selects every file, and
the analysis pass stores an ORAH version 2 hash with its tier.

Migration 58 adds the MusicBrainz release tracklist snapshots Match Review
aligns Releases against (see
[metadata.md](metadata.md#release-alignment)):
`musicbrainz_releases` (`musicbrainz_release_id` primary key, `title`,
`artist_credit`, `release_date`, `release_group_id`, `medium_count`,
`track_count`, `fetched_at` in Unix seconds) and `musicbrainz_release_tracks`
(primary key `(musicbrainz_release_id, disc, position)`, `title`,
`artist_credit`, `length_ms`, `recording_id`, `release_track_id`), both
`WITHOUT ROWID`, the tracks deleted with their release. They hold release
metadata only, keyed by MusicBrainz ID, never by Release id.
`ReleaseTracklistRepository.replace` swaps a release's header and tracks in
one transaction and refuses one of more than 512 media or 512 tracks
(`error.ReleaseTracklistTooLarge`); `get` reads at most 512 tracks.

Track full-text search uses an external-content FTS5 table over
`title, artist, album, album_artist`, maintained by SQLite triggers. Such tables
cannot be `ALTER`ed to gain a column, so migration 8 drops the triggers and the
virtual table, recreates both, and rebuilds the index. Repository APIs return
bounded, caller-owned pages and never expose SQLite rows or statements.

Migration 10 adds one partial index, `files_incomplete_properties`, over
`repository.incomplete_properties_predicate` — the rows whose declared audio
properties are still missing. It is partial rather than full for a reason worth
stating: the index contains exactly the rows that are broken, so it starts
small on a healthy library, shrinks as the property backfill repairs rows, and
reaches empty, at which point asking "what still needs probing" costs one
B-tree probe instead of 500,000 row reads. A full index on the same columns
would be largest precisely when there is nothing to do. The predicate has a
single definition shared by the index and the query, because SQLite decides
whether a partial index applies by comparing expressions rather than meanings.

Migration 13 adds `files_duration ON files(duration_ms, id)`, which is what
makes duplicate detection an indexed question rather than an O(n²) one. It is
full rather than partial, and that is the opposite choice to migration 10 for
the opposite reason: a duplicate scan asks its question of *every* file, and
the rows it asks about do not shrink as anything gets repaired. It covers both
columns so the bucket lookup reads the index alone. See `docs/analysis.md`.

`files.codec` is the **encoding**, not the container. `files.audio_format` is
the container a file was sniffed as, which decides who opens it; `codec` is a
stable lowercase identifier for what turned out to be inside — `pcm`,
`pcm_float`, `flac`, `qoa`, `mp1`, `mp2`, `mp3` — which decides what the bytes
cost. They coincide for FLAC and QOA and diverge wherever a container is a
wrapper. See `docs/codecs.md`.

## Listens and the scrobble queue

`listens` (version 15) is the local play history: one row per completed
listen, kept forever. It is keyed on `files.id`, not on a Track. A Track id
changes when an edit reprojects it, and a play count keyed on the Track would
reset with it; the file identity survives. `UNIQUE(file_id, started_at)`
makes recording idempotent: the same file starting at the same second is one
listen.

`recording_play_stats` (version 32) holds each Recording's play count and
latest `started_at`, one row per Recording with at least one listen. It is
keyed on `recordings.id` like `ratings`, so a song's plays count once whichever
of its files was heard, and survive a Track being reprojected. Migration 32
fills it from `listens GROUP BY recording_id`, skipping listens with a null
`recording_id`, after first setting every listen's `recording_id` to its
file's. Two invariants hold after every write:

- the table equals `SELECT recording_id, count(*), max(started_at) FROM
  listens WHERE recording_id IS NOT NULL GROUP BY recording_id`;
- every listen with a non-null `file_id` has its file's `recording_id`.

Plays follow the song. `ListenRepository.insertLocked` takes the listen's
`recording_id` from its file, not from the caller, and adds the listen to that
Recording's row in the same transaction, only when a row was inserted. The
production writer of `files.recording_id` is `FileRepository.setRecordingLocked`,
which the projection calls; the trigger `files_recording_moves_listens` sits on
the column itself, so it also covers any later writer. When a file with listens changes
Recording, the trigger moves those listens to the new Recording and recomputes
the old and new Recordings' rows from `listens`, deleting a row whose count
falls to 0, all inside the statement that changed the file. A Recording that
two files merge into therefore shows the sum of their plays. A listen whose
file is gone keeps the `recording_id` it had and keeps counting there.
A Recording deleted with `ON DELETE CASCADE` takes its row along; no
production path deletes Recordings, and a path that deletes listens must
subtract them here. `recording_play_stats_by_count` and
`recording_play_stats_by_last_played` index the two orders, and
`listens_by_recording` the trigger's recount.

Moving a listen does not touch its `scrobble_queue` row: the payload is built
from the listen's snapshot when it is queued and is keyed
`listen:<listens.id>`, so a listen already queued is sent as it was heard.

`trackPlayStats`, `TrackSummary.play_count` and `last_played_at`,
`TrackDetails`, and `TrackSort.play_count` and `last_played` read the Track's
Recording's row; a Track without a Recording, or a Recording without a row,
has 0 plays and no last play. `filePlayStats` still counts the listens of one
file, for the callers that ask about a file rather than a song.

A listen stores a snapshot of the title, artist, album, duration and
recording MBID that were heard, so history stays readable after the file is
gone. `remove-root` deletes the root's files and the Recordings only they
held, and `ON DELETE SET NULL` on `file_id` and `recording_id` leaves the
listen in place with a null file and, when its Recording went too, a null
Recording, rather than deleting it or failing the delete. Rows with a null
`file_id` no longer count towards a file in `filePlayStats`, and still count
towards their Recording while it exists.

`ListenRepository.recordAndQueue` inserts the listen and its `scrobble_queue`
row in one transaction with `event_key = "listen:<listens.id>"`, so a listen is
never stored without its delivery or queued twice.

Version 48 adds `listens.syncable`, 1 for every existing row. A listen kept
under a local listen policy that falls short of ListenBrainz's rule is
stored with 0 and never queued. `ListenRepository.finishSyncable` raises a
listen's heard time when its entry ends and, if that now meets the rule,
sets `syncable = 1` and queues it in the same transaction, at most once: the
`UPDATE ... WHERE syncable = 0 RETURNING id` matches only the first time.
`ListenRepository.clear` deletes, in one transaction, every `listen:` row of
`scrobble_queue`, delivered ones included, every listen and every
`recording_play_stats` row; feedback rows, ratings and loves stay. Listen ids
restart at 1 once the table is empty, so a delivered row left behind would
share its key with a new listen and the new one would never be queued. The listen policy and the recording switch are
`library_settings` keys `listens.policy` (an enum tag name) and
`listens.record` (`0` or `1`).

`scrobble_queue.state` is 0 pending, 1 leased, 2 delivered, 3 rejected.
`ScrobbleQueueRepository.lease` claims rows in one `UPDATE ... RETURNING`:
pending rows whose `next_attempt_at` has come, and leased rows whose
`lease_expires_at` has passed, so a worker that dies mid-submit strands nothing.
Every later mark (`markDelivered`, `markRetry`, `markRejected`, `release`)
applies only while `state = 1 AND lease_owner = owner`; a worker whose lease
expired and was reclaimed gets `StaleScrobbleEvent` instead of overwriting the
new owner's result. `release` returns a row to pending without counting an
attempt; the other marks count one. `nextAttemptAt` gives the earliest retry or
lease expiry for a worker to sleep until.

## Feedback

`feedback` (version 16) holds the user's love and hate. It is keyed on
`recordings.id`, so every file and Track of one song shares a row and a
reprojection that gives a Track a new id keeps it. Star ratings are a
separate thing (below). Rows are removed with their recording
(`ON DELETE CASCADE`), which `remove-root` does for a Recording only the
removed root held.

`score` is what the user wants (`-1`, `0`, `1`) and `synced_score` what
ListenBrainz was last told, so `score IS NOT synced_score` is exactly the work
left. A row is kept until it is synced: feedback given while scrobbling is off
waits, and so does feedback on a Recording with no MusicBrainz recording id,
which is never sent. Score `0` with a `synced_score` of `1` or `-1` is a clear
waiting to be sent; `markSynced` deletes the row once it has been, and clearing
a change that was never sent deletes it at once. A change the service refused
for good sets `synced_score` to what was refused and records the reason in
`last_error`, so it is not sent again until the user changes it.

The MusicBrainz recording id is the one in effect for any file of the
Recording, preferring a file some Track plays: a locked Orca value, else the
file's tag, else an accepted match (see
[metadata.md](metadata.md#musicbrainz-recording-ids)). It is found after the
files are rescanned or retagged. Removing a root forgets the Recordings only
its files held, with their feedback; adding and rescanning the same folder
creates new Recordings without it.

Version 16 also adds the index `files_by_recording ON files(recording_id)`,
which finds a Recording's files when looking for its MusicBrainz recording id.

`TrackSummary.feedback` comes from a `LEFT JOIN feedback` on
`tracks.recording_id` in the same statement as the page, never a query per row,
and the same statement selects `TrackSummary.recording_id` so a host can tell
which rows share a song. `FeedbackRepository.set` changes a bounded batch of
Tracks (`max_page`) in one write-lane transaction and skips, and counts, Tracks
without a Recording.

## Playlists and ratings

Migration 27 (version 27) adds `ratings`, `playlists` and `playlist_entries`,
and drops `tracks.rating` with its index after copying each Recording's
highest rating into `ratings`. The column lived on a row whose id changes
when an edit reprojects a Track, so no rating could have survived there.

- `ratings` is keyed on `recordings.id`, like `feedback`, with `rating`
  between 1 and 100 and no row for unrated.
- `playlist_entries` is `WITHOUT ROWID`, keyed on `(playlist_id, position)`,
  and names a `recording_id`. Positions are contiguous from 0. A shift parks
  the moved range on negative positions before landing it, because SQLite
  checks the primary key row by row and an in-place shift collides with a
  neighbour that has not moved yet.
- Entries and ratings go with their Recording, and entries with their
  playlist (`ON DELETE CASCADE`).
- `tracks_by_recording ON tracks(recording_id)` resolves an entry or rating to
  its Tracks, and `locations_by_uri ON locations(uri)` finds the location an
  imported playlist names.

See [playlists.md](playlists.md) for the behaviour.

### Playlist metadata

Version 35 adds six columns to `playlists` and the `playlist_tags` table. Existing playlists
keep their entries and order, and become manual, user-made and untagged.

- `description` (`''` when unset), `pinned_at` and `loved_at` (null when
  not). Pinning and loving leave `updated_at` alone; a description or tag
  change moves it.
- `kind` is 0 for a manual playlist and 1 for a smart one; `rules` holds a
  smart playlist's rules JSON as given and is null for a manual one. A smart
  playlist has no `playlist_entries` rows: its entries are the Tracks the
  rules match when it is read, under the `now` the caller passes.
- `creator` is 0 for a playlist the user made and 1 for one
  `libraryImportPlaylist` created.
- `playlist_tags` is `WITHOUT ROWID`, keyed on `(playlist_id, ordinal)`,
  and goes with its playlist (`ON DELETE CASCADE`).

## Library search

Version 36 adds `search_index`, a plain FTS5 table holding one row per
Artist (kind 0), Release (1), Playlist (3) and genre (4): `kind` and
`entity_id` unindexed, `title` and `subtitle` indexed with
`unicode61 remove_diacritics 2` and a prefix index on two and three
characters. The subtitle is a Release's album artist, a Playlist's
description, and empty for Artists and genres. Versions 36 and 37 also held
Tracks as kind 2; version 38 removed them, and Tracks are searched in
`track_search`, the external-content index the Track queries already use.

Its rowid is `entity_id * 8 + kind`. Triggers keep it current: after an
insert, after a delete, and after an update of the id or an indexed column
whose value changed, each a rowid lookup. The same rowid lets a query keep
one kind with `rowid % 8 = kind` without reading the unindexed columns,
which is what keeps a short prefix fast.

`track_search`'s update trigger, `tracks_au`, has the same guard since
version 38: it fires on an update of `id`, `title`, `artist`, `album` or
`album_artist` only when one of them changed. The projection rewrites those
columns on every upsert; an update that changes none of them leaves the
index alone instead of deleting and reinserting the Track's entry.

`SearchRepository.find` turns the text into a match expression in which no
character is syntax: each whitespace-separated word with a letter or digit
is quoted, with `"` doubled, given a trailing `*`, and the words are ANDed.
Artists, Releases, Playlists and genres are each ranked by
`bm25(search_index, 0, 0, 10, 4)`, weighting the title over the subtitle,
and limited separately, then the few hits are joined back for their text.
`ReleaseQuery.text` adds the same expression as a `releases.id` filter.

Tracks are ranked by tier instead, because bm25 scores every match before
returning the first. Three `track_search` queries each take the first
`limit` matches in rowid order:

| Tier | Every word of the text |
| --- | --- |
| 0 | is a whole word of the title |
| 1 | begins a word of the title |
| 2 | begins a word of the title, artist or album |

Each tier's matches are a subset of the next tier's, so taking a Track's
lowest tier and ordering by tier, then Track id, returns exactly the first
`limit` of all matches in that order. The tier is the hit's `rank`.
`album_artist` is left out of tier 2 because the Track subtitle, which a
match must explain, is the artist and album. Within a tier the order is by
id, not by how well the Track matches.

Each hit's detail is read only for the few hits a search returns, by
correlated subqueries on indexes: an Artist's Releases and Tracks through
`releases_by_artist`, `tracks_artist` and `tracks_release`, the predicates
`ArtistSummary` counts with; a Release's Tracks through `tracks_release`; a
Playlist's entries by its `playlist_entries` key and their duration through
`tracks_by_recording`; a genre's Tracks from `genre_totals`. Whether a
non-Track hit's title holds every word whole, which chooses
`SearchResults.top`, is a whole-word `{title}:` match on `search_index`
constrained to the hit's rowid. A Track's is its tier 0.

The reason hits for the first Artist hit are two more queries. The
Playlists holding its Tracks group the `playlist_entries` rows found
through `playlist_entries_by_recording` for the recordings of its Tracks;
its main genre groups `track_genres` by key over its Tracks. Both are
bounded by the Artist's Tracks. In a 511,872-Track library, with the
ReleaseFast build, the detail and reason hits move a search for `jun` from
75 ms to 77 ms, `the` from 91 ms to 95 ms and `amb` from 9 ms to 11 ms.

In the 500,000-Track benchmark (`zig build bench`), where `am` begins a word
in 142,858 Track titles and `the` in 142,857, a search takes 6 ms and 32 ms;
a three-word search takes 9 ms, and a Release page or count with text 14 ms
and 1 ms. `the` costs more because the benchmark retitles every Track,
leaving `track_search` in many unmerged segments that the prefix tiers
read; after an FTS5 `optimize` its prefix tier takes 2 ms, as `am`'s does.
Ranking every Track match with bm25 in `search_index`, as versions 36 and
37 did, took 114 ms for either. The insert phase takes 13.6 s; it took
22.2 s with Tracks in `search_index`, and takes 6.7 s with no full-text
triggers on `tracks` at all.

## Track facts

Version 32 adds `tracks.track_total`, `tracks.disc_total` and
`tracks.explicit`, which the projection writes from the Track's files.
`track_total` is the total the preferred file's tag states, else any member
file's, else a counted total: the larger of the number of positions on that
disc of the Release and the highest track number there, so a disc holding
tracks 2 to 4 counts 4, not 3. `TrackFileFacts.track_total_inferred` is true
only for a counted total, when no file of the Track states one. `disc_total`
is the preferred file's stated total, else any member file's, else the
Release's disc count. `explicit` is
`metadata.Explicit` by number (0 unknown, 1 none, 2 explicit, 3 clean), from
`observed_file_tags.explicit` (also version 32) or a user's edit; see
[metadata.md](metadata.md#parental-advisory). `ReleaseSummary.explicit` is
explicit when any of its Tracks is, else clean, then none. The migration
backfills the totals from the tags already observed; `explicit` stays unknown
until a rescan reads the files again. `releases.release_type` is added empty;
projection fills it with the lowercased primary type the files' tags agree
on, and a release-info fetch fills it from the MusicBrainz release group
only while it is NULL or empty, so a tag always outranks the provider.

`TrackSummary` also carries the playing file's `codec`, `sample_rate`,
`bit_depth` and `lossy`, `added_at` (`files.first_seen_at`) and `year` (the
first four digits of the Release date). `TrackSort.date_added` orders by that
same `files.first_seen_at` of the playing file, not by `tracks.created_at`,
which an edit that reprojects a Track resets.

Version 40 adds what `TrackSummary.integrated_lufs`, `bitrate_kbps` and `path`
read, and an index for each new sort:

- `file_loudness(file_id, source_identity, integrated_lufs)` holds the
  integrated loudness of each file's default `orca.audio-diagnostics` result
  (version 4, default parameters). Triggers on `analysis_results` keep it: an
  insert or a rewrite of `result` replaces the file's row, and deleting the
  result deletes it. The value is decoded in SQL from the stored result's
  little-endian `f32` at byte 8, written only when the result's flags say
  loudness was measured. A row counts only while its `source_identity`
  equals the file's `content_hash` with `content_hash_algorithm` 1, so
  changed bytes make the loudness unknown until the file is analysed again.
  The migration backfilled it from the results then stored, which were keyed
  by quick hash and so no longer count. `file_loudness_by_lufs` orders it.
- `files_by_bitrate` indexes `(size_bytes * 8 + duration_ms / 2) /
  duration_ms`, the kbps `TrackSummary.bitrate_kbps` reports, for files with
  a positive size and duration.
- `TrackSort.path` walks `locations_by_uri` and keeps a location only when it
  is the file's best one: not missing, `present` before `unverified`, then
  the lowest id.
- `tracks_sort_album_artist` orders `album_artist`, `album`, disc and track
  number, all case-insensitive where text.
- `genres_by_name` (`name COLLATE NOCASE`) and `track_genres_first` (the
  ordinal-0 rows by `genre_id`) give `TrackSort.genre` its walk.

Version 41 adds `files_without_bitrate`, the ids of files without a positive
size and duration. `TrackSort.bitrate` walks it for the Tracks that have no
bitrate, so a page no longer reads every Track to find them.

Version 43 adds `locations_held`, `locations(file_id, state)` over the rows
whose `state` is not `missing`. A test for a file's held location, as in
`TrackSummary.has_playable_file`, `bestLocation` and `TrackSort.path`, reads
only this index; `locations_file` holds no `state`, so each probe through it
also read the row. `TrackSort.path` finds the Tracks whose preferred file has no held
location by scanning `files` and probing `locations_held`, then joining
`tracks_by_preferred_file`. Every such Track needs that scan, and it is the
cost of a whole-library `path` page at offset 0: at 522,432 Tracks with a
file each, 274 ms before and about 150 ms after, a page and the probe of
every file; with 64 Tracks to a file, under 10 ms. A has-file flag kept on
`tracks` by the projection would make it an index range.

## Identification proposals

`identification_proposals` holds what the providers proposed for a file, keyed
on `files.id`: the providers that found the candidate (`musicbrainz`,
`acoustid` or `musicbrainz+acoustid`), its MusicBrainz recording id, Orca's
confidence from 0 to 1, and a JSON payload of what the providers said,
including each provider's confidence alone, AcoustID's score and the status,
date and track count of each release a search listed. `state` is 0
pending, 1 accepted, 2 dismissed. A file has one proposal per recording:
`IdentificationProposalRepository.recordSearch` finds an existing one by file
and recording id, whatever its provider, merges the new evidence into it and
keeps its state, so a dismissed proposal stays dismissed. A payload written
before per-provider confidences existed lends its row's confidence to the one
provider it names. Every payload field has a default, so payloads written
before a field existed still parse.

`identification_searches` (version 17) records which provider has answered
for which file, empty answers included: `(file_id, provider)` is its primary
key, `searched_at` is Unix seconds, and rows go with their file
(`ON DELETE CASCADE`). `recordSearch` writes the proposals and the search rows
of one search in one transaction, and only for providers that answered.
Migration 17 counts every file with a MusicBrainz proposal, in any state, as
searched by MusicBrainz, so no MusicBrainz search from before it is repeated.

`repository.unidentified_tracks` is the one definition of which Tracks the
matching job still has to search: those whose playing file has no recording
id in effect and lacks a search row for MusicBrainz, or for AcoustID when
AcoustID is in scope. The job's page and its count both use it, and every
lookup in it is by key: the three recording-id lookups and the two search-row
checks by primary key.

`acoustid_submissions` (version 17) records each fingerprint AcoustID
accepted: `(file_id, recording_mbid)` is its primary key, with the
`submission_id` AcoustID returned and `submitted_at`. Rows go with their file.
`repository.acoustid_submittable` selects the files a submission sends: an
Orca value for the recording id with `provider` or `user` provenance that is
the id in effect, is not the file's tag unless Orca wrote it there, and has
no row here for that id. A `provider` value also needs its accepted proposal
on the same file. Editing the id makes the file eligible again under the new
one.

`identification_proposals.album_group` (version 28) is null, or the integer
an [album correction](metadata.md#corrections) shares among its proposals,
one past the highest group in use when a verification forms it. A
verification unit first takes its files' proposals out of any group, so a
group holds the proposals of one unit. The partial index
`identification_proposals_album_group ON (album_group, state) WHERE
album_group IS NOT NULL` lists and finds groups. The review page and its
count leave grouped proposals out.

`health_dismissals` (version 29) holds one row per dismissed health issue,
keyed on `(file_id, kind)` and going with its file: the file's `quick_hash`
when it was dismissed, null for a file never hashed, and `dismissed_at` in
Unix seconds. The health page and count leave out an issue whose dismissal
`quick_hash IS files.quick_hash`, through the primary key. Version 29 also
adds `library_health_issues.related_file_id`, the other file of a duplicate,
set to null when that file is deleted, with the partial index
`library_health_by_related` the delete uses. See
[analysis.md](analysis.md#dismissals). `library_health_by_kind ON (kind,
severity, file_id)` serves the per-kind page and summary; see
[analysis.md](analysis.md#by-kind).

Version 49 adds `library_health_issues.similarity`, a nullable `REAL`: the
fingerprint score behind a `likely_duplicate`, which before lived only as a
rounded percentage in `details`. It is null for every other kind and for
likely duplicates recorded before version 49 until the duplicate pass runs
again. [Duplicate groups](analysis.md#groups) read it, and
`DuplicateGroupRepository.mergeMetadata` writes
`orca_metadata_values`, `track_genres`, `ratings` and `feedback` in one
transaction; see [analysis.md](analysis.md#resolving-a-group).

`recording_verifications` (version 28) holds each file's latest
[verification](providers.md#verification), keyed on `files.id` and going
with its file: the `quick_hash` the file had, the `recording_mbid` in effect,
the `outcome` (0 agrees, 1 disagrees, 2 unconfirmed, 3 no fingerprint), the
recordings heard as JSON (`[{"mbid","score"}]`, strongest first, at most
eight; null for no fingerprint), and `verified_at` in Unix seconds. Staleness
is computed, never stored: a row is stale when `quick_hash IS NOT
files.quick_hash` or `recording_mbid IS NOT` the recording ID in effect.
`repository.verifiable_*_sql` select the play files with a recording ID in
effect whose row is missing or stale, per Release, per Track or for Tracks
with no Release, through `tracks_release` and primary keys, and add a file
whose row `disagrees` when its Release has such a file or for one Track.
Each is built from the one `verifiable` definition, so the job's count and
its walk agree. A
correction AcoustID found is never submitted back to it: its accepted
proposal was not found by MusicBrainz alone.

`orca_metadata_values.written_at` (version 21) is when a tag write last put
the value into its file, or null. Changing the value clears it; undoing the
write does not. A tag write marks the file its path resolves to after the
write is observed, which is a new file when the path was one copy of a shared
file; the copy the write left keeps the value unmarked. The submission query
reads it to tell a tag Orca wrote from one the file already had. A copy split
off by a tag write has no `acoustid_submissions` row, so a recording id the
user edited is sent again for it.

## Provider state

`provider_state` (version 19) holds each service's rate-limit block
(`blocked_until_ms`), backoff (`backoff_ms`) and next request time
(`next_request_ms`, version 24), keyed by service name, so
every process that opens the Library obeys one block. `provider_leases`
(version 19) records which Gateway may send the request in flight to each
service: `owner` is a random id per Gateway and `expires_at` is when the
claim lapses. A Gateway claims it for each request and deletes it when the
request ends. Both tables keep Unix milliseconds.
`ProviderStateRepository.claimLease` claims in one upsert that applies only
when the row is absent, expired or already the claimant's, so two Gateways
never both hold a service. See
[providers.md](providers.md#rules-toward-providers).

`provider_cache` keeps a provider's refusal of a query beside its answers: a
row whose `status` is not `200` is a refusal, which the provider clients
answer as refused until it expires and never use as an answer.

Version 19 also adds `identification_proposals.accepted_in_bulk`: 1 for a
proposal accepted by `acceptConfident`, 0 for one accepted on its own and for
every proposal accepted before version 19. AcoustID submission leaves out an
ID whose accepted proposal was found by AcoustID or accepted in bulk, and an
ID a file holds without its accepted proposal, as a copy split off a shared
file does.

## Release artwork

`release_artwork` (version 20, rebuilt in version 51) holds the covers the
Library keeps for a Release, one row per kind: the primary key is
`(release_id, kind)`, and `release_id` references `releases(id)` with
`ON DELETE CASCADE`, so a pruned Release loses its rows; one reprojected
under a new id hands them over as [Album love](#album-love) describes.

- `kind` is 0 front, 1 back or 2 booklet (`ReleaseArtworkKind`).
- `source` is 2 for a cover fetched from the Cover Art Archive and 3 for one
  a person chose, from a candidate or a file (`ReleaseArtworkSource`; 0
  embedded and 1 folder are never stored, because those covers are read
  from their files). A fetched cover never replaces a chosen one, so a
  person's choice survives every later fetch.
- `musicbrainz_release_id` is the archive release the image came from, null
  for a cover chosen from a file.
- `image` and `mime` are the cover, and `width` and `height` its pixel size,
  measured from the image header when it is stored, -1 when the header does
  not read (`unreadable_cover_side`), and null only on a cover stored before
  version 51 that is not yet measured. A cover of unknown size raises no
  `undersized` problem. A null `image` records that the archive had no front
  cover, which stands for 30 days.
- `fetched_at` is Unix seconds.

`ReleaseArtworkRepository.coverReleaseMbid` chooses the release ID to fetch
under: the Release's tagged one, else the one most of its accepted proposals
name. See [providers.md](providers.md#cover-art-archive).

`cover_art_candidates` (version 51), primary key `(release_id, caa_id)`,
holds the images the archive offered the last time a person asked for a
Release's candidates, at most `max_cover_art_candidates` (8), replaced as a
whole by the next request: the archive's image ID, the
`musicbrainz_release_id` it belongs to, `kind` (0 front, 1 back, 2 booklet,
3 an image of the release the archive picks for the Release's release group,
4 anything else), `width`, `height` and `mime` measured from the full image,
null when it was not fetched or did not read, `approved` and the 250-pixel
`thumbnail`. The full image is never stored here; using a candidate fetches
it again into `release_artwork` as a chosen cover. It cascades and is handed
over with the Release like `release_artwork`, and clearing fetched provider
data deletes it with the fetched rows of `release_artwork`.

### Artwork problems

`artwork_problem` health issues are settled from the database alone, never
from image bytes, so the scanner records each local cover's size when it
reads its bytes: `observed_file_tags.artwork_width`, `artwork_height` and
`artwork_hash` for the embedded picture `artwork_mime_type` describes, and `folder_images.width`,
`height` and `hash` for a folder image. `hash` is the first 8 bytes of the
image's BLAKE3 digest, little-endian, as a signed integer, and 0 when the bytes would not
read, with `width` and `height` null; a readable image's hash is never 0.
An unchanged rescan reads neither,
and projection only reads these columns.

A Release's front cover in effect is the chosen one, else an embedded one,
else a front folder image, else the fetched one. Each of its files carries
at most one problem: `missing_front` when none of them exists,
`conflicting` when its embedded cover and the folder's front image have
different hashes, and `undersized` when the front in effect is under
`minimum_cover_pixels` (500) on either side, with the size in the details.
An unmeasured cover raises nothing.

Covers stored before version 51 are repaired by `ArtworkBackfill`
(`library/artwork_backfill.zig`), which property backfill runs after the
files missing properties and in the same manner as migration 10's repair: it
pages the three partial indexes by id, never walking a filesystem. It reads an embedded
cover's picture and a folder image's header from their files when their size
and modification time are those observed, and passes over one that changed
or is unreachable; a file whose picture will not read is stored with hash 0
and is not read again. It measures a kept `release_artwork` cover from the
stored bytes; one whose header will not read is stored with `width` and
`height` -1 and is not read again. Each batch settles the problems of the Releases it
measured in its own commit.

## Album love

`release_loves` (version 30) records the albums the user loves: one row per
loved Release, `release_id` its primary key referencing `releases(id)` with
`ON DELETE CASCADE`, and `loved_at` the Unix seconds it was loved. No row
means not loved. It is kept in the Library only: it is not `feedback`, which
belongs to a Recording and is sent to ListenBrainz, so loving an album
changes no song's feedback and is never sent.

A Release's id is not stable. An edit, an accepted match or a retag that
changes the album, album artist or release ID reprojects its Tracks under a
new Release and prunes the old one, which would cascade the love away. So,
like `release_artwork`, the projection hands the row over before pruning
(`carryReleaseState` in `library/projection.zig`): when a Release is no longer
used, its row goes to the Release that now holds most of its moved Tracks, a
tie going to the lower id, and only when that Release has no row of its own.
Two loved Releases merging into one therefore keep one love, and a split
album's love goes to the larger side. A Release removed outright, as
`remove-root` removes the Releases only its files used, takes its row with it.

`ReleaseLoveRepository.set` loves or clears a bounded batch of Releases
(`max_page`) in one write-lane transaction and skips, and counts, ids that
name no Release. Loving a loved Release keeps its `loved_at`.
`ReleaseSummary.loved` comes from a `LEFT JOIN release_loves` in the page's
own statement; `ReleaseQuery.loved_only` and `ReleaseSort.loved` (most
recently loved first) read the same table. It has no index on `loved_at`:
a filtered page reads the whole table, which holds one row per loved album,
and the unfiltered sort orders every Release however it is indexed.

`TrackQuery.loved_only` and `TrackSort.loved` read `feedback` instead: a
Track is loved when its Recording's `score` is `1`, so a clear still waiting
to be sent (`score` `0`) is not, and the sort orders by `feedback.updated_at`,
most recent first, with Tracks that are not loved last in either direction.

## Track lyrics

`track_lyrics` (version 31) keeps what LRCLIB answered for a Track, one row
per Track: `track_id` is its primary key and references `tracks(id)` with
`ON DELETE CASCADE`. `query_digest` is the BLAKE3 digest of the title,
artist, album and duration the Track was looked up with, `lrclib_id` the
record's id, `synced` and `plain` its texts as LRCLIB sent them, and
`instrumental` 1 for an instrumental. A row with neither text that is not
instrumental records a miss. `fetched_at` is Unix seconds.

A row stands only while its digest matches the Track's current values: an
edit or a rescan that changes any of them leaves the row in place but
unused, and the next fetch replaces it. A Track's id survives its edits, so
no row is handed over. `TrackLyricsRepository.put` replaces the row in one
write-lane transaction and stores nothing for a Track that no longer
exists. See [providers.md](providers.md#lrclib).

## Genres

`genres` (version 33) holds one row per genre: `name` is what it is shown as,
and `key` the folded form two spellings of one genre share, uniquely indexed.
`track_genres` gives a Track its genres in order: `(track_id, ordinal)` is the
primary key, `genre_id` references `genres(id)`, both with `ON DELETE
CASCADE`, and `provenance` is a `metadata.Provenance` (0 for a file's tags, 1
for a user's edit, 2 for a provider's genres). `track_genres_by_genre(genre_id, track_id)` is unique, so
a Track carries a genre once, which the Track counts below rely on, and it
serves every genre filter.

`metadata/genre_alias.zig` folds a value: `text_key.normalizeKey` with spaces,
hyphens, underscores, dots, slashes and apostrophes removed, so `Hip-Hop`,
`hip hop` and `HipHop` are the key `hiphop`, then an alias table maps common
variants (`Hip-Hop/Rap`, `RnB`, `Alt Rock`) to one canonical genre and gives
common genres a canonical name. A value the table does not know keeps the
first spelling stored. `&` is part of the key, so `R&B/Soul` is its own genre.

Before folding, `genre_alias.parts` splits a value on commas and semicolons,
trims each part and drops empty ones; `genre_alias.foldAll` folds the parts
and drops a key already seen, so a Track's genres keep the order of their
first mention. A slash never splits. `unsplit_names` lists the genre names
that contain a comma (Discogs' `Folk, World, & Country`); one at the start of
the remaining text, ending there or at a separator, is taken whole. The tag
readers split only repeated fields and NUL separators, so
`observed_file_genres` keeps each value as the file stores it, and the split
happens wherever genres are written to `track_genres`: the projection,
`setTrackGenres` and migration 33.

The projection writes a Track's genres from the genre tags of its preferred
file, or else of the lowest-numbered file at that position that has any. It
replaces the Track's file rows on every reprojection and never touches a Track
that has user rows. `GenreRepository.setTrackGenres` replaces a Track's rows
with user rows; with no names it restores the file rows. When a regroup
removes a Track, its user rows move to the Track its file joins, unless that
Track has its own. Genres no Track carries are pruned once per projection run
and after each `setTrackGenres`.

`GenreRepository.fillFromProvider` writes provider rows (provenance 2) on a
Release's Tracks that have no file or user rows, replacing earlier provider
rows, or on an Artist's Tracks that have no rows at all, so an Artist's
genres never displace a Release's. The projection keeps provider rows on a
Track whose file states no genre, and a file's or a user's genres replace
them. `releasesWithoutGenres` lists the Releases with a MusicBrainz release
ID and a Track with no rows. See
[providers.md](providers.md#genres-from-musicbrainz).

Migration 33 fills `track_genres` for every Track from the genres of its
preferred file, or else of the lowest-numbered file of its recording that has
any, through the same split and folding, registered as the SQL functions
`orca_genre_part(value, n)` (the `n`th part, or NULL past the last),
`orca_genre_key` and `orca_genre_name`. A recursive CTE expands each observed
value into its parts, so a library scanned before version 33 gets split genres
without a rescan.

`genre_totals` (version 38) holds each carried genre's Track count,
Release count, artist count and summed duration, so a genre listing, its
count and `byId` read one row per genre and never aggregate `track_genres`.
Its artists are the Track artists and the album artists of those Tracks'
Releases, as `ArtistQuery.genre_id` lists them. Two reference-count tables
keep the distinct counts exact: `genre_release_tracks(release_id, genre_id,
tracks)` and `genre_artist_refs(genre_id, artist_id, refs)`, where `refs`
counts a Track once for its artist and once for its Release's album artist.
A Release or artist counts while its row exists.

Triggers keep the three tables equal to a `GROUP BY` over the Tracks on
every write, whichever code path makes it: inserting, deleting or moving a
`track_genres` row; changing a Track's `duration_ms`, `artist_id` or
`release_id`; and changing a Release's `album_artist_id`, which moves its
`genre_release_tracks` counts from the old album artist to the new one. A
row whose count reaches 0 is deleted, so a genre is listed exactly while a
Track carries it, before pruning removes its `genres` row.
`tracks_genre_totals_bd` deletes a Track's `track_genres` rows before the
Track itself, because the cascade runs after the Track is gone and the
totals need its columns. The upkeep costs about 7 µs per `track_genres` row
written: seeding 744,000 rows on 500,000 Tracks takes 10.2 s instead of
3.8 s, and a listing page takes under 1 ms instead of 540 ms.
`migrations.genre_totals_drift_sql` counts the rows that differ from a fresh
`GROUP BY`; the tests assert it is 0.

`artworkReleases` lists the Releases of a genre that have a cover, by the
test `ReleaseQuery.has_artwork` uses, most played first.

A Track count filtered by genre alone counts `track_genres` rows for the
genre, which hold each of a Track's genres once.

## Artist info

Version 34 adds five tables keyed by their owner's id with `ON DELETE
CASCADE`, and `library_settings`. `artist_info`, `artist_links` and
`artist_related` hold an Artist's fetched info, `artist_loves` the user's
loves and `release_info` a Release's fetched description.

- **`artist_info`**, one row per Artist: the `musicbrainz_artist_id` and
  `wikidata_id` it was fetched for; the years active in `begin_year`,
  `end_year` and `ended` (1 when the Artist stopped, with or without a
  year), never a person's birth or death year (see
  [providers.md](providers.md#artist-info)), and `artist_type`; the
  biography's text, `biography_source` (0 Wikipedia), `biography_url`,
  `biography_licence` and `biography_language`, the article's language;
  `requested_language`, the language the fetch asked for, which differs
  when the biography fell back to English and is what reuse compares; the photo's
  bytes (`photo`, `photo_mime`), `photo_source` (0 a local image, 1
  Wikimedia Commons), `photo_url` (its Commons page), `photo_licence`,
  `photo_licence_url` and `photo_credit`; `fetched_at` in Unix seconds and
  the `ArtistInfoOutcome` number in `outcome`. A photo's details are written
  only with its bytes, so a credit can never describe another image.
  `listeners` is ListenBrainz's count of distinct listeners, null when
  ListenBrainz knows none, and `listeners_fetched_at` the Unix seconds of
  the last ListenBrainz refresh in which every request succeeded; reuse
  compares it, and `store` never changes either.
- **`artist_related`**, `WITHOUT ROWID`, primary key `(artist_id,
  ordinal)`: up to 12 related artists from ListenBrainz Labs, each with its
  `related_mbid`, `related_name` and `score`, highest score first. A refresh
  whose request succeeded replaces them all. `related` matches each to a
  library Artist by MusicBrainz artist ID, else by folded name, when it
  reads them.
- **`release_info`**, one row per Release: the Wikipedia `description`
  with `description_source` (0 Wikipedia), `description_url`,
  `description_licence` and `description_language`; `requested_language`;
  the `musicbrainz_release_id` and `musicbrainz_release_group_id` it was
  fetched for; `fetched_at` and the outcome. `store` replaces the row
  whole.
- **`library_settings`**, `WITHOUT ROWID`: `key` and a text `value`, the
  Library's own settings, never credentials. `genre_fill.musicbrainz` is
  `0` when automatic genre fill from MusicBrainz is off; absent, it is on.
- **`artist_links`**, `WITHOUT ROWID`, primary key `(artist_id, kind, url)`:
  the Artist's links, `kind` a `database.ArtistLinkKind` number, at most 64
  per Artist. A fetch that reached MusicBrainz replaces them all; one that
  did not keeps them.
- **`artist_loves`**: the Artists the user loves, `artist_id` the primary
  key and `loved_at` the Unix seconds it was loved, as `release_loves` is
  for albums ([Album love](#album-love)). Loving a loved Artist keeps its
  `loved_at`. Kept in the Library only and never sent.
  `ArtistSummary.loved` comes from a `LEFT JOIN artist_loves` in the page's
  own statement; `ArtistQuery.loved_only` filters by it and
  `ArtistSort.recently_loved` orders by `loved_at`, most recent first,
  Artists not loved last, each ending in `artists.id`.
  `ArtistSummary.has_photo` and `cover_release_id` are correlated
  subqueries in the same statement: an `artist_info` primary-key lookup, and
  the first Release in `ReleaseSort.artist` order through
  `releases_by_artist` (own Releases) or `tracks_artist` (appearances), so a
  page reads only its own Artists' Releases and needs no further index.

`ArtistInfoRepository.store` writes the row and, when given, the links in
one write-lane transaction, and `storeListenBrainz` the listeners and
related artists of an Artist that has a row, keeping the stored photo and its details unless
told to set or clear them. `earliestReleaseYear` gives the first four-digit
year of the Artist's Releases' dates. `releaseFolders` returns one present location and
its root for each of up to 64 of the Artist's Releases, from which
`core/artist_info.zig` derives the Artist's folder, and
`folderHoldsOtherArtists` checks that folder holds no other album artist's
files. Artists are keyed by name, so an Artist the projection renames or
prunes loses its rows with its id; nothing is handed over. See
[providers.md](providers.md#artist-info).

Version 37 adds **`related_artist_photos`**, `WITHOUT ROWID`, the photos of
related artists outside the Library: `musicbrainz_artist_id` the primary
key, `COLLATE NOCASE`; `photo` and `photo_mime`, both null for a marker
that the artist has no photo, a `CHECK` keeping them null or set together;
`photo_source` (a `PhotoSource`, always Commons), `photo_url` (the Commons
page), `photo_licence`, `photo_licence_url` and `photo_credit`, the same
attribution `artist_info` keeps, with `CHECK`s that `photo_source` is set
exactly when `photo` is and that a marker has no details;
and `fetched_at` in Unix seconds, which a fetch compares with
`refresh_after_s`. It is keyed by MusicBrainz ID rather than by Artist, so a
photo is shared by every Artist the artist is related to and outlives the
`artist_related` rows that named it. `storeRelatedPhoto` replaces a row
whole; `related` reports `has_photo` from it for an artist with no library
match, `relatedPhoto` reads the bytes and `relatedPhotoInfo` the attribution
without them.

Version 38 adds the index `analysis_results_created` on
`analysis_results(created_at)`, so `last_analysis_at` in the library stats
is one index probe instead of a read of every measurement and its overflow
pages. It also moves Track search out of `search_index`: it drops the
triggers `tracks_search_ai`, `tracks_search_au` and `tracks_search_ad`,
deletes the kind 2 rows, rebuilds `search_index` so no segment keeps the
deleted entries, and recreates `tracks_au` with the guard described under
[Library search](#library-search). `track_search` already holds every
Track, so nothing is reindexed. At 500,000 Tracks the delete and rebuild
take 2.9 s. Last, it creates `genre_totals`, `genre_release_tracks` and
`genre_artist_refs`, fills them from the Tracks with one `GROUP BY` each,
and then creates their triggers, described under [Genres](#genres).

Version 42 adds `artist_info.origin`, the name of MusicBrainz's begin area,
else its area, and **`artist_release_groups`**, primary key `(artist_id,
mbid)`, `ON DELETE CASCADE` from `artists`: the Artist's MusicBrainz release
groups from the artist-info browse, each with its `title`, `primary_type`,
`first_release_year`, `credited_with` (the credit's other artists) and
`position` in MusicBrainz's answer, at most `max_release_groups` (200).
`storeReleaseGroups` replaces them in one transaction: it marks the Artist's
rows by negating their positions, upserts the new groups, and deletes the
rows still marked, so a group in both the old and new answers keeps its row.
Every group is
stored, whatever its type and whether held or not; `elsewhere` leaves out,
when it reads them, each group whose primary type is not Album or EP,
compared without case, and each group whose MBID matches, without case, a `release_info`, `observed_file_tags` or
`orca_metadata_values` release-group ID of a Release filed under
the Artist or holding one of their Tracks, so the result follows the Library
without a refetch.

Version 44 adds **`release_group_covers`**, primary key `mbid`: the front
cover the Cover Art Archive gives a release group, as `image` and `mime`, and
`fetched_at` in Unix seconds, with a `CHECK` that `image` and `mime` are both
set or both null. A null `image` records that the archive had none, which
stands for 30 days. It is keyed by group ID rather than by Artist, so two
Artists credited on one group share its cover. The index
`artist_release_groups_mbid` and the trigger `artist_release_groups_cover_ad`
keep it free of orphans: after a row of `artist_release_groups` is deleted,
by `storeReleaseGroups` or by the cascade from `artists`, the cover goes once
no row names its group. `storeReleaseGroupCover` writes a cover only while a
row names the group. `elsewhere` reports each group's `cover` as
`not_fetched`, `none` or `kept`; `releaseGroupCover` reads the bytes, which
the artwork loader returns for `.{ .release_group = mbid }`, and
`releaseGroupCoverMark` whether there is an image and when it was fetched.

## Folder browsing

`LocationRepository.folderPage` lists one folder of a root from `locations`
alone; no schema serves it but the `UNIQUE(volume_id, uri)` index
(`sqlite_autoindex_locations_1`). A location's `uri` is the root's `path`, a
`/` and the path below it, so a folder is the half-open range
`[prefix, upper)` on that index, where `prefix` is the root's path (and the
folder's relative path) followed by `/`, and `upper` is `prefix` with the
final `/` replaced by `0`, the byte after it. The range is compared
bytewise, so `[`, `*`, `?`, `%` and `_` in a name match only themselves, and
no `GLOB` or `LIKE` is used.

- Children are found by skip scan: one `ORDER BY uri LIMIT 1` seek per
  child. A seek returning `prefix/name/...` is a folder, and the next seek
  starts at `prefix/name0`, skipping its whole subtree; one returning
  `prefix/name` is a file, and the next seek starts after it. A page costs
  one seek per child up to its end, not one row per file below the folder.
- Folders come first, ordered bytewise by `name/`, so `A (Deluxe)` sorts
  before `A`; files follow, ordered bytewise by name. `offset` counts
  folders, then files.
- A folder's totals read its range once into a materialized `DISTINCT
  file_id` set: its size is `file_count`, its join with
  `tracks_by_preferred_file` `track_count`, and its join with `files` the
  summed `duration_ms`. A file located twice in the folder counts once.
- Every statement filters `state <> 'missing'` and `+root_id`. The unary
  `+` keeps the planner off `locations_sweep`, which would read the whole
  root, as `mark_missing_under_sql` does.
- `folderTrackIds` reads the folder's whole range joined to
  `tracks_by_preferred_file`, ordered by `uri` then Track id, keeps each
  Track once and stops at `max_playlist_entries`.

`EXPLAIN QUERY PLAN` at a nested folder shows each statement as
`SEARCH locations USING INDEX sqlite_autoindex_locations_1 (volume_id=? AND
uri>? AND uri<?)`. At 500,000 locations in 25,000 artist folders
(`zig build bench`), the root's first page of 512 folders with totals takes
about 12 ms, a page two levels down under 1 ms, and the root's page at
offset 24,000, which seeks past 24,000 folders first, about 50 ms.

Version 45 adds the folder's pictures and its last scan:

- **`folder_images`**, unique on `(volume_id, uri)`, holds each image the
  scanner found beside the music: its `root_id`, `mime` (from the file's
  first 16 bytes; a file with no PNG, JPEG, GIF, WebP or BMP signature is not
  recorded), `role` (0 front for a name stem of `cover`, `front` or
  `folder`, 1 `back`, 2 `booklet`, 3 anything else; compared without case),
  `size_bytes`, `modified_ns`, `last_seen_generation`, and since version 51
  `width`, `height` and `hash` (see [Artwork problems](#artwork-problems)).
  An image is never
  a `files` row, so it never reaches projection, backfill, analysis or
  stats. An unchanged size and modification time skip the read, as for
  audio. The sweeps after an uncancelled run delete the rows the run did not
  reach rather than marking them missing: they hold nothing a later scan
  cannot observe again. `folder_images_sweep (root_id,
  last_seen_generation)` serves the sweep and `folder_images_folder
  (volume_id, rtrim(uri, replace(uri, '/', '')), uri)` lists the images
  directly in one folder in name order, and finds a Release's front images
  from the folder holding its Tracks' preferred files.
- **`folder_scans`**, primary key `(root_id, relative_path)`, `WITHOUT
  ROWID`: `scanned_at`, in Unix seconds, when a scan or reconcile last
  finished walking the folder, `""` being the root. The scanner records each
  folder once the depth-first walk leaves it, in the next batch's
  transaction; a cancelled walk records only the folders it finished.

Both tables go with their root (`ON DELETE CASCADE`). `folderPage` lists
images after the audio files, so `offset` counts folders, then files, then
images. A file's `status` is `unreadable` while it has an `unreadable_file`
health issue, which property backfill records, and `imported` otherwise.
The page also carries `image_count`, `last_scanned_at` and the Release
directly in the folder: its id, title and album artist when every present
Track preferred for a file in the folder belongs to that one Release, and
null otherwise, or when the folder has more than 512 children, so a page of
a library root never walks every folder in it. A folder holding only images, with no audio location below
it, is not listed as a subfolder.

Version 46 adds `releases.has_folder_cover`, 1 when the folder holding most
of the Release's present preferred files, the lowest path on a tie, holds a
front image, backfilled by the migration. It is stored because the
`ReleaseQuery.has_artwork` filter, its count and the genre artwork list read
it for every Release, and computing it there through `locations` and
`folder_images` cost the 500,000-track count about 65 ms.
`locations.releaseHasFolderCoverSql` is the one definition, and only these
write the flag:

- projection, for the Releases a folder's files project to and those they
  left, in the step that settles `artwork_problem`, so a moved or regrouped
  Track carries it;
- the scanner, for the Releases with a Track in the folder of each front
  image it records, retiring their `artwork_problem` when it is now 1;
- the sweeps after a run, for the Releases with a Track on a location they
  mark missing or in the folder of a front image they forget;
- root removal, for the Releases that lost Tracks.

A sweep does not raise `artwork_problem` again: a Release whose folder cover
went away gets it back the next time its folder is projected.
`releases.releaseCoverSql` adds a fetched Cover Art Archive cover to the
flag, and `ReleaseQuery.has_artwork`, the smart playlist `has_artwork` rule,
`TrackDetails.has_artwork`, the genre artwork list and projection's
`artwork_problem` all read it.

## Library stats

`LibraryStatsRepository.stats` (`Runtime.libraryStats`, `orca-cli stats`)
reads one row:

- `artists`, `releases` and `tracks`: `count(*)` of each table, the totals
  the unfiltered listings show.
- `files` and `total_bytes`: the files with at least one location whose
  state is not `missing`, counted once however many such locations they
  have, and the sum of their `files.size_bytes`.
- `total_duration_ms`: the sum of `tracks.duration_ms`, a null or negative
  duration counting as zero.
- `last_scan_finished_at`: `max(scan_runs.finished_at)` over completed runs.
  A cancelled or failed run does not count.
- `last_analysis_at`: `max(analysis_results.created_at)`, which the analysis
  cache sets on every insert and update.
- `last_duplicate_scan_at`: the latest `job_history.finished_at` of a
  `duplicate_scan` that `succeeded`. The history records host Jobs only and
  keeps the newest 1,000 rows, so a scan run by itself, or pruned away, does
  not count.
- `listens`: `count(*)` of `listens`.

The present files come from one scan of `locations` (`NOT INDEXED`) into an
ordered `DISTINCT`, joined to `files` by primary key in id order. Letting
the planner walk `locations_file` instead, or probing `locations` per file
with `EXISTS`, costs a table lookup per row for `state` and is about three
times slower at 500,000 files. `last_analysis_at` reads the last entry of
`analysis_results_created`.

## Job history

Version 47 adds **`job_history`**, one row per host Job that held its
Library's slot and finished, written by the control lane after the worker is
joined (see [control-plane.md](control-plane.md#history)): `kind` and `state`
as their enum tag names, `request` (the start request as JSON, null for a tag
write), `started_at` and `finished_at` in Unix seconds, `completed_units`,
`total_units` (null without a denominator), `error` (null on success),
`undo_group_id` (the tag write's mutation group, on success only),
`retryable` (1 when a request is kept and the Job did not succeed) and
`summary`, a line such as "1,204 files · 32 changed". Each insert prunes the
table to its newest 1,000 rows. `job_history_finished (finished_at, id)`
serves `JobHistoryRepository.page`, newest first; its filters are `scans`
(scan, reconcile, projection, property backfill), `analysis` (analysis,
duplicate scan), `file_changes` (tag writes) and `problems` (failed or
cancelled).

## Fetched cache

`FetchedCacheRepository` (`Runtime.libraryCacheSize`,
`Runtime.libraryClearCache`, `orca-cli cache`) measures and deletes the
provider data a Library keeps, all of which can be fetched again:

| `CacheSize` field | Tables |
| --- | --- |
| `artwork_bytes` | `release_artwork.image` of fetched covers (`source = 2`; a chosen cover is kept), `cover_art_candidates.thumbnail`, `release_group_covers.image` |
| `photo_bytes` | `artist_info.photo` unless it came from the Artist's folder (`photo_source = 0`), `related_artist_photos.photo` |
| `lyrics_bytes` | `track_lyrics.synced` and `plain` (LRCLIB) |
| `info_bytes` | the text of `artist_info`, `release_info`, `artist_links`, `artist_related` and `artist_release_groups` |

Clearing deletes those rows in one transaction under the write lane. An
`artist_info` row whose photo came from the Artist's folder keeps the photo,
with every fetched field nulled and `fetched_at = 0`, so the next look fetches
again. Embedded and folder covers are read from the files and
`releases.has_folder_cover`, and local lyrics from the files, so neither is
touched. `provider_cache`, the HTTP response cache, and the release
tracklist snapshots (`musicbrainz_releases`), which Match Review needs, are not
counted or cleared.

## Saved playback

`PlayerStateRepository` keeps one saved queue per Library. A save replaces
`player_state` and every `player_queue_entries` row in one transaction, at
most 10,000 entries (`max_saved_entries`), in playback order. `entry` is each
entry's index in the unshuffled list, so a shuffled queue restores in the
same order and unshuffles to the same list. Each row stores the Track id and
the Recording id it had when saved, with no foreign key to either. A load
resolves each row to the saved Track while that Track still has the saved
Recording, else to the lowest Track id of that Recording, else to nothing: a
reprojection that gives a Recording new Track ids keeps the queue, and an
entry whose Recording is gone is skipped and counted by the restore.

`track_positions` keeps where a long Track was left, keyed by Track and
cascading with it. Writing a position of zero, or a Track that is gone,
deletes the row instead. The runtime writes these from the control lane
only: on pause, seek, stop and each change of entry the host asks for, on
each save, and when the Player leaves its Library. It deletes a Track's row
once queue history records the Track as played to its end. See
[api.md](api.md#surface).

## Concurrency

- The primary connection uses WAL and `synchronous=NORMAL`.
- One write lane serializes complete write transactions. It is a real
  futex-backed mutex (`std.Io.Mutex`), not a spinlock: a scan worker holds it
  across a bounded 256-row transaction while UI threads read.
- Read snapshots use independent read-only connections.
- Connections use SQLite's full-mutex mode and a five-second busy timeout.
- One process at a time owns the mutation journal: the holder of an exclusive
  `flock` on `<database>.orca-journal.lock`, taken without waiting by open's
  recovery and by each tag write, undo and prune, which recover first. An open
  that cannot take it defers recovery to the next holder, and refuses with
  `error.MutationInProgress` when a migration is due. See [metadata.md](metadata.md#the-journal-lock).
- One scan or reconcile at a time walks a Library, across processes: the
  holder of an exclusive `flock` on `<database>.orca-scan.lock`. A walk that
  cannot take it is refused with `error.LibraryScanRunning`. See
  [storage.md](storage.md#one-walk-at-a-time).
- Prepared batch statements are reused within one transaction.
- On Linux, liborca switches SQLite's `unix` VFS from POSIX record locks to
  open file description (OFD) locks before its first connection opens. A
  POSIX lock belongs to the process, so any `close` of the database, `-wal`
  or `-shm` file anywhere in the process, such as a GTK file dialog browsing
  the folder, released it. A second Orca process then took itself for the
  last connection, check-pointed and deleted the WAL, and the first process's
  later writes went to an unlinked file and were lost. An OFD lock belongs to
  the open file and survives other closes. Caveats:
  - The override is process-wide: it applies to every SQLite connection in
    the process, the embedder's included.
  - An embedder's own multi-connection SQLite use in rollback-journal mode
    in the same process can see spurious `SQLITE_BUSY`.
  - An embedder must not open SQLite connections before liborca's first
    open: SQLite's system-call table must not change under open
    connections.
  - macOS has no OFD locks and keeps POSIX locks; see
    [roadmap.md](roadmap.md#known-issues).

Automated coverage verifies that a migrated library files every Track exactly
where a fresh projection does, that an album returns in disc-then-track order,
that paging a sort with ties returns every Track exactly once, that reversing a
sort reverses the whole listing rather than only its first key, that an
out-of-range page is refused rather than clamped, and additionally independent
libraries and indexes, FTS paging, a
10,000-row transactional update, concurrent read access while four write
producers serialize, that a rename preserves file identity and everything
attached to it, and that migrating the checked-in version-7 fixture preserves
every path-keyed row. The executable benchmark generates 500,000 tracks without
involving a scanner and measures insertion, reopen, and search latency.
