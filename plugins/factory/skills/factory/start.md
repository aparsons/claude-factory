# /factory start

## 1. Prerequisites

Run `factory-prereqs`. If it exits non-zero, show its list and stop: the factory does not run half-configured. Otherwise keep its check command for the briefs, and run `factory-state running on`.

## 2. Frontier

Run `factory-frontier --json`, then show the user its text form (`factory-frontier`) once.

- `alerts` with `default-branch-red`: say so first, with the failing workflow and run URL. A fix lands on the default branch, which is an outward step: ask whether to investigate it with a read-only agent; continue with the frontier meanwhile.
- `needs_tickets`: list them as "needs /to-tickets". Do not write tickets.
- If the user names a ticket or spec to go first, take it next, whatever its rank.

## 3. Integration branches

For each spec with a ready ticket, run `factory-integration ensure --spec <spec> --branch <spec_branch>` (the ticket's `spec_branch`). It creates and pushes the branch from the default branch when absent, and keeps a dedicated worktree for merges; it never switches the user's checkout.

## 4. Start implementers

For each `ready` ticket in rank order, start one implementer with the Agent tool:

- `description`: `implement #<ticket>: <title>` (the `#<ticket>` lets the ledger attribute the run)
- `subagent_type`: `general-purpose` (role agents arrive with ticket #6)
- `isolation`: `worktree`; `run_in_background`: true
- `model` and `effort`: the ticket's `model` and `effort`
- `prompt`: the implementer brief from `${CLAUDE_PLUGIN_ROOT}/skills/factory/briefs.md`, filled in

If the spawn gate blocks the start, stop starting builders; show its reason in one line. Remove a worktree it lists as safe only if the factory created it (otherwise ask). Start the next builder when one finishes. The gate counts the main checkout's and the integration worktrees' build output too and lists it with sizes; it may offer cleaning the main checkout's build output: pass that offer to the user, and clean it only on their yes. A worktree whose ticket's latest gate passed and whose agent has finished is `awaiting merge`: it counts toward disk but not the cap, and the reason lists it apart from the running builders; a later gate failure (sent back) makes it running again.

After each successful start, record it: `factory-state assign --ticket <n> --spec <s> --role <role> --model <model> --effort <effort> --branch <branch>`, then `factory-state update --ticket <n> --agent <agentId>`.

## 5. When an implementer reports

- Check passed: `factory-state gate --ticket <n> --result pass --tests-added <k>` and `factory-state update --ticket <n> --worktree <path it reported>`. Then the decision review (`${CLAUDE_PLUGIN_ROOT}/skills/factory/review.md`): its findings send the ticket back as a gate failure instead of merging; no findings, or the review turned off in settings, go on without asking. Start the merge yourself, no agent: run `factory-integration merge --ticket <n> --branch <branch> --worktree <path> --title "<title>"` with the Bash tool, `run_in_background` true, and carry on; you are woken when it ends (step 6). A merge costs no model tokens, so waiting for the project's pre-push check on it costs nothing. Start each merge as soon as its ticket passes, even while another merge into the same integration branch runs: `factory-integration merge` takes its turn on its own, in the order started, and merges into different branches run in parallel. Never add a wait, a `pgrep` or a `sleep` loop, or a hand-made lock to a merge or its start. The merger role stays in `roles.json` for a project whose merges need judgement; none does today.
- Check failed, or no evidence it passed: `factory-state gate --ticket <n> --result fail`, and send it back once with SendMessage, naming what failed. A second failure: `factory-state unassign --ticket <n> --reason "gate failed twice"`, tell the user, keep its worktree. (Escalation comes with ticket #6.)
- Stopped without a report, or the report says it could not finish: unassign with the reason and tell the user.

## 6. When a merge ends

When the background merge ends, read its output (the JSON on stdout) and its exit code: 0 merged, 3 conflict, 4 diverged or push-failed; any other exit code or no JSON is a failed command: show its stderr and ask the user. The tool has already appended a `merge` ledger event with the result and the duration (queueing included), which `factory-kpis` reports as merge time; record nothing yourself. `waited_seconds` appears when it queued behind another merge; ignore it unless the wait looks long. Then, by the JSON's `result`:

- `merged`: one line, `#<n> merged into <branch>`, with the draft pull request's URL when `pull_request.created` is true (`draft PR #<number> opened: <url>`). The tool already recorded the merge, removed the worktree and the ticket branch (locally and on origin), and opened the spec's draft pull request or added the ticket to it. Believe `worktree_removed` and `branch_deleted`: when either is false, say why in one line from `cleanup_note` (usually `worktree_lock.state` is `running`: the agent has not finished). The tool unlocks a worktree whose agent finished or whose process is gone and never breaks a running agent's lock, so do not unlock or remove anything by hand. If `pull_request` is null, say so with `pull_request_error` in one line; the next merge retries it. The pull request stays a draft: marking it ready or merging it is an outward step. Then, unless the project has no CI, start `factory-integration ci --ticket <n>` as a background Bash command (`run_in_background` true) and carry on; see "When CI ends".
- `conflict`: nothing was pushed and the ticket's worktree is kept. Ask the ticket's implementer (SendMessage) to merge `origin/<spec_branch>`, resolve, rerun the check and report again; then run the merge again, the same way. If it is gone, unassign the ticket with the reason and tell the user.
- `push-failed`: the pre-push check failed on the merged result. Record `factory-state gate --ticket <n> --result fail` and send the output to the implementer as above.
- `diverged`: someone else moved the integration branch. Stop that spec and ask the user.

## When CI ends

A merge counts as done only when CI on the merged commit is green. `factory-integration ci --ticket <n>` waits (polling, no model tokens) for the checks of the spec's pull request on the merged commit and ends with the result; you are woken when it does. Read its JSON and exit code, then by `result`:

- `green` (exit 0): one line, `#<n> CI green (<duration_s>s)`. The tool recorded a `ci` ledger event with the result and the duration; record nothing yourself. `none` (exit 0): no checks ran for the commit; say so in one line.
- `failed` (exit 3): the tool already recorded a gate failure against the ticket (the job's name, its URL and the failed lines) and sent it back through `factory-state rework`. Say one line (`#<n> CI failed: <job>, sent back`), start an implementer for it as in "Rework of a merged ticket" with the `failures` entries that are not `preexisting` (job, URL, lines) in its brief, then continue at step 5. `rework` false with a `rework_note` means the ticket was already back with an implementer: do not start another.
- `red-on-default` (exit 4): every failing job also fails on the default branch, so the ticket did not cause it and nothing was sent back. Report the jobs and URLs to the user in a few lines and ask what to do; this is not rework.
- `infra` (exit 5): a job failed with no failing step or the run was cancelled. Re-run it once (`gh run rerun <run> --failed`, the `run` of the failure) and run `factory-integration ci` again; if it comes back `infra` a second time, tell the user.
- `timeout` (exit 6): the checks did not finish in time; tell the user in one line and run it again when they say so.

Any other exit code or no JSON is a failed command: show its stderr and ask the user.

## Rework of a merged ticket

When something found after a ticket merged needs a follow-up fix to that same ticket (CI on the integration branch or the pull request fails because of it, or the user sends it back), do not assign it by hand: `factory-state rework --ticket <n> --reason "<what failed>"`. It moves the merged ticket back into the assignments (role, model and effort of its first assignment; `--role`, `--model`, `--effort` and `--branch` override them), keeps the earlier merge, and records a gate failure and a `rework` event, so the ticket stops counting as first-try and its rework shows in the KPIs. Start an implementer for it as in step 4 (brief: the failure and the earlier merge commit, `git log -1` of the ticket's `merged` record), then continue at step 5: a pass is merged as usual, and the ticket's merged record gains the new commit and keeps the old. A fix that is a new piece of work, not a correction of that ticket, is a new ticket instead.

## 7. Continue

Whenever an agent finishes (its completion notice arrives), run `factory-integration cleanup`: it retries the clean-up of every merged ticket whose worktree or branch was left because a lock was still held, and leaves a running agent's alone. Say one line for each ticket it finishes cleaning.

After every merge, recompute the frontier (`factory-frontier --json`) and go back to step 3 for newly ready tickets.

When a spec's status is `complete`: run `factory-state integration --spec <s> --branch <branch> --status complete` and say "Spec #<s>: all tickets merged into <branch>." Start nothing more for it; spec review comes with ticket #9, which reuses the draft pull request the first merge opened rather than opening another.

When nothing is ready and nothing is running, go idle: say in a few lines what waits on the user (specs needing `/to-tickets`, blocked specs and why, failures left for them) and stop working until they reply.
