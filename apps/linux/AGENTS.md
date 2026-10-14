# Linux GTK frontend guidance

## Boundary

`orca-gtk` is a thin presentation client of liborca's public Zig API. It owns
GTK widgets, accessibility, event handling, desktop integration, and view
state. Library paging, transport state, metadata resolution, mutation rules,
provider behavior, and job semantics remain in liborca. Add a public `Runtime`
method when the frontend needs engine behavior that is not exposed.

GTK4 remains hand-bound with minimal `extern fn` declarations because
`translate-C` cannot parse its headers. Foreign types and object lifetimes stay
inside the platform adapter.

## Lifetimes and threading

GTK and runtime calls remain on the main thread. Worker results return through
the existing wake and tick paths. Join frontend threads that hold a Library
handle before destroying or replacing that Library. Treat liborca snapshots
as authoritative; do not reconstruct state from events.

Every GTK object follows the surrounding ownership pattern. Keep callback
contexts alive until their signal, source, task, or widget is disconnected or
destroyed. Cancel or discard asynchronous work when its bound row, page, or
Library is no longer current. Artwork stays on the bounded request, decode,
and cache path in `art.zig`; do not decode full-size images on the main thread.

- Credentials go through `secret.zig` (libsecret) only; they never reach
  `settings.ini`, the Library or a log.
- liborca threads wake the GTK loop only through `App.waker` writing the
  eventfd in `main.zig`; the eventfd closes only after liborca has joined its
  threads.
- "Bit-perfect" is shown only when `liborca.SignalPath.bit_perfect_eligible`
  is set; the frontend never decides it from other fields.
- An unusable embedding model path warns and leaves Radio and mixes without
  sound similarity; it never fails startup.

## Rendering and verification

Use `scripts/headless-gui.sh` for deterministic UI checks. It isolates the
display, D-Bus, XDG directories, providers, and audio output and waits for
rendering to settle before capturing a PNG.

```sh
zig build
scripts/headless-gui.sh albums /tmp/albums.png
scripts/headless-gui.sh artists /tmp/artists.png move:800,500 scroll:3
scripts/headless-gui.sh albums /tmp/palette.png key:ctrl+k type:scan wait:500
ORCA_HEADLESS_SIZE=3440x1440 scripts/headless-gui.sh albums /tmp/albums-wide.png
```

Verify affected pages at 1440x900 (the default), 1920x1080, 2560x1440 and
3440x1440, set through `ORCA_HEADLESS_SIZE` as `WIDTHxHEIGHT`, and check
interaction state, keyboard path, and focus behavior. Compare screenshots
visually and inspect the captured log for warnings. Do not run the GUI on the
host's desktop session or play through a real output device. The step syntax
and isolation guarantees are in the header of `scripts/headless-gui.sh`.

When changing `scripts/headless-gui.sh`, keep its isolation:

- Every process runs under a private `XDG_RUNTIME_DIR` outside the user's,
  short enough for a Wayland socket. Never run a bare Wayland client against
  the user's session.
- Output is pinned to `scripts/silent-sink.sh 1`, and the run aborts when the
  sink cannot be made.
- Only PIDs the script recorded, whose environment carries this run's
  `XDG_RUNTIME_DIR`, are ever signalled.
- The app opens a copy of the fixture Library, never the source.
- Providers point at a closed port unless an `ORCA_HEADLESS_*_URL` names a
  local mock, and the caller's `ORCA_EMBEDDING_MODEL` is never passed through.
