# Releasing

How Orca is versioned, how changes are recorded and how a release is cut.

## Versioning

Orca follows [Semantic Versioning](https://semver.org). Before 1.0, a
release bumps the minor version when it contains a breaking change to the
Zig API, the C ABI or the Library schema, and the patch version otherwise.
1.0 follows the [Before 1.0](roadmap.md#before-10) gates.

## Changelog

Every change adds its entry to the Unreleased section of `CHANGELOG.md` in
the same commit: features, fixes, refactors, removals and breaking changes
alike.

## Steps

1. Rename the Unreleased section of `CHANGELOG.md` to the version and date,
   and state the Library schema version it ships.
2. Set `.version` in `build.zig.zon`.
3. Commit on a branch and merge it into `main` through a pull request once CI
   passes.
4. Check out the updated `main`, tag the release commit (`RELEASE_COMMIT`
   below) with a signed, annotated `vX.Y.Z` tag whose message is that
   version's section of `CHANGELOG.md`, and push the tag:

   ```sh
   version=X.Y.Z
   { printf 'Orca %s\n\n' "$version"
     awk -v v="$version" '$1 == "##" { p = ($2 == v); next } p' CHANGELOG.md
   } | git tag -s "v$version" --cleanup=whitespace -F - RELEASE_COMMIT
   git push origin "v$version"
   ```

   `--cleanup=whitespace` keeps the `###` headings, which the default
   cleanup removes as comments.
5. Update Orca's application entry on the AcoustID website to the new
   version. Every lookup and submission sends the version as
   `clientversion`, and the registered details should match what the
   service receives.
