# The factory executes what the user plans, and asks before outward steps

## Decision

The factory is a Claude Code plugin, in its own public repository with its own marketplace, installed at user level. It turns the session it runs in into the **factory manager** of the project it is opened in.

- **The user plans; the factory executes.** Specs and tickets are written by the user with `/to-spec` and `/to-tickets`, which only the user can run. The factory takes every ready spec from there: it replaces `/implement-spec` with one continuous loop across the whole backlog. Its agents use the model-invocable skills `tdd`, `code-review` and `pr`.
- **Work comes from the issue tracker.** The queue is the open issues labelled ready for an agent. The frontier is the tickets whose native blockers are all closed. Order: security and a broken default branch first, then the user's priority label or milestone order, then the ticket that unblocks the most others, then the oldest.
- **Autonomy stops at outward steps.** The manager assigns, starts, steers and stops agents, merges tickets into a spec's integration branch, opens draft pull requests, re-runs CI and reports on its own. It asks before merging to the default branch, releasing or tagging, publishing, opening a public issue or comment, changing a setting, or spending past the budget.
- **Rules are hooks, not prose.** Four hooks enforce what briefs used to ask for: `guard-bash` (no skipped hooks, no force-push to the default branch, no check output piped into `tail` or `head`), `factory-rules` (the project's rules injected into every subagent, which does not load the user's memory), `spawn-gate` (disk, temporary space and a builder cap) and `ledger` (every agent run recorded).
- **It runs inside the user's session.** `/factory start` keeps working between the user's messages: agent and CI completions wake it, a 20 to 30 minute heartbeat catches what does not notify, and a monitor flags stalled worktrees. `/factory stop` ends it.

## Why

The decisions that shape a product (what to build, how to split it, what to ship) stay with the user, and the skills that make them are user-invoked. Everything after that is repetitive coordination that a session does well and a person does slowly. The incidents that led here (a full temporary filesystem, a CI job hung for six hours, pushes that skipped the pre-push hook, a disk filled by parallel builds) were all rules written in briefs that nothing enforced; hooks hold even when an agent ignores its brief.

## Considered options

- **Inside each project's repository.** Rejected: the factory is not specific to one project, and copying it would drift.
- **The factory also writes specs and tickets.** Rejected: those are the user's decisions.
- **Wrap `/implement-spec`.** Rejected: it runs one spec per user command and cannot be started by the model.
- **Full autopilot through release.** Rejected: merges to the default branch and releases are seen by others.
- **Headless runs on a timer.** Rejected for now: harder to talk to mid-run; the interactive session is where the user is.

## Consequences

- A spec without tickets waits, reported as needing `/to-tickets`.
- The factory depends on the project naming its check command, release runbook and labels in its own `CLAUDE.md` and docs.
- The hooks bind sessions that have the plugin installed. A merge made outside Claude Code is not gated unless the project requires CI on its default branch.
