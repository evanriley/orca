# Providers and listening history

Orca talks to online services only through `network.Gateway`, and the rules
below hold for every provider. ListenBrainz, ListenBrainz Labs, MusicBrainz,
AcoustID, the Cover Art Archive, LRCLIB, Wikidata, Wikimedia Commons and
Wikipedia are connected.
Other services follow the same rules; a request that breaks one is a defect,
not a tuning choice.

## Rules toward providers

- **Identification.** Every request carries exactly one `User-Agent`, of the
  form `Name/version ( contact )`. The host supplies the name, version and
  contact with `Runtime.setClientIdentity`, and liborca's version is appended;
  liborca itself carries no identity and refuses provider work until one is
  set ([Client identity](api.md#client-identity)). `orca-cli` and `orca-gtk`
  send `Orca/0.2.0 ( evan@evanriley.com )`, with the contact taken from the
  `-Dprovider-contact` build option. That contact is the maintainer's email
  because the repository is private; it becomes the repository URL when the
  repository is public. Names and contacts are validated: empty, control
  characters and parentheses are refused.
- **Rate.** Each service's requests are spaced by its own minimum interval,
  the provider module's `minimum_interval_ms`, taken from what the service
  publishes. Orca does not wait longer than the service asks. A Gateway
  configured without an interval waits 1000 ms.

  | Service | Published guidance | Interval |
  | --- | --- | --- |
  | MusicBrainz | about 1 request a second per IP; more returns 503 to all (rate-limiting page) | 1000 ms |
  | AcoustID | "no more than 3 requests per second" (web service docs) | 334 ms |
  | ListenBrainz | "never more than one call per second", and `X-RateLimit-*` (API docs) | 1000 ms |
  | ListenBrainz Labs | none; follows ListenBrainz | 1000 ms |
  | Wikidata, Wikimedia Commons | Action API: one at a time, under 5 a second; API Gateway: 200 a minute with a `User-Agent` | 300 ms |
  | Wikipedia (REST) | under 5 a second; API Gateway: 200 a minute | 300 ms |
  | Cover Art Archive | "no rate limiting rules in place" (API docs) | 250 ms |
  | LRCLIB | none published; served behind Cloudflare | 500 ms |

  The gateway also honours `X-RateLimit-Remaining` and `X-RateLimit-Reset-In`
  when a response carries them, and waits out the window instead of sending
  into it.
- **429 and 503.** A `429`, or a `503` with a `Retry-After`, blocks every
  request to the service until the latest of its `Retry-After`, its
  `X-RateLimit-Reset-In` and a backoff of 60 s, doubling per repeated refusal
  up to 1 h; they are not added. One success resets the backoff. A `503`
  without `Retry-After` goes back to the caller as a failure.
- **`Retry-After` in full.** `Retry-After` is read as delay-seconds or as an
  HTTP-date in the IMF-fixdate form (`Wed, 21 Oct 2026 07:28:00 GMT`) and is
  honoured however long it is. A value in neither form is ignored, and a date
  already past adds nothing to the backoff. `X-RateLimit-Reset-In` counts
  for at most 1 h.
- **Blocks outlive the process.** Each service's block and backoff are kept
  in the Library (`provider_state`) in wall-clock time, and so is the
  earliest time of its next request: the minimum interval after the last
  request, or the end of a quota window (`X-RateLimit-Remaining: 0`). Every
  Gateway over that Library reads them before a request, so a restarted or
  second process, or the next job's Gateway, obeys a block, a quota window
  and the request spacing another one received. Libraries do not share
  blocks.
- **One request at a time per service.** A Gateway claims the service's lease
  in the Library (`provider_leases`) for each request, stores the next request
  time before sending, and releases the lease when the request, one retry
  attempt, or its redirect hops end. A request whose timeout would outlast the
  lease extends it first. Another Gateway, in this or another process, waits
  for the lease, polling every 250 ms, until its deadline or for at most 120
  s, and then fails with `error.ProviderBusy` without sending. A matching or
  submission job then fails and names the busy service (`MatchStats.busy`,
  `SubmissionOutcome.busy`); the listen worker reports `busy` and tries again
  120 s later; `orca-cli` prints, for example, `MusicBrainz is in use by
  another Orca process`. The lease of a process that crashed is free once it
  runs out, at most 120 s after it was claimed or extended.
- **Jitter.** Every backoff Orca chooses lasts a random 0.5 to 1.5 times its
  nominal length: the retries inside a call, the rate-limit backoff,
  ListenBrainz delivery's backoff, and the waits of the job retries below.
  Processes that failed together therefore do not retry together. A time the
  server gave is never shortened.
- **Job retries.** After an outage (a `5xx` or `408` without `Retry-After`)
  or a timeout, matching, AcoustID submission, cover art, lyrics and artist
  information ask again after a jittered 5 s, then a jittered 30 s, then
  report the service unavailable (`network.retry`). Each wait uses the
  Gateway's random source and clock, ends within 100 ms of a cancel, and is
  not begun if it would end past the job's deadline. A transient failure is
  never stored as a result.
- **No retries inside a call.** By default (`Config.maximum_attempts = 1`) a
  request is made once. A failure goes back to the caller, which retries on
  its own schedule. The gateway has a 30 s
  request deadline and a cancellation flag checked while it waits.
- **No connection reuse.** Provider requests do not reuse connections
  (`Connection: close`), because a pooled one the server dropped while idle
  would fail the first request after a quiet period.
- **One backoff per service.** A refusal or outage on one endpoint delays
  every endpoint of that service, so a failing submission cannot be masked by
  a working validation, or the reverse.
- **Batching.** A backlog goes out as `import` requests of up to 100 listens.
  One listen goes out as `single`. Requests larger than the service's limit
  are never sent: a listen over 10,240 bytes drops its optional fields, and
  one still too large is rejected locally.
- **`playing_now` is opt-in.** Orca announces what is playing only when the
  host turns Now Playing on, under the rules in [Now Playing](#now-playing).
- **Permanent refusals are not resent.** A `4xx` other than `401`, `403`,
  `408` and `429` marks the listen rejected. A rejected batch is split and its
  listens sent one at a time, so one bad listen cannot hold back the rest.
- **Token validation only on change.** The token is validated when a host
  reports that it changed (`libraryScrobblerCredentialsChanged`), once, the
  next time a request could be made. It is not validated at every start or
  before every submission, and `orca-cli scrobble` never validates: with
  nothing queued it makes no request and looks up no token, and otherwise a
  bad token shows as a `401` or `403` on submission, which stops delivery
  until the token changes.
- **Credentials.** A user's token or key is read from the host's secure
  storage through `CredentialStore` at the moment of a request. It is never
  written to the Library database, a log, a cache key or a settings file.
  `orca-gtk` uses the Secret Service through libsecret; `orca-cli` reads
  `ORCA_LISTENBRAINZ_TOKEN` and `ORCA_ACOUSTID_USER_KEY`.
- **Servers.** ListenBrainz-compatible servers are reachable with
  `Runtime.setListenBrainzServer`, a MusicBrainz mirror with
  `Runtime.setMusicBrainzServer`, another AcoustID server with
  `Runtime.setAcoustIdServer`, another Cover Art Archive with
  `Runtime.setCoverArtArchiveServer`, another LRCLIB server with
  `Runtime.setLrclibServer`, and other Wikidata, Wikimedia Commons and
  Wikipedia servers with `Runtime.setWikidataServer`,
  `Runtime.setWikimediaCommonsServer` and `Runtime.setWikipediaServer`, and
  another ListenBrainz Labs server with `Runtime.setListenBrainzLabsServer`.
  `http` is accepted only for `127.0.0.1`,
  `[::1]` and `localhost`, so a token or a library's contents never cross a
  network in clear text.

## Listens

A listen is one heard play of one queue entry. The Player's status is sampled
every 100 ms by `processNextCommand`, and a listen is recorded when:

- the track is at least 30 s long, and
- it has been audible for `min(half its length, 4 min)`.

That is ListenBrainz's rule, and the default listen policy. A Library may keep
another (`librarySetListenPolicy`, `orca-cli listens --policy=`):

| Policy | A listen is recorded once heard for |
| --- | --- |
| `half_or_four_minutes` | ListenBrainz's rule, above |
| `thirty_seconds` | 30 s, whatever the track's length |
| `full_track` | the whole track, less one second |

The policy decides only what the local history keeps. A listen is sent only
when it also meets ListenBrainz's rule: one that does not is stored with
`listens.syncable = 0` and never queued, and becomes syncable, and is queued
if sending is on, when its finished time meets the rule. Under `full_track`,
a play that meets ListenBrainz's rule but stops before the end is neither kept
nor sent. `librarySetListenRecording(library, false)` (`--record=off`) keeps
no listens at all, and so sends none; now-playing announcements still go out
while sending is on. Both settings are stored in the Library.

Audible time counts only frames played at their natural rate. Paused time and
positions skipped by a seek do not count. `started_at` is when the entry's
first frame would have played, in Unix seconds: the moment playback started,
less the position it started from. A track repeated in the queue is a new
listen each time it starts. The listened Track is the one the audible entry
serial names in the queue, never the audible cursor's; a sample whose serial
moves while it is resolved is skipped rather than ending the listen.

A listen is recorded by the Library's listen worker, off the control lane and
the render callback. When the entry ends, the recorded time is raised to what
was finally heard. An entry ends when the audible entry or Track changes, the
transport stops, or the Player drains: the last entry of a queue has decoded
to its end and every Zone has played it out, with the transport still
`playing`. Playing the same entry again after a drain is a new listen.

## Local play history

Listens are always recorded in the Library's `listens` table, whether or not
anything is sent anywhere. The table is the play history, kept forever, and
survives removing a folder: the listen keeps its title, artist and album with
a null file. `Runtime.libraryTrackPlayStats` and `TrackDetails` report the
play count and last play of a Track's file; `orca-cli track` prints them and
`orca-gtk` shows them in the details panel. The schema is described in
[database.md](database.md).

`orca-cli play-tracks` records listens under the Library's policy and never
sends them.

`libraryClearListens` (`orca-cli listens --clear`) deletes every listen, every
delivery of one, sent or still waiting, and with them every play count, in one
transaction, so `delivered` in the scrobbler status restarts from 0. Ratings, loves and feedback, and any feedback waiting to be sent,
stay.

## Delivery

Sending is opt-in per Library:
`librarySetScrobbling(library, true, offline, now_playing)`. At most one
Library per runtime scrobbles. A listen recorded while sending is off is never
queued later, so turning it on does not upload history. Love and hate given
while it was off are sent, because they are the user's current opinion rather
than an event.

An eligible listen is stored with a `scrobble_queue` row in one transaction.
The worker leases rows (`lease_owner`, `lease_expires_at`), sends them, and
marks them delivered, rejected or, on a transient failure, pending again with
a later attempt time. A transient failure is a `429`, a `5xx`, a timeout or a
network error: each unsent listen gets the end of the block or backoff it
started as its `next_attempt_at`, and the backoff also blocks the service in
`provider_state`, so a restarted or second process sends nothing before then.
Listens of a request that was never sent (offline, canceled, the service busy)
or whose token was refused go back to pending as they were. A lease that
outlives a crashed worker expires and is reclaimed, and a result from a worker
that lost its lease is discarded. Queue states are pending, leased, delivered
and rejected.

`libraryScrobblerStatus` reports the scrobbler's state:

| State | Meaning |
| --- | --- |
| `disabled` | Scrobbling is off. A Library with no running worker reports its queue counts from the database, at most once a second, and starts no worker. |
| `idle` | Nothing to send, or between requests. |
| `needs_token` | Listens are waiting and the store has no token. |
| `validating` | The token is being checked. |
| `invalid_token` | The service refused the token. Delivery resumes when it changes. |
| `submitting` | A request is in flight. |
| `rate_limited` | The service asked Orca to slow down. |
| `backing_off` | The last request failed; the next attempt is scheduled. |
| `offline` | Offline mode: listens stay queued and nothing is sent. |
| `busy` | Another Orca process holds the service's lease; the worker tries again 120 s later. |

The status also carries the user name of the last validated token, the number
of pending listens, the number of love and hate changes waiting to be sent
(`feedback_pending`), the total delivered, the time of the next attempt, the
end of the service's block (`blocked_until`, Unix seconds) and the last error.
A Library with no running worker reports both counts and the block from its
database; `orca-cli scrobble --status` prints the block as `blocked_until=` in
UTC.

Each pass of the worker sends, in this order, at most one request of each kind
and only while no request is held back: listens, then Now Playing, then one
feedback change. A due batch of listens is always sent first, and Now Playing
and feedback wait for the next pass. One backoff, one `429` block and one
refused token serve all three kinds of request.

## Love and hate

A song can be loved or hated (`librarySetFeedback`) and the mark can be
cleared. Feedback is kept in the Library whether or not anything is sent, is
shown on `TrackSummary.feedback` and `TrackDetails.feedback`, and belongs to
the song's Recording, not to a file or a Track. A FLAC and an MP3 of one song
share it, and a reprojection that gives a Track a new id keeps it. It is
independent of the star rating (see [playlists.md](playlists.md#ratings)).

While the Library scrobbles, feedback is sent to ListenBrainz
(`POST /1/feedback/recording-feedback`, score `1` love, `-1` hate, `0`
cleared):

- **Only under a MusicBrainz recording id.** Orca has no other identifier the
  service accepts. Feedback on a Recording none of whose files carries a
  recording id is kept and never sent; `TrackDetails.feedback_syncable` says
  whether an id is known, and it is not counted in `feedback_pending`.
- **One request per change, one change per pass.** The gateway spaces requests
  by at least a second, so a hundred loves take about two minutes and cost a
  hundred requests. Nothing is batched because the endpoint takes one
  recording.
- **Only the final state is sent, once it has stood for 2 s.** A change is not
  sent until it is 2 s old, so love, hate and love again in quick succession
  sends only the last opinion, and nothing at all when that matches what the
  service already has. A change made while a request is in flight stays
  pending and goes out next. Clearing feedback that was never sent sends
  nothing.
- **Clearing sent feedback sends score `0` once**, and the row is then
  forgotten.
- **Clearing a change the service rejected forgets it locally**, with no
  request: the service never held it.
- **A change the service accepted is not sent again.** If Orca cannot record
  that it was accepted, only the local mark is retried, after 60 s and then
  after twice as long each time, up to an hour, without another request.
- **Failures follow the shared rules.** `429`, `5xx` and network errors use the
  service backoff; `401` and `403` stop all delivery until the token changes;
  any other `4xx` except `408` marks the change rejected. A rejected change is not sent
  again until the user changes that song's feedback.
- **Nothing is fetched.** Orca never reads the user's feedback from the
  service, so feedback given elsewhere does not appear in Orca.

## Now Playing

`librarySetScrobbling(..., now_playing = true)` also announces the track that
is playing, with `listen_type: "playing_now"`, one listen and no `listened_at`,
built from the same fields as a listen. It is off by default.

- **At most one request per track actually listened to.** It is announced once
  the entry has been heard for 10 s, only when the track is 30 s or longer,
  and never for an entry that was skipped first, drained, or that reached the
  listen threshold on the same sample. A track played twice is announced
  twice. Pausing and seeking do not advance the 10 s.
- **Never retried and never queued.** An update is held in memory only, the
  newest one only, and is dropped when a request cannot go out (offline, no
  token, refused token, rate limit, backoff), when it is 60 s old or older
  when it would be sent, and after any failure of its own request. A `429`
  still blocks the service, and a `5xx` or network error counts toward the
  shared backoff, so Now Playing cannot hide an outage.
- **Never ahead of listens.** A due batch of listens is sent before it.

## Matching

A file without a MusicBrainz recording ID cannot have its loves, hates or
listens tied to a recording on ListenBrainz. `Runtime.startLibraryMatching`
asks MusicBrainz, and AcoustID by fingerprint, about those files and stores
what they find as proposals. Nothing takes effect until a person accepts one.
Acceptance stores the recording ID, title and artist, and the album's values
once every Track of its Release agrees on one MusicBrainz release, as Orca
metadata; see [metadata.md](metadata.md#accepting-a-match).

- **What is searched.** Every Track whose playing file has no recording ID in
  effect, in Track id order, by each service that has not yet answered for
  that file. An answer, empty ones included, is recorded per file and service
  in `identification_searches`, so no service is asked about a file twice. A
  failed or refused search records nothing and is repeated on the next run.
  One Track is one search however many files back it. `MatchRequest.limit`
  bounds how many Tracks one run examines, and `MatchRequest.track_id` limits
  it to one Track under the same rule.
- **One proposal per recording.** Candidates from both services are merged by
  recording ID. A proposal names the services that found it: `musicbrainz`,
  `acoustid` or `musicbrainz+acoustid`. When a file already has a proposal for
  that recording, it is updated in place and keeps its state, so a dismissed
  or accepted proposal is never offered again.
- **Confidence.** Orca scores each service's candidate from 0 to 1 against the
  Track's title, artist, album and length; AcoustID's own score is the
  fingerprint evidence in that score. The proposal's confidence is
  `1 − (1 − c_musicbrainz)(1 − c_acoustid)` over the services that found it, so
  two services agreeing rank above either alone. Candidates below 0.5 are
  dropped.
- **Failures.** A rate limit waits out the longer of the service's block and
  a backoff of 60 s doubling per attempt, cancellably, then asks again. An
  outage or a timeout is asked again after about 5 s, then about 30 s. After
  three attempts of either kind, or at once when the network cannot
  be reached or another process holds the service, the job stops and reports
  `failed`. Cached answers are still used without a network. A query answered
  with something that is not a search result is counted and skipped.
- **Refused queries.** A query MusicBrainz or AcoustID refuses with a `4xx`
  other than `401`, `403`, `408` and `429` is counted as refused and skipped,
  and the refusal is cached in `provider_cache` with its status for 7 days.
  Until then the query counts as refused without a request, and a cache hit;
  afterwards it is asked again. When AcoustID refuses a batch of several
  fingerprints, nothing is cached and each fingerprint is asked again in a
  request of its own, through the same gateway and its request spacing; only
  a refusal of a single fingerprint is cached. A refused key (AcoustID error codes
  4 and 6) is not cached, and a cached refusal never stands in for an answer
  while the service is down.
- **One Release.** `MatchRequest.release_id` limits a run to one Release's
  Tracks, under the same rule. With it, `accept_minimum_confidence` then
  accepts the Release's matches as `libraryAcceptConfidentMatches` would, and
  `cover_art` then fetches the Release's cover as in
  [Cover Art Archive](#cover-art-archive), under the Release id it started
  with; the files given values are then reprojected once. `orca-gtk`'s Match
  Album runs all three with the review threshold from Settings.
- **Re-identify.** `MatchRequest.mode = .reidentify` searches one Track
  (`track_id`) or one Release's Tracks (`release_id`) again: every one with a
  playing file, whatever recording ID is in effect and whatever services
  answered before. Without either it returns `error.InvalidMatchRequest`, as
  it does with `accept_minimum_confidence`, so no correction is accepted in
  bulk. A candidate for the recording ID already in effect is not proposed
  and counts as `confirmed` in `jobMatchStats`, once per Track; any other
  candidate is stored as a proposal as in a search. The answers are recorded
  in `identification_searches` as in a search, and a dismissed proposal stays
  dismissed. With `release_id`, the proposals are pointed at one release as
  [Match Album](#musicbrainz-release-lookup) does. The MusicBrainz query is
  built from the Track's current tags and does not use its recording ID, so
  for a mistagged file the fingerprint lookup on AcoustID carries the signal.
- **One job at a time.** A second `startLibraryMatching` while one runs returns
  `error.MatchingAlreadyRunning`, and one while an AcoustID submission runs
  returns `error.AcoustIdBusy`, so each service sees one client and one
  backoff. Cancellation is checked between Tracks, between fingerprints,
  while waiting for the next request slot and while backing off.

`jobMatchStats` reports, besides the Tracks examined and matched, the
MusicBrainz requests and cache hits, the fingerprints taken, read from the
cache or failed, the AcoustID requests, cache hits and refused queries, and
`acoustid`: `searched`, `off` (the request asked for no fingerprints),
`no_client_key` or `invalid_client_key`.

`libraryMatchProposals` lists a Track's pending proposals, most confident
first, with their source, AcoustID score and, for a correction, the
recording ID it replaces. `libraryAcceptMatch` accepts one and
`libraryDismissMatch` dismisses one; both return `error.ProposalInGroup` for
a proposal in an album group.
`libraryAcceptConfidentMatches(minimum)` accepts each file's best pending
proposal with a confidence of at least `minimum`, chosen as
[metadata.md](metadata.md#musicbrainz-recording-ids) describes; it is an
explicit user action, never run by a job.

### MusicBrainz search

- **The query.** `GET /ws/2/recording?fmt=json&limit=10&query=` with
  `recording:"TITLE" AND artist:"ARTIST" release:"ALBUM"`. The release term is
  optional, so it raises matching releases without excluding the others.
  Lucene syntax characters in the values are escaped with a backslash. A
  Track without a title or an artist is counted and not searched.
- **What is kept.** The recording ID, title, full artist credit, the release
  whose title is closest to the album with its ID and track number, the IDs
  of up to 25 releases the recording is listed on with each one's status,
  date and track count, the length, and MusicBrainz's own score from 0 to
  100.
- **Cache.** Answers, empty ones included, are cached in `provider_cache` for
  30 days of wall time, keyed by the request URL. When a request fails and an
  expired answer is cached, that answer is used.

### MusicBrainz release lookup

- **The request.** `GET /ws/2/release/{id}?fmt=json&inc=recordings+artist-credits+release-groups`,
  through the same gateway, cache, counters and refusal rules as the search.
  The ID is checked to be a lowercase UUID first.
- **When.** Before a file's search is recorded, the release of its most
  confident MusicBrainz proposal is looked up, once per run, and every
  proposal naming that release is filled in. A failure that would stop a
  search stops the job the same way, before that file is recorded, so it is
  searched again next time from the cache. A refused or missing release
  (`404`), an answer that is not a release, or a release without the
  recording leaves the proposals as found.
- **What is kept.** The track holding the recording: at the file's tagged
  track number when the recording appears more than once, else the first.
  Its title, artist credit, ID and position and its medium's position, which
  become the track and disc numbers (a vinyl number such as `A1` is not
  used), and the release's title, artist credit, date and release-group ID,
  with the album-artist ID only when the credit names one artist. A proposal
  found again on another release loses these values. Proposals found only by
  AcoustID carry no release.
- **Match Album.** After its search pass, which may search nothing, each
  file of the Release votes once for every release its stored proposals that
  are not dismissed list. The release with most votes wins, a tie going to
  the Release's tagged release ID, then to an `Official` release, then to
  one with as many tracks as the Release has Tracks, then to the earliest
  date (a release without one last), then to the lowest ID. Status, track
  count and date are what the search said about each release, first seen
  per release; a release a stored payload says none of them about ranks as
  unofficial, of another length and undated. It is looked up once, and
  every proposal listing it is pointed at it and filled in
  (`updatePayload`). A rerun after a failure completes from the cache.

### AcoustID lookup

- **Fingerprints.** The first 120 s of the playing file are decoded by Orca,
  resampled to 11,025 Hz and fingerprinted by Chromaprint, as `fpcalc` does;
  see [analysis.md](analysis.md#acoustid-fingerprints). A file that does not
  decode cleanly has no fingerprint, is counted in `fingerprint_failures`, and
  its Track is still searched on MusicBrainz.
- **The request.** `POST /v2/lookup`, a gzip-compressed form
  (`Content-Encoding: gzip`) with `client`, `clientversion`, `format=json`,
  `meta=recordings releasegroups compress`, `batch=1` and `duration.N` and
  `fingerprint.N` for up to 20 fingerprints. `duration` is the whole file's
  length in whole seconds, rounded. Answers come back per index.
- **What is kept.** Each recording with an ID once per fingerprint, under its
  best score: the ID, the title (empty when AcoustID has none), the artists
  joined by their join phrases, the release group title closest to the
  Track's album, the length and AcoustID's score. With `compress`, an artist
  or release group named in full once may appear by ID alone elsewhere; names
  are resolved across the whole answer.
- **Cache.** Each fingerprint's answer is cached in `provider_cache` for 90
  days, keyed by the duration and a BLAKE3 hash of the fingerprint, so
  fingerprints already answered are left out of the request.
- **Application key.** AcoustID identifies the application by a client key.
  `orca-cli` and `orca-gtk` set it with `Runtime.setAcoustIdClientKey` from
  the build option `-Dacoustid-key=` (default `AqlfLksN1K`); liborca has no
  key of its own. A `CredentialStore` value under `org.acoustid` /
  `client-key` overrides it. Without a key AcoustID is skipped and reported
  as `no_client_key`; a key AcoustID refuses (error code 4) stops AcoustID for
  the rest of the job and is reported as `invalid_client_key`.

### Verification

A recording ID in effect can be wrong: a file tagged as another track of its
album, a tag copied from the wrong edition. `MatchRequest.mode = .verify`
checks each file that has one against what AcoustID hears in its
fingerprint, and proposes a correction where AcoustID hears another
recording. MusicBrainz is asked only for the Release a correction names.

- **AcoustID is required.** Without an application key, or with
  `fingerprints = false`, `startLibraryMatching` returns
  `error.AcoustIdRequired` and no job starts. `accept_minimum_confidence` and
  `cover_art` return `error.InvalidMatchRequest`. A key AcoustID refuses
  mid-run stops the job `failed` with `acoustid = invalid_client_key`, and a
  credential store holding no key stops it with `no_client_key`.
- **Outcomes.** A file `agrees` when AcoustID lists its recording ID in
  effect at a score of at least 0.5 (`verify_agree_minimum`). It `disagrees`
  when AcoustID does not and lists another recording at 0.9 or more
  (`verify_disagree_minimum`); it is `unconfirmed` otherwise, an empty answer
  included. A file that does not decode, or changes while it is
  fingerprinted, is `no_fingerprint`. Each outcome is stored in
  `recording_verifications` with the file's quick hash, the recording ID in
  effect and up to eight recordings AcoustID heard, strongest first.
- **What is not stored.** A file with no present location or no file there,
  and a fingerprint AcoustID refused or left unanswered (counted in
  `acoustid_refused`), get no outcome and are tried again on the next run. A
  file with no quick hash is counted in `skipped` and never verified.
- **What is verified.** A file whose stored outcome is missing or stale. An
  outcome is stale once the file's quick hash or its recording ID in effect
  changes. A file whose fresh outcome is `disagrees` is verified again only
  beside a stale or unverified file of its Release, so the Release's album
  group can form again with every file it disputes, or when `track_id` asks
  for it alone; otherwise a rerun asks nothing about it. When only the
  recording ID changed and the new one is among the recordings heard at 0.5
  or more, the file agrees again without a lookup. `total_units` counts by
  the same rule.
- **Units.** The library is verified one Release at a time, in Release id
  order, then Tracks with no Release a page at a time; `release_id` and
  `track_id` limit it to one. A unit's files are fingerprinted, looked up 20
  at a time, and committed in one transaction with their proposals; a
  cancelled unit commits nothing. `limit` bounds the Tracks examined.
- **Corrections.** A file that disagrees is proposed each recording heard at
  0.9 or more, scored as a search candidate against the Track's artist,
  album and length but not its title, which may be the wrong recording's. A
  file whose recording ID is the user's own locked edit is verified and
  never proposed a correction. Accepting one is described in
  [metadata.md](metadata.md#corrections).
- **Album corrections.** When the Release has a MusicBrainz release ID and
  at most 512 Tracks, it is looked up once as in
  [MusicBrainz release lookup](#musicbrainz-release-lookup). Each disputing
  file whose strongest recording heard is on that release has that proposal
  filled in from it, positions included, and those proposals form one album
  group (`identification_proposals.album_group`), accepted or dismissed
  only whole with `libraryAcceptCorrectionGroup` and
  `libraryDismissCorrectionGroup`. The other disputing files get corrections
  of their own, with AcoustID's title and artist and no position. A lookup
  that fails stops the job as a search's would; a release MusicBrainz does
  not have leaves every correction ungrouped.
- **Cost.** About one AcoustID request per Release with a file to verify,
  and one MusicBrainz request per Release with a correction, each at most
  one a second. Answers come from the 90-day AcoustID and 30-day MusicBrainz
  caches when they can, so a file that disagrees, verified again beside a
  stale one, costs no request.
- **Idle maintenance.** `libraryMaintenance` verifies the library one
  Release per unit while nothing plays and no other job runs, one unit
  every `interval_ms` (default 5 minutes). Once no Release is left, a unit
  takes at most 20 Tracks with no Release. A unit is a verify job like any
  other: same Gateway, same rate limit and same leases. Before starting one,
  the runtime reads `provider_state`. While AcoustID or MusicBrainz has a
  block recorded, it starts nothing and reports `provider_busy`, so a unit
  never waits out a backoff. A matching, cover-fetch or submission job the
  host starts while a unit runs cancels the unit. It starts once the unit's
  worker has released its leases and been joined, so the two never send
  together. See [control-plane.md](control-plane.md#idle-maintenance).

`jobMatchStats` reports `verified`, `agreed`, `disagreed`, `unconfirmed`,
`skipped`, `correction_groups` and `proposals_stored` besides the fingerprint
and request counts. `libraryTrackVerification` returns a Track's stored
outcome, whether it is stale, and whether the strongest recording heard has
a dismissed proposal. `libraryCorrectionGroups` lists the album groups with a
pending proposal; `libraryMatchReviewPage` leaves their proposals out.

## AcoustID submission

`Runtime.startAcoustIdSubmission` sends AcoustID the fingerprints of files
whose recording ID Orca chose, so other people's copies of the recording can
be identified. It is started only by a person; no job starts it.

- **What is sent.** Files whose recording ID in effect is an Orca value from
  an accepted match or an edit, differs from the file's own tag or was written
  into it by Orca, and has not been sent for that file. IDs Orca did not
  choose are never sent. A file is sent once per
  recording ID: after the ID is edited, the new ID is sent again. An ID from
  an accepted match is not sent when AcoustID was among the match's sources,
  since AcoustID already knows it, or when the match was accepted by
  `libraryAcceptConfidentMatches`: a match without AcoustID has no
  fingerprint score, so a bulk acceptance of it rests on text alone. A match
  accepted one at a time from MusicBrainz alone is sent, and so is an ID the
  user edited, whatever proposed it. An ID from a match is sent only for the
  file the match was accepted on: a copy split off a shared file inherits the
  ID without the match and does not send it. Matches accepted before library
  version 19 count as accepted one at a time.
  `libraryAcoustIdSubmittableCount` and `libraryAcoustIdSubmittablePage` list
  them without fingerprinting anything.
- **ID or metadata.** When the file's length differs from the recording's by
  more than 30 s, the title, artist, album, album artist, track and disc
  number and year are sent instead of the ID. The recording's length comes
  from the accepted match; without one, the ID is sent.
- **Only clean fingerprints.** A file that does not decode cleanly is counted
  in `fingerprint_failures` and not sent.
- **The request.** `POST /v2/submit`, a gzip-compressed form with `client`,
  `clientversion`, `user`, `format=json` and, per item N, `duration.N`,
  `fingerprint.N`, `fileformat.N`, `bitrate.N` (the file's average) and
  either `mbid.N` or the metadata fields. A batch holds at most 50 items and
  at most 900 KB of form, below the service's 1 MiB limit; an item that would
  pass either bound starts the next batch.
- **User key.** The user's key is read from the `CredentialStore` under
  `org.acoustid` / `user-key` before each request and never kept. Without one
  the job fails with `needs_user_key` before fingerprinting anything; a key
  AcoustID refuses (`401`, `403`, or error code 6) fails it with
  `invalid_user_key`. Nothing is marked sent in either case.
- **Failures.** Another `4xx` rejects that batch: its files are counted in
  `rejected` and stay unsent. Rate limits, outages and timeouts are retried
  as in matching, and after three attempts the job fails with
  `unavailable`. While another process holds AcoustID it fails with `busy`.
- **Record.** Each accepted item's submission ID is stored in
  `acoustid_submissions` with the file and recording ID.

`jobSubmissionStats` reports the files examined, submitted and sent as
metadata, the fingerprints taken, read from the cache or failed, the files
rejected, the requests made and the `outcome`.

From the command line:

```sh
orca-cli match DATABASE [--batch=N] [--limit=N] [--no-fingerprints] [--cancel-after=MS]
orca-cli matches DATABASE TRACK_ID
orca-cli accept-match DATABASE PROPOSAL_ID
orca-cli dismiss-match DATABASE PROPOSAL_ID
orca-cli accept-matches DATABASE --min-score=0.9
orca-cli apply-release DATABASE RELEASE_ID [--fields=album,album_artist,date,release_id,track_titles]
orca-cli matches DATABASE --releases [--bucket=confident|needs_review|unmatched] [--min-score=0.9]
orca-cli matches DATABASE --release=ID [--candidate=MBID] (--evidence | --diff | --dismiss=MBID)
orca-cli fingerprint DATABASE TRACK_ID
ORCA_ACOUSTID_USER_KEY=KEY orca-cli submit-acoustid DATABASE [--dry-run]
```

`ORCA_MUSICBRAINZ_URL` and `ORCA_ACOUSTID_URL` point `match` and
`submit-acoustid` at other servers.

## Cover Art Archive

`Runtime.startReleaseCoverArtFetch(library, release_id)`, and a matching job
with `MatchRequest.cover_art`, fetch a Release's front cover from the Cover
Art Archive into the Library. Nothing is fetched for a Release whose front
cover a person chose, one of whose files carries a readable cover, or whose
folder holds a readable front image, and media files are never written. The
cover is stored in `release_artwork` ([database.md](database.md#release-artwork)),
and `libraryReleaseArtwork`, `libraryTrackArtwork` and the artwork loader
return it when no file of the Release has one and no cover was chosen: a
chosen cover always wins, then an embedded one.

- **Release ID.** The Release's tagged MusicBrainz release ID; without one,
  the release ID most of its accepted matches name, a tie going to the
  lowest. Without either nothing is fetched, and the outcome is
  `no_release_id`: review the matches, then fetch again. The ID is checked
  to be a lowercase UUID before a URL is built from it.
- **The request.** `GET /release/{mbid}/front-500` through the gateway as the
  service `coverartarchive`: its request interval, the shared backoff and
  block, the client identity and the service lease, as above.
- **Redirects.** The archive answers with a redirect to `archive.org`, which
  redirects again to the node holding the file. `Gateway.fetch` follows at
  most two redirects, each to `https` on `archive.org` or a host ending in
  `.archive.org`, sending only the user agent. A redirect anywhere else, to
  plain `http` included, is refused and nothing is stored; a third redirect
  is not followed. Against a server set with `setCoverArtArchiveServer` on a
  loopback host, a redirect back to that same server is also followed, so a
  local mock can redirect to itself.
- **The image.** At most 4 MiB, and only a JPEG or PNG by its bytes;
  anything else is refused and nothing is stored.
- **No cover.** A `404` is stored as a row without an image, and the release
  ID is not asked about again for 30 days of wall time; a fetched cover is
  not asked for again while its release ID stays the same.

`jobMatchStats(job).cover_art` reports the `CoverArtOutcome`: `chosen`,
`embedded`, `folder`, `fetched`, `cached`, `cached_miss`, `not_found`,
`no_release_id`, or, failing the job, `refused`, `unavailable` or `busy`.

### Cover candidates

`Runtime.startCoverArtCandidates(library, release_id)` lists the images the
archive holds for a Release so a person can pick one. It runs only when a
person asks for it, never from a scan, a match or a maintenance pass, and
makes at most 18 requests, each through the gateway as `coverartarchive`
under the same rate, backoff, identity and redirect rules:

1. `GET /release/{mbid}/`, the release's index, when the Release has a
   release ID, chosen as for the front cover.
2. `GET /release-group/{rgid}/`, the release group's index, only when the
   Release's files carry exactly one MusicBrainz release group ID. Only its
   front images are kept, as `release_group` candidates.
3. For each of at most 8 candidates (`max_cover_art_candidates`), fronts
   first, then release group fronts, backs, booklets and the rest, each in
   the archive's ID order, with an image listed by both indexes kept once:
   `GET /release/{mbid}/{id}`, the full image, whose header is measured for
   its size and whose bytes are then discarded, and
   `GET /release/{mbid}/{id}-250`, the thumbnail, which is kept.

An index is at most 1 MiB and lists at most 64 images; an image is at most
12 MiB, the bound on a cover a person sets, and only a JPEG or PNG by its
bytes. A full image that is refused, missing, too large or will not read
leaves its candidate without a size, and
`MatchStats.cover_art_candidates_unmeasured` counts it; a missing thumbnail
leaves it without one. An image or thumbnail that fails transiently (an
outage, a timeout, a rate limit, a busy service or no network) ends the
listing: the candidates measured before it are stored and the outcome is
`partial`, and with none measured the stored list is kept and the Job fails
`unavailable` or `busy`. Progress counts
candidates. The list replaces the Release's last one in
`cover_art_candidates` ([database.md](database.md#release-artwork)). When
the release's index was read but the release group's would not come, the
release's own candidates are stored and the Job succeeds with the outcome
`partial`; when there are none to keep, it fails as the request did.

`Runtime.libraryUseCoverArtCandidate(library, release_id, caa_id, kind)`
fetches the candidate's full image again, one request, and stores it as the
Release's chosen front, back or booklet. A candidate the Release no longer
lists is `error.UnknownCoverArtCandidate`; an image the archive no longer
holds fails the Job as `not_found` and stores nothing.

```sh
orca-cli match DATABASE --release=ID [--accept-min-score=SCORE] [--cover-art]
orca-cli cover-art DATABASE RELEASE_ID [--candidates | --use=CAA_ID[:front|back|booklet]]
orca-cli artwork DATABASE --release=ID --out=PATH
```

`ORCA_COVERARTARCHIVE_URL` points `match`, `cover-art`, `artist-info
--fetch` and `orca-gtk` at another server.

The [Artist info](#artist-info) fetch also asks the archive for release
group covers, `GET /release-group/{mbid}/front-250`, under the same service,
redirects and image rules. They are kept in `release_group_covers`
([database.md](database.md#artist-info)), apart from `release_artwork`.

## LRCLIB

`Runtime.startTrackLyrics(library, track_id, .{ .fetch = true })` asks
[LRCLIB](https://lrclib.net) for a Track's lyrics when the Track has no
synced lyrics of its own. The answer is kept in the Library's `track_lyrics`
table ([database.md](database.md#track-lyrics)); media files are never
written, and no `.lrc` file is created. Where LRCLIB's lyrics rank against
the Track's own is in [metadata.md](metadata.md#lyrics).

- **Opt-in.** Nothing is sent without `fetch`, which also needs
  `setClientIdentity` (`error.ClientIdentityRequired`). A lyrics job without
  `fetch` still uses an answer the Library already keeps. A frontend leaves
  fetching off until the person turns it on.
- **What is sent.** `GET /api/get` with `track_name`, `artist_name`,
  `album_name` and `duration`: the Track's effective title, artist and album
  and its length in whole seconds, percent-encoded. An empty album is left
  out, and so is a duration that is unknown or longer than an hour. No
  MusicBrainz ID, path, file name, token or other Library content is sent.
  A Track without a title or an artist is not looked up (`no_metadata`).
- **The request.** Through the gateway as the service `lrclib`: the client
  identity's `User-Agent`, its request interval, the shared backoff and
  block, and the service lease, as above. A lookup inside a block sends
  nothing and reports `unavailable`.
- **The answer.** At most 512 KiB of JSON. A record's `syncedLyrics` and
  `plainLyrics` are parsed as LRC; `instrumental: true` is kept as an
  instrumental with no lines. A `404`, or a record with neither text that is
  not instrumental, is a miss. `408`, `5xx` and timeouts are asked again
  after about 5 s, then about 30 s, within the 60 s deadline, and then are
  `unavailable`; a rate limit is `unavailable` at once. Any other status, a
  redirect, or a body that is not a record is `refused`. Nothing is stored
  for a failure.
- **Reuse.** Each answer is stored with a BLAKE3 digest of the title,
  artist, album and duration it was asked with. While the digest matches,
  lyrics and instrumentals are reused for ever and a miss for 7 days of wall
  time. An edit or a rescan that changes any of the four values changes the
  digest, and the next fetch asks again.
- **Terms.** LRCLIB grants use of its API and asks for no key. It does not
  license the lyrics themselves: rights to the words stay with their
  owners, and an application that shows or stores them answers for that use.

`jobLyricsOutcome(job)` reports the `LyricsOutcome`. With `fetch` it is what
the lookup came to, also when the Track's own plain lyrics are the ones
returned: `fetched`, `cached`, `cached_miss`, `not_found`, `no_metadata`,
`refused`, `unavailable`, `busy` or `cancelled`, and `local` only when the
Track's own synced lyrics made a lookup needless. These outcomes do not fail
the job.

```sh
orca-cli lyrics DATABASE TRACK_ID [--fetch]
```

`ORCA_LRCLIB_URL` points `lyrics --fetch` at another server.

## Artist info

`Runtime.startArtistInfoFetch(library, artist_id, options)` gathers an
Artist's photo, biography, years active and links into the Library's
`artist_info`, `artist_links`, `artist_related` and
`related_artist_photos` tables
([database.md](database.md#artist-info)). Media files are never written.
`libraryArtistInfo`, `libraryArtistPhoto` and `libraryArtistLinks` read
what was kept.

- **Opt-in.** Nothing is fetched until a host starts the job, which needs
  `setClientIdentity` (`error.ClientIdentityRequired`). `options.offline`
  makes no request at all: the job uses the local image and answers already
  in `provider_cache`, and reports `offline`.
- **The order.**
  1. **A local image.** The Artist's folder is the folder above each of the
     Artist's release folders, or the deepest folder common to them, when it
     lies inside the files' roots and holds no other Artist's files. The
     first of `artist.jpg`, `artist.png`, `folder.jpg`, `thumb.jpg` and
     `fanart.jpg` there that is an image by its bytes and at most 8 MiB is
     the photo, and Commons is not asked for one unless `force` is set.
  2. **MusicBrainz.** `GET /ws/2/artist/{mbid}?inc=url-rels+genres+artist-rels`
     on the Artist's MusicBrainz artist ID, as the service `musicbrainz`. It
     gives the type, the life span, the Wikidata item, the
     links, and an `image` relation, which is used only when it names a
     `commons.wikimedia.org/wiki/File:` page. An Artist without an ID gets
     the local image only (`no_musicbrainz_id`), and nothing is sent.
  3. **Wikidata.** `wbgetentities` for the item's image (P18), its work
     period (P2031 start, P2032 end, each at year precision or finer) and
     its Wikipedia sitelink in `options.language`, else English, as the
     service `wikidata`. P18 outranks MusicBrainz's image relation.
  4. **Wikimedia Commons.** `prop=imageinfo` for the file's licence
     (`LicenseShortName`, `LicenseUrl`), its author (`Artist`) and an
     800-pixel rendering, then the rendering itself, as the service
     `wikimedia-commons`. Commons returns the author as HTML; Orca keeps
     plain text with tags removed, entities decoded and whitespace collapsed,
     at most 1 KiB. The rendering is fetched only over `https` on
     `wikimedia.org` or a host under it, or on the loopback server set with
     `setWikimediaCommonsServer`; at most 4 MiB, and only a JPEG, PNG or
     WebP by its bytes.
  5. **Wikipedia.** `GET /api/rest_v1/page/summary/{title}` on
     `https://{language}.wikipedia.org`, as the service `wikipedia`: the
     article's lead as plain text, at most 16 KiB, and its page. A
     disambiguation page is no biography.
  6. **Release groups.** `GET
     /ws/2/release-group?artist={mbid}&inc=artist-credits&limit=100&fmt=json`,
     as the service `musicbrainz`: one request, so at most MusicBrainz's
     largest page of 100 groups, each with its title, primary type, first
     release year and the other artists of its credit, joined as MusicBrainz
     joins them. They replace the Artist's `artist_release_groups`, at most
     `max_release_groups` (200). A failed browse keeps the groups already
     stored, unless the Artist's MusicBrainz ID changed, which clears them.
     The MusicBrainz lookup also gives the Artist's origin: its begin area,
     else its area, named with the subdivision it lies in, such as
     `Portland, Oregon`. Unless the area is itself a subdivision or a
     country, `GET /ws/2/area/{id}?inc=area-rels&fmt=json` follows its
     current backward `part of` relations upward, at most 3 lookups,
     preferring a subdivision to a country, so the country is named only
     when no subdivision is found. The lookups are cached like every other
     MusicBrainz answer; when none finds a subdivision or country, or one
     fails, the origin is the area's name alone.
  7. **Genres.** Unless genre fill is off, the MusicBrainz artist's genres
     go on the Artist's Tracks that have none
     ([Genres from MusicBrainz](#genres-from-musicbrainz)).
  8. **ListenBrainz.** `POST /1/popularity/artist` with
     `{"artist_mbids":[mbid]}` on the ListenBrainz server, as the service
     `listenbrainz`, needing no token: its `total_user_count` is kept as the
     Artist's listeners. Then `GET
     /similar-artists/json?artist_mbids={mbid}&algorithm=…` on
     `https://labs.api.listenbrainz.org`, as the service
     `listenbrainz-labs`: the 12 highest-scored related artists other than
     the Artist itself are kept. Both run at most once in 7 days per Artist,
     unless `force` is set; the Labs answer is cached for 7 days.
  9. **Related artist photos.** For each of the first 8 related artists
     with no library Artist and no photo or no-photo marker kept less than
     30 days ago (with `force`, the first 8 such artists whatever their
     age), the photo is found as for the Artist itself: MusicBrainz on the
     related artist's ID, Wikidata's P18 when MusicBrainz names an item,
     then Commons' `imageinfo` and the rendering, under the same services
     and limits. That is up to 32 requests, so at one a second per service
     the step adds about 8 seconds. A photo is kept in
     `related_artist_photos` by MusicBrainz artist ID; a related artist
     with no image, or a refusal, keeps a marker so it is not asked again
     for 30 days; an unavailable, busy or offline step keeps nothing and is
     asked on the next fetch. One artist's failure neither stops the others
     nor changes the outcome. Each kept photo keeps its attribution as the
     Artist's own photo does: `photo_source` (Commons), `photo_url` (its
     Commons page), `photo_licence`, `photo_licence_url` and `photo_credit`
     from the `imageinfo` reply's `extmetadata`, which
     `libraryRelatedArtistPhotoInfo` returns for a host to show with it.
  10. **Release group covers.** For each album and EP Elsewhere lists
     (`libraryArtistElsewhere`, newest first, at most 200), `GET
     /release-group/{mbid}/front-250` on the Cover Art Archive, as the
     service `coverartarchive`, under its redirect and image rules
     ([Cover Art Archive](#cover-art-archive)). A cover is kept in
     `release_group_covers` by group ID and not asked for again, `force`
     included; a `404` or refusal keeps a row without an image, asked about
     again after 30 days. Each group is asked once; one the archive could
     not answer for keeps nothing and the next group is asked.
     `options.offline` skips the step.
     None of these change the outcome. A cover goes when no Artist's
     release groups name its group any more. The artwork loader serves it
     for the subject `.{ .release_group = mbid }`, without a request.
  11. **Releases.** With `options.include_releases`, each of up to 64 of the
     Artist's Releases with a MusicBrainz release ID gets its
     [release info](#release-info). The first Release that ends
     unavailable, busy or offline ends the fetch with that outcome: Releases
     already fetched stay stored, and a later fetch asks for the rest. A
     refused Release is recorded and the next one is asked.
- **Years active.** For a `Group`, `Orchestra` or `Choir`, MusicBrainz's
  life span is formation to dissolution and is used as it is. For any
  other type, a person among them, the life span is a lifetime, so its
  begin is never used: the years start at Wikidata's P2031, else at the
  earliest release date among the Artist's Releases in the Library, and
  end at P2032. Such an Artist is `ended` when P2032 is set or MusicBrainz
  says it ended, with no end year unless P2032 gives one.
- **What is sent.** Only the MusicBrainz artist, area and release IDs, the
  release group, Wikidata item and Commons file IDs and the article title
  the services themselves returned, and the language. No path, file name, tag or other Library
  content leaves the machine.
- **Rules.** Each service has its own gateway: the client
  identity's `User-Agent`, its request interval, the shared backoff and
  block, and the service lease, as above. Answers are kept in
  `provider_cache` for 30 days and a refusal for 7; when a service cannot be
  reached an expired answer is used instead.
- **Reuse.** Info fetched less than 30 days of wall time ago, for the same
  MusicBrainz artist ID and the same requested language, is kept and nothing
  is asked (`cached`). `force` asks again; it still answers from
  `provider_cache` while those answers are fresh.
- **Licences.** A Commons photo is shown with its licence, a link to the
  licence and its author's credit, as Commons requires; the photo's Commons
  page is kept as `photo_url`. A Wikipedia biography is CC BY-SA 4.0 and is
  shown with that licence and a link to the article. Wikidata is CC0.
  MusicBrainz's data is CC0, except its genres
  ([Genres from MusicBrainz](#genres-from-musicbrainz)). ListenBrainz's
  listener counts and related artists are shown as from ListenBrainz. A
  local image carries no licence or credit.
- **Failures.** The Artist's own lookups are asked again after an outage or
  a timeout, as in [Job retries](#rules-toward-providers); related-artist
  photos and release group covers are asked once per fetch, so one cannot
  spend the deadline. A step that fails leaves what an earlier fetch stored
  for that step, and the rest still run. The outcome is then the first failure:
  `refused` (a `4xx`, a redirect off the service or a body Orca does not
  accept), `unavailable` (`408`, `5xx`, a network failure or a block) or
  `busy` (another Gateway still holds a service's lease when the deadline
  passes). A cancelled job keeps nothing and reports `cancelled`. None of
  these fail the job.
- **Deadline.** A fetch without `include_releases`, a Release's own info
  fetch and a lyrics fetch end within `fetch_deadline_ms` (60 s): each
  request's timeout is cut to the time left, and a service another Gateway
  holds is waited for until then. The Artist's info is stored first, then
  its listeners and related artists, then their photos, then release group
  covers; `jobArtistInfoStores(job)` counts each store as it happens.

`jobArtistInfoOutcome(job)` reports the `ArtistInfoOutcome`: `fetched`,
`cached`, `no_musicbrainz_id`, `offline`, `not_found`, `refused`,
`unavailable`, `busy` or `cancelled`. The outcome is also stored with the
info.

```sh
orca-cli artist-info DATABASE ARTIST_ID [--fetch] [--force] [--offline] [--lang=xx]
orca-cli artist-photo DATABASE ARTIST_ID --out=PATH
orca-cli related-photo DATABASE MBID --out=PATH
orca-cli release-group-cover DATABASE MBID --out=PATH
```

`ORCA_MUSICBRAINZ_URL`, `ORCA_COVERARTARCHIVE_URL`, `ORCA_WIKIDATA_URL`,
`ORCA_WIKIMEDIA_URL`, `ORCA_WIKIPEDIA_URL`, `ORCA_LISTENBRAINZ_URL` and
`ORCA_LISTENBRAINZ_LABS_URL` point `artist-info --fetch`, `release-info
--fetch` and `genres --fill-from-musicbrainz` at other servers. With `ORCA_WIKIPEDIA_URL`
set, every language is asked of that one server. `artist-info --fetch`
prints `stored n=N at_ms=MS` each time the job stores part of what it
found, then the info; `artist-info` prints `listeners=N (ListenBrainz)` and `related: N` with one line per related
artist, each ending in `photo=yes` or `photo=no`; `orca-cli related
DATABASE ARTIST_ID` prints those lines alone, and `related-photo` writes a
related artist's kept photo, then prints `source=`, `licence=`, `credit=`,
`photo-url=` and `photo-licence-url=` lines. With `--include-releases`, each
`elsewhere:` line carries `cover=yes`, `cover=no` (the archive has none) or
`cover=-` (not asked yet), and `release-group-cover` writes a kept cover to
PATH and prints `source=coverartarchive`, its type and its size.

## Release info

`Runtime.startReleaseInfoFetch(library, release_id, options)` starts a
`release_info` Job that keeps a Release's description in `release_info`
([database.md](database.md#artist-info)); `libraryReleaseInfo` reads it and
`jobReleaseInfoOutcome` reports the outcome, an `ArtistInfoOutcome`. It needs
`setClientIdentity`, and `error.UnknownRelease` names a Release that does not
exist. Media files are never written.

1. **MusicBrainz.** `GET /ws/2/release/{mbid}` on the Release's MusicBrainz
   release ID gives the release group, then `GET
   /ws/2/release-group/{id}?inc=url-rels+genres` its Wikidata item, its
   Wikipedia link and its genres. A Release without an ID asks nothing
   (`no_musicbrainz_id`).
2. **Genres.** Unless genre fill is off, the release group's genres go on
   the Release's Tracks ([Genres from MusicBrainz](#genres-from-musicbrainz)).
3. **Wikidata.** The item's Wikipedia sitelink in `options.language`, else
   English. A group without an item uses its Wikipedia link.
4. **Wikipedia.** The article's REST summary, as for an Artist's biography:
   the description, its page, its language and the CC BY-SA 4.0 licence.

Each service is asked through the same gateways, caches, reuse and failure
rules as artist info: info fetched less than 30 days ago for the same
release ID and language is `cached`, `offline` sends nothing, and the
outcome is the first failure while the other steps still run.

```sh
orca-cli release-info DATABASE RELEASE_ID [--fetch] [--force] [--offline] [--lang=xx]
```

It prints `description=wikipedia url=… language=… licence="CC BY-SA 4.0"`,
the `musicbrainz=` and `release-group=` IDs, the text and `outcome=`.

## Genres from MusicBrainz

MusicBrainz's genres are user-voted and are CC BY-NC-SA 3.0, not CC0, so
genres filled from them are shown with "Genres from MusicBrainz, CC BY-NC-SA
3.0" (`musicbrainz_genre_licence`).

- **What is written.** The three most voted genres, with any tied with the
  third, at most five, as provider genres (`provenance=provider`). A
  Release's genres go on its Tracks that have no genres from a file or a
  user's edit, replacing earlier provider genres; an Artist's go only on
  its Tracks that have no genres at all. A file's or a user's genres are
  never replaced, and replace provider genres when they appear.
- **On by default.** Artist info and release info fill genres unless the
  Library's setting is off: `setGenreFill(library, .{ .musicbrainz = false
  })` turns it off and `libraryGenreFill` reads it. It is kept in the
  Library's `library_settings`.
- **On request.** `startGenreFill(library, .{ .limit, .offline })` starts a
  `release_info` Job that asks MusicBrainz for the release group of up to
  `limit` (1 to 512) Releases with a MusicBrainz release ID and a Track with
  no genres, and fills them whatever the setting says. Its progress counts
  Releases. Nothing but genres is fetched or stored.

```sh
orca-cli genres DATABASE --fill-from-musicbrainz [--limit N] [--offline]
orca-cli genre-fill DATABASE [on|off]
```
