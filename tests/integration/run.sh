#!/usr/bin/env bash
# shellcheck disable=SC2015 # `test && check || fail` is the assertion form
# Suite: factory-integration creates a spec's integration branch and worktree, and merges a
# finished ticket into it, against a temporary origin (no network), and keeps the spec's draft
# pull request through a fake gh (tests/integration/bin/gh) on PATH.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
fi_="$root/plugins/factory/bin/factory-integration"
st="$root/plugins/factory/bin/factory-state"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/integration-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass=0
fail() { echo "FAIL: $*"; exit 1; }
ok() { pass=$((pass + 1)); }

export FAKE_GH_DIR="$tmp/gh"
mkdir -p "$FAKE_GH_DIR"
echo '[]' >"$FAKE_GH_DIR/prs.json"
echo '{"3": "Spec: the parser", "12": "Parse the header", "13": "Read the body", "14": "Other body", "15": "Write the footer", "16": "Sixteen", "17": "Late"}' >"$FAKE_GH_DIR/issues.json"
export PATH="$root/tests/integration/bin:$PATH"
prs() { jq "$@" "$FAKE_GH_DIR/prs.json"; }

# origin with main; the project is a clone on main
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/seed" 2>/dev/null
printf 'target/\n' >"$tmp/seed/.gitignore"
echo base >"$tmp/seed/c.txt"
mkdir -p "$tmp/seed/.claude" && echo '{"attribution": {"pr": "Made by the test factory"}}' >"$tmp/seed/.claude/settings.json"
git -C "$tmp/seed" add . && git -C "$tmp/seed" commit -q -m base && git -C "$tmp/seed" push -q origin main
p="$tmp/proj"
git clone -q "$tmp/origin.git" "$p"
export CLAUDE_PROJECT_DIR="$p"
o() { git --git-dir="$tmp/origin.git" "$@"; }

# --- ensure ---
out=$("$fi_" ensure --spec 3 --branch spec/3-parser)
wt="$p/.claude/worktrees/spec-3"
jq -e --arg wt "$wt" '. == {spec: 3, branch: "spec/3-parser", worktree: $wt, created: true}' <<<"$out" >/dev/null || fail "ensure output: $out"; ok
[ "$(o rev-parse spec/3-parser)" = "$(o rev-parse main)" ] || fail "integration branch pushed from main"; ok
[ "$(git -C "$wt" symbolic-ref --short HEAD)" = spec/3-parser ] || fail "integration worktree on its branch"; ok
[ "$(git -C "$p" symbolic-ref --short HEAD)" = main ] && [ -z "$(git -C "$p" status --porcelain)" ] || fail "user checkout untouched and clean"; ok
"$st" show | jq -e --arg wt "$wt" '.integration["3"] | .branch == "spec/3-parser" and .worktree == $wt and .status == "active"' >/dev/null || fail "integration in state"; ok
out=$("$fi_" ensure --spec 3 --branch spec/3-parser)
jq -e '.created == false' <<<"$out" >/dev/null || fail "ensure is idempotent: $out"; ok
if "$fi_" ensure --spec 4 --branch main 2>/dev/null; then fail "ensure accepted the default branch"; fi; ok

# implement <ticket> <branch> <file> <content>: a builder's worktree with one commit, assigned
implement() {
  local w="$p/.claude/worktrees/agent-$1"
  git -C "$p" worktree add -q -b "$2" "$w" origin/spec/3-parser
  echo "$4" >"$w/$3"
  git -C "$w" add "$3" && git -C "$w" commit -q -m "ticket $1"
  mkdir -p "$w/target" && echo build >"$w/target/out.bin"
  "$st" assign --ticket "$1" --spec 3 --role implementer --model sonnet --effort high --branch "$2" --worktree "$w"
}

# --- merge ---
implement 12 t12-parse b.txt hello
out=$("$fi_" merge --ticket 12 --branch t12-parse --worktree "$p/.claude/worktrees/agent-12" --title "Parse the header")
jq -e '.result == "merged" and .worktree_removed == true and .branch_deleted == true' <<<"$out" >/dev/null || fail "merge output: $out"; ok
[ "$(o log -1 --format=%s spec/3-parser)" = "Merge t12-parse into spec/3-parser: Parse the header (#12)" ] || fail "merge commit subject: $(o log -1 --format=%s spec/3-parser)"; ok
[ "$(o rev-parse spec/3-parser)" = "$(jq -r .commit <<<"$out")" ] || fail "merge pushed"; ok
[ ! -e "$p/.claude/worktrees/agent-12" ] || fail "ticket worktree removed (with ignored build output)"; ok
! git -C "$p" rev-parse -q --verify refs/heads/t12-parse >/dev/null || fail "ticket branch deleted"; ok
"$st" show | jq -e '(.assignments | has("12") | not) and .merged["12"].commit != null' >/dev/null || fail "state merged"; ok
tail -n 1 "$p/.factory/ledger.jsonl" | jq -e '.event == "merge" and .ticket == 12 and .spec == 3' >/dev/null || fail "merge event"; ok
[ "$(git -C "$p" symbolic-ref --short HEAD)" = main ] && [ "$(git -C "$p" rev-parse main)" = "$(o rev-parse main)" ] || fail "main untouched"; ok

# --- the first merge opens the spec's draft pull request ---
prs -e 'length == 1' >/dev/null || fail "one pull request opened: $(prs -c .)"; ok
prs -e '.[0] | .isDraft and .head == "spec/3-parser" and .base == "main" and .state == "OPEN"' >/dev/null || fail "draft from the integration branch to main: $(prs -c .)"; ok
jq -e '.pull_request == {number: 101, url: "https://github.com/o/r/pull/101", created: true}' <<<"$out" >/dev/null || fail "merge result names the pull request: $out"; ok
prs -e '.[0].title | contains("#3") and contains("the parser")' >/dev/null || fail "title names the spec: $(prs -r '.[0].title')"; ok
body=$(prs -r '.[0].body')
grep -qxF -- '- #12 Parse the header' <<<"$body" && grep -qxF 'Closes #12' <<<"$body" && grep -qF '#3' <<<"$body" || fail "body names the spec and ticket: $body"; ok
[ "$(tail -n 1 <<<"$body")" = "Made by the test factory" ] || fail "body ends with the project's attribution: $body"; ok

# --- conflict: stop, abort, keep everything ---
implement 13 t13-a c.txt from-13
implement 14 t14-b c.txt from-14
# the user adds a line of their own to the pull request's body; the update keeps it
prs '.[0].body |= sub("\n\n- #12"; "\n\nReviewer note: keep this.\n\n- #12")' >"$tmp/prs.json" && mv "$tmp/prs.json" "$FAKE_GH_DIR/prs.json"
before_body=$(prs -r '.[0].body')
out=$("$fi_" merge --ticket 13 --branch t13-a --worktree "$p/.claude/worktrees/agent-13") || fail "merge 13: $out"

# --- a later merge adds its ticket and its Closes line to the same pull request ---
prs -e 'length == 1' >/dev/null || fail "no second pull request: $(prs -c .)"; ok
jq -e '.pull_request == {number: 101, url: "https://github.com/o/r/pull/101", created: false}' <<<"$out" >/dev/null || fail "merge 13 result names the pull request: $out"; ok
body=$(prs -r '.[0].body')
expected=$(awk '{ print } /^- #12 Parse the header$/ { print "- #13 Read the body" } /^Closes #12$/ { print "Closes #13" }' <<<"$before_body")
grep -qxF 'Reviewer note: keep this.' <<<"$body" && [ "$body" = "$expected" ] || fail "body gains #13 and nothing else changes: $(diff <(echo "$expected") <(echo "$body"))"; ok
prs -e '.[0].isDraft' >/dev/null || fail "still a draft"; ok
before=$(o rev-parse spec/3-parser)
code=0; out=$("$fi_" merge --ticket 14 --branch t14-b --worktree "$p/.claude/worktrees/agent-14") || code=$?
[ "$code" = 3 ] && jq -e '.result == "conflict" and .files == ["c.txt"]' <<<"$out" >/dev/null || fail "conflict ($code): $out"; ok
[ "$(o rev-parse spec/3-parser)" = "$before" ] || fail "nothing pushed on conflict"; ok
[ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$before" ] || fail "integration worktree left clean"; ok
[ -d "$p/.claude/worktrees/agent-14" ] && git -C "$p" rev-parse -q --verify refs/heads/t14-b >/dev/null || fail "worktree and branch kept on conflict"; ok
"$st" show | jq -e '.assignments | has("14")' >/dev/null || fail "assignment kept on conflict"; ok

# --- a failing pre-push hook: nothing merged locally, assignment kept ---
"$st" unassign --ticket 14 >/dev/null
implement 15 t15-c d.txt fifteen
mkdir -p "$p/.git/hooks"
printf '#!/bin/sh\necho "check failed: test x" >&2\nexit 1\n' >"$p/.git/hooks/pre-push"
chmod +x "$p/.git/hooks/pre-push"
code=0; out=$("$fi_" merge --ticket 15 --branch t15-c --worktree "$p/.claude/worktrees/agent-15") || code=$?
[ "$code" = 4 ] && jq -e '.result == "push-failed" and (.output | contains("check failed: test x"))' <<<"$out" >/dev/null || fail "push failure ($code): $out"; ok
[ "$(git -C "$wt" rev-parse HEAD)" = "$(o rev-parse spec/3-parser)" ] || fail "local merge undone after the push failed"; ok
"$st" show | jq -e '.assignments | has("15")' >/dev/null || fail "assignment kept after the push failed"; ok
rm "$p/.git/hooks/pre-push"
prs -e 'length == 1 and (.[0].body | contains("#15") | not)' >/dev/null || fail "a failed push leaves the pull request alone"; ok

# --- a third merge finds the open pull request and opens no other ---
out=$("$fi_" merge --ticket 15 --branch t15-c --worktree "$p/.claude/worktrees/agent-15") || fail "merge 15: $out"
prs -e 'length == 1' >/dev/null || fail "still one pull request: $(prs -c .)"; ok
[ "$(grep -c '^pr create' "$FAKE_GH_DIR/calls.log")" = 1 ] || fail "gh pr create called once: $(cat "$FAKE_GH_DIR/calls.log")"; ok
! grep -qE '^pr (ready|merge)' "$FAKE_GH_DIR/calls.log" || fail "never marked ready or merged"; ok
body=$(prs -r '.[0].body')
[ "$(grep -c '^- #1[235] ' <<<"$body")" = 3 ] && [ "$(grep -c '^Closes #1[235]$' <<<"$body")" = 3 ] && [ "$(tail -n 1 <<<"$body")" = "Made by the test factory" ] || fail "three tickets listed and closed: $body"; ok
jq -e '.pull_request.number == 101 and .pull_request.created == false' <<<"$out" >/dev/null || fail "merge 15 result: $out"; ok

# --- gh unavailable: the merge still succeeds, without a pull request ---
implement 16 t16-d g.txt sixteen
out=$(FAKE_GH_FAIL=1 "$fi_" merge --ticket 16 --branch t16-d --worktree "$p/.claude/worktrees/agent-16") || fail "merge without gh: $out"
jq -e '.result == "merged" and .pull_request == null and (.pull_request_error | length > 0)' <<<"$out" >/dev/null || fail "merge without gh reports no pull request: $out"; ok

# --- clean-up through Claude Code's worktree locks ---
# Claude Code locks an agent's worktree with a reason like "claude agent agent-<id> (pid N start S)",
# and the pid is the long-lived Claude Code process, which outlives the agent. Recorded lock reasons:
# an agent the ledger shows finished (its pid still alive), one still running, one whose process
# is gone, one whose pid now belongs to another process, and a lock that is not Claude Code's.
sleep 300 & live=$!
trap 'kill "$live" 2>/dev/null || true; rm -rf "$tmp"' EXIT
started() { sed 's/^.*) //' "/proc/$1/stat" | cut -d' ' -f20; }
bash -c 'exit 0' & dead=$!
wait "$dead"
stop_agent() { printf '{"ts":"2026-01-01T10:00:00Z","event":"agent_stop","agent_id":"%s","role":"implementer","outcome":"completed"}\n' "$1" >>"$p/.factory/ledger.jsonl"; }
# locked <ticket> <branch> <file> <reason>: an implemented ticket whose branch is also on origin and whose worktree is locked
locked() {
  implement "$1" "$2" "$3" "content-$1"
  git -C "$p" push -q origin "$2"
  git -C "$p" worktree lock --reason "$4" "$p/.claude/worktrees/agent-$1"
}
# gone <ticket> <branch>: the worktree and both copies of the branch are gone
gone() {
  [ ! -e "$p/.claude/worktrees/agent-$1" ] || return 1
  ! git -C "$p" rev-parse -q --verify "refs/heads/$2" >/dev/null || return 1
  ! o rev-parse -q --verify "refs/heads/$2" >/dev/null 2>&1
}
merge_it() { "$fi_" merge --ticket "$1" --branch "$2" --worktree "$p/.claude/worktrees/agent-$1"; }

locked 21 t21-fin i1.txt "claude agent agent-fin21 (pid $live start $(started "$live"))"
stop_agent fin21
out=$(merge_it 21 t21-fin) || fail "merge 21: $out"
jq -e '.result == "merged" and .worktree_removed == true and .branch_deleted == true and .remote_branch_deleted == true and .worktree_lock.state == "finished"' <<<"$out" >/dev/null || fail "finished agent: $out"; ok
gone 21 t21-fin || fail "finished agent: worktree, local and remote branch all removed"; ok

locked 22 t22-run i2.txt "claude agent agent-run22 (pid $live start $(started "$live"))"
out=$(merge_it 22 t22-run) || fail "merge 22: $out"
jq -e '.result == "merged" and .worktree_removed == false and .branch_deleted == false and .worktree_lock.state == "running" and (.cleanup_note | contains("running"))' <<<"$out" >/dev/null || fail "running agent: $out"; ok
[ -d "$p/.claude/worktrees/agent-22" ] && git -C "$p" rev-parse -q --verify refs/heads/t22-run >/dev/null && o rev-parse -q --verify refs/heads/t22-run >/dev/null || fail "running agent: worktree and both branches kept"; ok
git -C "$p" worktree list --porcelain | grep -qF "locked claude agent agent-run22" || fail "running agent: lock left in place"; ok
[ "$(git -C "$p" log -1 --format=%s origin/spec/3-parser)" = "Merge t22-run into spec/3-parser (#22)" ] || fail "running agent: the merge itself still stands"; ok

locked 23 t23-gone i3.txt "claude agent agent-gone23 (pid $dead start 1)"
out=$(merge_it 23 t23-gone) || fail "merge 23: $out"
jq -e '.worktree_removed == true and .branch_deleted == true and .worktree_lock.state == "gone"' <<<"$out" >/dev/null || fail "gone process: $out"; ok
gone 23 t23-gone || fail "gone process: everything removed"; ok

locked 24 t24-reuse i4.txt "claude agent agent-reuse24 (pid $live start 1)"
out=$(merge_it 24 t24-reuse) || fail "merge 24: $out"
jq -e '.worktree_removed == true and .worktree_lock.state == "gone"' <<<"$out" >/dev/null || fail "pid reused by another process counts as gone: $out"; ok
gone 24 t24-reuse || fail "reused pid: everything removed"; ok

locked 25 t25-manual i5.txt "keep for the review"
out=$(merge_it 25 t25-manual) || fail "merge 25: $out"
jq -e '.worktree_removed == false and .branch_deleted == false and .worktree_lock.state == "unknown" and .worktree_lock.reason == "keep for the review"' <<<"$out" >/dev/null || fail "a lock that is not Claude Code's is never broken: $out"; ok

# leftovers: what a kept worktree leaves behind, and its retry once the agent finishes
out=$("$fi_" leftovers --json)
jq -e 'map(.ticket) == [22, 25] and (.[0] | .branch == "t22-run" and .worktree_exists and .branch_local and .branch_remote and .lock == "running")' <<<"$out" >/dev/null || fail "leftovers: $out"; ok
out=$("$fi_" leftovers)
[[ "$out" == *"#22"*"t22-run"*"running"* ]] || fail "leftovers text: $out"; ok
out=$("$fi_" cleanup) || fail "cleanup: $out"
jq -e 'map(select(.worktree_removed == true)) == []' <<<"$out" >/dev/null || fail "cleanup leaves a running agent alone: $out"; ok
stop_agent run22
out=$("$fi_" cleanup --ticket 22) || fail "cleanup 22: $out"
jq -e '. == [.[0]] and .[0].ticket == 22 and .[0].worktree_removed == true and .[0].branch_deleted == true and .[0].remote_branch_deleted == true' <<<"$out" >/dev/null || fail "cleanup after the agent finished: $out"; ok
gone 22 t22-run || fail "retried clean-up removed everything"; ok
"$fi_" leftovers --json | jq -e 'map(.ticket) == [25]' >/dev/null || fail "leftovers after the retry"; ok
git -C "$p" worktree unlock "$p/.claude/worktrees/agent-25"
"$fi_" cleanup | jq -e 'map(.ticket) == [25] and .[0].worktree_removed == true' >/dev/null || fail "cleanup once the lock is released"; ok
[ "$("$fi_" leftovers)" = "No leftover worktrees or branches." ] || fail "nothing left over: $("$fi_" leftovers)"; ok
kill "$live" 2>/dev/null || true

# --- rework: a merged ticket is sent back for a follow-up fix and merged again ---
# Ticket 12 merged at the top of this suite. Its check had passed; a later failure (the live run's
# macOS CI) sends it back. The follow-up reuses the ticket's branch name, which is free again.
first=$("$st" show | jq -r '.merged["12"].commit')
"$st" gate --ticket 12 --result pass --tests-added 1
"$st" rework --ticket 12 --reason "macOS CI failed" || fail "rework"
"$st" show | jq -e --arg c "$first" '.assignments["12"] | .spec == 3 and .branch == "t12-parse" and .role == "implementer"' >/dev/null || fail "rework: assigned again"; ok
"$st" show | jq -e --arg c "$first" '.merged["12"].commit == $c' >/dev/null || fail "rework: the earlier merge is kept"; ok
w12="$p/.claude/worktrees/agent-12b"
git -C "$p" worktree add -q -b t12-parse "$w12" origin/spec/3-parser
echo fix >"$w12/fix12.txt" && git -C "$w12" add fix12.txt && git -C "$w12" commit -q -m "fix for ticket 12"
"$st" update --ticket 12 --worktree "$w12"
# the follow-up's branch must not be taken for a leftover of the first merge
"$fi_" leftovers --json | jq -e 'map(.ticket) | index(12) == null' >/dev/null || fail "leftovers lists the follow-up of a reworked ticket: $("$fi_" leftovers --json)"; ok
"$fi_" cleanup >/dev/null
[ -d "$w12" ] && git -C "$p" rev-parse -q --verify refs/heads/t12-parse >/dev/null || fail "cleanup removed the follow-up's worktree or branch"; ok
out=$("$fi_" merge --ticket 12 --branch t12-parse --worktree "$w12" --title "Parse the header") || fail "merge after rework: $out"
jq -e '.result == "merged" and .worktree_removed == true and .branch_deleted == true' <<<"$out" >/dev/null || fail "merge after rework output: $out"; ok
second=$(jq -r .commit <<<"$out")
[ "$second" != "$first" ] && [ "$(o rev-parse spec/3-parser)" = "$second" ] || fail "the follow-up merge was pushed"; ok
[ -f "$wt/fix12.txt" ] || fail "the follow-up's change is in the integration branch"; ok
"$st" show | jq -e --arg a "$first" --arg b "$second" '(.assignments | has("12") | not) and (.merged["12"] | .commit == $b and .commits == [$a, $b])' >/dev/null || fail "state: merged record gains the new commit and keeps the old: $("$st" show | jq -c '.merged["12"]')"; ok
led="$p/.factory/ledger.jsonl"
jq -s -e --arg a "$first" --arg b "$second" '[.[] | select(.ticket == 12 and (.event == "merge" or .event == "gate" or .event == "rework")) | [.event, .result, .commit, .reason]]
    == [["merge", null, $a, null], ["gate", "pass", null, null], ["gate", "fail", null, "macOS CI failed"], ["rework", null, null, "macOS CI failed"], ["merge", null, $b, null]]' "$led" >/dev/null ||
  fail "ledger: merge, gate pass, gate fail, rework, merge: $(jq -c 'select(.ticket == 12) | [.event, .result, .commit, .reason]' "$led")"; ok
"$root/plugins/factory/bin/factory-kpis" --json --ledger "$led" | jq -e '.quality | (.first_try_gate_pass_rate == 0)
    and (.rework_by_ticket | map(select(.ticket == 12)) == [{ticket: 12, failed_gates: 0, review_send_backs: 1, escalations: 0, total: 1}])' >/dev/null ||
  fail "kpis: ticket 12 is not first-try and its rework is counted: $("$root/plugins/factory/bin/factory-kpis" --json --ledger "$led" | jq -c .quality)"; ok
"$root/plugins/factory/bin/factory-kpis" --ledger "$led" | grep -qE '^\| #12 \| 0 \| 1 \| 0 \| 1 \|' || fail "kpis table: the rework row for #12"; ok

# --- diverged: the local integration branch and origin both moved ---
git clone -q -b spec/3-parser "$tmp/origin.git" "$tmp/other"
echo other >"$tmp/other/e.txt" && git -C "$tmp/other" add e.txt && git -C "$tmp/other" commit -q -m other && git -C "$tmp/other" push -q origin spec/3-parser
echo local >"$wt/f.txt" && git -C "$wt" add f.txt && git -C "$wt" commit -q -m local
implement 17 t17-e h.txt seventeen
code=0; out=$("$fi_" merge --ticket 17 --branch t17-e --worktree "$p/.claude/worktrees/agent-17") || code=$?
[ "$code" = 4 ] && jq -e '.result == "diverged"' <<<"$out" >/dev/null || fail "diverged ($code): $out"; ok

# --- refusals ---
if "$fi_" merge --ticket 99 --branch t99-x 2>/dev/null; then fail "merge of an unassigned ticket"; fi; ok

echo "integration suite passed ($pass checks)"
