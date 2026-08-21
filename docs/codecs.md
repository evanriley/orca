# Codec boundary

Codec implementations consume `ReadableSource` and expose Orca-owned PCM facts;
container-specific state does not escape the codec module.

The initial WAV reader supports integer PCM at 8/16/24/32 bits and IEEE float
at 32/64 bits. It walks RIFF chunks rather than assuming a fixed 44-byte header,
rejects truncated or unsupported input, reports exact frame counts, and performs
bounded positional frame reads. It does not allocate while reading frames.
