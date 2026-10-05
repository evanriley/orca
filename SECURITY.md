# Security policy

## Supported versions

Orca is a 0.x preview. Only the latest release receives security fixes.

## Reporting a vulnerability

Report vulnerabilities privately with GitHub's private vulnerability
reporting:

1. Open the [Security tab](https://github.com/evanriley/orca/security) of the
   `evanriley/orca` repository.
2. Choose Report a vulnerability and describe the issue.

Do not open a public issue or pull request for a vulnerability.

Include the affected version (`orca-cli --version`), the platform, and steps
or a file that reproduces the problem.

Orca is a one-maintainer project. Reports are handled on a best-effort basis,
with no guaranteed response time. A reporter will hear back through the same
private report.

## Scope

In scope:

- `liborca`, the engine, including scanning, decoding, the Library database
  and the audio engine.
- The C ABI in `liborca/orca.h`.
- File mutation: tag writes, their journal and their recovery.
- Provider traffic: the network gateway, the providers and the handling of
  credentials; see [Privacy](docs/privacy.md).
- `orca-cli` and `orca-gtk`.

Out of scope:

- Vulnerabilities in the third-party libraries Orca links, which belong to
  those projects. A report that Orca uses one unsafely is in scope.
- The services Orca contacts, such as MusicBrainz or ListenBrainz.
- Problems that require an attacker who already controls the user's account
  or the Library database file.
