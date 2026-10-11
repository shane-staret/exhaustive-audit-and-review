# Worked example: one whole run, end to end

This page traces the run whose report is in `example-report.md`: run `20261010T093500Z` on the demo fixture, with Claude Code 2.1.296. Every command and output below is copied from that run, with one exception: the preflight block in step 1 is what the helper prints after the fixes listed at the end. During the run itself, `capabilities` reported every agent missing (fix 1). `<dir>` stands for the folder the demo was built in, `<config>` for `<dir>/claude-config`, and `$H` for `~/.claude/skills/exhaustive-audit-and-review/exhaustive_audit_and_review.sh`.

## 0. The demo

```bash
bash $H demo-fixture <dir>
```
```
demo-fixture: built a demo workspace (2 modules: orders, notify) and a demo Claude Code config with 15 planted defects (3 critical)
```

The user then typed `/exhaustive-audit-and-review run all --root <dir>/workspace --config-dir <dir>/claude-config`.

## 1. Preflight

Claude ran `discover` and `plan` (once for exhaustive coverage and once for sampled) with `--root` and `--config-dir`, and `capabilities --strict` with `--config-dir` alone, and showed this block (as the fixed helper prints it):

```
Modules (registry MODULES.md): orders — 9 files, 61 lines, small · notify — 6 files, 25 lines, small
Excluded / skipped: none
Runtime: Claude Code 2.1.296 · 17/17 agents present · nesting depth 5 (≥2 needed) · concurrency cap 20 → waves of ≤18 · nothing BLOCKED
Companion /claude-code-new-functionality-check: callable (last sweep not overdue)
Audited config: no superpowers / autoharness / LSP plugins · no new-functionality-check data
Plan: 8 scopes in 1 wave → 19 agents (code 12 · dimensions 4 · health 2 · research 1)
Estimate (exhaustive and sampled are the same here): 19 agents · 53.2M processed tokens · 31 minutes — a floor, measured on this demo
```

`discover` counts every text file in a module (86 lines in all). The code review covers the 72 of those lines that are in code files, and that is what the report's coverage table counts.

It asked with AskUserQuestion, offering "run both modules" or "cancel". Exhaustive and sampled were the same here, since 86 lines fit in one review scope each. It did not ask about the currency sweep, because the sweep was not overdue, nor about `CHECK=` commands, because there were none. After the yes:

```bash
bash $H plan --root <dir>/workspace --config-dir <config> --scope all --coverage exhaustive > plan.json
bash $H init-run --plan plan.json --root <dir>/workspace --config-dir <config>
```
```
20261010T093500Z
<config>/exhaustive-audit-and-review/runs/20261010T093500Z
```

## 2. Currency

Claude called the companion skill, `/claude-code-new-functionality-check status`, which reported a fresh sweep. It then saved the facts the read-only agents cannot gather for themselves:

```bash
bash $H config-facts --root <dir>/workspace --config-dir <config> > <config>/exhaustive-audit-and-review/runs/20261010T093500Z/config-facts.json
```

The facts recorded one hook (on `UserPromptSubmit`, with a matcher), no plugins, and no new-functionality-check data in the audited config.

## 3. One wave

```bash
bash $H next-wave 20261010T093500Z --config-dir <config>
```

Its JSON, shown here as one line per scope (scope, agent, module, files):

```
D2-architecture  | exhaustive-audit-and-review-architecture  | - | .
D3-domain        | exhaustive-audit-and-review-domain        | - | .
D4-operations    | exhaustive-audit-and-review-operations    | - | .
D5-claude-system | exhaustive-audit-and-review-claude-system | - | <config>
PH-1             | project-health                            | orders | orders
PH-2             | project-health                            | notify | notify
CR-1-01          | code-reviewer                             | orders | orders/app/__init__.py, … (7 files)
CR-2-01          | code-reviewer                             | notify | notify/bin/update.sh, … (4 files)
```

All eight went out in one message. Each prompt began with `AUDIT-RUN: 20261010T093500Z <scope>` and `AUDIT-ROOT: <root>`. The code scopes added `FORMAT: audit-json`, `MODULE:` and their file list. The health scopes added `REPORT ONLY`, `FORMAT: audit-json`, `MODULE:` and `MODULE-PATH:`. Claude did not poll. As each report arrived:

```bash
bash $H save-result 20261010T093500Z D2-architecture <the agent's output file> --config-dir <config>
bash $H validate 20261010T093500Z D2-architecture --config-dir <config>
```
```
saved <config>/…/results/D2-architecture.json (3 findings; reply in 1 piece(s); attempt 1)
VALID 3 findings
```

All eight came back valid: 3, 10, 21 and 14 findings from the dimensions, 3 and 1 from health, and 21 and 9 from the two code reviews, 82 in all. `finalize` later merged two pairs of code findings that shared a fingerprint, which left 80.
- Two health replies came back `VALID-OVERLONG`, because a "not reviewed" note ran past 200 characters. `finalize` trims such a field, and the agents now state that cap.
- The longest scope was a code review, at about 18 minutes, because each `code-reviewer` waits for its five specialists.

## 4. Research

```bash
bash $H agenda 20261010T093500Z --config-dir <config>          # 4 questions, budget 4
bash $H scrub-check <config>/…/runs/20261010T093500Z/agenda.md --config-dir <config>
```
```
CLEAN
```

The web-only researcher got `AUDIT-RUN: 20261010T093500Z research` and the agenda, and nothing else. Its reply was then saved and verified:

```bash
bash $H save-result 20261010T093500Z research <the agent's output file> --config-dir <config>
bash $H attach-research 20261010T093500Z <config>/…/results/research.json --config-dir <config>
```
```
research: 4 verified, 2 unverified, 0 failed
```

## 5. Finalize

```bash
bash $H finalize 20261010T093500Z --config-dir <config>
```
```
EXHAUSTIVE-AUDIT COMPLETE
findings: 80 (critical 7, high 26, medium 28, low 17, info 2)
report: <config>/…/exhaustive_audit_v1_20261010T100801Z.md
claude-system report: <config>/…/exhaustive_audit_claude_system_v1_20261010T100801Z.md
```

## 6. Present, score, prove

- **Present.** Claude showed the fixed-shape summary that opens `example-report.md`.
- **Score.** `score-demo` matched all 15 planted defects, including all 3 criticals.
- **Prove.** Claude Code's own records of the session's subagents (`projects/<project>/<session>/subagents/agent-*.meta.json`) show 19 agents: the 9 dispatched at depth 1, and the 10 code-review specialists at depth 2, five under each `code-reviewer`.

## What this first real run taught (and what was fixed before publishing)

Running the audit for real is a test of its own. This run found four problems in the audit itself, and each was fixed test-first:

1. **`capabilities` looked for the agents in the audited config, not the running session's.** On the demo it reported every agent missing.
   - It now reads agents, the companion skill and the limits from the running Claude Code config.
   - It reports what the audited config has installed separately, under `audited_config`.
2. **The estimate was far too low.** It came from constants nobody had measured. The real figures are in `example-report.md`, and the constants now come from this run.
3. **Quote verification failed on markdown punctuation:** a backtick in a quote that the page renders as code. Both sides are now normalized before they are compared.
4. **`project-health` filled gaps from the running machine's house notes, even when the run audited another config folder.** The skill now passes `HOUSE-CONTEXT:` (or `none`) in the health dispatch, and the agent uses only that.

Some things worked exactly as designed:
- the preflight question;
- one dispatch message per wave;
- `save-result` reading replies from the transcripts;
- `validate`;
- the fail-closed denylist check;
- the dispatch proof;
- stable IDs.
