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
for f in CLAUDE.md GLOSSARY.md docs/agents/issue-tracker.md docs/agents/triage-labels.md scripts/check.sh .githooks/pre-push .gitignore docs/adr/0001-scripts-print-with-printf.md; do
  [ -f "$sbd/$f" ] || fail "sandbox lacks $f"
done; ok
[ -x "$sbd/scripts/check.sh" ] && [ -x "$sbd/.githooks/pre-push" ] || fail "check script and hook are executable"; ok
[ "$(git -C "$sbd" config core.hooksPath)" = .githooks ] || fail "hooks path is set in the clone"; ok
(cd "$sbd" && bash scripts/check.sh >/dev/null) || fail "the sandbox's own check does not pass"; ok
[ -z "$(git -C "$sbd" status --porcelain)" ] || fail "sandbox clone is not clean"; ok
# the decision review has a decision to review against, and a ticket that tempts a conflict with it
grep -q 'printf' "$sbd/docs/adr/0001-scripts-print-with-printf.md" && grep -q 'echo' "$sbd/docs/adr/0001-scripts-print-with-printf.md" || fail "the ADR does not rule out echo in favour of printf"; ok
grep -q 'docs/adr/' "$sbd/CLAUDE.md" || fail "CLAUDE.md does not point at docs/adr/"; ok
# a slow pre-push hook keeps a merge running long enough for a second one to queue; tests set the delay to 0
grep -q 'SANDBOX_PUSH_DELAY' "$sbd/.githooks/pre-push" || fail "the pre-push hook has no delay"; ok
(cd "$sbd" && SANDBOX_PUSH_DELAY=0 .githooks/pre-push >/dev/null) || fail "the pre-push hook fails with no delay"; ok
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

# a second spec, blocked by the first as a whole: two tickets linked only to ticket 2 (early), one with no links (held)
jq -e '.title | test("^Spec:")' "$FAKE_GH_DIR/issues/5.json" >/dev/null || fail "issue 5 is not the second spec"
jq -e '.body | test("(^|\n)## User Stories")' "$FAKE_GH_DIR/issues/5.json" >/dev/null || fail "the second spec has no User Stories heading"
jq -e '.parent == null and .blocked == [1] and (.labels | index("ready-for-agent"))' "$FAKE_GH_DIR/issues/5.json" >/dev/null || fail "spec 5 is not blocked by spec 1 as a whole"; ok
for t in 6 7 8; do
  jq -e '.parent == 5 and (.labels | index("ready-for-agent"))' "$FAKE_GH_DIR/issues/$t.json" >/dev/null || fail "ticket $t is not a ready sub-issue of spec 5"
  jq -e '.body | test("## Acceptance criteria")' "$FAKE_GH_DIR/issues/$t.json" >/dev/null || fail "ticket $t has no acceptance criteria"
done; ok
jq -e '.blocked == [2]' "$FAKE_GH_DIR/issues/6.json" >/dev/null && jq -e '.blocked == [2]' "$FAKE_GH_DIR/issues/7.json" >/dev/null || fail "tickets 6 and 7 are not linked to ticket 2 only"
jq -e '.blocked == []' "$FAKE_GH_DIR/issues/8.json" >/dev/null || fail "ticket 8 has links of its own"; ok
# ticket 2 tempts a decision-review send-back: a one-line echo against the ADR
jq -e '.body | test("echo")' "$FAKE_GH_DIR/issues/2.json" >/dev/null || fail "ticket 2 does not tempt an echo"; ok
[ ! -e "$FAKE_GH_DIR/issues/9.json" ] || fail "more than two specs and six tickets were created"; ok

# the factory accepts it: prerequisites pass, and only the first ticket is on the frontier
(cd "$sbd" && "$prereqs" --project "$sbd" >/dev/null) || fail "factory-prereqs rejects the sandbox"; ok
fr=$(cd "$sbd" && "$frontier" --json --project "$sbd") || fail "factory-frontier failed"
jq -e '[.ready[].number] == [2]' <<<"$fr" >/dev/null || fail "the frontier is not just ticket 2: $fr"
jq -e '[.blocked[].number] | sort == [3, 4, 6, 7, 8]' <<<"$fr" >/dev/null || fail "tickets 3, 4, 6, 7 and 8 are not blocked: $fr"; ok
jq -e '.specs | map(select(.number == 1 or .number == 5)) | length == 2' <<<"$fr" >/dev/null || fail "the specs are not recognised: $fr"; ok
# the spec-level link holds only the ticket with no link of its own: 8 is spec-blocked by spec 1; 6 and 7 wait on ticket 2 alone
jq -e '[.blocked[] | select(.status == "spec-blocked") | .number] == [8] and (.blocked[] | select(.number == 8) | .blocked_by_spec == [1])' <<<"$fr" >/dev/null || fail "ticket 8 is not held by spec 1's link alone: $fr"; ok
jq -e '[.blocked[] | select(.number == 6 or .number == 7) | .status == "blocked" and .blocked_by == [2]] == [true, true]' <<<"$fr" >/dev/null || fail "tickets 6 and 7 are not held by ticket 2 alone: $fr"; ok
# once ticket 2 is merged, the early tickets are ready though spec 1 is still open; ticket 8 stays held
mkdir -p "$sbd/.factory"
jq -n '{version: 1, running: false, assignments: {}, integration: {},
  merged: {"2": {ticket: 2, spec: 1, commit: "abc", merged_at: "2026-01-01T00:00:00Z"}}}' >"$sbd/.factory/state.json"
fr=$(cd "$sbd" && "$frontier" --json --project "$sbd") || fail "factory-frontier failed after ticket 2 merged"
jq -e '[.ready[].number] | sort == [3, 6, 7]' <<<"$fr" >/dev/null || fail "after ticket 2 merged the frontier is not 3, 6, 7: $fr"
jq -e '[.blocked[] | select(.status == "spec-blocked") | .number] == [8]' <<<"$fr" >/dev/null || fail "ticket 8 was not held after ticket 2 merged: $fr"; ok
rm -rf "$sbd/.factory"

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
# world <dir>: a sandbox after a good second-loop run, built with real git: origin, a clone, spec 1's
# integration branch with three --no-ff ticket merges and a spec report, spec 5's with two (tickets 6
# and 7, linked only to ticket 2, started early; ticket 8 has no links of its own and stays held by the
# spec-level link), every ticket worktree locked the way Claude Code locks an agent's and removed
# through the lock, a ledger (a decision-review send-back on ticket 2, merge events with their
# durations, the second merge into spec 5's branch having waited), a state file, and the canned
# `gh issue view` and `gh pr list` answers. Switches: W_BAD_ORDER, W_NO_REPORT, W_NO_LEDGER,
# W_NO_REVIEW, W_EARLY_LATE, W_HELD_STARTED, W_NO_QUEUE, W_LEFT_BRANCH, W_LEFT_LOCK.
world() {
  local d=$1 ib=spec/1-sandbox-greeter ibb=spec/5-sandbox-farewell wt wtb dead t
  bash -c 'exit 0' & dead=$!
  wait "$dead"
  git init -q --bare -b main "$d.git"
  git clone -q "$d.git" "$d" 2>/dev/null
  printf 'base\n' >"$d/base.txt"
  git -C "$d" add . && git -C "$d" commit -q -m base && git -C "$d" push -q origin main
  git -C "$d" push -q origin main:"$ib" main:"$ibb"
  wt="$d/.claude/worktrees/spec-1" wtb="$d/.claude/worktrees/spec-5"
  git -C "$d" worktree add -q --track -b "$ib" "$wt" "origin/$ib" 2>/dev/null
  git -C "$d" worktree add -q --track -b "$ibb" "$wtb" "origin/$ibb" 2>/dev/null
  mkdir -p "$d/.factory"
  : >"$d/.factory/ledger.jsonl"
  # led <event> <ticket> [result] [extra JSON]: a ledger line; tickets 6 and up belong to spec 5
  led() {
    jq -c -n --arg e "$1" --argjson t "$2" --arg r "${3:-}" --argjson x "${4:-null}" \
      '{ts: "2026-01-01T00:00:00Z", event: $e, ticket: $t, spec: (if $t >= 5 then 5 else 1 end)}
       + (if $r == "" then {} else {result: $r} end) + ($x // {})' >>"$d/.factory/ledger.jsonl"
  }
  # build <ticket> <integration branch>: a worktree with one commit, locked as Claude Code locks an
  # agent's, then removed through the lock (what the merge's clean-up does)
  build() {
    local w="$d/.claude/worktrees/agent-$1"
    git -C "$d" worktree add -q -b "t$1-work" "$w" "$2"
    echo "ticket $1" >"$w/f$1.txt"
    git -C "$w" add . && git -C "$w" commit -q -m "ticket $1"
    git -C "$d" worktree lock --reason "claude agent agent-$1 (pid $dead start 1)" "$w"
    git -C "$d" worktree remove --force --force "$w"
    led agent_stop "$1"; led gate "$1" pass
  }
  # land <ticket> <integration worktree> <integration branch> <merge event JSON>
  land() {
    git -C "$2" merge -q --no-ff -m "Merge t$1-work into $3: Ticket $1 (#$1)" "t$1-work"
    if [ -n "${W_LEFT_BRANCH:-}" ] && [ "$1" = 6 ]; then git -C "$d" push -q origin "t$1-work"; fi
    git -C "$d" branch -q -D "t$1-work"
    led merge "$1" merged "$4"
  }
  for t in 2 3 4; do
    # with W_BAD_ORDER, ticket 3 is assigned before ticket 2 is merged (below), not here
    [ -n "${W_BAD_ORDER:-}" ] && [ "$t" = 3 ] || led assign "$t"
    build "$t" "$ib"
    if [ "$t" = 2 ] && [ -z "${W_NO_REVIEW:-}" ]; then led gate 2 fail; led gate 2 pass; fi
    [ -z "${W_BAD_ORDER:-}" ] || [ "$t" != 2 ] || led assign 3
    land "$t" "$wt" "$ib" '{"duration_s": 20}'
    if [ "$t" = 2 ] && [ -z "${W_EARLY_LATE:-}" ]; then led assign 6; led assign 7; fi
    if [ "$t" = 4 ] && [ -n "${W_EARLY_LATE:-}" ]; then led assign 6; led assign 7; fi
  done
  [ -z "${W_HELD_STARTED:-}" ] || led assign 8
  build 6 "$ibb"; build 7 "$ibb"
  land 6 "$wtb" "$ibb" '{"duration_s": 50}'
  if [ -n "${W_NO_QUEUE:-}" ]; then
    land 7 "$wtb" "$ibb" '{"duration_s": 50}'
  else
    land 7 "$wtb" "$ibb" '{"duration_s": 80, "waited_s": 30}'
  fi
  if [ -z "${W_NO_REPORT:-}" ]; then
    mkdir -p "$wt/docs/factory/reports"
    echo "# Spec report" >"$wt/docs/factory/reports/1-sandbox-greeter.md"
    git -C "$wt" add . && git -C "$wt" commit -q -m "Spec report: #1"
  fi
  git -C "$wt" push -q origin "$ib"
  git -C "$wtb" push -q origin "$ibb"
  if [ -n "${W_LEFT_LOCK:-}" ]; then
    mkdir -p "$d/.factory/locks/spec_5-sandbox-farewell"
    printf 'pid=%s\nticket=7\n' "$dead" >"$d/.factory/locks/spec_5-sandbox-farewell/q00000001"
  fi
  [ -z "${W_NO_LEDGER:-}" ] || rm "$d/.factory/ledger.jsonl"
  jq -n --arg b "$ib" --arg wt "$wt" --arg bb "$ibb" --arg wtb "$wtb" '{version: 1, running: false, assignments: {}, merged: {},
    integration: {"1": {branch: $b, worktree: $wt, status: "complete"}, "5": {branch: $bb, worktree: $wtb, status: "active"}}}' >"$d/.factory/state.json"
  git -C "$d" fetch -q origin
  jq -n '{number: 1, title: "Spec: sandbox greeter", state: "OPEN",
    subIssues: {nodes: [{number: 2, state: "CLOSED", title: "a"}, {number: 3, state: "CLOSED", title: "b"}, {number: 4, state: "CLOSED", title: "c"}], totalCount: 3}}' \
    >"$FAKE_GH_DIR/issue-view-1.json"
  jq -n '{number: 5, title: "Spec: sandbox farewell", state: "OPEN",
    subIssues: {nodes: [{number: 6, state: "CLOSED", title: "d"}, {number: 7, state: "CLOSED", title: "e"}, {number: 8, state: "OPEN", title: "f"}], totalCount: 3}}' \
    >"$FAKE_GH_DIR/issue-view-5.json"
  jq -n --arg b "$ib" '[{number: 9, isDraft: true, state: "OPEN", url: "https://github.com/o/r/pull/9", headRefName: $b, baseRefName: "main",
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
for c in tickets order worktrees merged ledger report pr asked review kpis early held queue cleanup; do
  case "$vout" in *"ok: $c"*) ok ;; *) fail "verify did not check $c: $vout" ;; esac
done
case "$vout" in *"sandbox verify passed"*) ok ;; *) fail "no closing line: $vout" ;; esac
case "$vout" in *"asked before merging"*) ok ;; *) fail "verify does not tell the user to confirm the question: $vout" ;; esac
case "$vout" in *"no wait of its own"*) ok ;; *) fail "verify does not tell the user to confirm the manager wrote no waits: $vout" ;; esac

W_BAD_ORDER=1 world "$tmp/order"
verify "$tmp/order"; bad "a ticket assigned before its blocker merged" order

W_NO_REPORT=1 world "$tmp/noreport"
verify "$tmp/noreport"; bad "no spec report on the integration branch" report

W_NO_LEDGER=1 world "$tmp/noledger"
verify "$tmp/noledger"; bad "no ledger" ledger

W_NO_REVIEW=1 world "$tmp/noreview"
verify "$tmp/noreview"; bad "no ticket was sent back by the decision review" review
case "$vout" in *"ADR"*) ok ;; *) fail "the review failure does not say what to do: $vout" ;; esac

W_EARLY_LATE=1 world "$tmp/late"
verify "$tmp/late"; bad "the early tickets waited for the whole spec" early

W_HELD_STARTED=1 world "$tmp/held"
verify "$tmp/held"; bad "a ticket with no links of its own started despite the spec-level link" held

W_NO_QUEUE=1 world "$tmp/noqueue"
verify "$tmp/noqueue"; bad "the second merge into one branch never waited" queue

W_LEFT_BRANCH=1 world "$tmp/leftbranch"
verify "$tmp/leftbranch"; bad "a ticket branch left on origin after its merge" cleanup

W_LEFT_LOCK=1 world "$tmp/leftlock"
verify "$tmp/leftlock"; bad "a merge lock left behind" cleanup

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
jq '.subIssues.nodes |= .[:2]' "$FAKE_GH_DIR/issue-view-1.json" >"$tmp/iv.json" && mv "$tmp/iv.json" "$FAKE_GH_DIR/issue-view-1.json"
verify "$tmp/few"; bad "a spec with two tickets" tickets

# --early-spec names the second spec; the default is the sandbox's layout (spec + 4)
world "$tmp/early"
code=0; vout=$("$sb" verify --dir "$tmp/early" --spec 1 --early-spec 5 2>&1) || code=$?
good "--early-spec 5"
code=0; vout=$("$sb" verify --dir "$tmp/early" --spec 1 --early-spec 6 2>&1) || code=$?
[ "$code" = 1 ] || fail "a wrong --early-spec passed: $vout"; ok

# usage errors
if "$sb" 2>/dev/null; then fail "no command was accepted"; fi
if "$sb" bogus 2>/dev/null; then fail "an unknown command was accepted"; fi
if "$sb" verify --dir "$tmp/does-not-exist" 2>/dev/null; then fail "verify accepted a missing directory"; fi; ok

echo "sandbox suite: $pass checks passed"
