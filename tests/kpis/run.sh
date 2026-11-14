#!/usr/bin/env bash
# Suite: factory-kpis over fixture ledgers, compared with golden tables (Markdown and JSON).
# Regenerate goldens after an intended change: UPDATE_GOLDEN=1 tests/kpis/run.sh
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
here="$(cd "$(dirname "$0")" && pwd)"
kpis="$here/../../plugins/factory/bin/factory-kpis"
fx="$here/fixtures"
export FACTORY_KPIS_FREE_ROOT_KB=10485760 FACTORY_KPIS_FREE_TMP_KB=2097152
# The clock is pinned: a ticket that passed its gate and has not merged counts as stalled after an
# hour, so "now" must not drift away from the fixtures (the last gate pass is 2026-02-01T10:14:00Z).
export FACTORY_NOW=2026-02-01T10:30:00Z
tmp=$(mktemp -d "${TMPDIR:-/tmp}/kpis-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0 count=0

# case <name> <factory-kpis args...>: compares golden/<name>.md and golden/<name>.json
case_() {
  local name=$1; shift
  local fmt
  for fmt in md json; do
    local args=("$@") out="$tmp/$name.$fmt"
    [ "$fmt" = md ] || args+=(--json)
    "$kpis" "${args[@]}" >"$out"
    count=$((count + 1))
    if [ "${UPDATE_GOLDEN:-}" = 1 ]; then cp "$out" "$here/golden/$name.$fmt"
    elif ! diff -u "$here/golden/$name.$fmt" "$out"; then echo "FAIL: $name.$fmt differs from golden"; fail=1; fi
  done
}

case_ empty --ledger "$fx/empty.jsonl"
case_ missing-ledger --ledger "$tmp/does-not-exist.jsonl"
case_ one-spec --ledger "$fx/one-spec.jsonl" --git-log "$fx/one-spec.gitlog" --runs "$fx/one-spec.runs.json" --usage "$fx/one-spec.usage.json"
case_ escalation --ledger "$fx/escalation.jsonl"
case_ mixed --ledger "$fx/mixed.jsonl"
# A ticket is first-try only if no gate failure was ever recorded for it, whatever came before or after.
case_ gate-pass-only --ledger "$fx/gate-pass-only.jsonl"
case_ gate-fail-then-pass --ledger "$fx/gate-fail-then-pass.jsonl"
case_ gate-pass-fail-pass --ledger "$fx/gate-pass-fail-pass.jsonl"
case_ gate-sequences --ledger "$fx/gate-sequences.jsonl"
# Merge time: from `merge` events that carry a duration (any result, queueing included); older events without one are ignored.
case_ merge-times --ledger "$fx/merge-times.jsonl"

# Explicit rule check (not only goldens): first-try rate and rework per ticket for pass-fail-pass.
got=$("$kpis" --json --ledger "$fx/gate-pass-fail-pass.jsonl" | jq -c '[.quality.first_try_gate_pass_rate, .quality.rework_by_ticket[0].review_send_backs]')
count=$((count + 1))
[ "$got" = "[0,1]" ] || { echo "FAIL: pass-fail-pass gave $got, want [0,1]"; fail=1; }

# Explicit rule check: three timed merges of 90s (conflict), 30s and 600s (queued 540s): median 90s, total 720s.
got=$("$kpis" --json --ledger "$fx/merge-times.jsonl" | jq -c '.flow | [.merge_time_median_s, .merge_time_total_s, .merge_wait_total_s]')
count=$((count + 1))
[ "$got" = "[90,720,540]" ] || { echo "FAIL: merge times gave $got, want [90,720,540]"; fail=1; }
# No timed merge recorded: n/a, never 0.
got=$("$kpis" --json --ledger "$fx/gate-pass-only.jsonl" | jq -c '.flow | [.merge_time_median_s, .merge_time_total_s, .merge_wait_total_s]')
count=$((count + 1))
[ "$got" = "[null,null,null]" ] || { echo "FAIL: no merges gave $got, want nulls"; fail=1; }

# Cost is the range of the prices file: one Sonnet 5.5 run of 1M input tokens costs $2 at both ends.
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"agent_stop","agent_id":"x","role":"other","model":"claude-sonnet-5-5-20260101","ticket":null,"tokens":{"input":1000000,"output":null,"cache_read":null,"cache_creation":null}}' >"$tmp/one.jsonl"
got=$("$kpis" --json --ledger "$tmp/one.jsonl" | jq -c '.cost | [.usd_low, .usd_high]')
count=$((count + 1))
[ "$got" = "[2,2]" ] || { echo "FAIL: price lookup by model prefix gave $got"; fail=1; }

[ "$fail" -eq 0 ] || exit 1
echo "kpis suite passed ($count checks)"
