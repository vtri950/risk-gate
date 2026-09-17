#!/usr/bin/env bash
set -eo pipefail
# NOTE: no `set -u` — bash 3.2 (macOS) treats empty arrays as unbound.
# handoff-gate.sh — deterministic handoff definition-of-done gate (no LLM key)
# Worker handoffs without acceptance criteria waste the review cycle:
# reviewer asks for repro steps, worker context-switches back, repeat.
# This gate requires non-exempt PRs to state how the change was verified,
# and UI/perf PRs to attach evidence (screenshot, video, or perf numbers).
#
# Usage:
#   ./scripts/handoff-gate.sh [--config .github/risk-gate.yml] [--base origin/main]
#                             [--files "a.ts b.ts"] [--pr-body "..."] [--pr-body-file FILE]
#                             [--pr-number N] [--json] [--strict]
# Exit codes:
#   0 = pass (DoD present, or PR exempt)
#   1 = fail (non-exempt PR missing verify steps or required artifact)
#   2 = error
#
# Deterministic signals (no AI):
#   1. PR body contains a verify section: Verify:/Verified:/Test:/Tests:/
#      Tested:/Repro:/Steps:/How to verify/How I verified.
#   2. If the diff touches UI/perf paths, the body must also name an
#      artifact: screenshot/video/screencast/perf/trace/flamegraph/preview.
#      --strict requires the artifact line on every non-exempt PR.
#   3. Docs-only / exempt-path / exempt-label PRs skip the requirement.

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
    --help|-h) sed -n '2,22p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

REQUIRE_VERIFY="true"
UI_PATTERNS=("*.tsx" "*.jsx" "*.css" "*.scss" "**/components/**" "*perf*" "*benchmark*" "**/screenshots/**")
ARTIFACT_RES=("screenshot" "video" "screencast" "perf" "trace" "flamegraph" "preview" "storybook" "lighthouse")
EXEMPT_PATHS=("docs/**" "*.md" ".github/copilot-instructions.md")
EXEMPT_LABELS=("chore" "deps" "dependabot")

if [[ -f "$CONFIG" ]] && command -v yq >/dev/null 2>&1; then
  v=$(yq -r '.handoff.require_verify // "true"' "$CONFIG" 2>/dev/null || echo "true")
  [[ -n "$v" ]] && REQUIRE_VERIFY="$v"
  read_lines_cfg() { local __a="$1" __q="$2" __l; eval "$__a=()"; while IFS= read -r __l; do [[ -n "$__l" ]] || continue; eval "$__a+=(\"\$__l\")"; done < <(yq -r "$__q" "$CONFIG" 2>/dev/null || true); return 0; }
  read_lines_cfg _up '.handoff.ui_patterns[]?'
  [[ ${#_up[@]} -gt 0 ]] && UI_PATTERNS=("${_up[@]}")
  read_lines_cfg _ar '.handoff.artifact_keywords[]?'
  [[ ${#_ar[@]} -gt 0 ]] && ARTIFACT_RES=("${_ar[@]}")
  read_lines_cfg _ep '.handoff.exempt_paths[]?'
  [[ ${#_ep[@]} -gt 0 ]] && EXEMPT_PATHS=("${_ep[@]}")
  read_lines_cfg _el '.handoff.exempt_labels[]?'
  [[ ${#_el[@]} -gt 0 ]] && EXEMPT_LABELS=("${_el[@]}")
fi

# --- PR body: explicit arg > file > live gh API > stale event payload ---
# NOTE: gh first — GITHUB_EVENT_PATH is frozen at event time, so reruns after a
# PR-body edit would otherwise keep failing on the stale body.
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
    echo "::warning::handoff-gate could not read PR #$PR_NUMBER labels (gh auth? missing GITHUB_TOKEN?) — exempt-label check skipped" >&2
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

# --- DoD signals ---
VERIFY_RES='(^|[^a-zA-Z])(Verify|Verified|Test plan|Tests?|Tested|Repro|Steps|How to verify|How I verified)[^a-zA-Z]*:'
HAS_VERIFY=false
[[ -n "$PR_BODY" ]] && echo "$PR_BODY" | grep -Eqi "$VERIFY_RES" && HAS_VERIFY=true

UI_TOUCHED=""
for f in "${NONEXEMPT[@]}"; do
  for pat in "${UI_PATTERNS[@]}"; do
    if match_path "$f" "$pat"; then UI_TOUCHED="$f"; break 2; fi
  done
done

HAS_ARTIFACT=false
if [[ -n "$PR_BODY" ]]; then
  for kw in "${ARTIFACT_RES[@]}"; do
    if echo "$PR_BODY" | grep -Fqi "$kw"; then HAS_ARTIFACT=true; break; fi
  done
fi

NEEDS_ARTIFACT=false
[[ -n "$UI_TOUCHED" || "$STRICT" == true ]] && NEEDS_ARTIFACT=true

emit_json() {
  local result="$1" reason="$2"
  python3 -c "
import json
print(json.dumps({
  'pass': True if '$result' == 'pass' else False,
  'exempt': bool('''$EXEMPT_REASON'''),
  'exempt_reason': '''$EXEMPT_REASON''',
  'has_verify': bool('''$([ "$HAS_VERIFY" == true ] && echo x)'''),
  'ui_touched': '''$UI_TOUCHED''',
  'has_artifact': bool('''$([ "$HAS_ARTIFACT" == true ] && echo x)'''),
  'changed_files': '''${CHANGED[*]}'''.split() if '''${CHANGED[*]}''' else [],
  'reason': '''$reason'''
}, indent=2))
"
}

if [[ -n "$EXEMPT_REASON" ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "exempt: $EXEMPT_REASON" || echo "✓ handoff-gate passed (exempt: $EXEMPT_REASON)"
  exit 0
fi

if [[ "$REQUIRE_VERIFY" != "true" ]]; then
  [[ "$OUTPUT_JSON" == true ]] && emit_json pass "disabled via handoff.require_verify" || echo "✓ handoff-gate passed (disabled via handoff.require_verify=false)"
  exit 0
fi

if [[ "$HAS_VERIFY" == false ]]; then
  MSG="❌ handoff-gate FAILED: non-exempt PR has no verify section."
  HINT="Fix: add a 'Verify:' (or Test:/Repro:/Steps:) block to the PR body — changed files plus how the change was checked. Worker handoffs without acceptance criteria bounce back; write it once here."
  if [[ "$OUTPUT_JSON" == true ]]; then
    emit_json fail "$MSG $HINT"
  else
    echo "$MSG" >&2
    echo "Changed: ${CHANGED[*]:-(none)}" >&2
    echo "" >&2
    echo "$HINT" >&2
  fi
  exit 1
fi

if [[ "$NEEDS_ARTIFACT" == true && "$HAS_ARTIFACT" == false ]]; then
  MSG="❌ handoff-gate FAILED: UI/perf change has no evidence artifact."
  HINT="Fix: name the evidence in the PR body — screenshot, video, or perf numbers (touched: $UI_TOUCHED). Keywords: ${ARTIFACT_RES[*]}."
  if [[ "$OUTPUT_JSON" == true ]]; then
    emit_json fail "$MSG $HINT"
  else
    echo "$MSG" >&2
    echo "Touched: $UI_TOUCHED" >&2
    echo "" >&2
    echo "$HINT" >&2
  fi
  exit 1
fi

[[ "$OUTPUT_JSON" == true ]] && emit_json pass "definition-of-done present" || echo "✓ handoff-gate passed (verify present$([ -n "$UI_TOUCHED" ] && echo ", artifact present"))"
exit 0
