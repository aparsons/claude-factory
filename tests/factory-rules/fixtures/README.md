# Recorded hook input for factory-rules

`subagent-start-*.json` follow "SubagentStart input" in https://code.claude.com/docs/en/hooks
(common fields plus `agent_id` and `agent_type`). The hook answers with
`hookSpecificOutput.additionalContext`, which the subagent receives when it starts
("SubagentStart decision control"). `@CWD@` is replaced with the project directory by the suite.
