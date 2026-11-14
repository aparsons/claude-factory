#!/usr/bin/env bash
# Suite: after two gate failures or a stall a ticket is re-run once one tier up; factory-state
# says what to do next, records the escalation in the state and the ledger, and factory-kpis
# lists it in the next report.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
st="$root/plugins/factory/bin/factory-state"
kpis="$root/plugins/factory/bin/factory-kpis"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/escalation-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_PROJECT_DIR="$tmp/proj" FACTORY_NOW=2026-03-01T10:00:00Z
unset CLAUDE_SESSION_ID
state="$tmp/proj/.factory/state.json"
ledger="$tmp/proj/.factory/ledger.jsonl"
pass=0
fail() { echo "FAIL: $*"; exit 1; }
check() { jq -e "$2" <<<"$out" >/dev/null || fail "$1: $out"; pass=$((pass + 1)); }
checks() { jq -e "$2" "$state" >/dev/null || fail "$1: $(cat "$state")"; pass=$((pass + 1)); }
lastev() { jq -e "$2" <<<"$(tail -n 1 "$ledger")" >/dev/null || fail "$1: $(tail -n 1 "$ledger")"; pass=$((pass + 1)); }
refused() { # refused <name> <command...>: exits 3 without changing the state or the ledger
  local before after lb la code=0
  before=$(cat "$state"); lb=$(wc -l <"$ledger")
  "${@:2}" >/dev/null 2>"$tmp/err" || code=$?
  [ "$code" = 3 ] || fail "$1: exit $code, wanted 3 ($(cat "$tmp/err"))"
  after=$(cat "$state"); la=$(wc -l <"$ledger")
  [ "$before" = "$after" ] && [ "$lb" = "$la" ] || fail "$1: state or ledger changed"
  pass=$((pass + 1))
}

"$st" assign --ticket 5 --spec 2 --role implementer --model sonnet --effort high --branch t5-parse --worktree /w/a1
"$st" update --ticket 5 --agent a1

# --- gate results say what to do next ---
out=$("$st" gate --ticket 5 --result fail)
check "first failure: retry" '. == {ticket: 5, result: "fail", failures: 1, next: "retry"}'
lastev "gate event" '.event == "gate" and .ticket == 5 and .spec == 2 and .result == "fail"'
out=$("$st" gate --ticket 5 --result fail)
check "second failure: escalate" '. == {ticket: 5, result: "fail", failures: 2, next: "escalate"}'
checks "failures counted on the assignment" '.assignments["5"].gate_failures == 2'

# --- escalate: one tier up, recorded in the state and the ledger ---
out=$(FACTORY_NOW=2026-03-01T10:05:00Z "$st" escalate --ticket 5 --reason "gate failed twice")
check "escalation names the agent to start" '.ticket == 5 and .role == "implementer-deep" and .agent == "factory:implementer-deep"
  and .model == "opus" and .effort == "high" and .effort_override == false and .branch == "t5-parse"
  and .previous == {role: "implementer", model: "sonnet", effort: "high", worktree: "/w/a1", agent: "a1"}'
checks "assignment moved one tier up, failures reset" '.assignments["5"] | .role == "implementer-deep" and .model == "opus" and .effort == "high"
  and .branch == "t5-parse" and .agent == null and .worktree == null and .started == "2026-03-01T10:05:00Z" and (has("gate_failures") | not)'
checks "escalation kept in the state" '.escalations["5"] == {ticket: 5, spec: 2, from: {role: "implementer", model: "sonnet", effort: "high"},
  to: {role: "implementer-deep", model: "opus", effort: "high"}, reason: "gate failed twice", at: "2026-03-01T10:05:00Z"}'
lastev "escalation in the ledger" '. == {ts: "2026-03-01T10:05:00Z", event: "escalation", ticket: 5, spec: 2,
  from: "implementer", to: "implementer-deep", from_model: "sonnet", from_effort: "high", model: "opus", effort: "high",
  reason: "gate failed twice", session_id: null}'

# --- only once ---
refused "a second escalation of the same ticket" "$st" escalate --ticket 5 --reason again
out=$("$st" gate --ticket 5 --result fail)
check "after escalation the first failure retries" '.failures == 1 and .next == "retry"'
out=$("$st" gate --ticket 5 --result fail)
check "after escalation two failures stop" '.failures == 2 and .next == "stop"'
out=$("$st" gate --ticket 5 --result pass --tests-added 4)
check "a pass merges" '. == {ticket: 5, result: "pass", failures: 0, next: "merge"}'
lastev "pass recorded with tests" '.result == "pass" and .tests_added == 4'

# --- a stall: recorded, escalate straight away ---
"$st" assign --ticket 6 --spec 2 --role implementer-deep --model opus --effort high --branch t6-auth
out=$("$st" stall --ticket 6)
check "stall: escalate" '. == {ticket: 6, next: "escalate"}'
lastev "stall in the ledger" '.event == "stall" and .ticket == 6 and .spec == 2'
out=$("$st" escalate --ticket 6 --reason stalled)
check "the top definition escalates its effort" '.role == "implementer-deep" and .model == "opus" and .effort == "xhigh" and .effort_override'
out=$("$st" stall --ticket 6)
check "a second stall stops" '.next == "stop"'

# --- no tier above: stop, and escalate refuses ---
"$st" assign --ticket 7 --spec 2 --role implementer-deep --model opus --effort max --branch t7-x
"$st" gate --ticket 7 --result fail >/dev/null
out=$("$st" gate --ticket 7 --result fail)
check "nothing above max: stop" '.next == "stop"'
refused "escalate with no tier above" "$st" escalate --ticket 7 --reason "gate failed twice"
refused "escalate an unassigned ticket" "$st" escalate --ticket 99 --reason x
code=0; "$st" escalate --ticket 7 >/dev/null 2>&1 || code=$?
[ "$code" = 2 ] || fail "escalate needs a reason: exit $code"
pass=$((pass + 1))

# --- a gate for a ticket with no assignment (already merged) still records, next merge/stop ---
out=$("$st" gate --ticket 40 --result pass)
check "gate without an assignment" '.next == "merge" and .failures == 0'

# --- the next report lists the escalations ---
md=$("$kpis" --ledger "$ledger")
for s in "| Escalations | 2 |" "### Escalations" "| Ticket | From | To | Reason |" \
  "| #5 | implementer sonnet/high | implementer-deep opus/high | gate failed twice |" \
  "| #6 | implementer-deep opus/high | implementer-deep opus/xhigh | stalled |"; do
  [[ "$md" == *"$s"* ]] || fail "report lacks '$s': $md"
  pass=$((pass + 1))
done
out=$("$kpis" --json --ledger "$ledger")
check "escalations in the KPI JSON" '.quality.escalations == 2 and (.quality.escalated | map(.ticket)) == [5, 6]'

echo "escalation suite passed ($pass checks)"
