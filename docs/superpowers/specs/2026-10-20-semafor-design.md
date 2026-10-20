# Semafor — subscription frontier-model status monitor

- **Date:** 2026-10-20
- **Status:** revision 2 — passive-first measurement (re-approve §5–§9, §12–§14)
- **Author:** Tim Koopmans (brainstormed with Claude)
- **Revision 2 (2026-10-20, after M3 spike):** active latency probes removed. Measurement is
  **passive**: latency/throughput are derived from the CLIs' own session logs while Tim works
  (verified on real data: Claude Code logs pair `api-request`↔`assistant.requestRef` with
  timestamps giving per-call latency + tok/s; Codex rollouts give turn durations + token
  counts). The question being answered is "am I going crazy *while working*", and passive
  data answers it for free — zero quota burn, zero ToS exposure, and it measures the model
  actually in use (`requestedModel`, e.g. Opus 5.5 in squizz work) rather than a synthetic
  probe target. Spike evidence: Anthropic client-gates direct `/v1/messages` with OAuth tokens
  anyway (fake 429s). The HTTP control probe stays (unauthenticated GET — it is what separates
  "VPN flake" from "provider crawl"). Codex OAuth refresh stays out: the CLI owns the rotating
  refresh token; expiry keeps the "run `codex` once" hint.
- **One-liner:** A native macOS menu bar app that tells you whether your subscription frontier models (Claude, GPT‑6 Astra) are rate-limited, degrading, or about to run dry — *measured*, not as advertised by status pages.

## 1. Problem

Existing tooling answers the wrong question:

- **Token Monitor.app** (installed) counts tokens across ~40 tools. It is an archive, not a gauge. It cannot answer "am I restricted right now?"
- **CodexBar / ai-usage-bar / SwiftBar plugins** show official rate-limit windows and poll *official status feeds* for incident badges. Official feeds report what providers admit. Observed failure (2026‑10‑19): both status pages green while frontier models crawled. No existing tool measures what the models actually feel like.

The pain, in order of severity:
1. Provider status says OK; frontier models are crawling. Undetectable by status-page polling.
2. No visibility into window utilization, reset times, or pace — "can I start a big task now, or will I hit the weekly cap Thursday?"
3. Silent throttling/capacity events (429, overloaded) are visible only as bad UX inside a session.

## 2. Goals / Non-goals

**Goals (v1)**
- One glance in the menu bar: worst state across Claude + Codex/Astra, with utilization %.
- Popover: per-provider usage windows with reset countdowns, burn-rate projection ("at this pace, weekly window gone by ~Thu 14:00"), measured TTFT / tokens-per-sec trends, and a **status-divergence banner** when official status disagrees with measurement.
- Notifications on state transitions into LIMITED / DEGRADED / CRAWLING and on recovery.
- Capacity-event log from local CLI session files (429s, "hit your limit", overloaded).
- Network-vs-provider disambiguation (local VPN/network can't be mistaken for provider degradation).

**Non-goals (v1, deliberate)**
- Any provider beyond Claude + Codex/Astra (no OpenCode, Cursor, Gemini, …). Provider protocol makes later additions cheap.
- Token/cost history (Token Monitor's job; Semafor stores only its own probe/limit samples).
- Multi-account, teams, mobile, App Store distribution, auto-update.
- Astra *spend attribution* (per-task cost); we only note multiplier modes affect drain rate.

## 3. Product decisions (from brainstorm)

| Decision | Resolution |
|---|---|
| Gap vs existing tools | Limits & health, not token counts |
| Form factor | Menu bar app, Beacon-style (native Swift, no Dock icon) |
| Signals | Official usage endpoints + passive session-log latency/throughput measurement + burn-rate projection + HTTP control probe + status-page cross-check |
| Measurement | Passive-first from session logs (revision 2); HTTP control probe for network separation (see §7) |
| Codebase strategy | From scratch, reusing Beacon patterns (not a CodexBar fork; ai-usage-bar is too thin to fork meaningfully) |

## 4. Shape

- Swift 6.2, SwiftPM, macOS 14+, `LSUIElement`, SwiftUI `MenuBarExtra`.
- One package: targets `SemaforCore` (library), `SemaforApp` (executable), `SemaforCoreTests`.
- `justfile` + `scripts/` packaging pattern copied from Beacon (`just build`, `just run`, `dist/` artifact; unsigned local build).
- App name: **Semafor** (rename before M1 if Tim prefers another).

## 5. Architecture

```
                     ┌────────────────────────────────────────────┐
                     │                SemaforApp                   │
                     │  MenuBarExtra UI · notifications · settings │
                     └──────────────▲──────────────┬───────────────┘
                                    │ Verdict stream │ commands
                     ┌──────────────┴──────────────┐│
                     │        VerdictEngine        ││
                     │  state rules + burn-rate     ││
                     │  headline + divergence       ││
                     └───▲──────▲──────▲──────▲─────┘│
                          │      │      │      │      │
             ┌────────────┐│ ┌────┴─────┐ ┌────┴────┐ ┌─┴──────────────┐
             │ limit      ││ │Passive   │ │Capacity │ │ StatusPage     │
             │ snapshots  ││ │Prober +  │ │Events   │ │ Watcher        │
             └─────▲──────┘│ │baseline  │ │  (M4)   │ │                │
                   │       │ └────▲─────┘ └────▲────┘ └─▲──────────────┘
                   │       │      │            │        │
             ┌─────┴───────┴──────┴────────────┴────────┴─────┐
             │            Providers (Claude, Codex)            │
             │   fetchLimits() · statusPage() · ControlProbe   │
             └───────────────────────┬─────────────────────────┘
                                     │ session-log paths
                     ┌───────────────┴───────────────┐  append-only JSONL
                     │  SessionLogTailer (M3)        │  ┌────────────────┐
                     │  offsets + activity signal    │  │  SampleStore   │
                     └───────────────────────────────┘  └────────────────┘
```

Units, each independently testable:

| Unit | Responsibility | Depends on |
|---|---|---|
| `Provider` (protocol) | Uniform access to one subscription's limits, official status, and session-log locations | — |
| `ClaudeProvider` | Keychain OAuth → usage endpoint + status feed | Keychain, URLSession |
| `CodexProvider` | `auth.json` OAuth → usage endpoint + status feed | `~/.codex`, URLSession |
| `SessionLogTailer` | Incremental tailing of CLI JSONL with byte-offset tracking; activity timestamps | disk |
| `PassiveProber` | Derives latency/throughput `ProbeSample`s from tailed lines (completion + dedupe rules); launch backfill | SessionLogTailer |
| `ControlProbe` | Unauthenticated HTTP GET of provider domains; network-vs-provider separation | URLSession |
| `BurnRateEstimator` | Pace check + time-to-exhaustion per window | SampleStore |
| `VerdictEngine` | Pure state rules → per-provider verdict + reasons + headline | all above |
| `SampleStore` | Append-only JSONL ring, 30-day retention, actor-isolated | disk |
| `StatusPageWatcher` | Official status polling for divergence comparison | URLSession |
| `Settings` | User-configurable policy (UserDefaults-backed) | — |

### 5.1 Provider protocol (interface sketch)

```swift
protocol Provider: Sendable {
    var id: ProviderID { get }            // .claude | .codex
    func fetchLimits() async throws -> [UsageWindow]
    func statusPage() async throws -> StatusPageState
    var sessionLogPaths: [URL] { get }    // feeds SessionLogTailer
}

struct UsageWindow: Codable, Sendable {
    let name: WindowName        // .fiveHour | .sevenDay | .primary | .secondary
    let usedPercent: Double?    // nil = not reported
    let windowSeconds: Int?     // 18_000 | 604_800 | reported | nil
    let resetsAt: Date?
    let fetchedAt: Date
}

struct ProbeSample: Codable, Sendable {   // one passive measurement
    let provider: ProviderID
    let model: String                     // requestedModel from the log (e.g. "claude-opus-5-5")
    let ttft: TimeInterval                // request line → first streamed content line
    let duration: TimeInterval?           // request line → final streamed line
    let tokensPerSecond: Double?          // outputTokens/duration; nil when not derivable
    let outcome: ProbeOutcome             // .ok | .timeout (stalled) | .streamFailure | .authError | …
    let timestamp: Date                   // request start
}

struct CapacityEvent: Codable, Sendable { // from session logs (M4)
    let provider: ProviderID
    let kind: Kind                        // .rateLimit429 | .planLimit | .overloaded | .stall
    let detail: String?
    let at: Date
}
```

## 6. Data sources

All credentials are *already on this machine*; Semafor only reads what the CLIs themselves use, and talks only to the owning provider's endpoints.

### 6.1 Claude (Claude Code, OAuth in macOS Keychain)

- **Token:** generic password item `Claude Code-credentials` (account: current user) → JSON `claudeAiOauth.accessToken`. Re-read every cycle so CLI-initiated refresh is picked up. First read triggers one Keychain permission prompt; add an in-app hint.
- **Limits:** `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>` (+ OAuth beta header) → five-hour and seven-day windows: utilization + reset timestamp. *(Exact field names to be pinned in the M1 live spike; decode behind a tolerant DTO.)*
- **Measurement (passive):** derived from `~/.claude/projects/**/*.jsonl`. Each API call is logged as an `api-request` line (`id`, `timestamp`, `params.model`, `querySource`) joined to its streamed `assistant` lines via `requestRef` (server `requestId` also present, usage incl. `output_tokens` per line, `requestedModel`). Per call: TTFT proxy = first assistant line − request line; full duration = last line − request line; tok/s = `max(output_tokens across lines)/duration`. Only main-thread traffic (`querySource == "repl_main_thread"`) counts. *Verified on live logs 2026-10-20: 97 calls from one work session, median 3.7 s to first block, median 74 tok/s.* No active probe: direct `/v1/messages` with the OAuth token is client-gated (bogus 429s, spike 2026-10-20) and would burn quota for a synthetic signal.
- **Session logs:** `~/.claude/projects/**/*.jsonl`.
- **Status feed:** `https://status.claude.com/api/v2/status.json` (status.anthropic.com 301s here; Statuspage format, spike-pinned).

### 6.2 Codex / Astra (ChatGPT subscription OAuth in `~/.codex/auth.json`)

- **Token:** `tokens.access_token` + `tokens.account_id` (sent as account header). The Codex CLI owns OAuth refresh — its refresh token is single-use/rotating, so Semafor never refreshes or writes back (would race the CLI); on expiry the UI keeps the "run `codex` once" hint (spec §10). Codex CLI ≥ 0.153.0 (installed: 0.163.0) — Astra-capable.
- **Limits:** `GET https://chatgpt.com/backend-api/codex/usage` → `rate_limits` primary/secondary windows: `used_percent`, `resets_at`, window lengths. This allowance is shared by Work/Codex incl. Astra; Fast/Ultrafast drain it faster (multiplier) — surfaced as context, not modeled. *(Pinned in M1 spike.)*
- **Measurement (passive):** derived from `~/.codex/sessions/**/rollout-*.jsonl`. `event_msg` lines carry per-line timestamps: `task_started`→`task_complete` gives turn duration; `event_msg:token_count` (+ `token_usage_record`) carries cumulative usage → tok/s from Δtokens/Δt **restricted to adjacent-event bursts (< 30 s apart)** so tool/think gaps don't masquerade as a crawling model; TTFT proxy = `task_started` → first `response_item` after it, **counted only for turns without `function_call` items** (tool-free turns). Model from rollout meta (`gpt-6-astra`). Turn-level granularity — Claude-quality per-request pairing isn't available; that asymmetry is accepted. No active probe: `chatgpt.com/backend-api/codex/responses` streaming works (spike-pinned, see `docs/superpowers/spike/2026-10-20/`) but is unnecessary quota spend under the passive-first decision.
- **Session logs:** `~/.codex/sessions/**` (and `history.jsonl` as secondary).
- **Status feed:** `https://status.openai.com/api/v2/status.json` (Statuspage format, spike-pinned).

## 7. Measurement policy (passive-first)

- **Tailer:** `SessionLogTailer` keeps byte offsets per file and re-reads only appended bytes (mtime+size poll every 60 s, configurable, ±20 % jitter — no FSEvents needed at this cadence). Torn trailing lines are held back until complete.
- **Activity signal:** any session-log append across a provider's dirs within the last 10 min ⇒ `active` (the tailer's own offsets are the signal; shared with burn-rate and M4 capacity extraction).
- **Launch backfill:** once at startup, read the last 7 days (configurable) of logs to seed baselines — learned baselines from day one instead of 20-samples-from-scratch.
- **Completion & dedupe:** a Claude request's sample is emitted only once its stream looks complete (no new `requestRef` lines for ≥ 2 s, or a later `api-request` supersedes it); dedupe key = (file path, request key). Tailer offsets persist to a small JSON state file beside the store; on missing state the backfill re-reads and the store read path dedupes by that key, so restarts never double-count. Codex turn samples emit on `task_complete`.
- **Filtering:** Claude — `querySource == "repl_main_thread"` only; calls with < 10 output tokens ignored. Codex — tok/s only from adjacent `token_count` bursts (< 30 s apart); TTFT proxy only from tool-free turns.
- **Control probe (network baseline):** while measuring (any sample in the last 15 min), one unauthenticated HTTP GET of a static asset on the provider's domain (e.g. `robots.txt`, 10 s timeout) per provider per 5 min. If control latency is also bad (last 3 consecutive ≥ 5 s or failed) ⇒ `UNKNOWN(network)` and no degradation alerts or divergence banner.
- **Cost guard:** none needed beyond the control-probe cadence — passive reads consume no quota and issue no provider-authenticated requests; zero retries everywhere. (The old daily-cap machinery is dropped with active probes.)

## 8. Analysis & verdicts

### 8.1 Baselines (per provider+model — `mode` retired from `ProbeSample` with active probing)

Segments: weekday/weekend × 4 time-of-day buckets. For each of **TTFT** and **tok/s**: median + MAD over retained samples. A learned baseline activates once a segment has ≥ 20 samples; otherwise absolute defaults (TTFT ≤ 8 s, tok/s ≥ 20; configurable). Degradation z-score: `z = |x − median| / max(MAD, floor)`.

### 8.2 Verdict ladder (pure function — all inputs explicit)

Priority: `UNKNOWN > LIMITED > CRAWLING > DEGRADED > BUSY > OK`.

**Freshness:** probe-based rules (CRAWLING/DEGRADED and probe-derived UNKNOWN) consider only samples within a recency window (default 30 min). Outside it, nothing was measured — the verdict is computed from limits alone (OK/BUSY/LIMITED/auth-UNKNOWN); "unmeasured" is not a state. Sparklines keep 24 h regardless.

| State | Rule |
|---|---|
| `UNKNOWN` | auth expired/missing, or (while measuring) control probe bad |
| `LIMITED` | any window `usedPercent ≥ 98` **or** capacity event of kind `.rateLimit429`/`.planLimit` within last 10 min |
| `CRAWLING` | N=3 consecutive probes with `z(tok/s) > 6` or `z(TTFT) > 6` (vs learned baseline; defaults pre-learn) |
| `DEGRADED` | N=3 consecutive probes past `z > 3` on either metric |
| `BUSY` | any window ≥ 80 % used **or** pace warning (used% exceeds elapsed% of window by > 15 points) |
| `OK` | otherwise |

Every verdict carries `reasons: [VerdictReason]` (which rule fired, with numbers) — the popover always shows *why*.

### 8.3 Burn-rate projection

From limit snapshots over the active window: slope = Δused% / Δt over the trailing ≥ 2 h of samples; if slope > 0, ETA = now + (100 − used%) / slope, rendered "at this pace, weekly window gone ~Thu 14:00 (±2 h)" — ± derived from slope variance (wider when sparse). Slope ≈ 0 ⇒ "no measurable drain in the last 2 h." Pace check per window: `used% − elapsed%` (> 15 pt ⇒ ahead-of-pace warning, feeds `BUSY`).

### 8.4 Divergence banner

Active when our state is `DEGRADED/CRAWLING/LIMITED` (confidence: ≥ N probes or capacity event) while both relevant official status components report operational: *"Status pages: ✅ operational · ours: Astra crawling, 9 tok/s, TTFT 21 s."* Suppressed when `UNKNOWN(network)`.

## 9. UI

- **Menu bar:** merged icon (one status item by default): provider glyph + worst `used%` (e.g. `◐ 62%`); per-provider icons optional. State color: green (OK) · amber (BUSY/DEGRADED) · red (LIMITED/CRAWLING) · hollow/greyed (UNKNOWN).
- **Popover:** per provider: window bars + `resets in 3h 12m` · burn-rate headline · TTFT & tok/s sparklines (last 24 h, segment-adjusted) · divergence banner · recent capacity events · `Test now` · `Pause`. Footer: last poll, settings, quit.
- **Settings:** thresholds (z, N, BUSY %, pace delta), scan interval, recency window, backfill days, control-probe toggle, notification toggles, launch-at-login (SMAppService), data reset. (Probe-model, Fast-mode, cadence and cap settings retired with active probes.)
- **Notifications (UNUserNotificationCenter):** verdict transitions into LIMITED/DEGRADED/CRAWLING (debounced by the N-probe rule; ≥ 30 min re-alert cooldown), recovery (`back to OK`), window resets. Nothing else — no noise.

## 10. Error handling & safety

- **Expired token:** state `UNKNOWN(auth)` + popover hint "run `claude` / `codex` once"; never a notification, never a crash loop.
- **Endpoint drift:** every provider decode goes through a permissive DTO with captured raw-sample (sanitized) for debugging; provider errors map to `UNKNOWN(provider-api)` with the detail in popover.
- **No retry storms:** one attempt per cycle per call; failures just age the snapshot. Stale-data display: data older than 3× poll interval dims + "stale" label.
- **Privacy:** tokens read locally, sent only to owning provider; never logged, never in sample store, never leave the machine. Sample store contains only probe/limit/status records. Logs scrubbed of bearer strings. Local-only app; no update server; no analytics.
- **Uninstall:** app + Application Support dir; launch agent removed via SMAppService.

## 11. Sample store

Actor-wrapped append-only JSONL under `~/Library/Application Support/Semafor/`:
`limits.jsonl` · `probes.jsonl` · `events.jsonl` · `status.jsonl`.
Rotation: daily file per type, retain 30 days or 50 MB per type (whichever hits first). All writes additive; readers tolerate trailing partial lines (crash-safe). Settings: UserDefaults.

## 12. Testing

- **Fixture unit tests:** recorded (sanitized) JSON per endpoint → DTO decode tests; contract-break smoke tests run via opt-in `just live-smoke` against real endpoints.
- **Pure math:** burn-rate slope/ETA, pace check, z-score/baseline learning, verdict ladder (exhaustive rule table incl. priority ties).
- **Log watcher:** synthetic Claude/Codex JSONL fixtures (incl. 429/overloaded markers) → expected CapacityEvents + activity signal.
- **Passive extraction:** sanitized real session-log fixtures (Claude `api-request`/`assistant` pairs incl. `requestRef` joins; Codex `task_started`/`token_count`/`task_complete` sequences) with synthetic timestamps → expected `ProbeSample`s covering TTFT proxy, tok/s, completion/dedupe rules, and `querySource`/tool-turn/output-token filtering; control-probe mapping tests. No stub server needed — nothing streams live anymore.
- **Providers:** fake `Provider` injection for VerdictEngine/UI; Keychain + auth.json access behind thin adapters with fakes.
- **UI:** view-model tests only; no snapshot tests in v1.

## 13. Milestones

| # | Deliverable | Acceptance |
|---|---|---|
| M1 | Scaffold + both providers + popover with live windows/resets | Menu bar shows real % for Claude & Codex; live spike pins endpoint/field shapes; probe path stubbed |
| M2 | SampleStore + burn-rate headline + pace warnings | "gone ~Thu" headline matches hand-check on a busy week |
| M3 | SessionLogTailer + PassiveProber + baselines + verdicts + divergence banner | Injected slow-session fixtures (real-log shaped) yield CRAWLING + divergence banner; VPN-flake fixture (bad control) suppresses it; backfill seeds baselines from 7 days of history |
| M4 | Capacity-event extractor on the tailer + notifications + settings polish + launch-at-login | 429 injected into fixture session fires event; transitions notify once with cooldown |

Each milestone: `just test` green, dogfooded ≥ 1 day before the next.

## 14. Open questions (non-blocking)

1. ~~Claude frontier probe target~~ **resolved (revision 2):** moot — passive measurement keys on `requestedModel` from the logs (observed: Opus 5.5 in squizz work); nothing to choose.
2. ~~Astra Fast-mode probe default~~ **retired (revision 2):** no active probes.
3. Repo name/visibility: `semafor`, private GitHub later? (local init now)
4. Icon glyph preference (semaphore vs. fuel-gauge vs. signal-bars).
