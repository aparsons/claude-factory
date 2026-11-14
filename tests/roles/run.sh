#!/usr/bin/env bash
# Suite: the role table lives in the agent definitions; factory-roles reads it and names the
# tier above for an escalation; the frontier and the hooks take roles from the definitions only.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
plugin="$root/plugins/factory"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/roles-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/proj"
export CLAUDE_PROJECT_DIR="$tmp/proj"
pass=0
fail() { echo "FAIL: $*"; exit 1; }
# check <name> <jq filter that must be true> : over $out
check() { jq -e "$2" <<<"$out" >/dev/null || fail "$1: $(jq -c "$2" <<<"$out" 2>&1) in $out"; pass=$((pass + 1)); }
# frontmatter <file> <key>: the value of a top-level key in a definition's frontmatter
frontmatter() { awk -v k="$2" 'NR == 1 { next } /^---$/ { exit } index($0, k ": ") == 1 { print substr($0, length(k) + 3) }' "$1"; }

# --- the six definitions carry the role table (spec #1, user story 17) ---
want='implementer sonnet high worktree
implementer-deep opus high worktree
merger haiku low -
standards-reviewer sonnet medium -
spec-reviewer opus high -
watcher haiku low -'
while read -r role model effort isolation; do
  f="$plugin/agents/$role.md"
  [ -f "$f" ] || fail "no definition $f"
  [ "$(head -n 1 "$f")" = "---" ] || fail "$role: no frontmatter"
  [ "$(frontmatter "$f" name)" = "$role" ] || fail "$role: name is '$(frontmatter "$f" name)'"
  [ -n "$(frontmatter "$f" description)" ] || fail "$role: no description"
  [ "$(frontmatter "$f" model)" = "$model" ] || fail "$role: model is '$(frontmatter "$f" model)', want $model"
  [ "$(frontmatter "$f" effort)" = "$effort" ] || fail "$role: effort is '$(frontmatter "$f" effort)', want $effort"
  got=$(frontmatter "$f" isolation); [ -n "$got" ] || got=-
  [ "$got" = "$isolation" ] || fail "$role: isolation is '$got', want $isolation"
  [ -n "$(awk 'NR > 1 && /^---$/ { found = 1; next } found && NF { print; exit }' "$f")" ] || fail "$role: empty system prompt"
  pass=$((pass + 1))
done <<<"$want"
[ "$(find "$plugin/agents" -name '*.md' | wc -l)" = 6 ] || fail "exactly six definitions: $(ls "$plugin/agents")"
pass=$((pass + 1))

# --- reviewers and the merger and watcher have an allowlist without edit, write or agent tools ---
for role in standards-reviewer spec-reviewer merger watcher; do
  tools=$(frontmatter "$plugin/agents/$role.md" tools)
  [ -n "$tools" ] || fail "$role: no tools allowlist (no list means every tool)"
  for t in Edit Write MultiEdit NotebookEdit Agent Task; do
    [[ ",$(tr -d ' ' <<<"$tools")," != *",$t,"* ]] || fail "$role: tools include $t: $tools"
  done
  pass=$((pass + 1))
done
for role in standards-reviewer spec-reviewer; do
  [[ "$(frontmatter "$plugin/agents/$role.md" tools)" == *Read* ]] || fail "$role cannot read"
  pass=$((pass + 1))
done

# --- the role table lives only in the definitions ---
[ ! -e "$plugin/data/roles.json" ] || fail "data/roles.json still holds a role table"
pass=$((pass + 1))

# --- factory-roles prints the table from the definitions ---
out=$("$plugin/bin/factory-roles" --json)
check "six roles" 'keys == ["implementer", "implementer-deep", "merger", "spec-reviewer", "standards-reviewer", "watcher"]'
check "implementer" '.implementer == {role: "implementer", agent: "factory:implementer", model: "sonnet", effort: "high", isolation: "worktree", builder: true, tools: null}'
check "spec reviewer is read-only" '.["spec-reviewer"] | .agent == "factory:spec-reviewer" and .model == "opus" and .effort == "high" and (.builder | not) and (.tools | index("Edit") == null)'
txt=$("$plugin/bin/factory-roles")
[[ "$txt" == *"implementer-deep"*"opus"*"high"*"worktree"* ]] || fail "text table: $txt"
pass=$((pass + 1))

# --- the tier above: the next definition, else one effort level up ---
out=$("$plugin/bin/factory-roles" next implementer)
check "implementer escalates to implementer-deep" '. == {role: "implementer-deep", agent: "factory:implementer-deep", model: "opus", effort: "high", effort_override: false}'
out=$("$plugin/bin/factory-roles" next implementer-deep)
check "implementer-deep escalates its effort" '. == {role: "implementer-deep", agent: "factory:implementer-deep", model: "opus", effort: "xhigh", effort_override: true}'
out=$("$plugin/bin/factory-roles" next implementer-deep --effort xhigh)
check "from the effort it ran at" '.effort == "max" and .effort_override'
out=$("$plugin/bin/factory-roles" next merger)
check "merger: haiku low to medium" '. == {role: "merger", agent: "factory:merger", model: "haiku", effort: "medium", effort_override: true}'
code=0; "$plugin/bin/factory-roles" next implementer-deep --effort max >/dev/null 2>&1 || code=$?
[ "$code" = 1 ] || fail "no tier above max: exit $code"
pass=$((pass + 1))
code=0; "$plugin/bin/factory-roles" next nobody >/dev/null 2>&1 || code=$?
[ "$code" = 2 ] || fail "unknown role: exit $code"
pass=$((pass + 1))

# --- per-project settings override a role's model or effort ---
mkdir -p "$tmp/proj/.factory"
echo '{"roles": {"implementer": {"model": "opus"}}}' >"$tmp/proj/.factory/settings.json"
out=$("$plugin/bin/factory-roles" --json)
check "settings override the model, keep the effort" '.implementer.model == "opus" and .implementer.effort == "high"'
rm -rf "$tmp/proj/.factory"

# --- a changed definition changes the frontier: it reads nothing else ---
cp -r "$plugin" "$tmp/plugin"
sed -i 's/^model: sonnet$/model: haiku/; s/^effort: high$/effort: medium/' "$tmp/plugin/agents/implementer.md"
out=$("$tmp/plugin/bin/factory-frontier" --json --from "$root/tests/frontier/fixtures/graph" --state "$tmp/none.json")
check "frontier takes model and effort from the definition" '.ready[] | select(.number == 14) | .role == "implementer" and .agent == "factory:implementer" and .model == "haiku" and .effort == "medium"'
check "deep role from its definition" '.ready[0] | .role == "implementer-deep" and .agent == "factory:implementer-deep" and .model == "opus"'

# --- the hooks know a role by its definition: a new one needs no hook change ---
cat >"$tmp/plugin/agents/decision-reviewer.md" <<'MD'
---
name: decision-reviewer
description: test role
model: haiku
effort: low
tools: Read, Grep, Glob, Bash
---
Review.
MD
cat >"$tmp/plugin/agents/porter.md" <<'MD'
---
name: porter
description: test builder
model: sonnet
effort: high
isolation: worktree
---
Build.
MD
launch() { # launch <subagent_type>: a PreToolUse Agent call without isolation in the input
  jq -nc --arg t "$1" '{session_id: "s", cwd: "/x", hook_event_name: "PreToolUse", tool_name: "Agent",
    tool_use_id: "toolu_1", tool_input: {description: "do #7", prompt: "p", subagent_type: $t}}'
}
gate() { # gate <subagent_type>: exit code of the spawn gate with no room at all
  local code=0
  launch "$1" | env CLAUDE_PROJECT_DIR="$tmp/proj" FACTORY_TEST=1 FACTORY_TEST_FREE_DISK_MB=0 FACTORY_TEST_FREE_TEMP_MB=0 \
    FACTORY_TEST_RUNNING_BUILDERS=99 FACTORY_TEST_WORKTREE_MB=1000 "$tmp/plugin/hooks/spawn-gate.sh" >/dev/null 2>&1 || code=$?
  echo "$code"
}
[ "$(gate factory:porter)" = 2 ] || fail "a definition with isolation worktree is a builder"
[ "$(gate factory:decision-reviewer)" = 0 ] || fail "a definition without isolation is read-only"
[ "$(gate factory:watcher)" = 0 ] || fail "watcher is read-only"
[ "$(gate 'factory:../../x')" = 0 ] || fail "a path-like type is not a role"
pass=$((pass + 4))
launch factory:decision-reviewer | CLAUDE_PROJECT_DIR="$tmp/proj" LEDGER_NOW=2026-01-01T00:00:00Z bash "$tmp/plugin/hooks/ledger.sh"
out=$(tail -n 1 "$tmp/proj/.factory/ledger.jsonl")
check "ledger knows a role from its definition" '.role == "decision-reviewer" and .ticket == 7'
launch factory:nobody | CLAUDE_PROJECT_DIR="$tmp/proj" LEDGER_NOW=2026-01-01T00:00:00Z bash "$tmp/plugin/hooks/ledger.sh"
out=$(tail -n 1 "$tmp/proj/.factory/ledger.jsonl")
check "ledger: a type without a definition is other" '.role == "other"'

echo "roles suite passed ($pass checks)"
