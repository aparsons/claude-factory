# /factory status

Run these and show their output compactly, in this order, with one heading each:

1. `factory-frontier`: alerts, ready tickets in rank order (standalone tickets marked `(standalone)`), running, blocked, specs (including those needing `/to-tickets`).
2. `factory-state list`: running agents with role, model, effort, age and status. A `merge-stalled` status means the ticket passed its gate but has not merged for longer than `merge_stall_minutes`: say so with its age and look at its merge command and the merge queue (`factory-integration merge` takes turns on its own; never add a wait). Also flag any whose agent you know has finished but is still listed.
3. `factory-integration leftovers`: merged tickets whose worktree or branch is still there, and whether a running agent holds the lock. Listing only: the manager retries the clean-up (`factory-integration cleanup`) when an agent finishes.
4. Blocked specs: from `factory-frontier --json`, each spec with status `blocked`, and why (its tickets' `blocked_by`, or tickets not labelled for agents in `not_for_agents`). A ticket with status `spec-blocked` is held only by its spec's link to another spec (`blocked_by_spec` names it): say so in one line; a ticket of a blocked spec that has its own link into the blocking spec, or a spec with no link at all, is not held by it.
5. `factory-budget`: plan usage and spec estimates against the budgets, as printed.
6. `factory-kpis`: the KPI table, as printed. The first-try gate pass rate counts a ticket only if no failed gate was ever recorded for it, and the rework table lists failed gates, review send-backs and escalations per ticket: report them as printed, never as a rounded-up success.

Then one line: whether the manager is running (`factory-state show`, `.running`). Change nothing.
