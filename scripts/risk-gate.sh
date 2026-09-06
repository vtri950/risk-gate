#!/usr/bin/env bash
set -euo pipefail

# risk-gate.sh — deterministic risk-based PR labeling
# Usage:
#   ./scripts/risk-gate.sh [--base origin/main] [--config .github/risk-gate.yml] [--json] [--label] [--check]
#   ./scripts/risk-gate.sh --files "api/foo.ts auth/bar.ts" # for testing
#
# Exit codes:
#   0 = no risk (no label needed)
#   1 = risky (needs-human-review)
#   2 = error
#
# Inspired by DuckbillHQ thread: shell script adds github label for risky touches
# https://x.com/mikejulian/status/2096450476170694785

CONFIG=".github/risk-gate.yml"
BASE="origin/main"
OUTPUT_JSON=false
MODE="check"
FILES_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --json) OUTPUT_JSON=true; shift;;
    --files) FILES_OVERRIDE="$2"; shift 2;;
    --label|--check) MODE="${1#--}"; shift;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# --- parse config (yq if available, else grep/sed fallback) ---
get_config_value() {
  local key="$1"
  if command -v yq >/dev/null 2>&1; then
    yq -r "$key // \"\"" "$CONFIG" 2>/dev/null || echo ""
  else
    # fallback: simple line extraction for risky_paths
    echo ""
  fi
}

RISKY_PATHS=()
RISKY_PATTERNS=()
LABEL="needs-human-review"

if [[ -f "$CONFIG" ]]; then
  if command -v yq >/dev/null 2>&1; then
    LABEL=$(yq -r '.risk.label // "needs-human-review"' "$CONFIG")
    mapfile -t RISKY_PATHS < <(yq -r '.risk.risky_paths[]? // empty' "$CONFIG")
    mapfile -t RISKY_PATTERNS < <(yq -r '.risk.risky_patterns[]? // empty' "$CONFIG")
  else
    # minimal fallback without yq: use defaults
    RISKY_PATHS=("api/**" "mcp/**" "auth/**" "src/design-system/**" "skills/**" "AGENTS.md" ".opencode/**" "**/migrations/**")
    RISKY_PATTERNS=(".*\\.sql$")
  fi
else
  echo "warn: config $CONFIG not found, using defaults" >&2
  RISKY_PATHS=("api/**" "mcp/**" "auth/**" "src/design-system/**" "skills/**" "AGENTS.md" ".opencode/**" "**/migrations/**")
  RISKY_PATTERNS=(".*\\.sql$")
fi

# --- get changed files ---
CHANGED_FILES=()
if [[ -n "$FILES_OVERRIDE" ]]; then
  read -ra CHANGED_FILES <<< "$FILES_OVERRIDE"
else
  # try git diff against base, fallback to HEAD~1
  if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    mapfile -t CHANGED_FILES < <(git diff --name-only --diff-filter=ACMRT "$BASE"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")
  else
    mapfile -t CHANGED_FILES < <(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only --cached 2>/dev/null || echo "")
  fi
  # if still empty, try unstaged
  if [[ ${#CHANGED_FILES[@]} -eq 0 || -z "${CHANGED_FILES[0]}" ]]; then
    mapfile -t CHANGED_FILES < <(git diff --name-only 2>/dev/null || echo "")
  fi
fi

# filter empty
FILTERED=()
for f in "${CHANGED_FILES[@]}"; do
  [[ -n "$f" ]] && FILTERED+=("$f")
done
CHANGED_FILES=("${FILTERED[@]}")

# helper: glob match (bash extglob)
match_glob() {
  local file="$1" pattern="$2"
  # support ** via bash globstar
  shopt -s globstar extglob nullglob 2>/dev/null || true
  # convert simple glob to bash pattern matching
  # use case statement for matching
  case "$file" in
    $pattern) return 0;;
    *) return 1;;
  esac
}

# more robust: use fnmatch via python if available for ** support
match_path() {
  local file="$1" pat="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import fnmatch, sys
f=sys.argv[1]
p=sys.argv[2]
# fnmatch doesn't handle ** well, convert **/ to * and ** to *
import pathlib
# use pathlib PurePath match via fnmatch with ** expanded
if fnmatch.fnmatch(f, p) or fnmatch.fnmatch(f, p.replace('**/','').replace('**','*')):
    sys.exit(0)
# try pathlib match
try:
    from pathlib import PurePath
    if PurePath(f).match(p):
        sys.exit(0)
except:
    pass
sys.exit(1)
" "$file" "$pat" && return 0 || return 1
  else
    match_glob "$file" "$pat"
  fi
}

RISKY_HITS=()
for file in "${CHANGED_FILES[@]}"; do
  matched=false
  for pat in "${RISKY_PATHS[@]}"; do
    if match_path "$file" "$pat"; then
      RISKY_HITS+=("$file → $pat")
      matched=true
      break
    fi
  done
  # check regex patterns only if not already matched
  if [[ "$matched" == false ]]; then
    for rx in "${RISKY_PATTERNS[@]}"; do
      [[ -z "$rx" ]] && continue
      if echo "$file" | grep -Eq "$rx"; then
        RISKY_HITS+=("$file → regex:$rx")
        break
      fi
    done
  fi
done

IS_RISKY=false
if [[ ${#RISKY_HITS[@]} -gt 0 ]]; then IS_RISKY=true; fi

# --- output ---
if [[ "$OUTPUT_JSON" == true ]]; then
  if [[ ${#RISKY_HITS[@]} -eq 0 ]]; then HITS_JSON="[]"; else HITS_JSON=$(printf '%s\n' "${RISKY_HITS[@]}" | python3 -c "import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))"); fi
  if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then FILES_JSON="[]"; else FILES_JSON=$(printf '%s\n' "${CHANGED_FILES[@]}" | python3 -c "import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))"); fi
  RISKY_PY=$([ "$IS_RISKY" = true ] && echo "True" || echo "False")
  python3 -c "
import json as j
hits = j.loads('''$HITS_JSON''')
files = j.loads('''$FILES_JSON''')
data = {
  'risky': $RISKY_PY,
  'label': '$LABEL',
  'changed_files': files,
  'hits': hits
}
print(j.dumps(data, indent=2))
"
else
  if [[ "$IS_RISKY" == true ]]; then
    echo "RISKY: needs '$LABEL'"
    printf '  - %s\n' "${RISKY_HITS[@]}"
    echo "changed_files: ${CHANGED_FILES[*]}"
  else
    echo "SAFE: no risky paths matched"
    [[ ${#CHANGED_FILES[@]} -gt 0 ]] && echo "changed_files: ${CHANGED_FILES[*]}" || echo "changed_files: (none detected)"
  fi
fi

# --- mode handling ---
if [[ "$MODE" == "label" && "$IS_RISKY" == true ]]; then
  if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${PR_NUMBER:-}" ]]; then
    echo "Adding label $LABEL to PR #$PR_NUMBER via gh" >&2
    gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/labels" -f labels[]="$LABEL" 2>&1 || echo "warn: failed to add label (needs gh auth)" >&2
  elif command -v gh >/dev/null 2>&1 && [[ -n "${PR_NUMBER:-}" ]]; then
    gh pr edit "$PR_NUMBER" --add-label "$LABEL" 2>&1 || true
  fi
fi

if [[ "$IS_RISKY" == true ]]; then
  exit 1
else
  exit 0
fi
