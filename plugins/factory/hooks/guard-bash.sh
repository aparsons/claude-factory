#!/usr/bin/env bash
# shellcheck disable=SC2016 # '$(' is literal text being matched, not an expansion
# shellcheck disable=SC1003 # a lone backslash in single quotes is a character to match, not an escaped quote
# guard-bash: PreToolUse hook on the Bash tool. Two jobs, both read from the command text:
#
#   BLOCK (exit 2, reason on stderr, which Claude sees and can act on):
#     - --no-verify, and git commit -n: skipping the repository's git hooks
#     - a core.hooksPath override: -c core.hooksPath=..., GIT_CONFIG_KEY_n=core.hooksPath, or
#       git config core.hooksPath <elsewhere> (a relative path in the repository's own config,
#       such as the documented `git config core.hooksPath .githooks`, is allowed)
#     - a force-push (or delete) of the default branch
#     - a check or a push piped into head or tail without pipefail (the pipe's status is
#       tail's, so a failing check looks like success)
#   ASK (exit 0, permissionDecision "ask" on stdout, so the user is prompted even in auto mode):
#     - gh pr merge, gh release (except list, view, download), git tag (except listing),
#       a push to the default branch, a push of tags
#     These are the plugin's `ask` rules. A plugin cannot ship permissions.ask in its own
#     settings (only `agent` and `subagentStatusLine` take effect from a plugin), so they are
#     returned from this hook, which Claude Code honours in auto mode. A block outranks an ask.
#
# The command is split into simple commands the way a shell does (quotes, $(...), heredocs,
# comments, ; && || | |& & and newlines), and each is judged on its words, so a look-alike
# in a quoted message, a log file name or a comment does not trigger. It reads text, not
# intent: README lists the forms it cannot catch.
#
# Anything it cannot read fails OPEN with a warning on stderr: this is a safety net for known
# mistakes, not a security boundary, and a guard that blocks on its own bug stops all work.
# Test seam: none needed; the default branch is read from the repository (origin/HEAD).
set -euo pipefail

warn() { echo "guard-bash: warning: $*" >&2; }

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
# shellcheck disable=SC1091 # lib/common.sh, checked on its own
. "$root/lib/common.sh"

input=$(cat)
tool="" cwd="" cmd=""
if ! { IFS= read -r -d $'\x1f' tool && IFS= read -r -d $'\x1f' cwd && IFS= read -r -d $'\x1f' cmd; } < <(
  jq -j 'if type == "object" then [(.tool_name // ""), (.cwd // ""), ((.tool_input.command // "") | tostring)] | join("\u001f") + "\u001f" else error("not an object") end' \
    <<<"$input" 2>/dev/null
); then
  warn "hook input is not a JSON object with a Bash command; allowing the call"
  exit 0
fi
[ "$tool" = Bash ] || exit 0
# Fast path: nothing here can match without one of these words or a pipe.
case "$cmd" in
  *git* | *gh* | *'|'* | *sh* | *eval*) ;;
  *) exit 0 ;;
esac
[ -n "$cwd" ] || cwd=$PWD

BLOCKS=()
ASKS=()
PIPEFAIL=0

# ---- tokenizer ---------------------------------------------------------------------------
# strip_heredocs <text>: drops heredoc bodies and their terminator lines, so message text is
# never read as commands.
strip_heredocs() {
  awk '
    skipping { l = $0; sub(/^\t+/, "", l); if (l == delim) skipping = 0; next }
    {
      print
      if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        if (substr($0, RSTART - 1, 1) != "<" && substr($0, RSTART + 2, 1) != "<") {
          d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", d); gsub(/["\047]/, "", d)
          delim = d; skipping = 1
        }
      }
    }' <<<"$1"
}

# tokenize <text>: fills TOK (words, quotes removed), CSTART/CLEN (each simple command's slice
# of TOK) and CSEP (the operator after it: | |& && || ; &).
TOK=() CSTART=() CLEN=() CSEP=()
tokenize() {
  local s i=0 n c nx prev="" mode word="" has=0 sub=0
  local -a stack=() cur=()
  s=$(strip_heredocs "$1")
  n=${#s}
  TOK=() CSTART=() CLEN=() CSEP=()
  flush() { if [ "$has" = 1 ]; then cur+=("$word"); fi; word="" has=0; }
  endcmd() { # endcmd <sep>
    flush
    if [ ${#cur[@]} -gt 0 ]; then
      CSTART+=("${#TOK[@]}") CLEN+=("${#cur[@]}") CSEP+=("$1")
      TOK+=("${cur[@]}")
      cur=()
    elif [ ${#CSEP[@]} -gt 0 ] && [ "$1" != ";" ]; then
      CSEP[${#CSEP[@]} - 1]=$1
    fi
  }
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    nx=${s:i+1:1}
    mode=""
    [ ${#stack[@]} -gt 0 ] && mode=${stack[${#stack[@]} - 1]}
    case "$mode" in
      s) # single quotes
        if [ "$c" = "'" ]; then
          unset 'stack[${#stack[@]}-1]'
          [ "$sub" -gt 0 ] && word+=$c
        else word+=$c; fi
        ;;
      d) # double quotes
        if [ "$c" = '\' ]; then
          if [ "$sub" -gt 0 ]; then word+="$c$nx"
          else case "$nx" in '"' | '\' | '$' | '`') word+=$nx ;; *) word+="$c$nx" ;; esac; fi
          i=$((i + 1))
        elif [ "$c" = '"' ]; then
          unset 'stack[${#stack[@]}-1]'
          [ "$sub" -gt 0 ] && word+=$c
        elif [ "$c" = '$' ] && [ "$nx" = '(' ]; then
          stack+=(c); sub=$((sub + 1)); word+='$('; i=$((i + 1))
        elif [ "$c" = '`' ]; then
          stack+=(k); sub=$((sub + 1)); word+=$c
        else word+=$c; fi
        ;;
      c | k) # inside $( ), ( ) or backticks: copy raw, keep quotes and parens balanced
        word+=$c
        case "$c" in
          '\') word+=$nx; i=$((i + 1)) ;;
          "'") stack+=(s) ;;
          '"') stack+=(d) ;;
          '`') if [ "$mode" = k ]; then unset 'stack[${#stack[@]}-1]'; sub=$((sub - 1)); else stack+=(k); sub=$((sub + 1)); fi ;;
          '(') [ "$mode" = c ] && stack+=(c) && sub=$((sub + 1)) ;;
          ')') if [ "$mode" = c ]; then unset 'stack[${#stack[@]}-1]'; sub=$((sub - 1)); fi ;;
        esac
        ;;
      *) # top level
        case "$c" in
          ' ' | $'\t') flush ;;
          $'\n') endcmd ";" ;;
          '\')
            if [ "$nx" = $'\n' ]; then i=$((i + 1)); else word+=$nx; has=1; i=$((i + 1)); fi
            ;;
          "'") stack+=(s); has=1 ;;
          '"') stack+=(d); has=1 ;;
          '`') stack+=(k); sub=$((sub + 1)); word+=$c; has=1 ;;
          '$')
            has=1
            if [ "$nx" = '(' ]; then stack+=(c); sub=$((sub + 1)); word+='$('; i=$((i + 1)); else word+=$c; fi
            ;;
          '<' | '>')
            has=1; word+=$c
            if [ "$nx" = '(' ]; then stack+=(c); sub=$((sub + 1)); word+=$nx; i=$((i + 1)); fi
            ;;
          '#')
            if [ "$has" = 0 ]; then
              while [ $((i + 1)) -lt "$n" ] && [ "${s:i+1:1}" != $'\n' ]; do i=$((i + 1)); done
            else word+=$c; fi
            ;;
          ';') endcmd ";" ;;
          '&')
            if [ "$nx" = '&' ]; then endcmd "&&"; i=$((i + 1))
            elif [ "$prev" = '>' ] || [ "$prev" = '<' ] || [ "$nx" = '>' ]; then word+=$c; has=1
            else endcmd "&"; fi
            ;;
          '|')
            if [ "$nx" = '|' ]; then endcmd "||"; i=$((i + 1))
            elif [ "$nx" = '&' ]; then endcmd "|&"; i=$((i + 1))
            else endcmd "|"; fi
            ;;
          '(' | ')') endcmd ";" ;;
          *) word+=$c; has=1 ;;
        esac
        ;;
    esac
    prev=$c
    i=$((i + 1))
  done
  endcmd ";"
}

# ---- helpers -----------------------------------------------------------------------------
lc() { printf '%s' "${1,,}"; }
block() { BLOCKS+=("$1"); }
ask() { ASKS+=("$1"); }

DEFAULTS=""
default_branches() { # main and master, plus origin/HEAD's branch; cached
  if [ -z "$DEFAULTS" ]; then
    local d
    d=$(git -C "$cwd" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
    DEFAULTS=" main master ${d#*/} "
  fi
  printf '%s' "$DEFAULTS"
}
is_default() { [[ "$(default_branches)" == *" $1 "* ]]; }
current_branch() { # current_branch <dir>
  git -C "${1:-$cwd}" symbolic-ref -q --short HEAD 2>/dev/null || true
}

CHECK_CMD="" CHECK_LOADED=0
project_check_command() {
  if [ "$CHECK_LOADED" = 0 ]; then
    local p=${CLAUDE_PROJECT_DIR:-}
    [ -n "$p" ] || p=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
    CHECK_CMD=$(factory_check_command "$p" 2>/dev/null || true)
    CHECK_CMD=${CHECK_CMD#./}
    CHECK_LOADED=1
  fi
  printf '%s' "$CHECK_CMD"
}

# words <slice...>: the command's words minus redirections, leading env assignments and
# wrappers. Sets W (words) and also reports env assignments that override git config.
W=()
words() {
  local -a in=("$@") out=()
  local k=0 t
  while [ "$k" -lt ${#in[@]} ]; do
    t=${in[k]}
    if [[ "$t" =~ ^[0-9]*(\&?>>?|<<?<?|>\&|<\&)$ ]]; then k=$((k + 2)); continue; fi # "> file", "2>> file"
    if [[ "$t" =~ ^[0-9]*(\&?>>?|<<?<?|>\&|<\&). ]]; then k=$((k + 1)); continue; fi  # "2>&1", ">file"
    out+=("$t")
    k=$((k + 1))
  done
  # strip prefix
  k=0
  while [ "$k" -lt ${#out[@]} ]; do
    t=${out[k]}
    if [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      case "$(lc "$t")" in
        git_config_key_*=core.hookspath | git_config_parameters=*core.hookspath*)
          block "git: an environment override of core.hooksPath bypasses the repository's git hooks. Remove it and let git run the hook, then fix what the hook reports." ;;
      esac
      k=$((k + 1)); continue
    fi
    case "$t" in
      '!' | '{' | '}' | if | then | else | elif | do | while | until | time | exec | nohup | sudo | setsid | stdbuf | command | builtin)
        k=$((k + 1)); continue ;;
      env)
        k=$((k + 1))
        while [ "$k" -lt ${#out[@]} ] && [[ "${out[k]}" == -* ]]; do
          case "${out[k]}" in -u | -C | -S) k=$((k + 1)) ;; esac
          k=$((k + 1))
        done
        continue ;;
      timeout)
        k=$((k + 1))
        while [ "$k" -lt ${#out[@]} ] && [[ "${out[k]}" == -* ]]; do
          case "${out[k]}" in -k | -s) k=$((k + 1)) ;; esac
          k=$((k + 1))
        done
        k=$((k + 1)) # the duration
        continue ;;
      nice | ionice)
        k=$((k + 1))
        while [ "$k" -lt ${#out[@]} ] && [[ "${out[k]}" == -* ]]; do
          case "${out[k]}" in -n | -c | -p) k=$((k + 1)) ;; esac
          k=$((k + 1))
        done
        continue ;;
    esac
    break
  done
  W=("${out[@]:k}")
}

# stdin_reader: true when the words are head or tail reading a pipe (no file operand)
stdin_reader() {
  case "${W[0]:-}" in head | tail) ;; *) return 1 ;; esac
  local k=1 t
  while [ "$k" -lt ${#W[@]} ]; do
    t=${W[k]}
    case "$t" in
      --) [ $((k + 1)) -lt ${#W[@]} ] && return 1; break ;;
      -n | -c | -s | --lines | --bytes | --pid | --max-unchanged-stats | --sleep-interval) k=$((k + 1)) ;;
      -*) ;;
      *) return 1 ;;
    esac
    k=$((k + 1))
  done
  return 0
}

# is_check: true when the words (W) run a check, test, lint or build, or push
is_check() {
  local -a w=("${W[@]}")
  local c=${w[0]:-} base line cc sc=""
  [ -n "$c" ] || return 1
  base=${c##*/}
  case "$base" in
    bash | sh | zsh | dash | ksh)
      local k=1 t
      while [ "$k" -lt ${#w[@]} ]; do
        t=${w[k]}
        case "$t" in
          -c) # a command string: any check inside counts
            [ "$k" -lt $((${#w[@]} - 1)) ] && contains_check "${w[k + 1]}" && return 0
            return 1 ;;
          -o | +o | -O) k=$((k + 1)) ;;
          -*) ;;
          *) sc=$t; break ;;
        esac
        k=$((k + 1))
      done
      [ -n "$sc" ] || return 1
      w=("$sc" "${w[@]:k+1}") c=$sc base=${sc##*/}
      ;;
  esac
  line="${w[*]}"
  line=${line#./}
  cc=$(project_check_command)
  if [ -n "$cc" ] && { [ "$line" = "$cc" ] || [[ "$line" == "$cc "* ]]; }; then return 0; fi
  # push
  if [ "$base" = git ]; then
    local k=1
    while [ "$k" -lt ${#w[@]} ] && [[ "${w[k]}" == -* ]]; do
      case "${w[k]}" in -C | -c | --git-dir | --work-tree | --namespace) k=$((k + 1)) ;; esac
      k=$((k + 1))
    done
    [ "${w[k]:-}" = push ] && return 0
    return 1
  fi
  # check scripts
  if [[ "$base" =~ ^(check|tests?|ci|lint|verify|run[-_]tests?)(\.sh)?$ ]] && { [[ "$c" == */* ]] || [ -n "$sc" ]; }; then return 0; fi
  if [[ "$c" =~ (^|/)tests?/.*\.sh$ ]]; then return 0; fi
  case "$base" in
    pytest | tox | nox | shellcheck | eslint | tsc | rspec | jest | vitest | mypy | ruff | golangci-lint | pre-commit) return 0 ;;
    cargo | go | npm | pnpm | yarn | bun | deno | dotnet | mvn | gradle | gradlew | mix | bundle | rake | make | just | uv | poetry | bazel)
      local k=1
      while [ "$k" -lt ${#w[@]} ]; do
        case "${w[k]}" in test | tests | check | lint | clippy | build | verify | ci | nextest | vet | typecheck | validate) return 0 ;; esac
        k=$((k + 1))
      done
      return 1 ;;
    claude)
      [ "${w[1]:-}" = plugin ] && [ "${w[2]:-}" = validate ] && return 0
      return 1 ;;
  esac
  return 1
}

contains_check() { # contains_check <command string>: any simple command in it is a check
  local depth=${GUARD_DEPTH:-0}
  [ "$depth" -lt 3 ] || return 1
  local -a tok cs cl
  local found=1 j
  tokenize "$1"
  tok=("${TOK[@]}") cs=("${CSTART[@]}") cl=("${CLEN[@]}")
  for j in "${!cs[@]}"; do
    words "${tok[@]:cs[j]:cl[j]}"
    if is_check; then found=0; break; fi
  done
  return "$found"
}

# ---- git ---------------------------------------------------------------------------------
# analyze_git <dir> <words after git...>
analyze_git() {
  local dir=$1; shift
  local -a args=("$@")
  local n=${#args[@]} i=0 t key kv sub
  # global options
  while [ "$i" -lt "$n" ] && [[ "${args[i]}" == -* ]]; do
    t=${args[i]}
    case "$t" in
      -C) i=$((i + 1)); t=${args[i]:-}
        case "$t" in /*) dir=$t ;; *) dir="$dir/$t" ;; esac ;;
      -c) i=$((i + 1)); kv=${args[i]:-}; key=$(lc "${kv%%=*}")
        [ "$key" = core.hookspath ] && block "git -c core.hooksPath overrides the repository's git hooks for one command, the way --no-verify does. Remove it and let git run the hook, then fix what the hook reports." ;;
      --config-env=*) [[ "$(lc "$t")" == --config-env=core.hookspath=* ]] && block "git --config-env core.hooksPath overrides the repository's git hooks. Remove it and let git run the hook, then fix what the hook reports." ;;
      --git-dir | --work-tree | --namespace | --super-prefix | --exec-path | --config-env) i=$((i + 1)) ;;
    esac
    i=$((i + 1))
  done
  sub=${args[i]:-}
  [ -n "$sub" ] || return 0
  local -a rest=("${args[@]:i+1}")
  local nr=${#rest[@]} k=0

  # --no-verify anywhere before "--"; git commit -n
  while [ "$k" -lt "$nr" ]; do
    t=${rest[k]}
    [ "$t" = "--" ] && break
    if [ "$t" = "--no-verify" ]; then
      block "git $sub --no-verify skips the repository's git hooks (pre-commit, pre-push). Never skip them: run the command without it and fix what the hook reports (run the project's check command to see it first)."
    elif [ "$sub" = commit ] && [[ "$t" == -* ]] && [[ "$t" != --* ]]; then
      local clust=${t:1} ch j=0 needs_next=0
      while [ "$j" -lt ${#clust} ]; do
        ch=${clust:j:1}
        case "$ch" in
          n) block "git commit -n is --no-verify: it skips the repository's git hooks. Never skip them: run the commit without it and fix what the hook reports (run the project's check command to see it first)."; break ;;
          m | F | C | c | t) [ $((j + 1)) -ge ${#clust} ] && needs_next=1; break ;;
          S | u) break ;;
        esac
        j=$((j + 1))
      done
      [ "$needs_next" = 1 ] && k=$((k + 1))
    elif [ "$sub" = commit ]; then
      case "$t" in --message | --file | --author | --date | --reuse-message | --reedit-message | --template | --cleanup | --fixup | --squash | --trailer) k=$((k + 1)) ;; esac
    fi
    k=$((k + 1))
  done

  case "$sub" in
    config) analyze_git_config "${rest[@]}" ;;
    push) analyze_git_push "$dir" "${rest[@]}" ;;
    tag) analyze_git_tag "${rest[@]}" ;;
  esac
}

analyze_git_config() {
  local -a pos=() a=("$@")
  local scope=local readonly_=0 k=0 t
  while [ "$k" -lt ${#a[@]} ]; do
    t=${a[k]}
    case "$t" in
      --global | --system | --worktree) scope=other ;;
      -f | --file) scope=other; k=$((k + 1)) ;;
      --file=*) scope=other ;;
      --get | --get-all | --get-regexp | --get-urlmatch | --list | -l | --unset | --unset-all | --remove-section | --show-origin | --edit | -e) readonly_=1 ;;
      --type | --default | --comment) k=$((k + 1)) ;;
      -*) ;;
      *) pos+=("$t") ;;
    esac
    k=$((k + 1))
  done
  [ "${#pos[@]}" -gt 0 ] || return 0
  case "${pos[0]}" in # git config set|get|unset|list
    get | list | unset) return 0 ;;
    set) pos=("${pos[@]:1}") ;;
  esac
  [ "${#pos[@]}" -gt 0 ] || return 0
  [ "$(lc "${pos[0]}")" = core.hookspath ] || return 0
  [ "$readonly_" = 0 ] && [ "${#pos[@]}" -ge 2 ] || return 0
  local v=${pos[1]}
  if [ "$scope" = other ] || [ -z "$v" ] || [[ "$v" == /* || "$v" == '~'* || "$v" == *'$'* || "$v" == ..* || "$v" == */../* ]]; then
    block "git config core.hooksPath '$v' points git's hooks somewhere else (or in global config), which switches off the repository's own hooks. Do not override it: let git run the hook and fix what it reports. The repository's own hooks are enabled with a relative path in its local config, such as: git config core.hooksPath .githooks"
  fi
}

analyze_git_tag() {
  local -a a=("$@")
  [ ${#a[@]} -gt 0 ] || return 0
  local t
  for t in "${a[@]}"; do
    case "$t" in
      -l | --list | -n | -n[0-9]* | --contains | --no-contains | --points-at | --merged | --no-merged | --sort | --sort=* | -v | --verify | --column | --no-column | --format | --format=*) return 0 ;;
    esac
  done
  ask "git tag creates, moves or deletes a tag, which is a release step other people see (outward step)."
}

analyze_git_push() {
  local dir=$1; shift
  local -a a=("$@") pos=()
  local k=0 t force=0 del=0 all=0 mirror=0 tags=0 clust ch j
  while [ "$k" -lt ${#a[@]} ]; do
    t=${a[k]}
    case "$t" in
      --) pos+=("${a[@]:k+1}"); break ;;
      --force | --force-with-lease | --force-with-lease=*) force=1 ;;
      --delete) del=1 ;;
      --all | --branches) all=1 ;;
      --mirror) mirror=1; force=1 ;;
      --tags) tags=1 ;;
      --push-option | --repo | --receive-pack | --exec) k=$((k + 1)) ;;
      --*) ;;
      -*) clust=${t:1}; j=0
        while [ "$j" -lt ${#clust} ]; do
          ch=${clust:j:1}
          case "$ch" in
            f) force=1 ;;
            d) del=1 ;;
            o) [ $((j + 1)) -ge ${#clust} ] && k=$((k + 1)); break ;;
          esac
          j=$((j + 1))
        done ;;
      *) pos+=("$t") ;;
    esac
    k=$((k + 1))
  done
  local cur dflt
  cur=$(current_branch "$dir")
  dflt=$(default_branches)
  dflt=${dflt# }; dflt=${dflt% }
  local msg_force="Force-pushing the default branch rewrites history everyone shares. Never do it: add a new commit (or git revert) and push normally. To update your own feature branch use: git push --force-with-lease origin <feature-branch>"
  local msg_del="Deleting the default branch from the remote breaks everyone who uses it. Never do it from an agent."

  if [ "$tags" = 1 ]; then ask "git push --tags publishes tags, which is a release step other people see (outward step)."; fi
  if [ "$mirror" = 1 ] || [ "$all" = 1 ]; then
    if [ "$force" = 1 ]; then block "git push --force with --all or --mirror force-updates every branch, the default branch (${dflt// /, }) included. $msg_force"
    else ask "git push --all includes the default branch (outward step: other people see it)."; fi
    return 0
  fi
  local -a specs=()
  if [ ${#pos[@]} -gt 1 ]; then specs=("${pos[@]:1}"); fi
  if [ ${#specs[@]} -eq 0 ]; then # pushes the current branch
    if [ -n "$cur" ] && is_default "$cur"; then
      if [ "$force" = 1 ]; then block "git push --force on the default branch ($cur). $msg_force"
      else ask "this pushes the current branch, the default branch ($cur) (outward step: other people see it)."; fi
    fi
    return 0
  fi
  local s plus src dst
  for s in "${specs[@]}"; do
    plus=0
    [[ "$s" == +* ]] && { plus=1; s=${s#+}; }
    if [[ "$s" == *:* ]]; then src=${s%%:*} dst=${s#*:}; else src=$s dst=$s; [ "$s" = HEAD ] && dst=$cur; fi
    dst=${dst#refs/heads/}
    if [[ "$dst" == refs/tags/* ]]; then ask "git push of $dst publishes a tag, which is a release step other people see (outward step)."; continue; fi
    is_default "$dst" || continue
    if [ "$del" = 1 ] || [ -z "$src" ]; then block "git push would delete the default branch ($dst). $msg_del"
    elif [ "$force" = 1 ] || [ "$plus" = 1 ]; then block "git push --force to the default branch ($dst). $msg_force"
    else ask "git push to the default branch ($dst) is an outward step: other people see it. Merge through a pull request instead unless the user wants this push."; fi
  done
}

# ---- gh ----------------------------------------------------------------------------------
analyze_gh() {
  local -a a=("$@")
  local k=0 t g="" s=""
  while [ "$k" -lt ${#a[@]} ]; do
    t=${a[k]}
    case "$t" in
      -R | --repo | --hostname) k=$((k + 1)) ;;
      -*) ;;
      *) if [ -z "$g" ]; then g=$t; elif [ -z "$s" ]; then s=$t; break; fi ;;
    esac
    k=$((k + 1))
  done
  if [ "$g" = pr ] && [ "$s" = merge ]; then
    ask "gh pr merge merges into the default branch (outward step: the user decides)."
  elif [ "$g" = release ]; then
    case "$s" in
      "" | list | view | download | verify | verify-asset) ;;
      *) ask "gh release $s publishes or changes a release (outward step: the user decides)." ;;
    esac
  fi
}

# ---- one command string ------------------------------------------------------------------
analyze() { # analyze <command string> <pipefail already set: 0|1>
  local depth=${GUARD_DEPTH:-0}
  [ "$depth" -lt 3 ] || return 0
  local -a tok cs cl sep
  local j piped_check=0 base
  tokenize "$1"
  tok=("${TOK[@]}") cs=("${CSTART[@]}") cl=("${CLEN[@]}") sep=("${CSEP[@]}")
  [ "$2" = 1 ] && PIPEFAIL=1
  for j in "${!cs[@]}"; do
    words "${tok[@]:cs[j]:cl[j]}"
    local -a w=("${W[@]}")
    local c=${w[0]:-}
    base=${c##*/}
    if [ -n "$c" ]; then
      if stdin_reader && [ "$piped_check" = 1 ] && [ "$PIPEFAIL" = 0 ]; then
        block "a check or push is piped into ${w[0]} without pipefail: the pipeline's exit status is ${w[0]}'s, so a failing check or rejected push looks like success. Either set -o pipefail first (set -o pipefail; <command> | ${w[0]} ...) or redirect to a file and read it after: <command> > out.log 2>&1; echo \"exit \$?\"; ${w[0]} -n 40 out.log"
      fi
      W=("${w[@]}")
      if is_check; then piped_check=1; fi
      case "$base" in
        set) local t; for t in "${w[@]:1}"; do [ "$t" = pipefail ] && PIPEFAIL=1; done ;;
        bash | sh | zsh | dash | ksh)
          local k=1 pf=$PIPEFAIL t2
          while [ "$k" -lt ${#w[@]} ]; do
            t2=${w[k]}
            case "$t2" in
              pipefail) pf=1 ;;
              -c) if [ "$k" -lt $((${#w[@]} - 1)) ]; then GUARD_DEPTH=$((depth + 1)) analyze "${w[k + 1]}" "$pf"; fi; break ;;
              -[a-z]*c) if [ "$k" -lt $((${#w[@]} - 1)) ]; then GUARD_DEPTH=$((depth + 1)) analyze "${w[k + 1]}" "$pf"; fi; break ;;
            esac
            k=$((k + 1))
          done ;;
        eval) GUARD_DEPTH=$((depth + 1)) analyze "${w[*]:1}" "$PIPEFAIL" ;;
        git) analyze_git "$cwd" "${w[@]:1}" ;;
        gh) analyze_gh "${w[@]:1}" ;;
      esac
    fi
    case "${sep[j]}" in
      "|" | "|&") ;;
      *) piped_check=0 ;;
    esac
  done
}

analyze "$cmd" 0

if [ ${#BLOCKS[@]} -gt 0 ]; then
  {
    echo "guard-bash: blocked."
    printf ' - %s\n' "${BLOCKS[@]}"
  } >&2
  exit 2
fi
if [ ${#ASKS[@]} -gt 0 ]; then
  reason=$(printf 'guard-bash (factory): %s\n' "${ASKS[@]}")
  jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
fi
exit 0
