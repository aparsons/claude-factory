# claude-factory

A Claude Code plugin that turns your session into the manager of an agent-driven software factory. You plan the work with `/to-spec` and `/to-tickets`; the factory runs agents on every ready ticket in parallel git worktrees, with a model and effort chosen for each task, enforces its rules with hooks, records every run in a ledger, and reports progress and KPIs.

## Install

```
/plugin marketplace add aparsons/claude-factory
/plugin install factory@claude-factory
```

Status: being specified. See the open spec issue, [`GLOSSARY.md`](GLOSSARY.md) and [`docs/adr/`](docs/adr/).

Licensed under Apache 2.0.
