#!/usr/bin/env bash
# shellcheck disable=SC2016 # commands under test are single-quoted on purpose
# Suite: guard-bash blocks the known-dangerous commands with an actionable reason, asks before
# outward git and gh commands, and lets look-alikes pass. Run with recorded hook input.
set -euo pipefail
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
here="$(cd "$(dirname "$0")" && pwd)"
hook="$here/../../plugins/factory/hooks/guard-bash.sh"
fx="$here/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guard-bash.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*"; exit 1; }

# Two repositories: trunk has default branch main (checked out), dev has default branch develop
# (a feature branch is checked out). The hook reads origin/HEAD to learn the default branch.
mkrepo() { # mkrepo <dir> <default> <current>
  git init -q -b "$2" "$1"
  git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$1" update-ref "refs/remotes/origin/$2" HEAD
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$2"
  [ "$2" = "$3" ] || git -C "$1" checkout -q -b "$3"
}
mkrepo "$tmp/trunk" main main
mkrepo "$tmp/dev" develop t8-feature
mkdir -p "$tmp/plain"
printf '## Checks\n\nRun `./gate --all` as the check before every commit.\n' >"$tmp/plain/CLAUDE.md"

# run_fixture <file> [cwd]: sets $code, $out, $err
run_fixture() {
  code=0
  out=$(cd "${2:-$tmp/trunk}" && CLAUDE_PROJECT_DIR="${2:-$tmp/trunk}" "$hook" <"$1" 2>"$tmp/err") || code=$?
  err=$(cat "$tmp/err")
}
# run_cmd <command> [cwd]: the recorded envelope with the command (and cwd) swapped in
run_cmd() {
  local cwd=${2:-$tmp/trunk}
  jq --arg c "$1" --arg d "$cwd" '.tool_input.command = $c | .cwd = $d' "$fx/bash-call.json" >"$tmp/in.json"
  run_fixture "$tmp/in.json" "$cwd"
}
# block <command> <reason-substring> [cwd]
block() {
  run_cmd "$1" "${3:-}"
  [ "$code" = 2 ] || fail "should block: $1 (exit $code, out: $out, err: $err)"
  [[ "$err" == *"$2"* ]] || fail "reason for '$1' lacks '$2': $err"
  [ -z "$out" ] || fail "a block prints nothing on stdout: $out"
  pass=$((pass + 1))
}
# ask <command> <reason-substring> [cwd]
ask() {
  run_cmd "$1" "${3:-}"
  [ "$code" = 0 ] || fail "should ask, not block: $1 (exit $code, err: $err)"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "ask"' \
    <<<"$out" >/dev/null 2>&1 || fail "should ask: $1 (out: $out)"
  [[ "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" == *"$2"* ]] || fail "ask reason for '$1' lacks '$2': $out"
  pass=$((pass + 1))
}
# allow <command> [cwd]
allow() {
  run_cmd "$1" "${2:-}"
  [ "$code" = 0 ] || fail "should allow: $1 (exit $code, err: $err)"
  [ -z "$out" ] || fail "should allow silently: $1 (out: $out)"
  pass=$((pass + 1))
}

# --- recorded inputs, run as recorded ---
run_fixture "$fx/no-verify.json"
[ "$code" = 2 ] && [[ "$err" == *"--no-verify"* ]] || fail "recorded no-verify: $code $err"
pass=$((pass + 1))
run_fixture "$fx/force-push-main.json"
[ "$code" = 2 ] && [[ "$err" == *"main"* ]] || fail "recorded force-push: $code $err"
pass=$((pass + 1))
run_fixture "$fx/piped-tail.json"
[ "$code" = 2 ] && [[ "$err" == *"pipefail"* ]] || fail "recorded piped-tail: $code $err"
pass=$((pass + 1))
run_fixture "$fx/tail-log.json"; [ "$code" = 0 ] && [ -z "$out" ] || fail "recorded tail-log: $code $out $err"
pass=$((pass + 1))
run_fixture "$fx/commit-heredoc.json"; [ "$code" = 0 ] && [ -z "$out" ] || fail "recorded commit-heredoc: $code $out $err"
pass=$((pass + 1))
run_fixture "$fx/gh-pr-merge.json"
[ "$code" = 0 ] && [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" = ask ] || fail "recorded gh pr merge: $code $out"
pass=$((pass + 1))
run_fixture "$fx/agent-call.json"; [ "$code" = 0 ] && [ -z "$out" ] || fail "non-Bash tool is ignored: $code $out"
pass=$((pass + 1))
run_fixture "$fx/malformed.json"
[ "$code" = 0 ] && [[ "$err" == *"warning"* ]] || fail "malformed input fails open with a warning: $code $err"
pass=$((pass + 1))
code=0; err=$(printf '' | "$hook" 2>&1 >/dev/null) || code=$?
[ "$code" = 0 ] && [[ "$err" == *"warning"* ]] || fail "empty input fails open with a warning: $code $err"
pass=$((pass + 1))

# --- --no-verify and git commit -n ---
block 'git commit --no-verify -m "x"' '--no-verify'
block 'git commit -m "x" --no-verify' '--no-verify'
block 'git commit -n -m x' '--no-verify'
block 'git commit -nm x' '--no-verify'
block 'git commit -anm x' '--no-verify'
block 'git push --no-verify origin spec/1-x' '--no-verify'
block 'git -C /tmp/p push --no-verify' '--no-verify'
block 'git merge --no-verify topic' '--no-verify'
block 'git commit "--no-verify" -m x' '--no-verify'
block 'cd sub && git commit -m x && git push --no-verify' '--no-verify'
block 'FOO=1 git commit --no-verify -m x' '--no-verify'
block 'bash -c '"'"'git commit --no-verify -m x'"'" '--no-verify'
block 'timeout 60 git push --no-verify' '--no-verify'
block 'git commit -m "$(date)" --no-verify' '--no-verify'
block 'git commit -m x
git push --no-verify' '--no-verify'
block 'if true; then git commit -n -m x; fi' '--no-verify'
block '(git commit --no-verify -m x)' '--no-verify'
# the reason tells the agent what to do instead
block 'git push --no-verify' 'fix what the hook reports'

# --- core.hooksPath override ---
block 'git -c core.hooksPath=/dev/null push origin x' 'core.hooksPath'
block 'git -c core.hooksPath= commit -m x' 'core.hooksPath'
block 'git -c CORE.HOOKSPATH=/tmp/empty commit -m x' 'core.hooksPath'
block 'git config core.hooksPath /dev/null' 'core.hooksPath'
block 'git config --local core.hooksPath ../elsewhere' 'core.hooksPath'
block 'git config --global core.hooksPath .githooks' 'core.hooksPath'
block 'git config core.hooksPath ""' 'core.hooksPath'
block 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp git push' 'core.hooksPath'
block 'git -c core.hooksPath=/dev/null push origin x' 'run the hook'

# --- force-push to the default branch ---
block 'git push --force origin main' 'main'
block 'git push -f origin master' 'master'
block 'git push --force-with-lease origin HEAD:main' 'main'
block 'git push --force-with-lease=main:abc123 origin main' 'main'
block 'git push origin +main' 'main'
block 'git push origin +HEAD:refs/heads/main' 'main'
block 'git push -uf origin main' 'main'
block 'git push origin main --force' 'main'
block 'git -C /somewhere push -f origin main' 'main'
block 'cd x && git push --force origin main' 'main'
block 'git push -f' 'main' "$tmp/trunk"
block 'git push --force origin' 'main' "$tmp/trunk"
block 'git push --force --all' 'main'
block 'git push --mirror' 'main'
block 'git push -f origin develop' 'develop' "$tmp/dev"
block 'git push --force origin t8-x:main' 'main'
block 'git push origin --delete main' 'main'
block 'git push origin :main' 'main'
block 'git push --force origin main' 'git push --force-with-lease origin <feature-branch>'

# --- check or push piped into head or tail without pipefail ---
block 'scripts/check.sh | tail -n 20' 'pipefail'
block 'scripts/check.sh 2>&1 | tail -20' 'pipefail'
block 'bash scripts/check.sh 2>&1 | tail' 'pipefail'
block './scripts/check.sh |& tail -n 5' 'pipefail'
block 'git push origin spec/1-x 2>&1 | tail -n 5' 'pipefail'
block 'git push origin spec/1-x | head -3' 'pipefail'
block 'cargo test 2>&1 | head -50' 'pipefail'
block 'cargo build --release 2>&1 | tail' 'pipefail'
block 'npm test 2>&1 | tail -n 30' 'pipefail'
block 'npm run lint | tail' 'pipefail'
block 'make check | tail' 'pipefail'
block 'pytest -x | head' 'pipefail'
block 'shellcheck scripts/*.sh | tail' 'pipefail'
block 'claude plugin validate . | head' 'pipefail'
block 'scripts/check.sh 2>&1 | tee check.log | tail -n 5' 'pipefail'
block 'cd /x && scripts/check.sh | tail' 'pipefail'
block 'bash tests/guard-bash/run.sh | tail' 'pipefail'
block './gate --all 2>&1 | tail' 'pipefail' "$tmp/plain"
block 'bash gate --all | head' 'pipefail' "$tmp/plain"
block 'scripts/check.sh | tail' 'redirect'

# --- allowed look-alikes ---
allow 'tail -n 100 build.log'
allow 'tail -f /tmp/build.log'
allow 'head -20 README.md'
allow 'cat build.log | tail -n 20'
allow 'git log --oneline | head -5'
allow 'ls -la | head'
allow 'grep -n error out.log | tail -n 5'
allow 'cargo test > out.log 2>&1; tail -n 40 out.log'
allow 'scripts/check.sh > check.log 2>&1; echo "exit $?"; tail -n 40 check.log'
allow 'set -o pipefail; scripts/check.sh | tail -n 20'
allow 'set -euo pipefail && scripts/check.sh 2>&1 | tail'
allow 'bash -o pipefail -c '"'"'scripts/check.sh | tail'"'"
allow 'scripts/check.sh | tee check.log'
allow 'scripts/check.sh 2>&1 | grep FAILED'
allow './gate --all' "$tmp/plain"
allow './gate2 --all | tail' "$tmp/plain"
allow 'make verify'
allow 'npm test'
allow 'git commit -m "document why --no-verify is blocked"'
allow 'git commit -m "fix -n handling"'
allow 'git commit -m x -S'
allow 'git commit -am "wip"'
allow 'echo "--no-verify"'
allow 'echo git push --force origin main'
allow 'grep -rn -- --no-verify docs/'
allow 'git grep -- --no-verify'
allow 'git commit -m x # --no-verify'
allow 'git push -n origin spec/1-x'
allow 'git push --dry-run origin t8-x'
allow 'git log -n 5'
allow 'git config core.hooksPath'
allow 'git config --get core.hooksPath'
allow 'git config --unset core.hooksPath'
allow 'git config core.hooksPath .githooks'
allow 'git config --local core.hooksPath .githooks'
allow 'git push --force-with-lease origin t8-feature'
allow 'git push -f origin t8-feature' "$tmp/dev"
allow 'git push -f' "$tmp/dev"
allow 'git push --force origin main-fix'
allow 'git push -u origin spec/1-the-factory'
allow 'git push origin HEAD:refs/heads/ticket/8-x'
allow 'git branch -f t8-x HEAD~1'
allow 'git status && git diff | head -40'

# --- outward steps: always ask ---
ask 'gh pr merge 12 --squash' 'gh pr merge'
ask 'gh pr merge' 'gh pr merge'
ask 'gh pr merge 3 -R o/r' 'gh pr merge'
ask 'gh -R o/r pr merge 3' 'gh pr merge'
ask 'cd x && gh pr merge 1 --auto' 'gh pr merge'
ask 'gh release create v0.1.0 --notes x' 'gh release'
ask 'gh release delete v0.1.0' 'gh release'
ask 'gh release upload v0.1.0 dist.zip' 'gh release'
ask 'git tag v0.1.0' 'git tag'
ask 'git tag -a v0.1.0 -m "release"' 'git tag'
ask 'git tag -d v0.1.0' 'git tag'
ask 'git -C /p tag v1' 'git tag'
ask 'git push origin main' 'default branch'
ask 'git push origin HEAD:main' 'default branch'
ask 'git push origin t8-x:refs/heads/main' 'default branch'
ask 'git push -u origin master' 'default branch'
ask 'git push' 'default branch' "$tmp/trunk"
ask 'git push origin' 'default branch' "$tmp/trunk"
ask 'git push origin develop' 'develop' "$tmp/dev"
ask 'git push --tags' 'tag'
ask 'git push origin refs/tags/v1.0.0' 'tag'
ask 'git push origin main && echo done' 'default branch'
ask 'git push origin main' 'outward'

# --- ask look-alikes pass ---
allow 'gh pr view 12'
allow 'gh pr list --state open'
allow 'gh pr create --draft --title x --body y'
allow 'gh pr checks 12'
allow 'gh pr diff 12'
allow 'gh release list'
allow 'gh release view v0.1.0'
allow 'gh release download v0.1.0'
allow 'git tag'
allow 'git tag -l'
allow 'git tag --list "v*"'
allow 'git tag -n'
allow 'git tag --contains HEAD'
allow 'git tag --points-at HEAD'
allow 'git push origin spec/1-the-factory-manager'
allow 'git push origin main-fix'
allow 'git push origin t8-x:t8-x'
allow 'git push' "$tmp/dev"
allow 'echo "gh pr merge"'
allow 'git log --oneline main..HEAD'
allow 'git merge origin/main'
allow 'git checkout main'

# --- a block outranks an ask ---
block 'git push --force origin main && gh pr merge 1' 'main'

echo "guard-bash suite passed ($pass checks)"
