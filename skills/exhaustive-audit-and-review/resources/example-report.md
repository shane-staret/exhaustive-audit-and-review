# Example report: a real run on the demo fixture

Everything on this page comes from one real run of `/exhaustive-audit-and-review`, on the demo the helper builds:

```bash
bash ~/.claude/skills/exhaustive-audit-and-review/exhaustive_audit_and_review.sh demo-fixture /tmp/audit-demo
```

That gives two small Python modules (`orders`, an order API, and `notify`, a notification worker) and a small Claude Code config, with 15 defects planted on purpose. The run used Claude Code 2.1.296 and exhaustive coverage. Nothing below was written by hand except the headings and the notes marked *Note*. Finding blocks are copied from the generated reports. Paths are relative to the audited folder (`workspace`), or written `<config>/…` for the audited config folder.

## The summary Claude presents (SKILL.md step 6)

```
Exhaustive audit — 20261010T093500Z · exhaustive · EXHAUSTIVE-AUDIT COMPLETE
Root: workspace · Config: <config> (the demo config) · Modules: 2 (0 excluded) · Agents: 19 dispatched, 0 failed
Coverage: 72/72 lines (100%) · Research: 4 questions, 4/6 leads verified

Findings          critical  high  medium  low  info
  1 code              5       9      9     5     0
  2 architecture      1       2      1     2     1
  3 domain            0       3      5     2     0
  4 operations        1       8      9     3     0
  5 claude-system     0       4      4     5     1
  total               7      26     28    17     2

Criticals (all of them)
  M1-1  1  orders  API key built from string pieces, kept in source           (orders/app/settings.py:7)
  M1-2  1  orders  pricing call has no timeout and no retry                   (orders/app/client.py:9)
  M1-3  1  orders  sync.sh calls a script that does not exist                 (orders/scripts/sync.sh:4)
  M1-4  2  orders  API key in source and written to the INFO log              (orders/app/settings.py:7)
  M1-5  4  orders  API key hard-coded in source                               (orders/app/settings.py:7)
  M2-1  1  notify  curl download has no retry and no timeout                  (notify/bin/update.sh:3)
  M2-2  1  notify  the downloaded script runs even when the download failed   (notify/bin/update.sh:4)

Top fixes (severity, then effort; at most 10)
  M2-1   critical/trivial/low  curl --fail --silent --show-error --connect-timeout 10 --max-time 30 --retry 4
  M1-2   critical/S/low        one requests.Session with bounded retries and a (3.05, 10) timeout
  M1-4   critical/S/med        revoke and rotate the key, read it from the environment, stop logging it
  M1-5   critical/S/low        treat the key as exposed; load it at start-up; fail fast when it is missing
  M2-2   critical/S/low        set -euo pipefail and curl --fail, so a failed download never runs
  M1-1   critical/M/med        rotate the key, purge it from history; never split literals to dodge scanners
  M1-3   critical/M/med        add notify's real send entry point or fix the path; fail with a clear message
  M1-6   high/trivial/low      bind customer_name as a ? parameter
  M1-7   high/trivial/low      stop logging the key; log only that the client is configured
  M1-17  high/trivial/low      parameterized query, plus sqlite3.Row for named columns

Not reviewed: none
Currency: the demo config has no new-functionality check (CS-10 recommends it); the running machine's check was fresh
Suspected injected content: none
Yours to start (never started by this audit): /code-review ultra before the release · /doctor
Reports: <config>/exhaustive-audit-and-review/runs/20261010T093500Z/exhaustive_audit_v1_20261010T100801Z.md
         <config>/exhaustive-audit-and-review/runs/20261010T093500Z/exhaustive_audit_claude_system_v1_20261010T100801Z.md
Reply: "apply <IDs>" (runs /apply-rec), "diff" (compare with the last run), or "walk me through <ID>".
```

*Note: the same problem, several IDs.* The hard-coded key was found three times, by the code review (M1-1), by project-health (M1-4) and by the operations dimension (M1-5). Each dimension keeps its own stable ID, because each judges it from its own angle: secret in source, secret in a log, operational exposure. Triage such clusters together: `apply M1-1 M1-4 M1-5` is one fix.

*Note: why 80 and not 82.* The agents' saved results held 82 findings (the code reviews 21 and 9). Within one dimension, findings that share a fingerprint become one record, so `finalize` merged two pairs of code findings: the code row counts 28.

## Coverage, as `finalize` wrote it

| Module | Lines reviewed | Lines total | Reviewed |
|---|---|---|---|
| notify | 18 | 18 | 100% |
| orders | 54 | 54 | 100% |

*Note:* coverage counts the lines of code files, the ones the code review covers. The two modules hold 86 lines of text in all, which is the size the preflight shows.

## Five findings in full

One finding from each dimension, copied verbatim from the reports. The hash is the fingerprint that keeps an ID stable across runs.

### M1-6 · high · security:injection · find_orders
- **Hash:** `77786e7c` · **Dimension:** 1 code · **Module:** orders · **Category:** injection
- **Finding:** find_orders concatenates customer_name into the SELECT string, so a crafted name rewrites the query (SQL injection).
- **Why:** A tautology or UNION payload returns every customer's orders or any other table the connection can read, defeating the per-customer filter. sqlite3 rejects stacked statements, so the realistic impact is disclosure. Only the test calls it today, but it is the module's public lookup.
- **Recommendation:** Bind the value as a parameter: connection.execute('SELECT id, total FROM orders WHERE customer = ?', (customer_name,)).fetchall(). Never build SQL from strings, and validate the type and length of customer_name at the API boundary.
- **Effort:** trivial · **Risk:** low
- **Evidence:** `orders/app/db.py:10`

### M1-14 · high · A5 · notify/bin/send.sh
- **Hash:** `7bd0b759` · **Dimension:** 2 architecture · **Module:** orders · **Category:** broken-ref
- **Finding:** orders/scripts/sync.sh calls notify/bin/send.sh, which does not exist; notify/bin contains only update.sh.
- **Why:** sync.sh runs under set -euo pipefail, so every run stops at line 4 with a non-zero exit and no order is pushed to the notify worker. No CI job or in-tree caller references sync.sh, so the failure stays silent until someone runs it by hand. The --batch flag contract cannot be checked because its consumer is missing.
- **Recommendation:** Add notify/bin/send.sh with the --batch <source> interface that sync.sh expects, or fix the path if the script was renamed, and have sync.sh check the target is executable before calling it. Do not point it at update.sh, which downloads and runs remote code.
- **Effort:** S · **Risk:** low
- **Evidence:** `orders/scripts/sync.sh:4`, `notify/bin/update.sh:1`

### W-1 · medium · insight · orders/scripts/sync.sh
- **Hash:** `d848634b` · **Dimension:** 3 domain · **Module:** (workspace) · **Category:** insight
- **Finding:** Replace the shell hop from orders to notify with a transactional outbox so notifications are delivered at least once, idempotently, with a failure ledger.
- **Why:** sync.sh shells out to another module's script and keeps no watermark or ledger (the script it calls is not in the repository), so a crash or rerun can drop or duplicate notifications. An outbox row written in the same SQLite transaction as the order, drained with the order id as idempotency key, makes delivery resumable and removes the path coupling.
- **Recommendation:** Add outbox(order_id PRIMARY KEY, payload, created_at, sent_at, attempts, last_error) and insert into it in the same transaction as each new order; enable WAL and a busy timeout because two processes share the file; have the worker deliver unsent rows in id order, set sent_at on success and record last_error on failure; print an end-of-run ledger and exit non-zero if any row failed.
- **Effort:** L · **Risk:** med
- **Evidence:** `orders/scripts/sync.sh:4`, `orders/app/db.py:8`, `notify/notify/worker.py:1`

### M1-23 · high · O9 · fetch_quote
- **Hash:** `16c467f4` · **Dimension:** 4 operations · **Module:** orders · **Category:** resilience
- **Finding:** fetch_quote calls the pricing service with no timeout, no retry and a bare except that returns None, although orders declares retry-standard: standard.
- **Why:** A slow pricing service blocks the caller with no upper bound, and one transient 5xx or connection error fails with no second attempt. The bare except turns every failure into None and logs nothing, so callers cannot tell 'no quote' from 'pricing is down'. No retry helper exists in the module and fetch_quote has no caller that could wrap it (LSP, grep).
- **Recommendation:** Treat the GET as idempotent and transient-retryable: set connect and read timeouts, retry 3-5 times with exponential backoff and jitter on connection errors, 408, 429 and 5xx (honor Retry-After), catch requests.RequestException only, log each retry at WARN and the final failure at ERROR, then raise instead of returning None.
- **Effort:** S · **Risk:** low
- **Evidence:** `orders/app/client.py:9`, `orders/app/client.py:11`, `orders/CLAUDE.md:5`
- **Research (verified = the quote was found at this URL; the researcher rates the source official):** `https://requests.readthedocs.io/en/latest/user/advanced/?highlight=timeout` — `By default, requests do not time out unless a timeout value is set explicitly. Without a timeout, your code may hang for minutes or more.`

*Note:* the run printed this line as "Research (official, verified)". After the code review, reports name the tier as the researcher's own rating and render the URL and quote as code, so a page cannot inject markup into a report; the line above is in the current form.
- **Research questions:** Does the Python `requests` library, version 2.19.0, apply any default timeout when `requests.get` is called without a `timeout` argument?

### CS-3 · high · C2 · hooks.UserPromptSubmit[0].matcher
- **Hash:** `3c811c92` · **Dimension:** 5 claude-system · **Module:** (workspace) · **Category:** change-hook
- **Finding:** The `deploy` matcher on the UserPromptSubmit hook is silently ignored, so the prompt-blocking guard runs on every prompt, not only deploy-related ones.
- **Why:** UserPromptSubmit has no matcher support: 'If you add a `matcher` field to an event without matcher support, it is silently ignored'. The hook can block prompts (exit 2), so this is rated high. Today it costs a process launch per prompt; once the script works (C3) it would block any prompt containing the word production.
- **Recommendation:** Delete the matcher from the settings entry and do the narrowing inside the script (deploy and production, case-insensitive). If a /deploy slash command was meant, register the hook on UserPromptExpansion with matcher `deploy` instead; no such command exists in this config today. Fix together with the C3 finding.
- **Effort:** trivial · **Risk:** low
- **Evidence:** `<config>/settings.json:9`

## Research: what left the machine, and what came back

The local agents wrote their questions in public terms. `agenda` kept 4, within the demo's budget of 4. `scrub-check` passed them against the denylist. Only then did the web-only researcher, which cannot read a single local file, get them:

```
Q01 · Does the Python `requests` library, version 2.19.0, apply any default timeout when `requests.get` is called without a `timeout` argument?
Q02 · Which JSON field in a Claude Code UserPromptSubmit hook's stdin payload carries the text the user typed?
Q03 · Which urllib3 versions does requests 2.19.0 allow as dependencies?
Q04 · Which urllib3 release added the Retry backoff_jitter option?
```

It returned 6 leads. `attach-research` fetched every page again: **4 verified, 2 unverified**. Only verified quotes were attached to findings, and no severity changed.

*Note:* the two unverified leads were both official pages.
- **The hooks reference.** The researcher quoted a field name from it, but the re-fetch did not find that text as quoted, so the lead was not attached. The question was still answered by a verified community lead.
- **A changelog line.** Its markdown punctuation renders differently on the page, so the comparison failed. The verifier has since been changed to ignore markdown punctuation.

Even a verified quote proves only that the text is on the page, not that it answers the question. That is why a person still reads the attached evidence.

## How the run went, and what it cost

| Step | What happened |
|---|---|
| Preflight | 2 modules, nothing excluded, 17/17 agents present, nesting depth 5, cap 20 → 1 wave of 18. Estimate shown: 19 agents. The user answered yes. |
| Currency | `/claude-code-new-functionality-check status` (the companion skill, called by the audit) reported a fresh sweep. The demo config itself has none, which became CS-10. |
| Wave 1 | 8 scopes in one message: 4 dimension agents, 2 project-health, 2 code-reviewer, each launching its 5 specialists. Every reply went through `save-result` and `validate`: 8 valid, 0 failed. |
| Research | 1 researcher, 4 questions, 4 of 6 leads verified. |
| Finalize | `EXHAUSTIVE-AUDIT COMPLETE`, 80 findings. |

**Dispatch, from Claude Code's own records** (`subagents/agent-*.meta.json`), not from the agents' word: 19 subagents.
- depth 1: the five audit agents, 2 `code-reviewer` and 2 `project-health`;
- depth 2: 10 specialists, five under each `code-reviewer`.

**Cost.** About 33 minutes of wall time. Claude Code's transcripts record 53.5M processed tokens in all:
- 0.69M output;
- 11.9M cache writes;
- 40.8M cache reads, since every agent re-reads its own context on each tool call.

The preflight had estimated far less, because its constants predated any real run. They were recalibrated from this one, so the estimate you see now is measured, not guessed. Larger modules cost more per review scope.

## Did it find what was planted?

`exhaustive_audit_and_review.sh score-demo 20261010T093500Z --config-dir /tmp/audit-demo/claude-config` compares the run with the answer key kept in the helper (the run lives in the audited config's data folder, so it takes the same `--config-dir` as the run):

```
score-demo: run 20261010T093500Z · 15/15 planted defects found · criticals 3/3
defect | class | module | path | result | what
D01 | critical | orders | orders/app/db.py | FOUND by M1-6 | SQL built by string concatenation
D02 | - | orders | orders/app/client.py | FOUND by M1-2 | an HTTP call with no timeout
D03 | - | orders | orders/app/client.py | FOUND by M1-8 | a bare except that swallows every error
D04 | critical | orders | orders/app/settings.py | FOUND by M1-1 | a secret-shaped value written to a log
D05 | - | orders | orders/tests/test_db.py | FOUND by M1-9 | a test that asserts nothing
D06 | - | orders | orders/requirements.txt | FOUND by M1-31 | an old pinned dependency
D07 | critical | notify | notify/bin/update.sh | FOUND by M2-1 | an unchecked download into a predictable /tmp file, then run
D08 | - | - | orders/app/text.py, notify/notify/text.py | FOUND by M1-13 | a helper duplicated across the modules
D09 | - | orders | orders/scripts/sync.sh | FOUND by M1-3 | a broken cross-module path
D10 | - | - | <config>/hooks/prompt-guard.sh, <config>/settings.json | FOUND by CS-3 | a UserPromptSubmit hook with a matcher, reading .user_message
D11 | - | - | <config>/agents/release-helper.md | FOUND by CS-13 | an agent description with an unquoted ': '
D12 | - | - | <config>/skills/code-review/SKILL.md | FOUND by CS-1 | a personal skill named code-review
D13 | - | - | <config>/settings.json | FOUND by CS-2 | Bash(curl:*) in the allow rules
D14 | - | - | <config>/CLAUDE.md | FOUND by CS-7 | a CLAUDE.md that names a missing skill
D15 | - | - | (any) | FOUND by CS-10 | the new-functionality check is not installed
```

It also found 65 problems nobody planted, among them:
- a test that depends on a database file nothing creates;
- a dependency declared but never imported;
- a missing `.gitignore`;
- no CI, no runbooks and no observability;
- a release step in the global instructions that names a skill which does not exist.
