# /factory start

## 1. Prerequisites

Run `factory-prereqs`. If it exits non-zero, show its list and stop: the factory does not run half-configured. Otherwise keep its check command for the briefs, and run `factory-state running on`.

## 2. Frontier

Run `factory-frontier --json`, then show the user its text form (`factory-frontier`) once.

- `alerts` with `default-branch-red`: say so first, with the failing workflow and run URL. A fix lands on the default branch, which is an outward step: ask whether to investigate it with a read-only agent; continue with the frontier meanwhile.
- `needs_tickets`: list them as "needs /to-tickets". Do not write tickets.
- A ticket with `standalone: true` is an issue with no parent and no sub-issues (a bug or small task). It is a ticket like any other; its `spec` is its own number and its `spec_branch` is its own integration branch `ticket/<n>-<slug>`. Every step below applies to it unchanged, with that number as the spec.
- If the user names a ticket or spec to go first, take it next, whatever its rank.

## 3. Integration branches

For each spec with a ready ticket, and each ready standalone ticket, run `factory-integration ensure --spec <spec> --branch <spec_branch>` (the ticket's `spec` and `spec_branch`). It creates and pushes the branch from the default branch when absent, and keeps a dedicated worktree for merges; it never switches the user's checkout.

## 4. Start implementers

For each `ready` ticket in rank order, start one implementer with the Agent tool:

- `description`: `implement #<ticket>: <title>` (the `#<ticket>` lets the ledger attribute the run)
- `subagent_type`: `general-purpose` (role agents arrive with ticket #6)
- `isolation`: `worktree`; `run_in_background`: true
- `model` and `effort`: the ticket's `model` and `effort`
- `prompt`: the implementer brief from `${CLAUDE_PLUGIN_ROOT}/skills/factory/briefs.md`, filled in

If the spawn gate blocks the start, stop starting builders; show its reason in one line. Remove a worktree it lists as safe only if the factory created it (otherwise ask). Start the next builder when one finishes.

After each successful start, record it: `factory-state assign --ticket <n> --spec <s> --role <role> --model <model> --effort <effort> --branch <branch>`, then `factory-state update --ticket <n> --agent <agentId>`.

## 5. When an implementer reports

- Check passed: `factory-state gate --ticket <n> --result pass --tests-added <k>` and `factory-state update --ticket <n> --worktree <path it reported>`. Start a merger: Agent tool, `description` `merge #<ticket>`, `subagent_type` `general-purpose`, no isolation, `run_in_background` true, `model` and `effort` from the `merger` role in `roles.json`, `prompt` the merger brief.
- Check failed, or no evidence it passed: `factory-state gate --ticket <n> --result fail`, and send it back once with SendMessage, naming what failed. A second failure: `factory-state unassign --ticket <n> --reason "gate failed twice"`, tell the user, keep its worktree. (Escalation comes with ticket #6.)
- Stopped without a report, or the report says it could not finish: unassign with the reason and tell the user.

## 6. When a merger reports

Read the JSON it relays from `factory-integration merge`:

- `merged`: one line, `#<n> merged into <branch>`. The tool already recorded the merge, removed the worktree and the ticket branch.
- `conflict`: nothing was pushed and the ticket's worktree is kept. Ask the ticket's implementer (SendMessage) to merge `origin/<spec_branch>`, resolve, rerun the check and report again; then start a merger again. If it is gone, unassign the ticket with the reason and tell the user.
- `push-failed`: the pre-push check failed on the merged result. Record `factory-state gate --ticket <n> --result fail` and send the output to the implementer as above.
- `diverged`: someone else moved the integration branch. Stop that spec and ask the user.

## 7. Continue

After every merge, recompute the frontier (`factory-frontier --json`) and go back to step 3 for newly ready tickets.

When a spec's status is `complete`: run `factory-state integration --spec <s> --branch <branch> --status complete` and say "Spec #<s>: all tickets merged into <branch>." (for a `standalone` entry: "Ticket #<s>: merged into <branch>."). Start no more tickets for it; follow `${CLAUDE_PLUGIN_ROOT}/skills/factory/finish.md` (review, one fixer, spec report, draft pull request, then ask). A standalone ticket goes through the same steps: its draft pull request is from `ticket/<n>-<slug>` to the default branch and closes that one issue. Marking a pull request ready and merging it are outward steps.

When nothing is ready and nothing is running, go idle: say in a few lines what waits on the user (specs needing `/to-tickets`, blocked specs and why, failures left for them) and stop working until they reply.
