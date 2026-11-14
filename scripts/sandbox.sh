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
      pre-push hook), the triage labels, and one spec of three tickets:
        #2 greet.sh prints a greeting        (no blockers)
        #3 greet.sh takes a name             (blocked by #2)
        #4 greet.sh --shout                  (blocked by #2 and #3)
      cloned to DIR (default ./NAME). --dry-run prints the plan and calls nothing.
      Needs gh 2.94+ (sub-issues and blocked-by) authenticated, git and jq.
  scripts/sandbox.sh verify [--dir DIR] [--spec N]
      After a factory run in DIR (default .), check it against the spec's acceptance criteria:
      tickets taken in frontier order, worktrees used and removed, every ticket merged into the
      integration branch, ledger written, spec report committed, one draft pull request closing the
      spec and its tickets, and nothing merged to the default branch. Exit 0 when all hold.
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
  mkdir -p "$d/docs/agents" "$d/scripts" "$d/tests" "$d/.githooks"
  cat >"$d/CLAUDE.md" <<'EOF'
## Checks

Run `scripts/check.sh` before every commit. The pre-push hook runs it too (enable once per clone: `git config core.hooksPath .githooks`). Never skip the hook.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues on this repository (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root.
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
# Runs the check command before every push.
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

  local url spec t2 t3 t4
  spec_body >"$tmp/spec.md"
  url=$(cd "$dir" && gh issue create --title "Spec: sandbox greeter" --body-file "$tmp/spec.md" --label ready-for-agent)
  spec=${url##*/}
  ticket_body "$spec" 'Add `greet.sh` at the repository root. `./greet.sh` prints `Hello, world!` and exits 0. Add `tests/greet.sh`, a test script that runs it and fails when the output differs.' \
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

  cat <<EOF
Sandbox repository: https://github.com/$slug (private)
Local clone:        $dir
Spec #$spec, tickets #$t2 (no blockers), #$t3 (blocked by #$t2), #$t4 (blocked by #$t2, #$t3)

Next:
  1. cd $dir, start Claude Code there with the factory plugin installed, and run /factory start
  2. answer the manager's questions; do NOT approve merging the draft pull request
  3. when it is done: $self verify --dir $dir --spec $spec
  4. clean up:        $self destroy --repo $slug --yes
EOF
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  local dir=. spec=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir=${2:?}; shift ;;
      --spec) spec=${2:?}; shift ;;
      *) die "verify: unknown argument $1" ;;
    esac
    shift
  done
  [[ "$spec" =~ ^[0-9]+$ ]] || die "--spec needs a number, got '$spec'"
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

  local issue tickets ntickets
  issue=$(gh issue view "$spec" --json number,title,state,subIssues 2>/dev/null) || issue=""
  tickets=$(jq -c '[(.subIssues.nodes // .subIssues // [])[] | .number] | sort' <<<"${issue:-null}" 2>/dev/null) || tickets='[]'
  [ -n "$tickets" ] || tickets='[]'
  ntickets=$(jq 'length' <<<"$tickets")
  if [ "$ntickets" = 3 ]; then
    pass tickets "spec #$spec has three tickets: $(jq -r 'map("#\(.)") | join(", ")' <<<"$tickets")"
  else
    flunk tickets "spec #$spec has $ntickets tickets, not three"
  fi

  local ib
  ib=$(jq -r --arg s "$spec" '.integration[$s].branch // empty' .factory/state.json 2>/dev/null || true)
  if [ -z "$ib" ]; then
    local refs=()
    mapfile -t refs < <(git for-each-ref --format='%(refname:short)' "refs/remotes/origin/spec/$spec-*")
    [ ${#refs[@]} -eq 0 ] || ib=${refs[0]#origin/}
  fi

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

    local wt_main wt_int stray=() p
    wt_int=$(jq -r --arg s "$spec" '.integration[$s].worktree // empty' .factory/state.json 2>/dev/null || true)
    wt_main=$(git rev-parse --show-toplevel)
    while IFS= read -r p; do
      [ "$p" = "$wt_main" ] || [ "$p" = "$wt_int" ] || stray+=("$p")
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
  else
    pass asked "the pull request is unmerged and $default does not contain the integration branch"
  fi

  echo
  echo "Confirm by eye: the manager asked before merging, in the session (this script sees only the repository)."
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
