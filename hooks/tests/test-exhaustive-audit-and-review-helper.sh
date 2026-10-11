#!/bin/bash
# test-exhaustive-audit-and-review-helper.sh — offline tests for
# skills/exhaustive-audit-and-review/exhaustive_audit_and_review.sh, the deterministic half of the
# /exhaustive-audit-and-review skill.
#
# Verifies: the usage contract (every subcommand, the schema caps in '<field> <= N' form, the enums);
# discover (true size totals, registry order, excludes under two spellings of the root, symlinks never
# followed, the root as the only module, iCloud placeholders, tiers); capabilities (agents, companions,
# depth and concurrency limits, a bounded claude --version); config-facts (names, never values; masked
# secrets; bounded CHECK commands; CONFIG_TEST labels); plan (scope selection, chunking, sampling, waves
# within the concurrency cap, estimates); the run lifecycle (init-run, next-wave retry once then failed,
# save-result and its AUDIT-RUN guard, DISPATCH FAILED, prose before the JSON, validate against the
# finding schema, one case per rule); research (agenda, the fail-closed scrub-check, attach-research on
# file:// fixtures and its whole-reply checks, the fetch policy against a stand-in curl); finalize (stable
# fingerprints, reused IDs and module numbers, numeric report numbering, COMPLETE vs PARTIAL, no absolute
# path in a rendered report); diff buckets; lookup; status; demo-fixture and score-demo.
#
# Everything runs in a throwaway sandbox with a fake HOME and a stub `claude` that only answers
# --version: no network is touched and no real config is read. Secret-shaped values and home folders
# are assembled at run time, so this file holds none. bash-3.2-safe.
# EXHAUSTIVE_AUDIT_HELPER=<path> runs the suite against another copy of the helper (mutation runs).

set -u
# A missing tool fails once, by name, before anything runs (hundreds of empty answers would hide the cause).
for tool in python3 git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: this suite needs $tool on PATH"; exit 1; }
done
SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
ROOT="${EXHAUSTIVE_AUDIT_PACKAGE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
HELPER="${EXHAUSTIVE_AUDIT_HELPER:-$ROOT/skills/exhaustive-audit-and-review/exhaustive_audit_and_review.sh}"
SUITE_BASH="${BASH:-/bin/bash}"
sandbox_ok() {
    # sandbox_ok <path> -> true only for a path the EXIT trap may delete: absolute, more than slashes, and not
    # HOME. An empty path is the dangerous one: bash's `cd ""` stays where it is, so a suite whose sandbox
    # came back empty would work in, then delete, the folder it was started from.
    local home="${HOME:-}"
    case "$1" in /*[!/]*) ;; *) return 1 ;; esac
    [ "${1%/}" != "${home%/}" ]
}
remove_sandbox() { sandbox_ok "$SB_RAW" && { chmod -R u+rwx "$SB_RAW" 2>/dev/null; rm -rf "$SB_RAW"; }; }
SB_RAW="$(mktemp -d "${TMPDIR:-/tmp}/exhaustive-audit-helper-test.XXXXXX")" || { echo "FAIL: cannot create a sandbox"; exit 1; }
# On macOS TMPDIR is a symlink: every path the helper prints is built from the resolved spelling.
[ -d "$SB_RAW" ] && sandbox_ok "$SB_RAW" && SB="$(CDPATH= cd -- "$SB_RAW" && pwd -P)" && sandbox_ok "$SB" \
    || { echo "FAIL: cannot use the sandbox [$SB_RAW]: not a folder this suite may delete"; exit 1; }
trap remove_sandbox EXIT
CFG="$SB/config"
DATA="$CFG/exhaustive-audit-and-review"
FAKE_HOME="$SB/home"
WS="$SB/ws"
mkdir -p "$FAKE_HOME" "$SB/bin" "$CFG" "$DATA"

PASS=0
FAIL=0

check() {
    # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); echo "PASS: $1"
    else
        FAIL=$((FAIL+1)); echo "FAIL: $1 (expected [$2], got [$3])"
    fi
}

check_contains() {
    # check_contains <name> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS+1)); echo "PASS: $1" ;;
        *) FAIL=$((FAIL+1)); echo "FAIL: $1 (expected to contain [$2], got [$3])" ;;
    esac
}

check_absent() {
    # check_absent <name> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL+1)); echo "FAIL: $1 (expected NOT to contain [$2])" ;;
        *) PASS=$((PASS+1)); echo "PASS: $1" ;;
    esac
}

check_prefix() {
    # check_prefix <name> <prefix> <actual>
    case "$3" in
        "$2"*) PASS=$((PASS+1)); echo "PASS: $1" ;;
        *) FAIL=$((FAIL+1)); echo "FAIL: $1 (expected to start with [$2], got [$3])" ;;
    esac
}

jv() {
    # jv <json-text> <python expression over d> — a string prints bare, anything else as compact
    # key-sorted JSON. When the text is not JSON or the expression fails, stdout stays empty (so the check
    # using it fails) and stderr names the error and the expression, so a check that is itself wrong says so.
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    v = eval(sys.argv[1])
except Exception as problem:
    sys.stderr.write("jv: %s in %s\n" % (type(problem).__name__, sys.argv[1]))
    sys.exit(0)
sys.stdout.write(v if isinstance(v, str) else json.dumps(v, sort_keys=True))
' "$2"
}

jfile() {
    # jfile <json-file> <python expression over d>
    if [ -f "$1" ]; then jv "$(cat "$1")" "$2"; fi
}

file_mode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1" 2>/dev/null; }

# Variables that could point the helper at a real config, a real denylist, a real ledger or a
# real clock. ea unsets all of them, then applies the case's own VAR=value words.
LEAKY_VARS="CLAUDE_CONFIG_DIR EXHAUSTIVE_AUDIT_DIR EXHAUSTIVE_AUDIT_DENYLIST EXHAUSTIVE_AUDIT_NOW EXHAUSTIVE_AUDIT_RUNTIME_CONFIG
EXHAUSTIVE_AUDIT_PYTHON EXHAUSTIVE_AUDIT_RETRY_ATTEMPTS EXHAUSTIVE_AUDIT_CONNECT_TIMEOUT EXHAUSTIVE_AUDIT_MAX_TIME
EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS EXHAUSTIVE_AUDIT_CHECK_TIMEOUT_SECS EXHAUSTIVE_AUDIT_CLI_TIMEOUT_SECS
EXHAUSTIVE_AUDIT_TIMEOUT_TOOL EXHAUSTIVE_AUDIT_DEADLINE_SECS CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH
CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR NEW_FUNCTIONALITY_CHECK_CLAUDE_DIR
NEW_FUNCTIONALITY_CHECK_STATE_FILE NEW_FUNCTIONALITY_CHECK_UPDATE_RESULT_FILE FAKE_CLAUDE_MODE FAKE_CLAUDE_VERSION"

ea() {
    # ea [VAR=value ...] <subcommand> [args...] — the helper inside the sandbox: a throwaway HOME,
    # the sandbox config dir, and a stub `claude` first on PATH.
    local -a vars unset_args
    local name
    vars=()
    unset_args=()
    for name in $LEAKY_VARS; do
        unset_args[${#unset_args[@]}]="-u"
        unset_args[${#unset_args[@]}]="$name"
    done
    while [ $# -gt 0 ]; do
        case "$1" in
            [A-Z_]*=*) vars[${#vars[@]}]="$1"; shift ;;
            *) break ;;
        esac
    done
    env "${unset_args[@]}" "HOME=$FAKE_HOME" "PATH=$SB/bin:$PATH" "CLAUDE_CONFIG_DIR=$CFG" \
        "EXHAUSTIVE_AUDIT_RETRY_BASE_SECS=0" "FAKE_CLAUDE_LOG=$SB/claude-calls.log" \
        ${vars[@]+"${vars[@]}"} "$SUITE_BASH" "$HELPER" "$@"
}

run() {
    # run [VAR=value ...] <subcommand> [args...] — sets OUT (stdout), ERR (stderr) and RC.
    ea "$@" > "$SB/.out" 2> "$SB/.err"
    RC=$?
    OUT="$(cat "$SB/.out")"
    ERR="$(cat "$SB/.err")"
}

lines() {
    # lines <file> <n> — writes exactly n numbered lines
    mkdir -p "$(dirname "$1")"
    awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' > "$1"
}

first_line() { printf '%s\n' "$1" | head -1; }

# Git runs isolated from any global or system config, with a fixed identity.
: > "$SB/gitconfig"
export GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="fixture" GIT_COMMITTER_NAME="fixture"
export GIT_AUTHOR_EMAIL="fixture@""example.invalid" GIT_COMMITTER_EMAIL="fixture@""example.invalid"
git_init() { git -c init.defaultBranch=main init -q "$1"; }
git_commit_all() {
    # git_commit_all <repo> <message> [<epoch>]
    git -C "$1" add -A
    if [ -n "${3:-}" ]; then
        GIT_AUTHOR_DATE="$3 +0000" GIT_COMMITTER_DATE="$3 +0000" git -C "$1" commit -q -m "$2"
    else
        git -C "$1" commit -q -m "$2"
    fi
}
NOW_EPOCH="$(date +%s)"
T1=$((NOW_EPOCH - 40 * 86400))
T2=$((NOW_EPOCH - 20 * 86400))

# A secret-shaped value, assembled at run time so this file never holds one.
SECRET="AK""IA""QWERTYUIOPASDFGH"
MASKED_SECRET="AKIA****DFGH"
SETTING_VALUE="value-that-must-never-be-printed"
# Home folders are assembled too: the package suite rejects any shipped file that spells one out.
USERS_DIR="/Use""rs/"
LINUX_HOME_DIR="/ho""me/"

# ---------------------------------------------------------------------------
# Fixtures: a stub claude, a workspace, a config dir, and a few odd roots
# ---------------------------------------------------------------------------
cat > "$SB/bin/claude" <<'STUB'
#!/bin/bash
# A stand-in for the claude CLI: the helper may only ever ask it for its version.
printf '%s\n' "$*" >> "${FAKE_CLAUDE_LOG:-/dev/null}"
case "${FAKE_CLAUDE_MODE:-ok}" in
    ok)   printf '%s (Claude Code)\n' "${FAKE_CLAUDE_VERSION:-2.1.300}" ;;
    fail) exit 1 ;;
    slow) sleep 5 ;;
esac
STUB
chmod +x "$SB/bin/claude"

# Outside the root: a symlink may point here, and nothing here may ever be counted.
mkdir -p "$SB/outside"
printf '# outside\n' > "$SB/outside/CLAUDE.md"
lines "$SB/outside/big.py" 500
lines "$SB/outside/big.js" 500

mkdir -p "$WS"
cat > "$WS/MODULES.md" <<'EOF'
# Modules

| Module | Purpose |
|---|---|
| `web/` | front end |
| [api](api/) | back end |
| ghost | listed, but there is no folder |
EOF
printf 'notes\n' > "$WS/notes.txt"

# api: a git module with 13 tracked text files and 52 lines; the last file git lists has 4.
A="$WS/api"
mkdir -p "$A/src" "$A/tests" "$A/certs" "$A/.github/workflows"
printf '# api\n# testing-standard: standard\n# test-command: pytest -q\n# retry-standard: full\n# project-organization: verify make check\n# project-organization: keep notes.txt\n' > "$A/CLAUDE.md"
printf 'requests==2.31.0\nflask>=2.0  # web framework\n-r dev.txt\n# a comment\n' > "$A/requirements.txt"
cat > "$A/pyproject.toml" <<'EOF'
[project]
name = "api"
dependencies = [
  "httpx>=0.27",
  "pydantic==2.8.2",
]

[tool.poetry.dependencies]
python = "^3.9"
sqlalchemy = { version = "2.0.30", optional = true }
EOF
lines "$A/src/handlers.py" 3
lines "$A/src/sql_query.py" 7
lines "$A/src/util.py" 5
lines "$A/src/zz_secret_store.py" 4
lines "$A/tests/test_util.py" 4
printf 'API_URL=http://localhost:8080\n' > "$A/.env"
printf 'API_URL=\n' > "$A/.env.example"
printf -- '-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n' > "$A/certs/server.pem"
printf 'on: push\njobs:\n  test: {}\n' > "$A/.github/workflows/ci.yml"
printf '# lock\npackage = []\n' > "$A/poetry.lock"
printf '\211PNG\r\n\032\n\000\000\000\015IHDR' > "$A/logo.png"
ln -s "$SB/outside/big.py" "$A/src/ext.py"
git_init "$A"
git_commit_all "$A" "initial" "$T1"
awk '{ print "changed " NR }' "$A/src/util.py" > "$A/src/util.py.new" && mv "$A/src/util.py.new" "$A/src/util.py"
git_commit_all "$A" "touch util" "$T2"

# web: a non-git module (package.json) with 4 text files and 15 lines.
mkdir -p "$WS/web/src"
printf '{"name": "web", "dependencies": {"react": "^18.2.0"}, "devDependencies": {"jest": "29.7.0"}}\n' > "$WS/web/package.json"
printf '{}\n' > "$WS/web/package-lock.json"
lines "$WS/web/src/app.js" 11
lines "$WS/web/README.md" 2
printf 'bplist00' > "$WS/web/src/.lazy.js.icloud"
lines "$WS/web/node_modules/dep/index.js" 100
lines "$WS/web/dist/bundle.js" 50
ln -s "$SB/outside/big.js" "$WS/web/src/ext.js"

# beta (AGENTS.md only), gamma (a .csproj), zeta (go.mod + Makefile + code).
mkdir -p "$WS/beta" "$WS/gamma" "$WS/zeta"
printf '# beta\n' > "$WS/beta/AGENTS.md"
printf '<Project>\n</Project>\n' > "$WS/gamma/App.csproj"
printf 'module zeta\n' > "$WS/zeta/go.mod"
printf 'all:\n' > "$WS/zeta/Makefile"
lines "$WS/zeta/main.go" 6

# Not modules: an excluded folder, skip markers, a plain folder, a symlink out, a hidden folder.
mkdir -p "$WS/Globex/src" "$WS/skipme" "$WS/legacy" "$WS/docs" "$WS/.hidden"
printf '{"name": "globex"}\n' > "$WS/Globex/package.json"
lines "$WS/Globex/src/big.js" 900
printf '# skipme\n# exhaustive-audit: skip\n' > "$WS/skipme/CLAUDE.md"
printf '{"name": "skipme"}\n' > "$WS/skipme/package.json"
printf '# legacy\n# project-organization: skip\n' > "$WS/legacy/CLAUDE.md"
printf '# Guide\n' > "$WS/docs/guide.md"
printf '| Name |\n|---|\n| zeta |\n| beta |\n' > "$WS/docs/modules.md"
printf '# hidden\n' > "$WS/.hidden/CLAUDE.md"
ln -s "$SB/outside" "$WS/link-out"
ln -s "$WS" "$SB/ws-link"

# The config dir.
cat > "$CFG/settings.json" <<EOF
{
  "model": "sonnet",
  "env": {"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "3", "SAMPLE_SETTING": "$SETTING_VALUE"},
  "enabledPlugins": {"superpowers@market": true, "autoharness@local": false, "typescript-lsp@market": true},
  "permissions": {"allow": ["Read", "Bash(ls:*)"], "deny": ["Read(**/.env)"], "defaultMode": "auto"},
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/on-stop.sh"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash", "args": ["~/.claude/hooks/guard.sh"]}]}]
  }
}
EOF
mkdir -p "$CFG/agents" "$CFG/skills/alpha/resources" "$CFG/skills/beta" "$CFG/skills/gamma" "$CFG/hooks"
printf -- '---\nname: code-reviewer\ndescription: "Reviews code."\ntools: Read, Grep, Glob, Bash, Agent\nmodel: sonnet\n---\n\nBody.\n' > "$CFG/agents/code-reviewer.md"
printf -- '---\nname: code-reviewer-security\ndescription: "Security."\ntools: Read, Grep\nmodel: sonnet\n---\n' > "$CFG/agents/code-reviewer-security.md"
printf -- '---\nname: project-health\ndescription: "Hygiene."\ntools: Read, Write\n---\n' > "$CFG/agents/project-health.md"
printf -- '---\nname: exhaustive-audit-and-review-claude-system\ndescription: "Config audit."\ntools: Read, Grep, Glob\nmodel: sonnet\nomitClaudeMd: true\n---\n' > "$CFG/agents/exhaustive-audit-and-review-claude-system.md"
printf -- '---\nname: alpha\ndescription: Use when testing.\n---\n\n# Alpha\n' > "$CFG/skills/alpha/SKILL.md"
printf '# Beta\n\nNo frontmatter here.\n' > "$CFG/skills/beta/SKILL.md"
printf -- '---\nname: gamma\ndescription: "Typed by the user only."\ndisable-model-invocation: true\n---\n' > "$CFG/skills/gamma/SKILL.md"
printf '#!/bin/bash\necho stop\n' > "$CFG/hooks/on-stop.sh"
chmod +x "$CFG/hooks/on-stop.sh"
printf '#!/bin/bash\nif then fi (\n' > "$CFG/hooks/broken.sh"
printf '# Global\n\n## One\n\ntext\n\n```\n## Not a heading\n```\n\n## Two\n' > "$CFG/CLAUDE.md"
CLAUDE_MD_BYTES="$(wc -c < "$CFG/CLAUDE.md" | tr -d ' ')"

# The new-functionality check, as stubs (a real copy is an optional companion of this package).
NFC_SKILL="$CFG/skills/claude-code-new-functionality-check"
mkdir -p "$NFC_SKILL" "$CFG/claude-code-new-functionality-check"
cat > "$NFC_SKILL/claude_code_new_functionality_check.sh" <<'STUB'
#!/bin/bash
case "${1:-}" in
    inventory) printf '# Config inventory (stub)\n### MCP servers (name | scope | type)\nexample | user | stdio\n' ;;
    *) echo "stub: unsupported ${1:-}" >&2; exit 1 ;;
esac
STUB
cat > "$CFG/hooks/claude-code-new-functionality-check-reminder.sh" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--status" ] || exit 1
echo "DUE: last sweep 9 days ago; ledger at ${CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR:-unset}"
echo "installed CLI: 2.1.300 · state: ${NEW_FUNCTIONALITY_CHECK_STATE_FILE:-unset}"
STUB
chmod +x "$NFC_SKILL/claude_code_new_functionality_check.sh" "$CFG/hooks/claude-code-new-functionality-check-reminder.sh"
{
    printf '# Ledger\n\n## Proposal index\n\n'
    printf '| ID | status | target | feature_key | title | upstream | logged | decided |\n|---|---|---|---|---|---|---|---|\n'
    printf '| %s-%04d | proposed | hook | k1 | One | 2.1.1 | 2026-01-01 | |\n' NF 1
    printf '| %s-%04d | applied — done | hook | k2 | Two | 2.1.1 | 2026-01-01 | 2026-01-02 |\n' NF 2
    printf '| %s-%04d | accepted | skill | k3 | Three | 2.1.1 | 2026-01-01 | 2026-01-02 |\n' NF 3
    printf '| %s-%04d | declined — no | skill | k4 | Four | 2.1.1 | 2026-01-01 | 2026-01-02 |\n' NF 4
} > "$CFG/claude-code-new-functionality-check/ledger.md"
printf 'Initech\n' > "$CFG/claude-code-new-functionality-check/denylist.txt"
printf '# private terms, one per line\nGlobex\nabc\n' > "$DATA/denylist.txt"
{
    printf '# house settings for the sandbox\n'
    printf 'EXCLUDE=Globex\n'
    printf 'MAX_LOC_PER_REVIEW=10\n'
    printf 'RESEARCH_BUDGET=2\n'
    printf 'CHECK=echo check-ok\n'
    printf 'CHECK=echo "$PWD"; exit 3\n'
    printf 'CHECK=sleep 5\n'
    printf 'CHECK=echo token=%s\n' "$SECRET"
    printf 'CONFIG_TEST=bash tests/config-suite.sh --token %s\n' "$SECRET"
    printf 'BOGUS=1\n'
} > "$DATA/house.conf"

# A second config: an absolute EXCLUDE written in the symlinked spelling, and another registry.
mkdir -p "$SB/cfg2/exhaustive-audit-and-review"
printf 'EXCLUDE=%s\nMODULE_REGISTRY=docs/modules.md\n' "$SB/ws-link/Globex" > "$SB/cfg2/exhaustive-audit-and-review/house.conf"
# A third config: nothing at all (every default applies).
mkdir -p "$SB/cfg3"
# A fourth: CONFIG_TEST lines only (a known key: no warning).
mkdir -p "$SB/cfg4/exhaustive-audit-and-review"
printf 'CONFIG_TEST=bash hooks/tests/run-all-tests.sh\nCONFIG_TEST=bash hooks/tests/test-one.sh\n' > "$SB/cfg4/exhaustive-audit-and-review/house.conf"

# Odd roots: a single git repo, a manifest-only folder, an empty folder, an evicted file, tiers.
mkdir -p "$SB/single/pkg"
lines "$SB/single/main.py" 3
lines "$SB/single/pkg/mod.py" 2
git_init "$SB/single"
git_commit_all "$SB/single" "initial"
mkdir -p "$SB/plain/src"
printf 'all:\n' > "$SB/plain/Makefile"
lines "$SB/plain/src/x.c" 4
mkdir -p "$SB/empty/notes"
printf '# notes\n' > "$SB/empty/notes/readme.md"
mkdir -p "$SB/evicted"
lines "$SB/evicted/a.py" 3
lines "$SB/evicted/b.py" 2
git_init "$SB/evicted"
git_commit_all "$SB/evicted" "initial"
mv "$SB/evicted/b.py" "$SB/evicted/.b.py.icloud"
for spec in t1:4999 t2:5000 t3:30000 t4:100000; do
    name="${spec%%:*}"; total="${spec#*:}"
    mkdir -p "$SB/tiers/$name"
    printf '# %s\n' "$name" > "$SB/tiers/$name/CLAUDE.md"
    lines "$SB/tiers/$name/data.txt" $((total - 1))
done

# ---------------------------------------------------------------------------
# 0. The helper parses, and the usage contract
# ---------------------------------------------------------------------------
if bash -n "$HELPER" 2>/dev/null; then check "helper is syntax-clean" "ok" "ok"; else check "helper is syntax-clean" "ok" "syntax error"; fi
if [ -x "$HELPER" ]; then check "helper is executable" "yes" "yes"; else check "helper is executable" "yes" "no"; fi

run --help
check "--help exits 0" "0" "$RC"
for sub in discover capabilities config-facts plan init-run next-wave save-result validate agenda scrub-check \
           attach-research finalize status runs diff lookup demo-fixture score-demo; do
    check_contains "--help lists the $sub subcommand" "$sub" "$OUT"
done
# The caps use the '<field> <= N' form, which the package suite reads out of this text and then looks
# for in every agent that writes findings.
for cap in "check <= 40" "subject <= 120" "category <= 40" "finding <= 200" "rationale <= 400" \
           "recommendation <= 400" "notes <= 600" "severity critical|high|medium|low|info" \
           "effort trivial|S|M|L|XL" "risk low|med|high" "dim int 1-5" "evidence 1-5 items" "research_questions <= 3 items, each <= 200" \
           "<=60 findings per code scope" "<=40 per other scope" "quote <= 300" "AUDIT-RUN: <run> <scope>" "AUDIT-RUN: <run> research" \
           "tier official|vendor|community"; do
    check_contains "--help states [$cap]" "$cap" "$OUT"
done
check "--help states each field cap once, so the agents have exactly one number to quote" \
      "category 40|check 40|finding 200|notes 600|rationale 400|recommendation 400|subject 120" \
      "$(printf '%s\n' "$OUT" | grep -oE '(finding|rationale|recommendation|subject|check|category|notes)[[:space:]]*<=[[:space:]]*[0-9]+' | sed -E 's/[[:space:]]*<=[[:space:]]*/ /' | sort -u | paste -sd '|' -)"
for est in "processed tokens (cache reads included)" "code-reviewer 4.4M" "code specialist 2.2M" "dimension agent 3.5M" \
           "project-health 3.6M" "researcher 1.2M" "flat per scope, never scaled by lines" "18 per wave with a code scope" \
           "12 per wave without" "13 for research" "measured on the bundled demo (2 small modules); larger scopes cost more"; do
    check_contains "--help documents the estimate: $est" "$est" "$OUT"
done
run -h
check "-h exits 0" "0" "$RC"
run help
check "help exits 0" "0" "$RC"
check_contains "help prints the same usage" "attach-research" "$OUT"
run
check "no subcommand is a usage error" "1" "$RC"
run frobnicate
check "an unknown subcommand is a usage error" "1" "$RC"
run discover --root "$WS" --bogus
check "an unknown flag is a usage error" "1" "$RC"
run discover --root
check "a flag without its value is a usage error" "1" "$RC"

# ---------------------------------------------------------------------------
# 0b. The python half runs isolated, with the interpreter the user names
# ---------------------------------------------------------------------------
# An audited repo is the natural folder to start the helper from, so a stdlib-named file there must never
# be imported: it would run that repo's code with the user's rights.
PLANT="$SB/planted"
mkdir -p "$PLANT/mod"
printf '# planted\n' > "$PLANT/mod/CLAUDE.md"
for module in json calendar; do
    printf 'open("%s", "a").write("%s imported\\n")\n' "$SB/planted-marker" "$module" > "$PLANT/$module.py"
done
OUT="$(cd "$PLANT" && ea discover --root . 2>"$SB/.err")"
RC=$?
check "a stdlib-named file in the working folder is never imported" "absent" "$( [ -e "$SB/planted-marker" ] && echo present || echo absent )"
check "... and discover still works from that folder" "0/planted/1" "$RC/$(jv "$OUT" 'd["root_name"]')/$(jv "$OUT" 'len(d["modules"])')"
mkdir -p "$SB/py dir"
cat > "$SB/py dir/python-wrapper" <<'STUB'
#!/bin/bash
echo used >> "${FAKE_PYTHON_LOG:-/dev/null}"
exec python3 "$@"
STUB
chmod +x "$SB/py dir/python-wrapper"
run "EXHAUSTIVE_AUDIT_PYTHON=$SB/py dir/python-wrapper" "FAKE_PYTHON_LOG=$SB/python-wrapper.log" discover --root "$SB/single"
check "EXHAUSTIVE_AUDIT_PYTHON (a path with a space) is the python that runs" "0/used" "$RC/$(head -1 "$SB/python-wrapper.log" 2>/dev/null)"
run "EXHAUSTIVE_AUDIT_PYTHON=$SB/no-such-python" discover --root "$SB/single"
check "an EXHAUSTIVE_AUDIT_PYTHON that is not an executable stops the helper (exit 1)" "1" "$RC"
check_contains "... with an ERROR that names the variable" "ERROR EXHAUSTIVE_AUDIT_PYTHON" "$ERR"
check "... and nothing on stdout (no other python was used)" "" "$OUT"
run "EXHAUSTIVE_AUDIT_PYTHON=no-such-python-anywhere" discover --root "$SB/single"
check "... the same for a bare name that is not on PATH" "1" "$RC"
run "EXHAUSTIVE_AUDIT_PYTHON=$SB/no-such-python" --help
check "--help with a broken EXHAUSTIVE_AUDIT_PYTHON exits 1" "1" "$RC"
check_contains "... after printing the usage text" "attach-research" "$OUT"

# ---------------------------------------------------------------------------
# 1. discover
# ---------------------------------------------------------------------------
modf() { jv "$OUT" "[m for m in d['modules'] if m['name'] == '$1'][0]['$2']"; }

run discover --root "$WS"
check "discover exits 0" "0" "$RC"
check "discover: modules in registry order, then by name" '["web", "api", "beta", "gamma", "zeta"]' "$(jv "$OUT" '[m["name"] for m in d["modules"]]')"
check "discover: idx follows that order" '[1, 2, 3, 4, 5]' "$(jv "$OUT" '[m["idx"] for m in d["modules"]]')"
check "discover: the registry is named root-relative" "MODULES.md" "$(jv "$OUT" 'd["registry"]')"
check "discover: root_name is the folder name" "ws" "$(jv "$OUT" 'd["root_name"]')"
check "discover: config_dir is the <config> placeholder" "<config>" "$(jv "$OUT" 'd["config_dir"]')"
check "regression: a module's size is the SUM over every text file, not the last file's count" "52" "$(modf api lines)"
check "discover: api counts its 13 tracked text files (binary and symlink left out)" "13" "$(modf api files)"
check "discover: api is a git module" "true" "$(modf api git)"
check "discover: web counts 4 files and 15 lines (node_modules, dist, placeholder, symlink left out)" "4/15" "$(modf web files)/$(modf web lines)"
check "discover: web is not a git module" "false" "$(modf web git)"
check "discover: a module's path is root-relative" "api" "$(modf api path)"
check "discover: a child module is not the root" "false" "$(modf api is_root)"
check "discover: tier small" "small" "$(modf api tier)"
check "discover: skip_marker is false on a module" "false" "$(modf api skip_marker)"
check "discover: api manifests" '["pyproject.toml", "requirements.txt"]' "$(modf api manifests)"
check "discover: api instructions" '["CLAUDE.md"]' "$(modf api instructions)"
check "discover: an AGENTS.md alone makes a module" '["AGENTS.md"]' "$(modf beta instructions)"
check "discover: a .csproj is a manifest" '["App.csproj"]' "$(modf gamma manifests)"
check "discover: Globex is excluded by house.conf before anything is read" '[{"path": "Globex", "reason": "house.conf"}]' "$(jv "$OUT" 'd["excluded"]')"
check "discover: skipped folders and why" '[{"path": "docs", "reason": "not-a-module"}, {"path": "legacy", "reason": "skip-marker"}, {"path": "link-out", "reason": "symlink"}, {"path": "skipme", "reason": "skip-marker"}]' "$(jv "$OUT" 'd["skipped"]')"
check "discover: iCloud placeholders are listed, not counted" '["web/src/.lazy.js.icloud"]' "$(jv "$OUT" 'd["placeholders"]')"
check "discover: totals are true sums" '{"files": 22, "lines": 78, "modules": 5}' "$(jv "$OUT" 'd["totals"]')"
check_absent "discover: a hidden folder is never a module" ".hidden" "$OUT"
check_absent "discover: nothing outside the root is ever named" "big.py" "$OUT"
check_absent "discover: no absolute path in the output" "$SB" "$OUT"
check_contains "discover: an unknown house.conf key is a warning" "unknown key BOGUS" "$ERR"
check_absent "discover: CONFIG_TEST is a known house.conf key" "CONFIG_TEST" "$ERR"

run discover --root "$SB/ws-link"
check "discover via a symlinked spelling: the same root" "ws" "$(jv "$OUT" 'd["root_name"]')"
check "discover via a symlinked spelling: the same modules" '["web", "api", "beta", "gamma", "zeta"]' "$(jv "$OUT" '[m["name"] for m in d["modules"]]')"
check "discover via a symlinked spelling: EXCLUDE still holds" '[{"path": "Globex", "reason": "house.conf"}]' "$(jv "$OUT" 'd["excluded"]')"
check "discover via a symlinked spelling: the same totals" '{"files": 22, "lines": 78, "modules": 5}' "$(jv "$OUT" 'd["totals"]')"
run discover --root "$SB_RAW/ws"
check "discover via the unresolved temp spelling: the same modules" '["web", "api", "beta", "gamma", "zeta"]' "$(jv "$OUT" '[m["name"] for m in d["modules"]]')"
run discover --root "$WS" --config-dir "$SB/cfg2"
check "an absolute EXCLUDE in the symlinked spelling still excludes" '[{"path": "Globex", "reason": "house.conf"}]' "$(jv "$OUT" 'd["excluded"]')"
check "MODULE_REGISTRY sets the order, the rest follow by name" '["zeta", "beta", "api", "gamma", "web"]' "$(jv "$OUT" '[m["name"] for m in d["modules"]]')"
check "MODULE_REGISTRY is named in the output" "docs/modules.md" "$(jv "$OUT" 'd["registry"]')"
run discover --root "$WS" --exclude zeta
check "--exclude drops a module" '["web", "api", "beta", "gamma"]' "$(jv "$OUT" '[m["name"] for m in d["modules"]]')"
check_contains "--exclude is recorded with its reason" '{"path": "zeta", "reason": "--exclude"}' "$(jv "$OUT" 'd["excluded"]')"
OUT="$(cd "$SB/ws-link" && ea discover 2>/dev/null)"
check "discover without --root: the current folder, resolved (here through a symlink)" "ws/5" "$(jv "$OUT" 'd["root_name"]')/$(jv "$OUT" 'len(d["modules"])')"
run discover --root "$SB/no-such-root"
check "discover: a missing root is a precondition error" "1" "$RC"

run discover --root "$SB/single"
check "root-as-module: a single git repo is the only module" '[{"git": true, "is_root": true, "lines": 5, "name": "single", "path": "."}]' "$(jv "$OUT" '[{k: m[k] for k in ("name", "path", "is_root", "git", "lines")} for m in d["modules"]]')"
check "root-as-module: the registry is absent and not needed" "null" "$(jv "$OUT" 'd["registry"]')"
run discover --root "$SB/plain"
check "root-as-module: a manifest-only root (not git) is the module" '[{"files": 2, "git": false, "lines": 5, "path": "."}]' "$(jv "$OUT" '[{k: m[k] for k in ("path", "git", "files", "lines")} for m in d["modules"]]')"
run discover --root "$SB/empty"
check "an empty root has no module" "[]" "$(jv "$OUT" 'd["modules"]')"
check "an empty root lists its plain folders as not-a-module" '[{"path": "notes", "reason": "not-a-module"}]' "$(jv "$OUT" 'd["skipped"]')"
run discover --root "$SB/evicted"
check "an evicted tracked file is a placeholder, not a count" '[".b.py.icloud"]/1/3' "$(jv "$OUT" 'd["placeholders"]')/$(jv "$OUT" 'd["modules"][0]["files"]')/$(jv "$OUT" 'd["modules"][0]["lines"]')"
run discover --root "$SB/tiers"
check "tiers by lines: 4999 small, 5000 medium, 30000 large, 100000 xlarge" '[["t1", 4999, "small"], ["t2", 5000, "medium"], ["t3", 30000, "large"], ["t4", 100000, "xlarge"]]' "$(jv "$OUT" '[[m["name"], m["lines"], m["tier"]] for m in d["modules"]]')"
run plan --root "$WS" --scope all
check "plan carries discovery's iCloud placeholders" '["web/src/.lazy.js.icloud"]' "$(jv "$OUT" 'd["placeholders"]')"
check "... and its unreadable paths (none in this workspace)" "[]" "$(jv "$OUT" 'd["unreadable"]')"
run plan --root "$WS" --scope module api
check "a module plan carries only that module's placeholders" "[]" "$(jv "$OUT" 'd["placeholders"]')"

# Discovery never loses what it cannot read: an unreadable folder or file is listed with why, warned about
# by its root-relative name, carried into the plan, and makes the finished run PARTIAL.
LOCKED="$SB/locked"
if [ "$(id -u)" = "0" ]; then
    echo "SKIP-LOUD: running as root, which can read a chmod 000 path, so the unreadable-path cases cannot run"
else
    mkdir -p "$LOCKED/lk/private" "$LOCKED/lk/src" "$LOCKED/gl/private" "$LOCKED/zz"
    printf '{"name": "lk"}\n' > "$LOCKED/lk/package.json"
    lines "$LOCKED/lk/src/app.py" 3
    lines "$LOCKED/lk/private/hidden.py" 4
    lines "$LOCKED/lk/locked.py" 5
    printf 'bplist00' > "$LOCKED/lk/.notes.md.icloud"
    printf '# gl\n' > "$LOCKED/gl/CLAUDE.md"
    lines "$LOCKED/gl/main.py" 2
    lines "$LOCKED/gl/private/inner.py" 6
    lines "$LOCKED/gl/private/sub/deep.py" 2
    git_init "$LOCKED/gl"
    git_commit_all "$LOCKED/gl" "initial"
    printf '{"name": "zz"}\n' > "$LOCKED/zz/package.json"
    chmod 000 "$LOCKED/lk/private" "$LOCKED/lk/locked.py" "$LOCKED/gl/private" "$LOCKED/zz"
    run discover --root "$LOCKED"
    check "discover with unreadable paths still exits 0" "0" "$RC"
    check "discover lists every unreadable path, root-relative, with why" '[["gl/private", "Permission denied"], ["lk/locked.py", "Permission denied"], ["lk/private", "Permission denied"], ["zz", "Permission denied"]]' "$(jv "$OUT" '[[u["path"], u["reason"]] for u in d["unreadable"]]')"
    check "... an unreadable top-level folder is not passed off as not-a-module" "[]" "$(jv "$OUT" '[s for s in d["skipped"] if s["path"] == "zz"]')"
    check "... the readable files still count (lk: package.json, app.py; gl: CLAUDE.md, main.py)" "lk 2/4 gl 2/3" "lk $(modf lk files)/$(modf lk lines) gl $(modf gl files)/$(modf gl lines)"
    check "... the placeholder is listed beside them" '["lk/.notes.md.icloud"]' "$(jv "$OUT" 'd["placeholders"]')"
    for path in gl/private lk/locked.py lk/private zz; do
        check_contains "... and warns about $path by its root-relative name" "$path could not be read" "$ERR"
    done
    check_absent "... never by an absolute path" "$SB" "$ERR"
    run plan --root "$LOCKED" --scope workspace
    check "plan carries the unreadable paths" '["gl/private", "lk/locked.py", "lk/private", "zz"]' "$(jv "$OUT" '[u["path"] for u in d["unreadable"]]')"
    check "plan carries the placeholders" '["lk/.notes.md.icloud"]' "$(jv "$OUT" 'd["placeholders"]')"
    printf '%s' "$OUT" > "$SB/plan-locked.json"
    run plan --root "$LOCKED" --scope module gl
    check "a module plan carries only its own unreadable paths" '["gl/private"]' "$(jv "$OUT" '[u["path"] for u in d["unreadable"]]')"
    run plan --root "$LOCKED" --scope claude-system
    check "a claude-system plan carries none (it reviews the config, not the tree)" "[]/[]" "$(jv "$OUT" 'd["unreadable"]')/$(jv "$OUT" 'd["placeholders"]')"
    DL="$SB/data-locked"
    mkdir -p "$DL"
    run "EXHAUSTIVE_AUDIT_DIR=$DL" EXHAUSTIVE_AUDIT_NOW=20260501T000000Z init-run --plan "$SB/plan-locked.json" --root "$LOCKED"
    RUN_L="$(first_line "$OUT")"
    python3 - "$DL/runs/$RUN_L/results" "$RUN_L" D2-architecture D3-domain D4-operations PH-1 PH-2 <<'PY'
import json, os, sys
results, run = sys.argv[1:3]
for scope in sys.argv[3:]:
    with open(os.path.join(results, scope + ".json"), "w") as handle:
        json.dump({"header": {"run": run, "scope": scope, "agent": "reviewer", "files_reviewed": 1, "lines_reviewed": 1},
                   "findings": []}, handle)
PY
    for scope in D2-architecture D3-domain D4-operations PH-1 PH-2; do run "EXHAUSTIVE_AUDIT_DIR=$DL" validate "$RUN_L" "$scope"; done
    run "EXHAUSTIVE_AUDIT_DIR=$DL" EXHAUSTIVE_AUDIT_NOW=20260501T000000Z finalize "$RUN_L"
    check "every scope valid, but paths unread: the run is PARTIAL" "EXHAUSTIVE-AUDIT PARTIAL — not reviewed: 4 unreadable path(s), 1 iCloud placeholder(s)" "$(first_line "$OUT")"
    check "... findings.json says PARTIAL" "PARTIAL" "$(jfile "$DL/runs/$RUN_L/findings.json" 'd["banner"]')"
    check "... and lists each unseen path under not reviewed, with why" '["gl/private: unreadable (Permission denied)", "lk/locked.py: unreadable (Permission denied)", "lk/private: unreadable (Permission denied)", "zz: unreadable (Permission denied)", "lk/.notes.md.icloud: an iCloud placeholder (not downloaded)"]' "$(jfile "$DL/runs/$RUN_L/findings.json" 'd["not_reviewed"]')"
    check_contains "... and so does the report's Not reviewed section" "- lk/private: unreadable (Permission denied)" "$(cat "$DL/runs/$RUN_L/exhaustive_audit_v1_20260501T000000Z.md" 2>/dev/null)"
    check_absent "... which never says nothing was missed" "Nothing: every planned scope" "$(cat "$DL/runs/$RUN_L/exhaustive_audit_v1_20260501T000000Z.md" 2>/dev/null)"
    python3 - "$SB/plan-locked.json" "$SB/plan-locked-bad.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["unreadable"] = "lk/private"
json.dump(plan, open(sys.argv[2], "w"))
PY
    run "EXHAUSTIVE_AUDIT_DIR=$DL" init-run --plan "$SB/plan-locked-bad.json" --root "$LOCKED"
    check "init-run refuses a plan whose unreadable list is malformed (exit 1)" "1" "$RC"
    check_contains "... saying so" "its unreadable list is malformed" "$ERR"
    chmod 755 "$LOCKED/lk/private" "$LOCKED/gl/private" "$LOCKED/zz"
    chmod 644 "$LOCKED/lk/locked.py"
    mkdir -p "$SB/locked-root/inner" "$SB/locked-config/agents"
    printf '# inner\n' > "$SB/locked-root/inner/CLAUDE.md"
    chmod 000 "$SB/locked-root" "$SB/locked-config/agents"
    run discover --root "$SB/locked-root"
    check "a root that cannot be listed is recorded as unreadable, not taken for an empty folder" '[[".", "Permission denied"]]' "$(jv "$OUT" '[[u["path"], u["reason"]] for u in d["unreadable"]]')"
    run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$SB/locked-config" config-facts --root "$SB/single" --config-dir "$SB/locked-config"
    check_contains "a config folder that cannot be listed is a warning, never a silent empty list" "a folder could not be listed and counts as empty (Permission denied)" "$ERR"
    chmod 755 "$SB/locked-root" "$SB/locked-config/agents"
fi

# ---------------------------------------------------------------------------
# 2. capabilities
# ---------------------------------------------------------------------------
run capabilities --config-dir "$CFG"
check "capabilities exits 0" "0" "$RC"
check "capabilities: all 17 agents are checked" "17" "$(jv "$OUT" 'len(d["agents"])')"
check "capabilities: a present agent is true" "true" "$(jv "$OUT" 'd["agents"]["code-reviewer"]')"
check "capabilities: a missing agent is false" "false" "$(jv "$OUT" 'd["agents"]["runbook-author"]')"
check "capabilities: the researcher agent is checked" "false" "$(jv "$OUT" 'd["agents"]["exhaustive-audit-and-review-researcher"]')"
check "capabilities: the runtime config is the audited config here" "<config>" "$(jv "$OUT" 'd["runtime_config"]')"
check "capabilities: the audited config's superpowers is enabled" "true" "$(jv "$OUT" 'd["audited_config"]["companions"]["superpowers"]["enabled"]')"
check "capabilities: the audited config's autoharness is disabled (false in enabledPlugins)" "false" "$(jv "$OUT" 'd["audited_config"]["companions"]["autoharness"]["enabled"]')"
check "capabilities: the audited config's LSP plugins" '{"pyright": false, "typescript": true}' "$(jv "$OUT" 'd["audited_config"]["companions"]["lsp"]')"
check "capabilities: the audited config holds the new-functionality data" "true" "$(jv "$OUT" 'd["audited_config"]["companions"]["new_functionality_check_data"]')"
check "capabilities: plugins are no longer reported at the top level" "[\"new_functionality_check\"]" "$(jv "$OUT" 'sorted(d["companions"])')"
check "capabilities: the new-functionality check is present" "true" "$(jv "$OUT" 'd["companions"]["new_functionality_check"]["present"]')"
check "capabilities: its helper, config-relative" "<config>/skills/claude-code-new-functionality-check/claude_code_new_functionality_check.sh" "$(jv "$OUT" 'd["companions"]["new_functionality_check"]["helper"]')"
check "capabilities: its reminder, config-relative" "<config>/hooks/claude-code-new-functionality-check-reminder.sh" "$(jv "$OUT" 'd["companions"]["new_functionality_check"]["reminder"]')"
check "capabilities: depth from settings.json env" '{"concurrent_source": "default", "depth_source": "settings", "max_concurrent": 20, "max_depth": 3}' "$(jv "$OUT" 'd["limits"]')"
check "capabilities: nothing blocked" "[]" "$(jv "$OUT" 'd["blocked"]')"
check "capabilities: the CLI version comes from claude --version" "2.1.300" "$(jv "$OUT" 'd["cli_version"]')"
check_absent "capabilities: a current CLI has no spawn-cap warning" "2.1.224" "$(jv "$OUT" 'd["warnings"]')"
check "capabilities: config_dir placeholder" "<config>" "$(jv "$OUT" 'd["config_dir"]')"
check_absent "capabilities: no absolute path" "$SB" "$OUT"

run CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 capabilities
check "depth 1: still exit 0 without --strict" "0" "$RC"
check "depth 1 comes from the environment" "1/env" "$(jv "$OUT" 'd["limits"]["max_depth"]')/$(jv "$OUT" 'd["limits"]["depth_source"]')"
check_contains "depth below 2 is listed as blocked" "depth" "$(jv "$OUT" 'd["blocked"]')"
run CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 capabilities --strict
check "depth below 2 with --strict exits 3" "3" "$RC"
run CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2 capabilities --strict
check "depth 2 is enough for main session -> code-reviewer -> specialist" "0/[]" "$RC/$(jv "$OUT" 'd["blocked"]')"
run CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=12 capabilities
check "the concurrency cap comes from the environment" "12/env" "$(jv "$OUT" 'd["limits"]["max_concurrent"]')/$(jv "$OUT" 'd["limits"]["concurrent_source"]')"
run CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=abc capabilities
check "a non-numeric depth falls back to settings.json, with a warning" "3/settings" "$(jv "$OUT" 'd["limits"]["max_depth"]')/$(jv "$OUT" 'd["limits"]["depth_source"]')"
check_contains "... and the warning names the variable" "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH" "$(jv "$OUT" 'd["warnings"]')"
run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$SB/cfg3" capabilities --config-dir "$SB/cfg3"
check "an empty config: default limits" '{"concurrent_source": "default", "depth_source": "default", "max_concurrent": 20, "max_depth": 3}' "$(jv "$OUT" 'd["limits"]')"
check "an empty config: no companion" "false/false/false" "$(jv "$OUT" 'd["companions"]["new_functionality_check"]["present"]')/$(jv "$OUT" 'd["audited_config"]["companions"]["superpowers"]["enabled"]')/$(jv "$OUT" 'd["audited_config"]["companions"]["new_functionality_check_data"]')"
mkdir -p "$SB/nfc-relocated"
run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$SB/cfg3" "CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR=$SB/nfc-relocated" capabilities --config-dir "$SB/cfg3"
check "capabilities: the companion's relocated data folder counts for the running session's own config" "true" "$(jv "$OUT" 'd["audited_config"]["companions"]["new_functionality_check_data"]')"
run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$CFG" "CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR=$SB/nfc-relocated" capabilities --config-dir "$SB/cfg3"
check "capabilities: ... never for a config from elsewhere (the override describes this machine)" "false" "$(jv "$OUT" 'd["audited_config"]["companions"]["new_functionality_check_data"]')"

# The agents that get dispatched, the companion skill that gets called and the limits that apply all
# belong to the RUNNING session's config; --config-dir only names the config under audit.
RUNTIME_DIR="$SB/runtime-config"
AUDITED_DIR="$SB/audited-config"
mkdir -p "$RUNTIME_DIR/agents" "$RUNTIME_DIR/hooks" "$RUNTIME_DIR/skills/claude-code-new-functionality-check" \
         "$AUDITED_DIR/claude-code-new-functionality-check"
for agent in exhaustive-audit-and-review-architecture exhaustive-audit-and-review-domain exhaustive-audit-and-review-operations \
             exhaustive-audit-and-review-claude-system exhaustive-audit-and-review-researcher code-reviewer code-reviewer-structure \
             code-reviewer-security code-reviewer-test-quality code-reviewer-simplification code-reviewer-smells project-health \
             apply-rec-orchestrator apply-rec-editor apply-rec-analyst dependency-modernizer runbook-author; do
    printf -- '---\nname: %s\ndescription: "An agent."\n---\n' "$agent" > "$RUNTIME_DIR/agents/$agent.md"
done
cp "$NFC_SKILL/claude_code_new_functionality_check.sh" "$RUNTIME_DIR/skills/claude-code-new-functionality-check/"
cp "$CFG/hooks/claude-code-new-functionality-check-reminder.sh" "$RUNTIME_DIR/hooks/"
printf '{"env": {"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "4"}, "enabledPlugins": {"pyright-lsp@market": true}}\n' > "$RUNTIME_DIR/settings.json"
printf '{"env": {"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1", "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "9"}, "enabledPlugins": {"superpowers@market": true, "autoharness@local": true}}\n' > "$AUDITED_DIR/settings.json"
run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$RUNTIME_DIR" capabilities --config-dir "$AUDITED_DIR"
check "runtime with the agents, audited config without: every agent is present" "17/17" "$(jv "$OUT" 'sum(1 for v in d["agents"].values() if v)')/$(jv "$OUT" 'len(d["agents"])')"
check "... the runtime config is shown as a placeholder of its own" "<runtime>" "$(jv "$OUT" 'd["runtime_config"]')"
check "... the companion skill the session can call is the runtime's" "true/<runtime>/skills/claude-code-new-functionality-check/claude_code_new_functionality_check.sh" "$(jv "$OUT" 'd["companions"]["new_functionality_check"]["present"]')/$(jv "$OUT" 'd["companions"]["new_functionality_check"]["helper"]')"
check "... the limits are the runtime's (depth 4, cap 20), not the audited config's (depth 1, cap 9)" '{"concurrent_source": "default", "depth_source": "settings", "max_concurrent": 20, "max_depth": 4}' "$(jv "$OUT" 'd["limits"]')"
check "... so nothing is blocked by the audited config's depth" "[]" "$(jv "$OUT" 'd["blocked"]')"
check "... the plugins reported are the audited config's" '{"autoharness": true, "lsp": {"pyright": false, "typescript": false}, "new_functionality_check_data": true, "superpowers": true}' "$(jv "$OUT" '{"superpowers": d["audited_config"]["companions"]["superpowers"]["enabled"], "autoharness": d["audited_config"]["companions"]["autoharness"]["enabled"], "lsp": d["audited_config"]["companions"]["lsp"], "new_functionality_check_data": d["audited_config"]["companions"]["new_functionality_check_data"]}')"
check_absent "... and no absolute path is printed for either config" "$SB" "$OUT"
run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$AUDITED_DIR" capabilities --config-dir "$RUNTIME_DIR"
check "the reverse (agents only in the audited config): every agent is missing" "0/17" "$(jv "$OUT" 'sum(1 for v in d["agents"].values() if v)')/$(jv "$OUT" 'len(d["agents"])')"
check "... the companion skill is missing too" "false" "$(jv "$OUT" 'd["companions"]["new_functionality_check"]["present"]')"
check "... and the runtime's depth of 1 is what blocks" "1" "$(jv "$OUT" 'd["limits"]["max_depth"]')"
run capabilities --config-dir "$AUDITED_DIR"
check "without the seam, the runtime is CLAUDE_CONFIG_DIR: its agents count, not the audited config's" "true/<runtime>" "$(jv "$OUT" 'd["agents"]["code-reviewer"]')/$(jv "$OUT" 'd["runtime_config"]')"
run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$RUNTIME_DIR" plan --root "$WS" --scope workspace --config-dir "$AUDITED_DIR"
check "plan: the concurrency cap is the runtime's too" '{"cap": 20, "per_wave": 18}' "$(jv "$OUT" 'd["limits"]')"
run FAKE_CLAUDE_VERSION=2.1.100 capabilities
check_contains "a CLI below 2.1.224 is a warning" "2.1.224" "$(jv "$OUT" 'd["warnings"]')"
check "... the old version is still reported" "2.1.100" "$(jv "$OUT" 'd["cli_version"]')"
run FAKE_CLAUDE_MODE=fail capabilities
check "a failing claude --version leaves cli_version null" "null" "$(jv "$OUT" 'd["cli_version"]')"
check_contains "... with a warning that says why" "claude --version" "$(jv "$OUT" 'd["warnings"]')"
STARTED="$(date +%s)"
run FAKE_CLAUDE_MODE=slow EXHAUSTIVE_AUDIT_CLI_TIMEOUT_SECS=1 capabilities
ELAPSED=$(( $(date +%s) - STARTED ))
check "a hung claude --version is bounded: cli_version null" "null" "$(jv "$OUT" 'd["cli_version"]')"
check_contains "... the warning says it timed out, with its attempts" "timed out after 2 attempt" "$(jv "$OUT" 'd["warnings"]')"
# Two 1s attempts take about 2s; a child that outlived its kill would hold each attempt for the stub's full 5s.
if [ "$ELAPSED" -le 8 ]; then check "... and the whole call stays bounded (no lingering child)" "bounded" "bounded"; else check "... and the whole call stays bounded (no lingering child)" "bounded" "${ELAPSED}s"; fi

# ---------------------------------------------------------------------------
# 3. config-facts
# ---------------------------------------------------------------------------
factf() { jv "$OUT" "[m for m in d['modules'] if m['name'] == '$1'][0]$2"; }

run config-facts --root "$WS" --config-dir "$CFG"
check "config-facts exits 0" "0" "$RC"
check "config-facts: one record per module" '["web", "api", "beta", "gamma", "zeta"]' "$(jv "$OUT" '[m["name"] for m in d["modules"]]')"
check "config-facts: git activity in the last 90 days" "2" "$(factf api "['git']['commits_90d']")"
check_prefix "config-facts: the last commit date" "20" "$(factf api "['git']['last_commit_date']")"
check "config-facts: a non-git module has no git facts, and says it is not a repository" '{"commits_90d": null, "error": null, "last_commit_date": null, "repo": false}' "$(factf web "['git']")"
check "config-facts: a healthy repository has no git error" "true/null" "$(factf api "['git']['repo']")/$(factf api "['git']['error']")"
check "config-facts: tracked sensitive files, names only (.env.example is not one)" '["api/.env", "api/certs/server.pem"]' "$(factf api "['tracked_sensitive']")"
check_absent "config-facts: never the content of a sensitive file" "localhost:8080" "$OUT"
check "config-facts: lockfiles" '["api/poetry.lock"]' "$(factf api "['lockfiles']")"
check "config-facts: lockfiles (npm)" '["web/package-lock.json"]' "$(factf web "['lockfiles']")"
check "config-facts: CI files" '["api/.github/workflows/ci.yml"]' "$(factf api "['ci']")"
check "config-facts: tests present" "true/false" "$(factf api "['tests_present']")/$(factf web "['tests_present']")"
check "config-facts: CLAUDE.md markers (a repeated marker keeps every value)" '{"project-organization": "verify make check\nkeep notes.txt", "retry-standard": "full", "test-command": "pytest -q", "testing-standard": "standard"}' "$(factf api "['markers']")"
check "config-facts: python dependencies (requirements.txt and pyproject; never python itself or -r)" '[["flask", ">=2.0", "api/requirements.txt"], ["httpx", ">=0.27", "api/pyproject.toml"], ["pydantic", "==2.8.2", "api/pyproject.toml"], ["requests", "==2.31.0", "api/requirements.txt"], ["sqlalchemy", "2.0.30", "api/pyproject.toml"]]' "$(factf api "['dependencies']" | python3 -c 'import json,sys; print(json.dumps(sorted([x["name"], x["spec"], x["file"]] for x in json.load(sys.stdin))))' 2>/dev/null)"
check "config-facts: package.json dependencies and devDependencies" '[["jest", "29.7.0", "web/package.json"], ["react", "^18.2.0", "web/package.json"]]' "$(factf web "['dependencies']" | python3 -c 'import json,sys; print(json.dumps(sorted([x["name"], x["spec"], x["file"]] for x in json.load(sys.stdin))))' 2>/dev/null)"
check "config-facts: hook registrations with their form" '[["PreToolUse", "Bash", "guard.sh", "exec"], ["Stop", null, "on-stop.sh", "shell"]]' "$(jv "$OUT" 'sorted([h["event"], h["matcher"], h["command_basename"], h["form"]] for h in d["config"]["settings"]["hooks"])')"
check "config-facts: permission counts" '{"allow": 2, "ask": 0, "default_mode": "auto", "deny": 1}' "$(jv "$OUT" 'd["config"]["settings"]["permissions"]')"
check "config-facts: enabled plugins (true values only)" '["superpowers@market", "typescript-lsp@market"]' "$(jv "$OUT" 'd["config"]["settings"]["enabled_plugins"]')"
check "config-facts: env keys, names only" '["CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH", "SAMPLE_SETTING"]' "$(jv "$OUT" 'd["config"]["settings"]["env_keys"]')"
check_absent "config-facts: never an env value" "$SETTING_VALUE" "$OUT"
check "config-facts: the model setting" "sonnet" "$(jv "$OUT" 'd["config"]["settings"]["model"]')"
check "config-facts: agent tools as a list" '["Read", "Grep", "Glob", "Bash", "Agent"]' "$(jv "$OUT" '[a for a in d["config"]["agents"] if a["name"] == "code-reviewer"][0]["tools"]')"
check "config-facts: omitClaudeMd is read" "true/false" "$(jv "$OUT" '[a for a in d["config"]["agents"] if a["name"] == "exhaustive-audit-and-review-claude-system"][0]["omit_claude_md"]')/$(jv "$OUT" '[a for a in d["config"]["agents"] if a["name"] == "code-reviewer"][0]["omit_claude_md"]')"
check "config-facts: a skill with frontmatter and resources" '{"description_chars": 17, "has_frontmatter": true, "has_resources": true, "model_invocable": true, "name": "alpha"}' "$(jv "$OUT" '[s for s in d["config"]["skills"] if s["name"] == "alpha"][0]')"
check "config-facts: a skill without frontmatter" "false" "$(jv "$OUT" '[s for s in d["config"]["skills"] if s["name"] == "beta"][0]["has_frontmatter"]')"
check "config-facts: disable-model-invocation makes a skill typed-only" "false" "$(jv "$OUT" '[s for s in d["config"]["skills"] if s["name"] == "gamma"][0]["model_invocable"]')"
check "config-facts: hook files, executable and syntax" '[["broken.sh", false, false], ["on-stop.sh", true, true]]' "$(jv "$OUT" 'sorted([h["name"], h["executable"], h["syntax_ok"]] for h in d["config"]["hooks_dir"] if h["name"] in ("broken.sh", "on-stop.sh"))')"
check "config-facts: CLAUDE.md size and sections (a fenced heading is not one)" "{\"bytes\": $CLAUDE_MD_BYTES, \"sections\": [\"One\", \"Two\"]}" "$(jv "$OUT" 'd["config"]["claude_md"]')"
check "config-facts: the new-functionality status line, with its path masked" "DUE: last sweep 9 days ago; ledger at <config>/claude-code-new-functionality-check" "$(jv "$OUT" 'd["config"]["new_functionality_check"]["status_line"]')"
check "config-facts: open proposals are the proposed and accepted ids" "[\"NF-0001\", \"NF-0003\"]" "$(jv "$OUT" 'd["config"]["new_functionality_check"]["open_proposals"]')"
check "config-facts: the inventory could be generated" "true" "$(jv "$OUT" 'd["config"]["new_functionality_check"]["inventory_present"]')"
check "config-facts: CHECK commands are not run without --checks" "null" "$(jv "$OUT" 'd["config"]["checks"]')"
check "config-facts: CONFIG_TEST labels, read-only and masked" "[\"bash tests/config-suite.sh --token $MASKED_SECRET\"]" "$(jv "$OUT" 'd["config"]["config_tests"]')"
check_absent "config-facts: a secret never reaches the output" "$SECRET" "$OUT"
check_absent "config-facts: no absolute path" "$SB" "$OUT"
check "config-facts: config_dir placeholder" "<config>" "$(jv "$OUT" 'd["config_dir"]')"

run EXHAUSTIVE_AUDIT_CHECK_TIMEOUT_SECS=1 config-facts --root "$WS" --checks
check "config-facts --checks exits 0" "0" "$RC"
check "--checks: each CHECK line runs, in order" "4" "$(jv "$OUT" 'len(d["config"]["checks"])')"
check "--checks: exit code and tail" '[0, ["check-ok"]]' "$(jv "$OUT" '[d["config"]["checks"][0]["exit_code"], d["config"]["checks"][0]["tail"]]')"
check "--checks: a failing check keeps its exit code; its cwd is the root, shown as ." '[3, ["."]]' "$(jv "$OUT" '[d["config"]["checks"][1]["exit_code"], d["config"]["checks"][1]["tail"]]')"
check "--checks: a hung check is stopped by the timeout (124)" "124" "$(jv "$OUT" 'd["config"]["checks"][2]["exit_code"]')"
check "--checks: a secret in the output is masked" "[\"token=$MASKED_SECRET\"]" "$(jv "$OUT" 'd["config"]["checks"][3]["tail"]')"
check "--checks: a secret in the command label is masked" "echo token=$MASKED_SECRET" "$(jv "$OUT" 'd["config"]["checks"][3]["command_label"]')"
check_absent "--checks: no secret anywhere" "$SECRET" "$OUT"
run EXHAUSTIVE_AUDIT_CHECK_TIMEOUT_SECS=1 EXHAUSTIVE_AUDIT_TIMEOUT_TOOL=none config-facts --root "$WS" --checks
check "--checks without timeout/gtimeout: the background-kill fallback stops a hung check" "124" "$(jv "$OUT" 'd["config"]["checks"][2]["exit_code"]')"
run config-facts --root "$WS" --config-dir "$SB/cfg4"
check "a house.conf with CONFIG_TEST lines gives no unknown-key warning" "" "$(printf '%s' "$ERR" | grep -i 'unknown key')"
check "CONFIG_TEST lines are surfaced in order" '["bash hooks/tests/run-all-tests.sh", "bash hooks/tests/test-one.sh"]' "$(jv "$OUT" 'd["config"]["config_tests"]')"
check "config-facts without the new-functionality check: nothing to report" '{"inventory_present": false, "not_run": [], "open_proposals": [], "status_line": null}' "$(jv "$OUT" 'd["config"]["new_functionality_check"]')"

# A git that fails is not a module without git: config-facts says which, and git's own message (made
# relative) reaches stderr.
GF="$SB/gitfail"
mkdir -p "$GF/brk" "$GF/fine"
printf '# brk\n' > "$GF/brk/CLAUDE.md"
printf 'gitdir: %s\n' "$GF/brk/.git-missing" > "$GF/brk/.git"
printf '{"name": "fine"}\n' > "$GF/fine/package.json"
mkdir -p "$GF/long"
printf '# long\n' > "$GF/long/CLAUDE.md"
printf 'gitdir: %s/.git-%s\n' "$GF/long" "$(printf '%0240d' 0 | tr 0 x)" > "$GF/long/.git"
run config-facts --root "$GF"
check "a long git message is cut to 200 characters in the warning" "200" "$(printf '%s\n' "$ERR" | sed -n 's/.*git log exited 128 in long: //p' | head -1 | awk '{ print length($0) }')"
check "config-facts with a broken repository still exits 0" "0" "$RC"
check "a repository whose git fails is reported as such" "true/fatal: not a git repository: brk/.git-missing" "$(factf brk "['git']['repo']")/$(factf brk "['git']['error']" | sed 's/^git log exited 128: //')"
check "... while a folder without git is simply not a repository" '{"commits_90d": null, "error": null, "last_commit_date": null, "repo": false}' "$(factf fine "['git']")"
check_contains "git's own message reaches stderr, with the folder it ran in" "git log exited 128 in brk: fatal: not a git repository: brk/.git-missing" "$ERR"
check_contains "... the ls-files failure too, before discovery falls back to walking" "git ls-files exited 128 in brk" "$ERR"
check_absent "... never with an absolute path" "$SB" "$ERR"

# A config folder from elsewhere is code from elsewhere: the audit never runs its companion scripts or its
# CHECK= lines. The companion runs from the RUNNING session's config instead, pointed at the audited one.
FOREIGN="$SB/foreign-config"
mkdir -p "$FOREIGN/hooks" "$FOREIGN/skills/claude-code-new-functionality-check" "$FOREIGN/claude-code-new-functionality-check" \
         "$FOREIGN/exhaustive-audit-and-review"
for script in "$FOREIGN/hooks/claude-code-new-functionality-check-reminder.sh" \
              "$FOREIGN/skills/claude-code-new-functionality-check/claude_code_new_functionality_check.sh"; do
    printf '#!/bin/bash\necho ran >> "%s"\necho "FOREIGN CODE RAN"\n' "$FOREIGN/ran.marker" > "$script"
    chmod +x "$script"
done
printf 'CHECK=echo ran >> "%s"\n' "$FOREIGN/ran.marker" > "$FOREIGN/exhaustive-audit-and-review/house.conf"
printf '| ID | status |\n|---|---|\n| %s-%04d | proposed |\n' NF 7 > "$FOREIGN/claude-code-new-functionality-check/ledger.md"
run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$SB/cfg3" config-facts --root "$WS" --config-dir "$FOREIGN" --checks
check "a foreign config's companion scripts and CHECK= lines never run" "absent" "$( [ -e "$FOREIGN/ran.marker" ] && echo present || echo absent )"
check "... config-facts still exits 0" "0" "$RC"
check "... with no companion in the running session, both scripts are recorded as not run" "2" "$(jv "$OUT" 'len(d["config"]["new_functionality_check"]["not_run"])')"
check_contains "... saying why" "never run" "$(jv "$OUT" 'd["config"]["new_functionality_check"]["not_run"]')"
check "... the CHECK= line is listed as not run" '[[false, null, []]]' "$(jv "$OUT" '[[c["ran"], c["exit_code"], c["tail"]] for c in d["config"]["checks"]]')"
check_contains "... and a warning says so" "never run" "$ERR"
check "... the foreign ledger is still read (a file, not code)" '["NF-0007"]' "$(jv "$OUT" 'd["config"]["new_functionality_check"]["open_proposals"]')"
check_absent "... no absolute path" "$SB" "$OUT"
run EXHAUSTIVE_AUDIT_RUNTIME_CONFIG="$RUNTIME_DIR" "CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR=$SB/nfc-relocated" config-facts --root "$WS" --config-dir "$FOREIGN"
check "with a companion in the running session, its scripts run, never the foreign ones" "absent" "$( [ -e "$FOREIGN/ran.marker" ] && echo present || echo absent )"
check "... pointed at the audited config's own data folder, whatever this machine's override says" "DUE: last sweep 9 days ago; ledger at <config>/claude-code-new-functionality-check" "$(jv "$OUT" 'd["config"]["new_functionality_check"]["status_line"]')"
check "... the inventory comes from the running session's helper, and nothing is left unrun" "true/[]" "$(jv "$OUT" 'd["config"]["new_functionality_check"]["inventory_present"]')/$(jv "$OUT" 'd["config"]["new_functionality_check"]["not_run"]')"
run EXHAUSTIVE_AUDIT_CHECK_TIMEOUT_SECS=1 config-facts --root "$WS" --checks
check "the running session's own config still runs its CHECK= lines" '[true, 0]' "$(jv "$OUT" '[d["config"]["checks"][0]["ran"], d["config"]["checks"][0]["exit_code"]]')"
# Every variable the companion reads points at the audited config; this machine's own overrides apply to
# the running session's config only.
ECHO_RT="$SB/runtime-echo"
mkdir -p "$ECHO_RT/hooks"
cat > "$ECHO_RT/hooks/claude-code-new-functionality-check-reminder.sh" <<'STUB'
#!/bin/bash
echo "ledger=$CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR config=$NEW_FUNCTIONALITY_CHECK_CLAUDE_DIR state=$NEW_FUNCTIONALITY_CHECK_STATE_FILE update=$NEW_FUNCTIONALITY_CHECK_UPDATE_RESULT_FILE"
STUB
chmod +x "$ECHO_RT/hooks/claude-code-new-functionality-check-reminder.sh"
machine_facts() {
    # machine_facts <config-dir> — config-facts with this machine's four companion overrides set
    run "EXHAUSTIVE_AUDIT_RUNTIME_CONFIG=$ECHO_RT" "CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR=$ECHO_RT/own-ledger" \
        "NEW_FUNCTIONALITY_CHECK_CLAUDE_DIR=$ECHO_RT" "NEW_FUNCTIONALITY_CHECK_STATE_FILE=$ECHO_RT/own-state.json" \
        "NEW_FUNCTIONALITY_CHECK_UPDATE_RESULT_FILE=$ECHO_RT/own-update.json" config-facts --root "$WS" --config-dir "$1"
}
machine_facts "$FOREIGN"
check "a foreign config's companion run sees only the audited config's folders and files" "ledger=<config>/claude-code-new-functionality-check config=<config> state=<config>/tmp/claude-code-new-functionality-check-state.json update=<config>/.last-update-result.json" "$(jv "$OUT" 'd["config"]["new_functionality_check"]["status_line"]')"
machine_facts "$ECHO_RT"
check "the running session's own config keeps this machine's overrides (unchanged behavior)" "ledger=<config>/own-ledger config=<config> state=<config>/own-state.json update=<config>/own-update.json" "$(jv "$OUT" 'd["config"]["new_functionality_check"]["status_line"]')"

# ---------------------------------------------------------------------------
# 4. plan
# ---------------------------------------------------------------------------
run plan --root "$WS" --scope claude-system
check "plan claude-system exits 0" "0" "$RC"
check "regression: a claude-system plan has exactly one scope" '["D5-claude-system"]' "$(jv "$OUT" '[s["id"] for s in d["scopes"]]')"
check "the claude-system scope record" '{"agent": "exhaustive-audit-and-review-claude-system", "dim": 5, "id": "D5-claude-system", "kind": "dimension", "module": null}' "$(jv "$OUT" '{k: d["scopes"][0][k] for k in ("id", "kind", "dim", "agent", "module")}')"
check "claude-system: one wave" '[["D5-claude-system"]]' "$(jv "$OUT" 'd["waves"]')"
check "claude-system estimate: the dimension agent plus the researcher" '{"agents": 2, "minutes": 25, "processed_tokens": 4700000}' "$(jv "$OUT" '{k: d["estimate"][k] for k in ("agents", "processed_tokens", "minutes")}')"
check "claude-system: the sampled alternative is the same" '{"agents": 2, "minutes": 25, "processed_tokens": 4700000}' "$(jv "$OUT" 'd["alternatives"]["sampled"]')"
check "the estimate is in processed tokens; the old tokens key is gone" "false" "$(jv "$OUT" '"tokens" in d["estimate"]')"
check "the estimate names its basis" "measured on the bundled demo (2 small modules); larger scopes cost more" "$(jv "$OUT" 'd["estimate"]["basis"]')"
check "plan: scope and coverage are echoed" "claude-system/exhaustive" "$(jv "$OUT" 'd["scope"]')/$(jv "$OUT" 'd["coverage"]')"
check "plan: limits" '{"cap": 20, "per_wave": 18}' "$(jv "$OUT" 'd["limits"]')"

run plan --root "$WS" --scope workspace
check "plan workspace: dimensions 2-4 and one health scope per module, no code, no D5" '["D2-architecture", "D3-domain", "D4-operations", "PH-1", "PH-2", "PH-3", "PH-4", "PH-5"]' "$(jv "$OUT" '[s["id"] for s in d["scopes"]]')"
check "plan workspace: a health scope record" '{"agent": "project-health", "dim": 2, "id": "PH-2", "kind": "health", "module": "api"}' "$(jv "$OUT" '{k: [s for s in d["scopes"] if s["id"] == "PH-2"][0][k] for k in ("id", "kind", "dim", "agent", "module")}')"
check "plan workspace: estimate" '{"agents": 9, "minutes": 25, "processed_tokens": 29700000}' "$(jv "$OUT" '{k: d["estimate"][k] for k in ("agents", "processed_tokens", "minutes")}')"

run plan --root "$WS" --scope all
check "plan all exits 0" "0" "$RC"
check "plan all: every scope" '["D2-architecture", "D3-domain", "D4-operations", "D5-claude-system", "PH-1", "PH-2", "PH-3", "PH-4", "PH-5", "CR-1-01", "CR-2-01", "CR-2-02", "CR-2-03", "CR-5-01"]' "$(jv "$OUT" '[s["id"] for s in d["scopes"]]')"
check "plan all: chunks pack whole files up to the line budget" '[["CR-2-01", ["api/src/handlers.py", "api/src/sql_query.py"], 10], ["CR-2-02", ["api/src/util.py", "api/src/zz_secret_store.py"], 9], ["CR-2-03", ["api/tests/test_util.py"], 4]]' "$(jv "$OUT" '[[s["id"], s["paths"], s["lines"]] for s in d["scopes"] if s.get("module") == "api" and s["kind"] == "code"]')"
check "plan all: a file larger than the budget gets its own chunk" '[["web/src/app.js"], 11]' "$(jv "$OUT" '[[s["paths"], s["lines"]] for s in d["scopes"] if s["id"] == "CR-1-01"][0]')"
check "plan all: a code scope record" '{"agent": "code-reviewer", "children": 5, "dim": 1, "kind": "code", "module": "zeta"}' "$(jv "$OUT" '{k: [s for s in d["scopes"] if s["id"] == "CR-5-01"][0][k] for k in ("kind", "dim", "agent", "module", "children")}')"
check "plan all: waves" '[["D2-architecture", "D3-domain", "D4-operations", "D5-claude-system", "PH-1", "PH-2", "PH-3", "PH-4", "PH-5", "CR-1-01"], ["CR-2-01", "CR-2-02", "CR-2-03"], ["CR-5-01"]]' "$(jv "$OUT" 'd["waves"]')"
check "plan all: estimate" '{"agents": 40, "minutes": 67, "processed_tokens": 110200000}' "$(jv "$OUT" '{k: d["estimate"][k] for k in ("agents", "processed_tokens", "minutes")}')"
check "plan all: estimate by kind" '{"code": {"agents": 30, "processed_tokens": 77000000}, "dimension": {"agents": 4, "processed_tokens": 14000000}, "health": {"agents": 5, "processed_tokens": 18000000}, "research": {"agents": 1, "processed_tokens": 1200000}}' "$(jv "$OUT" 'd["estimate"]["by_kind"]')"
check "plan all: the sampled alternative" '{"agents": 28, "minutes": 49, "processed_tokens": 79400000}' "$(jv "$OUT" 'd["alternatives"]["sampled"]')"
check_absent "plan all: no absolute path" "$SB" "$OUT"

run CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=10 plan --root "$WS" --scope all
check "a smaller cap: the plan still succeeds" "0" "$RC"
check "waves never exceed cap - 2 (a code scope costs 6, anything else 1)" "8" "$(jv "$OUT" 'max(sum(6 if [s for s in d["scopes"] if s["id"] == i][0]["kind"] == "code" else 1 for i in w) for w in d["waves"])')"
check "every scope is in exactly one wave" "14/14" "$(jv "$OUT" 'len([i for w in d["waves"] for i in w])')/$(jv "$OUT" 'len(set(i for w in d["waves"] for i in w))')"
check "dimension and health scopes come before code scopes" "true" "$(jv "$OUT" '(lambda order: max(i for i, k in enumerate(order) if k != "code") < min(i for i, k in enumerate(order) if k == "code"))([[s for s in d["scopes"] if s["id"] == i][0]["kind"] for w in d["waves"] for i in w])')"
check "the per-wave limit is reported" '{"cap": 10, "per_wave": 8}' "$(jv "$OUT" 'd["limits"]')"
run CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=7 plan --root "$WS" --scope all
check "a cap that leaves room for no code scope is blocked" "3" "$RC"
run CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=7 plan --root "$WS" --scope workspace
check "... but a plan without code scopes still fits" "0/5" "$RC/$(jv "$OUT" 'max(len(w) for w in d["waves"])')"

run plan --root "$WS" --scope module api
check "plan module: health, code, and dimensions 2-4 for that module, no D5" '[["D2-architecture", "api"], ["D3-domain", "api"], ["D4-operations", "api"], ["PH-2", "api"], ["CR-2-01", "api"], ["CR-2-02", "api"], ["CR-2-03", "api"]]' "$(jv "$OUT" '[[s["id"], s["module"]] for s in d["scopes"]]')"
check "plan module: the scope is echoed" "module api" "$(jv "$OUT" 'd["scope"]')"
check "a code scope costs the same at any size (10, 9 and 4 lines: 3 x 15.4M)" "46200000" "$(jv "$OUT" 'd["estimate"]["by_kind"]["code"]["processed_tokens"]')"
printf '%s' "$OUT" > "$SB/plan-api.json"
run plan --root "$WS" --scope module nosuch
check "plan module: an unknown module is a usage error" "1" "$RC"
run plan --root "$WS" --scope everything
check "plan: an unknown scope is a usage error" "1" "$RC"
run plan --root "$WS" --coverage partial
check "plan: an unknown coverage is a usage error" "1" "$RC"
run plan --root "$WS" --loc-budget 0
check "plan: a zero line budget is a usage error" "1" "$RC"

run plan --root "$WS" --scope module api --coverage sampled --loc-budget 12
check "sampled: one code scope, the riskiest names first" '[["CR-2-01", ["api/src/sql_query.py", "api/src/zz_secret_store.py"], 11]]' "$(jv "$OUT" '[[s["id"], s["paths"], s["lines"]] for s in d["scopes"] if s["kind"] == "code"]')"
run plan --root "$WS" --scope module api --coverage sampled --loc-budget 16
check "sampled: then the most recently changed git files" '[["api/src/sql_query.py", "api/src/util.py", "api/src/zz_secret_store.py"], 16]' "$(jv "$OUT" '[[s["paths"], s["lines"]] for s in d["scopes"] if s["kind"] == "code"][0]')"
check "sampled: the exhaustive alternative is offered" "true" "$(jv "$OUT" '"exhaustive" in d["alternatives"]')"

# ---------------------------------------------------------------------------
# 5. init-run
# ---------------------------------------------------------------------------
run EXHAUSTIVE_AUDIT_NOW=20261010T120000Z init-run --plan "$SB/plan-api.json" --root "$WS"
check "init-run exits 0" "0" "$RC"
check "init-run prints the UTC run id first" "20261010T120000Z" "$(first_line "$OUT")"
check "init-run then prints the run folder, config-relative" "<config>/exhaustive-audit-and-review/runs/20261010T120000Z" "$(printf '%s\n' "$OUT" | sed -n '2p')"
R1="$(first_line "$OUT")"
check "init-run: the run folder is private (0700)" "700" "$(file_mode "$DATA/runs/$R1")"
check "init-run: results/ is private too" "700" "$(file_mode "$DATA/runs/$R1/results")"
check "init-run: the plan is kept" "7" "$(jfile "$DATA/runs/$R1/plan.json" 'len(d["scopes"])')"
check "init-run: the run's plan records the audited root" "$WS" "$(jfile "$DATA/runs/$R1/plan.json" 'd["root"]')"
check "init-run: ... and each module's root-relative folder" '[["api", "api"]]' "$(jfile "$DATA/runs/$R1/plan.json" '[[m["name"], m["path"]] for m in d["modules"]]')"
run EXHAUSTIVE_AUDIT_NOW=20261010T120000Z init-run --plan "$SB/plan-api.json" --root "$WS"
check "init-run: a taken run id gets a -2 suffix" "20261010T120000Z-2" "$(first_line "$OUT")"
R2="$(first_line "$OUT")"
run EXHAUSTIVE_AUDIT_NOW=20261010T120000Z init-run --plan "$SB/plan-api.json" --root "$WS"
check "init-run: then -3" "20261010T120000Z-3" "$(first_line "$OUT")"
R3="$(first_line "$OUT")"
python3 - "$SB/plan-api.json" "$SB" <<'PY'
import copy, json, sys
plan = json.load(open(sys.argv[1]))
dropped = copy.deepcopy(plan)
dropped["waves"][-1] = dropped["waves"][-1][:-1]
duplicate = copy.deepcopy(plan)
duplicate["scopes"].append(dict(duplicate["scopes"][0]))
duplicate["waves"][0].append(duplicate["scopes"][0]["id"])
cases = {"empty": {}, "scopeless": {"root_name": plan["root_name"], "waves": plan["waves"]},
         "dropping": dropped, "duplicated": duplicate}
for name, value in cases.items():
    with open("%s/plan-bad-%s.json" % (sys.argv[2], name), "w") as handle:
        json.dump(value, handle)
PY
for pair in "empty|it is not a plan (no root_name)" "scopeless|its scopes are missing or malformed" \
            "dropping|its waves do not hold every scope exactly once" "duplicated|its waves do not hold every scope exactly once"; do
    run init-run --plan "$SB/plan-bad-${pair%%|*}.json" --root "$WS"
    check "init-run refuses a ${pair%%|*} plan (exit 1)" "1" "$RC"
    check_contains "... and says why" "the plan file is not usable: ${pair#*|}" "$ERR"
done
run init-run --plan "$SB/no-such-plan.json" --root "$WS"
check "init-run: a missing plan is a precondition error" "1" "$RC"
printf 'not json' > "$SB/bad-plan.json"
run init-run --plan "$SB/bad-plan.json" --root "$WS"
check "init-run: a plan that is not JSON is a precondition error" "1" "$RC"
run init-run --plan "$SB/plan-api.json" --root "$SB/single"
check "init-run: a plan made for another root is refused" "1" "$RC"

# ---------------------------------------------------------------------------
# 6. next-wave, save-result, validate: the run lifecycle
# ---------------------------------------------------------------------------
cat > "$SB/mk.py" <<'PY'
# mk.py <out|-> <run> <scope> <case> — writes one agent result, valid or broken in one named way.
import copy, json, sys
out, run, scope, case = sys.argv[1:5]
FINDING = {"dim": 2, "module": "api", "check": "A3", "subject": "requests", "severity": "high",
           "category": "dependencies", "finding": "The HTTP client pin is old",
           "rationale": "Old pins miss fixes.", "recommendation": "Bump the pin and run the tests.",
           "effort": "S", "risk": "med", "evidence": [{"path": "api/requirements.txt", "line": 1}],
           "research_questions": ["Which advisories affect requests 2.31?"]}

def many(count):
    items = []
    for number in range(count):
        item = copy.deepcopy(FINDING)
        item["subject"] = "dependency-%d" % number
        items.append(item)
    return items

doc = {"header": {"run": run, "scope": scope, "agent": "reviewer", "files_reviewed": 2, "lines_reviewed": 30,
                  "notes": "checked", "not_reviewed": []},
       "findings": [copy.deepcopy(FINDING)]}
h, f = doc["header"], doc["findings"][0]
raw = None
if case == "valid": pass
elif case == "valid_critical": f["severity"] = "critical"; f["evidence"] = [{"path": "api/requirements.txt", "line": 9}]
elif case == "top_unknown": doc["summary"] = "extra"
elif case == "no_header": del doc["header"]
elif case == "run_mismatch": h["run"] = "19990101T000000Z"
elif case == "scope_mismatch": h["scope"] = "D3-domain"
elif case == "header_unknown": h["model"] = "x"
elif case == "files_negative": h["files_reviewed"] = -1
elif case == "lines_bool": h["lines_reviewed"] = True
elif case == "notes_overlong": h["notes"] = "n" * 700
elif case == "notes_too_long": h["notes"] = "n" * 1201
elif case == "not_reviewed_bad": h["not_reviewed"] = [3]
elif case == "finding_unknown": f["confidence"] = "high"
elif case == "dim_zero": f["dim"] = 0
elif case == "dim_six": f["dim"] = 6
elif case == "dim_string": f["dim"] = "2"
elif case == "dim_bool": f["dim"] = True
elif case == "module_unknown": f["module"] = "nosuch"
elif case == "module_null": f["module"] = None
elif case == "check_pattern": f["check"] = "has space"
elif case == "check_overlong": f["check"] = "c" * 50
elif case == "check_too_long": f["check"] = "c" * 81
elif case == "subject_missing": del f["subject"]
elif case == "subject_empty": f["subject"] = "  "
elif case == "severity_bad": f["severity"] = "urgent"
elif case == "category_too_long": f["category"] = "c" * 81
elif case == "finding_too_long": f["finding"] = "f" * 401
elif case == "rationale_overlong": f["rationale"] = "r" * 450
elif case == "rationale_too_long": f["rationale"] = "r" * 801
elif case == "recommendation_too_long": f["recommendation"] = "r" * 801
elif case == "effort_bad": f["effort"] = "XXL"
elif case == "risk_bad": f["risk"] = "medium"
elif case == "evidence_empty": f["evidence"] = []
elif case == "evidence_six": f["evidence"] = [{"path": "api/x.py", "line": n} for n in range(6)]
elif case == "evidence_absolute": f["evidence"] = [{"path": "/etc/hosts", "line": 1}]
elif case == "evidence_dotdot": f["evidence"] = [{"path": "api/../../elsewhere", "line": 1}]
elif case == "evidence_tilde": f["evidence"] = [{"path": "~/notes.txt", "line": 1}]
elif case == "evidence_drive": f["evidence"] = [{"path": "C:\\work\\x.py", "line": 1}]
elif case == "evidence_config": f["evidence"] = [{"path": "<config>/settings.json", "line": 3}]
elif case == "evidence_line_negative": f["evidence"] = [{"path": "api/x.py", "line": -1}]
elif case == "evidence_line_bool": f["evidence"] = [{"path": "api/x.py", "line": False}]
elif case == "evidence_unknown": f["evidence"] = [{"path": "api/x.py", "line": 1, "column": 2}]
elif case == "evidence_not_list": f["evidence"] = {"path": "api/x.py", "line": 1}
elif case == "questions_four": f["research_questions"] = ["first question", "second question", "third question", "fourth question"]
elif case == "question_too_long": f["research_questions"] = ["q" * 401]
elif case == "questions_not_list": f["research_questions"] = "one question"
elif case == "questions_absent": del f["research_questions"]
elif case == "control_char": f["finding"] = "bell \x07 here"
elif case == "newline_in_subject": f["subject"] = "two\nlines"
elif case == "bidi_override": f["subject"] = "abc\u202edef"
elif case == "findings_40": doc["findings"] = many(40)
elif case == "findings_41": doc["findings"] = many(41)
elif case == "findings_60": doc["findings"] = many(60)
elif case == "findings_61": doc["findings"] = many(61)
elif case == "findings_not_list": doc["findings"] = {"a": 1}
elif case == "not_json": raw = "this is prose, not JSON"
elif case == "array_top": raw = json.dumps([doc])
elif case == "secret": f["rationale"] = "The key " + "AK" + "IA" + "QWERTYUIOPASDFGH" + " is committed."
elif case == "ten_errors":
    h["model"], h["files_reviewed"], h["lines_reviewed"] = "x", -1, True
    f["confidence"], f["dim"], f["check"], f["severity"] = "high", 0, "has space", "urgent"
    f["effort"], f["risk"], f["evidence"] = "XXL", "medium", []
else: sys.exit("mk.py: unknown case " + case)
text = raw if raw is not None else json.dumps(doc)
if out == "-":
    sys.stdout.write(text)
else:
    with open(out, "w") as handle:
        handle.write(text)
PY

cat > "$SB/tx.py" <<'PY'
# tx.py <out> <mode> <header-line> <reply> — a subagent transcript in the shape Claude Code writes.
import json, sys
out, mode, header, reply = sys.argv[1:5]
USAGE = {"input_tokens": 100, "output_tokens": 20, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 500}

def line(kind, content, ident=None):
    message = {"role": kind, "content": content}
    if kind == "assistant" and ident:
        message["id"] = ident
        message["usage"] = dict(USAGE)
    return json.dumps({"type": kind, "message": message})

rows = [line("user", "Review this scope.\n" + header + "\nReturn the JSON object only.")]
tool = line("assistant", [{"type": "tool_use", "name": "Read", "input": {}}], "msg-1")
rows += [tool, tool]   # streaming repeats one message: its usage counts once
rows.append(line("user", [{"type": "tool_result", "content": "file text"}]))
if mode == "handback":
    rows.append(line("assistant", [{"type": "tool_use", "name": "SubagentHandback", "input": {"message": reply}}], "msg-2"))
    rows.append(line("user", [{"type": "tool_result", "content": [{"type": "text", "text": "{\"success\":true}"}]}]))
    rows.append(line("assistant", [{"type": "text", "text": "The report was handed back."}], "msg-3"))
elif mode == "plain":
    rows.append(line("assistant", [{"type": "text", "text": "Here is the result:\n```json\n" + reply + "\n```"}], "msg-2"))
elif mode == "split":
    half = len(reply) // 2
    rows.append(line("assistant", [{"type": "text", "text": reply[:half]}], "msg-2"))
    rows.append(line("user", "Output token limit hit. Resume directly, no apology, no recap of what you were doing."))
    rows.append(line("assistant", [{"type": "text", "text": reply[half:]}], "msg-3"))
elif mode == "late-header":
    rows[0] = line("user", "Review this scope.\nReturn the JSON object only.")
    rows.append(line("user", header))
    rows.append(line("assistant", [{"type": "text", "text": reply}], "msg-2"))
else:
    sys.exit("tx.py: unknown mode " + mode)
with open(out, "w") as handle:
    handle.write("\n".join(rows) + "\n")
PY

RES1="$DATA/runs/$R1/results"
state_of() { jfile "$RES1/$1.state" "d['$2']"; }

run next-wave "$R1"
check "next-wave exits 0" "0" "$RC"
check "next-wave: wave 1 holds the first six scopes" '["D2-architecture", "D3-domain", "D4-operations", "PH-2", "CR-2-01", "CR-2-02"]' "$(jv "$OUT" '[x["scope_id"] for x in d["dispatches"]]')"
check "next-wave: wave number and not done" "1/false" "$(jv "$OUT" 'd["wave"]')/$(jv "$OUT" 'd["done"]')"
check "next-wave: every dispatch carries its AUDIT-RUN line" "AUDIT-RUN: $R1 CR-2-01" "$(jv "$OUT" '[x["header"] for x in d["dispatches"] if x["scope_id"] == "CR-2-01"][0]')"
check "next-wave: a code dispatch" '{"agent": "code-reviewer", "dim": 1, "module": "api", "paths": ["api/src/handlers.py", "api/src/sql_query.py"]}' "$(jv "$OUT" '{k: [x for x in d["dispatches"] if x["scope_id"] == "CR-2-01"][0][k] for k in ("agent", "dim", "module", "paths")}')"
check "next-wave: a health dispatch points at its module" '["project-health", ["api"]]' "$(jv "$OUT" '[[x["agent"], x["paths"]] for x in d["dispatches"] if x["scope_id"] == "PH-2"][0]')"
check "next-wave: a module-scoped dimension points at its module" '["exhaustive-audit-and-review-architecture", ["api"]]' "$(jv "$OUT" '[[x["agent"], x["paths"]] for x in d["dispatches"] if x["scope_id"] == "D2-architecture"][0]')"
check "next-wave: first attempts" "[1]" "$(jv "$OUT" 'sorted(set(x["attempt"] for x in d["dispatches"]))')"

python3 "$SB/tx.py" "$SB/t-d2.jsonl" handback "AUDIT-RUN: $R1 D2-architecture" "$(python3 "$SB/mk.py" - "$R1" D2-architecture valid)"
run save-result "$R1" D2-architecture "$SB/t-d2.jsonl"
check "save-result (SubagentHandback) exits 0" "0" "$RC"
check_contains "save-result says what it saved" "saved" "$OUT"
check "save-result: the result file holds the agent's JSON" "requests" "$(jfile "$RES1/D2-architecture.json" 'd["findings"][0]["subject"]')"
check "save-result: the raw reply is kept" "yes" "$( [ -s "$RES1/D2-architecture.raw.txt" ] && echo yes || echo no )"
check "save-result: the attempt is counted" "1" "$(state_of D2-architecture attempts)"
check "save-result: usage totals, each message counted once" "60" "$(jfile "$RES1/D2-architecture.state" 'd["usage"]["output_tokens"]')"
run validate "$R1" D2-architecture
check "validate a good result: exit 0" "0" "$RC"
check "validate a good result: VALID with the count" "VALID 1 findings" "$OUT"
check "validate marks the scope valid" "valid" "$(state_of D2-architecture state)"

python3 "$SB/tx.py" "$SB/t-d3.jsonl" plain "AUDIT-RUN: $R1 D3-domain" "$(python3 "$SB/mk.py" - "$R1" D3-domain valid)"
run save-result "$R1" D3-domain "$SB/t-d3.jsonl"
check "save-result (a plain final message in a code fence) exits 0" "0" "$RC"
run validate "$R1" D3-domain
check "... and validates" "VALID 1 findings" "$OUT"

python3 "$SB/tx.py" "$SB/t-d4.jsonl" split "AUDIT-RUN: $R1 D4-operations" "$(python3 "$SB/mk.py" - "$R1" D4-operations valid)"
run save-result "$R1" D4-operations "$SB/t-d4.jsonl"
check "save-result (a reply split by the output-token limit) exits 0" "0" "$RC"
check_contains "... the split reply is rejoined" "2 piece" "$OUT"
run validate "$R1" D4-operations
check "... and validates" "VALID 1 findings" "$OUT"

python3 "$SB/mk.py" - "$R1" PH-2 valid | ea save-result "$R1" PH-2 - > "$SB/.out" 2>&1
check "save-result from stdin exits 0" "0" "$?"
check "save-result from stdin records its source" "stdin" "$(state_of PH-2 source)"
run validate "$R1" PH-2
check "... and validates" "VALID 1 findings" "$OUT"

python3 "$SB/tx.py" "$SB/t-wrong.jsonl" handback "AUDIT-RUN: $R1 CR-2-02" "$(python3 "$SB/mk.py" - "$R1" CR-2-01 valid)"
run save-result "$R1" CR-2-01 "$SB/t-wrong.jsonl"
check "the AUDIT-RUN guard refuses another scope's transcript (exit 2)" "2" "$RC"
check "... and files nothing under the scope" "absent" "$( [ -e "$RES1/CR-2-01.json" ] && echo present || echo absent )"
check_contains "... and says why" "AUDIT-RUN" "$OUT$ERR"
python3 "$SB/tx.py" "$SB/t-near.jsonl" handback "AUDIT-RUN: $R1 CR-2-01 (retry)" "$(python3 "$SB/mk.py" - "$R1" CR-2-01 valid)"
run save-result "$R1" CR-2-01 "$SB/t-near.jsonl"
check "the AUDIT-RUN line must match exactly, not as a prefix" "2" "$RC"
python3 "$SB/tx.py" "$SB/t-late.jsonl" late-header "AUDIT-RUN: $R1 CR-2-01" "$(python3 "$SB/mk.py" - "$R1" CR-2-01 valid)"
run save-result "$R1" CR-2-01 "$SB/t-late.jsonl"
check "the AUDIT-RUN line must be in the FIRST user message" "2" "$RC"
python3 "$SB/tx.py" "$SB/t-cr1.jsonl" handback "AUDIT-RUN: $R1 CR-2-01" "$(python3 "$SB/mk.py" - "$R1" CR-2-01 valid)"
run save-result "$R1" CR-2-01 "$SB/t-cr1.jsonl"
check "the right transcript is accepted" "0" "$RC"
run validate "$R1" CR-2-01
check "... and validates" "VALID 1 findings" "$OUT"
run save-result "$R1" CR-9-99 "$SB/t-cr1.jsonl"
check "save-result: a scope outside the plan is a usage error" "1" "$RC"
run save-result 19990101T000000Z CR-2-01 "$SB/t-cr1.jsonl"
check "save-result: an unknown run is a usage error" "1" "$RC"
run save-result "../$R1" CR-2-01 "$SB/t-cr1.jsonl"
check "save-result: a run id that is a path is refused" "1" "$RC"
run save-result "$R1" CR-2-01 "$SB/no-such-transcript.jsonl"
check "save-result: a missing transcript is a usage error" "1" "$RC"

# Retry once, then failed.
python3 "$SB/tx.py" "$SB/t-cr2.jsonl" plain "AUDIT-RUN: $R1 CR-2-02" "$(python3 "$SB/mk.py" - "$R1" CR-2-02 finding_unknown)"
run save-result "$R1" CR-2-02 "$SB/t-cr2.jsonl"
check "a schema-breaking reply is still saved for validation" "0" "$RC"
run validate "$R1" CR-2-02
check "validate rejects it: exit 2" "2" "$RC"
check_prefix "validate rejects it: INVALID with reasons" "INVALID:" "$OUT"
run next-wave "$R1"
check "an INVALID scope is offered again, as attempt 2" '[["CR-2-02", 2]]' "$(jv "$OUT" '[[x["scope_id"], x["attempt"]] for x in d["dispatches"]]')"
check "... still in wave 1" "1" "$(jv "$OUT" 'd["wave"]')"
run save-result "$R1" CR-2-02 "$SB/t-cr2.jsonl"
run validate "$R1" CR-2-02
check "INVALID twice: exit 2 again" "2" "$RC"
check "INVALID twice: the scope is failed" "failed" "$(state_of CR-2-02 state)"
run next-wave "$R1"
check "a failed scope is never offered again: wave 2 is next" '2/["CR-2-03"]' "$(jv "$OUT" 'd["wave"]')/$(jv "$OUT" '[x["scope_id"] for x in d["dispatches"]]')"
python3 "$SB/tx.py" "$SB/t-cr3-failed.jsonl" plain "AUDIT-RUN: $R1 CR-2-03" "DISPATCH FAILED: the Agent tool is not available at this depth"
run save-result "$R1" CR-2-03 "$SB/t-cr3-failed.jsonl"
check "a DISPATCH FAILED reply is a problem (exit 2), never an empty result" "2" "$RC"
check_contains "... and says so" "DISPATCH FAILED" "$OUT"
check "... it counts as an invalid attempt" "invalid/1" "$(state_of CR-2-03 state)/$(state_of CR-2-03 attempts)"
check "... its raw reply is kept for the record" "yes" "$( [ -s "$RES1/CR-2-03.raw.txt" ] && echo yes || echo no )"
run validate "$R1" CR-2-03
check "validate after a DISPATCH FAILED reply: INVALID (exit 2), not a usage error" "2" "$RC"
check_contains "... naming the cause" "DISPATCH FAILED" "$OUT"
run next-wave "$R1"
check "... so the scope is offered once more" '[["CR-2-03", 2]]' "$(jv "$OUT" '[[x["scope_id"], x["attempt"]] for x in d["dispatches"]]')"
check "the second validate of the same attempt did not count twice" "invalid" "$(state_of CR-2-03 state)"
python3 "$SB/tx.py" "$SB/t-cr3.jsonl" handback "AUDIT-RUN: $R1 CR-2-03" "$(python3 "$SB/mk.py" - "$R1" CR-2-03 valid_critical)"
run save-result "$R1" CR-2-03 "$SB/t-cr3.jsonl"
run next-wave "$R1"
check "next-wave validates a saved result itself, then reports the run done" 'true/[]/null' "$(jv "$OUT" 'd["done"]')/$(jv "$OUT" 'd["dispatches"]')/$(jv "$OUT" 'd["wave"]')"
check "... and the saved result is now valid" "valid" "$(state_of CR-2-03 state)"
run status "$R1"
check "status: valid, failed, missing" "6/1/0" "$(jv "$OUT" 'd["valid"]')/$(jv "$OUT" 'd["failed"]')/$(jv "$OUT" 'd["missing"]')"
check "status: per-scope state" "failed" "$(jv "$OUT" 'd["scopes"]["CR-2-02"]')"

run EXHAUSTIVE_AUDIT_NOW=20261010T140000Z finalize "$R1"
check "finalize exits 0" "0" "$RC"
check_contains "finalize: a failed scope makes the run PARTIAL, named" "EXHAUSTIVE-AUDIT PARTIAL — not reviewed: CR-2-02" "$OUT"
F1="$DATA/runs/$R1/findings.json"
check "finalize: the same finding from six scopes is merged into one" "1" "$(jfile "$F1" 'len(d["findings"])')"
check "finalize: a merged finding keeps the highest severity" "critical" "$(jfile "$F1" 'd["findings"][0]["severity"]')"
check "finalize: a merged finding keeps the union of its evidence" '[["api/requirements.txt", 1], ["api/requirements.txt", 9]]' "$(jfile "$F1" '[[e["path"], e["line"]] for e in d["findings"][0]["evidence"]]')"
check "finalize: the scope map" '{"CR-2-01": "valid", "CR-2-02": "failed", "CR-2-03": "valid", "D2-architecture": "valid", "D3-domain": "valid", "D4-operations": "valid", "PH-2": "valid"}' "$(jfile "$F1" 'd["scopes"]')"
check "finalize: coverage counts the lines of valid code scopes only" '{"api": {"lines_reviewed": 14, "lines_total": 23}}' "$(jfile "$F1" 'd["coverage"]')"
check "finalize: the banner field" "PARTIAL" "$(jfile "$F1" 'd["banner"]')"
check "finalize: the fingerprint is 8 hex characters" "8" "$(jfile "$F1" 'len(d["findings"][0]["fp"])')"
check "finalize: a module finding gets an M id" "M1-1" "$(jfile "$F1" 'd["findings"][0]["id"]')"
check_contains "finalize: not_reviewed names the failed scope" "CR-2-02" "$(jfile "$F1" 'd["not_reviewed"]')"

# The finding schema: one case per rule, on a fresh run of the same plan.
vcase() {
    # vcase <case> <expected exit> <expected output prefix> [<scope>]
    local scope="${4:-D2-architecture}"
    python3 "$SB/mk.py" "$DATA/runs/$R2/results/$scope.json" "$R2" "$scope" "$1"
    run validate "$R2" "$scope"
    check "validate $1: exit $2" "$2" "$RC"
    check_prefix "validate $1: $3" "$3" "$OUT"
}
vcase valid 0 "VALID 1 findings"
vcase top_unknown 2 "INVALID:"
vcase no_header 2 "INVALID:"
vcase run_mismatch 2 "INVALID:"
vcase scope_mismatch 2 "INVALID:"
vcase header_unknown 2 "INVALID:"
vcase files_negative 2 "INVALID:"
vcase lines_bool 2 "INVALID:"
vcase notes_overlong 0 "VALID-OVERLONG"
vcase notes_too_long 2 "INVALID:"
vcase not_reviewed_bad 2 "INVALID:"
vcase finding_unknown 2 "INVALID:"
vcase dim_zero 2 "INVALID:"
vcase dim_six 2 "INVALID:"
vcase dim_string 2 "INVALID:"
vcase dim_bool 2 "INVALID:"
vcase module_unknown 2 "INVALID:"
vcase module_null 0 "VALID 1 findings"
vcase check_pattern 2 "INVALID:"
vcase check_overlong 0 "VALID-OVERLONG"
vcase check_too_long 2 "INVALID:"
vcase subject_missing 2 "INVALID:"
vcase subject_empty 2 "INVALID:"
vcase severity_bad 2 "INVALID:"
vcase category_too_long 2 "INVALID:"
vcase finding_too_long 2 "INVALID:"
vcase rationale_overlong 0 "VALID-OVERLONG"
vcase rationale_too_long 2 "INVALID:"
vcase recommendation_too_long 2 "INVALID:"
vcase effort_bad 2 "INVALID:"
vcase risk_bad 2 "INVALID:"
vcase evidence_empty 2 "INVALID:"
vcase evidence_six 2 "INVALID:"
vcase evidence_absolute 2 "INVALID:"
vcase evidence_dotdot 2 "INVALID:"
vcase evidence_tilde 2 "INVALID:"
vcase evidence_drive 2 "INVALID:"
vcase evidence_config 0 "VALID 1 findings"
vcase evidence_line_negative 2 "INVALID:"
vcase evidence_line_bool 2 "INVALID:"
vcase evidence_unknown 2 "INVALID:"
vcase evidence_not_list 2 "INVALID:"
vcase questions_four 2 "INVALID:"
vcase question_too_long 2 "INVALID:"
vcase questions_not_list 2 "INVALID:"
vcase questions_absent 0 "VALID 1 findings"
vcase control_char 2 "INVALID:"
vcase newline_in_subject 2 "INVALID:"
vcase bidi_override 2 "INVALID:"
vcase findings_40 0 "VALID 40 findings"
vcase findings_41 2 "INVALID:"
vcase findings_60 0 "VALID 60 findings" CR-2-01
vcase findings_61 2 "INVALID:" CR-2-01
vcase findings_not_list 2 "INVALID:"
vcase not_json 2 "INVALID:"
vcase array_top 2 "INVALID:"
python3 "$SB/mk.py" "$DATA/runs/$R2/results/D2-architecture.json" "$R2" D2-architecture top_unknown
run validate "$R2" D2-architecture
check_contains "INVALID names the unknown field" "summary" "$OUT"
vcase secret 0 "VALID 1 findings"
check_contains "validate reports how many secret-shaped values it masked" "masked 1" "$OUT"
check_absent "validate masks the secret in place" "$SECRET" "$(cat "$DATA/runs/$R2/results/D2-architecture.json")"
check_contains "... keeping its first 4 and last 4 characters" "$MASKED_SECRET" "$(cat "$DATA/runs/$R2/results/D2-architecture.json")"

# Every token family the masker knows, one finding each. The tokens are assembled from fragments at run
# time and compared in python, so neither this file nor the suite's output ever holds one.
cat > "$SB/secrets.py" <<'PY'
# secrets.py write <result> <expected> <run> <scope> | check <result> <expected>
import json, sys
FAMILIES = [
    ("aws-access-key", "AK" + "IA" + "Z9Y8X7W6V5U4T3S2"),
    ("aws-session-key", "AS" + "IA" + "Q1W2E3R4T5Y6U7I8"),
    ("github-classic", "gh" + "p_" + "aB3dE5" * 6),
    ("github-server", "gh" + "s_" + "Zx9Yw8" * 6),
    ("github-fine-grained", "github" + "_pat_" + "11AbCdEf" * 4),
    ("slack", "xo" + "xb-" + "1234-5678-abcdEFGH"),
    ("stripe", "sk" + "_live_" + "Ab3De5Gh7Jk9Mn2P"),
    ("google", "AI" + "za" + "Ab3" * 11 + "Xy"),
    ("anthropic", "sk" + "-ant-" + "api03-" + "Ab3_" * 6),
    ("openai-project", "sk" + "-proj-" + "Cd4-" * 6 + "Zz9"),
    ("openai-legacy", "sk" + "-" + "Ef5Gh6" * 6),
    ("hugging-face", "hf" + "_" + "Jk7Lm8" * 6),
    ("nvidia", "nv" + "api-" + "Pq9_Rs1-" * 4),
    ("gitlab", "gl" + "pat-" + "Tu2Vw3-" * 3),
    ("jwt", "ey" + "J" + "hbGciOiJIUzI1" + "." + "eyJzdWIiOiIxMjM0" + "." + "SflKxwRJSMeKKF2Q"),
    ("private-key-header", "-----BEGIN RSA " + "PRIVATE" + " KEY-----"),
]
ASSIGNMENTS = [
    ("assigned-token", "token = ", "Ab12Cd34Ef56Gh78Ij90"),
    ("assigned-api-key", "api_key: ", "Kl12Mn34Op56Qr78"),
    ("assigned-password", "password=", "St12Uv34Wx56Yz78Ab"),
    ("assigned-client-secret", "\"client_secret\": \"", "Cd12Ef34Gh56Ij78Kl"),
    ("assigned-access-key", "access-key = ", "Mn12Op34Qr56St78Uv"),
]
LETTERS_ONLY = ("letters-only", "secret = ", "abcdefghijklmnopqrstuv")

def mask(value):
    return value[:4] + "****" + value[-4:]

def cases():
    for family, token in FAMILIES:
        yield family, "The value %s leaked." % token, token, mask(token)
    for family, name, value in ASSIGNMENTS:
        yield family, name + value, value, name + mask(value)
    family, name, value = LETTERS_ONLY
    yield family, name + value, value, None

if sys.argv[1] == "write":
    result, expected, run, scope = sys.argv[2:6]
    findings = []
    for number, (family, text, raw, masked) in enumerate(cases()):
        findings.append({"dim": 2, "module": "api", "check": "S1", "subject": "family-%d" % number, "severity": "high",
                         "category": "secrets", "finding": "A secret-shaped value", "rationale": text,
                         "recommendation": "Rotate it.", "effort": "S", "risk": "high",
                         "evidence": [{"path": "api/.env", "line": number + 1}]})
    with open(result, "w") as handle:
        json.dump({"header": {"run": run, "scope": scope, "agent": "reviewer", "files_reviewed": 1, "lines_reviewed": 1},
                   "findings": findings}, handle)
    with open(expected, "w") as handle:
        json.dump([[family, raw, masked] for family, _, raw, masked in cases()], handle)
else:
    result, expected = sys.argv[2:4]
    text = "\n".join(finding["rationale"] for finding in json.load(open(result))["findings"])
    for family, raw, masked in json.load(open(expected)):
        if masked is None:
            print("%s kept=%s" % (family, "yes" if raw in text else "no"))
        else:
            print("%s gone=%s masked=%s" % (family, "no" if raw in text else "yes", "yes" if masked in text else "no"))
PY
python3 "$SB/secrets.py" write "$DATA/runs/$R2/results/D3-domain.json" "$SB/secrets-expected.json" "$R2" D3-domain
run validate "$R2" D3-domain
check "validate masks every token family and assignment it knows" "VALID 22 findings|masked 21 secret-shaped value(s) in place" "$(printf '%s\n' "$OUT" | paste -sd '|' -)"
while read -r family gone masked; do
    case "$family" in
        letters-only) check "the masker leaves a letters-only assigned value alone" "kept=yes" "$gone" ;;
        *) check "the masker hides $family: the raw value is gone, first 4 + **** + last 4 remain" "gone=yes masked=yes" "$gone $masked" ;;
    esac
done <<EOF
$(python3 "$SB/secrets.py" check "$DATA/runs/$R2/results/D3-domain.json" "$SB/secrets-expected.json")
EOF
run validate "$R2" PH-2
check "validate: a scope with no saved result is a precondition error" "1" "$RC"
python3 "$SB/tx.py" "$SB/t-r2-prose.jsonl" plain "AUDIT-RUN: $R2 CR-2-02" "I could not finish the review."
run save-result "$R2" CR-2-02 "$SB/t-r2-prose.jsonl"
check "a reply with no JSON object is a problem (exit 2), never an empty result" "2" "$RC"
check "... it is an invalid attempt, and no result file is left behind" "invalid/absent" "$(jfile "$DATA/runs/$R2/results/CR-2-02.state" 'd["state"]')/$( [ -e "$DATA/runs/$R2/results/CR-2-02.json" ] && echo present || echo absent )"
python3 "$SB/mk.py" "$SB/r2-cr3.json" "$R2" CR-2-03 valid
python3 "$SB/tx.py" "$SB/t-r2-notes.jsonl" plain "AUDIT-RUN: $R2 CR-2-03" "SKIPPED: one page asked to be fetched again {\"twice\": true}
$(printf '```json\n%s\n```' "$(cat "$SB/r2-cr3.json")")"
run save-result "$R2" CR-2-03 "$SB/t-r2-notes.jsonl"
check "prose lines before a fenced json block are tolerated" "0" "$RC"
check_contains "... and handed back as notes" "note before the JSON: SKIPPED: one page asked to be fetched again" "$OUT"
run validate "$R2" CR-2-03
check "... and the result object after them is the result, not a JSON object inside the prose" "VALID 1 findings" "$OUT"
python3 "$SB/mk.py" "$DATA/runs/$R2/results/D4-operations.json" "$R2" D4-operations ten_errors
run validate "$R2" D4-operations
check "validate with ten schema errors: exit 2" "2" "$RC"
check "... names the first eight reasons" "8" "$(printf '%s' "$OUT" | sed -e 's/^INVALID: //' -e 's/ (and [0-9]* more)$//' | awk -F'; ' '{ print NF }')"
check_contains "... and counts the rest" "(and 2 more)" "$OUT"

# Crash-safety on resume: a state file cut short never loses its scope, and a plan.json cut short stops
# every run command with a reason instead of a traceback.
python3 "$SB/tx.py" "$SB/t-r3-d2.jsonl" handback "AUDIT-RUN: $R3 D2-architecture" "$(python3 "$SB/mk.py" - "$R3" D2-architecture valid)"
run save-result "$R3" D2-architecture "$SB/t-r3-d2.jsonl"
run validate "$R3" D2-architecture
run next-wave "$R3"
check "a valid scope is not offered again" "false" "$(jv "$OUT" '"D2-architecture" in [x["scope_id"] for x in d["dispatches"]]')"
printf '{"attempts": 1, "sta' > "$DATA/runs/$R3/results/D2-architecture.state"
run next-wave "$R3"
check "a state file cut short counts as not yet saved: next-wave offers the scope again" "true" "$(jv "$OUT" '"D2-architecture" in [x["scope_id"] for x in d["dispatches"]]')"
check_contains "... with a warning that names it" "the state of D2-architecture could not be read" "$ERR"
cp "$DATA/runs/$R3/plan.json" "$SB/plan-r3.saved"
printf '{"root_name": "ws", "scop' > "$DATA/runs/$R3/plan.json"
run next-wave "$R3"
check "a plan.json cut short stops a run command (exit 1)" "1" "$RC"
check_contains "... saying the plan is not valid JSON" "the plan of run $R3 is not valid JSON" "$ERR"
cp "$SB/plan-r3.saved" "$DATA/runs/$R3/plan.json"

# Another user's home folder is redacted wherever it appears: after file://, as /root, and under a WSL
# mount. Note lines before the JSON pass through the same cleaning as every printed text.
{
    printf 'see file://%salice/x\nsee file://%sbob/y\nsee /root/.ssh/z\nsee /mnt/c/%scarol/w\n' "$USERS_DIR" "$LINUX_HOME_DIR" "Use""rs/"
    python3 "$SB/mk.py" - "$R3" D3-domain valid
} | ea save-result "$R3" D3-domain - > "$SB/.out" 2> "$SB/.err"
OUT="$(cat "$SB/.out")"
check_contains "a macOS home folder after file:// is redacted" "note before the JSON: see file://~/x" "$OUT"
check_contains "... a Linux one too" "note before the JSON: see file://~/y" "$OUT"
check_contains "/root is a home folder" "note before the JSON: see ~/.ssh/z" "$OUT"
check_contains "... and so is a Windows home under a WSL mount" "note before the JSON: see ~/w" "$OUT"
for name in alice bob carol; do
    check_absent "... no user name survives ($name)" "$name" "$OUT"
done

# A write that fails never leaves its scratch file behind, and the ERROR names the file being written.
mkdir "$DATA/runs/$R1/agenda.md"
run agenda "$R1"
check "a file agenda cannot write stops it (exit 1)" "1" "$RC"
check_contains "... naming the file it was writing, not its scratch copy" "ERROR agenda: IsADirectoryError on <config>/exhaustive-audit-and-review/runs/$R1/agenda.md:" "$ERR"
check "... and leaving no scratch file behind" "0" "$(ls -A "$DATA/runs/$R1" | grep -c '\.tmp\.')"
rmdir "$DATA/runs/$R1/agenda.md"

# ---------------------------------------------------------------------------
# 7. scrub-check (fails closed)
# ---------------------------------------------------------------------------
printf 'Q01 · asked by 1a2b3c4d · Is the flask 2.0 line still supported upstream?\n' > "$SB/agenda-clean.md"
printf 'Q01 · fine\nQ02 · How does globex price its plans?\n' > "$SB/agenda-term.md"
printf 'Q01 · What does initech publish?\n' > "$SB/agenda-term2.md"
printf 'Q01 · See %ssomeone/x.md\n' "$USERS_DIR" > "$SB/agenda-path.md"
printf 'Q01 · fine\nQ02 · Read ~/notes first\nQ03 · and %ssomeone/x\nQ04 · and C:\\work\\y\n' "$LINUX_HOME_DIR" > "$SB/agenda-paths.md"
printf 'Q01 · Write to %s\n' "someone@""example.com" > "$SB/agenda-email.md"
printf '# only comments and a short term\nabc\n\n' > "$SB/deny-empty.txt"
printf 'Wonka\n' > "$SB/deny-a.txt"
printf 'Acme\n' > "$SB/deny-b.txt"

run scrub-check "$SB/agenda-clean.md"
check "scrub-check: a clean agenda exits 0" "0" "$RC"
check "scrub-check: ... and says CLEAN" "CLEAN" "$OUT"
check_contains "scrub-check: ... and counts the too-short term it ignored" "1 denylist term(s) under 4 characters ignored" "$ERR"
check_absent "scrub-check: ... without ever printing it" "abc" "$OUT$ERR"
run scrub-check "$SB/agenda-term.md"
check "scrub-check: a term from the data dir denylist exits 2" "2" "$RC"
check_contains "scrub-check: ... names the line" "line 2: private term" "$OUT"
check_absent "scrub-check: ... never prints the term (any case)" "lobex" "$OUT$ERR"
run scrub-check "$SB/agenda-term2.md"
check "scrub-check: a term from the new-functionality denylist (the union) exits 2" "2" "$RC"
check_absent "scrub-check: ... never prints that term either" "nitech" "$OUT$ERR"
run scrub-check "$SB/agenda-path.md"
check "scrub-check: a home path exits 2" "2" "$RC"
check_contains "scrub-check: ... as an absolute path" "line 1: absolute path" "$OUT"
run scrub-check "$SB/agenda-paths.md"
check "scrub-check: ~/, /home/ and C:\\ paths are flagged" "3" "$(printf '%s\n' "$OUT" | grep -c 'absolute path')"
# The other home spellings the report redaction knows (/root, a WSL drive mount, a file:// URL) must not
# reach the web either, while a web page's own /home/ or /root/ path is not a local path.
printf 'Q01 · Read %ssomeone/x\nQ02 · and /mnt/c%ssomeone/y\nQ03 · and file://%ssomeone/z\nQ04 · fine: https://example.com%spage and https://example.org%sx\n' \
    "/ro""ot/" "$USERS_DIR" "$USERS_DIR" "$LINUX_HOME_DIR" "/ro""ot/" > "$SB/agenda-paths2.md"
run scrub-check "$SB/agenda-paths2.md"
check "scrub-check: /root/, WSL /mnt/<drive>/Users/ and file:// home paths are flagged; a web URL's path is not" \
    "1,2,3" "$(printf '%s\n' "$OUT" | sed -n 's/^line \([0-9]*\): absolute path$/\1/p' | paste -sd, -)"
run scrub-check "$SB/agenda-email.md"
check "scrub-check: an email address exits 2" "2" "$RC"
check_contains "scrub-check: ... as an email" "line 1: email" "$OUT"
check_absent "scrub-check: ... never prints the address" "example.com" "$OUT$ERR"
run EXHAUSTIVE_AUDIT_DENYLIST="$SB/no-such-denylist.txt" scrub-check "$SB/agenda-clean.md"
check "scrub-check fails closed: no denylist file at all exits 3" "3" "$RC"
check_contains "scrub-check: ... BLOCKED" "BLOCKED: no denylist terms" "$OUT$ERR"
run EXHAUSTIVE_AUDIT_DENYLIST="$SB/deny-empty.txt" scrub-check "$SB/agenda-clean.md"
check "scrub-check fails closed: a denylist with no usable term exits 3" "3" "$RC"
check_contains "scrub-check: ... and BLOCKED states the 4-character floor" "a term needs at least 4 characters; 1 shorter term(s) ignored" "$OUT"
check_absent "scrub-check: ... never printing the short term" "abc" "$OUT$ERR"
run CLAUDE_CONFIG_DIR="$SB/cfg3" scrub-check "$SB/agenda-clean.md"
check "scrub-check fails closed: a config with no denylist at all exits 3" "3" "$RC"
printf 'Q01 · About acme\nQ02 · About wonka\n' > "$SB/agenda-ab.md"
run EXHAUSTIVE_AUDIT_DENYLIST="$SB/deny-a.txt:$SB/deny-b.txt" scrub-check "$SB/agenda-ab.md"
check "scrub-check: EXHAUSTIVE_AUDIT_DENYLIST is a colon-separated list" "2/2" "$RC/$(printf '%s\n' "$OUT" | grep -c 'private term')"
run scrub-check "$SB/no-such-agenda.md"
check "scrub-check: a missing file is a usage error" "1" "$RC"

# The dispatched agents load the RUNNING session's instruction files, so its denylists count even when
# another config folder is the one under audit; the companion's relocated folder counts too.
DENY_RT="$SB/deny-runtime"
DENY_AUD="$SB/deny-audited"
mkdir -p "$DENY_RT/exhaustive-audit-and-review" "$DENY_RT/claude-code-new-functionality-check" \
         "$DENY_AUD/exhaustive-audit-and-review" "$SB/nfc-override"
printf 'Vandelay\n' > "$DENY_RT/exhaustive-audit-and-review/denylist.txt"
printf 'Kramerica\n' > "$DENY_RT/claude-code-new-functionality-check/denylist.txt"
printf 'Pendant\n' > "$DENY_AUD/exhaustive-audit-and-review/denylist.txt"
printf 'Brisket\n' > "$SB/nfc-override/denylist.txt"
printf 'Q01 · Who imports vandelay latex?\n' > "$SB/agenda-rt-data.md"
printf 'Q01 · What does kramerica build?\n' > "$SB/agenda-rt-nfc.md"
printf 'Q01 · How long is brisket smoked?\n' > "$SB/agenda-override.md"
run "EXHAUSTIVE_AUDIT_RUNTIME_CONFIG=$DENY_RT" scrub-check "$SB/agenda-rt-data.md" --config-dir "$DENY_AUD"
check "scrub-check: a term only the running session's data denylist holds blocks, while another config is audited" "2" "$RC"
run "EXHAUSTIVE_AUDIT_RUNTIME_CONFIG=$DENY_RT" scrub-check "$SB/agenda-rt-nfc.md" --config-dir "$DENY_AUD"
check "scrub-check: ... and so does a term from its companion's denylist" "2" "$RC"
check_absent "scrub-check: ... never printing either term" "andelay" "$OUT$ERR"
run "CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR=$SB/nfc-override" scrub-check "$SB/agenda-override.md"
check "scrub-check: the companion's relocated denylist (CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR) is read" "2" "$RC"
run "EXHAUSTIVE_AUDIT_RUNTIME_CONFIG=$DENY_RT" "EXHAUSTIVE_AUDIT_DENYLIST=$SB/deny-a.txt" scrub-check "$SB/agenda-rt-data.md" --config-dir "$DENY_AUD"
check "scrub-check: EXHAUSTIVE_AUDIT_DENYLIST still replaces every list, the running session's included" "0/CLEAN" "$RC/$OUT"
if [ "$(id -u)" = "0" ]; then
    echo "SKIP-LOUD: running as root, which can read a chmod 000 denylist, so the unreadable-denylist cases cannot run"
else
    printf 'Locked\n' > "$SB/deny-locked.txt"
    chmod 000 "$SB/deny-locked.txt"
    run "EXHAUSTIVE_AUDIT_DENYLIST=$SB/deny-a.txt:$SB/deny-locked.txt" scrub-check "$SB/agenda-clean.md"
    check "scrub-check: a denylist that exists but cannot be read blocks (exit 3)" "3" "$RC"
    check_prefix "scrub-check: ... as BLOCKED" "BLOCKED" "$OUT"
    check_contains "scrub-check: ... naming that list" "deny-locked.txt" "$OUT"
    check_absent "scrub-check: ... never CLEAN" "CLEAN" "$OUT"
    chmod 000 "$DENY_RT/exhaustive-audit-and-review/denylist.txt"
    run "EXHAUSTIVE_AUDIT_RUNTIME_CONFIG=$DENY_RT" scrub-check "$SB/agenda-clean.md" --config-dir "$DENY_AUD"
    check "scrub-check: an unreadable list in the default union blocks too (exit 3)" "3" "$RC"
    check_contains "scrub-check: ... named by its placeholder path" "<runtime>/exhaustive-audit-and-review/denylist.txt" "$OUT"
    check_absent "scrub-check: ... with no term from any list" "andelay" "$OUT$ERR"
    chmod 600 "$SB/deny-locked.txt" "$DENY_RT/exhaustive-audit-and-review/denylist.txt"
    # Any file the helper cannot read or write: the ERROR names the subcommand and the file, relativized.
    printf 'Q01 · a question\n' > "$CFG/locked-agenda.md"
    chmod 000 "$CFG/locked-agenda.md"
    run scrub-check "$CFG/locked-agenda.md"
    check "a file that cannot be read stops the subcommand (exit 1)" "1" "$RC"
    check_contains "... with an ERROR naming the subcommand and the file" "ERROR scrub-check: PermissionError on <config>/locked-agenda.md: Permission denied" "$ERR"
    check_absent "... never by an absolute path" "$SB" "$ERR"
    chmod 600 "$CFG/locked-agenda.md"
fi

# ---------------------------------------------------------------------------
# 8. Two finalized runs: IDs, banner, report numbering, research, diff, lookup
# ---------------------------------------------------------------------------
FIN="$SB/fin"
mkdir -p "$FIN/api/src" "$FIN/web"
printf '| Module |\n|---|\n| web |\n| api |\n' > "$FIN/MODULES.md"
printf 'requests==2.31.0\nflask>=2.0\n' > "$FIN/api/requirements.txt"
lines "$FIN/api/src/util.py" 3
lines "$FIN/api/src/handlers.py" 3
lines "$FIN/api/src/sql_query.py" 4
git_init "$FIN/api"
git_commit_all "$FIN/api" "initial" "$T1"
printf '{"name": "web"}\n' > "$FIN/web/package.json"
DF="$SB/data-fin"
mkdir -p "$DF"
printf 'RESEARCH_BUDGET=3\n' > "$DF/house.conf"

cat > "$SB/scen.py" <<'PY'
# scen.py <results-dir> <run> <A|B> <root> <home> — the agent results of two runs of one workspace.
import json, os, sys
results, run, phase, root, home = sys.argv[1:6]
Q_REQ = "Which published advisories affect requests 2.31?"
Q_FLASK = "Is the flask 2.0 line still supported upstream?"
Q_ENV = "How should env files be kept out of version control?"
Q_INFO = "What does an informational finding cost to keep?"

def finding(dim, module, check, subject, severity, path, line, questions=(), text=None, rationale=None):
    return {"dim": dim, "module": module, "check": check, "subject": subject, "severity": severity,
            "category": "general", "finding": text or ("%s needs attention" % subject),
            "rationale": rationale or "It matters for maintainability.", "recommendation": "Fix it.",
            "effort": "S", "risk": "med", "evidence": [{"path": path, "line": line}],
            "research_questions": list(questions)}

def write(scope, agent, findings):
    doc = {"header": {"run": run, "scope": scope, "agent": agent, "files_reviewed": 1, "lines_reviewed": 10,
                      "notes": "", "not_reviewed": []}, "findings": findings}
    with open(os.path.join(results, scope + ".json"), "w") as handle:
        json.dump(doc, handle)

if phase == "A":
    write("D2-architecture", "architecture", [finding(2, "api", "A1", "requests", "high", "api/requirements.txt", 1, [Q_REQ]),
                                              finding(2, None, "A9", "shared helper", "low", "MODULES.md", 1)])
    write("D3-domain", "domain", [finding(3, "api", "D2", "flask", "medium", "api/requirements.txt", 2, [Q_FLASK])])
    write("D4-operations", "operations", [finding(4, "web", "O4", "ci", "medium", "web/package.json", 1),
                                          finding(4, "api", "O7", "timeouts", "medium", "api/src/util.py", 1),
                                          finding(4, "api", "O8", "logging", "low", "api/src/handlers.py", 2),
                                          finding(4, "api", "O9", "old subject", "info", "api/src/sql_query.py", 3)])
    write("PH-1", "project-health", [])
    write("PH-2", "project-health", [])
else:
    reworded = finding(2, "api", "A1", "Requests", "high", "api/requirements.txt", 1, [Q_REQ],
                       text="requests lags the current release by a wide margin",
                       rationale="Seen in %s/api/requirements.txt and noted in %s/notes.txt." % (root, home))
    write("D2-architecture", "architecture", [reworded, finding(2, "svc", "A2", "manifest", "low", "svc/package.json", 1)])
    write("D3-domain", "domain", [finding(3, "api", "D2", "flask", "critical", "api/requirements.txt", 2, [Q_FLASK])])
    write("D4-operations", "operations", [finding(4, "web", "O4", "ci", "low", "web/package.json", 1,
                                                  ["which published advisories affect   requests 2.31?"]),
                                          finding(4, "api", "O9", "new subject", "info", "api/src/sql_query.py", 3, [Q_INFO]),
                                          finding(4, "api", "O1", "secrets", "critical", "api/.env", 1, [Q_ENV])])
    write("PH-1", "project-health", [])
    write("PH-2", "project-health", [])
PY

runf() { run "EXHAUSTIVE_AUDIT_DIR=$DF" "$@"; }
idof() { jfile "$1" "[f['id'] for f in d['findings'] if f['subject'] == '$2'][0]"; }
fpof() { jfile "$1" "[f['fp'] for f in d['findings'] if f['subject'] == '$2'][0]"; }

runf plan --root "$FIN" --scope workspace
printf '%s' "$OUT" > "$SB/plan-fin-a.json"
runf EXHAUSTIVE_AUDIT_NOW=20260101T000000Z init-run --plan "$SB/plan-fin-a.json" --root "$FIN"
RUN_A="$(first_line "$OUT")"
python3 "$SB/scen.py" "$DF/runs/$RUN_A/results" "$RUN_A" A "$FIN" "$FAKE_HOME"
for scope in D2-architecture D3-domain D4-operations PH-1 PH-2; do runf validate "$RUN_A" "$scope"; done
runf EXHAUSTIVE_AUDIT_NOW=20260101T000000Z finalize "$RUN_A"
check "run A: finalize exits 0" "0" "$RC"
check_contains "run A: every scope valid makes it COMPLETE" "EXHAUSTIVE-AUDIT COMPLETE" "$OUT"
check_contains "run A: the report path is printed, relative to its placeholder" "report: <data>/runs/$RUN_A/exhaustive_audit_v1_20260101T000000Z.md" "$OUT"
FA="$DF/runs/$RUN_A/findings.json"
check "run A: module numbers follow the plan's module order" '{"api": 2, "web": 1}' "$(jfile "$FA" 'd["module_numbers"]')"
check "run A: IDs are content-ordered within each prefix" "M2-1 M2-2 M2-3 M2-4 M2-5 M1-1 W-1" "$(idof "$FA" requests) $(idof "$FA" flask) $(idof "$FA" timeouts) $(idof "$FA" logging) $(idof "$FA" 'old subject') $(idof "$FA" ci) $(idof "$FA" 'shared helper')"
check "run A: the banner field" "COMPLETE" "$(jfile "$FA" 'd["banner"]')"
REPORT_A="$DF/runs/$RUN_A/exhaustive_audit_v1_20260101T000000Z.md"
check "run A: the report is written in the run folder" "yes" "$( [ -f "$REPORT_A" ] && echo yes || echo no )"
check_contains "run A report: the banner line" "EXHAUSTIVE-AUDIT COMPLETE" "$(cat "$REPORT_A" 2>/dev/null)"
check_contains "run A report: the triage index columns" "| ID | Hash | Sev | Dim | Module | Check | Finding | Effort | Risk |" "$(cat "$REPORT_A" 2>/dev/null)"
check_contains "run A report: the native tools section names /code-review ultra" "/code-review ultra" "$(cat "$REPORT_A" 2>/dev/null)"
check_contains "run A report: ... and /doctor" "/doctor" "$(cat "$REPORT_A" 2>/dev/null)"
check_contains "run A report: a Not reviewed section" "Not reviewed" "$(cat "$REPORT_A" 2>/dev/null)"
check_contains "run A report: a coverage table" "Coverage" "$(cat "$REPORT_A" 2>/dev/null)"

# Run B: the registry order flips, a module is added, one scope never reports.
printf '| Module |\n|---|\n| api |\n| web |\n' > "$FIN/MODULES.md"
mkdir -p "$FIN/svc"
printf '{"name": "svc"}\n' > "$FIN/svc/package.json"
runf plan --root "$FIN" --scope workspace
printf '%s' "$OUT" > "$SB/plan-fin-b.json"
runf EXHAUSTIVE_AUDIT_NOW=20260201T000000Z init-run --plan "$SB/plan-fin-b.json" --root "$FIN"
RUN_B="$(first_line "$OUT")"
RB="$DF/runs/$RUN_B"
for name in exhaustive_audit_v9_20250101T000000Z.md exhaustive_audit_v10_20250102T000000Z.md \
            exhaustive_audit_v12_20250103T000000Z_errors.md exhaustive_audit_v13_progress.md \
            exhaustive_audit_claude_system_v40_20250101T000000Z.md; do
    printf 'old report\n' > "$RB/$name"
done
python3 "$SB/scen.py" "$RB/results" "$RUN_B" B "$FIN" "$FAKE_HOME"
for scope in D2-architecture D3-domain D4-operations PH-1 PH-2; do runf validate "$RUN_B" "$scope"; done
runf EXHAUSTIVE_AUDIT_NOW=20260201T000000Z finalize "$RUN_B"
check "run B: finalize exits 0" "0" "$RC"
check_contains "run B: a missing scope makes it PARTIAL, named" "EXHAUSTIVE-AUDIT PARTIAL — not reviewed: PH-3" "$OUT"
FB="$RB/findings.json"
check "regression: report numbers sort numerically (v10 > v9), other names ignored" "yes" "$( [ -f "$RB/exhaustive_audit_v11_20260201T000000Z.md" ] && echo yes || echo no )"
REPORT_B="$RB/exhaustive_audit_v11_20260201T000000Z.md"
check "IDs: the fingerprint survives a reworded finding and rationale" "$(fpof "$FA" requests)" "$(fpof "$FB" Requests)"
check "IDs: the reworded finding keeps its ID" "$(idof "$FA" requests)" "$(idof "$FB" Requests)"
check "IDs: module numbers are reused although the registry order changed" '{"api": 2, "svc": 3, "web": 1}' "$(jfile "$FB" 'd["module_numbers"]')"
check "IDs: a new module gets the next free number" "M3-1" "$(idof "$FB" manifest)"
check "IDs: a new finding takes the next free number in its module" "M2-6" "$(idof "$FB" secrets)"
check "IDs: a regressed finding keeps its ID" "$(idof "$FA" flask)" "$(idof "$FB" flask)"
check "IDs: an improved finding keeps its ID" "$(idof "$FA" ci)" "$(idof "$FB" ci)"
check "run B: the banner field" "PARTIAL" "$(jfile "$FB" 'd["banner"]')"
check "run B: scope states" '{"D2-architecture": "valid", "D3-domain": "valid", "D4-operations": "valid", "PH-1": "valid", "PH-2": "valid", "PH-3": "missing"}' "$(jfile "$FB" 'd["scopes"]')"
check_contains "run B report: the banner line" "EXHAUSTIVE-AUDIT PARTIAL — not reviewed: PH-3" "$(cat "$REPORT_B" 2>/dev/null)"
check_contains "run B report: a root path in prose is made relative" "Seen in api/requirements.txt" "$(cat "$REPORT_B" 2>/dev/null)"
check_contains "run B report: a home path in prose becomes ~" "noted in ~/notes.txt" "$(cat "$REPORT_B" 2>/dev/null)"
check_absent "run B report: no absolute sandbox path" "$SB" "$(cat "$REPORT_B" 2>/dev/null)"
check_absent "run B report: no unresolved sandbox path" "$SB_RAW" "$(cat "$REPORT_B" 2>/dev/null)"
check_absent "run B report: no home folder" "$USERS_DIR" "$(cat "$REPORT_B" 2>/dev/null)"
check_absent "run B findings.json: no absolute path either" "$SB" "$(cat "$FB" 2>/dev/null)"

# Research: agenda, scrub-check, the researcher's reply, attach-research.
runf agenda "$RUN_B"
check "agenda exits 0" "0" "$RC"
check "agenda prints its path" "<data>/runs/$RUN_B/agenda.md" "$OUT"
AGENDA="$(cat "$RB/agenda.md" 2>/dev/null)"
check_contains "agenda: Q01 is the first critical finding's question" "Q01" "$AGENDA"
check "agenda: the budget keeps 3 of the 4 distinct questions, critical first" "Is the flask 2.0 line still supported upstream?|How should env files be kept out of version control?|Which published advisories affect requests 2.31?" "$(printf '%s\n' "$AGENDA" | grep '^Q0' | sed 's/.* · //' | paste -sd '|' -)"
check_absent "agenda: the info question falls outside the budget" "informational" "$AGENDA"
check_contains "agenda: a question carries the fingerprint of the finding that asked it" "$(fpof "$FB" flask)" "$(printf '%s\n' "$AGENDA" | grep '^Q01')"
check_contains "agenda: a duplicate question is asked once, by both findings" "$(fpof "$FB" ci)" "$(printf '%s\n' "$AGENDA" | grep '^Q03')"
check_absent "agenda: no module name or path leaves in it" "api/" "$AGENDA"
runf scrub-check "<data>/runs/$RUN_B/agenda.md"
check "the agenda passes scrub-check (and <data>/ resolves)" "0/CLEAN" "$RC/$OUT"

mkdir -p "$SB/pages"
cat > "$SB/pages/flask.html" <<'EOF'
<!doctype html><html><head><title>Flask</title><script>var hidden = "a script is never page text";</script></head>
<body><p>Flask 2.0 reached   end of life
in 2023; upgrade to a supported release.</p></body></html>
EOF
cat > "$SB/leads.py" <<'PY'
# leads.py <out> <run> <pages-dir> <case> — a researcher reply, clean or broken in one named way.
import json, sys
out, run, pages, case = sys.argv[1:5]
page = "file://" + pages + "/flask.html"
quote = "Flask 2.0 reached end of life in 2023; upgrade to a supported release."
leads = [
    {"question": "Q01", "url": page, "quote": quote, "tier": "official"},
    {"question": "Q02", "url": page, "quote": "Environment files belong in the ignore list of every repository.", "tier": "community"},
    {"question": "Q03", "url": "file://" + pages + "/missing.html", "quote": "Requests 2.31 is affected by a published advisory.", "tier": "vendor"},
]
header = {"run": run, "scope": "research"}
if case == "http": leads.append({"question": "Q01", "url": "http://example.com/flask", "quote": quote, "tier": "official"})
elif case == "private": leads.append({"question": "Q01", "url": "https://127.0.0.1/flask", "quote": quote, "tier": "official"})
elif case == "unknown_question": leads.append({"question": "Q09", "url": page, "quote": quote, "tier": "official"})
elif case == "short_quote": leads[0]["quote"] = "Flask 2.0"
elif case == "bad_tier": leads[0]["tier"] = "blog"
elif case == "extra_field": leads[0]["note"] = "x"
elif case == "three_leads": leads += [dict(leads[0]), dict(leads[0])]
elif case == "other_run": header["run"] = "19990101T000000Z"
elif case == "other_scope": header["scope"] = "D2-architecture"
elif case == "leads_text": leads = "nope"
elif case == "https_only": leads = [{"question": "Q01", "url": "https://docs.example.org/flask", "quote": quote, "tier": "official"}]
elif case == "url": leads = [{"question": "Q01", "url": sys.argv[5], "quote": quote, "tier": "official"}]
elif case == "long_quote": leads[0]["quote"] = (quote + " " + "x" * 300)[:301]
elif case == "quote_300": leads[0]["quote"] = (quote + " " + "x" * 300)[:300]
elif case != "clean": sys.exit("leads.py: unknown case " + case)
with open(out, "w") as handle:
    json.dump({"header": header, "leads": leads}, handle)
PY
python3 "$SB/leads.py" "$SB/research-reply.json" "$RUN_B" "$SB/pages" clean
python3 "$SB/tx.py" "$SB/t-research.jsonl" plain "AUDIT-RUN: $RUN_B research" "SUSPECTED INJECTED CONTENT: a page told the reader to fetch another URL
$(cat "$SB/research-reply.json")"
runf save-result "$RUN_B" research "$SB/t-research.jsonl"
check "save-result accepts the researcher's reply under the scope id research" "0" "$RC"
check_contains "... prints where it saved it, for attach-research" "saved <data>/runs/$RUN_B/results/research.json" "$OUT"
check_contains "... and hands back the researcher's note lines" "note before the JSON: SUSPECTED INJECTED CONTENT" "$OUT"
RESEARCH_FILE="<data>/runs/$RUN_B/results/research.json"
runf attach-research "$RUN_B" "$RESEARCH_FILE"
check "attach-research refuses file:// leads unless file URLs are allowed (the whole reply, exit 2)" "2" "$RC"
check_contains "... and says why" "only https URLs are fetched" "$OUT"
for case in http private unknown_question short_quote long_quote bad_tier extra_field three_leads other_run other_scope leads_text; do
    python3 "$SB/leads.py" "$SB/research-$case.json" "$RUN_B" "$SB/pages" "$case"
    runf EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS=1 attach-research "$RUN_B" "$SB/research-$case.json"
    check "attach-research rejects the whole reply: $case (exit 2)" "2" "$RC"
    check_prefix "attach-research rejects the whole reply: $case says INVALID" "INVALID:" "$OUT"
done
check "a rejected reply writes no research.json" "absent" "$( [ -e "$RB/research.json" ] && echo present || echo absent )"
python3 "$SB/leads.py" "$SB/research-quote_300.json" "$RUN_B" "$SB/pages" quote_300
runf EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS=1 attach-research "$RUN_B" "$SB/research-quote_300.json"
check "a 300-character quote is within the cap (the reply is checked, then fetched)" "0" "$RC"
rm -f "$RB/research.json"
runf EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS=1 attach-research "$RUN_B" "$RESEARCH_FILE"
check "attach-research with file:// fixtures exits 0" "0" "$RC"
check_contains "attach-research counts every lead" "research: 1 verified, 1 unverified, 1 failed" "$OUT"
RJ="$RB/research.json"
check "research.json: the verified lead is attached to the finding that asked" "true" "$(jfile "$RJ" "[a['verified'] for a in d['attachments']['$(fpof "$FB" flask)']][0]")"
check "research.json: an unverified lead is recorded, but attached to nothing" "unverified/absent" "$(jfile "$RJ" "[l['status'] for l in d['leads'] if l['question'] == 'Q02'][0]")/$(jfile "$RJ" "'present' if '$(fpof "$FB" secrets)' in d['attachments'] else 'absent'")"
check "research.json: a failed fetch is recorded with its cause" "failed" "$(jfile "$RJ" "[l['status'] for l in d['leads'] if l['question'] == 'Q03'][0]")"

runf EXHAUSTIVE_AUDIT_NOW=20260201T000000Z finalize "$RUN_B"
check "re-finalize: the next report number" "yes" "$( [ -f "$RB/exhaustive_audit_v12_20260201T000000Z.md" ] && echo yes || echo no )"
check "re-finalize: IDs are stable" "M2-6/M3-1" "$(idof "$FB" secrets)/$(idof "$FB" manifest)"
check "re-finalize: research is attached to its finding, severity untouched" '[["official", true]]/critical' "$(jfile "$FB" "[[r['tier'], r['verified']] for r in [f for f in d['findings'] if f['subject'] == 'flask'][0]['research'] if r['verified']]")/$(jfile "$FB" "[f['severity'] for f in d['findings'] if f['subject'] == 'flask'][0]")"
REPORT_B2="$RB/exhaustive_audit_v12_20260201T000000Z.md"
check_contains "re-finalize report: a verified quote is shown" "Flask 2.0 reached end of life in 2023" "$(cat "$REPORT_B2" 2>/dev/null)"
check_absent "re-finalize report: an unverified quote is not shown as fact" "belong in the ignore list" "$(cat "$REPORT_B2" 2>/dev/null)"

# Diff: evidence makes RESOLVED, its absence makes DROPPED.
ID_D="$(idof "$FA" timeouts)"
ID_E="$(idof "$FA" logging)"
ID_W="$(idof "$FA" 'shared helper')"
printf '# apply-rec log\n\n| ID | Result | Note |\n|---|---|---|\n| %s | APPLIED | timeouts added |\n| %s | DECLINED | not now |\n' "$ID_D" "$ID_W" > "$DF/runs/$RUN_A/apply_rec_log_v1_20260115T000000Z.md"
printf 'more\n' >> "$FIN/api/src/handlers.py"
git_commit_all "$FIN/api" "fix: structured logging (closes $ID_E)"
runf diff
check "diff exits 0" "0" "$RC"
DIFF="$OUT"
check_contains "diff: defaults to the two latest finalized runs" "$RUN_A" "$DIFF"
for bucket in "NEW (2)" "RECURRING (1)" "REGRESSED (1)" "IMPROVED (1)" "RESOLVED (2)" "DROPPED (1)" "APPROXIMATE (1)"; do
    check_contains "diff bucket $bucket" "## $bucket" "$DIFF"
done
check_contains "diff: RESOLVED by an apply log" "apply log" "$(printf '%s\n' "$DIFF" | grep "| $ID_D |")"
check_contains "diff: RESOLVED by a commit that names the ID" "git commit" "$(printf '%s\n' "$DIFF" | grep "| $ID_E |")"
check_contains "diff: a finding gone without evidence is DROPPED" "| $ID_W |" "$(printf '%s\n' "$DIFF" | sed -n '/^## DROPPED/,/^## /p')"
check_contains "diff: an approximate match pairs the old and new IDs" "$(idof "$FA" 'old subject')" "$(printf '%s\n' "$DIFF" | sed -n '/^## APPROXIMATE/,$p')"
check "diff: the diff is written into the newer run" "yes" "$( [ -f "$RB/diff_vs_$RUN_A.md" ] && echo yes || echo no )"
check_absent "diff: no absolute path" "$SB" "$DIFF"
runf diff "$RUN_A" "$RUN_B"
check "diff with explicit runs: the same buckets" "$DIFF" "$OUT"
runf diff "$RUN_A" 19990101T000000Z
check "diff: an unknown run is a usage error" "1" "$RC"

# Lookup and status.
runf lookup "$(idof "$FB" secrets)"
check "lookup: a known ID exits 0" "0" "$RC"
check_prefix "lookup: a markdown block headed by the ID" "### $(idof "$FB" secrets)" "$OUT"
check_contains "lookup: it carries the hash" "$(fpof "$FB" secrets)" "$OUT"
check_contains "lookup: it carries the evidence" "api/.env:1" "$OUT"
check_contains "lookup: it names the run it used, and why that one" "$RUN_B (the latest finalized run" "$OUT"
runf lookup "$(fpof "$FB" secrets)"
check_prefix "lookup: a finding's hash finds it too" "### $(idof "$FB" secrets)" "$OUT"
runf lookup "$(idof "$FB" flask)"
check_contains "lookup: a verified research quote is shown" "Flask 2.0 reached end of life" "$OUT"
runf lookup "$ID_W"
check "lookup: an ID absent from the latest run exits 1" "1" "$RC"
runf lookup "$ID_W" --run "$RUN_A"
check "lookup --run: an older run" "0" "$RC"
check_contains "lookup --run: the block names that run" "$RUN_A (given with --run)" "$OUT"
runf lookup M9-99
check "lookup: an unknown ID exits 1" "1" "$RC"
runf status "$RUN_B"
check "status: counts and banner" "5/0/1/PARTIAL" "$(jv "$OUT" 'd["valid"]')/$(jv "$OUT" 'd["failed"]')/$(jv "$OUT" 'd["missing"]')/$(jv "$OUT" 'd["banner"]')"
runf status
check "status without a run: the latest run" "$RUN_B" "$(jv "$OUT" 'd["run"]')"
runf status 19990101T000000Z
check "status: an unknown run exits 1" "1" "$RC"
runf runs
check "runs: every run with its banner, oldest first" "[[\"$RUN_A\", \"COMPLETE\"], [\"$RUN_B\", \"PARTIAL\"]]" "$(jv "$OUT" '[[r["run"], r["banner"]] for r in d["runs"]]')"

# The fetch policy, offline: a stand-in curl fails on purpose. Transient errors are retried within the
# attempt limit, a permanent one is not, and a spent deadline stops before the first attempt.
mkdir -p "$SB/fakecurl"
cat > "$SB/fakecurl/curl" <<'STUB'
#!/bin/bash
# A stand-in for curl. Every call is counted in FAKE_CURL_COUNT, and its arguments are logged one line per
# call in FAKE_CURL_ARGV. The first FAKE_CURL_FAILS calls fail: with a connection error (exit 7), or with the
# HTTP status FAKE_CURL_FAIL_STATUS and, when FAKE_CURL_RETRY_AFTER is set, a Retry-After header.
# FAKE_CURL_STATUS fails every call with that status. The next FAKE_CURL_EMPTY calls answer 200 with an
# empty body; after that the page in FAKE_CURL_BODY. The landing URL is the one asked for, or FAKE_CURL_LANDING.
printf '%s\n' "$*" >> "${FAKE_CURL_ARGV:-/dev/null}"
out=""; hdr=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -D) hdr="$2"; shift 2 ;;
        -w|--connect-timeout|--max-time|--max-filesize|--proto|--proto-redir|--max-redirs) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
calls=$(( $(cat "$FAKE_CURL_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$calls" > "$FAKE_CURL_COUNT"
[ -n "$hdr" ] && : > "$hdr"
if [ -n "${FAKE_CURL_STATUS:-}" ]; then
    printf '%s %s' "$FAKE_CURL_STATUS" "$url"; echo "curl: (22) The requested URL returned error: $FAKE_CURL_STATUS" >&2; exit 22
fi
if [ "$calls" -le "${FAKE_CURL_FAILS:-0}" ]; then
    if [ -n "${FAKE_CURL_FAIL_STATUS:-}" ]; then
        if [ -n "$hdr" ]; then
            printf 'HTTP/1.1 %s Busy\r\n' "$FAKE_CURL_FAIL_STATUS" > "$hdr"
            [ -n "${FAKE_CURL_RETRY_AFTER:-}" ] && printf 'Retry-After: %s\r\n' "$FAKE_CURL_RETRY_AFTER" >> "$hdr"
        fi
        printf '%s %s' "$FAKE_CURL_FAIL_STATUS" "$url"; echo "curl: (22) The requested URL returned error: $FAKE_CURL_FAIL_STATUS" >&2; exit 22
    fi
    printf '000 %s' "$url"; echo "curl: (7) Failed to connect" >&2; exit 7
fi
if [ $(( calls - ${FAKE_CURL_FAILS:-0} )) -le "${FAKE_CURL_EMPTY:-0}" ]; then
    : > "$out"
else
    cat "$FAKE_CURL_BODY" > "$out"
fi
printf '200 %s' "${FAKE_CURL_LANDING:-$url}"
STUB
chmod +x "$SB/fakecurl/curl"
python3 "$SB/leads.py" "$SB/research-https.json" "$RUN_B" "$SB/pages" https_only
fake_curl() { runf "PATH=$SB/fakecurl:$SB/bin:$PATH" "FAKE_CURL_COUNT=$SB/curl-count" "FAKE_CURL_BODY=$SB/pages/flask.html" "$@"; }
rm -f "$SB/curl-count"
fake_curl FAKE_CURL_FAILS=1 attach-research "$RUN_B" "$SB/research-https.json"
check "a transient fetch error is retried, then the quote verifies" "0/research: 1 verified, 0 unverified, 0 failed" "$RC/$(first_line "$OUT")"
check "... after exactly two attempts" "2" "$(cat "$SB/curl-count" 2>/dev/null)"
check_contains "... and the retry is announced with its attempt count" "attempt 1/3" "$ERR"
rm -f "$SB/curl-count"
fake_curl FAKE_CURL_FAILS=9 attach-research "$RUN_B" "$SB/research-https.json"
check "a fetch that keeps failing stops at the attempt limit" "3" "$(cat "$SB/curl-count" 2>/dev/null)"
check "... and its lead is failed, never verified" "research: 0 verified, 0 unverified, 1 failed" "$(first_line "$OUT")"
check_contains "... research.json records the attempts and the cause" "after 3 attempts" "$(cat "$RB/research.json" 2>/dev/null)"
rm -f "$SB/curl-count"
fake_curl FAKE_CURL_STATUS=404 attach-research "$RUN_B" "$SB/research-https.json"
check "a permanent error (404) is not retried" "1" "$(cat "$SB/curl-count" 2>/dev/null)"
check "... and its lead is failed" "research: 0 verified, 0 unverified, 1 failed" "$(first_line "$OUT")"
check_contains "... research.json records the cause" "HTTP 404" "$(cat "$RB/research.json" 2>/dev/null)"
check_absent "... and no absolute path anywhere in it" "$SB" "$(cat "$RB/research.json" 2>/dev/null)"
check_absent "attach-research prints no absolute path" "$SB" "$OUT"
rm -f "$SB/curl-count"
fake_curl FAKE_CURL_FAILS=9 EXHAUSTIVE_AUDIT_DEADLINE_SECS=0 attach-research "$RUN_B" "$SB/research-https.json"
check "a spent overall deadline stops before the first attempt" "0/1 failed" "$(cat "$SB/curl-count" 2>/dev/null || echo 0)/$(first_line "$OUT" | sed 's/.*, //')"

# The request itself is hardened: -q first (so no .curlrc can loosen it), https only for the request and
# every redirect, bounded redirects, size and time.
rm -f "$SB/curl-count" "$SB/curl-argv"
fake_curl "FAKE_CURL_ARGV=$SB/curl-argv" attach-research "$RUN_B" "$SB/research-https.json"
CURL_ARGV="$(head -1 "$SB/curl-argv" 2>/dev/null)"
check "curl's first argument is -q, so a user's .curlrc is never read" "-q" "${CURL_ARGV%% *}"
for flag in "--proto =https" "--proto-redir =https" "--max-redirs 5" "--max-filesize 5000000" "--connect-timeout 10" "--max-time 30"; do
    check_contains "curl is called with $flag" " $flag " " $CURL_ARGV "
done
# Where a fetch finally lands goes through the same URL policy as the lead itself.
for landing in "http://docs.example.org/flask" "https://127.0.0.1/flask" "https://10.0.0.5/flask" "https://user@example.org/flask" \
               "https://2130706433/flask" "https://localhost./flask" "https://[::1]/flask"; do
    rm -f "$SB/curl-count"
    fake_curl "FAKE_CURL_LANDING=$landing" attach-research "$RUN_B" "$SB/research-https.json"
    check "a fetch that lands on $landing is refused" "research: 0 verified, 0 unverified, 1 failed" "$(first_line "$OUT")"
    check_contains "... research.json says it is not a public https page" "not a public https page" "$(cat "$RB/research.json" 2>/dev/null)"
    check "... and nothing is attached" "{}" "$(jfile "$RB/research.json" 'd["attachments"]')"
done
rm -f "$SB/curl-count"
fake_curl "FAKE_CURL_LANDING=https://docs.example.org/flask/stable" attach-research "$RUN_B" "$SB/research-https.json"
check "a fetch that lands on another public https page is kept" "research: 1 verified, 0 unverified, 0 failed" "$(first_line "$OUT")"
rm -f "$SB/curl-count"
fake_curl FAKE_CURL_FAILS=1 FAKE_CURL_FAIL_STATUS=503 FAKE_CURL_RETRY_AFTER=2 attach-research "$RUN_B" "$SB/research-https.json"
check "a 503 with Retry-After is retried, then the quote verifies" "research: 1 verified, 0 unverified, 0 failed/2" "$(first_line "$OUT")/$(cat "$SB/curl-count" 2>/dev/null)"
check_contains "... after the wait the server asked for" "retrying in 2s" "$ERR"
rm -f "$SB/curl-count"
fake_curl FAKE_CURL_EMPTY=1 attach-research "$RUN_B" "$SB/research-https.json"
check "an empty 200 body counts as a truncated response: retried, then verified" "research: 1 verified, 0 unverified, 0 failed/2" "$(first_line "$OUT")/$(cat "$SB/curl-count" 2>/dev/null)"
rm -f "$SB/curl-count"
STARTED="$(date +%s)"
fake_curl FAKE_CURL_FAILS=9 FAKE_CURL_FAIL_STATUS=503 FAKE_CURL_RETRY_AFTER=30 EXHAUSTIVE_AUDIT_DEADLINE_SECS=3 attach-research "$RUN_B" "$SB/research-https.json"
ELAPSED=$(( $(date +%s) - STARTED ))
check "a retry whose wait would pass the overall deadline is not waited for" "1/research: 0 verified, 0 unverified, 1 failed" "$(cat "$SB/curl-count" 2>/dev/null)/$(first_line "$OUT")"
check_contains "... research.json says the next retry would pass the deadline" "would pass the 3s deadline" "$(cat "$RB/research.json" 2>/dev/null)"
if [ "$ELAPSED" -le 10 ]; then check "... and the call returns at once instead of sleeping 30s" "prompt" "prompt"; else check "... and the call returns at once instead of sleeping 30s" "prompt" "${ELAPSED}s"; fi

# Every lead URL goes through the one URL policy before anything is fetched: each of these is refused, the
# whole reply is INVALID, and nothing is fetched or attached.
RESEARCH_SUM="$(cksum < "$RB/research.json" 2>/dev/null)"
TAB_CHAR="$(printf '\t')"
rm -f "$SB/curl-count"
for url in "https://localhost/x" "https://LOCALHOST./x" "https://x.localhost/x" "https://app.internal/x" "https://printer.local/x" \
           "https://box.lan/x" "https://nas.home.arpa/x" "https://intranet/x" "https://docs.example.org./x" "https://%6c%6fcalhost/x" \
           "https://10.1.2.3/x" "https://172.16.0.1/x" "https://192.168.1.1/x" "https://169.254.169.254/x" "https://100.64.0.1/x" \
           "https://127.0.0.1/x" "https://0.0.0.0/x" "https://192.0.2.1/x" "https://198.18.0.1/x" "https://224.0.0.1/x" "https://240.0.0.1/x" \
           "https://127.1/x" "https://2130706433/x" "https://0x7f000001/x" "https://0x7f.0.0.1/x" "https://0177.0.0.1/x" "https://127.000.000.001/x" \
           "https://1.2.3/x" "https://[::1]/x" "https://[fe80::1]/x" "https://[fc00::1]/x" "https://[::ffff:127.0.0.1]/x" "https://[ff02::1]/x" \
           "https://[64:ff9b::7f00:1]/x" "https://user@example.org/x" "https://user:pw@example.org/x" "https://docs.example.org/a b" \
           "https://docs.example.org/a${TAB_CHAR}b" "https:///x" "http://docs.example.org/x" "ftp://docs.example.org/x"; do
    python3 "$SB/leads.py" "$SB/research-url.json" "$RUN_B" "$SB/pages" url "$url"
    fake_curl attach-research "$RUN_B" "$SB/research-url.json"
    check "the URL policy refuses $url: the whole reply is INVALID (exit 2)" "2" "$RC"
    check_prefix "the URL policy refuses $url: INVALID" "INVALID:" "$OUT"
done
check "... nothing was fetched for any refused URL" "0" "$(cat "$SB/curl-count" 2>/dev/null || echo 0)"
check "... and research.json was left as it was" "$RESEARCH_SUM" "$(cksum < "$RB/research.json" 2>/dev/null)"
# Each rule says why, so one rule can never silently stand in for another.
for pair in "https://docs.example.org./x|url host ends with a dot" "https://127.1/x|not a canonical IPv4 address" \
            "https://intranet/x|a single label" "https://user@example.org/x|carries a user name" \
            "https://%6c%6fcalhost/x|not a plain DNS name" "https://[64:ff9b::7f00:1]/x|local or private host" \
            "https://[fe80::1]/x|local or private host" "https://app.internal/x|local or private host" \
            "https://docs.example.org/a b|whitespace or a control character" "http://docs.example.org/x|only https URLs"; do
    python3 "$SB/leads.py" "$SB/research-url.json" "$RUN_B" "$SB/pages" url "${pair%%|*}"
    fake_curl attach-research "$RUN_B" "$SB/research-url.json"
    check_contains "the URL policy says why it refuses ${pair%%|*}" "${pair#*|}" "$OUT"
done
for url in "https://93.184.216.34/flask" "https://[2606:4700::1111]/flask" "https://docs.example.org:8443/flask" "https://xn--bcher-kva.example/flask"; do
    python3 "$SB/leads.py" "$SB/research-url.json" "$RUN_B" "$SB/pages" url "$url"
    fake_curl attach-research "$RUN_B" "$SB/research-url.json"
    check "the URL policy keeps a public https URL: $url" "0/research: 1 verified, 0 unverified, 0 failed" "$RC/$(first_line "$OUT")"
done
# Quotes are compared after both sides are normalized: markdown and code punctuation dropped, curly quotes
# and dashes unified, whitespace collapsed. Case still counts, and the quote must still be contiguous.
python3 - "$SB/pages/jitter.html" <<'PY'
import sys
LEFT, RIGHT, EN_DASH = chr(0x201C), chr(0x201D), chr(0x2013)
page = ("<html><body><h1>Retries</h1><p>Set backoff_jitter to " + LEFT + "full" + RIGHT + " " + EN_DASH
        + " it spreads the retries across the window.</p></body></html>\n")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(page)
PY
python3 - "$SB/research-fold.json" "$RUN_B" "$SB/pages" <<'PY'
import json, sys
out, run, pages = sys.argv[1:4]
page = "file://" + pages + "/jitter.html"
quotes = [("Q01", 'Set `backoff_jitter` to "full" - it spreads the retries'),
          ("Q01", 'Set **backoff_jitter** to \\"full\\" - it spreads the retries'),
          ("Q02", 'Set `backoff_jitter` to "none" - it spreads the retries'),
          ("Q02", 'set `backoff_jitter` to "full" - it spreads the retries'),
          ("Q03", 'Set `backoff_jitter` to "full" spreads the retries')]
leads = [{"question": question, "url": page, "quote": quote, "tier": "official"} for question, quote in quotes]
with open(out, "w") as handle:
    json.dump({"header": {"run": run, "scope": "research"}, "leads": leads}, handle)
PY
runf EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS=1 attach-research "$RUN_B" "$SB/research-fold.json"
check "quote matching ignores markdown punctuation, escaped and curly quotes and dashes, but not case or gaps" "research: 2 verified, 3 unverified, 0 failed" "$(first_line "$OUT")"
check "... the verified leads are the backtick and the bold-and-escaped quotes" '["Q01", "Q01"]' "$(jfile "$RB/research.json" '[l["question"] for l in d["leads"] if l["status"] == "verified"]')"
check "... a different sentence is not verified" "unverified" "$(jfile "$RB/research.json" '[l["status"] for l in d["leads"] if "none" in l["quote"]][0]')"
check "... a different case is not verified" "unverified" "$(jfile "$RB/research.json" '[l["status"] for l in d["leads"] if l["quote"].startswith("set ")][0]')"
check "... a quote with words left out is not verified" "unverified" "$(jfile "$RB/research.json" '[l["status"] for l in d["leads"] if l["question"] == "Q03"][0]')"
# Only text a reader sees can verify a quote: script, style and noscript text never does.
cat > "$SB/pages/hidden.html" <<'EOF'
<!doctype html><html><head><style>.note::after { content: "style text is never page text"; }</style>
<script>var hidden = "a script is never page text";</script></head>
<body><noscript>noscript text is never page text</noscript><p>Visible text is the only page text here.</p></body></html>
EOF
python3 - "$SB/research-hidden.json" "$RUN_B" "$SB/pages" <<'PY'
import json, sys
out, run, pages = sys.argv[1:4]
page = "file://" + pages + "/hidden.html"
quotes = [("Q01", "a script is never page text"), ("Q02", "style text is never page text"),
          ("Q03", "noscript text is never page text"), ("Q01", "Visible text is the only page text here.")]
leads = [{"question": question, "url": page, "quote": quote, "tier": "official"} for question, quote in quotes]
with open(out, "w") as handle:
    json.dump({"header": {"run": run, "scope": "research"}, "leads": leads}, handle)
PY
runf EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS=1 attach-research "$RUN_B" "$SB/research-hidden.json"
check "a quote found only in script, style or noscript text is never verified" "research: 1 verified, 3 unverified, 0 failed" "$(first_line "$OUT")"
check "... the verified one is the visible paragraph" '["Visible text is the only page text here."]' "$(jfile "$RB/research.json" '[l["quote"] for l in d["leads"] if l["status"] == "verified"]')"
# A retry names the page it is fetching by host and path; a query string can carry a token, so never that.
python3 "$SB/leads.py" "$SB/research-query.json" "$RUN_B" "$SB/pages" url "https://docs.example.org/flask?session=abc123opaque"
rm -f "$SB/curl-count"
fake_curl FAKE_CURL_FAILS=1 attach-research "$RUN_B" "$SB/research-query.json"
check_contains "a retry WARNING names the page by host and path" "attempt 1/3 for docs.example.org/flask failed" "$ERR"
check_absent "... never its query string" "abc123opaque" "$ERR"

# A verified quote is text a web page chose, and its tier is the researcher's own rating: the report says
# both, and shows URL and quote as code, so a viewer never renders an image, a link or HTML from them.
cat > "$SB/pages/markup.html" <<'EOF'
<!doctype html><html><body><p>See ![beacon](https://tracker.example/p.png) and &lt;img src=x&gt; or [docs](https://evil.example/) for `more` now.</p></body></html>
EOF
python3 - "$SB/research-markup.json" "$RUN_B" "$SB/pages" <<'PY'
import json, sys
out, run, pages = sys.argv[1:4]
leads = [{"question": "Q02", "url": "file://" + pages + "/markup.html", "tier": "official",
          "quote": "See ![beacon](https://tracker.example/p.png) and <img src=x> or [docs](https://evil.example/) for `more` now."}]
with open(out, "w") as handle:
    json.dump({"header": {"run": run, "scope": "research"}, "leads": leads}, handle)
PY
runf EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS=1 attach-research "$RUN_B" "$SB/research-markup.json"
check "a quote full of markup still verifies against its page" "research: 1 verified, 0 unverified, 0 failed" "$(first_line "$OUT")"
runf EXHAUSTIVE_AUDIT_NOW=20260201T000000Z finalize "$RUN_B"
MARKUP_REPORT="$RB/exhaustive_audit_v13_20260201T000000Z.md"
RESEARCH_LINE="$(grep -F 'markup.html' "$MARKUP_REPORT" 2>/dev/null)"
check_contains "the report says verified means only that the quote was found at that URL" "verified = the quote was found at this URL" "$RESEARCH_LINE"
check_contains "... and that the tier is the researcher's own rating, not a fact" "the researcher rates the source official" "$RESEARCH_LINE"
check "... and once its code spans are removed, nothing in the line can render as an image, link or HTML" "clean" "$(printf '%s' "$RESEARCH_LINE" | python3 -c '
import re, sys
line = sys.stdin.read()
bare = re.sub(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", "", line)
print("clean" if line and not any(mark in bare for mark in ("![", "<", "](")) else "markup outside a code span: " + bare)
')"
check_contains "... the quote keeps its own backticks inside a longer code fence" '``' "$RESEARCH_LINE"
# The backoff: the delay plus a jitter of up to a fifth of it, never less than a second (so it can always
# vary), and never past the 30s cap. Many draws make a missing value practically impossible by chance.
backoff_values() { ea _backoff-wait "$1" "$2" 2>&1 | sort -un | paste -sd ' ' -; }
check "the backoff wait for a 1s delay varies: 1 or 2 seconds" "1 2" "$(backoff_values 1 60)"
check "... for the suite's 0s base: 0 or 1 second" "0 1" "$(backoff_values 0 60)"
check "... for a 10s delay: 10 to 12 seconds" "10 11 12" "$(backoff_values 10 120)"
check "... a 29s delay is held at the 30s cap: 29 or 30 seconds" "29 30" "$(backoff_values 29 200)"
check "... and at the cap itself the wait never passes it" "30" "$(backoff_values 30 60)"
rm -f "$SB/curl-count"
fake_curl EXHAUSTIVE_AUDIT_RETRY_BASE_SECS=1 FAKE_CURL_FAILS=2 attach-research "$RUN_B" "$SB/research-https.json"
WAITS="$(printf '%s\n' "$ERR" | sed -n 's/.*retrying in \([0-9][0-9]*\)s.*/\1/p' | paste -sd ' ' -)"
case "$WAITS" in "1 2"|"1 3"|"2 2"|"2 3") WAIT_VERDICT="doubling" ;; *) WAIT_VERDICT="waits were [$WAITS]" ;; esac
check "with a 1s base the waits double: 1-2s, then 2-3s" "doubling" "$WAIT_VERDICT"
check "... and the third attempt verifies the quote" "3/research: 1 verified, 0 unverified, 0 failed" "$(cat "$SB/curl-count" 2>/dev/null)/$(first_line "$OUT")"
rm -f "$SB/curl-argv"
fake_curl "FAKE_CURL_ARGV=$SB/curl-argv" EXHAUSTIVE_AUDIT_MAX_TIME=0 EXHAUSTIVE_AUDIT_CONNECT_TIMEOUT=0 EXHAUSTIVE_AUDIT_RETRY_ATTEMPTS=abc attach-research "$RUN_B" "$SB/research-https.json"
check_contains "a zero --max-time would mean no limit, so it is refused: curl gets the 30s default" " --max-time 30 " " $(head -1 "$SB/curl-argv" 2>/dev/null) "
check_contains "... and a zero connect timeout gets the 10s default" " --connect-timeout 10 " " $(head -1 "$SB/curl-argv" 2>/dev/null) "
check_contains "... with a warning that names the variable and its floor" "EXHAUSTIVE_AUDIT_MAX_TIME must be a whole number >= 1; using 30" "$ERR"
check_contains "... the same for a value that is not a number" "EXHAUSTIVE_AUDIT_RETRY_ATTEMPTS must be a whole number >= 1; using 3" "$ERR"
check "_backoff-wait refuses a delay that is not a whole number" "1" "$(ea _backoff-wait x >/dev/null 2>&1; echo $?)"
check "_classify: a refused connection is transient" "transient" "$(ea _classify 7 000)"
check "_classify: a clean read with no HTTP status (file://) is ok" "ok" "$(ea _classify 0 000)"
check "_classify: 200 is ok" "ok" "$(ea _classify 0 200)"
check "_classify: a 200 with a broken transfer is transient" "transient" "$(ea _classify 18 200)"
check "_classify: 404 is permanent" "permanent" "$(ea _classify 22 404)"
check "_classify: 429 and 503 are transient" "transient transient" "$(ea _classify 22 429) $(ea _classify 22 503)"
check "_classify: 501 is permanent" "permanent" "$(ea _classify 22 501)"

# ---------------------------------------------------------------------------
# 9. REPORT_LAYOUT=assets-output and the claude-system report
# ---------------------------------------------------------------------------
DG="$SB/data-g"
mkdir -p "$DG"
printf 'REPORT_LAYOUT=assets-output\n' > "$DG/house.conf"
rung() { run "EXHAUSTIVE_AUDIT_DIR=$DG" "$@"; }
rung plan --root "$FIN" --scope claude-system
printf '%s' "$OUT" > "$SB/plan-fin-cs.json"
rung EXHAUSTIVE_AUDIT_NOW=20260301T000000Z init-run --plan "$SB/plan-fin-cs.json" --root "$FIN"
RUN_C="$(first_line "$OUT")"
python3 - "$DG/runs/$RUN_C/results/D5-claude-system.json" "$RUN_C" "$CFG" "$FAKE_HOME" "$SB" <<'PY'
import json, sys
out, run, config, home, sandbox = sys.argv[1:6]
finding = {"dim": 5, "module": None, "check": "C3", "subject": "permissions.allow", "severity": "high",
           "category": "permissions", "finding": "A broad allow rule", "rationale": "Found in %s/settings.json." % config,
           "recommendation": "Narrow it.", "effort": "trivial", "risk": "low",
           "evidence": [{"path": "<config>/settings.json", "line": 4}], "research_questions": []}
# A rationale over its 400-character cap holding two absolute paths, padded from the sandbox's own length
# so the cut falls inside the config path, just past the sandbox prefix: cutting before relativizing would
# leave a raw fragment of the sandbox path in the report.
lead = " Seen in "
filler = "x" * max(0, 399 - len(lead) - (len(sandbox) + 3))
long_finding = dict(finding, check="C4", subject="long rationale", severity="low",
                    rationale=filler + lead + config + "/settings.json and " + home + "/notes.txt.")
with open(out, "w") as handle:
    json.dump({"header": {"run": run, "scope": "D5-claude-system", "agent": "claude-system", "files_reviewed": 3,
                          "lines_reviewed": 40, "notes": "", "not_reviewed": []}, "findings": [finding, long_finding]}, handle)
PY
rung validate "$RUN_C" D5-claude-system
rung EXHAUSTIVE_AUDIT_NOW=20260301T000000Z finalize "$RUN_C"
check "assets-output: finalize exits 0" "0" "$RC"
check_contains "assets-output: the report goes to the root's assets/output" "report: assets/output/exhaustive_audit_v1_20260301T000000Z.md" "$OUT"
check_contains "assets-output: the claude-system report beside it" "assets/output/exhaustive_audit_claude_system_v1_20260301T000000Z.md" "$OUT"
CS_REPORT="$FIN/assets/output/exhaustive_audit_claude_system_v1_20260301T000000Z.md"
check "assets-output: both files exist" "yes/yes" "$( [ -f "$FIN/assets/output/exhaustive_audit_v1_20260301T000000Z.md" ] && echo yes || echo no )/$( [ -f "$CS_REPORT" ] && echo yes || echo no )"
check_contains "claude-system report: a dim-5 finding gets a CS id" "CS-1" "$(cat "$CS_REPORT" 2>/dev/null)"
check_contains "claude-system report: the config dir is <config>" "Found in <config>/settings.json" "$(cat "$CS_REPORT" 2>/dev/null)"
check_absent "claude-system report: no absolute path" "$SB" "$(cat "$CS_REPORT" 2>/dev/null)"
LONG_WHY="$(grep -F 'xxxxxxxxxx' "$CS_REPORT" 2>/dev/null)"
check_contains "an over-cap rationale with two absolute paths is made relative before it is cut" "Seen in <config>/settings.json and ~/notes" "$LONG_WHY"
check_absent "... so no fragment of an absolute path survives the cut" "$SB" "$LONG_WHY"
check_absent "... not even the start of the sandbox path" "${SB%/*}/" "$LONG_WHY"
check_contains "assets-output: COMPLETE" "EXHAUSTIVE-AUDIT COMPLETE" "$OUT"
rung diff
check "diff with fewer than two finalized runs is a usage error" "1" "$RC"

# REPORT_LAYOUT=assets-output never writes through a symlinked assets/ or assets/output/ that leads out of
# the root: the reports go to the run folder instead, with a warning.
DS="$SB/data-symlink"
mkdir -p "$DS"
printf 'REPORT_LAYOUT=assets-output\n' > "$DS/house.conf"
for link in assets assets/output; do
    tag="$(printf '%s' "$link" | tr / -)"
    LR="$SB/linkroot-$tag"
    ELSEWHERE="$SB/elsewhere-$tag"
    mkdir -p "$LR/mod" "$ELSEWHERE" "$(dirname "$LR/$link")"
    printf '{"name": "mod"}\n' > "$LR/mod/package.json"
    ln -s "$ELSEWHERE" "$LR/$link"
    run "EXHAUSTIVE_AUDIT_DIR=$DS" plan --root "$LR" --scope claude-system
    printf '%s' "$OUT" > "$SB/plan-$tag.json"
    run "EXHAUSTIVE_AUDIT_DIR=$DS" EXHAUSTIVE_AUDIT_NOW=20260601T000000Z init-run --plan "$SB/plan-$tag.json" --root "$LR"
    RUN_S="$(first_line "$OUT")"
    python3 - "$DS/runs/$RUN_S/results/D5-claude-system.json" "$RUN_S" <<'PY'
import json, sys
with open(sys.argv[1], "w") as handle:
    json.dump({"header": {"run": sys.argv[2], "scope": "D5-claude-system", "agent": "claude-system", "files_reviewed": 1,
                          "lines_reviewed": 1}, "findings": []}, handle)
PY
    run "EXHAUSTIVE_AUDIT_DIR=$DS" validate "$RUN_S" D5-claude-system
    run "EXHAUSTIVE_AUDIT_DIR=$DS" EXHAUSTIVE_AUDIT_NOW=20260601T000000Z finalize "$RUN_S"
    check_contains "a symlinked $link leading out of the root: the report goes to the run folder" "report: <data>/runs/$RUN_S/exhaustive_audit_v1_20260601T000000Z.md" "$OUT"
    check_contains "... with a warning" "leads outside the root" "$ERR"
    check "... and nothing is written where the link points" "" "$(ls -A "$ELSEWHERE")"
done

# ---------------------------------------------------------------------------
# 10. demo-fixture and score-demo
# ---------------------------------------------------------------------------
DEMO="$SB/demo"
DEMO_CFG="$DEMO/claude-config"
run demo-fixture "$DEMO"
check "demo-fixture exits 0" "0" "$RC"
check_contains "demo-fixture says what it built" "15 planted defects (3 critical)" "$OUT"
check_absent "demo-fixture prints no absolute path" "$SB" "$OUT"
check "demo-fixture: the two modules and the config" "yes/yes/yes" "$( [ -f "$DEMO/workspace/orders/app/db.py" ] && echo yes || echo no )/$( [ -f "$DEMO/workspace/notify/bin/update.sh" ] && echo yes || echo no )/$( [ -f "$DEMO_CFG/settings.json" ] && echo yes || echo no )"
check "demo-fixture: the demo's own folders get ordinary modes" "755/644" "$(file_mode "$DEMO/workspace/orders")/$(file_mode "$DEMO/workspace/orders/app/db.py")"
check "demo-fixture: its data dir and denylist are private" "700/600" "$(file_mode "$DEMO_CFG/exhaustive-audit-and-review")/$(file_mode "$DEMO_CFG/exhaustive-audit-and-review/denylist.txt")"
check "demo-fixture: no generated file holds a contiguous secret-shaped value" "" "$(grep -rlE 'sk-demo-[0-9a-f]{8}' "$DEMO" 2>/dev/null)"
check "demo-fixture: the demo settings are valid JSON" "sonnet" "$(jfile "$DEMO_CFG/settings.json" 'd["model"]')"
check_contains "demo-fixture: the planted SQL concatenation" "WHERE customer = '\" + customer_name" "$(cat "$DEMO/workspace/orders/app/db.py" 2>/dev/null)"
check_contains "demo-fixture: the planted unquoted ': ' in an agent description" "description: Use when: preparing" "$(cat "$DEMO_CFG/agents/release-helper.md" 2>/dev/null)"
check_contains "demo-fixture: the planted Bash(curl:*) allow rule" "Bash(curl:*)" "$(cat "$DEMO_CFG/settings.json" 2>/dev/null)"
check "demo-fixture: the planted personal code-review skill" "yes" "$( [ -f "$DEMO_CFG/skills/code-review/SKILL.md" ] && echo yes || echo no )"
run demo-fixture "$DEMO"
check "demo-fixture never builds into a folder that is not empty" "1" "$RC"
run discover --root "$DEMO/workspace" --config-dir "$DEMO_CFG"
check "the demo workspace has its two modules, in registry order" '["orders", "notify"]' "$(jv "$OUT" '[m["name"] for m in d["modules"]]')"
# A real run of this demo processed 53.5M tokens with 19 agents in about 33 minutes (one wave, then research).
run plan --root "$DEMO/workspace" --config-dir "$DEMO_CFG" --scope all
check "the demo's estimate matches its measured run: 19 agents, 53.2M processed tokens, 31 minutes" '{"agents": 19, "minutes": 31, "processed_tokens": 53200000}' "$(jv "$OUT" '{k: d["estimate"][k] for k in ("agents", "processed_tokens", "minutes")}')"

cat > "$SB/demo_results.py" <<'PY'
# demo_results.py <results-dir> <run> <full|miss> — what an audit of the demo might report.
import json, os, sys
results, run, case = sys.argv[1:4]

def finding(dim, module, check, subject, severity, path, line, text):
    return {"dim": dim, "module": module, "check": check, "subject": subject, "severity": severity, "category": "security",
            "finding": text, "rationale": "Planted in the demo.", "recommendation": "Fix it.", "effort": "S", "risk": "high",
            "evidence": [{"path": path, "line": line}], "research_questions": []}

found = [finding(4, "orders", "security:injection", "find_orders", "critical", "orders/app/db.py", 9, "SQL is built by string concatenation"),
         finding(4, "orders", "secrets:logged", "API_KEY", "high", "orders/app/settings.py", 10, "The API key is written to the log"),
         finding(4, "orders", "resilience:timeout", "requests.get", "high", "orders/app/client.py", 9, "No timeout on the pricing call"),
         finding(5, None, "hooks:matcher", "prompt-guard.sh", "high", "<config>/hooks/prompt-guard.sh", 4, "The hook reads .user_message, which is never sent")]
if case == "full":
    found.append(finding(4, "notify", "supply-chain:download", "update.sh", "critical", "notify/bin/update.sh", 3, "curl downloads into /tmp and runs it unchecked"))
for scope, findings in (("D2-architecture", []), ("D3-domain", []), ("D4-operations", found), ("PH-1", []), ("PH-2", [])):
    with open(os.path.join(results, scope + ".json"), "w") as handle:
        json.dump({"header": {"run": run, "scope": scope, "agent": "demo", "files_reviewed": 1, "lines_reviewed": 1},
                   "findings": findings}, handle)
PY
demo_run() {
    # demo_run <UTC stamp> <full|miss> -> sets DEMO_RUN to a finalized run of the demo workspace
    run plan --root "$DEMO/workspace" --config-dir "$DEMO_CFG" --scope workspace
    printf '%s' "$OUT" > "$SB/plan-demo.json"
    run "EXHAUSTIVE_AUDIT_NOW=$1" init-run --plan "$SB/plan-demo.json" --root "$DEMO/workspace" --config-dir "$DEMO_CFG"
    DEMO_RUN="$(first_line "$OUT")"
    python3 "$SB/demo_results.py" "$DEMO_CFG/exhaustive-audit-and-review/runs/$DEMO_RUN/results" "$DEMO_RUN" "$2"
    for scope in D2-architecture D3-domain D4-operations PH-1 PH-2; do run validate "$DEMO_RUN" "$scope" --config-dir "$DEMO_CFG"; done
    run "EXHAUSTIVE_AUDIT_NOW=$1" finalize "$DEMO_RUN" --config-dir "$DEMO_CFG"
}
demo_run 20260401T000000Z full
check "the demo run lives in the demo config's data dir" "yes" "$( [ -f "$DEMO_CFG/exhaustive-audit-and-review/runs/$DEMO_RUN/findings.json" ] && echo yes || echo no )"
run validate "$DEMO_RUN" D2-architecture
check "a run command without init-run's --config-dir cannot find the run (exit 1)" "1" "$RC"
check_contains "... and says which --config-dir to give" "--config-dir that init-run had" "$ERR"
run score-demo "$DEMO_RUN" --config-dir "$DEMO_CFG"
check "score-demo: every planted critical found exits 0" "0" "$RC"
check_contains "score-demo: the summary" "5/15 planted defects found · criticals 3/3" "$OUT"
check_contains "score-demo: a found defect names the finding that found it" "D01 | critical | orders | orders/app/db.py | FOUND by M1-" "$OUT"
check_contains "score-demo: a config defect is matched by its <config>/ path" "D10 | - | - | <config>/hooks/prompt-guard.sh, <config>/settings.json | FOUND by CS-1" "$OUT"
check_contains "score-demo: the right path without the right keyword is still a miss" "D03 | - | orders | orders/app/client.py | MISSED" "$OUT"
demo_run 20260402T000000Z miss
run score-demo "$DEMO_RUN" --config-dir "$DEMO_CFG"
check "score-demo: a missed critical exits 2" "2" "$RC"
check_contains "score-demo: ... and names it" "MISSED critical: D07" "$OUT"
check_contains "score-demo: ... the summary counts it" "criticals 2/3" "$OUT"
run score-demo 19990101T000000Z --config-dir "$DEMO_CFG"
check "score-demo: an unknown run exits 1" "1" "$RC"

# ---------------------------------------------------------------------------
# 11. The stub CLI was only ever asked for its version
# ---------------------------------------------------------------------------
check "claude was only ever run as claude --version" "" "$(grep -v '^--version$' "$SB/claude-calls.log" 2>/dev/null)"
check "claude --version was run" "yes" "$( [ -s "$SB/claude-calls.log" ] && echo yes || echo no )"

# ---------------------------------------------------------------------------
# 12. The suite itself: its sandbox, its preconditions, its JSON reader
# ---------------------------------------------------------------------------
# The EXIT trap deletes the sandbox, so a sandbox path that came back as HOME (or empty, where bash's
# `cd ""` stays put) would have the suite work in, then delete, a folder it does not own. A stand-in mktemp
# hands back a throwaway HOME, then an empty path: the suite must stop with its FAIL line and leave that
# folder as it was. A probe never probes again, so a suite that regressed cannot start itself forever.
if [ -n "${EXHAUSTIVE_AUDIT_SANDBOX_PROBE:-}" ]; then
    :
else
    PROBE_HOME="$SB/probe-home"
    mkdir -p "$PROBE_HOME" "$SB/fake-mktemp" "$SB/no-tools" "$SB/python-only"
    printf 'marker\n' > "$PROBE_HOME/marker"
    printf '#!/bin/bash\nprintf "%%s\\n" "${FAKE_MKTEMP_RESULT:-}"\n' > "$SB/fake-mktemp/mktemp"
    chmod +x "$SB/fake-mktemp/mktemp"
    for result in "$PROBE_HOME" ""; do
        OUT="$(cd "$PROBE_HOME" && HOME="$PROBE_HOME" FAKE_MKTEMP_RESULT="$result" PATH="$SB/fake-mktemp:$PATH" \
               EXHAUSTIVE_AUDIT_SANDBOX_PROBE=1 "$SUITE_BASH" "$SELF" 2>/dev/null)"
        RC=$?
        label="${result:+HOME}"
        check "a sandbox path that is ${label:-empty} stops the suite (exit 1)" "1" "$RC"
        check_prefix "... with its FAIL line" "FAIL: cannot use the sandbox [" "$(first_line "$OUT")"
        check "... and the folder it was handed is left as it was" "marker" "$(ls -A "$PROBE_HOME" 2>/dev/null)"
    done
    # A missing tool fails once, by name, instead of hundreds of checks failing with empty answers.
    ln -s "$(command -v python3)" "$SB/python-only/python3"
    OUT="$(PATH="$SB/no-tools" EXHAUSTIVE_AUDIT_SANDBOX_PROBE=1 "$SUITE_BASH" "$SELF" 2>&1)"
    check "without python3 the suite fails once, naming it" "1/FAIL: this suite needs python3 on PATH" "$?/$OUT"
    OUT="$(PATH="$SB/python-only" EXHAUSTIVE_AUDIT_SANDBOX_PROBE=1 "$SUITE_BASH" "$SELF" 2>&1)"
    check "without git the suite fails once, naming it" "1/FAIL: this suite needs git on PATH" "$?/$OUT"
fi
check_contains "jv names the error and the expression when a check's own expression is wrong" 'KeyError in d["no-such-key"]' "$(jv '{"a": 1}' 'd["no-such-key"]' 2>&1 >/dev/null)"

# --- END CASES ---
echo "----"
echo "exhaustive-audit-and-review-helper: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
