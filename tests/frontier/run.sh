#!/usr/bin/env bash
# Suite: factory-frontier readiness and ranking over recorded gh output (no live gh).
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
tool="$root/plugins/factory/bin/factory-frontier"
fx="$root/tests/frontier/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/frontier-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/proj"
export CLAUDE_PROJECT_DIR="$tmp/proj"
pass=0
fail() { echo "FAIL: $*"; exit 1; }
# check <name> <jq filter that must be true> : over $out
check() { jq -e "$2" <<<"$out" >/dev/null || fail "$1: $(jq -c "$2" <<<"$out" 2>&1)"; pass=$((pass + 1)); }
run() { out=$("$tool" --json --from "$1" --state "${2:-$tmp/none.json}"); }

# --- readiness and ranking, no state ---
run "$fx/graph"
check "rank order" '[.ready[].number] == [15, 16, 20, 19, 11, 14, 51]'
check "ranks numbered from 1" '[.ready[].rank] == [1, 2, 3, 4, 5, 6, 7]'
check "security first, deep implementer on opus high" '.ready[0] | .security and .role == "implementer-deep" and .model == "opus" and .effort == "high"'
check "well-specified ticket on sonnet high" '.ready[] | select(.number == 14) | .role == "implementer" and .model == "sonnet" and .effort == "high"'
check "closed blocker does not block" '[.ready[].number] | index(16) != null'
check "open blocker blocks" '.blocked[] | select(.number == 12) | .status == "blocked" and .blocked_by == [11]'
check "chain blocked" '.blocked[] | select(.number == 13) | .blocked_by == [12]'
check "another assignee is not ready" '.blocked[] | select(.number == 18) | .status == "assigned-elsewhere" and .assignees == ["someone"]'
check "uncounted blockers block" '.blocked[] | select(.number == 21) | .blocked_by == ["more"]'
check "transitive unblock count" '.ready[] | select(.number == 11) | .unblocks == 2'
check "milestone carried" '.ready[] | select(.number == 20) | .milestone.title == "M1"'
check "ticket branch t<N>-slug" '.ready[] | select(.number == 15) | .branch == "t15-escape-the-shell-argument"'
check "integration branch spec/<N>-slug" '.ready[] | select(.number == 15) | .spec_branch == "spec/10-the-graph"'
check "spec without tickets needs /to-tickets" '.needs_tickets == [30] and (.specs[] | select(.number == 30) | .status == "needs-tickets")'
check "spec with only human tickets is blocked" '.specs[] | select(.number == 40) | .status == "blocked" and .not_for_agents == [41]'
check "spec with ready tickets is ready" '.specs[] | select(.number == 10) | .status == "ready" and .tickets == 11 and .closed == 1'
check "specs are not tickets" '[.ready[].number, .blocked[].number] | (index(10), index(30), index(40), index(50)) == null'
check "no runs, no alert" '.alerts == [] and .default_branch.red == false and .default_branch.name == "main"'

# --- state: merged tickets are done and unblock; assigned tickets are running ---
cat >"$tmp/state.json" <<'JSON'
{"assignments": {"14": {"ticket": 14, "spec": 10, "role": "implementer", "model": "sonnet", "effort": "high", "branch": "t14-old-small-fix", "started": "2026-01-01T00:00:00Z"}},
 "merged": {"11": {"ticket": 11, "spec": 10, "branch": "t11-base-types", "commit": "abc"},
            "51": {"ticket": 51, "spec": 50, "branch": "t51-merged-but-open", "commit": "def"}},
 "integration": {"10": {"spec": 10, "branch": "spec/10-custom", "status": "active"}}}
JSON
run "$fx/graph" "$tmp/state.json"
check "merged blocker unblocks" '[.ready[].number] | index(12) != null'
check "merged ticket not offered" '[.ready[].number] | (index(11), index(51)) == null'
check "assigned ticket is running, not ready" '([.ready[].number] | index(14) == null) and ([.running[].number] == [14])'
check "chain still blocked by unmerged" '.blocked[] | select(.number == 13) | .blocked_by == [12]'
check "spec with every ticket merged or closed is complete" '.specs[] | select(.number == 50) | .status == "complete" and .merged == 1'
check "spec with a running ticket is running" '.specs[] | select(.number == 10) | .status == "running" and .running == 1 and .merged == 1'
check "recorded integration branch wins" '.ready[] | select(.number == 12) | .spec_branch == "spec/10-custom"'

# --- default branch health ---
mkdir -p "$tmp/red" "$tmp/green"
cp "$fx/graph/issues.json" "$fx/graph/repo.json" "$tmp/red/"
cp "$fx/graph/issues.json" "$fx/graph/repo.json" "$tmp/green/"
cat >"$tmp/red/runs.json" <<'JSON'
[{"workflowName": "CI", "status": "completed", "conclusion": "failure", "url": "https://x/runs/2", "createdAt": "2026-01-02T00:00:00Z"},
 {"workflowName": "CI", "status": "completed", "conclusion": "success", "url": "https://x/runs/1", "createdAt": "2026-01-01T00:00:00Z"},
 {"workflowName": "Docs", "status": "completed", "conclusion": "success", "url": "https://x/runs/3", "createdAt": "2026-01-02T00:00:00Z"}]
JSON
cat >"$tmp/green/runs.json" <<'JSON'
[{"workflowName": "CI", "status": "in_progress", "conclusion": "", "url": "https://x/runs/3", "createdAt": "2026-01-03T00:00:00Z"},
 {"workflowName": "CI", "status": "completed", "conclusion": "success", "url": "https://x/runs/2", "createdAt": "2026-01-02T00:00:00Z"},
 {"workflowName": "CI", "status": "completed", "conclusion": "failure", "url": "https://x/runs/1", "createdAt": "2026-01-01T00:00:00Z"}]
JSON
run "$tmp/red"
check "red default branch is the first alert" '.alerts[0].kind == "default-branch-red" and .alerts[0].failing == [{"workflow": "CI", "conclusion": "failure", "url": "https://x/runs/2"}] and .default_branch.red'
run "$tmp/green"
check "a later success clears an old failure" '.alerts == [] and (.default_branch.red | not)'
txt=$("$tool" --from "$tmp/red" --state "$tmp/none.json")
[[ "$txt" == ALERT:*"default branch main is red"* ]] || fail "text output starts with the alert: $txt"
pass=$((pass + 1))

# --- settings: an ordered priority label list and a factory assignee ---
mkdir -p "$tmp/proj/.factory"
echo '{"priority_labels": ["P9"], "factory_assignee": "someone"}' >"$tmp/proj/.factory/settings.json"
run "$fx/graph"
check "settings priority list replaces the default label tiers; factory assignee counts as unassigned" \
  '[.ready[].number] == [15, 20, 19, 11, 18, 14, 51, 16]'
echo '{"priority_labels": ["P9", "priority:high"]}' >"$tmp/proj/.factory/settings.json"
run "$fx/graph"
check "a listed label ranks above unlabelled" '[.ready[].number][0:2] == [15, 16]'
echo '{"deep_when": {"unblocks_at_least": 2}}' >"$tmp/proj/.factory/settings.json"
run "$fx/graph"
check "settings lower the deep threshold" '.ready[] | select(.number == 11) | .role == "implementer-deep"'
rm -rf "$tmp/proj/.factory"

# --- a real recording ---
run "$fx/recorded"
check "recorded: only the unblocked ticket is ready" '[.ready[].number] == [2]'
check "recorded: it unblocks the other twelve" '.ready[0].unblocks == 12 and .ready[0].role == "implementer-deep"'
check "recorded: the spec is listed once, not as a ticket" '[.specs[].number] == [1] and (.specs[0].tickets == 13)'
check "recorded: blocked tickets name their blockers" '.blocked[] | select(.number == 5) | (.blocked_by | sort) == [3, 4]'

# --- standalone tickets: a parent-less issue without sub-issues that is not marked as a spec ---
run "$fx/standalone"
check "standalone: ranked with spec tickets by the same rules" '[.ready[].number] == [60, 71, 62]'
check "standalone bug is a ticket on its own integration branch" \
  '.ready[0] | .number == 60 and .standalone and .spec == 60 and .branch == "t60-crash-on-empty-input"
     and .spec_branch == "ticket/60-crash-on-empty-input" and .role == "implementer" and .priority_label == "priority:high"'
check "spec ticket is not standalone" '.ready[] | select(.number == 71) | (.standalone | not) and .spec == 70 and .spec_branch == "spec/70-widgets"'
check "standalone blocked by another issue" '.blocked[] | select(.number == 61) | .status == "blocked" and .blocked_by == [60] and .standalone'
check "standalone blocker counts as unblocking" '.ready[0].unblocks == 1'
check "spec with tickets stays a spec" '.specs[] | select(.number == 70) | .status == "ready" and .tickets == 2 and (.standalone | not)'
check "spec marked by title or body without sub-issues needs /to-tickets" \
  '.needs_tickets == [80, 81] and ([.specs[] | select(.status == "needs-tickets") | .number] == [80, 81])'
check "specs are not tickets, standalone or not" '[.ready[].number, .blocked[].number] | (index(70), index(80), index(81)) == null'
check "a standalone ticket is its own one-ticket entry in specs" \
  '[.specs[] | select(.standalone) | {number, tickets, status, branch}] == [
     {number: 60, tickets: 1, status: "ready", branch: "ticket/60-crash-on-empty-input"},
     {number: 61, tickets: 1, status: "blocked", branch: "ticket/61-retry-the-flaky-download"},
     {number: 62, tickets: 1, status: "ready", branch: "ticket/62-typo-in-the-help-text"}]'
cat >"$tmp/state-standalone.json" <<'JSON'
{"assignments": {"62": {"ticket": 62, "spec": 62, "role": "implementer", "model": "sonnet", "effort": "high", "branch": "t62-typo", "started": "2026-01-01T00:00:00Z"}},
 "merged": {"60": {"ticket": 60, "spec": 60, "branch": "t60-crash-on-empty-input", "commit": "abc"}},
 "integration": {"61": {"spec": 61, "branch": "ticket/61-custom", "status": "active"}}}
JSON
run "$fx/standalone" "$tmp/state-standalone.json"
check "merged standalone ticket unblocks and is complete" \
  '([.ready[].number] == [71, 61]) and (.specs[] | select(.number == 60) | .status == "complete" and .merged == 1)'
check "running standalone ticket" '[.running[].number] == [62] and (.specs[] | select(.number == 62) | .status == "running")'
check "recorded standalone integration branch wins" '.ready[] | select(.number == 61) | .spec_branch == "ticket/61-custom"'
txt=$("$tool" --from "$fx/standalone" --state "$tmp/none.json")
for s in "1. #60 (standalone) implementer" "#61 (standalone) blocked by #60" "#81 needs-tickets (needs /to-tickets)" "#60 ready (standalone)"; do
  [[ "$txt" == *"$s"* ]] || fail "standalone text output lacks '$s': $txt"
  pass=$((pass + 1))
done

# --- text output ---
txt=$("$tool" --from "$fx/graph" --state "$tmp/none.json")
for s in "Frontier: 7 ready" "1. #15 (spec #10) implementer-deep opus/high" "[security]" "[priority priority:high]" "#30 needs-tickets (needs /to-tickets)" "#12 (spec #10) blocked by #11"; do
  [[ "$txt" == *"$s"* ]] || fail "text output lacks '$s': $txt"
  pass=$((pass + 1))
done

echo "frontier suite passed ($pass checks)"
