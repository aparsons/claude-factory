# /factory stop

1. `factory-state running off`. From now on start no agents, including mergers, until `/factory start`, and schedule no more heartbeats (`factory-rhythm next` returns none while it is not running); a heartbeat already pending finds nothing to do.
2. Show `factory-state list`: the running agents.
3. Ask the user, in one question, whether to let them finish or stop them. For each one they want stopped: stop it (TaskStop), run `factory-state unassign --ticket <n> --reason stopped`, and name its worktree, which is kept (removing it is the user's call).
   Agents left running still report; when one does, record its gate result with `factory-state gate` but do not start a merger until `/factory start`.
4. Write a digest: call the Skill tool with `factory:factory-report`. Show the path it prints, and record it: `factory-rhythm digested --path <path>`.
