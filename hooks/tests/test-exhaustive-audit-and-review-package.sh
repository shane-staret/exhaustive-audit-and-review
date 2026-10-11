#!/bin/bash
# test-exhaustive-audit-and-review-package.sh — is the exhaustive-audit-and-review package consistent?
#
# Hermetic and shipped with the package: it reads files relative to itself, so the same file runs in
# ~/.claude and in a fresh clone. It checks what the package promises, not how one machine is wired:
#   1. package.manifest lists exactly what ships, every listed file exists, nothing shadows a built-in
#      command (no `code-review` skill), and no house-only file ships (a wiring suite, which reads one
#      machine's real config, or the publishing script and its suite);
#   2. agents: exact tool lines for the audit agents (web access only in the researcher), names match
#      file stems, frontmatter is strict YAML, no agent can launch skills or ask the user;
#   3. shipped text carries no home paths, no private ledger ids, never the headless invocation, and no
#      agent or skill file promises to stop after a fixed number of minutes (a promise no agent can keep);
#   4. both skills follow the authoring shape (trigger-only description with a negative scope, a
#      Resource table, anti-patterns, a split checklist, required resources, no archive/ folder), and the
#      audit's preflight asks with AskUserQuestion before init-run;
#   5. every helper subcommand the skill names exists in the helper's usage text, and every agent that
#      writes findings states the enums and length caps the helper validates;
#   6. the helper, installer and suites parse;
#   7. every shipped suite stops at once when it cannot create its sandbox, and leaves the folder it was
#      started from as it was.
# Each extraction is first proven able to fail on a planted fixture (negative controls); the bans run there
# with their production patterns, and a file a scan cannot read fails the scan.
# bash-3.2-safe; reads files, and starts each shipped suite once with a TMPDIR that does not exist (python3
# is used for YAML when PyYAML is present).

set -u
ROOT="${EXHAUSTIVE_AUDIT_PACKAGE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
NAME="exhaustive-audit-and-review"
SKILL_DIR="$ROOT/skills/$NAME"
MANIFEST="$SKILL_DIR/package.manifest"
HELPER="$SKILL_DIR/exhaustive_audit_and_review.sh"
sandbox_ok() {
    # sandbox_ok <path> -> true only for a path the EXIT trap may delete: absolute, more than slashes, and not
    # HOME. An empty path is the dangerous one: bash's `cd ""` stays where it is, so a suite whose mktemp
    # failed once worked in, and then deleted, the folder it was started from.
    local home="${HOME:-}"
    case "$1" in /*[!/]*) ;; *) return 1 ;; esac
    [ "${1%/}" != "${home%/}" ]
}
remove_sandbox() { sandbox_ok "$SANDBOX" && rm -rf "$SANDBOX"; }
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/$NAME-package-test.XXXXXX")" || { echo 'FAIL: cannot create a sandbox'; exit 1; }
[ -d "$SANDBOX" ] && SANDBOX="$(CDPATH= cd -- "$SANDBOX" && pwd -P)" && sandbox_ok "$SANDBOX" \
    || { echo "FAIL: cannot use the sandbox [$SANDBOX]: not a folder this suite may delete"; exit 1; }
trap remove_sandbox EXIT

AUDIT_AGENTS="$NAME-architecture $NAME-domain $NAME-operations $NAME-claude-system $NAME-researcher"
CODE_REVIEW_AGENTS="code-reviewer code-reviewer-structure code-reviewer-security code-reviewer-test-quality code-reviewer-simplification code-reviewer-smells"
APPLY_REC_AGENTS="apply-rec-orchestrator apply-rec-editor apply-rec-analyst dependency-modernizer runbook-author"
ALL_AGENTS="$AUDIT_AGENTS $CODE_REVIEW_AGENTS project-health $APPLY_REC_AGENTS"
# Agents that launch other agents (everything else must not grant Agent).
DISPATCHERS="code-reviewer apply-rec-orchestrator"
# Agents that write findings in the shared schema.
FINDING_WRITERS="$NAME-architecture $NAME-domain $NAME-operations $NAME-claude-system code-reviewer project-health"
REQUIRED_RESOURCES="references.md testing-$NAME.md worked-example.md example-report.md wiring.md claude-system-checklist.md"
TEMPLATES="code_quality_standard.md retry_standard.md testing_standard.md code_navigation_standard.md runbook_incident.md.tmpl"
SUITES="test-$NAME-helper.sh test-$NAME-package.sh test-$NAME-install.sh"
DESCRIPTION_MAX=500

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
is_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
tools_line() { awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } /^tools:/ { sub(/^tools:[ \t]*/, ""); print; exit }' "$1"; }
fm_value() { awk -v key="$2" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } { k = $0; sub(/:.*/, "", k); if (k == key) { sub(/^[^:]*:[ \t]*/, ""); print; exit } }' "$1"; }
grants() { printf '%s' "$(tools_line "$2")" | grep -Eq "(^|[ ,])$1([ ,]|\$)"; }
manifest_entries() { grep -vE '^[[:space:]]*(#|$)' "$1" | sed 's/[[:space:]]*$//'; }
expand_manifest() {
    # expand_manifest <manifest> <root> -> every file the manifest ships, one absolute path per line (a folder
    # entry expands to its files), and "MISSING <entry>" for each entry that is not on disk. Entries are read
    # whole, so a space or a glob character in one never splits or expands it.
    local entry p
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        p="$2/${entry%/}"
        if [ -d "$p" ]; then find "$p" -type f ! -name '.DS_Store'
        elif [ -f "$p" ]; then printf '%s\n' "$p"
        else printf 'MISSING %s\n' "$entry"; fi
    done <<< "$(manifest_entries "$1")"
}
NL='
'

# The shipped-text bans, named once so the negative controls run exactly the patterns section 3 runs.
HOME_PATH_RE='/Users/[A-Za-z]|/home/[a-z]'
WINDOWS_PATH_RE='C:\\Users\\'
LEDGER_ID_RE='RW-[0-9]{4}'
DECISION_ID_RE='ADR 0[0-9]{3}'
TIMED_STOP_RE='stops? after [0-9]+ ?min(ute)?s?([^a-z]|$)'
HEADLESS="claude"" -p \""      # assembled, so this file never holds the invocation it bans
# House-only files read one machine's real config (wiring suites) or name its private repository (the
# publishing script and its suite), so a public package must never list them.
HOUSE_ONLY_RE='(^|/)([^/]*-wiring\.sh|sync_config_repo\.sh|test-sync-config-repo\.sh)$'
ban() {
    # ban <file list> <description> <grep options> <pattern> -> one PASS when no file named in the list (one
    # path per line) matches, else one FAIL naming the first hits. A file grep cannot read (exit above 1), or
    # a list that names no file, fails too: a scan that cannot run is never clean.
    local list="$1" what="$2" opts="$3" pattern="$4" f out rc scanned=0 hits="" unread=""
    [ -r "$list" ] || { bad "the file list for $what cannot be read ($list)"; return; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        scanned=$((scanned+1))
        out="$(grep -n "$opts" -- "$pattern" "$f" 2>"$SANDBOX/ban.err")"; rc=$?
        case "$rc" in
            0) hits="$hits$(printf '%s\n' "$out" | sed "s|^|${f#$ROOT/}:|")$NL" ;;
            1) ;;
            *) unread="$unread ${f#$ROOT/} (grep exit $rc: $(head -n 1 "$SANDBOX/ban.err"))" ;;
        esac
    done < "$list"
    if [ -n "$unread" ]; then bad "the scan for $what could not read:$unread"
    elif [ "$scanned" -eq 0 ]; then bad "no file was scanned for $what"
    elif [ -n "$hits" ]; then bad "shipped files contain $what: $(printf '%s' "$hits" | head -3 | cut -c1-140 | tr '\n' ' ')"
    else ok "no shipped file contains $what"; fi
}
house_only() { grep -E -- "$HOUSE_ONLY_RE" "$1"; }   # house_only <path list> -> the house-only paths in it
preflight_order() {
    # preflight_order <SKILL.md> -> "asks first" when the preflight section (from its "### ... Preflight"
    # heading to the next ## or ### heading) names AskUserQuestion before its first init-run; else what is wrong
    awk '
        /^###? / { if (on) exit }
        /^### .*[Pp]reflight/ { on = 1; next }
        on && !ask && index($0, "AskUserQuestion") { ask = NR * 10000 + index($0, "AskUserQuestion") }
        on && !init && index($0, "init-run") { init = NR * 10000 + index($0, "init-run") }
        END {
            if (!on) print "no preflight section"
            else if (!ask) print "no AskUserQuestion step"
            else if (!init) print "no init-run step"
            else if (ask < init) print "asks first"
            else print "init-run comes before AskUserQuestion"
        }' "$1"
}

# --- negative controls: each extraction must be able to fail ---------------------------------------
NC="$SANDBOX/nc"; mkdir -p "$NC"
printf -- '---\nname: demo\ndescription: "Use when testing."\ntools: Read, Grep\n---\nbody tools: Bash\n' > "$NC/agent.md"
if [ "$(tools_line "$NC/agent.md")" = "Read, Grep" ]; then ok "control: the tools line is read from the frontmatter only"; else bad "control: tools_line misread a fixture (got '$(tools_line "$NC/agent.md")')"; fi
if grants Bash "$NC/agent.md"; then bad "control: a tool named only in the body counted as granted"; else ok "control: a tool named only in the body is not granted"; fi
# Each ban runs here exactly as section 3 runs it, on one planted file and in a subshell, so its verdict is
# read rather than counted. The planted values are assembled at run time so this file never contains one
# (it is scanned too).
verdict_of_ban() {
    # verdict_of_ban <file> <grep options> <pattern> -> the PASS or FAIL line ban prints for that file alone
    printf '%s\n' "$1" > "$NC/one-file.list"
    ( ban "$NC/one-file.list" "the planted text" "$2" "$3" )
}
expect_ban() {
    # expect_ban <control> <file> <grep options> <pattern> -> ban must FAIL on that file, naming it
    local verdict
    verdict="$(verdict_of_ban "$2" "$3" "$4")"
    case "$verdict" in "FAIL:"*"$(basename "$2")"*) ok "control: $1" ;; *) bad "control: $1 (ban said: $verdict)" ;; esac
}
MAC_HOME="/Us""ers/someone"; LINUX_HOME="/ho""me/someone"; WIN_HOME='C:\Us''ers\someone'
printf 'path %s/x\n' "$MAC_HOME" > "$NC/mac-home.md"
printf 'path %s/x\n' "$LINUX_HOME" > "$NC/linux-home.md"
printf 'path %s\n' "$WIN_HOME" > "$NC/windows-home.md"
printf 'see %s-%s\n' RW "00""42" > "$NC/ledger-id.md"
printf 'see %s %s\n' ADR "00""07" > "$NC/decision-id.md"
printf 'run %sx" here\n' "$HEADLESS" > "$NC/headless.md"
printf 'You Stop after %s minutes, whatever happens.\n' 15 > "$NC/timed-stop.md"
expect_ban "the home-path ban catches a planted macOS home" "$NC/mac-home.md" -E "$HOME_PATH_RE"
expect_ban "the home-path ban catches a planted Linux home" "$NC/linux-home.md" -E "$HOME_PATH_RE"
expect_ban "the Windows-path ban catches a planted user path" "$NC/windows-home.md" -E "$WINDOWS_PATH_RE"
expect_ban "the ledger-id ban catches a planted id" "$NC/ledger-id.md" -E "$LEDGER_ID_RE"
expect_ban "the decision-record ban catches a planted id" "$NC/decision-id.md" -E "$DECISION_ID_RE"
expect_ban "the headless ban catches a planted invocation" "$NC/headless.md" -F "$HEADLESS"
expect_ban "the timed-stop ban catches a planted promise, whatever its case" "$NC/timed-stop.md" -iE "$TIMED_STOP_RE"
expect_ban "a file the scan cannot read fails the ban" "$NC/no-such-file.md" -E "$HOME_PATH_RE"
printf 'plain text: /usr/local, RW-42, ADR 7, stop after the minutes run out\n' > "$NC/clean.md"
case "$(verdict_of_ban "$NC/clean.md" -iE "$HOME_PATH_RE|$LEDGER_ID_RE|$DECISION_ID_RE|$TIMED_STOP_RE")" in
    PASS:*) ok "control: a file with near misses passes the bans" ;;
    *) bad "control: a file with near misses failed a ban: $(verdict_of_ban "$NC/clean.md" -iE "$HOME_PATH_RE|$LEDGER_ID_RE|$DECISION_ID_RE|$TIMED_STOP_RE")" ;;
esac
printf '%s\n' hooks/tests/test-demo-wiring.sh skills/sync-config-repo/sync_config_repo.sh hooks/tests/test-sync-config-repo.sh \
    hooks/tests/test-demo.sh skills/demo/wiring.sh skills/demo/resources/wiring.md > "$NC/house.list"
if [ "$(house_only "$NC/house.list" | tr '\n' ' ')" = "hooks/tests/test-demo-wiring.sh skills/sync-config-repo/sync_config_repo.sh hooks/tests/test-sync-config-repo.sh " ]; then
    ok "control: the house-only check finds a wiring suite and the publishing script and suite, nothing else"
else
    bad "control: the house-only check found '$(house_only "$NC/house.list" | tr '\n' ' ')'"
fi
printf '## The run\n### 1. Preflight\nShow the plan.\nRun init-run.\n### 2. Waves\nAsk with AskUserQuestion.\n' > "$NC/no-ask.md"
printf '### 1. Preflight\nRun init-run, then ask with AskUserQuestion.\n' > "$NC/late-ask.md"
printf '### 1. Preflight\nAsk with AskUserQuestion.\nThen run init-run.\n## Next\n' > "$NC/asks-first.md"
P_CONTROLS="$(preflight_order "$NC/no-ask.md")|$(preflight_order "$NC/late-ask.md")|$(preflight_order "$NC/asks-first.md")"
if [ "$P_CONTROLS" = "no AskUserQuestion step|init-run comes before AskUserQuestion|asks first" ]; then
    ok "control: the preflight check refuses a missing or late AskUserQuestion and passes one that comes first"
else
    bad "control: the preflight check misjudged its fixtures (got '$P_CONTROLS')"
fi
check_sandbox_guard() {
    # The EXIT trap deletes recursively, so its guard must refuse every path that is not a sandbox.
    local verdicts="" p
    for p in "" / // relative/path "${HOME:-/}" "${HOME:-/}/" "$SANDBOX"; do
        if sandbox_ok "$p"; then verdicts="$verdicts yes"; else verdicts="$verdicts no"; fi
    done
    if [ "$verdicts" = " no no no no no no yes" ]; then ok "control: the sandbox cleanup refuses '', /, //, a relative path and HOME, and accepts the sandbox"
    else bad "control: the sandbox cleanup guard judged '' / // relative HOME HOME/ sandbox as:$verdicts"; fi
}
check_sandbox_guard
printf '# comment\n\nskills/demo/\nagents/demo.md   \n' > "$NC/manifest"
if [ "$(manifest_entries "$NC/manifest" | tr '\n' ' ')" = "skills/demo/ agents/demo.md " ]; then ok "control: manifest parsing drops comments, blanks and trailing spaces"; else bad "control: manifest parsing is wrong (got '$(manifest_entries "$NC/manifest" | tr '\n' ' ')')"; fi
mkdir -p "$NC/pkg/agents" "$NC/pkg/skills/demo dir/resources"
printf 'x\n' > "$NC/pkg/agents/my agent.md"
printf 'x\n' > "$NC/pkg/skills/demo dir/SKILL.md"
printf 'x\n' > "$NC/pkg/skills/demo dir/resources/notes.md"
printf 'x\n' > "$NC/pkg/agents/star.md"   # what agents/*.md would pick up if an entry were ever globbed
printf '# demo\nagents/my agent.md\nskills/demo dir/\nagents/*.md\nagents/gone.md\n' > "$NC/pkg.manifest"
EXPANDED="$(expand_manifest "$NC/pkg.manifest" "$NC/pkg" | LC_ALL=C sort | tr '\n' '|')"
if [ "$EXPANDED" = "$NC/pkg/agents/my agent.md|$NC/pkg/skills/demo dir/SKILL.md|$NC/pkg/skills/demo dir/resources/notes.md|MISSING agents/*.md|MISSING agents/gone.md|" ]; then
    ok "control: a manifest entry holding a space or a glob is read whole, and a missing one is reported"
else
    bad "control: the manifest expanded to '$EXPANDED'"
fi

# --- 1. the manifest -----------------------------------------------------------------------------
if [ ! -f "$MANIFEST" ]; then
    bad "package.manifest is missing at skills/$NAME/package.manifest"
else
    ENTRIES="$(manifest_entries "$MANIFEST")"
    if printf '%s\n' "$ENTRIES" | grep -qx "skills/$NAME/"; then ok "the manifest ships the skill folder"; else bad "the manifest does not list skills/$NAME/"; fi
    if printf '%s\n' "$ENTRIES" | grep -qx 'skills/code-review/'; then bad "the manifest ships a code-review skill, which would replace Claude Code's built-in /code-review"; else ok "no code-review skill ships (the built-in /code-review stays reachable)"; fi
    DUPS="$(printf '%s\n' "$ENTRIES" | sort | uniq -d | head -3 | tr '\n' ' ')"
    if [ -z "$DUPS" ]; then ok "the manifest has no duplicate lines"; else bad "the manifest repeats: $DUPS"; fi
    BADPATHS="$(printf '%s\n' "$ENTRIES" | grep -E '^/|(^|/)\.\.(/|$)|\\' | head -3 | tr '\n' ' ')"
    if [ -z "$BADPATHS" ]; then ok "manifest paths are relative and stay inside the package"; else bad "unsafe manifest paths: $BADPATHS"; fi
    MISSING="$(expand_manifest "$MANIFEST" "$ROOT" | sed -n 's/^MISSING //p' | tr '\n' ' ')"
    if [ -z "$MISSING" ]; then ok "every manifest entry exists"; else bad "manifest entries missing on disk: $MISSING"; fi
    for agent in $ALL_AGENTS; do
        if printf '%s\n' "$ENTRIES" | grep -qx "agents/$agent.md"; then ok "ships agent $agent"; else bad "the manifest does not ship agents/$agent.md"; fi
    done
    if printf '%s\n' "$ENTRIES" | grep -qx 'skills/apply-rec/'; then ok "ships the /apply-rec skill"; else bad "the manifest does not ship skills/apply-rec/"; fi
    for t in $TEMPLATES; do
        if printf '%s\n' "$ENTRIES" | grep -qx "templates/$t"; then ok "ships template $t"; else bad "the manifest does not ship templates/$t"; fi
    done
    for s in $SUITES; do
        if printf '%s\n' "$ENTRIES" | grep -qx "hooks/tests/$s"; then ok "ships suite $s"; else bad "the manifest does not ship hooks/tests/$s"; fi
    done
fi
for f in SKILL.md README.md LICENSE install.sh exhaustive_audit_and_review.sh; do
    if [ -f "$SKILL_DIR/$f" ]; then ok "skill folder has $f"; else bad "skill folder is missing $f"; fi
done
for f in "$HELPER" "$SKILL_DIR/install.sh"; do
    if [ -x "$f" ]; then ok "$(basename "$f") is executable"; else bad "$(basename "$f") is not executable"; fi
done

# --- 2. agents -----------------------------------------------------------------------------------
expect_tools() {
    # expect_tools <agent> <exact tools line>
    local f="$ROOT/agents/$1.md"
    [ -f "$f" ] || { bad "$1.md is missing"; return; }
    if [ "$(tools_line "$f")" = "$2" ]; then ok "$1: tools are exactly '$2'"; else bad "$1: tools must be exactly '$2' (got '$(tools_line "$f")')"; fi
}
expect_tools "$NAME-architecture" "Read, Grep, Glob, LSP"
expect_tools "$NAME-domain" "Read, Grep, Glob"
expect_tools "$NAME-operations" "Read, Grep, Glob, LSP"
expect_tools "$NAME-claude-system" "Read, Grep, Glob"
expect_tools "$NAME-researcher" "WebSearch, WebFetch"
expect_tools "apply-rec-analyst" "Read, Grep, Glob, LSP"
for agent in "$NAME-claude-system" "$NAME-researcher"; do
    f="$ROOT/agents/$agent.md"
    if [ -f "$f" ] && [ "$(fm_value "$f" omitClaudeMd)" = "true" ]; then ok "$agent: omitClaudeMd is true (the user's own instructions stay out of its context)"; else bad "$agent: must set 'omitClaudeMd: true'"; fi
done
for agent in $ALL_AGENTS; do
    f="$ROOT/agents/$agent.md"
    [ -f "$f" ] || continue
    if [ "$(fm_value "$f" name)" = "$agent" ]; then ok "$agent: frontmatter name matches the file"; else bad "$agent: frontmatter name is '$(fm_value "$f" name)'"; fi
    if [ -n "$(fm_value "$f" description)" ]; then ok "$agent: has a description"; else bad "$agent: has no description"; fi
    if [ "$agent" != "$NAME-researcher" ] && { grants WebSearch "$f" || grants WebFetch "$f"; }; then bad "$agent: has web access (only the researcher may; local readers never touch the web)"; else ok "$agent: web access only where intended"; fi
    if grants Agent "$f" && ! is_in "$agent" "$DISPATCHERS"; then bad "$agent: grants Agent but is not a dispatcher"; else ok "$agent: Agent tool only where it dispatches"; fi
    if grants Skill "$f"; then bad "$agent: grants Skill (a subagent must not start skills that would need the user's answer)"; else ok "$agent: cannot start skills"; fi
    if grants AskUserQuestion "$f"; then bad "$agent: lists AskUserQuestion, which no subagent receives"; else ok "$agent: does not promise a question it cannot ask"; fi
done
for agent in $DISPATCHERS; do
    f="$ROOT/agents/$agent.md"
    [ -f "$f" ] || continue
    if grants Agent "$f"; then ok "$agent: grants Agent"; else bad "$agent: dispatches but does not grant Agent"; fi
    if grep -q 'DISPATCH FAILED' "$f"; then ok "$agent: carries the DISPATCH FAILED rule"; else bad "$agent: has no DISPATCH FAILED rule"; fi
done
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    # One path per line, read whole: a package root with a space in it once split every path and skipped
    # every file without a word.
    YAML_FILES="$SKILL_DIR/SKILL.md${NL}$ROOT/skills/apply-rec/SKILL.md"
    for agent in $ALL_AGENTS; do YAML_FILES="$YAML_FILES${NL}$ROOT/agents/$agent.md"; done
    YAML_READ=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        YAML_READ=$((YAML_READ+1))
        if python3 - "$f" <<'PY' 2>/dev/null
import sys, yaml
text = open(sys.argv[1], encoding="utf-8").read()
assert text.startswith("---\n")
data = yaml.safe_load(text.split("---\n", 2)[1])
assert isinstance(data, dict) and data.get("name") and data.get("description")
PY
        then ok "${f#$ROOT/}: frontmatter is strict YAML"; else bad "${f#$ROOT/}: frontmatter is not strict YAML (an unquoted ': ' in a value?)"; fi
    done <<< "$YAML_FILES"
    # Counted against the agent list, not the file list, so a path that broke apart cannot shrink both.
    set -- $ALL_AGENTS
    if [ "$YAML_READ" -eq $(($# + 2)) ]; then ok "the strict-YAML check read all $(($# + 2)) frontmatters (both skills and every agent)"
    else bad "the strict-YAML check read $YAML_READ of $(($# + 2)) frontmatters (both skills and every agent)"; fi
else
    echo "SKIP-LOUD: python3 with PyYAML not found — strict-YAML frontmatter not checked"
fi

# --- 3. shipped text -----------------------------------------------------------------------------
SHIPPED="$SANDBOX/shipped.txt"; : > "$SHIPPED"
[ ! -f "$MANIFEST" ] || expand_manifest "$MANIFEST" "$ROOT" | grep -v '^MISSING ' > "$SHIPPED"
SHIPPED_COUNT="$(grep -c . "$SHIPPED" || true)"
if [ "$SHIPPED_COUNT" -gt 0 ]; then ok "$SHIPPED_COUNT shipped files to scan"; else bad "no shipped file was found to scan"; fi
# The manifest's own lines and every file its folder entries expand to: a folder entry such as hooks/tests/
# would sweep a house-only suite in without naming it.
{ [ ! -f "$MANIFEST" ] || manifest_entries "$MANIFEST"; cat "$SHIPPED"; } > "$SANDBOX/listed.txt"
HOUSE_HITS="$(house_only "$SANDBOX/listed.txt")"; HOUSE_RC=$?
case "$HOUSE_RC" in
    1) ok "the manifest ships no house-only file (a wiring suite, the publishing script or its suite)" ;;
    0) bad "the manifest ships house-only files: $(printf '%s\n' "$HOUSE_HITS" | while IFS= read -r l; do printf '%s\n' "${l#"$ROOT"/}"; done | LC_ALL=C sort -u | tr '\n' ' ')" ;;
    *) bad "the house-only check could not read the list of shipped files (grep exit $HOUSE_RC)" ;;
esac
ban "$SHIPPED" "a macOS or Linux home path" -E "$HOME_PATH_RE"
ban "$SHIPPED" "a Windows user path" -E "$WINDOWS_PATH_RE"
ban "$SHIPPED" "a private ledger id (RW-NNNN)" -E "$LEDGER_ID_RE"
ban "$SHIPPED" "a private decision-record id (ADR NNNN)" -E "$DECISION_ID_RE"
ban "$SHIPPED" "the headless invocation" -F "$HEADLESS"
PROMPTS="$SANDBOX/prompts.txt"
while IFS= read -r f; do
    case "$f" in "$ROOT"/agents/*|"$ROOT"/skills/*) printf '%s\n' "$f" ;; esac
done < "$SHIPPED" > "$PROMPTS"
ban "$PROMPTS" "an agent or skill promise to stop after a fixed number of minutes" -iE "$TIMED_STOP_RE"

# --- 4. skill shape ------------------------------------------------------------------------------
skill_shape() {
    # skill_shape <skill dir> <expected name>
    local s="$1/SKILL.md" n="$2" d
    [ -f "$s" ] || { bad "$n: SKILL.md is missing"; return; }
    if [ "$(fm_value "$s" name)" = "$n" ]; then ok "$n: frontmatter name matches its folder"; else bad "$n: frontmatter name is '$(fm_value "$s" name)'"; fi
    d="$(fm_value "$s" description | sed 's/^"//; s/"$//')"
    case "$d" in "Use when"*) ok "$n: description starts with 'Use when'" ;; *) bad "$n: description must start with 'Use when'" ;; esac
    case "$d" in *"Do NOT use"*) ok "$n: description states a negative scope" ;; *) bad "$n: description has no 'Do NOT use' clause" ;; esac
    if [ "${#d}" -le "$DESCRIPTION_MAX" ]; then ok "$n: description is at most $DESCRIPTION_MAX characters (${#d})"; else bad "$n: description is ${#d} characters (max $DESCRIPTION_MAX)"; fi
    if grep -qE '^\| *Resource *\| *Load when' "$s"; then ok "$n: has a Resource / Load when table"; else bad "$n: has no '| Resource | Load when… |' table"; fi
    if grep -qiE '^#+ *Anti-patterns' "$s"; then ok "$n: has an anti-patterns section"; else bad "$n: has no anti-patterns section"; fi
    if grep -qi 'required by' "$s" && grep -qi 'house style\|this skill.s additions' "$s"; then ok "$n: checklist separates source-required items from house style"; else bad "$n: checklist is not split into required-by-source and house-style items"; fi
    if find "$1" -type d -name archive | grep -q .; then bad "$n: has an archive/ folder inside the skill"; else ok "$n: no archive/ folder inside the skill"; fi
}
skill_shape "$SKILL_DIR" "$NAME"
skill_shape "$ROOT/skills/apply-rec" "apply-rec"
# The audit costs hours of agents, so nothing may be dispatched before the user answers the preflight.
if [ -f "$SKILL_DIR/SKILL.md" ]; then
    P_ORDER="$(preflight_order "$SKILL_DIR/SKILL.md")"
    if [ "$P_ORDER" = "asks first" ]; then ok "$NAME: the preflight asks with AskUserQuestion before init-run"; else bad "$NAME: the preflight must ask with AskUserQuestion before init-run ($P_ORDER)"; fi
fi
for r in $REQUIRED_RESOURCES; do
    if [ -f "$SKILL_DIR/resources/$r" ]; then ok "resource $r exists"; else bad "resources/$r is missing"; fi
    if [ -f "$SKILL_DIR/SKILL.md" ] && grep -qF "resources/$r" "$SKILL_DIR/SKILL.md"; then ok "SKILL.md points at resources/$r"; else bad "SKILL.md never names resources/$r"; fi
done

# --- 5. skill ↔ helper, agents ↔ schema ----------------------------------------------------------
if [ -x "$HELPER" ]; then
    USAGE="$(bash "$HELPER" --help 2>&1)"
    NAMED="$(grep -oE 'exhaustive_audit_and_review\.sh [a-z][a-z-]+' "$SKILL_DIR/SKILL.md" 2>/dev/null | awk '{print $2}' | sort -u)"
    if [ -n "$NAMED" ]; then ok "SKILL.md names $(printf '%s\n' "$NAMED" | grep -c .) helper subcommands"; else bad "SKILL.md names no helper subcommand (expected 'exhaustive_audit_and_review.sh <subcommand>')"; fi
    for sub in $NAMED; do
        if printf '%s\n' "$USAGE" | grep -qE "(^|[^a-z-])$sub([^a-z-]|\$)"; then ok "helper usage documents '$sub'"; else bad "SKILL.md uses '$sub', which the helper's usage text does not document"; fi
    done
    for enum in 'critical|high|medium|low|info' 'trivial|S|M|L|XL' 'low|med|high'; do
        if printf '%s\n' "$USAGE" | grep -qF "$enum"; then ok "helper usage states the enum $enum"; else bad "helper usage does not state the enum $enum"; fi
    done
    CAPS="$(printf '%s\n' "$USAGE" | grep -oE '(finding|rationale|recommendation|subject|check|category|notes)[[:space:]]*(<=|≤)[[:space:]]*[0-9]+' | sed -E 's/[[:space:]]*(<=|≤)[[:space:]]*/ /' | sort -u)"
    if [ -n "$CAPS" ]; then ok "helper usage states $(printf '%s\n' "$CAPS" | grep -c .) field caps"; else bad "helper usage states no field caps ('<field> <= N')"; fi
    for agent in $FINDING_WRITERS; do
        f="$ROOT/agents/$agent.md"
        [ -f "$f" ] || continue
        for enum in 'critical|high|medium|low|info' 'trivial|S|M|L|XL' 'low|med|high'; do
            if grep -qF "$enum" "$f"; then ok "$agent: states the enum $enum"; else bad "$agent: does not state the enum $enum the helper validates"; fi
        done
        printf '%s\n' "$CAPS" | while read -r field cap; do
            [ -n "$field" ] || continue
            if grep -qE "$field[[:space:]]*(<=|≤)[[:space:]]*$cap([^0-9]|\$)" "$f"; then echo "PASS: $agent: states $field <= $cap"; else echo "FAIL: $agent: does not state '$field <= $cap'"; fi
        done > "$SANDBOX/caps.out"
        while IFS= read -r line; do case "$line" in PASS:*) ok "${line#PASS: }" ;; FAIL:*) bad "${line#FAIL: }" ;; esac; done < "$SANDBOX/caps.out"
    done
else
    bad "the helper is missing or not executable, so the skill/helper and schema checks could not run"
fi

# --- 6. everything parses ------------------------------------------------------------------------
for f in "$HELPER" "$SKILL_DIR/install.sh"; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then ok "$(basename "$f") parses (bash -n)"; else bad "$(basename "$f") has a syntax error"; fi
done
for s in $SUITES; do
    f="$ROOT/hooks/tests/$s"
    [ -f "$f" ] || { bad "suite $s is missing"; continue; }
    if bash -n "$f" 2>/dev/null; then ok "$s parses (bash -n)"; else bad "$s has a syntax error"; fi
done

# --- 7. every shipped suite stops when it cannot create its sandbox ------------------------------
# A suite whose mktemp failed once kept going with an empty sandbox path, worked in the folder it was
# started from and deleted it on exit. Each shipped suite starts here with a TMPDIR that does not exist,
# from a folder that holds one marker file: it must print only its FAIL line, exit 1 and leave the folder
# as it was. A probe never probes again (a suite that regressed would otherwise start itself forever), and
# root is skipped, because a suite that regressed would write at the root of the file system.
if [ -n "${EXHAUSTIVE_AUDIT_SANDBOX_PROBE:-}" ]; then
    :
elif [ "$(id -u)" -eq 0 ]; then
    echo "SKIP-LOUD: running as root: the sandbox probes of section 7 did not run"
else
    for s in $SUITES; do
        f="$ROOT/hooks/tests/$s"
        [ -f "$f" ] || continue
        PROBE="$(mktemp -d "$SANDBOX/probe.XXXXXX")" || { bad "$s: cannot make a probe folder"; continue; }
        printf 'marker\n' > "$PROBE/marker"
        OUT="$(cd "$PROBE" && EXHAUSTIVE_AUDIT_SANDBOX_PROBE=1 TMPDIR="$SANDBOX/no-such-tmpdir" "${BASH:-bash}" "$f" 2>/dev/null)"; RC=$?
        if [ "$RC" -eq 1 ] && [ "$OUT" = "FAIL: cannot create a sandbox" ]; then
            ok "$s stops at once when it cannot create its sandbox"
        else
            bad "$s did not stop with its FAIL line when it could not create its sandbox (exit $RC, $(printf '%s\n' "$OUT" | grep -c .) lines, first: $(printf '%s\n' "$OUT" | head -n 1 | cut -c1-100))"
        fi
        if [ "$(ls -A "$PROBE" 2>/dev/null)" = "marker" ]; then ok "$s leaves the folder it was started from as it was"; else bad "$s changed the folder it was started from (it now holds: $(ls -A "$PROBE" 2>/dev/null | head -5 | tr '\n' ' '))"; fi
    done
fi

echo "----"
echo "$NAME-package: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
