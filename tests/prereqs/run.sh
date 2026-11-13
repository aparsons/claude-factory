#!/usr/bin/env bash
# shellcheck disable=SC2016 # Markdown with backticks is written literally
# Suite: factory-prereqs over temporary projects, with a fake gh on PATH (no live gh).
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
tool="$root/plugins/factory/bin/factory-prereqs"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/prereqs-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*"; exit 1; }

# A fake gh: `gh auth status` exits $FAKE_GH_AUTH (default 0); `gh label list` prints $FAKE_GH_LABELS.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit "${FAKE_GH_AUTH:-0}" ;;
  "label list") printf '%s\n' ${FAKE_GH_LABELS:-ready-for-agent needs-triage} ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# project <dir>: a complete project
project() {
  local p=$1
  mkdir -p "$p/docs/agents" "$p/scripts"
  git init -q -b main "$p"
  git -C "$p" remote add origin https://github.com/o/r.git
  printf '## Checks\n\nRun `scripts/check.sh` before every commit. Hooks: `git config core.hooksPath .githooks`.\n' >"$p/CLAUDE.md"
  printf '#!/bin/sh\n' >"$p/scripts/check.sh"
  echo "# Issue tracker" >"$p/docs/agents/issue-tracker.md"
  printf '| a | b | c |\n| --- | --- | --- |\n| `ready-for-agent` | `ready-for-agent` | Ready |\n' >"$p/docs/agents/triage-labels.md"
}
# prereqs <dir> [ENV=V...]: sets $code and $out (JSON)
prereqs() {
  local p=$1; shift
  code=0
  out=$(env "$@" "$tool" --json --project "$p") || code=$?
}
check() { # check <name> <want code> <jq filter>
  [ "$code" = "$2" ] || fail "$1: exit $code, wanted $2: $out"
  jq -e "$3" <<<"$out" >/dev/null || fail "$1: $out"
  pass=$((pass + 1))
}
missing() { printf '(.missing | map(.check) | sort == (%s | sort))' "$1"; }

project "$tmp/ok"
prereqs "$tmp/ok"
check "complete project passes" 0 '.ok and .missing == [] and .check_command == "scripts/check.sh" and .ready_label == "ready-for-agent"'

project "$tmp/cargo"
printf 'Tests: run `cargo test --workspace` before pushing.\n' >"$tmp/cargo/CLAUDE.md"
prereqs "$tmp/cargo"
check "command-word check command" 0 '.check_command == "cargo test --workspace"'

project "$tmp/nocheck"
printf '# Notes\n\nSee `GLOSSARY.md` for the checks vocabulary.\n' >"$tmp/nocheck/CLAUDE.md"
prereqs "$tmp/nocheck"
check "no check command named" 1 "$(missing '["check-command"]') and .check_command == null"

project "$tmp/override"
printf '# Notes\n' >"$tmp/override/CLAUDE.md"
mkdir -p "$tmp/override/.factory"; echo '{"check_command": "make check"}' >"$tmp/override/.factory/settings.json"
prereqs "$tmp/override"
check "settings check_command" 0 '.check_command == "make check"'

project "$tmp/gone"
rm "$tmp/gone/scripts/check.sh"
prereqs "$tmp/gone"
check "named check script missing" 1 "$(missing '["check-command"]')"

project "$tmp/noclaude"
rm "$tmp/noclaude/CLAUDE.md"
prereqs "$tmp/noclaude"
check "no CLAUDE.md" 1 "$(missing '["claude-md"]')"

project "$tmp/nodocs"
rm -r "$tmp/nodocs/docs"
prereqs "$tmp/nodocs"
check "no tracker or label docs" 1 "$(missing '["issue-tracker-doc", "triage-labels-doc"]')"

project "$tmp/nolabel"
prereqs "$tmp/nolabel" FAKE_GH_LABELS="bug needs-triage"
check "label missing in the repository" 1 "$(missing '["ready-label"]')"

project "$tmp/custom"
printf '| a | b | c |\n| --- | --- | --- |\n| `ready-for-agent` | `agent-ready` | Ready |\n' >"$tmp/custom/docs/agents/triage-labels.md"
prereqs "$tmp/custom" FAKE_GH_LABELS="agent-ready"
check "custom label name from triage-labels.md" 0 '.ready_label == "agent-ready"'

project "$tmp/noauth"
prereqs "$tmp/noauth" FAKE_GH_AUTH=1
check "gh not authenticated" 1 "$(missing '["gh-auth"]')"

project "$tmp/noremote"
git -C "$tmp/noremote" remote remove origin
prereqs "$tmp/noremote"
check "no origin remote" 1 "$(missing '["git-remote"]')"

mkdir -p "$tmp/bare"
prereqs "$tmp/bare" FAKE_GH_AUTH=1
check "empty directory lists everything" 1 "$(missing '["git-repo", "claude-md", "issue-tracker-doc", "triage-labels-doc", "gh-auth"]')"

# text output lists what is missing with the fix
code=0; txt=$("$tool" --project "$tmp/nodocs") || code=$?
[ "$code" = 1 ] && [[ "$txt" == *"docs/agents/issue-tracker.md is missing"* && "$txt" == *"fix: run /setup-matt-pocock-skills"* ]] ||
  fail "text output: $txt"
pass=$((pass + 1))

echo "prereqs suite passed ($pass checks)"
