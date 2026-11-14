# Recorded hook input for the build-clean stop check

`subagent-stop-implementer.json` follows "SubagentStop input" in https://code.claude.com/docs/en/hooks
(`stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`).
Blocking a stop: exit 2 with the reason on stderr (SubagentStop decision control). The suite fills
`@CWD@` (the agent's working directory, assumed to be its worktree), `@TYPE@` and `@ACTIVE@`.
