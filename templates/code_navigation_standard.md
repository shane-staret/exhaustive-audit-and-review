# Code Navigation Standard (LSP-first)

**Scope:** EVERY turn that navigates code: the main session and every spawned subagent. Declare the standard in the user's global CLAUDE.md, which spawned subagents inherit; code-reading agents cite this file directly. It covers finding where a symbol is defined, who uses or calls it, what a change breaks, and whether code is dead. It applies to Python (`.py`, `.pyi`) and TypeScript/JavaScript (`.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`): the languages served by the official `pyright-lsp` and `typescript-lsp` plugins. Without those plugins enabled, the `LSP` tool has no server and the Grep fallback (§3) applies.

**Why:** Grep matches text. It cannot tell a call from a comment, a local variable from a module function, or `save` in one class from `save` in another. It also misses a symbol imported under an alias. The built-in `LSP` tool asks the language server, which resolves imports, aliases, scopes and types the way the interpreter or compiler does. Answers such as "who calls this?" and "is this unused?" become precise, and far less text needs to be read.

**Enforcement:**
- **WIRING:** the language-server plugins must be enabled, every code-reading agent must list `LSP` in its `tools:` line and cite this file, and text-only agents must not list it (§5). A small wiring test that checks all three is worth keeping.
- **JUDGMENT:** the `code-reviewer` specialists apply this standard while reviewing; it is not a finding category of its own.
- There is deliberately **no hook that forces the tool choice**. Picking the right tool is judgment, not an executable check.

---

## 1. Which tool

| Task (in Python / TS / JS code) | Use | Notes |
|---|---|---|
| Where is `X` defined? (name known, file unknown) | `LSP workspaceSymbol` (query `X`) | Then `goToDefinition` from a use site if several match |
| What is this symbol? Type, signature, docstring | `LSP hover` | Cheaper than reading the whole definition file |
| Jump from a use to its definition, or check an import resolves | `LSP goToDefinition` | No result on an import = broken import (after a move/rename) |
| Every use of a symbol (rename or delete safety, blast radius, dead code) | `LSP findReferences` | Plus the Grep sweep in §3 before a delete or rename |
| Who calls this function? What does it call? | `LSP incomingCalls` / `outgoingCalls` | Run `prepareCallHierarchy` first if the server needs it |
| Implementations of an interface, protocol or abstract method | `LSP goToImplementation` | |
| Outline of a file (functions, classes, constants and their lines) | `LSP documentSymbol` | Good first step before reading a large file |
| Tests that exercise a changed symbol (Testing Standard LOOK duty) | `LSP findReferences` on the symbol, keeping hits under `tests/` | Plus `Glob tests/**` for name-matched test files |

**The position idiom.** Every `LSP` call except `workspaceSymbol` takes a `filePath` plus a 1-based `line` and `character` pointing at the symbol. Get them in one of three ways:
- `workspaceSymbol` or `documentSymbol` gives the line directly;
- one Grep hit (`-n`) gives the line; count the column from the matched text;
- a `Read` of the file gives both.

Grep to locate once, then `LSP` to resolve: this is the standard way the two tools work together.

## 2. What stays Grep

Grep stays the right tool for text. The list below says what stays Grep:

- **Strings and patterns:** secret patterns, magic values, SQL text, log messages, `TODO`s, error strings, `retry-exempt:` markers, regexes a user supplies.
- **Non-code files:** Markdown, shell scripts (no shell language server is installed), YAML/JSON/TOML config, dependency manifests, `.env.example`, CSV.
- **Paths and filenames:** references to a moved file in docs, build configs, `source`/`include` lines, hard-coded paths.
- **History:** `git log --grep`, report IDs, ledger entries.
- **Cross-language references:** a Python name that appears in a shell script, a TS route string used by the backend, an API field named in SQL.
- **Positional or structural text patterns:** `item[N]` indexing, decorator names across a tree, call-shape searches where a regex is the specification.

## 3. Fallback and completeness

- **Grep fallback.** If `LSP` returns an error ("no server", a timeout, a file outside the project), or returns nothing where something plainly exists, fall back to Grep. **Say so** in the output, e.g. "LSP had no server for this file; used Grep". A silent fallback hides a lower-confidence answer.
- **Dynamic references are invisible to LSP.** Language servers cannot see `getattr(obj, name)`, string dispatch tables, `importlib`, framework magic (Flask routes, pytest fixtures by name, React props spread), re-exports built at runtime, or references from shell and other languages. Before deleting or renaming a symbol, pair `findReferences` with one Grep sweep for the bare name across all file types.
- **A server that will not start** is a machine problem, not a reason to drop LSP. The plugins ship no binaries: they launch the global `pyright-langserver` and `typescript-language-server`, installed with npm. `typescript-language-server` needs `typescript/lib/tsserver.js`, which TypeScript 7 (the native port) no longer ships. A global `typescript@7` fails with "Could not find a valid TypeScript installation"; keep the global at `typescript@6`. Report it, use the stated fallback, and fix the install.
- **Worktrees and unopened projects.** A language server indexes from the project root it was started for. In a git worktree, or a folder outside the session's project, results can be partial. The VSCode plugin can also fall back to grep-based search inside worktrees (Claude Code Issue #31391). Treat an empty result there as unknown, not as zero, and use the Grep fallback.

## 4. Iron rules

1. **Never** claim "unused", "no callers" or "safe to rename" from Grep alone while `LSP` is available for that language.
2. **Never** claim it from `LSP` alone when dynamic use is plausible (§3). Both checks, stated.
3. Never run `LSP` on a file type it does not serve (Markdown, shell, config). Use Grep there without comment; that is the rule, not a fallback.
4. An agent that navigates Python/TS code symbols must list `LSP` in its `tools:` line. A subagent with an explicit tool list cannot call a tool it was not granted. Keep the list of granted agents in one place, checked by a test.

## 5. Agents

- **Grant `LSP`** to every agent that reads code symbols: code reviewers, auditors that trace dependencies or call paths, refactoring and fix-applying agents, and agents that move files and must confirm that imports still resolve. `LSP` is read-only, so granting it to a read-only analyst leaves that analyst unable to change anything.
- **Deliberately do not grant it** to agents that:
  - only dispatch other agents;
  - work on reports, manifests, docs or config, never code symbols;
  - are privilege-separated by an exact tool list (a web-only researcher, a reader that judges config text): any added tool weakens that separation.
- To grant or withdraw `LSP` later, change the agent's `tools:` line and the wiring test's list together.
- Agents with no `tools:` line inherit every tool, `LSP` included.

## 6. Markers

None. Unlike the testing, retry and logging standards, this one has no per-module tier: it only chooses a tool, and the fallback rule (§3) already handles modules where no server applies.

## 7. Boundaries & interplay

- **Testing Standard (LOOK):** "discover the tests related to the files being touched" now means `Glob tests/**` for name matches **plus** `LSP findReferences` on the changed public symbols.
- **Code Quality Standard:** "descriptive + searchable names" still matters. LSP resolves symbols, but a Grep sweep (§3) and a human reader both still need names that can be searched.
- **Code smells** (the catalog at https://refactoring.guru/refactoring/smells): Dead Code, Shotgun Surgery, Feature Envy and Middle Man are all "who uses what" questions; answer them with `findReferences` / `incomingCalls` plus the §3 sweep.
- **Moving or renaming files:** moving a Python/Node file updates path strings with Grep (they are text), then confirms each rewritten import resolves with `LSP goToDefinition`.
- **Read-only checkouts:** `LSP` never writes, so the same rules apply unchanged in a checkout that must not be modified.
