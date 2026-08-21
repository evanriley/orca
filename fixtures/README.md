# Test fixtures

Small redistributable media and pathological-input fixtures belong here. Large
or generated performance corpora must be produced on demand and remain outside
Git.

`audio/generated-reference.flac` is 480 stereo frames generated from a
deterministic 16-bit ramp and encoded with FFmpeg's FLAC encoder.
`audio/generated-reference.qoa` is a hand-built, single-channel 20-frame QOA
stream with zeroed predictor state. Neither fixture contains third-party media.
