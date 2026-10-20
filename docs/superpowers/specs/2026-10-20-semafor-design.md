# Semafor — subscription frontier-model status monitor

- **Date:** 2026-10-20
- **Status:** spec ready — awaiting Tim's review
- **Author:** Tim Koopmans (brainstormed with Claude)
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
| Signals | Official usage endpoints + local CLI log sniffing + burn-rate projection + active latency probes + status-page cross-check |
| Probe cadence | Adaptive, activity-aware (see §7) |
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
            ┌────────────┐│ ┌────┴───┐ ┌────┴────┐ ┌─┴──────────────┐
            │ limit      ││ │ProbeSched│ │Capacity │ │ StatusPage     │
            │ snapshots  ││ │+ baseline│ │Events   │ │ Watcher        │
            └─────▲──────┘│ └────▲───┘ └────▲────┘ └─▲──────────────┘
                  │       │      │          │        │
            ┌─────┴───────┴──────┴──────────┴────────┴─────┐
            │            Providers (Claude, Codex)          │
            │  fetchLimits() · probe() · statusPage()       │
            │  + SessionLogWatcher (FSEvents on CLI dirs)   │
            └───────────────────────┬───────────────────────┘
                                    │ append-only JSONL ring
                            ┌───────┴────────┐
                            │  SampleStore    │
                            └────────────────┘
```

Units, each independently testable:

| Unit | Responsibility | Depends on |
|---|---|---|
| `Provider` (protocol) | Uniform access to one subscription's limits, probes, status, logs | — |
| `ClaudeProvider` | Keychain OAuth → usage endpoint + `/v1/messages` probe | Keychain, URLSession |
| `CodexProvider` | `auth.json` OAuth → usage endpoint + Codex Responses probe | `~/.codex`, URLSession |
| `SessionLogWatcher` | Activity timestamps + capacity events from CLI JSONL | FSEvents |
| `ProbeScheduler` | When/whether to probe (adaptive policy), owns baselines | SessionLogWatcher |
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
    func probe(_ model: ProbeModel) async throws -> ProbeSample
    func statusPage() async throws -> StatusPageState
    var sessionLogPaths: [URL] { get }
}

struct UsageWindow: Codable, Sendable {
    let name: WindowName        // .fiveHour | .sevenDay | .primary | .secondary
    let usedPercent: Double?    // nil = not reported
    let windowSeconds: Int?     // 18_000 | 604_800 | reported | nil
    let resetsAt: Date?
    let fetchedAt: Date
}

struct ProbeSample: Codable, Sendable {   // one probe outcome
    let provider: ProviderID
    let model: String                     // e.g. "gpt-6-astra", claude model id
    let mode: ProbeMode                   // .standard | .fast (codex only)
    let ttft: Duration                    // first token / first response byte
    let tokensPerSecond: Double?          // decode throughput; nil on failure
    let outcome: ProbeOutcome             // .ok | .timeout | .httpError(Int) | .authError | .network
    let timestamp: Date
}

struct CapacityEvent: Codable, Sendable { // from session logs
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
- **Probe:** `POST https://api.anthropic.com/v1/messages`, `stream: true`, fixed constant prompt, `max_tokens ≈ 120`, model from settings (default: Opus-tier frontier model; plus Haiku control canary, see §7). Measure TTFT at first content event; tokens/sec from content delta cadence.
- **Session logs:** `~/.claude/projects/**/*.jsonl`.
- **Status feed:** status.anthropic.com component/summary endpoint.

### 6.2 Codex / Astra (ChatGPT subscription OAuth in `~/.codex/auth.json`)

- **Token:** `tokens.access_token` + `tokens.account_id` (sent as account header). Refresh via the CLI's OAuth token endpoint when the stored token 401s or `last_refresh` is stale beyond a TTL; refresh token kept in the same file, never copied elsewhere. Codex CLI ≥ 0.153.0 (installed: 0.163.0) — Astra-capable.
- **Limits:** `GET https://chatgpt.com/backend-api/codex/usage` → `rate_limits` primary/secondary windows: `used_percent`, `resets_at`, window lengths. This allowance is shared by Work/Codex incl. Astra; Fast/Ultrafast drain it faster (multiplier) — surfaced as context, not modeled. *(Pinned in M1 spike.)*
- **Probe:** `POST https://chatgpt.com/backend-api/codex/responses` (the Codex CLI's own streaming endpoint), model from settings (default `gpt-6-astra`, mode `.standard`), fixed ~120-token prompt, SSE-timed exactly like the Claude probe. Optional `.fast` probe behind a setting (default off). Fallback if the endpoint churns: shell out to `codex exec --json` with a tiny prompt and time its JSON events (kept behind the same `probe()` interface).
- **Session logs:** `~/.codex/sessions/**` (and `history.jsonl` as secondary).
- **Status feed:** OpenAI status endpoint.

## 7. Probe policy (adaptive, activity-aware)

- **Activity signal:** any session-log write across a provider's dirs within the last 10 min ⇒ `active`.
- **Cadence:** active ⇒ every 5 min; idle ⇒ every 30 min; quiet hours (default 22:00–07:00, configurable) ⇒ Claude only every 30 min, Astra probes suspended; "Test now" bypasses all of it.
- **Targets per cycle:** one Claude frontier probe + one Astra standard probe (+ Haiku control on Claude cycles). Codex Fast probe optional per setting.
- **Control probe (network baseline):** one HTTP GET of a static asset on the provider's domain per cycle; used to separate "provider slow" from "my network/VPN slow." If control latency is also bad ⇒ `UNKNOWN(network)` and no degradation alerts.
- **Cost guard:** serial probes, ±20% jitter, 20 s hard timeout, zero retries, per-day request cap (default 600 ≈ one full active day incl. control + canary; UI surfaces the counter) with probes suspended once hit. Personal-use quota burn is negligible (~100–150 tokens/probe), flagged once in settings as a ToS judgement call.

## 8. Analysis & verdicts

### 8.1 Baselines (per provider+model+mode)

Segments: weekday/weekend × 4 time-of-day buckets. For each of **TTFT** and **tok/s**: median + MAD over retained samples. A learned baseline activates once a segment has ≥ 20 samples; otherwise absolute defaults (TTFT ≤ 8 s, tok/s ≥ 20; configurable). Degradation z-score: `z = |x − median| / max(MAD, floor)`.

### 8.2 Verdict ladder (pure function — all inputs explicit)

Priority: `UNKNOWN > LIMITED > CRAWLING > DEGRADED > BUSY > OK`.

| State | Rule |
|---|---|
| `UNKNOWN` | auth expired/missing, repeated network failure, or control probe bad |
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
- **Settings:** probe models per provider, Fast-mode probe toggle, thresholds (z, N, BUSY %, pace delta), cadence, quiet hours, notification toggles, launch-at-login (SMAppService), data reset.
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
- **Probe timing:** local stub SSE server (delays injected) → measured TTFT/tok-s within tolerance; timeout & error paths.
- **Providers:** fake `Provider` injection for VerdictEngine/UI; Keychain + auth.json access behind thin adapters with fakes.
- **UI:** view-model tests only; no snapshot tests in v1.

## 13. Milestones

| # | Deliverable | Acceptance |
|---|---|---|
| M1 | Scaffold + both providers + popover with live windows/resets | Menu bar shows real % for Claude & Codex; live spike pins endpoint/field shapes; probe path stubbed |
| M2 | SampleStore + burn-rate headline + pace warnings | "gone ~Thu" headline matches hand-check on a busy week |
| M3 | LatencyProber + baselines + verdicts + divergence banner | Yesterday's scenario reproducible against stub server; control probe suppresses false alarms on VPN flake |
| M4 | Session-log watcher + capacity events + notifications + settings + launch-at-login | 429 injected into fixture session fires event; transitions notify once with cooldown |

Each milestone: `just test` green, dogfooded ≥ 1 day before the next.

## 14. Open questions (non-blocking)

1. Which Claude model counts as the "frontier" probe target (Opus-tier default; confirm exact slug + Haiku canary choice).
2. Astra Fast-mode probe: default off — correct?
3. Repo name/visibility: `semafor`, private GitHub later? (local init now)
4. Icon glyph preference (semaphore vs. fuel-gauge vs. signal-bars).
