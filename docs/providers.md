# Providers and listening history

This file covers how liborca talks to online providers, records and delivers
listens, and uses each provider. Every request goes through `network.Gateway`
under the rules below; a request that breaks a rule is a defect, not a tuning
choice. [privacy.md](privacy.md) lists what each service receives, and
[cli.md](cli.md) lists the commands and their output.

Connected services: ListenBrainz, ListenBrainz Labs, MusicBrainz, AcoustID, the
Cover Art Archive, LRCLIB, Wikidata, Wikimedia Commons and Wikipedia.

## Rules toward providers

### Identification

Every request carries exactly one `User-Agent`. The host supplies a name,
version and contact with `Runtime.setClientIdentity` ([Client
identity](api.md#client-identity)); liborca carries no identity and refuses
provider work until one is set. The header reads `Name/version ( contact )`,
followed by `liborca/<version>` unless the host is Orca's own. `orca-cli` and
`orca-gtk` send the contact given at build time (`-Dprovider-contact`). The
three fields must be non-empty, free of control characters and parentheses, and
at most 256 bytes together.

### Rate

Each service's requests are spaced by its own minimum interval, the provider
module's `minimum_interval_ms`, taken from what the service publishes. A Gateway
configured without an interval waits 1000 ms.

| Service | Interval |
| --- | --- |
| MusicBrainz | 1000 ms |
| ListenBrainz, ListenBrainz Labs | 1000 ms |
| AcoustID | 334 ms |
| Wikidata, Wikimedia Commons, Wikipedia | 300 ms |
| Cover Art Archive | 250 ms |
| LRCLIB | 500 ms |

The gateway also honours `X-RateLimit-Remaining` and `X-RateLimit-Reset-In`,
waiting out the window instead of sending into it.

### 429 and 503

A `429`, or a `503` with a `Retry-After`, blocks every request to the service
until the latest of its `Retry-After`, its `X-RateLimit-Reset-In` and a backoff
of 60 s, doubling per repeated refusal up to 1 h; they are not added. One
success resets the backoff. A `503` without `Retry-After` goes back to the
caller as a failure.

`Retry-After` is read as delay-seconds or as an IMF-fixdate HTTP-date and is
honoured however long it is. A value in neither form is ignored, and a past date
adds nothing. `X-RateLimit-Reset-In` counts for at most 1 h.

A refusal or outage on one endpoint delays every endpoint of that service.

### Blocks outlive the process

Each service's block and backoff are kept in the Library (`provider_state`) in
wall-clock time, with the earliest time of its next request (the minimum
interval after the last request, or the end of a quota window). Every Gateway
over that Library reads them before a request, so a restarted or second process
obeys a block, quota window and spacing another received. Libraries do not share
blocks.

### One request at a time per service

A Gateway claims the service's lease in the Library (`provider_leases`) for each
request, stores the next request time before sending, and releases the lease
when the request, one retry attempt or its redirect hops end. A Gateway waits
out its own interval before it claims the lease and the service's stored next
request time while holding it, so Gateways that want one service take turns. A
request whose timeout would outlast the lease extends it first. Another
Gateway, in this or another process, polls every 250 ms until its deadline or
at most 120 s, then fails with `error.ProviderBusy` without sending. A
matching or submission job then fails and names the busy service
(`MatchStats.busy`, `SubmissionOutcome.busy`); the listen worker reports `busy`
and tries again 120 s later. The lease of a crashed process is free once it
runs out, at most 120 s after it was claimed or extended.

### Retries and jitter

By default (`Config.maximum_attempts = 1`) a request is made once and a failure
goes back to the caller. The gateway has a 30 s request deadline and a
cancellation flag checked while it waits.

After an outage (a `5xx` or `408` without `Retry-After`) or a timeout, matching,
AcoustID submission, cover art, lyrics and artist information ask again after a
jittered 5 s, then a jittered 30 s, then report the service unavailable
(`network.retry`). Each wait uses the Gateway's random source and clock, ends
within 100 ms of a cancel, and is not begun if it would end past the job's
deadline. A transient failure is never stored as a result.

Every backoff Orca chooses lasts a random 0.5 to 1.5 times its nominal length,
so processes that failed together do not retry together. A time the server gave
is never shortened.

### Connection reuse

GET requests reuse connections within one job; at most 16 stay idle and all
close when the job ends. A GET that fails on a reused connection before any
response byte arrives is sent once more at once on a new connection, as the same
request: one attempt, no extra pacing slot. POST submissions send `Connection:
close`. A connection that timed out, was canceled, failed or was not read in
full is never reused.

### Batching and permanent refusals

A backlog goes out as `import` requests of up to 100 listens; one listen goes
out as `single`. A listen over 10,240 bytes drops its optional fields, and one
still too large is rejected locally. A `4xx` other than `401`, `403`, `408` and
`429` marks the listen rejected, and a rejected batch is split and sent one
listen at a time, so one bad listen cannot hold back the rest.

### Token validation

The token is validated once, the next time a request could be made after a host
reports it changed (`libraryScrobblerCredentialsChanged`). It is not validated
at every start or before every submission. `orca-cli scrobble` never validates:
with nothing queued it makes no request, and otherwise a bad token shows as a
`401` or `403` on submission, which stops delivery until the token changes.

### Credentials

A user's token or key is read from the host's secure storage through
`CredentialStore` at the moment of a request. It is never written to the Library
database, a log, a cache key or a settings file. `orca-gtk` uses the Secret
Service through libsecret; `orca-cli` reads `ORCA_LISTENBRAINZ_TOKEN` and
`ORCA_ACOUSTID_USER_KEY`.

### Servers

A host points a service at another server with `Runtime.setListenBrainzServer`,
`setListenBrainzLabsServer`, `setMusicBrainzServer`, `setAcoustIdServer`,
`setCoverArtArchiveServer`, `setLrclibServer`, `setWikidataServer`,
`setWikimediaCommonsServer` or `setWikipediaServer`. `http` is accepted only for
`127.0.0.1` and `localhost`, so a token or a Library's contents never cross a
network in clear text.

## Listens

A listen is one heard play of one queue entry. The Player's status is sampled
every 100 ms by `processNextCommand`, and a listen is recorded when the track is
at least 30 s long and has been audible for `min(half its length, 4 min)`. That
is ListenBrainz's rule and the default policy. A Library may keep another
(`librarySetListenPolicy`, `orca-cli listens --policy=`):

| Policy | A listen is recorded once heard for |
| --- | --- |
| `half_or_four_minutes` | ListenBrainz's rule |
| `thirty_seconds` | 30 s, whatever the track's length |
| `full_track` | the whole track, less one second |

The policy decides only what the local history keeps. A listen is sent only when
it also meets ListenBrainz's rule: one that does not is stored with
`listens.syncable = 0` and never queued, and becomes syncable when its finished
time meets the rule. Under `full_track`, a play that meets ListenBrainz's rule
but stops before the end is neither kept nor sent.
`librarySetListenRecording(library, false)` (`--record=off`) keeps no listens
and so sends none; Now Playing announcements still go out while sending is on.
Both settings are stored in the Library.

Audible time counts only frames played at their natural rate: paused time and
positions skipped by a seek do not count. `started_at` is when the entry's first
frame would have played, in Unix seconds. A track repeated in the queue is a new
listen each time it starts. The listened Track is the one the audible entry
serial names in the queue, never the audible cursor's; a sample whose serial
moves while it is resolved is skipped.

The Library's listen worker records the listen off the control lane and the
render callback. When the entry ends, the recorded time is raised to what was
finally heard. An entry ends when the audible entry or Track changes, the
transport stops, or the Player drains (the last entry has decoded to its end and
every Zone has played it out, with the transport still `playing`). Playing the
same entry again after a drain is a new listen.

### Local play history

Listens are always recorded in the `listens` table, whether or not anything is
sent. The table is the play history, kept forever, and survives removing a
folder: the listen keeps its title, artist and album with a null file.
`Runtime.libraryTrackPlayStats` and `TrackDetails` report a Track's play count
and last play. `orca-cli play-tracks` records listens under the Library's policy
and never sends them. The schema is in [database.md](database.md).

`libraryClearListens` (`orca-cli listens --clear`) deletes every listen and
every delivery of one, sent or waiting, and with them every play count, in one
transaction, so `delivered` restarts from 0. Ratings, loves and hates, and
feedback waiting to be sent, stay.

## Delivery

Sending is opt-in per Library: `librarySetScrobbling(library, true, offline,
now_playing)`. At most one Library per runtime scrobbles. A listen recorded
while sending is off is never queued later, so turning it on does not upload
history. Love and hate given while it was off are sent, because they are the
user's current opinion rather than an event.

An eligible listen is stored with a `scrobble_queue` row in one transaction. The
worker leases rows (`lease_owner`, `lease_expires_at`), sends them, and marks
them delivered, rejected or, on a transient failure, pending again with a later
attempt time. A transient failure is a `429`, a `5xx`, a timeout or a network
error: each unsent listen gets the end of the block or backoff as its
`next_attempt_at`, and the backoff also blocks the service in `provider_state`.
Listens of a request that was never sent (offline, canceled, service busy) or
whose token was refused go back to pending as they were. A lease that outlives a
crashed worker expires and is reclaimed, and a result from a worker that lost
its lease is discarded. Queue states are pending, leased, delivered and
rejected.

`libraryScrobblerStatus` reports one of:

- `disabled`: scrobbling is off. A Library with no running worker reports its
  queue counts and block from the database, at most once a second.
- `idle`: nothing to send, or between requests.
- `needs_token`: listens are waiting and the store has no token.
- `validating`: the token is being checked.
- `invalid_token`: the service refused the token; delivery resumes when it
  changes.
- `submitting`: a request is in flight.
- `rate_limited`: the service asked Orca to slow down.
- `backing_off`: the last request failed and the next attempt is scheduled.
- `offline`: offline mode; listens stay queued.
- `busy`: another Orca process holds the service's lease.

The status also carries the user name of the last validated token, the pending
listens, the love and hate changes waiting (`feedback_pending`), the total
delivered, the next attempt time, the end of the service's block
(`blocked_until`, Unix seconds) and the last error.

Each pass of the worker sends, in this order, at most one request of each kind
and only while no request is held back: listens, then Now Playing, then one
feedback change. One backoff, one `429` block and one refused token serve all
three.

## Love and hate

A song can be loved or hated (`librarySetFeedback`) and the mark cleared.
Feedback is kept in the Library whether or not anything is sent, appears in
`TrackSummary.feedback` and `TrackDetails.feedback`, and belongs to the song's
Recording, not to a file or Track, so a FLAC and an MP3 of one song share it and
a reprojection that gives a Track a new id keeps it. It is independent of the
star rating ([cli.md](cli.md#ratings)).

While the Library scrobbles, feedback is sent to ListenBrainz (`POST
/1/feedback/recording-feedback`, score `1` love, `-1` hate, `0` cleared):

- Only under a MusicBrainz recording ID. Feedback on a Recording none of whose
  files carries one is kept and never sent; `TrackDetails.feedback_syncable`
  says whether an ID is known, and such feedback is not in `feedback_pending`.
- One request per change, one change per pass; nothing is batched because the
  endpoint takes one recording.
- Only the final state, once it has stood for 2 s. Love, hate and love again in
  quick succession sends the last opinion, and nothing when that matches what
  the service already has. A change made while a request is in flight stays
  pending. Clearing feedback that was never sent sends nothing.
- Clearing sent feedback sends score `0` once, and the row is then forgotten.
  Clearing a change the service rejected forgets it locally with no request.
- A change the service accepted is not sent again. If Orca cannot record the
  acceptance, only the local mark is retried, after 60 s and doubling up to an
  hour, without another request.
- `429`, `5xx` and network errors use the service backoff; `401` and `403` stop
  all delivery until the token changes; any other `4xx` except `408` marks the
  change rejected, and it is not sent again until the user changes that song's
  feedback.
- Orca never reads feedback from the service, so feedback given elsewhere does
  not appear in Orca.

## Now Playing

`librarySetScrobbling(..., now_playing = true)` also announces the playing track
with `listen_type: "playing_now"`, one listen and no `listened_at`, built from
the same fields as a listen. It is off by default.

- At most one request per track actually listened to: once the entry has been
  heard for 10 s, only when the track is 30 s or longer, and never for an entry
  that was skipped first, drained, or that reached the listen threshold on the
  same sample. Pausing and seeking do not advance the 10 s.
- Never retried and never queued. Only the newest update is held, in memory, and
  it is dropped when a request cannot go out (offline, no token, refused token,
  rate limit, backoff), when it is 60 s old or older at send time, and after any
  failure of its own request. A `429` still blocks the service and a `5xx` or
  network error counts toward the shared backoff.
- Never ahead of listens.

## Matching

`Runtime.startLibraryMatching` asks MusicBrainz, and AcoustID by fingerprint,
about files without a MusicBrainz recording ID and stores what they find as
proposals. Nothing takes effect until a person accepts one; acceptance is
described in [metadata.md](metadata.md#accepting-a-match).

### What is searched

Every Track whose playing file has no recording ID in effect, in Track id order,
by each service that has not yet answered for that file. An answer, empty ones
included, is recorded per file and service in `identification_searches`, so no
service is asked about a file twice. A failed or refused search records nothing
and is repeated on the next run. One Track is one search however many files back
it. `MatchRequest.limit` bounds the Tracks one run examines and
`MatchRequest.track_id` limits it to one Track.

### Proposals and confidence

Candidates from both services are merged by recording ID into one proposal that
names its sources: `musicbrainz`, `acoustid` or `musicbrainz+acoustid`. A file's
existing proposal for that recording is updated in place and keeps its state, so
a dismissed or accepted proposal is never offered again.

Orca scores each service's candidate from 0 to 1 against the Track's title,
artist, album and length; AcoustID's own score is the fingerprint evidence in
that score. The proposal's confidence is `1 − (1 − c_musicbrainz)(1 −
c_acoustid)` over the services that found it, so two services agreeing rank
above either alone. Candidates below 0.5 are dropped.

### Failures

A rate limit waits out the longer of the service's block and a backoff of 60 s
doubling per attempt, cancellably, then asks again. An outage or timeout is
asked again after about 5 s, then about 30 s. After three attempts of either
kind, or at once when the network cannot be reached or another process holds the
service, the job stops `failed`. Cached answers are still used without a
network. A query answered with something that is not a search result is counted
and skipped.

A query a service refuses with a `4xx` other than `401`, `403`, `408` and `429`
is counted as refused and skipped, and the refusal is cached in `provider_cache`
with its status for 7 days; until then the query counts as refused without a
request. When AcoustID refuses a batch of fingerprints, nothing is cached and
each fingerprint is asked again alone through the same gateway; only a single
fingerprint's refusal is cached. A refused key (AcoustID error codes 4 and 6) is
not cached, and a cached refusal never stands in for an answer while the service
is down.

### Scope and concurrency

`MatchRequest.release_id` limits a run to one Release's Tracks. With it,
`accept_minimum_confidence` accepts the Release's matches as
`libraryAcceptConfidentMatches` would, and `cover_art` fetches the Release's
cover ([Cover Art Archive](#cover-art-archive)); the files given values are
reprojected once. `orca-gtk`'s Match Album runs all three with the review
threshold from Settings.

A search that stores proposals has not necessarily left anything to review on
the Matches page: a recording whose answer lists no release forms no release
candidate, and its Release stays `unmatched`. `MatchStats.releases_to_review`
counts the Releases a run's matches left in `confident` or `needs_review`, and
`libraryReleaseMatchBucket` gives one Release's bucket. `orca-gtk` names the
album and its tab after a search of one album or Track ("Big Grams is ready to
review in Needs Review", with a Review button that opens it), says "No album
match found" otherwise, and gives Find Matches' count of albums ready to
review.

A second `startLibraryMatching` while one runs returns
`error.MatchingAlreadyRunning`, and one during an AcoustID submission returns
`error.AcoustIdBusy`, so each service sees one client and one backoff.
Cancellation is checked between Tracks and fingerprints, while waiting for the
next request slot and while backing off.

### Re-identify

`MatchRequest.mode = .reidentify` searches one Track (`track_id`) or one
Release's Tracks (`release_id`) again: every one with a playing file, whatever
recording ID is in effect and whatever services answered before. Without either,
or with `accept_minimum_confidence`, it returns `error.InvalidMatchRequest`, so
no correction is accepted in bulk. A candidate for the recording ID already in
effect is not proposed and counts as `confirmed` in `jobMatchStats`, once per
Track; any other candidate is stored as a proposal, and a dismissed proposal
stays dismissed. With `release_id`, the proposals are pointed at one release as
[Match Album](#match-album) does. The MusicBrainz query is built from the
Track's current tags, not its recording ID, so for a mistagged file the AcoustID
fingerprint lookup carries the signal.

### Statistics and proposals

`jobMatchStats` reports the Tracks examined and matched, MusicBrainz requests
and cache hits, fingerprints taken, read from the cache or failed, AcoustID
requests, cache hits and refused queries, and `acoustid`: `searched`, `off`,
`no_client_key` or `invalid_client_key`.

`libraryMatchProposals` lists a Track's pending proposals, most confident first,
with source, AcoustID score and, for a correction, the recording ID it replaces.
`libraryAcceptMatch` and `libraryDismissMatch` act on one and return
`error.ProposalInGroup` for a proposal in an album group.
`libraryAcceptConfidentMatches(minimum)` accepts each file's best pending
proposal at or above `minimum`, chosen as
[metadata.md](metadata.md#bulk-acceptance) describes; it is an explicit user
action, never run by a job.

### MusicBrainz search

`GET /ws/2/recording?fmt=json&limit=10&query=` with `recording:"TITLE" AND
artist:"ARTIST" release:"ALBUM"`. The release term is optional, so it raises
matching releases without excluding the others. Lucene syntax characters in the
values are escaped with a backslash. A Track without a title or an artist is
counted and not searched.

Kept: the recording ID, title, full artist credit, the release whose title is
closest to the album with its ID and track number, the IDs of up to 25 releases
the recording is listed on with each one's status, date and track count, the
length, and MusicBrainz's score from 0 to 100.

Answers, empty ones included, are cached in `provider_cache` for 30 days of wall
time, keyed by the request URL. When a request fails and an expired answer is
cached, that answer is used.

### MusicBrainz release lookup

`GET /ws/2/release/{id}?fmt=json&inc=recordings+artist-credits+release-groups`,
through the same gateway, cache, counters and refusal rules as the search. The
ID is checked to be a lowercase UUID first.

Before a file's search is recorded, the release of its most confident
MusicBrainz proposal is looked up, once per run, and every proposal naming that
release or no release (found only by AcoustID) whose recording it holds is
filled in. A failure that would stop a search stops the job the same way before
that file is recorded, so it is searched again from the cache. A refused or
missing release (`404`), an answer that is not a release, or a release without
the recording leaves the proposals as found.

Kept per proposal: the track holding the recording (at the file's tagged track
number when the recording appears more than once, else the first) with its
title, artist credit, ID, position and medium position, which become the track
and disc numbers (a vinyl number such as `A1` is not used), and the release's
title, artist credit, date and release-group ID, with the album-artist ID only
when the credit names one artist. A proposal found again on another release
loses these values.

Every successful lookup also replaces the release's tracklist snapshot in
`musicbrainz_releases` and `musicbrainz_release_tracks` in one transaction: its
title, artist credit, date, release-group ID, medium count and every track with
its disc, position, title, artist credit, length, recording ID and track ID. A
track whose position is missing takes its index; one with an invalid ID, or at a
disc and position already taken, is left out. A release of more than 512 media
or 512 tracks is not snapshotted. `fetched_at` is when the lookup ran, even when
the answer came from the cache.

### Match Album

After its search pass, which may search nothing, each file of the Release votes
once for every release its non-dismissed stored proposals list. The release with
most votes wins; ties go to the Release's tagged release ID, then an `Official`
release, then one with as many tracks as the Release has Tracks, then the
earliest date (none last), then the lowest ID. Status, track count and date are
what the search said about each release, first seen per release; a release a
stored payload says none of them about ranks as unofficial, of another length
and undated.

The winner is looked up once, and every stored proposal whose recording it
holds, whether or not it lists the release, is pointed at it and filled in
(`updatePayload`). Then the Release's best candidate, as Match Review ranks it
before any acceptance, is looked up unless its snapshot is younger than the
30-day cache: at most one more request per run, none when it is the winner or
the cache holds it. A rerun after a failure completes from the cache.

### AcoustID lookup

The first 120 s of the playing file are decoded by Orca, resampled to 11,025 Hz
and fingerprinted by Chromaprint
([analysis.md](analysis.md#acoustid-fingerprints)). A file that does not decode
cleanly has no fingerprint, is counted in `fingerprint_failures`, and its Track
is still searched on MusicBrainz.

`POST /v2/lookup`, a gzip-compressed form (`Content-Encoding: gzip`) with
`client`, `clientversion`, `format=json`, `meta=recordings releasegroups
compress`, `batch=1` and `duration.N` and `fingerprint.N` for up to 20
fingerprints. `duration` is the whole file's length in whole seconds, rounded.
Answers come back per index.

Kept: each recording with an ID once per fingerprint under its best score: the
ID, the title (empty when AcoustID has none), the artists joined by their join
phrases, the release group title closest to the Track's album, the length and
AcoustID's score. With `compress`, an artist or release group named in full once
may appear by ID alone elsewhere, so names are resolved across the whole answer.

Each fingerprint's answer is cached in `provider_cache` for 90 days, keyed by
the duration and a BLAKE3 hash of the fingerprint; fingerprints already answered
are left out of the request.

AcoustID identifies the application by a client key. `orca-cli` and `orca-gtk`
set it with `Runtime.setAcoustIdClientKey` from the build option
`-Dacoustid-key=`; liborca has no key of its own. A `CredentialStore` value
under `org.acoustid` / `client-key` overrides it. Without a key AcoustID is
skipped and reported `no_client_key`; a key AcoustID refuses (error code 4)
stops AcoustID for the rest of the job and is reported `invalid_client_key`.

## Verification

A recording ID in effect can be wrong: a file tagged as another track of its
album, a tag copied from the wrong edition. `MatchRequest.mode = .verify` checks
each file that has one against what AcoustID hears in its fingerprint and
proposes a correction where AcoustID hears another recording. MusicBrainz is
asked only for the Release a correction names.

Without an application key, or with `fingerprints = false`,
`startLibraryMatching` returns `error.AcoustIdRequired` and no job starts;
`accept_minimum_confidence` and `cover_art` return `error.InvalidMatchRequest`.
A key AcoustID refuses mid-run stops the job `failed` with `acoustid =
invalid_client_key`, and a credential store holding no key stops it with
`no_client_key`.

### Outcomes

A file `agrees` when AcoustID lists its recording ID in effect at a score of at
least 0.5 (`verify_agree_minimum`). It `disagrees` when AcoustID does not and
lists another recording at 0.9 or more (`verify_disagree_minimum`); it is
`unconfirmed` otherwise, an empty answer included. A file that does not decode,
or changes while it is fingerprinted, is `no_fingerprint`. Each outcome is
stored in `recording_verifications` with the file's quick hash, the recording ID
in effect and up to eight recordings AcoustID heard, strongest first.

A file with no present location or no file there, and a fingerprint AcoustID
refused or left unanswered (`acoustid_refused`), get no outcome and are tried
again on the next run. A file with no quick hash is counted in `skipped` and
never verified.

### What is verified

A file whose stored outcome is missing or stale. An outcome is stale once the
file's quick hash or its recording ID in effect changes. A file whose fresh
outcome is `disagrees` is verified again only beside a stale or unverified file
of its Release, so the album group can form again with every file it disputes,
or when `track_id` asks for it alone. When only the recording ID changed and the
new one is among the recordings heard at 0.5 or more, the file agrees again
without a lookup. `total_units` counts by the same rule.

The library is verified one Release at a time, in Release id order, then Tracks
with no Release a page at a time; `release_id` and `track_id` limit it to one. A
unit's files are fingerprinted, looked up 20 at a time, and committed in one
transaction with their proposals; a cancelled unit commits nothing. `limit`
bounds the Tracks examined. The cost is about one AcoustID request per Release
with a file to verify and one MusicBrainz request per Release with a correction,
from the caches when they can.

### Corrections

A file that disagrees is proposed each recording heard at 0.9 or more, scored as
a search candidate against the Track's artist, album and length but not its
title, which may be the wrong recording's. A file whose recording ID is the
user's own locked edit is verified and never proposed a correction. Accepting
one is described in [metadata.md](metadata.md#corrections).

When the Release has a MusicBrainz release ID and at most 512 Tracks, it is
looked up once as in [MusicBrainz release lookup](#musicbrainz-release-lookup).
Each disputing file whose strongest recording heard is on that release has that
proposal filled in from it, positions included, and those proposals form one
album group (`identification_proposals.album_group`), accepted or dismissed only
whole with `libraryAcceptCorrectionGroup` and `libraryDismissCorrectionGroup`.
The other disputing files get corrections of their own, with AcoustID's title
and artist and no position. A lookup that fails stops the job as a search's
would; a release MusicBrainz does not have leaves every correction ungrouped.

### Idle maintenance

`libraryMaintenance` verifies the library one Release per unit while nothing
plays and no other job runs, one unit every `interval_ms` (default 5 minutes).
Once no Release is left, a unit takes at most 20 Tracks with no Release. A unit
is a verify job with the same Gateway, rate limit and leases. Before starting
one, the runtime reads `provider_state`: while AcoustID or MusicBrainz has a
block recorded it starts nothing and reports `provider_busy`. A matching,
cover-fetch or submission job the host starts while a unit runs cancels the unit
and starts once the unit's worker has released its leases and been joined. See
[control-plane.md](control-plane.md#idle-maintenance).

`jobMatchStats` also reports `verified`, `agreed`, `disagreed`, `unconfirmed`,
`skipped`, `correction_groups` and `proposals_stored`.
`libraryTrackVerification` returns a Track's stored outcome, whether it is
stale, and whether the strongest recording heard has a dismissed proposal.
`libraryCorrectionGroups` lists the album groups with a pending proposal;
`libraryMatchReviewPage` leaves their proposals out.

## AcoustID submission

`Runtime.startAcoustIdSubmission` sends AcoustID the fingerprints of files whose
recording ID Orca chose, so other people's copies of the recording can be
identified. liborca never starts it by itself; a frontend starts it on a
person's request or, with consent, on its own (`orca-gtk`'s Contribute to
AcoustID).

### What is sent

Files whose recording ID in effect is an Orca value from an accepted match or an
edit, differs from the file's own tag or was written into it by Orca, and has
not been sent for that file. IDs Orca did not choose are never sent. A file is
sent once per recording ID: an edited ID is sent again. Excluded:

- an ID from a match whose sources include AcoustID, which already knows it;
- an ID from a match accepted by `libraryAcceptConfidentMatches`, which rests on
  text alone. A match accepted one at a time from MusicBrainz alone is sent, and
  so is an ID the user edited, whatever proposed it;
- an ID from a match, on any file but the one the match was accepted on: a copy
  split off a shared file inherits the ID without the match;
- an ID a release-track pairing set
  ([metadata.md](metadata.md#pairing-a-track)), unless the file also holds an
  AcoustID proposal for that recording in any state, so it is sent only where
  the file's fingerprint agreed. An ID the person then edits, even to the same
  value, counts as an edit.

`libraryAcoustIdSubmittableCount` and `libraryAcoustIdSubmittablePage` list the
files without fingerprinting anything. A file that does not decode cleanly is
counted in `fingerprint_failures` and not sent.

When the file's length differs from the recording's by more than 30 s, the
title, artist, album, album artist, track and disc number and year are sent
instead of the ID. The recording's length comes from the accepted match; without
one, the ID is sent.

### The request

`POST /v2/submit`, a gzip-compressed form with `client`, `clientversion`,
`user`, `format=json` and, per item N, `duration.N`, `fingerprint.N`,
`fileformat.N`, `bitrate.N` (the file's average) and either `mbid.N` or the
metadata fields. A batch holds at most 50 items and 900 KiB of form, below the
service's 1 MiB limit; an item that would pass either bound starts the next
batch. Each accepted item's submission ID is stored in `acoustid_submissions`
with the file and recording ID.

### User key and failures

The user's key is read from the `CredentialStore` under `org.acoustid` /
`user-key` before each request and never kept. Without one the job fails with
`needs_user_key` before fingerprinting anything; a key AcoustID refuses (`401`,
`403`, or error code 6) fails it with `invalid_user_key`. Nothing is marked sent
in either case. Another `4xx` rejects that batch: its files are counted in
`rejected` and stay unsent. Rate limits, outages and timeouts are retried as in
matching, and after three attempts the job fails with `unavailable`. While
another process holds AcoustID it fails with `busy`.

`jobSubmissionStats` reports the files examined, submitted and sent as metadata,
fingerprints taken, read from the cache or failed, files rejected, requests made
and the `outcome`.

## Cover Art Archive

`Runtime.startReleaseCoverArtFetch(library, release_id)`, and a matching job
with `MatchRequest.cover_art`, fetch a Release's front cover from the Cover Art
Archive into the Library. Nothing is fetched for a Release whose front cover a
person chose, one of whose files carries a readable cover, or whose folder holds
a readable front image, and media files are never written. The cover is stored
in `release_artwork` ([database.md](database.md#release-artwork)) and served by
`libraryReleaseArtwork`, `libraryTrackArtwork` and the artwork loader when no
file of the Release has one and none was chosen: a chosen cover wins, then an
embedded one.

The Release's tagged MusicBrainz release ID is used; without one, the release ID
most of its accepted matches name, a tie going to the lowest. Without either
nothing is fetched and the outcome is `no_release_id`. The ID is checked to be a
lowercase UUID before a URL is built from it.

`GET /release/{mbid}/front-500` goes through the gateway as the service
`coverartarchive`, with its interval, shared backoff, identity and lease.

- Redirects. The archive redirects to `archive.org`, which redirects again to
  the node holding the file. `Gateway.fetch` follows at most two redirects, each
  to `https` on `archive.org` or a host ending in `.archive.org`, sending only
  the user agent. A redirect anywhere else, plain `http` included, is refused
  and nothing is stored. Against a server set with `setCoverArtArchiveServer` on
  a loopback host, a redirect back to that same server is also followed, so a
  local mock can redirect to itself.
- The image is at most 4 MiB and only a JPEG or PNG by its bytes; anything else
  is refused and nothing is stored.
- A `404` is stored as a row without an image and the release ID is not asked
  about again for 30 days of wall time; a fetched cover is not asked for again
  while its release ID stays the same.

`jobMatchStats(job).cover_art` reports the `CoverArtOutcome`: `chosen`,
`embedded`, `folder`, `fetched`, `cached`, `cached_miss`, `not_found`,
`no_release_id`, or, failing the job, `refused`, `unavailable` or `busy`.

### Cover candidates

`Runtime.startCoverArtCandidates(library, release_id)` lists the images the
archive holds for a Release so a person can pick one. It runs only when a person
asks, never from a scan, match or maintenance pass, and makes at most 18
requests through the gateway as `coverartarchive`:

1. `GET /release/{mbid}/`, the release's index, when the Release has a release
   ID chosen as for the front cover.
2. `GET /release-group/{rgid}/`, the release group's index, only when the
   Release's files carry exactly one MusicBrainz release group ID. Only its
   front images are kept, as `release_group` candidates.
3. For each of at most 8 candidates (`max_cover_art_candidates`; fronts first,
   then release group fronts, backs, booklets and the rest, each in the
   archive's ID order, an image listed by both indexes kept once): `GET
   /release/{mbid}/{id}`, the full image, whose header is measured for its size
   and whose bytes are then discarded, and `GET /release/{mbid}/{id}-250`, the
   thumbnail, which is kept.

An index is at most 1 MiB and lists at most 64 images; an image is at most 12
MiB and only a JPEG or PNG by its bytes. A full image that is refused, missing,
too large or unreadable leaves its candidate without a size
(`MatchStats.cover_art_candidates_unmeasured`); a missing thumbnail leaves it
without one. An image that fails transiently (outage, timeout, rate limit, busy
service or no network) ends the listing: the candidates measured before it are
stored and the outcome is `partial`; with none measured the stored list is kept
and the Job fails `unavailable` or `busy`. When the release's index was read but
the release group's would not come, the release's own candidates are stored and
the outcome is `partial`. The list replaces the Release's last one in
`cover_art_candidates` ([database.md](database.md#release-artwork)); progress
counts candidates.

`Runtime.libraryUseCoverArtCandidate(library, release_id, caa_id, kind)` fetches
the candidate's full image again, one request, and stores it as the Release's
chosen front, back or booklet. A candidate the Release no longer lists is
`error.UnknownCoverArtCandidate`; an image the archive no longer holds fails the
Job as `not_found` and stores nothing.

[Artist info](#artist-info) also fetches release group covers, `GET
/release-group/{mbid}/front-250`, under the same service, redirect and image
rules, into `release_group_covers` ([database.md](database.md#artist-info)).

## LRCLIB

`Runtime.startTrackLyrics(library, track_id, .{ .fetch = true })` asks
[LRCLIB](https://lrclib.net) for a Track's lyrics when the Track has no synced
lyrics of its own. The answer is kept in `track_lyrics`
([database.md](database.md#track-lyrics)); media files are never written and no
`.lrc` file is created. How LRCLIB's lyrics rank against the Track's own is in
[metadata.md](metadata.md#lyrics).

Nothing is sent without `fetch`, which also needs `setClientIdentity`
(`error.ClientIdentityRequired`). A job without `fetch` still uses an answer the
Library keeps. A frontend leaves fetching off until the person turns it on.

`GET /api/get` with `track_name`, `artist_name`, `album_name` and `duration`:
the Track's effective title, artist and album and its length in whole seconds,
percent-encoded. An empty album is left out, and so is a duration that is
unknown or longer than an hour. No MusicBrainz ID, path, file name, token or
other Library content is sent. A Track without a title or an artist is not
looked up (`no_metadata`). The request goes through the gateway as the service
`lrclib`; a lookup inside a block sends nothing and reports `unavailable`.

The answer is at most 512 KiB of JSON. A record's `syncedLyrics` and
`plainLyrics` are parsed as LRC; `instrumental: true` is kept as an instrumental
with no lines. A `404`, or a record with neither text that is not instrumental,
is a miss. `408`, `5xx` and timeouts are asked again after about 5 s, then about
30 s, within the 60 s deadline, then are `unavailable`; a rate limit is
`unavailable` at once. Any other status, a redirect, or a body that is not a
record is `refused`. Nothing is stored for a failure.

Each answer is stored with a BLAKE3 digest of the title, artist, album and
duration it was asked with. While the digest matches, lyrics and instrumentals
are reused for ever and a miss for 7 days of wall time. A change to any of the
four values changes the digest, and the next fetch asks again.

LRCLIB grants use of its API and asks for no key. It does not license the
lyrics: rights to the words stay with their owners, and an application that
shows or stores them answers for that use.

`jobLyricsOutcome(job)` reports the `LyricsOutcome`: `fetched`, `cached`,
`cached_miss`, `not_found`, `no_metadata`, `refused`, `unavailable`, `busy` or
`cancelled`, and `local` only when the Track's own synced lyrics made a lookup
needless. These outcomes do not fail the job. With `fetch` the outcome is what
the lookup came to, also when the Track's own plain lyrics are returned.

## Artist info

`Runtime.startArtistInfoFetch(library, artist_id, options)` gathers an Artist's
photo, biography, years active and links into `artist_info`, `artist_links`,
`artist_related` and `related_artist_photos`
([database.md](database.md#artist-info)). Media files are never written.
`libraryArtistInfo`, `libraryArtistPhoto` and `libraryArtistLinks` read what was
kept.

Nothing is fetched until a host starts the job, which needs `setClientIdentity`
(`error.ClientIdentityRequired`). `options.offline` makes no request: the job
uses the local image and answers already in `provider_cache` and reports
`offline`.

### Steps

Each service is asked as its own gateway service (`musicbrainz`, `wikidata`,
`wikimedia-commons`, `wikipedia`, `listenbrainz`, `listenbrainz-labs`,
`coverartarchive`).

1. A local image. The Artist's folder is the folder above each of its release
   folders, or the deepest folder common to them, when it lies inside the files'
   roots and holds no other Artist's files. The first of `artist.jpg`,
   `artist.png`, `folder.jpg`, `thumb.jpg` and `fanart.jpg` there that is an
   image by its bytes and at most 8 MiB is the photo; Commons is not asked for
   one unless `force` is set.
2. MusicBrainz: `GET /ws/2/artist/{mbid}?inc=url-rels+genres+artist-rels` gives
   the type, life span, Wikidata item, links and an `image` relation, used only
   when it names a `commons.wikimedia.org/wiki/File:` page. An Artist without an
   ID gets the local image only (`no_musicbrainz_id`) and nothing is sent. The
   Artist's origin is its begin area, else its area, named with the subdivision
   it lies in (`Portland, Oregon`); unless the area is itself a subdivision or
   country, at most 3 `GET /ws/2/area/{id}?inc=area-rels` lookups follow its
   backward `part of` relations upward, preferring a subdivision to a country,
   and the area's own name stands when none is found.
3. Wikidata: `wbgetentities` for the item's image (P18, which outranks
   MusicBrainz's image relation), work period (P2031 start, P2032 end) and its
   Wikipedia sitelink in `options.language`, else English.
4. Wikimedia Commons: `prop=imageinfo` for the file's licence
   (`LicenseShortName`, `LicenseUrl`), author (`Artist`, kept as plain text of
   at most 1 KiB) and an 800-pixel rendering, then the rendering: at most 4 MiB,
   only a JPEG, PNG or WebP by its bytes, and only over `https` on
   `wikimedia.org` or a host under it, or on the loopback server set with
   `setWikimediaCommonsServer`.
5. Wikipedia: `GET /api/rest_v1/page/summary/{title}` on
   `https://{language}.wikipedia.org` gives the article's lead as plain text, at
   most 16 KiB, and its page. A disambiguation page is no biography.
6. Release groups: `GET
   /ws/2/release-group?artist={mbid}&inc=artist-credits&limit=100&fmt=json`, one
   request, replaces the Artist's `artist_release_groups`, at most
   `max_release_groups` (200). A failed browse keeps the stored groups, unless
   the Artist's MusicBrainz ID changed, which clears them.
7. Genres. Unless genre fill is off, the artist's MusicBrainz genres go on the
   Artist's Tracks that have none ([Genres from
   MusicBrainz](#genres-from-musicbrainz)).
8. ListenBrainz: `POST /1/popularity/artist` with `{"artist_mbids":[mbid]}`
   needs no token and gives `total_user_count`, kept as the Artist's listeners.
   `GET /similar-artists/json?artist_mbids={mbid}&algorithm=…` on
   `https://labs.api.listenbrainz.org` gives the 12 highest-scored related
   artists other than the Artist. Both run at most once in 7 days per Artist
   unless `force` is set; the Labs answer is cached for 7 days.
9. Related artist photos. For each of the first 8 related artists with no
   library Artist and no photo or no-photo marker kept less than 30 days ago
   (with `force`, the first 8 whatever the age), the photo is found as for the
   Artist: MusicBrainz, Wikidata's P18, then Commons. It is kept in
   `related_artist_photos` by MusicBrainz artist ID with its attribution
   (`photo_source`, `photo_url`, `photo_licence`, `photo_licence_url`,
   `photo_credit`; `libraryRelatedArtistPhotoInfo`). A related artist with no
   image, or a refusal, keeps a marker for 30 days; an unavailable, busy or
   offline step keeps nothing. One artist's failure neither stops the others nor
   changes the outcome.
10. Release group covers. For each album and EP `libraryArtistElsewhere` lists
    (newest first, at most 200), `GET /release-group/{mbid}/front-250` on the
    Cover Art Archive under its [redirect and image rules](#cover-art-archive).
    A cover is kept in `release_group_covers` by group ID and not asked for
    again, `force` included; a `404` or refusal keeps a row without an image,
    asked again after 30 days, and an unanswered group keeps nothing.
    `options.offline` skips the step, which never changes the outcome. A cover
    is deleted when no Artist's release groups name its group.
11. Releases. With `options.include_releases`, each of up to 64 of the Artist's
    Releases with a MusicBrainz release ID gets its [release
    info](#release-info). The first Release that ends unavailable, busy or
    offline ends the fetch with that outcome; fetched Releases stay stored and a
    later fetch asks for the rest. A refused Release is recorded and the next
    one is asked.

### Years active

For a `Group`, `Orchestra` or `Choir`, MusicBrainz's life span is formation to
dissolution and is used as it is. For any other type the life span is a
lifetime, so its begin is never used: the years start at Wikidata's P2031, else
at the earliest release date among the Artist's Releases in the Library, and end
at P2032. Such an Artist is `ended` when P2032 is set or MusicBrainz says it
ended, with no end year unless P2032 gives one.

### Rules

Only MusicBrainz artist, area and release IDs, release group, Wikidata item and
Commons file IDs and the article title the services themselves returned, and the
language, are sent. No path, file name, tag or other Library content leaves the
machine.

Each service goes through its own gateway: the client identity's `User-Agent`,
its interval, the shared backoff and block, and the service lease. Answers are
kept in `provider_cache` for 30 days and a refusal for 7; when a service cannot
be reached an expired answer is used.

Info fetched less than 30 days of wall time ago for the same MusicBrainz artist
ID and requested language is kept and nothing is asked (`cached`). `force` asks
again but still answers from `provider_cache` while those answers are fresh.

A Commons photo is shown with its licence, a link to it and its author's credit,
as Commons requires; the photo's Commons page is kept as `photo_url`. A
Wikipedia biography is CC BY-SA 4.0 and is shown with that licence and a link to
the article. Wikidata is CC0. MusicBrainz's data is CC0 except its genres.
ListenBrainz's listener counts and related artists are shown as from
ListenBrainz. A local image carries no licence or credit.

### Failures, deadline and outcomes

The Artist's own lookups are asked again after an outage or timeout as in
[Retries and jitter](#retries-and-jitter); related-artist photos and release
group covers are asked once per fetch, so one cannot spend the deadline. A step
that fails leaves what an earlier fetch stored for it and the rest still run.
The outcome is the first failure: `refused` (a `4xx`, a redirect off the service
or a body Orca does not accept), `unavailable` (`408`, `5xx`, a network failure
or a block) or `busy` (another Gateway still holds a service's lease at the
deadline). A cancelled job keeps nothing and reports `cancelled`. None of these
fail the job.

A fetch without `include_releases`, a Release's info fetch and a lyrics fetch
end within `fetch_deadline_ms` (60 s): each request's timeout is cut to the time
left, and a held service is waited for until then. The Artist's info is stored
first, then listeners and related artists, then their photos, then release group
covers; `jobArtistInfoStores(job)` counts each store as it happens.

`jobArtistInfoOutcome(job)` reports the `ArtistInfoOutcome`: `fetched`,
`cached`, `no_musicbrainz_id`, `offline`, `not_found`, `refused`, `unavailable`,
`busy` or `cancelled`. The outcome is also stored with the info.

## Release info

`Runtime.startReleaseInfoFetch(library, release_id, options)` starts a
`release_info` Job that keeps a Release's description in `release_info`
([database.md](database.md#artist-info)). `libraryReleaseInfo` reads it and
`jobReleaseInfoOutcome` reports an `ArtistInfoOutcome`. It needs
`setClientIdentity`, and `error.UnknownRelease` names a Release that does not
exist. Media files are never written.

1. MusicBrainz. `GET /ws/2/release/{mbid}` gives the release group, then `GET
   /ws/2/release-group/{id}?inc=url-rels+genres` its Wikidata item, Wikipedia
   link and genres. A Release without an ID asks nothing (`no_musicbrainz_id`).
2. Genres. Unless genre fill is off, the release group's genres go on the
   Release's Tracks ([Genres from MusicBrainz](#genres-from-musicbrainz)).
3. Wikidata. The item's Wikipedia sitelink in `options.language`, else English;
   a group without an item uses its Wikipedia link.
4. Wikipedia. The article's REST summary, as for an Artist's biography: the
   description, its page, its language and the CC BY-SA 4.0 licence.

The gateways, caches, reuse and failure rules are those of artist info: info
fetched less than 30 days ago for the same release ID and language is `cached`,
`offline` sends nothing, and the outcome is the first failure while the other
steps still run.

## Genres from MusicBrainz

MusicBrainz's genres are user-voted and CC BY-NC-SA 3.0, not CC0, so genres
filled from them are shown with "Genres from MusicBrainz, CC BY-NC-SA 3.0"
(`musicbrainz_genre_licence`).

The three most voted genres, with any tied with the third, at most five, are
written as provider genres (`provenance=provider`). A Release's genres go on its
Tracks that have no genres from a file or a user's edit, replacing earlier
provider genres; an Artist's go only on its Tracks that have no genres at all. A
file's or a user's genres are never replaced and replace provider genres when
they appear.

Artist info and release info fill genres unless the Library's setting is off:
`setGenreFill(library, .{ .musicbrainz = false })` turns it off and
`libraryGenreFill` reads it, kept in `library_settings`.
`startGenreFill(library, .{ .limit, .offline })` starts a `release_info` Job
that asks MusicBrainz for the release group of up to `limit` (1 to 512) Releases
with a MusicBrainz release ID and a Track with no genres, and fills them
whatever the setting says. Its progress counts Releases, and nothing but genres
is fetched or stored.

## Server environment variables

`orca-cli` reads `ORCA_LISTENBRAINZ_URL`, `ORCA_LISTENBRAINZ_LABS_URL`,
`ORCA_MUSICBRAINZ_URL`, `ORCA_ACOUSTID_URL`, `ORCA_COVERARTARCHIVE_URL`,
`ORCA_LRCLIB_URL`, `ORCA_WIKIDATA_URL`, `ORCA_WIKIMEDIA_URL` and
`ORCA_WIKIPEDIA_URL` to point a service at another server under the rules of
[Servers](#servers). With `ORCA_WIKIPEDIA_URL` set, every language is asked of
that one server. The commands that use them are in [cli.md](cli.md).
