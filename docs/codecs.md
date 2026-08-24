# Codec boundary

Codec implementations consume `ReadableSource` and expose Orca-owned PCM facts;
container-specific state does not escape the codec module.

The initial WAV reader supports integer PCM at 8/16/24/32 bits and IEEE float
at 32/64 bits. It walks RIFF chunks rather than assuming a fixed 44-byte header,
rejects truncated or unsupported input, reports exact frame counts, and performs
bounded positional frame reads. It does not allocate while reading frames.

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
