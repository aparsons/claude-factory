# Finishing a spec: review, fix, draft pull request, report

Runs for a spec (or a standalone ticket) whose status is `complete`: every ticket is merged into its integration branch `<branch>`. Do the steps in order; one line per event.

## 1. Review

Start the two reviewers at once, read-only, in the background, one Agent call each, with the briefs in `${CLAUDE_PLUGIN_ROOT}/skills/factory/briefs.md` ("Reviewer"):

- `description`: `review spec #<spec>: standards` and `review spec #<spec>: spec` (the `#<spec>` lets the ledger attribute the run)
- `subagent_type`: `factory:standards-reviewer` and `factory:spec-reviewer` (their model, effort and read-only tools are in their definitions; pass no `model` or `effort`)
- no `isolation`: a reviewer reads the integration worktree (`factory-state show`, `.integration["<spec>"].worktree`) and never edits

Each runs `code-review` on the branch's diff against the default branch, with its own focus (standards and docs; the spec's user stories, ticket acceptance criteria and security), and reports a numbered findings list with file and line, or "no findings". Reviewers do not push, comment on the tracker or edit files.

Reviewers are not builders: the spawn gate lets them through when disk is low.

When both report, record each: `factory-state review --spec <spec> --role <role> --findings <k>`. The count is the number of findings you accept after reading them; drop duplicates and anything that is not a defect or a missed requirement, and say why in one line.

## 2. Fix

No findings: go to step 3. Otherwise start **one** builder (`subagent_type` `factory:implementer`; `factory:implementer-deep` when a finding is security) with the "Fixer" brief: the accepted findings, numbered, in its worktree based on `<branch>`. Record it as the brief says (`factory-state assign` under the spec's number), and start it as in start.md step 5 (`isolation` `worktree`, the spawn gate applies). It follows the implementer's rules (test first, check passes, clean build output) and reports like an implementer.

When it reports a passing check, run the merge yourself as for any ticket (`factory-integration merge --ticket <spec number> --branch <the fixer's branch> ...`, as a background command) and read its JSON as in start.md step 7. Review once only: do not start a second review round; list findings left unfixed in the lessons.

## 3. Spec report

1. Write the lessons to a file under `${TMPDIR:-/tmp}`: what went well and badly in this spec, from the ledger and what you saw (escalations, stalls, conflicts, findings), in at most ten lines. Say nothing the ledger and your session do not show.
2. In the integration worktree: `factory-spec-report write --spec <spec> --branch <branch> --issue <issue.json> --worktree <integration worktree> --lessons <lessons file> --git-log <merges.txt> --runs <runs.json> --commit`. Gather `<merges.txt>` and `<runs.json>` as `factory-report` does; `<issue.json>` is `gh issue view <spec> --json number,title,state,subIssues`.
3. Push the branch: `git -C <integration worktree> push origin <branch>` (the pre-push hook runs the check; wait for it; never skip it). Pushing an integration branch is not an outward step.

## 4. Draft pull request

1. Run `factory-spec-report closes --spec <spec> --issue <issue.json>` to get the lines the body must contain.
2. Write the body with the `pr` skill (call the Skill tool with `pr`) for `<branch>` against the default branch. Its body must end with the lines from step 1: one `Closes #<n>` line for the spec and for each ticket. Save it to a file under `${TMPDIR:-/tmp}`.
3. Run `factory-spec-report closes --spec <spec> --issue <issue.json> --body <body file>`. If it exits 1, add the lines it names to the body and run it again.
4. The first merge into the integration branch already opened the spec's draft pull request (`gh pr list --head <branch> --json number,url`): replace its body with `gh pr edit <number> --body-file <body file>`. Only when there is none, open it as a **draft**: `gh pr create --draft --base <default branch> --head <branch> --title "<title>" --body-file <body file>`. Never without `--draft`.
5. Check the pull request's CI as `start.md` step 9 says (`factory-ci check --branch <branch>`) before asking: an infrastructure failure is re-run once, a real one is reported with its log lines.
6. `factory-state integration --spec <spec> --branch <branch> --status complete` if not already recorded. Say: "Spec #<spec>: draft pull request <url>, report docs/factory/reports/<slug>.md."

## 5. Ask

Ask the user, in one question, whether to mark the pull request ready and merge it, with the pull request URL and the report's headline numbers (tickets merged, escalations, findings fixed, cost range). Marking it ready and merging are outward steps: do neither until the user says yes, and then only the step they approved. If they say no or give changes, send them to the right agent; do not argue. Do not ask again until something changed.
