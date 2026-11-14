# Decision review

After a ticket's check passes and before its merge, a short read-only review catches work that passes its check but contradicts a decision the project made. It is part of the gate, and a project can turn it off.

## 1. Plan

Run `factory-review plan --ticket <n> --worktree <path> --base origin/<spec_branch>`.

- `enabled` false (the project set `"decision_review": false` in `.factory/settings.json`, for a project without ADRs): skip the review. Go straight to the merge, without asking.
- Otherwise note its `adrs`, `changed_files` and `diff_command`. An empty `adrs` still gets reviewed: the ticket's acceptance criteria are checked.

## 2. Review

Start the reviewer with the Agent tool: `subagent_type` `factory:decision-reviewer` (read-only, small model; its model and effort come from its definition), `description` `decision review #<ticket>: <title>`, `run_in_background` true, and the decision-reviewer brief from `${CLAUDE_PLUGIN_ROOT}/skills/factory/briefs.md`, filled in. It is not a builder: the spawn gate does not limit it. Carry on; you are woken when it finishes.

## 3. Act on its report

- **No findings** (the report says "no findings"): proceed to the merge without asking the user. Say nothing more than the merge line.
- **Findings**: each quotes a decision line of a named ADR it conflicts with, or an acceptance criterion left unmet. Do not merge. Record it as a gate failure: `factory-state gate --ticket <n> --result fail`. It is a gate event with result `fail`, so the ticket stops counting as first-try and its rework shows in the KPIs, the same as a failed check. Send the findings, verbatim, to the ticket's implementer with SendMessage ("review found these conflicts; fix them, rerun the check and report again"), then handle its next report as in `start.md` step 6, which runs the review again on the new diff. The second gate failure of a ticket (a failed check or a send-back) follows the failed-twice rule of step 6.
- **The reviewer fails, or reports something that is not a list of findings or "no findings"**: do not guess. Say so in one line and ask the user whether to merge without the review.

The user may overrule a finding: if they say so, merge. Never overrule one yourself.
