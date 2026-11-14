# shellcheck shell=bash
# Shared helpers for the factory's executables. Source it; it defines functions only.

# factory_project: the project root. $CLAUDE_PROJECT_DIR when set, else the main
# checkout of the current repository (so a call from inside a worktree still finds
# the project's one .factory directory), else the current directory.
factory_project() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return
  fi
  local common
  if common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    case "$common" in
      */.git) printf '%s\n' "${common%/.git}"; return ;;
    esac
    git rev-parse --show-toplevel 2>/dev/null && return
  fi
  pwd
}

# factory_ready_label <project>: the label string the project uses for the
# ready-for-agent role, read from docs/agents/triage-labels.md (second column of the
# ready-for-agent row); ready-for-agent when the file or row is absent.
factory_ready_label() {
  local f="$1/docs/agents/triage-labels.md" label=""
  if [ -f "$f" ]; then
    label=$(awk -F'|' '$2 ~ /`ready-for-agent`/ { gsub(/[` ]/, "", $3); print $3; exit }' "$f")
  fi
  printf '%s\n' "${label:-ready-for-agent}"
}

# factory_settings <project>: the project's .factory/settings.json as compact JSON,
# or {} when absent or unreadable.
factory_settings() {
  local f="$1/.factory/settings.json"
  if [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    jq -c . "$f"
  else
    echo '{}'
  fi
}

# factory_merge_stall_minutes <project>: minutes a ticket may sit between a passed gate and its
# merge before it counts as stalled: merge_stall_minutes from the settings, 60 when unset or
# not a non-negative number.
factory_merge_stall_minutes() {
  factory_settings "$1" | jq -r '.merge_stall_minutes | if type == "number" and . >= 0 then . else 60 end'
}

# factory_now: UTC ISO 8601, overridable with FACTORY_NOW for tests.
factory_now() { printf '%s\n' "${FACTORY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

# factory_exclude <project> <path>...: keeps factory paths (e.g. /.factory/) out of the user's
# `git status` by adding them to the repository's info/exclude when not already ignored.
# Local to the clone: no tracked file changes. A no-op outside a git repository.
factory_exclude() {
  local p=$1 ex path; shift
  ex=$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  ex="$ex/info/exclude"
  for path in "$@"; do
    git -C "$p" check-ignore -q "${path#/}x" 2>/dev/null && continue
    mkdir -p "$(dirname "$ex")"
    grep -qxF -- "$path" "$ex" 2>/dev/null || printf '%s\n' "$path" >>"$ex"
  done
}
