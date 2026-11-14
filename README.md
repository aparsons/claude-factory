# claude-factory

A Claude Code plugin that turns your session into the manager of an agent-driven software factory. You plan the work with `/to-spec` and `/to-tickets`; the factory runs agents on every ready ticket in parallel git worktrees, with a model and effort chosen for each task, enforces its rules with hooks, records every run in a ledger, and reports progress and KPIs.

## Install

```
/plugin marketplace add aparsons/claude-factory
/plugin install factory@claude-factory
```

## Use

In a project that follows the mattpocock-skills issue conventions (specs and tickets as issues, the triage labels, a check command named in `CLAUDE.md`):

- `/factory start`: checks prerequisites, then runs an implementer per ready ticket in rank order, each in its own worktree on the spec's integration branch `spec/<n>-<slug>`, and a merger that merges it there. It never merges to the default branch, tags, publishes or comments without asking.
- `/factory status`: frontier, running agents, blocked specs, KPIs.
- `/factory stop`: no new agents; offers to stop running ones; writes a digest.

While running, the manager keeps working between your messages: agent and CI completions wake it, and a heartbeat of 20 to 30 minutes (a dynamic loop wake-up, never short polling) covers the rest. It posts one line per event (ticket merged, agent stalled or escalated, CI red, budget threshold), writes a digest to `.factory/digests/` every 60 minutes while work runs, sends a push notification only when it needs you, and with an empty queue goes idle and lists what waits on you. `factory-rhythm` decides each of these; settings `report_interval_min`, `heartbeat_minutes` (default `[20, 30]`), `budget_five_hour_pct` and `budget_seven_day_pct`.

A spec is an issue with sub-issues (its tickets), or a parent-less issue marked as a spec (a `Spec:` or `PRD:` title, a `spec` label, or a `## User Stories` heading as `/to-spec` writes); a spec without sub-issues is reported as needing `/to-tickets`. Any other ready issue with no parent and no sub-issues, such as a bug or a small task, is a **standalone ticket**: ready when its native blockers are closed and ranked with the spec tickets by the same rules. Having no spec, it integrates into its own branch `ticket/<n>-<slug>`, made from the default branch: its implementer works from there, the merger merges it there, and it gets its own draft pull request (one ticket, one pull request). Merging that pull request to the default branch is an outward step the factory asks about, as for a spec.

## Guard rails

`guard-bash` runs before every Bash call, in every session and subagent. It reads the command the way a shell splits it (quotes, `$(...)`, heredocs, comments, `;` `&&` `||` `|` `&`), so a look-alike such as `tail -n 100 build.log` or a commit message that mentions `--no-verify` passes.

Blocked, with a reason the agent can act on:

- `--no-verify`, and `git commit -n`
- a `core.hooksPath` override (`git -c core.hooksPath=...`, `GIT_CONFIG_KEY_n=core.hooksPath`, `git config core.hooksPath <elsewhere>`); a relative path in the repository's own config, as in `git config core.hooksPath .githooks`, is allowed
- a force-push (`--force`, `-f`, `--force-with-lease`, `+ref`, `--mirror`) or delete of the default branch (`main`, `master` and whatever `origin/HEAD` names)
- a check, test, build or push piped into `head` or `tail` without `pipefail` (the pipe's status is `tail`'s, so a failure looks like success); the project's check command from `CLAUDE.md` counts as a check

Asked, so Claude Code prompts you even in auto mode: `gh pr merge`, `gh release` (except `list`, `view`, `download`), `git tag` (except listing), a push to the default branch, `git push --tags` or a tag ref. A Claude Code plugin cannot ship `permissions.ask` in its own settings (only `agent` and `subagentStatusLine` take effect from a plugin), so `guard-bash` returns these as `ask` decisions, which Claude Code honours in auto mode. To have them as ordinary permission rules as well, add to your own `settings.json`: `"permissions": {"ask": ["Bash(gh pr merge *)", "Bash(gh release *)", "Bash(git tag *)", "Bash(git push *)"]}` (the last prompts for every push; the hook asks only for the default branch).

What it cannot catch, because it reads command text and not intent:

- a command built at run time (`$(...)` or a variable that expands to `--no-verify`, `eval "$cmd"` of a variable, `xargs git push`), or run from a script file, an alias or a git alias
- `gh api` calls that merge, release or tag (`gh api -X PUT repos/o/r/pulls/1/merge`), another client or the web UI, and pushing a tag by a bare name (`git push origin v1.0`)
- skipping hooks by other means: deleting or `chmod -x` a hook file, `HUSKY=0`, or `git -C <dir>` / `cd` into a repository whose default branch differs from the one `origin/HEAD` names in the session's directory
- `pipefail` set in a way the command text does not show (for example a profile), and `head`/`tail` hidden behind another program (`| less`, `| sed -n 1,20p`, `| awk`)
- a push with no refspec uses the current branch of the session's directory, which a preceding `cd` or `git checkout` in the same command can change

State, ledger and digests live in the project's `.factory/` (kept out of `git status` through `.git/info/exclude`). Optional `.factory/settings.json` keys: `builder_cap`, `disk_reserve_gb`, `temp_min_gb`, `default_worktree_gb` (spawn gate); `check_command`; `build_jobs` (parallel jobs in the lean build rule, default 2), `commit_trailer` (replaces the generic trailer rule) and `build_output_max_mb` (a builder cannot finish above it, default 500), read by the `factory-rules` hook, which adds the project's rules to every starting subagent, and the stop check that enforces the last; `priority_labels` (ordered, highest first); `factory_assignee` (a login whose assignment still counts as free); `roles` (a role's `model` or `effort` over its agent definition in `plugins/factory/agents/`) and `deep_when` (when a ticket goes to `implementer-deep`).

Status: being built. See the open spec issue, [`GLOSSARY.md`](GLOSSARY.md) and [`docs/adr/`](docs/adr/).

Licensed under Apache 2.0.
