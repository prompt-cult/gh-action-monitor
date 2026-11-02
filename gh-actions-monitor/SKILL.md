---
name: gh-actions-monitor
description: GitHub Actions run / PR-jobs monitoring and polling. Blocking poll loop over fresh `gh` state; use when `gh --watch` is not trustworthy and you must not miss state changes.
---

# GH Actions Monitor

Use this when `gh ... --watch` is not trustworthy enough and you need a blocking poll loop that notices state changes quickly instead of sleeping through them.

## Tool

`gh-actions-monitor/gh-actions-monitor.lua`

Examples:

```sh
gh-actions-monitor/gh-actions-monitor.lua run 26059219391 \
  --repo livemorecapital/livemore-pricing-engine \
  --interval 15 \
  --soft-deadline 480 \
  --timeout 1200
```

```sh
gh-actions-monitor/gh-actions-monitor.lua pr-checks 389 \
  --repo livemorecapital/livemore-pricing-engine \
  --interval 15 \
  --soft-deadline 480 \
  --timeout 1200 \
  --fail-fast
```

Exit codes:

- `0` success
- `2` monitored thing failed
- `3` soft deadline exceeded while still pending
- `4` hard timeout exceeded while still pending
- `5` tool or `gh` error
