#!/usr/bin/env bash
# ledger hook: appends one JSON line per agent event to <project>/.factory/ledger.jsonl.
# Events (hook input is JSON on stdin):
#   PreToolUse(Agent)   -> agent_launch         description, requested model, ticket (#<n>), tool_use_id
#   PostToolUse(Agent)  -> agent_launch_result  agent id and resolved model, joined to the launch by tool_use_id
#   SubagentStart       -> agent_start          agent id, type, role
#   SubagentStop        -> agent_stop           duration, outcome, model and tokens read from the agent transcript
# Anything unavailable is recorded as null, never guessed. The hook never blocks: it always exits 0.
# Test seams: LEDGER_NOW overrides the timestamp (UTC ISO 8601).
set -euo pipefail
trap 'exit 0' ERR

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null) || exit 0
[ -n "$event" ] || exit 0

project=${CLAUDE_PROJECT_DIR:-}
if [ -z "$project" ]; then
  project=$(jq -r '.cwd // empty' <<<"$input")
  project=$(git -C "${project:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${project:-.}")
fi
dir="$project/.factory"
ledger="$dir/ledger.jsonl"
now=${LEDGER_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

# Shared jq definitions: role from agent type; ticket number from text.
defs='
def role: (. // "") | sub("^factory:"; "")
  | if IN("implementer","implementer-deep","merger","standards-reviewer","spec-reviewer","watcher") then . else "other" end;
def ticket: (. // "") | (capture("#(?<n>[0-9]+)") | .n | tonumber) // null;
'

case "$event" in
PreToolUse | PostToolUse)
  [ "$(jq -r '.tool_name // empty' <<<"$input")" = "Agent" ] || exit 0
  if [ "$event" = PreToolUse ]; then
    jq -c --arg ts "$now" "$defs"'
      .tool_input as $t
      | {ts: $ts, event: "agent_launch", session_id: (.session_id // null),
         tool_use_id: (.tool_use_id // null),
         agent_type: ($t.subagent_type // null),
         role: ($t.subagent_type | role),
         description: ($t.description // null),
         model: ($t.model // null),
         effort: (.effort.level // null),
         ticket: ((($t.description | ticket) // ($t.prompt | ticket)))}' <<<"$input" | { mkdir -p "$dir"; cat >>"$ledger"; }
  else
    jq -c --arg ts "$now" '
      (.tool_response // {}) as $r
      | {ts: $ts, event: "agent_launch_result", session_id: (.session_id // null),
         tool_use_id: (.tool_use_id // null),
         agent_id: ($r.agentId // null),
         status: ($r.status // null),
         model: ($r.resolvedModel // null)}' <<<"$input" | { mkdir -p "$dir"; cat >>"$ledger"; }
  fi
  ;;
SubagentStart)
  jq -c --arg ts "$now" "$defs"'
    {ts: $ts, event: "agent_start", session_id: (.session_id // null),
     agent_id: (.agent_id // null), agent_type: (.agent_type // null),
     role: (.agent_type | role),
     model: null, effort: (.effort.level // null), ticket: null}' <<<"$input" | { mkdir -p "$dir"; cat >>"$ledger"; }
  ;;
SubagentStop)
  agent_id=$(jq -r '.agent_id // empty' <<<"$input")
  started=null
  if [ -n "$agent_id" ] && [ -f "$ledger" ]; then
    started=$(jq -cs --arg id "$agent_id" \
      '[.[] | select(type == "object" and .event == "agent_start" and .agent_id == $id)] | (last | .ts) // null' \
      "$ledger" 2>/dev/null || echo null)
  fi
  transcript=$(jq -r '.agent_transcript_path // empty' <<<"$input")
  transcript=${transcript/#\~/$HOME}
  parsed='{}'
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    parsed=$(jq -R -s -c '
      (split("\n") | map(fromjson? // empty)) as $l
      | ($l | map(select(.type == "assistant" and (.message.usage | type) == "object"))) as $a
      # streamed messages repeat under one id: keep the last copy of each
      | ($a | to_entries | group_by(.value.message.id // ("noid" + (.key | tostring))) | map(last.value)) as $u
      | def sum(f): [$u[].message.usage | f | select(type == "number")] as $v
          | if ($v | length) == 0 then null else ($v | add) end;
        {found: ($u | length > 0),
         model: ([$a[].message.model | select(. != null and . != "<synthetic>")] | first // null),
         prompt: ([$l[] | select(.type == "user") | .message.content
                   | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end] | first // null),
         tokens: {input: sum(.input_tokens), output: sum(.output_tokens),
                  cache_read: sum(.cache_read_input_tokens), cache_creation: sum(.cache_creation_input_tokens)}}' \
      "$transcript" 2>/dev/null || echo '{}')
  fi
  jq -c --arg ts "$now" --argjson started "$started" --argjson p "$parsed" "$defs"'
    {ts: $ts, event: "agent_stop", session_id: (.session_id // null),
     agent_id: (.agent_id // null), agent_type: (.agent_type // null),
     role: (.agent_type | role),
     model: ($p.model // null),
     effort: (.effort.level // null),
     ticket: (($p.prompt | ticket)),
     started_at: $started,
     duration_s: (if $started == null then null else (($ts | fromdateiso8601) - ($started | fromdateiso8601)) end),
     outcome: "completed",
     tokens: ($p.tokens // {input: null, output: null, cache_read: null, cache_creation: null})}' <<<"$input" | { mkdir -p "$dir"; cat >>"$ledger"; }
  ;;
esac
exit 0
