#!/usr/bin/env bash
# shellcheck disable=SC2015 # `test && check || fail` is the assertion form
# Suite: factory-integration creates a spec's integration branch and worktree, and merges a
# finished ticket into it, against a temporary origin (no network, no gh).
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

# origin with main; the project is a clone on main
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/seed" 2>/dev/null
printf 'target/\n' >"$tmp/seed/.gitignore"
echo base >"$tmp/seed/c.txt"
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

# --- conflict: stop, abort, keep everything ---
implement 13 t13-a c.txt from-13
implement 14 t14-b c.txt from-14
"$fi_" merge --ticket 13 --branch t13-a --worktree "$p/.claude/worktrees/agent-13" >/dev/null || fail "merge 13"
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

# --- diverged: the local integration branch and origin both moved ---
git clone -q -b spec/3-parser "$tmp/origin.git" "$tmp/other"
echo other >"$tmp/other/e.txt" && git -C "$tmp/other" add e.txt && git -C "$tmp/other" commit -q -m other && git -C "$tmp/other" push -q origin spec/3-parser
echo local >"$wt/f.txt" && git -C "$wt" add f.txt && git -C "$wt" commit -q -m local
code=0; out=$("$fi_" merge --ticket 15 --branch t15-c --worktree "$p/.claude/worktrees/agent-15") || code=$?
[ "$code" = 4 ] && jq -e '.result == "diverged"' <<<"$out" >/dev/null || fail "diverged ($code): $out"; ok

# --- refusals ---
if "$fi_" merge --ticket 99 --branch t99-x 2>/dev/null; then fail "merge of an unassigned ticket"; fi; ok

echo "integration suite passed ($pass checks)"
