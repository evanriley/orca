# Library persistence

Each `LibraryDatabase` owns one SQLite database and one serialized logical write
lane. Paths are copied at open time so the Library owns all state needed to open
independent read connections. `OrcaRuntime.openLibrary` associates that database
with a typed generational `LibraryHandle` and closes it during explicit removal
or ordered runtime shutdown.

## Schema and migrations

Schema changes are transactional and selected by `PRAGMA user_version`. Version
1 establishes separate Artist, Release, Recording, Track, File, and Location
tables; filesystem paths therefore never become musical identity. Unknown newer
schema versions are rejected rather than opened destructively.

Track full-text search uses an external-content FTS5 table maintained by SQLite
triggers. Repository APIs return bounded, caller-owned pages and never expose
SQLite rows or statements.

## Concurrency

- The primary connection uses WAL and `synchronous=NORMAL`.
- A short control-plane lock serializes complete write transactions.
- Read snapshots use independent read-only connections.
- Connections use SQLite's full-mutex mode and a five-second busy timeout.
- Prepared batch statements are reused within one transaction.

Automated coverage verifies independent libraries and indexes, FTS paging, a
10,000-row transactional update, and concurrent read access while four write
producers serialize. The executable benchmark generates 500,000 tracks without
involving a scanner and measures insertion, reopen, and search latency.
