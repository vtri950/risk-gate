#!/usr/bin/env node
// skills-auditor.mjs — evals which agent skills are obsolete vs modern LLM knowledge
// Duckbill pattern: "We wrote evals for our skills then tested them to see which had been consumed by modern LLM knowledge. We ultimately deleted a lot"
// Usage:
//   node auditor/skills-auditor.mjs [--dir skills] [--json] [--prune]
//   OPENAI_API_KEY=... node auditor/skills-auditor.mjs  # uses LLM for eval
//   node auditor/skills-auditor.mjs --heuristic          # no API key, heuristic mode

import fs from "fs";
import path from "path";

const args = process.argv.slice(2);
const getArg = (k, def) => {
  const i = args.indexOf(k);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
};
const hasFlag = (k) => args.includes(k);

const DIR = getArg("--dir", getArg("--skills-dir", "skills"));
const JSON_OUT = hasFlag("--json");
const HEURISTIC = hasFlag("--heuristic") || (!process.env.OPENAI_API_KEY && !process.env.ANTHROPIC_API_KEY);
const PRUNE = hasFlag("--prune");

function readSkills(dir) {
  if (!fs.existsSync(dir)) return [];
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const skills = [];
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      const md = path.join(full, "SKILL.md");
      if (fs.existsSync(md)) skills.push({ name: e.name, path: md, content: fs.readFileSync(md, "utf8") });
      else {
        // nested
        skills.push(...readSkills(full));
      }
    } else if (e.name.endsWith(".md")) {
      skills.push({ name: path.basename(e.name, ".md"), path: full, content: fs.readFileSync(full, "utf8") });
    }
  }
  return skills;
}

// Heuristic eval: estimates if skill is "2025-era cruft"
// Checks for patterns that modern LLMs already know
const OBSOLETE_PATTERNS = [
  /you are a helpful assistant/i,
  /think step by step/i,
  /use tools to/i,
  /always respond in/i,
  /never reveal/i,
  /as an AI/i,
];

const REDUNDANT_KEYWORDS = [
  "chain-of-thought",
  "few-shot",
  "prompt engineering",
  "2024",
  "2025",
];

function heuristicScore(skill) {
  const c = skill.content;
  let score = 0;
  const reasons = [];

  // 1. Length / cruft
  const lines = c.split("\n").length;
  if (lines > 300) {
    score += 2;
    reasons.push(`very long (${lines} lines) — likely contains restated LLM knowledge`);
  }

  // 2. Generic instructions LLM already knows
  for (const rx of OBSOLETE_PATTERNS) {
    if (rx.test(c)) {
      score += 2;
      reasons.push(`contains generic prompt "${rx.source}" — modern LLM already does this`);
    }
  }

  // 3. Dated references
  for (const kw of REDUNDANT_KEYWORDS) {
    if (c.toLowerCase().includes(kw.toLowerCase())) {
      score += 1;
      reasons.push(`mentions "${kw}" — verify if still needed`);
    }
  }

  // 4. Contains project-specific value? (negative score)
  const specificSignals = [/`.*`/, /file_path/, /repo/i, /api/i, /example/i];
  let specificity = 0;
  for (const rx of specificSignals) if (rx.test(c)) specificity++;
  if (specificity >= 3) {
    score -= 2;
    reasons.push(`highly project-specific (${specificity} signals) — likely KEEP`);
  }

  // 5. Duplicate instruction density
  const words = c.toLowerCase().split(/\W+/);
  const uniq = new Set(words).size;
  const ratio = uniq / Math.max(words.length, 1);
  if (ratio < 0.45) {
    score += 1;
    reasons.push(`low lexical diversity (${ratio.toFixed(2)}) — repetitive instructions`);
  }

  let verdict = "KEEP";
  if (score >= 3) verdict = "PRUNE";
  else if (score >= 1) verdict = "REWRITE";

  return { score, reasons, verdict };
}

async function llmEval(skill) {
  // If API key present, use OpenAI to judge if skill adds value over base model
  const prompt = `You are evaluating an agent skill file for redundancy.
Skill name: ${skill.name}
Content (truncated to 4000 chars):
---
${skill.content.slice(0, 4000)}
---
Question: Does a modern LLM (GPT-4o / Claude 4 class, 2026) already know this without the skill?
Answer JSON only: {"verdict":"PRUNE|REWRITE|KEEP","reason":"...","score":0-5}
PRUNE = fully consumed by LLM knowledge, delete it.
REWRITE = partially useful but needs trimming.
KEEP = project-specific, not in base model.`;

  if (process.env.OPENAI_API_KEY) {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${process.env.OPENAI_API_KEY}` },
      body: JSON.stringify({
        model: process.env.AUDITOR_MODEL || "gpt-4o-mini",
        messages: [{ role: "user", content: prompt }],
        temperature: 0,
      }),
    });
    const j = await res.json();
    const text = j.choices?.[0]?.message?.content || "";
    try {
      const m = text.match(/\{[\s\S]*\}/);
      return JSON.parse(m[0]);
    } catch {
      return { verdict: "REWRITE", reason: text.slice(0, 200), score: 2 };
    }
  }
  // fallback
  return heuristicScore(skill);
}

async function main() {
  const skills = readSkills(DIR);
  if (skills.length === 0) {
    console.log(`No skills found in ${DIR}/ (looks for SKILL.md or *.md)`);
    process.exit(0);
  }

  console.log(`Auditing ${skills.length} skills in ${DIR}/ ${HEURISTIC ? "(heuristic mode)" : "(LLM mode)"}\n`);

  const results = [];
  for (const s of skills) {
    const r = HEURISTIC ? heuristicScore(s) : await llmEval(s);
    results.push({ name: s.name, path: s.path, ...r });
  }

  // sort: PRUNE first
  results.sort((a, b) => (b.score - a.score));

  if (JSON_OUT) {
    console.log(JSON.stringify(results, null, 2));
  } else {
    for (const r of results) {
      const icon = r.verdict === "PRUNE" ? "🗑️ " : r.verdict === "REWRITE" ? "✏️ " : "✓";
      console.log(`${icon} ${r.verdict}  ${r.name}  (score ${r.score})`);
      console.log(`   ${r.path}`);
      for (const reason of r.reasons || [r.reason]) console.log(`   - ${reason}`);
      console.log();
    }
    const prune = results.filter((r) => r.verdict === "PRUNE").length;
    const rewrite = results.filter((r) => r.verdict === "REWRITE").length;
    const keep = results.filter((r) => r.verdict === "KEEP").length;
    console.log(`Summary: ${prune} PRUNE, ${rewrite} REWRITE, ${keep} KEEP / ${results.length} total`);
    if (prune > 0) console.log(`→ Run with --prune to move pruned skills to .trash/ (manual review)`);
  }

  if (PRUNE) {
    const trash = path.join(path.dirname(DIR), ".trash-skills");
    fs.mkdirSync(trash, { recursive: true });
    for (const r of results.filter((x) => x.verdict === "PRUNE")) {
      const dest = path.join(trash, path.basename(r.path));
      console.log(`Moving ${r.path} → ${dest}`);
      fs.renameSync(r.path, dest);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
