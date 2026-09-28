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

Right-clicking a track, an album (tile, cover or title), an artist (row or
avatar), a queue entry, or the playing track's cover in Now Playing and the
player bar opens a menu: Play, Play Next, Add to Queue, Edit Tags…, Show Album
and Show Artist, as far as they apply; queue entries offer Play and Remove.
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
and the output device. Scans, measurement, duplicate finding and tag writes
share the status card at the foot of the sidebar, one at a time. ReplayGain
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

The output menu ends with the **signal path**: the source format, then
ReplayGain, equalizer, crossfeed, volume and the output format as they apply,
and whether the path is bit-perfect, with the reasons when it is not. It comes
from `Runtime.playerSignalPath` and is read only when the menu opens and when
the track changes while it is open, never on the tick.

The **details panel** sits right of the Tracks list and of each album page.
The header toggle or `Ctrl+I` shows or hides every panel at once, and the
choice is saved as `[view] details`; it starts hidden and is hidden below the
760sp breakpoint. The Tracks panel shows the first selected track, otherwise
the playing one; an album page's panel shows the track last activated there,
otherwise the playing track when it belongs to the album. It is filled from
`Runtime.libraryTrackDetails` when the shown track changes and when the
library changes. The playing track also gets its signal path, read when the
track changes, never on the tick.

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

`nix build` installs `share/applications/org.orca_music.Orca.desktop` and the
icon, so the package can be installed like any desktop application.

## macOS SwiftUI

`apps/macos` is a Swift Package client of the installed C module. It keeps the
same bounded 256-row paging contract in a native SwiftUI `List`, exposes AppKit
menus and shortcuts, and mirrors authoritative Player snapshots through
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. It links against
`zig-out/lib/liborca` and does not import Zig, SQLite, codec, or audio layouts.
SwiftUI file import, URL drop handling, notifications, accessibility labels,
menus, and keyboard shortcuts remain presentation-only platform concerns.
