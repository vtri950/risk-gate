# risk-gate — Ditch Code Review (Mostly)

Deterministic toolkit implementing the DuckbillHQ pattern from [Mike Julian's thread](https://x.com/mikejulian/status/2096450476170694785):

> 60 open PRs → 2 days of review → switched to risk-based review + strict guardrails → **353 → 684 PRs (+94%)**, median **1h** (vs 26h for human-reviewed)

Plan-first layer: review moves to planning, PRs prove conformance (plan link) + pass separate bug / security / lint-test checks + preview deploy for UI spot-checks.

No AI for routing — shell scripts + GitHub labels. Expensive guardrails buy back safety.

## What you get (100%)

| Primitive | Script | What it does |
|---|---|---|
| **#1 Risk Gate** | `scripts/risk-gate.sh` + `action.yml` | Labels `needs-human-review` only if diff touches `api/mcp/auth/design-system/skills/migrations` |
| **#1b Copilot Mesh** | `.github/workflows/copilot-mesh.yml` + `scripts/generate-copilot-instructions.sh` | Cosmos-style orchestration on native Copilot: SAFE → `copilot-safe` + auto-merge, RISKY → Pair Reviewer checklist. No LLM key |
| **#2a Docs Gate** | `scripts/docs-gate.sh` | Fails if `*.md` outside `docs/` — prevents context poisoning |
| **#2b Skills Isolation** | `scripts/skills-isolation.sh` | Forces `skills/`, `AGENTS.md`, `.opencode/` into solo PRs |
| **#2c Coverage Gate** | `scripts/coverage-gate.sh --floor 85` | Enforces 85% floor |
| **#2d Lint Gate** | `scripts/lint-gate.sh` | Runs `ruff/ty/prettier/eslint` with max rules |
| **#4 Plan-Conformance Gate** | `scripts/plan-link-gate.sh` | Requires non-exempt PRs to link a plan (`Closes #N`, `Plan:`/`RFC:`, or a `plans/` path) |
| **#3 Skills Auditor** | `auditor/skills-auditor.mjs` | Evals which skills are obsolete vs LLM knowledge — PRUNE/REWRITE/KEEP |

## Quick start (1 minute per repo)

```bash
# 1. Copy into your repo
cp -r /path/to/risk-gate/scripts ./
cp /path/to/risk-gate/.github/risk-gate.yml .github/
chmod +x scripts/*.sh

# 2. Customize risky paths
vim .github/risk-gate.yml

# 3. Wire CI (GitHub Actions)
# .github/workflows/ci.yml
jobs:
  risk-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: ./risk-gate  # or copy action.yml locally
      - run: ./scripts/docs-gate.sh
      - run: ./scripts/plan-link-gate.sh --pr-number ${{ github.event.pull_request.number }}
      - run: ./scripts/skills-isolation.sh
      - run: ./scripts/coverage-gate.sh --floor 85
```

### Branch protection (required for the magic)

Repo → Settings → Branches → Require status checks + **Require pull request reviews only if label `needs-human-review` present**.

In practice: add a rule via `action.yml` output `risky`:
- If `risky == true` → require 1 approval
- If `risky == false` → auto-merge allowed (1h median)

## Copilot Mesh (Cosmos-style, no LLM key)

Deterministic Risk Analyzer + native Copilot Deep Reviewer + auto-merge. Your repos already have Copilot — this is the glue.

```bash
# 1. Generate Copilot memory from your risk policy
./scripts/generate-copilot-instructions.sh
# → .github/copilot-instructions.md (Copilot reads this on every review)

# 2. Workflow is already wired: .github/workflows/copilot-mesh.yml
# SAFE  → copilot-safe label + guidance comment + gh pr merge --auto
# RISKY → needs-human-review label + Pair Reviewer checklist comment

# 3. Re-run generator after changing .github/risk-gate.yml
# CI fails on drift via --check
```

One-time GitHub setup per repo (5 min):
1. Settings → Rules → Rulesets → New branch ruleset → target `main` → ✅ `Automatically request Copilot code review` + `Review new pushes`
2. Settings → Copilot → Code review → effort `Lite` (cheap) or `Balanced` (deep), Auto-approval globs for low-risk (`docs/**`, `*.md`)
3. Settings → General → ✅ Allow auto-merge + auto-delete head branches
4. Copy into any repo: `scripts/risk-gate.sh`, `scripts/generate-copilot-instructions.sh`, `.github/risk-gate.yml`, `examples/copilot-mesh.yml.example` → `.github/workflows/copilot-mesh.yml`

See `examples/copilot-mesh.yml.example` for the portable copy-paste version.

## Config

`.github/risk-gate.yml` is the single source of truth for all 3 primitives. See `examples/risk-gate.yml.example`.

## Auditor

```bash
# heuristic, no API key
node auditor/skills-auditor.mjs --dir skills --heuristic

# LLM-powered (accurate)
OPENAI_API_KEY=sk-... node auditor/skills-auditor.mjs --dir .opencode/skills --json

# prune cruft
node auditor/skills-auditor.mjs --dir skills --prune
```

## SOC2 note

For auditors asking "where's review?": `risk-gate` logs `risky` decision + label in CI artifacts. Risky PRs still require human approval via branch protection. Non-risky PRs are logged as `SAFE` with deterministically checked guardrails.

## Install as submodule

```bash
git submodule add https://github.com/vtri950/risk-gate.git
```
