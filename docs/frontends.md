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

`orca-gtk` consumes only the installed C boundary. Its `GtkListView` renders a
bounded 256-row page, with explicit next/previous paging and bounded search
queries, so a large library never becomes a giant frontend-owned model. Set
`ORCA_LIBRARY` to an Orca SQLite library path before launching:

```sh
ORCA_LIBRARY=/path/to/library.db zig build run-linux
```

Transport buttons invoke the same authoritative Player operations and snapshots
used by the CLI/control plane. GTK owns presentation only.

The frontend owns `org.mpris.MediaPlayer2.orca` on the session bus when one is
available. MPRIS Play/Pause/PlayPause/Stop methods invoke the same Player handle,
and `PlaybackStatus` is read from and signaled from authoritative snapshots.
Library selection uses a GTK file dialog or native file drop, successful opens
raise a desktop notification, and the application action exposes a Space media
shortcut. Standard GTK controls retain their native accessibility semantics.

## macOS SwiftUI

`apps/macos` is a Swift Package client of the installed C module. It keeps the
same bounded 256-row paging contract in a native SwiftUI `List`, exposes AppKit
menus and shortcuts, and mirrors authoritative Player snapshots through
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. It links against
`zig-out/lib/liborca` and does not import Zig, SQLite, codec, or audio layouts.
SwiftUI file import, URL drop handling, notifications, accessibility labels,
menus, and keyboard shortcuts remain presentation-only platform concerns.
