#!/usr/bin/env bash
# shellcheck disable=SC2016 # Markdown with backticks is written and matched literally
# Suite: factory-rules adds the project's rules as context to every starting subagent.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$root/plugins/factory/hooks/factory-rules.sh"
fx="$root/tests/factory-rules/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/factory-rules.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*"; exit 1; }

project="$tmp/proj"
mkdir -p "$project"
git init -q -b main "$project"
printf '## Checks\n\nRun `scripts/check.sh` before every commit.\n' >"$project/CLAUDE.md"

# run <fixture> [ENV=VALUE...]: sets $code, $out, $ctx (the added context)
run() {
  local f=$1; shift
  code=0
  out=$(sed "s#@CWD@#$project#" "$f" | env CLAUDE_PROJECT_DIR="$project" "$@" bash "$hook" 2>"$tmp/err") || code=$?
  ctx=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out" 2>/dev/null || true)
}
has() { # has <name> <substring...>: the context contains each substring
  local name=$1; shift
  [ "$code" = 0 ] || fail "$name: exit $code"
  for s in "$@"; do [[ "$ctx" == *"$s"* ]] || fail "$name: context lacks '$s': $ctx"; done
  pass=$((pass + 1))
}
lacks() { # lacks <name> <substring>
  [[ "$ctx" != *"$2"* ]] || fail "$1: context has '$2': $ctx"
  pass=$((pass + 1))
}

# --- the rules, for a builder ---
run "$fx/subagent-start-implementer.json"
[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" = SubagentStart ] || fail "wrong event name: $out"
pass=$((pass + 1))
has "check command from CLAUDE.md" '`scripts/check.sh`'
has "lean build settings" "CARGO_BUILD_JOBS=2" "make -j2" "debug"
has "clean up before reporting" "Remove your build output" "git status --porcelain"
has "never skip hooks" "--no-verify" "core.hooksPath"
has "check output never truncated" "head" "tail"
has "secrets" "secret" "never print" "repository"
has "commit trailer" "trailer" "Co-Authored-By"
has "evidence" "evidence" "last summary line"

# --- every subagent, not only builders ---
run "$fx/subagent-start-explore.json"
has "a read-only agent gets the rules too" '`scripts/check.sh`' "--no-verify" "secret"

# --- settings ---
mkdir -p "$project/.factory"
echo '{"check_command": "make verify", "build_jobs": 4, "commit_trailer": "Signed-off-by: Bot <bot@example.com>"}' >"$project/.factory/settings.json"
run "$fx/subagent-start-implementer.json"
has "settings check_command wins" '`make verify`'
lacks "settings check_command replaces CLAUDE.md" 'scripts/check.sh'
has "settings build_jobs" "CARGO_BUILD_JOBS=4" "make -j4"
has "settings commit_trailer" "Signed-off-by: Bot <bot@example.com>"
echo 'not json' >"$project/.factory/settings.json"
run "$fx/subagent-start-implementer.json"
has "bad settings fall back to defaults" '`scripts/check.sh`' "CARGO_BUILD_JOBS=2"
rm -rf "$project/.factory"

# --- no check command in CLAUDE.md: the rest still applies ---
printf '# Notes\n' >"$project/CLAUDE.md"
run "$fx/subagent-start-implementer.json"
has "no check command" "names no check command" "--no-verify"
printf '## Checks\n\nRun `scripts/check.sh` before every commit.\n' >"$project/CLAUDE.md"

# --- project found from the working directory when CLAUDE_PROJECT_DIR is unset ---
code=0
out=$(sed "s#@CWD@#$project#" "$fx/subagent-start-implementer.json" | env -u CLAUDE_PROJECT_DIR bash "$hook" 2>/dev/null) || code=$?
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")
has "project from cwd" '`scripts/check.sh`'

# --- never blocks, never noisy ---
run "$fx/malformed.json"
[ "$code" = 0 ] && [ -z "$out" ] || fail "malformed input must exit 0 with no output: $code $out"
pass=$((pass + 1))
code=0; out=$(printf '' | bash "$hook" 2>/dev/null) || code=$?
[ "$code" = 0 ] && [ -z "$out" ] || fail "empty input must exit 0 with no output"
pass=$((pass + 1))
code=0
out=$(jq -c '.hook_event_name = "SubagentStop"' "$fx/subagent-start-implementer.json" | bash "$hook" 2>/dev/null) || code=$?
[ "$code" = 0 ] && [ -z "$out" ] || fail "other events must be ignored: $code $out"
pass=$((pass + 1))

echo "factory-rules suite passed ($pass checks)"
