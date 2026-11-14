#!/usr/bin/env bash
# Suite: spawn-gate blocks builders when the machine has no room, never blocks read-only roles.
set -euo pipefail
# Under a git hook (pre-push) GIT_DIR and friends leak in and would point the temp repo's git calls at this one.
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/../../plugins/factory/hooks/spawn-gate.sh"
fx="$here/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spawn-gate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*"; exit 1; }

project="$tmp/proj"
mkdir -p "$project"
# gate <fixture> [ENV=VALUE...]: sets $code, $err
gate() {
  local f=$1; shift
  code=0
  err=$(env CLAUDE_PROJECT_DIR="$project" FACTORY_TEST=1 FACTORY_TEST_FREE_DISK_MB=100000 \
    FACTORY_TEST_FREE_TEMP_MB=100000 FACTORY_TEST_RUNNING_BUILDERS=0 FACTORY_TEST_WORKTREE_MB=1000 \
    "$@" "$gate" <"$f" 2>&1 >/dev/null) || code=$?
}
expect() { # expect <name> <code> [stderr-substring...]
  local name=$1 want=$2; shift 2
  [ "$code" = "$want" ] || fail "$name: exit $code, wanted $want ($err)"
  for s in "$@"; do [[ "$err" == *"$s"* ]] || fail "$name: stderr lacks '$s': $err"; done
  pass=$((pass + 1))
}

# --- pass ---
gate "$fx/agent-implementer.json"; expect "builder passes with room" 0
gate "$fx/agent-implementer-deep.json"; expect "deep builder passes with room" 0
gate "$fx/bash-call.json" FACTORY_TEST_FREE_DISK_MB=1; expect "non-agent tool ignored" 0

# --- block on disk: need 2*1000 + 5120 = 7120 MB ---
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=7119
expect "block on disk" 2 "free disk is 7119 MB" "need 7120 MB" "2 x 1000 MB"
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=7120; expect "disk exactly enough" 0
gate "$fx/agent-isolated.json" FACTORY_TEST_FREE_DISK_MB=10; expect "isolation makes a builder" 2 "free disk"

# --- block on temp: minimum 1024 MB ---
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_TEMP_MB=1023
expect "block on temp" 2 "free temporary space is 1023 MB" "need 1024 MB"
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_TEMP_MB=1024; expect "temp exactly enough" 0

# --- block on cap: default 3 ---
gate "$fx/agent-implementer.json" FACTORY_TEST_RUNNING_BUILDERS=3
expect "block on cap" 2 "3 builders are running, the cap is 3"
gate "$fx/agent-implementer.json" FACTORY_TEST_RUNNING_BUILDERS=2; expect "below cap" 0
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=1 FACTORY_TEST_FREE_TEMP_MB=1 FACTORY_TEST_RUNNING_BUILDERS=9
expect "all reasons listed" 2 "free disk" "free temporary space" "builders are running"

# --- read-only roles never blocked, even with nothing free ---
bad=(FACTORY_TEST_FREE_DISK_MB=0 FACTORY_TEST_FREE_TEMP_MB=0 FACTORY_TEST_RUNNING_BUILDERS=99)
gate "$fx/agent-reviewer.json" "${bad[@]}"; expect "reviewer passes" 0
gate "$fx/agent-explore.json" "${bad[@]}"; expect "unknown type without isolation passes" 0

# --- settings override ---
mkdir -p "$project/.factory"
echo '{"builder_cap": 1, "disk_reserve_gb": 0, "temp_min_gb": 0.5}' >"$project/.factory/settings.json"
gate "$fx/agent-implementer.json" FACTORY_TEST_RUNNING_BUILDERS=1; expect "settings lower the cap" 2 "the cap is 1"
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=2000; expect "settings drop the reserve" 0
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=1999; expect "settings reserve still 2x build" 2 "need 2000 MB"
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_TEMP_MB=511; expect "settings temp minimum" 2 "need 512 MB"
echo '{"builder_cap": 9}' >"$project/.factory/settings.json"
gate "$fx/agent-implementer.json" FACTORY_TEST_RUNNING_BUILDERS=8; expect "partial settings merge over defaults" 0
gate "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=7119; expect "unset keys keep defaults" 2 "need 7120 MB"
echo 'not json' >"$project/.factory/settings.json"
gate "$fx/agent-implementer.json"; expect "bad settings use defaults with a warning" 0 "unreadable"
rm -rf "$project/.factory"

# --- malformed input fails open with a warning ---
gate "$fx/malformed.json"; expect "malformed input fails open" 0 "warning" "allowing"
code=0; err=$(printf '' | "$gate" 2>&1 >/dev/null) || code=$?; expect "empty input fails open" 0 "warning"
echo '{"tool_name":"Agent"}' >"$tmp/noinput.json"
gate "$tmp/noinput.json"; expect "missing tool_input fails open" 0 "warning"

# --- real worktrees: counting, measured size, safe-to-remove list (no injected counts) ---
git init -q -b main "$project"
git -C "$project" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$project" branch spec/x
mkdir -p "$project/.worktrees"
git -C "$project" worktree add -q "$project/.worktrees/t-merged" -b t-merged spec/x
git -C "$project" worktree add -q "$project/.worktrees/t-live" -b t-live spec/x
git -C "$project" worktree add -q "$project/.worktrees/t-fresh" -b t-fresh spec/x
git -C "$project" worktree add -q "$project/.worktrees/t-dirty" -b t-dirty spec/x
git -C "$project" -c user.name=t -c user.email=t@t -C "$project/.worktrees/t-live" commit -q --allow-empty -m work
echo x >"$project/.worktrees/t-dirty/new.txt"
head -c 3000000 /dev/zero >"$project/.worktrees/t-live/build.bin"
old=$(date -d '2 hours ago' +%Y%m%d%H%M)
for w in t-merged t-live t-dirty; do touch -t "$old" "$project/.worktrees/$w/.git"; done
real() { # real <fixture> [ENV=VALUE...]: only the free space is injected
  local f=$1; shift
  code=0
  err=$(env CLAUDE_PROJECT_DIR="$project" FACTORY_TEST=1 FACTORY_TEST_FREE_DISK_MB=100000 \
    FACTORY_TEST_FREE_TEMP_MB=100000 "$@" "$gate" <"$f" 2>&1 >/dev/null) || code=$?
}
echo '{"builder_cap": 3, "disk_reserve_gb": 0}' >"$project/.factory-settings.tmp"; mkdir -p "$project/.factory"
mv "$project/.factory-settings.tmp" "$project/.factory/settings.json"
real "$fx/agent-implementer.json"; expect "3 running (live, fresh, dirty) hits cap 3" 2 "3 builders are running" \
  "t-merged"
[[ "$err" != *"t-live"* && "$err" != *"t-fresh"* && "$err" != *"t-dirty"* ]] || fail "unsafe worktree named as safe: $err"
real "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=5; expect "measured size used" 2 "[measured]"
echo '{"builder_cap": 4, "disk_reserve_gb": 0}' >"$project/.factory/settings.json"
real "$fx/agent-implementer.json"; expect "cap 4 passes with 3 running" 0
rm -rf "$project/.worktrees"; git -C "$project" worktree prune
real "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=4000
expect "default 4 GB build used when no worktrees" 2 "[default]" "need 8192 MB"

# --- build output of the main checkout and of integration worktrees counts too ---
# Faked large main-checkout build output: 12000 MB in target/ makes the build estimate 12000 MB.
mkdir -p "$project/.factory"
echo '{"builder_cap": 9, "disk_reserve_gb": 0}' >"$project/.factory/settings.json"
real "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=23999 FACTORY_TEST_MAIN_BUILD_MB=12000
expect "large main-checkout build output raises the need" 2 "need 24000 MB" "2 x 12000 MB"
[[ "$err" == *"Build output outside ticket worktrees"* && "$err" == *"main checkout"* && "$err" == *"target"* && "$err" == *"12000 MB"* ]] ||
  fail "block reason does not list the main checkout's build output with its size: $err"
[[ "$err" == *"Nothing is using"* && "$err" == *"only with the user's yes"* ]] || fail "block reason does not offer cleaning with the user: $err"
pass=$((pass + 1))
real "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=24000 FACTORY_TEST_MAIN_BUILD_MB=12000
expect "enough room for the main checkout's build size passes" 0

# Real files: the main checkout's untracked and ignored paths are measured; its worktree dirs are not.
mkdir -p "$project/target" "$project/.worktrees"
head -c 3145728 /dev/zero >"$project/target/out.bin"
head -c 9000000 /dev/zero >"$project/.worktrees/stray.bin"
real "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=5
expect "real main-checkout build output measured" 2 "main checkout" "target (3 MB)"
[[ "$err" != *"stray.bin"* ]] || fail "worktree directory counted as main build output: $err"

# An integration worktree's build output is listed and counts toward the estimate.
git -C "$project" worktree add -q "$project/.worktrees/spec-x" spec/x
mkdir -p "$project/.worktrees/spec-x/build"
head -c 6291456 /dev/zero >"$project/.worktrees/spec-x/build/out.bin"
real "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=11
expect "integration worktree build output listed" 2 "integration worktree .worktrees/spec-x" "build (6 MB)"

# Cleaning is offered only when nothing is using the main checkout's build output.
(cd "$project/target" && exec sleep 30) &
holder=$!
sleep 0.3
real "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=5
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[[ "$err" == *"in use"* && "$err" != *"Nothing is using"* ]] || fail "cleaning offered while a process runs in the build directory: $err"
pass=$((pass + 1))
real "$fx/agent-implementer.json" FACTORY_TEST_FREE_DISK_MB=5
[[ "$err" == *"Nothing is using"* ]] || fail "cleaning not offered when nothing uses the build directory: $err"
[ -f "$project/target/out.bin" ] || fail "the gate deleted the main checkout's build output"
pass=$((pass + 1))

echo "spawn-gate suite passed ($pass checks)"
