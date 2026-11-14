# Plan usage fixtures

`usage-*.json` are the project's `.factory/usage.json`: the `rate_limits` object of the Claude
Code status line input (`five_hour` and `seven_day`, each `used_percentage` 0 to 100 and
`resets_at` in Unix epoch seconds), https://code.claude.com/docs/en/statusline ("Available
data"). Both windows are optional there: they appear only for Claude.ai subscribers and after
the first API response of a session.

The suite fixes the time at 2026-01-01T10:00:00Z (epoch 1767261600): the five-hour window
resets at 14:00Z, the seven-day at 1767800000. `usage-stale.json` has windows that reset
before then.

`statusline-*.json` are status line inputs: `statusline-input.json` has both windows,
`statusline-no-limits.json` none, `statusline-five-hour-only.json` one.

`state-estimates.json` is a `.factory/state.json` with spec cost estimates: spec 1 is at 1.5
times its first estimate, spec 2 just past it, spec 3 has a first estimate of 0 (no ratio).
