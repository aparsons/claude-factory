#!/usr/bin/env bash
# Suite: a ticket whose gate passed but that has not merged shows as merge-stalled in
# `factory-state list` and in the Stalls KPI; a later fail or a merge clears it. Fixture
# ledgers: merged, stalled, failed. Regenerate goldens after an intended change:
#   UPDATE_GOLDEN=1 tests/merge-stalled/run.sh
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../../plugins/factory/bin"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/merge-stalled-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export FACTORY_NOW=2026-11-13T11:00:00Z FACTORY_KPIS_FREE_ROOT_KB=10485760 FACTORY_KPIS_FREE_TMP_KB=2097152
unset CLAUDE_SESSION_ID
count=0 fail=0

# project <case> [settings JSON]: a project directory holding the case's .factory files
project() {
  local p; p=$(mktemp -d "$tmp/$1.XXXXXX")
  mkdir -p "$p/.factory"
  cp "$here/fixtures/$1/state.json" "$here/fixtures/$1/ledger.jsonl" "$p/.factory/"
  [ -z "${2:-}" ] || printf '%s\n' "$2" >"$p/.factory/settings.json"
  printf '%s\n' "$p"
}

# golden <name> <file>: compares a produced file with golden/<name>
golden() {
  count=$((count + 1))
  if [ "${UPDATE_GOLDEN:-}" = 1 ]; then cp "$2" "$here/golden/$1"
  elif ! diff -u "$here/golden/$1" "$2"; then echo "FAIL: $1 differs from golden"; fail=1; fi
}

# flagged <project>: the tickets `factory-state list` flags as merge-stalled
flagged() { CLAUDE_PROJECT_DIR=$1 "$bin/factory-state" list --json | jq -c '[.[] | select(.status == "merge-stalled") | .ticket]'; }
# stalls <project>: the Stalls KPI
stalls() { CLAUDE_PROJECT_DIR=$1 "$bin/factory-kpis" --json | jq -c .flow.stalls; }
# expect <what> <got> <want>
expect() {
  count=$((count + 1))
  [ "$2" = "$3" ] || { echo "FAIL: $1: got $2, want $3"; fail=1; }
}

for c in merged stalled failed; do
  p=$(project "$c")
  CLAUDE_PROJECT_DIR=$p "$bin/factory-state" list >"$tmp/$c.list.txt"
  golden "$c.list.txt" "$tmp/$c.list.txt"
  CLAUDE_PROJECT_DIR=$p "$bin/factory-state" list --json >"$tmp/$c.list.json"
  golden "$c.list.json" "$tmp/$c.list.json"
  CLAUDE_PROJECT_DIR=$p "$bin/factory-kpis" >"$tmp/$c.kpis.md"
  golden "$c.kpis.md" "$tmp/$c.kpis.md"
done

# the threshold is a setting: past the stall's age nothing is flagged, below the fresh ticket's age
# both are, and an unusable value falls back to the default of 60
p=$(project stalled '{"merge_stall_minutes": 720}')
expect "merge_stall_minutes 720: flagged" "$(flagged "$p")" "[]"
expect "merge_stall_minutes 720: Stalls KPI (the stall event only)" "$(stalls "$p")" "1"
p=$(project stalled '{"merge_stall_minutes": 10}')
expect "merge_stall_minutes 10: flagged" "$(flagged "$p")" "[12,13]"
expect "merge_stall_minutes 10: Stalls KPI" "$(stalls "$p")" "3"
p=$(project stalled '{"merge_stall_minutes": "soon"}')
expect "unusable merge_stall_minutes: flagged" "$(flagged "$p")" "[12]"

# a merge recorded after the pass clears the flag, and so does unassigning the ticket
p=$(project stalled)
CLAUDE_PROJECT_DIR=$p "$bin/factory-state" merge --ticket 12 --commit abc123 >/dev/null
expect "after a merge: flagged" "$(flagged "$p")" "[]"
expect "after a merge: Stalls KPI" "$(stalls "$p")" "1"
p=$(project stalled)
CLAUDE_PROJECT_DIR=$p "$bin/factory-state" unassign --ticket 12 --reason "dropped" >/dev/null
expect "after an unassign: Stalls KPI" "$(stalls "$p")" "1"

# a pass after a fail flags it again (the latest gate decides)
p=$(project failed)
CLAUDE_PROJECT_DIR=$p "$bin/factory-state" gate --ticket 14 --result pass >/dev/null
expect "fail then a new pass, within the hour: Stalls KPI" "$(FACTORY_NOW=2026-11-13T11:30:00Z stalls "$p")" "0"
expect "fail then a new pass, past the hour: Stalls KPI" "$(FACTORY_NOW=2026-11-13T12:01:00Z stalls "$p")" "1"

[ "$fail" -eq 0 ] || exit 1
echo "merge-stalled suite passed ($count checks)"
