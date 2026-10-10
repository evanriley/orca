# Discovery

This file covers how `library/discovery.zig` ranks Library Recordings
against a seed, the reasons it gives, the discovery settings, the Radio
preview, Library Radio on a Player and Daily Mixes
(`library/daily_mixes.zig`). Radio and Daily Mixes share this scoring.
Everything is computed from the Library database: no network, no providers.

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
pending picks and the entries queued after the playing entry, so the picks
follow it; an idle Player's whole queue is emptied. On an idle Player a
`track` seed is appended and plays at once; any other seed plays its first
pick when it arrives. The call reads the seed's title and returns; picks are
ranked on a worker thread.

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
last entry; `RadioStatus.continued` marks it. The condition is checked again
when the runtime starts the session, so a queue replaced, stopped or moved off
its last entry in between starts none. A continued session whose first top-up
finds nothing ends. Stopping Radio does not start one for the entry
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

## Daily Mixes

`library/daily_mixes.zig` makes up to six mixes a mix day from the Library's
listening history and stores them in `daily_mixes`, `daily_mix_artists` and
`daily_mix_entries` ([database.md](database.md)).

### Mix day

A mix day starts at 04:00 local time. The mix day of `now_s` at
`utc_offset_s` (seconds east of UTC) is
`floor((now_s + utc_offset_s - 4 h) / 1 day)`, counted from the Unix epoch;
before 04:00 it is still the previous day. The mix day the stored mixes were
made for is kept in the `mixes.generated_day` setting.

### Generation

`Runtime.startDailyMixes(library, .{ now_s, utc_offset_s, force })` starts a
`daily_mixes` Job ([control-plane.md](control-plane.md#jobs)). It runs in this
order:

1. `mixes.count` 0 clears the stored mixes and forgets the mix day.
2. Without `force`, stored mixes from this mix day or a later one are kept.
3. Fewer than 30 listens up to `now_s`, or listens on fewer than 3 local
   calendar days, clear the stored mixes and forget the mix day, so the next
   run checks again.
4. Otherwise the day's mixes replace the stored ones.

Another `mixes.count` takes effect at the next forced run or mix day.

Each outcome finishes the Job as succeeded; `libraryDailyMixes` reports the
resulting state. Every write replaces all stored rows in one transaction, so
a failed or cancelled run leaves the previous mixes intact. Frontends start
the Job when they start and when Home opens; liborca has no timer.

### Clusters

The 50 Artists with the most listens in the 30 days before `now_s` (a listen
counts for the Artist of its Recording's lowest-id Track) are grouped by each
Artist's most frequent first genre. Clusters are ordered by their listens,
then genre id. A cluster qualifies with at least 2 Artists, or with at least
40 candidates by its Artists. Qualifying clusters become genre mixes, named
after the genre, in cluster order.

A genre mix ranks candidates with the shared scoring core against a cluster
profile: the cluster's Artists at 1.0 and their related Artists, the genre
pinned at 1, and the years, audio features and co-listening of the Artists'
Tracks. Never-played Recordings are candidates whatever
`radio.include_unplayed` says. "Rarely played" ranks Recordings with plays
but none in the last 365 days by play count times 1 + jitter / 2.

### Theme mixes

A theme mix draws from one pool of the Library:

| Kind | Name | Pool |
|---|---|---|
| `decade` | the decade, as "1990s" | Tracks on Releases from the favorite decade |
| `new_to_you` | New to you | Tracks on Releases none of whose Tracks were played, by Artists with a listen in the last 90 days |
| `deep_cuts` | Deep cuts | Tracks played at most once by the 10 Artists most played in the last 90 days, as Home's deep cuts |
| `upbeat` | Upbeat | Tracks with an energy of 2/3 or more |
| `wind_down` | Wind down | Tracks with an energy below 1/3 |

The favorite decade is the decade with the most listens in the last 30 days
by the Release year of each listen's Recording; without such a listen it is
the decade with the most Tracks, and with no dated Release there is no decade
mix. Energy and its thirds are those of Radio's focus filters
([Candidates](#candidates)); a Track without audio features is never in
Upbeat or Wind down.

A theme qualifies when its pool holds at least 40 candidates after the
exclusions of [Filling a mix](#filling-a-mix) other than earlier mixes. Its
candidates, at most 2,000 in a seeded order, are ranked with the shared
scoring core against one profile of the day's 50 most-played Artists. Their
Tracks seed it, with their related Artists, and without an Artist pin.
Never-played Recordings are candidates whatever `radio.include_unplayed` says.

### Slots

With N = `mixes.count`:

1. "Rarely played" takes the last slot when it has candidates and N is more
   than 1.
2. When at least two other slots remain and any theme qualifies, one is kept
   for a theme mix.
3. Genre mixes fill the other slots.
4. Slots still empty take further qualifying themes.

Themes are taken in the order `decade`, `new_to_you`, `deep_cuts`, `upbeat`,
`wind_down`, starting at kind (mix day mod 5) and wrapping, skipping themes that
do not qualify; so the kept slot rotates daily. Mixes are stored genre mixes
first, then theme mixes, then "Rarely played". A Library with three genre
clusters and no rarely-played Recordings gets three genre mixes and three
theme mixes; one with many clusters and rarely-played Recordings gets four
genre mixes, one theme mix and "Rarely played". Cancellation is checked
before each mix.

The jitter seed is a hash of the mix day and the mix's position, so one mix
day always produces the same mixes from the same Library.

### Filling a mix

Each mix takes at most 25 entries and 90 minutes, best first. A pick that
would run past 90 minutes is passed over; an unknown duration counts as 0. A
pool with enough candidates reaches 60 minutes.

A genre mix aims for 15 favorites (loved, rated 80 or more, or 3 or more
plays with one in the last 180 days), 6 rarely played (1 or 2 plays, or none
in 180 days) and 4 never played. Each pick comes from the class furthest
below its target; a class with nothing left is filled from the next class
furthest below its target. Decade, Upbeat and Wind down mixes aim for the
same makeup. "Rarely played", "New to you" and "Deep cuts", whose candidates
are mostly of one class, take their candidates in order.

Left out of every mix:

- Recordings on live Releases, hated Recordings and Recordings marked Not for
  me;
- Recordings played within `discovery.avoid_days`, unless no candidate is left
  without them, as in Radio;
- Recordings an earlier mix of the day holds;
- picks that would break the Picking rules: no more than 2 consecutive by one
  Artist, no more than 2 from one Release in any 10. Mixes never relax them.

Each mix stores the counts left out by reason: `recent`, `not_for_me`,
`hated` and `live` over the Recordings of its Artists (for "Rarely played"
and theme mixes, of their pools; for Upbeat and Wind down, of the first 2,000
Recordings with audio features left out for any reason), each Recording under the first that applies;
`other_mix` and `diversity` over its ranked candidates.

### Stored data

Per mix: its position, kind (0 genre, 1 Rarely played, 2 decade, 3 New to
you, 4 Deep cuts, 5 Upbeat, 6 Wind down), genre id, decade (the first year,
such as 1990, for a decade mix), name, mix day, generation time, up to 4 top
Artists (by 30-day listens for a genre mix, by play count for the others),
the left-out counts, the makeup counts by
class, and `signals`: bit n is set when reason kind n names at least one of
its entries. Per entry: its position, Recording and `PickReason`, with the
kinds and numbering of [Reasons](#reasons); each reason is true of the
entry.

### Reading and feedback

- `libraryDailyMixes(library, now_s, utc_offset_s)` returns the state
  (`ready`, `not_enough_history`, `off`, `not_generated`), the generation
  time and mix day, and at most 6 mixes, each with its id, position, kind,
  name, genre id, up to 4 Artist ids and names (names at most 256 bytes),
  entry count and total duration, signals, left-out and makeup counts, and
  up to 4 Release ids for a cover mosaic.
- `libraryDailyMixEntries(library, mix_id, output)` returns at most 25
  entries of either kind in position order, each with the Recording's
  lowest-id Track with a present file, the Recording, the Track's duration
  and the reasons. `UnknownDailyMix` for an unknown mix.
- `libraryNotForMe(library, track_id, now_s)` marks the Track's Recording in
  `recommendation_feedback` until `now_s` + 90 days; marking it again
  restarts the 90 days. Radio leaves it out, and mix reads leave it out at
  once without deleting the entry, so
  `libraryClearNotForMe(library, track_id)` puts it back in place.
- `libraryResetRecommendations(library)` deletes every Not for me mark.
  Radio session feedback is not stored and is unaffected.
- `librarySaveDailyMix(library, mix_id, name)` creates a manual playlist
  holding the entries `libraryDailyMixEntries` returns, in order, and returns
  its id. Names follow `libraryCreatePlaylist`.

Entry counts, durations, entries and saved playlists leave out Recordings
with an unexpired Not for me mark and Recordings with no present file.

The C ABI counterparts are in [frontends.md](frontends.md#surface), and
`orca-cli mixes` lists and prints mixes ([cli.md](cli.md)).

## Home

The Home page numbers and lists come from bounded, read-only queries on the
Library's database, with no network. Each takes `now_s` and `utc_offset_s`.
A local day is `floor((t + utc_offset_s) / 86400)`; a week is the 7 local days
ending today, and the previous week the 7 before. A listen counts when it
started at or before `now_s`. Lists hold at most 24 items.

- Listening week: time listened is the sum of `listened_ms` per local day;
  plays, distinct Artists and Releases are counted over listens of the week,
  each listen resolved to the first Track of its Recording. The most played
  Artist and the previous week's time and plays accompany it.
- Recently played: Releases ordered by their latest play.
- Rediscover: Releases played at least 10 times and not in the last 180 days,
  most played first.
- Never played: Tracks whose Recording has no listen, newest added first.
- Deep cuts: Tracks played at most once by the 10 Artists most played in the
  last 90 days, unplayed first.
- Unplayed albums: Releases with at least one Track and no listen of any
  Track's Recording, at most one per album Artist (the Artist id when set,
  else the album artist text, ignoring case and surrounding spaces). A type
  naming an album sorts first, any other or no type next, and a type naming an
  EP or single last, matching whole words of `release_type` as the live check
  does. Within a type the order is a shuffle of the Release id and the local
  day number, so it holds for a day and changes on the next. An Artist is
  represented by its first Release in that order, so by an album when it has
  one.
- Release anniversaries: Releases with a full `YYYY-MM-DD` release date whose
  month and day fall within 3 days of the local today, dated in an earlier
  year than the anniversary's (a Release dated today or later never shows,
  nor does a date of a year or a month only). `years_ago` is counted against
  the anniversary's own year, so 1 January shows 29 to 31 December of earlier
  years. 29 February counts as 28 February in a year without one. Each carries
  its day offset from today, -3 to 3. Round anniversaries (a multiple of 5
  years) come first, then Releases by Artists with a listen, then the nearest
  to today, then the Release id.
- Top Artists: the most played Artists over the last N days.
- Formats: Tracks by the codec of their preferred file as FLAC, ALAC, MP3 or
  other; a Track with no preferred file is other, so the four sum to the Track
  count. Release and Track counts and the total duration come with it.
- On this day: the most played Release on this date a year ago (29 February
  maps to 28 February), Tracks added this local week (from Monday 00:00) and
  this local year, and the share of Tracks never played, rounded down to a
  whole percent.
- History age: the first listen, the distinct local days with listens, and
  whether listen recording is on.

All-time counts come from the stored play statistics and windowed counts from
the listens, as Radio and Daily Mixes read them. The C ABI counterparts are in
[frontends.md](frontends.md#surface) and `orca-cli home` prints every section
([cli.md](cli.md)).
