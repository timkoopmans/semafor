# Semafor

A native macOS menu bar app that shows whether your subscription frontier
models (Claude via Claude Code, GPT-6 Astra via ChatGPT/Codex) are
rate-limited, degrading, or about to run dry — measured, not as advertised.

Menu bar shows the worst window utilization across providers (tinted by the
worst verdict); the popover carries per-provider usage windows with reset
countdowns, a burn-rate headline ("at this pace, gone ~Thu 14:00 (±3h)"),
a verdict chip ("Crawling · Opus 5.5 · TTFT 21.4 s · 9 tok/s") with
self-normalising sparklines, and a banner when the official status pages say
green while your measured calls say otherwise.

Latency and throughput are measured **passively** from the session logs
Claude Code and Codex already write (`~/.claude/projects`,
`~/.codex/sessions`) while you work — no extra model calls, no quota spent.

Reads the OAuth credentials your CLIs already keep on this machine (macOS
Keychain for Claude Code, `~/.codex/auth.json` for Codex) and talks only to
each provider's usage endpoint, its official status page, and two public
robots.txt URLs for the network control probe. Nothing is uploaded anywhere.

Status: M1+M2+M3 shipped as 0.2.x (`CHANGELOG.md`). M4 (capacity-event
notifications, launch polish) gets its own plan. Design:
`docs/superpowers/specs/`, plans: `docs/superpowers/plans/`.

## Build

```sh
just build       # swift build
just test        # swift test
just dev         # test-bundle .app in dist/
just run         # build test bundle and launch it
just deploy      # release .app → ~/Applications
just live-scan claude 7   # passive extractor shape-check vs real logs
```
