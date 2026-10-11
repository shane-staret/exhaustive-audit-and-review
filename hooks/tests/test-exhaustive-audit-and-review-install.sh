#!/bin/bash
# test-exhaustive-audit-and-review-install.sh — offline tests for the package installer.
#
# Hermetic: the installer and its manifest are found relative to this suite (hooks/tests/ sits two
# levels below the folder that holds skills/, agents/, templates/ and hooks/), every run gets a
# throwaway HOME, and most cases install a FIXTURE package: the installer under test and the real
# package.manifest beside a small stand-in for every file the manifest lists. So the same file runs
# in place under ~/.claude, from a fresh clone of the public repository, and before the rest of the
# package exists. It never touches the user's own config.
#
# Verifies: --help documents every option; a shell that is not bash (zsh) is refused before anything
# changes; the dry run lists exactly the manifest's files (a folder entry expands to its files, never to
# litter: OS files, caches, archives, backups, .git and editor leftovers) and changes nothing; the
# sandbox cleanup never deletes an empty path, /, a relative path or HOME; --yes installs each one with
# its content and mode, records its sha256 in a private installed.sha256 and backs nothing up the first
# time; a second run changes nothing; a newer package updates the files the installer put there, backing
# each one up first; a file it did not put there, or one changed since, is foreign: reported, left
# unchanged, the run ends with exit 2, and --replace <path> replaces it after a backup; a dangling
# symlink is never written through; files the package does not ship are reported, never deleted;
# --opt-in creates a private data folder, a denylist
# that lists no term (and says a term needs at least 4 characters) and a house.conf with every key off,
# and never overwrites either; a manifest line that is absolute, climbs out with .., has an empty or .
# segment or a backslash, repeats a file, or names nothing in the package or a folder holding no file is
# refused by its line number, an empty or missing manifest is refused, and CRLF line endings plan the
# same files; run from inside its own target it copies nothing; CDPATH never redirects a path and a
# target path with a newline is refused; a failure part-way exits 2, says where the backups are and
# still records what it placed, and a data folder that cannot be written exits 2 and says the files
# could not be recorded. The README's quick start runs word for word against a fixture clone. The last
# case installs the real package when every manifest entry exists, and runs the installed copy's own
# package suite from a path that holds a space, its strict-YAML checks included. bash-3.2-safe.
#
# Env: EXHAUSTIVE_AUDIT_PACKAGE_ROOT  the package root (default: two levels above this folder)
#      EXHAUSTIVE_AUDIT_INSTALLER     the install.sh the fixture cases test (default: the package's own)

set -u
unset CDPATH    # an exported CDPATH would redirect this suite's own cd calls
ROOT="${EXHAUSTIVE_AUDIT_PACKAGE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
NAME="exhaustive-audit-and-review"
INSTALLER="${EXHAUSTIVE_AUDIT_INSTALLER:-$ROOT/skills/$NAME/install.sh}"
MANIFEST="$ROOT/skills/$NAME/package.manifest"
HELPER_REL="skills/$NAME/exhaustive_audit_and_review.sh"
DATA_REL=".claude/$NAME"
BACKUPS_REL=".claude/backups/$NAME-install"
HOUSE_KEYS="EXCLUDE MODULE_REGISTRY REPORT_LAYOUT CHECK CONFIG_TEST MAX_LOC_PER_REVIEW RESEARCH_BUDGET"
PINNED_STAMP="20260101T000000Z"     # what the fixed clock in case 16 reports
sandbox_ok() {
    # sandbox_ok <path> -> true only for a path the EXIT trap may delete: absolute, more than slashes, and not
    # HOME. An empty path is the dangerous one: bash's `cd ""` stays where it is, so this suite once worked
    # in, and then deleted, the folder it was started from when mktemp failed.
    local home="${HOME:-}"
    case "$1" in /*[!/]*) ;; *) return 1 ;; esac
    [ "${1%/}" != "${home%/}" ]
}
remove_sandbox() { sandbox_ok "$SANDBOX" || return 0; chmod -R u+rwx "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"; }
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/$NAME-install-test.XXXXXX")" || { echo 'FAIL: cannot create a sandbox'; exit 1; }
# Spell the sandbox physically (TMPDIR often sits behind a symlink), as every path the installer prints
# is then spelled, and work from inside it, so a path resolved against the current folder by mistake
# lands in the sandbox, never in the folder the suite was started from.
[ -d "$SANDBOX" ] && SANDBOX="$(cd "$SANDBOX" && pwd -P)" && sandbox_ok "$SANDBOX" \
    || { echo "FAIL: cannot use the sandbox [$SANDBOX]: not a folder this suite may delete"; exit 1; }
trap remove_sandbox EXIT
cd "$SANDBOX" || exit 1
NL='
'

PASS=0
FAIL=0
SKIP=0
check() {
    # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1 (expected [$2], got [$3])"; fi
}
skip() { SKIP=$((SKIP+1)); echo "SKIP-LOUD: $1"; }   # a test runner can flag a passing suite that skipped checks
yes_no() { if "$@"; then echo yes; else echo no; fi; }
contains() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
count_matching() { printf '%s\n' "$1" | grep -cE -- "$2"; }   # count_matching <text> <extended regex>
# GNU stat takes -c, BSD stat -f; ask once, so each mode check is one process.
if stat -c %a / >/dev/null 2>&1; then MODE_OPT="-c"; MODE_FMT='%a %n'; PERM_FMT='%a'; else MODE_OPT="-f"; MODE_FMT='%Lp %N'; PERM_FMT='%Lp'; fi
perm_of() { stat "$MODE_OPT" "$PERM_FMT" "$1" 2>/dev/null; }
inode_of() { ls -di "$1" 2>/dev/null | awk '{ print $1 }'; }
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA="shasum -a 256"
else SHA="openssl dgst -sha256 -r"; fi
sha_of() { $SHA "$1" 2>/dev/null | awk '{ sub(/^\\/, "", $1); print $1 }'; }
snapshot_of() {
    # snapshot_of <dir> -> every path under it with its mode, then every file's checksum. Two equal
    # snapshots mean nothing was added, removed, rewritten with other content or chmodded.
    (cd "$1" && find . -exec stat "$MODE_OPT" "$MODE_FMT" {} + | LC_ALL=C sort -k2 \
        && find . -type f -exec cksum {} + | LC_ALL=C sort -k3)
}

HOME_N=0
H=""
new_home() {
    # new_home -> sets H to a new HOME holding an empty .claude (a machine where Claude Code has run). The
    # name holds a space, so every case also proves the paths are quoted. It sets a global rather than
    # printing, because a $(...) call would bump the counter in a subshell and hand every case one HOME.
    HOME_N=$((HOME_N+1))
    H="$SANDBOX/home $HOME_N"
    mkdir -p "$H/.claude"
}

manifest_entries() { grep -vE '^[[:space:]]*(#|$)' "$1" | sed 's/[[:space:]]*$//'; }   # as the package suite reads it
FIX_N=0
F=""
stand_in() {
    # stand_in <relative path> -> a small file at $F/<path> (executable for a script), listed as expected
    mkdir -p "$F/$(dirname "$1")"
    printf 'stand-in for %s, version 1\n' "$1" > "$F/$1"
    case "$1" in *.sh) chmod 755 "$F/$1" ;; *) chmod 644 "$F/$1" ;; esac
    printf '%s\n' "$1" >> "$F.expected"
}
new_fixture() {
    # new_fixture -> sets F to a new package root: the installer under test and the real manifest beside a
    # stand-in for every file the manifest lists (two per folder entry, plus the helper in the skill folder),
    # litter the installer must never ship, and files outside the manifest. "$F.expected" lists, sorted,
    # exactly the files an install must place.
    local entry litter
    FIX_N=$((FIX_N+1))
    F="$SANDBOX/package $FIX_N"
    mkdir -p "$F/skills/$NAME" "$F/agents"
    : > "$F.expected"
    cp "$INSTALLER" "$F/skills/$NAME/install.sh" && chmod 755 "$F/skills/$NAME/install.sh"
    cp "$MANIFEST" "$F/skills/$NAME/package.manifest" && chmod 644 "$F/skills/$NAME/package.manifest"
    printf '%s\n' "skills/$NAME/install.sh" "skills/$NAME/package.manifest" >> "$F.expected"
    while IFS= read -r entry; do
        case "$entry" in
            "") ;;
            */) stand_in "${entry}SKILL.md"; stand_in "${entry}resources/notes.md" ;;
            *) [ -e "$F/$entry" ] || stand_in "$entry" ;;
        esac
    done <<< "$(manifest_entries "$MANIFEST" 2>/dev/null)"
    stand_in "$HELPER_REL"
    # Litter inside a folder entry: never installed.
    mkdir -p "$F/skills/$NAME/archive" "$F/skills/apply-rec/__pycache__" "$F/skills/$NAME/.git" "$F/skills/apply-rec/.pytest_cache/v"
    printf 'litter\n' > "$F/skills/$NAME/.DS_Store"
    printf 'an old version\n' > "$F/skills/$NAME/archive/SKILL_old.md"
    printf 'a backup copy\n' > "$F/skills/$NAME/SKILL.md.bak-$PINNED_STAMP"
    printf 'compiled\n' > "$F/skills/apply-rec/__pycache__/notes.cpython-312.pyc"
    printf '[core]\n' > "$F/skills/$NAME/.git/config"
    printf '{}\n' > "$F/skills/apply-rec/.pytest_cache/v/lastfailed"
    # Editor leftovers, at the top of a folder entry and deeper: never installed, and never reported as
    # extra files.
    for litter in 'SKILL.md~' '.SKILL.md.swp' '.SKILL.md.swo' 'SKILL.md.orig' 'SKILL.md.rej' 'SKILL.md.tmp' '.#SKILL.md' '#SKILL.md#'; do
        printf 'editor leftover\n' > "$F/skills/$NAME/$litter"
        printf 'editor leftover\n' > "$F/skills/apply-rec/resources/$litter"
    done
    # Outside the manifest: never installed (a clone keeps README and LICENSE at its root too).
    printf 'not shipped\n' > "$F/agents/not-in-the-manifest.md"
    printf 'the clone README\n' > "$F/README.md"
    printf 'the clone LICENSE\n' > "$F/LICENSE"
    LC_ALL=C sort -u -o "$F.expected" "$F.expected"
}
run_installer() {
    # run_installer <install.sh> <home> [installer args...] -> runs it as a user whose config folder is <home>/.claude
    local installer="$1" h="$2"
    shift 2
    env -u CLAUDE_CONFIG_DIR HOME="$h" bash "$installer" "$@"
}
fx() { local h="$1"; shift; run_installer "$F/skills/$NAME/install.sh" "$h" "$@"; }   # the current fixture's installer

paths_with() {
    # paths_with <status> <installer output> -> the path of every line with that status, notes cut, sorted
    local prefix line
    prefix="$(printf '  %-7s ' "$1")"
    printf '%s\n' "$2" | while IFS= read -r line; do
        case "$line" in "$prefix"*) line="${line#"$prefix"}"; printf '%s\n' "${line%%  (*}" ;; esac
    done | LC_ALL=C sort
}
all_installed() {
    # all_installed <package root> <config folder> [paths to leave out] -> "yes" when every expected file is in
    # the folder with the package's content and mode, else the first line of checksums or modes that differs
    local pkg="$1" cfg="$2" leave="${3:-}" rel want got
    set --
    while IFS= read -r rel; do
        case " $leave " in *" $rel "*) continue ;; esac
        set -- "$@" "./$rel"
    done < "$pkg.expected"
    [ "$#" -gt 0 ] || { echo "no file is expected"; return; }
    want="$( (cd "$pkg" && cksum "$@"; stat "$MODE_OPT" "$MODE_FMT" "$@") 2>&1)"
    got="$( (cd "$cfg" && cksum "$@"; stat "$MODE_OPT" "$MODE_FMT" "$@") 2>&1)"
    if [ "$want" = "$got" ]; then echo yes; return; fi
    printf '%s\n' "$want" > "$SANDBOX/want.txt"
    printf '%s\n' "$got" > "$SANDBOX/got.txt"
    echo "differs: $(diff "$SANDBOX/want.txt" "$SANDBOX/got.txt" | grep -m 1 '^>')"
}
installed_files() { (cd "$1" && find . -type f ! -path "./$NAME/*" ! -path './backups/*' | sed 's|^\./||' | LC_ALL=C sort); }
expected_record() {
    # expected_record <package root> -> the installed.sha256 an install of every expected file must leave:
    # "<sha256>  <path>" per file in path order, hashed here with one run of the hash tool
    local pkg="$1" rel
    set --
    while IFS= read -r rel; do set -- "$@" "$rel"; done < "$pkg.expected"
    (cd "$pkg" && $SHA "$@" 2>/dev/null) | awk '{ h = $1; sub(/^\\/, "", h); p = $0; sub(/^[^ ]* [ *]?/, "", p); print h "  " p }'
}
record_line() { awk -v p="$2" 'substr($0, 67) == p' "$1/$DATA_REL/installed.sha256" 2>/dev/null; }   # record_line <home> <path>
active_lines() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -c '[^[:space:]]'; }
backup_runs() { ls -1 "$1/$BACKUPS_REL" 2>/dev/null | grep -c .; }
first_backup() { ls -1d "$1/$BACKUPS_REL"/*/ 2>/dev/null | head -n 1; }

# 0. The installer and its manifest ship, and the installer parses.
check "install.sh exists" yes "$(yes_no test -s "$INSTALLER")"
check "install.sh parses (bash -n)" yes "$(yes_no bash -n "$INSTALLER")"
check "package.manifest exists in the package" yes "$(yes_no test -s "$MANIFEST")"
# The EXIT trap deletes recursively, so its guard must refuse every path that is not a sandbox.
SANDBOX_VERDICTS=""
for P in "" / // relative/path "${HOME:-/}" "${HOME:-/}/" "$SANDBOX"; do SANDBOX_VERDICTS="$SANDBOX_VERDICTS $(yes_no sandbox_ok "$P")"; done
check "control: the sandbox cleanup refuses '', /, //, a relative path and HOME, and accepts the sandbox" \
    " no no no no no no yes" "$SANDBOX_VERDICTS"

# 1. Usage: --help documents every option the parser accepts; a bad option is refused.
new_fixture
new_home
HELP="$(fx "$H" --help 2>&1)"; RC=$?
check "--help exits 0" 0 "$RC"
check "--help prints the usage" yes "$(contains "$HELP" "Usage:")"
# Every option parse_args matches must be described in --help, on a line that starts with it
# ("  --yes ...", "  -h, --help ..."): an option the help leaves out is one nobody finds.
PARSED_OPTIONS="$(awk '/^parse_args\(\) \{/ { on = 1; next } on && /^}/ { exit } on' "$INSTALLER" 2>/dev/null \
    | grep -oE '^[[:space:]]+-[-a-z|]+\)' | tr -d ' )' | tr '|' '\n')"
check "the parser's options were found (--help among them)" yes \
    "$(printf '%s\n' "$PARSED_OPTIONS" | grep -qx -- '--help' && echo yes || echo no)"
UNDOCUMENTED=""
for OPT in $PARSED_OPTIONS; do
    printf '%s\n' "$HELP" | grep -qE -- "^[[:space:]]+(-[-a-z]+, )*$OPT([ ,]|\$)" || UNDOCUMENTED="$UNDOCUMENTED $OPT"
done
check "--help describes every option the parser accepts" "" "$UNDOCUMENTED"
for WORD in "dry run" "--yes" "--replace <path>" "--opt-in" "--target <dir>" "CLAUDE_CONFIG_DIR" "foreign" \
            "installed.sha256" "never deletes" "Exit:"; do
    check "--help explains '$WORD'" yes "$(contains "$HELP" "$WORD")"
done
OUT="$(fx "$H" --frobnicate 2>&1)"; RC=$?
check "an unknown option exits 1" 1 "$RC"
check "an unknown option is named" yes "$(contains "$OUT" "--frobnicate")"
OUT="$(fx "$H" --target 2>&1)"; RC=$?
check "--target without a folder exits 1" 1 "$RC"
OUT="$(fx "$H" --replace 2>&1)"; RC=$?
check "--replace without a path exits 1" 1 "$RC"
BEFORE="$(snapshot_of "$H")"
OUT="$(fx "$H" --yes --replace agents/not-in-the-manifest.md 2>&1)"; RC=$?
check "--replace naming a file the package does not install exits 1" 1 "$RC"
check "--replace naming a file the package does not install says so" yes "$(contains "$OUT" "not a file this package installs")"
check "--replace naming a file the package does not install changes nothing" "$BEFORE" "$(snapshot_of "$H")"

# 2. Missing tools: python3, git and curl only warn, on stderr, so stdout stays the plan.
TOOLS_ONLY="$SANDBOX/tools-only"; mkdir -p "$TOOLS_ONLY"
for TOOL in bash env dirname basename find sort cmp grep sed awk mkdir cp chmod mv rm cat date mktemp readlink ls \
            tr cut head tail wc uniq stat sha256sum shasum openssl perl; do
    TOOL_PATH="$(command -v "$TOOL" 2>/dev/null)" && ln -s "$TOOL_PATH" "$TOOLS_ONLY/$TOOL"
done
new_home
OUT="$(PATH="$TOOLS_ONLY" fx "$H" 2>"$SANDBOX/stderr.txt")"; RC=$?
check "without python3, git and curl the dry run still exits 0" 0 "$RC"
check "the missing-tool warnings stay off stdout" 0 "$(count_matching "$OUT" 'was not found')"
check "one warning each for curl, git and python3 goes to stderr" "curl git python3" \
    "$(grep -oE '(python3|git|curl) was not found' "$SANDBOX/stderr.txt" | awk '{ print $1 }' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"

# 3. No config folder: refuse rather than invent one.
NOCFG="$SANDBOX/no-config-home"; mkdir -p "$NOCFG"
OUT="$(fx "$NOCFG" --yes 2>&1)"; RC=$?
check "a missing config folder exits 1" 1 "$RC"
check "a missing config folder is not created" no "$(yes_no test -e "$NOCFG/.claude")"

# 3b. Run by a shell that is not bash (zsh is the macOS login shell, and it parses this file), the installer
#     refuses before it changes anything, rather than running under another shell's rules.
if command -v zsh >/dev/null 2>&1; then
    new_fixture
    new_home
    BEFORE="$(snapshot_of "$H")"
    OUT="$(env -u CLAUDE_CONFIG_DIR HOME="$H" zsh "$F/skills/$NAME/install.sh" --yes 2>&1)"; RC=$?
    check "run by zsh, the installer exits 1" 1 "$RC"
    check "run by zsh, it says it needs bash" yes "$(contains "$OUT" "needs bash")"
    check "run by zsh, it changes nothing" "$BEFORE" "$(snapshot_of "$H")"
else
    skip "zsh is not installed, so the refusal of a shell that is not bash did not run"
fi

# 4. The dry run lists exactly the manifest's files, one copy line each, and changes nothing.
new_fixture
new_home
BEFORE="$(snapshot_of "$H")"
OUT="$(fx "$H" 2>&1)"; RC=$?
check "the dry run exits 0" 0 "$RC"
check "the dry run says it is one" yes "$(contains "$OUT" "DRY RUN")"
check "the dry run offers exactly the manifest's files (folders expanded; litter and unlisted files left out)" \
    "$(cat "$F.expected")" "$(paths_with copy "$OUT")"
check "the dry run prints one copy line per file" "$(grep -c . "$F.expected")" "$(count_matching "$OUT" '^  copy    ')"
check "a copy line is two spaces, the padded status word and the path" 1 \
    "$(count_matching "$OUT" '^  copy    agents/code-reviewer\.md$')"
check "the dry run reports no other status" 0 "$(count_matching "$OUT" '^  (update|mode|same|extra|foreign) ')"
check "the dry run changes nothing" "$BEFORE" "$(snapshot_of "$H")"

# 5. --yes installs every file with its content and mode, records each one, and backs nothing up.
OUT="$(umask 022; fx "$H" --yes 2>&1)"; RC=$?
check "--yes exits 0" 0 "$RC"
check "--yes installs every file with the package's content and mode" yes "$(all_installed "$F" "$H/.claude")"
check "--yes installs nothing else (no litter, nothing outside the manifest)" "$(cat "$F.expected")" "$(installed_files "$H/.claude")"
check "the helper is executable after install" yes "$(yes_no test -x "$H/.claude/$HELPER_REL")"
check "the installer is executable after install" yes "$(yes_no test -x "$H/.claude/skills/$NAME/install.sh")"
check "a first install backs nothing up" 0 "$(backup_runs "$H")"
check "the data folder is private (mode 700, whatever the umask)" 700 "$(perm_of "$H/$DATA_REL")"
check "installed.sha256 is private (mode 600)" 600 "$(perm_of "$H/$DATA_REL/installed.sha256")"
check "installed.sha256 holds one '<sha256>  <path>' line per installed file, in path order" \
    "$(expected_record "$F")" "$(cat "$H/$DATA_REL/installed.sha256" 2>/dev/null)"
check "--yes alone writes no denylist and no house.conf" "installed.sha256" "$(ls -A "$H/$DATA_REL" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# 6. A second run finds everything in place and changes nothing, not even the record.
BEFORE="$(snapshot_of "$H")"
INODE="$(inode_of "$H/$DATA_REL/installed.sha256")"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "a second --yes exits 0" 0 "$RC"
check "a second --yes reports every file unchanged" "$(cat "$F.expected")" "$(paths_with same "$OUT")"
check "a second --yes copies, updates and flags nothing" 0 "$(count_matching "$OUT" '^  (copy|update|mode|foreign|extra) ')"
check "a second --yes changes nothing" "$BEFORE" "$(snapshot_of "$H")"
check "a second --yes does not rewrite installed.sha256" "$INODE" "$(inode_of "$H/$DATA_REL/installed.sha256")"

# 6b. A script whose content is unchanged but which lost its executable bit is repaired and reported as a
#     mode fix; the dry run only reports it.
chmod -x "$H/.claude/$HELPER_REL"
OUT="$(fx "$H" 2>&1)"
check "the dry run reports a lost executable bit as a mode fix" "$HELPER_REL" "$(paths_with mode "$OUT")"
check "the dry run leaves the bit alone" no "$(yes_no test -x "$H/.claude/$HELPER_REL")"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "a run that repairs an executable bit exits 0" 0 "$RC"
check "the script is executable again" yes "$(yes_no test -x "$H/.claude/$HELPER_REL")"
check "a mode fix backs nothing up" 0 "$(backup_runs "$H")"

# 7. A newer package updates the files this installer put there, after backing each one up.
cp "$H/.claude/agents/code-reviewer.md" "$SANDBOX/v1-code-reviewer.md"
cp "$H/.claude/skills/$NAME/SKILL.md" "$SANDBOX/v1-SKILL.md"
printf 'version 2\n' >> "$F/agents/code-reviewer.md"
printf 'version 2\n' >> "$F/skills/$NAME/SKILL.md"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "an update run exits 0" 0 "$RC"
check "exactly the changed files are reported as updates" "agents/code-reviewer.md${NL}skills/$NAME/SKILL.md" "$(paths_with update "$OUT")"
check "the installed copies match the newer package" yes "$(all_installed "$F" "$H/.claude")"
check "exactly one backup folder was made" 1 "$(backup_runs "$H")"
BK="$(first_backup "$H")"
[ -n "$BK" ] || BK="$SANDBOX/no-backup-folder/"
check "the backup folder is named <UTC>.<random>" yes \
    "$(basename "$BK" | grep -qE '^[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{6}$' && echo yes || echo no)"
check "the backup holds the old agent at its own path" yes "$(yes_no cmp -s "$SANDBOX/v1-code-reviewer.md" "${BK}agents/code-reviewer.md")"
check "the backup holds the old SKILL.md at its own path" yes "$(yes_no cmp -s "$SANDBOX/v1-SKILL.md" "${BK}skills/$NAME/SKILL.md")"
check "the backup holds nothing else" 2 "$(find "$BK" -type f 2>/dev/null | grep -c .)"
check "no backup copy lands inside skills/ or agents/" "" "$(find "$H/.claude/skills" "$H/.claude/agents" -name '*.bak*' 2>/dev/null)"
check "installed.sha256 now records the newer versions" "$(expected_record "$F")" "$(cat "$H/$DATA_REL/installed.sha256" 2>/dev/null)"

# 8. A file the installer did not put there is foreign: reported, left unchanged and never backed up, and
#    the run ends with exit 2 until --replace (repeatable) names it.
new_fixture
new_home
mkdir -p "$H/.claude/agents"
for AGENT in code-reviewer project-health runbook-author; do
    printf 'my own %s\n' "$AGENT" > "$H/.claude/agents/$AGENT.md"
    cp "$H/.claude/agents/$AGENT.md" "$SANDBOX/own-$AGENT.md"
done
FOREIGN3="agents/code-reviewer.md${NL}agents/project-health.md${NL}agents/runbook-author.md"
BEFORE="$(snapshot_of "$H")"
OUT="$(fx "$H" 2>&1)"; RC=$?
check "a dry run that finds foreign files exits 2" 2 "$RC"
check "the dry run reports each one as foreign" "$FOREIGN3" "$(paths_with foreign "$OUT")"
check "a dry run with foreign files changes nothing" "$BEFORE" "$(snapshot_of "$H")"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "--yes with foreign files exits 2" 2 "$RC"
check "--yes reports each one as foreign" "$FOREIGN3" "$(paths_with foreign "$OUT")"
check "a foreign file is noted as not installed by this installer" yes "$(contains "$OUT" "not installed by this installer")"
check "the run says to re-run with --replace for each file to replace" yes "$(contains "$OUT" "--replace agents/code-reviewer.md")"
KEPT=0
for AGENT in code-reviewer project-health runbook-author; do
    cmp -s "$SANDBOX/own-$AGENT.md" "$H/.claude/agents/$AGENT.md" && KEPT=$((KEPT+1))
done
check "every foreign file is left unchanged" 3 "$KEPT"
check "every other file is installed" yes \
    "$(all_installed "$F" "$H/.claude" "agents/code-reviewer.md agents/project-health.md agents/runbook-author.md")"
check "a foreign file is not recorded as installed" "" "$(record_line "$H" agents/code-reviewer.md)"
check "a foreign file left in place is not backed up" 0 "$(backup_runs "$H")"
OUT="$(fx "$H" --yes --replace agents/code-reviewer.md --replace agents/project-health.md 2>&1)"; RC=$?
check "--replace twice, with a third foreign file left, exits 2" 2 "$RC"
check "the two named files are reported as updates" "agents/code-reviewer.md${NL}agents/project-health.md" "$(paths_with update "$OUT")"
check "the file not named stays foreign" "agents/runbook-author.md" "$(paths_with foreign "$OUT")"
check "the named files now match the package" yes "$(all_installed "$F" "$H/.claude" "agents/runbook-author.md")"
check "the file not named is unchanged" yes "$(yes_no cmp -s "$SANDBOX/own-runbook-author.md" "$H/.claude/agents/runbook-author.md")"
BK="$(first_backup "$H")"
[ -n "$BK" ] || BK="$SANDBOX/no-backup-folder/"
check "the user's own reviewer was backed up first" yes "$(yes_no cmp -s "$SANDBOX/own-code-reviewer.md" "${BK}agents/code-reviewer.md")"
check "the user's own project-health was backed up first" yes "$(yes_no cmp -s "$SANDBOX/own-project-health.md" "${BK}agents/project-health.md")"
check "a replaced file is recorded with its new sha256" "$(sha_of "$F/agents/code-reviewer.md")  agents/code-reviewer.md" \
    "$(record_line "$H" agents/code-reviewer.md)"
OUT="$(fx "$H" --yes --replace agents/runbook-author.md 2>&1)"; RC=$?
check "once no foreign file is left, the run exits 0" 0 "$RC"
check "and nothing is reported foreign" "" "$(paths_with foreign "$OUT")"

# 8b. A file that was already identical to the package's before the first install is recorded, so a newer
#     package updates it like any file the installer placed.
new_fixture
new_home
mkdir -p "$H/.claude/agents"
cp "$F/agents/code-reviewer.md" "$H/.claude/agents/code-reviewer.md"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "an identical file already in place is reported unchanged" yes "$(paths_with same "$OUT" | grep -qx agents/code-reviewer.md && echo yes || echo no)"
check "an identical file already in place is recorded" "$(sha_of "$F/agents/code-reviewer.md")  agents/code-reviewer.md" \
    "$(record_line "$H" agents/code-reviewer.md)"
printf 'version 2\n' >> "$F/agents/code-reviewer.md"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "a newer package updates it (exit 0)" 0 "$RC"
check "it is reported as an update" "agents/code-reviewer.md" "$(paths_with update "$OUT")"

# 9. A file this installer put there but the user changed since is foreign too, even when the package moves on.
new_fixture
new_home
fx "$H" --yes >/dev/null 2>&1
V1_RECORD="$(sha_of "$H/.claude/agents/project-health.md")  agents/project-health.md"   # what was placed
check "the installed file is recorded as placed" "$V1_RECORD" "$(record_line "$H" agents/project-health.md)"
printf 'my local tweak\n' >> "$H/.claude/agents/project-health.md"
cp "$H/.claude/agents/project-health.md" "$SANDBOX/tweaked-project-health.md"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "an edited file makes the run exit 2" 2 "$RC"
check "the edited file is reported as foreign" "agents/project-health.md" "$(paths_with foreign "$OUT")"
check "the note says it was changed since it was installed" yes "$(contains "$OUT" "changed since")"
check "the edit is kept" yes "$(yes_no cmp -s "$SANDBOX/tweaked-project-health.md" "$H/.claude/agents/project-health.md")"
printf 'version 2\n' >> "$F/agents/project-health.md"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "a newer package does not overwrite an edited file either (exit 2)" 2 "$RC"
check "the edit survives the newer package" yes "$(yes_no cmp -s "$SANDBOX/tweaked-project-health.md" "$H/.claude/agents/project-health.md")"
check "its record still names what the installer put there" "$V1_RECORD" "$(record_line "$H" agents/project-health.md)"
check "an edited file left in place is not backed up" 0 "$(backup_runs "$H")"
OUT="$(fx "$H" --yes --replace agents/project-health.md 2>&1)"; RC=$?
check "--replace takes the newer package over the edit (exit 0)" 0 "$RC"
check "the replaced file matches the newer package" yes "$(yes_no cmp -s "$F/agents/project-health.md" "$H/.claude/agents/project-health.md")"
BK="$(first_backup "$H")"
[ -n "$BK" ] || BK="$SANDBOX/no-backup-folder/"
check "the backup keeps the edit" yes "$(yes_no cmp -s "$SANDBOX/tweaked-project-health.md" "${BK}agents/project-health.md")"

# 10. A dangling symlink where a package file goes is foreign: never written through.
new_fixture
new_home
mkdir -p "$H/.claude/agents" "$SANDBOX/link-dest"
ln -s "$SANDBOX/link-dest/code-reviewer.md" "$H/.claude/agents/code-reviewer.md"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "a dangling symlink makes the run exit 2" 2 "$RC"
check "a dangling symlink is reported as foreign" "agents/code-reviewer.md" "$(paths_with foreign "$OUT")"
check "the link is still a link" yes "$(yes_no test -L "$H/.claude/agents/code-reviewer.md")"
check "nothing was written through it" no "$(yes_no test -e "$SANDBOX/link-dest/code-reviewer.md")"

# 11. Files the package does not ship are reported under its folders and never deleted.
new_fixture
new_home
fx "$H" --yes >/dev/null 2>&1
printf 'my notes\n' > "$H/.claude/skills/$NAME/resources/my-notes.md"
printf 'local notes\n' > "$H/.claude/skills/apply-rec/local-notes.md"
printf 'my own agent\n' > "$H/.claude/agents/my-own-agent.md"
OUT="$(fx "$H" --yes 2>&1)"; RC=$?
check "a run with extra files exits 0" 0 "$RC"
check "files the package does not ship are reported under its folders" \
    "skills/apply-rec/local-notes.md${NL}skills/$NAME/resources/my-notes.md" "$(paths_with extra "$OUT")"
check "extra files are never deleted" yes \
    "$( [ -f "$H/.claude/skills/$NAME/resources/my-notes.md" ] && [ -f "$H/.claude/skills/apply-rec/local-notes.md" ] && echo yes || echo no)"
check "a file outside the package's folders is not reported" no "$(contains "$OUT" "my-own-agent.md")"
check "and is left alone" yes "$(yes_no test -f "$H/.claude/agents/my-own-agent.md")"

# 12. --opt-in: a private data folder, a denylist that lists no term (research stays refused) and a house.conf
#     with every key off; neither file is ever overwritten, nor written through a dangling link.
new_fixture
new_home
BEFORE="$(snapshot_of "$H")"
OUT="$(fx "$H" --opt-in 2>&1)"; RC=$?
check "an --opt-in dry run exits 0" 0 "$RC"
check "an --opt-in dry run changes nothing" "$BEFORE" "$(snapshot_of "$H")"
check "an --opt-in dry run names the denylist and house.conf" "yes yes" "$(contains "$OUT" "denylist.txt") $(contains "$OUT" "house.conf")"
OUT="$(umask 022; fx "$H" --yes --opt-in 2>&1)"; RC=$?
DATA="$H/$DATA_REL"
check "--opt-in exits 0" 0 "$RC"
check "the data folder is private (mode 700, whatever the umask)" 700 "$(perm_of "$DATA")"
check "the denylist is private (mode 600)" 600 "$(perm_of "$DATA/denylist.txt")"
check "house.conf is private (mode 600)" 600 "$(perm_of "$DATA/house.conf")"
check "the denylist explains itself" yes "$(yes_no test -s "$DATA/denylist.txt")"
check "the denylist lists no term" 0 "$(active_lines "$DATA/denylist.txt")"
check "the denylist says research questions are refused until it lists a term" yes \
    "$(grep -qi 'refused until' "$DATA/denylist.txt" 2>/dev/null && echo yes || echo no)"
check "the denylist says a term needs at least 4 characters, because a shorter one is ignored" "yes yes" \
    "$(grep -qi 'at least 4 characters' "$DATA/denylist.txt" 2>/dev/null && echo yes || echo no) $(grep -qi 'ignored' "$DATA/denylist.txt" 2>/dev/null && echo yes || echo no)"
check "house.conf turns nothing on" 0 "$(active_lines "$DATA/house.conf")"
for KEY in $HOUSE_KEYS; do
    check "house.conf explains $KEY= on one commented-out line" 1 "$(grep -cE "^#[[:space:]]*$KEY=" "$DATA/house.conf" 2>/dev/null)"
done
printf 'acme-private-term\n' > "$DATA/denylist.txt"
printf 'EXCLUDE=private-folder\n' > "$DATA/house.conf"
OUT="$(fx "$H" --yes --opt-in 2>&1)"; RC=$?
check "a second --opt-in exits 0" 0 "$RC"
check "an existing denylist is never overwritten" "acme-private-term" "$(cat "$DATA/denylist.txt")"
check "an existing house.conf is never overwritten" "EXCLUDE=private-folder" "$(cat "$DATA/house.conf")"
new_home
fx "$H" --yes >/dev/null 2>&1
OUT="$(umask 022; fx "$H" --yes --opt-in 2>&1)"; RC=$?
check "--opt-in into the data folder an earlier install made exits 0" 0 "$RC"
check "the denylist written there is private too (mode 600)" 600 "$(perm_of "$H/$DATA_REL/denylist.txt")"
check "and so is house.conf (mode 600)" 600 "$(perm_of "$H/$DATA_REL/house.conf")"
new_home
mkdir -p "$H/$DATA_REL" "$SANDBOX/elsewhere"
ln -s "$SANDBOX/elsewhere/denylist.txt" "$H/$DATA_REL/denylist.txt"
OUT="$(fx "$H" --yes --opt-in 2>&1)"; RC=$?
check "a dangling denylist link is left as it is (exit 0)" 0 "$RC"
check "nothing is written through a dangling denylist link" no "$(yes_no test -e "$SANDBOX/elsewhere/denylist.txt")"

# 13. A manifest line that is absolute, climbs out with .., has an empty or . segment or a backslash, repeats
#     a file, names a folder without its /, names a folder that holds no file, or names nothing in the
#     package is refused by its line number before anything changes, and so is a manifest that lists no
#     file or is missing. Each bad line is otherwise valid, so only the guard under test can refuse it, and
#     that guard's own words are asserted.
manifest_refused() {
    # manifest_refused <description> <words only that guard says> [line number] -> the current fixture's
    # installer, run with --yes, exits 1, names that line, says why and changes nothing
    new_home
    BEFORE="$(snapshot_of "$H")"
    OUT="$(fx "$H" --yes 2>&1)"; RC=$?
    check "$1: exits 1" 1 "$RC"
    [ -z "${3:-}" ] || check "$1: names line $3" yes "$(contains "$OUT" "line $3:")"
    check "$1: says why ('$2')" yes "$(contains "$OUT" "$2")"
    check "$1: changes nothing" "$BEFORE" "$(snapshot_of "$H")"
}
bad_manifest_case() {
    # bad_manifest_case <description> <bad line> <words only that guard says> [function that prepares the fixture]
    new_fixture
    [ -z "${4:-}" ] || "$4"
    printf '%s\n' "$2" >> "$F/skills/$NAME/package.manifest"
    manifest_refused "$1" "$3" "$(wc -l < "$F/skills/$NAME/package.manifest" | tr -d ' ')"
}
plant_backslash_name() { printf 'a file whose name holds a backslash\n' > "$F/agents\\backslash.md"; }   # so the line names a real file
plant_empty_folder() { mkdir -p "$F/skills/empty-folder"; }
bad_manifest_case "an absolute path" "/etc/hosts" "is an absolute path"
bad_manifest_case "a .. segment" "agents/../agents/code-reviewer.md" "has a .. segment"
bad_manifest_case "an empty segment" "agents//not-in-the-manifest.md" "has an empty or . segment"
bad_manifest_case "a . segment" "./agents/not-in-the-manifest.md" "has an empty or . segment"
bad_manifest_case "a backslash" 'agents\backslash.md' "has a backslash" plant_backslash_name
bad_manifest_case "a repeated line" "agents/code-reviewer.md" "already listed"
bad_manifest_case "a file a folder entry already covers" "skills/apply-rec/SKILL.md" "already listed"
bad_manifest_case "a file missing from the package" "agents/no-such-agent.md" "is not in the package"
bad_manifest_case "a folder missing from the package" "skills/no-such-skill/" "is not in the package"
bad_manifest_case "a folder named without its trailing /" "templates" "is a folder"
bad_manifest_case "a folder entry that holds no file" "skills/empty-folder/" "holds no file to install" plant_empty_folder
new_fixture
printf '# a manifest that lists nothing\n\n   \n' > "$F/skills/$NAME/package.manifest"
manifest_refused "a manifest of comments and blank lines" "lists no file"
new_fixture
: > "$F/skills/$NAME/package.manifest"
manifest_refused "an empty manifest" "lists no file"
new_fixture
mv "$F/skills/$NAME/package.manifest" "$F/skills/$NAME/package.manifest.moved-away"
manifest_refused "a missing manifest" "no package.manifest beside the installer"

# 13b. A manifest saved with Windows line endings (CR LF) plans exactly the files the clean one does.
new_fixture
new_home
awk '{ printf "%s\r\n", $0 }' "$F/skills/$NAME/package.manifest" > "$SANDBOX/crlf.manifest"
cp "$SANDBOX/crlf.manifest" "$F/skills/$NAME/package.manifest"
check "control: every line of the CRLF manifest ends in CR LF" "$(grep -c . "$SANDBOX/crlf.manifest")" \
    "$(grep -c "$(printf '\r')\$" "$F/skills/$NAME/package.manifest")"
OUT="$(fx "$H" 2>&1)"; RC=$?
check "a CRLF manifest: the dry run exits 0" 0 "$RC"
check "a CRLF manifest plans exactly the files the clean one does" "$(cat "$F.expected")" "$(paths_with copy "$OUT")"

# 14. Run from inside its own target, the installer copies nothing.
new_fixture
new_home
fx "$H" --yes >/dev/null 2>&1
BEFORE="$(snapshot_of "$H")"
OUT="$(run_installer "$H/.claude/skills/$NAME/install.sh" "$H" --yes 2>&1)"; RC=$?
check "in place: exits 0" 0 "$RC"
check "in place: says it is already installed there" yes "$(contains "$OUT" "already installed here")"
check "in place: lists no file" 0 "$(count_matching "$OUT" '^  (copy|update|mode|same|foreign|extra) ')"
check "in place: nothing changes" "$BEFORE" "$(snapshot_of "$H")"
BEFORE="$(snapshot_of "$F")"
OUT="$(fx "$H" --yes --target "$F" 2>&1)"; RC=$?
check "a target that is the package itself exits 0" 0 "$RC"
check "a target that is the package itself gets nothing" "$BEFORE" "$(snapshot_of "$F")"

# 15. Paths are entered literally: an exported CDPATH never redirects a relative --target or the installer's
#     view of its own package, and a target path holding a newline is refused.
CDP="$SANDBOX/cdpath"; mkdir -p "$CDP/work/rel-target" "$CDP/decoy/rel-target"
BEFORE="$(snapshot_of "$CDP/decoy")"
new_fixture
new_home
OUT="$( (cd "$CDP/work" && CDPATH="$CDP/decoy" fx "$H" --yes --target rel-target) 2>&1)"; RC=$?
check "a relative --target under an exported CDPATH exits 0" 0 "$RC"
check "a relative --target is the folder in the current directory, not one CDPATH names" yes "$(all_installed "$F" "$CDP/work/rel-target")"
check "nothing is written under the folder CDPATH names" "$BEFORE" "$(snapshot_of "$CDP/decoy")"
new_home
OUT="$( (cd "$F/skills" && env -u CLAUDE_CONFIG_DIR CDPATH=. HOME="$H" bash "$NAME/install.sh" --target "$H/.claude") 2>&1)"; RC=$?
check "run by a relative path under CDPATH=., the installer exits 0" 0 "$RC"
check "and names its own package folder once" "  package: $F" "$(printf '%s\n' "$OUT" | grep '^  package:')"
check "and still reads its own manifest" "$(grep -c . "$F.expected")" "$(count_matching "$OUT" '^  copy    ')"
NLDIR="$SANDBOX/new${NL}line"; mkdir -p "$NLDIR"
new_home
OUT="$(fx "$H" --yes --target "$NLDIR" 2>&1)"; RC=$?
check "a target path holding a newline exits 1" 1 "$RC"
check "a target path holding a newline is refused by name" yes "$(contains "$OUT" "newline")"
check "nothing is installed into a folder whose path holds a newline" "" "$(ls -A "$NLDIR")"

# 16. Two update runs in one second never share a backup folder (a fixed clock first on PATH makes both see
#     the same second); a target that cannot be written, or a copy that fails part-way, exits 2 and says
#     what it could not do, where the backups are, and still records the files it placed.
FIXED_CLOCK="$SANDBOX/fixed-clock"; mkdir -p "$FIXED_CLOCK"
printf '#!/bin/sh\necho %s\n' "$PINNED_STAMP" > "$FIXED_CLOCK/date"; chmod +x "$FIXED_CLOCK/date"
new_fixture
new_home
fx "$H" --yes >/dev/null 2>&1
cp "$H/.claude/agents/code-reviewer.md" "$SANDBOX/clock-v1.md"
printf 'version 2\n' >> "$F/agents/code-reviewer.md"
PATH="$FIXED_CLOCK:$PATH" fx "$H" --yes >/dev/null 2>&1
cp "$H/.claude/agents/code-reviewer.md" "$SANDBOX/clock-v2.md"
printf 'version 3\n' >> "$F/agents/code-reviewer.md"
PATH="$FIXED_CLOCK:$PATH" fx "$H" --yes >/dev/null 2>&1
check "two update runs in the same second make two backup folders" 2 "$(backup_runs "$H")"
check "both backup folders are named for that second" 2 "$(ls -1 "$H/$BACKUPS_REL" 2>/dev/null | grep -c "^$PINNED_STAMP\.")"
KEPT=0
for BK in "$H/$BACKUPS_REL"/*/; do
    cmp -s "$SANDBOX/clock-v1.md" "${BK}agents/code-reviewer.md" && KEPT=$((KEPT+1))
    cmp -s "$SANDBOX/clock-v2.md" "${BK}agents/code-reviewer.md" && KEPT=$((KEPT+1))
done
check "each run's backup keeps its own copy (the first is never overwritten)" 2 "$KEPT"
if [ "$(id -u)" -ne 0 ]; then
    new_fixture
    new_home
    chmod 555 "$H/.claude"
    OUT="$(fx "$H" --yes 2>&1)"; RC=$?
    chmod 755 "$H/.claude"
    check "an unwritable target exits 2" 2 "$RC"
    check "an unwritable target is named in the message" yes "$(contains "$OUT" "could not copy")"

    new_fixture
    new_home
    fx "$H" --yes >/dev/null 2>&1
    printf 'version 2\n' >> "$F/skills/$NAME/SKILL.md"           # early in the manifest's order
    printf 'version 2\n' >> "$F/templates/testing_standard.md"   # late in it
    OLD_LATE_RECORD="$(sha_of "$H/.claude/templates/testing_standard.md")  templates/testing_standard.md"
    chmod 444 "$H/.claude/templates/testing_standard.md"         # it is backed up, then cannot be replaced
    OUT="$(fx "$H" --yes 2>&1)"; RC=$?
    chmod 644 "$H/.claude/templates/testing_standard.md"
    BK="$(first_backup "$H")"
    [ -n "$BK" ] || BK="NO-BACKUP-FOLDER-WAS-MADE/"   # an empty needle would match any output
    check "a copy that fails part-way exits 2" 2 "$RC"
    check "the failure names the backup folder already in use" yes "$(contains "$OUT" "${BK%/}")"
    check "a file placed before the failure is recorded with its new sha256" \
        "$(sha_of "$F/skills/$NAME/SKILL.md")  skills/$NAME/SKILL.md" "$(record_line "$H" "skills/$NAME/SKILL.md")"
    check "the file that could not be replaced keeps its old record" "$OLD_LATE_RECORD" "$(record_line "$H" templates/testing_standard.md)"

    new_fixture
    new_home
    mkdir -p "$H/$DATA_REL" && chmod 555 "$H/$DATA_REL"
    OUT="$(fx "$H" --yes 2>&1)"; RC=$?
    chmod 755 "$H/$DATA_REL"
    check "a data folder that cannot be written exits 2" 2 "$RC"
    check "and says the files are in place but could not be recorded" yes "$(contains "$OUT" "could not be recorded")"
    check "and no record was written" no "$(yes_no test -e "$H/$DATA_REL/installed.sha256")"
else
    skip "running as root, which ignores file modes: the unwritable-target, part-way and unwritable-data-folder cases did not run"
fi

# 17. CLAUDE_CONFIG_DIR is the default target.
CFG="$SANDBOX/config-dir"; mkdir -p "$CFG"
new_fixture
new_home
env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash "$F/skills/$NAME/install.sh" --yes >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR is the default target" yes "$(all_installed "$F" "$CFG")"
check "and HOME's config folder is left alone" "" "$(ls -A "$H/.claude")"

# 18. The README's quick start works: the installer commands of its Install block, run word for word from the
#     folder that holds the clone, plan every file as a dry run and then install them with the opt-in files.
#     The clone is a copy of a fixture package, in the folder its `git clone` line makes.
README="$ROOT/skills/$NAME/README.md"
run_readme_line() {
    # run_readme_line <README line> -> runs it word for word (split as a shell splits it, never globbed) from
    # the folder that holds the clone, as a user whose config folder is $H/.claude; sets OUT and RC
    set -f; set -- $1; set +f
    if [ "${1:-}" != bash ]; then OUT="not an installer line: $*"; RC=127; return; fi
    shift
    OUT="$(cd "$QS" && env -u CLAUDE_CONFIG_DIR HOME="$H" bash "$@" 2>&1)"; RC=$?
}
if [ ! -f "$README" ]; then
    skip "the package has no README.md yet, so its quick start did not run"
else
    QS_BLOCK="$(awk '/^## / { if (section) exit; section = ($0 == "## Install"); next }
        section && /^```/ { if (block) exit; block = 1; next }
        section && block' "$README")"
    QS_CLONE="$(printf '%s\n' "$QS_BLOCK" | awk '$1 == "git" && $2 == "clone" {
        if ($4 != "") { print $4; exit }
        n = split($3, part, "/"); name = part[n]; sub(/\.git$/, "", name); print name; exit }')"
    QS_RUNS="$(printf '%s\n' "$QS_BLOCK" | grep -E '^bash [^ ]*install\.sh( |$)')"
    check "the README's Install block clones the package into a named folder" yes "$([ -n "$QS_CLONE" ] && echo yes || echo no)"
    QS_CLONE="${QS_CLONE:-no-clone-folder-named}"
    check "the README's Install block runs the installer twice: a dry run, then --yes --opt-in" \
        "bash $QS_CLONE/skills/$NAME/install.sh${NL}bash $QS_CLONE/skills/$NAME/install.sh --yes --opt-in" "$QS_RUNS"
    new_fixture
    new_home
    QS="$SANDBOX/quickstart"; mkdir -p "$QS"
    cp -Rp "$F" "$QS/$QS_CLONE" && cp "$F.expected" "$QS/$QS_CLONE.expected"
    BEFORE="$(snapshot_of "$H")"
    run_readme_line "$(printf '%s\n' "$QS_RUNS" | sed -n 1p)"
    check "quick start, first run: exits 0" 0 "$RC"
    check "quick start, first run: is a dry run" yes "$(contains "$OUT" "DRY RUN")"
    check "quick start, first run: plans every file of the package" "$(cat "$F.expected")" "$(paths_with copy "$OUT")"
    check "quick start, first run: changes nothing" "$BEFORE" "$(snapshot_of "$H")"
    run_readme_line "$(printf '%s\n' "$QS_RUNS" | sed -n 2p)"
    check "quick start, second run: exits 0" 0 "$RC"
    check "quick start, second run: installs every file with its content and mode" yes "$(all_installed "$QS/$QS_CLONE" "$H/.claude")"
    check "quick start, second run: records what it installed" "$(expected_record "$QS/$QS_CLONE")" "$(cat "$H/$DATA_REL/installed.sha256" 2>/dev/null)"
    check "quick start, second run: writes the denylist and house.conf templates" "denylist.txt house.conf installed.sha256" \
        "$(ls "$H/$DATA_REL" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
fi

# 19. The real package: once it is complete (every manifest entry, and the files the skill folder must hold,
#     exist on disk), install it into an empty config folder and run the installed copy's own package suite
#     against itself. Until then this case skips loudly rather than failing.
REAL_MISSING=""
if [ -f "$MANIFEST" ]; then
    while IFS= read -r ENTRY; do
        [ -n "$ENTRY" ] || continue
        [ -e "$ROOT/${ENTRY%/}" ] || REAL_MISSING="$REAL_MISSING $ENTRY"
    done <<< "$(manifest_entries "$MANIFEST")
skills/$NAME/SKILL.md
skills/$NAME/README.md
skills/$NAME/LICENSE
skills/$NAME/install.sh
$HELPER_REL"
else
    REAL_MISSING=" skills/$NAME/package.manifest"
fi
if [ -n "$REAL_MISSING" ]; then
    skip "the real package is not complete yet (missing:$REAL_MISSING); the real install and its package suite did not run"
else
    new_home
    OUT="$(run_installer "$ROOT/skills/$NAME/install.sh" "$H" --yes 2>&1)"; RC=$?
    check "the real package installs into an empty config folder (exit 0)" 0 "$RC"
    REAL_COPIES="$(paths_with copy "$OUT")"
    REAL_DIFFERS=""
    while IFS= read -r REL; do
        [ -n "$REL" ] || continue
        cmp -s "$ROOT/$REL" "$H/.claude/$REL" || REAL_DIFFERS="$REAL_DIFFERS $REL"
    done <<< "$REAL_COPIES"
    check "the real install copied at least one file per manifest entry" yes \
        "$([ "$(printf '%s\n' "$REAL_COPIES" | grep -c .)" -ge "$(manifest_entries "$MANIFEST" | grep -c .)" ] && echo yes || echo no)"
    check "every file it listed is installed byte for byte" "" "$REAL_DIFFERS"
    # The throwaway HOME also hides a PyYAML installed for this user, which silently turned the copy's
    # strict-YAML checks into a skip; Python is pointed at this user's site folder so they run here too,
    # under a package root whose path holds a space.
    PY_USER_BASE="$(python3 -m site --user-base 2>/dev/null)" || PY_USER_BASE=""
    OUT="$(env -u CLAUDE_CONFIG_DIR HOME="$H" PYTHONUSERBASE="${PY_USER_BASE:-$H/.local}" EXHAUSTIVE_AUDIT_PACKAGE_ROOT="$H/.claude" \
        bash "$H/.claude/hooks/tests/test-$NAME-package.sh" 2>&1)"; RC=$?
    check "the installed copy passes its own package suite" 0 "$RC"
    [ "$RC" -eq 0 ] || printf '%s\n' "$OUT" | grep '^FAIL' | head -n 10 | sed 's/^/  package suite: /'
    if python3 -c 'import yaml' >/dev/null 2>&1; then
        check "the installed copy ran its strict-YAML checks" yes "$(contains "$OUT" "the strict-YAML check read all")"
    else
        skip "python3 with PyYAML not found, so the installed copy's strict-YAML checks did not run"
    fi
fi

echo "----"
echo "$NAME-install: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
