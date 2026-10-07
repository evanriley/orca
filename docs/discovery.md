# Discovery

This file covers how `library/discovery.zig` ranks Library Recordings
against a seed, the reasons it gives, the discovery settings, the Radio
preview and Library Radio on a Player. Radio and Daily Mixes share this scoring. Everything is computed from
the Library database: no network, no providers.

## Seeds and the seed profile

A seed is one of:

| Seed | Seed Tracks |
|---|---|
| `track` | that Track |
| `release` | the Release's Tracks |
| `artist` | the Artist's Tracks |
| `genre` | the Tracks tagged with the genre |
| `decade` | Tracks whose Release year falls in the decade, such as 1990 |
| `loved` | Tracks of loved Recordings |
| `recent` | the last 5 distinct Recordings in the last 50 listens |

At most 512 seed Tracks are read, most played first. The profile built from
them holds:

- Artists: the seed's own Artists at 1.0 for the `track`, `release`, `artist`
  and `recent` seeds; for the other seeds each Artist's share of seed Tracks
  relative to the largest. A `loved` seed adds the 64 most recently loved
  Artists at 1.0. The top 64 are kept.
- Related Artists: for the top 16 seed Artists, the related artists
  ListenBrainz reported (`artist_related`), each at `score / best × 0.8 ×` the
  seed Artist's weight, matched to Library Artists by MusicBrainz ID.
- Genres: each seed Track's first genre counts 1.0 and its others 0.5,
  normalised so the strongest is 1. A `genre` seed's genre is always 1. The
  top 32 are kept.
- Years: the decade for a `decade` seed, otherwise the 25th to 75th
  percentile of seed Release years.
- Sound: the median tempo, most common key and mean energy of the seed Tracks
  that have [audio features](analysis.md#audio-features).
- Co-listening: up to 2,000 listens of seed Recordings in the last 365 days,
  and for each the Recordings and Artists heard within the next 30 minutes.

## Candidates

A candidate is one Track per Recording: the lowest-id Track whose file has a
present location. These are never candidates:

- hated Recordings;
- Recordings marked Not for me whose `recommendation_feedback.expires_at` is
  after now;
- Recordings played within the avoid window (see
  [Settings](#settings)), unless nothing else qualifies, in which case
  `Picks.relaxed_recent` is true;
- live Releases, unless `include_live` is set: a release type containing
  `live`, or a title containing `(live`, `[live` or `live album`;
- the seed Track's Recording, and Recordings the session excludes.

Focus filters are hard filters: a genre, a decade, or the bottom or top third
of the Library's energy. Filters of one kind admit a Recording that matches
any of them; filters of different kinds must all match.

An SQL prefilter caps the pool at 2,000 Recordings, drawn in turn from: the
profile and related Artists (600), the 8 strongest profile genres (600), the
300 most co-listened Recordings (300), the 20 most co-listened Artists (200),
tempo within 10% of the seed's or of its
half or double (300), Release years within 5 of the seed range (200), and then
any eligible Recording. Each draw is ordered by a hash of the Recording and the
session seed, so the pool varies between sessions without favouring low ids.

## Scoring

Each candidate gets seven component values from 0 to 1. The total is their
weighted sum, plus any session adjustments for its Artist and genres.

| Component | Weight at explore 0 | Weight at explore 100 |
|---|---|---|
| Artist | 0.35 | 0.10 |
| Genre | 0.20 | 0.10 |
| Audio | 0.15 | 0.25 |
| Co-listening | 0.10 | 0.25 |
| Era | 0.08 | 0.05 |
| Taste | 0.07 | 0.10 |
| Jitter | 0.05 | 0.15 |

Weights move linearly with `explore`; the default is 35.

- Artist: 1.0 for a profile Artist at its profile weight, or its related
  weight.
- Genre: the mean of the profile weights of the candidate's genres, its first
  genre counting 1.0 and the others 0.5; a genre not in the profile counts 0.
- Audio: 0.4 tempo, 0.2 key and 0.4 energy. Tempo is
  `1 − min over r ∈ {½, 1, 2} of |log2(a / (r·b))| / log2(1.25)`, floored at
  0, so half and double time match. Key is 1 when equal, 0.7 for the relative
  key or a fifth apart, otherwise 0. Energy is `1 − |Δ|` of the Library
  percentile. A part missing on either side drops out and the rest are
  renormalised; a candidate without features scores 0.3. When the seed has no
  features, the Audio weight is spread over the other components.
- Co-listening: the share of seed listens followed within 30 minutes by this
  Recording or its Artist.
- Era: `max(0, 1 − distance / 15)` from the seed's year range; 0.3 when either
  year is unknown.
- Taste: 0.5 when loved, plus rating / 200, plus 0.2 when its Release or
  Artist is loved, capped at 1.
- Jitter: a hash of the Recording id and the session seed.

The same seed, options, session seed and `now` rank the same Library the same
way.

## Picking

Candidates are taken best first, subject to:

- no more than 2 consecutive picks by one Artist;
- no more than 2 picks from one Release in any 10;
- when unplayed Recordings are allowed, at most 1 never-played pick in any 4;
  otherwise none.

When no candidate satisfies the Release rule it is relaxed first, then the
Artist rule. The unplayed rule holds while any played candidate remains; once
none does, never-played candidates fill the rest, under the Release and Artist
rules again, so a Library with little history still returns as many picks as
asked for. When unplayed Recordings are not allowed they are never picked.

## Reasons

Each pick carries up to two `ReasonPart`s, each a kind and two integers. The
kind numbers are stored in `daily_mix_entries` and never change.

| Kind | Value | Arguments |
|---|---|---|
| `played` | 0 | a: play count, b: last played, Unix seconds |
| `loved` | 1 | |
| `same_artist` | 2 | a: Artist |
| `related_artist` | 3 | a: seed Artist, b: the pick's Artist |
| `shared_genre` | 4 | a: genre |
| `often_after` | 5 | a: Recording (b = 0) or Artist (b = 1) |
| `similar_sound` | 6 | a: flags, 1 tempo, 2 key, 4 energy |
| `never_played` | 7 | |
| `rarely_played` | 8 | a: play count |
| `added` | 9 | a: when added, Unix seconds |

Reasons come from the components that contributed most, by weight times
value, and each is true of the pick:

- `same_artist` only for the seed's own Artists; `related_artist` names the
  seed Artist ListenBrainz related it to.
- `shared_genre` names the genre the pick and the profile share with the
  highest profile weight.
- `often_after` needs at least two distinct seed listens followed by the
  pick: an Artist for an `artist` seed, otherwise the seed Recording it
  followed most.
- `similar_sound` sets tempo at a sub-score of at least 0.7, key at 0.7 and
  energy at 0.85, and appears only when the pick has features.
- `loved` only for a loved Recording.

A remaining slot gets a history fact: `never_played`, `rarely_played` for 1 or
2 plays, or `played` for 3 or more; then `added` when the Track was added in
the last 60 days. Reasons that credit a featured artist are never produced.

## Settings

Stored in `library_settings`:

| Key | Values | Default |
|---|---|---|
| `radio.continue` | 0, 1 | 1 |
| `radio.include_unplayed` | 0, 1 | 1 |
| `discovery.avoid_days` | 0, 1, 3, 7 | 3 |
| `mixes.count` | 0, 4, 6 | 6 |

A stored value outside its set reads as the default.
`RadioOptions.include_unplayed` and `avoid_recent` default to these settings;
`avoid_recent = true` with `discovery.avoid_days` 0 avoids the last 3 days.

## Radio preview

`Runtime.libraryRadioPreview` ranks up to 512 picks for a seed without a
Player, with each pick's Track, Recording, Artist, Release, total score,
component values and reasons, and the weights used. A preview session fixes
`now` and the session seed; left out, they come from the clock. The C ABI
counterpart is `orca_library_radio_preview`, and `orca-cli radio` prints a
preview ([cli.md](cli.md)).

The scoring core also takes a `Session`: up to 4,096 excluded Recordings, up
to 256 Artist and 256 genre score adjustments, and up to 16 recent picks,
which the diversity and unplayed rules continue from. A larger session fails
with `RadioSessionTooLarge`.

## Library Radio

`core/runtime_radio.zig` runs a Radio session on a Player. A Player has at
most one session, and it is never saved.

### Starting

`playerStartRadio(player, library, seed, options)` needs a Player bound to
`library` and replaces any session the Player had, removing that session's
pending picks. The playing entry and the user's queued entries stay. On an
idle Player a `track` seed is appended and plays at once; any other seed plays
its first pick when it arrives. The call reads the seed's title and returns;
picks are ranked on a worker thread.

### Picks and top-ups

The session keeps 8 picks pending: picks after the playing entry. Each top-up
runs the scoring core with the session's options and state on a reader
connection and appends what it ranked to the queue. The sampling pass, at most
every 100 ms from `pump`, notes a session with fewer than 8 pending and the
same pump starts a top-up; it reads no SQLite and allocates nothing. A
finished worker wakes the host and the next pump applies its picks on the
control lane. Each top-up carries the session's generation, and one that
finished after the options or feedback changed is discarded and run again. A
top-up that failed is retried after one second.

The session excludes every Recording it has picked, up to the latest 3,072,
so a pick never recurs in a session, and passes its last 16 picks to the
diversity and unplayed rules. Each pick is tracked by its queue entry id,
which stays the same across moves, inserts, removals and shuffle; at most 64
picks are tracked, from the playing one on.

| State | When |
|---|---|
| `active` | top-ups run |
| `paused_by_repeat` | repeat is on; nothing is added until it is off |
| `exhausted` | the last top-up found nothing under the options and feedback; new options or undo clear it |
| `full` | the queue holds `playback_queue.capacity` entries |

### Editing the queue during Radio

- An enqueue lands before the first pick the engine has not committed to, so
  the user's entries play before Radio's. Insert next is unchanged. Both count
  as `user_queued`.
- Moves and removals keep each pick's entry id; status reports where the
  picks are now. A pick removed by the user is no longer tracked.
- Turning shuffle on or off removes the pending picks and picks again.
- The engine commits to the entry after the playing one once it decodes ahead
  into it or opens it as the next source. That entry is never removed by
  Radio.

### Options and feedback

`playerSetRadioOptions` removes the pending picks the engine has not
committed to, lets their Recordings be picked again, and picks under the new
options.

`playerRadioLessLikeThis(player, entry_id)` removes the pick, skipping to the
next entry when it is playing, and for the rest of the session excludes its
Recording and adjusts its Artist by −0.5 and its first genre by −0.25. A pick
already committed to as next is refused with `error.QueueEntryInUse`.

A pick left by `playerNext` or `playerQueueJump` within 30 seconds of its
start is a skip: its Recording is excluded and its Artist adjusted by −0.25.
One left later, or one that finished, is not.

`playerRadioUndoFeedback` forgets the exclusions and adjustments that "less
like this" and skips made, and zeroes their counts. Removed entries stay
removed. The session holds at most 1,024 such exclusions and 256 adjustments
each for Artists and genres.

### Ending

`playerStopRadio` removes the pending picks the engine has not committed to
and ends the session. Playing other Tracks in place of the queue, clearing it,
restoring saved state, loading a file, binding another Library, closing the
Library and destroying the Player end the session and leave the queue as those
calls leave it. A top-up in flight is joined.

### Continuing

With `radio.continue` on, repeat off and no session, a Player playing the last
entry of its queue starts a `recent` session with the default options once per
last entry; `RadioStatus.continued` marks it. A continued session whose first
top-up finds nothing ends. Stopping Radio does not start one for the entry
playing then.

### Status

`playerRadio` returns a `RadioStatus` with the seed, its title (the Track or
Release title, Artist or genre name, at most 256 bytes; empty for `decade`,
`loved` and `recent`), the options, the state, the counts of picks added,
user-queued entries, "less like this" and skips, and the pending count.
`playerRadioPicks` reports up to 32 `RadioQueuePick`s from the playing one on,
in playback order, each with its entry id, position, Track, Recording and
reasons. The C ABI counterparts are in
[frontends.md](frontends.md#surface).
