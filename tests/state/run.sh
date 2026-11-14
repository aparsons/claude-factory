#!/usr/bin/env bash
# Suite: factory-state updates .factory/state.json atomically and writes the ledger events
# factory-kpis reads.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
st="$root/plugins/factory/bin/factory-state"
kpis="$root/plugins/factory/bin/factory-kpis"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/state-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_PROJECT_DIR="$tmp/proj" FACTORY_NOW=2026-01-01T10:00:00Z
unset CLAUDE_SESSION_ID
state="$tmp/proj/.factory/state.json"
ledger="$tmp/proj/.factory/ledger.jsonl"
pass=0
fail() { echo "FAIL: $*"; exit 1; }
check() { jq -e "$2" "$state" >/dev/null || fail "$1: $(cat "$state")"; pass=$((pass + 1)); }
lastev() { jq -e "$2" <<<"$(tail -n 1 "$ledger")" >/dev/null || fail "$1: $(tail -n 1 "$ledger")"; pass=$((pass + 1)); }
fails() { # fails <name> <command...>: must exit 2 without changing the state
  local before after
  before=$(cat "$state" 2>/dev/null || true)
  if "${@:2}" >/dev/null 2>&1; then fail "$1: succeeded"; fi
  after=$(cat "$state" 2>/dev/null || true)
  [ "$before" = "$after" ] || fail "$1: state changed"
  pass=$((pass + 1))
}

# --- empty state ---
[ "$("$st" show | jq -c .)" = '{"version":1,"running":false,"assignments":{},"merged":{},"integration":{},"estimates":{}}' ] ||
  fail "empty state: $("$st" show)"
pass=$((pass + 1))
[ ! -e "$tmp/proj/.factory" ] || fail "show must not create the factory directory"
pass=$((pass + 1))

# --- assign ---
"$st" assign --ticket 12 --spec 3 --role implementer --model sonnet --effort high --branch t12-parse
check "assignment added" '.assignments["12"] == {ticket: 12, spec: 3, role: "implementer", model: "sonnet", effort: "high", branch: "t12-parse", worktree: null, agent: null, started: "2026-01-01T10:00:00Z"}'
lastev "assign event in the kpis shape" '. == {ts: "2026-01-01T10:00:00Z", event: "assign", ticket: 12, spec: 3, role: "implementer", model: "sonnet", effort: "high", branch: "t12-parse", session_id: null}'
CLAUDE_SESSION_ID=s-9 "$st" assign --ticket 13 --spec 3 --role implementer-deep --model opus --effort high --branch t13-x
lastev "session id recorded when known" '.session_id == "s-9" and .ticket == 13'
check "two assignments" '.assignments | keys == ["12", "13"]'

# --- update ---
"$st" update --ticket 12 --agent a-1 --worktree /w/agent-1
check "update fills in only what is given" '.assignments["12"] | .agent == "a-1" and .worktree == "/w/agent-1" and .branch == "t12-parse"'
fails "update of an unknown ticket" "$st" update --ticket 99 --agent x

# --- list with age ---
out=$(FACTORY_NOW=2026-01-01T11:30:00Z "$st" list)
[[ "$out" == *"#12"*"implementer"*"sonnet"*"1h30m"* ]] || fail "list shows role, model and age: $out"
pass=$((pass + 1))
[ "$(FACTORY_NOW=2026-01-01T10:20:00Z "$st" list --json | jq -c '[.[].age_min]')" = "[20,20]" ] || fail "list --json ages"
pass=$((pass + 1))

# --- unassign ---
"$st" unassign --ticket 13 --reason "stalled"
check "unassign removes" '.assignments | keys == ["12"]'
lastev "unassign event" '.event == "unassign" and .ticket == 13 and .spec == 3 and .reason == "stalled"'
fails "unassign of an unknown ticket" "$st" unassign --ticket 13

# --- gate and merge ---
"$st" gate --ticket 12 --result fail --tests-added 2
lastev "gate event" '.event == "gate" and .ticket == 12 and .spec == 3 and .result == "fail" and .tests_added == 2'
fails "gate needs pass or fail" "$st" gate --ticket 12 --result maybe
"$st" merge --ticket 12 --commit abc123
check "merge moves the assignment" '(.assignments == {}) and .merged["12"] == {ticket: 12, spec: 3, branch: "t12-parse", worktree: "/w/agent-1", commit: "abc123", merged_at: "2026-01-01T10:00:00Z"}'
lastev "merge event" '. == {ts: "2026-01-01T10:00:00Z", event: "merge", ticket: 12, spec: 3, branch: "t12-parse", commit: "abc123", session_id: null}'
fails "merge of an unassigned ticket" "$st" merge --ticket 12 --commit abc
fails "merge without a commit" "$st" merge --ticket 12

# --- integration, estimate, running ---
"$st" integration --spec 3 --branch spec/3-parser --worktree /p/.claude/worktrees/spec-3
FACTORY_NOW=2026-01-02T00:00:00Z "$st" integration --spec 3 --branch spec/3-parser --status complete
check "integration recorded, created kept, worktree kept" '.integration["3"] == {created: "2026-01-01T10:00:00Z", spec: 3, branch: "spec/3-parser", worktree: "/p/.claude/worktrees/spec-3", status: "complete"}'
"$st" estimate --spec 3 --usd 2.5
"$st" estimate --spec 3 --usd 4.25
check "first estimate kept" '.estimates["3"] | .first == 2.5 and .current == 4.25'
fails "estimate needs an amount" "$st" estimate --spec 3 --usd lots
"$st" running on
check "running on" '.running == true'
"$st" running off
check "running off" '.running == false'

# --- atomic, locked writes: concurrent assigns all land, nothing left behind ---
for n in $(seq 100 119); do
  "$st" assign --ticket "$n" --spec 7 --role implementer --model sonnet --effort high --branch "t$n-x" &
done
wait
check "20 concurrent assigns all recorded" '[.assignments | keys[] | tonumber | select(. >= 100)] | length == 20'
[ "$(grep -c '"event":"assign","ticket":1[01][0-9],' "$ledger")" = 20 ] || fail "20 assign events"
pass=$((pass + 1))
[ -z "$(find "$tmp/proj/.factory" -name '.state.*' -o -name 'state.lock')" ] || fail "temporary files or lock left behind"
pass=$((pass + 1))

# --- a corrupt state file is never overwritten ---
cp "$state" "$tmp/good.json"
echo '{not json' >"$state"
fails "corrupt state refuses updates" "$st" running on
[ "$(cat "$state")" = '{not json' ] || fail "corrupt state was overwritten"
pass=$((pass + 1))
cp "$tmp/good.json" "$state"

# --- ledger lines stay valid and factory-kpis maps tickets to specs from assign events ---
jq -e -s 'all(.[]; type == "object" and (.ts | type == "string") and (.event | type == "string"))' "$ledger" >/dev/null || fail "ledger lines"
pass=$((pass + 1))
echo '{"ts":"2026-01-01T10:30:00Z","event":"agent_stop","agent_id":"a-1","role":"implementer","model":"claude-sonnet-5-5","ticket":12,"duration_s":60,"outcome":"completed","tokens":{"input":1000,"output":100,"cache_read":0,"cache_creation":0}}' >>"$ledger"
[ "$("$kpis" --json --ledger "$ledger" | jq -c '[.cost.by_ticket[] | select(.ticket == 12) | .spec]')" = "[3]" ] ||
  fail "factory-kpis does not see ticket 12 in spec 3"
pass=$((pass + 1))

echo "state suite passed ($pass checks)"
