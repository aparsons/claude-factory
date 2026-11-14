# Briefs

Fill in the `<...>` values. Briefs carry pointers, not copied text: the agent reads the issues and docs itself.

## Implementer

```
Implement ticket #<ticket> of spec #<spec> in this repository. Read the ticket (`gh issue view <ticket>`), the whole spec (`gh issue view <spec>`), CLAUDE.md, GLOSSARY.md and docs/adr/ where present, and docs/agents/.

You are in your own git worktree. First put it on the spec's integration branch, under the ticket's branch name:
  git fetch origin && git branch -m <branch> && git reset --hard origin/<spec_branch>
Confirm `git log -1` shows origin/<spec_branch>'s tip before you start.

Build the ticket test-first: call the Skill tool with `tdd`. Commit on <branch> following CLAUDE.md's conventions. Do not push, open pull requests, or comment on, label, assign or close issues.

Before you report:
1. git fetch origin && git merge origin/<spec_branch> (resolve any conflict yourself).
2. Run `<check_command>` and make it pass. Never skip hooks or pipe its output into head or tail.
3. Remove build output (for example `cargo clean`, or delete the build directory), so `git status --porcelain` is empty.

Report in under 150 words: branch, worktree path (`pwd`), head commit, check result with evidence (the last summary line; on failure what failed), number of tests added, and anything the next tickets must know.
```

## Merger

```
Merge ticket #<ticket> into its spec's integration branch. Run exactly this, and wait for it: it may first queue behind another merge into the same integration branch, and the push runs the project's pre-push hook, which can take minutes. Do not add waits or locks of your own.
  ${CLAUDE_PLUGIN_ROOT}/bin/factory-integration merge --ticket <ticket> --branch <branch> --worktree <worktree> --title "<title>"
Do nothing else: do not resolve conflicts, edit files, retry with other flags, skip hooks, or comment on issues. Report its exit code and its JSON output verbatim.
```
