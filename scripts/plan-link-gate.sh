#!/usr/bin/env bash
set -euo pipefail
# plan-link-gate.sh — deterministic plan-conformance gate (no LLM key)
# Idea: review shifts to planning, not the PR stage. A PR that implements
# a plan must link that plan, so reviewers (human or Copilot) can check
# "does the implementation match the intent of the plan?"
#
# Usage:
#   ./scripts/plan-link-gate.sh [--config .github/risk-gate.yml] [--base origin/main]
#                              [--files "a.ts b.ts"] [--pr-body "..."] [--pr-body-file FILE]
#                              [--pr-number N] [--json] [--strict]
# Exit codes:
#   0 = pass (plan linked, or PR exempt)
#   1 = fail (non-exempt PR with no plan link)
#   2 = error
#
# Deterministic signals (no AI):
#   1. PR body links a plan: Closes #N, Fixes #N, Plan:/RFC:/Spec:/Design:,
#      or a path/URL under a known plan dir (plans/, docs/plans/, docs/rfcs/, etc.)
#   2. Diff itself touches a plan file (plans/**, docs/plans/**, etc.)
#   3. RISKY-path PRs (per risk-gate.sh) always require a plan link unless exempt.
#      Small/exempt PRs (docs-only, *.md, chore label) skip the requirement.

CONFIG=".github/risk-gate.yml"
BASE="origin/main"
FILES_OVERRIDE=""
PR_BODY=""
PR_BODY_FILE=""
PR_NUMBER="${PR_NUMBER:-}"
OUTPUT_JSON=false
STRICT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --files) FILES_OVERRIDE="$2"; shift 2;;
    --pr-body) PR_BODY="$2"; shift 2;;
    --pr-body-file) PR_BODY_FILE="$2"; shift 2;;
    --pr-number) PR_NUMBER="$2"; shift 2;;
    --json) OUTPUT_JSON=true; shift;;
    --strict) STRICT=true; shift;;
    --help|-h) sed -n '2,25p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

REQUIRE_LINK="true"
MIN_LINES_FOR_PLAN="0"
PLAN_PATHS=("plans/**" "docs/plans/**" "docs/plan/**" "docs/rfcs/**" "docs/rfc/**" ".github/plans/**" "ref.plan.md" "PLAN.md")
EXEMPT_PATHS=("docs/**" "*.md" ".github/copilot-instructions.md")
EXEMPT_LABELS=("chore" "deps" "dependabot")

if [[ -f "$CONFIG" ]] && command -v yq >/dev/null 2>&1; then
  v=$(yq -r '.plan.require_link // "true"' "$CONFIG" 2>/dev/null || echo "true")
  [[ -n "$v" ]] && REQUIRE_LINK="$v"
  v=$(yq -r '.plan.min_lines_for_plan // 0' "$CONFIG" 2>/dev/null || echo "0")
  [[ -n "$v" ]] && MIN_LINES_FOR_PLAN="$v"
  mapfile -t _pp < <(yq -r '.plan.plan_paths[]?' "$CONFIG" 2>/dev/null || true)
  [[ ${#_pp[@]} -gt 0 ]] && PLAN_PATHS=("${_pp[@]}")
  mapfile -t _ep < <(yq -r '.plan.exempt_paths[]?' "$CONFIG" 2>/dev/null || true)
  [[ ${#_ep[@]} -gt 0 ]] && EXEMPT_PATHS=("${_ep[@]}")
  mapfile -t _el < <(yq -r '.plan.exempt_labels[]?' "$CONFIG" 2>/dev/null || true)
  [[ ${#_el[@]} -gt 0 ]] && EXEMPT_LABELS=("${_el[@]}")
fi

# --- PR body: explicit arg > file > gh API > env ---
if [[ -z "$PR_BODY" && -n "$PR_BODY_FILE" && -f "$PR_BODY_FILE" ]]; then
  PR_BODY=$(cat "$PR_BODY_FILE")
fi
if [[ -z "$PR_BODY" && -n "${GITHUB_EVENT_PATH:-}" && -f "$GITHUB_EVENT_PATH" ]]; then
  PR_BODY=$(python3 -c "import json,os; print(json.load(open(os.environ['GITHUB_EVENT_PATH'])).get('pull_request',{}).get('body','') or '')" 2>/dev/null || echo "")
fi
if [[ -z "$PR_BODY" && -n "$PR_NUMBER" ]] && command -v gh >/dev/null 2>&1; then
  PR_BODY=$(gh pr view "$PR_NUMBER" --json body -q '.body // ""' 2>/dev/null || echo "")
fi

# --- changed files ---
CHANGED=()
if [[ -n "$FILES_OVERRIDE" ]]; then
  read -ra CHANGED <<< "$FILES_OVERRIDE"
else
  if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    mapfile -t CHANGED < <(git diff --name-only --diff-filter=ACMRT "$BASE"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")
  else
    mapfile -t CHANGED < <(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only --cached 2>/dev/null || echo "")
  fi
  if [[ ${#CHANGED[@]} -eq 0 || -z "${CHANGED[0]:-}" ]]; then
    mapfile -t CHANGED < <(git diff --name-only 2>/dev/null || echo "")
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

# --- exempt? (docs-only / exempt paths / exempt labels) ---
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
    echo "::warning::plan-link-gate could not read PR #$PR_NUMBER labels (gh auth? missing GITHUB_TOKEN?) — exempt-label check skipped" >&2
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

# min-lines threshold: tiny PRs skip unless --strict
ADDED_LINES=0
if [[ -z "$EXEMPT_REASON" && "$MIN_LINES_FOR_PLAN" != "0" ]]; then
  if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    ADDED_LINES=$(git diff --numstat "$BASE"...HEAD 2>/dev/null | awk '{a+=$1} END {print a+0}')
  else
    ADDED_LINES=$(git diff --numstat HEAD~1 2>/dev/null | awk '{a+=$1} END {print a+0}')
  fi
  if [[ "$ADDED_LINES" -lt "$MIN_LINES_FOR_PLAN" && "$STRICT" == false ]]; then
    EXEMPT_REASON="small change (${ADDED_LINES} lines < ${MIN_LINES_FOR_PLAN})"
  fi
fi

# --- plan-link signals ---
LINK_SIGNALS=()
if [[ -n "$PR_BODY" ]]; then
  echo "$PR_BODY" | grep -Eq '(Closes|Fixes|Resolves)[[:space:]]+#[0-9]+' && LINK_SIGNALS+=("issue-link")
  echo "$PR_BODY" | grep -Eqi '(^|[^a-z])(Plan|RFC|Spec|Design|Proposal)[[:space:]]*(:|#|https?://|plans?/)' && LINK_SIGNALS+=("plan-keyword")
  for pp in "plans/" "docs/plans/" "docs/plan/" "docs/rfcs/" "docs/rfc/" ".github/plans/" "ref.plan.md" "PLAN.md" "ref.tools"; do
    if echo "$PR_BODY" | grep -Fq "$pp"; then LINK_SIGNALS+=("plan-path:$pp"); break; fi
  done
fi
PLAN_FILE_TOUCHED=""
for f in "${CHANGED[@]}"; do
  for pat in "${PLAN_PATHS[@]}"; do
    if match_path "$f" "$pat"; then PLAN_FILE_TOUCHED="$f"; LINK_SIGNALS+=("plan-file:$f"); break 2; fi
  done
done

emit_json() {
  local result="$1" reason="$2"
  python3 -c "
import json
print(json.dumps({
  'pass': True if '$result' == 'pass' else False,
  'exempt': bool('''$EXEMPT_REASON'''),
  'exempt_reason': '''$EXEMPT_REASON''',
  'signals': '''${LINK_SIGNALS[*]}'''.split() if '''${LINK_SIGNALS[*]}''' else [],
  'plan_file_touched': '''$PLAN_FILE_TOUCHED''',
  'changed_files': '''${CHANGED[*]}'''.split() if '''${CHANGED[*]}''' else [],
  'reason': '''$reason'''
}, indent=2))
"
}

if [[ -n "$EXEMPT_REASON" ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "exempt: $EXEMPT_REASON" || echo "✓ plan-link-gate passed (exempt: $EXEMPT_REASON)"
  exit 0
fi

if [[ "$REQUIRE_LINK" != "true" ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "disabled via plan.require_link" || echo "✓ plan-link-gate passed (disabled via plan.require_link=false)"
  exit 0
fi

if [[ ${#LINK_SIGNALS[@]} -gt 0 ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "plan linked via ${LINK_SIGNALS[*]}" || echo "✓ plan-link-gate passed (plan linked: ${LINK_SIGNALS[*]})"
  exit 0
fi

# fail
MSG="❌ plan-link-gate FAILED: non-exempt PR has no linked plan."
HINT="Fix: add 'Closes #N' or a 'Plan: <path|URL>' line to the PR body (plans/, docs/plans/, docs/rfcs/), or include the plan file in this PR (review moves to planning; PR must show conformance)."
if [[ "$OUTPUT_JSON" == true ]]; then
  emit_json fail "$MSG $HINT"
else
  echo "$MSG" >&2
  echo "Changed: ${CHANGED[*]:-(none)}" >&2
  echo "" >&2
  echo "$HINT" >&2
fi
exit 1
