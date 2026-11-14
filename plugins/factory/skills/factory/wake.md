# Waking and the reporting rhythm

While `factory-state show` has `running: true`, keep working between the user's messages. Never short-poll: do not sleep in a loop, and do not check an agent or a CI run on a timer shorter than the heartbeat. You are woken by:

- an agent's completion (a background agent reports back);
- a CI completion (a `watcher` waiting on a run, in the background, reports back);
- a `factory-watch` monitor line (low disk or temporary space, a CI run past three times its median, a stalled or unremoved worktree), when the monitor is running;
- the heartbeat, the dynamic loop wake-up described below;
- the user's message.

## On every wake

1. Handle what woke you (an agent's report, a CI result, a monitor line) as in `start.md` steps 5 to 8.
2. Run `factory-rhythm next`. It is the only source for what follows; do not estimate.
3. Say each event in one line with `factory-rhythm note <kind> ... --text "<detail>"` and show its `line`. Kinds: `merged` (ticket merged into its integration branch), `stalled` and `escalated` (an agent stalled or was escalated), `ci-red`, `budget` (a threshold in `budget` was crossed; say it once per window), `question`, `budget-stop`. These are the only notes. No narration between events.
4. Act on `budget`, which `factory-rhythm next` takes from `factory-budget` (the thresholds are its settings; `start.md` step 4 says what to do for each finding): `no-new-builders` on the 5-hour window means start no builders until it resets (running ones finish; `factory-rhythm note budget`); `ask` (the 7-day window, or a spec past its estimate ratio) means ask the user, in one question, before continuing, and `factory-rhythm note question`.
5. If `digest_due`: call the Skill tool with `factory:factory-report`, then `factory-rhythm digested --path <the path it printed>`. Show the path in one line. The digest is a file in `.factory/digests/`; it is not pasted into the session.
6. Schedule the next wake-up (below), unless `heartbeat_seconds` is null.

## Heartbeat

The heartbeat catches what does not notify. Schedule it as the session's dynamic loop wake-up (`ScheduleWakeup`, as `/loop` does with no interval), with `delaySeconds` set to the `heartbeat_seconds` that `factory-rhythm next` printed (20 to 30 minutes; it is shortened to land on the digest, never below 20 minutes) and a prompt that says to run the wake routine in `wake.md`. Schedule exactly one: if one is already pending, leave it. A wake caused by an event still schedules the next heartbeat from the fresh `next`.

`start.md` step 1 starts the rhythm (the first `factory-rhythm next` and heartbeat); `stop.md` ends it (schedule nothing more).

## The digest, every 60 minutes while work runs

`factory-rhythm next` says `digest_due` once a full report interval (default 60 minutes, `report_interval_min`) has passed since the last digest, or since the first assignment when there is none, and only while an agent runs or a ticket is ready. Idle gaps produce no digests.

## Push notifications

Send a push notification (the `PushNotification` tool) only when a note has `notify: true`: a question that blocks work, a stall you cannot fix (`factory-rhythm note stalled ... --needs-user`), or a budget stop. Everything else, including every merge, escalation that was handled, red CI that you are re-running, and every digest and heartbeat, stays in the session as one line. Never push to say that work is progressing.

## Idle

When `idle` is true (running, nothing active, nothing ready), the queue is empty: schedule no heartbeat and start no work. Say, in a few lines, what `waiting_on_user` lists: specs needing `/to-tickets`, blocked specs and the tickets that need a human, tickets stopped after failing twice or stalling, and a red default branch. If it is empty, say that nothing is waiting. Then stop working until the user replies, a monitor line or an agent report wakes you, or a new ticket appears (a user message such as "check again" runs the frontier). Write the final digest before going quiet if the last one is older than the work since.
