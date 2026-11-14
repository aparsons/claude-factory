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

A spec is an issue with sub-issues (its tickets), or a parent-less issue marked as a spec (a `Spec:` or `PRD:` title, a `spec` label, or a `## User Stories` heading as `/to-spec` writes); a spec without sub-issues is reported as needing `/to-tickets`. Any other ready issue with no parent and no sub-issues, such as a bug or a small task, is a **standalone ticket**: ready when its native blockers are closed and ranked with the spec tickets by the same rules. Having no spec, it integrates into its own branch `ticket/<n>-<slug>`, made from the default branch: its implementer works from there, the merger merges it there, and it gets its own draft pull request (one ticket, one pull request). Merging that pull request to the default branch is an outward step the factory asks about, as for a spec.

State, ledger and digests live in the project's `.factory/` (kept out of `git status` through `.git/info/exclude`). Optional `.factory/settings.json` keys: `builder_cap`, `disk_reserve_gb`, `temp_min_gb`, `default_worktree_gb` (spawn gate); `check_command`; `priority_labels` (ordered, highest first); `factory_assignee` (a login whose assignment still counts as free); `roles` and `deep_when` (over `plugins/factory/data/roles.json`).

Status: being built. See the open spec issue, [`GLOSSARY.md`](GLOSSARY.md) and [`docs/adr/`](docs/adr/).

Licensed under Apache 2.0.
