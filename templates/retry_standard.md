# Retry & Resilience Standard

**Scope:** EVERY code-writing turn by Claude Code — in the main session and in every spawned subagent (declare this standard in the user's global CLAUDE.md, which spawned subagents inherit). Forward-looking: applies to new and touched code; existing modules are retrofitted on request. The goal is absolute: **no silent failures, and no silent partial success** — transient faults are absorbed by design, permanent faults surface loudly, and multi-item jobs prove their completeness.

**Enforcement:**
- **WRAP / SURFACE / ACCOUNT (judgment):** the `code-reviewer` ensemble's `code-reviewer-structure` specialist flags tier-scaled `resilience` findings whenever a review runs; an unmitigated transient path with no visible justification is **critical** at standard/full tier (verdict → NEEDS WORK).
- **Retry-path tests (judgment):** the `code-reviewer-test-quality` specialist flags missing failure-injection tests per tier.
- **AUDIT:** the operations dimension of `/exhaustive-audit-and-review` compares each module's declared tier with the resilience posture it observes.
- **INIT:** declare the `# retry-standard:` tier when a module is created, so the duty is never silently skipped.
- There is deliberately **no deterministic hook** for this standard — retry presence is a judgment call, not an executable check (unlike a test suite, which a hook can run).

**Sources:** the design goal that retry logic is as mandatory as tests (no silent failures; jobs finish accurately and completely); AWS Architecture / Google SRE retry guidance (bounded exponential backoff + jitter; retry only transient classes; beware retry storms and non-idempotent replays); the high-water-mark pattern of incremental data loading (per-item failure ledger + watermark-hold = guaranteed eventual completeness; see §4).

---

## 1. The four duties

Every turn that touches code performing **external I/O** — network/HTTP, REST APIs, cloud SDK calls (storage, queues, hosted search or AI services), subprocess/CLI invocations of remote services, DB access, browser automation — in a module with tier ≠ `none`:

### CLASSIFY — before writing the call
- For each external operation, decide its bucket: **transient-retryable** (timeouts, connection resets, HTTP 408/429/5xx, rate limits, SDK-flagged transient errors), **permanent** (4xx logic errors, auth failures, validation errors — retrying cannot help), or **non-idempotent** (a retry may duplicate a side effect: POST-that-creates, payment-like calls, stateful imports).
- The classification drives the design; "it'll probably work" is not a classification.

### WRAP — every transient-retryable operation gets a policy-compliant retry
- Bounded attempts, exponential backoff + jitter, retry **only** the transient classes, per-attempt timeout, overall deadline (§3 has the numbers).
- Non-idempotent operations are retried ONLY behind an idempotency guard (idempotency key, existence check, dedup query) — otherwise they fail fast and surface.
- Prefer the platform's native mechanism over hand-rolling (§4); any implementation meeting §3 is compliant.
- Fail-fast on a transient-capable path is allowed ONLY with a visible one-line justification: `# retry-exempt: <reason>` at the call site (§5). Silence is never a justification.

### SURFACE — failures are loud, never silent
- Exhausted retries and permanent errors **raise / exit non-zero** with context: operation, attempts made, last error — logged at ERROR per the Code Quality Standard logging rules.
- Never return a default/empty value that masks a failure; never `except: pass` / `|| true` around external I/O.
- Each retry attempt logs at WARN with attempt n/N and the triggering cause (never secrets).

### ACCOUNT — batch jobs prove completeness
- Any job processing multiple items (documents, records, URLs, files, accounts) keeps a per-item ledger: attempted / succeeded / failed(+reason).
- End-of-run reconciliation is printed AND determines the exit code: any failed item ⇒ non-zero exit or an explicit, unmistakable partial-success report. "Done" with silent drops is the cardinal sin this standard exists to prevent.
- Long/expensive batches prefer a resumable pattern (watermark, checkpoint, failed-item re-queue) so partial runs converge to 100% (the reference pattern in §4).

---

## 2. Tier system

Each module declares its tier in its `CLAUDE.md` (for a single repository, its root `CLAUDE.md`):

```
# retry-standard: full|standard|minimal|none
```

| Tier | Required resilience | Retry-path tests | Typical modules |
|------|---------------------|------------------|-----------------|
| **full** | All four duties; completeness ledger REQUIRED on every batch job; resumable/checkpoint pattern for long batches | REQUIRED — failure-injection tests (transient error → recovers; exhaustion → raises loudly) | Pipelines whose silent partial success corrupts downstream data |
| **standard** | All four duties on transient-failure-prone code; batch jobs report per-item outcomes | Expected alongside new retry logic (test-quality specialist flags gaps) | Anything calling networks/SDKs/APIs (the default tier) |
| **minimal** | SURFACE always (loud failures, no swallowing); WRAP advisory — critical paths only | — | Local-only utilities, one-shot personal scripts |
| **none** | Explicit waiver. Marker line MUST carry a one-line justification (e.g. `# retry-standard: none — docs-only mirror, no executable code`) | — | Mirrors, doc kits, data snapshots |

- **Default when the marker is absent:** `standard` — the duties bind everywhere, and an audit should flag the missing declaration.
- The no-silent-failure rules (SURFACE) are iron at every tier above `none` — `minimal` relaxes retry *coverage*, never failure *visibility*.

## 3. Retry policy (the numbers)

Defaults — deviate only with a stated reason:

| Parameter | Default | Notes |
|---|---|---|
| Max attempts | 3–5 total | 1 initial + 2–4 retries; more only for long unattended batches |
| Backoff | exponential: base ~1s, factor 2, cap 30–60s | e.g. 1s → 2s → 4s → 8s |
| Jitter | ±20% (or full jitter) | mandatory when many workers can hit one service |
| Per-attempt timeout | ALWAYS set on network calls | `requests` without `timeout=` hangs forever — that is a finding |
| Overall deadline | context-appropriate | interactive: seconds; batch: minutes — never unbounded |
| `Retry-After` | honored when present | 429/503 responses; cap it at the overall deadline |

**Retry ONLY on:** connection errors/resets, DNS hiccups, timeouts, HTTP 408, 429, 5xx (except 501), explicit rate-limit/throttle signals, SDK-flagged transient errors, stale-auth-token (refresh first, then retry once).
**NEVER retry on:** 400/401/403/404/422 and other 4xx logic errors (except 408/429), schema/validation failures, assertion errors, non-idempotent operations without a guard. A blanket `except Exception:` inside a retry loop retries the unretryable — that is a finding.

## 4. Per-language idioms (preferred, not mandated — any implementation meeting §3 complies)

| Stack | Preferred mechanism |
|---|---|
| **Python + a cloud SDK** | The SDK's built-in retry setting, configured to §3 — e.g. botocore's `Config(retries={"total_max_attempts": 4, "mode": "standard"})` (4 attempts in total; its `max_attempts` key counts retries only). SDK-native retries already know which of the service's errors are transient. |
| **Python + requests** | `urllib3.util.retry.Retry(total=4, backoff_factor=1, status_forcelist=[408, 429, 500, 502, 503, 504], respect_retry_after_header=True)` mounted on a `Session` via `HTTPAdapter`; ALWAYS pass `timeout=` per call (the adapter does not add one). |
| **Python, general** | A small local `retry_transient(fn, ...)` helper or decorator implementing §3 (bounded loop, `time.sleep` backoff + jitter, transient-class filter, final re-raise). `tenacity` is fine where already justified — not a required dependency. |
| **Bash** | A `retry_with_backoff` function: bounded loop, `sleep $((BASE * 2**attempt))` + `$RANDOM` jitter, retry only on retryable exit codes/output patterns, final failure → stderr + non-zero exit. Pair `set -e` fleet loops with an explicit per-item tally so a mid-fleet abort still reports what succeeded. |
| **JS/TS** | Bounded `fetch` retry loop with an `AbortController` timeout per attempt; exponential backoff + jitter; retry only network errors/408/429/5xx. |
| **Browser automation / crawling** | Bounded navigation/element retries with explicit waits (never unbounded polling); per-page/per-item ledger; Scrapy: `RETRY_TIMES` / `RETRY_HTTP_CODES` tuned to §3. |

**Reference pattern — resumable batch (cite in reviews):** bounded per-item fetch retries + a result that carries `(records, failed_ids, earliest_failure_ts)` + a watermark held at the earliest failure, so failed items are re-pulled on the next run until coverage reaches 100%.

## 5. Markers

```
# retry-standard: full|standard|minimal|none    → module tier, declared in the module's CLAUDE.md (`none` carries a one-line justification)
# retry-exempt: <one-line reason>               → call-site waiver comment on/above a deliberately fail-fast external call
```

- `# retry-exempt:` makes deliberate fail-fast VISIBLE and reviewable (e.g. `# retry-exempt: the deploy CLI wraps its own 5-attempt retry`, `# retry-exempt: interactive probe — user retries by re-running`). Reviewers downgrade the missing-retry finding to info when the stated reason holds; it never excuses swallowed failures or silent partial success.
- Language-appropriate comment syntax counts (`# …` py/sh, `// …` js/ts). The literal string `retry-exempt:` is the grep contract.

## 6. Iron rules

1. **Never swallow the final failure.** After retries exhaust, raise / exit non-zero with context. A retry loop ending in `pass`, a bare `continue`, or a masking default return inverts this standard.
2. **Never retry unbounded.** Every retry loop has a max attempt count AND an overall deadline.
3. **Never retry without backoff.** No hot loops; jitter whenever concurrency or shared services are involved.
4. **Never blind-retry non-idempotent operations.** Idempotency key / existence check / dedup guard first — or fail fast with `# retry-exempt:`.
5. **Retry only transient classes.** Auth and 4xx logic errors fail immediately (one token-refresh-then-retry is the sanctioned exception).
6. **Every retry is logged** at WARN with attempt n/N, cause, and operation context; exhaustion at ERROR. Secrets/PII never appear in retry logs (mask first-4 + last-4, per the Code Quality Standard).
7. **Partial batch success is never reported as success.** Per-item ledger + end-of-run reconciliation + non-zero exit (or an explicit partial-success contract) on any item failure.
8. **Fail-fast requires visible justification** — `# retry-exempt: <reason>` at the call site or a design note in the module's CLAUDE.md. Silence is never a justification.

## 7. Boundaries & interplay

- **Third-party / vendored code** is exempt, and a retrofit never touches it. Archived copies (such as files kept in an `archive/` folder) are never touched.
- Conflicts with a module CLAUDE.md declaration → the module declaration wins (record intentional deviations there).
- **Code Quality Standard:** its "fail fast" rule governs *permanent* errors and *post-exhaustion* behavior; this standard governs the *transient window* before that. Retry transient classes per §3, then fail fast loudly — complement, not contradiction. Error-path logging follows `code_quality_standard.md` §2.
- **Testing Standard:** retry behavior is public behavior — new retry logic ships with tier-scaled failure-injection tests (mock/fake transport raising transiently, sleep patched so tests stay fast and offline, exhaustion asserted to raise). See `testing_standard.md` §1 WRITE and iron rule 5 (offline by default).
- **Simplicity:** one policy-compliant wrapper per boundary (KISS) — nested/duplicated retry layers multiply attempts and are a simplification finding.
