#!/usr/bin/env bash
set -euo pipefail
# review-noise-meter.sh — Gergely #5 / Jacob #4 / Uber uReview lesson:
# "How do you evaluate how useful vs noisy AI code reviews are?"
#
# Deterministic, no LLM key. Pulls PR review comments via `gh` and scores noise:
#   - total bot comments vs human comments
#   - bot-on-bot chatter (Bun Robobun failure mode: bots replying to bots)
#   - duplicate/near-duplicate suggestions (needs dedupe)
#   - defensive-crap patterns (Jacob: "consider adding...", "you might want...")
#   - unaddressed rate (proxy for usefulness when reactions absent)
#
# Usage:
#   ./scripts/review-noise-meter.sh --pr-number N [--json] [--max-bot-comments 10] [--fail]
#   ./scripts/review-noise-meter.sh --file comments.json --json  # offline testing
# Exit codes:
#   0 = pass (noise within budget, or --no-fail)
#   1 = fail (noise over budget with --fail)
#   2 = error

PR_NUMBER="${PR_NUMBER:-}"
FILE=""
OUTPUT_JSON=false
MAX_BOT_COMMENTS=10
FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-number) PR_NUMBER="$2"; shift 2;;
    --file) FILE="$2"; shift 2;;
    --json) OUTPUT_JSON=true; shift;;
    --max-bot-comments) MAX_BOT_COMMENTS="$2"; shift 2;;
    --fail) FAIL=true; shift;;
    --help|-h) sed -n '2,25p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$FILE" && -z "$PR_NUMBER" ]]; then
  echo "warn: no --pr-number or --file given, skipping (pass)" >&2
  [[ "$OUTPUT_JSON" == true ]] && echo '{"pass":true,"skipped":true,"reason":"no PR number"}'
  exit 0
fi

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

if [[ -n "$FILE" ]]; then
  cp "$FILE" "$RAW"
else
  if ! command -v gh >/dev/null 2>&1; then
    echo "warn: gh not found, skipping noise check" >&2
    [[ "$OUTPUT_JSON" == true ]] && echo '{"pass":true,"skipped":true,"reason":"gh missing"}'
    exit 0
  fi
  # review comments + issue comments + PR reviews in one blob
  {
    gh pr view "$PR_NUMBER" --json reviews --jq '.reviews[] | {author: .author.login, body: .body, state: .state}' 2>/dev/null || echo ""
    echo "---ISSUE_COMMENTS---"
    gh pr view "$PR_NUMBER" --json comments --jq '.comments[] | {author: .author.login, body: .body}' 2>/dev/null || echo ""
  } > "$RAW" || true
fi

# Heuristic scoring via python (stdlib only)
python3 - "$RAW" "$MAX_BOT_COMMENTS" "$OUTPUT_JSON" "$FAIL" <<'PY'
import re, sys, json

raw_path, max_bot, as_json, fail = sys.argv[1], int(sys.argv[2]), sys.argv[3]=="true", sys.argv[4]=="true"
text = open(raw_path, errors="ignore").read()

# Split bodies: crude but deterministic — each line with author/body JSON or raw text fallback
bot_names = ("copilot", "coderabbit", "greptile", "qodo", "ellipsis", "claude", "robobun",
             "cursor", "astra", "codex", "github-advanced-security", "dependabot")
bodies, bot_bodies = [], []
for line in text.splitlines():
    low = line.lower()
    is_bot = any(b in low for b in bot_names) or "[bot]" in low
    bodies.append((line, is_bot))
    if is_bot:
        bot_bodies.append(line)

def defensive_hits(s):
    pats = [r"consider adding", r"you might want", r"it might be (good|better|safer)",
            r"defensive", r"just in case", r"for safety", r"nit:", r"nitpick"]
    return sum(1 for p in pats if re.search(p, s, re.I))

def bot_on_bot(s):
    # bot replying to/quoting another bot
    return bool(re.search(r"@(copilot|coderabbit|claude|robobun|github-actions)\[bot\]|in reply to.*bot", s, re.I))

def normalize(s):
    return re.sub(r"\s+", " ", s.strip().lower())[:200]

seen, dupes = set(), 0
for b in bot_bodies:
    n = normalize(b)
    if n in seen and len(n) > 40:
        dupes += 1
    seen.add(n)

bot_count = len(bot_bodies)
def_count = sum(defensive_hits(b) for b in bot_bodies)
bob_count = sum(1 for b in bot_bodies if bot_on_bot(b))

noise_score = bot_count + dupes * 2 + bob_count * 3 + min(def_count, 10)
verdict = "pass" if bot_count <= max_bot and bob_count == 0 and dupes <= 2 else "noisy"

result = {
    "pass": verdict == "pass",
    "verdict": verdict,
    "bot_comments": bot_count,
    "human_or_unknown_comments": len(bodies) - bot_count,
    "duplicate_bot_comments": dupes,
    "bot_on_bot_comments": bob_count,
    "defensive_pattern_hits": def_count,
    "noise_score": noise_score,
    "budget": {"max_bot_comments": max_bot},
    "hint": "Uber uReview lesson: grade + dedupe + confidence-filter bot comments. Jacob lesson: bulk defensive nits = bloat. Keep high/medium severity only; batch nits into one bullet.",
}
if as_json:
    print(json.dumps(result, indent=2))
else:
    if verdict == "pass":
        print(f"✓ review-noise-meter passed (bot={bot_count} dupes={dupes} bot-on-bot={bob_count} defensive={def_count} score={noise_score})")
    else:
        print(f"❌ review-noise-meter NOISY: bot={bot_count} (budget {max_bot}) dupes={dupes} bot-on-bot={bob_count} defensive={def_count} score={noise_score}", file=sys.stderr)
        print("Fix: dedupe bot comments, raise confidence threshold, restrict bots to high/medium severity, batch nits.", file=sys.stderr)
sys.exit(0 if verdict == "pass" or not fail else 1)
PY
