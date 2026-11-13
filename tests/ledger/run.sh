#!/usr/bin/env bash
# shellcheck disable=SC2015
# Suite: the ledger hook, run with recorded hook input.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$root/plugins/factory/hooks/ledger.sh"
fx="$root/tests/ledger/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ledger-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0 count=0
ok() { count=$((count + 1)); }
bad() { echo "FAIL: $*"; fail=1; }
# run <fixture> <now>: feed a fixture to the hook with the project at $tmp/proj
run() {
  local f=$1 now=$2
  sed "s#@TRANSCRIPT@#${3:-$fx/transcript.jsonl}#" "$fx/$f" |
    CLAUDE_PROJECT_DIR="$tmp/proj" LEDGER_NOW="$now" bash "$hook"
}
ledger="$tmp/proj/.factory/ledger.jsonl"
last() { tail -n 1 "$ledger"; }
check() { # check <label> <jq filter on last line, must be true>
  if jq -e "$2" <<<"$(last)" >/dev/null; then ok; else bad "$1: $(last)"; fi
}

# Launch (PreToolUse): requested model, ticket from description, role stripped of prefix.
run pre-agent.json 2026-01-01T10:00:00Z
check "launch" '.event == "agent_launch" and .ticket == 3 and .role == "implementer" and .model == "sonnet" and .effort == "high" and .tool_use_id == "toolu_01ABC" and .session_id == "sess-1"'

# Start.
run subagent-start.json 2026-01-01T10:00:05Z
check "start" '.event == "agent_start" and .agent_id == "agent-abc123" and .role == "implementer" and .agent_type == "factory:implementer" and .model == null and .ts == "2026-01-01T10:00:05Z"'

# Stop: tokens summed once per message id, duration from the start line, ticket from the prompt.
run subagent-stop.json 2026-01-01T10:10:05Z
check "stop" '.event == "agent_stop" and .duration_s == 600 and .outcome == "completed" and .model == "claude-sonnet-5-5" and .ticket == 3 and .effort == "high"
  and .tokens == {input: 120, output: 80, cache_read: 2500, cache_creation: 200}'

# Launch result joins agent id and resolved model.
run post-agent.json 2026-01-01T10:10:06Z
check "launch result" '.event == "agent_launch_result" and .agent_id == "agent-abc123" and .model == "claude-sonnet-5-5" and .tool_use_id == "toolu_01ABC"'

# Missing fields: no transcript, no start line, unknown type -> nulls, role other, still one line.
before=$(wc -l <"$ledger")
run subagent-stop-missing.json 2026-01-01T11:00:00Z
check "missing" '.role == "other" and .duration_s == null and .started_at == null and .model == null and .ticket == null and .effort == null
  and .tokens == {input: null, output: null, cache_read: null, cache_creation: null}'
[ "$(wc -l <"$ledger")" -eq $((before + 1)) ] && ok || bad "missing: expected one new line"

# Partial usage: absent cache fields stay null, present ones are summed.
run subagent-stop.json 2026-01-01T12:00:00Z "$fx/transcript-partial.jsonl"
check "partial" '.tokens == {input: 7, output: 3, cache_read: null, cache_creation: null} and .model == "claude-haiku-5-5" and .ticket == null'

# Other tools and malformed input are ignored and never fail.
before=$(wc -l <"$ledger")
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' | CLAUDE_PROJECT_DIR="$tmp/proj" bash "$hook" && ok || bad "bash exit"
echo 'garbage' | CLAUDE_PROJECT_DIR="$tmp/proj" bash "$hook" && ok || bad "garbage exit"
[ "$(wc -l <"$ledger")" -eq "$before" ] && ok || bad "ignored input wrote a line"

# Every line is valid JSON with ts and event.
jq -e -s 'all(.[]; has("ts") and has("event"))' "$ledger" >/dev/null && ok || bad "lines lack ts/event"

[ "$fail" -eq 0 ] || exit 1
echo "ledger suite passed ($count checks)"
