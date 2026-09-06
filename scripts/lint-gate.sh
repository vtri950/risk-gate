#!/usr/bin/env bash
set -euo pipefail
# lint-gate.sh — runs maxed-out linters (Duckbill: ruff/prettier/eslint/ty nearly every rule)
# Usage: ./scripts/lint-gate.sh [--fix]

FIX=""
if [[ "${1:-}" == "--fix" ]]; then FIX="--fix"; fi

FAIL=0

run() {
  echo "→ $*"
  if ! "$@"; then FAIL=1; fi
}

if [[ -f "pyproject.toml" || -f "ruff.toml" ]]; then
  if command -v ruff >/dev/null 2>&1; then
    run ruff check . $FIX
    run ruff format --check . 2>/dev/null || run ruff format . --check 2>/dev/null || true
  fi
  if command -v ty >/dev/null 2>&1; then
    run ty check .
  fi
fi

if [[ -f "package.json" ]]; then
  if command -v npx >/dev/null 2>&1; then
    [[ -f ".prettierrc" || -f ".prettierrc.json" ]] && run npx prettier --check . || true
    [[ -f "eslint.config.js" || -f ".eslintrc" ]] && run npx eslint . || true
  fi
fi

if [[ $FAIL -eq 0 ]]; then
  echo "✓ lint-gate passed"
else
  echo "❌ lint-gate FAILED" >&2
fi
exit $FAIL
