# Architecture

Orca is a local-files-first music player and library maintainer. Its engine,
`liborca`, is the product: a library that does everything music-related, on
which graphical, command-line and terminal applications are built as thin
clients. The model is Ghostty and libghostty: one core, several native
frontends, no frontend owning behaviour.

## Layers

```text
 orca-gtk (Zig)   orca-cli (Zig)   future TUI (Zig)      SwiftUI app (Swift)
        \               |               /                        |
         +---- liborca Zig API --------+                 liborca C ABI (orca.h)
                         |                                       |
                         +------------- liborca -----------------+
                                           |
   library · database · storage · codec · metadata · audio · analysis · jobs
                                           |
  SQLite · libFLAC · minimp3 · libopusfile · libvorbisfile · PipeWire (Linux)
```

- **Zig clients** import the `liborca` module and call its Zig API directly.
  The project is Zig-first, so every frontend is Zig unless a platform forces
  another language.
- **Non-Zig clients** use the C ABI in `liborca/orca.h`: opaque runtime
  ownership, generational handles, plain-data snapshots and callback-scoped
  query views. Only the macOS app needs it, because AppKit requires Swift.
- **Frontends own presentation only**: windows, widgets, accessibility, event
  loops and OS media-control glue. Transport state, library paging, metadata
  resolution and file mutation belong to `liborca`.

## Using liborca from Zig

`build.zig` exports the module as `liborca`. A dependent project adds Orca to
its `build.zig.zon` and imports the module:

```zig
const orca = b.dependency("orca", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("liborca", orca.module("liborca"));
```

The module links SQLite, libFLAC, libopusfile and libvorbisfile, plus PipeWire
on Linux, through the host's pkg-config.

## Rules that hold everywhere

- A capability is done only when a client reaches it through the public runtime
  or ABI path. A unit-tested component that nothing calls is not a feature.
- The real-time render callback never allocates, frees, locks, waits, performs
  I/O or touches SQLite.
- Filesystem paths are never musical identity. Artist, Release, Recording,
  Track, File and Location are separate, and a Location is keyed by a stable
  volume identity.
- Files change only through an approved, journaled `MutationPlan` with startup
  recovery.
- Every queue, page, commit and retry is bounded.
- Foreign libraries stay behind Orca-owned interfaces and never leak their
  types.

## Subsystem contracts

| Subsystem | Contract |
| --- | --- |
| Runtime ownership and shutdown | [ownership.md](ownership.md) |
| Commands, events and jobs | [control-plane.md](control-plane.md) |
| Audio engine | [audio-engine.md](audio-engine.md) |
| Codecs | [codecs.md](codecs.md) |
| Database and schema | [database.md](database.md) |
| Storage and scanning | [storage.md](storage.md) |
| Metadata and file mutation | [metadata.md](metadata.md) |
| Analysis and duplicates | [analysis.md](analysis.md) |
| Frontends and the C ABI | [frontends.md](frontends.md) |

What exists, what is next and what is deferred: [roadmap.md](roadmap.md).
