#!/usr/bin/env bash
set -eo pipefail
# NOTE: no `set -u` — bash 3.2 (macOS) treats empty arrays as unbound.
# skills-isolation.sh — forces agent skills / AGENTS.md changes into isolated PRs
# Duckbill: "We also force any changes to agent skills / agents.md go into their own PR"
# Usage: ./scripts/skills-isolation.sh [--base origin/main] [--files "..."]

BASE="origin/main"
FILES_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2;;
    --files) FILES_OVERRIDE="$2"; shift 2;;
    *) shift;;
  esac
done

CHANGED=()
read_lines() { local __a="$1" __l; eval "$__a=()"; while IFS= read -r __l; do [[ -n "$__l" ]] || continue; eval "$__a+=(\"\$__l\")"; done; return 0; }
if [[ -n "$FILES_OVERRIDE" ]]; then
  read -ra CHANGED <<< "$FILES_OVERRIDE"
else
  if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    read_lines CHANGED < <(git diff --name-only --diff-filter=ACMRT "$BASE"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")
  else
    read_lines CHANGED < <(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only --cached 2>/dev/null || echo "")
  fi
  if [[ ${#CHANGED[@]} -eq 0 ]]; then
    read_lines CHANGED < <(git diff --name-only 2>/dev/null || echo "")
  fi
fi

SKILL_FILES=()
OTHER_FILES=()
for f in "${CHANGED[@]}"; do
  [[ -z "$f" ]] && continue
  if [[ "$f" == skills/* || "$f" == .opencode/* || "$f" == "AGENTS.md" || "$f" == ".agents/"* || "$f" == ".claude/"* ]]; then
    SKILL_FILES+=("$f")
  else
    OTHER_FILES+=("$f")
  fi
done

if [[ ${#SKILL_FILES[@]} -gt 0 && ${#OTHER_FILES[@]} -gt 0 ]]; then
  echo "❌ skills-isolation FAILED: skills/AGENTS.md must be in isolated PR" >&2
  echo "Skill/meta files:" >&2
  printf '  - %s\n' "${SKILL_FILES[@]}" >&2
  echo "Other files:" >&2
  printf '  - %s\n' "${OTHER_FILES[@]}" >&2
  echo "" >&2
  echo "Fix: split into 2 PRs — one for skills/AGENTS.md, one for code" >&2
  exit 1
else
  if [[ ${#SKILL_FILES[@]} -gt 0 ]]; then
    echo "✓ skills-isolation passed (isolated skills PR: ${SKILL_FILES[*]})"
  else
    echo "✓ skills-isolation passed (no skill files touched)"
  fi
  exit 0
fi
