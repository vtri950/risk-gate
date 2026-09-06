# Skills Auditor

Eval harness to detect 2025-era cruft consumed by modern LLM knowledge.

```bash
# heuristic (no API key, fast)
node auditor/skills-auditor.mjs --dir skills --heuristic

# LLM mode (accurate)
OPENAI_API_KEY=... node auditor/skills-auditor.mjs --dir skills
OPENAI_API_KEY=... node auditor/skills-auditor.mjs --dir .opencode/skills

# JSON for CI
node auditor/skills-auditor.mjs --json > audit.json

# auto-move PRUNE to .trash-skills/
node auditor/skills-auditor.mjs --prune --heuristic
```
