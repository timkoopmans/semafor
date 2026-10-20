# Semafor hal Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add the local Qwen box `hal` as a third monitored provider: passive samples from OpenCode's SQLite db, a `/models` health probe, recent-API-error flagging, and degradation verdicts in the menu-bar ladder.

**Architecture:** Read-only in-process SQLite through a `systemLibrary` CSQLite module (~150-line wrapper). A `HalScanner` actor polls the OpenCode db on the scan tick, decodes assistant-message JSON into `ProbeSample`s and `HalErrorRecord`s, and persists cursor + errors in `opencode-scan-state.json`. `HalProvider` implements the existing `Provider` protocol with a health-only `fetchLimits()`. App wiring, sections, and the verdict ladder treat hal like the other providers minus controls/limits/divergence.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, zero third-party deps (Apple system libs OK), macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-20-semafor-hal-monitoring-design.md` (verified against the live db: `message` columns are `id, session_id, time_created, time_updated, data`; `time.*` are epoch **milliseconds**; errors are `error.name` + `error.data.statusCode`)

## Global Constraints

- Zero third-party dependencies; `systemLibrary` CSQLite linking system `libsqlite3` is sanctioned.
- Nothing from the conversation db is ever logged or persisted beyond derived numeric fields (spec §8).
- Menu-bar glyph for hal is `◈`, display name `Qwen`, section order Claude → Codex → Qwen.
- Settings keys/defaults: `hal.enabled` = true, `hal.baseURL` = `http://hal:8000/v1`, `hal.modelName` = `Qwen3.8-Flash-Next`, `hal.dbPath` = `""` (empty ⇒ `~/.local/share/opencode/opencode.db`).
- Sample field rules (spec §3.1): `ttft` always nil; `tokens` = `tokens.output`; duration only when `(completed − created)/1000 ∈ [0.5, 3600]`.
- Every task ends with `swift test` green and its own commit; HEAD branch `feat/semafor-m3`.

## Review Focus

No task's tests exercise these directly — expect and handle:

1. **OpenCode db absent or WAL-locked** (OpenCode never ran on a fresh Mac, or the db sits mid-checkpoint): `OpenCodeDb` open throws `DbError.openFailed`; scanner logs nothing and skips the tick; hal ages to UNKNOWN via the freshness gate, never crashes.
2. **Cursor integrity against streaming/garbage rows**: each complete row is sampled exactly once across restarts; a permanently malformed row is consumed, a still-streaming row stops the cursor without consuming it — no stall, no double count.
3. **Health down while measurements are fresh / down and stale**: fresh samples keep degradation verdicts despite `/models` failing; only when samples are also stale does UNKNOWN with the `server_down` reason show.
4. **Aborted/cancelled messages**: `MessageAbortedError` rows produce neither samples nor error counts (user cancel ≠ server fault).
5. **ms-vs-s misread**: a rows' duration outside 0.5 s…3600 s yields nil duration/tok-s with `tokens` still recorded — a seconds-valued timestamp can never produce a 3-day "usual".

---

### Task 1: ProviderID.hal + settings keys

**Files:**
- Modify: `Sources/SemaforCore/Models.swift` (ProviderID, lines 3–21)
- Modify: `Sources/SemaforCore/Settings.swift` (Key enum + properties, after `baselineDefaultTokPerSec`)
- Test: `Tests/SemaforCoreTests/SettingsHalTests.swift` (new)

**Interfaces:**
- Consumes: nothing.
- Produces: `ProviderID.hal` (`displayName == "Qwen"`, `menuGlyph == "◈"`, last case of `allCases`); `AppSettings.halEnabled: Bool`, `halBaseURL: String`, `halModelName: String`, `halDbPath: String` with the Global Constraints' keys/defaults, same `value(...)`/`defaults.set` pattern as existing keys.

- [x] **Step 1: Write failing tests** — `SettingsHalTests`: defaults are `true` / `http://hal:8000/v1` / `Qwen3.8-Flash-Next` / `""` for a fresh `UserDefaults(suiteName: …unique…)`; set/get round-trips all four; `ProviderID.hal.displayName == "Qwen"`, `menuGlyph == "◈"`, `ProviderID.allCases.last == .hal`.
- [x] **Step 2: Run, verify fail** (`swift test`, undefined `.hal`).
- [x] **Step 3: Implement** the enum case + switches and the four settings properties.
- [x] **Step 4: `swift test` green.** Compile errors elsewhere (non-exhaustive switches) are fixed here, not stubbed away.
- [x] **Step 5: Commit** `git commit -m "Add hal provider identity and settings keys"`.

### Task 2: CSQLite module + OpenCodeDb wrapper

**Files:**
- Create: `Sources/CSQLite/module.modulemap`, `Sources/CSQLite/shim.h` (`#include <sqlite3.h>`)
- Modify: `Package.swift` (systemLibrary target `CSQLite`; SemaforCore depends on it)
- Create: `Sources/SemaforCore/Hal/OpenCodeDb.swift`
- Test: `Tests/SemaforCoreTests/Hal/OpenCodeDbTests.swift` (new)

**Interfaces:**
- Consumes: system `sqlite3` only.
- Produces:
```swift
public final class OpenCodeDb: @unchecked Sendable {   // actor-serialized use; not thread-safe itself
    public struct Row: Sendable { public let rowid: Int64; public let data: String }
    public enum DbError: Error, Equatable, Sendable { case openFailed(status: Int32), queryFailed(status: Int32) }
    public init(path: String, readOnly: Bool = true) throws   // SQLITE_OPEN_READONLY|FULLMUTEX for readOnly; busy_timeout 1000 ms
    public func rows(after cursor: Int64, limit: Int) throws -> [Row]   // SELECT rowid, data FROM message WHERE rowid > ? ORDER BY rowid LIMIT ?
    public func exec(_ sql: String) throws               // test/scan smoke only; requires readOnly: false
    public func close()
}
```
Open failure ⇒ `DbError.openFailed(status:)` (never fatal); `openFailed(SQLITE_NOTADB)` for garbage files.

- [x] **Step 1: Failing tests** — tmp-dir db created via `OpenCodeDb(path:readOnly:false)` + `exec` of `CREATE TABLE message (id text primary key, session_id text, time_created int, time_updated int, data text)` and 3 inserts: `rows(after:-1, limit:10)` returns rowids ascending, `limit:2` truncates, `rows(after:2,…)` skips; missing path throws `.openFailed`; read-only open of that file succeeds and `exec` throws `.queryFailed`.
- [x] **Step 2: Verify fail.** **Step 3: Implement** modulemap (`module CSQLite [system] { header "shim.h" link "sqlite3" }`), Package.swift target, wrapper (prepare/step/finalize with `sqlite3_column_int64`/`_text`; `defer` finalize on every path).
- [x] **Step 4: Green.** **Step 5: Commit** `"Add read-only SQLite wrapper for OpenCode db"`.

### Task 3: HalScanner measurement path

**Files:**
- Create: `Sources/SemaforCore/Hal/HalScanner.swift`
- Test: `Tests/SemaforCoreTests/Hal/HalScannerTests.swift` (new)

**Interfaces:**
- Consumes: `OpenCodeDb` (Task 2), `SampleStore.append(.probe(_:))`, `AppSettings.scanIntervalSeconds`, `ProbeSample` incl. `tokens` (existing).
- Produces:
```swift
public struct HalErrorRecord: Codable, Equatable, Sendable { public let code: Int; public let at: Date }
public actor HalScanner {
    public struct ScanState: Codable, Equatable { public var cursor: Int64; public var lastScan: Date?; public var recentErrors: [HalErrorRecord] }
    public init(dbPath: String, settings: AppSettings, store: SampleStore, stateURL: URL)
    public func start()                                     // Task loop: scanOnce every scanIntervalSeconds, never throws out
    @discardableResult public func scanOnce(now: Date) async throws -> Int   // samples appended this tick
    public func state() async -> ScanState                  // for tests/smoke
}
```
Row rules (spec §3.1): decode `data` JSON (`role, providerID, modelID, tokens.output, time.created, time.completed` — Int ms); non-assistant / non-hal / malformed ⇒ consumed (cursor advances, no sample); `error != nil` ⇒ handled Task 4 (this task: treat as consumed, no sample); `error == nil && time.completed == nil` ⇒ **stop, cursor stays**; else emit `ProbeSample(provider: .hal, model: modelID ?? "hal-unknown", sessionKey: "opencode.db#\(rowid)", ttft: nil, duration: gated, tokensPerSecond: output/duration, tokens: output ≥ 1 ? output : nil, outcome: .ok, timestamp: created/1000)`. State JSON written every tick (`.000Z` ISO8601, same `StoreDateCoding` format).

- [x] **Step 1: Failing tests** (fixture db built via Task-2 write path; store from `SampleStoreTests`-style temp config; fixed `now`):
  - `emitsSamplesWithSpecFields`: assistant+hal row created `T` completed `T+2931 ms`, output 180 ⇒ sample ttft nil, duration 2.931, tok/s ≈ 61.4 (180/2.931), tokens 180, model from `modelID`, sessionKey `opencode.db#<rowid>`, timestamp `T`.
  - `nonHalAndNonAssistantIgnoredButConsumed`, `malformedJsonConsumedNotStalled`.
  - `streamingRowStopsCursorUntilCompleted`: row lacking `time.completed` → 0 samples, cursor stays; append `time.completed`+`error`… (complete it), next `scanOnce` emits it.
  - `cursorResumesAcrossInstances`: second scanner same stateURL continues without re-emitting.
  - `secondsMisreadRowsFailDurationGate`: completed−created = 2 days of ms ⇒ duration/tok-s nil, tokens recorded.
- [x] **Step 2: Verify fail.** **Step 3: Implement** actor + DTO (`private struct MessageData: Decodable` with nested optionals; `JSONDecoder().decode(MessageData.self, from: Data(text.utf8))`).
- [x] **Step 4: Green.** **Step 5: Commit** `"HalScanner: passive samples from OpenCode db"`.

### Task 4: Error classification + recentErrors persistence

**Files:**
- Modify: `Sources/SemaforCore/Hal/HalScanner.swift`
- Test: `Tests/SemaforCoreTests/Hal/HalScannerTests.swift` (extend)

**Interfaces:**
- Consumes: Task 3 internals (`ScanState.recentErrors` already declared).
- Produces: `public func recentErrors(now: Date, window: TimeInterval) -> [HalErrorRecord]` (newest-first, filtered); classification per spec §3.3: `error.name == "MessageAbortedError"` ⇒ consumed, no sample, no record; `error.name == "APIError"` (or any other error name) with `data.statusCode ≥ 400` ⇒ no sample, record `{code, at: created/1000}`; cap 200 (drop oldest), prune `at < now − 7 d` every tick; missing/garbage `statusCode` ⇒ recorded as code 0.

- [x] **Step 1: Failing tests** — `abortedMessagesInvisible` (aborted rows: 0 samples, 0 records); `apiErrorRecordedNotSampled` (429 row ⇒ no probe sample, record code 429 at ms-correct time); `recordsPersistAndPrune` (restart reads back records; 8-day-old pruned; 250 inserted ⇒ cap 200 keeping newest); `garbageStatusCodeRecordsZero`.
- [x] **Step 2: Verify fail.** **Step 3: Implement** (extend `MessageData` with `error: ErrorInfo?`, `ErrorInfo { name: String?, data: ErrorPayload? }`, `ErrorPayload { statusCode: Int? }`).
- [x] **Step 4: Green.** **Step 5: Commit** `"HalScanner: flag recent hal API errors"`.

### Task 5: HalProvider health + polling gate

**Files:**
- Create: `Sources/SemaforCore/Hal/HalProvider.swift`
- Modify: `Sources/SemaforCore/Provider.swift` (protocol + extension), `Sources/SemaforCore/Polling/PollScheduler.swift` (skip when `!pollingEnabled`)
- Test: `Tests/SemaforCoreTests/Hal/HalProviderTests.swift` (new), PollScheduler test file (extend)

**Interfaces:**
- Consumes: `HTTPClient`, `fetchJSON(_:request:client:)`, `EndpointRequest`, `AppSettings.halBaseURL/halModelName/halEnabled`, existing `StubHTTPClient` test fake.
- Produces:
```swift
public final class HalProvider: Provider, @unchecked Sendable {
    public init(http: any HTTPClient, settings: AppSettings)
    public func servedModel() async -> String?       // last successful pick; kept across failures
    public var pollingEnabled: Bool { settings.halEnabled }
}
extension Provider { public var pollingEnabled: Bool { true } }   // Claude/Codex unaffected
```
`fetchLimits()`: GET `\(trimTrailingSlash(settings.halBaseURL))/models` via `fetchJSON` decoding `{"data":[{"id":String}]}` → record pick (`id == halModelName` ⇒ that, else first, empty ⇒ nil), return `[]`. Errors surface via `fetchJSON`'s existing mapping (`.network`/`.http`/`.decoding`). `statusPage()` ⇒ `.unknown` without network; `sessionLogPaths` ⇒ `[]`. PollScheduler: skip `runFetch`/loop iteration while `pollingEnabled == false` (existing snapshot stays; UI hides section anyway).

- [x] **Step 1: Failing tests** — `fetchLimitsSucceedsWithNoWindows` + `servedModelPicksExactThenFirstThenNil`; `failureKeepsLastServedModel` (stub throws after a success ⇒ `.network`, servedModel unchanged); `httpStatus500MapsToHttp`; `disabledStopsSchedulerPolling` (settings.halEnabled = false ⇒ PollScheduler never calls fetchLimits for .hal; Claude still polled).
- [x] **Step 2: Verify fail.** **Step 3: Implement.** **Step 4: Green.** **Step 5: Commit** `"HalProvider: /models health probe and polling gate"`.

### Task 6: App wiring, hal section UI, settings UI

**Files:**
- Modify: `Sources/SemaforApp/SemaforApp.swift` (AppModel: lines ~36, 123–200), `Sources/SemaforCore/ViewModels/ViewModels.swift`, `Sources/SemaforApp/MenuContentView.swift`, `Sources/SemaforApp/SettingsView.swift`
- Test: `Tests/SemaforCoreTests/ViewModelsVerdictsTests.swift` (extend)

**Interfaces:**
- Consumes: Tasks 1–5 (`HalScanner(dbPath:settings:store:stateURL:)`, `HalProvider`, `recentErrors(now:window:)`, `AppSettings.halDbPath`).
- Produces: `ProviderSectionModel` init gains `servingText: String? = nil, errorLineText: String? = nil, errorLineIsAmber: Bool = false`; `static func halErrorLine(records: [HalErrorRecord], now: Date, calendar: Calendar) -> (text: String, amber: Bool)?` (spec §3.3: nil when none in last 24 h; `"errors today: 2× 429 · 1× 500 · last 12m ago"` — same-day grouped counts, codes descending; " · last Xm ago" omitted when the newest is older than 24 h; amber when any record within 24 h has code in `[429, 500, 502, 503, 504, 529]`).

AppModel: construct + retain `HalProvider` (added to the scheduler `providers:` array) and `HalScanner` (stateURL `directory/opencode-scan-state.json`; db path `settings.halDbPath.isEmpty ? NSHomeDirectory() + "/.local/share/opencode/opencode.db" : settings.halDbPath`); start it where the prober starts; replace both `for id in [ProviderID.claude, .codex]` loops with `enabledProviderIDs` = `[.claude, .codex] + (settings.halEnabled ? [.hal] : [])`; hal section built with `servingText` = `"serving \(served)"` or `"serving unknown"`, appending `" · not \(settings.halModelName) ⚠"` when served ≠ `halModelName` (swap warning), `measuredToday` = count of `bundle.probes` with `.ok` in local today, error line from `halScanner.recentErrors(now:window: 86_400)` through `halErrorLine`. MenuContentView: `servingText` as secondary caption under the header, `errorLineText` under the token bars, `.orange` when amber else tertiary (reuse the bars' row pattern). SettingsView: "Local Qwen (hal)" section — Toggle + three `LabeledContent` rows via the existing numberField/text row helpers.

- [x] **Step 1: Failing VM tests** — `halErrorLineFormatsGroupsAndAmbers` (two 429 + one 500 within 1 h ⇒ exact text + amber; only a 400 ⇒ text, not amber; empty/old ⇒ nil), `swapWarningComposedInServingText` via `ProviderSectionModel` construction.
- [x] **Step 2: Verify fail.** **Step 3: Implement** wiring + UI. **Step 4: Green** (`swift build` catches AppModel drift). **Step 5: Commit** `"Wire hal into app, popover, and settings"`.

### Task 7: Verdict semantics, smoke CLI, ship

**Files:**
- Modify: `Sources/SemaforCore/Verdicts/VerdictEngine.swift` (only if the empty-controls guard is missing — check first), `Sources/SemaforSmoke/main.swift`, `justfile` comment, `CHANGELOG.md`
- Test: verdict tests (existing VerdictEngine test file, extend)

**Interfaces:**
- Consumes: everything above.
- Produces: hal-safe verdict rules + `swift run SemaforSmoke scan hal [--days N]`; `just live-scan hal` (existing generic task passes through — verify).

- [x] **Step 1: Failing verdict tests** — `halNeverSeesControlOrLimitVerdicts` (zero control samples ⇒ no `"control"` reason — add `!freshControls.isEmpty` guard if the existing code lacks it; empty `windows` ⇒ never LIMITED/BUSY); `halTokOnlySamplesDriveDegradation` (recent hal tok/s ≪ median ⇒ CRAWLING via tok/s rule with all ttft nil); `halCountsInMenuBarLadder` (`StatusItemModel.title` surfaces hal's degraded when others OK); `divergenceIgnoresHal` (hal degraded + others OK + no status ⇒ nil divergence).
- [x] **Step 2: Verify fail.** **Step 3: Implement** guard fix (if needed) + smoke branch mirroring the claude/codex branch: scanner one-shot on a **temp stateURL** (never disturb the app's cursor file) against the real db path, print n, tok/s percentiles, error-code histogram via `redact(...)` (counts only — no row content ever printed).
- [x] **Step 4: `swift test` green; run `just live-scan hal` against the real db and confirm sane numbers** (compare tok/s median against `sqlite3` spot check; error histogram non-crashing).
- [x] **Step 5: Commit**, then `just package 0.3.0` and deploy to `~/Applications/Semafor.app` (remember: shell needs `workdir` at the repo root); launch, eyeball hal section (serving line, tiles, bars, error line — no store wipe needed).
- [x] **Step 6: Update ledger** `.superpowers/sdd/2026-10-20-semafor-m3/progress.md`; commit.

## Completion notes (2026-10-20)
- All 7 tasks landed at 662faf6, final whole-branch review clean (3 Importants found and fixed), 224/224.
- Task 7 step 5: packaged + deployed 0.3.0, pipeline verified mechanically (cursor 1006, 899 hal probes, health fetch clean, serving line = Qwen3.8-Flash-Next). Popover eyeball pending operator on first click (dogfood ≥1 day before merge to main).
- Task 7 step 6: ledger lives in gitignored .superpowers/ (no commit) — per controller ruling.
