#!/usr/bin/env bash
# The repository's check command: plugin validation, shellcheck, test suites.
# Fails on any failure and names what failed.
set -euo pipefail
cd "$(dirname "$0")/.."

failed=()
run() { # run <label> <command...>
  local label=$1; shift
  echo "== $label"
  if "$@"; then echo "ok: $label"; else echo "FAILED: $label"; failed+=("$label"); fi
}

if command -v claude >/dev/null 2>&1; then
  run "validate marketplace" claude plugin validate .
  run "validate plugin" claude plugin validate plugins/factory
elif [ "${CI:-}" = "true" ]; then
  echo "SKIPPED: claude plugin validate (claude is not installed in CI)"
else
  echo "FAILED: claude is not installed; cannot run claude plugin validate"
  failed+=("claude missing")
fi

if command -v shellcheck >/dev/null 2>&1; then
  scripts=()
  while IFS= read -r f; do scripts+=("$f"); done < <(
    { git ls-files -co --exclude-standard -- '*.sh' '*/bin/*' 'bin/*' '.githooks/*'; } | grep -v '/\.gitkeep$' | sort -u
  )
  if [ ${#scripts[@]} -gt 0 ]; then run "shellcheck" shellcheck "${scripts[@]}"; fi
else
  echo "FAILED: shellcheck is not installed"
  failed+=("shellcheck missing")
fi

for suite in tests/*/run.sh; do
  [ -e "$suite" ] || continue
  run "$suite" bash "$suite"
done

if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "check failed:"
  printf '  - %s\n' "${failed[@]}"
  exit 1
fi
echo
echo "check passed"
