#!/usr/bin/env bash
# shellcheck disable=SC2015 # `test && check || fail` is the assertion form
# Suite: scripts/sandbox.sh (the release dry run's sandbox) against a fake gh and local git
# remotes only. No network, no GitHub repository, issue or label is created.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
sb="$root/scripts/sandbox.sh"
prereqs="$root/plugins/factory/bin/factory-prereqs"
frontier="$root/plugins/factory/bin/factory-frontier"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandbox-suite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export FAKE_GH_DIR="$tmp/gh"
export PATH="$root/tests/sandbox/fixtures/bin:$PATH"
pass=0
fail() { echo "FAIL: $*"; exit 1; }
ok() { pass=$((pass + 1)); }
# Never reach the real gh: this suite must not create anything on GitHub. A fake that is not
# executable would let the real one through, so stop before any call unless the fake is first.
[ "$(command -v gh)" = "$root/tests/sandbox/fixtures/bin/gh" ] || fail "gh on PATH is not the fake: $(command -v gh)"

# --- create: a sandbox repository with one spec of three tickets and blocking edges ---
out=$("$sb" create --name factory-sandbox-test --dir "$tmp/sb") || fail "create exited $?: $out"; ok
case "$out" in *fake-user/factory-sandbox-test*) ok ;; *) fail "create does not name the repository: $out" ;; esac
case "$out" in *"/factory start"*) ok ;; *) fail "create does not say how to run the factory: $out" ;; esac
sbd="$tmp/sb"
for f in CLAUDE.md GLOSSARY.md docs/agents/issue-tracker.md docs/agents/triage-labels.md scripts/check.sh .githooks/pre-push .gitignore; do
  [ -f "$sbd/$f" ] || fail "sandbox lacks $f"
done; ok
[ -x "$sbd/scripts/check.sh" ] && [ -x "$sbd/.githooks/pre-push" ] || fail "check script and hook are executable"; ok
[ "$(git -C "$sbd" config core.hooksPath)" = .githooks ] || fail "hooks path is set in the clone"; ok
(cd "$sbd" && bash scripts/check.sh >/dev/null) || fail "the sandbox's own check does not pass"; ok
[ -z "$(git -C "$sbd" status --porcelain)" ] || fail "sandbox clone is not clean"; ok
[ "$(git --git-dir="$FAKE_GH_DIR/remote/factory-sandbox-test.git" rev-parse main)" = "$(git -C "$sbd" rev-parse main)" ] ||
  fail "main is not pushed to the sandbox remote"; ok
grep -qx ready-for-agent "$FAKE_GH_DIR/labels" && grep -qx needs-triage "$FAKE_GH_DIR/labels" || fail "labels are not created"; ok
grep -q -- '^repo create .*--private' "$FAKE_GH_DIR/calls.log" || fail "the repository is not private"; ok
if grep -q -- '--public' "$FAKE_GH_DIR/calls.log"; then fail "the repository was made public"; fi; ok

jq -e '.title | test("^Spec:")' "$FAKE_GH_DIR/issues/1.json" >/dev/null || fail "issue 1 is not the spec"
jq -e '.body | test("(^|\n)## User Stories")' "$FAKE_GH_DIR/issues/1.json" >/dev/null || fail "the spec has no User Stories heading"
jq -e '.parent == null and .blocked == []' "$FAKE_GH_DIR/issues/1.json" >/dev/null || fail "the spec has a parent or blockers"; ok
for t in 2 3 4; do
  jq -e '.parent == 1 and (.labels | index("ready-for-agent"))' "$FAKE_GH_DIR/issues/$t.json" >/dev/null ||
    fail "ticket $t is not a ready sub-issue of the spec"
  jq -e '.body | test("## Acceptance criteria")' "$FAKE_GH_DIR/issues/$t.json" >/dev/null || fail "ticket $t has no acceptance criteria"
done; ok
jq -e '.blocked == []' "$FAKE_GH_DIR/issues/2.json" >/dev/null || fail "ticket 2 is blocked"
jq -e '.blocked == [2]' "$FAKE_GH_DIR/issues/3.json" >/dev/null || fail "ticket 3 is not blocked by 2"
jq -e '.blocked == [2, 3]' "$FAKE_GH_DIR/issues/4.json" >/dev/null || fail "ticket 4 is not blocked by 2 and 3"; ok
[ ! -e "$FAKE_GH_DIR/issues/5.json" ] || fail "more than one spec and three tickets were created"; ok

# the factory accepts it: prerequisites pass, and only the first ticket is on the frontier
(cd "$sbd" && "$prereqs" --project "$sbd" >/dev/null) || fail "factory-prereqs rejects the sandbox"; ok
fr=$(cd "$sbd" && "$frontier" --json --project "$sbd") || fail "factory-frontier failed"
jq -e '[.ready[].number] == [2]' <<<"$fr" >/dev/null || fail "the frontier is not just ticket 2: $fr"
jq -e '[.blocked[].number] | sort == [3, 4]' <<<"$fr" >/dev/null || fail "tickets 3 and 4 are not blocked: $fr"; ok
jq -e '.specs | map(select(.number == 1)) | length == 1' <<<"$fr" >/dev/null || fail "the spec is not recognised: $fr"; ok

# create refuses a directory that is not empty, and does not call gh then
mkdir -p "$tmp/busy" && echo x >"$tmp/busy/file"
calls=$(wc -l <"$FAKE_GH_DIR/calls.log")
if "$sb" create --name factory-sandbox-busy --dir "$tmp/busy" >/dev/null 2>&1; then fail "create used a non-empty directory"; fi
[ "$(wc -l <"$FAKE_GH_DIR/calls.log")" = "$calls" ] || fail "create called gh before refusing"; ok

# --dry-run prints the plan and calls nothing
out=$("$sb" create --dry-run --name factory-sandbox-plan --dir "$tmp/plan") || fail "dry-run exited $?"
case "$out" in *factory-sandbox-plan*private*) ok ;; *) fail "dry-run does not print the plan: $out" ;; esac
[ "$(wc -l <"$FAKE_GH_DIR/calls.log")" = "$calls" ] && [ ! -e "$tmp/plan" ] || fail "dry-run changed something"; ok

# --owner is used for the repository
"$sb" create --name factory-sandbox-org --owner some-org --dir "$tmp/org" >/dev/null || fail "create --owner failed"
grep -q -- '^repo create some-org/factory-sandbox-org ' "$FAKE_GH_DIR/calls.log" || fail "--owner not passed to gh"; ok

# --- destroy: only sandbox repositories, only when told to ---
if "$sb" destroy --repo fake-user/factory-sandbox-test >/dev/null 2>&1; then fail "destroy without --yes"; fi
if "$sb" destroy --repo fake-user/oska --yes >/dev/null 2>&1; then fail "destroy deleted a repository that is not a sandbox"; fi
if grep -q '^repo delete' "$FAKE_GH_DIR/calls.log"; then fail "gh repo delete was called by a refused destroy"; fi; ok
"$sb" destroy --repo fake-user/factory-sandbox-test --yes >/dev/null || fail "destroy --yes failed"
grep -qx 'repo delete fake-user/factory-sandbox-test --yes' "$FAKE_GH_DIR/calls.log" || fail "gh repo delete not called as expected"; ok

# --- verify: what a good run leaves behind, and how a bad one fails ---
# world <dir>: a sandbox after a good run, built with real git: origin, a clone, the integration
# branch with three --no-ff ticket merges and a spec report, a ledger, a state file, and the canned
# `gh issue view` and `gh pr list` answers. Switches: W_BAD_ORDER, W_NO_REPORT, W_NO_LEDGER.
world() {
  local d=$1 ib=spec/1-sandbox-greeter wt t i
  git init -q --bare -b main "$d.git"
  git clone -q "$d.git" "$d" 2>/dev/null
  printf 'base\n' >"$d/base.txt"
  git -C "$d" add . && git -C "$d" commit -q -m base && git -C "$d" push -q origin main
  git -C "$d" push -q origin main:"$ib"
  wt="$d/.claude/worktrees/spec-1"
  git -C "$d" worktree add -q --track -b "$ib" "$wt" "origin/$ib" 2>/dev/null
  mkdir -p "$d/.factory"
  : >"$d/.factory/ledger.jsonl"
  led() { jq -c -n --arg e "$1" --argjson t "$2" --arg r "${3:-}" '{ts: "2026-01-01T00:00:00Z", event: $e, ticket: $t, spec: 1} + (if $r == "" then {} else {result: $r} end)' >>"$d/.factory/ledger.jsonl"; }
  for t in 2 3 4; do
    i=$((t - 1))
    # with W_BAD_ORDER, ticket 3 is assigned before ticket 2 is merged (below), not here
    [ -n "${W_BAD_ORDER:-}" ] && [ "$t" = 3 ] || led assign "$t"
    git -C "$d" worktree add -q -b "t$t-work" "$d/.claude/worktrees/agent-$t" "$ib"
    echo "ticket $t" >"$d/.claude/worktrees/agent-$t/f$t.txt"
    git -C "$d/.claude/worktrees/agent-$t" add . && git -C "$d/.claude/worktrees/agent-$t" commit -q -m "ticket $t"
    git -C "$d" worktree remove --force "$d/.claude/worktrees/agent-$t"
    led agent_stop "$t"; led gate "$t" pass
    [ -z "${W_BAD_ORDER:-}" ] || [ "$t" != 2 ] || led assign 3
    git -C "$wt" merge -q --no-ff -m "Merge t$t-work into $ib: Ticket $i (#$t)" "t$t-work"
    git -C "$wt" branch -q -d "t$t-work"
    led merge "$t"
  done
  if [ -z "${W_NO_REPORT:-}" ]; then
    mkdir -p "$wt/docs/factory/reports"
    echo "# Spec report" >"$wt/docs/factory/reports/1-sandbox-greeter.md"
    git -C "$wt" add . && git -C "$wt" commit -q -m "Spec report: #1"
  fi
  git -C "$wt" push -q origin "$ib"
  [ -z "${W_NO_LEDGER:-}" ] || rm "$d/.factory/ledger.jsonl"
  jq -n --arg b "$ib" --arg wt "$wt" '{version: 1, running: false, assignments: {}, merged: {},
    integration: {"1": {branch: $b, worktree: $wt, status: "complete"}}}' >"$d/.factory/state.json"
  git -C "$d" fetch -q origin
  jq -n '{number: 1, title: "Spec: sandbox greeter", state: "OPEN",
    subIssues: {nodes: [{number: 2, state: "CLOSED", title: "a"}, {number: 3, state: "CLOSED", title: "b"}, {number: 4, state: "CLOSED", title: "c"}], totalCount: 3}}' \
    >"$FAKE_GH_DIR/issue-view.json"
  jq -n --arg b "$ib" '[{number: 5, isDraft: true, state: "OPEN", url: "https://github.com/o/r/pull/5", headRefName: $b, baseRefName: "main",
    body: "Sandbox.\n\nCloses #1\nCloses #2\nCloses #3\nCloses #4"}]' >"$FAKE_GH_DIR/pr-list.json"
}
# verify <dir>: sets $code and $vout
verify() { code=0; vout=$("$sb" verify --dir "$1" --spec 1 2>&1) || code=$?; }
good() { # good <name>
  [ "$code" = 0 ] || fail "$1: verify exited $code: $vout"
  case "$vout" in *FAIL*) fail "$1: verify printed a FAIL: $vout" ;; esac
  ok
}
bad() { # bad <name> <criterion that must fail>
  [ "$code" = 1 ] || fail "$1: verify exited $code, wanted 1: $vout"
  case "$vout" in *"FAIL: $2"*) ok ;; *) fail "$1: no FAIL: $2 line: $vout" ;; esac
}

world "$tmp/good"
verify "$tmp/good"
good "a good run passes"
for c in tickets order worktrees merged ledger report pr asked; do
  case "$vout" in *"ok: $c"*) ok ;; *) fail "verify did not check $c: $vout" ;; esac
done
case "$vout" in *"sandbox verify passed"*) ok ;; *) fail "no closing line: $vout" ;; esac
case "$vout" in *"asked before merging"*) ok ;; *) fail "verify does not tell the user to confirm the question: $vout" ;; esac

W_BAD_ORDER=1 world "$tmp/order"
verify "$tmp/order"; bad "a ticket assigned before its blocker merged" order

W_NO_REPORT=1 world "$tmp/noreport"
verify "$tmp/noreport"; bad "no spec report on the integration branch" report

W_NO_LEDGER=1 world "$tmp/noledger"
verify "$tmp/noledger"; bad "no ledger" ledger

world "$tmp/leftover"
git -C "$tmp/leftover" worktree add -q -b t4-left "$tmp/leftover/.claude/worktrees/agent-left" main
verify "$tmp/leftover"; bad "a ticket worktree left behind" worktrees

world "$tmp/nodraft"
jq '.[0].isDraft = false' "$FAKE_GH_DIR/pr-list.json" >"$tmp/pr.json" && mv "$tmp/pr.json" "$FAKE_GH_DIR/pr-list.json"
verify "$tmp/nodraft"; bad "a pull request that is not a draft" pr

world "$tmp/nopr"
echo '[]' >"$FAKE_GH_DIR/pr-list.json"
verify "$tmp/nopr"; bad "no pull request" pr

world "$tmp/noclose"
jq '.[0].body = "Closes #1"' "$FAKE_GH_DIR/pr-list.json" >"$tmp/pr.json" && mv "$tmp/pr.json" "$FAKE_GH_DIR/pr-list.json"
verify "$tmp/noclose"; bad "a pull request that does not close the tickets" pr

world "$tmp/merged"
jq '.[0].state = "MERGED"' "$FAKE_GH_DIR/pr-list.json" >"$tmp/pr.json" && mv "$tmp/pr.json" "$FAKE_GH_DIR/pr-list.json"
verify "$tmp/merged"; bad "a pull request merged without asking" asked

world "$tmp/pushed"
git -C "$tmp/pushed" push -q origin spec/1-sandbox-greeter:main
verify "$tmp/pushed"; bad "the integration branch landed on main" asked

world "$tmp/few"
jq '.subIssues.nodes |= .[:2]' "$FAKE_GH_DIR/issue-view.json" >"$tmp/iv.json" && mv "$tmp/iv.json" "$FAKE_GH_DIR/issue-view.json"
verify "$tmp/few"; bad "a spec with two tickets" tickets

# usage errors
if "$sb" 2>/dev/null; then fail "no command was accepted"; fi
if "$sb" bogus 2>/dev/null; then fail "an unknown command was accepted"; fi
if "$sb" verify --dir "$tmp/does-not-exist" 2>/dev/null; then fail "verify accepted a missing directory"; fi; ok

echo "sandbox suite: $pass checks passed"
