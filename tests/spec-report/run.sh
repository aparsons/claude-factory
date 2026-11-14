#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # `test && check || fail` is the assertion form; single quotes hold literal $
# Suite: factory-spec-report writes a spec's report into docs/factory/reports/ (progress, KPIs,
# cost, escalations, review findings, lessons) and lists the issues its pull request must close.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/../../plugins/factory/bin/factory-spec-report"
st="$here/../../plugins/factory/bin/factory-state"
fx="$here/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spec-report-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export FACTORY_KPIS_FREE_ROOT_KB=10485760 FACTORY_KPIS_FREE_TMP_KB=2097152
export FACTORY_NOW=2026-02-02T09:00:00Z
pass=0
fail() { echo "FAIL: $*"; exit 1; }
ok() { pass=$((pass + 1)); }

p="$tmp/proj"
mkdir -p "$p/.factory"
git init -q -b main "$p"
cp "$fx/ledger.jsonl" "$p/.factory/ledger.jsonl"
cp "$fx/state.json" "$p/.factory/state.json"
export CLAUDE_PROJECT_DIR="$p"

# the integration worktree: a checkout on the spec's branch
git -C "$p" commit -q --allow-empty -m base
wt="$tmp/wt"
git -C "$p" worktree add -q -b spec/3-parser "$wt"

# --- write ---
out=$("$tool" write --spec 3 --branch spec/3-parser --issue "$fx/issue.json" --worktree "$wt" --lessons "$fx/lessons.md")
report="$wt/docs/factory/reports/3-parser.md"
[ "$out" = "$report" ] && [ -f "$report" ] || fail "write prints the report path under docs/factory/reports/<branch slug>.md: $out"; ok
grep -q '^# Spec report: #3 Spec: The parser' "$report" || fail "heading"; ok
grep -q 'Tickets merged: 2 of 3' "$report" || fail "progress count"; ok
grep -qE '^\| #4 \| Lexer \| merged \| abc1234 \|' "$report" || fail "merged ticket row"; ok
if grep -q 'fix9999' "$report"; then fail "the review fixer's merge (keyed by the spec's number) is not a ticket"; fi; ok
grep -qE '^\| #6 \| Error messages \| running \|' "$report" || fail "running ticket row"; ok
grep -q 'Escalations' "$report" && grep -q 'implementer to implementer-deep' "$report" && grep -q 'gate failed twice' "$report" || fail "escalation of the spec's ticket"; ok
# the spec's own section (the project KPI table further down lists every escalation)
section=$(awk '/^## Escalations/ {on = 1; next} /^## / {on = 0} on' "$report")
grep -q '#5' <<<"$section" && ! grep -q 'other spec' <<<"$section" || fail "another spec's escalation leaked in"; ok
grep -qE '^\| standards-reviewer \| 2 \|' "$report" && grep -qE '^\| spec-reviewer \| 1 \|' "$report" || fail "review findings of this spec"; ok
if grep -qE '^\| spec-reviewer \| 9 \|' "$report"; then fail "another spec's review leaked in"; fi; ok
grep -q 'First estimate: \$4.00' "$report" && grep -q 'Current estimate: \$6.50' "$report" || fail "estimates"; ok
grep -qE 'Estimated cost \(low to high\): \$[0-9]+\.[0-9]{2} to \$[0-9]+\.[0-9]{2}' "$report" || fail "spec cost range"; ok
grep -qE '^\| #4 \| 1 \| \$' "$report" || fail "cost per ticket row"; ok
grep -q '## Lessons' "$report" && grep -q 'needed the deep implementer' "$report" || fail "lessons"; ok
grep -q '^## Factory KPIs' "$report" && grep -q '^### Flow' "$report" && grep -q 'First-try gate pass rate' "$report" || fail "full KPI table, headings demoted"; ok
if grep -q '^# Factory KPIs' "$report"; then fail "KPI heading not demoted"; fi; ok
grep -q 'Free disk on /' "$report" && grep -q '10 GB' "$report" || fail "health in the KPI table"; ok
[ -z "$(git -C "$wt" log --oneline -- docs 2>/dev/null)" ] || fail "write alone commits nothing"; ok

# unknown numbers print as not recorded, not as invented values
out=$(CLAUDE_PROJECT_DIR="$tmp/empty-proj" "$tool" write --spec 3 --branch spec/3-parser --issue "$fx/issue.json" --worktree "$tmp/wt2")
grep -q 'Tickets merged: 0 of 3' "$out" && grep -q 'Escalations: none' "$out" && grep -q 'Lessons: none recorded' "$out" || fail "empty project report"; ok
grep -q 'Estimated cost (low to high): n/a' "$out" || fail "no ledger: cost is n/a"; ok

# --- commit ---
"$tool" write --spec 3 --branch spec/3-parser --issue "$fx/issue.json" --worktree "$wt" --lessons "$fx/lessons.md" --commit >/dev/null
[ "$(git -C "$wt" log -1 --format=%s)" = "Spec report: #3" ] || fail "commit message"; ok
[ "$(git -C "$wt" show --name-only --format= HEAD)" = "docs/factory/reports/3-parser.md" ] || fail "commit holds only the report"; ok
[ -z "$(git -C "$wt" status --porcelain)" ] || fail "tree clean after commit"; ok
"$tool" write --spec 3 --branch spec/3-parser --issue "$fx/issue.json" --worktree "$wt" --lessons "$fx/lessons.md" --commit >/dev/null
[ "$(git -C "$wt" rev-list --count main..HEAD)" = 1 ] || fail "rewriting the same report makes no empty commit"; ok

# --- closes ---
got=$("$tool" closes --spec 3 --issue "$fx/issue.json")
[ "$got" = "$(printf 'Closes #3\nCloses #4\nCloses #5\nCloses #6')" ] || fail "closes lists the spec and every ticket: $got"; ok
got=$("$tool" closes --spec 9 --issue "$fx/standalone.json")
[ "$got" = "Closes #9" ] || fail "a standalone ticket closes itself: $got"; ok

printf 'Summary.\n\nCloses #3\nCloses #4\nfixes #5\n' >"$tmp/body-short.md"
if msg=$("$tool" closes --spec 3 --issue "$fx/issue.json" --body "$tmp/body-short.md" 2>&1); then fail "body missing #6 passed"; fi
grep -q '#6' <<<"$msg" && ! grep -q '#4' <<<"$msg" || fail "names only what is missing: $msg"; ok
printf 'Summary.\n\nCloses #3, closes #4\nResolves #5\nCloses #6\n' >"$tmp/body-full.md"
"$tool" closes --spec 3 --issue "$fx/issue.json" --body "$tmp/body-full.md" >/dev/null || fail "complete body rejected"; ok
printf 'This is not closes #3 but "Closes" #4\n' >"$tmp/body-prose.md"
if "$tool" closes --spec 3 --issue "$fx/issue.json" --body "$tmp/body-prose.md" >/dev/null 2>&1; then fail "prose mentioning issues passed"; fi; ok

if "$tool" write --spec x --branch b 2>/dev/null; then fail "non-numeric spec accepted"; fi; ok
if "$tool" bogus 2>/dev/null; then fail "unknown command accepted"; fi; ok

# --- factory-state review ---
"$st" review --spec 3 --role spec-reviewer --findings 4
jq -e -s 'last | .event == "review" and .spec == 3 and .role == "spec-reviewer" and .findings == 4 and .ticket == null' "$p/.factory/ledger.jsonl" >/dev/null || fail "factory-state review writes a review event"; ok
if "$st" review --spec 3 --findings x 2>/dev/null; then fail "review accepted a non-numeric count"; fi; ok

echo "spec-report suite passed ($pass checks)"
