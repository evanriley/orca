# Architecture

How Orca is layered, the rules that hold across every subsystem, the formats
and codecs, the dependencies and their licences, and the supported platforms.

Orca is a local-files-first music player and library maintainer. Its engine,
`liborca`, is the product: a library that does everything music-related, on
which graphical and command-line applications are built as thin clients. One
core, several native frontends, no frontend owning behaviour.

## Layers

```text
 orca-gtk (Zig)      orca-cli (Zig)            foreign frontends
        \                 |                          |
         +-- liborca Zig API --+          liborca C ABI (orca.h)
                     |                                |
                     +-------------- liborca ---------+
                                         |
   library · database · storage · codec · metadata · audio · analysis · jobs
                                         |
  SQLite · libFLAC · mpg123 · ALAC · libxaac · Xiph libraries · PipeWire
  Chromaprint · KissFFT · libsamplerate · ONNX Runtime
```

- Zig clients import the `liborca` module and call its Zig API
  ([api.md](api.md)). Every frontend is Zig unless a platform forces another
  language.
- Non-Zig clients use the C ABI in `liborca/orca.h`: opaque runtime ownership,
  generational handles, plain-data snapshots and callback-scoped query views
  ([c-abi.md](c-abi.md)). `tests/c_abi_smoke.c` exercises it.
- Frontends own presentation only: windows, widgets, accessibility, event loops
  and OS media-control glue. Transport state, library paging, metadata
  resolution and file mutation belong to `liborca`.

## Rules that hold everywhere

- A capability is complete only when a client reaches it through the public
  runtime or ABI path. A unit-tested component that nothing calls is not a
  feature.
- The real-time render callback never allocates, frees, locks, waits, performs
  I/O or touches SQLite.
- Filesystem paths are never musical identity. Artist, Release, Recording,
  Track, File and Location are separate, and a Location is keyed by a stable
  volume identity.
- Files change only through an approved, journaled `MutationPlan` with startup
  recovery.
- Every queue, page, commit and retry is bounded.
- Provider traffic goes through `network.Gateway`.
- Foreign libraries stay behind Orca-owned interfaces and never leak their
  types.

## Formats and codecs

Codecs consume a positional `ReadableSource` and expose Orca-owned PCM facts;
container state does not escape the codec module. A prefix that belongs to no
encoding, such as an ID3v2 tag in front of a FLAC file, is resolved by
`storage.format.detect`, and the registry opens the codec over an offset view of
the suffix. No decoder skips tags.

`CodecRegistry.probe` returns what a container declares (sample rate, channels,
sample width, a duration derived from the declared frame count) by opening a
decoder and reading no audio. It returns Orca facts, never a decoder, header or
codec error, and a property the container does not state is null, not zero.

| Format | Decoder | Licence | Gapless and length |
| --- | --- | --- | --- |
| WAV, AIFF, AIFC | Zig (`wav.zig`, `aiff.zig`) | none needed | exact frame counts |
| FLAC | libFLAC | BSD-3-Clause | STREAMINFO total |
| MPEG audio | mpg123 | LGPL-2.1 | Xing/Info and LAME delay and padding |
| AAC, HE-AAC, xHE-AAC | libxaac | Apache-2.0 | MP4 edit list; ADTS has no priming |
| ALAC | Apple reference decoder | Apache-2.0 | MP4 edit list, then `iTunSMPB` |
| Ogg Opus | opusfile | BSD-3-Clause | libraries trim pre-skip and end |
| Ogg Vorbis | vorbisfile | BSD-3-Clause | libraries trim end |
| QOA | `qoa.h` from `phoboslab/qoa` | MIT | frame counts |

Each C or C++ library sits behind one shim file in `liborca/codec/`
(`flac_shim.c`, `aac_shim.c`, `alac_shim.cpp`, `opus_shim.c`, `vorbis_shim.c`,
`qoa_shim.c`), or, for mpg123, behind the Zig declarations in `mp3.zig`. No
library type, and no C type beyond fixed-width integers, is visible above its
shim or outside `mp3.zig`.

A new format uses the best-maintained decoder library for that format behind
one shim. Orca writes its own decoder only when no correct library exists.

## Dependencies and licences

Dependencies are chosen on technical merit; GPL, LGPL and AGPL are allowed. A
copyleft dependency that can reasonably be optional gets a build option so a
build without it stays possible. A frontend may dynamically link its platform
toolkit or keyring. Third-party source that Orca changes lives in a fork at
`github.com/evanriley/<name>`, with each change as a commit, pinned by commit
in `build.zig.zon`; the repository holds no third-party source. `zig build`
installs the licence texts of source-built code under
`share/doc/orca/licenses`.

| Dependency | Licence | How it is used |
| --- | --- | --- |
| SQLite | public domain | system library |
| libFLAC, libogg, libopus, opusfile, libvorbis | BSD-3-Clause | system libraries |
| libsamplerate | BSD-2-Clause | system library, behind `samplerate_shim.c` |
| PipeWire | MIT | system library on Linux, behind `pipewire_shim.c` |
| ONNX Runtime | MIT | system library, behind `embedding_shim.c` |
| mpg123 | LGPL-2.1 | dynamically linked system library, declared in `mp3.zig` |
| QOA | MIT | built from source by `build.zig`, pinned in `build.zig.zon` |
| ALAC | Apache-2.0 | built from the `evanriley/alac` fork by `build/alac.zig` |
| libxaac | Apache-2.0 | built from source by `build.zig` |
| Chromaprint | MIT | built from source by `build/chromaprint.zig` |
| KissFFT (in Chromaprint) | BSD-3-Clause | built from source with Chromaprint |

`build.zig.zon` pins the sources `build.zig` builds. System libraries come
from `pkg-config`, supplied by the dev shell and the Nix package.

ONNX Runtime runs the audio-embedding model. It is MIT and carries some
MPL-2.0 files; liborca links it dynamically and compiles none of its source.
`-Dembeddings=false` builds liborca without it.

The models are data files, not part of liborca, and neither is in the
repository or compiled in. A host names the path of one, and liborca accepts
only a file whose size and SHA-256 it was built with
([sound-similarity.md](sound-similarity.md)).

- `clap_audio_int8.onnx` is Orca's int8 export of the audio part of
  `laion/clap-htsat-unfused`, whose weights are published as Apache-2.0,
  written by `scripts/embedding/export_model.py`.
- `maest_audio_int8.onnx` is Orca's int8 export of
  `mtg-upf/discogs-maest-30s-pw-129e` by the Music Technology Group,
  Universitat Pompeu Fabra, written by `scripts/embedding/export_maest.py`.
  The weights are licensed CC BY-NC-SA 4.0: non-commercial use, with
  attribution, and derivatives under the same licence. The file is such a
  derivative, and its release states the licence, the attribution and the
  source. The engine downloads it only when a host asks, and packages bundle
  only the permissively licensed file.

Chromaprint's repository also carries FFmpeg's resampler (`src/avresample`). It
is not compiled: `config.h` leaves `USE_INTERNAL_AVRESAMPLE` undefined, and Orca
resamples with libsamplerate.

## Platforms

Linux x86_64 is the supported platform: the engine, the PipeWire output, the
filesystem watcher, the GTK4 frontend and the Nix package. For macOS, `zig build
lib -Dtarget=aarch64-macos` cross-builds a static `liborca`; macOS has no audio
output, watcher or app.

Planned work and ideas: [roadmap.md](roadmap.md).
