#!/usr/bin/env bash
# shellcheck disable=SC2015 # `test && check || fail` is the assertion form
# Suite: a restarted session resumes the saved assignments, worktrees and escalations without
# duplicating agents (factory-resume plans it; factory-state records it), against a temporary
# origin and a state file saved by a session that is gone.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="$root/plugins/factory/bin"
resume="$bin/factory-resume"
st="$bin/factory-state"
fi_="$bin/factory-integration"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/resume-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass=0
fail() { echo "FAIL: $*"; exit 1; }
ok() { pass=$((pass + 1)); }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/seed" 2>/dev/null
printf 'target/\n' >"$tmp/seed/.gitignore"
echo base >"$tmp/seed/c.txt"
git -C "$tmp/seed" add . && git -C "$tmp/seed" commit -q -m base && git -C "$tmp/seed" push -q origin main
p="$tmp/proj"
git clone -q "$tmp/origin.git" "$p"
export CLAUDE_PROJECT_DIR="$p" FACTORY_NOW=2026-01-01T10:00:00Z
unset CLAUDE_SESSION_ID
"$fi_" ensure --spec 3 --branch spec/3-parser >/dev/null
"$fi_" ensure --spec 5 --branch spec/5-other >/dev/null
wtdir="$p/.claude/worktrees"

# builder <ticket> <branch> [file]: a builder's worktree on its branch with one commit
builder() {
  git -C "$p" worktree add -q -b "$2" "$wtdir/agent-$1" origin/spec/3-parser
  echo "work $1" >"$wtdir/agent-$1/${3:-f$1.txt}"
  git -C "$wtdir/agent-$1" add . && git -C "$wtdir/agent-$1" commit -q -m "ticket $1"
}
assign() { # assign <ticket> <role> <model> <effort> <worktree|->
  local wt=()
  [ "$5" = - ] || wt=(--worktree "$5")
  "$st" assign --ticket "$1" --spec 3 --role "$2" --model "$3" --effort "$4" --branch "t$1-x" "${wt[@]}"
  "$st" update --ticket "$1" --agent "a-$1"
}

# the state the previous session left behind
builder 12 t12-x                                   # worktree present, uncommitted work
echo wip >"$wtdir/agent-12/wip.txt"
mkdir -p "$wtdir/agent-12/target" && echo big >"$wtdir/agent-12/target/out.bin"   # ignored build output
assign 12 implementer sonnet high "$wtdir/agent-12"
builder 13 t13-x                                   # recorded worktree gone, branch with a commit
assign 13 implementer sonnet high "$wtdir/agent-13"
git -C "$p" worktree remove --force "$wtdir/agent-13"
assign 14 implementer sonnet high -                # nothing exists yet
builder 15 t15-x                                   # merged into the integration branch, state not updated
assign 15 implementer sonnet high "$wtdir/agent-15"
iw="$wtdir/spec-3"
git -C "$iw" merge -q --no-ff -m "Merge t15-x into spec/3-parser: Fifteen (#15)" t15-x
git -C "$iw" push -q origin spec/3-parser
merge15=$(git -C "$iw" rev-parse HEAD)
builder 16 t16-x                                   # an agent this session still runs
assign 16 implementer sonnet high "$wtdir/agent-16"
builder 17 t17-x                                   # escalated before the restart
assign 17 implementer sonnet high "$wtdir/agent-17"
"$st" escalate --ticket 17 --reason "gate failed twice" >/dev/null
"$st" update --ticket 17 --agent a-17b --worktree "$wtdir/agent-17"
git -C "$p" worktree add -q -b worktree-agent-zzz "$wtdir/agent-zzz" origin/spec/3-parser   # nobody's
"$st" integration --spec 4 --branch spec/4-gone --worktree "$wtdir/spec-4"                   # worktree missing
"$st" running on

before_state=$(cat "$p/.factory/state.json")
before_ledger=$(cat "$p/.factory/ledger.jsonl")

plan=$("$resume" --live a-16)
plan_json=$("$resume" --json --live a-16)
[ "$(cat "$p/.factory/state.json")" = "$before_state" ] && [ "$(cat "$p/.factory/ledger.jsonl")" = "$before_ledger" ] ||
  fail "the plan changed the state or the ledger"; ok
j() { jq -e "$2" <<<"$plan_json" >/dev/null || fail "$1: $plan_json"; ok; }
a() { jq -c --arg t "$1" '.assignments[] | select(.ticket == ($t | tonumber))' <<<"$plan_json"; }
aj() { jq -e "$3" <<<"$(a "$2")" >/dev/null || fail "$1: $(a "$2")"; ok; }

j "every saved assignment is planned exactly once" '[.assignments[].ticket] | sort == [12, 13, 14, 15, 16, 17]'
j "the manager was running" '.running == true'

aj "present worktree, dead agent: resume, salvage the uncommitted work" 12 \
 '.action == "resume" and .worktree == "'"$wtdir/agent-12"'" and .branch_exists == true and .dirty == 1 and .ahead == 1 and .salvage == true and .role == "implementer" and .agent == "a-12"'
aj "worktree gone, branch kept: restart on the branch" 13 \
  '.action == "restart" and .worktree == null and .branch_exists == true and .ahead == 1 and .salvage == false'
aj "nothing exists: restart from the integration branch" 14 \
  '.action == "restart" and .worktree == null and .branch_exists == false and .ahead == 0'
aj "merged but not recorded: record the merge, with its commit" 15 \
  '.action == "merged" and .commit == "'"$merge15"'" and .worktree == "'"$wtdir/agent-15"'"'
aj "an agent the manager still runs is left alone" 16 '.action == "live" and .agent == "a-16"'
aj "an escalation survives: same assignment, escalated" 17 \
  '.action == "resume" and .escalated == true and .role == "implementer-deep" and .agent == "a-17b"'
j "the integration branch is each assignment's own spec" '[.assignments[].integration_branch] | unique == ["spec/3-parser"]'

j "a worktree nobody owns is an orphan, not removed" '.orphans == [{path: "'"$wtdir/agent-zzz"'", branch: "worktree-agent-zzz"}]'
[ -d "$wtdir/agent-zzz" ] || fail "the plan removed an orphan"; ok
j "an integration worktree that is gone is listed to ensure" '(.integration[] | select(.spec == 4)) | .worktree_exists == false and .action == "ensure"'
j "an integration worktree that exists needs nothing" '(.integration[] | select(.spec == 3)) | .worktree_exists == true and .action == "none"'
j "integration worktrees are not orphans" '.orphans | map(.path) | index("'"$wtdir/spec-3"'") == null'

# the text form names each ticket and what to do
[[ "$plan" == *"#12"*"resume"* ]] && [[ "$plan" == *"#13"*"restart"* ]] && [[ "$plan" == *"#15"*"merged"* ]] &&
  [[ "$plan" == *"#16"*"live"* ]] && [[ "$plan" == *"#17"*"escalated"* ]] || fail "text plan: $plan"; ok
[[ "$plan" == *"agent-zzz"* ]] || fail "text plan names the orphan: $plan"; ok

# without --live, a session id that recorded the assignment is the same session: live
"$st" unassign --ticket 14 --reason test >/dev/null
CLAUDE_SESSION_ID=s-live "$st" assign --ticket 14 --spec 3 --role implementer --model sonnet --effort high --branch t14-x
act=$("$resume" --json --session s-live | jq -r '.assignments[] | select(.ticket == 14) | .action')
[ "$act" = live ] || fail "same session is live: $act"; ok
act=$("$resume" --json --session s-other | jq -r '.assignments[] | select(.ticket == 14) | .action')
[ "$act" = restart ] || fail "another session is stale: $act"; ok

# --- recording what the manager did: factory-state resume ---
"$st" resume --ticket 12 --action resume
jq -e '.assignments | length == 6' "$p/.factory/state.json" >/dev/null || fail "resume duplicated or dropped an assignment"; ok
jq -e '.assignments["12"] | .agent == null and .worktree == null and .resumed_at == "2026-01-01T10:00:00Z" and .role == "implementer" and .started == "2026-01-01T10:00:00Z" and .branch == "t12-x"' "$p/.factory/state.json" >/dev/null ||
  fail "resume keeps the assignment, clears agent and worktree: $(jq -c '.assignments["12"]' "$p/.factory/state.json")"; ok
tail -n 1 "$p/.factory/ledger.jsonl" | jq -e '.event == "resume" and .ticket == 12 and .spec == 3 and .action == "resume" and .role == "implementer" and .model == "sonnet" and .effort == "high" and .session_id == null' >/dev/null ||
  fail "resume event: $(tail -n 1 "$p/.factory/ledger.jsonl")"; ok
"$st" update --ticket 12 --agent a-12b --worktree "$wtdir/agent-12b"
jq -e '.assignments["12"] | .agent == "a-12b" and .worktree == "'"$wtdir/agent-12b"'"' "$p/.factory/state.json" >/dev/null || fail "update after resume"; ok
"$st" resume --ticket 17 --action restart
jq -e '.escalations["17"] != null and .assignments["17"].role == "implementer-deep"' "$p/.factory/state.json" >/dev/null || fail "resume kept the escalation"; ok
if "$st" escalate --ticket 17 --reason again >/dev/null 2>&1; then fail "an escalated ticket escalated twice after a resume"; fi; ok
bad=$(cat "$p/.factory/state.json")
if "$st" resume --ticket 99 --action resume >/dev/null 2>&1; then fail "resume of an unknown ticket"; fi
if "$st" resume --ticket 12 --action nonsense >/dev/null 2>&1; then fail "resume with a bad action"; fi
[ "$(cat "$p/.factory/state.json")" = "$bad" ] || fail "a refused resume changed the state"; ok

# --- no duplicate agents: a ticket that has an assignment cannot be assigned again ---
rc=0
"$st" assign --ticket 13 --spec 3 --role implementer --model sonnet --effort high --branch t13-x >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" = 3 ] || fail "assign of an assigned ticket exits 3, got $rc"; ok
[[ "$(cat "$tmp/err")" == *"already assigned"* ]] || fail "assign refusal names the reason: $(cat "$tmp/err")"; ok
jq -e '.assignments["13"].agent == "a-13"' "$p/.factory/state.json" >/dev/null || fail "refused assign changed the assignment"; ok

# --- the frontier keeps assigned tickets out of its ready list after the restart ---
mkdir -p "$tmp/fr"
cat >"$tmp/fr/issues.json" <<'EOF'
[{"number":13,"title":"Thirteen","state":"OPEN","createdAt":"2026-01-01T00:00:00Z","labels":[{"name":"ready-for-agent"}],"milestone":null,"assignees":[],"parent":{"number":3},"blockedBy":{"nodes":[]},"blocking":{"nodes":[]},"subIssues":{"nodes":[]},"subIssuesSummary":{"total":0}},
 {"number":18,"title":"Eighteen","state":"OPEN","createdAt":"2026-01-01T00:00:00Z","labels":[{"name":"ready-for-agent"}],"milestone":null,"assignees":[],"parent":{"number":3},"blockedBy":{"nodes":[]},"blocking":{"nodes":[]},"subIssues":{"nodes":[]},"subIssuesSummary":{"total":0}},
 {"number":3,"title":"Spec: parser","state":"OPEN","createdAt":"2026-01-01T00:00:00Z","labels":[{"name":"ready-for-agent"}],"milestone":null,"assignees":[],"parent":null,"blockedBy":{"nodes":[]},"blocking":{"nodes":[]},"subIssues":{"nodes":[{"number":13},{"number":18}]},"subIssuesSummary":{"total":2}}]
EOF
ready=$("$bin/factory-frontier" --json --from "$tmp/fr" | jq -c '[.ready[].number]')
[ "$ready" = "[18]" ] || fail "the frontier lists only the unassigned ticket: $ready"; ok

# --- usage ---
"$resume" --help >/dev/null || fail "--help"; ok
if "$resume" --bogus >/dev/null 2>&1; then fail "unknown argument accepted"; fi; ok

echo "resume suite passed ($pass checks)"
