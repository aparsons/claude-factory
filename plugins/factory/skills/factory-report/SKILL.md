---
name: factory-report
description: Write the factory's digest, the KPI table and a short progress summary, to .factory/digests/. Use when the factory manager needs a progress report or the hourly digest.
context: fork
agent: general-purpose
model: haiku
effort: low
background: false
allowed-tools: Bash(factory-kpis:*) Bash(mkdir:*) Bash(date:*) Bash(git log:*) Bash(gh run list:*) Bash(gh issue list:*)
---

Write a factory digest for the project in the current directory. Do not edit anything except the digest file.

1. Run `date -u +%Y-%m-%d-%H%M` for the file stamp and `date -u +%Y-%m-%dT%H:%M:%SZ` for the heading time.
2. Gather the optional inputs. Skip one that fails; its KPIs will print as n/a.
   - `git log --merges --format='%cI%x09%s' > "$tmp/merges.txt"` (use a file under `${TMPDIR:-/tmp}` and remove it afterwards)
   - `gh run list --limit 30 --json conclusion,status,startedAt,updatedAt > "$tmp/runs.json"`
3. Run `factory-kpis` (if it is not on PATH, `${CLAUDE_PLUGIN_ROOT}/bin/factory-kpis`) with `--git-log "$tmp/merges.txt" --runs "$tmp/runs.json"` for the inputs you have. It reads `.factory/ledger.jsonl` and `.factory/usage.json` itself. Do not change its numbers.
4. Create `.factory/digests/` and write `.factory/digests/<stamp>.md` containing:
   - the heading `# Factory digest, <time>`;
   - a progress summary of at most six lines, using only what the table and the ledger show (tickets merged, agents running, each escalation from the table's Escalations section with its ticket and reason, stalls, cost range, plan usage). Say "not recorded" for anything n/a; never estimate or fill a gap;
   - the full KPI table exactly as `factory-kpis` printed it.
5. Print the path of the digest and nothing else.
