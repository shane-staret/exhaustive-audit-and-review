# Code Quality Standard

**Scope:** EVERY line of code generated or modified by Claude Code — in the main session and in every spawned subagent (declare this standard in the user's global CLAUDE.md, which spawned subagents inherit). Forward-looking: applies to new and touched code; existing code is retrofitted on request, one file at a time.

**Enforcement:** the `code-reviewer` agent's five-specialist ensemble checks compliance whenever a review runs; `/exhaustive-audit-and-review` audits it periodically across a whole workspace.

**Sources:** distilled from Robert C. Martin's *Clean Code* (wojteklu's summary gist, https://gist.github.com/wojteklu/73c6914cc446146b8b533c0988cf8d29) and Codacy's clean-code guidance, adapted for code that Claude Code writes.

---

## 1. Clean code rules

### General
- **KISS** — reduce complexity; the simplest design that works wins.
- **Boy-scout rule** — leave touched code cleaner than you found it.
- **Fix root causes**, not symptoms.
- **Follow the language's community conventions** — PEP 8 (Python), Google JS Style (JS/TS), Google Shell Style (bash). Be consistent with the surrounding file above all.

### Names
- Descriptive, unambiguous, pronounceable, **searchable** names; meaningful distinctions (no `data2`, `tmp`, `x` beyond trivial loop indices).
- No type/encoding prefixes (`strName`, `lst_users`).
- **No magic numbers or repeated literal strings** — extract named constants whose names explain intent (`MAX_RETRIES = 3`, not `3`).

### Functions
- **Small, one thing per function.** >50 lines or >1 responsibility → split.
- Few arguments (>5 positional → introduce a dataclass/options object). **No boolean flag arguments** — split into two well-named functions.
- Minimize side effects; if a function mutates state, the name must say so.
- Nesting depth ≤3 — extract helpers or invert conditionals (avoid negative conditionals).

### Comments
- Code explains itself first; comments explain **WHY** (intent, constraint, consequence), never WHAT the next line does.
- No redundant noise, no closing-brace comments, **never commented-out code** — delete it (git remembers).
- Docstrings for non-obvious public functions: purpose, args, returns, raises.

### Structure
- Declare variables close to first use; keep related code vertically dense; dependent functions near each other, callers above callees.
- Short lines; consistent indentation; whitespace to separate concepts. (Mechanical style stays the linters' job — see §4.)

### Objects / modules
- Small classes, single responsibility, few instance variables; hide internals.
- **Law of Demeter** — talk to direct collaborators only; no `a.b().c().d()` train wrecks.
- Keep configurable data at the top level (constants/config), not buried in logic. Prefer polymorphism/dispatch tables to sprawling if/elif chains.

### Error handling
- **Never swallow exceptions.** No bare `except:` / `except Exception: pass` / `|| true` without a logged, justified reason.
- Fail fast with context-rich messages (what operation, what inputs, what was expected).
- Validate inputs at trust boundaries; raise/return early.
- Transient-failure handling (retries, backoff, timeouts, batch completeness) follows the **Retry & Resilience Standard** (`~/.claude/templates/retry_standard.md`) — "fail fast" there means *after* the bounded transient-retry window, and skipping retries requires a visible `# retry-exempt:` justification.

### Tests
- Readable, fast, independent, repeatable; one concept per test; cover the error paths, not just the happy path.

### Smells to refuse
Rigidity (one change cascades), fragility (breaks far away), needless complexity, needless repetition (DRY — extract on the 2nd–3rd occurrence), opacity (code you must decode).

---

## 2. Logging standard

**Default tier: `standard`.** Modules dial up/down via marker (§3).

### Non-negotiables (all tiers)
1. **Every error path is logged** with context: the operation attempted, a summary of relevant inputs/state, and the exception itself — *then* handled or re-raised. A caught-and-ignored exception without a log line is a review finding.
2. **Never log secrets or PII.** Tokens/keys/passwords are masked first-4 + last-4 (only the first and last four characters are shown). Applies to every log level including DEBUG.
3. **Leveled logging** — DEBUG (diagnostic detail), INFO (key decisions, state transitions, lifecycle milestones), WARN (recoverable anomalies, fallbacks taken), ERROR (failed operations). No diagnostics via bare print/echo-to-stdout in committed code.
4. **Messages carry context, not just verdicts** — `"inventory sync failed for region=%s after %d retries"`, never `"failed"`.

### Standard tier (default) adds
- Key decision points and state transitions at INFO (mode selected, fallback chosen, N items processed, file written where).
- Long-running loops/batches: progress at sensible intervals — **never per-iteration logging in hot loops**.

### Per-language idioms
| Language | Rules |
|---|---|
| **Python** | Module-level `logger = logging.getLogger(__name__)`. `logger.exception(...)` inside `except` blocks (captures traceback). No `print()` for diagnostics (CLI user-facing output is fine — that's product output, not logging). Lazy `%s` formatting in log calls. |
| **Bash** | Prefix every message with its component: `echo "COMPONENT: message"`; errors/warnings → stderr (`>&2`). Persistent logs: ISO-8601 UTC timestamp headers. Optional deep tracing via an env flag (`[ "${DEBUG:-0}" = "1" ] && set -x`). |
| **JS/TS** | A leveled logger (project logger or `console.debug/info/warn/error` used deliberately). No stray `console.log` in committed code. |

### Destinations
Runtime log files belong in the module's **`logs/`** directory, which is gitignored. Hook/CLI tools log to stdout/stderr per the bash idiom.

---

## 3. Per-module dial markers (declared in the module's CLAUDE.md; for a single repository, its root CLAUDE.md)

```
# logging-standard: verbose      → Standard + entry/exit DEBUG (params summary + timing) on non-trivial functions
# logging-standard: standard     → the default described above (marker optional)
# logging-standard: minimal      → error paths + major lifecycle events only
# code-quality: relaxed          → clean-code rubric advisory-only (sandbox / research / vendored code)
```

Reviewers and code-writing agents MUST honor these markers, as they honor any other project context. `# code-quality: relaxed` never relaxes the secrets/PII logging ban.

---

## 4. Boundaries

- **Mechanical style** (exact formatting, import order) belongs to linters/formatters in CI or pre-commit checks — reviewers flag style only where it harms readability.
- **Third-party / vendored code** is exempt, and a retrofit never touches it.
- Conflicts with a module CLAUDE.md declaration → the module declaration wins (record intentional deviations there).
