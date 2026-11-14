#!/usr/bin/env bash
# shellcheck disable=SC2015 # `test && check || fail` is the assertion form
# Suite: `factory-integration ci` after a merge. The spec's pull request runs CI on the merged
# commit; the manager waits for it in the background. Green is recorded (a `ci` ledger event with the
# result and the duration); a failure the ticket caused sends it back through `factory-state rework`
# with the job, its URL and the failed lines; a failure already present on the default branch is
# reported, not sent back. gh is faked (tests/merge-ci/bin/gh, first on PATH); this suite never
# reaches GitHub.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
fi_="$root/plugins/factory/bin/factory-integration"
st="$root/plugins/factory/bin/factory-state"
kpis="$root/plugins/factory/bin/factory-kpis"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/merge-ci-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass=0
fail() { echo "FAIL: $*"; exit 1; }
ok() { pass=$((pass + 1)); }

export FAKE_GH_DIR="$tmp/gh"
export PATH="$root/tests/merge-ci/bin:$PATH"
[ "$(command -v gh)" = "$root/tests/merge-ci/bin/gh" ] || fail "the fake gh is not first on PATH: $(command -v gh)"; ok
export FACTORY_CI_POLL=0.05 FACTORY_CI_GRACE=1

sha=1111111111111111111111111111111111111111
ib=spec/3-parser

# project: a fresh project with ticket 12 merged into spec 3's integration branch at $sha
project() {
  rm -rf "$tmp/proj" "$FAKE_GH_DIR"
  mkdir -p "$FAKE_GH_DIR"
  git init -q -b main "$tmp/proj"
  export CLAUDE_PROJECT_DIR="$tmp/proj"
  "$st" integration --spec 3 --branch "$ib"
  "$st" assign --ticket 12 --spec 3 --role implementer --model sonnet --effort high --branch t12-parse
  "$st" merge --ticket 12 --commit "$sha"
}
# run <id> <workflow> <branch> <commit> <status> <conclusion> <started> <updated>: adds a workflow run
runs=""
run() {
  runs=$(jq -c --argjson id "$1" --arg w "$2" --arg b "$3" --arg c "$4" --arg s "$5" --arg k "$6" --arg a "$7" --arg u "$8" \
    '. + [{databaseId: $id, workflowName: $w, headBranch: $b, headSha: $c, status: $s,
           conclusion: (if $k == "" then null else $k end), attempt: 1, url: "https://github.com/o/r/actions/runs/\($id)",
           createdAt: $a, startedAt: $a, updatedAt: $u}]' <<<"${runs:-[]}")
  printf '%s\n' "$runs" >"$FAKE_GH_DIR/runs.json"
}
# jobs <id> <name:conclusion:failed step>...: the jobs of a run
jobs() {
  local id=$1 out="[]" spec n c s; shift
  for spec in "$@"; do
    IFS=: read -r n c s <<<"$spec"
    out=$(jq -c --arg n "$n" --arg c "$c" --arg s "$s" --arg id "$id" \
      '. + [{name: $n, conclusion: $c, url: "https://github.com/o/r/actions/runs/\($id)/job/\($n | length)",
             steps: ([{name: "Set up job", conclusion: "success"}] + (if $s == "" then [] else [{name: $s, conclusion: "failure"}] end))}]' <<<"$out")
  done
  jq -n --argjson j "$out" '{jobs: $j}' >"$FAKE_GH_DIR/jobs-$id.json"
}
ledger="$tmp/proj/.factory/ledger.jsonl"
last_event() { jq -c --arg e "$1" 'select(.event == $e)' "$ledger" | tail -n 1; }
count_events() { jq -c --arg e "$1" 'select(.event == $e)' "$ledger" 2>/dev/null | wc -l; }
ci() { code=0; out=$("$fi_" ci --ticket 12 --timeout 5 "$@" 2>"$tmp/err") || code=$?; }

# --- all checks green: one result, one ledger event with the duration ---
project
runs=""
run 201 CI "$ib" "$sha" completed success 2026-01-01T10:00:00Z 2026-01-01T10:05:00Z
run 202 Lint "$ib" "$sha" completed skipped 2026-01-01T10:00:00Z 2026-01-01T10:01:00Z
run 203 CI "$ib" 2222222222222222222222222222222222222222 completed failure 2026-01-01T09:00:00Z 2026-01-01T09:05:00Z
ci
[ "$code" = 0 ] && jq -e '.result == "green" and .ticket == 12 and .branch == "spec/3-parser" and .commit == "'"$sha"'" and .rework == false' <<<"$out" >/dev/null || fail "green ($code): $out $(cat "$tmp/err")"; ok
last_event ci | jq -e '.ticket == 12 and .spec == 3 and .commit == "'"$sha"'" and .result == "green" and .duration_s == 300' >/dev/null || fail "green ci event: $(last_event ci)"; ok
[ "$(count_events rework)" = 0 ] && ! jq -e 'select(.event == "gate")' "$ledger" >/dev/null 2>&1 || fail "green sends nothing back"; ok
"$st" show | jq -e '(.assignments | has("12") | not) and (.merged | has("12"))' >/dev/null || fail "green leaves the ticket merged"; ok
grep -q 'run list --branch spec/3-parser --commit '"$sha" "$FAKE_GH_DIR/calls.log" || fail "checks of the merged commit on the integration branch were read"; ok

# --- the manager waits for checks that are still running ---
project
runs=""
run 201 CI "$ib" "$sha" completed success 2026-01-01T10:00:00Z 2026-01-01T10:05:00Z
export FAKE_GH_PENDING_POLLS=3
ci
unset FAKE_GH_PENDING_POLLS
[ "$code" = 0 ] && jq -e '.result == "green"' <<<"$out" >/dev/null || fail "waited green ($code): $out $(cat "$tmp/err")"; ok
[ "$(wc -l <"$FAKE_GH_DIR/polls")" -ge 4 ] || fail "polled until the checks finished: $(wc -l <"$FAKE_GH_DIR/polls") polls"; ok

# --- checks that never finish within the timeout ---
project
runs=""
run 201 CI "$ib" "$sha" in_progress "" 2026-01-01T10:00:00Z 2026-01-01T10:00:00Z
code=0; out=$("$fi_" ci --ticket 12 --timeout 1 2>"$tmp/err") || code=$?
[ "$code" = 6 ] && jq -e '.result == "timeout" and .rework == false' <<<"$out" >/dev/null || fail "timeout ($code): $out"; ok
last_event ci | jq -e '.result == "timeout"' >/dev/null || fail "timeout recorded"; ok
[ "$(count_events rework)" = 0 ] || fail "a timeout sends nothing back"; ok

# --- no checks start for the commit: not a failure ---
project
runs=""
run 203 CI "$ib" 2222222222222222222222222222222222222222 completed failure 2026-01-01T09:00:00Z 2026-01-01T09:05:00Z
ci
[ "$code" = 0 ] && jq -e '.result == "none" and .rework == false' <<<"$out" >/dev/null || fail "no checks ($code): $out"; ok
last_event ci | jq -e '.result == "none"' >/dev/null || fail "no checks recorded"; ok

# --- a failure the ticket caused: recorded as a gate failure and sent back through rework ---
project
runs=""
run 301 CI "$ib" "$sha" completed failure 2026-01-01T10:00:00Z 2026-01-01T10:07:00Z
run 302 CI main 3333333333333333333333333333333333333333 completed success 2026-01-01T08:00:00Z 2026-01-01T08:05:00Z
jobs 301 "test (ubuntu):failure:Run tests" "lint:success:"
cat >"$FAKE_GH_DIR/log-301.txt" <<'LOG'
test (ubuntu)	Run tests	2026-01-01T10:06:00.0000000Z running 3 tests
test (ubuntu)	Run tests	2026-01-01T10:06:01.0000000Z test parser::reads_header ... ok
test (ubuntu)	Run tests	2026-01-01T10:06:02.0000000Z test parser::reads_body ... FAILED
test (ubuntu)	Run tests	2026-01-01T10:06:03.0000000Z thread 'parser::reads_body' panicked at src/parser.rs:42: assertion failed: body.len() == 3
test (ubuntu)	Run tests	2026-01-01T10:06:04.0000000Z error: test failed, to rerun pass `--lib`
LOG
ci
[ "$code" = 3 ] || fail "ticket failure exit ($code): $out $(cat "$tmp/err")"; ok
jq -e '.result == "failed" and .rework == true and (.failures | length) == 1' <<<"$out" >/dev/null || fail "ticket failure result: $out"; ok
jq -e '.failures[0] | .job == "test (ubuntu)" and .workflow == "CI" and .preexisting == false and (.url | test("actions/runs/301"))
  and (.lines | any(test("reads_body ... FAILED"))) and (.lines | any(test("assertion failed: body.len\\(\\) == 3"))) and (.lines | any(test("reads_header") | not))' <<<"$out" >/dev/null || fail "failure names the job, URL and failed lines: $(jq -c .failures <<<"$out")"; ok
gate=$(jq -c 'select(.event == "gate" and .result == "fail")' "$ledger" | tail -n 1)
jq -e '.ticket == 12 and .spec == 3 and (.reason | contains("test (ubuntu)") and contains("actions/runs/301") and contains("reads_body ... FAILED"))' <<<"$gate" >/dev/null || fail "gate fail records job, URL and lines: $gate"; ok
last_event rework | jq -e '.ticket == 12 and (.reason | contains("test (ubuntu)"))' >/dev/null || fail "rework event: $(last_event rework)"; ok
"$st" show | jq -e '.assignments["12"] | .spec == 3 and .branch == "t12-parse" and .role == "implementer"' >/dev/null || fail "ticket assigned again for rework"; ok
last_event ci | jq -e '.result == "failed" and .ticket == 12 and (.duration_s | type == "number")' >/dev/null || fail "failed ci event: $(last_event ci)"; ok
# the same failure again while the rework is under way: reported, not assigned twice
ci
[ "$code" = 3 ] && jq -e '.rework == false and (.rework_note | length > 0)' <<<"$out" >/dev/null || fail "second failure while in rework ($code): $out"; ok
[ "$(count_events rework)" = 1 ] || fail "one rework only"; ok

# --- a failure already present on the default branch: reported to the user, not sent back ---
project
runs=""
run 401 CI "$ib" "$sha" completed failure 2026-01-01T10:00:00Z 2026-01-01T10:07:00Z
run 402 CI main 3333333333333333333333333333333333333333 completed failure 2026-01-01T08:00:00Z 2026-01-01T08:06:00Z
jobs 401 "test (ubuntu):failure:Run tests"
jobs 402 "test (ubuntu):failure:Run tests"
printf 'test (ubuntu)\tRun tests\t2026-01-01T10:06:02Z test flaky::on_main ... FAILED\n' >"$FAKE_GH_DIR/log-401.txt"
ci
[ "$code" = 4 ] || fail "red on default exit ($code): $out $(cat "$tmp/err")"; ok
jq -e '.result == "red-on-default" and .rework == false and (.failures | length) == 1 and .failures[0].preexisting == true and .failures[0].job == "test (ubuntu)"' <<<"$out" >/dev/null || fail "red on default result: $out"; ok
[ "$(count_events rework)" = 0 ] && ! jq -e 'select(.event == "gate")' "$ledger" >/dev/null 2>&1 || fail "red on default: no gate failure, no rework"; ok
"$st" show | jq -e '(.assignments | has("12") | not) and (.merged | has("12"))' >/dev/null || fail "red on default leaves the ticket merged"; ok
last_event ci | jq -e '.result == "red-on-default"' >/dev/null || fail "red on default recorded: $(last_event ci)"; ok

# --- one job red on the default branch too, another new: only the new one sends the ticket back ---
project
runs=""
run 501 CI "$ib" "$sha" completed failure 2026-01-01T10:00:00Z 2026-01-01T10:07:00Z
run 502 CI main 3333333333333333333333333333333333333333 completed failure 2026-01-01T08:00:00Z 2026-01-01T08:06:00Z
jobs 501 "test (macos):failure:Run tests" "test (ubuntu):failure:Run tests"
jobs 502 "test (macos):failure:Run tests" "test (ubuntu):success:"
printf 'test (ubuntu)\tRun tests\t2026-01-01T10:06:02Z test parser::reads_body ... FAILED\ntest (macos)\tRun tests\t2026-01-01T10:06:02Z test os::paths ... FAILED\n' >"$FAKE_GH_DIR/log-501.txt"
ci
[ "$code" = 3 ] && jq -e '.result == "failed" and .rework == true and (.failures | length) == 2' <<<"$out" >/dev/null || fail "mixed failures ($code): $out"; ok
jq -e '([.failures[] | select(.preexisting) | .job] == ["test (macos)"]) and ([.failures[] | select(.preexisting | not) | .job] == ["test (ubuntu)"])' <<<"$out" >/dev/null || fail "mixed failures sorted: $(jq -c .failures <<<"$out")"; ok
last_event rework | jq -e '(.reason | contains("test (ubuntu)") and contains("reads_body") and (contains("test (macos)") | not) and (contains("os::paths") | not))' >/dev/null || fail "rework reason names only the new failure: $(last_event rework)"; ok

# --- an infrastructure failure (a job failed with no failing step): not the ticket's fault ---
project
runs=""
run 601 CI "$ib" "$sha" completed failure 2026-01-01T10:00:00Z 2026-01-01T10:07:00Z
jobs 601 "test (ubuntu):failure:"
ci
[ "$code" = 5 ] && jq -e '.result == "infra" and .rework == false and .failures[0].kind == "infra" and .failures[0].run == 601' <<<"$out" >/dev/null || fail "infra failure ($code): $out"; ok
[ "$(count_events rework)" = 0 ] || fail "infra failure sends nothing back"; ok
last_event ci | jq -e '.result == "infra"' >/dev/null || fail "infra recorded"; ok

# --- a re-run of the same workflow is the latest run: its result counts ---
project
runs=""
run 701 CI "$ib" "$sha" completed failure 2026-01-01T10:00:00Z 2026-01-01T10:07:00Z
run 702 CI "$ib" "$sha" completed success 2026-01-01T10:20:00Z 2026-01-01T10:26:00Z
ci
[ "$code" = 0 ] && jq -e '.result == "green"' <<<"$out" >/dev/null || fail "latest run of a workflow counts ($code): $out"; ok

# --- refusals ---
project
code=0; "$fi_" ci --ticket 99 --timeout 1 2>/dev/null >&2 || code=$?
[ "$code" = 2 ] || fail "ci of an unmerged ticket exits 2, got $code"; ok
code=0; "$fi_" ci 2>/dev/null >&2 || code=$?
[ "$code" = 2 ] || fail "ci without --ticket exits 2, got $code"; ok

# --- the CI pass rate and duration KPIs take their values from the ci events ---
"$st" ci --ticket 12 --result green --duration-s 300 --commit "$sha"
"$st" ci --ticket 12 --result failed --duration-s 500 --commit "$sha"
"$st" ci --ticket 12 --result red-on-default --duration-s 700 --commit "$sha"
"$st" ci --ticket 12 --result infra --duration-s 9000 --commit "$sha"
got=$("$kpis" --json --ledger "$ledger" | jq -c '.quality | [.ci_pass_rate, .ci_median_duration_s]')
[ "$got" = "[0.5,400]" ] || fail "KPIs count green and failed ci events only: $got"; ok

echo "merge-ci suite passed ($pass checks)"
