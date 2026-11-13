# Recorded hook input for the ledger hook

Shapes follow the Claude Code hooks reference, https://code.claude.com/docs/en/hooks :

- common fields (`session_id`, `transcript_path`, `cwd`, `hook_event_name`, `effort.level`): "Common input fields"
- `subagent-start.json`: "SubagentStart input" (`agent_id`, `agent_type`; no model, effort of the subagent or prompt)
- `subagent-stop.json`: "SubagentStop input" (`agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`)
- `pre-agent.json`: "PreToolUse input", Agent tool fields (`prompt`, `description`, `subagent_type`, `model`)
- `post-agent.json`: PostToolUse `tool_response` of a foreground Agent call (`agentId`, `resolvedModel`, `totalDurationMs`, `usage`; note `usage` and `totalTokens` cover the final request only, so the hook sums the subagent transcript instead)
- `transcript.jsonl`: a small subagent transcript. Assistant lines carry `message.id`, `message.model` and `message.usage`; a streamed message appears more than once under one id and counts once (its last copy).
- `transcript-partial.jsonl`: a transcript whose usage lacks cache fields, to check that unavailable fields stay null.

`@TRANSCRIPT@` in a fixture is replaced with the transcript path by the suite.
