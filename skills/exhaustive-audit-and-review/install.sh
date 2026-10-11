#!/usr/bin/env bash
# install.sh — install or update the exhaustive-audit-and-review package.
#
# Copies every file that package.manifest, beside this script, lists from the package into a Claude
# Code config folder: the skill and /apply-rec, the audit, code-review, project-health and apply-rec
# agents, the standards templates and the offline test suites. A manifest line ending in / names a
# whole folder. The package registers no hook and changes no settings.
#
# Usage: install.sh [--yes] [--replace <path>]... [--opt-in] [--target <dir>]
#   --yes             carry the steps out; without it the run is a dry run that reports every step
#                     and changes nothing
#   --replace <path>  replace this foreign file with the package's copy, after backing it up; repeat
#                     it for each such file, naming the path exactly as the dry run prints it
#   --opt-in          create the private data folder <target>/exhaustive-audit-and-review/ with a
#                     denylist template (research questions are refused until it lists a term) and a
#                     house.conf template (every setting commented out); existing files are kept
#   --target <dir>    the config folder (default: $CLAUDE_CONFIG_DIR, else ~/.claude)
#   -h, --help        this text
#
# Safety: it never deletes anything. Every file it installs is recorded with its sha256 in
# <target>/exhaustive-audit-and-review/installed.sha256. A file that differs from the package is
# replaced only when that record shows this installer put it there and it is unchanged since, or
# when --replace names it, and only after a copy goes to
# <target>/backups/exhaustive-audit-and-review-install/<UTC>.<random>/. Any other file that differs
# (an agent of the same name that was already there, or a file edited since) is foreign: reported
# and left unchanged. An identical file is skipped, a file the package does not ship is reported and
# left alone, and run from inside its own target the installer copies nothing.
#
# Exit: 0 ok · 1 usage, a bad manifest or a failed precondition (nothing was changed) · 2 a step
# failed, or a foreign file was left unchanged (re-run with --replace <path> for each one to replace)
# bash-3.2-safe.

set -uo pipefail

NAME="exhaustive-audit-and-review"
DATA_DIR_NAME="$NAME"          # <target>/<this>/ holds installed.sha256 and the opt-in files
RECORD_NAME="installed.sha256"
BACKUP_SUBDIR="backups/$NAME-install"
PRIVATE_UMASK=077              # the data folder (0700) and its files (0600) hold private names
SHA256_HEX_LENGTH=64
MIN_BASH_MAJOR=3
MIN_BASH_MINOR=2
EXIT_USAGE=1
EXIT_FAILED=2

NEWLINE='
'
TAB="$(printf '\t')"

# Every cd below clears CDPATH: an exported CDPATH would send a relative path somewhere else and
# make cd print that folder into the captured value. (Pattern reused from claude-code-new-functionality-check.)
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$SCRIPT_DIR/package.manifest"
APPLY=no
OPT_IN=no
TARGET_ARG=""
REPLACE=""          # the --replace paths, one per line
TARGET=""
DATA_DIR=""
RECORD_FILE=""
RECORD=""           # installed.sha256 as it stood (or was last written) during this run
HASHER=""
PACKAGE=""          # every file the package installs, one per line, in manifest order
FOLDERS=""          # the manifest's folder entries without their trailing /, one per line
INSTALLED=""        # the files this run placed or found identical, one per line
FOREIGN=""          # each foreign file left unchanged, with the reason, one per line
RECORD_PENDING=no   # yes while files are being placed, so a failure part-way still records them
BACKUP_DIR=""
ACTION=""
NOTE=""
REASON=""
EXTRAS=0

die() {
    # die <exit code> <message>; files placed before the failure are still recorded, and once a backup
    # was taken it also says where the backups are
    printf 'install: %s\n' "$2" >&2
    if [ "$RECORD_PENDING" = yes ]; then
        RECORD_PENDING=no
        record_installed || printf 'install: could not record the files placed so far in %s\n' "$RECORD_FILE" >&2
    fi
    [ -z "$BACKUP_DIR" ] || printf 'install: backups taken so far: %s\n' "$BACKUP_DIR" >&2
    exit "$1"
}
say() { printf '%s\n' "$*"; }
warn() { printf 'install: warning: %s\n' "$1" >&2; }
usage() {
    # The help is the header from "# Usage:" to the "# bash-3.2-safe." line, found by those markers
    # rather than by line numbers, so the block can grow without losing a line.
    awk '/^# Usage:/ { on = 1 } /^# bash-3\.2-safe/ { exit } on { sub(/^# ?/, ""); print }' "$0"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes) APPLY=yes ;;
            --replace)
                [ "$#" -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "--replace needs a path, as the dry run prints it"
                REPLACE="$REPLACE$2$NEWLINE"; shift ;;
            --opt-in) OPT_IN=yes ;;
            --target)
                [ "$#" -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "--target needs a folder"
                TARGET_ARG="$2"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "$EXIT_USAGE" "unknown option: $1 (see --help)" ;;
        esac
        shift
    done
}

bash_is_new_enough() {
    [ -n "${BASH_VERSION:-}" ] || return 1
    [ "${BASH_VERSINFO[0]}" -gt "$MIN_BASH_MAJOR" ] \
        || { [ "${BASH_VERSINFO[0]}" -eq "$MIN_BASH_MAJOR" ] && [ "${BASH_VERSINFO[1]}" -ge "$MIN_BASH_MINOR" ]; }
}
present() { [ -e "$1" ] || [ -L "$1" ]; }   # a dangling symlink counts as there, so nothing is written through it
is_listed() { case "$NEWLINE$2$NEWLINE" in *"$NEWLINE$1$NEWLINE"*) return 0 ;; esac; return 1; }   # is_listed <line> <lines>
is_sha256() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq "$SHA256_HEX_LENGTH" ]; }

pick_hasher() {
    # pick_hasher -> sets HASHER to the first sha256 tool found; each prints "<sha256> <name>" per file
    if command -v sha256sum >/dev/null 2>&1; then HASHER="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then HASHER="shasum -a 256"
    elif command -v openssl >/dev/null 2>&1; then HASHER="openssl dgst -sha256 -r"
    else return 1; fi
}
file_sha() {
    # file_sha <file> -> its sha256; prints nothing (status 1) when it cannot be read
    local out
    out="$($HASHER "$1" 2>/dev/null)" || return 1
    out="${out#\\}"            # a tool escapes an odd file name with a leading backslash
    out="${out%% *}"
    is_sha256 "$out" || return 1
    printf '%s\n' "$out"
}
hash_lines() {
    # hash_lines <root> <paths> -> "<sha256>  <path>" for each path (one per line, relative to <root>), in
    # order, from a single run of the hash tool
    local root="$1" paths="$2" rel line sums
    set --
    while IFS= read -r rel; do [ -z "$rel" ] || set -- "$@" "./$rel"; done <<< "$paths"
    [ "$#" -gt 0 ] || return 0
    sums="$(CDPATH= cd -- "$root" && $HASHER "$@")" || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        IFS= read -r line <&3 || return 1
        line="${line#\\}"
        line="${line%% *}"
        is_sha256 "$line" || return 1
        printf '%s  %s\n' "$line" "$rel"
    done <<< "$paths" 3<<< "$sums"
}

list_folder() {
    # list_folder <root> <folder> -> every file under <root>/<folder>, as a path relative to <root>, sorted.
    # Never litter: OS files, caches, archives, backup copies and editor leftovers are neither installed nor
    # reported. The export to the public repository skips the same editor leftovers; keep the two lists equal.
    (CDPATH= cd -- "$1" && find "./$2" \( -type d \( -name archive -o -name .archive -o -name .git \
        -o -name __pycache__ -o -name .pytest_cache -o -name '*.bak*' \) -prune \) \
        -o \( -type f ! -name .DS_Store ! -name '*.bak*' ! -name '*.pyc' \
        ! -name '*~' ! -name '.*.swp' ! -name '.*.swo' ! -name '*.orig' ! -name '*.rej' ! -name '*.tmp' \
        ! -name '.#*' ! -name '#*#' -print \) | sed 's|^\./||' | LC_ALL=C sort)
}

refuse() { die "$EXIT_USAGE" "package.manifest line $1: $2 $3"; }   # refuse <line number> <entry> <why>
check_entry() {
    # check_entry <line number> <entry> -> returns when the entry is a plain relative path naming a file, or
    # with a trailing / a folder, in the package; refuses the manifest otherwise
    local n="$1" entry="$2" path="${2%/}"
    case "$entry" in /*) refuse "$n" "$entry" "is an absolute path; entries are relative to the package root" ;; esac
    case "/$path/" in */../*) refuse "$n" "$entry" "has a .. segment, which could reach outside the package" ;; esac
    case "/$path/" in *//*|*/./*) refuse "$n" "$entry" "has an empty or . segment; write the plain path" ;; esac
    case "$entry" in *\\*) refuse "$n" "$entry" "has a backslash; separate folders with /" ;; esac
    if [ "$path" != "$entry" ]; then
        [ -d "$SOURCE_ROOT/$path" ] || refuse "$n" "$entry" "is not in the package at $SOURCE_ROOT"
    elif [ -d "$SOURCE_ROOT/$path" ]; then
        refuse "$n" "$entry" "is a folder; end the line with / to install all of it"
    elif [ ! -f "$SOURCE_ROOT/$path" ]; then
        refuse "$n" "$entry" "is not in the package at $SOURCE_ROOT"
    fi
}
read_manifest() {
    # read_manifest -> sets PACKAGE (every file to install, in manifest order; a folder's files sorted) and
    # FOLDERS. Refuses the manifest (exit 1, naming the line) when a line is not a plain relative path,
    # names nothing in the package, or lists a file a second time.
    [ -f "$MANIFEST" ] || die "$EXIT_USAGE" "no package.manifest beside the installer (looked for $MANIFEST)"
    local line n=0 files file pairs="" dup rest
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n+1))
        line="${line%"${line##*[![:space:]]}"}"                    # trailing blanks, and a CR, go
        case "${line#"${line%%[![:space:]]*}"}" in ''|'#'*) continue ;; esac
        check_entry "$n" "$line"
        if [ "${line%/}" = "$line" ]; then
            files="$line"
        else
            files="$(list_folder "$SOURCE_ROOT" "${line%/}")" || refuse "$n" "$line" "could not be listed completely"
            [ -n "$files" ] || refuse "$n" "$line" "holds no file to install"
            FOLDERS="$FOLDERS${line%/}$NEWLINE"
        fi
        while IFS= read -r file; do
            [ -f "$SOURCE_ROOT/$file" ] || refuse "$n" "$line" "holds a file whose name cannot be read safely (a line break in it?)"
            pairs="$pairs$n$TAB$file$NEWLINE"
        done <<< "$files"
        PACKAGE="$PACKAGE$files$NEWLINE"
    done < "$MANIFEST"
    [ -n "$PACKAGE" ] || die "$EXIT_USAGE" "$MANIFEST lists no file"
    PACKAGE="${PACKAGE%"$NEWLINE"}"
    FOLDERS="${FOLDERS%"$NEWLINE"}"
    # A file listed twice (a repeated line, or a file a folder entry already covers) is refused where it
    # is listed the second time.
    dup="$(printf '%s' "$pairs" | awk '{ n = $0; sub(/\t.*/, "", n); p = $0; sub(/^[^\t]*\t/, "", p) }
        p in first { print n "\t" first[p] "\t" p; exit } { first[p] = n }')"
    [ -z "$dup" ] && return 0
    rest="${dup#*"$TAB"}"
    refuse "${dup%%"$TAB"*}" "${rest#*"$TAB"}" "is already listed (line ${rest%%"$TAB"*})"
}
check_replace_paths() {
    local rel
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        is_listed "$rel" "$PACKAGE" \
            || die "$EXIT_USAGE" "--replace $rel: not a file this package installs (name it exactly as the dry run prints it)"
    done <<< "$REPLACE"
}
read_record() {
    present "$RECORD_FILE" || return 0
    RECORD="$(cat "$RECORD_FILE" 2>/dev/null)" || die "$EXIT_USAGE" "cannot read $RECORD_FILE (nothing was changed)"
}
recorded_sha() {
    # recorded_sha <path> -> the sha256 installed.sha256 holds for that path; nothing when it holds none
    [ -n "$RECORD" ] || return 0
    printf '%s\n' "$RECORD" | RECORDED_PATH="$1" awk -v len="$SHA256_HEX_LENGTH" '
        substr($0, len + 1, 2) == "  " && substr($0, len + 3) == ENVIRON["RECORDED_PATH"] && substr($0, 1, len) !~ /[^0-9a-f]/ {
            sha = substr($0, 1, len)
        }
        END { if (sha != "") print sha }'
}
warn_missing_tools() {
    local tool
    command -v python3 >/dev/null 2>&1 || warn "python3 was not found; the helper needs it"
    for tool in git curl; do
        command -v "$tool" >/dev/null 2>&1 || warn "$tool was not found; some audit steps use it"
    done
}

preflight() {
    bash_is_new_enough \
        || die "$EXIT_USAGE" "this installer needs bash $MIN_BASH_MAJOR.$MIN_BASH_MINOR or newer (this is ${BASH_VERSION:-not bash})"
    TARGET="${TARGET_ARG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
    case "$TARGET" in
        *"$NEWLINE"*) die "$EXIT_USAGE" "the target path contains a newline, which no step can handle safely; use another folder" ;;
    esac
    [ -d "$TARGET" ] || die "$EXIT_USAGE" "no Claude Code config folder at $TARGET (start Claude Code once, or pass --target <dir>)"
    TARGET="$(CDPATH= cd -- "$TARGET" && pwd)" || die "$EXIT_USAGE" "cannot enter $TARGET"
    DATA_DIR="$TARGET/$DATA_DIR_NAME"
    RECORD_FILE="$DATA_DIR/$RECORD_NAME"
    pick_hasher || die "$EXIT_USAGE" "no sha256 tool was found (sha256sum, shasum or openssl); one is needed to record what is installed"
    warn_missing_tools
    read_manifest
    check_replace_paths
    read_record
}

# ensure_backup_dir, backup_file, install_file and lost_exec_bit are reused from
# claude-code-new-functionality-check's install.sh.
ensure_backup_dir() {
    # ensure_backup_dir -> sets BACKUP_DIR to this run's backup folder, creating it once. mktemp makes the
    # name unique (two runs in one second never share a folder) and the folder private; the UTC stamp in
    # front keeps the folders in time order.
    [ -z "$BACKUP_DIR" ] || return 0
    local base="$TARGET/$BACKUP_SUBDIR" dir
    dir="$(mkdir -p "$base" && mktemp -d "$base/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" \
        || die "$EXIT_FAILED" "cannot create a backup folder under $base; stopped before replacing anything"
    BACKUP_DIR="$dir"
}
backup_file() {
    # backup_file <relative path> -> copies <target>/<path> into this run's backup folder
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/$(dirname "$1")" && cp -p "$TARGET/$1" "$BACKUP_DIR/$1" \
        || die "$EXIT_FAILED" "could not back up $TARGET/$1; stopped before replacing it"
}
install_file() {
    # install_file <relative path> <copy|update> -> places the package copy, backing up first. (Adapted: the
    # folder is made only when missing, and a script that kept its executable bit is not chmodded again.)
    local rel="$1" action="$2" dir="$TARGET"
    [ "$action" = update ] && backup_file "$rel"
    case "$rel" in */*) dir="$TARGET/${rel%/*}" ;; esac
    { [ -d "$dir" ] || mkdir -p "$dir"; } && cp -p "$SOURCE_ROOT/$rel" "$TARGET/$rel" \
        || die "$EXIT_FAILED" "could not copy $rel into $TARGET"
    case "$rel" in *.sh) [ -x "$TARGET/$rel" ] || chmod +x "$TARGET/$rel" || die "$EXIT_FAILED" "could not make $rel executable" ;; esac
}
lost_exec_bit() {
    # lost_exec_bit <relative path> -> true for an installed script that is no longer executable
    case "$1" in *.sh) [ ! -x "$TARGET/$1" ] ;; *) return 1 ;; esac
}

decide() {
    # decide <relative path> -> sets ACTION (copy|update|mode|same|foreign) and NOTE for one package file.
    # A differing file is updated only when the record shows this installer put it there and it is
    # unchanged since, or when --replace names it; otherwise it is foreign and stays as it is.
    local rel="$1" target="$TARGET/$1" recorded
    NOTE=""
    if ! present "$target"; then ACTION=copy; return 0; fi
    if cmp -s "$SOURCE_ROOT/$rel" "$target"; then
        ACTION=same
        lost_exec_bit "$rel" && { ACTION=mode; NOTE="  (content unchanged; not executable)"; }
        return 0
    fi
    ACTION=update
    recorded="$(recorded_sha "$rel")"
    if [ -n "$recorded" ] && [ "$(file_sha "$target")" = "$recorded" ]; then return 0; fi
    if is_listed "$rel" "$REPLACE"; then NOTE="  (replaced because --replace names it)"; return 0; fi
    ACTION=foreign
    if [ -n "$recorded" ]; then REASON="changed since this installer put it there"; else REASON="not installed by this installer"; fi
    NOTE="  ($REASON; left unchanged)"
}

copy_step() {
    say "Files:"
    if [ "$SOURCE_ROOT" -ef "$TARGET" ]; then
        say "  the package is already installed here ($TARGET is the folder it runs from); nothing to copy"
        return 0
    fi
    local rel copies=0 updates=0 modes=0 same=0 foreign=0
    [ "$APPLY" = no ] || RECORD_PENDING=yes
    while IFS= read -r rel; do
        decide "$rel"
        printf '  %-7s %s%s\n' "$ACTION" "$rel" "$NOTE"
        case "$ACTION" in
            copy) copies=$((copies+1)) ;;
            update) updates=$((updates+1)) ;;
            mode) modes=$((modes+1)) ;;
            same) same=$((same+1)) ;;
            foreign) foreign=$((foreign+1)); FOREIGN="$FOREIGN$rel  ($REASON)$NEWLINE"; continue ;;
        esac
        [ "$APPLY" = yes ] || continue
        case "$ACTION" in
            copy|update) install_file "$rel" "$ACTION" ;;
            mode) chmod +x "$TARGET/$rel" || die "$EXIT_FAILED" "could not make $rel executable" ;;
        esac
        INSTALLED="$INSTALLED$rel$NEWLINE"
    done <<< "$PACKAGE"
    report_extras
    say "  $copies to copy, $updates to update (each backed up first), $modes to make executable, $same unchanged, $foreign foreign (left unchanged), $EXTRAS not in the package"
    [ "$APPLY" = yes ] || return 0
    RECORD_PENDING=no
    record_installed || die "$EXIT_FAILED" "the files are in place, but they could not be recorded in $RECORD_FILE"
}
report_extras() {
    # report_extras -> lists as extra each file under the package's folders in the target that the package
    # does not ship (it is never deleted), and sets EXTRAS to their number
    local folder rel
    EXTRAS=0
    while IFS= read -r folder; do
        [ -n "$folder" ] && [ -d "$TARGET/$folder" ] || continue
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            is_listed "$rel" "$PACKAGE" && continue
            printf '  %-7s %s  (not in this package; left in place)\n' extra "$rel"
            EXTRAS=$((EXTRAS+1))
        done <<< "$(list_folder "$TARGET" "$folder")"
    done <<< "$FOLDERS"
}
record_installed() {
    # record_installed -> merges the files this run placed or found identical into installed.sha256 (one
    # "<sha256>  <path>" line per file, in path order), keeping the lines of every other file. The list is
    # written to a private temporary file beside the old one and swapped in whole; an unchanged list is not
    # rewritten. Returns 1 when it could not record.
    [ -n "$INSTALLED" ] || return 0
    local fresh merged tmp
    fresh="$(hash_lines "$TARGET" "$INSTALLED")" || return 1
    merged="$( { [ -z "$RECORD" ] || printf '%s\n' "$RECORD" | PLACED="$INSTALLED" awk -v len="$SHA256_HEX_LENGTH" '
            BEGIN { n = split(ENVIRON["PLACED"], placed, "\n"); for (i = 1; i <= n; i++) if (placed[i] != "") skip[placed[i]] = 1 }
            NF && !(substr($0, len + 3) in skip)'
        printf '%s\n' "$fresh"; } | LC_ALL=C sort -k2)" || return 1
    [ "$merged" != "$RECORD" ] || return 0
    (umask "$PRIVATE_UMASK" && mkdir -p "$DATA_DIR") || return 1
    tmp="$(mktemp "$DATA_DIR/.$RECORD_NAME.XXXXXX")" || return 1
    if printf '%s\n' "$merged" > "$tmp" && mv -f "$tmp" "$RECORD_FILE"; then
        RECORD="$merged"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

write_denylist_template() {
    cat <<'DENYLIST'
# denylist.txt: private terms that must never appear in a web-research question.
# One term per line: a client or employer name, a project code name, a private repository
# name, a person's name. Lines starting with # are comments.
# A term needs at least 4 characters: a shorter one would match too much and is ignored, so
# write a short acronym out in a longer form, such as its full name.
# Research questions are refused until this file lists at least one term. An empty list
# fails closed, so nothing is searched before you have said what must stay private.
DENYLIST
}
write_house_conf_template() {
    cat <<'HOUSE'
# house.conf: this machine's settings for /exhaustive-audit-and-review. It is never published.
# Every setting below is off. To turn one on, delete the "# " in front of its line and give it
# a value. Lines starting with # are comments.

# A folder under the audit root that is never read or audited; one line per folder.
# EXCLUDE=
# A file in the audit root that lists the modules in the order to audit them, such as MODULES.md.
# MODULE_REGISTRY=
# Where reports go: run-dir (the run's own folder, the default) or assets-output (<root>/assets/output/).
# REPORT_LAYOUT=run-dir
# A command run as an extra check, only after you agree to it at preflight; one line per command.
# CHECK=
# The command that runs your Claude Code configuration's own tests, for the claude-system review.
# CONFIG_TEST=
# The most lines of code one code-review scope covers (default 4000).
# MAX_LOC_PER_REVIEW=
# The most web searches and page fetches the research step may use in one run.
# RESEARCH_BUDGET=
HOUSE
}
opt_in_file() {
    # opt_in_file <file name> <writer function> <what it is> -> writes <data folder>/<file name>, private,
    # unless anything is there already (a dangling link included)
    local file="$DATA_DIR/$1"
    if present "$file"; then say "  $1 exists; left as it is"; return 0; fi
    say "  write $3"
    [ "$APPLY" = yes ] || return 0
    # noclobber: a file that appeared since the check above is never overwritten
    (umask "$PRIVATE_UMASK" && set -C && "$2" > "$file") || die "$EXIT_FAILED" "cannot write $file"
}
opt_in_step() {
    [ "$OPT_IN" = yes ] || return 0
    say "Opt-in (the private data folder):"
    if [ -d "$DATA_DIR" ]; then
        say "  the data folder is $DATA_DIR"
    else
        say "  create the data folder $DATA_DIR (mode 700)"
        [ "$APPLY" = no ] || { (umask "$PRIVATE_UMASK" && mkdir -p "$DATA_DIR") || die "$EXIT_FAILED" "cannot create $DATA_DIR"; }
    fi
    opt_in_file denylist.txt write_denylist_template \
        "denylist.txt, which lists no term yet: research questions are refused until you add one"
    opt_in_file house.conf write_house_conf_template "house.conf, with every setting commented out"
}

next_steps() {
    say "Next:"
    say "  - run /agents in Claude Code; if the new agents are not listed yet, start a new session"
    [ "$OPT_IN" = no ] || say "  - add your private terms to $DATA_DIR/denylist.txt before the first research step"
    say "  - start an audit with /$NAME"
    say "  - run the tests: bash \"$TARGET/hooks/tests/test-$NAME-package.sh\" (and -helper, -install)"
}
foreign_report() {
    # foreign_report -> when a foreign file was left unchanged, names each one and how to replace it, then exits 2
    [ -n "$FOREIGN" ] || return 0
    local line flags=""
    printf 'install: these files differ from the package and are left unchanged:\n' >&2
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'install:   %s\n' "$line" >&2
        flags="$flags --replace $(printf '%q' "${line%%  (*}")"
    done <<< "$FOREIGN"
    printf 'install: to replace one with the package copy (it is backed up first), re-run with --replace <path>, once for each file you want replaced:\n' >&2
    printf 'install:  %s\n' "$flags" >&2
    exit "$EXIT_FAILED"
}

main() {
    parse_args "$@"
    preflight
    if [ "$APPLY" = yes ]; then
        say "$NAME installer"
    else
        say "$NAME installer — DRY RUN: nothing changes until you add --yes"
    fi
    say "  package: $SOURCE_ROOT"
    say "  target:  $TARGET"
    copy_step
    opt_in_step
    if [ "$APPLY" = yes ]; then
        [ -z "$BACKUP_DIR" ] || say "Backups of replaced files: $BACKUP_DIR"
        next_steps
    fi
    foreign_report
    return 0
}

main "$@"
