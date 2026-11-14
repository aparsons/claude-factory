#!/usr/bin/env bash
# Suite: the decision review (ticket #21): the decision-reviewer role is a read-only definition on a
# small model, and factory-review plan says whether a ticket is reviewed before its merge and
# what the reviewer gets (the project's ADRs, the changed files, the diff command), over a
# temporary repository (no network, no gh).
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
plugin="$root/plugins/factory"
tool="$plugin/bin/factory-review"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass=0
fail() { echo "FAIL: $*"; exit 1; }
# check <name> <jq filter that must be true> : over $out
check() { jq -e "$2" <<<"$out" >/dev/null || fail "$1: $(jq -c "$2" <<<"$out" 2>&1) in $out"; pass=$((pass + 1)); }
# frontmatter <file> <key>: the value of a top-level key in a definition's frontmatter
frontmatter() { awk -v k="$2" 'NR == 1 { next } /^---$/ { exit } index($0, k ": ") == 1 { print substr($0, length(k) + 3) }' "$1"; }

# --- the role: a read-only reviewer on a small model (user story 15) ---
def="$plugin/agents/decision-reviewer.md"
[ -f "$def" ] || fail "no definition $def"
[ "$(head -n 1 "$def")" = "---" ] || fail "no frontmatter"
[ "$(frontmatter "$def" name)" = decision-reviewer ] || fail "name is '$(frontmatter "$def" name)'"
[ -n "$(frontmatter "$def" description)" ] || fail "no description"
[ "$(frontmatter "$def" model)" = haiku ] || fail "model is '$(frontmatter "$def" model)', want a small model (haiku)"
[ -n "$(frontmatter "$def" effort)" ] || fail "no effort"
[ -z "$(frontmatter "$def" isolation)" ] || fail "a reviewer does not run in a worktree of its own (not a builder)"
tools=$(frontmatter "$def" tools)
[ -n "$tools" ] || fail "no tools allowlist (no list means every tool)"
for t in Edit Write MultiEdit NotebookEdit Agent Task; do
  [[ ",$(tr -d ' ' <<<"$tools")," != *",$t,"* ]] || fail "tools include $t: $tools"
done
[[ ",$(tr -d ' ' <<<"$tools")," == *",Read,"* ]] || fail "the reviewer cannot read: $tools"
[ -n "$(awk 'NR > 1 && /^---$/ { found = 1; next } found && NF { print; exit }' "$def")" ] || fail "empty system prompt"
pass=$((pass + 1))
# it reports only ADR conflicts and unmet acceptance criteria, quoting the decision line
body=$(awk 'NR > 1 && /^---$/ { found = 1; next } found { print }' "$def")
for needle in "ADR" "acceptance criteri" "quote"; do
  grep -qi "$needle" <<<"$body" || fail "the reviewer's prompt does not say '$needle'"
done
pass=$((pass + 1))

# --- a repository: main with two ADRs, a spec branch, and a ticket branch with a diff ---
p="$tmp/proj"
git init -q -b main "$p"
mkdir -p "$p/docs/adr" "$p/src"
printf '# 1. Named intrinsics\n\nUse the named intrinsics, never a generic form.\n' >"$p/docs/adr/0001-named-intrinsics.md"
printf '# 2. Plain files\n\nState lives in plain files.\n' >"$p/docs/adr/0002-plain-files.md"
echo base >"$p/src/a.txt"
git -C "$p" add .
git -C "$p" commit -q -m base
git -C "$p" branch spec/9-the-thing
git -C "$p" checkout -q -b t21-ticket
echo changed >"$p/src/a.txt"
echo new >"$p/src/b.txt"
git -C "$p" add .
git -C "$p" commit -q -m ticket
export CLAUDE_PROJECT_DIR="$p"
plan() { "$tool" plan --ticket 21 --worktree "$p" --base spec/9-the-thing "$@"; }

# --- enabled by default; the reviewer gets the ADRs, the changed files and the diff command ---
out=$(plan)
check "ticket and base named" '.ticket == 21 and .base == "spec/9-the-thing"'
check "enabled by default" '.enabled == true and .reason == null'
check "the ADRs, sorted, relative to the worktree" '.adrs == ["docs/adr/0001-named-intrinsics.md", "docs/adr/0002-plain-files.md"]'
check "the changed files against the base" '.changed_files == ["src/a.txt", "src/b.txt"]'
check "the diff command is against the integration branch" '.diff_command == "git -C \(.worktree | @sh) diff spec/9-the-thing...HEAD"'
check "the worktree is absolute" '.worktree | startswith("/")'
cmd=$(jq -r .diff_command <<<"$out")
[ "$(bash -c "$cmd" | grep -c '^+')" -gt 0 ] || fail "the diff command prints the diff"
pass=$((pass + 1))

# --- a project without ADRs is still reviewed against the acceptance criteria ---
git -C "$p" checkout -q main
git -C "$p" checkout -q -b spec/10-no-adrs
git -C "$p" rm -q -r docs/adr
git -C "$p" commit -q -m "no adrs"
git -C "$p" checkout -q -b t22-noadr
echo more >"$p/src/c.txt"
git -C "$p" add .
git -C "$p" commit -q -m more
out=$("$tool" plan --ticket 22 --worktree "$p" --base spec/10-no-adrs)
check "no ADRs: still enabled, empty list" '.enabled == true and .adrs == []'
check "only the ticket's own change" '.changed_files == ["src/c.txt"]'
git -C "$p" checkout -q t21-ticket

# --- the project setting turns the review off (user story 19) ---
mkdir -p "$p/.factory"
echo '{"decision_review": false}' >"$p/.factory/settings.json"
out=$(plan)
check "setting off: not reviewed, with the reason" '.enabled == false and .reason == "decision_review is false in .factory/settings.json" and .ticket == 21'
echo '{"decision_review": true, "builder_cap": 2}' >"$p/.factory/settings.json"
out=$(plan)
check "setting on is the default" '.enabled == true'
echo '{"builder_cap": 2}' >"$p/.factory/settings.json"
out=$(plan)
check "other settings leave it on" '.enabled == true'
echo 'not json' >"$p/.factory/settings.json"
out=$(plan)
check "unreadable settings leave it on" '.enabled == true'
rm -rf "$p/.factory"

# --- the plan changes nothing ---
[ -z "$(git -C "$p" status --porcelain)" ] || fail "the plan left changes: $(git -C "$p" status --porcelain)"
pass=$((pass + 1))
[ ! -e "$p/.factory" ] || fail "the plan created .factory"
pass=$((pass + 1))

# --- usage errors exit 2 ---
for args in "plan --worktree $p --base main" "plan --ticket 21 --base main" "plan --ticket 21 --worktree $p" \
  "plan --ticket x --worktree $p --base main" "plan --ticket 21 --worktree $p --base nobranch" \
  "plan --ticket 21 --worktree $tmp/missing --base main" "nothing"; do
  code=0
  # shellcheck disable=SC2086 # the arguments are split on purpose
  "$tool" $args >/dev/null 2>&1 || code=$?
  [ "$code" = 2 ] || fail "'$args': exit $code, want 2"
  pass=$((pass + 1))
done

echo "review suite passed ($pass checks)"
