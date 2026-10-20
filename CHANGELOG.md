# Changelog

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
