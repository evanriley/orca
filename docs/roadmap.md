# Roadmap

Where Orca is headed. What works today is in the
[README](../README.md#features). Defects, test gaps and smaller enhancements
are [GitHub issues](https://github.com/evanriley/orca/issues).

- [Planned](#planned): capabilities with a decided scope.
- [Ideas](#ideas): larger capabilities with no commitment.
- [Not planned](#not-planned): out of scope.

## Planned

- Tag writers for M4A, Ogg, WAV, AIFF and FLAC with a leading ID3 tag, which
  are reported as not writable today
  ([#49](https://github.com/evanriley/orca/issues/49)).
- File moves. The journaled `MutationPlan` executor performs them, but no
  runtime entry point or client reaches them.
- Full multichannel. Canonical PCM carries a channel count but no layout, so
  decoding, loudness analysis, DSP and PipeWire channel positions need one.
  Until then playback, loudness analysis and AcoustID fingerprinting refuse a
  file with more than two channels.
- Crossfade, never applied between gapless album tracks.
- Synchronized multi-zone playback with drift correction.
- Windows.
- More formats, sniffed or not recognized until they are supported:
  - WavPack, Monkey's Audio (APE), TTA and Musepack.
  - DSD (DSF and DFF), which also needs DSD-to-PCM conversion or native DSD
    output.
  - WMA.
  - FLAC in Ogg, Matroska and WebM audio, and FLAC or Opus inside MP4.

## Ideas

- Conversion and encoding.
- Secure, verified CD ripping.
- A terminal client built on the Zig API.
- Convolution DSP for room correction and headphone targets from impulse
  responses.
- An optional fixed output rate with a band-limited resampler, for devices
  held at another rate and for gapless playback across sample-rate changes.
  Output at the source rate stays the default, since only that path can be
  bit-perfect.
- Exclusive output and an ALSA direct-hardware backend.
- An optional FFmpeg fallback behind a build flag, used only for formats that
  no per-format library decodes.
- Classical music by composition: works, composers and performers.
- Streaming sources and cross-device sync.
- `liborca` on Android and iOS.

## Not planned

- macOS during the C++ port; it will be revisited with a fresh approach after
  the port lands.
- Preserving file modification dates on tag writes: it would hide the
  write from the incremental scan.
- A DAW, plugin host, or arbitrary DSP graph.
- A required FFmpeg dependency.
- A custom database engine, TLS stack or cryptography.
