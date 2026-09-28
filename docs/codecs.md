# Codec boundary

Codec implementations consume `ReadableSource` and expose Orca-owned PCM facts;
container-specific state does not escape the codec module.

The reverse also holds: a container concern does not enter a codec. A stream
that sits behind a prefix belonging to no encoding — an ID3v2 tag stapled in
front of a FLAC file — is resolved by `storage.format.detect`, and the registry
opens the codec over an offset view of the suffix. No decoder skips tags, and
the offset view is owned by the returned Decoder and released strictly after
the codec it fed. See `docs/storage.md` for what detection guarantees.

The WAV reader supports integer PCM at 8/16/24/32 bits and IEEE float at
32/64 bits, in the classic `fmt ` chunk or in `WAVE_FORMAT_EXTENSIBLE`, whose
SubFormat GUID carries the real format tag. It walks RIFF chunks rather than assuming a fixed 44-byte header,
rejects truncated or unsupported input, reports exact frame counts, and performs
bounded positional frame reads. It does not allocate while reading frames.

`CodecRegistry.probe` answers what a container declares — sample rate, channels,
sample width, and a duration derived from the declared frame count — by opening
a decoder and reading no audio. It returns Orca facts: the caller never sees a
decoder, a container header, or a codec error dressed as a property, and a
property the container does not state comes back null rather than zero.

## Codec identity

A probe also reports **which encoding** the container turned out to hold, as a
stable lowercase identifier from `decoder.codec_id`: `pcm`, `pcm_float`,
`flac`, `qoa`, `mp1`, `mp2`, `mp3`, `alac`, `aac`, `opus`, `vorbis`. The scanner stores it in `files.codec` and
the property backfill repairs it for rows written before it existed.

**It is not a synonym for `audio_format`.** `audio_format` names the container
a file was sniffed as, which decides who opens it; `codec` names the encoding
inside, which decides what the bytes cost and what quality they carry. The two
coincide for FLAC and QOA and diverge everywhere a container is a wrapper: a
RIFF/WAVE file holds integer PCM or IEEE float, an MPEG stream is Layer I, II
or III, and the MP4 and Ogg containers this project will grow into hold AAC or
ALAC and Vorbis or Opus. A library that recorded only the container could not
tell an ALAC rip from an AAC one.

The identifier is matched on by equality, never displayed — a human-readable
label belongs to the frontend. Lossy and lossless are told apart by
`codec_id.isLossless`, which is a function of the identifier rather than a
second stored column that could disagree with the first. A file that sniffs as
audio and then refuses to open keeps an **empty** codec: the container is known
and the encoding is not, and an invented identifier would be worse than none.

## MPEG audio (MP3)

`codec/mp3.zig` is the `Decoder` implementation; `codec/mp3_stream.zig` is the
pure-Zig bitstream parsing it stands on. The vendored public-domain `minimp3`
(`codec/vendor/minimp3/`) supplies only the synthesis filterbank, reached
through `codec/mp3_shim.c`. That shim is the containment boundary: no minimp3
type, and no C type at all, is visible above it.

Length and trimming come from the stream, never from the decoder:

- A **Xing** or **Info** header gives the MPEG frame count, and the **LAME**
  extension gives encoder delay and padding. Reported length is
  `frames * samples_per_frame - delay - padding`, and the head of the decoded
  stream is trimmed by `delay + 529`, the Layer III decoder delay. This is what
  makes an MP3's duration and its gapless boundary correct.
- A **VBRI** header supplies a frame count but no usable seek table.
- With no header at all — the majority of real files — length is estimated from
  the constant frame size, and `StreamInfo.exact_length` is false. An estimated
  length never truncates decoding; the stream ends where the data does.

Seeking resolves three ways. Constant-bitrate streams seek by arithmetic on the
frame size. Variable-bitrate streams seek through a lazily extended index of
frame headers, which is exact, is built only on demand and only as far as the
target, and decodes no audio. A Xing TOC is the fallback for a stream whose
headers cannot be walked, and is approximate — measured at roughly five percent
of the duration. Every path backs off far enough for the Layer III bit
reservoir to refill, because frames decoded before it does produce silence.

Trailing ID3v1, APEv2 and Lyrics3 tags are excluded from the audio region, and
a synthesized silent frame terminates streams of declared length. Without
either, the final frame of a file is lost, because a frame is only confirmed
against the bytes that follow it.

Free-format and reserved-field frames are refused. Streams that change channel
count or sample rate mid-file are refused rather than silently reinterpreted.
Truncated input ends the stream; input that never syncs fails at open.

## QOA

QOA decodes through the reference `qoa.h`, vendored under
`codec/vendor/qoa` with its MIT licence and contained by `codec/qoa_shim.c`.
The pure-Zig package it replaced shipped no licence and could not seek. Every
QOA frame carries its own predictor state and every frame but the last holds
5,120 frames of audio, which the adapter's structural pass enforces, so a seek
is an offset computation and a skip inside one frame.

## MP4: ALAC and AAC

MP4 is split three ways. `storage/iso_bmff.zig` frames boxes and finds the
movie box by header alone, so a `moov` stored after the media data costs a
handful of reads; the movie box is bounded at 64 MiB. `codec/mp4.zig` reads the
first sound track whose sample entry is `alac` or `mp4a` with an MPEG-4 or
MPEG-2 AAC `esds`, builds its packet table (bounded at 4M packets), and runs the
packet loop. The engines behind `codec/engine.zig` turn one packet into float
frames and know nothing about the container.

- **ALAC** decodes through Apple's reference decoder, built from source from
  the `alac` package. It is C++, and `alac_shim.cpp` is the only file that sees
  it. The configuration is copied to aligned memory before `Init`, which reads
  it through a struct pointer. ALAC is lossless and reports its bit depth.
- **AAC** (AAC-LC, HE-AAC v1/v2, xHE-AAC) decodes through Ittiam's libxaac,
  AOSP's decoder, built from source by `build/libxaac.zig` using its portable C
  paths on every target. libxaac writes 16-bit PCM for AAC-LC and HE-AAC
  whatever width is requested, so the shim requests 16. Plain AAC completes
  init only after parsing the first access unit, which init does not consume;
  the shim hands it over at open and decodes it normally afterwards. A seek
  re-initializes the decoder and pre-rolls two packets. libxaac's peak limiter
  is on by default and is switched off.
- Both vendored decoders compile with the undefined-behaviour sanitizer off;
  they rely on two's-complement behaviour of shifts that every target defines.

Gapless playback follows the track's edit list: the first presented edit gives
the encoder priming to skip and the audible length. Files without an edit list
fall back to Apple's `iTunSMPB` tag, and failing that every packet plays. The
fallback to `iTunSMPB` has no fixture yet.

A decoder that withholds the start of a packet shifts every later frame
earlier than the sample table places it. libxaac withholds 240 frames of the
first access unit after init, so the packet loop pads any packet shorter than
its sample-table duration with silence at the front. Those frames are
priming or seek pre-roll and are skipped. Measured against FFmpeg's decode of
the same file, the result has zero lag, the exact length, and differences at
16-bit quantization level.

`probe` answers from the container: setting up libxaac costs about 6 ms, which
made a 300-file AAC scan 12 times slower than FLAC's. Duration uses the
decoder's own gapless arithmetic, rate and channels come from the ALAC
configuration or the AudioSpecificConfig, and a test holds the probe to what
the decoder reports for every fixture.

Tags come from `moov/udta/meta/ilst` through `metadata/mp4_tags.zig`: the
standard text atoms, `trkn`, `disk`, `cpil`, `gnre` (an ID3v1 number) and
`----` freeform atoms for MusicBrainz identifiers, ISRC and label. The first
`covr` image is the cover.

## Ogg Opus and Ogg Vorbis

Both decode through the reference libraries, libopusfile and libvorbisfile,
each behind its own shim (`codec/opus_shim.c`, `codec/vorbis_shim.c`). The
libraries own the Ogg container, pre-skip and end trimming, and sample-exact
seeking, so a decoded stream is exactly as long as the audio the encoder was
given and `frame_count` agrees with it. The shims turn the libraries'
cursor-shaped I/O callbacks into positional reads over `ReadableSource`.

- Opus always decodes at 48 kHz. The input rate an Opus header records is
  informational and is not reported as the stream's rate.
- Neither codec has a sample width, so `source_format` is null and
  `files.bit_depth` stays unknown, as for MP3.
- A chained stream whose channel count or rate changes between links fails
  rather than reinterpreting samples.
- A seek rebuilds Opus decoder state from an 80 ms pre-roll. The sought audio
  lands on the requested frame but converges on the sequential decode rather
  than matching it sample for sample.

Tags come from the stream's comment header, read by `metadata/ogg_comment.zig`
without either library: it reassembles the second packet of the first logical
stream from Ogg pages, bounded at 16 MiB, and hands the payload to the Vorbis
comment parser FLAC already uses. Embedded artwork in Ogg
(`METADATA_BLOCK_PICTURE`) is not read yet.

## FLAC

`codec/flac.zig` parses STREAMINFO itself and drives **libFLAC** through
`codec/flac_shim.c`. The shim is the containment boundary, on the same terms as
`mp3_shim.c` and `pipewire_shim.c`: libFLAC's headers and its native decoder
object live inside it, and no `FLAC__` type — no C type beyond fixed-width
integers — is visible above it.

libFLAC's stream decoder is push-shaped, pulling bytes through a read callback
and pushing whole blocks back through a write callback. Orca's `ReadableSource`
is positional and holds no cursor and no file handle, so the shim is
initialized with `FLAC__stream_decoder_init_stream` and carries the byte cursor
libFLAC believes it is at, feeding it from `readAt`. That is what lets a
provider or permission-scoped source decode without ever materializing a path.
Metadata blocks are ignored and MD5 verification is declined explicitly: the
caller has already parsed STREAMINFO, and a whole-file checksum that only
reports at finish is meaningless for a decoder that is routinely seeked and
abandoned mid-track.

Two behaviours of the end of a stream are deliberate, and both were learned
from real files:

- **A sought stream that ends is finished, not damaged.** Frames before a seek
  target are never decoded, so a running count can never reach STREAMINFO's
  declared total and every correct stream would look truncated. The `Decoder`
  contract signals end of input with zero frames and has no way to say "ended
  early but intact", so reporting the end of a sought track as an error was
  indistinguishable from corruption: one album stalled with 8,266 underruns.
  The cost is that a truncated file seeked into ends quietly; every ordinary
  play from the beginning still detects it.
- **A shortfall smaller than one maximum block is the final frame.** One of 104
  ID3-carrying FLACs in the reference library stops 2,620 frames short of the
  11,979,324 STREAMINFO declares, inside its final 4,096-frame block. `ffmpeg`
  calls that an invalid sync code, resyncs and returns the audio; treating it
  as damage lost the whole track. Accepting it is narrow on purpose — a file
  missing more than its last block is still an error, and a stream that
  declares no total is not covered at all.

libFLAC's own error callback is ignored, because whether a stream ended early
enough to count as damage is a question only the caller can answer: it is
decided against the declared total, above the shim.

### History: the pure-Zig package was not lossless

Until this was replaced, FLAC decoding went through the pinned
`audiophile/flac` package, which **reconstructed mid-side stereo incorrectly**.
Roughly half of all decoded samples came back one LSB low, on the majority of
real FLAC files, because mid-side is the stereo mode encoders usually choose.

A FLAC encoder storing mid-side writes `mid = (left + right) >> 1` and
`side = left - right`. The low bit of `mid` is discarded, and it is recoverable
precisely because `left + right` and `left - right` always share parity — so
the missing bit is `side & 1`. The specification's reconstruction restores it
first:

    restored = (mid << 1) | (side & 1)
    left     = (restored + side) >> 1
    right    = (restored - side) >> 1

The package instead computed `left = mid + (side >> 1)` and
`right = left - side`, dropping the restoration. For odd `side` the result is
one too low and `right` inherits the error. Exhaustively over 208,208
(left, right) pairs the specification formula round-trips exactly and that one
is wrong for **50.0%** of them, always by exactly 1 LSB; the smallest
counterexample is `left = 1, right = 0`, which decoded as `(0, -1)`.

One LSB at 16 bits is −96 dBFS, so nothing about this was audible. What it broke
was every use of decoded audio as an *identity*: `files.audio_hash` became
encoding-dependent, so genuinely byte-identical files failed to match and were
demoted to `likely_duplicate`, and loudness, peak and fingerprints varied with
the encoding rather than with the music.

The package ships no licence of any kind — no LICENSE file, no SPDX headers,
nothing in its manifest — so vendoring a corrected copy was not available, and
the decode path moved to libFLAC instead.

`fixtures/audio/midside-reference.flac` exists so this cannot come back
silently. Its two channels are near-opposites, which drives `mid` to a constant
zero and makes mid-side by far the cheapest decorrelation for an encoder to
choose, and its `side` is odd for every single frame — so a decoder that skips
the low-bit restoration is wrong on 100% of samples rather than 50%. The test
regenerates the expected PCM from the same integer sequence the fixture was
built from, so there is no second fixture to drift.

**Replacing the decoder invalidated every stored measurement.** Both
`diagnostics_algorithm_version` and `fingerprint_algorithm_version` moved to 2,
so an existing library re-selects every file rather than trusting figures taken
through the old decoder. Bringing a library up to date is
`orca-cli analyze-library DATABASE`, followed by `orca-cli duplicates DATABASE`
if duplicate findings matter.
