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

# factory_claude_md <project>: the path of the project's CLAUDE.md, or nothing.
factory_claude_md() {
  local f
  for f in "$1/CLAUDE.md" "$1/.claude/CLAUDE.md"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return; }
  done
  return 0
}

# factory_check_command <project>: the project's check command: check_command in
# .factory/settings.json, else the first code span on a line of CLAUDE.md about checks or
# tests that looks like a command. Nothing when none is named.
factory_check_command() {
  local cmd md
  cmd=$(factory_settings "$1" | jq -r '.check_command // empty')
  if [ -z "$cmd" ]; then
    md=$(factory_claude_md "$1")
    if [ -n "$md" ]; then
      # shellcheck disable=SC2016 # backticks in the pattern are literal Markdown code-span marks
      cmd=$(grep -iE 'check|test|\bCI\b' "$md" | grep -oE '`[^`]+`' | tr -d '`' |
        grep -E '^(\./|scripts/|bin/|tools/)|\.sh( |$)|^(make|just|npm|pnpm|yarn|bun|deno|cargo|go|pytest|tox|nox|uv|poetry|mvn|gradle|\./gradlew|dotnet|bazel|mix|bundle|rake)( |$)' |
        head -n 1 || true)
    fi
  fi
  printf '%s\n' "$cmd"
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

# factory_roles <plugin root>: the role table, read from the agent definitions'
# frontmatter (agents/<role>.md, the only place it lives), as compact JSON:
#   {<role>: {role, agent: "factory:<role>", model, effort, isolation, builder, tools}}
# builder: the definition runs in its own worktree. tools: the allowlist, or null for all.
factory_roles() {
  local f
  for f in "$1"/agents/*.md; do
    [ -f "$f" ] || continue
    awk -v file="$(basename "$f" .md)" '
      NR == 1 { if ($0 != "---") exit; next }
      /^---$/ { exit }
      /^[A-Za-z][A-Za-z_-]*:/ {
        i = index($0, ":"); v = substr($0, i + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v)
        print file "\t" substr($0, 1, i - 1) "\t" v
      }' "$f"
  done | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t") | {file: .[0], key: .[1], value: .[2]})
    | group_by(.file)
    | map((map({key, value}) | from_entries) as $m | ($m.name // .[0].file) as $r
        | {key: $r, value: {role: $r, agent: ("factory:" + $r), model: ($m.model // null), effort: ($m.effort // null),
            isolation: ($m.isolation // null), builder: ($m.isolation == "worktree"),
            tools: (if ($m.tools // "") == "" then null else $m.tools | split(",") | map(gsub("^\\s+|\\s+$"; "")) end)}})
    | from_entries'
}

# factory_role_file <plugin root> <agent type>: the definition file of an agent type
# (factory:<role> or <role>); fails when the type names no definition.
factory_role_file() {
  local role=${2#factory:}
  [[ "$role" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [ -f "$1/agents/$role.md" ] || return 1
  printf '%s\n' "$1/agents/$role.md"
}

# factory_ci_infra_re: the errors that mark a CI failure as infrastructure, not the code's, as they
# appear in a log (extended regular expression, case-insensitive). Used by factory-ci and by
# factory-integration ci, so both read a log the same way.
factory_ci_infra_re() {
  printf '%s\n' 'shutdown signal|lost communication with the server|received request to deprovision|runner .*(went offline|is offline|unreachable)|could not resolve host|temporary failure in name resolution|name or service not known|eai_again|connection reset by peer|connection timed out|tls handshake timeout|etimedout|econnreset|failed to connect to|rpc failed; curl|unexpected disconnect while reading sideband|early eof|returned error: 50[0-9]|http error 50[0-9]|(^|[^0-9])50[234] (bad gateway|service unavailable|gateway time)|service unavailable|bad gateway|unable to (download|resolve) action|failed to download action|an action could not be found at the uri|the operation was canceled'
}
