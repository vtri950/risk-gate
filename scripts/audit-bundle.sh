#!/usr/bin/env bash
set -eo pipefail
# NOTE: no `set -u` — bash 3.2 (macOS) treats empty arrays as unbound.
# audit-bundle.sh — collects SOC2 evidence: every deterministic gate decision in one artifact.
#
# Collects every deterministic gate decision into one artifact:
#   risk tier + hits + inbox, plan-link, schema-gate, docs/skills gates,
#   coverage/lint (if present), git SHA, actor, PR labels/approvals (via gh if authed).
# Upload the output dir as a CI artifact; retain 1y for auditors.
#
# Usage:
#   ./scripts/audit-bundle.sh [--pr-number N] [--out audit/risk-gate-<sha>] [--json]
#   GITHUB_* envs are picked up automatically in Actions.
# Exit: always 0 (never block merge; it only records).

PR_NUMBER="${PR_NUMBER:-}"
OUT=""
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-number) PR_NUMBER="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --json) OUTPUT_JSON=true; shift;;
    --help|-h) sed -n '2,18p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
SHORT=$(echo "$SHA" | cut -c1-7)
ACTOR="${GITHUB_ACTOR:-$(git config user.name 2>/dev/null || echo unknown)}"
REPO="${GITHUB_REPOSITORY:-unknown}"
[[ -z "$OUT" ]] && OUT="audit/risk-gate-${SHORT:-local}"
mkdir -p "$OUT"

run_gate() { # name, command... — never fails, records stdout+exit
  local name="$1"; shift
  local out="$OUT/${name}.json"
  local code=0
  "$@" --json > "$out" 2>"$OUT/${name}.stderr" || code=$?
  python3 -c "
import json
p='$out'
try: d=json.load(open(p))
except Exception: d={'raw': open(p, errors='ignore').read()[:4000]}
d['_exit_code']=int('$code')
json.dump(d, open(p,'w'), indent=2)
" 2>/dev/null || true
  echo "$code"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISK_CODE=$(run_gate risk-gate "$SCRIPT_DIR/risk-gate.sh" --json || true)
PLAN_CODE=$(run_gate plan-link "$SCRIPT_DIR/plan-link-gate.sh" --json ${PR_NUMBER:+--pr-number "$PR_NUMBER"} || true)
SCHEMA_CODE=$(run_gate schema-gate "$SCRIPT_DIR/schema-gate.sh" --json ${PR_NUMBER:+--pr-number "$PR_NUMBER"} || true)
HANDOFF_CODE=$(run_gate handoff-gate "$SCRIPT_DIR/handoff-gate.sh" --json ${PR_NUMBER:+--pr-number "$PR_NUMBER"} || true)
PREVENTION_CODE=$(run_gate prevention-gate "$SCRIPT_DIR/prevention-gate.sh" --json ${PR_NUMBER:+--pr-number "$PR_NUMBER"} || true)

# docs/skills gates are pass/fail text — wrap as JSON
for g in docs-gate skills-isolation; do
  if [[ -x "$SCRIPT_DIR/$g.sh" ]]; then
    code=0
    "$SCRIPT_DIR/$g.sh" > "$OUT/${g}.log" 2>&1 || code=$?
    python3 -c "import json; json.dump({'pass': bool(1-int('$code')), 'exit_code': int('$code'), 'log': open('$OUT/${g}.log', errors='ignore').read()[:3000]}, open('$OUT/${g}.json','w'), indent=2)"
  fi
done

# PR metadata (best-effort via gh)
LABELS="[]"; APPROVALS="[]"; PR_BODY_LEN=0
if [[ -n "$PR_NUMBER" ]] && command -v gh >/dev/null 2>&1; then
  LABELS=$(gh pr view "$PR_NUMBER" --json labels -q '.labels[].name' 2>/dev/null | python3 -c "import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))" 2>/dev/null || echo "[]")
  APPROVALS=$(gh pr view "$PR_NUMBER" --json reviews -q '.reviews[] | "\(.author.login):\(.state)"' 2>/dev/null | python3 -c "import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))" 2>/dev/null || echo "[]")
fi

python3 - "$OUT" "$SHA" "$ACTOR" "$REPO" "$PR_NUMBER" "$LABELS" "$APPROVALS" "$RISK_CODE" "$PLAN_CODE" "$SCHEMA_CODE" <<'PY'
import json, sys, datetime, glob, os
out, sha, actor, repo, pr, labels, approvals, rc, pc, sc = sys.argv[1:11]
def load(n):
    try: return json.load(open(f"{out}/{n}.json"))
    except Exception: return {"missing": True}
risk, plan, schema = load("risk-gate"), load("plan-link"), load("schema-gate")
handoff, prevention = load("handoff-gate"), load("prevention-gate")
bundle = {
    "generated_at": datetime.datetime.utcnow().isoformat() + "Z",
    "repo": repo, "sha": sha, "actor": actor, "pr_number": pr or None,
    "conclusion": {
        "tier": risk.get("tier", "unknown"),
        "risky": risk.get("risky"),
        "plan_pass": plan.get("pass"), "schema_pass": schema.get("pass"),
        "handoff_pass": handoff.get("pass"), "prevention_pass": prevention.get("pass"),
    },
    "policy": "risk-based review (DuckbillHQ pattern): P0 blocking human approval via branch protection; "
              "P1 advisory; P2 auto-merge allowed. Guardrails: plan-link, handoff DoD, prevention trail, "
              "schema-gate, docs-gate, skills-isolation, coverage floor 85, lint max. See .github/risk-gate.yml.",
    "labels": json.loads(labels or "[]"),
    "approvals": json.loads(approvals or "[]"),
    "gates": {"risk-gate": risk, "plan-link": plan, "schema-gate": schema,
              "handoff-gate": handoff, "prevention-gate": prevention,
              "docs-gate": load("docs-gate"), "skills-isolation": load("skills-isolation")},
    "auditor_note": "For SOC2: P0 PRs require human approval (branch protection on label needs-human-review). "
                    "P2 PRs merge with deterministic guardrails; this bundle is the evidence. Retain as CI artifact.",
}
json.dump(bundle, open(f"{out}/audit-bundle.json", "w"), indent=2)
md = [f"# risk-gate audit bundle — {sha[:7]}",
      f"- repo: {repo} | actor: {actor} | PR: {pr or 'n/a'} | at: {bundle['generated_at']}",
      f"- tier: {bundle['conclusion']['tier']} | risky: {bundle['conclusion']['risky']} | "
      f"plan: {bundle['conclusion']['plan_pass']} | schema: {bundle['conclusion']['schema_pass']} | "
      f"handoff: {bundle['conclusion']['handoff_pass']} | prevention: {bundle['conclusion']['prevention_pass']}",
      f"- labels: {', '.join(bundle['labels']) or '(none)'}",
      f"- policy: {bundle['policy']}", "", "## Gate files", ""]
for f in sorted(glob.glob(f"{out}/*.json")):
    md.append(f"- `{os.path.basename(f)}`")
open(f"{out}/AUDIT.md", "w").write("\n".join(md) + "\n")
print(json.dumps({"bundle": f"{out}/audit-bundle.json", "tier": bundle["conclusion"]["tier"]}, indent=2))
PY

if [[ "$OUTPUT_JSON" == true ]]; then
  cat "$OUT/audit-bundle.json"
else
  echo "✓ audit-bundle wrote $OUT/audit-bundle.json + AUDIT.md (tier + all gate decisions)"
fi
exit 0
