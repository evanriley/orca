# Metadata

This file covers how Orca models, edits, matches, reads and writes track
metadata: the metadata layers, Library edits, match acceptance, cover art,
lyrics, and the journaled mutation of media files.

## Layers

- `ObservedFileMetadata` records what a source file currently says.
- `OrcaMetadata` records preferred values, user edits, locks and accepted
  provider matches without mutating the file.
- `EffectiveMetadata` is a resolved view under an explicit preference policy.

Every value carries provenance. A user-locked Orca value outranks automatic
resolution even when the policy prefers file tags.

Format readers and writers terminate at this boundary: format-specific genre
numbers, fixed-width storage and comment keys do not define the canonical model.
The ID3v1/v1.1 mapping rejects text it cannot represent without loss.

The scanner persists observations in `observed_file_tags` (genres in
`observed_file_genres`), one row per `files` row, in the same bounded
transaction as the file row. Observations never update Track metadata and never
cause a write to a source file.

## Library edits

`Runtime.libraryEditTracks` sets or clears Orca's own values for Tracks without
touching their files. A set value is a locked `user` value in
`orca_metadata_values` on every file the Track resolves to, so it outranks the
files' tags and survives rescans; a cleared value lets the tags apply again. The
edited files are reprojected before the call returns, which moves a Track to
another Release or Artist when the edit says so.

Editable fields are title, artist, album, album artist, track number, disc
number, date, compilation, the MusicBrainz recording, release, release-group,
release-track and album-artist IDs (lowercase UUIDs), the
[parental advisory](#parental-advisory), the
[composer and comment](#composer-and-comment), and genres (see
[Genres](#genres)). `metadata.Field` only appends, because
`orca_metadata_values.field` stores fields by number. `orca-cli edit` and the
`orca-gtk` tag editor drive it.

Writing the values into the files is a separate, explicit mutation; see
[Writing tags back](#writing-tags-back).

## MusicBrainz recording IDs

A file's MusicBrainz recording ID is what its listens and its recording's love
and hate are sent to ListenBrainz under. The ID in effect is:

1. a locked Orca value: a user's edit or an accepted correction;
2. else the file's tag, when not empty;
3. else an unlocked Orca value, which is an accepted match.

`repository.effectiveRecordingMbid` states this order once in SQL, and the
listen subject and the feedback queries use it. `TrackRepository.recordingMbid`
applies `metadata.resolveValue` under `prefer_file` to the same values for
`TrackDetails.musicbrainz_recording_id` and its source (`tag`, `match` or
`edit`). A file that gains a tag on a rescan uses the tag at once, and matching
does not search for it.

The projection does not read the recording ID. A tag write stores it as
`MUSICBRAINZ_TRACKID` in FLAC, and as a `UFID` frame owned by
`http://musicbrainz.org` in MP3 and ADTS, as Picard does. Which IDs reach
AcoustID is in [providers.md](providers.md#acoustid-submission).

### Accepting a match

A match is an `identification_proposals` row from the matching job
([providers.md](providers.md#matching)). Nothing takes effect until a person
accepts one. `IdentificationProposalRepository.acceptProposal` runs in one
transaction:

1. Reads the proposal: `error.UnknownIdentificationProposal` when it does not
   exist, `error.StaleIdentificationProposal` when it is not pending.
2. Parses its payload and checks its recording ID:
   `error.InvalidProposalPayload`, with nothing written, on failure.
3. Refuses a proposal in an album group with `error.ProposalInGroup`.
4. Stores the recording ID as an unlocked `provider` value for the file, and the
   title and artist (the release track's when the proposal was looked up on its
   release, else the recording's) on every file of the Track. A correction
   stores them locked; see [Corrections](#corrections).
5. Marks the proposal accepted and dismisses the file's other pending proposals.
6. Applies the consensus of the Release the Track belongs to.

Every value goes through one upsert: a locked value is kept, a value equal to
the stored one keeps its `written_at` and is not counted, an empty value is
never stored, a MusicBrainz ID must be a lowercase UUID, and a value is cut to
4096 bytes on a character boundary. `values_written` counts every value stored,
the Release's other files included. No media file is written.

`Runtime.libraryAcceptMatch` and `libraryAcceptConfidentMatches` reproject the
files given values before they return, so a Track can move to another Release. A
frontend holding a Release id reloads it after an accept; see
[Release identity](#release-identity).

#### Release consensus

`IdentificationProposalRepository.applyReleaseConsensus(release_id)` stores a
MusicBrainz release's album-level values once the whole Orca Release agrees on
it. It holds when every Track of the Release has a play file that names the same
release R, by an accepted proposal looked up on R or by an observed
`MUSICBRAINZ_ALBUMID` of R; a file whose location is missing counts. A Release
of more than 512 Tracks never reaches consensus.

When it holds, every file of every Track accepted on R gets R's album, album
artist, date, disc and track numbers (positions on R) and the release,
release-group, release-track and album-artist IDs, the last only when R credits
one artist. A release credited to Various Artists
(`89ad4ac3-39f7-470e-963a-56509c546377`) adds `compilation=1`. A Track that
names R only by its tag gets nothing. Applying it again stores nothing.

An accept applies it in its own transaction, bulk acceptance once per Release it
touched before each commit, and Match Album at its end.

#### Applying a release

`Runtime.libraryApplyRelease(library, allocator, release_id, fields)`, `orca-cli
apply-release --fields=` and `orca_library_apply_matched_release_fields` store
the `ReleaseFieldSet` a person chose of the Release's best candidate
([api.md](api.md)), locked, and return a `ReleaseApplyOutcome`.
`Runtime.libraryApplyMatchedRelease(library, release_id, fields)` does the same
with a non-null `fields` and returns only the number of values stored.

With `fields` null (`apply-release` without `--fields`,
`orca_library_apply_matched_release`), `libraryApplyMatchedRelease` stores every
value of the release that every Track names by tag or accepted match, as
unlocked provider values, and accepts no proposal. A Release whose Tracks do not
all name one release stores nothing.

An Apply with fields takes its values from the candidate's tracklist snapshot
laid against the Release by the [alignment](#release-alignment), not from
proposals. It fails with `error.NoReleaseTracklist` without a snapshot,
`error.NoReleaseCandidate` without a candidate and `error.ReleaseTooLarge` over
512 Tracks (the count-only API returns 0). Tracks the alignment does not place
never refuse an Apply. On every file of each Track with a play file it stores:

- `album`: the release title;
- `album_artist`: the release artist credit, plus `compilation=1` when the
  credit is the Various Artists artist alone;
- `release_date`: the release date;
- `release_id`: the release and release-group IDs, and the album-artist ID when
  the credit names one artist.

A Track the alignment places `automatic` or `paired` also takes its release
track's values:

- `release_id`: disc and track numbers, and the release-track and recording IDs;
  the pending proposal that placed it automatically (never a correction or one
  in an album group) is accepted;
- `track_titles`: the title and artist credit.

A snapshot without the release's artist IDs leaves the album-artist ID and
compilation flag alone. `release_type`, `genre` and `artwork` are compared by
Match Review but never stored. A user's locked value wins, including a value a
pairing set; a locked provider value is replaced. An equal value is not counted,
and fields not selected keep their values and provenance. Without `release_id`
pending proposals stay pending. The stored values are locked, so they outrank
the files' tags under `prefer_file`, and a later user edit replaces them. No
file is written; the Release is reprojected.

`ReleaseApplyOutcome` carries the release ID, the values stored, `track_values`
and `release_values_only` (Tracks that took release-track values, and Tracks
that took only the release's), `artist_ids_unknown`, a `LeftAloneTrack` per
Track given no release-track values (reason `not_placed` or `no_play_file`), and
`reviewed_release_id`. An Apply that left no Track alone marks the reprojected
Release as [reviewed](#marking-a-release-as-reviewed) whatever fields it chose,
including none, and whatever values still differ, so a finished Release leaves
the Confident and Needs Review lists. `reviewed_release_id` is the Release's ID
after the reprojection, or null when a Track is not placed afterwards or the
written files lie on several Releases. An Apply that left a Track alone keeps
the Release listed with its `needs_pairing` count.

#### Release candidates and confidence

A Release's candidates are the releases its Tracks' release IDs in effect name
and the releases its pending and accepted proposals list. A candidate's
confidence is the mean over the Release's Tracks of each Track's score:

- 1 when the Track's release ID names the candidate, Orca holds the
  candidate's snapshot and the alignment places the Track `automatic` or
  `paired`;
- otherwise 1 when an accepted proposal was pointed at the candidate;
- otherwise the confidence of the first pending proposal that lists it;
- otherwise 0.

Release IDs are compared in lowercase, the form MusicBrainz uses, so a tag
holding an ID in uppercase names the same release. A value that is not a
MusicBrainz ID names no release: it is never looked up and gives no
candidate.

A release ID alone is a claim, not evidence. While a Track's release ID names
a release Orca holds no snapshot of, that candidate is unread:
`ReleaseCandidate.confidence` is null (`ReleaseCandidate.unread`), it ranks
above every read candidate, its title falls back to the Release's album title,
and the Release is in the `needs_review` bucket whatever the threshold. A
match run reads it, as [the next section](#marking-a-release-as-reviewed)
describes, and the candidate is then weighed like any other.

#### Marking a release as reviewed

`Runtime.libraryMarkReleaseReviewed(library, release_id, release_mbid)` and
`orca-cli mark-release-reviewed` record that a person decided the Release is
`release_mbid`, or its best candidate when null, and keeps its values as they
are. Values that differ from the release do not refuse it. It is refused with
`error.ReleaseNotPlaced` unless the Release has Tracks and every Track has a
play file and is placed `automatic` or `paired`.

The review is stored in `reviewed_releases` with a SHA-256 digest of the
snapshot's header and tracks, the Release's Track IDs, and each file's observed
tags and Orca values of the fields an Apply stores. It holds while that release
is the best candidate and the digest is unchanged. A Release whose review holds
is listed only in the `reviewed` bucket of the release-match page, and
`ReleaseMatchCounts.reviewed` counts it. A change to the Tracks, a value, the
best candidate or the snapshot brings the Release back; the stale row stays
until the next review replaces it.

A Release its tags identify is reviewed without a stored row: every Track's
play file has an observed `musicbrainz_release_id` tag naming one release, that
release is the best candidate, and the alignment with its snapshot places every
Track `automatic` or `paired`. It is listed in the `reviewed` bucket with
`ReleaseMatchItem.from_tags` set and counted in `ReleaseMatchCounts.reviewed`.
A person's review that holds takes precedence and clears `from_tags`. The
release-match page and counts decide this per chunk of Releases with one tag
statement and, for the releases its Tracks' release IDs name, one snapshot
read and one pairing read.

A library-scope match run (`Runtime.startLibraryMatching` without a Release or
Track, Match Again) looks up the releases the tags name once its Track walk
finishes without stopping. It takes, 64 at a time in release ID order, each
distinct release a Track's release ID in effect names, from fully, partially
and mixed tagged Releases alike, unless the Release with that Track dismissed
it, it has a snapshot younger than the 30-day cache, or MusicBrainz refused its
lookup (a `404` included) within the 7 days the refusal is cached. A refused
release is selected again once its refusal expires, under a changed release ID,
or by re-identifying its Release; an outage or timeout records nothing, so the
next run asks again. Each lookup stores a
whole snapshot or none, through the same gateway, cache and back-off as every
other request. A Release-scope run (Match Album) reads each unread candidate
before its best one. A cancelled, offline or busy run stops at the release it
reached; the next run selects the remaining releases again, since nothing
records the step as done. A run with a `limit` that the walk reaches skips the
step. Before its first lookup the step counts the releases it selects; the
Job's `total_units` becomes the Tracks walked plus that count,
`completed_units` advances by one for each release looked up or skipped and
reaches the total when the step ends, `current_item` is the album artist and
title of the first Release naming it, and `detail` is "looking up the releases
your tags name" until the step ends.

`Runtime.libraryUnmarkReleaseReviewed(library, release_id)` and `orca-cli
unmark-release-reviewed` delete the review, held or stale, and change no value:
`error.ReleaseNotReviewed` when there is none, including for a Release only its
tags identify. Such a Release returns to its own bucket when a file's release
ID tag is removed or names another release. `libraryDismissReleaseCandidate`
removes a release from the candidates.

#### Release identity

The projection resolves a Release's MusicBrainz release ID from the Orca value
and the tag under `prefer_file`, so an accepted release ID keys the Release. An
Apply, accept or edit that changes the album, album artist or release ID of
every Track of a Release, when no Release holds the new key, re-keys that row in
place. It keeps its id and with it its pairings, review, love, dismissed
candidates and covers, so a frontend holding the id follows it. Its release info
and stored release-level proposals are deleted.

When the Tracks instead join an existing Release, split, or share the Release
with files outside the reprojected folder, they move to another row. A Release
left without Tracks hands its fetched cover, cover candidates, love, dismissed
candidates and review to the Release that took most of them, each unless that
one has its own.

#### Match Review diff

`Runtime.libraryReleaseMatchDiff` compares the Release with a candidate release.
With a tracklist snapshot, the candidate side is what an Apply of it would
store; Tracks the alignment does not place show no candidate title or artist
credit. Without one, it comes from the Tracks' proposals. Each Track row carries
the local and candidate title and artist credit, and `differs` is set when an
Apply of `track_titles` would change either. The `track_titles` field counts
those Tracks. A field among `album`, `album_artist`, `release_date`,
`release_id` and `track_titles` differs exactly when an Apply of that field
alone would change a value in effect, computed by the dry run the Apply uses.
`release_type`, `genre` and `artwork` come from proposals and stored covers.

`Runtime.libraryReleaseMatchEvidence` takes the candidate's title, artist
credit and date from its snapshot when there is one, and compares each placed
Track's duration with its release track's length. Without a snapshot they come
from proposals. Fingerprint counts always come from proposals.

#### Release alignment

Match Review compares a Release with one MusicBrainz release's own tracklist,
the snapshot every matching lookup stores
([providers.md](providers.md#musicbrainz-release-lookup)).
`Runtime.libraryReleaseAlignment` and `orca-cli release-alignment` compute it on
each call; only a person's pairings are stored. Each release track, in disc and
position order, gets at most one Track and a status:

- `paired`: a person paired the Track with it ([Pairing a
  Track](#pairing-a-track)).
- `automatic`: the release track lists a recording ID the Track holds, from the
  play file's recording ID in effect, an accepted match or a pending match
  (`recording_source` says which).
- `suggested`: no recording ID places them, but at least two of three agree:
  titles equal after `text_key` normalization, lengths within 2000 ms, and the
  Track's disc (1 when unset) and track number equal the release track's. The
  pair is suggested only when each is the other's single best by that count; any
  tie suggests nothing. A person confirms it.
- `not_in_files`: no Track is on it.

Tracks placed on no release track are listed as not on the release. Every row
carries its evidence flags and the length delta.

Pairings place their Tracks first. Automatic placement then runs in four passes:
recording IDs in effect and accepted, then pending ones; within each, a Track
first takes a free release track listing its recording at its own disc and track
number, then the first free one listing it. Tracks go in disc, track number
(unset last), then Track ID order. A recording the release lists twice therefore
places a Track at its own track number, else on the first listing; of two Tracks
holding a recording listed once, the one at that track number wins, else the
earlier by track number, then lower Track ID; and a recording ID in effect or
accepted outranks another Track's pending match.

#### Pairing a Track

A person pairs a Track of a Release with one release track of one MusicBrainz
release that has a snapshot (`Runtime.libraryPairReleaseTrack`, `orca-cli
pair-track`). `release_track_pairings` stores the release track's recording ID
and whether it confirmed the suggestion shown at that moment
(`confirmed_suggestion`) or not (`by_hand`).

- Every file of the Track takes the release track's recording ID and
  release-track ID as locked user values, and Orca keeps the value each
  replaced. No media file is written. The Track's files are reprojected.
- A Track has one pairing. Pairing it again undoes the earlier one first.
- Errors: `error.TrackNotOnRelease`, `error.NoReleaseTracklist`,
  `error.UnknownReleaseTrack` (not in the snapshot) and
  `error.ReleaseTrackAlreadyPaired` (another Track holds it, until unpaired).
- A pairing outranks automatic placement.
- A pairing whose release track a newer snapshot no longer lists stays stored,
  is ignored by the alignment, and is listed by
  `Runtime.libraryReleaseTrackPairings` with `in_snapshot` false.
- Unpairing (`Runtime.libraryUnpairReleaseTrack`, `orca-cli unpair-track`)
  removes the pairing and, where a file still holds the value the pairing set,
  restores the value it replaced with its provenance and lock, or removes it
  when there was none.
- Editing either field in the metadata editor makes the value the person's own:
  unpairing leaves it.
- A pairing is deleted with its Track or Release. When its Track moves to
  another Release the pairing moves with it; another Track's pairing of the same
  release track there is deleted, and the values it set stay.

#### Corrections

A pending proposal is a correction when its file has a recording ID in effect
and the proposal names another. It is computed, never stored:
`MatchProposal.corrects` is the ID it would replace.
[Verification](providers.md#verification) proposes corrections, and so can a
re-identify. Accepting one stores locked `provider` values, so they outrank the
file's tags, a tag write writes them over the tags, and `TrackDetails` still
names their source `match`:

- the recording ID on the file, over any value, a user's locked edit included,
  since accepting is the user's explicit choice;
- the title and artist on every file of the Track, over an unlocked value or a
  locked `provider` value, so a title or artist the user set is kept;
- for a proposal in an album group, also the track and disc numbers and the
  release-track ID, under the same rule.

No album, release or release-group ID is written. The accept rules for equality,
empty values, IDs and length apply. Bulk acceptance never takes a correction.

A group is accepted only whole, because the projection re-seats a file whose
track number another holds, so half a swap would scramble the album.
`IdentificationProposalRepository.acceptCorrectionGroup` accepts every pending
member in one transaction and applies the consensus of each Release it touched;
`dismissCorrectionGroup` dismisses every pending member. An unknown group is
`error.UnknownCorrectionGroup`, one with no pending member
`error.StaleCorrectionGroup`. A correction is undone by clearing the fields it
set (Clear in Edit Tags, `orca-cli edit --clear=FIELD`).

#### Bulk acceptance

`acceptConfident` accepts at most one pending proposal per file, in commits of
at most 512, and passes over a proposal whose payload or recording ID it cannot
read or that is in an album group. A file with a recording ID in effect is left
out, since its proposals are corrections. It returns the proposals accepted, the
values stored and the files accepted or given a value.

Of a file's proposals that reach the given confidence, those found by AcoustID
with a fingerprint score of at least 0.9 are backed by the file's own audio.
When any is, the first of them in this order is accepted:

1. the higher percent, `floor(confidence × 100)`;
2. the track number of the Track that plays the file, when both are known;
3. found by MusicBrainz too;
4. the higher MusicBrainz score, unknown lowest;
5. the length closest to the Track's, unknown last;
6. the lowest recording ID.

A text-only rival never blocks such a match. When none is backed, the file's
most confident proposal is accepted only when it reaches the confidence and
shows a higher percent than every other pending proposal. A file accepted at one
confidence is therefore accepted at every lower one, and `confidentCount` runs
the same selection.

## Parental advisory

`metadata.Explicit` is a Track's advisory: `unknown` when no file states one,
`none`, `explicit`, or `clean`. The readers map the iTunes advisory number (0
none, 1 or 4 explicit, 2 clean) from the MP4 `rtng` atom or an `ITUNESADVISORY`
freeform atom, an ID3v2 `TXXX` frame described `ITUNESADVISORY`, and a Vorbis
`ITUNESADVISORY` comment in any case. Any other value states nothing.

The projection takes the preferred file's advisory, else the first member file's
that states one. A user edit (`metadata.Field.explicit`, `orca-cli edit
--explicit=yes|no|clean`) stores `1`, `0` or `2` and outranks the files;
`write-tags` writes it back as the same `TXXX` frame or Vorbis comment.
`Explicit.advisoryText` and `fromAdvisoryText` are the only place the numbers
are spelled.

## Composer and comment

`metadata.Field.composer` and `metadata.Field.comment` are free text, observed
into `observed_file_tags.composer` and `.comment`. The readers take them from:

- ID3v2: `TCOM`, and the first `COMM` frame with an empty description in any
  language. A described `COMM` (such as iTunes' `iTunNORM`) is other data. With
  no such `COMM`, the comment is the first `TXXX` described `comment`, in any
  case. An ID3v2 tag holding only a cover, a comment or both reads the ID3v1
  trailer's values beside them. The ID3v1 comment is neither read nor written.
- Vorbis comments: `COMPOSER` and `COMMENT` in any case; `DESCRIPTION` is the
  comment only when no `COMMENT` has text.
- MP4: `©wrt` and `©cmt`.

WAV and AIFF `INFO` chunks state neither. `TrackDetails.composer` and `.comment`
are a locked edit, else the preferred file's tag, else an unlocked edit
(`TrackRepository.resolvedField` under `prefer_file`), null when none states
one. Neither enters the projection, grouping or search. `orca-cli edit
--composer= --comment=` sets them and `--clear=composer|comment` drops Orca's
value.

## Genres

A Track's genres are kept in order in `track_genres` with their `Provenance`:
every genre its file's tags give, or up to 16 the user set. The readers report
each genre value as the file stores it (repeated `GENRE` comments, ID3v2 `TCON`
values split on NUL, MP4 `©gen` and `gnre`), and `observed_file_genres` keeps
those values whole. `metadata/genre_alias.zig` turns them into genres; the
splitting and folding rules are in [database.md](database.md#genres).

The projection takes genres from the Track's files and does not overwrite a
Track's `user` genres. `Runtime.librarySetTrackGenres` (`orca-cli edit
--genre=A;B`) replaces a Track's genres with `user` ones, which outrank its
files until cleared with no names (`--clear=genre`). `write-tags` writes a
Track's `user` genres into its files; genres that came from a file are never
rewritten.

## Cover art

The scanner records `artwork_mime_type`, `artwork_byte_size` and `artwork_kind`
in `observed_file_tags` from the tag read that produces every other observed
field. It never reads the image.

### Fetch

`metadata/artwork.zig` reads an image on demand from the file through
`id3v2.readPicture` or `vorbis_comment.readPicture`, stepping over a leading
ID3v2 tag. Within a file the first front cover wins, and with no front cover the
first usable picture is taken, the same preference the observation records. The
observation row is not consulted, so a Track whose stored observation is stale
still yields its cover.

- The media type comes from the bytes: `EmbeddedImage.mime_type` is what the
  magic bytes say. A payload that is none of PNG, JPEG, GIF, WebP or BMP is
  refused as `UnrecognizedArtworkImage`. `Artwork.mime_type`, an observation,
  records the declaration.
- `model.max_image_bytes` bounds an image at 12 MiB. The whole image is held in
  memory, so the bound is compared with the declared length before anything is
  allocated.

Images are not stored in the Library except one: a cover fetched from the Cover
Art Archive for a Release none of whose files has one (`release_artwork`; see
[providers.md](providers.md#cover-art-archive)). A chosen cover wins over an
embedded one, and an embedded one over a fetched one.

liborca keeps no image cache. `Runtime.libraryRequestArtwork` queues a request
on the Library's artwork loader (`core/artwork.zig`), which reads covers on its
own thread with at most `artwork.capacity` requests outstanding;
`Runtime.libraryTakeArtwork` collects results. Keeping decoded images is the
host's concern.

### Release artwork

A Release's artwork is the cover of its first Track, in listening order (disc,
track number, then `tracks.id`), that has one. Only files the last scan observed
artwork in are candidates, so a Release with no covers costs one indexed query
and no file opens, and at most eight candidates are opened
(`max_release_candidates`). `Runtime.libraryTrackArtwork`,
`Runtime.libraryReleaseArtwork` and `orca-cli artwork` return it.

## Lyrics

A Track's lyrics are read on demand from its file and a sidecar beside it, and,
when a lyrics job is asked to fetch, from LRCLIB. They are never scanned and
never written to a file; only LRCLIB's answers are kept in the Library
([providers.md](providers.md#lrclib)). `metadata/lyrics.zig` holds the model,
`metadata/lrc.zig` the parser every text source goes through,
`library/lyrics_lookup.zig` the sidecar and the choice between local sources,
and `core/lyrics_fetch.zig` the choice between those and LRCLIB.

### Sources

- Sidecar: the file's path with its extension replaced by `.lrc` (appended when
  there is none), case kept; `Song.LRC` is not found for `Song.flac` on a
  case-sensitive filesystem.
- ID3v2 (MP3, ADTS, FLAC behind ID3): `SYLT`, else the first non-empty `USLT`.
- Vorbis comment (FLAC, Ogg Vorbis, Opus): `LYRICS`, else `UNSYNCEDLYRICS`.
- MP4: `©lyr`.
- WAV and AIFF are not read.

`SYLT` is read only with millisecond timestamps (format 2) and content type
lyrics (1), using its own times. `USLT`, comments and `©lyr` are parsed as LRC.
All four ID3v2 text encodings are read, and the frame's language becomes
`Lyrics.language` (`XXX` is none).

`Lyrics.source_name` is the sidecar's file name, `embedded` or `LRCLIB`.
`Lyrics.offset_ms` is the text's `[offset:]` in milliseconds, 0 without one;
synced line starts already include it.

### Choice order

1. A synced sidecar.
2. Synced lyrics in the file.
3. Synced lyrics from LRCLIB.
4. A plain sidecar.
5. Plain lyrics in the file.
6. Plain lyrics from LRCLIB.
7. An instrumental from LRCLIB, with no lines.

LRCLIB's lyrics are those fetched or kept for the Track's current title, artist,
album and duration. A job that does not fetch still uses kept ones.

### LRC rules

- A line starts with one or more `[m:ss]`, `[mm:ss.f]`, `[mm:ss.ff]` or
  `[mm:ss.fff]` stamps; each stamp makes one line with the same text. A stamp
  with 60 or more seconds drops its line.
- `<mm:ss.xx>` word stamps are removed from the text.
- `[offset:N]` shifts every line to `start - N` milliseconds, clamped at 0.
- Other `[key:value]` ID tags and lines starting with `#` are skipped.
- A UTF-8 byte order mark and CRLF line ends are accepted.
- Text with any stamped line is synced and its unstamped rows are dropped;
  otherwise every row is a plain line. Text with only tags is no lyrics.

A source over 512 KiB, with more than 4096 lines, or not UTF-8 has no lyrics. A
malformed or unreadable tag reads as none; only running out of memory is an
error.

### Reaching it

`Runtime.startTrackLyrics` reads, and with `fetch` asks LRCLIB, on a job worker.
`Runtime.jobLyricsOutcome` says where lyrics were found or why none were,
`Runtime.jobTakeLyrics` moves the `Lyrics` to the caller (untaken lyrics are
freed with the job), and `Lyrics.lineAt(position_ms)` is the synced line being
heard. `orca-cli lyrics` and `orca-cli play-tracks --lyrics` print them; see
[cli.md](cli.md).

## File mutation

Files are written or moved only from an explicitly approved immutable
`MutationPlan`. A plan deep-copies every action, path, change and value (genres
included) into plan-owned storage at construction and seals the copy with a
BLAKE3 content digest. Approval names the digest as well as the plan ID, and
`beginExecution` reverifies the seal, so a caller cannot preview one plan and
execute another through an alias it still holds.

Identity is `(size, modified_ns, quick_hash, content_hash)`. `quick_hash` is
BLAKE3 over (first 64 KiB, last 64 KiB, size) (`storage/quick_hash.zig`) and
only nominates a match: an edit confined to the middle of a file larger than 128
KiB that keeps its size and modification time leaves it unchanged.
`content_hash` is BLAKE3-256 over every byte (`storage/content_hash.zig`) and is
what proves a file unchanged. A check compares size, modification time and quick
hash first and reads the whole file, streamed through a fixed buffer, only when
all three match.

The content hash is computed when the plan is built, as the backup copy is
written (from the bytes copied, with no second read), and by every check that
compares a file with a journaled identity: staging, the revalidation before the
rename, undo and recovery. The journal persists the full identity, so recovery
compares the same `FileIdentity` an in-process check does
([database.md](database.md)). `Plan.init` refuses an identity without a content
hash with `error.InvalidMutationPlan`. The executor does not write
`files.content_hash`.

Every action of a group is journaled before any filesystem work begins, and
journal writes raise SQLite durability for their own transaction, so a group is
always discoverable after a crash. Moves reject collisions and use the same
journal.

### The journal lock

One holder at a time owns a Library's mutation journal: the holder of an
exclusive advisory lock (`flock`) on `<database>.orca-journal.lock`
(`metadata.JournalLock`). The operating system releases it when the process
exits in any way, and a paused process keeps it, which a lease in the database
could not promise. It is taken without waiting and held only for the duration of
one of:

- `LibraryDatabase.open`, for recovery.
- A tag write, from `Runtime.startTagWrite` until the plan has executed.
- `Runtime.undoTagWrite`, until the group is undone.
- `Runtime.pruneTagWriteBackups`.
- `Runtime.libraryRelocateRoot`, while it rewrites the root and the journaled
  paths under it. It runs no recovery, which would look for files at the old
  path.

Tag writes and undo re-observe the files after releasing it. A write, undo or
prune that finds the lock held returns `error.MutationInProgress` and changes
nothing; a refused write's plan stays pending.

Once it holds the lock, the operation first runs recovery
(`LibraryDatabase.recoverPendingMutations`), because a holder that exited since
the Library was opened may have left work unfinished; a write does this on its
job's thread. A failed recovery fails the operation with its error and journals
nothing of its own. An open that finds the lock held leaves the journal alone,
since its rows belong to a live writer: it sets
`LibraryDatabase.recovery_deferred`, which the next recovery clears. Each
acquisition opens the file anew, so two acquisitions in one process exclude each
other as two processes do.

A Library with no database file has no lock file and no backup directory: tag
writes, undo and pruning return `error.NoBackupDirectory`, and its open runs no
recovery.

**Never delete the lock file.** A process that opened it before the deletion
still holds its lock, and the next process creates and locks a new file, so both
own the journal.

### Tag-write files

A tag write to `Album/01.flac` in plan 7, action 0, uses three files and the
journal lock. Only the backup outlives the write, and it lives outside the music
folders:

| File | Path | Exists |
| --- | --- | --- |
| Stage | `Album/.01.flac.orca-stage-7-0` | until the write commits |
| Backup | `<database>.orca-backups/7/0-01.flac` | until undone or pruned |
| Restore | `Album/.01.flac.orca-restore-7-0` | during an undo |
| Journal lock | `<database>.orca-journal.lock` | always; never delete it |

`<database>` is the absolute path of the database file, so the journaled backup
path does not depend on the working directory.

A write runs in three steps, and at every point either the original is in place
or a durable, verified copy of it exists:

1. Build the complete replacement at the stage, and fsync it and its directory.
2. Copy the original into the backup directory with its modification time, fsync
   the copy and every directory created for it, and verify the copy's size,
   modification time, quick hash and the content hash of the bytes copied
   against the identity the plan approved.
3. Revalidate the file's full identity, rename the stage onto it, and fsync the
   directory.

The stage and the backup get the file's exact permission bits, set after
creation so the umask does not narrow them; the rewritten file keeps its mode,
and an undo puts back the original's. Both are created by the writing process,
so the rewritten file belongs to that process's user and group and does not
keep the original's extended attributes or ACL entries.

The journal records the stage's identity before step 2 and the file's identity
after step 3; undo and recovery compare the file against that record. The backup
is a copy, so it may sit on another disk and uses its space until undone or
pruned. A disk that fills during the copy fails the write at step 2 with the
file untouched.

### Read-only files

Orca does not change a file the person has made read-only, although the rename
that replaces it needs only the folder's permission. A file is read-only when
no write permission bit is set, or when the process may not write it
(`access(W_OK)` fails, as for another user's file, an ACL or an immutable
file). `metadata.executor.requireWritableFile` decides it, and Orca never
changes the file's permissions.

- `planTagWrite` skips the file with `file_read_only`; the plan's other files
  are written.
- `executePlan` checks every file to write after journaling the group and
  before any filesystem change, and again before each backup copy. A read-only
  file fails its operation with `error.FileReadOnly`, journaled as
  `FileReadOnly`; it is not staged, copied or backed up, and the group rolls
  back as any failed write does. The Job's `TagWriteFailure` reason is
  `file_read_only`.
- An undo refuses with `error.FileReadOnly` while a file it would restore is
  read-only. It changes no file and no journal row, and runs once the file is
  writable again.
- [Recovery](#recovery) restoring a file refuses a read-only one the same way.
  The Library stays closed until the file is writable again, then the next
  open finishes the recovery.

### Undo

Logical groups undo in reverse action order. `undoGroup` starts from the states
of the group's operations:

- Every operation `committed`: a fresh undo.
- Some `undoing`, none `planned`, `staged` or `failed`: an interrupted undo,
  finished as recovery does, per the [Recovery](#recovery) tables.
- Every operation `rolled_back`: `error.MutationGroupAlreadyUndone`.
- Otherwise `error.MutationNeedsReconciliation` when an operation is
  `needs_reconciliation`, else `error.MutationGroupNotCommitted`.

Before a fresh undo changes any file it checks every operation. A write whose
backup was pruned returns `error.TagWriteBackupPruned`, and a
[read-only](#read-only-files) file returns `error.FileReadOnly`. A file that changed
since the write, or a backup that is missing or no longer has the original's
identity, records `needs_reconciliation` and returns
`error.MutationNeedsReconciliation`; both are compared by content hash, so an
edit that kept the size, modification time and quick hash is still refused.

It then journals its intent: every operation of the group becomes `undoing` in
one durable transaction, or none does. A crash or error from here on leaves the
group nonterminal, so the next undo or open finishes it; an operation never
returns to `committed`.

Each file is then restored: its backup is copied to the restore file with the
original's modification time, fsynced and verified, the file is revalidated
against the write's result, and the restore file is renamed onto it. The backup
is deleted, the plan and backup directories are removed once empty, and the
operation becomes `rolled_back`. An undo needs free space for one file on the
music disk; if the copy fails, the file is untouched and the operation stays
`undoing`.

### Recovery

`LibraryDatabase.open` applies the schema and runs journal recovery under the
[journal lock](#the-journal-lock) before returning the Library, and refuses to
open if recovery cannot reach a terminal state.

Recovery drives every group with a `planned`, `staged`, `failed` or `undoing`
operation to terminal states. It first marks the group's `committed` operations
`undoing` in one transaction, so a crash during recovery leaves the group
discoverable, then unwinds it in reverse action order. A `failed` operation
becomes `rolled_back` and keeps the error its write journaled; an operation
rolled back from any other state records `recovered`. A tag write being written
or undone is decided by identity alone:

| Found | Action | Result |
| --- | --- | --- |
| File is the original | delete stage, restore file and backup | `rolled_back` |
| Nothing was staged | delete a torn stage | `rolled_back` |
| File is the result, backup is the original | restore as an undo does | `rolled_back` |
| File is the result, backup is the original, file read-only | keep every file | refuses to open; retried at the next open |
| File is the result, backup missing or damaged | keep every file | `needs_reconciliation` |
| File's folder missing, as on an unmounted drive | keep every file | refuses to open; retried at the next open |
| File missing or matching neither | keep every file | `needs_reconciliation` |

An `undoing` operation reaches those rows from each point an undo can stop at:

| Undo stopped | Found | Result |
| --- | --- | --- |
| Before its restore, or during the restore copy | file is the result | restored, `rolled_back` |
| After the restore rename, or after deleting the backup | file is the original | `rolled_back` |
| After the file changed externally | file matches neither | `needs_reconciliation`, every file kept |

Orca removes directories only inside the backup directory, never a music folder.

### Pruning backups

`Runtime.pruneTagWriteBackups(library, io, older_than_s)` deletes the backups of
every group whose operations are all `committed` and were last updated at least
`older_than_s` seconds ago; zero prunes every committed group. A group being
undone or awaiting reconciliation keeps its backups, and nothing prunes
automatically. It returns a `PruneSummary` (backups pruned, bytes). Each backup
is deleted before its journal path is cleared, so an interrupted prune finishes
on the next run. A pruned write cannot be undone. `orca-cli prune-backups
DATABASE [--older-than=DAYS]` runs it.

### Change history

`Runtime.libraryTagWriteGroupPage(library, allocator, limit, offset)` lists
finished tag writes newest first, at most 512 at a time.
`Runtime.libraryTagWriteGroup(library, allocator, io, group_id)` shows one write
file by file. Both only read: they never write or move a media file and never
change the journal or a backup.

The history is derived from the journal. A `TagWriteGroup` is one `group_id`,
the plan id `undoTagWrite` takes:

- A group with a `planned` or `staged` operation is still being written and is
  left out; `libraryTagWriteGroup` returns `error.UnknownTagWriteGroup` for it,
  for a group of moves only, and for a group never written.
- `written_at` is the earliest `created_at` of its operations (Unix seconds);
  `file_count` counts them.
- `title` is the Release title every Track of its files shares, empty when they
  span several Releases or none.
- `state` is the first row that applies:

| Operations | `state` |
| --- | --- |
| Any `needs_reconciliation` | `needs_reconciliation` |
| Any `failed` | `failed` |
| Any `undoing` | `undoing` |
| All `committed` | `applied` |
| Not all `rolled_back`, or one keeps its write's error | `failed` |
| One records `recovered` | `rolled_back` |
| Otherwise, all `rolled_back` | `undone` |

An undo writes no error and recovery writes `recovered`, which is how an undo is
told from recovery. An interrupted undo finished by recovery or by the next
`undoTagWrite` records `recovered` too and reads as `rolled_back`.

`can_undo` and `expired` come from `undoAvailability`, the function `undoGroup`
decides by, and read no file. `can_undo` means every operation is `committed`
with every backup path kept, or an interrupted undo is to be finished. `expired`
means every operation is `committed` and a backup was pruned. An undo still
checks every file first, so a write whose file changed since shows `can_undo`
and then returns `error.MutationNeedsReconciliation`.

`TagWriteGroupDetail` reads each operation's backup and its file through the tag
reader and compares their tags. Each differing field is a `TagWriteDiff` row:
`restores` is the backup's value, which an undo puts back, and `current` is the
file's; genres are one row joined with `; `. A file whose backup or current file
cannot be read is one `unknown` row with both values empty. `diffs` holds whole
files only, in action order, at most 512 rows; `more_files` counts the changed
files left out, and `field_count` counts every differing field of every file,
those left out included, so it is 0 once the backups are gone.

`Runtime.exportTagWriteHistory(library, io, path, options)` writes every group's
list line, newest first, through an atomic replace and returns
`TagWriteHistoryExport.groups`. Without `TagWriteHistoryExportOptions.replace`
it refuses an existing file with `error.PathAlreadyExists` and leaves it as it
was. `orca-cli changes` and `orca_library_export_tag_write_history` call it; see
[cli.md](cli.md).

### Relocated roots

A write stays undoable after its root moves. `libraryRelocateRoot` rewrites
every journaled source, destination, stage and backup path below the root's old
path to the same path below the new one, in the transaction that moves the root,
so the journal and the root never disagree. A path matches only below the old
path and a `/`, so relocating `/music` leaves `/music2` alone. Backups in
`<database>.orca-backups` are outside the root and stay.

Only finished operations are rewritten. An operation under the root `planned`,
`staged`, `failed` or `undoing` returns `error.MutationInProgress`, and one
`needs_reconciliation` returns `error.MutationNeedsReconciliation`; either way
nothing changes.

## Writing tags back

`Runtime.planTagWrite` compares each Track file's Orca values with its observed
tags and seals a `MutationPlan` of the values to write. It writes nothing. A
value is written only when it is the one in effect, so a file's own tag is never
replaced by an automatic value:

- A locked value (a user's edit or an accepted correction) is written when it
  differs from the file's tag.
- An unlocked value (such as an accepted match) is written only when the file
  has no tag for its field.
- An unlocked value that differs from the file's tag is a conflict: listed in
  `TagWritePlan.conflicts` with both values and not written, while the file's
  other changes are. Editing the field locks the user's choice, which the next
  write applies.
- A Track's `user` genres replace the file's genres when the two lists differ
  once split and folded, taken from the first selected Track the file backs that
  has `user` genres. The file's current values are the change's `before`, and
  the write refuses to start if the file no longer states exactly them.

`TagWritePlan` lists each file's changes with the provenance of Orca's value
(`user` for an edit, `provider` for a match), its genre change as
`TagWriteFile.genres` (a `TagWriteGenres` with the values before and the user's
genres after, or null), the conflicts, the files left out with the reason, and
the plan's ID and digest. The digest covers the genre change. The C ABI lists a
genre change separately, through `orca_library_query_tag_write_genres`, so a
file whose only change is its genres has a `change_count` of 0 in
`orca_tag_write_file_view`. The skip reasons are:

- `missing`: no present location to write to.
- `format_not_writable`: no writer for the sniffed format. FLAC, MP3 and ADTS
  are written; M4A, Ogg, WAV and AIFF are not, nor is a FLAC stream behind a
  leading ID3v2 tag.
- `changed_since_scan`: the file's identity no longer matches the last scan.
  Rescan first.
- `folder_not_writable`: Orca cannot create files in the file's folder, which
  the staged copy needs. C value `ORCA_TAG_WRITE_SKIP_FOLDER_NOT_WRITABLE` (3).
- `file_read_only`: the file is [read-only](#read-only-files). C value
  `ORCA_TAG_WRITE_SKIP_FILE_READ_ONLY` (4).

The runtime holds at most eight plans awaiting approval. `Runtime.startTagWrite`
approves one by its ID and digest and executes it as a `mutation` Job; a digest
mismatch, or a journal lock held elsewhere (`error.MutationInProgress`), leaves
the plan unwritten and pending. `Runtime.discardTagWrite` drops one. The Job
cannot be cancelled once started, because a journaled group commits or rolls
back as a whole. When it ends, every file in the plan is re-observed and
reprojected.

The plan ID is the journal group. `Runtime.undoTagWrite(group)` restores the
files' previous bytes and re-observes them; for a group already undone it
re-observes them and returns `error.MutationGroupAlreadyUndone`. Orca's values
survive both directions.

A write that fails rolls its group back as recovery does and ends the Job
`failed`. `Runtime.jobTagWriteFailure(job)` returns a `TagWriteFailure` for
every failed write: a `TagWriteFailureReason` and, as `file`, the file it
stopped at and its index in the plan's actions, or null when it failed before
reaching a file. The reasons are:

| Reason | C value | Failed when |
| --- | --- | --- |
| `permission_denied` | 0 | Orca may not create or replace files in the file's folder or the backup directory |
| `read_only_file_system` | 1 | the file or the backup directory is on a read-only file system |
| `no_space` | 2 | the disk had no room for the stage or the backup |
| `changed_since_plan` | 3 | the file's identity, or its format, changed after planning |
| `other` | 4 | any other error, such as a journal write that failed |
| `file_read_only` | 5 | the file is [read-only](#read-only-files) |
| `backup_exists` | 6 | the plan's backup directory was created after planning, by another write; no file |
| `recovery_failed` | 7 | the recovery the write runs first failed, as for a folder that is missing; no file |

A failure with no file leaves every file as it was, and `backup_exists`,
`recovery_failed` and a `changed_since_plan` format change journal nothing for
the plan.
`jobTagWriteFailure` returns null while the Job runs or after success, and
`error.NotATagWriteJob` for another kind of Job. The C ABI's
`orca_job_tag_write_failure` fills an `orca_tag_write_failure`, with `file_id`
and `action_index` 0 when there is no file, and returns
`ORCA_STATUS_NOT_FOUND` for null and `ORCA_STATUS_INVALID_ARGUMENT` for another
kind of Job.

A plan writes one present location of each file. A file held at several paths is
byte-identical copies, so writing one copy splits it off into a file of its own
that carries Orca's values, and the copies left behind keep the shared file
([database.md](database.md#identity)). When a write commits, each value it wrote
is marked with `orca_metadata_values.written_at` on the file its path holds
after the re-observation; changing the value clears the mark. The mark keeps a
recording ID that Orca wrote eligible for AcoustID submission.

### Format rules

Writers keep what they do not understand, and copy the audio bytes unchanged;
only the tag region is rewritten.

- ID3v2 keeps the file's version (2.3 or 2.4), copies unchanged frames verbatim,
  keeps a `n/total` total, and updates an existing ID3v1 trailer. A file with no
  ID3v2 tag gets a 2.4 one.
- A recording ID replaces only the MusicBrainz `UFID` and the `TXXX` frames the
  reader takes one from (`MusicBrainz Track Id`, `MUSICBRAINZ_TRACKID`). The
  release, release-group, release-track and album-artist IDs are `TXXX` frames
  under Picard's descriptions (`MusicBrainz Album Id`, `MusicBrainz Release
  Group Id`, `MusicBrainz Release Track Id`, `MusicBrainz Album Artist Id`),
  each replacing only the `TXXX` frames under that description or its Vorbis
  spelling in any case. Other `UFID` owners and `TXXX` descriptions are kept
  byte for byte. A `TXXX` frame is UTF-16 with a byte-order mark on each string
  in 2.3 and UTF-8 in 2.4.
- Genres replace every `TCON` frame with one: NUL-separated values in 2.4, and
  in 2.3, which has no multi-value text frames, the genres joined with `; `. The
  ID3v1 trailer's genre byte is kept. A name that `TCON` reserves is written as
  given but reads back differently: digits only as that ID3v1 genre (`80` as
  `Folk`, or nothing past the table up to 255), a name in parentheses without
  them (`(Live)` as `Live`), and `RX` and `CR` as `Remix` and `Cover`.
- The composer replaces every `TCOM` frame. The comment replaces every `COMM`
  frame with an empty description, in any language, and every `TXXX` described
  `comment`, with one `COMM` in language `eng`; described `COMM` frames are kept
  byte for byte. The ID3v1 comment is kept.
- Vorbis comments in FLAC match fields by the reader's aliases and canonical
  values, so a write never duplicates a field under another spelling. A write
  replaces every entry under a key, in any case, with one; genres get one entry
  per genre. The release-level IDs are `MUSICBRAINZ_ALBUMID`,
  `MUSICBRAINZ_RELEASEGROUPID`, `MUSICBRAINZ_RELEASETRACKID` and
  `MUSICBRAINZ_ALBUMARTISTID`; the composer is `COMPOSER` and the comment
  `COMMENT`. A `DESCRIPTION` entry is kept, and a comment the reader took from
  it is the write's precondition.
- MP4 has no tag writer, so its genres, composer and comment are not written.
- The FLAC writer preserves unknown comments and metadata blocks.

`orca-cli write-tags`, `undo-tags` and `prune-backups` and the `orca-gtk` Write
Tags to Files and Edit Tags actions drive the plan; see [cli.md](cli.md).
