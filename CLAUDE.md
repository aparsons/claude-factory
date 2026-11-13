## Checks

Run `scripts/check.sh` before every commit; it is the whole CI check job (`claude plugin validate`, shellcheck, every `tests/*/run.sh`). The pre-push hook runs it too (enable once per clone: `git config core.hooksPath .githooks`).

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues on aparsons/claude-factory (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
