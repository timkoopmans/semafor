# Changelog

## 0.2.1 — metric tiles (dogfood feedback)

Sparklines alone didn't answer "is this fast or slow": they auto-scaled, so
every day looked equally wiggly, and normalized ttft/tok-s read opposite
directions with no reference. Each provider now gets two metric tiles:
latest absolute value (`87 tok/s`, `3.2 s ttft`) coloured by directional
robust z against the learned baseline (amber past zWarn, red past zCrawl,
only on the slow side), a `usual 80` caption from the same median the
verdict ladder uses, and a squiggle on a fixed 0…2×-median domain with a
dashed "usual" line dead centre.

## 0.2.0 — M3 (passive measurement + verdicts)

**What's in**

- Passive latency/throughput measurement: Semafor tails the session logs
  Claude Code (`api-request` ↔ `assistant.requestRef` pairing) and Codex
  (`task_started`/`task_complete` turns, burst-filtered `token_count`
  deltas) already write, deriving per-call TTFT and tok/s while you work —
  no extra model calls, no quota spent.
- Launch backfill seeds 7 days of history into learned baselines; byte-
  offset tailer resumes across restarts; `sessionKey` dedupe guards
  re-reads.
- Learned baselines: median/MAD per provider × model × weekend × 6-hour
  bucket with MAD-floored z-scores; defaults until 20 samples/segment.
- Verdict ladder per provider (OK/Busy/Degraded/Crawling/Limited/Unknown)
  with shown reasons, freshness rule (probe rules only trust samples from
  the last 30 min), flapping guard (N consecutive slow calls), and a
  robots.txt control probe that blames your network (UNKNOWN) before
  blaming the provider.
- Status-page divergence banner: official feeds (status.claude.com /
  status.openai.com, Statuspage) green while measured calls crawl ⇒
  "Status pages: ✅ operational · ours: Codex Crawling (…)" — suppressed
  whenever the control probe or their own page explains it.
- Popover: verdict chip (state · model · TTFT · tok/s), two 60×18
  self-normalising sparklines, "measured N calls today" caption; menu-bar
  tint now follows verdicts (crawling/limited red > degraded/busy amber >
  unknown grey > percent ladder).
- Settings: scan interval, backfill days, sample recency, control-probe
  toggle, warn/crawl z, consecutive-N.
- `just live-scan <provider> <days>`: extractor shape-check against the
  real logs (validated: claude-opus-5-5 n=6265 ttft p50 3.21 s / 87 tok/s;
  gpt-6-astra n=135 tok/s p50 28.3 — burst filter confirmed on live data).

## 0.1.0 — M1+M2 (menu bar limits + burn-rate, measured)

First working release. Native menu bar app (no Dock icon), zero third-party
dependencies, macOS 14+.

**What's in**

- Menu bar title shows the worst window utilization across providers
  (`✳` Claude / `⬡` Codex, `40%` style), colored green → amber (≥80) →
  red (≥98); grey when signed out or nothing polled yet; Codex wins ties.
- Popover per provider: usage bars, `resets in 3h 12m` countdowns
  (refreshed on a 30 s tick), `ahead of pace (+31 pts)` tags, and a
  burn-rate headline (`at this pace, gone ~Thu 14:00 (±3h)`) fitted over
  the last 24 h of samples.
- Data sources (read-only, local credentials, nothing uploaded):
  Claude via `api.anthropic.com/api/oauth/usage` using the Claude Code
  Keychain token; Codex via `chatgpt.com/backend-api/codex/usage` using
  `~/.codex/auth.json` ChatGPT OAuth. Key names pinned against live
  payloads (`rate_limit`/`reset_at` verified live, plural aliases kept).
- Polling: jittered interval (2/5/15/30 min), one attempt per tick (no
  retry storms), failures keep showing previous data dimmed with a hint
  (`Not signed in — run `codex` once`, etc.).
- Append-only JSONL sample store (`~/Library/Application Support/Semafor/`,
  30-day / per-type size rotation, crash-torn final line skipped).
- Settings: poll interval, launch-at-login (`SMAppService`), probe model
  IDs (persisted; used from M3), Reset data.
- Footer: last-poll age, `Test now` (coalescing manual refresh),
  `Pause`/`Resume`, gear, `Quit`.

**Acceptance (M1+M2 sweep)**

- [x] 70 unit tests green (`swift test`), covering providers against live
      payload fixtures, scheduler (manual clock, coalescing, staleness),
      store (crash-truncation, rotation, 200-way concurrency), burn-rate
      math, and all popover/menu copy.
- [x] Live spike: both usage endpoints verified against the real account
      (`just live-smoke claude|codex --raw`); decoded values match captured
      raw bodies.
- [x] End-to-end: deployed `~/Applications/Semafor.app` polls both providers
      into the store; transient first-poll failures self-recover next tick.
- [x] `just package/app/deploy 0.1.0`: ad-hoc-signed bundle, `LSUIElement`,
      correct bundle id, no updater remnants; deploy replaces a running
      instance cleanly.
- [x] Burn-rate headline path exercised over seeded 3 h history (store rows
      spanning >2 h produce `gone ~` headings via the fitted slope).
- [ ] Human dogfood ≥ 1 h: menu percentages vs `claude`/`codex` CLIs,
      popover layout, Test now / Pause behavior.
- [ ] First-run Keychain approval for the `Claude Code-credentials` item
      (click Always Allow when macOS asks once per new build).
## 0.2.2 — token history + settings polish

- 7-day tokens/day bar strip per provider (today tinted, caption "7.9k tok
  today · peak 38k this week"). `ProbeSample` gained `tokens: Int?` — Claude
  samples carry the final cumulative `output_tokens`, Codex samples the
  accepted-burst total (never rate×duration, which lies across idle gaps).
  Legacy rows decode as nil and simply draw no strip until counts exist.
- Settings window: proper `LabeledContent` rows — labels no longer hyphenate
  into "Sam-ple recen-cy", fields right-aligned, window widened to 420.
- Footer: live per-second poll counter ("poll 37 s ago", own TimelineView so
  it ticks between UI rebuilds); "Test now" renamed "Refresh"; the counter
  can no longer be truncated by the buttons.
