# Recorded hook input

Shapes follow the PreToolUse input documented at https://code.claude.com/docs/en/hooks
(common fields plus `tool_name`, `tool_input`, `tool_use_id`; the Agent tool's `tool_input`
has `prompt`, `description`, `subagent_type`, `model`). The subagent tool is named `Agent`
(formerly `Task`, still accepted as an alias): https://code.claude.com/docs/en/sub-agents
Isolation is passed on the call as `isolation: "worktree"` (the docs show the value in agent
frontmatter; the same word is assumed on the call). Blocking: exit 2, stderr is the reason
Claude sees (hooks reference, PreToolUse decision control).
