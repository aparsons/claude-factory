# claude-factory

A Claude Code plugin that turns your session into the manager of an agent-driven software factory. You plan the work with `/to-spec` and `/to-tickets`; the factory runs agents on every ready ticket in parallel git worktrees, with a model and effort chosen for each task, enforces its rules with hooks, records every run in a ledger, and reports progress and KPIs.

## Install

```
/plugin marketplace add aparsons/claude-factory
/plugin install factory@claude-factory
```

## Use

In a project that follows the mattpocock-skills issue conventions (specs and tickets as issues, the triage labels, a check command named in `CLAUDE.md`):

- `/factory start`: checks prerequisites, then runs an implementer per ready ticket in rank order, each in its own worktree on the spec's integration branch `spec/<n>-<slug>`, and merges each finished ticket there itself, as a background command that costs no model tokens (merges into one integration branch run one at a time, in order, and each is recorded in the ledger with its duration, so merge time appears in the KPIs); the merge removes the ticket's worktree and branch (locally and on origin) even though Claude Code still holds a lock on the worktree, once the agent has finished, and never touches a running agent's. After a spec's first merge it opens one draft pull request from the integration branch, so CI runs there from the start, and adds each later ticket to it. A merged ticket that needs a follow-up fix goes back through `factory-state rework --ticket N --reason TEXT`: its earlier merge stays in the state and ledger, a gate failure and a `rework` event are recorded (so it is no longer a first-try ticket), and the next merge adds the new commit to its merged record. Before each merge, a read-only `decision-reviewer` on a small model checks the ticket's diff against the project's ADRs and the ticket's acceptance criteria and reports only conflicts with a named ADR (quoting the decision line) or unmet criteria; findings send the ticket back to its implementer and are recorded as a gate failure (rework), a clean review goes on to the merge without asking, and `"decision_review": false` in `.factory/settings.json` turns it off. A merge counts as done only when CI on the merged commit is green: the manager then waits in the background (`factory-integration ci`, no model tokens) for the draft pull request's checks on that commit and records a `ci` ledger event with the result and duration (the CI pass rate and duration KPIs); a failure the ticket caused is recorded as a gate failure with the job's name, URL and failed lines and the ticket goes back through `rework` with that failure in its builder's brief, while a failure that is already red on the default branch is reported to you instead of sent back. It never marks that pull request ready, merges to the default branch, tags, publishes or comments without asking.
- `/factory status`: frontier, running agents, leftover worktrees and branches of merged tickets, blocked specs, KPIs.
- `/factory stop`: no new agents; offers to stop running ones; writes a digest.

State, ledger and digests live in the project's `.factory/` (kept out of `git status` through `.git/info/exclude`). Optional `.factory/settings.json` keys: `builder_cap`, `disk_reserve_gb`, `temp_min_gb`, `default_worktree_gb` (spawn gate); `check_command`; `priority_labels` (ordered, highest first); `factory_assignee` (a login whose assignment still counts as free); `decision_review` (`false` skips the decision review before merges); `roles` and `deep_when` (over `plugins/factory/data/roles.json`).

Status: being built. See the open spec issue, [`GLOSSARY.md`](GLOSSARY.md) and [`docs/adr/`](docs/adr/).

Licensed under Apache 2.0.
