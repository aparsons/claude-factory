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

State, ledger and digests live in the project's `.factory/` (kept out of `git status` through `.git/info/exclude`). Optional `.factory/settings.json` keys: `builder_cap`, `disk_reserve_gb`, `temp_min_gb`, `default_worktree_gb` (spawn gate); `check_command`; `merge_stall_minutes` (default 60: a ticket whose gate passed but that has not merged for longer shows as merge-stalled and counts in the Stalls KPI); `priority_labels` (ordered, highest first); `factory_assignee` (a login whose assignment still counts as free); `roles` and `deep_when` (over `plugins/factory/data/roles.json`).

Status: being built. See the open spec issue, [`GLOSSARY.md`](GLOSSARY.md) and [`docs/adr/`](docs/adr/).

Licensed under Apache 2.0.
