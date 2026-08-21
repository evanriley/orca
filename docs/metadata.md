# Metadata layers

Orca keeps three concepts separate:

- `ObservedFileMetadata` records what a source file currently says.
- `OrcaMetadata` records preferred values, user edits, locks, and later provider
  proposals without mutating that file.
- `EffectiveMetadata` is a resolved view under an explicit preference policy.

Every value carries provenance. A user-locked Orca value outranks automatic
resolution even when the general policy prefers file tags.

Format readers terminate at this boundary. The initial ID3v1/v1.1 reader parses
legacy MP3 fields into a view; format-specific genre numbers and fixed-width
storage do not define the canonical metadata model. Rich ID3, Vorbis comments,
FLAC pictures, and MP4 atoms will extend the reader side without changing the
three-layer contract.

Scanner observations are persisted in `observed_file_metadata`, keyed to the
physical observed file record and updated in the same bounded transaction. They
do not update Track metadata and never cause a source-file write.
