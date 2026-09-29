# Providers and listening history

Orca talks to online services only through `network.Gateway`, and the rules
below hold for every provider. ListenBrainz is the first one connected.
Other services follow the same rules; a request that breaks one is a defect,
not a tuning choice.

## Rules toward providers

- **Identification.** Every request carries a `User-Agent` of the form
  `Name/version ( contact )`. Orca's is
  `Orca/0.2.0-alpha ( evan@evanriley.com )`. The contact is the maintainer's
  email because the repository is private; it becomes the repository URL when
  the repository is public. A host embedding liborca replaces the name,
  version and contact with `Runtime.setClientIdentity`, and liborca's version
  is appended. Names and contacts are validated: empty, control characters and
  parentheses are refused.
- **Rate.** At most one request per second per service. The gateway honours
  `X-RateLimit-Remaining` and `X-RateLimit-Reset-In` when a response carries
  them, and waits out the window instead of sending into it.
- **429.** A `429` blocks every request to the service until the longer of
  its `Retry-After` or `X-RateLimit-Reset-In` and a backoff of 60 s, doubling
  per repeated refusal up to 1 h; the two are not added. One success resets
  the backoff.
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
- **Credentials.** The token is read from the host's secure storage through
  `CredentialStore` at the moment of a request. It is never written to the
  Library database, a log, a cache key or a settings file. `orca-gtk` uses the
  Secret Service through libsecret; `orca-cli` reads
  `ORCA_LISTENBRAINZ_TOKEN`.
- **Servers.** ListenBrainz-compatible servers are reachable with
  `Runtime.setListenBrainzServer`. `http` is accepted only for `127.0.0.1`,
  `[::1]` and `localhost`, so a token never crosses a network in clear text.

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
a later attempt time. A lease that outlives a crashed worker expires and is
reclaimed, and a result from a worker that lost its lease is discarded. Queue
states are pending, leased, delivered and rejected.

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

The status also carries the user name of the last validated token, the number
of pending listens, the number of love and hate changes waiting to be sent
(`feedback_pending`), the total delivered, the time of the next attempt and the
last error. A Library with no running worker reports both counts from its
database.

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
