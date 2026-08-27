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
