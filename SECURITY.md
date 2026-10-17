# Security policy

## Supported versions

Orca is a 0.x preview. Only the latest release receives security fixes.

## Reporting a vulnerability

Report vulnerabilities privately by email to
[evan@evanriley.com](mailto:evan@evanriley.com). Do not report a vulnerability
in public.

Include the affected version (`orca-cli --version`), the platform, and steps
or a file that reproduces the problem.

Orca is a one-maintainer project. Reports are handled on a best-effort basis,
with no guaranteed response time. A reporter will hear back by email.

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
