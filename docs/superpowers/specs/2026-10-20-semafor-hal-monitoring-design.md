# Semafor hal monitoring — design spec

Date: 2026-10-20 · Status: approved approach (A), awaiting spec review
Depends on: M3 passive measurement core (fired tiles, baselines, verdicts)

## 1. Goal

Monitor the local model — Qwen3.8-Flash-Next served by vLLM on the homelab
box `hal` — with the same passive machinery used for Claude and Codex:
measured throughput and degradation from the tools' own session data, plus a
cheap health probe against the user's own server. No model calls, no quota
spent. OpenCode is the only driver of hal, so OpenCode's session database is
the measurement source.

## 2. Non-goals

- Control probes (hal is the user's own box; there is nothing to compare
  queue-vs-direct against).
- Usage-limit windows / `LIMITED` / `BUSY` verdicts (no usage API exists).
- Divergence checks (needs two signals; hal has one).
- GPU/system telemetry, notifications, capacity events (M4).

## 3. Data sources

### 3.1 Measurement: OpenCode SQLite database

`~/.local/share/opencode/opencode.db` (SQLite, WAL mode). Verified against
the live db: the `message` table's columns are `id, session_id,
time_created, time_updated, data` — role/providerID are **not** columns, so
the SQL stays dumb and the Swift side parses `data` (JSON) with keys:
`cost, tokens{total,input,output,reasoning,cache}, modelID, providerID,
time{created,completed}, finish, parentID, role, mode, agent, path, error?`.

Scanner query per tick (`LIMIT` bounds memory; rowid is the cursor):

```sql
SELECT rowid, data FROM message WHERE rowid > :cursor ORDER BY rowid LIMIT 2000
```

Rows are filtered in Swift: keep `role == "assistant"` and
`providerID == "hal"` (no json1 dependency; a scan over the other providers'
rows is cheap at one pass per tick).

**Amendment 2026-10-20 — schema v2 (binding, supersedes the `message`-table
reading above)**: OpenCode migrated session storage; the desktop app (the
only writer since Sept 17) writes the `session_message` table
(`id, session_id, type, seq, time_created, time_updated, data`), live-verified
while this feature dogfoods. The legacy `message` table stays frozen — its
already-ingested samples remain in the Semafor store and baseline pools, but
the scanner now targets `session_message` only:

```sql
SELECT rowid, type, data FROM session_message WHERE rowid > :cursor ORDER BY rowid LIMIT 2000
```

Swift-side filters: keep rows whose **`type` column** == `"assistant"` **and**
`data.model.providerID == "hal"` (providerID moved from top level into the
`model` object: `{id, providerID, variant}`; `model.id` replaces `modelID`).
Error rows carry `data.error = {type, message, status, response}` — decode
**only** `type` and `status`; `message`/`response` are never decoded, stored,
or printed (privacy §8 unchanged). Classification maps onto the §3.3 rules:
`error.type == "aborted"` ⇒ invisible (user cancel); any other `error.type`
(`provider.error`, `provider.transport`, `provider.invalid-request`, or
unknown) ⇒ no sample, record `{code: status >= 400 ? status : 0, at:
time.created/1000}`. `tokens` stay at `data.tokens.output`. Streaming-stop
rule unchanged on `data.time.completed` absence (in-flight rows verified live:
`created`+`streamed` set, `completed` missing). The scan state gains a
`schemaVersion` field: loading a state file whose version is not 2 ⇒ reset
cursor to 0 and clear recentErrors (one-off re-backfill from the new table).

**Timestamp units**: `time.created`/`time.completed` are epoch **milliseconds**
(verified 13-digit). Divide by 1000. Sanity gate: a derived duration outside
`0.5 s … 3600 s` ⇒ `duration`/`tokensPerSecond` nil (a seconds-vs-ms
misread can never poison the baseline).

Scan cursor persisted to `~/Library/Application Support/Semafor/
opencode-scan-state.json` (`{ "cursor": Int, "lastScan": iso8601,
"recentErrors": [{ "code": Int, "name": String?, "at": iso8601 }] }`).

Per completed assistant message → one `ProbeSample`:

| field | derivation |
|---|---|
| provider | `.hal` |
| model | `data.modelID` (e.g. `Qwen3.8-Flash-Next`, fallback `qwen3.8-27b`) |
| sessionKey | `"opencode.db#\(rowid)"` |
| ttft | **always nil** — the db records no first-token time; the tok/s baseline learns independently (approved) |
| duration | `(time.completed − time.created) / 1000` when both present and inside 0.5 s…3600 s, else nil |
| tokensPerSecond | `tokens.output / duration` when both usable (`output ≥ 1`, duration gate above) |
| tokens | `tokens.output` (Int), nil when absent |
| outcome | `.ok` (a persisted assistant message completed by definition; `finish` recorded later if a failure marker ever appears) |
| timestamp | `time.created` |

Rows missing `time.completed` are streaming rows: the cursor is contiguous
and stops at the first such row, so the next tick re-reads from there
(`LIMIT 500` bounds the revisit). A row is consumed (cursor passes it) only
when it yielded a sample or was permanently unparseable.

### 3.2 Health: model-serving endpoint

`ProviderID.hal` provider's `fetchLimits()` performs
`GET \(baseURL)/models` with a 5 s timeout, no auth.

- 2xx → snapshot carries `servedModel: String?` (the model id from the list
  matching `halModelName`, else the first id, else nil). This drives the
  statusLine swap warning (§5).
- Transport failure (DNS, refused, timeout) → `ProviderError.network` →
  section renders unknown with reason `server_down`.
- 4xx/5xx → `.http(status)` → same unknown path, reason carries the status.

Health failure never touches measured samples: degradation verdicts stay
fresh until the 30-min sample freshness gate expires them.

### 3.3 Recent server errors (flagged, not verdict-affecting in v0)

Assistant rows may carry `error: { name, data: { message, statusCode,
isRetryable, ... } }` (verified live: `APIError` with `statusCode` 400, and
`MessageAbortedError` for user cancels). The scanner classifies each row:

- **`MessageAbortedError`** — user cancel, not a server fault: no sample,
  no error count.
- **`APIError` with `statusCode ≥ 400`** — no throughput sample (an errored
  request measures nothing); recorded as `HalErrorRecord { code: Int,
  at: Date }` in the scan state's `recentErrors` (cap 200, pruned past 7
  days, survives restarts).
- **`finish` empty/missing with no error and no `time.completed`** — still
  streaming; cursor stops there (§3.1).

Section rendering (`errorLineText`):

- any errors in the last 24 h → `"errors today: 2× 429 · 1× 500 · last 12m ago"`
  (per-day counts of `error.code`, most recent first; "last" omitted if none
  within 24 h of the newest).
- **amber** when the window holds a rate-limit/overload/server code
  (429, 500, 502, 503, 504, 529); otherwise grey (e.g. request-shape 4xx
  like the 400 seen live — surfaced, not alarming).
- v0 does not feed these into the verdict ladder; degradation still comes
  from measured tok/s only.

## 4. Architecture (approach A — approved)

Zero third-party dependencies is a project rule, so SQLite is reached
in-process through `systemLibrary`:

- `Sources/SemaforCore/SystemLibs/sqlite3.h` module map + `@_silgen_name`-free
  import via `import SQLite3` shim (module map with
  `header "sqlite3.h"` under systemLibrary — the standard pattern; ~15 lines).
- `OpenCodeDb.swift` (~150 lines): `open(readOnly)` with
  `SQLITE_OPEN_READONLY`; `prepare`/`step`/`finalize` wrapper returning
  `[[String: Any]]`-free typed rows (`rowid: Int64, data: String`).
  WAL caveat: read-only opening of a WAL db works while the owner process
  (OpenCode) keeps `-shm`/`-wal` readable; if the open fails (`SQLITE_CANTOPEN`/
  `SQLITE_BUSY`) the scanner skips the tick, logs nothing sensitive, and the
  30-min freshness gate does the rest. DB path comes from
  `NSHomeDirectory() + "/.local/share/opencode/opencode.db"`, overridable for
  tests via the settings key below.
- `OpenCodeDbScanner.swift`: owns the tick (60 s, driven by AppModel's scan
  timer alongside the log tailers), cursor state, sample emission into the
  same `SampleStore` (`.probe` records) and in-memory section refresh.
- `HalProvider.swift`: `Provider` conformance (health check only).
  `fetchLimits()` calls `GET \(baseURL)/models`, decodes
  `{ "data": [{ "id": String }] }`, records the served model on internal
  state (readable via `servedModel() async -> String?`; failures keep the
  last known value — snapshot staleness carries freshness instead), and
  returns zero windows. PollScheduler then surfaces `.network`/`.http` as
  `snapshot.lastError` via the existing error path. (Deviation from §3.2's
  "servedModel on snapshot": keeps `ProviderSnapshot` untouched; same UI
  outcome.) `statusPage()` returns `.unknown` without network; `sessionLogPaths`
  is `[]`. Protocol gains `var pollingEnabled: Bool { get }` with an
  extension default `true`; `HalProvider` returns `settings.halEnabled`
  and `PollScheduler` skips its loop while false (Claude/Codex unaffected).

`ProviderID` gains `hal` (menu-bar glyph `◈`). Sections render in
Claude/Codex/hal order. hal skips: control sampling, controls display,
LIMITED/BUSY/divergence verdict inputs (VerdictEngine rule list is
provider-aware; hal's ladder keeps UNKNOWN→CRAWLING/DEGRADED→OK from
measured samples only, and **hal verdicts do count in the menu-bar ladder**).

StatusLine (the compact menu text) shows a swap warning when the newest hal
measurement's `modelID` ≠ `halModelName` (vLLM currently serves one model at
a time; flash-next may silently fall back to vllm-qwen).

## 5. Settings

| key | default |
|---|---|
| `halEnabled` | `true` |
| `halBaseURL` | `http://hal:8000/v1` |
| `halModelName` | `Qwen3.8-Flash-Next` |
| `halDbPath` (advanced, empty = derived) | `""` |

`halEnabled = false` hides the section, stops the scanner and health poll;
stored samples are kept (store window ages them out naturally).

## 6. Dev tooling

`just live-scan hal` — reads the real OpenCode db once, prints sample
counts/percentiles (mirrors `just live-scan claude|codex`), never writes to
the store beyond a normal append.

## 7. Testing

- `OpenCodeDbTests`: build a throwaway sqlite db via the wrapper (WAL off),
  insert assistant rows, assert cursor semantics (resume after restart,
  streaming row revisited, providerID filter, malformed JSON skipped).
- `OpenCodeScannerTests`: fake clock; 60 s tick; emitted ProbeSample fields
  against fixture db rows incl. fallback model attribution and nil-ttft.
- `HalProviderTests`: URLProtocol fake server — 200 `/models` list → served
  model; refused → `.network` → `server_down` reason; 500 → `.http(500)`.
- Error classification (`HalScannerTests`): aborted rows silently consumed
  (no sample, no count), APIError rows → recorded, never sampled;
  `recentErrors` survives restart, prunes at 7 days, caps at 200; error-line
  copy + amber rule (429/5xx class vs benign 4xx) pinned in a pure
  ViewModel formatter test; epoch-ms units and the duration sanity gate
  (seconds-misread rows yield nil duration/tps, never a 3-day "usual").
- VerdictEngine: hal excludes controls/LIMITED/BUSY/divergence; degradation
  from tok/s-only samples colours correctly; hal counts in the ladder.
- ViewModel: hal section copy (no limit rows, "serving X" line, swap warning).

## 8. Privacy

The db contains conversation text. Only numeric/time fields listed in §3.1
are read; row `data` is parsed and discarded — nothing logged, nothing
persisted beyond derived `ProbeSample`s. `halBaseURL` may contain no
credentials (plain LAN URL assumed; documented).
