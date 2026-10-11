# Wiring the exhaustive audit on a machine

`install.sh`, in this skill's folder, does the copying; the package `README.md` shows how to run it. This page is the manual version, for a person or an AI wiring the package by hand, or repairing it after something overwrote the config. It covers what goes where and why.

The installer:
- runs as a dry run by default, and copies only with `--yes`;
- backs up what it replaces, and never deletes anything;
- records what it installed;
- refuses to replace a file it did not install unless you name that file with `--replace <path>`.

`<config>` below means your Claude Code config folder, `${CLAUDE_CONFIG_DIR:-~/.claude}`.

## The files

| From the package | To | Job |
|---|---|---|
| `skills/exhaustive-audit-and-review/` (the whole folder) | `<config>/skills/exhaustive-audit-and-review/` | the procedure (`/exhaustive-audit-and-review`), its helper `exhaustive_audit_and_review.sh`, the resources and the installer |
| `agents/exhaustive-audit-and-review-architecture.md`, `-domain.md`, `-operations.md`, `-claude-system.md` | `<config>/agents/` | the four dimension agents. Read-only: `Read, Grep, Glob`, plus `LSP` for architecture and operations. No shell, no web |
| `agents/exhaustive-audit-and-review-researcher.md` | `<config>/agents/` | the researcher: `WebSearch, WebFetch` only, no local read |
| `agents/code-reviewer.md` and the five `agents/code-reviewer-*.md` | `<config>/agents/` | dimension 1: the review ensemble (structure, security, test-quality, simplification, smells) |
| `agents/project-health.md` | `<config>/agents/` | the hygiene half of dimension 2, launched in `REPORT ONLY` mode |
| `skills/apply-rec/` and `agents/apply-rec-orchestrator.md`, `apply-rec-editor.md`, `apply-rec-analyst.md`, `dependency-modernizer.md`, `runbook-author.md` | `<config>/skills/`, `<config>/agents/` | triage by ID: plans each fix and asks before it changes anything |
| `templates/code_quality_standard.md`, `retry_standard.md`, `testing_standard.md`, `code_navigation_standard.md`, `runbook_incident.md.tmpl` | `<config>/templates/` | the standards the agents cite |
| `hooks/tests/test-exhaustive-audit-and-review-{helper,package,install}.sh` | `<config>/hooks/tests/` | the offline suites; the installer always copies them, and nothing runs them unless you do |

**Not shipped on purpose: a `code-review` skill.** A personal skill with that name replaces Claude Code's bundled `/code-review`, `/code-review ultra` included. The audit dispatches the `code-reviewer` *agent* directly, so it needs no such skill.

**Agent names that may already exist.** You may already have agents with the same names; `code-reviewer` is a common one. Compare them before you pass `--replace`. The audit needs the `FORMAT: audit-json` mode the shipped `code-reviewer` and `project-health` support.

The helper and the installer must be executable.

**Requirements:**
- bash 3.2 or later, python3 3.9 or later, git, curl, and a sha256 tool (`shasum`, `sha256sum` or `openssl`); `timeout` or `gtimeout` when present;
- Claude Code 2.1.224 or later, which removed the cap of 200 subagents per session, with nesting depth ≥ 2 (the default has been 3 since 2.1.219) and a concurrency cap of at least 8 (the cap arrived in 2.1.217; its default is 20).

**Recommended Claude Code versions:**
- 2.1.271 or later, so `omitClaudeMd` takes effect. Older versions ignore the key, and the two agents that set it simply load your CLAUDE.md;
- 2.1.280 or later, so background agents can use `LSP`. Before that, the agents fall back to Grep and say so.

A running session picks up new skills. Recent versions also pick up new agent files: run `/agents`, and if the five audit agents are missing, start a new session.

## Claude Code limits the audit relies on

Claude Code's defaults are what the audit needs, so set these in `settings.json` under `env` only when something else has lowered them. The example shows the defaults:

```json
{
  "env": {
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "3",
    "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "20"
  }
}
```

- **Depth.** A depth of 1 turns nesting off. Then `code-reviewer` cannot launch its specialists, and `capabilities --strict` reports the audit as BLOCKED (exit 3).
- **Concurrency.** The audit sizes its waves to the cap minus 2, so a cap below 20 means more, smaller waves. Below 8 even one code review (six agents) cannot fit, and `plan` exits 3.

## The data folder (per machine)

`<config>/exhaustive-audit-and-review/`, written `<data>` below; `EXHAUSTIVE_AUDIT_DIR` moves it. It is never published and never part of the package. The installer creates it (0700) on its first `--yes` run, to keep its record `installed.sha256` there; `install.sh --yes --opt-in` also adds the denylist and `house.conf` templates. You can create it by hand instead (`mkdir -m 700`).

Every file in it is optional. Without them, the audit runs on its defaults. Research is skipped, though: with no denylist term, `scrub-check` fails closed, and the report says so.

When you audit another config folder with `--config-dir`, the run uses that folder's data folder: its settings, its notes and its run history.

| File | Holds | Read by |
|---|---|---|
| `house.conf` | the settings below | the helper |
| `house-context.md` | your notes for the dimension agents: what the projects are for and who uses them, which modules feed which (file formats, exports), and conventions that no `CLAUDE.md` writes down | the architecture, domain, operations and claude-system agents, when the file exists; never the researcher |
| `denylist.txt` (0600) | private terms that must never leave the machine in a research query | `scrub-check` |
| `runs/<run>/` | one folder per run (created on first use) | the helper, and `/apply-rec` through `lookup` |

### house.conf

One `KEY=value` per line; `#` starts a comment. `EXCLUDE` and `CHECK` may repeat.

| Key | Default | Effect |
|---|---|---|
| `EXCLUDE=<folder>` | none | A folder the audit never reads, applied before anything is read: a child folder's name, a root-relative path or an absolute path. Use it for client work, vendored code and data dumps. Repeat it for each folder. |
| `MODULE_REGISTRY=<file>` | `MODULES.md` at the root, when it exists | A root-relative file whose markdown table names your modules, first column first, in a fixed order. Module numbers (`M<k>-…` IDs) then stay put as folders come and go. The registry only orders modules: it never makes a folder a module. Without any registry, modules sort by name. |
| `REPORT_LAYOUT=run-dir\|assets-output` | `run-dir` | With `run-dir`, the reports stay in `<data>/runs/<run>/`, outside every repository. With `assets-output`, they are written under `<root>/assets/output/`, for a workspace that keeps generated reports there. The run's state stays in the data folder either way. |
| `CHECK=<command>` | none | A verification command, such as a test runner or a wiring suite. It runs only after you say yes at preflight. Its exit code and the tail of its output reach the claude-system and operations agents through `config-facts --checks`. When you audit a config folder other than the running session's own, its `CHECK=` lines are listed and never run, and the companion package runs from the running session's copy, so a foreign config's scripts and commands never run. |
| `MAX_LOC_PER_REVIEW=<n>` | `4000` | The most lines one `code-reviewer` scope holds. Larger modules are split into several scopes. |
| `RESEARCH_BUDGET=<n>` | `8` | The most research questions one run sends to the researcher. The most severe findings' questions go first. (The bundled demo's config sets 4, to keep that run small.) |
| `CONFIG_TEST=<command>` | none | How `/apply-rec` checks a change it made to your Claude Code config (any `CS-` finding), for example your config's own test runner. Repeatable. The audit itself never runs it. |

A small example:

```
# exhaustive-audit-and-review: this machine only
EXCLUDE=clients
EXCLUDE=vendor
REPORT_LAYOUT=run-dir
CHECK=bash ~/.claude/hooks/tests/test-exhaustive-audit-and-review-package.sh
MAX_LOC_PER_REVIEW=4000
```

### The denylist

`<data>/denylist.txt` names what must never appear in a web search: client and employer names, project code names, private repository names, people, hostnames.
- Write one term per line. A line starting with `#` is a comment. A term needs at least 4 characters; shorter ones would match too much, so they are ignored and counted in a warning, never printed.
- `scrub-check` reads the union of up to six lists, each file once:
  - this file and the `claude-code-new-functionality-check` package's `denylist.txt`, in the config folder being audited;
  - the same two in the config folder of the session running the audit, when you audit another folder with `--config-dir`. The agents load the running machine's instruction files, so its private terms are checked too;
  - `$CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR/denylist.txt`, when that variable moves the companion's data folder.

  `EXHAUSTIVE_AUDIT_DENYLIST` (one file, or several separated by `:`) replaces all of them.
- **No usable term at all means exit 3.** Research is then skipped, because a check against nothing proves nothing. A list that exists but cannot be read also means exit 3, naming the file.
- Keep the file 0600. Never print it, and never paste it into a prompt: it is a list of exactly the words that must not leave the machine.

## Companions (all optional)

| Companion | What it adds | Without it |
|---|---|---|
| the `claude-code-new-functionality-check` package | the currency step: its status, an incremental sweep when you say yes, and its open proposals, which the claude-system agent cites instead of repeating | the report says it was not available and recommends it |
| language-server plugins for your languages (for example the TypeScript and Pyright LSP plugins) | precise symbol resolution for the architecture and operations agents | a Grep fallback, stated in each affected finding |
| superpowers | nothing the audit needs; when present, the claude-system dimension audits it like any plugin | nothing changes |
| autoharness, or another skill-learning plugin | the claude-system dimension also audits its learned-skill library (checklist C23) | that check is skipped |
| a dedicated security-scan plugin | named at the end as the next step for a deep security pass | not mentioned |

The audit recommends `/code-review ultra` and `/doctor`, and starts neither.

## Where things live at run time

| Path | Holds | Safe to clear? |
|---|---|---|
| `<data>/runs/<run>/` | the run's plan, `config-facts.json`, the saved and validated agent results, the research agenda and result, `findings.json` (the record of the run), any `/apply-rec` logs, and the reports with `REPORT_LAYOUT=run-dir` | Not while you triage. The next run reuses IDs from `findings.json`, `/apply-rec` looks IDs up there, and `diff` reads the apply logs as evidence of fixes. |
| `<root>/assets/output/` (only with `assets-output`) | the reports | yes, if `findings.json` is kept |
| `<data>/installed.sha256` | what `install.sh --yes` put in `<config>`: one checksum and path per file | No. The installer uses it to tell a file it installed (safe to update) from your own file of the same name (left alone, reported `foreign`, replaced only with `--replace <path>`). |

## Checking the wiring

```bash
bash ~/.claude/skills/exhaustive-audit-and-review/exhaustive_audit_and_review.sh capabilities
bash ~/.claude/hooks/tests/test-exhaustive-audit-and-review-package.sh
```

`capabilities` lists:
- the companions it found;
- the depth and concurrency limits;
- the CLI version;
- BLOCKED with its reason, when the audit cannot run.

The package suite proves the files agree with each other. For an end-to-end check, use the demo run in `testing-exhaustive-audit-and-review.md`.

## When something else manages your config

A dotfiles sync or a team deploy that replaces `agents/` or `skills/` can remove these files without a sound. After such a deploy, run `install.sh --yes` again; it skips whatever is already in place. Better still, add the files to whatever does the deploying.

## Uninstalling

1. Move out of `<config>` only the files the installer put there and you have not changed since: the lines of `<data>/installed.sha256` whose checksum still matches the file (the package README has a loop that lists them). Never go by `package.manifest`: a file of the same name that you already had was reported `foreign`, left alone, and is still yours.
2. A file you replaced on purpose with `--replace` has its original under `<config>/backups/exhaustive-audit-and-review-install/`; copy it back if you want it.
3. The data folder holds your runs and your private lists: keep it, or move it somewhere else.
