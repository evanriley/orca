# Releasing

How Orca is versioned, how changes are recorded and how a release is cut.

## Versioning

Orca follows [Semantic Versioning](https://semver.org). Before 1.0, a
release bumps the minor version when it contains a breaking change to the
Zig API, the C ABI or the Library schema, and the patch version otherwise.
1.0 follows the
[1.0 readiness](https://b.maybemaybe.lol/672513d) conditions.

## Changelog

Every change adds its entry to the Unreleased section of `CHANGELOG.md` in
the same commit: features, fixes, refactors, removals and breaking changes
alike. An entry is one unwrapped line and one sentence, under Added, Fixed or
Changed, naming the API, setting or command a user meets. A breaking change
starts with `**Breaking:**`. Changes to CI alone need no entry.

## The audio-embedding model

Two audio-embedding model files exist. Neither is in the repository. Each is
the one asset of its own release, which the README's download commands and
`Runtime.startEmbeddingModelDownload(model, destination)` fetch. The Nix
package fetches only `clap_audio_int8.onnx`. liborca accepts only a file with
the size and SHA-256 in `liborca/analysis/audio_embedding.zig`.

- `clap_audio_int8.onnx`: release tag `model-clap-int8-1`, written by
  `scripts/embedding/export_model.py`.
- `maest_audio_int8.onnx`: release tag `model-maest-int8-1`, written by
  `scripts/embedding/export_maest.py`.

The MAEST file is derived from
[mtg-upf/discogs-maest-30s-pw-129e](https://huggingface.co/mtg-upf/discogs-maest-30s-pw-129e)
at the revision pinned in the export script, and is licensed CC BY-NC-SA 4.0.
Its release notes carry that licence, the attribution (Music Technology Group,
Universitat Pompeu Fabra), the source repository and revision, and a statement
that the file is a quantised derivative of the original weights.

A different model is a new file under a new tag, never a replaced asset:

1. Write the file with the model's export script and `OUTDIR` as its argument.
2. Set the release tag, file name, size and SHA-256 of the model's `ModelSpec`
   in `liborca/analysis/audio_embedding.zig`.
3. Upload the file as the asset of a new `model-NAME-N` release.
4. Set the URL and digest in the README. For the bundled model only, also set
   the URL and hash of `embeddingModel` in `nix/package.nix`.

## Steps

1. Rename the Unreleased section of `CHANGELOG.md` to the version and date,
   and state the Library schema version it ships.
2. Set `.version` in `build.zig.zon`.
3. Copy `liborca/orca.h` to `tests/abi/orca-X.Y.Z.h`, and add the version to
   the baselines in `build.zig` and `tests/abi/compat.zig`.
4. Commit, push the commit to Gerrit with `git push origin HEAD:refs/for/main`,
   and submit it once CI votes Verified +1.
5. Check out the updated `main`, tag the release commit (`RELEASE_COMMIT`
   below) with a signed, annotated `orca-vX.Y.Z` tag whose message is that
   version's section of `CHANGELOG.md`, and push the tag:

   ```sh
   version=X.Y.Z
   { printf 'Orca %s\n\n' "$version"
     awk -v v="$version" '$1 == "##" { p = ($2 == v); next } p' CHANGELOG.md
   } | git tag -s "orca-v$version" --cleanup=whitespace -F - RELEASE_COMMIT
   git push origin "orca-v$version"
   ```

   `--cleanup=whitespace` keeps the `###` headings, which the default
   cleanup removes as comments.
6. Update Orca's application entry on the AcoustID website to the new
   version. Every lookup and submission sends the version as
   `clientversion`, and the registered details should match what the
   service receives.
