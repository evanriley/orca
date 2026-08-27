# Test fixtures

Small redistributable media and pathological-input fixtures belong here. Large
or generated performance corpora must be produced on demand and remain outside
Git.

`audio/generated-reference.flac` is 480 stereo frames generated from a
deterministic 16-bit ramp and encoded with FFmpeg's FLAC encoder.
`audio/generated-reference.qoa` is a hand-built, single-channel 20-frame QOA
stream with zeroed predictor state. Neither fixture contains third-party media.

`audio/id3-prefixed-reference.flac` and `audio/id3-footer-prefixed-reference.flac`
are `audio/generated-reference.flac` behind a synthetic ID3v2.4 tag — 210 bytes
without a footer, 220 with one. Some taggers staple an ID3v2 tag to the front of
a FLAC stream, and 104 files in the reference library do; these fixtures keep
that case covered without it. The tag is deliberately longer than the 64-byte
prefix container detection reads first, so resolving it requires the second read
rather than a longer one.
