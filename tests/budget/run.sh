#!/usr/bin/env bash
# Suite: plan-usage budgets. factory-statusline records the status line's rate limits in
# .factory/usage.json; factory-budget decides from fixture usage files, settings and the
# state's spec estimates; spawn-gate refuses builders above the five-hour threshold.
set -euo pipefail
# Under a git hook (pre-push) GIT_DIR and friends leak in and would point git calls at this repository.
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
here="$(cd "$(dirname "$0")" && pwd)"
plugin="$here/../../plugins/factory"
fx="$here/fixtures"
sl="$plugin/bin/factory-statusline"
budget="$plugin/bin/factory-budget"
gate="$plugin/hooks/spawn-gate.sh"
kpis="$plugin/bin/factory-kpis"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/budget-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*"; exit 1; }
ok() { pass=$((pass + 1)); }

project="$tmp/proj"
mkdir -p "$project/.factory"
export CLAUDE_PROJECT_DIR="$project" FACTORY_NOW=2026-01-01T10:00:00Z
usage="$project/.factory/usage.json"
settings="$project/.factory/settings.json"
state="$project/.factory/state.json"

# ---------------------------------------------------------------- factory-statusline
out=$("$sl" <"$fx/statusline-input.json")
[ -f "$usage" ] || fail "statusline wrote no usage.json"; ok
jq -e '.rate_limits == {five_hour: {used_percentage: 23.5, resets_at: 1767276000}, seven_day: {used_percentage: 41.2, resets_at: 1767800000}}
  and .recorded_at == "2026-01-01T10:00:00Z"' "$usage" >/dev/null || fail "usage.json content: $(cat "$usage")"; ok
[[ "$out" == *"23.5%"* && "$out" == *"41.2%"* ]] || fail "default status line lacks the percentages: $out"; ok
[ "$(jq -r '.cost.plan_usage | "\(.five_hour_pct) \(.seven_day_pct) \(.five_hour_resets_at)"' <("$kpis" --json))" = "23.5 41.2 1767276000" ] ||
  fail "factory-kpis does not read what the status line wrote"; ok

# no limits in the input (not a subscriber, or before the first response): the file is left alone
cp "$usage" "$tmp/before.json"
out=$("$sl" <"$fx/statusline-no-limits.json")
cmp -s "$usage" "$tmp/before.json" || fail "input without limits changed usage.json"; ok
[ -n "$out" ] || fail "default status line printed nothing without limits"; ok

# one window only: merged over what is recorded
"$sl" <"$fx/statusline-five-hour-only.json" >/dev/null
jq -e '.rate_limits.five_hour == {used_percentage: 50, resets_at: 1767280000}
  and .rate_limits.seven_day.used_percentage == 41.2' "$usage" >/dev/null || fail "partial update did not merge: $(cat "$usage")"; ok

# no factory directory: the factory is not running in this project, so nothing is created
mkdir -p "$tmp/other"
CLAUDE_PROJECT_DIR="$tmp/other" "$sl" <"$fx/statusline-input.json" >/dev/null
[ ! -e "$tmp/other/.factory" ] || fail "statusline created a factory directory"; ok

# the project comes from the input when $CLAUDE_PROJECT_DIR is not set (a status line has none)
mkdir -p "$tmp/viainput/.factory"
jq --arg d "$tmp/viainput" '.workspace.project_dir = $d' "$fx/statusline-input.json" >"$tmp/input.json"
env -u CLAUDE_PROJECT_DIR "$sl" <"$tmp/input.json" >/dev/null
[ -f "$tmp/viainput/.factory/usage.json" ] || fail "project dir not taken from the input"; ok

# never breaks the status line: bad input exits 0
code=0; "$sl" <<<'not json' >/dev/null 2>&1 || code=$?
[ "$code" = 0 ] || fail "bad input exit $code"; ok
code=0; "$sl" </dev/null >/dev/null 2>&1 || code=$?
[ "$code" = 0 ] || fail "empty input exit $code"; ok

# beside the user's own: its output is the status line, and it gets the same input
cat >"$tmp/mine.sh" <<'EOF'
#!/usr/bin/env bash
echo "mine: $(jq -r .model.display_name)"
EOF
chmod +x "$tmp/mine.sh"
rm -f "$usage"
out=$("$sl" --then "$tmp/mine.sh" <"$fx/statusline-input.json")
[ "$out" = "mine: Opus" ] || fail "chained output: $out"; ok
[ -f "$usage" ] || fail "usage not recorded when chained"; ok
out=$("$sl" --then "exit 3" <"$fx/statusline-input.json") || fail "failing chained command broke the status line"; ok

# ---------------------------------------------------------------- factory-budget
rm -f "$usage" "$settings" "$state"
code=0; out=$("$budget" 2>&1) || code=$?
[ "$code" = 0 ] || fail "no usage file: exit $code: $out"; ok
[[ "$out" == *"ok"* ]] || fail "no usage file output: $out"; ok
[ "$("$budget" --json | jq -c '[.builders, .continue, .five_hour.status, .seven_day.status]')" = '["ok","ok","unknown","unknown"]' ] ||
  fail "no usage file json"; ok

check() { # check <usage fixture> [state fixture]: sets $code, $out
  cp "$fx/$1" "$usage"
  if [ -n "${2:-}" ]; then cp "$fx/$2" "$state"; else rm -f "$state"; fi
  code=0; out=$("$budget" 2>&1) || code=$?
}
expect() { # expect <name> <exit code> [substring...]
  local name=$1 want=$2; shift 2
  [ "$code" = "$want" ] || fail "$name: exit $code, wanted $want: $out"
  for s in "$@"; do [[ "$out" == *"$s"* ]] || fail "$name: output lacks '$s': $out"; done
  ok
}
jsonq() { "$budget" --json | jq -r "$1"; }

check usage-ok.json; expect "comfortable usage" 0 "ok"
check usage-5h-at-limit.json; expect "exactly 80% is not above" 0
check usage-5h-high.json
expect "above 80% of the 5-hour window" 3 "83%" "80%" "no new builders" "2026-01-01T14:00:00Z"
[ "$(jsonq '.builders + " " + .resume_at + " " + .continue')" = "paused 2026-01-01T14:00:00Z ok" ] || fail "5-hour json: $(jsonq .)"; ok
check usage-7d-at-limit.json; expect "exactly 85% is not above" 0
check usage-7d-high.json; expect "above 85% of the 7-day window" 3 "88%" "85%" "ask the user"
[ "$(jsonq '.builders + " " + .continue')" = "ok ask" ] || fail "7-day does not pause builders, it asks: $(jsonq .)"; ok
check usage-both-high.json; expect "both windows over" 3 "no new builders" "ask the user"
check usage-stale.json; expect "windows that have already reset" 0
[ "$(jsonq '.five_hour.stale')" = true ] || fail "stale window not marked"; ok

# a window missing from the file is unknown, not over
check usage-5h-only.json; expect "five-hour only, over" 3 "no new builders"
[ "$(jsonq .seven_day.status)" = unknown ] || fail "missing 7-day window"; ok

# spec estimates: report and ask above 1.5 times the first
check usage-ok.json state-estimates.json
expect "spec estimate above 1.5x" 3 "spec #2" "15.01" "10" "1.5"
[[ "$out" != *"spec #1"* && "$out" != *"spec #3"* ]] || fail "spec at exactly 1.5x, or without a first estimate, flagged: $out"; ok
[ "$(jsonq '[.specs[] | "\(.spec):\(.status)"] | join(" ")')" = "1:ok 2:ask 3:ok" ] || fail "specs json: $(jsonq .specs)"; ok
[ "$(jsonq '.specs[1].ratio')" = 1.5 ] || fail "ratio rounds to two places: $(jsonq .specs)"; ok
[ "$(jsonq .continue)" = ask ] || fail "estimate overrun must ask"; ok

# settings
echo '{"budget_five_hour_pct": 90, "budget_seven_day_pct": 95, "budget_spec_ratio": 2}' >"$settings"
check usage-5h-high.json state-estimates.json; expect "raised thresholds pass" 0
echo '{"budget_five_hour_pct": 40}' >"$settings"
check usage-ok.json; expect "lowered 5-hour threshold" 3 "42.5%" "40%"
echo '{"budget_seven_day_pct": 10}' >"$settings"
check usage-ok.json; expect "lowered 7-day threshold" 3 "18%" "10%"
echo '{"budget_spec_ratio": 1.2}' >"$settings"
check usage-ok.json state-estimates.json; expect "lowered spec ratio flags spec 1 too" 3 "spec #1" "spec #2"
echo '{"builder_cap": 9}' >"$settings"
check usage-5h-high.json; expect "unset keys keep defaults" 3 "80%"
echo 'not json' >"$settings"
check usage-5h-high.json; expect "unreadable settings use defaults" 3 "80%"
echo '{"budget_five_hour_pct": "lots"}' >"$settings"
check usage-5h-high.json; expect "non-numeric threshold uses the default" 3 "80%"
rm -f "$settings"

# unreadable usage file: no decision from it, with a warning
echo 'not json' >"$usage"; rm -f "$state"
code=0; out=$("$budget" 2>&1) || code=$?
expect "unreadable usage file" 0 "unreadable"
"$budget" --bogus >/dev/null 2>&1 && fail "unknown option accepted"; ok

# ---------------------------------------------------------------- spawn-gate
builder="$here/../spawn-gate/fixtures/agent-implementer.json"
reviewer="$here/../spawn-gate/fixtures/agent-reviewer.json"
gate_run() { # gate_run <agent fixture>: sets $code, $out
  code=0
  out=$(env FACTORY_TEST=1 FACTORY_TEST_FREE_DISK_MB=100000 FACTORY_TEST_FREE_TEMP_MB=100000 \
    FACTORY_TEST_RUNNING_BUILDERS=0 FACTORY_TEST_WORKTREE_MB=1000 "$gate" <"$1" 2>&1 >/dev/null) || code=$?
}
cp "$fx/usage-ok.json" "$usage"; gate_run "$builder"; expect "gate: builder passes under 80%" 0
cp "$fx/usage-5h-at-limit.json" "$usage"; gate_run "$builder"; expect "gate: builder passes at exactly 80%" 0
cp "$fx/usage-5h-high.json" "$usage"; gate_run "$builder"
expect "gate: builder blocked above 80%" 2 "83%" "80%" "2026-01-01T14:00:00Z"
gate_run "$reviewer"; expect "gate: read-only role passes above 80%" 0
cp "$fx/usage-7d-high.json" "$usage"; gate_run "$builder"; expect "gate: 7-day is the manager's question, not the gate's" 0
cp "$fx/usage-stale.json" "$usage"; gate_run "$builder"; expect "gate: a window that has reset does not block" 0
cp "$fx/usage-5h-high.json" "$usage"
echo '{"budget_five_hour_pct": 90}' >"$settings"; gate_run "$builder"; expect "gate: threshold from settings" 0
echo '{"budget_five_hour_pct": 40}' >"$settings"; cp "$fx/usage-ok.json" "$usage"; gate_run "$builder"
expect "gate: lowered threshold blocks" 2 "42.5%" "40%"
echo 'not json' >"$usage"; rm -f "$settings"; gate_run "$builder"; expect "gate: unreadable usage fails open" 0
rm -f "$usage"; gate_run "$builder"; expect "gate: no usage file passes" 0

echo "budget suite passed ($pass checks)"
