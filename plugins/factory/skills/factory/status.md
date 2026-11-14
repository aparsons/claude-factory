# /factory status

Run these and show their output compactly, in this order, with one heading each:

1. `factory-frontier`: alerts, ready tickets in rank order, running, blocked, specs (including those needing `/to-tickets`).
2. `factory-state list`: running agents with role, model, effort, age and status. A `merge-stalled` status means the ticket passed its gate but has not merged for longer than `merge_stall_minutes`: say so with its age and look at its merger and the merge queue (`factory-integration merge` takes turns on its own; never add a wait). Also flag any whose agent you know has finished but is still listed.
3. Blocked specs: from `factory-frontier --json`, each spec with status `blocked`, and why (its tickets' `blocked_by`, or tickets not labelled for agents in `not_for_agents`).
4. `factory-kpis`: the KPI table, as printed.

Then one line: whether the manager is running (`factory-state show`, `.running`). Change nothing.
