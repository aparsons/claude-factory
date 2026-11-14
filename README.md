# claude-factory

A Claude Code plugin that turns your session into the manager of an agent-driven software factory. You plan the work with `/to-spec` and `/to-tickets`; the factory runs agents on every ready ticket in parallel git worktrees, with a model and effort chosen for each task, enforces its rules with hooks, records every run in a ledger, and reports progress and KPIs.

## Install

```
/plugin marketplace add aparsons/claude-factory
/plugin install factory@claude-factory
```

It installs at user level and does nothing in a project until you run `/factory start` there. The plugin works with only bash, git, `gh` and `jq` (a Raspberry Pi is enough).

## Prerequisites

- Claude Code, `git`, `jq`, and `gh` (2.94 or newer for sub-issues and blocked-by), authenticated (`gh auth login`).
- A project that follows the mattpocock-skills conventions: specs and tickets as GitHub issues (a ticket is a sub-issue of its spec, blockers are native dependencies), the `ready-for-agent` label, `docs/agents/issue-tracker.md` and `docs/agents/triage-labels.md`, and a check command named in `CLAUDE.md` (for example "Run `scripts/check.sh` before every commit") or `check_command` in `.factory/settings.json`.
- An `origin` remote on GitHub. The skills `tdd`, `code-review` and `pr` from mattpocock-skills are used by the agents.

`/factory start` runs `factory-prereqs` and lists anything missing instead of running half-configured. You keep writing specs and tickets yourself with `/to-spec` and `/to-tickets`.

## Use

In a project that follows the mattpocock-skills issue conventions (specs and tickets as issues, the triage labels, a check command named in `CLAUDE.md`):

- `/factory start`: checks prerequisites, then runs an implementer per ready ticket in rank order, each in its own worktree on the spec's integration branch `spec/<n>-<slug>`, and merges each finished ticket there itself, as a background command that costs no model tokens (merges into one integration branch run one at a time, in order, and each is recorded in the ledger with its duration, so merge time appears in the KPIs); the merge removes the ticket's worktree and branch (locally and on origin) even though Claude Code still holds a lock on the worktree, once the agent has finished, and never touches a running agent's. After a spec's first merge it opens one draft pull request from the integration branch, so CI runs there from the start, and adds each later ticket to it. A merged ticket that needs a follow-up fix goes back through `factory-state rework --ticket N --reason TEXT`: its earlier merge stays in the state and ledger, a gate failure and a `rework` event are recorded (so it is no longer a first-try ticket), and the next merge adds the new commit to its merged record. Before each merge, a read-only `decision-reviewer` on a small model checks the ticket's diff against the project's ADRs and the ticket's acceptance criteria and reports only conflicts with a named ADR (quoting the decision line) or unmet criteria; findings send the ticket back to its implementer and are recorded as a gate failure (rework), a clean review goes on to the merge without asking, and `"decision_review": false` in `.factory/settings.json` turns it off. A merge counts as done only when CI on the merged commit is green: the manager then waits in the background (`factory-integration ci`, no model tokens) for the draft pull request's checks on that commit and records a `ci` ledger event with the result and duration (the CI pass rate and duration KPIs); a failure the ticket caused is recorded as a gate failure with the job's name, URL and failed lines and the ticket goes back through `rework` with that failure in its builder's brief, while a failure that is already red on the default branch is reported to you instead of sent back. It never marks that pull request ready, merges to the default branch, tags, publishes or comments without asking.
- `/factory status`: frontier, running agents, leftover worktrees and branches of merged tickets, blocked specs, KPIs.
- `/factory stop`: no new agents; offers to stop running ones; writes a digest.

While running, the manager keeps working between your messages: agent and CI completions wake it, and a heartbeat of 20 to 30 minutes (a dynamic loop wake-up, never short polling) covers the rest. It posts one line per event (ticket merged, agent stalled or escalated, CI red, budget threshold), writes a digest to `.factory/digests/` every 60 minutes while work runs, sends a push notification only when it needs you, and with an empty queue goes idle and lists what waits on you. `factory-rhythm` decides each of these; settings `report_interval_min`, `heartbeat_minutes` (default `[20, 30]`), `budget_five_hour_pct` and `budget_seven_day_pct`.

A spec is an issue with sub-issues (its tickets), or a parent-less issue marked as a spec (a `Spec:` or `PRD:` title, a `spec` label, or a `## User Stories` heading as `/to-spec` writes); a spec without sub-issues is reported as needing `/to-tickets`. Any other ready issue with no parent and no sub-issues, such as a bug or a small task, is a **standalone ticket**: ready when its native blockers are closed and ranked with the spec tickets by the same rules. Having no spec, it integrates into its own branch `ticket/<n>-<slug>`, made from the default branch: its implementer works from there, the manager merges it there, and it gets its own draft pull request (one ticket, one pull request). Merging that pull request to the default branch is an outward step the factory asks about, as for a spec.

A ticket's own blocking links decide when it is ready; a spec blocked by another spec holds a ticket only when the ticket has no link of its own to the blocking spec's work (the spec or one of its tickets), so linking a ticket to just the tickets it needs lets it start early without editing the tracker, and the frontier lists a ticket held only by its spec's link as `spec-blocked`, naming the spec.

The KPIs are honest about rework. A ticket counts as first-try only if no failed gate was ever recorded for it: a failure recorded after a pass (a decision-review or CI send-back) supersedes the pass, and both stay in the ledger, which is never rewritten. The table lists rework per ticket (failed gates, review send-backs, escalations), so you can see which tickets were hard.

The spawn gate counts the build output (untracked and git-ignored directories such as `target/`) of the main checkout and of every integration worktree, not only the ticket worktrees, when it decides whether there is room for another builder. Its block message lists each with its size and, when no process is running inside the main checkout's build directory, offers to clean it. The factory never deletes the main checkout's build output without your yes. A ticket whose check passed and whose agent has finished (`awaiting merge`) counts toward disk but not toward the builder cap.

## Guard rails

`guard-bash` runs before every Bash call, in every session and subagent. It reads the command the way a shell splits it (quotes, `$(...)`, heredocs, comments, `;` `&&` `||` `|` `&`), so a look-alike such as `tail -n 100 build.log` or a commit message that mentions `--no-verify` passes.

Blocked, with a reason the agent can act on:

- `--no-verify`, and `git commit -n`
- a `core.hooksPath` override (`git -c core.hooksPath=...`, `GIT_CONFIG_KEY_n=core.hooksPath`, `git config core.hooksPath <elsewhere>`); a relative path in the repository's own config, as in `git config core.hooksPath .githooks`, is allowed
- a force-push (`--force`, `-f`, `--force-with-lease`, `+ref`, `--mirror`) or delete of the default branch (`main`, `master` and whatever `origin/HEAD` names)
- a check, test, build or push piped into `head` or `tail` without `pipefail` (the pipe's status is `tail`'s, so a failure looks like success); the project's check command from `CLAUDE.md` counts as a check

Asked, so Claude Code prompts you even in auto mode: `gh pr merge`, `gh release` (except `list`, `view`, `download`), `git tag` (except listing), a push to the default branch, `git push --tags` or a tag ref. A Claude Code plugin cannot ship `permissions.ask` in its own settings (only `agent` and `subagentStatusLine` take effect from a plugin), so `guard-bash` returns these as `ask` decisions, which Claude Code honours in auto mode. To have them as ordinary permission rules as well, add to your own `settings.json`: `"permissions": {"ask": ["Bash(gh pr merge *)", "Bash(gh release *)", "Bash(git tag *)", "Bash(git push *)"]}` (the last prompts for every push; the hook asks only for the default branch).

What it cannot catch, because it reads command text and not intent:

- a command built at run time (`$(...)` or a variable that expands to `--no-verify`, `eval "$cmd"` of a variable, `xargs git push`), or run from a script file, an alias or a git alias
- `gh api` calls that merge, release or tag (`gh api -X PUT repos/o/r/pulls/1/merge`), another client or the web UI, and pushing a tag by a bare name (`git push origin v1.0`)
- skipping hooks by other means: deleting or `chmod -x` a hook file, `HUSKY=0`, or `git -C <dir>` / `cd` into a repository whose default branch differs from the one `origin/HEAD` names in the session's directory
- `pipefail` set in a way the command text does not show (for example a profile), and `head`/`tail` hidden behind another program (`| less`, `| sed -n 1,20p`, `| awk`)
- a push with no refspec uses the current branch of the session's directory, which a preceding `cd` or `git checkout` in the same command can change

## Monitor

`factory-watch` is a plugin monitor that starts when `/factory` is invoked. It prints one line, which wakes the manager, each time a condition starts, and nothing while it lasts (a condition that clears and returns prints again): free disk below the reserve (`disk_reserve_gb`, 5 GB), free temporary space below `temp_min_gb` (1 GB), a CI run in progress for more than three times the median of its workflow's successful runs (at least three of them; polled through `gh` every `ci_poll_seconds`, 300), a builder worktree with no commit, change or reflog entry for `stall_minutes` (30), and a clean worktree that is merged (or empty) and idle for `merged_grace_minutes` (15) but not removed. A worktree on a branch with a running assignment in `state.json` counts only as stalled, never as unremoved. It is silent while the factory is stopped.

State, ledger and digests live in the project's `.factory/` (kept out of `git status` through `.git/info/exclude`). Optional `.factory/settings.json` keys: `builder_cap`, `disk_reserve_gb`, `temp_min_gb`, `default_worktree_gb` (spawn gate); `check_command`; `merge_stall_minutes` (default 60: a ticket whose gate passed but that has not merged for longer shows as merge-stalled and counts in the Stalls KPI); `build_jobs` (parallel jobs in the lean build rule, default 2), `commit_trailer` (replaces the generic trailer rule) and `build_output_max_mb` (a builder cannot finish above it, default 500), read by the `factory-rules` hook, which adds the project's rules to every starting subagent, and the stop check that enforces the last; `priority_labels` (ordered, highest first); `stall_minutes`, `merged_grace_minutes`, `ci_poll_seconds` (the monitor, below); `factory_assignee` (a login whose assignment still counts as free); `decision_review` (`false` skips the decision review before merges); `roles` (a role's `model` or `effort` over its agent definition in `plugins/factory/agents/`) and `deep_when` (when a ticket goes to `implementer-deep`).

Budgets: install the status line command beside your own so the factory can read your plan usage, in `~/.claude/settings.json` (the factory never edits your settings): `"statusLine": {"type": "command", "command": "factory-statusline --then ~/.claude/my-statusline.sh"}`, or just `factory-statusline` when you have none (use its path under the plugin's `bin/` if it is not on `PATH`). It records the 5-hour and 7-day usage and reset times in `.factory/usage.json` of any project where the factory runs. Then no new builders start above 80% of the 5-hour window until it resets (the `spawn-gate` hook), the manager asks before continuing above 85% of the 7-day window, and it reports and asks when a spec's estimated cost passes 1.5 times its first estimate. Settings keys: `budget_five_hour_pct`, `budget_seven_day_pct`, `budget_spec_ratio`. `factory-budget` shows where you stand.

Restarts and CI: the factory's state lives in the project's `.factory/`, so `/factory start` in a new session resumes it. `factory-resume` plans each saved assignment (its agent is gone): record a merge that was pushed but not recorded, or start a builder again on the existing branch, salvaging uncommitted work first, keeping any escalation. A ticket that already has an assignment is never assigned a second time, so agents are not duplicated. Worktrees nothing owns are listed, never removed without asking. `factory-ci check` looks at the latest CI run of each workflow on a branch: a failure that is an infrastructure error (runner lost, a network or service error in the log, cancelled, did not start) is re-run once with `gh run rerun --failed`; a real failure, a timeout, or an infrastructure error again after the re-run is reported with its failing log lines.

## Limits

- GitHub only, and only projects that use the mattpocock-skills issue conventions. No headless or scheduled runs: the factory works while a session is open.
- It never merges to the default branch, tags, releases or publishes on its own: those are outward steps it asks about. `guard-bash` cannot catch everything (see above); the `ask` rules are a second line, not a sandbox.
- Cost is a low-to-high estimate at list prices; plan usage is known only if the status line command is installed. A spec estimate is a guess until a ticket has a cost.
- One escalation per ticket; a ticket that fails after it is handed back to you. Builders run at most `builder_cap` (3) at a time, and none while disk or temporary space is low.
- Merge conflicts are never resolved by the merger: the ticket's implementer resolves them, or you are asked.

## Release dry run

Before each release, the maintainer proves the whole loop on a throwaway repository. `scripts/sandbox.sh` makes it repeatable:

```
scripts/sandbox.sh create                      # private repo factory-sandbox-<date>: two specs, six tickets, an ADR
cd <the clone it names>; claude                # plugin installed; run /factory start, answer its questions, do not approve a merge
scripts/sandbox.sh verify --dir <the clone> --spec 1 --early-spec 5   # checks what the run left behind (the numbers `create` printed)
scripts/sandbox.sh destroy --repo <owner>/<name> --yes
```

The sandbox is built to exercise the second version of the loop. Spec #1 (a greeter) has three tickets in a chain; its first ticket tempts a one-line `echo` against ADR 0001 (scripts print with `printf`), so the decision review sends it back once. Spec #5 (a farewell) is blocked by spec #1 as a whole, but its tickets #6 and #7 are each linked only to ticket #2, so they start as soon as #2 merges, side by side, and their two merges into one integration branch must queue; ticket #8 has no link of its own, so the spec-level link holds it for the whole run (`spec-blocked` in the frontier). The seeded pre-push hook pauses `SANDBOX_PUSH_DELAY` seconds (default 45) so the two merges overlap. Claude Code holds a lock on every agent worktree at merge time, so each merge must clean up through it.

`create --dry-run` prints the plan and calls nothing. `verify` checks that tickets were taken in frontier order, worktrees were used and removed, every ticket of spec #1 was merged into its integration branch, the ledger and the spec report were written, one draft pull request closes the spec and its tickets, and nothing reached the default branch; and the second loop: a ticket was sent back after its check passed and then passed again, with the first-try rate below 100% and the send-back counted as rework in `factory-kpis`; #6 and #7 were assigned after #2 merged and before spec #1 was done, and both merged into spec #5's integration branch, the second having waited for the first (`waited_s` on its `merge` event); #8 was never started; and no ticket worktree, ticket branch (here or on origin) or merge lock was left behind. What the script cannot see, you confirm in the session: that the manager asked before merging, wrote no wait (`sleep`, `pgrep` or a lock loop) of its own around a merge, and that the review's finding named ADR 0001 and quoted its line. `verify` fails when the send-back or the overlap did not happen; run the dry run again then (a larger `SANDBOX_PUSH_DELAY` makes the overlap likelier). `tests/sandbox/run.sh` tests the script against a fake `gh` and local remotes only (it runs in `scripts/check.sh`); the live run is not part of CI.

Licensed under Apache 2.0.
