#!/usr/bin/env bash
set -eo pipefail
# NOTE: no `set -u` — bash 3.2 (macOS) treats empty arrays as unbound.
# prevention-gate.sh — deterministic retro-trail gate (no LLM key)
# A fix without a prevention note gets re-introduced in two weeks: the retro
# found the error, but nothing makes it impossible next time. This gate
# requires fix-intent PRs to record what deterministic check would have
# caught the bug — or to state explicitly that the finding was judgment-call.
#
# Usage:
#   ./scripts/prevention-gate.sh [--config .github/risk-gate.yml] [--base origin/main]
#                                [--files "a.ts b.ts"] [--pr-body "..."] [--pr-body-file FILE]
#                                [--pr-number N] [--json]
# Exit codes:
#   0 = pass (Prevention trail present, PR not a fix, or PR exempt)
#   1 = fail (fix-intent PR with no Prevention trail)
#   2 = error
#
# Deterministic signals (no AI):
#   1. Fix intent: body matches fix/bug/regression/hotfix/defect/retro words.
#      Non-fix PRs pass with a reason (nothing to prevent).
#   2. Trail: body contains `Prevention:` with a value in
#      lint|hook|ci|test|docs|existing-gate|judgment-call, optionally
#      followed by a link to the new/updated check.
#   3. Docs-only / exempt-path / exempt-label PRs skip the requirement.

CONFIG=".github/risk-gate.yml"
BASE="origin/main"
FILES_OVERRIDE=""
PR_BODY=""
PR_BODY_FILE=""
PR_NUMBER="${PR_NUMBER:-}"
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --files) FILES_OVERRIDE="$2"; shift 2;;
    --pr-body) PR_BODY="$2"; shift 2;;
    --pr-body-file) PR_BODY_FILE="$2"; shift 2;;
    --pr-number) PR_NUMBER="$2"; shift 2;;
    --json) OUTPUT_JSON=true; shift;;
    --help|-h) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

ENABLED="true"
VALID_VALUES="lint|hook|ci|test|docs|existing-gate|judgment-call"
EXEMPT_PATHS=("docs/**" "*.md" ".github/copilot-instructions.md")
EXEMPT_LABELS=("chore" "deps" "dependabot")

if [[ -f "$CONFIG" ]] && command -v yq >/dev/null 2>&1; then
  v=$(yq -r '.prevention.enabled // "true"' "$CONFIG" 2>/dev/null || echo "true")
  [[ -n "$v" ]] && ENABLED="$v"
  v=$(yq -r '.prevention.valid_values // ""' "$CONFIG" 2>/dev/null || echo "")
  [[ -n "$v" ]] && VALID_VALUES="$v"
  read_lines_cfg() { local __a="$1" __q="$2" __l; eval "$__a=()"; while IFS= read -r __l; do [[ -n "$__l" ]] || continue; eval "$__a+=(\"\$__l\")"; done < <(yq -r "$__q" "$CONFIG" 2>/dev/null || true); return 0; }
  read_lines_cfg _ep '.prevention.exempt_paths[]?'
  [[ ${#_ep[@]} -gt 0 ]] && EXEMPT_PATHS=("${_ep[@]}")
  read_lines_cfg _el '.prevention.exempt_labels[]?'
  [[ ${#_el[@]} -gt 0 ]] && EXEMPT_LABELS=("${_el[@]}")
fi

# --- PR body: explicit arg > file > live gh API > stale event payload ---
if [[ -z "$PR_BODY" && -n "$PR_BODY_FILE" && -f "$PR_BODY_FILE" ]]; then
  PR_BODY=$(cat "$PR_BODY_FILE")
fi
if [[ -z "$PR_BODY" && -n "$PR_NUMBER" ]] && command -v gh >/dev/null 2>&1; then
  PR_BODY=$(gh pr view "$PR_NUMBER" --json body -q '.body // ""' 2>/dev/null || echo "")
fi
if [[ -z "$PR_BODY" && -n "${GITHUB_EVENT_PATH:-}" && -f "$GITHUB_EVENT_PATH" ]]; then
  PR_BODY=$(python3 -c "import json,os; print(json.load(open(os.environ['GITHUB_EVENT_PATH'])).get('pull_request',{}).get('body','') or '')" 2>/dev/null || echo "")
fi

# --- changed files ---
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
FILTERED=()
for f in "${CHANGED[@]}"; do [[ -n "${f:-}" ]] && FILTERED+=("$f"); done
CHANGED=("${FILTERED[@]:-}")

match_path() {
  local file="$1" pat="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import fnmatch, sys
f=sys.argv[1]; p=sys.argv[2]
if fnmatch.fnmatch(f, p) or fnmatch.fnmatch(f, p.replace('**/','').replace('**','*')):
    sys.exit(0)
try:
    from pathlib import PurePath
    if PurePath(f).match(p):
        sys.exit(0)
except:
    pass
sys.exit(1)
" "$file" "$pat" && return 0 || return 1
  else
    case "$file" in $pat) return 0;; *) return 1;; esac
  fi
}

# --- exempt? ---
NONEXEMPT=()
for f in "${CHANGED[@]}"; do
  exempt=false
  for pat in "${EXEMPT_PATHS[@]}"; do
    if match_path "$f" "$pat"; then exempt=true; break; fi
  done
  [[ "$exempt" == false ]] && NONEXEMPT+=("$f")
done

PR_LABELS=""
if [[ -n "$PR_NUMBER" ]] && command -v gh >/dev/null 2>&1; then
  if GH_OUT=$(gh pr view "$PR_NUMBER" --json labels -q '.labels[].name' 2>/dev/null); then
    PR_LABELS="$GH_OUT"
  else
    echo "::warning::prevention-gate could not read PR #$PR_NUMBER labels (gh auth? missing GITHUB_TOKEN?) — exempt-label check skipped" >&2
  fi
fi

EXEMPT_REASON=""
if [[ ${#CHANGED[@]} -eq 0 ]]; then
  EXEMPT_REASON="no changed files detected"
elif [[ ${#NONEXEMPT[@]} -eq 0 ]]; then
  EXEMPT_REASON="docs/exempt-only change"
else
  for lab in "${EXEMPT_LABELS[@]}"; do
    if echo "$PR_LABELS" | grep -qi "^${lab}$"; then EXEMPT_REASON="label $lab"; break; fi
  done
fi

# --- fix intent + trail signals ---
FIX_RES='(^|[^a-zA-Z])(fix|fixes|fixed|fixing|bug|bugfix|regression|hotfix|defect|post-mortem|postmortem|retro)([^a-zA-Z]|$)'
IS_FIX=false
[[ -n "$PR_BODY" ]] && echo "$PR_BODY" | grep -Eqi "$FIX_RES" && IS_FIX=true

TRAIL_RES='(^|[^a-zA-Z])prevention[[:space:]]*:'
HAS_TRAIL=false
TRAIL_VALUE=""
if [[ -n "$PR_BODY" ]]; then
  TRAIL_LINE=$(echo "$PR_BODY" | grep -Ei "$TRAIL_RES" | head -n 1 || true)
  if [[ -n "$TRAIL_LINE" ]]; then
    HAS_TRAIL=true
    TRAIL_VALUE=$(echo "$TRAIL_LINE" | sed -E 's/.*[Pp][Rr][Ee][Vv][Ee][Nn][Tt][Ii][Oo][Nn][[:space:]]*:[[:space:]]*//' | cut -c1-120 | tr -d "'")
  fi
fi

TRAIL_VALID=false
if [[ "$HAS_TRAIL" == true ]]; then
  echo "$TRAIL_VALUE" | grep -Eqi "^(${VALID_VALUES})" && TRAIL_VALID=true
fi

emit_json() {
  local result="$1" reason="$2"
  python3 -c "
import json
print(json.dumps({
  'pass': True if '$result' == 'pass' else False,
  'exempt': bool('''$EXEMPT_REASON'''),
  'exempt_reason': '''$EXEMPT_REASON''',
  'is_fix': bool('''$([ "$IS_FIX" == true ] && echo x)'''),
  'has_trail': bool('''$([ "$HAS_TRAIL" == true ] && echo x)'''),
  'trail_value': '''$TRAIL_VALUE''',
  'trail_valid': bool('''$([ "$TRAIL_VALID" == true ] && echo x)'''),
  'changed_files': '''${CHANGED[*]}'''.split() if '''${CHANGED[*]}''' else [],
  'reason': '''$reason'''
}, indent=2))
"
}

if [[ -n "$EXEMPT_REASON" ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "exempt: $EXEMPT_REASON" || echo "✓ prevention-gate passed (exempt: $EXEMPT_REASON)"
  exit 0
fi

if [[ "$ENABLED" != "true" ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "disabled via prevention.enabled" || echo "✓ prevention-gate passed (disabled via prevention.enabled=false)"
  exit 0
fi

if [[ "$IS_FIX" == false ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "not a fix PR — no trail required" || echo "✓ prevention-gate passed (not a fix PR)"
  exit 0
fi

if [[ "$TRAIL_VALID" == true ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "prevention trail present: $TRAIL_VALUE" || echo "✓ prevention-gate passed (Prevention: $TRAIL_VALUE)"
  exit 0
fi

if [[ "$HAS_TRAIL" == true ]]; then
  MSG="❌ prevention-gate FAILED: Prevention value not recognized: '$TRAIL_VALUE'."
  HINT="Fix: use one of ($VALID_VALUES) — e.g. 'Prevention: lint (new rule in ...)'. Use 'judgment-call' only when no script could decide pass/fail."
else
  MSG="❌ prevention-gate FAILED: fix PR has no Prevention trail."
  HINT="Fix: add a 'Prevention:' line to the PR body — what deterministic check would have caught this (lint|hook|ci|test|docs|existing-gate), or 'judgment-call' if no script could decide it."
fi
if [[ "$OUTPUT_JSON" == true ]]; then
  emit_json fail "$MSG $HINT"
else
  echo "$MSG" >&2
  echo "Changed: ${CHANGED[*]:-(none)}" >&2
  echo "" >&2
  echo "$HINT" >&2
fi
exit 1
