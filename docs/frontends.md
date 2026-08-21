# Native frontend boundary

First-party graphical applications are thin clients of `liborca`. They own
windows, widgets, accessibility presentation, and native event loops; library,
transport, metadata, and mutation semantics remain in the core.

## C ABI

`liborca/orca.h` exposes opaque runtime ownership, typed generational handles,
POD snapshots, and bounded callback-scoped query views. Both static and shared
libraries install with the header. Returned string views are valid only during
their callback, so no SQLite row or Zig container crosses the ABI.

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

## macOS SwiftUI

`apps/macos` is a Swift Package client of the installed C module. It keeps the
same bounded 256-row paging contract in a native SwiftUI `List`, exposes AppKit
menus and shortcuts, and mirrors authoritative Player snapshots through
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. It links against
`zig-out/lib/liborca` and does not import Zig, SQLite, codec, or audio layouts.
