# Codec boundary

Codec implementations consume `ReadableSource` and expose Orca-owned PCM facts;
container-specific state does not escape the codec module.

The reverse also holds: a container concern does not enter a codec. A stream
that sits behind a prefix belonging to no encoding — an ID3v2 tag stapled in
front of a FLAC file — is resolved by `storage.format.detect`, and the registry
opens the codec over an offset view of the suffix. No decoder skips tags, and
the offset view is owned by the returned Decoder and released strictly after
the codec it fed. See `docs/storage.md` for what detection guarantees.

The initial WAV reader supports integer PCM at 8/16/24/32 bits and IEEE float
at 32/64 bits. It walks RIFF chunks rather than assuming a fixed 44-byte header,
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
`flac`, `qoa`, `mp1`, `mp2`, `mp3`. The scanner stores it in `files.codec` and
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

## Known defect: FLAC mid-side decoding is not lossless

**The pinned `audiophile/flac` dependency reconstructs mid-side stereo
incorrectly.** Roughly half of all decoded samples are one LSB low, on the
majority of real FLAC files, because mid-side is the stereo mode encoders
usually choose.

A FLAC encoder storing mid-side writes `mid = (left + right) >> 1` and
`side = left - right`. The low bit of `mid` is discarded, and it is recoverable
precisely because `left + right` and `left - right` always share parity — so
the missing bit is `side & 1`. The specification's reconstruction restores it
first:

    restored = (mid << 1) | (side & 1)
    left     = (restored + side) >> 1
    right    = (restored - side) >> 1

`zig-pkg/flac-1.0.2-*/src/Frame.zig` instead computes:

    left  = mid + (side >> 1)
    right = left - side

which drops the restoration. For odd `side` the result is one too low, and
`right` inherits the error. Exhaustively over 208,208 (left, right) pairs the
specification formula round-trips exactly and this one is wrong for **50.0%**
of them, always by exactly 1 LSB. The smallest counterexample is
`left = 1, right = 0`, which decodes as `(0, -1)`.

Measured on 30 seconds of real music, two FLAC encodings of one PCM stream that
`ffmpeg` confirms are byte-identical when decoded:

    our WAV decode vs our FLAC decode : 513,872 of 1,048,576 samples differ
    largest difference               : 0.0000305176  (exactly 1 LSB at 16-bit)
    compression level 0 vs level 12  : 4,544 samples differ

The last line is why this is not merely academic: the error depends on the
*encoding*, so two files holding identical audio decode differently.

**What it does and does not affect.** One LSB at 16 bits is −96 dBFS, so this is
inaudible and playback quality is not a practical concern. What it does break is
anything treating decoded audio as an identity:

- `files.audio_hash` is encoding-dependent, so exact-duplicate detection misses
  genuinely byte-identical pairs and demotes them to `likely_duplicate`. One
  such pair is already known in the reference library.
- Loudness, peak and fingerprints vary slightly with encoding.

**Fixing it invalidates every stored `audio_hash` and every fingerprint**, so
the analysis pass would have to be re-run over the library. That, plus the fact
that the defect is in a pinned third-party package rather than in Orca, is why
it is documented here rather than worked around: the options are to report it
upstream, to vendor a corrected copy, or to accept it, and that is a decision
about dependencies rather than a code change.

## Known gap: WAVE_FORMAT_EXTENSIBLE is refused

`wav.zig` rejects a `fmt ` chunk of 40 bytes with `UnsupportedWavEncoding`.
That is `WAVE_FORMAT_EXTENSIBLE`, which ffmpeg emits by default for stereo
`pcm_s16le`, so a WAV produced by the most obvious command line will not open.
The real sample format is the SubFormat GUID's first two bytes, which map onto
the same tags the 16-byte header uses. No file in the reference library is
affected, since it contains no WAV at all.
