#!/usr/bin/env bash
# shellcheck disable=SC2015 # `test && check || fail` is the assertion form
# Suite: factory-ci re-runs a CI failure that is an infrastructure error once, and reports a real
# failure with its failing log lines. Run lists, jobs and logs are recorded fixtures served by a
# fake `gh` on PATH (no network).
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
ci="$root/plugins/factory/bin/factory-ci"
fx="$root/tests/ci/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ci-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*"; exit 1; }
ok() { pass=$((pass + 1)); }

# the fake gh: `run list` prints $GH_FX/runs.json, `run view N --json jobs` jobs-N.json,
# `run view N --log-failed` log-N.txt, `run rerun N --failed` records the call
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
case "$1 $2" in
  "run list") cat "$GH_FX/runs.json" ;;
  "run view")
    case "$*" in
      *"--json jobs"*) if [ -f "$GH_FX/jobs-$3.json" ]; then cat "$GH_FX/jobs-$3.json"; else echo '{"jobs":[]}'; fi ;;
      *"--log-failed"*) if [ -f "$GH_FX/log-$3.txt" ]; then cat "$GH_FX/log-$3.txt"; fi ;;
    esac ;;
  "run rerun") exit "${GH_RERUN_EXIT:-0}" ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export CLAUDE_PROJECT_DIR="$tmp/proj" FACTORY_NOW=2026-01-01T11:00:00Z
mkdir -p "$CLAUDE_PROJECT_DIR"
unset CLAUDE_SESSION_ID
export GH_CALLS="$tmp/calls"

# run <scenario> [args...]: sets out (stdout JSON) and rc, and the gh calls made
run() {
  local s=$1; shift
  : >"$GH_CALLS"
  export GH_FX="$fx/$s"
  rc=0
  out=$("$ci" check --branch spec/1-x "$@" 2>"$tmp/err") || rc=$?
}
j() { jq -e "$2" <<<"$out" >/dev/null || fail "$1: $out"; ok; }
reran() { grep -qx "run rerun $1 --failed" "$GH_CALLS"; }
no_rerun() { ! grep -q '^run rerun' "$GH_CALLS"; }

# --- nothing red ---
run green
[ "$rc" = 0 ] || fail "green exits 0: $rc"; ok
j "green: no failing runs" '.runs == []'
no_rerun || fail "green: re-ran"; ok

# --- cancelled: an infrastructure error, re-run once ---
run cancelled
[ "$rc" = 0 ] || fail "cancelled exits 0 (a re-run is not a report): $rc"; ok
j "cancelled: verdict and action" '.runs | length == 1 and .[0].id == 101 and .[0].workflow == "Check" and .[0].verdict == "infra" and .[0].action == "rerun" and .[0].rerun_started == true'
reran 101 || fail "cancelled: gh run rerun 101 --failed not called: $(cat "$GH_CALLS")"; ok
grep -q -- '--branch spec/1-x' "$GH_CALLS" || fail "run list is scoped to the branch"; ok
j "cancelled: reason" '.runs[0].reason | test("cancelled")'

# --- runner lost: the job failed but no step did, and there is no log ---
run runner-lost
[ "$rc" = 0 ] || fail "runner-lost exits 0: $rc"; ok
j "runner lost is infra and re-run" '.runs[0] | .verdict == "infra" and .action == "rerun" and (.reason | test("runner"))'
reran 102 || fail "runner-lost: not re-run"; ok

# --- network error in a failing step's log ---
run network
[ "$rc" = 0 ] || fail "network exits 0: $rc"; ok
j "network is infra and re-run" '.runs[0] | .verdict == "infra" and .action == "rerun" and (.reason | test("Could not resolve host"))'
reran 103 || fail "network: not re-run"; ok

# --- a real failure: reported with its failing log lines, never re-run ---
run real
[ "$rc" = 3 ] || fail "real failure exits 3 (something to report): $rc"; ok
j "real: verdict, action, url" '.runs[0] | .id == 104 and .verdict == "real" and .action == "report" and .url == "https://github.com/o/r/actions/runs/104" and .rerun_started == false'
j "real: failing lines, prefix and timestamp stripped" '.runs[0].log_lines | index("FAILED: tests/state/run.sh") != null and index("FAIL: merge moves the assignment: {\"version\":1}") != null and (map(test("^check\t|^20[0-9][0-9]-")) | any | not)'
j "real: lines that are not failures are left out" '.runs[0].log_lines | index("ok: tests/frontier/run.sh") == null'
no_rerun || fail "real: re-ran"; ok
run real --max-lines 2
j "max-lines keeps the last failing lines" '.runs[0].log_lines | length == 2 and (.[-1] | test("exit code 1"))'

# --- an infrastructure error again after the re-run is reported, not re-run twice ---
run infra-again
[ "$rc" = 3 ] || fail "infra-again exits 3: $rc"; ok
j "second infra failure is reported" '.runs[0] | .verdict == "infra" and .attempt == 2 and .action == "report" and .rerun_started == false and (.reason | test("again"))'
j "second infra failure carries its log lines" '.runs[0].log_lines | length > 0'
no_rerun || fail "infra-again: re-ran a second time"; ok

# --- in progress, and superseded by a newer run ---
run in-progress
[ "$rc" = 0 ] || fail "in-progress exits 0: $rc"; ok
j "a run in progress is pending" '.runs == [] and .pending == 1'
no_rerun || fail "in-progress: re-ran"; ok
run superseded
[ "$rc" = 0 ] || fail "superseded exits 0: $rc"; ok
j "only the latest run of a workflow counts" '.runs == []'
no_rerun || fail "superseded: re-ran"; ok

# --- a timeout is a hang, not infrastructure ---
run timed-out
[ "$rc" = 3 ] || fail "timed-out exits 3: $rc"; ok
j "timed out is real" '.runs[0] | .verdict == "real" and .action == "report" and (.reason | test("timed out"))'
no_rerun || fail "timed-out: re-ran"; ok

# --- two workflows: one re-run, one reported ---
run mixed
[ "$rc" = 3 ] || fail "mixed exits 3: $rc"; ok
j "mixed: Check re-run, Lint reported, Docs ignored" '(.runs | map({(.workflow): .action}) | add) == {Check: "rerun", Lint: "report"}'
reran 109 || fail "mixed: Check not re-run"; ok
! reran 110 || fail "mixed: Lint re-run"; ok

# --- --dry-run decides but starts nothing ---
run network --dry-run
j "dry run: the action is rerun, nothing started" '.runs[0] | .action == "rerun" and .rerun_started == false'
no_rerun || fail "dry run: re-ran"; ok

# --- a re-run gh refuses is reported ---
GH_RERUN_EXIT=1 run cancelled
[ "$rc" = 3 ] || fail "a refused re-run exits 3: $rc"; ok
j "refused re-run is reported" '.runs[0] | .action == "report" and .rerun_started == false and (.reason | test("re-run failed"))'

# --- the ledger records each decision ---
ledger="$CLAUDE_PROJECT_DIR/.factory/ledger.jsonl"
[ -f "$ledger" ] || fail "no ledger written"; ok
jq -e -s 'map(select(.event == "ci_rerun")) | length >= 4 and (.[0] | .ts == "2026-01-01T11:00:00Z" and .run == 101 and .workflow == "Check" and .branch == "spec/1-x" and .verdict == "infra")' "$ledger" >/dev/null || fail "ci_rerun events: $(cat "$ledger")"; ok
jq -e -s 'map(select(.event == "ci_failure" and .run == 104)) | length >= 1 and (.[0] | .verdict == "real" and .workflow == "Check")' "$ledger" >/dev/null || fail "ci_failure event"; ok

# --- usage ---
"$ci" --help >/dev/null || fail "--help"; ok
if "$ci" bogus >/dev/null 2>&1; then fail "unknown command accepted"; fi; ok

echo "ci suite passed ($pass checks)"
