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

`~/.local/share/opencode/opencode.db` (SQLite, WAL mode). The `message` table
carries `role`, `providerID`, and `data` (JSON) with keys:
`cost, tokens{total,input,output,reasoning,cache}, modelID, providerID,
time{created,completed}, finish, parentID, role, mode, agent, path`.

Scanner query per 60 s tick:

```sql
SELECT rowid, data FROM message
WHERE role = 'assistant' AND providerID = 'hal' AND rowid > :cursor
ORDER BY rowid LIMIT 500
```

(If `providerID` turns out not to be a real column, the same filter via
`json_extract(data,'$.providerID')` — decided at implementation time from the
live schema; tests cover whichever shape ships.)

Scan cursor persisted to `~/Library/Application Support/Semafor/
opencode-scan-state.json` (`{ "cursor": Int, "lastScan": iso8601 }`).

Per completed assistant message → one `ProbeSample`:

| field | derivation |
|---|---|
| provider | `.hal` |
| model | `data.modelID` (e.g. `Qwen3.8-Flash-Next`, fallback `qwen3.8-27b`) |
| sessionKey | `"opencode.db#\(rowid)"` |
| ttft | **always nil** — the db records no first-token time; the tok/s baseline learns independently (approved) |
| duration | `time.completed − time.created` when both present, else nil |
| tokensPerSecond | `tokens.output / duration` when both usable (`output ≥ 1`, `duration ≥ 0.5 s`) |
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
- `HalProvider.swift`: `ProviderFetching` conformance (health check only).
  `fetchLimits()` maps the `/models` response onto the existing
  `ProviderSnapshot` shape with zero usage windows and `servedModel`.

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
- VerdictEngine: hal excludes controls/LIMITED/BUSY/divergence; degradation
  from tok/s-only samples colours correctly; hal counts in the ladder.
- ViewModel: hal section copy (no limit rows, "serving X" line, swap warning).

## 8. Privacy

The db contains conversation text. Only numeric/time fields listed in §3.1
are read; row `data` is parsed and discarded — nothing logged, nothing
persisted beyond derived `ProbeSample`s. `halBaseURL` may contain no
credentials (plain LAN URL assumed; documented).
