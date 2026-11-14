#!/usr/bin/env bash
# build-clean: SubagentStop hook, a builder's stop check. Refuses to let a builder finish
# while its worktree's build output is above the configured size, so cleaning up is enforced
# rather than asked for. Blocks with exit 2 and a reason on stderr (the agent sees it and
# keeps working).
#
# Build output = what is not tracked in the worktree: untracked files and git-ignored files
# (target/, build/, node_modules/, ...). Measured in the agent's working directory's
# worktree; the project's main checkout is never measured, and neither are read-only roles
# (reviewers, watcher, merger, Explore, Plan).
# Settings (.factory/settings.json): build_output_max_mb (default 500).
#
# A second refusal in a row (stop_hook_active) lets the agent finish and records a
# build_output_left line in the ledger instead: a builder that cannot clean must not loop.
# Any problem reading input or measuring exits 0: this is a resource safety net.
set -euo pipefail
trap 'exit 0' ERR

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
# shellcheck disable=SC1091 # lib/common.sh, checked on its own
. "$root/lib/common.sh"

input=$(cat)
[ "$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)" = SubagentStop ] || exit 0

agent_type=$(jq -r '.agent_type // ""' <<<"$input")
case "${agent_type#factory:}" in
  merger | standards-reviewer | spec-reviewer | watcher | Explore | Plan) exit 0 ;;
esac

cwd=$(jq -r '.cwd // empty' <<<"$input")
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
gitdir=$(git -C "$top" rev-parse --path-format=absolute --git-dir 2>/dev/null) || exit 0
common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
[ "$gitdir" != "$common" ] || exit 0 # the main checkout is not a builder's worktree

cd "$top"
project=$(factory_project)
limit_mb=$(factory_settings "$project" | jq -r '.build_output_max_mb // 500')
[[ "$limit_mb" =~ ^[0-9]+$ ]] || limit_mb=500

paths=()
while IFS= read -r -d '' p; do paths+=("$p"); done < <(git ls-files -o --directory -z)
[ ${#paths[@]} -gt 0 ] || exit 0
sizes=$(du -sk -- "${paths[@]}" 2>/dev/null | sort -rn || true)
total_kb=$(awk '{ s += $1 } END { print s + 0 }' <<<"$sizes")
[ "$total_kb" -gt $((limit_mb * 1024)) ] || exit 0
total_mb=$(((total_kb + 1023) / 1024))

if [ "$(jq -r '.stop_hook_active // false' <<<"$input")" = true ]; then
  mkdir -p "$project/.factory"
  jq -cn --arg ts "$(factory_now)" --arg id "$(jq -r '.agent_id // empty' <<<"$input")" --arg wt "$top" \
    --argjson mb "$total_mb" --argjson limit "$limit_mb" \
    '{ts: $ts, event: "build_output_left", agent_id: (if $id == "" then null else $id end), worktree: $wt, mb: $mb, limit_mb: $limit}' \
    >>"$project/.factory/ledger.jsonl"
  exit 0
fi

{
  echo "build-clean: you cannot finish yet. Your worktree's build output is $total_mb MB and the limit is $limit_mb MB ($top)."
  echo "Largest untracked or ignored items:"
  head -n 5 <<<"$sizes" | awk '{ printf "   %s KB  ", $1; sub(/^[0-9]+\t/, ""); print }'
  echo "Remove your build output (for example cargo clean, or delete the build or target directory) until git status --porcelain is empty, then report again."
} >&2
exit 2
