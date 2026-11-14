# Glossary

## The factory

**Factory**:
A Claude Code plugin that turns one interactive session into the manager of a project's agent-driven development: it takes planned work, runs agents on it in parallel, and reports how it is going.
_Avoid_: pipeline, swarm

**Factory manager**:
The session running the factory. It assigns, prioritizes, starts, steers and stops agents, and reports; it asks the user before any outward step.
_Avoid_: orchestrator (for the session), controller

**Outward step**:
An action other people can see or that changes shared settings: merging to the default branch, a release or tag, publishing, a new public issue or comment, a repository setting, or spending past the budget. The factory manager asks before each one.

## Work

**Spec**:
A planned piece of work recorded as one issue, written by the user with `/to-spec`.

**Ticket**:
A vertical slice of a spec, recorded as an issue with the spec as its parent and its blockers as native dependencies, written by the user with `/to-tickets`.
_Avoid_: task, job

**Standalone ticket**:
A ticket with no spec: an issue ready for an agent with no parent and no sub-issues that is not marked as a spec, such as a bug or a small task. It is built and merged like any ticket, into its own integration branch `ticket/<n>-<slug>`, with its own pull request.

**Frontier**:
The tickets labelled ready for an agent whose blockers are all closed: what can start now.

**Integration branch**:
The branch a spec's tickets are merged into before the spec's single pull request to the default branch (`spec/<n>-<slug>`); for a standalone ticket, its own branch `ticket/<n>-<slug>`.

**Gate**:
The checks a ticket's work must pass before it is merged into the integration branch: the project's check command and the review of the ticket.

## Agents

**Builder**:
An agent that changes and compiles code in its own git worktree. Builders are limited by the spawn gate.
_Avoid_: worker

**Read-only agent**:
An agent that reads and reports without building, such as a reviewer or a researcher. Not limited by disk.

**Role**:
What an agent is started for (implementer, deep implementer, merger, standards reviewer, spec reviewer, watcher). Each role is an agent definition in the plugin, which carries its model, effort, tools and isolation.

**Escalation**:
Running a ticket again one tier up in model or effort after its agent failed the gate twice or stalled.

**Stall**:
An agent or worktree with no commits, output or tool use for longer than the configured time.

## Guard rails and records

**Spawn gate**:
The rule, enforced by a hook, that starts a builder only when free disk, free temporary space and the number of running builders allow it.

**Ledger**:
The append-only record of every agent run and factory event in a project: role, model, effort, tokens, duration, outcome. KPIs are computed from it.
_Avoid_: log (for this record)

**Digest**:
The full progress and KPI report the factory manager writes every hour while work runs. Kept in the project, not committed.

**Spec report**:
The full report written when a spec completes, committed in that spec's pull request.
