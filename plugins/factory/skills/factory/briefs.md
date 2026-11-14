# Briefs

Fill in the `<...>` values. Briefs carry pointers, not copied text: the agent reads the issues and docs itself.

For a standalone ticket (`standalone: true`, no spec), the implementer brief opens with "Implement standalone ticket #<ticket> in this repository." and drops the spec from what to read; its `<spec_branch>` is the ticket's own `ticket/<n>-<slug>` branch.

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

## Escalated implementer

The implementer brief, with its worktree step replaced by this one and the paragraph after it added. `<what failed>`: the failing check output or the stall, in a few lines.

```
You are in your own git worktree. First put it on the previous attempt's branch, or on the spec's integration branch if that branch is gone:
  git fetch origin
  git rev-parse -q --verify refs/heads/<branch> && git reset --hard <branch> || git reset --hard origin/<spec_branch>
  git branch -M <branch>
Confirm `git log -1` shows that commit before you start.

This ticket is escalated: a previous attempt by <previous.role> (<previous.model>/<previous.effort>) failed (<reason>). What failed:
<what failed>
Read its commits on <branch> first (`git log origin/<spec_branch>..HEAD`). Keep what is sound, find the cause of the failure and fix it; start over from origin/<spec_branch> if the attempt is not worth keeping.
```

## Merger

```
Merge ticket #<ticket> into its spec's integration branch. Run exactly this, and wait for it: the push runs the project's pre-push hook, which can take minutes.
  ${CLAUDE_PLUGIN_ROOT}/bin/factory-integration merge --ticket <ticket> --branch <branch> --worktree <worktree> --title "<title>"
Do nothing else: do not resolve conflicts, edit files, retry with other flags, skip hooks, or comment on issues. Report its exit code and its JSON output verbatim.
```
