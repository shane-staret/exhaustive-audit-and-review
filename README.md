# Exhaustive Audit and Review

A [Claude Code](https://code.claude.com/docs) skill that audits **everything at once**: your Claude Code setup itself (hooks, skills, agents, plugins, MCP servers, settings, instruction files) **and** the projects you build with it. It looks for broken or outdated architecture, critical bugs and security holes, redundancy, and folder-layout drift, and gives each fix a stable ID.

Skills compose like functions. This one is a high-level function built from lower-level ones:
- it **calls** the [claude-code-new-functionality-check](https://github.com/shane-staret/claude-code-new-functionality-check) skill to see whether your setup has fallen behind what Claude Code now offers;
- in the same run, it **dispatches** a five-specialist code-review ensemble over your application code to find critical bugs and security issues;
- it adds a per-module hygiene agent and five audit agents of its own (architecture, domain, operations, Claude Code system, web research).

One run can take **hours** and start dozens to hundreds of subagents on a large workspace. Run it before a major release or after an overhaul, not every week. A preflight step always shows you the module list and a token and time estimate, and asks before anything starts.

**It never fixes anything by itself.** You triage the findings by ID, and the bundled `/apply-rec` skill plans each fix you choose and asks before it changes a file.

## How it works

Your Claude Code session runs the audit itself. It dispatches every agent, and a tested helper script holds the fiddly logic: discovery, planning, validation, IDs and reports.

1. **Preflight.** The helper finds the modules under the folder you audit and checks which companions are installed.
   - **A module** is a child folder that is a git repository, or holds a manifest such as `package.json` or `pyproject.toml`, or a `CLAUDE.md` or `AGENTS.md`. A folder that is itself a single repository is audited as one module. A `MODULES.md` table at the root (or the file `MODULE_REGISTRY=` names) fixes the modules' order.
   - It plans the run and estimates the agents, processed tokens and minutes for two coverages:
     - **exhaustive:** every file;
     - **sampled:** the riskiest files of each module.

   Claude shows you the plan and asks: these modules? Which coverage? If the currency check is installed and overdue, refresh it first? If your `house.conf` lists `CHECK=` commands, run them? Nothing runs before you answer.
2. **Currency.** If [claude-code-new-functionality-check](https://github.com/shane-staret/claude-code-new-functionality-check) is installed, the audit calls it for its status, and runs its sweep first if you said yes. Its open proposals feed the Claude Code dimension. If the companion is missing, the report says so and recommends it.
3. **Five dimensions, in waves.** Each wave stays two below Claude Code's cap on concurrent subagents (20 by default).

   | Dim | What it looks at | Who |
   |---|---|---|
   | 1 code | every file: structure, security, tests, simplicity, code smells | `code-reviewer` and its 5 specialists, one review per scope of at most 4,000 lines |
   | 2 architecture | the dependency graph and its cycles, duplication across modules, missing shared pieces, contract drift, broken cross-module references, dead modules, layout drift; per-module hygiene | `exhaustive-audit-and-review-architecture`, plus `project-health` per module |
   | 3 domain | each module's stack against its established practices, plus 1–3 concrete improvement ideas per module | `exhaustive-audit-and-review-domain` |
   | 4 operations | CI/CD, observability, runbooks, outdated dependencies, OWASP exposure, supply chain, secrets hygiene, retry and resilience | `exhaustive-audit-and-review-operations` |
   | 5 Claude Code system | hooks, agents, skills, settings and permissions, instruction files, plugins (superpowers and autoharness included), MCP servers, release currency | `exhaustive-audit-and-review-claude-system` |

4. **Research, privilege-separated.** The local agents can read your files but have no web access. Instead they write questions in public technical terms, such as "is library X at version Y still supported?". The helper checks those questions against your private-term denylist and refuses to send one that names something private.

   A separate **web-only** researcher, which cannot read a single local file, answers them. The helper then re-fetches each answer and keeps it only if its quote really appears on the page.
5. **Finalize.** Every finding gets a stable ID:
   - `W-n` for findings that span the workspace;
   - `M<k>-n` for module *k*;
   - `CS-n` for your Claude Code system.

   An ID is derived from what the finding is about, not from its wording, so the next run recognizes the same problem.

   The report opens with `EXHAUSTIVE-AUDIT COMPLETE`, or with `EXHAUSTIVE-AUDIT PARTIAL — not reviewed: …` when any part could not be reviewed. It is never quietly incomplete.
6. **Present.** You get findings by severity and dimension, every critical, the top fixes, coverage, and anything not reviewed. You also get the native tools it recommends but never starts: `/code-review ultra` before a release, and `/doctor`.

Then you decide: `apply W-2 M3-1` runs `/apply-rec`, which plans first and asks before any change. A later `diff` shows what is new, what recurs, what got worse or better, and what was fixed. A finding counts as fixed only with evidence: an `/apply-rec` log, or a commit message that names its ID. So when you fix one by hand, put its ID in the commit message; otherwise it shows as DROPPED, for you to check.

## What ships in this package

- **The skill:**
  - `SKILL.md`, the procedure Claude follows;
  - the helper `exhaustive_audit_and_review.sh`;
  - `install.sh`;
  - `resources/`: a rubric for the Claude Code system dimension, wiring notes, a testing guide, a worked example, an example report, and references.
- **Its five agents:** architecture, domain, operations, claude-system and researcher.
- **The code-review ensemble:** `code-reviewer` and its five specialists (structure, security, test-quality, simplification, smells). The audit dispatches these agents directly.

  No `code-review` skill ships, because a personal skill of that name would replace Claude Code's built-in `/code-review` on your machine.
- **`project-health`:** module hygiene. It applies the conventions your own `CLAUDE.md` files declare, and none it assumes.
- **`/apply-rec`, the fix-by-ID skill,** and its agents:
  - `apply-rec-orchestrator`, `apply-rec-editor`, `dependency-modernizer` and `runbook-author`;
  - `apply-rec-analyst`, a read-only agent that drafts security fixes for you to apply by hand.
- **Standards the agents read:**
  - code quality;
  - testing;
  - retry and resilience;
  - code navigation (LSP-first);
  - a runbook template.
- **Three offline test suites.**

## Requirements

- Claude Code 2.1.224 or later; earlier versions capped a session at 200 subagents, and a large audit can start more. It was built and tested on 2.1.296. [wiring.md](https://github.com/shane-staret/exhaustive-audit-and-review/blob/main/skills/exhaustive-audit-and-review/resources/wiring.md) lists the newer versions that improve it.
  - Subagent nesting must be allowed at least 2 levels deep. The default is 3; `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` changes it.
  - The concurrency cap must be at least 8, because one code review is six agents and each wave keeps two slots free. Keep its default of 20 or higher (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`).
  - The preflight checks both.
- bash 3.2 or later, python3 (3.9 or later), git, curl, and a sha256 tool (`shasum`, `sha256sum` or `openssl`; the installer uses it to record what it installed). `timeout` or `gtimeout` is used when present, to bound slow commands.
- macOS is tested. The scripts are plain bash and are meant to work on Linux.
- **Optional companions:**
  - [claude-code-new-functionality-check](https://github.com/shane-staret/claude-code-new-functionality-check), for the currency step;
  - the `typescript-lsp` and `pyright-lsp` plugins from Anthropic's official marketplace, for LSP-first symbol navigation (the agents fall back to text search without them);
  - [superpowers](https://github.com/obra/superpowers) and [autoharness](https://github.com/tigerless-labs/autoharness), which the Claude Code dimension audits when present.

## Install

```bash
git clone https://github.com/shane-staret/exhaustive-audit-and-review.git
bash exhaustive-audit-and-review/skills/exhaustive-audit-and-review/install.sh
bash exhaustive-audit-and-review/skills/exhaustive-audit-and-review/install.sh --yes --opt-in
```

**The first run is a dry run.** It lists what it would copy and changes nothing.

**The second run:**
- copies the skill, the agents, the standards and the test suites into `~/.claude` (or `$CLAUDE_CONFIG_DIR`);
- creates the per-machine folder `~/.claude/exhaustive-audit-and-review/` (private, 0700) and records there, in `installed.sha256`, exactly what it installed;
- with `--opt-in`, also puts a denylist template and a commented `house.conf` in that folder, keeping any you already have.

**What it will never do:**
- **Delete anything.** A file it replaces is backed up first, under `~/.claude/backups/exhaustive-audit-and-review-install/`.
- **Overwrite a file it did not install.** If you already have an agent named, say, `code-reviewer` with your own content, the installer reports it as `foreign`, leaves it alone, and tells you how to replace it on purpose with `--replace <path>`.

Then:
1. **Check that Claude Code sees the agents.** Run `/agents`; if they are not listed yet, start a new session.
2. **Add your private terms to `~/.claude/exhaustive-audit-and-review/denylist.txt`**, one per line: client and employer names, project code names, private repository names, people.
   - A term needs at least 4 characters; a shorter one would match too much and is ignored, so write a short acronym out in a longer form, such as its full name.
   - Web research stays blocked until some denylist has a term: this one, or the claude-code-new-functionality-check package's, which the audit also reads. The rest of the audit still runs.
3. **Allow the helper once.** A run calls the helper script dozens of times. When Claude Code first asks permission for it, choose the option that stops asking for that command, so an hours-long run does not wait at every step.
4. **Optionally, fill in `house.conf`:**
   - `EXCLUDE=` for folders that must never be audited;
   - where reports go;
   - read-only `CHECK=` commands to run at preflight;
   - the review size.

   You can also add a `house-context.md` with facts about your setup that the agents should know.

   [wiring.md](https://github.com/shane-staret/exhaustive-audit-and-review/blob/main/skills/exhaustive-audit-and-review/resources/wiring.md) explains every key.

**Install with Claude instead.** Open Claude Code in the cloned folder and say:

> Install the exhaustive audit from this repository. Read README.md and skills/exhaustive-audit-and-review/resources/wiring.md, run install.sh as a dry run and show me the plan, then install it with my OK.

## First run: try the demo

The helper can build a small demo workspace and a demo Claude Code config, both with planted problems, so you can watch a whole run on something harmless before you point it at real work:

```bash
bash ~/.claude/skills/exhaustive-audit-and-review/exhaustive_audit_and_review.sh demo-fixture /tmp/audit-demo
```

The folder must be new or empty, so pick a fresh one to build it again. (With `$CLAUDE_CONFIG_DIR` set, use that folder in place of `~/.claude` here and below.)

Then start Claude Code in any folder and type `/exhaustive-audit-and-review run all --root /tmp/audit-demo/workspace --config-dir /tmp/audit-demo/claude-config`. When it finishes, the summary's first line names the run. Score it against the demo's answer key:

```bash
bash ~/.claude/skills/exhaustive-audit-and-review/exhaustive_audit_and_review.sh score-demo <run> --config-dir /tmp/audit-demo/claude-config
```

The [example report](https://github.com/shane-staret/exhaustive-audit-and-review/blob/main/skills/exhaustive-audit-and-review/resources/example-report.md) is a real run on that demo.

**What the demo costs.** The demo has two small modules (61 and 25 lines), and on the author's machine its run used:
- 19 agents;
- about 53M processed tokens, mostly cache reads, because every agent re-reads its own context on each tool call;
- about 33 minutes.

Each code-review scope alone costs about 15M processed tokens. The preflight's estimate uses these measured figures, so treat it as a floor: a real module of thousands of lines costs more per scope. The optional currency sweep is not in the estimate, and the 17 agents and 2 skills this package installs add their descriptions to every session's context.

On a real workspace, start with **sampled** coverage to see the cost, then run **exhaustive** before a release.

## Using it

| Say or type | What happens |
|---|---|
| `/exhaustive-audit-and-review` | `run all`: every dimension over every module and your Claude Code config (after the preflight question) |
| `/exhaustive-audit-and-review run module <name>` | dimensions 1–4 for one module |
| `/exhaustive-audit-and-review run workspace` | dimensions 2–4 over every module, without the per-file review |
| `/exhaustive-audit-and-review run claude-system` | your Claude Code config only, with the currency step |
| `/exhaustive-audit-and-review resume <run>` | continue a run that was interrupted |
| `/exhaustive-audit-and-review status` | the runs so far and where each stopped; nothing is started |
| `/exhaustive-audit-and-review diff` | compare the last two runs: new, recurring, regressed, improved, resolved (with evidence of a fix), dropped (gone without such evidence) and approximate matches |
| `apply W-2 M3-1 CS-4` | `/apply-rec` plans those fixes and asks before changing anything |
| `walk me through CS-4` | one finding, its evidence and what fixing it involves |

## Privacy and safety

- **Read-only audit.** The five audit agents have no tool that edits a file or runs a command. The code-review and project-health agents it reuses do have such tools, because they serve other skills too. The audit dispatches them in its JSON mode, whose instructions forbid writing any file (an instruction, not a tool restriction), and nothing in a run commits or pushes. Fixes happen only through `/apply-rec`, on your word.
- **What leaves your machine.** As in any Claude Code session, what the agents read is sent to the model. Beyond that:
  - only the research questions go to web search, in public terms, after the denylist check. It fails closed: no denylist terms, no research;
  - the helper then fetches the researcher's pages itself (https only, never a local or private address) to check each quote.
- **No local agent touches the web.** Only the web-only researcher does, and it reads no local file, so a poisoned web page has nothing to steal.
- **The denylist check covers your own machine too.** When you audit another config folder with `--config-dir`, research questions are checked against that folder's denylists and your running session's, because the agents load your own instruction files.
- **Audited folders are data, not code.** The helper's python starts in isolated mode, so a file in the audited folder named like a python module (such as `json.py`) is never imported. When you audit a config folder other than your own, its scripts and `CHECK=` commands are never run.
- **Fetched pages are checked twice.** Every research URL, and the page it finally lands on after redirects, must be public https: no user name in the URL, no local or private address in any spelling. The fetch follows redirects only over https, and TLS certificate checks guard what a name resolves to.
- **Names, never values.** Environment variables, MCP servers and secrets appear by name only. Anything secret-shaped that slips into a finding is masked.
- **No headless sessions.** Everything runs inside your interactive session as normal subagents. On a subscription it counts against your plan's usage; with API-key billing it is charged at your model's prices.
- **Paths stay relative.** Reports use paths relative to the audited folder, and per-machine data lives in the data folder of the config you audit (`~/.claude/exhaustive-audit-and-review/` by default), which nothing publishes. With `REPORT_LAYOUT=assets-output`, the reports are written inside the audited folder instead, so keep them out of anything you publish.

## Files

```
skills/exhaustive-audit-and-review/
  SKILL.md                         the procedure Claude follows
  exhaustive_audit_and_review.sh   the helper: discover, plan, validate, IDs, reports, diff, demo
  install.sh                       the installer (reads package.manifest)
  package.manifest                 every file this package ships
  resources/                       rubric, wiring, testing, worked example, example report, references
skills/apply-rec/                  fix chosen findings by ID
agents/                            5 audit agents, the 6-agent code-review ensemble,
                                   project-health and the 5 apply-rec agents
templates/                         the standards the agents read, and a runbook template
hooks/tests/test-exhaustive-audit-and-review-{helper,package,install}.sh
```

Run data lives in the data folder of the config you audit, `<config>/exhaustive-audit-and-review/runs/<run>/` (by default under `~/.claude`): the plan, every agent's saved result, `findings.json` and the reports.

## Tests

The three suites are offline and run against throwaway folders. They work from the clone, and from `~/.claude/hooks/tests/` after installing:

```bash
bash exhaustive-audit-and-review/hooks/tests/test-exhaustive-audit-and-review-package.sh
bash exhaustive-audit-and-review/hooks/tests/test-exhaustive-audit-and-review-install.sh
bash exhaustive-audit-and-review/hooks/tests/test-exhaustive-audit-and-review-helper.sh
```

## Updating and uninstalling

- **Update:** run `git pull` in the clone, then rerun `install.sh --yes`.
  - A file it installed earlier and you have not edited is updated, after a backup.
  - A file you have changed is left alone and reported as `foreign`.
  - Your per-machine files are never overwritten; the installer only updates its record, `installed.sha256`, there.
- **Uninstall:** move out only what the installer put there and you have not changed since. Never go by `package.manifest`: a file you already had under the same name was reported `foreign` and left alone, and it is still yours. This lists the files still exactly as installed (paths relative to `~/.claude`):

  ```bash
  C="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  while read -r sum file; do
    [ "$(shasum -a 256 "$C/$file" 2>/dev/null | cut -c1-64)" = "$sum" ] && printf '%s\n' "$file"
  done < "$C/exhaustive-audit-and-review/installed.sha256"
  ```

  Move those files out of `~/.claude`. A file you replaced on purpose with `--replace` has its original in `~/.claude/backups/exhaustive-audit-and-review-install/`; copy it back if you want it. Keep the per-machine folder if you want your past runs.

## Words used here

| Word | Meaning |
|---|---|
| module | a child folder of the audited root that is a git repository, or holds a manifest or a `CLAUDE.md`/`AGENTS.md` |
| tier | a module's size class by lines: small (under 5,000), medium (under 30,000), large (under 100,000), xlarge |
| scope | one agent's share of the work: a code review of at most 4,000 lines, one module's hygiene check, or one dimension |
| wave | the scopes dispatched together, kept two below the concurrency cap |
| currency, sweep | whether your setup has fallen behind what Claude Code now offers; the companion package checks it with a "sweep" of the release notes, and a sweep is "overdue" after a week |
| `house.conf`, `house-context.md` | your per-machine settings and notes for the audit (see wiring.md) |
| denylist | your private terms, which no research question may contain |
| cloud placeholder | an iCloud Drive file that is listed but not downloaded (a `.name.icloud` stub); it is reported, never read or counted |
| LSP | Language Server Protocol: the plugins that let agents resolve code symbols the way a compiler does |
| finding ID | `W-n` (whole workspace), `M<k>-n` (module *k*), `CS-n` (Claude Code system), stable from run to run |

## License

MIT; see [LICENSE](https://github.com/shane-staret/exhaustive-audit-and-review/blob/main/LICENSE).
