#!/usr/bin/env bash
set -euo pipefail
# docs-gate.sh — enforces centralized docs (prevents context poisoning)
# Duckbill pattern: markdown docs accumulating from doc-happy agents → centralize to docs/
# Usage: ./scripts/docs-gate.sh [--config .github/risk-gate.yml] [--base origin/main] [--files "..."]

CONFIG=".github/risk-gate.yml"
BASE="origin/main"
FILES_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --files) FILES_OVERRIDE="$2"; shift 2;;
    *) shift;;
  esac
done

ALLOWED_DIRS=("docs/" ".github/")
ALLOWED_ROOT=("README.md" "AGENTS.md" "CONTRIBUTING.md")

if [[ -f "$CONFIG" ]] && command -v yq >/dev/null 2>&1; then
  mapfile -t ALLOWED_DIRS < <(yq -r '.guardrails.docs_allowed_dirs[]? // empty' "$CONFIG")
  mapfile -t ALLOWED_ROOT < <(yq -r '.guardrails.docs_allowed_root_files[]? // empty' "$CONFIG")
  [[ ${#ALLOWED_DIRS[@]} -eq 0 ]] && ALLOWED_DIRS=("docs/" ".github/")
fi

# get changed files
CHANGED=()
if [[ -n "$FILES_OVERRIDE" ]]; then
  read -ra CHANGED <<< "$FILES_OVERRIDE"
else
  if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    mapfile -t CHANGED < <(git diff --name-only --diff-filter=ACMRT "$BASE"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")
  else
    mapfile -t CHANGED < <(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only --cached 2>/dev/null || echo "")
  fi
  if [[ ${#CHANGED[@]} -eq 0 || -z "${CHANGED[0]}" ]]; then
    mapfile -t CHANGED < <(git diff --name-only 2>/dev/null || echo "")
  fi
fi

VIOLATIONS=()
for f in "${CHANGED[@]}"; do
  [[ -z "$f" ]] && continue
  [[ "$f" != *.md ]] && continue
  allowed=false
  for d in "${ALLOWED_DIRS[@]}"; do
    if [[ "$f" == "$d"* ]]; then allowed=true; break; fi
  done
  for r in "${ALLOWED_ROOT[@]}"; do
    if [[ "$f" == "$r" ]]; then allowed=true; break; fi
  done
  if [[ "$allowed" == false ]]; then
    VIOLATIONS+=("$f")
  fi
done

if [[ ${#VIOLATIONS[@]} -gt 0 ]]; then
  echo "❌ docs-gate FAILED: markdown outside allowed dirs" >&2
  echo "Allowed dirs: ${ALLOWED_DIRS[*]}" >&2
  echo "Allowed root: ${ALLOWED_ROOT[*]}" >&2
  echo "Violations:" >&2
  printf '  - %s\n' "${VIOLATIONS[@]}" >&2
  echo "" >&2
  echo "Fix: move docs to docs/ or update .github/risk-gate.yml guardrails.docs_allowed_dirs" >&2
  exit 1
else
  echo "✓ docs-gate passed"
  exit 0
fi
