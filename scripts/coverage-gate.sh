#!/usr/bin/env bash
set -euo pipefail
# coverage-gate.sh — enforces floor 85% (Duckbill pattern)
# Usage: ./scripts/coverage-gate.sh [--floor 85] [--file coverage/coverage-final.json] [--lcov coverage/lcov.info]

FLOOR=85
FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --floor) FLOOR="$2"; shift 2;;
    --file) FILE="$2"; shift 2;;
    --lcov) FILE="$2"; shift 2;;
    *) shift;;
  esac
done

# also read from config if yq available
if [[ -f ".github/risk-gate.yml" ]] && command -v yq >/dev/null 2>&1; then
  CFG_FLOOR=$(yq -r '.guardrails.coverage_floor // ""' .github/risk-gate.yml 2>/dev/null || echo "")
  if [[ -n "$CFG_FLOOR" && "$FLOOR" == "85" ]]; then
    FLOOR="$CFG_FLOOR"
  fi
fi

# auto-discover file
if [[ -z "$FILE" ]]; then
  for cand in "coverage/coverage-final.json" "coverage.json" "coverage-summary.json" "coverage/lcov.info" "lcov.info"; do
    if [[ -f "$cand" ]]; then FILE="$cand"; break; fi
  done
fi

if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  echo "warn: no coverage file found (tried coverage/coverage-final.json, coverage.json, lcov.info)" >&2
  echo "hint: run tests with --coverage first, or pass --file <path>" >&2
  exit 0
fi

PCT=""
if [[ "$FILE" == *.json ]]; then
  PCT=$(python3 -c "
import json, sys
p=sys.argv[1]
try:
    d=json.load(open(p))
    # try coverage-summary shape
    if 'total' in d and 'lines' in d['total']:
        print(d['total']['lines']['pct'])
    elif 'total' in d:
        print(d['total'].get('pct', d['total'].get('percent', '')))
    # jest coverage-final: sum lines
    else:
        total=0; covered=0
        for f,v in d.items():
            if isinstance(v, dict) and 's' in v:
                s=v['s']
                total+=len(s)
                covered+=sum(1 for x in s.values() if x>0)
        if total>0:
            print(round(covered/total*100,2))
        else:
            print('')
except Exception as e:
    print('')
" "$FILE")
else
  # lcov
  PCT=$(python3 -c "
import sys
p=sys.argv[1]
lf=lh=0
for line in open(p):
    if line.startswith('LF:'): lf+=int(line.split(':')[1])
    if line.startswith('LH:'): lh+=int(line.split(':')[1])
if lf>0:
    print(round(lh/lf*100,2))
" "$FILE")
fi

if [[ -z "$PCT" ]]; then
  echo "warn: could not parse coverage from $FILE" >&2
  exit 0
fi

echo "Coverage: ${PCT}% (floor ${FLOOR}%) from $FILE"

python3 -c "
import sys
pct=float(sys.argv[1])
floor=float(sys.argv[2])
sys.exit(0 if pct>=floor else 1)
" "$PCT" "$FLOOR"

if [[ $? -eq 0 ]]; then
  echo "✓ coverage-gate passed"
  exit 0
else
  echo "❌ coverage-gate FAILED: ${PCT}% < ${FLOOR}%" >&2
  exit 1
fi
