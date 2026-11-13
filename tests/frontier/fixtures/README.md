# factory-frontier fixtures

Recorded `gh` output, read with `factory-frontier --from <dir>` so the suite runs offline.

- `recorded/issues.json`: a real recording from aparsons/claude-factory on 2026-11-12:
  `gh issue list --state open --label ready-for-agent --limit 1000 --json number,title,state,createdAt,labels,milestone,assignees,parent,blockedBy,blocking,subIssues,subIssuesSummary`
  (spec #1 with tickets #2 to #14 and their native blockers).
- `graph/issues.json`: the same shape, written for the ranking cases: spec #10 with tickets
  #11 to #21 (blocked chains, security, priority label, milestones, another assignee, a
  blocker count larger than the listed nodes), spec #30 without tickets, spec #40 whose only
  ticket is not labelled for agents, spec #50 with one open ticket (#51).
- `graph/repo.json`: `gh repo view --json defaultBranchRef`.
- Run lists for the default-branch cases are written by the suite in the shape of
  `gh run list --json workflowName,status,conclusion,url,createdAt`.

The field shapes (`blockedBy`/`blocking`/`subIssues` as `{nodes, totalCount}`, `parent` as a node
or null) are those printed by gh 2.103; see `gh issue list --help` for the JSON fields.
