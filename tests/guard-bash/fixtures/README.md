# Recorded hook input

Shape follows the PreToolUse input of the Claude Code hooks reference,
https://code.claude.com/docs/en/hooks (common fields plus `tool_name`, `tool_input.command`,
`tool_use_id`). Blocking is exit 2 with the reason on stderr; asking is exit 0 with
`hookSpecificOutput.permissionDecision: "ask"` on stdout (PreToolUse decision control).

- `bash-call.json`: the envelope; the suite swaps `tool_input.command` and `cwd` for each case.
- `no-verify.json`, `force-push-main.json`, `piped-tail.json`, `tail-log.json`, `commit-heredoc.json`,
  `gh-pr-merge.json`: whole recorded inputs, run as recorded.
- `malformed.json`, `agent-call.json`: input the hook must ignore.
