# Task 2 report: CSQLite module + OpenCodeDb wrapper

## Implementation

- Added the `CSQLite` system-library module map and shim, and linked it as a SemaforCore dependency.
- Added `OpenCodeDb` with the requested API, SQLite read-only/read-write flags, FULLMUTEX, a 1000 ms busy timeout, bound cursor/limit query, and statement finalization on each query path.
- Validates the SQLite schema at open time so garbage files fail immediately as `openFailed` rather than succeeding until first query.
- Added temp-database tests for ordered rows, cursor/limit, missing path, read-only exec rejection, and invalid database files.

## TDD evidence

### RED

Command: `swift test --filter OpenCodeDbTests`

Output: compilation failed as expected because `OpenCodeDb` did not yet exist (`cannot find type 'OpenCodeDb' in scope`).

The additional invalid-file regression test initially failed because SQLite accepts a garbage file on read-only open until schema access: “an error was expected but none was thrown”. This drove the open-time schema validation.

### GREEN

Command: `swift test --filter OpenCodeDbTests`

Output: `Test run with 4 tests in 1 suite passed`.

Command: `swift test`

Output: `Test run with 194 tests in 28 suites passed`.

## Review notes

- Every prepared statement is finalized with `defer`; partial open failures close the SQLite handle. Wrapper closes on explicit close and deinit.
- No third-party dependencies added. Existing warning in `HTTPClient.swift` about unnecessary `nonisolated(unsafe)` was present during build and is unrelated.

## Review fixes

- `rows(after:limit:)` now reads text using SQLite's reported byte count, preserving embedded NUL bytes. Because `Row.data` is non-optional, SQL `NULL` is rejected as `DbError.queryFailed(status: SQLITE_MISMATCH)` rather than being represented as empty text; this choice is documented beside the conversion.
- `close()` now uses `sqlite3_close_v2`, which defers closing safely if statements remain outstanding instead of losing a still-open handle.
- Added tests for embedded-NUL round-trip and rejected NULL data. Before the fix, both tests failed: embedded-NUL text returned only `"a"`, and NULL returned an empty string.

### Covering verification

Command: `swift test --filter OpenCodeDbTests`

Output: `Test run with 6 tests in 1 suite passed`.

Command: `swift test`

Output: `Test run with 196 tests in 28 suites passed`.
