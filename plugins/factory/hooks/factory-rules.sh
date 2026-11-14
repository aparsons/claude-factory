#!/usr/bin/env bash
# factory-rules: SubagentStart hook. Adds the project's rules to every starting subagent as
# context, because subagents do not load the user's memory and briefs should not repeat rules.
# The rules: the project's check command (from CLAUDE.md, or check_command in
# .factory/settings.json), lean build settings, clean up before reporting, never skip hooks,
# secrets never in output or the repository, the commit trailer, reports with evidence.
# Settings keys read: check_command, build_jobs (default 2), commit_trailer.
# Never blocks: any problem exits 0 with no output (a subagent without the rules still runs).
set -euo pipefail
trap 'exit 0' ERR

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
# shellcheck disable=SC1091 # lib/common.sh, checked on its own
. "$root/lib/common.sh"

input=$(cat)
[ "$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)" = SubagentStart ] || exit 0

if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  [ -d "$cwd" ] && cd "$cwd"
fi
project=$(factory_project)

settings=$(factory_settings "$project")
check_command=$(factory_check_command "$project")
jobs=$(jq -r '.build_jobs // 2' <<<"$settings")
[[ "$jobs" =~ ^[0-9]+$ ]] || jobs=2
trailer=$(jq -r '.commit_trailer // empty' <<<"$settings")

if [ -n "$check_command" ]; then
  check_rule="The project's check command is \`$check_command\`. Run it before every commit and before you report, and make it pass."
else
  check_rule="CLAUDE.md names no check command: read CLAUDE.md and the repository's scripts for how the project is checked, and run that before you report."
fi
if [ -n "$trailer" ]; then
  trailer_rule="End every commit message with this trailer: $trailer"
else
  trailer_rule="Follow CLAUDE.md's commit conventions. End every commit message and pull request description with the attribution trailer your instructions give (for example a Co-Authored-By line), exactly as given."
fi

rules="Factory rules for this project (they apply to you, whatever your brief says):
- Check: $check_rule Never skip hooks (no --no-verify, no core.hooksPath override), and never pipe the check or a push into head or tail, which hides a failing exit status.
- Build lean: at most $jobs parallel jobs (CARGO_BUILD_JOBS=$jobs, make -j$jobs, ninja -j$jobs, and the same for other tools), debug builds unless the ticket needs release, one build directory per worktree, no shared or extra target directories. Keep temporary files out of /tmp or delete them when you are done.
- Clean up before reporting: Remove your build output (for example cargo clean, or delete the build or target directory), so git status --porcelain is empty. A builder cannot finish while its worktree's build output is over the configured size.
- Secrets: never print a secret, token or key, and never write one into a file, a commit or the repository. If a command's output shows one, do not repeat it in your report.
- Commits: $trailer_rule
- Report with evidence: say what you ran and quote the result, such as the last summary line of the check, or what failed. Do not report success you did not observe."

jq -n --arg ctx "$rules" '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $ctx}}'
exit 0
