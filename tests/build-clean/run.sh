#!/usr/bin/env bash
# Suite: a builder's stop check refuses to finish while its worktree's build output is over the limit.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$root/plugins/factory/hooks/build-clean.sh"
fx="$root/tests/build-clean/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/build-clean.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*"; exit 1; }

project="$tmp/proj"
git init -q -b main "$project"
printf 'target/\n' >"$project/.gitignore"
git -C "$project" add .gitignore
git -C "$project" -c user.name=t -c user.email=t@t commit -q -m base
mkdir -p "$project/.worktrees"
wt="$project/.worktrees/t-1"
git -C "$project" worktree add -q "$wt" -b t-1
mkdir -p "$project/.factory"
echo '{"build_output_max_mb": 1}' >"$project/.factory/settings.json"

# stop <cwd> <agent_type> [active]: sets $code, $err
stop() {
  code=0
  err=$(sed -e "s#@CWD@#$1#" -e "s#@TYPE@#$2#" -e "s#@ACTIVE@#${3:-false}#" "$fx/subagent-stop-implementer.json" |
    env CLAUDE_PROJECT_DIR="$project" bash "$hook" 2>&1 >/dev/null) || code=$?
}
expect() { # expect <name> <code> [stderr-substring...]
  local name=$1 want=$2; shift 2
  [ "$code" = "$want" ] || fail "$name: exit $code, wanted $want ($err)"
  for s in "$@"; do [[ "$err" == *"$s"* ]] || fail "$name: stderr lacks '$s': $err"; done
  pass=$((pass + 1))
}

# --- clean worktree passes ---
stop "$wt" factory:implementer; expect "clean worktree passes" 0

# --- ignored build output over the limit blocks (limit 1 MB) ---
mkdir -p "$wt/target/debug"
head -c 3000000 /dev/zero >"$wt/target/debug/big.bin"
stop "$wt" factory:implementer
expect "build output over the limit blocks" 2 "build output" "3 MB" "limit is 1 MB" "target" "git status --porcelain"
stop "$wt" factory:implementer-deep; expect "deep implementer blocks too" 2 "limit is 1 MB"
stop "$wt" general-purpose; expect "a general-purpose builder in a worktree blocks" 2 "limit is 1 MB"

# --- untracked, not ignored output counts as well ---
rm -rf "$wt/target"
mkdir "$wt/build"
head -c 1900000 /dev/zero >"$wt/build/out.o"
stop "$wt" factory:implementer; expect "untracked build directory blocks" 2 "build" "2 MB"
rm -rf "$wt/build"

# --- tracked files are source, not build output ---
head -c 3000000 /dev/zero >"$wt/data.bin"
git -C "$wt" add data.bin
git -C "$wt" -c user.name=t -c user.email=t@t commit -q -m data
stop "$wt" factory:implementer; expect "tracked files do not count" 0

# --- just under the limit passes, just over blocks (limit 1 MB) ---
mkdir -p "$wt/target"
head -c 900000 /dev/zero >"$wt/target/a.bin"
stop "$wt" factory:implementer; expect "under the limit passes" 0
head -c 1200000 /dev/zero >"$wt/target/a.bin"
stop "$wt" factory:implementer; expect "over the limit blocks" 2

# --- the limit comes from settings, default 500 MB ---
echo '{"build_output_max_mb": 10}' >"$project/.factory/settings.json"
stop "$wt" factory:implementer; expect "a higher limit passes" 0
echo '{}' >"$project/.factory/settings.json"
stop "$wt" factory:implementer; expect "default limit is large enough for small output" 0
echo 'not json' >"$project/.factory/settings.json"
stop "$wt" factory:implementer; expect "bad settings use the default" 0
echo '{"build_output_max_mb": 1}' >"$project/.factory/settings.json"

# --- who is checked ---
stop "$wt" factory:standards-reviewer; expect "reviewers are not builders" 0
stop "$wt" factory:merger; expect "mergers are not builders" 0
stop "$project" factory:implementer; expect "the main checkout is not a builder worktree" 0
head -c 3000000 /dev/zero >"$project/big.untracked"
stop "$project" factory:implementer; expect "main checkout output is never measured" 0

# --- a second refusal in a row does not loop forever, and is recorded ---
stop "$wt" factory:implementer true; expect "stop_hook_active lets the agent finish" 0
[ -f "$project/.factory/ledger.jsonl" ] || fail "no ledger line for output left behind"
jq -e -s 'last | .event == "build_output_left" and .agent_id == "agent-abc123" and .mb == 2 and .limit_mb == 1' \
  "$project/.factory/ledger.jsonl" >/dev/null || fail "ledger line: $(cat "$project/.factory/ledger.jsonl")"
pass=$((pass + 1))

# --- cleaned up: passes ---
rm -rf "$wt/target"
stop "$wt" factory:implementer; expect "cleaned worktree passes again" 0

# --- never blocks on its own trouble ---
code=0; printf '{"cwd": ' | bash "$hook" 2>/dev/null || code=$?
[ "$code" = 0 ] || fail "malformed input must exit 0, got $code"
pass=$((pass + 1))
stop "$tmp/nonexistent" factory:implementer; expect "unknown directory passes" 0
mkdir -p "$wt/target"; head -c 3000000 /dev/zero >"$wt/target/a.bin"
code=0
sed -e "s#@CWD@#$wt#" -e "s#@TYPE@#factory:implementer#" -e "s#@ACTIVE@#false#" "$fx/subagent-stop-implementer.json" |
  jq -c '.hook_event_name = "SubagentStart"' | env CLAUDE_PROJECT_DIR="$project" bash "$hook" 2>/dev/null || code=$?
[ "$code" = 0 ] || fail "other events must be ignored"
pass=$((pass + 1))

echo "build-clean suite passed ($pass checks)"
