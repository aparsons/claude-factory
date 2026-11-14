#!/usr/bin/env bash
# Suite: factory-watch prints one line per state change (low disk or temporary space, a CI run
# past three times its workflow's median, a stalled worktree, a merged worktree not removed),
# over simulated states.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
watch="$root/plugins/factory/bin/factory-watch"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/watch-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*"; exit 1; }

now=2026-06-01T12:00:00Z
export FACTORY_NOW=$now FACTORY_TEST=1 FACTORY_TEST_FREE_DISK_MB=100000 FACTORY_TEST_FREE_TEMP_MB=100000
unset CLAUDE_SESSION_ID

# fresh <name>: a project with one commit on main; sets $project, exports CLAUDE_PROJECT_DIR
fresh() {
  project="$tmp/$1"
  mkdir -p "$project/.factory"
  export CLAUDE_PROJECT_DIR="$project"
  git -C "$project" init -q -b main
  git -C "$project" config user.email t@example.com
  git -C "$project" config user.name t
  GIT_AUTHOR_DATE=2026-05-01T00:00:00Z GIT_COMMITTER_DATE=2026-05-01T00:00:00Z git -C "$project" commit -q --allow-empty -m base
}
# lines <args...>: runs one check; sets $out (its stdout) and $n (its line count)
lines() {
  out=$("$watch" --once "$@" 2>"$tmp/err") || fail "factory-watch $*: exit $? ($(cat "$tmp/err"))"
  n=$(printf '%s' "$out" | grep -c . || true)
}
expect() { # expect <name> <lines> [substring...]
  local name=$1 want=$2 s
  shift 2
  [ "$n" = "$want" ] || fail "$name: $n lines, wanted $want: $out"
  for s in "$@"; do [[ "$out" == *"$s"* ]] || fail "$name: output lacks '$s': $out"; done
  pass=$((pass + 1))
}
# old <minutes> <path>...: sets the modification time that long before $now
old() {
  local m=$1
  shift
  touch -d "$(date -u -d "$now - $m minutes" +%Y-%m-%dT%H:%M:%SZ)" "$@"
}
# worktree <name> <own commit: 0|1> <idle minutes>: a builder worktree <name> on a branch of the
# same name under .worktrees, whose last activity was that long ago
worktree() {
  local p="$project/.worktrees/$1" when gd
  when=$(date -u -d "$now - $3 minutes" +%Y-%m-%dT%H:%M:%SZ)
  git -C "$project" worktree add -q -b "$1" "$p" main
  if [ "$2" = 1 ]; then
    echo "$1" >"$p/work.txt"
    git -C "$p" add work.txt
    GIT_AUTHOR_DATE=$when GIT_COMMITTER_DATE=$when git -C "$p" commit -q -m work
    old "$3" "$p/work.txt"
  fi
  gd=$(git -C "$p" rev-parse --absolute-git-dir)
  old "$3" "$p/.git" "$gd/HEAD"
  [ ! -e "$gd/logs/HEAD" ] || old "$3" "$gd/logs/HEAD"
}

# --- healthy: silent ---
fresh healthy
lines; expect "healthy machine prints nothing" 0

# --- free disk: one line on the change, none while it stays low, again after a recovery ---
fresh disk
FACTORY_TEST_FREE_DISK_MB=4000 lines; expect "low disk prints one line" 1 "disk" "4000 MB" "5120 MB"
FACTORY_TEST_FREE_DISK_MB=3000 lines; expect "still low, no new line" 0
lines; expect "recovered, silent" 0
FACTORY_TEST_FREE_DISK_MB=4000 lines; expect "low again prints again" 1 "disk"
FACTORY_TEST_FREE_DISK_MB=5120 lines; expect "exactly at the threshold is fine" 0

# --- temporary space ---
fresh temp
FACTORY_TEST_FREE_TEMP_MB=1023 lines; expect "low temporary space" 1 "temporary space" "1023 MB" "1024 MB"
FACTORY_TEST_FREE_TEMP_MB=1023 FACTORY_TEST_FREE_DISK_MB=1 lines; expect "disk added to temp: only the new one" 1 "disk"

# --- both at once: two lines, one each ---
fresh both
FACTORY_TEST_FREE_TEMP_MB=1 FACTORY_TEST_FREE_DISK_MB=1 lines; expect "two conditions, two lines" 2 "disk" "temporary space"

# --- thresholds from settings ---
fresh settings
echo '{"disk_reserve_gb": 1, "temp_min_gb": 0.5}' >"$project/.factory/settings.json"
FACTORY_TEST_FREE_DISK_MB=1100 FACTORY_TEST_FREE_TEMP_MB=600 lines; expect "settings lower the thresholds" 0
FACTORY_TEST_FREE_DISK_MB=1000 FACTORY_TEST_FREE_TEMP_MB=500 lines; expect "settings thresholds apply" 2 "1024 MB" "512 MB"

# --- CI runs past three times the workflow's median ---
# run <id> <workflow> <status> <started minutes before now> <duration seconds>
run() {
  local id=$1 wf=$2 st=$3 ago=$4 dur=$5 s u
  s=$(date -u -d "$now - $ago minutes" +%Y-%m-%dT%H:%M:%SZ)
  u=$(date -u -d "$s + $dur seconds" +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --argjson id "$id" --arg wf "$wf" --arg st "$st" --arg s "$s" --arg u "$u" \
    '{databaseId: $id, workflowName: $wf, status: $st, conclusion: (if $st == "completed" then "success" else "" end),
      createdAt: $s, startedAt: $s, updatedAt: (if $st == "completed" then $u else $s end),
      url: ("https://github.com/o/r/actions/runs/" + ($id | tostring))}'
}
fresh ci
{
  run 1 ci completed 300 60
  run 2 ci completed 200 60
  run 3 ci completed 100 90
  run 4 ci in_progress 4 0 # 240 s: past 3 x 60 s
  run 5 slow completed 500 600
  run 6 slow completed 400 600
  run 7 slow completed 300 600
  run 8 slow in_progress 10 0 # 600 s: well under 3 x 600 s
  run 9 young completed 50 10
  run 10 young completed 40 10
  run 11 young in_progress 60 0 # only two completed runs: no median to trust
} | jq -s . >"$tmp/runs.json"
lines --runs "$tmp/runs.json"
expect "run past 3x its workflow median" 1 "ci" "#4" "240 s" "180 s"
lines --runs "$tmp/runs.json"; expect "the same run is not reported twice" 0
# the run finishes, a new slow one starts: only the new one
{ jq -c '.[] | select(.databaseId != 4)' "$tmp/runs.json"; run 12 ci in_progress 5 0; } | jq -s . >"$tmp/runs2.json"
lines --runs "$tmp/runs2.json"; expect "another slow run is a new line" 1 "#12"
# a queued run has not started: never slow
{
  jq -c '.[] | select(.databaseId <= 3)' "$tmp/runs.json"
  jq -nc '{databaseId: 20, workflowName: "ci", status: "queued", conclusion: "", createdAt: "2026-06-01T08:00:00Z", startedAt: "2026-06-01T08:00:00Z", updatedAt: "2026-06-01T08:00:00Z", url: "u"}'
} | jq -s . >"$tmp/runs3.json"
fresh ci2
lines --runs "$tmp/runs3.json"; expect "queued run is not slow" 0
echo '[]' >"$tmp/none.json"
lines --runs "$tmp/none.json"; expect "no runs, no line" 0

# --- stalled worktree ---
fresh stall
worktree t5-busy 1 5
worktree t6-stuck 1 90
lines; expect "only the idle worktree stalls" 1 "t6-stuck" "stall" "90 min"
lines; expect "a stall is reported once" 0
echo '{"stall_minutes": 3}' >"$project/.factory/settings.json"
lines; expect "settings stall time: the busy one stalls too" 1 "t5-busy"
# progress clears it, so a later stall prints again
echo y >>"$project/.worktrees/t6-stuck/work.txt"
lines; expect "progress is silent" 0
old 90 "$project/.worktrees/t6-stuck/work.txt"
lines; expect "stalls again after progress" 1 "t6-stuck"

# --- uncommitted work counts as progress ---
fresh dirty
worktree t7-dirty 1 90
echo z >"$project/.worktrees/t7-dirty/new.txt"
lines; expect "a recently changed file is progress" 0

# --- a worktree just created has made no commits yet but is not stalled ---
fresh newborn
worktree t8-new 0 1
lines; expect "a new worktree is not stalled" 0

# --- merged worktree not removed ---
fresh merged
worktree t9-done 1 60
git -C "$project" merge -q --ff-only t9-done
lines; expect "merged, clean, old: not removed" 1 "t9-done" "merged" "not been removed"
lines; expect "reported once" 0
git -C "$project" worktree remove --force "$project/.worktrees/t9-done"
lines; expect "removed, silent" 0

fresh merged2
worktree t10-fresh 1 3
git -C "$project" merge -q --ff-only t10-fresh
lines; expect "merged moments ago is within the grace" 0
worktree t11-dirty 1 60
git -C "$project" merge -q --ff-only t11-dirty
echo more >>"$project/.worktrees/t11-dirty/work.txt"
lines; expect "merged but with changes: not reported as unremoved" 0

# --- a running assignment is a builder: idle is a stall, never "merged, not removed" ---
fresh assigned
echo '{"running": true, "assignments": {"12": {"ticket": 12, "branch": "t12-empty"}}}' >"$project/.factory/state.json"
worktree t12-empty 0 60
lines; expect "an assigned empty worktree stalls" 1 "stall" "t12-empty"
jq '.assignments = {}' "$project/.factory/state.json" >"$tmp/s.json"
mv "$tmp/s.json" "$project/.factory/state.json"
lines; expect "without the assignment it is merged, not removed" 1 "merged" "t12-empty"

# --- integration worktrees are not builders ---
fresh integ
git -C "$project" branch spec/1-x main
git -C "$project" worktree add -q "$project/.worktrees/spec-1" spec/1-x
old 600 "$project/.worktrees/spec-1/.git"
lines; expect "an integration worktree is never stalled or unremoved" 0

# --- the loop: prints on the change only, and stays quiet when the factory is not running ---
fresh loop
loop() { # loop <cycles>
  out=$(FACTORY_TEST_FREE_DISK_MB=1 "$watch" --interval 0 --cycles "$1" 2>"$tmp/err") || fail "loop: exit $? ($(cat "$tmp/err"))"
  n=$(printf '%s' "$out" | grep -c . || true)
}
echo '{"running": true}' >"$project/.factory/state.json"
loop 3; expect "loop prints a persistent condition once" 1 "disk"
echo '{"running": false}' >"$project/.factory/state.json"
loop 3; expect "loop is quiet when the factory is stopped" 0
rm -f "$project/.factory/state.json"
loop 2; expect "no state file: the loop watches" 1 "disk"

# --- bad arguments ---
if "$watch" --nonsense >/dev/null 2>&1; then fail "unknown argument accepted"; fi
pass=$((pass + 1))
"$watch" --help >/dev/null || fail "--help failed"
pass=$((pass + 1))

echo "watch suite passed ($pass checks)"
