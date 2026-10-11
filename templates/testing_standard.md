# Testing Standard

**Scope:** EVERY code-writing turn by Claude Code — in the main session and in every spawned subagent (declare this standard in the user's global CLAUDE.md, which spawned subagents inherit). Forward-looking: applies to new and touched code; existing modules are retrofitted on request (a test-writing skill, if one is installed, can do it module by module).

**Enforcement:**
- **RUN (deterministic, optional):** a Stop hook can run the module's declared `# test-command:` at the end of any turn that changed code-bearing files and block the stop on a failure, so the session fixes it in the same turn. No such hook comes with this standard; the markers in §5 are the contract one reads.
- **WRITE / UPDATE (judgment):** the `code-reviewer` ensemble's `code-reviewer-test-quality` specialist flags tier-scaled test-gap findings whenever a review runs.
- **AUDIT:** a periodic audit such as `/exhaustive-audit-and-review` should flag modules with no declared tier or test command, failing suites, and test gaps.

**Sources:** Anthropic Claude Code best practices ("give Claude a check it can run"; Stop hook as the deterministic gate; TDD as the strongest agentic pattern), the test-pyramid literature (~70/20/10 unit/integration/E2E, right-sized per module), and the superpowers plugin's TDD discipline.

---

## 1. The four duties

Every turn that touches code in a module with tier ≠ `none`:

### LOOK — before modifying code
- Discover existing tests FIRST: `Glob tests/**` plus tests related to the files being touched:
  - **Matching names:** Glob.
  - **Tests that import or call the changed symbols:** run `LSP findReferences` on each changed public symbol in Python/TS/JS and keep the hits under `tests/`. This resolves aliases and re-exports that a text search misses.
  - **Fallback:** Grep on import lines when `LSP` has no server or fails, and say so (`~/.claude/templates/code_navigation_standard.md`).
- READ the related tests before changing the code they exercise — they are executable documentation of intended behavior.
- Never duplicate an existing test; extend or update it.

### WRITE — new behavior ships with tests
- New or changed **public behavior** (exported functions, CLI surfaces, entry points, HTTP/file contracts) gets new or updated tests **in the same turn**, sized by the module's tier (§2).
- **Bug fixes start with a failing reproduction test** at every tier above `none` — write it, watch it fail, then fix (the superpowers plugin's `test-driven-development` skill, when installed, walks this; its `systematic-debugging` skill helps with the diagnosis). In `full`-tier modules this RED→GREEN→REFACTOR discipline applies to ALL feature work, not just fixes.
- Pure refactors (behavior preserved) need no new tests — the existing suite passing IS the test.

### RUN — evidence over assertion
- After code changes, run the module's `# test-command-fast:` (if declared) or `# test-command:` and **show the output** in the conversation. "Should pass" is not evidence; a pasted runner summary is (the superpowers plugin's `verification-before-completion` skill, when installed, enforces this).
- If a Stop hook re-runs the suite as a deterministic gate, don't lean on it; run proactively so failures surface while context is fresh.

### UPDATE — when a gap or stale test is identified
- A **stale test** asserts behavior that was changed *by design*. Update it to assert the new intended behavior, and say so explicitly in the turn summary (which behavior changed, why the test moved).
- A **gap** (uncovered path found during review, debugging, or reading) gets a test in the same turn when small, or a tracked follow-up when large — never silently ignored.
- **Acceptance-criteria completeness:** before work is called done, every acceptance criterion (ticket / issue / PR / spec / validation plan) maps to ≥1 passing test that verifies it — build the AC→test map and check every row. This is a hard gate on acceptance criteria; behavioral robustness beyond the AC stays ROI/tier-guided (not a literal 100%-line-coverage target).
- **NEVER weaken, delete, or skip a test merely to make it pass.** That inverts the tool. See iron rules (§6).

---

## 2. Tier system

Each module declares its tier in its `CLAUDE.md` (for a single repository, its root `CLAUDE.md`):

```
# testing-standard: full|standard|minimal|none
```

| Tier | Required tests | TDD | Test commands | CI test workflow |
|------|---------------|-----|---------------|-------------|
| **full** | Unit + integration required; E2E for UI/HTTP surfaces (critical happy paths only). Pyramid target ~70/20/10. | RED→GREEN→REFACTOR for ALL features and bugfixes | `# test-command:` AND `# test-command-fast:` required | **Required** |
| **standard** | Tests for new/changed public behavior, same turn. Unit required; integration where module boundaries / IO seams exist; E2E optional. | Required for bugfixes | `# test-command:` required | Default-yes (skippable; record the skip in module CLAUDE.md) |
| **minimal** | Smoke/contract only: import test, CLI `--help`, one happy-path per entry point. No findings for uncovered internals. | Required for bugfixes | `# test-command:` recommended | Never |
| **none** | Explicit waiver. The marker line MUST carry a one-line justification (e.g. `# testing-standard: none — third-party upstream mirror`). | — | — | Never |

- **Default when the marker is absent:** generate-side duties behave as `standard`; a test-running hook can only gate a module that declares a `# test-command:` (absent both → ungated, which an audit should flag).
- `none` is for scratch/experimental code, third-party upstreams, and mirror-only repos. Under `none` a test-running hook skips the module entirely and reviewers suppress ALL test findings (including "no tests detected").

## 3. Framework defaults per language

| Stack | Default | Notes |
|---|---|---|
| **Python** | pytest — `python -m pytest -q tests/`, or `uv run pytest -q tests/` where the module is uv-managed | `unittest` tolerated where already established. **Never introduce a second framework into a module without asking the user first.** |
| **Shell** | Plain-bash assert suites (`test-<subject>.sh`): PASS/FAIL counters, temp fixture dirs, exit 1 on any failure | `bats` optional, not required (not installed by default). |
| **Web frontend** | Playwright E2E + axe-core accessibility checks | Reuse the project's browser-testing setup, or an installed browser-automation skill; don't hand-roll browser automation. |
| **Data/validation pipelines** | Bespoke harnesses acceptable IF the entry point **exits non-zero on failure** (e.g. a `validate_*.py` script that checks every record and exits 1 on any failure) | Wire that entry point as the `# test-command:`. |

## 4. Placement & naming

- Layout: `tests/unit/`, `tests/integration/`, `tests/fixtures/`, optional `tests/e2e/`. A `tests/archive/` folder of superseded tests, if a project keeps one, is frozen history and must never be collected.
- **Test files keep plain, stable names** — `test_<subject>.py` / `test-<subject>.sh` — even in a project that versions or timestamps its other filenames. Versioned names churn on every bump, breaking CI references and `pytest path::test` invocations, and archived copies would still match `test_*.py` and be collected as stale duplicates.
- Every pytest module declares in `pyproject.toml` (or `pytest.ini`):

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
norecursedirs = ["archive", ".*", "__pycache__"]
```

## 5. Test-command markers (declared in the module's CLAUDE.md)

```
# test-command: <cmd>          → the FULL suite; run by a test gate (if any), CI, and audits
# test-command-fast: <cmd>     → optional fast subset (e.g. unit only); preferred by a test gate
```

- One command per marker; compose with `&&` if needed. First match wins.
- **Distinct from any per-stop smoke check** — a check that runs on EVERY stop must stay sub-second; test commands run only when code changed. Don't put full suites in a smoke check.
- Commands run from the repo root. A test gate should bound them with a timeout (120 s is a sensible default); if your suite exceeds it, declare a `# test-command-fast:` and keep the full suite for CI.

## 6. Iron rules

1. **Never weaken, delete, or `xfail`/skip a test to make it pass.** A genuinely flaky test is quarantined with `@pytest.mark.skip(reason="flaky: <issue/why>")` (or the runner's equivalent) plus a note in the turn summary — never deleted, never silently loosened.
2. **Bug fix = failing test first.** Reproduce, watch it fail, fix, watch it pass.
3. **New behavior ships with tests in the same turn** (per tier).
4. **Evidence over assertion** — completion claims include the actual runner output.
5. **No live-network / live-credential tests** without an explicit fixture/mocking/recording strategy; tests must run offline by default. Tests requiring a live service belong behind an opt-in marker (e.g. `@pytest.mark.live`) excluded from the default command.
6. **Tests are independent and order-free** — no shared mutable state between tests; each test sets up and tears down its own world (fixtures in `tests/fixtures/`).
7. **The secrets ban applies inside tests and fixtures** — no real tokens/keys/PII in test code, fixture files, or recorded cassettes (secret scanning covers them too).
8. Test code follows the Code Quality Standard too (readable, one concept per test, error paths covered — see `code_quality_standard.md` §1).

## 7. Boundaries

- **Third-party / vendored code** is exempt, and a test retrofit never touches it.
- Archived copies (such as an `archive/` folder) are never touched, never collected, never counted.
- Conflicts with a module CLAUDE.md declaration → the module declaration wins (record intentional deviations there).
- Mechanical coverage percentages are NOT the target — coverage ROI is (critical paths, boundaries, error paths). Reviewers judge value, not numbers.
