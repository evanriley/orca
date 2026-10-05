# Privacy

What Orca sends to outside services, when, and what identifies you. The rules
that govern every request (identification, pacing, back-off, credentials) are
in [providers.md](providers.md).

## Summary

- Orca sends nothing anywhere else: no telemetry, no crash reports, no update
  checks, no analytics.
- Every outbound request goes through one gateway, `network.Gateway`, to one
  of the services below. [How this was checked](#how-this-was-checked) says
  how.
- Your music files and paths never leave your machine. What leaves is tag
  text, MusicBrainz IDs, audio fingerprints, durations and listen records, as
  listed per service.
- A request needs an action you take or a feature you switch on. The sections
  below name them, and the defaults in `orca-gtk`.
- What the services return is kept in the Library database on your machine.

## What identifies you

- Every request carries one `User-Agent` of the form `Name/version ( contact )`.
  The contact is the one the build was given with `-Dprovider-contact`, so it
  names the project that built Orca, not you. Nothing about your machine, user
  name or Library is in it.
- A ListenBrainz token identifies your ListenBrainz account. It is sent only to
  the ListenBrainz server, and only when you have configured one.
- An AcoustID user key identifies your AcoustID account. It is sent only to the
  AcoustID server, and only when you submit fingerprints.
- AcoustID also receives the application key of the build, which identifies
  Orca, not you.
- Each service you contact sees your IP address, as with any web request.
- Orca reads a token or key from your secure storage at the moment of a
  request. `orca-gtk` uses the Secret Service. `orca-cli` reads
  `ORCA_LISTENBRAINZ_TOKEN` and `ORCA_ACOUSTID_USER_KEY` from the environment.

## Services

### ListenBrainz

Server: `api.listenbrainz.org`. Scrobbling, love and hate marks, and artist
info.

- Submit listens. Opt-in: `orca-gtk` Settings, Listening, Submit listens, off
  by default; `orca-cli scrobble`. A listen is sent after it counts, once it
  meets ListenBrainz's rule. A listen recorded while submitting was off is
  never sent later.
- Sent per listen: artist, title and album text, the start time, the length,
  the MusicBrainz recording, release and artist IDs and the track number when
  the tags have them, and the client name and version. Your token goes in the
  `Authorization` header.
- Validate the token. Sent when you set or change the token, with the token.
- Now Playing. Opt-in, off by default (Send now playing, which needs Submit
  listens). The same fields as a listen, without a start time, for the track
  playing once it has been heard briefly.
- Love and hate. Sent while submitting is on, for a song that has a MusicBrainz
  recording ID: the recording ID and a score for love, hate or cleared, with
  your token.
- Artist popularity. Part of
  [artist and release info](#artist-and-release-info):
  a POST of the artist's MusicBrainz ID. No token is sent.

### ListenBrainz Labs

Server: `labs.api.listenbrainz.org`. Part of
[artist and release info](#artist-and-release-info): a GET of the artist's
MusicBrainz ID to find similar artists. No token is sent.

### MusicBrainz

Server: `musicbrainz.org`. Matching, artist and release info, and genres.

- Match search. You start it: Match in `orca-gtk`, Match Album, a Track's
  Match, a Health action, or `orca-cli match`. For each Track without a
  recording ID, a search with its title, artist and, when known, its album.
- Release lookup. During matching, verification and Match Album: the
  MusicBrainz release ID of a candidate.
- Artist and release info: MusicBrainz artist, area, release and release-group
  IDs.
- Genres. On by default and part of artist and release info
  (`orca-cli genre-fill` turns it off; `orca-cli genres
  --fill-from-musicbrainz` runs it on request). It uses the same lookups.

### AcoustID

Server: `api.acoustid.org`.

- Fingerprint lookup. You start it with the matching and verification actions
  above, and only while Match by audio fingerprint is on (the default in
  `orca-gtk`; `orca-cli match --no-fingerprints` turns it off). Sent: the
  application key, the version, the file's length in seconds and a Chromaprint
  fingerprint of the first two minutes of its audio. The audio itself is not
  sent.
- Idle maintenance. Off by default; in `orca-gtk` it also needs fingerprint
  matching. While nothing plays, it verifies one album at a time in the
  background with the same lookups, and the MusicBrainz release lookups they
  lead to.
- Submission. You start it with the AcoustID submission action or
  `orca-cli submit-acoustid`. It sends the fingerprints of files whose
  recording ID you chose, so others can find them. Sent: the application key,
  your AcoustID user key, the length, the fingerprint, the file format and
  bitrate, and either the recording ID or, when the file's length differs much
  from the recording's, the title, artist, album, album artist, track and disc
  numbers and year. It fails without your user key and sends nothing.

### Cover Art Archive and archive.org

Servers: `coverartarchive.org`, which redirects to `archive.org` hosts.

- Cover for a release. You start it: Match Album, a fetch-cover action, or
  `orca-cli cover-art`. Sent: the release's MusicBrainz ID. Nothing is fetched
  when a cover is already chosen, embedded or in the folder.
- Cover candidates. You start it from Artwork Review: the release and release
  group IDs, then the IDs of the images listed.
- Release-group covers, part of
  [artist and release info](#artist-and-release-info): release-group IDs.
- A redirect is followed only to `https` on `archive.org`, and the redirected
  request carries only the `User-Agent`.

### LRCLIB

Server: `lrclib.net`. Lyrics.

- Opt-in, off by default: `orca-gtk` Settings, Listening, Fetch lyrics from
  LRCLIB; `orca-cli lyrics --fetch`. It looks up a Track whose files have no
  synced lyrics when its lyrics are shown.
- Sent: the Track's title, artist, album and length in whole seconds. No IDs,
  path, token or other Library content. A Track with no title or artist is not
  looked up.

### Wikidata, Wikimedia Commons and Wikipedia

Servers: `www.wikidata.org`, `commons.wikimedia.org` with its image host on
`wikimedia.org`, and `{language}.wikipedia.org`, English unless the host asks
for another language.

- Part of [artist and release info](#artist-and-release-info). What is sent is
  an ID or title a previous service returned: a Wikidata item ID, a Commons
  file name, a Wikipedia article title, and the language. No tag text, path or
  Library content.

### Artist and release info

A job that gathers an artist's photo, biography, years active, links, related
artists and release groups, and an album's description.

- `orca-gtk` starts it when you open an artist page, unless Settings,
  Listening, Fetch artist info is off (on by default), and when you open an
  album page, which has no setting. It starts nothing for an artist or release
  with no MusicBrainz ID in the Library. `orca-cli artist-info --fetch` and
  `release-info --fetch` start it by command.
- It contacts MusicBrainz, Wikidata, Wikimedia Commons, Wikipedia, ListenBrainz
  (popularity), ListenBrainz Labs (similar artists) and the Cover Art Archive
  (release-group covers); [providers.md](providers.md#artist-info) gives the
  order.
- What is sent is MusicBrainz IDs of the artist, its related artists, areas,
  releases and release groups, and the IDs and titles those services returned.
  No tag text, path or Library content. The answers are kept in the Library
  database and reused.
- An offline option makes no request and uses what is kept.

## Pages opened in your browser

`orca-gtk` has links to `musicbrainz.org`, `wikipedia.org`, `acoustid.org` and
`listenbrainz.org`. Following one opens it in your desktop's browser. That is
your browser's request, not Orca's. The address of some of them carries a
MusicBrainz ID.

## Other servers

A host can point each service at another server, such as a mirror or your own
ListenBrainz-compatible server. `orca-cli` reads `ORCA_LISTENBRAINZ_URL`,
`ORCA_MUSICBRAINZ_URL`, `ORCA_ACOUSTID_URL`, `ORCA_COVERARTARCHIVE_URL`,
`ORCA_LRCLIB_URL`, `ORCA_WIKIDATA_URL`, `ORCA_WIKIMEDIA_URL`,
`ORCA_WIKIPEDIA_URL` and `ORCA_LISTENBRAINZ_LABS_URL`. A server address must
use `https`, or `http` to the local machine only, so a token or Library
content never crosses a network in clear text. Your token goes to whichever
ListenBrainz server is set.

## Sending less

- Leave the opt-in features off: Submit listens, Send now playing, Fetch
  lyrics from LRCLIB and Idle maintenance.
- Turn off Fetch artist info and Match by audio fingerprint in Settings, and
  do not start matching, cover or AcoustID actions.
- `orca-cli` makes requests only for the commands that name a service:
  `match`, `scrobble`, `lyrics --fetch`, `artist-info --fetch`,
  `release-info --fetch`, `cover-art`, `genres --fill-from-musicbrainz`,
  `submit-acoustid`, and `watch --maintenance`.

## How this was checked

- The only HTTP client in the tree is `std.http.Client`, held by the gateway's
  standard transport in `liborca/network/client.zig`. The transport is called
  only from the gateway's request and redirect methods.
- That transport is built only by the listen worker and the job worker, each
  wrapping it in a gateway. No provider holds a transport of its own.
- Searches of `liborca`, `apps`, `build`, `build.zig` and `examples` find no
  other use of `std.http`, no `std.Io.net` connection outside tests (the other
  uses parse host names), and no C socket, `getaddrinfo` or `curl` call. The C
  sources' only connections are PipeWire's local ones.
- The apps' only other external addresses are the browser links above.
- No telemetry, crash-reporting or update-check client exists in the source.
