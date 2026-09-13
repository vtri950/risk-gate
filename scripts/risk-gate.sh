#!/usr/bin/env bash
set -eo pipefail
# NOTE: no `set -u` — bash 3.2 (macOS) treats empty arrays as unbound.

# risk-gate.sh — deterministic risk-based PR labeling with tiers (P0/P1/P2)
# Usage:
#   ./scripts/risk-gate.sh [--base origin/main] [--config .github/risk-gate.yml] [--json] [--label] [--check] [--inbox]
#   ./scripts/risk-gate.sh --files "api/foo.ts auth/bar.ts" # for testing
#
# Tiers (Anthropic/OpenAI + Uber Inbox lesson from Gergely thread):
#   P0 = blocking human review (needs-human-review) — auth, API, schema, skills
#   P1 = advisory human review (needs-human-advisory) — src/lib/packages, non-trivial logic
#   P2 = SAFE (copilot-safe) — docs, chore, small UI copy
#
# Exit codes (backward compat):
#   0 = no P0 risk (P1 and P2 allowed to auto-merge)
#   1 = P0 risky (needs-human-review)
#   2 = error
#
# Inspired by DuckbillHQ thread: shell script adds github label for risky touches
# https://x.com/mikejulian/status/2096450476170694785

CONFIG=".github/risk-gate.yml"
BASE="origin/main"
OUTPUT_JSON=false
INBOX=false
MODE="check"
FILES_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --json) OUTPUT_JSON=true; shift;;
    --inbox) INBOX=true; OUTPUT_JSON=true; shift;;
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
P0_PATHS=()
P0_PATTERNS=()
P1_PATHS=()
P1_PATTERNS=()
LABEL="needs-human-review"
P0_LABEL="needs-human-review"
P1_LABEL="needs-human-advisory"

# portable line reader (bash 3.2 has no mapfile): read stdin into named array
read_lines() { # $1=array name; reads stdin
  local __arr="$1" __line
  eval "$__arr=()"
  while IFS= read -r __line; do
    [[ -n "$__line" ]] || continue
    eval "$__arr+=(\"\$__line\")"
  done
  return 0
}

if [[ -f "$CONFIG" ]]; then
  if command -v yq >/dev/null 2>&1; then
    LABEL=$(yq -r '.risk.label // "needs-human-review"' "$CONFIG")
    P0_LABEL=$(yq -r '.risk.tiers.p0_label // .risk.label // "needs-human-review"' "$CONFIG")
    P1_LABEL=$(yq -r '.risk.tiers.p1_label // "needs-human-advisory"' "$CONFIG")
    read_lines RISKY_PATHS < <(yq -r '.risk.risky_paths[]?' "$CONFIG" 2>/dev/null || true)
    read_lines RISKY_PATTERNS < <(yq -r '.risk.risky_patterns[]?' "$CONFIG" 2>/dev/null || true)
    read_lines P0_PATHS < <(yq -r '.risk.tiers.p0_paths[]? // .risk.risky_paths[]?' "$CONFIG" 2>/dev/null || true)
    read_lines P0_PATTERNS < <(yq -r '.risk.tiers.p0_patterns[]? // .risk.risky_patterns[]?' "$CONFIG" 2>/dev/null || true)
    read_lines P1_PATHS < <(yq -r '.risk.tiers.p1_paths[]?' "$CONFIG" 2>/dev/null || true)
    read_lines P1_PATTERNS < <(yq -r '.risk.tiers.p1_patterns[]?' "$CONFIG" 2>/dev/null || true)
    # fallback: legacy risky_* doubles as P0
    [[ ${#P0_PATHS[@]} -eq 0 ]] && P0_PATHS=("${RISKY_PATHS[@]}")
    [[ ${#P0_PATTERNS[@]} -eq 0 ]] && P0_PATTERNS=("${RISKY_PATTERNS[@]}")
  else
    # minimal fallback without yq: use defaults
    RISKY_PATHS=("api/**" "mcp/**" "auth/**" "src/design-system/**" "skills/**" ".opencode/**" "AGENTS.md" "**/migrations/**")
    RISKY_PATTERNS=(".*\\.sql$")
    P0_PATHS=("${RISKY_PATHS[@]}")
    P0_PATTERNS=("${RISKY_PATTERNS[@]}")
    P1_PATHS=("src/**" "lib/**" "packages/**" "internal/**")
    P1_PATTERNS=()
  fi
else
  echo "warn: config $CONFIG not found, using defaults" >&2
  RISKY_PATHS=("api/**" "mcp/**" "auth/**" "src/design-system/**" "skills/**" ".opencode/**" "AGENTS.md" "**/migrations/**")
  RISKY_PATTERNS=(".*\\.sql$")
  P0_PATHS=("${RISKY_PATHS[@]}")
  P0_PATTERNS=("${RISKY_PATTERNS[@]}")
  P1_PATHS=("src/**" "lib/**" "packages/**" "internal/**")
  P1_PATTERNS=()
fi
# default P1 when config has no tiers yet (Uber Inbox: highlight core logic)
if [[ ${#P1_PATHS[@]} -eq 0 && ${#P1_PATTERNS[@]} -eq 0 ]]; then
  P1_PATHS=("src/**" "lib/**" "packages/**" "internal/**")
fi

# --- get changed files ---
CHANGED_FILES=()
if [[ -n "$FILES_OVERRIDE" ]]; then
  read -ra CHANGED_FILES <<< "$FILES_OVERRIDE"
else
  # try git diff against base, fallback to HEAD~1
  if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    read_lines CHANGED_FILES < <(git diff --name-only --diff-filter=ACMRT "$BASE"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")
  else
    read_lines CHANGED_FILES < <(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only --cached 2>/dev/null || echo "")
  fi
  # if still empty, try unstaged
  if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    read_lines CHANGED_FILES < <(git diff --name-only 2>/dev/null || echo "")
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

P0_HITS=()
P1_HITS=()
for file in "${CHANGED_FILES[@]}"; do
  matched=false
  for pat in "${P0_PATHS[@]}"; do
    [[ -z "$pat" ]] && continue
    if match_path "$file" "$pat"; then
      P0_HITS+=("$file → $pat")
      matched=true
      break
    fi
  done
  if [[ "$matched" == false ]]; then
    for rx in "${P0_PATTERNS[@]}"; do
      [[ -z "$rx" ]] && continue
      if echo "$file" | grep -Eq "$rx"; then
        P0_HITS+=("$file → regex:$rx")
        matched=true
        break
      fi
    done
  fi
  # P1 only if not already P0 (Uber Inbox: P0 first)
  if [[ "$matched" == false ]]; then
    for pat in "${P1_PATHS[@]}"; do
      [[ -z "$pat" ]] && continue
      if match_path "$file" "$pat"; then
        P1_HITS+=("$file → $pat")
        matched=true
        break
      fi
    done
  fi
  if [[ "$matched" == false ]]; then
    for rx in "${P1_PATTERNS[@]}"; do
      [[ -z "$rx" ]] && continue
      if echo "$file" | grep -Eq "$rx"; then
        P1_HITS+=("$file → regex:$rx")
        break
      fi
    done
  fi
done
# legacy alias for backward compat
RISKY_HITS=("${P0_HITS[@]}")

TIER="P2"
EFFECTIVE_LABEL="copilot-safe"
IS_RISKY=false
if [[ ${#P0_HITS[@]} -gt 0 ]]; then TIER="P0"; EFFECTIVE_LABEL="$P0_LABEL"; IS_RISKY=true;
elif [[ ${#P1_HITS[@]} -gt 0 ]]; then TIER="P1"; EFFECTIVE_LABEL="$P1_LABEL"; fi
# keep legacy LABEL in sync for P0 case
[[ "$TIER" == "P0" ]] && LABEL="$P0_LABEL"

# --- output ---
if [[ "$OUTPUT_JSON" == true ]]; then
  if [[ ${#P0_HITS[@]} -eq 0 ]]; then P0_JSON="[]"; else P0_JSON=$(printf '%s\n' "${P0_HITS[@]}" | python3 -c "import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))"); fi
  if [[ ${#P1_HITS[@]} -eq 0 ]]; then P1_JSON="[]"; else P1_JSON=$(printf '%s\n' "${P1_HITS[@]}" | python3 -c "import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))"); fi
  if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then FILES_JSON="[]"; else FILES_JSON=$(printf '%s\n' "${CHANGED_FILES[@]}" | python3 -c "import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))"); fi
  RISKY_PY=$([ "$IS_RISKY" = true ] && echo "True" || echo "False")
  # inbox: P0 first, then P1, then rest (Uber Code Review Inbox triage)
  INBOX_JSON=$(python3 -c "
import json
p0=json.loads('''$P0_JSON''')
p1=json.loads('''$P1_JSON''')
files=json.loads('''$FILES_JSON''')
p0f={h.split(' → ')[0] for h in p0}
p1f={h.split(' → ')[0] for h in p1}
inbox=[]
for h in p0: inbox.append({'file': h.split(' → ')[0], 'tier': 'P0', 'via': h})
for h in p1: inbox.append({'file': h.split(' → ')[0], 'tier': 'P1', 'via': h})
for f in files:
    if f not in p0f and f not in p1f: inbox.append({'file': f, 'tier': 'P2', 'via': 'safe'})
print(json.dumps(inbox))
")
  python3 -c "
import json as j
p0 = j.loads('''$P0_JSON''')
p1 = j.loads('''$P1_JSON''')
files = j.loads('''$FILES_JSON''')
inbox = j.loads('''$INBOX_JSON''')
data = {
  'risky': $RISKY_PY,
  'tier': '$TIER',
  'label': '$EFFECTIVE_LABEL',
  'p0_label': '$P0_LABEL',
  'p1_label': '$P1_LABEL',
  'changed_files': files,
  'hits': p0,  # legacy: P0 hits
  'p0_hits': p0,
  'p1_hits': p1,
  'inbox': inbox,
}
print(j.dumps(data, indent=2))
"
else
  if [[ "$TIER" == "P0" ]]; then
    echo "RISKY P0: needs '$P0_LABEL'"
    printf '  - %s\n' "${P0_HITS[@]}"
    [[ ${#P1_HITS[@]} -gt 0 ]] && { echo "Advisory P1:"; printf '  - %s\n' "${P1_HITS[@]}"; }
    echo "changed_files: ${CHANGED_FILES[*]}"
  elif [[ "$TIER" == "P1" ]]; then
    echo "ADVISORY P1: suggest '$P1_LABEL' (non-blocking, review when you can)"
    printf '  - %s\n' "${P1_HITS[@]}"
    echo "changed_files: ${CHANGED_FILES[*]}"
  else
    echo "SAFE P2: no risky paths matched"
    [[ ${#CHANGED_FILES[@]} -gt 0 ]] && echo "changed_files: ${CHANGED_FILES[*]}" || echo "changed_files: (none detected)"
  fi
fi

# --- mode handling ---
if [[ "$MODE" == "label" && "$TIER" != "P2" ]]; then
  ADD_LABEL="$EFFECTIVE_LABEL"
  if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${PR_NUMBER:-}" ]]; then
    echo "Adding label $ADD_LABEL to PR #$PR_NUMBER via gh" >&2
    gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/labels" -f labels[]="$ADD_LABEL" 2>&1 || echo "warn: failed to add label (needs gh auth)" >&2
  elif command -v gh >/dev/null 2>&1 && [[ -n "${PR_NUMBER:-}" ]]; then
    gh pr edit "$PR_NUMBER" --add-label "$ADD_LABEL" 2>&1 || true
  fi
elif [[ "$MODE" == "label" && "$IS_RISKY" == true ]]; then
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
