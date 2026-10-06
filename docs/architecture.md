# Architecture

This file describes how Orca is layered, the rules that hold across every
subsystem, the formats and codecs, the dependencies and their licences, the
supported platforms, and where each subsystem's contract lives.

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
  SQLite · libFLAC · minimp3 · ALAC · libxaac · Xiph libraries · PipeWire
  Chromaprint · KissFFT · libsamplerate
```

- Zig clients import the `liborca` module and call its Zig API
  ([api.md](api.md)). Every frontend is Zig unless a platform forces another
  language.
- Non-Zig clients use the C ABI in `liborca/orca.h`: opaque runtime ownership,
  generational handles, plain-data snapshots and callback-scoped query views
  ([frontends.md](frontends.md)). `tests/c_abi_smoke.c` exercises it.
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
  recovery ([metadata.md](metadata.md#file-mutation)).
- Every queue, page, commit and retry is bounded.
- Provider traffic goes through `network.Gateway`
  ([providers.md](providers.md#rules-toward-providers)).
- Foreign libraries stay behind Orca-owned interfaces and never leak their
  types.

## Formats and codecs

Codecs consume a positional `ReadableSource` and expose Orca-owned PCM facts;
container state does not escape the codec module. A prefix that belongs to no
encoding, such as an ID3v2 tag in front of a FLAC file, is resolved by
`storage.format.detect`, and the registry opens the codec over an offset view of
the suffix ([storage.md](storage.md)). No decoder skips tags.

`CodecRegistry.probe` returns what a container declares (sample rate, channels,
sample width, a duration derived from the declared frame count) by opening a
decoder and reading no audio. It returns Orca facts, never a decoder, header or
codec error, and a property the container does not state is null, not zero.

| Format | Decoder | Licence | Gapless and length |
| --- | --- | --- | --- |
| WAV, AIFF, AIFC | Zig (`wav.zig`, `aiff.zig`) | none needed | exact frame counts |
| FLAC | libFLAC | BSD-3-Clause | STREAMINFO total |
| MPEG audio | Zig framing, vendored minimp3 | CC0 | Xing/Info and LAME delay and padding |
| AAC, HE-AAC, xHE-AAC | libxaac | Apache-2.0 | MP4 edit list; ADTS has no priming |
| ALAC | Apple reference decoder | Apache-2.0 | MP4 edit list, then `iTunSMPB` |
| Ogg Opus | opusfile | BSD-3-Clause | libraries trim pre-skip and end |
| Ogg Vorbis | vorbisfile | BSD-3-Clause | libraries trim end |
| QOA | vendored `qoa.h` | MIT | frame counts |

Each C or C++ library sits behind one shim file in `liborca/codec/`
(`flac_shim.c`, `mp3_shim.c`, `aac_shim.c`, `alac_shim.cpp`, `opus_shim.c`,
`vorbis_shim.c`, `qoa_shim.c`). No library type, and no C type beyond
fixed-width integers, is visible above its shim.

- WAV reads integer PCM at 8, 16, 24 and 32 bits and IEEE float at 32 and 64
  bits, in `fmt ` or `WAVE_FORMAT_EXTENSIBLE`. AIFC is accepted only
  uncompressed (`NONE`, `twos`, `sowt`, `fl32`, `fl64`). 8-bit WAV is unsigned
  and 8-bit AIFF is signed.
- A WAV data chunk that ends inside a frame plays its whole frames and reports
  `PartialWavFrame` through `Decoder.damage`. An AIFF whose COMM declares more
  frames than SSND holds plays the frames present and reports `TruncatedAiff`;
  an AIFF with no SSND fails to open with `MissingSoundChunk`.
- A probe reports the encoding as a stable lowercase `decoder.codec_id`: `pcm`,
  `pcm_float`, `flac`, `qoa`, `mp1`, `mp2`, `mp3`, `alac`, `aac`, `opus`,
  `vorbis`. The scanner stores it in `files.codec`. `codec` names the encoding
  inside a container (a RIFF file holds PCM or float, MP4 holds AAC or ALAC),
  while `audio_format` names the container and decides who opens it.
  `codec_id.isLossless` derives lossy from lossless, so no second column can
  disagree.
- MP3 length and trimming come from the stream, never the decoder: reported
  length is `frames * samples_per_frame - delay - padding` from the Xing or Info
  header and LAME extension, and the head is trimmed by `delay + 529`. Without a
  header the length is estimated and `StreamInfo.exact_length` is false.
  Trailing ID3v1, APEv2 and Lyrics3 tags are excluded from the audio region, and
  a synthesized silent frame terminates streams of exact length; without both,
  the final frame is lost. Seeks back off far enough for the Layer III bit
  reservoir to refill.
- MP4 (`codec/mp4.zig`) reads the first sound track whose sample entry is `alac`
  or `mp4a`. The movie box is bounded at 64 MiB and the packet table at 4 Mi
  packets. A decoder that withholds the start of a packet shifts every later
  frame early: libxaac withholds 240 frames of the first access unit, so the
  packet loop pads any packet shorter than its sample-table duration with
  silence at the front.
- Ogg Opus always decodes at 48 kHz. Opus and Vorbis have no sample width, so
  `files.bit_depth` is unknown, as for MP3. An Ogg comment header is read by
  `metadata/ogg_comment.zig` without either library, bounded at 16 MiB and 4,096
  pages. A chained stream whose channel count or rate changes fails.
- Tag readers per format are in [metadata.md](metadata.md).

### FLAC

FLAC is lossless, so its decoder must be bit-exact: `files.audio_hash`,
loudness, peak and fingerprints are identities of the audio, and libFLAC is the
reference decoder. A different decoder is not substituted.

`ReadableSource` is positional and holds no cursor or file handle, so the shim
uses `FLAC__stream_decoder_init_stream` and carries the byte cursor libFLAC
believes it is at. Metadata callbacks are off. A sought stream that ends is
finished, not damaged, because frames before a seek target are never decoded.
An unsought stream that ends short by more than one maximum block fails, with
`FlacStreamErrors` when libFLAC reported frame errors and `TruncatedFlac`
otherwise.

Playback tolerates the rest and reports it through `Decoder.damage` once an
unsought decode reaches its end: frame errors libFLAC recovered from before the
declared end (`FlacStreamErrors`), a shortfall smaller than one maximum block
(`TruncatedFlac`), and decoded audio that disagrees with a nonzero STREAMINFO
MD5 (`FlacMd5Mismatch`). The shim checks MD5 on every decode from the start and
reads the result when libFLAC finishes the stream; a later seek restarts the
decoder. The analysis pass turns damage into `corrupt_audio`
([analysis.md](analysis.md)).
`fixtures/audio/midside-reference.flac` guards mid-side reconstruction: a
decoder that skips restoring the low bit of `mid` is wrong on every sample.

### Sanitizers

ALAC and libxaac compile with `-fno-sanitize=undefined`: they rely on
two's-complement shifts that every supported target defines.

## Dependencies and licences

Everything liborca compiles in or links is permissively licensed, so an embedder
may keep its own code closed. GPL and LGPL dependencies are not permitted in the
engine. A frontend may dynamically link its platform toolkit or keyring. `zig
build` installs the licence texts of vendored and source-built code under
`share/doc/orca/licenses`.

| Dependency | Licence | How it is used |
| --- | --- | --- |
| SQLite | public domain | system library |
| libFLAC, libogg, libopus, opusfile, libvorbis | BSD-3-Clause | system libraries |
| libsamplerate | BSD-2-Clause | system library, behind `samplerate_shim.c` |
| PipeWire | MIT | system library on Linux, behind `pipewire_shim.c` |
| minimp3, QOA | CC0, MIT | vendored in `liborca/codec/vendor` |
| ALAC, libxaac | Apache-2.0 | built from source by `build.zig` |
| Chromaprint | MIT | built from source by `build/chromaprint.zig` |
| KissFFT (in Chromaprint) | BSD-3-Clause | built from source with Chromaprint |

`build.zig.zon` pins the sources `build.zig` builds: ALAC (a git commit),
libxaac (v0.1.13) and Chromaprint (v1.6.1). System libraries come from
`pkg-config`, supplied by the dev shell and the Nix package.

Chromaprint's repository also carries FFmpeg's LGPL resampler
(`src/avresample`). It is not compiled: `config.h` leaves
`USE_INTERNAL_AVRESAMPLE` undefined, and Orca resamples with libsamplerate. The
build step `check Chromaprint licences`, which `zig build` and `zig build test`
run, fails if any Chromaprint or KissFFT source it compiles contains a GPL or
LGPL notice.

## Platforms

Linux x86_64 is the supported platform: the engine, the PipeWire output, the
filesystem watcher, the GTK4 frontend and the Nix package. For macOS, `zig build
lib -Dtarget=aarch64-macos` cross-builds a static `liborca`; macOS has no audio
output, watcher or app.

## Subsystem contracts

| Subsystem | Contract |
| --- | --- |
| Runtime ownership and shutdown | [api.md](api.md#runtime-ownership-and-shutdown) |
| Commands, events and jobs | [control-plane.md](control-plane.md) |
| Audio engine | [audio-engine.md](audio-engine.md) |
| Database and schema | [database.md](database.md) |
| Storage and scanning | [storage.md](storage.md) |
| Metadata and file mutation | [metadata.md](metadata.md) |
| Analysis and duplicates | [analysis.md](analysis.md) |
| Playlists and ratings | [cli.md](cli.md#playlists-and-ratings) |
| Providers, listens and scrobbling | [providers.md](providers.md) |
| Public Zig API | [api.md](api.md) |
| Frontends and the C ABI | [frontends.md](frontends.md) |
| Command-line interface | [cli.md](cli.md) |
| Outbound network traffic | [privacy.md](privacy.md) |

What exists, what is next and what is deferred: [roadmap.md](roadmap.md).
