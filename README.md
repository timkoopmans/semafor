# Semafor

A native macOS menu bar app that shows whether your subscription frontier
models (Claude via Claude Code, GPT-6 Astra via ChatGPT/Codex) are
rate-limited, degrading, or about to run dry — measured, not as advertised.

Menu bar shows the worst window utilization across providers; the popover
carries per-provider usage windows with reset countdowns and a burn-rate
headline ("at this pace, gone ~Thu 14:00 (±3h)").

Reads the OAuth credentials your CLIs already keep on this machine (macOS
Keychain for Claude Code, `~/.codex/auth.json` for Codex) and talks only to
each provider's own usage endpoint. Nothing is uploaded anywhere.

Status: M1+M2 shipped as 0.1.0 (`CHANGELOG.md`). M3 (probes, verdicts,
status-page divergence) and M4 (session-log watcher, notifications) get
separate plans. Design: `docs/superpowers/specs/`, plans:
`docs/superpowers/plans/`.

## Build

```sh
just build      # swift build
just test       # swift test
just dev        # test-bundle .app in dist/
just run        # build test bundle and launch it
just deploy     # release .app → ~/Applications
```
