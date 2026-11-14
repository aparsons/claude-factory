#!/usr/bin/env bash
# spawn-gate: PreToolUse hook on the Agent tool. Blocks a builder start when the
# machine has no room: free disk, free temporary space, or the builder cap.
# Read-only roles always pass. Blocks with exit 2 and a reason on stderr (Claude sees it).
# Any problem reading input or measuring fails OPEN with a warning on stderr: this is a
# resource safety net, not a security boundary, and a gate that blocks on its own bug would
# stop every agent start (including the manager's recovery); a false pass costs at most
# one worktree build, which the factory-watch monitor also flags.
#
# Test seam: when FACTORY_TEST=1, these replace real measurements:
#   FACTORY_TEST_FREE_DISK_MB, FACTORY_TEST_FREE_TEMP_MB,
#   FACTORY_TEST_RUNNING_BUILDERS, FACTORY_TEST_WORKTREE_MB
#
# Counting running builders: from the worktrees, not the ledger. A worktree is what holds
# the disk, it exists whether or not a ledger event was written, and it cannot lose a stop
# event to a crashed session. A worktree counts as running unless it is safe to remove:
# clean, tip contained in the default or a spec integration branch (merged, or no changes),
# and older than YOUNG_MIN minutes (so a builder just started is not mistaken for empty).
set -euo pipefail

YOUNG_MIN=15
warn() { echo "spawn-gate: warning: $*" >&2; }
plugin=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
# shellcheck disable=SC1091 # lib/common.sh, checked on its own
. "$plugin/lib/common.sh"

input=$(cat)
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$input"; then
  warn "hook input is not a JSON object; allowing the launch"
  exit 0
fi
tool=$(jq -r '.tool_name // ""' <<<"$input")
case "$tool" in Agent | Task) ;; *) exit 0 ;; esac
if ! jq -e '.tool_input | type == "object"' >/dev/null 2>&1 <<<"$input"; then
  warn "Agent call has no tool_input object; allowing the launch"
  exit 0
fi

# A role is an agent definition (agents/<role>.md); it is a builder when it runs in its own
# worktree (isolation: worktree in its frontmatter), as is any agent started with that isolation.
agent_type=$(jq -r '.tool_input.subagent_type // ""' <<<"$input")
isolation=$(jq -r '.tool_input.isolation // ""' <<<"$input")
role=other builder=0
if def=$(factory_role_file "$plugin" "$agent_type"); then
  role=${agent_type#factory:}
  awk 'NR == 1 { next } /^---$/ { exit } /^isolation:[ \t]*worktree[ \t]*$/ { found = 1 } END { exit !found }' "$def" && builder=1
fi
[ "$isolation" = worktree ] && builder=1
[ "$builder" = 1 ] || exit 0

project=${CLAUDE_PROJECT_DIR:-}
if [ -z "$project" ]; then
  cwd=$(jq -r '.cwd // ""' <<<"$input")
  project=$(git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null) || {
    warn "cannot find the project directory; allowing the launch"
    exit 0
  }
fi

# --- settings: built-in defaults, merged with .factory/settings.json ---
cap=3 reserve_gb=5 temp_min_gb=1 default_build_gb=4
settings="$project/.factory/settings.json"
num_re='^[0-9.]+$'
if [ -f "$settings" ]; then
  if s=$(jq -r '[(.builder_cap // 3), (.disk_reserve_gb // 5), (.temp_min_gb // 1), (.default_worktree_gb // 4)] | map(tostring) | join(" ")' "$settings" 2>/dev/null) &&
    read -r c r t d <<<"$s" && [[ "$c$r$t$d" =~ $num_re ]]; then
    cap=$c reserve_gb=$r temp_min_gb=$t default_build_gb=$d
  else
    warn "$settings is unreadable or has non-numeric limits; using defaults"
  fi
fi
gb_to_mb() { awk -v g="$1" 'BEGIN { printf "%d", g * 1024 }'; }
reserve_mb=$(gb_to_mb "$reserve_gb")
temp_min_mb=$(gb_to_mb "$temp_min_gb")
default_build_mb=$(gb_to_mb "$default_build_gb")

# --- worktrees under the project's worktree directories ---
wt_dirs=()
for d in "$project/.worktrees" "$project/.claude/worktrees"; do [ -d "$d" ] && wt_dirs+=("$d"); done
wt_paths=()
if [ ${#wt_dirs[@]} -gt 0 ]; then
  while IFS= read -r line; do
    p=${line#worktree }
    for d in "${wt_dirs[@]}"; do
      case "$p" in "$d"/*) [ -d "$p" ] && wt_paths+=("$p") ;; esac
    done
  done < <(git -C "$project" worktree list --porcelain 2>/dev/null | grep '^worktree ' || true)
fi

# base refs a worktree can be merged into: default branch and spec integration branches
bases=()
while IFS= read -r r; do [ -n "$r" ] && bases+=("$r"); done < <(
  {
    git -C "$project" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true
    for r in main master; do
      git -C "$project" rev-parse -q --verify "refs/heads/$r" >/dev/null 2>&1 && echo "refs/heads/$r"
      git -C "$project" rev-parse -q --verify "refs/remotes/origin/$r" >/dev/null 2>&1 && echo "refs/remotes/origin/$r"
    done
    git -C "$project" for-each-ref --format='%(refname)' refs/heads/spec refs/remotes/origin/spec 2>/dev/null || true
  } | sort -u
)

now=$(date +%s)
running=0
safe=()
largest_kb=0
for p in "${wt_paths[@]}"; do
  kb=$(du -sk "$p" 2>/dev/null | cut -f1 || true)
  [ -n "$kb" ] && [ "$kb" -gt "$largest_kb" ] && largest_kb=$kb
  branch=$(git -C "$p" symbolic-ref -q --short HEAD 2>/dev/null || true)
  case "$branch" in main | master | spec/*) continue ;; esac # integration worktrees are not builders
  head=$(git -C "$p" rev-parse -q --verify HEAD 2>/dev/null || true)
  merged=0
  for b in "${bases[@]}"; do
    [ -n "$branch" ] && [ "$b" = "refs/heads/$branch" ] && continue
    if [ -n "$head" ] && git -C "$p" merge-base --is-ancestor "$head" "$b" 2>/dev/null; then merged=1; break; fi
  done
  dirty=0
  [ -n "$(git -C "$p" status --porcelain 2>/dev/null || true)" ] && dirty=1
  born=$(stat -c %Y "$p/.git" 2>/dev/null || echo "$now")
  young=0
  [ $((now - born)) -lt $((YOUNG_MIN * 60)) ] && young=1
  if [ $merged = 1 ] && [ $dirty = 0 ] && [ $young = 0 ]; then
    safe+=("${p#"$project"/}${branch:+ ($branch)}")
  else
    running=$((running + 1))
  fi
done
measured_mb=$(((largest_kb + 1023) / 1024))

# --- free space ---
free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'; }
free_disk=""
for d in "$project" "${wt_dirs[@]}"; do
  v=$(free_mb "$d" || true)
  [ -n "$v" ] && { [ -z "$free_disk" ] || [ "$v" -lt "$free_disk" ]; } && free_disk=$v
done
free_temp=$(free_mb "${TMPDIR:-/tmp}" || true)
build_mb=${measured_mb:-0}
build_source="measured"
if [ "${build_mb:-0}" -le 0 ]; then build_mb=$default_build_mb build_source="default"; fi

if [ "${FACTORY_TEST:-}" = 1 ]; then
  free_disk=${FACTORY_TEST_FREE_DISK_MB:-$free_disk}
  free_temp=${FACTORY_TEST_FREE_TEMP_MB:-$free_temp}
  running=${FACTORY_TEST_RUNNING_BUILDERS:-$running}
  if [ -n "${FACTORY_TEST_WORKTREE_MB:-}" ]; then build_mb=$FACTORY_TEST_WORKTREE_MB build_source="measured"; fi
fi
if ! [[ "${free_disk:-}" =~ ^[0-9]+$ && "${free_temp:-}" =~ ^[0-9]+$ ]]; then
  warn "could not measure free disk or temporary space; allowing the launch"
  exit 0
fi

need_disk=$((2 * build_mb + reserve_mb))
problems=()
[ "$free_disk" -lt "$need_disk" ] && problems+=("free disk is $free_disk MB, need $need_disk MB (2 x $build_mb MB worktree build [$build_source] + $reserve_mb MB reserve)")
[ "$free_temp" -lt "$temp_min_mb" ] && problems+=("free temporary space is $free_temp MB, need $temp_min_mb MB")
[ "$running" -ge "$cap" ] && problems+=("$running builders are running, the cap is $cap")
[ ${#problems[@]} -eq 0 ] && exit 0

{
  echo "spawn-gate: builder start blocked (role: $role)."
  printf ' - %s\n' "${problems[@]}"
  if [ ${#safe[@]} -gt 0 ]; then
    echo "Worktrees safe to remove (merged into their base, or with no changes):"
    printf '   %s\n' "${safe[@]}"
  else
    echo "No worktree is safe to remove (none is merged or empty)."
  fi
  echo "Free the space or wait for a running builder to finish, then start the builder again."
  echo "Limits come from .factory/settings.json (builder_cap, disk_reserve_gb, temp_min_gb, default_worktree_gb)."
} >&2
exit 2
