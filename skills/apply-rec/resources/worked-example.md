# Worked example — one /apply-rec run, end to end

A neutral project traced through the skill: the folder `shop/` holds two modules, `orders-api` (Python, its own git repository) and `web` (TypeScript, its own git repository), and `/exhaustive-audit-and-review` has run on it. IDs, versions, file names and outputs are illustrative; the steps, the line formats and the rules are the real ones.

## 0. The request

After reading the audit summary, the user types:

```
/apply-rec M1-3, M1-7, M2-2, CS-1
```

| ID | Module | Finding | Severity | Category |
|---|---|---|---|---|
| M1-3 | orders-api | a bare `except:` swallows a failed payment call | high (effort S) | error-handling |
| M1-7 | orders-api | `requests` is pinned to a release past its support window (`subject` is `pypi:requests`) | medium | dependency |
| M2-2 | web | user input reaches an SQL string (`check` is `security:injection`) | critical | injection |
| CS-1 | the config | a hook's `curl` call has no timeout | medium | change-hook |

## 1. Resolve the run (skill, main session)

```
$ bash ~/.claude/skills/exhaustive-audit-and-review/exhaustive_audit_and_review.sh lookup M1-3
<the finding's fields, naming run 20261001T090000Z>        exit 0
```

That run is the run for the whole invocation; every other ID is looked up with `--run 20261001T090000Z`.

## 2. Plan phase (orchestrator, no DECISION lines)

The orchestrator:
1. looks up M1-7, M2-2 and CS-1 in that run (all exit 0);
2. reads the verify commands the project declares: `orders-api/CLAUDE.md` has `# test-command: pytest -q`, `web/CLAUDE.md` has `# project-organization: verify npm test`, and for CS-1 the audit's `house.conf` has a `CONFIG_TEST=` line;
3. classifies, going down the table (the first matching row wins):
   - M2-2: category `injection` → security-sensitive → `apply-rec-analyst`;
   - CS-1: its ID starts with `CS-` → claude-system → `apply-rec-editor`;
   - M1-7: category `dependency` → dependency-bump → `dependency-modernizer`;
   - M1-3: no earlier row matches → generic → `apply-rec-editor`;
4. asks `dependency-modernizer` for its read-only plan for M1-7 (minor-without-changelog, a clean tree, its own repository);
5. applies the run rules: M1-7 (a bump) and M1-3 (an edit) both change the `orders-api` repository, and a bump needs a run of its own there, so M1-7 is deferred.

It answers:

```
APPLY-REC PLAN
==============
Run: 20261001T090000Z   Root: shop/
| ID | Category | Child | Repository | What will change | Verify | Gated | Questions (proposed answer) |
|---|---|---|---|---|---|---|---|
| M1-3 | generic | apply-rec-editor | orders-api | payments/client.py: catch requests.RequestException, log it with context, re-raise; test tests/unit/test_client.py::test_payment_error_is_raised | `pytest -q` (CLAUDE.md) | no | — |
| M2-2 | security-sensitive | apply-rec-analyst | web | a parameterized-query patch for src/db/orders.ts, drafted only | — | yes | APPLY / DECLINE / DEFER |
| CS-1 | claude-system | apply-rec-editor | <config> | hooks/notify.sh: `curl -s "$URL"` → `curl -s --max-time 10 "$URL"` (old/new text in its APPROVED PLAN) | CONFIG_TEST (house.conf) | yes | APPLY / DECLINE / DEFER |
Not found / malformed / lookup failed: none
Deferred by the run rules (Step 3c): M1-7 — a bump needs its own run for orders-api; run /apply-rec M1-7 on its own
Blocked (Step 3c): none
GATE UNAVAILABLE: decisions needed for M2-2, CS-1
```

Below it come the `APPROVED PLAN` blocks: M1-3's file, test and change; M2-2's finding, the evidence the analyst will read, and "drafts a patch only; the user applies it"; CS-1's exact old and new line; and `dependency-modernizer`'s own plan block for M1-7, kept for its later run.

## 3. Questions (skill, main session)

The skill re-derives "gated" itself: M2-2 (security-sensitive) and CS-1 (its ID starts with `CS-`). M1-3 is routine and its ID is in the user's own message, so the skill writes `DECISION: APPLY M1-3` without a question. M1-7 is relayed as deferred, with its reason.

One `AskUserQuestion` round with two questions: "M2-2: the analyst drafts a patch you apply by hand — APPLY / DECLINE / DEFER?" and "CS-1: change hooks/notify.sh as shown — APPLY / DECLINE / DEFER?". The user answers APPLY to both.

## 4. Apply phase (orchestrator, with the decisions)

```
DECISION: APPLY M1-3
DECISION: APPLY M2-2
DECISION: APPLY CS-1
```

The three children touch three different places (`orders-api`, `web` for the read-only analyst, and the config), so they start in one wave; each report arrives on its own, and nobody polls.

- **apply-rec-editor, M1-3.** Reads the existing tests for `payments/client.py`, adds `test_payment_error_is_raised`, and runs it: it fails because no exception is raised, which is the expected reason. Edits `payments/client.py`; the test passes; `pytest -q` passes. `Outcome: APPLIED`.
- **apply-rec-editor, CS-1.** Copies `hooks/notify.sh` to `${CLAUDE_CONFIG_DIR:-~/.claude}/backups/apply-rec-20261001/hooks/notify.sh`, makes the one approved change, and runs the `CONFIG_TEST=` command: PASS. `Outcome: APPLIED`.
- **apply-rec-analyst, M2-2.** Traces `incomingCalls` from the query builder to the route handler: request input reaches it unescaped, so the finding holds. Drafts a diff that uses a parameterized query, and names the test to add first (a quote inside an order id must not change the query). `Outcome: DEFERRED`: patch drafted, and the user applies it by hand.

## 5. The apply log

`${CLAUDE_CONFIG_DIR:-~/.claude}/exhaustive-audit-and-review/runs/20261001T090000Z/apply_rec_log_v1_20261001T101500Z.md`:

```
| ID | Outcome | Note |
|---|---|---|
| M1-3 | APPLIED | payments/client.py re-raises RequestException; test failed first, then passed; verify PASS |
| M1-7 | DEFERRED | not run — a bump needs its own run for orders-api |
| M2-2 | DEFERRED | injection (apply-rec-analyst): patch drafted; the user applies it by hand |
| CS-1 | APPLIED | hooks/notify.sh curl gets --max-time 10; verify PASS (CONFIG_TEST) |
```

Below the table: each ID's decision line, recommendation, changed files, child outcome (with the analyst's diff) and verify output.

## 6. Report (skill)

```
APPLY-REC COMPLETE
==================
IDs processed: 4 (of 4)
Applied:        2
Declined:       0
Deferred:       1
Failed:         0
Not decided:    0
Not run:        1
Not reproduced: 0
Not found:      0

Log: <the path above>
```

The skill names the next steps: run `/apply-rec M1-7` on its own, and apply the M2-2 patch after reviewing it, naming `M2-2` in that commit's message. After the next audit run, its `diff` counts M1-3 and CS-1 as resolved if their findings are gone, with this log's `APPLIED` rows as the evidence, and M2-2 once that commit exists.

## What changed on disk

- `orders-api`: `payments/client.py` and `tests/unit/test_client.py`, uncommitted.
- The config: `hooks/notify.sh`, plus its backup.
- The run folder: the apply log.

Nothing was committed or pushed, and `web` stays untouched until the user applies the drafted patch.
