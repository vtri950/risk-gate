#!/usr/bin/env bash
set -eo pipefail
# NOTE: no `set -u` — bash 3.2 (macOS) treats empty arrays as unbound.
# schema-gate.sh — Jackie Luo (Sigil) lesson: "all that really matters is the database schema."
# Data/state is rigid; stateless logic is fluid/regenerable. So schema + API contracts
# always deserve human review, even when risk-gate tiers miss them.
#
# Detects: prisma/drizzle/alembic/django migrations, *.sql, ORM models,
# OpenAPI/MCP/proto/GraphQL contracts, mcp/** skills touching state.
# Requires: PR body names the migration/rollback (BREAKING_MIGRATION, Schema:, Migration:)
#           unless --advisory (then warn-only).
#
# Usage:
#   ./scripts/schema-gate.sh [--base origin/main] [--files "..."] [--pr-body "..."]
#     [--pr-number N] [--json] [--advisory]
# Exit: 0 pass (no schema touch, or annotated), 1 fail (schema touch, no annotation), 2 error

CONFIG=".github/risk-gate.yml"
BASE="origin/main"
FILES_OVERRIDE=""
PR_BODY=""
PR_NUMBER="${PR_NUMBER:-}"
OUTPUT_JSON=false
ADVISORY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --files) FILES_OVERRIDE="$2"; shift 2;;
    --pr-body) PR_BODY="$2"; shift 2;;
    --pr-number) PR_NUMBER="$2"; shift 2;;
    --json) OUTPUT_JSON=true; shift;;
    --advisory) ADVISORY=true; shift;;
    --help|-h) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# PR body fallback: gh / event path
if [[ -z "$PR_BODY" && -n "$PR_NUMBER" ]] && command -v gh >/dev/null 2>&1; then
  PR_BODY=$(gh pr view "$PR_NUMBER" --json body -q '.body // ""' 2>/dev/null || echo "")
fi
if [[ -z "$PR_BODY" && -n "${GITHUB_EVENT_PATH:-}" && -f "$GITHUB_EVENT_PATH" ]]; then
  PR_BODY=$(python3 -c "import json,os; print(json.load(open(os.environ['GITHUB_EVENT_PATH'])).get('pull_request',{}).get('body','') or '')" 2>/dev/null || echo "")
fi

CHANGED=()
if [[ -n "$FILES_OVERRIDE" ]]; then
  read -ra CHANGED <<< "$FILES_OVERRIDE"
else
  if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    while IFS= read -r f; do [[ -n "$f" ]] && CHANGED+=("$f"); done < <(git diff --name-only --diff-filter=ACMRT "$BASE"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")
  else
    while IFS= read -r f; do [[ -n "$f" ]] && CHANGED+=("$f"); done < <(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only --cached 2>/dev/null || echo "")
  fi
  if [[ ${#CHANGED[@]} -eq 0 ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && CHANGED+=("$f"); done < <(git diff --name-only 2>/dev/null || echo "")
  fi
fi

python3 - "$OUTPUT_JSON" "$ADVISORY" "$PR_BODY" "${CHANGED[@]}" <<'PY'
import re, sys, json

as_json = sys.argv[1] == "true"
advisory = sys.argv[2] == "true"
body = sys.argv[3] or ""
files = [a for a in sys.argv[4:] if a]

SCHEMA_GLOBS = [
    r"prisma/schema\.prisma$", r"prisma/migrations/", r"drizzle/", r"migrations?/",
    r"alembic/", r".*\.sql$", r"db/schema\.rb$", r"schema\.xml$",
    r"src/models?/", r"src/schemas?/", r"src/entities/", r"models?/.*\.py$",
    r"knexfile.*", r"ormconfig.*", r"drizzle\.config\..*",
]
CONTRACT_GLOBS = [
    r"openapi.*\.ya?ml$", r"openapi.*\.json$", r"api/openapi", r"mcp/.*\.json$",
    r".*\.proto$", r"schema\.graphql$", r".*\.graphqls?$", r"asyncapi.*",
]
NON_ADDITIVE_HINTS = [r"drop\s+(table|column)", r"alter\s+column", r"rename\s+column",
                      r"dropnotnull", r"removecolumn", r"::retry", r"down\("]

def hit(path):
    for rx in SCHEMA_GLOBS:
        if re.search(rx, path, re.I):
            return ("schema", rx)
    for rx in CONTRACT_GLOBS:
        if re.search(rx, path, re.I):
            return ("contract", rx)
    return None

hits = []
for f in files:
    h = hit(f)
    if h:
        hits.append({"file": f, "kind": h[0], "via": h[1]})

annotated = bool(re.search(r"(BREAKING_MIGRATION|Schema\s*:|Migration\s*:|Rollback\s*:|Closes\s+#\d+)", body, re.I))
risky_body = False
for f in files:
    if f.endswith(".sql") or "migration" in f.lower():
        try:
            import subprocess
            diff = subprocess.run(["git", "diff", "--cached", "--", f],
                                  capture_output=True, text=True).stdout
            if any(re.search(p, diff, re.I) for p in NON_ADDITIVE_HINTS):
                risky_body = True
        except Exception:
            pass

passed = (not hits) or annotated
result = {
    "pass": passed or advisory,
    "advisory": advisory,
    "schema_hits": hits,
    "annotated": annotated,
    "non_additive_suspected": risky_body,
    "changed_files": files,
    "reason": ("no schema/contract touch" if not hits else
               ("annotated" if annotated else "schema/contract touched without Schema:/Migration: annotation")),
    "hint": "Jackie Luo rule: data is rigid, logic is fluid. Schema/API changes need human review + rollback plan. Add 'Schema: <what changed + rollback>' to PR body.",
}
if as_json:
    print(json.dumps(result, indent=2))
else:
    if not hits:
        print("✓ schema-gate passed (no schema/contract files touched)")
    elif annotated:
        print(f"✓ schema-gate passed (annotated, {len(hits)} schema/contract files)")
        for h in hits:
            print(f"  - {h['file']} [{h['kind']}]")
    else:
        print(f"❌ schema-gate FAILED: {len(hits)} schema/contract files without annotation", file=sys.stderr)
        for h in hits:
            print(f"  - {h['file']} [{h['kind']} via {h['via']}]", file=sys.stderr)
        print("Fix: add 'Schema: ...' or 'BREAKING_MIGRATION' + rollback to PR body.", file=sys.stderr)
sys.exit(0 if (passed or advisory) else 1)
PY
