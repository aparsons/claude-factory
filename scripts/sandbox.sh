#!/usr/bin/env bash
# shellcheck disable=SC2016 # Markdown with backticks is written literally
# The release dry run's sandbox: creates a throwaway GitHub repository holding one spec of three
# tiny tickets with blocking edges, and verifies afterwards what the factory left behind.
# See README.md ("Release dry run") for the whole procedure.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/sandbox.sh create [--name NAME] [--owner OWNER] [--dir DIR] [--dry-run]
      Create a private GitHub repository NAME (default factory-sandbox-<date>-<time>) under OWNER
      (default: the gh login), seeded with a tiny project that follows the mattpocock-skills
      conventions (CLAUDE.md with a check command, issue tracker and triage label docs, a
      pre-push hook that pauses SANDBOX_PUSH_DELAY seconds, default 45), an ADR (docs/adr/0001: print
      with printf, never echo), the triage labels, and two specs of three tickets:
        #1 spec: greeter
          #2 greet.sh prints a greeting      (no blockers; tempts an echo against the ADR)
          #3 greet.sh takes a name           (blocked by #2)
          #4 greet.sh --shout                (blocked by #2 and #3)
        #5 spec: farewell                    (blocked by spec #1 as a whole)
          #6 bye.sh, #7 thanks.sh            (each blocked by #2 only: they start early, side by side)
          #8 wave.sh                         (no links of its own: held by the spec-level link)
      cloned to DIR (default ./NAME). --dry-run prints the plan and calls nothing.
      Needs gh 2.94+ (sub-issues and blocked-by) authenticated, git and jq.
  scripts/sandbox.sh verify [--dir DIR] [--spec N] [--early-spec M]
      After a factory run in DIR (default .), check it against the specs' acceptance criteria:
      tickets taken in frontier order, worktrees used and removed, every ticket merged into the
      integration branch, ledger written, spec report committed, one draft pull request closing the
      spec and its tickets, and nothing merged to the default branch; and the second loop: a ticket
      sent back by the decision review and passed again (the first-try rate below 100% in the KPIs),
      the second spec's early tickets (linked to just the first spec's first ticket) started before
      the first spec was done while its unlinked ticket stayed held, their two merges into one
      integration branch queued (the second waited), and no ticket worktree, branch or merge lock left
      behind (Claude Code holds a lock on every agent worktree at merge time). M defaults to N + 4,
      the sandbox's layout. Exit 0 when all hold.
  scripts/sandbox.sh destroy --repo OWNER/NAME --yes
      Delete a sandbox repository (its name must start with factory-sandbox-). Needs the
      delete_repo scope: gh auth refresh -s delete_repo.
USAGE
}

die() { echo "sandbox.sh: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# ---------------------------------------------------------------- seed files
seed() { # seed <dir>: the sandbox's tracked files
  local d=$1
  mkdir -p "$d/docs/agents" "$d/docs/adr" "$d/scripts" "$d/tests" "$d/.githooks"
  cat >"$d/CLAUDE.md" <<'EOF'
## Checks

Run `scripts/check.sh` before every commit. The pre-push hook runs it too (enable once per clone: `git config core.hooksPath .githooks`). Never skip the hook.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues on this repository (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
EOF
  cat >"$d/GLOSSARY.md" <<'EOF'
# Glossary

**Greeting**:
The line `greet.sh` prints: `Hello, <name>!`, or `Hello, world!` without a name.
EOF
  cat >"$d/README.md" <<'EOF'
# factory sandbox

A throwaway repository for the claude-factory release dry run. It holds a tiny shell greeter that the factory builds from three tickets. Safe to delete.
EOF
  cat >"$d/docs/agents/domain.md" <<'EOF'
# Domain docs

Single-context: read `GLOSSARY.md` and the decisions in `docs/adr/` at the repository root before changing anything. A change must not contradict an ADR.
EOF
  cat >"$d/docs/adr/0001-scripts-print-with-printf.md" <<'EOF'
# 0001. Scripts print with printf, never echo

Every script in this repository writes its output with `printf`, never with `echo`: `echo` treats leading dashes and backslashes differently from shell to shell, so its output is not portable.

Decision: print with `printf '%s\n' ...`. Do not use `echo` to produce a script's output.
EOF
  cat >"$d/docs/agents/issue-tracker.md" <<'EOF'
# Issue tracker: GitHub

Issues and specs live as GitHub issues; use the `gh` CLI.

- Read an issue: `gh issue view <number> --json number,title,body,labels`.
- A ticket is a sub-issue of its spec; blocking is GitHub's native issue dependency (blocked by). A ticket is unblocked when every blocker is closed.
- Comment, label and close with `gh issue comment`, `gh issue edit`, `gh issue close`.
EOF
  cat >"$d/docs/agents/triage-labels.md" <<'EOF'
# Triage Labels

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |
EOF
  cat >"$d/scripts/check.sh" <<'EOF'
#!/usr/bin/env bash
# The repository's check command: every script in tests/ must pass.
set -euo pipefail
cd "$(dirname "$0")/.."
for t in tests/*.sh; do
  [ -e "$t" ] || continue
  echo "== $t"
  bash "$t"
done
echo "check passed"
EOF
  cat >"$d/.githooks/pre-push" <<'EOF'
#!/usr/bin/env bash
# Runs the check command before every push. The sandbox makes it slow on purpose, so that two merges
# started together overlap and the second has to queue for the first: the pause is SANDBOX_PUSH_DELAY
# seconds (default 45; set it to 0 to push quickly).
sleep "${SANDBOX_PUSH_DELAY:-45}"
exec "$(git rev-parse --show-toplevel)/scripts/check.sh"
EOF
  printf '.factory/\n.claude/worktrees/\n' >"$d/.gitignore"
  chmod +x "$d/scripts/check.sh" "$d/.githooks/pre-push"
}

# ---------------------------------------------------------------- issue bodies
spec_body() {
  cat <<'EOF'
## Problem Statement

The sandbox has no greeter. The factory's release dry run needs a small, real piece of work to build.

## Solution

A shell script, `greet.sh`, that greets the world, a name, and can shout.

## User Stories

1. As a user, I want `./greet.sh` to print a greeting, so that I can see it works.
2. As a user, I want `./greet.sh Ada` to greet by name.
3. As a user, I want `./greet.sh --shout Ada` to greet in capitals.

## Implementation Decisions

- One bash script, `greet.sh`, at the repository root.
- Each behaviour has a test script in `tests/`, run by `scripts/check.sh`.

## Testing Decisions

Tests run `greet.sh` and compare its output; no mocks.

## Out of Scope

Anything beyond three tiny tickets: this is a throwaway.
EOF
}

spec_b_body() {
  cat <<'EOF'
## Problem Statement

The greeter has no way to say goodbye or thanks. The factory's release dry run uses this second spec to prove ticket-level blocking: it is blocked by the first spec as a whole, but two of its tickets are linked to just the first ticket they need, so they may start early.

## Solution

Three small shell scripts: `bye.sh`, `thanks.sh` and `wave.sh`.

## User Stories

1. As a user, I want `./bye.sh` to print a farewell.
2. As a user, I want `./thanks.sh` to print thanks.
3. As a user, I want `./wave.sh` to print a wave.

## Implementation Decisions

- One bash script per behaviour at the repository root, each with its own test script in `tests/`, run by `scripts/check.sh`. The scripts share no files, so their tickets never conflict.

## Testing Decisions

Tests run the script and compare its output; no mocks.

## Out of Scope

Anything beyond three tiny tickets: this is a throwaway.
EOF
}

ticket_body() { # ticket_body <spec> <what> <criteria...>
  local spec=$1 what=$2 c; shift 2
  printf '## Parent\n\n#%s\n\n## What to build\n\n%s\n\n## Acceptance criteria\n\n' "$spec" "$what"
  for c in "$@"; do printf -- '- [ ] %s\n' "$c"; done
}

# ---------------------------------------------------------------- create
cmd_create() {
  local name="" owner="" dir="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name=${2:?}; shift ;;
      --owner) owner=${2:?}; shift ;;
      --dir) dir=${2:?}; shift ;;
      --dry-run) dry=1 ;;
      *) die "create: unknown argument $1" ;;
    esac
    shift
  done
  [ -n "$name" ] || name="factory-sandbox-$(date +%Y%m%d-%H%M%S)"
  [[ "$name" == factory-sandbox-* ]] || die "the repository name must start with factory-sandbox-: $name"
  [ -n "$dir" ] || dir="./$name"
  if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then die "$dir exists and is not empty"; fi

  if [ "$dry" = 1 ]; then
    cat <<EOF
Plan (nothing is created):
  repository  ${owner:-<your gh login>}/$name (private)
  clone       $dir
  labels      needs-triage needs-info ready-for-agent ready-for-human wontfix
  spec        "Spec: sandbox greeter" (labelled ready-for-agent)
  tickets     greet.sh prints a greeting; greet.sh takes a name (blocked by the first);
              greet.sh --shout (blocked by the first two), each a ready-for-agent sub-issue of the spec
  adr         docs/adr/0001: scripts print with printf, never echo (the first ticket tempts an echo)
  spec        "Spec: sandbox farewell", blocked by the first spec as a whole
  tickets     bye.sh and thanks.sh (each blocked only by the first greeter ticket: they start early and
              their merges queue); wave.sh (no links of its own: held by the spec-level link)
EOF
    return 0
  fi

  need git; need gh; need jq
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
  [ -n "$owner" ] || owner=$(gh api user --jq .login)
  [ -n "$owner" ] || die "could not read the gh login; pass --owner"
  local slug="$owner/$name" tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandbox.XXXXXX")
  # shellcheck disable=SC2064 # expand $tmp now
  trap "rm -rf '$tmp'" RETURN

  mkdir -p "$dir"
  dir=$(cd "$dir" && pwd)
  git init -q -b main "$dir"
  seed "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "Sandbox: a greeter project for the factory's dry run"
  gh repo create "$slug" --private --source "$dir" --remote origin --push >/dev/null
  git -C "$dir" config core.hooksPath .githooks

  local label
  for label in needs-triage needs-info ready-for-agent ready-for-human wontfix; do
    gh label create "$label" --force >/dev/null
  done

  local url spec t2 t3 t4 spec_b t6 t7 t8
  spec_body >"$tmp/spec.md"
  url=$(cd "$dir" && gh issue create --title "Spec: sandbox greeter" --body-file "$tmp/spec.md" --label ready-for-agent)
  spec=${url##*/}
  ticket_body "$spec" 'Add `greet.sh` at the repository root. `./greet.sh` prints `Hello, world!` and exits 0 (a one-line `echo` does it). Add `tests/greet.sh`, a test script that runs it and fails when the output differs.' \
    '`./greet.sh` prints `Hello, world!`' '`tests/greet.sh` checks it, and `scripts/check.sh` passes' >"$tmp/t1.md"
  url=$(cd "$dir" && gh issue create --title "greet.sh prints a greeting" --body-file "$tmp/t1.md" --label ready-for-agent --parent "$spec")
  t2=${url##*/}
  ticket_body "$spec" '`greet.sh` takes a name: `./greet.sh Ada` prints `Hello, Ada!`. Without a name it still prints `Hello, world!`. Extend the test.' \
    '`./greet.sh Ada` prints `Hello, Ada!`' 'no argument still prints `Hello, world!`' 'the test covers both, and `scripts/check.sh` passes' >"$tmp/t2.md"
  url=$(cd "$dir" && gh issue create --title "greet.sh takes a name" --body-file "$tmp/t2.md" --label ready-for-agent --parent "$spec" --blocked-by "$t2")
  t3=${url##*/}
  ticket_body "$spec" '`greet.sh --shout` prints the greeting in capitals: `./greet.sh --shout Ada` prints `HELLO, ADA!`; `./greet.sh --shout` prints `HELLO, WORLD!`. Extend the test.' \
    '`./greet.sh --shout Ada` prints `HELLO, ADA!`' '`./greet.sh --shout` prints `HELLO, WORLD!`' 'earlier behaviour is unchanged, the test covers it, and `scripts/check.sh` passes' >"$tmp/t3.md"
  url=$(cd "$dir" && gh issue create --title "greet.sh --shout" --body-file "$tmp/t3.md" --label ready-for-agent --parent "$spec" --blocked-by "$t2,$t3")
  t4=${url##*/}

  # the second spec: blocked by the first as a whole; tickets 6 and 7 are linked only to the first
  # spec's first ticket (so they may start early, and run side by side), ticket 8 has no links of its own
  spec_b_body >"$tmp/specb.md"
  url=$(cd "$dir" && gh issue create --title "Spec: sandbox farewell" --body-file "$tmp/specb.md" --label ready-for-agent --blocked-by "$spec")
  spec_b=${url##*/}
  ticket_body "$spec_b" 'Add `bye.sh` at the repository root: `./bye.sh` prints `Goodbye!` and exits 0. Add `tests/bye.sh`, a test script that runs it and fails when the output differs.' \
    '`./bye.sh` prints `Goodbye!`' '`tests/bye.sh` checks it, and `scripts/check.sh` passes' >"$tmp/t5.md"
  url=$(cd "$dir" && gh issue create --title "bye.sh prints a farewell" --body-file "$tmp/t5.md" --label ready-for-agent --parent "$spec_b" --blocked-by "$t2")
  t6=${url##*/}
  ticket_body "$spec_b" 'Add `thanks.sh` at the repository root: `./thanks.sh` prints `Thank you!` and exits 0. Add `tests/thanks.sh`, a test script that runs it and fails when the output differs.' \
    '`./thanks.sh` prints `Thank you!`' '`tests/thanks.sh` checks it, and `scripts/check.sh` passes' >"$tmp/t6.md"
  url=$(cd "$dir" && gh issue create --title "thanks.sh prints thanks" --body-file "$tmp/t6.md" --label ready-for-agent --parent "$spec_b" --blocked-by "$t2")
  t7=${url##*/}
  ticket_body "$spec_b" 'Add `wave.sh` at the repository root: `./wave.sh` prints `o/` and exits 0. Add `tests/wave.sh`, a test script that runs it and fails when the output differs.' \
    '`./wave.sh` prints `o/`' '`tests/wave.sh` checks it, and `scripts/check.sh` passes' >"$tmp/t7.md"
  url=$(cd "$dir" && gh issue create --title "wave.sh prints a wave" --body-file "$tmp/t7.md" --label ready-for-agent --parent "$spec_b")
  t8=${url##*/}

  cat <<EOF
Sandbox repository: https://github.com/$slug (private)
Local clone:        $dir
Spec #$spec: tickets #$t2 (no blockers; it tempts a decision-review send-back: a one-line echo against ADR 0001),
  #$t3 (blocked by #$t2), #$t4 (blocked by #$t2, #$t3)
Spec #$spec_b (blocked by spec #$spec as a whole): tickets #$t6 and #$t7 (each blocked only by #$t2: they start
  early and side by side, so their two merges into one integration branch must queue), #$t8 (no links of its
  own: the spec-level link holds it for the whole run)

Next:
  1. cd $dir, start Claude Code there with the factory plugin installed, and run /factory start
  2. answer the manager's questions; do NOT approve merging a draft pull request. The pre-push hook pauses
     SANDBOX_PUSH_DELAY seconds (default 45) so the two merges overlap
  3. when it is done (tickets #$t6 and #$t7 merged, #$t8 still held): $self verify --dir $dir --spec $spec --early-spec $spec_b
  4. clean up:        $self destroy --repo $slug --yes
EOF
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  local dir=. spec=1 early=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir=${2:?}; shift ;;
      --spec) spec=${2:?}; shift ;;
      --early-spec) early=${2:?}; shift ;;
      *) die "verify: unknown argument $1" ;;
    esac
    shift
  done
  [[ "$spec" =~ ^[0-9]+$ ]] || die "--spec needs a number, got '$spec'"
  [ -n "$early" ] || early=$((spec + 4))
  [[ "$early" =~ ^[0-9]+$ ]] || die "--early-spec needs a number, got '$early'"
  [ -d "$dir" ] || die "no such directory: $dir"
  need git; need gh; need jq
  cd "$dir"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$dir is not a git repository"
  local project failed=0
  project=$(pwd)
  git fetch -q origin 2>/dev/null || true

  pass() { echo "ok: $1: $2"; }
  flunk() { echo "FAIL: $1: $2"; failed=1; }

  local default=main sym
  sym=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && default=${sym#origin/}

  # spec_tickets <spec>: its sub-issues' numbers, sorted, as a JSON array
  spec_tickets() {
    local issue t
    issue=$(gh issue view "$1" --json number,title,state,subIssues 2>/dev/null) || issue=""
    t=$(jq -c '[(.subIssues.nodes // .subIssues // [])[] | .number] | sort' <<<"${issue:-null}" 2>/dev/null) || t='[]'
    printf '%s' "${t:-[]}"
  }
  # integration_branch <spec>: from the state file, else the spec's branch on origin
  integration_branch() {
    local b refs=()
    b=$(jq -r --arg s "$1" '.integration[$s].branch // empty' .factory/state.json 2>/dev/null || true)
    if [ -z "$b" ]; then
      mapfile -t refs < <(git for-each-ref --format='%(refname:short)' "refs/remotes/origin/spec/$1-*")
      [ ${#refs[@]} -eq 0 ] || b=${refs[0]#origin/}
    fi
    printf '%s' "$b"
  }

  local tickets ntickets etickets ib_b
  tickets=$(spec_tickets "$spec")
  etickets=$(spec_tickets "$early")
  ntickets=$(jq 'length' <<<"$tickets")
  if [ "$ntickets" = 3 ]; then
    pass tickets "spec #$spec has three tickets: $(jq -r 'map("#\(.)") | join(", ")' <<<"$tickets")"
  else
    flunk tickets "spec #$spec has $ntickets tickets, not three"
  fi

  local ib
  ib=$(integration_branch "$spec")
  ib_b=$(integration_branch "$early")

  # ledger: the record of every run, and the order tickets were taken in
  local ledger=.factory/ledger.jsonl problems
  if [ ! -s "$ledger" ]; then
    flunk ledger "no $ledger: the factory wrote none"
    flunk order "cannot tell without the ledger"
  else
    problems=$(jq -s -r --argjson t "$tickets" '
      . as $l
      | ([$l[] | select(.event == "agent_stop")] | length) as $runs
      | [ (if $runs < ($t | length) then "only \($runs) agent run(s) recorded" else empty end),
          ($t[] | . as $n | if ([$l[] | select(.event == "gate" and .result == "pass" and .ticket == $n)] | length) == 0
                  then "no passing gate recorded for #\($n)" else empty end) ] | .[]' "$ledger") || problems="the ledger is not valid JSON lines"
    if [ -z "$problems" ]; then
      pass ledger "agent runs, and a passing gate for every ticket, are recorded"
    else
      flunk ledger "$(tr '\n' ';' <<<"$problems")"
    fi
    problems=$(jq -s -r --argjson t "$tickets" '
      . as $l
      | def at(ev; n): ([range(0; $l | length) | select($l[.].event == ev and $l[.].ticket == n)] | first);
      [ range(0; $t | length) as $k | $t[$k] as $n
        | at("assign"; $n) as $a | at("merge"; $n) as $m
        | if $a == null then "#\($n) was never assigned"
          elif $m == null then "#\($n) was never merged"
          elif $k > 0 and (at("merge"; $t[$k - 1]) // 1e9) > $a then "#\($n) was assigned before #\($t[$k - 1]) merged"
          else empty end ] | .[]' "$ledger") || problems="the ledger is not valid JSON lines"
    if [ -z "$problems" ]; then
      pass order "tickets were assigned in frontier order, each after its blocker merged"
    else
      flunk order "$(tr '\n' ';' <<<"$problems")"
    fi

    # the decision review: a ticket's gate passed, was sent back (a failure after the pass), and passed again
    problems=$(jq -s -r --argjson t "$tickets" '
      . as $l
      | [ $t[] | . as $n | [$l[] | select(.event == "gate" and .ticket == $n) | .result] | join(",")
          | select(test("pass,([a-z]+,)*fail,([a-z]+,)*pass$")) ] | length
      | if . > 0 then empty else "no ticket of the spec was sent back after a passing check and then passed again" end' "$ledger") || problems="the ledger is not valid JSON lines"
    if [ -z "$problems" ]; then
      pass review "a ticket was sent back after its check passed (the decision review) and passed again"
    else
      flunk review "$problems: the decision review's send-back was not exercised. The first ticket tempts a one-line echo against ADR 0001 (printf only); run the dry run again, or send a ticket back by hand"
    fi

    # honest KPIs: the sent-back ticket is rework and is not first-try
    local kpis_bin k
    kpis_bin="$(dirname "$self")/../plugins/factory/bin/factory-kpis"
    if [ -x "$kpis_bin" ] && k=$(CLAUDE_PROJECT_DIR="$project" "$kpis_bin" --json 2>/dev/null) &&
      jq -e '(.quality.first_try_gate_pass_rate // 1) < 1 and any(.quality.rework_by_ticket[]?; .review_send_backs >= 1)' <<<"$k" >/dev/null 2>&1; then
      pass kpis "the first-try gate pass rate is below 100% and the send-back is counted as rework"
    else
      flunk kpis "factory-kpis does not show the send-back: first-try rate below 100% and review_send_backs for the ticket"
    fi

    # ticket-level blocking: the second spec is blocked by the first as a whole; its tickets linked to
    # ticket $tickets[0] only start once that is merged, long before the first spec is done; the ticket
    # with no link of its own is held by the spec-level link and never starts
    if [ "$(jq length <<<"$etickets")" != 3 ]; then
      flunk early "spec #$early has $(jq length <<<"$etickets") tickets, not three (pass --early-spec)"
      flunk held "spec #$early has $(jq length <<<"$etickets") tickets, not three (pass --early-spec)"
      flunk queue "spec #$early has $(jq length <<<"$etickets") tickets, not three (pass --early-spec)"
    else
      problems=$(jq -s -r --argjson a "$tickets" --argjson e "$etickets" '
        . as $l
        | def at(ev; n): ([range(0; $l | length) | select($l[.].event == ev and $l[.].ticket == n)] | first);
        [ $e[0:2][] as $n | at("assign"; $n) as $s
          | if $s == null then "#\($n) was never assigned"
            elif $s < (at("merge"; $a[0]) // 1e9) then "#\($n) was assigned before #\($a[0]) merged"
            elif $s > (at("merge"; $a[-1]) // 1e9) then "#\($n) was assigned only after the whole of spec #\($a | length) tickets merged: its own link did not let it start early"
            else empty end ] | .[]' "$ledger") || problems="the ledger is not valid JSON lines"
      if [ -z "$problems" ]; then
        pass early "tickets $(jq -r '.[0:2] | map("#\(.)") | join(" and ")' <<<"$etickets") started once #$(jq -r '.[0]' <<<"$tickets") merged, before spec #$spec was done"
      else
        flunk early "$(tr '\n' ';' <<<"$problems")"
      fi
      problems=$(jq -s -r --argjson e "$etickets" '
        . as $l | $e[2] as $n
        | if ([$l[] | select(.ticket == $n and (.event == "assign" or .event == "merge"))] | length) > 0
          then "#\($n) has no link of its own and must stay held by the spec-level link, but the ledger shows it assigned or merged" else empty end' "$ledger") || problems="the ledger is not valid JSON lines"
      if [ -z "$problems" ]; then
        pass held "#$(jq -r '.[2]' <<<"$etickets") has no link of its own and stayed held by the spec-level link"
      else
        flunk held "$problems"
      fi
      # two merges into one integration branch started together: both merged, the second waited for the first
      problems=$(jq -s -r --argjson e "$etickets" '
        [.[] | select(.event == "merge" and (.ticket as $t | $e[0:2] | index($t)))] as $m
        | if ($m | length) != 2 or ($m | any(.result != "merged")) then "the merge events of #\($e[0]) and #\($e[1]) are not both recorded as merged"
          elif (($m[1].waited_s // 0) | . > 0 | not) then "the second merge (#\($m[1].ticket)) did not wait for the first: the merges did not overlap, so the queue was not exercised (the pre-push hook pauses SANDBOX_PUSH_DELAY seconds; start both merges together)"
          elif ($m[1].duration_s // 0) < $m[1].waited_s then "the second merge records a duration shorter than its wait"
          else empty end' "$ledger") || problems="the ledger is not valid JSON lines"
      if [ -z "$problems" ]; then
        local bmerged
        bmerged=$(git log --first-parent --merges --format='%s' "origin/${ib_b:-none}" "^origin/$default" 2>/dev/null |
          sed -n 's/^.*(#\([0-9]*\))$/\1/p' | jq -R -s -c 'split("\n") | map(select(. != "") | tonumber) | sort')
        [ "$bmerged" = "$(jq -c '.[0:2] | sort' <<<"$etickets")" ] || problems="${ib_b:-the integration branch of spec #$early} has merges for ${bmerged:-none}, wanted both early tickets $(jq -c '.[0:2]' <<<"$etickets")"
      fi
      if [ -z "$problems" ]; then
        pass queue "two merges into one integration branch were started together: the second waited for the first, both merged"
      else
        flunk queue "$problems"
      fi
    fi
  fi

  # clean-up through Claude Code's worktree locks: no ticket branch (here or on origin), no merge lock left
  local left=() n b
  for n in $(jq -r '.[]' <<<"$tickets") $(jq -r '.[]' <<<"$etickets"); do
    while IFS= read -r b; do [ -z "$b" ] || left+=("local branch $b"); done < <(git for-each-ref --format='%(refname:short)' "refs/heads/t$n-*")
    while IFS= read -r b; do [ -z "$b" ] || left+=("origin branch ${b#refs/heads/}"); done < <(git ls-remote --heads origin "t$n-*" 2>/dev/null | cut -f2)
  done
  while IFS= read -r b; do [ -z "$b" ] || left+=("merge lock ${b#"$project"/}"); done < <(find "$project/.factory/locks" -type f -name 'q*' 2>/dev/null)
  if [ ${#left[@]} -eq 0 ]; then
    pass cleanup "no ticket worktree, branch or merge lock was left behind"
  else
    flunk cleanup "left behind: $(IFS=';'; echo "${left[*]}")"
  fi

  # the integration branch: three --no-ff ticket merges, in order, and no worktree left behind
  if [ -z "$ib" ] || ! git rev-parse -q --verify "refs/remotes/origin/$ib" >/dev/null; then
    flunk merged "no integration branch for spec #$spec on origin"
    flunk worktrees "no integration branch to check"
    flunk report "no integration branch to check"
  else
    local merges merged_order want
    merges=$(git log --first-parent --merges --reverse --format='%P|%s' "origin/$ib" "^origin/$default")
    merged_order=$(sed -n 's/^[0-9a-f]* [0-9a-f]*|.*(#\([0-9]*\))$/\1/p' <<<"$merges" | jq -R -s -c 'split("\n") | map(select(. != "") | tonumber)')
    want=$tickets
    if [ "$merged_order" = "$want" ]; then
      pass merged "$ib has a merge commit per ticket, in order: $(jq -r 'map("#\(.)") | join(", ")' <<<"$merged_order")"
    else
      flunk merged "$ib has merges for $merged_order, wanted $want, each a two-parent merge"
    fi

    local wt_main wt_int wt_all stray=() p
    wt_int=$(jq -r --arg s "$spec" '.integration[$s].worktree // empty' .factory/state.json 2>/dev/null || true)
    wt_all=$(jq -r '[.integration[]?.worktree // empty] | .[]' .factory/state.json 2>/dev/null || true)
    wt_main=$(git rev-parse --show-toplevel)
    while IFS= read -r p; do
      [ "$p" = "$wt_main" ] || grep -qxF -- "$p" <<<"$wt_all" || stray+=("$p")
    done < <(git worktree list --porcelain | sed -n 's/^worktree //p')
    if [ -z "$wt_int" ]; then
      flunk worktrees "no integration worktree recorded in .factory/state.json"
    elif [ ! -d "$wt_int" ]; then
      flunk worktrees "the integration worktree $wt_int is gone"
    elif [ ${#stray[@]} -gt 0 ]; then
      flunk worktrees "worktrees left behind: ${stray[*]}"
    else
      pass worktrees "tickets merged from their own branches; only the integration worktree remains"
    fi

    local report="docs/factory/reports/${ib#*/}.md"
    if git cat-file -e "origin/$ib:$report" 2>/dev/null; then
      pass report "$report is committed on $ib"
    else
      flunk report "$report is not on $ib"
    fi
  fi

  # the pull request: one, draft, closing the spec and its tickets; and nothing merged
  local prs npr pr state=""
  prs=$(cd "$project" && gh pr list --head "${ib:-none}" --state all --json number,isDraft,state,url,baseRefName,body 2>/dev/null) || prs='[]'
  npr=$(jq 'length' <<<"$prs" 2>/dev/null || echo 0)
  if [ "$npr" != 1 ]; then
    flunk pr "$npr pull requests from ${ib:-the integration branch}, wanted one"
  else
    pr=$(jq -c '.[0]' <<<"$prs")
    state=$(jq -r '.state' <<<"$pr")
    local missing
    missing=$(jq -r --argjson t "$tickets" --argjson s "$spec" '
      .body as $b | ([$s] + $t)[] | . as $n
      | select(($b | test("(^|\n)(Closes|Fixes|Resolves) #\($n)([^0-9]|$)")) | not) | "#\($n)"' <<<"$pr" | tr '\n' ' ')
    if [ "$(jq -r '.isDraft' <<<"$pr")" != true ]; then
      flunk pr "pull request #$(jq -r .number <<<"$pr") is not a draft"
    elif [ -n "$missing" ]; then
      flunk pr "its body does not close: $missing"
    else
      pass pr "draft pull request #$(jq -r .number <<<"$pr") ($(jq -r .url <<<"$pr")) closes the spec and its tickets"
    fi
  fi
  if [ "$state" = MERGED ]; then
    flunk asked "the pull request is merged: the factory must ask first"
  elif [ -n "$ib" ] && git rev-parse -q --verify "refs/remotes/origin/$ib" >/dev/null &&
    git merge-base --is-ancestor "origin/$ib" "origin/$default"; then
    flunk asked "origin/$default already contains $ib: it was merged without asking"
  elif [ -n "$ib_b" ] && git rev-parse -q --verify "refs/remotes/origin/$ib_b" >/dev/null &&
    git merge-base --is-ancestor "origin/$ib_b" "origin/$default"; then
    flunk asked "origin/$default already contains $ib_b: it was merged without asking"
  else
    pass asked "the pull request is unmerged and $default does not contain the integration branch"
  fi

  echo
  echo "Confirm by eye, in the session (this script sees only the repository): the manager asked before merging;"
  echo "each merge was a background command with no wait of its own (no sleep, pgrep or lock loop written by the manager);"
  echo "the decision review's finding named ADR 0001 and quoted its line; the early tickets' merges were not started by an agent."
  if [ "$failed" = 0 ]; then
    echo "sandbox verify passed"
  else
    echo "sandbox verify failed"
    return 1
  fi
}

# ---------------------------------------------------------------- destroy
cmd_destroy() {
  local repo="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=${2:?}; shift ;;
      --yes) yes=1 ;;
      *) die "destroy: unknown argument $1" ;;
    esac
    shift
  done
  [[ "$repo" == */* ]] || die "destroy needs --repo OWNER/NAME"
  [[ "${repo##*/}" == factory-sandbox-* ]] || die "refusing to delete $repo: only repositories named factory-sandbox-* are deleted"
  [ "$yes" = 1 ] || die "deleting $repo cannot be undone; pass --yes"
  need gh
  gh repo delete "$repo" --yes
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
