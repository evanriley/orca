# Storage capabilities

Decoders and analyzers consume `ReadableSource`, a small capability interface
for positional reads, total size, and stable observed identity. It deliberately
does not expose path strings or filesystem handles.

`LocalFileSource` is the desktop implementation. It owns an open file, captures
size/inode/modification identity at open time, and supports offset reads without
changing shared stream position. Provider, mobile, and permission-sensitive
sources can implement the same contract without pretending to be local paths.
