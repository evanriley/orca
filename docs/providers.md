# Providers and listening history

Orca talks to online services only through `network.Gateway`, and the rules
below hold for every provider. ListenBrainz, MusicBrainz, AcoustID and the
Cover Art Archive are connected.
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
- **Rate.** At most one request per second per service. The gateway honours
  `X-RateLimit-Remaining` and `X-RateLimit-Reset-In` when a response carries
  them, and waits out the window instead of sending into it.
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
- **One process per service.** Before each request a Gateway claims the
  service's lease in the Library (`provider_leases`) for 120 s, and it
  releases the lease when its job ends. While another process holds the
  lease, the request fails with `error.ProviderBusy` without being sent. A
  matching or submission job then fails and names the busy service
  (`MatchStats.busy`, `SubmissionOutcome.busy`); the listen worker reports
  `busy` and tries again 120 s later; `orca-cli` prints, for example,
  `MusicBrainz is in use by another Orca process`. The lease of a process
  that crashed is free 120 s after its last request.
- **Jitter.** Every backoff Orca chooses lasts a random 0.5 to 1.5 times its
  nominal length: the retries inside a call, the rate-limit backoff,
  ListenBrainz delivery's backoff, and the waits of matching and submission.
  Processes that failed together therefore do not retry together. A time the
  server gave is never shortened.
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
  `Runtime.setAcoustIdServer` and another Cover Art Archive with
  `Runtime.setCoverArtArchiveServer`. `http` is accepted only for `127.0.0.1`,
  `[::1]` and `localhost`, so a token or a library's contents never cross a
  network in clear text.

## Listens

A listen is one heard play of one queue entry. The Player's status is sampled
every 100 ms by `processNextCommand`, and a listen is recorded when:

- the track is at least 30 s long, and
- it has been audible for `min(half its length, 4 min)`.

Audible time counts only frames played at their natural rate. Paused time and
positions skipped by a seek do not count. `started_at` is when the entry's
first frame would have played, in Unix seconds: the moment playback started,
less the position it started from. A track repeated in the queue is a new
listen each time it starts.

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

`orca-cli play-tracks` records listens and never sends them.

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
independent of `tracks.rating`, the unused star rating.

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
what they find as proposals. Nothing takes effect until a person accepts one;
what acceptance writes is in
[metadata.md](metadata.md#musicbrainz-recording-ids).

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
- **Failures.** A `429`, a `5xx` or a timeout waits out the longer of the
  service's block and a backoff of 60 s doubling per attempt, cancellably,
  then asks again. After three attempts, or at once when the network cannot
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
  [Cover Art Archive](#cover-art-archive). `orca-gtk`'s Match Album runs all
  three with the review threshold from Preferences.
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
first, with their source and AcoustID score. `libraryAcceptMatch` accepts one
and `libraryDismissMatch` dismisses one.
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
  whose title is closest to the album with its ID and track number, the
  length, and MusicBrainz's own score from 0 to 100.
- **Cache.** Answers, empty ones included, are cached in `provider_cache` for
  30 days of wall time, keyed by the request URL. When a request fails and an
  expired answer is cached, that answer is used.

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
  `rejected` and stay unsent. `429`, `5xx` and network errors use the same
  backoff as matching, and after three attempts the job fails with
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
orca-cli fingerprint DATABASE TRACK_ID
ORCA_ACOUSTID_USER_KEY=KEY orca-cli submit-acoustid DATABASE [--dry-run]
```

`ORCA_MUSICBRAINZ_URL` and `ORCA_ACOUSTID_URL` point `match` and
`submit-acoustid` at other servers.

## Cover Art Archive

`Runtime.startReleaseCoverArtFetch(library, release_id)`, and a matching job
with `MatchRequest.cover_art`, fetch a Release's front cover from the Cover
Art Archive into the Library. Nothing is fetched for a Release one of whose
files carries a readable cover, and media files are never written. The
cover is stored in `release_artwork` ([database.md](database.md#release-artwork)),
and `libraryReleaseArtwork`, `libraryTrackArtwork` and the artwork loader
return it when no file of the Release has one: an embedded cover always
wins.

- **Release ID.** The Release's tagged MusicBrainz release ID; without one,
  the release ID most of its accepted matches name, a tie going to the
  lowest. Without either nothing is fetched, and the outcome is
  `no_release_id`: review the matches, then fetch again. The ID is checked
  to be a lowercase UUID before a URL is built from it.
- **The request.** `GET /release/{mbid}/front-500` through the gateway as the
  service `coverartarchive`: one request a second, the shared backoff and
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

`jobMatchStats(job).cover_art` reports the `CoverArtOutcome`: `embedded`,
`fetched`, `cached`, `cached_miss`, `not_found`, `no_release_id`, or, failing
the job, `refused`, `unavailable` or `busy`.

```sh
orca-cli match DATABASE --release=ID [--accept-min-score=SCORE] [--cover-art]
orca-cli cover-art DATABASE RELEASE_ID
orca-cli artwork DATABASE --release=ID --out=PATH
```

`ORCA_COVERARTARCHIVE_URL` points `match`, `cover-art` and `orca-gtk` at
another server.
