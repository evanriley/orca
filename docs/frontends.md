# Native frontend boundary

First-party graphical applications are thin clients of `liborca`. They own
windows, widgets, accessibility presentation, and native event loops; library,
transport, metadata, and mutation semantics remain in the core.

## C ABI

`liborca/orca.h` exposes opaque runtime ownership, typed generational handles,
POD snapshots, and bounded callback-scoped query views. Both static and shared
libraries install with the header. Returned string views are valid only during
their callback, so no SQLite row or Zig container crosses the ABI. Every page is
bounded to 512 rows.

**Threading is a contract, not a convention.** All `orca_*` calls for one
runtime come from a single thread, `orca_runtime_poll_event` included, which is
single-consumer. Debug builds record the creating thread and return
`ORCA_STATUS_WRONG_THREAD` on a violation. The runtime behind the boundary is
genuinely multithreaded — a decode engine per Player, a registered worker per
scan — and its object pools take no lock, so a GUI timer racing
`orca_runtime_destroy` is a real use-after-free.

The boundary covers the whole engine, not a fragment of it:

- **Library and roots.** Open/close, bounded track and health pages, root
  add/remove/query.
- **Jobs.** `orca_library_start_scan` registers a background worker and returns
  immediately; `orca_job_snapshot_get`, `orca_job_cancel` and
  `orca_library_scan_stats` observe it. Scan progress is a count of files
  processed with `has_total = 0` — a walk has no honest denominator until it has
  finished. A scan projects as it commits;
  `orca_library_start_projection` reprojects without a walk.
- **Events.** `orca_runtime_pump` drives the control lane and
  `orca_runtime_poll_event` drains the lossless completion channel and the
  coalescing telemetry channel into a tagged POD with a named `extern union`
  payload. Events are hints and correlations; authoritative consumers read
  snapshots.
- **Transport and queue.** Play by Track id, enqueue, next/previous, clear,
  repeat, shuffle, volume, `seek_ms`, paged queue listing, and
  `orca_player_status`, which carries transport, epoch, position, duration,
  track, queue position and volume in one lock-free read. Position comes from
  the packed epoch+frames atomic the render callback writes; now-playing reports
  the audible entry, never the decode cursor.
- **Devices and Zones.** Enumeration, Zone create/attach/open/close/status, and
  `orca_player_open_default_output`, which creates, attaches and opens in one
  call so a single-output frontend never has to know Zones exist.

`orca_player_play` is refused unless the Player has a loaded source or a
non-empty queue *and* an attached Zone: a transport that reports PLAYING while
nothing renders is a defect, not a state.

## Linux GTK4

`orca-gtk` is a Zig client of liborca's public Zig API, built on GTK 4 and
libadwaita, both bound by hand in `apps/linux/gtk.zig` and `apps/linux/adw.zig`.
Every liborca call happens on the GTK main thread, from a signal handler or the
100 ms tick.

```sh
zig build run-linux                                   # library in $XDG_DATA_HOME/orca
ORCA_LIBRARY=/path/to/library.db zig build run-linux  # another library
```

The window is an `AdwNavigationSplitView`:

- The sidebar (`AdwSidebar`) lists the pages, shows the queue length, and
  shows scan progress at its foot while a scan runs.
- **Albums** is a grid of covers, paged 512 Releases at a time and sorted by
  artist, title, year or recently added. An album without a cover shows its
  initials on a colour chosen from its title. Activating one opens its page:
  the cover, title, artist, year, length, Play and Shuffle, and its tracks by
  disc.
- **Artists** is every Artist with an initials avatar, searchable. An artist
  opens a page with their first album's cover as an avatar, Play and Shuffle,
  and their albums; an album there opens its page in place.
- **Tracks** is the track list, with the Artist and Album browse panes behind
  the header's toggle. The
  list pages 512 rows at a time from liborca as it scrolls, and a header
  click re-queries in the engine's order rather than sorting loaded rows. The
  playing track is marked. A library with no tracks shows a welcome page with
  Add Music Folder; a scan in progress shows there too.
- **Now Playing** is the audible track's cover, large, on a wash of the
  cover's average colour, with the next five entries. Clicking the cover in
  the player bar opens it.
- **Queue** is the Player's queue as the engine resolves it, with thumbnails
  and the audible entry marked. Clicking an entry plays it; the button at the
  end of a row removes it.

- **Health** lists what liborca found wrong with the library, with a count in
  the sidebar and a Find Duplicates button.
- **Matches** lists the songs with MusicBrainz or AcoustID proposals
  awaiting review (`libraryMatchReviewPage`), with their count in the
  sidebar. Each row shows the song's own title, artist, album and length and
  its best proposal's score; expanding it lists every proposal with its
  source (MusicBrainz, AcoustID or MusicBrainz + AcoustID) and AcoustID's
  fingerprint score when there is one, Accept, Dismiss and a MusicBrainz
  button that opens the recording's page in the browser. An AcoustID
  proposal without a title reads Unknown title. A proposal more than 10 s
  longer or shorter than the song shows its length in the warning colour.
  Find Matches starts the matching job, which shares the status card and,
  unless Match by audio fingerprint is off in Preferences, also asks
  AcoustID by fingerprint with the application key the app sets at startup.
  Accept Confident asks first, then accepts each song's only proposal at or
  above the threshold set in Preferences (90% by default,
  `[matching] accept_confidence` in `settings.ini`). With nothing to review
  the page offers Find Matches, or says every song has a recording ID.

  Submit to AcoustID (N) appears when an AcoustID key is saved and
  `libraryAcoustIdSubmittableCount` is above zero. It asks first, then runs
  `startAcoustIdSubmission` as a job on the status card, and the count is
  read again when it finishes. A missing or refused key, or an unreachable
  AcoustID, is reported in a toast; nothing is marked sent.

Right-clicking a track, an album (tile, cover or title), an artist (row or
avatar), a queue entry, or the playing track's cover in Now Playing and the
player bar opens a menu: Play, Play Next, Add to Queue, Love, Dislike, Edit
Tags…, Show Album and Show Artist, as far as they apply; queue entries offer
Play and Remove. A song with no feedback offers Love and Dislike; a loved one
offers Remove Love, a disliked one Remove Dislike. On a selection the entries
apply to every selected song.
The playing track is marked across its whole row in the track list, on album
pages and in the queue.

Back (the mouse back button, or Alt+←) leaves an album or artist page first,
then returns to the page shown before, across the sidebar's pages: Albums, an
album, Now Playing, then Back returns to that album. On a selected row in the track list it acts on the
whole selection. Play Next and Remove go through `Runtime.playerQueueInsertNext`
and `playerQueueRemove`, so an entry the engine has already lined up is never
pulled out from under the output.
- The player bar spans the window: cover, title and artist; shuffle, previous,
  play, next and repeat; the seek bar; volume, the output menu and the queue.
  A heart beside the title loves the audible song and, pressed again, removes
  the love; it is read when the audible song changes and after any change.

**Love and dislike** are kept by liborca per recording (`librarySetFeedback`).
Every song row ends its title with a heart button: the Tracks list, album
pages, the queue, and the Now Playing page for the audible song and the songs
up next. A loved song shows a filled red heart; any other song shows an outline
heart, dimmed until the row is hovered or selected. Pressing the button loves
the song, or removes the love, and a disliked song becomes loved. The button
does not play the song or change the selection. The player bar's heart does the
same for the audible song. Disliked songs have no marker on their row, and the
details panel's Feedback row says Loved, Disliked or None. A song without a
MusicBrainz recording ID is saved on this computer only, and the Feedback row
says it won't sync to ListenBrainz.

The details panel's **MusicBrainz** section shows the recording ID in effect
and where it came from (From tags, Matched or Set by you), with a MusicBrainz
button. A song without one shows its top three proposals with Accept and
Dismiss, each naming its source and AcoustID score in its tooltip, and Review all when there are more, which opens the Matches page at
that song; with no proposals it offers Find Match, which searches for that
song alone. A change made in one place repaints the others, by recording and
without a query per row: rows carry `TrackSummary.recording_id` and `feedback`,
and only those whose recording changed are replaced. The list factories connect
each button once, in setup, and read the row's song when the button is pressed.

Below 760sp the sidebar collapses behind a back button, the browse panes hide
and the player bar tightens. Messages are toasts. Shortcuts are listed in the
shortcuts dialog (Ctrl+?); Space and Ctrl+←/→ are handled by a bubble-phase key
controller rather than application accelerators, so a focused search box keeps
them.

**Edit Tags** edits one track or many; a field the selection disagrees on is
marked mixed and left alone unless filled in, and clearing a field returns it
to what the file says. Save changes the library only. Save and Write to Files
plans the write with `Runtime.planTagWrite`, shows each file's changes and any
files skipped, and runs the approved plan as a job; the toast when it finishes
offers Undo (`undoTagWrite`). `libraryEditTracks` returns the Tracks the edited
files back afterwards, because an edit that moves a track to another album
gives it a new id.

**Preferences** (Ctrl+,) lists the library's folders with Add, Remove and
Rescan, starts loudness measurement and duplicate finding, and sets ReplayGain
and the output device. Scans, measurement, duplicate finding, tag writes,
matching and AcoustID submission share the status card at the foot of the
sidebar, one at a time. ReplayGain
and the output device (by name, since device ids are renumbered between runs)
are saved in `$XDG_CONFIG_HOME/orca/settings.ini`, along with the sound
settings below. Removing a folder asks first, then forgets its tracks; the
files on disk are not touched, and it is refused while a job is running.

The **Sound** page drives the Player's DSP chain through
`Runtime.playerSetEqualizer` and `playerSetCrossfeed`. The equalizer has ten
bands from -12 to +12 dB, a preamp and presets (Flat, Bass, Treble, Vocal,
Loudness); a curve that matches no preset reads Custom, and switching the
equalizer off and on restores the last curve. Crossfeed has three amounts.
Slider drags are coalesced into one apply about 60 ms after the last move,
because applying pauses the engine briefly. Both are saved in `[sound]`
(`equalizer=G1,...,G10:PREAMP`, `equalizer_enabled=true|false`,
`crossfeed=AMOUNT`, `crossfeed_enabled=true|false`), so the curve and amount
survive while the effect is off, and applied at launch when enabled. A file
that predates the `*_enabled` keys and holds `off` leaves the effect off with
the default curve or amount.

The Library page's **AcoustID** group holds Match by audio fingerprint, on
by default, which is `MatchRequest.fingerprints` for Find Matches and Find
Match and is saved as `[matching] fingerprints=true|false`. Below it, the
user's AcoustID key has the same password row, Save, stored row, Remove and
Unlock as the ListenBrainz token below, stored under
`acoustid_credential_service` / `acoustid_user_key_account`. Its stored
state is found without unlocking the keyring, so opening Preferences never
prompts; a locked keyring reads "Keyring locked" until Unlock is chosen.
Get a key opens AcoustID's API key page in the browser. The Matches page
finds whether a key is saved the same way at startup, and again after each
save and remove.

The **Listening** page holds the ListenBrainz settings. Submit listens calls
`Runtime.librarySetScrobbling`. The user token is a password row with a Save
button, enabled while the field has text; Enter in the field saves too. It is
stored in the Secret Service through libsecret (`apps/linux/secret.zig`) and
never in `settings.ini` or the Library. Saving clears the field and calls
`libraryScrobblerCredentialsChanged`. When a token is stored, a row above the
field reads "Saved in your keyring" with a Remove button, and the field is
titled Replace token; Remove deletes the token and calls
`libraryScrobblerCredentialsChanged`. The stored state is found when the page
is first shown, and again after each save and remove, by an asynchronous search
that reads no secret; it may prompt to unlock the keyring. A keyring that stays
locked reads "Keyring locked", with an Unlock button that searches again.
Saving, removing and searching are asynchronous, so a prompt cannot freeze the
window.
The status row is rewritten from `libraryScrobblerStatus` on the tick while
Preferences is open: connected with the user name and the number of listens
waiting and, when there are any, the loves and dislikes waiting to sync, token
rejected, waiting after a rate limit or outage, offline, or not connected.
Listens are always recorded locally; the page says so. Show what I'm playing
now is the Now Playing argument of `librarySetScrobbling`; it is off by default
and insensitive while Submit listens is off. `[listening]
scrobble=true|false` and `now_playing=true|false` are saved and re-applied at
launch. `ORCA_LISTENBRAINZ_URL` selects another server, for a self-hosted
instance or a local mock; `ORCA_MUSICBRAINZ_URL` and `ORCA_ACOUSTID_URL` do
the same for matching and submission.

The output menu ends with the **signal path**: the source format, then
ReplayGain, equalizer, crossfeed, volume and the output format as they apply,
and whether the path is bit-perfect, with the reasons when it is not. It comes
from `Runtime.playerSignalPath` and is read only when the menu opens and when
the track changes while it is open, never on the tick.

The **details panel** sits right of the Tracks list and of each album page.
The header toggle or `Ctrl+I` shows or hides every panel at once, and the
choice is saved as `[view] details`; it starts hidden and is hidden below the
760sp breakpoint. The Tracks panel shows the first selected track, otherwise
the playing one; an album page's panel shows its selected track, otherwise the
playing track when it belongs to the album. On an album page a click or the
arrow keys select a row, one per page, and double-click or Enter plays from
it. The panel is filled from `Runtime.libraryTrackDetails` when the shown
track changes and when the library changes. The playing track also gets its
signal path, read when the track changes, never on the tick. A History
section shows the play count and last play (local time), and is read again
whenever `Runtime.libraryListensRecorded` reports a newly recorded listen.

The output is opened on first play, not at launch. `ORCA_OUTPUT_DEVICE` pins it
to an orca device id, overriding the output menu; see
[Testing playback without making noise](../CLAUDE.md).

Covers go through `apps/linux/art.zig`. A widget asks for a cover while it is
bound and forgets it when unbound; the frontend asks liborca's artwork loader
(`Runtime.libraryRequestArtwork`) and collects results on its tick, then
decodes each on a GTask thread through `gdk_pixbuf_new_from_stream_at_scale` at
one of three sizes (128, 400 or 960 pixels), so an 11 MiB JPEG never
materializes at full resolution and never decodes on the main thread. Up to
600 decoded covers are kept, least recently used first out; a request for a
widget that scrolled away is cancelled before liborca reads a file. The app
allocates from `std.heap.smp_allocator`: covers are freed as they are
replaced, which an arena would never do.

The frontend owns `org.mpris.MediaPlayer2.orca` on the session bus when one is
available. MPRIS methods invoke the same Player handle, and `PlaybackStatus` is
read from and signaled from authoritative snapshots.

`nix build` installs `share/applications/org.orca_music.Orca.desktop`, the
icon and the two heart icons, so the package can be installed like any desktop
application. The heart icons resolve through the icon theme, so `zig build
run-linux` installs first and puts `zig-out/share` on `XDG_DATA_DIRS`; running
`zig-out/bin/orca-gtk` directly needs that variable set the same way.

## Listening from a host

A host that wants listening history and scrobbling calls, on the Zig API:

- `Runtime.setCredentialStore` with a `CredentialStore` over the platform's
  secure storage. `get` receives the service and account
  (`listenbrainz_token_service`, `listenbrainz_token_account`) and returns an
  owned copy of the token, or null. It is called on a listen worker's thread,
  never the caller's, so the store must be safe to call from there. It must
  never prompt or block on user interaction: a locked keyring reads as no
  token, and the worker's shutdown waits for the call to return. `orca-gtk`
  searches the Secret Service without unlocking it; only saving, removing or
  looking up the token from Preferences, on the main loop, may show an unlock
  prompt.
- `Runtime.setClientIdentity` to name the host in submissions and in the
  history. The default is Orca's.
- `Runtime.setListenBrainzServer` only to select a self-hosted or compatible
  server.
- `Runtime.librarySetScrobbling` (its last argument turns Now Playing on),
  `libraryScrobblerCredentialsChanged` after the token changes, and
  `libraryScrobblerStatus` for presentation.
- `Runtime.librarySetFeedback` and `libraryTrackFeedback` for love and hate,
  which `TrackSummary.feedback` and `TrackDetails.feedback` also report.
  `orca-gtk` repaints the heart, the rows and the details panel after each
  change rather than waiting for a reload.

The identity, the store's context and the server string are borrowed and must
outlive the runtime. The setters may be called at any time and reach each
listen worker on its next pass; a host that sets them before binding a Player
to a Library avoids a first pass with the defaults. Listens are sampled inside
`processNextCommand`, so a host pumps it as it already does. The C ABI does not
expose listening yet. [providers.md](providers.md) describes what a listen is
and what is sent.

## macOS SwiftUI

`apps/macos` is a Swift Package client of the installed C module. It keeps the
same bounded 256-row paging contract in a native SwiftUI `List`, exposes AppKit
menus and shortcuts, and mirrors authoritative Player snapshots through
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. It links against
`zig-out/lib/liborca` and does not import Zig, SQLite, codec, or audio layouts.
SwiftUI file import, URL drop handling, notifications, accessibility labels,
menus, and keyboard shortcuts remain presentation-only platform concerns.
