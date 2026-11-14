#!/usr/bin/env bash
# Suite: factory-rhythm decides what the manager does when it wakes: one-line event notes
# (and whether one needs a push notification), the next heartbeat (20 to 30 minutes), whether
# the hourly digest is due, whether the queue is empty, and what waits on the user.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
tool="$root/plugins/factory/bin/factory-rhythm"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rhythm-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_PROJECT_DIR="$tmp/proj" FACTORY_NOW=2026-01-01T10:00:00Z
unset CLAUDE_SESSION_ID
fdir="$tmp/proj/.factory"
ledger="$fdir/ledger.jsonl"
mkdir -p "$fdir"
pass=0
fail() { echo "FAIL: $*"; exit 1; }
# check <name> <jq filter that must be true> : over $out
check() { jq -e "$2" <<<"$out" >/dev/null || fail "$1: $(jq -c "$2" <<<"$out" 2>&1) in $out"; pass=$((pass + 1)); }
lastev() { jq -e "$2" <<<"$(tail -n 1 "$ledger")" >/dev/null || fail "$1: $(tail -n 1 "$ledger")"; pass=$((pass + 1)); }
fails() { # fails <name> <command...>: must exit 2 and write nothing to the ledger
  local before after
  before=$(cat "$ledger" 2>/dev/null || true)
  if "${@:2}" >/dev/null 2>&1; then fail "$1: succeeded"; fi
  after=$(cat "$ledger" 2>/dev/null || true)
  [ "$before" = "$after" ] || fail "$1: ledger changed"
  pass=$((pass + 1))
}

# --- notes: one line per event, a push only when the user is needed ---
out=$("$tool" note merged --ticket 11 --text "into spec/1-x")
check "merged: one line" '.line == "#11 merged: into spec/1-x" and .kind == "merged"'
check "merged: no push" '.notify == false'
lastev "merged note recorded" '.event == "note" and .kind == "merged" and .ticket == 11 and .notify == false and .line == "#11 merged: into spec/1-x" and .ts == "2026-01-01T10:00:00Z"'
out=$("$tool" note stalled --ticket 12 --text "no progress for 45m, escalating")
check "stalled that is handled: no push" '.line == "#12 stalled: no progress for 45m, escalating" and .notify == false'
out=$("$tool" note stalled --ticket 12 --text "cannot fix, stopped" --needs-user)
check "stalled it cannot fix: push" '.notify == true'
out=$("$tool" note escalated --ticket 13 --text "implementer sonnet/high -> implementer-deep opus/high")
check "escalated line" '.line | startswith("#13 escalated: ")'
out=$("$tool" note ci-red --text "CI on spec/1-x, log in .factory/ci.log")
check "ci red line, no ticket needed" '.line == "CI red: CI on spec/1-x, log in .factory/ci.log" and .notify == false'
out=$("$tool" note budget --text "5-hour window at 81%, no new builders until it resets")
check "budget threshold line" '.line | startswith("Budget: ")'
check "budget threshold alone is no push" '.notify == false'
out=$("$tool" note question --text "merge spec #1 to main?")
check "question needs the user" '.notify == true and .line == "Needs you: merge spec #1 to main?"'
out=$("$tool" note budget-stop --text "7-day window at 86%")
check "budget stop needs the user" '.notify == true and (.line | startswith("Budget stop: "))'
lastev "session id null when unknown" '.session_id == null'
fails "unknown kind" "$tool" note gossip --text x
fails "ticket kind without a ticket" "$tool" note merged --text x
fails "ticket must be a number" "$tool" note merged --ticket abc --text x
fails "text is required" "$tool" note ci-red

# --- digest marker ---
"$tool" digested --path .factory/digests/2026-01-01-1000.md >/dev/null
lastev "digest event" '.event == "digest" and .path == ".factory/digests/2026-01-01-1000.md"'

# --- next: waking ---
rm -f "$ledger" "$fdir/state.json" "$fdir/usage.json" "$fdir/settings.json"
frontier() { printf '%s\n' "$1" >"$tmp/frontier.json"; }
nf='{"alerts":[],"ready":[],"running":[],"blocked":[],"needs_tickets":[],"specs":[]}'
state() { printf '%s\n' "$1" >"$fdir/state.json"; }
asg='{"ticket":12,"spec":1,"role":"implementer","model":"sonnet","effort":"high","branch":"t12-x","started":"2026-01-01T09:30:00Z"}'
rd='{"number":14,"rank":1,"title":"t","spec":1}'
next() { out=$("$tool" next --frontier "$tmp/frontier.json"); }

# the manager is not running: nothing to schedule
frontier "$nf"
next
check "not running: no heartbeat, not idle, no digest" '.running == false and .heartbeat_seconds == null and .idle == false and .digest_due == false'

# running with an empty queue: idle, no heartbeat
state '{"running": true, "assignments": {}}'
next
check "empty queue goes idle" '.running and .idle and .heartbeat_seconds == null and .digest_due == false and .active == 0 and .ready == 0'

# running with work: dynamic heartbeat in 20 to 30 minutes
state "{\"running\": true, \"assignments\": {\"12\": $asg}}"
frontier "$(jq -c '.running = [{"number":12,"spec":1}]' <<<"$nf")"
printf '%s\n' '{"ts":"2026-01-01T09:30:00Z","event":"assign","ticket":12,"spec":1}' >"$ledger"
next
check "work running: not idle" '.running and (.idle | not) and .active == 1'
check "heartbeat 20 to 30 minutes" '.heartbeat_seconds >= 1200 and .heartbeat_seconds <= 1800'
check "no digest yet: the first is due 60 minutes after the first assignment" '.last_digest == null and .digest_due == false and .digest_interval_min == 60 and .digest_in_seconds == 1800'

FACTORY_NOW=2026-01-01T09:35:00Z next
check "digest far off: longest heartbeat" '.digest_in_seconds == 3300 and .heartbeat_seconds == 1800'
FACTORY_NOW=2026-01-01T10:15:00Z next
check "digest near: heartbeat never shorter than 20 minutes" '.digest_in_seconds == 900 and .heartbeat_seconds == 1200 and (.digest_due | not)'
FACTORY_NOW=2026-01-01T10:30:00Z next
check "digest due after 60 minutes" '.digest_due and .digest_in_seconds == 0 and .heartbeat_seconds == 1200'
FACTORY_NOW=2026-01-01T10:45:00Z next
check "digest overdue" '.digest_due and .digest_in_seconds == -900 and .heartbeat_seconds == 1200'

# a digest resets the interval
printf '%s\n' '{"ts":"2026-01-01T10:25:00Z","event":"digest","path":"p"}' >>"$ledger"
FACTORY_NOW=2026-01-01T10:30:00Z next
check "interval counts from the last digest" '.last_digest == "2026-01-01T10:25:00Z" and (.digest_due | not) and .digest_in_seconds == 3300 and .heartbeat_seconds == 1800'

# settings: report interval and heartbeat range
printf '%s\n' '{"report_interval_min": 30}' >"$fdir/settings.json"
FACTORY_NOW=2026-01-01T10:30:00Z next
check "report interval from settings" '.digest_interval_min == 30 and .digest_in_seconds == 1500 and .heartbeat_seconds == 1500'
printf '%s\n' '{"heartbeat_minutes": [20, 25]}' >"$fdir/settings.json"
FACTORY_NOW=2026-01-01T10:30:00Z next
check "heartbeat range from settings" '.heartbeat_seconds == 1500'
rm "$fdir/settings.json"

# ready tickets waiting for a builder slot count as work
state '{"running": true, "assignments": {}}'
frontier "$(jq -c --argjson r "$rd" '.ready = [$r]' <<<"$nf")"
next
check "ready tickets keep the factory working" '(.idle | not) and .ready == 1 and .heartbeat_seconds != null'

# --- waiting on the user ---
state '{"running": true, "assignments": {}}'
frontier "$(jq -c '.needs_tickets = [{"number":30,"title":"Spec: no tickets"}]
  | .specs = [{"number":30,"title":"Spec: no tickets","status":"needs-tickets"},
              {"number":40,"title":"Spec: humans","status":"blocked","not_for_agents":[41]},
              {"number":50,"title":"Spec: done","status":"complete"}]
  | .alerts = [{"kind":"default-branch-red","branch":"main","failing":[{"workflow":"CI","url":"https://x/1"}]}]' <<<"$nf")"
printf '%s\n' \
  '{"ts":"2026-01-01T08:00:00Z","event":"unassign","ticket":7,"spec":40,"reason":"gate failed twice after escalation"}' \
  '{"ts":"2026-01-01T08:10:00Z","event":"unassign","ticket":8,"spec":40,"reason":"stalled after escalation"}' \
  '{"ts":"2026-01-01T08:20:00Z","event":"assign","ticket":8,"spec":40}' \
  '{"ts":"2026-01-01T08:30:00Z","event":"unassign","ticket":9,"spec":40,"reason":"stopped"}' >"$ledger"
next
check "idle with things waiting on the user" '.idle and .heartbeat_seconds == null'
check "spec needing tickets" '.waiting_on_user | any(.kind == "needs-tickets" and .spec == 30)'
check "blocked spec with its human tickets" '.waiting_on_user | any(.kind == "blocked-spec" and .spec == 40 and .not_for_agents == [41])'
check "complete spec is not waiting" '.waiting_on_user | any(.spec == 50) | not'
check "ticket stopped for the user" '.waiting_on_user | any(.kind == "stopped" and .ticket == 7 and .reason == "gate failed twice after escalation")'
check "ticket reassigned is not stopped" '.waiting_on_user | any(.ticket == 8) | not'
check "ticket the user stopped is not waiting" '.waiting_on_user | any(.ticket == 9) | not'
check "red default branch" '.waiting_on_user | any(.kind == "default-branch-red" and .branch == "main")'

# --- budget thresholds from the plan usage ---
rm -f "$ledger"
frontier "$nf"
printf '%s\n' '{"rate_limits":{"five_hour":{"used_percentage":81,"resets_at":1767276000},"seven_day":{"used_percentage":86,"resets_at":1767800000}}}' >"$fdir/usage.json"
next
check "5-hour window past 80%: no new builders" '.budget | any(.window == "five_hour" and .used_pct == 81 and .threshold == 80 and .action == "no-new-builders")'
check "7-day window past 85%: ask" '.budget | any(.window == "seven_day" and .used_pct == 86 and .threshold == 85 and .action == "ask")'
printf '%s\n' '{"rate_limits":{"five_hour":{"used_percentage":79,"resets_at":1767276000},"seven_day":{"used_percentage":10,"resets_at":1767800000}}}' >"$fdir/usage.json"
next
check "below thresholds: nothing" '.budget == []'
printf '%s\n' '{"rate_limits":{"five_hour":{"used_percentage":95,"resets_at":1767276000}}}' >"$fdir/usage.json"
printf '%s\n' '{"budget_five_hour_pct": 96}' >"$fdir/settings.json"
next
check "thresholds from settings" '.budget == []'
rm "$fdir/settings.json"
printf '%s\n' '{"rate_limits":{"five_hour":{"used_percentage":95,"resets_at":1000000000}}}' >"$fdir/usage.json"
next
check "a window that has reset is stale" '.budget == []'
rm "$fdir/usage.json"
next
check "no usage recorded: no budget flags" '.budget == []'
state '{"running": true, "assignments": {}, "estimates": {"1": {"first": 10, "current": 16}, "2": {"first": 10, "current": 12}}}'
next
check "a spec past its estimate ratio: ask (from factory-budget)" '.budget == [{window: "spec", spec: 1, ratio: 1.6, threshold: 1.5, action: "ask"}]'
want=$({ "$root/plugins/factory/bin/factory-budget" --json || [ $? -eq 3 ]; } | jq -c '[.specs[] | select(.status == "ask") | .spec]')
[ "$want" = "[1]" ] || fail "factory-budget and factory-rhythm disagree: $want"
pass=$((pass + 1))

# --- the manager's skill uses it ---
wake="$root/plugins/factory/skills/factory/wake.md"
grep -q 'factory-rhythm' "$root/plugins/factory/skills/factory/SKILL.md" || fail "SKILL.md does not name factory-rhythm"
[ -f "$wake" ] || fail "no wake.md"
grep -q 'factory-rhythm next' "$wake" || fail "wake.md does not use factory-rhythm next"
grep -q 'factory-rhythm note' "$wake" || fail "wake.md does not use factory-rhythm note"
grep -qi 'ScheduleWakeup' "$wake" || fail "wake.md does not schedule the heartbeat"
grep -qi 'PushNotification' "$wake" || fail "wake.md does not say when to push"
pass=$((pass + 5))

echo "rhythm suite passed ($pass checks)"
