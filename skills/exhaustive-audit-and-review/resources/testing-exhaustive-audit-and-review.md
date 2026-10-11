# Testing a run, and testing changes to the exhaustive audit

How to verify work done under this skill before you call it done. Runner evidence counts; "should pass" does not.

`<config>` below means `${CLAUDE_CONFIG_DIR:-~/.claude}`.

## Automated: run these and show the output

The three suites ship with the package and are hermetic. They find the helper, the agents and the skill relative to themselves, so the same commands work under `<config>/hooks/tests/` and from a clone (`hooks/tests/`).

### 1. Helper suite

```
bash <config>/hooks/tests/test-exhaustive-audit-and-review-helper.sh
```

- **Hermetic.** It is offline and runs under `/bin/bash` (3.2). It builds its fixtures in a temporary folder, and never reads the real config.
- **Regressions first.** It holds a regression case for each of these easy-to-make mistakes:
  - module sizes are true totals, not one file's count;
  - report numbers sort as numbers, so `v10` follows `v9`;
  - report globs never pick up error or progress files;
  - IDs come from `check` + `subject`, never from prose.
- **Every subcommand** is covered after that, from `discover` to `score-demo`. The suite's header lists the current cases.
- **Generated secrets.** Secret-shaped test strings are built from fragments at run time, so the suite never trips a secret scanner.

### 2. Package suite

```
bash <config>/hooks/tests/test-exhaustive-audit-and-review-package.sh
```

It checks what the package promises:
- **The manifest.**
  - `package.manifest` lists exactly what ships, and every entry exists.
  - Paths stay relative and inside the package, with no duplicates.
  - No `code-review` skill ships, so the built-in `/code-review` stays reachable.
  - No machine-specific file ships, whether a line names it or a folder entry sweeps it in: a `*-wiring.sh` suite (it reads one machine's real config), or the author's publishing script and its suite.
- **The agents.**
  - The five audit agents have their exact `tools:` lines, and only the researcher has web tools.
  - `omitClaudeMd: true` is set on the claude-system agent and the researcher.
  - Only the dispatchers grant `Agent`, and no agent grants `Skill` or lists the user-question tool.
  - Names match the file names, and every shipped frontmatter is strict YAML.
- **Shipped text.** It carries no home paths, no private ledger or decision-record ids, and never the headless invocation form. No agent or skill file promises to stop after a fixed number of minutes, a promise no agent can keep.
- **The skills.** This skill and `apply-rec` have the authoring shape: a trigger-only description with a negative scope, under 500 characters; a `| Resource | Load when… |` table; an anti-patterns section; a split checklist; every required resource present and named; no `archive/` folder. This skill's preflight section asks with AskUserQuestion before it runs `init-run`.
- **SKILL.md against the helper.** Every `exhaustive_audit_and_review.sh <subcommand>` written in SKILL.md appears in the helper's `--help`. Every agent that writes findings states the three enums and every `<field> <= N` cap the helper's usage text states.
- **Parsing.** The helper, the installer and the suites parse (`bash -n`).
- **Sandboxes.** Each shipped suite is started once with a `TMPDIR` that does not exist, from a folder that holds one marker file. It must stop at once with its FAIL line and leave that folder as it was, because a suite that kept going once worked in, and then deleted, the folder it was started from.
- **Negative controls.** Each extraction is first proven able to fail on a planted fixture. The bans run there with their production patterns, and a file a scan cannot read fails the scan.

### 3. Install suite

```
bash <config>/hooks/tests/test-exhaustive-audit-and-review-install.sh
```

It runs against a temporary `HOME` and covers:
- run by a shell that is not bash (zsh), the installer refuses before it changes anything;
- a dry run changes nothing;
- `--yes` copies, with backups;
- identical files are skipped;
- a file the installer did not install is refused unless named with `--replace`;
- `--opt-in` creates the data folder at 0700 and the denylist at 0600, and the denylist says a term needs at least 4 characters;
- nothing is ever deleted, and litter is never installed: OS files, caches, archives, backups, `.git`, and editor leftovers (`*~`, `.*.swp`, `.*.swo`, `*.orig`, `*.rej`, `*.tmp`, `.#*`, `#*#`);
- each manifest guard refuses its line by number, in its own words: an absolute path, a `..`, an empty or `.` segment, a backslash, a repeated file, a missing file or folder, a folder without its `/`, and a folder that holds no file. An empty or missing manifest is refused too, and CRLF line endings plan the same files;
- a failure part-way exits 2 and still records what was placed; a data folder that cannot be written exits 2 and says the files could not be recorded;
- an exported `CDPATH` and a path holding a newline are handled;
- the README's quick start works: the installer lines of its Install block run word for word, a dry run and then `--yes --opt-in`, against a fixture clone;
- the real package installs into an empty config folder whose path holds a space, and the installed copy passes its own package suite there, strict-YAML checks included.

### 4. Mutation checks

A guard that cannot fail proves nothing. Make each change below in a scratch copy of the package, never in the installed one: install the package into an empty folder with `install.sh --yes --target <folder>`, change the copy, and run the copy's suites. Confirm the suite goes red for the right reason, and that the unchanged package stays green.
- **Package suite:**
  - add `Bash` to the domain agent's tools;
  - remove `omitClaudeMd` from the researcher;
  - give a local agent `WebFetch`;
  - add a promise to an agent that it stops after a fixed number of minutes, written in digits ("You stop after N minutes", with a number for N);
  - put an unquoted `: ` in a description (this check needs PyYAML; without it the suite skips the check loudly);
  - put a home-folder path in a shipped file;
  - delete the preflight question (AskUserQuestion) from SKILL.md;
  - list a `*-wiring.sh` suite in `package.manifest`;
  - drop the `|| { echo 'FAIL: cannot create a sandbox'; exit 1; }` after a shipped suite's `mktemp -d`.
- **Install suite** (it tests the copy's `install.sh`; `EXHAUSTIVE_AUDIT_INSTALLER=<file>` points it at another one):
  - remove one manifest guard from `install.sh`, for example the backslash refusal;
  - remove one pattern from the litter list in `list_folder`, for example `*.orig`;
  - let a failure to write `installed.sha256` pass silently;
  - remove the bash version check from `preflight` (caught where zsh is installed);
  - delete the README's Install block, or change a path in it.

You may add a wiring suite of your own on top, for example one that checks the files are installed and your `house.conf` excludes what it must. If it reads your private config, keep it out of anything you publish.

## After a run: check the run, not just the tools

1. **The banner.** `finalize` printed `EXHAUSTIVE-AUDIT COMPLETE`, or `EXHAUSTIVE-AUDIT PARTIAL — not reviewed: …` naming each missing scope, and the presentation repeated it word for word.
2. **The scopes.** `exhaustive_audit_and_review.sh status <run>` shows every planned scope saved and validated, or failed with a reason.
3. **Prove the dispatch from Claude Code's own records,** not from the replies.
   - Each subagent leaves a record in the running session's config folder (`~/.claude` by default, even when the audit used `--config-dir`): `projects/<project>/<session>/subagents/agent-*.meta.json`, holding its `agentType` and `spawnDepth`. Here `<project>` is the folder Claude Code was started in, spelled with dashes for slashes, and `<session>` is the session's id. Count them:

     ```
     python3 -c 'import json, glob, sys, collections; c = collections.Counter((json.load(open(f)).get("agentType"), json.load(open(f)).get("spawnDepth")) for f in glob.glob(sys.argv[1] + "/subagents/agent-*.meta.json")); [print(n, t, d) for (t, d), n in sorted(c.items(), key=str)]' ~/.claude/projects/<project>/<session>
     ```

   - **What to expect.** One record per planned scope, with that scope's agent type at depth 1. Five specialist records (`code-reviewer-structure`, `-security`, `-test-quality`, `-simplification`, `-smells`) at depth 2 for every code scope. No `general-purpose` stand-ins.
   - **Fewer than five.** A code scope with fewer than five children did not run its ensemble, whatever its reply says.
   - **A caveat.** These records are observed behavior, not a documented interface. If their shape changes, say so instead of guessing.
4. **The reports.**
   - No absolute home-folder path appears in them; `grep -rnE '(/Users|/home)/[A-Za-z]' <report folder>` finds nothing.
   - Secrets are masked, and the reports pass a secret scan before anyone shares them.
5. **Triage works.**
   - `exhaustive_audit_and_review.sh lookup <ID>` prints one finding (add the run's `--config-dir` when it used one).
   - `exhaustive_audit_and_review.sh diff` against the previous run marks a fixed finding RESOLVED only when an apply log or a commit names its ID; otherwise it is DROPPED.
6. **Nothing was started that the audit only recommends:** no `/code-review ultra`, no `/doctor`, no security-scan plugin.

## The demo run (end-to-end)

1. **Build the fixture.** `exhaustive_audit_and_review.sh demo-fixture <dir>` builds two small modules under `<dir>/workspace` and a demo config folder, `<dir>/claude-config`, with planted defects. `<dir>` must be new or empty. Its answer key stays inside the helper.
2. **Run the audit.** In a session started in any folder, run `/exhaustive-audit-and-review run all --root <dir>/workspace --config-dir <dir>/claude-config`, and answer the preflight.
3. **Score it.** `exhaustive_audit_and_review.sh score-demo <run> --config-dir <dir>/claude-config`, where `<run>` is the id on the summary's first line, either reports every planted critical as found, or lists the misses.
4. **Check the run.** Run steps 1–6 above.
5. **Record the cost.** Note the real numbers: agents, tokens and minutes. They belong in `worked-example.md`.

New agent files usually load into a running session. If `/agents` does not list the five, start a fresh session.

## Changing the helper

Work test-first:
1. Add the case.
2. Watch it fail for the right reason.
3. Write the least code that passes.
4. Run the whole suite again.

A case that pins behavior you changed on purpose is stale: update it, and say so. Never weaken a case to get green. Every new guard gets a mutant (section 4).

## Changing an agent or SKILL.md

- **Keep the pinned shape.** The package suite pins the exact tool lines, the schema caps and enums each finding-writing agent states, and the subcommands SKILL.md names. A machine's own suites may pin more of SKILL.md's wording, for example "do not poll" and the PARTIAL banner.
- **Read it fresh.** After a substantial edit, give an agent with no prior context only SKILL.md and ask it:
  - What happens before the first dispatch, and who may skip it?
  - What do you do with a `DISPATCH FAILED` reply?
  - How do you save a reply?
  - What does `scrub-check` exit 3 mean?
  - When does the next wave start?
  - When is a run PARTIAL?
  - Which tools does the audit only recommend?

  Every answer must come from the file. Close each gap the agent names before you ship.
