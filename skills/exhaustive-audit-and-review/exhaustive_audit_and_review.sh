#!/usr/bin/env bash
# exhaustive_audit_and_review.sh — the deterministic half of the /exhaustive-audit-and-review skill.
#
# The audit's judgment belongs to its agents. Everything that must be exact and repeatable lives
# here instead: which folders are modules and how big they are, how the review is cut into scopes
# and waves, whether an agent's reply is valid, which ID a finding keeps from run to run, and what
# the reports say. A model re-deriving those on every run would drift; a tested script does not.
#
# Usage: exhaustive_audit_and_review.sh <subcommand> [args]   (every subcommand also takes --config-dir DIR)
#   discover [--root DIR] [--exclude NAME]...
#       the modules under the root (resolved with pwd -P; a symlink is never followed out of it),
#       with true sizes and tiers, the folders excluded or skipped, the iCloud placeholders, and every
#       folder or file it could not read ("unreadable", each with why, also warned on stderr)
#   capabilities [--strict]
#       from the RUNTIME config (the running session's ${CLAUDE_CONFIG_DIR:-~/.claude}, whatever --config-dir
#       names): the agents that will be dispatched, the companion skill it can call, the nesting depth and
#       concurrency limits, the CLI version; a depth below 2 is listed as blocked (--strict: exit 3 when
#       anything is blocked). runtime_config is <config> when it is the audited config, else <runtime>;
#       audited_config.companions holds what the AUDITED config enables (superpowers, autoharness, lsp) and
#       whether it holds the companion's data folder
#   config-facts [--root DIR] [--exclude NAME]... [--checks]
#       what the read-only agents cannot run themselves: git activity (with git's own error when it
#       fails), names of tracked secret-bearing files, lockfiles, CI files, CLAUDE.md markers, dependencies,
#       hook registrations, plugins, env key names (never values), agents, skills, the companion's status;
#       --checks also runs the house.conf CHECK= commands (60s each); CONFIG_TEST= lines are listed, never
#       run. The audited config's own code never runs unless it is the running session's config: the
#       companion runs from <runtime>, pointed at the audited config (a script <runtime> lacks is listed
#       in not_run), and a foreign config's CHECK= lines are listed with "ran": false
#   plan [--root DIR] [--scope all|workspace|claude-system|module NAME] [--coverage exhaustive|sampled]
#        [--loc-budget N] [--exclude NAME]...
#       the review scopes, their waves (each within cap - 2 concurrent agents), and the estimate for both
#       coverages: agents, estimate.processed_tokens (cache reads included) and minutes, with its basis;
#       the unreadable paths and placeholders the scope covers; exit 3 when the concurrency cap leaves
#       no room for a scope
#   init-run --plan FILE [--root DIR]
#       creates <data>/runs/<run>/ (0700) holding plan.json (with the root and every module's folder)
#       and results/; prints the run id, then the run folder
#   next-wave RUN
#       the next wave's dispatches, each with its "AUDIT-RUN: <run> <scope>" line; an INVALID scope is
#       offered once more and then failed; "done": true when nothing is left
#   save-result RUN SCOPE OUTPUT-FILE|-
#       files an agent's reply under SCOPE from its transcript (or from stdin with -): a hand-back
#       message first, else its final text, split replies rejoined, prose before the JSON allowed.
#       A transcript whose first user message lacks the exact line "AUDIT-RUN: <run> <scope>" is
#       refused (exit 2). SCOPE "research" files the researcher's reply
#   validate RUN SCOPE
#       "VALID <n> findings", "VALID-OVERLONG <n> findings: ..." or "INVALID: <reasons>" (exit 2),
#       against the finding schema below; secret-shaped values are masked in place
#   agenda RUN
#       the validated findings' research questions, deduplicated, most severe first, at most
#       RESEARCH_BUDGET; writes <run>/agenda.md and prints its path
#   scrub-check FILE
#       CLEAN (exit 0), or "line N: private term|absolute path|email" (exit 2; a term is never printed);
#       "BLOCKED: no denylist terms" (exit 3) when the denylists hold no usable term, and "BLOCKED: the
#       denylist <path> exists but cannot be read" (exit 3) when one of them cannot be read
#   attach-research RUN FILE
#       checks the researcher's reply (FILE, as save-result wrote it), re-fetches every lead over https
#       with bounded retries (a fetch that lands somewhere the URL policy refuses counts as failed),
#       verifies each quote, and attaches the verified ones to the findings that asked; prints
#       "research: <v> verified, <u> unverified, <f> failed"
#   finalize RUN
#       IDs (W-n, M<k>-n, CS-n; kept across runs by fingerprint), findings.json and the reports; prints
#       the banner first: EXHAUSTIVE-AUDIT COMPLETE, or EXHAUSTIVE-AUDIT PARTIAL — not reviewed: ... (a
#       scope that is not valid, or a path the plan could not read or that is an iCloud placeholder).
#       A verified research quote is shown as code, as found at its URL; its tier is the researcher's rating
#   status [RUN]          one run's scopes (valid, failed, missing) and banner; default: the latest run
#   runs                  every run, oldest first, with its counts and banner
#   diff [OLD NEW]
#       NEW, RECURRING, REGRESSED, IMPROVED, RESOLVED (only with an apply log or a commit naming the ID),
#       DROPPED and APPROXIMATE; default: the two latest finalized runs; writes <new>/diff_vs_<old>.md
#   lookup ID [--run RUN]
#       one finding as a markdown block that names its run; default: the latest finalized run
#   demo-fixture DIR
#       builds DIR/workspace (two modules) and DIR/claude-config with planted defects; DIR must be new or empty
#   score-demo RUN
#       the run's findings against the demo's answer key; exit 0 only when every planted critical was found
#
# Paths printed are relative to the audited root, or start with <config>/ (the audited config dir),
# <runtime>/ (the running session's config dir, when it is another one) or <data>/ (a data dir outside
# the config dir); FILE arguments accept the same placeholders. JSON goes to stdout, sorted.
#
# Exit: 0 ok · 1 usage or precondition error (a file that cannot be read or written included: the ERROR
# names the subcommand and the file) · 2 a check found a problem · 3 blocked (fails closed)
#
# Configuration: the config dir is --config-dir, else ${CLAUDE_CONFIG_DIR:-~/.claude}; the data dir is
# ${EXHAUSTIVE_AUDIT_DIR:-<config>/exhaustive-audit-and-review}, never published, holding runs/<run>/
# and an optional house.conf (KEY=value lines, # comments): EXCLUDE= (repeatable: a child folder name,
# a root-relative path or an absolute path), MODULE_REGISTRY= (root-relative; else MODULES.md; the first
# table column names the modules), REPORT_LAYOUT=run-dir|assets-output, CHECK= (repeatable, run only by
# config-facts --checks), CONFIG_TEST= (repeatable; listed by config-facts, used by /apply-rec),
# MAX_LOC_PER_REVIEW= (default 4000), RESEARCH_BUDGET= (default 8). Denylists, unioned and read once each:
# <data>/denylist.txt, <config>/claude-code-new-functionality-check/denylist.txt, the same two in the running
# session's config (<runtime>/exhaustive-audit-and-review/ and <runtime>/claude-code-new-functionality-check/,
# since the dispatched agents load that config's instruction files), and $CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR/
# denylist.txt when that is set; EXHAUSTIVE_AUDIT_DENYLIST (a colon-separated file list) replaces them all. A
# term is one line of 4+ characters, matched case-insensitively; shorter lines are ignored and counted on stderr.
# Run commands find a run in the data dir, so give init-run and every later run command the same
# --config-dir (or none).
#
# Environment: EXHAUSTIVE_AUDIT_PYTHON (the python to use; when set it must name an executable, else exit 1;
# python always runs isolated, so the working folder and PYTHON* variables never reach it),
# EXHAUSTIVE_AUDIT_NOW (a UTC stamp such as 20261010T120000Z, for tests), EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS=1
# (file:// leads, for tests),
# EXHAUSTIVE_AUDIT_RETRY_ATTEMPTS / _RETRY_BASE_SECS / _CONNECT_TIMEOUT / _MAX_TIME / _DEADLINE_SECS
# (the fetch policy: whole numbers, with attempts and both timeouts >= 1; a bad value is named on stderr
# and its default used; each wait is the doubling delay plus up to a fifth of it as jitter, at least one
# second's worth, never past 30s), EXHAUSTIVE_AUDIT_CHECK_TIMEOUT_SECS, EXHAUSTIVE_AUDIT_CLI_TIMEOUT_SECS,
# EXHAUSTIVE_AUDIT_TIMEOUT_TOOL (timeout, gtimeout or none), EXHAUSTIVE_AUDIT_RUNTIME_CONFIG (the running
# session's config folder, for tests; default ${CLAUDE_CONFIG_DIR:-~/.claude}; plan's cap comes from it too).

set -uo pipefail
EA_ORIGINAL_UMASK="$(umask)"
umask 077

PREFIX="exhaustive-audit-and-review"
EXIT_USAGE=1
FIND_PYTHON_BAD_OVERRIDE=2            # find_python's own status: EXHAUSTIVE_AUDIT_PYTHON names no executable
TAB="$(printf '\t')"

# ------------------------------------------------------------------ fetch policy
# Bounded-backoff policy (Retry & Resilience Standard): curl's --connect-timeout and --max-time are the
# per-attempt timeout, DEADLINE_SECS the overall one; only transient classes are retried.
RETRY_ATTEMPTS="${EXHAUSTIVE_AUDIT_RETRY_ATTEMPTS:-3}"
RETRY_BASE_SECS="${EXHAUSTIVE_AUDIT_RETRY_BASE_SECS:-1}"
RETRY_CAP_SECS=30
CONNECT_TIMEOUT="${EXHAUSTIVE_AUDIT_CONNECT_TIMEOUT:-10}"
MAX_TIME="${EXHAUSTIVE_AUDIT_MAX_TIME:-30}"
DEADLINE_SECS="${EXHAUSTIVE_AUDIT_DEADLINE_SECS:-240}"
MAX_FILESIZE_BYTES=5000000
MAX_REDIRECTS=5
CURL_TRANSIENT_EXITS=" 5 6 7 18 28 35 52 55 56 "   # resolve/connect/partial/timeout/TLS/empty/send/recv
# Each policy value is a whole number with a floor (name:default:floor). A bad one is named and replaced by
# its default, so a typo can never remove a timeout: curl reads --max-time 0 as "no limit".
for policy in RETRY_ATTEMPTS:3:1 RETRY_BASE_SECS:1:0 CONNECT_TIMEOUT:10:1 MAX_TIME:30:1 DEADLINE_SECS:240:0; do
    policy_name="${policy%%:*}"; policy_rest="${policy#*:}"
    policy_default="${policy_rest%%:*}"; policy_floor="${policy_rest#*:}"
    policy_value="${!policy_name}"
    case "$policy_value" in
        ''|*[!0-9]*) policy_value="" ;;
        *) policy_value=$(( 10#$policy_value ))       # decimal, so a leading zero is never read as octal
           [ "$policy_value" -ge "$policy_floor" ] || policy_value="" ;;
    esac
    if [ -z "$policy_value" ]; then
        printf '%s: WARNING EXHAUSTIVE_AUDIT_%s must be a whole number >= %s; using %s\n' \
            "$PREFIX" "$policy_name" "$policy_floor" "$policy_default" >&2
        policy_value="$policy_default"
    fi
    printf -v "$policy_name" '%s' "$policy_value"
done
unset policy policy_name policy_rest policy_default policy_floor policy_value
if [ "${EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS:-0}" = "1" ]; then
    CURL_PROTO="=https,file"
else
    CURL_PROTO="=https"
fi

# The header comment IS the usage text (line 2 up to the first blank line); the schema tables are
# generated from the one constant table in the python below, so the two can never disagree.
print_usage() {
    awk 'NR > 1 && /^$/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
    find_python
    case $? in
        0) run_py _usage-tables ;;
        "$FIND_PYTHON_BAD_OVERRIDE") return "$EXIT_USAGE" ;;
        *) printf '(python3 is missing, so the finding schema cannot be printed)\n' ;;
    esac
}

PYTHON_CMD=""
find_python() {
    # The user's EXHAUSTIVE_AUDIT_PYTHON is taken as one word or not at all: quietly running some other
    # python would hide a broken setting.
    local candidate
    [ -n "$PYTHON_CMD" ] && return 0
    if [ -n "${EXHAUSTIVE_AUDIT_PYTHON:-}" ]; then
        if command -v "$EXHAUSTIVE_AUDIT_PYTHON" >/dev/null 2>&1; then
            PYTHON_CMD="$EXHAUSTIVE_AUDIT_PYTHON"
            return 0
        fi
        printf '%s: ERROR EXHAUSTIVE_AUDIT_PYTHON is set but names no executable; point it at python3 or unset it\n' "$PREFIX" >&2
        return "$FIND_PYTHON_BAD_OVERRIDE"
    fi
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then
            PYTHON_CMD="$candidate"
            return 0
        fi
    done
    return 1
}

# The python half sits in a no-op heredoc after this script's final exit: bash never reaches it at run
# time and bash -n parses it as data. This loader hands python the text between that heredoc's opening
# and closing lines, padded so a traceback's line numbers are this file's.
PY_LOADER='
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    source = handle.read()
opening = "\n: <<" + chr(39) + "PYEOF" + chr(39) + "\n"
start = source.index(opening) + len(opening)
program = "\n" * source[:start].count("\n") + source[start:source.index("\nPYEOF\n", start) + 1]
sys.argv = [path] + sys.argv[2:]
exec(compile(program, path, "exec"), {"__name__": "__main__", "__file__": path})
'

run_py() {
    find_python
    case $? in
        0) ;;
        "$FIND_PYTHON_BAD_OVERRIDE") return "$EXIT_USAGE" ;;
        *) printf '%s: ERROR this helper needs python3, and none is on PATH\n' "$PREFIX" >&2; return "$EXIT_USAGE" ;;
    esac
    # -I keeps the working folder off sys.path (an audited repo's json.py would otherwise be imported and
    # run) and ignores every PYTHON* variable; -X utf8 and -B restore the UTF-8 text handling and the
    # no-bytecode rule that isolation would otherwise leave to the user's environment.
    EA_BASH="$BASH" EA_UMASK="$EA_ORIGINAL_UMASK" "$PYTHON_CMD" -I -X utf8 -B -c "$PY_LOADER" "$0" "$@"
}

# ---------------------------------------------------------------- http_get
# Adapted from claude_code_new_functionality_check.sh (classify_fetch, retry_after_secs, http_get): the
# HTTP status decides first and the curl exit code only when there is none, because curl --fail on a
# plain 404 can exit with a "network" code that would otherwise be retried forever.
classify_fetch() {
    # classify_fetch <curl_exit> <http_code> -> ok | transient | permanent
    local curl_exit="$1" http_code="$2"
    case "$http_code" in
        000)
            if [ "$curl_exit" -eq 0 ]; then printf 'ok\n'
            elif [ "${CURL_TRANSIENT_EXITS#* $curl_exit }" != "$CURL_TRANSIENT_EXITS" ]; then printf 'transient\n'
            else printf 'permanent\n'
            fi ;;
        2??)
            # A success status with a failed transfer is a truncated body.
            if [ "$curl_exit" -eq 0 ]; then printf 'ok\n'; else printf 'transient\n'; fi ;;
        408|429) printf 'transient\n' ;;
        501)     printf 'permanent\n' ;;      # "not implemented" never fixes itself
        5??)     printf 'transient\n' ;;
        *)       printf 'permanent\n' ;;      # other 4xx and unfollowed 3xx: asking again changes nothing
    esac
}

cmd_classify() {
    [ $# -eq 2 ] || { printf '%s: ERROR _classify needs <curl_exit> <http_code>\n' "$PREFIX" >&2; return "$EXIT_USAGE"; }
    classify_fetch "$1" "$2"
}

retry_after_secs() {
    # retry_after_secs <header-file> -> a server-requested wait in whole seconds, capped; empty if none
    [ -f "$1" ] || return 0
    awk -v cap="$RETRY_CAP_SECS" '
        tolower($1) == "retry-after:" { value = $2; sub(/\r$/, "", value)
            if (value ~ /^[0-9]+$/) { print (value + 0 > cap + 0 ? cap : value); exit } }' "$1"
}

BACKOFF_WAIT=0
backoff_wait() {
    # backoff_wait <delay> — sets BACKOFF_WAIT: the delay plus a jitter of up to a fifth of it, never less
    # than a second (so even a short delay can vary), and never past RETRY_CAP_SECS.
    local span=$(( $1 / 5 ))
    [ "$span" -ge 1 ] || span=1
    BACKOFF_WAIT=$(( $1 + RANDOM % (span + 1) ))
    [ "$BACKOFF_WAIT" -le "$RETRY_CAP_SECS" ] || BACKOFF_WAIT="$RETRY_CAP_SECS"
}

cmd_backoff_wait() {
    # _backoff-wait <delay> [<draws>] — prints that many waits, one per line, so the policy can be tested
    local draws="${2:-1}" index=0 value
    for value in "${1:-x}" "$draws"; do
        case "$value" in
            ''|*[!0-9]*) printf '%s: ERROR _backoff-wait needs <delay> [<draws>] as whole numbers\n' "$PREFIX" >&2; return "$EXIT_USAGE" ;;
        esac
    done
    while [ "$index" -lt "$draws" ]; do
        backoff_wait "$1"
        printf '%s\n' "$BACKOFF_WAIT"
        index=$(( index + 1 ))
    done
}

url_label() {
    # url_label <url> — the host and path a log line may name; a query string or fragment can carry a token
    local label="${1#*://}"
    label="${label%%\?*}"
    printf '%s\n' "${label%%#*}"
}

START_EPOCH="$(date +%s)"
deadline_remaining() {
    local left=$(( DEADLINE_SECS - ($(date +%s) - START_EPOCH) ))
    [ "$left" -lt 0 ] && left=0
    printf '%s\n' "$left"
}

HTTP_GET_DETAIL=""
HTTP_OK=0; HTTP_TRANSIENT=10; HTTP_PERMANENT=11; HTTP_DEADLINE=13; HTTP_BAD_LANDING=14
http_get() {
    # http_get <url> <dest> — the ONE network wrapper: bounded attempts, exponential backoff with jitter,
    # Retry-After honored, a per-attempt timeout, an overall deadline, transient classes only. It
    # downloads beside <dest> and renames on success, so a failed fetch never leaves a partial page.
    # Every hop must be https (--proto-redir); the python half's URL policy judged the lead itself and
    # judges where the fetch lands (_url-check), so the two can never drift apart. Names are not resolved,
    # so HTTPS certificate verification is the defense left against a public name that points inward.
    local url="$1" dest="$2" attempt=1 delay="$RETRY_BASE_SECS" tmp hdr err out curl_exit http_code effective verdict wait_secs asked refusal
    tmp="$dest.part.$$"; hdr="$dest.hdr.$$"; err="$dest.err.$$"
    mkdir -p "$(dirname "$dest")"
    while :; do
        if [ "$(deadline_remaining)" -le 0 ]; then
            rm -f "$tmp" "$hdr" "$err"
            HTTP_GET_DETAIL="the overall deadline of ${DEADLINE_SECS}s passed before attempt $attempt"
            return "$HTTP_DEADLINE"
        fi
        # -q must come first: it stops curl reading a .curlrc that could loosen any of these limits.
        out="$(curl -q -sS -L --max-redirs "$MAX_REDIRECTS" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
                    --max-filesize "$MAX_FILESIZE_BYTES" --proto "$CURL_PROTO" --proto-redir "$CURL_PROTO" \
                    -D "$hdr" -o "$tmp" -w '%{http_code} %{url_effective}' "$url" </dev/null 2>"$err")"
        curl_exit=$?
        http_code="${out%% *}"
        effective="${out#* }"
        case "$http_code" in [0-9][0-9][0-9]) ;; *) http_code="000" ;; esac
        verdict="$(classify_fetch "$curl_exit" "$http_code")"
        if [ "$verdict" = "ok" ] && [ ! -s "$tmp" ]; then
            verdict="transient"      # a success with an empty body is a truncated response
        fi
        case "$verdict" in
            ok)
                if ! refusal="$(run_py _url-check "$effective" 2>&1)"; then
                    rm -f "$tmp" "$hdr" "$err"
                    HTTP_GET_DETAIL="the fetch landed somewhere that is not a public https page (${refusal:-the URL check could not run})"
                    return "$HTTP_BAD_LANDING"
                fi
                mv -f "$tmp" "$dest"
                rm -f "$hdr" "$err"
                HTTP_GET_DETAIL="$(wc -c < "$dest" | tr -d ' ') bytes after $attempt attempt(s)"
                return "$HTTP_OK" ;;
            permanent)
                HTTP_GET_DETAIL="permanent error (HTTP $http_code, curl exit $curl_exit) on attempt $attempt: $(head -1 "$err" 2>/dev/null)"
                rm -f "$tmp" "$hdr" "$err"
                return "$HTTP_PERMANENT" ;;
        esac
        if [ "$attempt" -ge "$RETRY_ATTEMPTS" ]; then
            HTTP_GET_DETAIL="transient error (HTTP $http_code, curl exit $curl_exit) after $attempt attempts: $(head -1 "$err" 2>/dev/null)"
            rm -f "$tmp" "$hdr" "$err"
            return "$HTTP_TRANSIENT"
        fi
        asked="$(retry_after_secs "$hdr")"
        if [ -n "$asked" ]; then
            wait_secs="$asked"
        else
            backoff_wait "$delay"
            wait_secs="$BACKOFF_WAIT"
        fi
        if [ "$wait_secs" -ge "$(deadline_remaining)" ] && [ "$wait_secs" -gt 0 ]; then
            HTTP_GET_DETAIL="transient error (HTTP $http_code, curl exit $curl_exit) after $attempt attempts; the next retry (${wait_secs}s away) would pass the ${DEADLINE_SECS}s deadline"
            rm -f "$tmp" "$hdr" "$err"
            return "$HTTP_TRANSIENT"
        fi
        printf '%s: WARNING fetch attempt %s/%s for %s failed (HTTP %s, curl exit %s); retrying in %ss\n' \
            "$PREFIX" "$attempt" "$RETRY_ATTEMPTS" "$(url_label "$url")" "$http_code" "$curl_exit" "$wait_secs" >&2
        sleep "$wait_secs"
        attempt=$(( attempt + 1 ))
        delay=$(( delay * 2 )); [ "$delay" -gt "$RETRY_CAP_SECS" ] && delay="$RETRY_CAP_SECS"
    done
}

cmd_attach_research() {
    # The python half checks the reply and writes the fetch plan; this half fetches each page once
    # (http_get), recording every outcome; the python half then verifies the quotes and attaches them.
    local prepared rc run_dir plan_file results url dest detail
    prepared="$(run_py _attach-prepare "$@")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        [ -n "$prepared" ] && printf '%s\n' "$prepared"
        return "$rc"
    fi
    run_dir="$prepared"
    plan_file="$run_dir/research.fetch-plan.tsv"
    results="$run_dir/research.fetch.tsv"
    : > "$results"
    while IFS="$TAB" read -r url dest; do
        [ -n "$url" ] || continue
        if http_get "$url" "$dest"; then
            printf '%s\tok\t%s\n' "$url" "$HTTP_GET_DETAIL" | tr -d '\r' >> "$results"
        else
            printf '%s\tfailed\t%s\n' "$url" "$(printf '%s' "$HTTP_GET_DETAIL" | tr '\t\r\n' '   ')" >> "$results"
        fi
    done < "$plan_file"
    run_py _attach-apply "$@"
}

# ------------------------------------------------------------------------ main
main() {
    local sub="${1:-}"
    case "$sub" in
        -h|--help|help) print_usage; return $? ;;
        '') print_usage >&2; return "$EXIT_USAGE" ;;
        attach-research) shift; cmd_attach_research "$@" ;;
        _classify) shift; cmd_classify "$@" ;;
        _backoff-wait) shift; cmd_backoff_wait "$@" ;;
        discover|capabilities|config-facts|plan|init-run|next-wave|save-result|validate|agenda|scrub-check|finalize|\
        status|runs|diff|lookup|demo-fixture|score-demo)
            run_py "$@" ;;
        *) printf '%s: ERROR unknown subcommand: %s (try --help)\n' "$PREFIX" "$sub" >&2; return "$EXIT_USAGE" ;;
    esac
}

main "$@"
exit $?

# ------------------------------------------------------------------ the python half
# Never executed by bash (the exit above comes first); run_py's loader runs it with python.
: <<'PYEOF'
import calendar
import hashlib
import html
import ipaddress
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from html.parser import HTMLParser
from urllib.parse import urlsplit

PREFIX = "exhaustive-audit-and-review"
EXIT_OK, EXIT_USAGE, EXIT_PROBLEM, EXIT_BLOCKED = 0, 1, 2, 3
EXIT_TIMED_OUT = 124
MIN_PYTHON = (3, 7)

# ----------------------------------------------------------------- the one schema table
# validate, finalize, the usage text and the agents all read these: the agents' files quote the
# usage text, and the package suite checks that they agree.
SEVERITIES = ("critical", "high", "medium", "low", "info")
EFFORTS = ("trivial", "S", "M", "L", "XL")
RISKS = ("low", "med", "high")
RESEARCH_TIERS = ("official", "vendor", "community")
CHECK_PATTERN = r"^[A-Za-z0-9:_.-]+$"
CAPS = {"check": 40, "subject": 120, "category": 40, "finding": 200, "rationale": 400,
        "recommendation": 400, "notes": 600, "path": 300, "question": 200, "not_reviewed": 200,
        "header_text": 100, "quote": 300}
OVERLONG_FACTOR = 2                   # 1x-2x a cap: VALID-OVERLONG (finalize truncates); beyond: INVALID
DIM_RANGE = (1, 5)
EVIDENCE_RANGE = (1, 5)
QUESTIONS_MAX = 3
NOT_REVIEWED_MAX = 50
FINDINGS_MAX = {"code": 60, "other": 40}
QUOTE_MIN = 20
LEADS_PER_QUESTION_MAX = 2
MULTILINE_FIELDS = ("rationale", "recommendation", "notes")
HEADER_REQUIRED = ("run", "scope", "agent", "files_reviewed", "lines_reviewed")
HEADER_OPTIONAL = ("notes", "not_reviewed")
FINDING_REQUIRED = ("dim", "module", "check", "subject", "severity", "category", "finding", "rationale",
                    "recommendation", "effort", "risk", "evidence")
FINDING_OPTIONAL = ("research_questions",)
TRUNCATED_FIELDS = ("check", "subject", "category", "finding", "rationale", "recommendation")
SEVERITY_RANK = dict((name, rank) for rank, name in enumerate(SEVERITIES))
DIM_NAMES = {1: "code", 2: "architecture", 3: "domain", 4: "operations", 5: "claude-system"}
ELLIPSIS = "…"
FP_CHARS = 8

# ----------------------------------------------------------------- the plan and its estimate
DIMENSION_SCOPES = ((2, "D2-architecture", "exhaustive-audit-and-review-architecture"),
                    (3, "D3-domain", "exhaustive-audit-and-review-domain"),
                    (4, "D4-operations", "exhaustive-audit-and-review-operations"),
                    (5, "D5-claude-system", "exhaustive-audit-and-review-claude-system"))
HEALTH_AGENT = "project-health"
CODE_AGENT = "code-reviewer"
CODE_REVIEW_CHILDREN = 5              # structure, security, test-quality, simplification, smells
CONCURRENCY_HEADROOM = 2              # a wave holds at most cap - 2 concurrent agents
# Processed tokens per agent (input + output + cache creation + cache reads; almost all cache reads,
# because every agent re-reads its context on each tool call), measured from Claude Code's own
# transcripts of a real run of the bundled demo. A code scope's six agents cost this much even when the
# scope is tiny, so its figure stays flat: it is never scaled by lines.
TOKENS_CODE_SPECIALIST = 2200000
TOKENS_CODE_REVIEWER = 4400000
TOKENS_DIMENSION = 3500000            # measured 2.3M-5.0M
TOKENS_HEALTH = 3600000
TOKENS_RESEARCHER = 1200000
MINUTES_CODE_WAVE = 18                # the code reviews are a wave's long pole
MINUTES_OTHER_WAVE = 12
MINUTES_RESEARCH = 13
ESTIMATE_BASIS = "measured on the bundled demo (2 small modules); larger scopes cost more"
TIER_CEILINGS = (("small", 5000), ("medium", 30000), ("large", 100000))
TIER_TOP = "xlarge"
DEFAULT_LOC_BUDGET = 4000
DEFAULT_RESEARCH_BUDGET = 8
DEFAULT_MAX_DEPTH = 3
MIN_DEPTH = 2                         # main session -> code-reviewer -> specialist
DEFAULT_MAX_CONCURRENT = 20
SPAWN_CAP_REMOVED_IN = (2, 1, 224)
SCOPE_CHOICES = ("all", "workspace", "claude-system", "module")
COVERAGE_CHOICES = ("exhaustive", "sampled")
CODE_EXTENSIONS = frozenset(("py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "go", "rs", "java", "kt", "rb", "php",
                             "cs", "swift", "sh", "bash", "ps1", "sql", "c", "cc", "cpp", "h", "hpp", "scala",
                             "lua", "pl", "r"))
RISK_WORDS = ("auth", "login", "token", "secret", "crypt", "password", "sql", "db", "query", "http", "request",
              "api", "upload", "exec", "shell", "eval", "deserial", "pickle", "yaml")
GIT_RECENCY_COMMITS = 2000

# ----------------------------------------------------------------- discovery
SKIP_DIRS = frozenset((".git", "node_modules", ".venv", "venv", "dist", "build", "__pycache__", "vendor",
                       "target", ".next", "coverage"))
MANIFEST_NAMES = ("package.json", "pyproject.toml", "requirements.txt", "setup.py", "go.mod", "Cargo.toml",
                  "pom.xml", "build.gradle", "Gemfile", "composer.json", "Makefile", "Dockerfile")
MANIFEST_SUFFIXES = (".csproj",)
INSTRUCTION_FILES = ("CLAUDE.md", "AGENTS.md", "CLAUDE.local.md", ".claude/CLAUDE.md")
SKIP_MARKERS = ("# exhaustive-audit: skip", "# project-organization: skip")
PLACEHOLDER_RE = re.compile(r"^\..+\.icloud$")
BINARY_SUFFIXES = frozenset((".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".pdf", ".zip", ".gz",
                             ".tgz", ".bz2", ".xz", ".7z", ".jar", ".war", ".class", ".so", ".dylib", ".dll",
                             ".exe", ".bin", ".woff", ".woff2", ".ttf", ".otf", ".eot", ".mp3", ".mp4", ".mov",
                             ".avi", ".wav", ".flac", ".ogg", ".webm", ".psd", ".sqlite", ".db", ".pyc",
                             ".pyo", ".o", ".a", ".lib"))
SNIFF_BYTES = 8192
READ_CHUNK = 1 << 16
GIT_TIMEOUT_SECS = 60
GIT_ERROR_CHARS = 200                 # git's own message, as far as a warning or a fact quotes it
EXIT_GIT_MISSING = 127                # the shell's "command not found", for a git that cannot start
SEPARATOR_ROW = re.compile(r"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$")

# ----------------------------------------------------------------- config facts
CAPABILITY_AGENTS = ("exhaustive-audit-and-review-architecture", "exhaustive-audit-and-review-domain",
                     "exhaustive-audit-and-review-operations", "exhaustive-audit-and-review-claude-system",
                     "exhaustive-audit-and-review-researcher", "code-reviewer", "code-reviewer-structure",
                     "code-reviewer-security", "code-reviewer-test-quality", "code-reviewer-simplification",
                     "code-reviewer-smells", "project-health", "apply-rec-orchestrator", "apply-rec-editor",
                     "apply-rec-analyst", "dependency-modernizer", "runbook-author")
NFC_NAME = "claude-code-new-functionality-check"
NFC_DIR_ENV = "CLAUDE_NEW_FUNCTIONALITY_CHECK_DIR"   # the companion's own override of its data folder
NFC_HELPER = "claude_code_new_functionality_check.sh"
NFC_REMINDER = "claude-code-new-functionality-check-reminder.sh"
NFC_SCRIPTS = (("--status", ("hooks", NFC_REMINDER)), ("inventory", ("skills", NFC_NAME, NFC_HELPER)))
NFC_TIMEOUT_SECS = 60
NFC_OPEN_STATUSES = ("proposed", "accepted")
LEDGER_ROW = re.compile(r"^\|\s*([A-Z]{1,8}-[0-9]+)\s*\|\s*([a-z]+)")
STATUS_LINE_CAP = 300
MARKER_NAMES = ("testing-standard", "retry-standard", "test-command", "logging-standard", "code-quality",
                "project-organization")
SENSITIVE_NAME = re.compile(r"^(?:\.env(?:\..+)?|id_rsa|id_ed25519|id_ecdsa|credentials.*\.json|.+\.pem|.+\.key)$")
SENSITIVE_SAFE_SUFFIXES = (".example", ".sample", ".template", ".dist")
LOCKFILES = frozenset(("package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
                       "bun.lock", "poetry.lock", "Pipfile.lock", "uv.lock", "pdm.lock", "Cargo.lock", "go.sum",
                       "Gemfile.lock", "composer.lock", "packages.lock.json", "mix.lock"))
CI_PATTERNS = tuple(re.compile(pattern) for pattern in (
    r"(^|/)\.github/workflows/[^/]+\.ya?ml$", r"(^|/)\.gitlab-ci\.ya?ml$", r"(^|/)\.circleci/config\.ya?ml$",
    r"(^|/)azure-pipelines\.ya?ml$", r"(^|/)Jenkinsfile$", r"(^|/)\.travis\.ya?ml$",
    r"(^|/)bitbucket-pipelines\.ya?ml$", r"(^|/)\.buildkite/[^/]+\.ya?ml$"))
TEST_DIR_NAMES = frozenset(("tests", "test", "__tests__", "spec", "specs"))
TEST_FILE = re.compile(r"^(?:test_.+\.py|.+_test\.(?:py|go|rb)|.+\.(?:test|spec)\.[cm]?[jt]sx?|test-.+\.sh|.+Test\.java)$")
REQUIREMENTS_FILE = re.compile(r"^requirements(?:[-_.][A-Za-z0-9_-]+)?\.txt$")
REQUIREMENT_LINE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*(.*)$")
POETRY_SECTION = re.compile(r"^tool\.poetry\.(?:group\.[^.]+\.)?(?:dev-)?dependencies$")
SCRIPT_TOKEN = re.compile(r"[^\s'\"=]+\.(?:sh|bash|py|js|mjs|cjs|ts|rb|pl|ps1)\b")
INTERPRETERS = frozenset(("bash", "sh", "zsh", "dash", "python", "python3", "node", "pwsh", "powershell", "ruby", "perl"))
CHECK_TIMEOUT_SECS = 60
CHECK_TAIL_LINES = 20
KILL_GRACE_SECS = 5
COMMAND_LABEL_CAP = 120
SYNTAX_TIMEOUT_SECS = 20
CLI_TIMEOUT_SECS = 10
CLI_ATTEMPTS = 2
VERSION_RE = re.compile(r"\b([0-9]+)\.([0-9]+)\.([0-9]+)\b")

# ----------------------------------------------------------------- runs, results, research
DATA_DIR_NAME = "exhaustive-audit-and-review"
RUNTIME_CONFIG_ENV = "EXHAUSTIVE_AUDIT_RUNTIME_CONFIG"   # the running session's config, when not CLAUDE_CONFIG_DIR (tests)
RUNTIME_MARK = "<runtime>"
RESEARCH_SCOPE = "research"
AUDIT_RUN_PREFIX = "AUDIT-RUN:"
CONTINUATION_PREFIX = "Output token limit hit"
DISPATCH_FAILED = "DISPATCH FAILED"
HANDBACK_TOOL = "SubagentHandback"
MAX_INVALID_ATTEMPTS = 2              # INVALID twice: the scope is failed and never offered again
MAX_RUN_SUFFIX = 99
MAX_REASONS_SHOWN = 8
MAX_NOTE_LINES = 10
UNSEEN_LISTED_MAX = 20                # unreadable paths and placeholders named one by one under Not reviewed
RUN_ID_RE = re.compile(r"^([0-9]{8}T[0-9]{6}Z)(?:-([0-9]+))?$")
STAMP_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
SCOPE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
QUESTION_ID_RE = re.compile(r"^Q[0-9]{2}$")
USAGE_KEYS = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
REPORT_RE = re.compile(r"^exhaustive_audit_v([0-9]+)_[0-9]{8}T[0-9]{6}Z\.md$")
REPORT_LAYOUTS = ("run-dir", "assets-output")
APPLY_LOG_PREFIX = "apply_rec_log"
APPLIED_RE = re.compile(r"\bAPPLIED\b")
MIN_TERM_CHARS = 4
DENYLIST_NAME = "denylist.txt"
DIFF_BUCKETS = ("NEW", "RECURRING", "REGRESSED", "IMPROVED", "RESOLVED", "DROPPED", "APPROXIMATE")
HOUSE_REPEATABLE = ("EXCLUDE", "CHECK", "CONFIG_TEST")

# ----------------------------------------------------------------- masking and path hygiene
def char_class(ranges):
    # Built from code points so that no invisible or bidirectional character sits in this source file.
    return "[" + "".join(re.escape(chr(low)) + ("-" + re.escape(chr(high)) if high != low else "") for low, high in ranges) + "]"


CONTROL_RE = re.compile(char_class(((0x00, 0x08), (0x0B, 0x0C), (0x0E, 0x1F), (0x7F, 0x9F), (0x200E, 0x200F),
                                    (0x202A, 0x202E), (0x2066, 0x2069))))
LINE_BREAK_RE = re.compile(char_class(((0x0A, 0x0A), (0x0D, 0x0D), (0x2028, 0x2029))))
PRIVATE_KEY_MARK = "PRIVATE" + " KEY"
SECRET_PATTERNS = tuple(re.compile(pattern) for pattern in (
    r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", r"\bgh[pousr]_[A-Za-z0-9]{36,}\b", r"\bgithub_pat_[A-Za-z0-9_]{22,}\b",
    r"\bxox[abprs]-[A-Za-z0-9-]{10,}", r"\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b", r"\bAIza[0-9A-Za-z_-]{35}\b",
    r"\bsk-ant-[A-Za-z0-9_-]{20,}", r"\bsk-proj-[A-Za-z0-9_-]{20,}", r"\bsk-[A-Za-z0-9]{32,}\b",
    r"\bhf_[A-Za-z0-9]{30,}\b", r"\bnvapi-[A-Za-z0-9_-]{30,}", r"\bglpat-[A-Za-z0-9_-]{20,}",
    r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
    "-----BEGIN [A-Z ]*" + PRIVATE_KEY_MARK + "-----"))
ASSIGNED_SECRET = re.compile(r"(?i)\b(api[_-]?key|secret|token|passw(?:or)?d|client[_-]?secret|access[_-]?key)"
                             r"(\s*[\"']?\s*[:=]\s*[\"']?)([A-Za-z0-9_\-/+=]{16,})")
MASK_KEEP = 4
MASK_FILL = "****"
HOME_NAME = r"[^/\s\"'`<>|:;,()\[\]]+"
# Another user's home folder: macOS and Linux homes, a Windows home under a WSL mount, and /root; also right
# after file://, whose own slash would otherwise hide the path from the lookbehind.
HOME_DIR_RE = re.compile(r"(?:(?<=file://)|(?<![A-Za-z0-9._~/-]))"
                         r"(?:/(?:Users|home)/{name}|/mnt/[A-Za-z]/Users/{name}|/root(?!{name}))".format(name=HOME_NAME))
WIN_HOME_RE = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:\\(?:Users|Documents and Settings)\\[^\\\s\"'`<>|]+", re.I)
ABSOLUTE_PATH_RE = re.compile(r"(?:(?<![A-Za-z0-9._-])~/|(?<![A-Za-z0-9._~/-])/(?:Users|home|root)/"
                              r"|(?<![A-Za-z0-9._~/-])/mnt/[A-Za-z]/Users/|file:///|(?<![A-Za-z0-9])[A-Za-z]:\\)")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

# ----------------------------------------------------------------- the URL policy
PRIVATE_HOST_SUFFIXES = (".localhost", ".local", ".internal", ".lan", ".home.arpa")
NUMERIC_LABEL_RE = re.compile(r"^(?:[0-9]+|0x[0-9a-f]*)$")
OCTET = r"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
DOTTED_QUAD_RE = re.compile(r"^%s(?:\.%s){3}$" % (OCTET, OCTET))
DNS_LABEL_RE = re.compile(r"^[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?$")
DNS_NAME_MAX = 253
NAT64_PREFIX = ipaddress.IPv6Network("64:ff9b::/96")
IPV4_BITS = 0xFFFFFFFF


class Fail(Exception):
    """A loud, expected stop: the message goes to stderr and the code becomes the exit status."""

    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


def die(code, message):
    raise Fail(code, message)


def log(level, message):
    sys.stderr.write("%s: %s %s\n" % (PREFIX, level, message))


def warn(message):
    log("WARNING", message)


def info(message):
    log("INFO", message)


def emit_json(value):
    sys.stdout.write(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def reason_of(problem):
    return problem.strerror or type(problem).__name__


def parse_int(text):
    text = str(text).strip()
    return int(text) if re.match(r"^[0-9]+$", text) else None


def env_int(name, default, minimum):
    value = parse_int(os.environ.get(name, "")) if os.environ.get(name) else None
    if os.environ.get(name) and (value is None or value < minimum):
        warn("%s must be a whole number >= %d; using %d" % (name, minimum, default))
        return default
    return default if value is None else value


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write_text(path, text):
    # Written beside the target and renamed, so a reader never sees half a file; a write or rename that
    # fails takes its scratch file with it before the error goes on.
    scratch = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(scratch, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(scratch, path)
    except BaseException:
        try:
            os.remove(scratch)
        except OSError:
            pass  # never created, or already gone: the original error is the one that matters
        raise


def write_json(path, value):
    write_text(path, json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def read_json(path):
    return json.loads(read_text(path))


def one_line(text):
    return re.sub(r"\s+", " ", str(text)).strip()


def norm(text):
    return re.sub(r"\s+", " ", str(text).lower()).strip()


def sort_key(name):
    return (name.lower(), name)


# ----------------------------------------------------------------- time
def now_epoch():
    forced = os.environ.get("EXHAUSTIVE_AUDIT_NOW", "")
    if forced:
        if not STAMP_RE.match(forced):
            die(EXIT_USAGE, "EXHAUSTIVE_AUDIT_NOW must look like 20261010T120000Z")
        return calendar.timegm(time.strptime(forced, "%Y%m%dT%H%M%SZ"))
    return int(time.time())


def stamp(epoch):
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(epoch))


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def stamp_epoch(text):
    return calendar.timegm(time.strptime(text, "%Y%m%dT%H%M%SZ"))


# ----------------------------------------------------------------- child processes
def original_umask():
    raw = os.environ.get("EA_UMASK", "")
    return int(raw, 8) if re.match(r"^[0-7]{1,4}$", raw) else 0o022


def restore_umask():
    os.umask(original_umask())


def child_env(cwd=None):
    """The user's own environment for a command the helper runs on their behalf."""
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("EA_"):
            env.pop(key)
    if cwd:
        env["PWD"] = cwd
    return env


def run_bounded(argv, timeout_secs, cwd=None, env=None, combine=True):
    """(exit code, stdout, stderr, timed out). The child runs in its own session, so a timeout kills
    everything it started (a grandchild holding the pipe open cannot stall the wait). A child that
    cannot start raises OSError for the caller to report."""
    process = subprocess.Popen(argv, cwd=cwd, env=env if env is not None else child_env(cwd=cwd),
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT if combine else subprocess.PIPE,
                               start_new_session=True, preexec_fn=restore_umask)
    try:
        out, err = process.communicate(timeout=timeout_secs)
        timed_out = False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # the group exited between the timeout and the kill: nothing is left to stop
        out, err = process.communicate()
        timed_out = True
    decode = lambda data: (data or b"").decode("utf-8", "replace")
    return (EXIT_TIMED_OUT if timed_out else process.returncode), decode(out), decode(err), timed_out


def bash_bin():
    return os.environ.get("EA_BASH") or "bash"


def run_git(ctx, base, args):
    """(exit code, stdout, problem) of git in <base>. A git that cannot start, hangs or fails is a warning
    with git's own message, never a silent empty answer; problem is that message ("" when git succeeded),
    made relative and masked before it is cut, so a cut never leaves half a path or half a secret."""
    where = display_path(ctx, base)
    try:
        code, out, err, timed_out = run_bounded(["git", "-C", base] + args, GIT_TIMEOUT_SECS, combine=False)
    except OSError as problem:
        what = "git could not start (%s)" % reason_of(problem)
        warn("%s in %s" % (what, where))
        return EXIT_GIT_MISSING, "", what
    if not timed_out and code == 0:
        return code, out, ""
    if timed_out:
        what, cause = "git %s timed out after %ds" % (args[0], GIT_TIMEOUT_SECS), ""
    else:
        what = "git %s exited %d" % (args[0], code)
        cause = one_line(clean_text(ctx, err))[:GIT_ERROR_CHARS] or "no message"
    suffix = ": " + cause if cause else ""
    warn("%s in %s%s" % (what, where, suffix))
    return code, out, what + suffix


# ----------------------------------------------------------------- context
class Ctx(object):
    """Where things are: the audited root, the audited config dir and the data dir (from --config-dir and
    the environment), the RUNTIME config (the running session's, whose agents, companion skill and limits
    are the ones that apply), the house.conf settings, and the path spellings printed text must not show."""

    def __init__(self, config_dir=None):
        self.home = os.environ.get("HOME", "")
        session = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(self.home, ".claude")
        self.config = os.path.abspath(os.path.expanduser(config_dir or session))
        self.runtime = os.path.abspath(os.path.expanduser(os.environ.get(RUNTIME_CONFIG_ENV) or session))
        data = os.environ.get("EXHAUSTIVE_AUDIT_DIR") or os.path.join(self.config, DATA_DIR_NAME)
        self.data = os.path.abspath(os.path.expanduser(data))
        self.root = None
        self.root_given = None
        self.extra_bases = []
        self._house = None

    @property
    def house(self):
        if self._house is None:
            self._house = load_house(os.path.join(self.data, "house.conf"))
        return self._house

    def set_root(self, given):
        raw = given or os.getcwd()
        path = os.path.expanduser(raw)
        if not os.path.isdir(path):
            die(EXIT_USAGE, "the root is not a folder: %s" % raw)
        self.root = os.path.realpath(path)
        self.root_given = os.path.abspath(path)


def inside(path, base):
    path, base = os.path.realpath(path), os.path.realpath(base)
    return path == base or path.startswith(base.rstrip(os.sep) + os.sep)


def same_folder(first, second):
    return os.path.realpath(first) == os.path.realpath(second)


def spellings(path):
    found = []
    if path:
        for candidate in (os.path.abspath(path), os.path.realpath(path)):
            candidate = candidate.rstrip("/")
            if len(candidate) > 1 and candidate not in found:
                found.append(candidate)
    return found


def path_bases(ctx):
    """(absolute spelling, placeholder) pairs, longest first, so a nested folder wins over its parent."""
    pairs = []
    for path in spellings(ctx.root) + spellings(ctx.root_given):
        pairs.append((path, "."))
    for path in spellings(ctx.config):
        pairs.append((path, "<config>"))
    if not same_folder(ctx.runtime, ctx.config):
        for path in spellings(ctx.runtime):
            pairs.append((path, RUNTIME_MARK))
    for path, mark in ctx.extra_bases:
        for spelled in spellings(path):
            pairs.append((spelled, mark))
    if not inside(ctx.data, ctx.config):
        for path in spellings(ctx.data):
            pairs.append((path, "<data>"))
    for path in spellings(ctx.home):
        pairs.append((path, "~"))
    unique = []
    for pair in pairs:
        if pair not in unique:
            unique.append(pair)
    unique.sort(key=lambda pair: -len(pair[0]))
    return unique


def relativize(ctx, text):
    """Absolute paths become root-relative, <config>/..., <data>/... or ~/...; any other home folder
    becomes ~. Printed text never carries a machine's absolute paths."""
    if not text:
        return text
    for base, mark in path_bases(ctx):
        prefix = "" if mark == "." else mark + "/"
        text = re.sub(re.escape(base) + "/", lambda _match, replacement=prefix: replacement, text)
        text = re.sub(re.escape(base) + r"(?![A-Za-z0-9._-])", lambda _match, replacement=mark: replacement, text)
    text = HOME_DIR_RE.sub("~", text)
    return WIN_HOME_RE.sub("~", text)


def display_path(ctx, path):
    return relativize(ctx, os.path.abspath(path))


def resolve_arg_path(ctx, value):
    for mark, base in (("<config>/", ctx.config), ("<data>/", ctx.data), (RUNTIME_MARK + "/", ctx.runtime)):
        if value.startswith(mark):
            return os.path.join(base, value[len(mark):])
    return os.path.abspath(os.path.expanduser(value))


def mask_value(value):
    return value[:MASK_KEEP] + MASK_FILL + value[-MASK_KEEP:]


def mask_secrets(text):
    """(text with every secret-shaped value masked to its first and last four characters, how many)."""
    count = [0]

    def whole(match):
        count[0] += 1
        return mask_value(match.group(0))

    def assigned(match):
        value = match.group(3)
        if not (re.search(r"[0-9]", value) and re.search(r"[A-Za-z]", value)):
            return match.group(0)
        count[0] += 1
        return match.group(1) + match.group(2) + mask_value(value)

    for pattern in SECRET_PATTERNS:
        text = pattern.sub(whole, text)
    return ASSIGNED_SECRET.sub(assigned, text), count[0]


def mask_document(node):
    """(node with every string masked, how many values were masked)."""
    if isinstance(node, str):
        return mask_secrets(node)
    if isinstance(node, list):
        total, items = 0, []
        for item in node:
            masked, count = mask_document(item)
            items.append(masked)
            total += count
        return items, total
    if isinstance(node, dict):
        total, result = 0, {}
        for key, value in node.items():
            masked, count = mask_document(value)
            result[key] = masked
            total += count
        return result, total
    return node, 0


def clean_text(ctx, text):
    return mask_secrets(relativize(ctx, text))[0]


def clean_obj(ctx, node):
    if isinstance(node, str):
        return clean_text(ctx, node)
    if isinstance(node, list):
        return [clean_obj(ctx, item) for item in node]
    if isinstance(node, dict):
        return dict((key, clean_obj(ctx, value)) for key, value in node.items())
    return node


def command_label(ctx, command):
    label = one_line(clean_text(ctx, command))
    return label if len(label) <= COMMAND_LABEL_CAP else label[:COMMAND_LABEL_CAP - 1] + ELLIPSIS


# ----------------------------------------------------------------- arguments
def parse_args(argv, spec, positional_max, usage):
    """Strict flags: an unknown flag or a flag without its value is a usage error, never ignored.
    spec maps a flag to "value", "multi", "bool" or "scope" (the value "module" takes one more word)."""
    spec = dict(spec)
    spec["--config-dir"] = "value"
    options, positional, index = {}, [], 0
    while index < len(argv):
        token = argv[index]
        if token.startswith("-") and token != "-":
            kind = spec.get(token)
            if kind is None:
                die(EXIT_USAGE, "unknown option %s (usage: %s)" % (token, usage))
            if kind == "bool":
                options[token] = True
                index += 1
                continue
            if index + 1 >= len(argv):
                die(EXIT_USAGE, "%s needs a value (usage: %s)" % (token, usage))
            value = argv[index + 1]
            index += 2
            if kind == "multi":
                options.setdefault(token, []).append(value)
            elif kind == "scope" and value == "module":
                if index >= len(argv):
                    die(EXIT_USAGE, "--scope module needs a module name (usage: %s)" % usage)
                options[token] = value
                options[token + " name"] = argv[index]
                index += 1
            else:
                options[token] = value
            continue
        positional.append(token)
        index += 1
    if len(positional) > positional_max:
        die(EXIT_USAGE, "unexpected argument %s (usage: %s)" % (positional[positional_max], usage))
    return options, positional


# ----------------------------------------------------------------- house.conf
def load_house(path):
    house = {"EXCLUDE": [], "CHECK": [], "CONFIG_TEST": [], "MODULE_REGISTRY": None, "REPORT_LAYOUT": "run-dir",
             "MAX_LOC_PER_REVIEW": DEFAULT_LOC_BUDGET, "RESEARCH_BUDGET": DEFAULT_RESEARCH_BUDGET}
    if not os.path.isfile(path):
        return house
    try:
        text = read_text(path)
    except OSError as problem:
        warn("house.conf could not be read (%s); every default applies" % (problem.strerror or problem))
        return house
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            warn("house.conf line %d is not KEY=value (ignored)" % number)
            continue
        key, value = [part.strip() for part in line.split("=", 1)]
        if key in HOUSE_REPEATABLE:
            if value:
                house[key].append(value)
        elif key == "MODULE_REGISTRY":
            house[key] = value or None
        elif key == "REPORT_LAYOUT":
            if value in REPORT_LAYOUTS:
                house[key] = value
            else:
                warn("house.conf line %d: REPORT_LAYOUT must be %s (kept %s)" % (number, " or ".join(REPORT_LAYOUTS), house[key]))
        elif key in ("MAX_LOC_PER_REVIEW", "RESEARCH_BUDGET"):
            minimum = 1 if key == "MAX_LOC_PER_REVIEW" else 0
            parsed = parse_int(value)
            if parsed is None or parsed < minimum:
                warn("house.conf line %d: %s must be a whole number >= %d (kept %d)" % (number, key, minimum, house[key]))
            else:
                house[key] = parsed
        else:
            warn("house.conf line %d: unknown key %s (ignored)" % (number, key))
    return house


# ----------------------------------------------------------------- discovery
def count_text_lines(path):
    """Lines in a text file, or None for a binary one; a last line without a newline counts. A file that
    cannot be read raises OSError, so the caller can record it by name."""
    if os.path.splitext(path)[1].lower() in BINARY_SUFFIXES:
        return None
    with open(path, "rb") as handle:
        head = handle.read(SNIFF_BYTES)
        if b"\0" in head:
            return None
        count, last = head.count(b"\n"), head[-1:]
        while True:
            chunk = handle.read(READ_CHUNK)
            if not chunk:
                break
            count += chunk.count(b"\n")
            last = chunk[-1:]
    if last and last != b"\n":
        count += 1
    return count


def tier_for(lines):
    for name, ceiling in TIER_CEILINGS:
        if lines < ceiling:
            return name
    return TIER_TOP


def to_root_relative(ctx, value):
    """A root-relative path for an EXCLUDE= value (a name, a relative path, or an absolute path in any
    spelling of the root), or None when it points outside the root or is malformed."""
    expanded = os.path.expanduser(value.strip())
    if os.path.isabs(expanded):
        real = os.path.realpath(expanded)
        if not inside(real, ctx.root) or real == ctx.root:
            return None
        return os.path.relpath(real, ctx.root).replace(os.sep, "/")
    parts = [part for part in expanded.replace("\\", "/").split("/") if part not in ("", ".")]
    if not parts or ".." in parts:
        return None
    return "/".join(parts)


def resolve_excludes(ctx, extra):
    found = []
    for value, reason in [(value, "house.conf") for value in ctx.house["EXCLUDE"]] + [(value, "--exclude") for value in extra]:
        rel = to_root_relative(ctx, value)
        if rel is None:
            warn("an EXCLUDE entry points outside the root or is malformed (ignored): %s" % relativize(ctx, value))
            continue
        found.append((rel, reason))
    return found


def excluded_by(rel, excludes):
    for path, reason in excludes:
        if rel == path or rel.startswith(path + "/"):
            return reason
    return None


def top_manifests(folder):
    names = []
    for name in safe_listdir(folder):
        if (name in MANIFEST_NAMES or name.endswith(MANIFEST_SUFFIXES)) and os.path.isfile(os.path.join(folder, name)):
            names.append(name)
    return sorted(names, key=sort_key)


def top_instructions(folder):
    return [name for name in INSTRUCTION_FILES if os.path.isfile(os.path.join(folder, name))]


def safe_listdir(folder, unreadable=None):
    """A folder's entries, sorted; [] when it does not exist. A folder that exists but cannot be listed is
    never passed off as an empty one: it goes into unreadable as (folder, why) when the caller keeps that
    list, else it is a warning."""
    try:
        return sorted(os.listdir(folder), key=sort_key)
    except (FileNotFoundError, NotADirectoryError):
        return []
    except OSError as problem:
        if unreadable is None:
            warn("a folder could not be listed and counts as empty (%s)" % reason_of(problem))
        else:
            unreadable.append((folder, reason_of(problem)))
        return []


def list_problem(folder):
    """Why a folder cannot be listed, or None when it can."""
    try:
        os.listdir(folder)
    except OSError as problem:
        return reason_of(problem)
    return None


def qualifies(folder):
    return (os.path.lexists(os.path.join(folder, ".git")) or bool(top_manifests(folder))
            or any(os.path.isfile(os.path.join(folder, name)) for name in ("CLAUDE.md", "AGENTS.md")))


def has_skip_marker(folder):
    path = os.path.join(folder, "CLAUDE.md")
    if not os.path.isfile(path) or os.path.islink(path):
        return False
    try:
        lines = read_text(path).splitlines()
    except OSError:
        return False
    return any(line.strip().startswith(marker) for line in lines for marker in SKIP_MARKERS)


def cell_name(cell):
    cell = cell.strip()
    link = re.match(r"^\[([^\]]+)\]\([^)]*\)", cell)
    if link:
        cell = link.group(1)
    cell = cell.strip("`* ").rstrip("/")
    return cell[2:] if cell.startswith("./") else cell


def registry_names(text):
    """The first column of every markdown table row that is not a header or separator row."""
    rows = [line.strip() for line in text.splitlines()]
    names = []
    for index, line in enumerate(rows):
        if not line.startswith("|") or SEPARATOR_ROW.match(line):
            continue
        following = rows[index + 1] if index + 1 < len(rows) else ""
        if SEPARATOR_ROW.match(following):
            continue
        name = cell_name(line.strip("|").split("|")[0])
        if name and name not in names:
            names.append(name)
    return names


def load_registry(ctx):
    configured = ctx.house["MODULE_REGISTRY"]
    rel = to_root_relative(ctx, configured) if configured else None
    if configured and rel is None:
        warn("MODULE_REGISTRY points outside the root (ignored)")
    if rel is None and os.path.isfile(os.path.join(ctx.root, "MODULES.md")):
        rel = "MODULES.md"
    if rel is None:
        return None, []
    path = os.path.join(ctx.root, rel)
    if not os.path.isfile(path):
        warn("the module registry %s does not exist; modules are ordered by name" % rel)
        return None, []
    return rel, registry_names(read_text(path))


def walk_files(base, rel_module, excludes, unreadable):
    """Every file under base (module-relative), never descending into SKIP_DIRS, an excluded folder or a
    symlinked folder; a folder the walk cannot list goes into unreadable."""
    found = []

    def record(problem):
        unreadable.append((problem.filename or base, reason_of(problem)))

    for current, dirs, files in os.walk(base, topdown=True, followlinks=False, onerror=record):
        rel_dir = os.path.relpath(current, base).replace(os.sep, "/")
        rel_dir = "" if rel_dir == "." else rel_dir
        keep = []
        for name in dirs:
            child = rel_dir + "/" + name if rel_dir else name
            rooted = child if rel_module == "." else rel_module + "/" + child
            if name in SKIP_DIRS or excluded_by(rooted, excludes) or os.path.islink(os.path.join(current, name)):
                continue
            keep.append(name)
        dirs[:] = sorted(keep)
        for name in files:
            found.append(rel_dir + "/" + name if rel_dir else name)
    return sorted(found)


def git_tracked(ctx, base):
    code, out, _ = run_git(ctx, base, ["ls-files", "-z"])
    if code != 0:
        return None
    return sorted(name for name in out.split("\0") if name)


def git_untracked_placeholders(ctx, base):
    code, out, _ = run_git(ctx, base, ["ls-files", "-z", "-o", "--exclude-standard"])
    if code != 0:
        return []
    return [name for name in out.split("\0") if name and PLACEHOLDER_RE.match(os.path.basename(name))]


def join_rel(module_rel, name):
    return name if module_rel == "." else module_rel + "/" + name


def blocked_folder(base, name):
    """The first folder on the way from base down to a tracked file that cannot be entered (else the file's
    own folder): that folder, not each file under it, is what discovery could not read."""
    current = base
    for part in name.split("/")[:-1]:
        current = os.path.join(current, part)
        if not os.access(current, os.X_OK):
            return current
    return current


def module_files(ctx, module_rel, excludes, unreadable):
    """(git, entries, placeholders) for one module. An entry is {path, lines, text} with a root-relative
    path; git modules list tracked files, others are walked. Symlinks, files whose real path leaves the
    module, and iCloud placeholders are never counted; a folder or file that cannot be read goes into
    unreadable as (absolute path, why) instead of silently counting as absent."""
    base = ctx.root if module_rel == "." else os.path.join(ctx.root, module_rel)
    base_real = os.path.realpath(base)
    git = os.path.lexists(os.path.join(base, ".git"))
    names = git_tracked(ctx, base) if git else None
    if git and names is None:
        warn("git ls-files failed in %s; its files are counted by walking the folder instead" % module_rel)
    if names is None:
        names = walk_files(base, module_rel, excludes, unreadable)
    entries, placeholders = [], set()
    for name in names:
        rooted = join_rel(module_rel, name)
        if excluded_by(rooted, excludes):
            continue
        full = os.path.join(base, name)
        leaf = os.path.basename(name)
        if PLACEHOLDER_RE.match(leaf):
            placeholders.add(rooted)
            continue
        try:
            os.lstat(full)
        except (FileNotFoundError, NotADirectoryError):
            evicted = "." + leaf + ".icloud"
            if os.path.lexists(os.path.join(os.path.dirname(full), evicted)):
                folder = os.path.dirname(rooted)
                placeholders.add(folder + "/" + evicted if folder and folder != "." else evicted)
            continue
        except OSError as problem:
            unreadable.append((blocked_folder(base, name), reason_of(problem)))
            continue
        if os.path.islink(full) or not os.path.isfile(full) or not inside(full, base_real):
            continue
        try:
            lines = count_text_lines(full)
        except OSError as problem:
            unreadable.append((full, reason_of(problem)))
            lines = None
        entries.append({"path": rooted, "lines": lines, "text": lines is not None})
    if git and names is not None:
        for name in git_untracked_placeholders(ctx, base):
            placeholders.add(join_rel(module_rel, name))
    return git, entries, sorted(placeholders)


def is_code(path):
    return os.path.splitext(path)[1][1:].lower() in CODE_EXTENSIONS


def root_relative(ctx, path):
    rel = os.path.relpath(path, ctx.root).replace(os.sep, "/")
    return rel if not rel.startswith("..") else relativize(ctx, path)


def unreadable_records(ctx, unreadable):
    """{path, why} for each (absolute path, why) discovery could not read, root-relative, once each, sorted;
    each is also a warning, since nothing under it is counted or reviewed."""
    records = []
    for path, why in unreadable:
        record = {"path": root_relative(ctx, path), "reason": why}
        if record not in records:
            records.append(record)
    records.sort(key=lambda record: record["path"])
    for record in records:
        warn("%s could not be read (%s); nothing in it is counted or reviewed" % (record["path"], record["reason"]))
    return records


def discover(ctx, extra_excludes=()):
    """(the discover document, per-module details for plan and config-facts)."""
    root = ctx.root
    excludes = resolve_excludes(ctx, extra_excludes)
    candidates, plain, skipped, excluded, unreadable = [], [], [], [], []
    for name in safe_listdir(root, unreadable):
        if name.startswith("."):
            continue
        full = os.path.join(root, name)
        reason = excluded_by(name, excludes)
        if reason:
            excluded.append({"path": name, "reason": reason})
            continue
        if os.path.islink(full):
            if os.path.isdir(full):
                skipped.append({"path": name, "reason": "symlink"})
            continue
        if not os.path.isdir(full):
            continue
        problem = list_problem(full)
        if problem:
            unreadable.append((full, problem))
            continue
        if not qualifies(full):
            plain.append(name)
        elif has_skip_marker(full):
            skipped.append({"path": name, "reason": "skip-marker"})
        else:
            candidates.append(name)
    for rel, reason in excludes:
        if "/" in rel and os.path.lexists(os.path.join(root, rel)):
            excluded.append({"path": rel, "reason": reason})
    specs = []
    if candidates:
        specs = [(name, name, False) for name in candidates]
        skipped.extend({"path": name, "reason": "not-a-module"} for name in plain)
    elif os.path.lexists(os.path.join(root, ".git")) or top_manifests(root):
        if has_skip_marker(root):
            skipped.append({"path": ".", "reason": "skip-marker"})
        else:
            specs = [(os.path.basename(root), ".", True)]
    else:
        skipped.extend({"path": name, "reason": "not-a-module"} for name in plain)
        warn("no module found: no child folder is a git repo or holds a manifest or CLAUDE.md, and the root is neither")
    registry, listed = load_registry(ctx)
    position = dict((name, index) for index, name in enumerate(listed))
    for name in listed:
        if name not in [spec[0] for spec in specs] and specs and not specs[0][2]:
            info("the registry lists %s, which is not a module here" % name)
    specs.sort(key=lambda spec: (0, position[spec[0]]) if spec[0] in position else (1,) + sort_key(spec[0]))
    modules, details, placeholders = [], {}, []
    for idx, (name, rel, is_root) in enumerate(specs, 1):
        git, entries, held = module_files(ctx, rel, excludes, unreadable)
        text_entries = [entry for entry in entries if entry["text"]]
        folder = root if rel == "." else os.path.join(root, rel)
        module = {"idx": idx, "name": name, "path": rel, "is_root": is_root, "git": git,
                  "files": len(text_entries), "lines": sum(entry["lines"] for entry in text_entries),
                  "manifests": top_manifests(folder), "instructions": top_instructions(folder), "skip_marker": False}
        module["tier"] = tier_for(module["lines"])
        modules.append(module)
        placeholders.extend(held)
        details[name] = {"base": folder, "entries": entries, "git": git,
                         "code": [entry for entry in text_entries if is_code(entry["path"])]}
    document = {"root_name": os.path.basename(root), "config_dir": "<config>", "registry": registry,
                "modules": modules, "excluded": sorted(excluded, key=lambda item: item["path"]),
                "skipped": sorted(skipped, key=lambda item: item["path"]), "placeholders": sorted(placeholders),
                "unreadable": unreadable_records(ctx, unreadable),
                "totals": {"modules": len(modules), "files": sum(m["files"] for m in modules),
                           "lines": sum(m["lines"] for m in modules)}}
    return clean_obj(ctx, document), details


def cmd_discover(argv):
    options, _ = parse_args(argv, {"--root": "value", "--exclude": "multi"}, 0, "discover [--root DIR] [--exclude NAME]...")
    ctx = Ctx(options.get("--config-dir"))
    ctx.set_root(options.get("--root"))
    document, _ = discover(ctx, options.get("--exclude", []))
    emit_json(document)
    return EXIT_OK


# ----------------------------------------------------------------- capabilities
def load_settings(folder, warnings):
    """settings.json of one config folder (the audited one or the runtime one); {} when absent."""
    path = os.path.join(folder, "settings.json")
    if not os.path.isfile(path):
        return {}
    try:
        data = read_json(path)
    except (OSError, ValueError) as problem:
        warnings.append("a settings.json could not be read as JSON (%s)" % type(problem).__name__)
        return {}
    return data if isinstance(data, dict) else {}


def read_limit(name, settings_env, default, minimum, warnings):
    raw = os.environ.get(name)
    if raw is not None and raw.strip():
        value = parse_int(raw)
        if value is not None and value >= minimum:
            return value, "env"
        warnings.append("%s in the environment is not a whole number >= %d; ignored" % (name, minimum))
    raw = settings_env.get(name) if isinstance(settings_env, dict) else None
    if raw is not None and str(raw).strip():
        value = parse_int(raw)
        if value is not None and value >= minimum:
            return value, "settings"
        warnings.append("settings.json env %s is not a whole number >= %d; ignored" % (name, minimum))
    return default, "default"


def limits(ctx, warnings):
    """The nesting depth and concurrency cap that apply to the agents this session will dispatch: the
    session's environment, else the RUNTIME config's settings.json, else the defaults."""
    settings = load_settings(ctx.runtime, warnings)
    env = settings.get("env") if isinstance(settings.get("env"), dict) else {}
    depth, depth_source = read_limit("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH", env, DEFAULT_MAX_DEPTH, 0, warnings)
    cap, cap_source = read_limit("CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS", env, DEFAULT_MAX_CONCURRENT, 1, warnings)
    return {"max_depth": depth, "depth_source": depth_source, "max_concurrent": cap, "concurrent_source": cap_source}


def enabled_plugins(settings):
    plugins = settings.get("enabledPlugins")
    if not isinstance(plugins, dict):
        return []
    return sorted(name for name, on in plugins.items() if on is True)


def plugin_enabled(plugins, needle):
    return any(needle in name for name in plugins)


def cli_version(warnings):
    """The installed CLI's version from `claude --version`: a timeout is retried once, anything else
    is permanent; every failure is a warning that says why and after how many attempts."""
    timeout = env_int("EXHAUSTIVE_AUDIT_CLI_TIMEOUT_SECS", CLI_TIMEOUT_SECS, 1)
    for attempt in range(1, CLI_ATTEMPTS + 1):
        try:
            code, out, _, timed_out = run_bounded(["claude", "--version"], timeout)
        except OSError as problem:
            warnings.append("claude --version could not start (%s); cli_version is unknown" % (problem.strerror or problem))
            return None
        if timed_out:
            if attempt < CLI_ATTEMPTS:
                warn("claude --version timed out after %ds (attempt %d/%d); retrying" % (timeout, attempt, CLI_ATTEMPTS))
                continue
            warnings.append("claude --version timed out after %d attempt(s) of %ds each; cli_version is unknown" % (attempt, timeout))
            return None
        if code != 0:
            warnings.append("claude --version exited %d on attempt %d (a permanent error, not retried); cli_version is unknown" % (code, attempt))
            return None
        match = VERSION_RE.search(out)
        if not match:
            warnings.append("claude --version printed no version number; cli_version is unknown")
            return None
        return match.group(0)
    return None


def version_tuple(text):
    match = VERSION_RE.search(text or "")
    return tuple(int(part) for part in match.groups()) if match else None


def is_runtime_config(ctx):
    """Whether the config under audit is the running session's own: only then may its own code run."""
    return same_folder(ctx.config, ctx.runtime)


def nfc_data_dir(ctx, config):
    """The companion's data folder for one config folder. Its override describes the running machine, so it
    relocates the runtime config's folder only; a config from elsewhere always keeps its own."""
    override = os.environ.get(NFC_DIR_ENV, "").strip()
    if override and same_folder(config, ctx.runtime):
        return os.path.abspath(os.path.expanduser(override))
    return os.path.join(config, NFC_NAME)


def runtime_companions(ctx):
    """The companion skill the running session can call (its Skill tool sees the runtime config only)."""
    helper = os.path.join(ctx.runtime, "skills", NFC_NAME, NFC_HELPER)
    reminder = os.path.join(ctx.runtime, "hooks", NFC_REMINDER)
    return {"new_functionality_check": {"present": os.path.isfile(helper),
                                        "helper": display_path(ctx, helper) if os.path.isfile(helper) else None,
                                        "reminder": display_path(ctx, reminder) if os.path.isfile(reminder) else None}}


def audited_companions(ctx, settings):
    """What the config under audit enables or holds: its plugins and the companion's data folder."""
    plugins = enabled_plugins(settings)
    return {"superpowers": {"enabled": plugin_enabled(plugins, "superpowers")},
            "autoharness": {"enabled": plugin_enabled(plugins, "autoharness")},
            "lsp": {"typescript": plugin_enabled(plugins, "typescript-lsp"), "pyright": plugin_enabled(plugins, "pyright-lsp")},
            "new_functionality_check_data": os.path.isdir(nfc_data_dir(ctx, ctx.config))}


def cmd_capabilities(argv):
    options, _ = parse_args(argv, {"--strict": "bool"}, 0, "capabilities [--strict]")
    ctx = Ctx(options.get("--config-dir"))
    warnings, blocked = [], []
    audited_settings = load_settings(ctx.config, warnings)
    limit = limits(ctx, warnings)
    if limit["max_depth"] < MIN_DEPTH:
        blocked.append("subagent nesting depth %d is below %d: code review runs main session -> code-reviewer -> "
                       "specialist; raise CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH to %d or more" % (limit["max_depth"], MIN_DEPTH, MIN_DEPTH))
    version = cli_version(warnings)
    parsed = version_tuple(version)
    if parsed is not None and parsed < SPAWN_CAP_REMOVED_IN:
        warnings.append("Claude Code %s is older than 2.1.224, which removed the per-session cap of 200 subagent "
                        "spawns; a large audit can hit that cap, so update Claude Code first" % version)
    # The agents that get dispatched are the running session's, whatever config is being audited.
    agents = dict((name, os.path.isfile(os.path.join(ctx.runtime, "agents", name + ".md"))) for name in CAPABILITY_AGENTS)
    document = {"config_dir": "<config>", "runtime_config": "<config>" if same_folder(ctx.runtime, ctx.config) else RUNTIME_MARK,
                "cli_version": version, "agents": agents, "companions": runtime_companions(ctx),
                "audited_config": {"companions": audited_companions(ctx, audited_settings)},
                "limits": limit, "blocked": blocked, "warnings": warnings}
    emit_json(clean_obj(ctx, document))
    return EXIT_BLOCKED if blocked and options.get("--strict") else EXIT_OK


# ----------------------------------------------------------------- config facts
def frontmatter(path):
    """(present, fields) of a markdown file's leading --- block; a value is a string or a list."""
    try:
        lines = read_text(path).splitlines()
    except OSError:
        return False, {}
    if not lines or lines[0].strip() != "---":
        return False, {}
    fields, key = {}, None
    for line in lines[1:]:
        if line.strip() == "---":
            return True, fields
        item = re.match(r"^\s+-\s+(.*)$", line)
        if item and key:
            if not isinstance(fields.get(key), list):
                fields[key] = []
            fields[key].append(unquote(item.group(1)))
            continue
        pair = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if pair:
            key = pair.group(1)
            fields[key] = unquote(pair.group(2).strip())
    return False, {}


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def truthy(value):
    return isinstance(value, str) and value.strip().lower() in ("true", "yes", "1")


def tool_list(value):
    if isinstance(value, list):
        return [item for item in value if item]
    if not isinstance(value, str) or not value.strip():
        return None
    return [unquote(part) for part in value.strip().strip("[]").split(",") if part.strip()]


def markdown_sections(text):
    sections, fenced = [], False
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            continue
        if not fenced and line.startswith("## "):
            sections.append(line[3:].strip())
    return sections


def command_basename(command, args):
    if not isinstance(command, str) or not command.strip():
        return None
    if isinstance(args, list):
        first = os.path.basename(command.strip())
        if first in INTERPRETERS:
            for arg in args:
                if isinstance(arg, str) and arg and not arg.startswith("-"):
                    return os.path.basename(arg)
        return first
    scripts = SCRIPT_TOKEN.findall(command)
    if scripts:
        return os.path.basename(scripts[-1])
    return os.path.basename(command.strip().split()[0])


def settings_facts(settings):
    hooks = []
    registered = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    for event, groups in registered.items():
        for group in groups if isinstance(groups, list) else []:
            if not isinstance(group, dict):
                continue
            matcher = group.get("matcher") if isinstance(group.get("matcher"), str) and group.get("matcher") else None
            for hook in group.get("hooks") or []:
                if isinstance(hook, dict):
                    hooks.append({"event": event, "matcher": matcher, "form": "exec" if isinstance(hook.get("args"), list) else "shell",
                                  "command_basename": command_basename(hook.get("command"), hook.get("args"))})
    permissions = settings.get("permissions") if isinstance(settings.get("permissions"), dict) else {}
    count = lambda key: len(permissions.get(key)) if isinstance(permissions.get(key), list) else 0
    env = settings.get("env") if isinstance(settings.get("env"), dict) else {}
    return {"hooks": hooks,
            "permissions": {"allow": count("allow"), "deny": count("deny"), "ask": count("ask"),
                            "default_mode": permissions.get("defaultMode") if isinstance(permissions.get("defaultMode"), str) else None},
            "enabled_plugins": enabled_plugins(settings), "env_keys": sorted(env),
            "model": settings.get("model") if isinstance(settings.get("model"), str) else None}


def agent_facts(ctx):
    folder = os.path.join(ctx.config, "agents")
    found = []
    for name in safe_listdir(folder):
        path = os.path.join(folder, name)
        if not name.endswith(".md") or not os.path.isfile(path):
            continue
        _, fields = frontmatter(path)
        found.append({"name": fields.get("name") if isinstance(fields.get("name"), str) and fields.get("name") else name[:-3],
                      "tools": tool_list(fields.get("tools")), "model": fields.get("model") if isinstance(fields.get("model"), str) else None,
                      "omit_claude_md": truthy(fields.get("omitClaudeMd"))})
    return found


def skill_facts(ctx):
    folder = os.path.join(ctx.config, "skills")
    found = []
    for name in safe_listdir(folder):
        skill = os.path.join(folder, name, "SKILL.md")
        if not os.path.isfile(skill):
            continue
        present, fields = frontmatter(skill)
        description = fields.get("description") if present else None
        found.append({"name": name, "has_frontmatter": present,
                      "description_chars": len(description) if isinstance(description, str) else 0,
                      "has_resources": os.path.isdir(os.path.join(folder, name, "resources")),
                      "model_invocable": not truthy(fields.get("disable-model-invocation"))})
    return found


def hook_facts(ctx):
    folder = os.path.join(ctx.config, "hooks")
    found = []
    for name in safe_listdir(folder):
        path = os.path.join(folder, name)
        if not os.path.isfile(path) or not name.endswith((".sh", ".py")):
            continue
        if name.endswith(".sh"):
            try:
                code, _, _, timed_out = run_bounded([bash_bin(), "-n", path], SYNTAX_TIMEOUT_SECS)
                syntax_ok = code == 0 and not timed_out
            except OSError as problem:
                warn("bash -n could not run on %s (%s)" % (name, problem.strerror or problem))
                syntax_ok = None
        else:
            try:
                compile(read_text(path), name, "exec")
                syntax_ok = True
            except (SyntaxError, ValueError):
                syntax_ok = False
        found.append({"name": name, "executable": os.access(path, os.X_OK), "syntax_ok": syntax_ok})
    return found


def claude_md_facts(ctx):
    path = os.path.join(ctx.config, "CLAUDE.md")
    if not os.path.isfile(path):
        return {"bytes": None, "sections": []}
    return {"bytes": os.path.getsize(path), "sections": markdown_sections(read_text(path))}


def nfc_env(ctx):
    """The environment for the companion's scripts, pointed at the AUDITED config and its data folder."""
    targets = {NFC_DIR_ENV: nfc_data_dir(ctx, ctx.config),
               "NEW_FUNCTIONALITY_CHECK_CLAUDE_DIR": ctx.config,
               "NEW_FUNCTIONALITY_CHECK_STATE_FILE": os.path.join(ctx.config, "tmp", NFC_NAME + "-state.json"),
               "NEW_FUNCTIONALITY_CHECK_UPDATE_RESULT_FILE": os.path.join(ctx.config, ".last-update-result.json")}
    env = child_env()
    if is_runtime_config(ctx):
        # The user's own overrides describe this very config, so they stay.
        for key, value in targets.items():
            env.setdefault(key, value)
    else:
        # They describe this machine, never a config from elsewhere.
        env.update(targets)
    env[NFC_DIR_ENV] = targets[NFC_DIR_ENV]   # the resolver already applies the override where it belongs
    return env


def open_proposals(ledger):
    if not os.path.isfile(ledger):
        return []
    found = []
    for line in read_text(ledger).splitlines():
        match = LEDGER_ROW.match(line)
        if match and match.group(2) in NFC_OPEN_STATUSES:
            found.append(match.group(1))
    return found


def run_companion(argv, env, what):
    try:
        code, out, _, timed_out = run_bounded(argv, NFC_TIMEOUT_SECS, env=env)
    except OSError as problem:
        warn("the new-functionality check's %s could not start (%s)" % (what, problem.strerror or problem))
        return None
    if timed_out or code != 0:
        warn("the new-functionality check's %s %s" % (what, "timed out" if timed_out else "exited %d" % code))
        return None
    return out


def nfc_facts(ctx):
    """The companion's view of the audited config. Its scripts always run from the RUNNING session's config,
    pointed at the audited one: a config under audit may come from elsewhere, and the audit never runs that
    config's own code. A script the audited config has but the running session lacks is listed as not run."""
    facts = {"status_line": None, "open_proposals": [], "inventory_present": False, "not_run": []}
    env = nfc_env(ctx)
    outputs = {}
    for what, relative in NFC_SCRIPTS:
        if not os.path.isfile(os.path.join(ctx.config, *relative)):
            continue
        script = os.path.join(ctx.runtime, *relative)
        if os.path.isfile(script):
            outputs[what] = run_companion([bash_bin(), script, what], env, what)
        else:
            facts["not_run"].append("the new-functionality check's %s: the running session's config has no copy of it, "
                                    "and the audited config's own copy is never run" % what)
    first = next((line.strip() for line in (outputs.get("--status") or "").splitlines() if line.strip()), None)
    if first:
        facts["status_line"] = clean_text(ctx, first)[:STATUS_LINE_CAP]
    facts["open_proposals"] = open_proposals(os.path.join(env[NFC_DIR_ENV], "ledger.md"))
    facts["inventory_present"] = bool((outputs.get("inventory") or "").strip())
    return facts


def timeout_tool():
    choice = os.environ.get("EXHAUSTIVE_AUDIT_TIMEOUT_TOOL", "")
    if choice == "none":
        return None
    for candidate in ([choice] if choice else ["timeout", "gtimeout"]):
        found = shutil.which(candidate)
        if found:
            return found
    return None


def run_check(command, root, timeout, tool):
    """(exit code, output) of one CHECK= command, run from the root with the user's umask. It is bounded
    by timeout/gtimeout when one exists, else by killing its process group (124 either way)."""
    script = "umask %03o; %s" % (original_umask(), command)
    env = child_env(cwd=root)
    try:
        if tool:
            code, out, _, timed_out = run_bounded([tool, "-k", str(KILL_GRACE_SECS), str(timeout), bash_bin(), "-c", script],
                                                  timeout + 2 * KILL_GRACE_SECS, cwd=root, env=env)
        else:
            code, out, _, timed_out = run_bounded([bash_bin(), "-c", script], timeout, cwd=root, env=env)
    except OSError as problem:
        return 127, "the check could not start: %s" % (problem.strerror or problem)
    return (EXIT_TIMED_OUT if timed_out else code), out


def house_checks(ctx):
    """Each CHECK= line's exit code and output tail, run from the root. Only the running session's own config
    gets its lines run: a config from elsewhere is code from elsewhere, so its lines are listed, never run."""
    if not is_runtime_config(ctx):
        if ctx.house["CHECK"]:
            warn("the audited config is not the running session's, so its %d CHECK= line(s) are listed and never run"
                 % len(ctx.house["CHECK"]))
        return [{"command_label": command_label(ctx, command), "ran": False, "exit_code": None, "tail": []}
                for command in ctx.house["CHECK"]]
    timeout = env_int("EXHAUSTIVE_AUDIT_CHECK_TIMEOUT_SECS", CHECK_TIMEOUT_SECS, 1)
    tool = timeout_tool()
    results = []
    for command in ctx.house["CHECK"]:
        code, out = run_check(command, ctx.root, timeout, tool)
        tail = [clean_text(ctx, line) for line in out.splitlines()[-CHECK_TAIL_LINES:]]
        results.append({"command_label": command_label(ctx, command), "ran": True, "exit_code": code, "tail": tail})
    return results


def strip_toml_comment(line):
    quote = None
    for index, char in enumerate(line):
        if quote:
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "#":
            return line[:index]
    return line


def requirement(value, path):
    match = REQUIREMENT_LINE.match(value.strip())
    if not match or "://" in value:
        return None
    return {"name": match.group(1), "spec": match.group(3).strip(), "file": path}


def parse_requirements(text, path):
    found = []
    for raw in text.splitlines():
        line = re.split(r"\s#", raw, maxsplit=1)[0].strip()
        if not line or line.startswith(("#", "-")):
            continue
        item = requirement(line, path)
        if item:
            found.append(item)
    return found


def parse_package_json(text, path):
    try:
        data = json.loads(text)
    except ValueError:
        warn("%s is not valid JSON; its dependencies are not listed" % path)
        return []
    found = []
    for section in ("dependencies", "devDependencies"):
        block = data.get(section) if isinstance(data, dict) else None
        if isinstance(block, dict):
            for name in sorted(block):
                found.append({"name": name, "spec": str(block[name]), "file": path})
    return found


def parse_pyproject(text, path):
    """[project].dependencies and the poetry dependency tables; a small reader, since tomllib is not in
    every supported python."""
    found, section = [], None
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        line = strip_toml_comment(lines[index]).strip()
        index += 1
        header = re.match(r"^\[([^\[\]]+)\]$", line)
        if header:
            section = header.group(1).strip()
            continue
        if section == "project" and re.match(r"^dependencies\s*=", line):
            array = line.split("=", 1)[1]
            while array.count("[") > array.count("]") and index < len(lines):
                array += "\n" + strip_toml_comment(lines[index])
                index += 1
            for double, single in re.findall(r"\"([^\"]*)\"|'([^']*)'", array):
                item = requirement(double or single, path)
                if item:
                    found.append(item)
        elif section and POETRY_SECTION.match(section):
            pair = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*=\s*(.+)$", line)
            if pair and pair.group(1).lower() != "python":
                value = pair.group(2).strip()
                quoted = re.match(r"^[\"']([^\"']*)[\"']$", value)
                version = re.search(r"version\s*=\s*[\"']([^\"']*)[\"']", value)
                spec = quoted.group(1) if quoted else (version.group(1) if version else value)
                found.append({"name": pair.group(1), "spec": spec, "file": path})
    return found


def dependency_facts(ctx, entries):
    found = []
    for entry in entries:
        path = entry["path"]
        if any(part in SKIP_DIRS for part in path.split("/")[:-1]) or not entry["text"]:
            continue
        leaf = os.path.basename(path)
        reader = parse_package_json if leaf == "package.json" else parse_pyproject if leaf == "pyproject.toml" else \
            parse_requirements if REQUIREMENTS_FILE.match(leaf) else None
        if reader:
            found.extend(reader(read_text(os.path.join(ctx.root, path)), path))
    return found


def marker_facts(folder):
    path = os.path.join(folder, "CLAUDE.md")
    markers = {}
    if not os.path.isfile(path):
        return markers
    for line in read_text(path).splitlines():
        match = re.match(r"^#\s*([a-z-]+):\s*(.*)$", line.strip())
        if match and match.group(1) in MARKER_NAMES:
            markers.setdefault(match.group(1), []).append(match.group(2).strip())
    return dict((name, "\n".join(values)) for name, values in markers.items())


def git_facts(ctx, base, git):
    """A module's git activity. A folder without git is repo false; a repository whose git fails is repo true
    with git's own error, so the failure never reads like a module that simply has no history."""
    facts = {"repo": git, "error": None, "last_commit_date": None, "commits_90d": None}
    if not git:
        return facts
    code, out, problem = run_git(ctx, base, ["log", "-1", "--format=%cI"])
    if code != 0:
        facts["error"] = problem
        return facts
    facts["last_commit_date"] = out.strip() or None
    code, out, problem = run_git(ctx, base, ["rev-list", "--count", "--since=90 days ago", "HEAD"])
    if code != 0:
        facts["error"] = problem
        return facts
    facts["commits_90d"] = parse_int(out) if out.strip() else None
    return facts


def sensitive(path):
    leaf = os.path.basename(path)
    return bool(SENSITIVE_NAME.match(leaf)) and not leaf.endswith(SENSITIVE_SAFE_SUFFIXES)


def module_facts(ctx, module, detail):
    entries = detail["entries"]
    paths = [entry["path"] for entry in entries]
    return {"name": module["name"], "git": git_facts(ctx, detail["base"], detail["git"]),
            "tracked_sensitive": sorted(path for path in paths if detail["git"] and sensitive(path)),
            "lockfiles": sorted(path for path in paths if os.path.basename(path) in LOCKFILES),
            "ci": sorted(path for path in paths if any(pattern.search(path) for pattern in CI_PATTERNS)),
            "markers": marker_facts(detail["base"]),
            "tests_present": any(TEST_FILE.match(os.path.basename(path)) or
                                 any(part in TEST_DIR_NAMES for part in path.split("/")[:-1]) for path in paths),
            "dependencies": dependency_facts(ctx, entries)}


def cmd_config_facts(argv):
    options, _ = parse_args(argv, {"--root": "value", "--exclude": "multi", "--checks": "bool"}, 0,
                            "config-facts [--root DIR] [--exclude NAME]... [--checks]")
    ctx = Ctx(options.get("--config-dir"))
    ctx.set_root(options.get("--root"))
    document, details = discover(ctx, options.get("--exclude", []))
    warnings = []
    settings = load_settings(ctx.config, warnings)   # the claude-system facts describe the AUDITED config
    for message in warnings:
        warn(message)
    facts = {"root_name": document["root_name"], "config_dir": "<config>",
             "modules": [module_facts(ctx, module, details[module["name"]]) for module in document["modules"]],
             "config": {"settings": settings_facts(settings), "agents": agent_facts(ctx), "skills": skill_facts(ctx),
                        "hooks_dir": hook_facts(ctx), "claude_md": claude_md_facts(ctx),
                        "new_functionality_check": nfc_facts(ctx),
                        "checks": house_checks(ctx) if options.get("--checks") else None,
                        "config_tests": [command_label(ctx, command) for command in ctx.house["CONFIG_TEST"]]}}
    emit_json(clean_obj(ctx, facts))
    return EXIT_OK


# ----------------------------------------------------------------- plan
def risk_score(module_relative_path):
    lowered = module_relative_path.lower()
    return sum(1 for word in RISK_WORDS if word in lowered)


def module_relative(module, path):
    return path if module["path"] == "." else path[len(module["path"]) + 1:]


def recency(ctx, module, detail):
    """root-relative path -> the time it last changed: its newest commit in a git module, its mtime otherwise."""
    times = {}
    if detail["git"]:
        code, out, _ = run_git(ctx, detail["base"], ["log", "--format=@%ct", "--name-only", "-n", str(GIT_RECENCY_COMMITS)])
        when = 0
        for line in out.splitlines() if code == 0 else []:
            if line.startswith("@"):
                when = parse_int(line[1:]) or 0
            elif line.strip():
                times.setdefault(join_rel(module["path"], line.strip()), when)
        return times
    for entry in detail["code"]:
        try:
            times[entry["path"]] = int(os.path.getmtime(os.path.join(detail["base"], module_relative(module, entry["path"]))))
        except OSError:
            times[entry["path"]] = 0
    return times


def chunk_exhaustive(files, budget):
    chunks, current, size = [], [], 0
    for entry in files:
        if current and size + entry["lines"] > budget:
            chunks.append(current)
            current, size = [], 0
        current.append(entry)
        size += entry["lines"]
    if current:
        chunks.append(current)
    return chunks


def chunk_sampled(module, files, budget, times):
    ranked = sorted(files, key=lambda entry: (-risk_score(module_relative(module, entry["path"])),
                                               -times.get(entry["path"], 0), entry["path"]))
    chosen, size = [], 0
    for entry in ranked:
        if size + entry["lines"] <= budget:
            chosen.append(entry)
            size += entry["lines"]
        elif not chosen:
            chosen.append(entry)   # one file larger than the budget is its own scope
            break
    return [sorted(chosen, key=lambda entry: entry["path"])] if chosen else []


def code_scopes(ctx, module, detail, coverage, budget):
    files = sorted(detail["code"], key=lambda entry: entry["path"])
    if coverage == "sampled":
        chunks = chunk_sampled(module, files, budget, recency(ctx, module, detail))
    else:
        chunks = chunk_exhaustive(files, budget)
    return [{"id": "CR-%d-%02d" % (module["idx"], number), "kind": "code", "dim": 1, "agent": CODE_AGENT,
             "module": module["name"], "paths": [entry["path"] for entry in chunk],
             "lines": sum(entry["lines"] for entry in chunk), "children": CODE_REVIEW_CHILDREN}
            for number, chunk in enumerate(chunks, 1)]


def scope_records(ctx, scope, chosen, details, coverage, budget):
    records = []
    if scope in ("all", "workspace", "module"):
        restrict = chosen[0]["name"] if scope == "module" else None
        for dim, ident, agent in DIMENSION_SCOPES:
            if dim != 5:
                records.append({"id": ident, "kind": "dimension", "dim": dim, "agent": agent, "module": restrict})
    if scope in ("all", "claude-system"):
        dim, ident, agent = DIMENSION_SCOPES[-1]
        records.append({"id": ident, "kind": "dimension", "dim": dim, "agent": agent, "module": None})
    if scope in ("all", "workspace", "module"):
        for module in chosen:
            records.append({"id": "PH-%d" % module["idx"], "kind": "health", "dim": 2, "agent": HEALTH_AGENT, "module": module["name"]})
    if scope in ("all", "module"):
        for module in chosen:
            records.extend(code_scopes(ctx, module, details[module["name"]], coverage, budget))
    return records


def scope_cost(record):
    return 1 + record.get("children", 0) if record["kind"] == "code" else 1


def pack_waves(records, per_wave):
    """Dimension and health scopes first, then code; a wave's agents (nested ones included) never exceed per_wave."""
    ordered = [record for record in records if record["kind"] != "code"] + [record for record in records if record["kind"] == "code"]
    waves, current, load = [], [], 0
    for record in ordered:
        cost = scope_cost(record)
        if current and load + cost > per_wave:
            waves.append(current)
            current, load = [], 0
        current.append(record["id"])
        load += cost
    if current:
        waves.append(current)
    return waves


def millions(count):
    return "%.1fM" % (count / 1000000.0)


def estimate(records, waves):
    """Agents, processed tokens (cache reads included) and minutes for a plan, per kind and in total."""
    by_kind = {"code": {"agents": 0, "processed_tokens": 0}, "dimension": {"agents": 0, "processed_tokens": 0},
               "health": {"agents": 0, "processed_tokens": 0}, "research": {"agents": 1, "processed_tokens": TOKENS_RESEARCHER}}
    for record in records:
        if record["kind"] == "code":
            agents = 1 + record["children"]
            tokens = TOKENS_CODE_REVIEWER + record["children"] * TOKENS_CODE_SPECIALIST
        else:
            agents, tokens = 1, TOKENS_DIMENSION if record["kind"] == "dimension" else TOKENS_HEALTH
        by_kind[record["kind"]]["agents"] += agents
        by_kind[record["kind"]]["processed_tokens"] += tokens
    kinds = dict((record["id"], record["kind"]) for record in records)
    minutes = sum(MINUTES_CODE_WAVE if any(kinds[ident] == "code" for ident in wave) else MINUTES_OTHER_WAVE for wave in waves)
    minutes += MINUTES_RESEARCH
    return {"agents": sum(item["agents"] for item in by_kind.values()),
            "processed_tokens": sum(item["processed_tokens"] for item in by_kind.values()), "minutes": minutes,
            "by_kind": by_kind, "basis": ESTIMATE_BASIS}


def unseen_in_scope(items, path_of, scope, chosen):
    """The paths discovery could not see that a plan covers: every one for the whole workspace, a module's
    own for one module, none for the claude-system scope (it reviews the config, not the tree)."""
    if scope == "claude-system":
        return []
    if scope != "module":
        return list(items)
    prefixes = [module["path"] for module in chosen]
    return [item for item in items
            if any(prefix == "." or path_of(item) == prefix or path_of(item).startswith(prefix + "/") for prefix in prefixes)]


def build_plan(ctx, scope, module_name, coverage, budget, extra_excludes):
    document, details = discover(ctx, extra_excludes)
    modules = document["modules"]
    if scope == "module":
        chosen = [module for module in modules if module["name"] == module_name]
        if not chosen:
            die(EXIT_USAGE, "no module named %s under this root (discover lists: %s)" % (module_name, ", ".join(m["name"] for m in modules) or "none"))
    else:
        chosen = [] if scope == "claude-system" else modules
    warnings = []
    limit = limits(ctx, warnings)
    for message in warnings:
        warn(message)
    cap = limit["max_concurrent"]
    per_wave = cap - CONCURRENCY_HEADROOM

    def variant(which):
        records = scope_records(ctx, scope, chosen, details, which, budget)
        heaviest = max([scope_cost(record) for record in records] or [0])
        if heaviest > per_wave:
            die(EXIT_BLOCKED, "BLOCKED: the concurrency cap of %d leaves %d agents per wave, fewer than the %d one scope "
                              "needs; raise CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS to %d or more" % (cap, per_wave, heaviest, heaviest + CONCURRENCY_HEADROOM))
        waves = pack_waves(records, per_wave)
        return records, waves, estimate(records, waves)

    records, waves, cost = variant(coverage)
    other = "sampled" if coverage == "exhaustive" else "exhaustive"
    _, _, other_cost = variant(other)
    covered = [{"idx": m["idx"], "name": m["name"], "path": m["path"], "git": m["git"], "files": m["files"],
                "lines": m["lines"], "tier": m["tier"], "code_lines": sum(e["lines"] for e in details[m["name"]]["code"])}
               for m in chosen]
    plan = {"root_name": document["root_name"], "config_dir": "<config>",
            "scope": "module %s" % module_name if scope == "module" else scope, "coverage": coverage,
            "scopes": records, "waves": waves, "estimate": cost,
            "alternatives": {other: dict((key, other_cost[key]) for key in ("agents", "processed_tokens", "minutes"))},
            "limits": {"cap": cap, "per_wave": per_wave}, "modules": covered,
            "unreadable": unseen_in_scope(document["unreadable"], lambda item: item["path"], scope, chosen),
            "placeholders": unseen_in_scope(document["placeholders"], lambda path: path, scope, chosen)}
    return clean_obj(ctx, plan)


def cmd_plan(argv):
    usage = "plan [--root DIR] [--scope all|workspace|claude-system|module NAME] [--coverage exhaustive|sampled] [--loc-budget N] [--exclude NAME]..."
    options, _ = parse_args(argv, {"--root": "value", "--scope": "scope", "--coverage": "value", "--loc-budget": "value",
                                   "--exclude": "multi"}, 0, usage)
    ctx = Ctx(options.get("--config-dir"))
    ctx.set_root(options.get("--root"))
    scope = options.get("--scope", "all")
    if scope not in SCOPE_CHOICES:
        die(EXIT_USAGE, "--scope must be one of %s (usage: %s)" % (", ".join(SCOPE_CHOICES), usage))
    coverage = options.get("--coverage", "exhaustive")
    if coverage not in COVERAGE_CHOICES:
        die(EXIT_USAGE, "--coverage must be exhaustive or sampled (usage: %s)" % usage)
    budget = ctx.house["MAX_LOC_PER_REVIEW"]
    if "--loc-budget" in options:
        budget = parse_int(options["--loc-budget"])
        if budget is None or budget < 1:
            die(EXIT_USAGE, "--loc-budget must be a whole number of lines >= 1")
    emit_json(build_plan(ctx, scope, options.get("--scope name"), coverage, budget, options.get("--exclude", [])))
    return EXIT_OK


# ----------------------------------------------------------------- runs
def run_key(run_id):
    match = RUN_ID_RE.match(run_id)
    return (match.group(1), int(match.group(2) or 1))


def runs_dir(ctx):
    return os.path.join(ctx.data, "runs")


def all_runs(ctx):
    folder = runs_dir(ctx)
    found = [name for name in safe_listdir(folder) if RUN_ID_RE.match(name) and os.path.isfile(os.path.join(folder, name, "plan.json"))]
    return sorted(found, key=run_key)


def finalized_runs(ctx):
    return [name for name in all_runs(ctx) if os.path.isfile(os.path.join(runs_dir(ctx), name, "findings.json"))]


def ensure_private_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path, 0o700)
        os.chmod(path, 0o700)
    return path


def check_plan(plan):
    if not isinstance(plan, dict) or not isinstance(plan.get("root_name"), str):
        return "it is not a plan (no root_name)"
    scopes = plan.get("scopes")
    if not isinstance(scopes, list) or not all(isinstance(s, dict) and SCOPE_ID_RE.match(str(s.get("id", ""))) and s.get("agent") for s in scopes):
        return "its scopes are missing or malformed"
    ids = [scope["id"] for scope in scopes]
    waves = plan.get("waves")
    if not isinstance(waves, list) or not all(isinstance(wave, list) for wave in waves):
        return "its waves are missing or malformed"
    if sorted(ident for wave in waves for ident in wave) != sorted(ids) or len(set(ids)) != len(ids):
        return "its waves do not hold every scope exactly once"
    unreadable = plan.get("unreadable", [])
    if not isinstance(unreadable, list) or not all(isinstance(item, dict) and isinstance(item.get("path"), str)
                                                   and isinstance(item.get("reason"), str) for item in unreadable):
        return "its unreadable list is malformed"
    placeholders = plan.get("placeholders", [])
    if not isinstance(placeholders, list) or not all(isinstance(path, str) for path in placeholders):
        return "its placeholders list is malformed"
    return None


class Run(object):
    """One run folder: its plan (with the recorded root), results/ and the per-scope state files."""

    def __init__(self, ctx, run_id):
        if not RUN_ID_RE.match(run_id or ""):
            die(EXIT_USAGE, "not a run id: %s (run ids look like 20261010T120000Z)" % one_line(run_id)[:80])
        self.ctx, self.id = ctx, run_id
        self.dir = os.path.join(runs_dir(ctx), run_id)
        plan_path = os.path.join(self.dir, "plan.json")
        if not os.path.isfile(plan_path):
            die(EXIT_USAGE, "no run %s in %s (give every run command the --config-dir that init-run had)" % (run_id, display_path(ctx, runs_dir(ctx))))
        try:
            self.plan = read_json(plan_path)
        except ValueError:
            die(EXIT_USAGE, "the plan of run %s is not valid JSON" % run_id)
        self.results = os.path.join(self.dir, "results")
        self.order = [scope["id"] for scope in self.plan.get("scopes", [])]
        self.scopes = dict((scope["id"], scope) for scope in self.plan.get("scopes", []))
        if self.plan.get("root"):
            ctx.root = self.plan["root"]
        if self.plan.get("config_path"):
            ctx.extra_bases.append((self.plan["config_path"], "<config>"))

    def modules(self):
        return self.plan.get("modules") or []

    def module_path(self, name):
        for module in self.modules():
            if module.get("name") == name:
                return module.get("path") or name
        return name

    def result_path(self, scope):
        return os.path.join(self.results, scope + ".json")

    def raw_path(self, scope):
        return os.path.join(self.results, scope + ".raw.txt")

    def state_path(self, scope):
        return os.path.join(self.results, scope + ".state")

    def load_state(self, scope):
        state = {"attempts": 0, "invalid_attempts": [], "state": "pending"}
        path = self.state_path(scope)
        if os.path.isfile(path):
            try:
                stored = read_json(path)
                if isinstance(stored, dict):
                    state.update(stored)
            except ValueError:
                warn("the state of %s could not be read; it counts as not yet saved" % scope)
        return state

    def save_state(self, scope, state):
        write_json(self.state_path(scope), state)

    def require_scope(self, scope, allow_research=False):
        if not SCOPE_ID_RE.match(scope or ""):
            die(EXIT_USAGE, "not a scope id: %s" % one_line(scope)[:80])
        if scope in self.scopes or (allow_research and scope == RESEARCH_SCOPE):
            return
        die(EXIT_USAGE, "scope %s is not in run %s's plan" % (scope, self.id))


def status_of(state):
    return state.get("state") if state.get("state") in ("valid", "failed") else "missing"


def record_invalid(state, attempt, reason):
    if attempt not in state["invalid_attempts"]:
        state["invalid_attempts"].append(attempt)
    state["state"] = "failed" if len(state["invalid_attempts"]) >= MAX_INVALID_ATTEMPTS else "invalid"
    state["reason"] = reason


def cmd_init_run(argv):
    options, _ = parse_args(argv, {"--plan": "value", "--root": "value"}, 0, "init-run --plan FILE [--root DIR]")
    ctx = Ctx(options.get("--config-dir"))
    if not options.get("--plan"):
        die(EXIT_USAGE, "init-run needs --plan FILE")
    source = resolve_arg_path(ctx, options["--plan"])
    if not os.path.isfile(source):
        die(EXIT_USAGE, "the plan file does not exist: %s" % options["--plan"])
    try:
        plan = read_json(source)
    except ValueError:
        die(EXIT_USAGE, "the plan file is not JSON (redirect the output of plan into it; never retype it)")
    problem = check_plan(plan)
    if problem:
        die(EXIT_USAGE, "the plan file is not usable: %s" % problem)
    ctx.set_root(options.get("--root"))
    if os.path.basename(ctx.root) != plan["root_name"]:
        die(EXIT_USAGE, "this plan was made for a root named %s, not %s; pass that root with --root" % (plan["root_name"], os.path.basename(ctx.root)))
    ensure_private_dir(ctx.data)
    folder = ensure_private_dir(runs_dir(ctx))
    epoch = now_epoch()
    base = stamp(epoch)
    for attempt in range(1, MAX_RUN_SUFFIX + 1):
        run_id = base if attempt == 1 else "%s-%d" % (base, attempt)
        try:
            os.mkdir(os.path.join(folder, run_id), 0o700)
            break
        except FileExistsError:
            continue
    else:
        die(EXIT_PROBLEM, "run ids %s up to -%d are all taken" % (base, MAX_RUN_SUFFIX))
    run_dir = os.path.join(folder, run_id)
    os.chmod(run_dir, 0o700)
    os.mkdir(os.path.join(run_dir, "results"), 0o700)
    record = dict(plan)
    record.update({"run": run_id, "created_at": iso(epoch), "root": ctx.root, "config_path": ctx.config})
    write_json(os.path.join(run_dir, "plan.json"), record)
    print(run_id)
    print(display_path(ctx, run_dir))
    return EXIT_OK


# ----------------------------------------------------------------- transcripts and replies
def read_transcript(path):
    entries = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                entries.append(entry)
    return entries


def message_of(entry):
    message = entry.get("message")
    return message if isinstance(message, dict) else {}


def first_user_text(entries):
    """The dispatch prompt: the first user message that is more than a system reminder."""
    for entry in entries:
        if entry.get("type") != "user":
            continue
        content = message_of(entry).get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            if any(isinstance(part, dict) and part.get("type") == "tool_result" for part in content):
                continue
            text = "\n".join(part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text")
        else:
            continue
        if re.sub(r"(?s)<system-reminder>.*?</system-reminder>", "", text).strip():
            return text
    return ""


def has_exact_line(text, wanted):
    return any(line.strip() == wanted for line in text.splitlines())


def reply_from_entries(entries):
    """Adapted from claude_code_new_functionality_check.sh save-result: the last non-blank hand-back
    message wins; without one, every assistant text block after the last tool result, joined (a reply
    split by the output-token limit continues after a plain-string continuation prompt)."""
    pieces, handback = [], None
    for entry in entries:
        content = message_of(entry).get("content")
        if entry.get("type") == "user":
            if isinstance(content, str):
                if not content.startswith(CONTINUATION_PREFIX):
                    pieces = []
            elif isinstance(content, list) and any(isinstance(part, dict) and part.get("type") == "tool_result" for part in content):
                pieces = []
        elif entry.get("type") == "assistant" and isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "tool_use" and part.get("name") == HANDBACK_TOOL:
                    message = (part.get("input") or {}).get("message")
                    if isinstance(message, str) and message.strip():
                        handback = message
            text = "".join(part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text")
            if text:
                pieces.append(text)
    if handback is not None:
        return handback, 1
    return "".join(pieces), len(pieces)


def usage_totals(entries):
    """Token usage of the agent's messages; streaming repeats a message id, which counts once."""
    by_id, anonymous = {}, []
    for entry in entries:
        message = message_of(entry)
        usage = message.get("usage")
        if entry.get("type") != "assistant" or not isinstance(usage, dict):
            continue
        if message.get("id"):
            by_id[message["id"]] = usage
        else:
            anonymous.append(usage)
    totals = dict((key, 0) for key in USAGE_KEYS)
    for usage in list(by_id.values()) + anonymous:
        for key in USAGE_KEYS:
            value = usage.get(key)
            if isinstance(value, int) and not isinstance(value, bool):
                totals[key] += value
    totals["messages"] = len(by_id) + len(anonymous)
    return totals


def transcript_meta(path):
    meta_path = re.sub(r"\.jsonl$", "", path) + ".meta.json"
    if not os.path.isfile(meta_path):
        return None
    try:
        meta = read_json(meta_path)
    except ValueError:
        return None
    if not isinstance(meta, dict):
        return None
    return dict((key, meta[key]) for key in ("agentType", "spawnDepth", "model") if key in meta)


def extract_result(text):
    """(the reply's result object or None, the prose lines before it). Code fences are dropped; the
    first top-level object that has a header wins, else the first object at all."""
    stripped = re.sub(r"(?m)^\s*```[A-Za-z0-9_-]*\s*$", "", text)
    decoder = json.JSONDecoder()
    objects, index = [], stripped.find("{")
    while index >= 0:
        try:
            value, end = decoder.raw_decode(stripped, index)
        except ValueError:
            index = stripped.find("{", index + 1)
            continue
        if isinstance(value, dict):
            objects.append((index, value))
            index = stripped.find("{", end)
        else:
            index = stripped.find("{", index + 1)
    if not objects:
        return None, []
    start, chosen = next(((at, value) for at, value in objects if "header" in value), objects[0])
    notes = [line.strip() for line in stripped[:start].splitlines() if line.strip()]
    return chosen, notes


def dispatch_failed(text):
    # Any line will do, so a one-line preface cannot hide it; a JSON line can never start with it.
    return any(line.strip().startswith(DISPATCH_FAILED) for line in text.splitlines())


def cmd_save_result(argv):
    usage = "save-result RUN SCOPE OUTPUT-FILE|-"
    options, positional = parse_args(argv, {}, 3, usage)
    if len(positional) != 3:
        die(EXIT_USAGE, "save-result needs RUN SCOPE OUTPUT-FILE|- (usage: %s)" % usage)
    run_id, scope, source = positional
    ctx = Ctx(options.get("--config-dir"))
    run = Run(ctx, run_id)
    run.require_scope(scope, allow_research=True)
    usage_record, meta = None, None
    if source == "-":
        text, pieces, origin = html.unescape(sys.stdin.read()), 1, "stdin"
    else:
        path = resolve_arg_path(ctx, source)
        if not os.path.isfile(path):
            die(EXIT_USAGE, "the output file does not exist: %s" % display_path(ctx, path))
        entries = read_transcript(path)
        wanted = "%s %s %s" % (AUDIT_RUN_PREFIX, run.id, scope)
        if not has_exact_line(first_user_text(entries), wanted):
            print("REFUSED: the transcript's first user message does not carry the exact line '%s'; it belongs to "
                  "another scope or run, so nothing was saved" % wanted)
            return EXIT_PROBLEM
        text, pieces = reply_from_entries(entries)
        origin, usage_record, meta = "transcript", usage_totals(entries), transcript_meta(path)
    state = run.load_state(scope)
    attempt = state["attempts"] + 1
    state.update({"attempts": attempt, "source": origin, "saved_at": iso(now_epoch())})
    if usage_record:
        state["usage"] = usage_record
    if meta:
        state["meta"] = meta
    write_text(run.raw_path(scope), mask_secrets(text)[0])
    document, notes = (None, []) if dispatch_failed(text) else extract_result(text)
    if document is None:
        reason = "the reply is DISPATCH FAILED" if dispatch_failed(text) else "the reply holds no JSON object (%d characters)" % len(text)
        record_invalid(state, attempt, reason)
        if os.path.exists(run.result_path(scope)):
            os.remove(run.result_path(scope))
        run.save_state(scope, state)
        print("INVALID: %s; attempt %d recorded, the scope is now %s" % (reason, attempt, state["state"]))
        return EXIT_PROBLEM
    document, masked = mask_document(document)
    write_json(run.result_path(scope), document)
    state["state"] = "saved"
    run.save_state(scope, state)
    kind = "leads" if scope == RESEARCH_SCOPE else "findings"
    items = document.get(kind)
    print("saved %s (%s %s; reply in %d piece(s); attempt %d%s)" % (
        display_path(ctx, run.result_path(scope)), len(items) if isinstance(items, list) else "no", kind, pieces, attempt,
        "; masked %d secret-shaped value(s)" % masked if masked else ""))
    for line in notes[:MAX_NOTE_LINES]:
        print("note before the JSON: %s" % one_line(clean_text(ctx, line))[:CAPS["not_reviewed"]])
    return EXIT_OK


# ----------------------------------------------------------------- validate
def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def expect_keys(where, obj, required, optional, errors):
    for key in obj:
        if key not in required and key not in optional:
            errors.append("%s: unknown field '%s'" % (where, key))
    for key in required:
        if key not in obj:
            errors.append("%s: missing field '%s'" % (where, key))


def check_text(where, key, value, cap, errors, overlong, required=True, multiline=False):
    if not isinstance(value, str):
        errors.append("%s: %s must be a string" % (where, key))
        return
    if required and not value.strip():
        errors.append("%s: %s must not be empty" % (where, key))
    if CONTROL_RE.search(value):
        errors.append("%s: %s contains a control character" % (where, key))
    if not multiline and LINE_BREAK_RE.search(value):
        errors.append("%s: %s must be one line" % (where, key))
    if len(value) > cap * OVERLONG_FACTOR:
        errors.append("%s: %s is %d characters, more than twice its cap of %d" % (where, key, len(value), cap))
    elif len(value) > cap:
        overlong.append("%s: %s is %d characters (cap %d)" % (where, key, len(value), cap))


def path_problem(path):
    if path.startswith(("/", "\\")):
        return "must be relative to the root (no leading /)"
    if path.startswith("~"):
        return "must not start with ~"
    if re.match(r"^[A-Za-z]:", path):
        return "must not be a drive path"
    if ".." in re.split(r"[/\\]", path):
        return "must not contain .."
    if path.startswith("<") and not (path == "<config>" or path.startswith("<config>/")):
        return "may use only the <config>/ placeholder"
    return None


def check_header(header, run_id, scope_id, errors, overlong):
    expect_keys("header", header, HEADER_REQUIRED, HEADER_OPTIONAL, errors)
    for key, wanted in (("run", run_id), ("scope", scope_id)):
        if key in header and header[key] != wanted:
            errors.append("header: %s must be %s, the %s being validated" % (key, wanted, key))
    if "agent" in header:
        check_text("header", "agent", header["agent"], CAPS["header_text"], errors, overlong)
    for key in ("files_reviewed", "lines_reviewed"):
        if key in header and not (is_int(header[key]) and header[key] >= 0):
            errors.append("header: %s must be a whole number >= 0" % key)
    if "notes" in header:
        check_text("header", "notes", header["notes"], CAPS["notes"], errors, overlong, required=False, multiline=True)
    if "not_reviewed" in header:
        items = header["not_reviewed"]
        if not isinstance(items, list) or len(items) > NOT_REVIEWED_MAX:
            errors.append("header: not_reviewed must be a list of at most %d strings" % NOT_REVIEWED_MAX)
        else:
            for item in items:
                check_text("header", "not_reviewed item", item, CAPS["not_reviewed"], errors, overlong)


def check_evidence(where, evidence, errors, overlong):
    low, high = EVIDENCE_RANGE
    if not isinstance(evidence, list) or not low <= len(evidence) <= high:
        errors.append("%s: evidence must be a list of %d to %d items" % (where, low, high))
        return
    for number, item in enumerate(evidence, 1):
        spot = "%s evidence %d" % (where, number)
        if not isinstance(item, dict):
            errors.append("%s: must be an object {path, line}" % spot)
            continue
        expect_keys(spot, item, ("path", "line"), (), errors)
        if "path" in item:
            check_text(spot, "path", item["path"], CAPS["path"], errors, overlong)
            problem = path_problem(item["path"]) if isinstance(item["path"], str) else None
            if problem:
                errors.append("%s: path %s" % (spot, problem))
        if "line" in item and not (is_int(item["line"]) and item["line"] >= 0):
            errors.append("%s: line must be a whole number >= 0" % spot)


def check_finding(where, finding, modules, errors, overlong):
    if not isinstance(finding, dict):
        errors.append("%s: must be an object" % where)
        return
    expect_keys(where, finding, FINDING_REQUIRED, FINDING_OPTIONAL, errors)
    low, high = DIM_RANGE
    if "dim" in finding and not (is_int(finding["dim"]) and low <= finding["dim"] <= high):
        errors.append("%s: dim must be a whole number %d-%d" % (where, low, high))
    if "module" in finding and finding["module"] is not None and finding["module"] not in modules:
        errors.append("%s: module must be one of this run's modules (%s) or null" % (where, ", ".join(modules) or "none"))
    if "check" in finding:
        check_text(where, "check", finding["check"], CAPS["check"], errors, overlong)
        if isinstance(finding["check"], str) and not re.match(CHECK_PATTERN, finding["check"]):
            errors.append("%s: check must match %s" % (where, CHECK_PATTERN))
    for key in ("subject", "category", "finding", "rationale", "recommendation"):
        if key in finding:
            check_text(where, key, finding[key], CAPS[key], errors, overlong, multiline=key in MULTILINE_FIELDS)
    for key, allowed in (("severity", SEVERITIES), ("effort", EFFORTS), ("risk", RISKS)):
        if key in finding and not (isinstance(finding[key], str) and finding[key] in allowed):
            errors.append("%s: %s must be one of %s" % (where, key, "|".join(allowed)))
    if "evidence" in finding:
        check_evidence(where, finding["evidence"], errors, overlong)
    if "research_questions" in finding:
        questions = finding["research_questions"]
        if not isinstance(questions, list) or len(questions) > QUESTIONS_MAX:
            errors.append("%s: research_questions must be a list of at most %d" % (where, QUESTIONS_MAX))
        else:
            for question in questions:
                check_text(where, "research question", question, CAPS["question"], errors, overlong)


def check_result(document, run_id, scope_id, scope_kind, modules):
    """(errors, overlong notes, finding count) of one agent result against the finding schema."""
    errors, overlong = [], []
    if not isinstance(document, dict):
        return ["the result must be a JSON object"], overlong, 0
    expect_keys("result", document, ("header", "findings"), (), errors)
    header = document.get("header")
    if isinstance(header, dict):
        check_header(header, run_id, scope_id, errors, overlong)
    elif "header" in document:
        errors.append("header must be an object")
    findings = document.get("findings")
    if not isinstance(findings, list):
        if "findings" in document:
            errors.append("findings must be a list")
        return errors, overlong, 0
    limit = FINDINGS_MAX["code" if scope_kind == "code" else "other"]
    if len(findings) > limit:
        errors.append("%d findings, more than the %d a %s scope may return" % (len(findings), limit, scope_kind))
    for number, finding in enumerate(findings, 1):
        check_finding("finding %d" % number, finding, modules, errors, overlong)
    return errors, overlong, len(findings)


def run_modules(run):
    names = [module["name"] for module in run.modules() if module.get("name")]
    for scope in run.plan.get("scopes", []):
        if scope.get("module") and scope["module"] not in names:
            names.append(scope["module"])
    return names


def validate_scope(run, scope):
    """Validates results/<scope>.json, masks secrets in place and records the verdict in the scope's
    state. Returns (exit code, verdict line, masked count)."""
    state = run.load_state(scope)
    path = run.result_path(scope)
    try:
        document = json.loads(read_text(path))
    except ValueError as problem:
        masked_text, masked = mask_secrets(read_text(path))
        if masked:
            write_text(path, masked_text)
        errors, overlong, count = ["the result is not JSON (%s)" % problem], [], 0
    else:
        document, masked = mask_document(document)
        if masked:
            write_json(path, document)
        errors, overlong, count = check_result(document, run.id, scope, run.scopes[scope].get("kind"), run_modules(run))
    if errors:
        shown = "; ".join(errors[:MAX_REASONS_SHOWN])
        if len(errors) > MAX_REASONS_SHOWN:
            shown += " (and %d more)" % (len(errors) - MAX_REASONS_SHOWN)
        record_invalid(state, state["attempts"], "INVALID: " + "; ".join(errors[:3]))
        line, code = "INVALID: " + shown, EXIT_PROBLEM
    else:
        state["state"], state["reason"] = "valid", None
        line, code = ("VALID-OVERLONG %d findings: %s" % (count, "; ".join(overlong[:MAX_REASONS_SHOWN]))) if overlong else "VALID %d findings" % count, EXIT_OK
    state["validated_at"] = iso(now_epoch())
    run.save_state(scope, state)
    return code, line, masked


def cmd_validate(argv):
    options, positional = parse_args(argv, {}, 2, "validate RUN SCOPE")
    if len(positional) != 2:
        die(EXIT_USAGE, "validate needs RUN SCOPE")
    ctx = Ctx(options.get("--config-dir"))
    run = Run(ctx, positional[0])
    scope = positional[1]
    if scope == RESEARCH_SCOPE:
        die(EXIT_USAGE, "the research reply is checked by attach-research, not validate")
    run.require_scope(scope)
    if not os.path.isfile(run.result_path(scope)):
        state = run.load_state(scope)
        if os.path.isfile(run.raw_path(scope)) and state.get("state") in ("invalid", "failed"):
            print("INVALID: %s (the scope is %s)" % (state.get("reason") or "no JSON object in the reply", state["state"]))
            return EXIT_PROBLEM
        die(EXIT_USAGE, "no saved result for %s in run %s: run save-result first" % (scope, run.id))
    code, line, masked = validate_scope(run, scope)
    print(clean_text(ctx, line))
    if masked:
        print("masked %d secret-shaped value(s) in place" % masked)
    return code


# ----------------------------------------------------------------- next-wave and status
def scope_states(run, validate_saved=False):
    states = {}
    for scope in run.order:
        state = run.load_state(scope)
        if validate_saved and state.get("state") == "saved" and os.path.isfile(run.result_path(scope)):
            _, line, _ = validate_scope(run, scope)
            info("validated the saved result of %s: %s" % (scope, clean_text(run.ctx, line)[:200]))
            state = run.load_state(scope)
        states[scope] = state
    return states


def next_wave_number(run, states):
    for number, wave in enumerate(run.plan.get("waves", []), 1):
        if any(states[scope]["state"] not in ("valid", "failed") for scope in wave):
            return number
    return None


def dispatch_paths(run, scope):
    if scope["kind"] == "code":
        return list(scope.get("paths") or [])
    if scope["kind"] == "health" or scope.get("module"):
        return [run.module_path(scope["module"])]
    return ["<config>"] if scope.get("dim") == 5 else ["."]


def cmd_next_wave(argv):
    options, positional = parse_args(argv, {}, 1, "next-wave RUN")
    if len(positional) != 1:
        die(EXIT_USAGE, "next-wave needs RUN")
    run = Run(Ctx(options.get("--config-dir")), positional[0])
    states = scope_states(run, validate_saved=True)
    number = next_wave_number(run, states)
    if number is None:
        emit_json({"run": run.id, "wave": None, "dispatches": [], "done": True})
        return EXIT_OK
    dispatches = []
    for scope_id in run.plan["waves"][number - 1]:
        state = states[scope_id]
        if state["state"] in ("valid", "failed"):
            continue
        scope = run.scopes[scope_id]
        dispatches.append({"scope_id": scope_id, "agent": scope["agent"], "dim": scope.get("dim"), "module": scope.get("module"),
                           "paths": dispatch_paths(run, scope), "header": "%s %s %s" % (AUDIT_RUN_PREFIX, run.id, scope_id),
                           "attempt": state["attempts"] + 1})
    emit_json(clean_obj(run.ctx, {"run": run.id, "wave": number, "dispatches": dispatches, "done": False}))
    return EXIT_OK


def run_summary(ctx, run_id):
    run = Run(ctx, run_id)
    states = scope_states(run)
    scopes = dict((scope, status_of(states[scope])) for scope in run.order)
    banner = None
    findings_path = os.path.join(run.dir, "findings.json")
    if os.path.isfile(findings_path):
        try:
            banner = read_json(findings_path).get("banner")
        except ValueError:
            warn("findings.json of run %s is not valid JSON" % run_id)
    counts = dict((name, sum(1 for value in scopes.values() if value == name)) for name in ("valid", "failed", "missing"))
    return run, scopes, counts, banner, states


def cmd_status(argv):
    options, positional = parse_args(argv, {}, 1, "status [RUN]")
    ctx = Ctx(options.get("--config-dir"))
    if positional:
        run_id = positional[0]
    else:
        runs = all_runs(ctx)
        if not runs:
            die(EXIT_USAGE, "no run exists yet in %s" % display_path(ctx, runs_dir(ctx)))
        run_id = runs[-1]
    run, scopes, counts, banner, states = run_summary(ctx, run_id)
    document = {"run": run.id, "scopes": scopes, "banner": banner, "finalized": banner is not None,
                "next_wave": next_wave_number(run, states)}
    document.update(counts)
    emit_json(document)
    return EXIT_OK


def cmd_runs(argv):
    options, _ = parse_args(argv, {}, 0, "runs")
    ctx = Ctx(options.get("--config-dir"))
    listed = []
    for run_id in all_runs(ctx):
        _, _, counts, banner, _ = run_summary(ctx, run_id)
        entry = {"run": run_id, "banner": banner}
        entry.update(counts)
        listed.append(entry)
    emit_json({"runs": listed})
    return EXIT_OK


# ----------------------------------------------------------------- fingerprints and IDs
def truncate(value, cap):
    return value if len(value) <= cap else value[:cap - 1] + ELLIPSIS


def normalize_finding(ctx, finding):
    """The finding as finalize keeps it: an overlong field is cut to its cap with an ellipsis. Each field is
    made relative and masked BEFORE the cut, so a cut can never leave half an absolute path (which no base
    matches any more) or half a secret (which no pattern matches any more)."""
    kept = dict((key, finding.get(key)) for key in FINDING_REQUIRED)
    for key in TRUNCATED_FIELDS:
        if isinstance(kept.get(key), str):
            kept[key] = truncate(clean_text(ctx, kept[key]), CAPS[key])
    kept["evidence"] = [dict(path=item["path"], line=item["line"]) for item in finding.get("evidence") or []]
    kept["research_questions"] = [truncate(clean_text(ctx, question), CAPS["question"])
                                  for question in finding.get("research_questions") or []]
    return kept


def fingerprint(finding):
    """sha1(lower(dim|module|check|norm(subject)|evidence[0].path))[:8]: the finding's identity, never its prose."""
    evidence = finding.get("evidence") or [{}]
    raw = "|".join([str(finding.get("dim")), finding.get("module") or "", finding.get("check") or "",
                    norm(finding.get("subject") or ""), evidence[0].get("path", "")])
    return hashlib.sha1(raw.lower().encode("utf-8")).hexdigest()[:FP_CHARS]


def split_id(ident):
    match = re.match(r"^(W|CS|M[0-9]+)-([0-9]+)$", ident or "")
    return (match.group(1), int(match.group(2))) if match else (None, 0)


def id_order(ident):
    prefix, number = split_id(ident)
    if prefix == "W":
        return (0, 0, number)
    if prefix == "CS":
        return (2, 0, number)
    return (1, int(prefix[1:]) if prefix else 0, number)


def id_prefix(finding, numbers):
    if finding.get("dim") == 5:
        return "CS"
    return "M%d" % numbers[finding["module"]] if finding.get("module") else "W"


def earlier_findings(ctx, run):
    """Every earlier finalized run's findings.json, oldest first, then this run's own previous one."""
    paths = [os.path.join(runs_dir(ctx), name, "findings.json") for name in finalized_runs(ctx) if run_key(name) < run_key(run.id)]
    own = os.path.join(run.dir, "findings.json")
    return paths + ([own] if os.path.isfile(own) else [])


def prior_assignments(paths):
    """(fp -> ID, module -> M number, highest number per ID prefix, highest module number); a newer run
    overrides an older one, so IDs and module numbers carry forward run after run."""
    ids, modules, used, top_module = {}, {}, {}, 0
    for path in paths:
        try:
            document = read_json(path)
        except (OSError, ValueError):
            warn("an earlier findings.json could not be read; its IDs are not reused")
            continue
        for name, number in (document.get("module_numbers") or {}).items():
            if is_int(number):
                modules[name] = number
                top_module = max(top_module, number)
        for finding in document.get("findings") or []:
            prefix, number = split_id(finding.get("id"))
            if prefix and finding.get("fp"):
                ids[finding["fp"]] = finding["id"]
                used[prefix] = max(used.get(prefix, 0), number)
                if prefix.startswith("M"):
                    top_module = max(top_module, int(prefix[1:]))
    return ids, modules, used, top_module


def assign_module_numbers(names, prior, top_module):
    numbers, following = {}, top_module + 1
    for name in names:
        if name in numbers:
            continue
        if name in prior:
            numbers[name] = prior[name]
        else:
            numbers[name] = following
            following += 1
    return numbers


def assign_ids(findings, prior_ids, numbers, used):
    taken, fresh = set(), []
    for finding in findings:
        prefix = id_prefix(finding, numbers)
        old = prior_ids.get(finding["fp"])
        if old and split_id(old)[0] == prefix and old not in taken:
            finding["id"] = old
            taken.add(old)
        else:
            fresh.append((prefix, finding))
    fresh.sort(key=lambda pair: (pair[0], SEVERITY_RANK[pair[1]["severity"]], pair[1]["dim"], pair[1]["check"],
                                 norm(pair[1]["subject"]), pair[1]["fp"]))
    for prefix, finding in fresh:
        number = used.get(prefix, 0) + 1
        while "%s-%d" % (prefix, number) in taken:
            number += 1
        used[prefix] = number
        finding["id"] = "%s-%d" % (prefix, number)
        taken.add(finding["id"])


def merge_findings(items):
    """One record per fingerprint: the first report's wording, the union of the evidence and questions,
    and the highest severity any report gave."""
    by_fp, order = {}, []
    for finding in items:
        fp = fingerprint(finding)
        if fp not in by_fp:
            record = dict(finding)
            record["fp"] = fp
            record["evidence"] = list(finding["evidence"])
            record["research_questions"] = list(finding["research_questions"])
            by_fp[fp] = record
            order.append(fp)
            continue
        record = by_fp[fp]
        if SEVERITY_RANK[finding["severity"]] < SEVERITY_RANK[record["severity"]]:
            record["severity"] = finding["severity"]
        for item in finding["evidence"]:
            if item not in record["evidence"]:
                record["evidence"].append(item)
        for question in finding["research_questions"]:
            if question not in record["research_questions"]:
                record["research_questions"].append(question)
    return [by_fp[fp] for fp in order]


# ----------------------------------------------------------------- agenda, scrub-check, research
def load_result(run, scope):
    """A valid scope's result, re-checked; (document, errors)."""
    try:
        document = read_json(run.result_path(scope))
    except (OSError, ValueError) as problem:
        return None, ["the saved result cannot be read (%s)" % type(problem).__name__]
    errors, _, _ = check_result(document, run.id, scope, run.scopes[scope].get("kind"), run_modules(run))
    return document, errors


def cmd_agenda(argv):
    options, positional = parse_args(argv, {}, 1, "agenda RUN")
    if len(positional) != 1:
        die(EXIT_USAGE, "agenda needs RUN")
    ctx = Ctx(options.get("--config-dir"))
    run = Run(ctx, positional[0])
    budget = ctx.house["RESEARCH_BUDGET"]
    asks = []
    for order, scope in enumerate(run.order):
        if run.load_state(scope).get("state") != "valid":
            continue
        document, errors = load_result(run, scope)
        if errors:
            warn("%s no longer validates; its questions are left out" % scope)
            continue
        for number, raw in enumerate(document["findings"]):
            finding = normalize_finding(ctx, raw)
            fp = fingerprint(finding)
            # The agent's own words, not the relativized ones: scrub-check must see an absolute path an agent
            # wrote, so the question is rewritten in public terms before it reaches the web.
            questions = [truncate(question, CAPS["question"]) for question in raw.get("research_questions") or []]
            for index, question in enumerate(questions):
                asks.append((SEVERITY_RANK[finding["severity"]], order, number, index, one_line(question), fp))
    asks.sort()
    questions, by_text = [], {}
    for _, _, _, _, text, fp in asks:
        key = norm(text)
        if key in by_text:
            if fp not in by_text[key]["fps"]:
                by_text[key]["fps"].append(fp)
            continue
        if len(questions) >= budget:
            continue
        entry = {"id": "Q%02d" % (len(questions) + 1), "question": mask_secrets(text)[0], "fps": [fp]}
        questions.append(entry)
        by_text[key] = entry
    write_json(os.path.join(run.dir, "agenda.json"), {"run": run.id, "budget": budget, "questions": questions})
    lines = ["# Research agenda", "", "Run %s · %d question(s), budget %d. Answer each in public technical terms; quote pages verbatim." % (run.id, len(questions), budget), ""]
    lines.extend("%s · asked by %s · %s" % (entry["id"], ", ".join(entry["fps"]), entry["question"]) for entry in questions)
    agenda_path = os.path.join(run.dir, "agenda.md")
    write_text(agenda_path, "\n".join(lines) + "\n")
    print(display_path(ctx, agenda_path))
    return EXIT_OK


def denylist_files(ctx):
    """Every denylist that applies, once each: the audited config's and the RUNNING session's (whose
    instruction files the dispatched agents load, whatever config is audited), each in its audit data
    folder and its companion's. EXHAUSTIVE_AUDIT_DENYLIST replaces them all."""
    override = os.environ.get("EXHAUSTIVE_AUDIT_DENYLIST")
    if override is not None and override.strip():
        return [path for path in override.split(":") if path]
    folders = (ctx.data, os.path.join(ctx.config, NFC_NAME), nfc_data_dir(ctx, ctx.config),
               os.path.join(ctx.runtime, DATA_DIR_NAME), os.path.join(ctx.runtime, NFC_NAME), nfc_data_dir(ctx, ctx.runtime))
    files, seen = [], set()
    for folder in folders:
        path = os.path.join(folder, DENYLIST_NAME)
        if os.path.realpath(path) not in seen:
            seen.add(os.path.realpath(path))
            files.append(path)
    return files


def denylist_terms(ctx):
    """(the usable terms of every denylist, lowercased; how many shorter ones were ignored). A list that
    exists but cannot be read blocks the check: a check against an unread list proves nothing."""
    terms, short = set(), 0
    for path in denylist_files(ctx):
        if not os.path.lexists(path):
            continue
        try:
            text = read_text(path)
        except OSError as problem:
            die(EXIT_BLOCKED, "BLOCKED: the denylist %s exists but cannot be read (%s); a check against an unread "
                              "list proves nothing" % (display_path(ctx, path), reason_of(problem)))
        for raw in text.splitlines():
            term = raw.strip()
            if not term or term.startswith("#"):
                continue
            if len(term) < MIN_TERM_CHARS:
                short += 1
            else:
                terms.add(term.lower())
    return sorted(terms), short


def cmd_scrub_check(argv):
    options, positional = parse_args(argv, {}, 1, "scrub-check FILE")
    if len(positional) != 1:
        die(EXIT_USAGE, "scrub-check needs FILE")
    ctx = Ctx(options.get("--config-dir"))
    path = resolve_arg_path(ctx, positional[0])
    if not os.path.isfile(path):
        die(EXIT_USAGE, "the file to check does not exist: %s" % positional[0])
    terms, short = denylist_terms(ctx)
    if short:
        # A shorter term would match inside ordinary words; it is counted, never printed.
        warn("%d denylist term(s) under %d characters ignored" % (short, MIN_TERM_CHARS))
    if not terms:
        ignored = "; %d shorter term(s) ignored" % short if short else ""
        print("BLOCKED: no denylist terms; a check against nothing proves nothing (a term needs at least %d characters%s; "
              "seed %s, one private term per line)" % (MIN_TERM_CHARS, ignored, display_path(ctx, os.path.join(ctx.data, DENYLIST_NAME))))
        return EXIT_BLOCKED
    hits = []
    for number, line in enumerate(read_text(path).splitlines(), 1):
        lowered = line.lower()
        if any(term in lowered for term in terms):
            hits.append("line %d: private term" % number)
        if ABSOLUTE_PATH_RE.search(line):
            hits.append("line %d: absolute path" % number)
        if EMAIL_RE.search(line):
            hits.append("line %d: email" % number)
    if hits:
        for hit in hits:
            print(hit)
        print("BLOCKED: do not dispatch this text; rewrite those lines in public technical terms, or drop them")
        return EXIT_PROBLEM
    print("CLEAN")
    return EXIT_OK


def public_address(address):
    """Whether a public web page can live at this address: global and not multicast, and for IPv6 never a
    wrapper (mapped, 6to4, Teredo, NAT64) around an IPv4 address that is not."""
    if not address.is_global or address.is_multicast:
        return False
    if address.version == 4:
        return True
    inner = [address.ipv4_mapped, address.sixtofour] + list(address.teredo or ())
    if address in NAT64_PREFIX:
        inner.append(ipaddress.IPv4Address(int(address) & IPV4_BITS))
    return all(public_address(wrapped) for wrapped in inner if wrapped is not None)


def host_problem(host):
    """Why a URL host is not a public web host, or None. Offline on purpose: names are never resolved, so a
    public name that resolves to a private address is not caught here; the HTTPS certificate check is the
    defense left for that case."""
    if host.endswith("."):
        return "url host ends with a dot"
    if ":" in host:
        try:
            address = ipaddress.IPv6Address(host)
        except ValueError:
            return "url host is not a valid IPv6 address"
        return None if public_address(address) else "url points at a local or private host"
    labels = host.split(".")
    if NUMERIC_LABEL_RE.match(labels[-1]):
        # curl and the system resolver read 127.1, 2130706433, 0x7f000001 and 0177.0.0.1 as addresses, so
        # only the canonical dotted quad is judged as one; every other numeric spelling is refused.
        if not DOTTED_QUAD_RE.match(host):
            return "url host is a number, not a canonical IPv4 address"
        return None if public_address(ipaddress.IPv4Address(host)) else "url points at a local or private host"
    if len(host) > DNS_NAME_MAX or not all(DNS_LABEL_RE.match(label) for label in labels):
        return "url host is not a plain DNS name (letters, digits, hyphens and dots)"
    if host == "localhost" or host.endswith(PRIVATE_HOST_SUFFIXES):
        return "url points at a local or private host"
    if len(labels) < 2:
        return "url host is a single label, which only a local network resolves"
    return None


def url_problem(url, allow_files):
    """Why a URL must not be fetched, or None: the one policy for every lead and for where its fetch lands."""
    if not isinstance(url, str) or not url:
        return "url must be a non-empty string"
    if CONTROL_RE.search(url) or re.search(r"\s", url):
        return "url contains whitespace or a control character"
    if url.startswith("file://"):
        return None if allow_files else "only https URLs are fetched (file:// needs EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS=1)"
    try:
        parts = urlsplit(url)
        host = parts.hostname or ""
    except ValueError:
        return "url cannot be parsed"
    if parts.scheme != "https":
        return "only https URLs are fetched"
    if "@" in parts.netloc:
        return "url carries a user name"
    if not host:
        return "url has no host"
    return host_problem(host)


def cmd_url_check(argv):
    """The bash half's check of where a fetch landed: exit 0 for a URL the policy allows, else the reason and exit 2."""
    if len(argv) != 1:
        die(EXIT_USAGE, "_url-check needs exactly one URL")
    problem = url_problem(argv[0], os.environ.get("EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS") == "1")
    if problem:
        print(problem)
        return EXIT_PROBLEM
    return EXIT_OK


def check_research_reply(reply, run_id, agenda_ids, allow_files):
    errors = []
    if not isinstance(reply, dict):
        return ["the reply must be a JSON object"]
    expect_keys("reply", reply, ("header", "leads"), (), errors)
    header = reply.get("header")
    if isinstance(header, dict):
        expect_keys("header", header, ("run", "scope"), (), errors)
        if header.get("run") != run_id:
            errors.append("header: run must be %s" % run_id)
        if header.get("scope") != RESEARCH_SCOPE:
            errors.append("header: scope must be %s" % RESEARCH_SCOPE)
    elif "header" in reply:
        errors.append("header must be an object")
    leads = reply.get("leads")
    if not isinstance(leads, list):
        if "leads" in reply:
            errors.append("leads must be a list")
        return errors
    per_question = {}
    for number, lead in enumerate(leads, 1):
        where = "lead %d" % number
        if not isinstance(lead, dict):
            errors.append("%s: must be an object" % where)
            continue
        expect_keys(where, lead, ("question", "url", "quote", "tier"), (), errors)
        question = lead.get("question")
        if not (isinstance(question, str) and QUESTION_ID_RE.match(question) and question in agenda_ids):
            errors.append("%s: question must be an agenda number (%s)" % (where, ", ".join(agenda_ids) or "the agenda is empty"))
        else:
            per_question[question] = per_question.get(question, 0) + 1
        problem = url_problem(lead.get("url"), allow_files)
        if problem:
            errors.append("%s: %s" % (where, problem))
        quote = lead.get("quote")
        if not isinstance(quote, str) or not QUOTE_MIN <= len(quote) <= CAPS["quote"] or CONTROL_RE.search(quote):
            errors.append("%s: quote must be %d to %d characters with no control character" % (where, QUOTE_MIN, CAPS["quote"]))
        if lead.get("tier") not in RESEARCH_TIERS:
            errors.append("%s: tier must be one of %s" % (where, "|".join(RESEARCH_TIERS)))
    for question, count in sorted(per_question.items()):
        if count > LEADS_PER_QUESTION_MAX:
            errors.append("%s has %d leads, more than %d" % (question, count, LEADS_PER_QUESTION_MAX))
    return errors


def load_agenda(run):
    path = os.path.join(run.dir, "agenda.json")
    if not os.path.isfile(path):
        die(EXIT_USAGE, "run %s has no agenda yet: run agenda first" % run.id)
    return read_json(path)


def cache_file(run, url):
    return os.path.join(run.dir, "research_cache", hashlib.sha1(url.encode("utf-8")).hexdigest()[:16] + ".page")


def cmd_attach_prepare(argv):
    options, positional = parse_args(argv, {}, 2, "attach-research RUN FILE")
    if len(positional) != 2:
        die(EXIT_USAGE, "attach-research needs RUN FILE")
    ctx = Ctx(options.get("--config-dir"))
    run = Run(ctx, positional[0])
    path = resolve_arg_path(ctx, positional[1])
    if not os.path.isfile(path):
        die(EXIT_USAGE, "the reply file does not exist: %s" % positional[1])
    agenda = load_agenda(run)
    try:
        reply = read_json(path)
    except ValueError:
        print("INVALID: the reply file is not JSON")
        return EXIT_PROBLEM
    allow_files = os.environ.get("EXHAUSTIVE_AUDIT_ALLOW_FILE_URLS") == "1"
    errors = check_research_reply(reply, run.id, [entry["id"] for entry in agenda.get("questions", [])], allow_files)
    if errors:
        print("INVALID: " + "; ".join(errors[:MAX_REASONS_SHOWN]) + (" (and %d more)" % (len(errors) - MAX_REASONS_SHOWN) if len(errors) > MAX_REASONS_SHOWN else ""))
        return EXIT_PROBLEM
    write_json(os.path.join(run.dir, "research.pending.json"), {"leads": reply["leads"]})
    urls = []
    for lead in reply["leads"]:
        if lead["url"] not in urls:
            urls.append(lead["url"])
    os.makedirs(os.path.join(run.dir, "research_cache"), 0o700, exist_ok=True)
    write_text(os.path.join(run.dir, "research.fetch-plan.tsv"), "".join("%s\t%s\n" % (url, cache_file(run, url)) for url in urls))
    print(run.dir)   # read by the bash half only, never shown
    return EXIT_OK


class TextOnly(HTMLParser):
    """Adapted from claude_code_new_functionality_check.sh render_html_text: visible text only."""
    BLOCK_TAGS = ("p", "div", "h1", "h2", "h3", "h4", "h5", "li", "br", "tr", "section", "article")
    HIDDEN_TAGS = ("script", "style", "noscript")

    def __init__(self):
        HTMLParser.__init__(self)
        self.parts, self.hidden = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in self.HIDDEN_TAGS:
            self.hidden += 1
        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in self.HIDDEN_TAGS and self.hidden:
            self.hidden -= 1

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def page_text(path):
    text = read_text(path)
    if re.search(r"(?i)<html|<!doctype", text[:4096]):
        parser = TextOnly()
        parser.feed(text)
        text = "".join(parser.parts)
    return norm_space(html.unescape(text))


def norm_space(text):
    return re.sub(r"\s+", " ", text).strip()


# A page renders markdown its own way (a quote copied with backticks around `name` reads "name" on the
# rendered page), so a quote and its page are compared on the same normalized form. The table is built
# from code points so that no curly quote or dash sits in this source file.
QUOTE_FOLDS = dict([(code, "'") for code in (0x2018, 0x2019, 0x201A, 0x201B)]
                   + [(code, '"') for code in (0x201C, 0x201D, 0x201E, 0x201F)]
                   + [(code, "-") for code in (0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212)])
ESCAPED_QUOTE_RE = re.compile(r"\\(?=[\"'])")
MARKDOWN_PUNCTUATION_RE = re.compile(r"[`*_]")


def fold_for_match(text):
    """The form a quote and its page are compared in: curly quotes and dashes made plain, a backslash before
    a quote dropped, ` * _ dropped, whitespace collapsed. Case and word order still count."""
    text = text.translate(QUOTE_FOLDS)
    text = ESCAPED_QUOTE_RE.sub("", text)
    text = MARKDOWN_PUNCTUATION_RE.sub("", text)
    return norm_space(text)


def cmd_attach_apply(argv):
    options, positional = parse_args(argv, {}, 2, "attach-research RUN FILE")
    ctx = Ctx(options.get("--config-dir"))
    run = Run(ctx, positional[0])
    agenda = dict((entry["id"], entry) for entry in load_agenda(run).get("questions", []))
    pending = read_json(os.path.join(run.dir, "research.pending.json"))["leads"]
    fetched = {}
    results_path = os.path.join(run.dir, "research.fetch.tsv")
    for line in read_text(results_path).splitlines() if os.path.isfile(results_path) else []:
        parts = line.split("\t", 2)
        if len(parts) == 3:
            fetched[parts[0]] = (parts[1], parts[2])
    counts = {"verified": 0, "unverified": 0, "failed": 0}
    leads, attachments = [], {}
    for lead in pending:
        status, detail = fetched.get(lead["url"], ("failed", "the page was never fetched"))
        if status == "ok":
            found = fold_for_match(lead["quote"]) in fold_for_match(page_text(cache_file(run, lead["url"])))
            status = "verified" if found else "unverified"
            detail = "the quote is on the page" if found else "the quote is not on the page"
        else:
            status = "failed"
        counts[status] += 1
        record = {"question": lead["question"], "url": lead["url"], "quote": lead["quote"], "tier": lead["tier"],
                  "status": status, "detail": clean_text(ctx, detail)}
        leads.append(record)
        if status == "verified":
            for fp in agenda[lead["question"]]["fps"]:
                attachments.setdefault(fp, []).append({"url": lead["url"], "quote": lead["quote"], "tier": lead["tier"], "verified": True})
    document = clean_obj(ctx, {"run": run.id, "generated_at": iso(now_epoch()), "counts": counts, "leads": leads, "attachments": attachments})
    research_path = os.path.join(run.dir, "research.json")
    write_json(research_path, document)
    print("research: %d verified, %d unverified, %d failed" % (counts["verified"], counts["unverified"], counts["failed"]))
    print("written: %s" % display_path(ctx, research_path))
    return EXIT_OK


# ----------------------------------------------------------------- finalize and the reports
def report_number(folder):
    found = [match.group(1) for match in (REPORT_RE.match(name) for name in safe_listdir(folder)) if match]
    highest = max(found, key=int) if found else "0"
    return int(highest) + 1


def report_folder(ctx, run):
    """Where the reports go: the run folder, or the root's assets/output with REPORT_LAYOUT=assets-output. An
    audited repo can ship assets/ (or assets/output/) as a symlink, so a folder that resolves outside the
    root is refused, with a warning, before anything is created through it."""
    root = run.plan.get("root")
    if ctx.house["REPORT_LAYOUT"] != "assets-output" or not root:
        return run.dir
    folder = os.path.join(root, "assets", "output")
    if not inside(folder, root):
        warn("assets/output leads outside the root (a symlink); the reports go to the run folder instead")
        return run.dir
    os.makedirs(folder, exist_ok=True)
    return folder


def cell(text):
    return one_line(text).replace("|", "\\|")


def evidence_text(evidence):
    return ", ".join("`%s:%s`" % (str(item["path"]).replace("`", "'"), item["line"]) for item in evidence)


def code_span(text):
    """text as one markdown code span, so a report viewer shows it literally (never an image, a link or HTML):
    the fence is longer than any backtick run inside, and a space pads a backtick at either end."""
    text = one_line(text)
    fence = "`" * (max([len(run) for run in re.findall(r"`+", text)] or [0]) + 1)
    pad = " " if text.startswith("`") or text.endswith("`") else ""
    return fence + pad + text + pad + fence


def finding_block(finding, run_note=None):
    lines = ["### %s · %s · %s · %s" % (finding["id"], finding["severity"], finding["check"], one_line(finding["subject"]))]
    if run_note:
        lines.append("- **Run:** %s" % run_note)
    lines.append("- **Hash:** `%s` · **Dimension:** %d %s · **Module:** %s · **Category:** %s" % (
        finding["fp"], finding["dim"], DIM_NAMES.get(finding["dim"], "?"), finding.get("module") or "(workspace)", one_line(finding["category"])))
    lines.append("- **Finding:** %s" % one_line(finding["finding"]))
    lines.append("- **Why:** %s" % one_line(finding["rationale"]))
    lines.append("- **Recommendation:** %s" % one_line(finding["recommendation"]))
    lines.append("- **Effort:** %s · **Risk:** %s" % (finding["effort"], finding["risk"]))
    lines.append("- **Evidence:** %s" % evidence_text(finding["evidence"]))
    for lead in finding.get("research") or []:
        if lead.get("verified"):
            # The page chose the quote and the researcher chose the tier: neither is presented as fact.
            lines.append("- **Research (verified = the quote was found at this URL; the researcher rates the source %s):** %s — %s"
                         % (lead["tier"], code_span(lead["url"]), code_span(lead["quote"])))
    if finding.get("research_questions"):
        lines.append("- **Research questions:** %s" % "; ".join(one_line(question) for question in finding["research_questions"]))
    return "\n".join(lines)


def banner_line(document):
    if document["banner"] == "COMPLETE":
        return "EXHAUSTIVE-AUDIT COMPLETE"
    missing = [scope for scope, status in document["scopes"].items() if status != "valid"]
    unread, held = len(document.get("unreadable") or []), len(document.get("placeholders") or [])
    if unread:
        missing.append("%d unreadable path(s)" % unread)
    if held:
        missing.append("%d iCloud placeholder(s)" % held)
    return "EXHAUSTIVE-AUDIT PARTIAL — not reviewed: %s" % ", ".join(missing)


def unseen_lines(plan):
    """Not-reviewed lines for the paths discovery could not see; a long list is cut, plan.json keeps it whole."""
    lines = ["%s: unreadable (%s)" % (item["path"], item["reason"]) for item in plan.get("unreadable") or []]
    lines += ["%s: an iCloud placeholder (not downloaded)" % path for path in plan.get("placeholders") or []]
    if len(lines) > UNSEEN_LISTED_MAX:
        rest = len(lines) - UNSEEN_LISTED_MAX
        lines = lines[:UNSEEN_LISTED_MAX] + ["%d more unreadable path(s) or placeholder(s); the run's plan.json lists them all" % rest]
    return lines


def triage_rows(findings, with_module=True):
    rows = []
    for finding in findings:
        cells = [finding["id"], "`%s`" % finding["fp"], finding["severity"], str(finding["dim"])]
        if with_module:
            cells.append(finding.get("module") or "—")
        cells.extend([cell(finding["check"]), cell(finding["finding"]), finding["effort"], finding["risk"]])
        rows.append("| " + " | ".join(cells) + " |")
    return rows


def native_tools_section():
    return ["## Native tools to run yourself", "",
            "This audit recommends these and never starts them.",
            "- `/code-review ultra` before a release: a deep review that runs in the cloud, that you start, and that is billed.",
            "- `/doctor` (and `/doctor prompt-audit`): checks the installation, the settings and the instruction files."]


def not_reviewed_section(document):
    lines = ["## Not reviewed", ""]
    if document["not_reviewed"]:
        lines.extend("- %s" % one_line(item) for item in document["not_reviewed"])
    else:
        lines.append("- Nothing: every planned scope returned a valid result.")
    return lines


def main_report(document, run, cs_name):
    findings = document["findings"]
    plan = run.plan
    lines = ["# Exhaustive audit — %s" % document["root_name"], "", banner_line(document), "",
             "- Run: `%s` · generated %s" % (document["run"], document["generated_at"]),
             "- Scope: %s · coverage: %s" % (plan.get("scope"), plan.get("coverage")),
             "- Scopes: %d valid, %d failed, %d missing" % tuple(sum(1 for s in document["scopes"].values() if s == name) for name in ("valid", "failed", "missing"))]
    if cs_name:
        lines.append("- Claude-system report: `%s`" % cs_name)
    lines += ["", "## Coverage", "", "| Module | Lines reviewed | Lines total | Reviewed |", "|---|---|---|---|"]
    for name, cover in sorted(document["coverage"].items()):
        total = cover["lines_total"]
        share = "%d%%" % (100 * cover["lines_reviewed"] // total) if total else "—"
        lines.append("| %s | %d | %d | %s |" % (cell(name), cover["lines_reviewed"], total, share))
    if not document["coverage"]:
        lines.append("| (no module in this scope) | 0 | 0 | — |")
    lines += ["", "## Findings by severity and dimension", "",
              "| Severity | " + " | ".join("%d %s" % (dim, DIM_NAMES[dim]) for dim in sorted(DIM_NAMES)) + " | Total |",
              "|---|" + "---|" * (len(DIM_NAMES) + 1)]
    for severity in SEVERITIES + ("total",):
        counts = [sum(1 for f in findings if f["dim"] == dim and severity in (f["severity"], "total")) for dim in sorted(DIM_NAMES)]
        lines.append("| %s | %s | %d |" % (severity, " | ".join(str(count) for count in counts), sum(counts)))
    lines += ["", "## Triage Index", "", "| ID | Hash | Sev | Dim | Module | Check | Finding | Effort | Risk |",
              "|---|---|---|---|---|---|---|---|---|"]
    lines += triage_rows(findings) or ["| — | | | | | | No findings. | | |"]
    numbers = document["module_numbers"]
    for name in sorted(numbers, key=lambda module: numbers[module]):
        own = [f for f in findings if f.get("module") == name and f["dim"] != 5]
        lines += ["", "## M%d · %s" % (numbers[name], name), ""]
        lines += [finding_block(f) + "\n" for f in own] or ["No findings."]
    workspace = [f for f in findings if not f.get("module") and f["dim"] != 5]
    if workspace:
        lines += ["", "## Workspace-wide", ""] + [finding_block(f) + "\n" for f in workspace]
    system = [f for f in findings if f["dim"] == 5]
    if system:
        lines += ["", "## Claude system", "", "%d finding(s); the details are in %s." % (len(system), "`%s`" % cs_name if cs_name else "the claude-system report")]
    lines += [""] + not_reviewed_section(document) + [""] + native_tools_section()
    return "\n".join(lines) + "\n"


def claude_system_report(document):
    findings = [f for f in document["findings"] if f["dim"] == 5]
    lines = ["# Exhaustive audit — claude system — %s" % document["root_name"], "", banner_line(document), "",
             "- Run: `%s` · generated %s" % (document["run"], document["generated_at"]),
             "- Config: `<config>` · claude-system scope: %s" % document["scopes"].get("D5-claude-system", "not planned"), "",
             "## Triage Index", "", "| ID | Hash | Sev | Dim | Check | Finding | Effort | Risk |", "|---|---|---|---|---|---|---|---|"]
    lines += triage_rows(findings, with_module=False) or ["| — | | | | | No findings. | | |"]
    lines += ["", "## Findings", ""] + ([finding_block(f) + "\n" for f in findings] or ["No findings."])
    lines += [""] + not_reviewed_section(document) + [""] + native_tools_section()
    return "\n".join(lines) + "\n"


def cmd_finalize(argv):
    options, positional = parse_args(argv, {}, 1, "finalize RUN")
    if len(positional) != 1:
        die(EXIT_USAGE, "finalize needs RUN")
    ctx = Ctx(options.get("--config-dir"))
    run = Run(ctx, positional[0])
    epoch = now_epoch()
    statuses, collected, reviewed, not_reviewed = {}, [], {}, []
    for scope_id in run.order:
        scope = run.scopes[scope_id]
        state = run.load_state(scope_id)
        status = status_of(state)
        document = None
        if status == "valid":
            document, errors = load_result(run, scope_id)
            if errors:
                warn("%s no longer validates (%s); it is reported as not reviewed" % (scope_id, errors[0]))
                status = "missing"
        statuses[scope_id] = status
        if status != "valid":
            why = state.get("reason") or ("no valid result" if status == "missing" else "failed")
            not_reviewed.append("%s: %s (%s)" % (scope_id, status, one_line(why)[:CAPS["not_reviewed"]]))
            continue
        for item in document["header"].get("not_reviewed") or []:
            not_reviewed.append("%s reported: %s" % (scope_id, one_line(item)))
        if scope.get("kind") == "code":
            done = min(document["header"].get("lines_reviewed", 0), scope.get("lines", 0))
            reviewed[scope["module"]] = reviewed.get(scope["module"], 0) + done
        collected.extend(normalize_finding(ctx, finding) for finding in document["findings"])
    findings = merge_findings(collected)
    research_path = os.path.join(run.dir, "research.json")
    attachments = read_json(research_path).get("attachments", {}) if os.path.isfile(research_path) else {}
    history = earlier_findings(ctx, run)
    prior_ids, prior_modules, used, top_module = prior_assignments(history)
    names = [module["name"] for module in run.modules()] + sorted(set(f["module"] for f in findings if f.get("module")))
    numbers = assign_module_numbers(names, prior_modules, top_module)
    assign_ids(findings, prior_ids, numbers, used)
    for finding in findings:
        finding["research"] = attachments.get(finding["fp"], [])
    findings.sort(key=lambda f: (SEVERITY_RANK[f["severity"]], id_order(f["id"])))
    coverage = dict((module["name"], {"lines_reviewed": reviewed.get(module["name"], 0), "lines_total": module.get("code_lines", 0)})
                    for module in run.modules())
    unreadable, placeholders = run.plan.get("unreadable") or [], run.plan.get("placeholders") or []
    not_reviewed.extend(unseen_lines(run.plan))
    every_scope_valid = all(status == "valid" for status in statuses.values())
    banner = "COMPLETE" if every_scope_valid and not unreadable and not placeholders else "PARTIAL"
    document = clean_obj(ctx, {"run": run.id, "root_name": run.plan.get("root_name"), "generated_at": iso(epoch),
                               "coverage": coverage, "scopes": statuses, "not_reviewed": not_reviewed, "banner": banner,
                               "findings": findings, "module_numbers": numbers, "unreadable": unreadable,
                               "placeholders": placeholders})
    write_json(os.path.join(run.dir, "findings.json"), document)
    folder = report_folder(ctx, run)
    number = report_number(folder)
    when = stamp(epoch)
    main_name = "exhaustive_audit_v%d_%s.md" % (number, when)
    cs_name = "exhaustive_audit_claude_system_v%d_%s.md" % (number, when) if "D5-claude-system" in run.scopes else None
    write_text(os.path.join(folder, main_name), clean_text(ctx, main_report(document, run, cs_name)))
    if cs_name:
        write_text(os.path.join(folder, cs_name), clean_text(ctx, claude_system_report(document)))
    print(banner_line(document))
    print("findings: %d (%s)" % (len(findings), ", ".join("%s %d" % (s, sum(1 for f in findings if f["severity"] == s)) for s in SEVERITIES)))
    print("findings.json: %s" % display_path(ctx, os.path.join(run.dir, "findings.json")))
    print("report: %s" % display_path(ctx, os.path.join(folder, main_name)))
    if cs_name:
        print("claude-system report: %s" % display_path(ctx, os.path.join(folder, cs_name)))
    return EXIT_OK


# ----------------------------------------------------------------- diff and lookup
def load_findings(ctx, run_id):
    run = Run(ctx, run_id)
    path = os.path.join(run.dir, "findings.json")
    if not os.path.isfile(path):
        die(EXIT_USAGE, "run %s is not finalized yet: run finalize first" % run_id)
    return run, read_json(path)


def id_pattern(ident):
    return re.compile(r"(?<![A-Za-z0-9-])" + re.escape(ident) + r"(?![0-9])")


def apply_logs(ctx, old_run):
    """(name, text) of every apply log in the old run's folder, a later run's folder, or the root's
    assets/output written after the old run."""
    folders = [os.path.join(runs_dir(ctx), name) for name in all_runs(ctx) if run_key(name) >= run_key(old_run.id)]
    since = stamp_epoch(run_key(old_run.id)[0])
    logs = []
    for folder in folders:
        for name in safe_listdir(folder):
            if name.startswith(APPLY_LOG_PREFIX) and os.path.isfile(os.path.join(folder, name)):
                logs.append((name, read_text(os.path.join(folder, name))))
    shared = os.path.join(old_run.plan.get("root") or "", "assets", "output")
    if old_run.plan.get("root") and os.path.isdir(shared):
        for name in safe_listdir(shared):
            path = os.path.join(shared, name)
            if name.startswith(APPLY_LOG_PREFIX) and os.path.isfile(path) and os.path.getmtime(path) >= since:
                logs.append((name, read_text(path)))
    return logs


def finding_repo(old_run, finding):
    root = old_run.plan.get("root")
    if finding.get("dim") == 5:
        folder = old_run.plan.get("config_path")
    elif finding.get("module") and root:
        folder = os.path.join(root, old_run.module_path(finding["module"]))
    else:
        folder = root
    return folder if folder and os.path.lexists(os.path.join(folder, ".git")) else None


def resolution_evidence(ctx, old_run, findings):
    """ID -> the evidence that the finding was acted on: an apply log row naming it APPLIED, or a commit
    since the old run that names it. Nothing else counts as resolved."""
    evidence = {}
    logs = apply_logs(ctx, old_run)
    for finding in findings:
        pattern = id_pattern(finding["id"])
        for name, text in logs:
            if any(pattern.search(line) and APPLIED_RE.search(line) for line in text.splitlines()):
                evidence[finding["id"]] = "apply log %s" % name
                break
    since = time.strftime("%Y-%m-%d %H:%M:%S +0000", time.gmtime(stamp_epoch(run_key(old_run.id)[0])))
    commits = {}
    for finding in findings:
        if finding["id"] in evidence:
            continue
        repo = finding_repo(old_run, finding)
        if not repo:
            continue
        if repo not in commits:
            code, out, _ = run_git(ctx, repo, ["log", "--since=%s" % since, "--format=%x1e%h%x1f%B"])
            commits[repo] = [entry.split("\x1f", 1) for entry in out.split("\x1e") if "\x1f" in entry] if code == 0 else []
        for short, body in commits[repo]:
            if id_pattern(finding["id"]).search(body):
                evidence[finding["id"]] = "git commit %s in %s" % (short.strip(), finding.get("module") or ("<config>" if finding.get("dim") == 5 else "the root"))
                break
    return evidence


def approximate_key(finding):
    path = finding["evidence"][0]["path"] if finding.get("evidence") else ""
    return (finding["dim"], finding.get("module"), finding["check"], path)


def diff_buckets(ctx, old_run, old, new):
    old_by, new_by = dict((f["fp"], f) for f in old["findings"]), dict((f["fp"], f) for f in new["findings"])
    buckets = dict((name, []) for name in DIFF_BUCKETS)
    new_only = []
    for fp, finding in new_by.items():
        if fp not in old_by:
            new_only.append(finding)
            continue
        before, after = SEVERITY_RANK[old_by[fp]["severity"]], SEVERITY_RANK[finding["severity"]]
        bucket = "RECURRING" if before == after else ("REGRESSED" if after < before else "IMPROVED")
        buckets[bucket].append((old_by[fp], finding))
    old_only = [finding for fp, finding in old_by.items() if fp not in new_by]
    evidence = resolution_evidence(ctx, old_run, old_only)
    remaining = []
    for finding in old_only:
        if finding["id"] in evidence:
            buckets["RESOLVED"].append((finding, evidence[finding["id"]]))
        else:
            remaining.append(finding)
    for finding in remaining:
        match = next((candidate for candidate in new_only if approximate_key(candidate) == approximate_key(finding)), None)
        if match:
            new_only.remove(match)
            buckets["APPROXIMATE"].append((finding, match))
        else:
            buckets["DROPPED"].append((finding, None))
    buckets["NEW"] = [(None, finding) for finding in new_only]
    for name in buckets:
        buckets[name].sort(key=lambda pair: id_order((pair[1] if isinstance(pair[1], dict) else pair[0])["id"]))
    return buckets


def diff_report(old_id, new_id, buckets):
    lines = ["# Exhaustive audit diff — %s → %s" % (old_id, new_id), "", "| Bucket | Count |", "|---|---|"]
    lines += ["| %s | %d |" % (name, len(buckets[name])) for name in DIFF_BUCKETS]
    head = "| ID | Hash | Sev | Module | Check | %s |"
    rule = "|---|---|---|---|---|---|"
    for name in DIFF_BUCKETS:
        pairs = buckets[name]
        lines += ["", "## %s (%d)" % (name, len(pairs)), ""]
        if not pairs:
            lines.append("None.")
            continue
        if name == "APPROXIMATE":
            lines += ["| Old ID | New ID | Hash (old → new) | Module | Check | Subject (old → new) |", rule]
            for old, new in pairs:
                lines.append("| %s | %s | `%s` → `%s` | %s | %s | %s → %s |" % (old["id"], new["id"], old["fp"], new["fp"], old.get("module") or "—",
                                                                                 cell(old["check"]), cell(old["subject"]), cell(new["subject"])))
            continue
        lines += [head % ("Evidence" if name == "RESOLVED" else "Finding"), rule]
        for old, new in pairs:
            current = new if isinstance(new, dict) else old
            if name in ("REGRESSED", "IMPROVED"):
                severity = "%s → %s" % (old["severity"], new["severity"])
            else:
                severity = current["severity"]
            last = new if name == "RESOLVED" else cell(current["finding"])
            lines.append("| %s | `%s` | %s | %s | %s | %s |" % (current["id"], current["fp"], severity, current.get("module") or "—", cell(current["check"]), last))
    return "\n".join(lines) + "\n"


def cmd_diff(argv):
    options, positional = parse_args(argv, {}, 2, "diff [OLD NEW]")
    ctx = Ctx(options.get("--config-dir"))
    if len(positional) == 1:
        die(EXIT_USAGE, "diff takes no run, or exactly two (OLD NEW)")
    if positional:
        old_id, new_id = positional
    else:
        finalized = finalized_runs(ctx)
        if len(finalized) < 2:
            die(EXIT_USAGE, "diff needs two finalized runs; this data dir has %d" % len(finalized))
        old_id, new_id = finalized[-2:]
    old_run, old = load_findings(ctx, old_id)
    new_run, new = load_findings(ctx, new_id)
    report = clean_text(ctx, diff_report(old_id, new_id, diff_buckets(ctx, old_run, old, new)))
    write_text(os.path.join(new_run.dir, "diff_vs_%s.md" % old_id), report)
    sys.stdout.write(report)
    return EXIT_OK


def cmd_lookup(argv):
    options, positional = parse_args(argv, {"--run": "value"}, 1, "lookup ID [--run RUN]")
    if len(positional) != 1:
        die(EXIT_USAGE, "lookup needs an ID such as M2-1, W-3 or CS-4 (or a finding's hash)")
    ctx = Ctx(options.get("--config-dir"))
    if options.get("--run"):
        run_id, note = options["--run"], "given with --run"
    else:
        finalized = finalized_runs(ctx)
        if not finalized:
            die(EXIT_USAGE, "no finalized run exists yet in %s" % display_path(ctx, runs_dir(ctx)))
        run_id, note = finalized[-1], "the latest finalized run; --run picks another"
    _, document = load_findings(ctx, run_id)
    wanted = positional[0]
    finding = next((f for f in document.get("findings", []) if f.get("id") == wanted or f.get("fp") == wanted), None)
    if finding is None:
        sys.stderr.write("%s: %s is not in run %s\n" % (PREFIX, one_line(wanted)[:40], run_id))
        return EXIT_USAGE
    print(clean_text(ctx, finding_block(finding, run_note="%s (%s)" % (run_id, note))))
    return EXIT_OK


# ----------------------------------------------------------------- the demo and its answer key
DEMO_MODULES = ("orders", "notify")
# Each planted defect: (id, critical, module, the evidence paths that count, keywords — one must appear
# in the finding's text, title). A finding found it when its module matches (or is workspace-wide), one
# of its evidence paths is listed (any path when none is), and a keyword appears.
DEMO_DEFECTS = (
    ("D01", True, "orders", ("orders/app/db.py",), ("sql", "inject", "concaten", "parameter"), "SQL built by string concatenation"),
    ("D02", False, "orders", ("orders/app/client.py",), ("timeout",), "an HTTP call with no timeout"),
    ("D03", False, "orders", ("orders/app/client.py",), ("except", "swallow"), "a bare except that swallows every error"),
    ("D04", True, "orders", ("orders/app/settings.py",), ("secret", "key", "credential", "log"), "a secret-shaped value written to a log"),
    ("D05", False, "orders", ("orders/tests/test_db.py",), ("assert",), "a test that asserts nothing"),
    ("D06", False, "orders", ("orders/requirements.txt",), ("requests", "2.19", "outdated", "old", "cve", "vulnerab"), "an old pinned dependency"),
    ("D07", True, "notify", ("notify/bin/update.sh",), ("curl", "tmp", "checksum", "verif", "download"), "an unchecked download into a predictable /tmp file, then run"),
    ("D08", False, None, ("orders/app/text.py", "notify/notify/text.py"), ("duplicat", "slugify", "shared", "copy"), "a helper duplicated across the modules"),
    ("D09", False, "orders", ("orders/scripts/sync.sh",), ("send.sh", "missing", "broken", "exist"), "a broken cross-module path"),
    ("D10", False, None, ("<config>/hooks/prompt-guard.sh", "<config>/settings.json"), ("user_message", "matcher"), "a UserPromptSubmit hook with a matcher, reading .user_message"),
    ("D11", False, None, ("<config>/agents/release-helper.md",), ("yaml", "quote", "colon", "frontmatter"), "an agent description with an unquoted ': '"),
    ("D12", False, None, ("<config>/skills/code-review/SKILL.md",), ("code-review", "shadow", "bundled", "built-in", "builtin"), "a personal skill named code-review"),
    ("D13", False, None, ("<config>/settings.json",), ("curl",), "Bash(curl:*) in the allow rules"),
    ("D14", False, None, ("<config>/CLAUDE.md",), ("deploy-checklist", "missing", "exist"), "a CLAUDE.md that names a missing skill"),
    ("D15", False, None, (), ("new-functionality", "new functionality", "currency"), "the new-functionality check is not installed"),
)
DEMO_FILES = {
    "workspace/MODULES.md": "# Modules\n\n| Module | Purpose |\n|---|---|\n| orders | the order API (Python) |\n| notify | the notification worker (Python and shell) |\n",
    "workspace/CLAUDE.md": "# Demo workspace\n\nTwo small modules with planted defects, built by exhaustive_audit_and_review.sh demo-fixture.\n",
    "workspace/orders/CLAUDE.md": "# orders\n\n# testing-standard: standard\n# test-command: python3 -m pytest -q\n# retry-standard: standard\n",
    "workspace/orders/requirements.txt": "requests==2.19.0\nflask==2.0.0\n",
    "workspace/orders/app/__init__.py": "\"\"\"The order API.\"\"\"\n",
    "workspace/orders/app/db.py": (
        "\"\"\"Order lookups.\"\"\"\nimport sqlite3\n\nDATABASE_PATH = \"orders.db\"\n\n\n"
        "def find_orders(customer_name):\n    connection = sqlite3.connect(DATABASE_PATH)\n    try:\n"
        "        query = \"SELECT id, total FROM orders WHERE customer = '\" + customer_name + \"'\"\n"
        "        return connection.execute(query).fetchall()\n    finally:\n        connection.close()\n"),
    "workspace/orders/app/client.py": (
        "\"\"\"Calls the pricing service.\"\"\"\nimport requests\n\nPRICING_URL = \"https://pricing.example.com/v1/quote\"\n\n\n"
        "def fetch_quote(order_id):\n    try:\n        response = requests.get(PRICING_URL, params={\"order\": order_id})\n"
        "        return response.json()\n    except:\n        return None\n"),
    "workspace/orders/app/settings.py": (
        "\"\"\"Pricing client settings.\"\"\"\nimport logging\n\nlogger = logging.getLogger(__name__)\n\n"
        "# Assembled at run time so this demo file never holds a literal secret.\n"
        "API_KEY = \"sk-\" + \"demo\" + \"-\" + \"7f3a9c2e41b5d860\"\n\n\n"
        "def configure():\n    logger.info(\"configuring the pricing client with key %s\", API_KEY)\n    return {\"api_key\": API_KEY}\n"),
    "workspace/orders/app/text.py": (
        "\"\"\"Text helpers.\"\"\"\nimport re\n\n\ndef slugify(value):\n"
        "    value = re.sub(r\"[^a-z0-9]+\", \"-\", value.lower())\n    return value.strip(\"-\")\n"),
    "workspace/orders/tests/test_db.py": (
        "from app.db import find_orders\n\n\ndef test_find_orders():\n    find_orders(\"customer-1\")\n"),
    "workspace/orders/scripts/sync.sh": (
        "#!/bin/bash\n# Pushes new orders to the notify worker.\nset -euo pipefail\n"
        "\"$(dirname \"$0\")/../../notify/bin/send.sh\" --batch orders\n"),
    "workspace/notify/CLAUDE.md": "# notify\n\n# testing-standard: minimal\n",
    "workspace/notify/pyproject.toml": "[project]\nname = \"notify\"\nversion = \"0.1.0\"\ndependencies = [\"requests>=2.31\"]\n",
    "workspace/notify/notify/__init__.py": "\"\"\"The notification worker.\"\"\"\n",
    "workspace/notify/notify/text.py": (
        "\"\"\"Text helpers.\"\"\"\nimport re\n\n\ndef slugify(value):\n"
        "    value = re.sub(r\"[^a-z0-9]+\", \"-\", value.lower())\n    return value.strip(\"-\")\n"),
    "workspace/notify/notify/worker.py": (
        "\"\"\"Sends queued notifications.\"\"\"\nfrom notify.text import slugify\n\n\n"
        "def topic_for(title):\n    return \"notify-\" + slugify(title)\n"),
    "workspace/notify/bin/update.sh": (
        "#!/bin/bash\n# Fetches and runs the latest notifier.\n"
        "curl -s https://downloads.example.com/notifier/latest.sh -o /tmp/notifier-latest.sh\n"
        "bash /tmp/notifier-latest.sh\n"),
    "claude-config/settings.json": (
        "{\n  \"model\": \"sonnet\",\n  \"permissions\": {\n    \"allow\": [\"Read\", \"Bash(git status:*)\", \"Bash(curl:*)\"],\n"
        "    \"deny\": [\"Read(**/.env)\"]\n  },\n  \"hooks\": {\n    \"UserPromptSubmit\": [\n"
        "      {\"matcher\": \"deploy\", \"hooks\": [{\"type\": \"command\", \"command\": \"bash ~/.claude/hooks/prompt-guard.sh\"}]}\n"
        "    ]\n  }\n}\n"),
    "claude-config/hooks/prompt-guard.sh": (
        "#!/bin/bash\n# Blocks prompts that ask for a production deploy.\ninput=\"$(cat)\"\n"
        "prompt=\"$(printf '%s' \"$input\" | python3 -c 'import json, sys; print(json.load(sys.stdin).get(\"user_message\", \"\"))')\"\n"
        "case \"$prompt\" in\n    *production*) echo \"Production deploys need a ticket.\" >&2; exit 2 ;;\nesac\nexit 0\n"),
    "claude-config/agents/release-helper.md": (
        "---\nname: release-helper\ndescription: Use when: preparing a release, collecting the changelog\ntools: Read, Grep\n---\n\n"
        "You help prepare releases.\n"),
    "claude-config/skills/code-review/SKILL.md": "---\nname: code-review\ndescription: \"Reviews the current diff.\"\n---\n\n# Code review\n\nReview the diff.\n",
    "claude-config/CLAUDE.md": "# Demo config\n\n## Workflow\n\n- Before every release, run the /deploy-checklist skill.\n",
    "claude-config/exhaustive-audit-and-review/house.conf": "# Demo settings for the exhaustive audit.\nMAX_LOC_PER_REVIEW=400\nRESEARCH_BUDGET=4\n",
    "claude-config/exhaustive-audit-and-review/denylist.txt": "# Private terms never sent to the web (a demo term).\nGlobex Corporation\n",
}
DEMO_EXECUTABLES = ("workspace/orders/scripts/sync.sh", "workspace/notify/bin/update.sh", "claude-config/hooks/prompt-guard.sh")
DEMO_PRIVATE_DIRS = ("claude-config/exhaustive-audit-and-review",)


def cmd_demo_fixture(argv):
    _, positional = parse_args(argv, {}, 1, "demo-fixture DIR")
    if len(positional) != 1:
        die(EXIT_USAGE, "demo-fixture needs DIR (a new or empty folder)")
    target = os.path.abspath(os.path.expanduser(positional[0]))
    if os.path.exists(target) and (not os.path.isdir(target) or os.listdir(target)):
        die(EXIT_USAGE, "demo-fixture builds only into a new or empty folder, and that one is not empty")
    # The demo is an ordinary workspace, so it gets ordinary modes; only its data dir is private.
    previous = os.umask(0o022)
    try:
        for relative in sorted(DEMO_FILES):
            path = os.path.join(target, relative)
            os.makedirs(os.path.dirname(path), 0o755, exist_ok=True)
            write_text(path, DEMO_FILES[relative])
            os.chmod(path, 0o755 if relative in DEMO_EXECUTABLES else 0o644)
    finally:
        os.umask(previous)
    for folder in DEMO_PRIVATE_DIRS:
        os.chmod(os.path.join(target, folder), 0o700)
    os.chmod(os.path.join(target, "claude-config", DATA_DIR_NAME, "denylist.txt"), 0o600)
    criticals = sum(1 for defect in DEMO_DEFECTS if defect[1])
    print("demo-fixture: built a demo workspace (%d modules: %s) and a demo Claude Code config with %d planted defects (%d critical)"
          % (len(DEMO_MODULES), ", ".join(DEMO_MODULES), len(DEMO_DEFECTS), criticals))
    print("  <dir>/workspace")
    print("  <dir>/claude-config")
    print("Next: /exhaustive-audit-and-review run all --root <dir>/workspace --config-dir <dir>/claude-config")
    print("Then: exhaustive_audit_and_review.sh score-demo <run>, with the same --config-dir (or none) that init-run had")
    return EXIT_OK


def defect_found_by(defect, findings):
    _, _, module, paths, keywords, _ = defect
    for finding in findings:
        if module and finding.get("module") not in (module, None):
            continue
        evidence = [item.get("path") for item in finding.get("evidence") or []]
        if paths and not any(path in paths for path in evidence):
            continue
        text = " ".join(str(finding.get(key, "")) for key in ("check", "subject", "category", "finding", "rationale", "recommendation")).lower()
        if any(keyword in text for keyword in keywords):
            return finding.get("id")
    return None


def cmd_score_demo(argv):
    options, positional = parse_args(argv, {}, 1, "score-demo RUN")
    if len(positional) != 1:
        die(EXIT_USAGE, "score-demo needs RUN")
    ctx = Ctx(options.get("--config-dir"))
    _, document = load_findings(ctx, positional[0])
    findings = document.get("findings", [])
    rows, missed_criticals, found = [], [], 0
    for defect in DEMO_DEFECTS:
        ident, critical, module, paths, _, title = defect
        by = defect_found_by(defect, findings)
        found += 1 if by else 0
        if critical and not by:
            missed_criticals.append(ident)
        rows.append("%s | %s | %s | %s | %s | %s" % (ident, "critical" if critical else "-", module or "-",
                                                     ", ".join(paths) or "(any)", "FOUND by %s" % by if by else "MISSED", title))
    criticals = sum(1 for defect in DEMO_DEFECTS if defect[1])
    print("score-demo: run %s · %d/%d planted defects found · criticals %d/%d" % (positional[0], found, len(DEMO_DEFECTS),
                                                                                criticals - len(missed_criticals), criticals))
    print("defect | class | module | path | result | what")
    for row in rows:
        print(row)
    if missed_criticals:
        print("MISSED critical: %s" % ", ".join(missed_criticals))
        return EXIT_PROBLEM
    return EXIT_OK


# ----------------------------------------------------------------- usage tables
def cmd_usage_tables(argv):
    caps = CAPS
    print("")
    print("FINDING SCHEMA (validate checks exactly this; the agents quote it)")
    print("  result: {\"header\": HEADER, \"findings\": [FINDING, ...]} and no other key")
    print("  HEADER: run (= RUN) · scope (= SCOPE) · agent (a string) · files_reviewed int >= 0 · lines_reviewed int >= 0")
    print("          · notes <= %d (optional) · not_reviewed: at most %d strings, each <= %d (optional)" % (caps["notes"], NOT_REVIEWED_MAX, caps["not_reviewed"]))
    print("  FINDING: dim int %d-%d · module: one of the run's modules, or null" % DIM_RANGE)
    print("          · check <= %d, matching %s · subject <= %d (a dependency, symbol or key, never prose)" % (caps["check"], CHECK_PATTERN, caps["subject"]))
    print("          · severity %s · category <= %d · finding <= %d" % ("|".join(SEVERITIES), caps["category"], caps["finding"]))
    print("          · rationale <= %d · recommendation <= %d · effort %s · risk %s" % (caps["rationale"], caps["recommendation"], "|".join(EFFORTS), "|".join(RISKS)))
    print("          · evidence %d-%d items {path, line int >= 0}; path <= %d, root-relative or <config>/... (no leading /, no ~, no ..)" % (EVIDENCE_RANGE[0], EVIDENCE_RANGE[1], caps["path"]))
    print("          · research_questions <= %d items, each <= %d, in public technical terms (optional)" % (QUESTIONS_MAX, caps["question"]))
    print("  LIMITS: <=%d findings per code scope, <=%d per other scope; unknown fields, control characters and a" % (FINDINGS_MAX["code"], FINDINGS_MAX["other"]))
    print("          line break outside rationale, recommendation and notes are INVALID; a string between 1x and 2x its")
    print("          cap is VALID-OVERLONG (finalize cuts it with an ellipsis), beyond 2x INVALID")
    print("  FINGERPRINT: sha1(lower(dim|module|check|subject|evidence[0].path))[:8]; the subject's case and spacing do not count")
    print("")
    print("RESEARCH REPLY (attach-research rejects the whole reply if any field is wrong)")
    print("  {\"header\": {\"run\": RUN, \"scope\": \"%s\"}, \"leads\": [LEAD, ...]}; the researcher's dispatch line is" % RESEARCH_SCOPE)
    print("  \"AUDIT-RUN: <run> %s\" (every other dispatch: \"AUDIT-RUN: <run> <scope>\")" % RESEARCH_SCOPE)
    print("  LEAD: question Qnn (an agenda number; at most %d leads per question) · url https://... on a public host:" % LEADS_PER_QUESTION_MAX)
    print("        a DNS name of two or more labels or a canonical public IP address; no user name, no local or private")
    print("        host, no trailing dot, no numeric spelling such as 127.1 (the same rule judges where a fetch lands)")
    print("        · quote str >= %d and quote <= %d, verbatim from the page · tier %s · no other field" % (QUOTE_MIN, caps["quote"], "|".join(RESEARCH_TIERS)))
    print("  A quote is verified when it appears contiguously in the fetched page once both are normalized: ` * _ and a")
    print("  backslash before a quote are dropped, curly quotes and dashes become plain ones, whitespace collapses; case counts.")
    print("")
    code_scope = TOKENS_CODE_REVIEWER + CODE_REVIEW_CHILDREN * TOKENS_CODE_SPECIALIST
    print("PLAN ESTIMATE, in processed tokens (cache reads included), per agent: code-reviewer %s, code specialist %s," % (millions(TOKENS_CODE_REVIEWER), millions(TOKENS_CODE_SPECIALIST)))
    print("  dimension agent %s, project-health %s, researcher %s. A code scope (a code-reviewer and its %d specialists)" % (millions(TOKENS_DIMENSION), millions(TOKENS_HEALTH), millions(TOKENS_RESEARCHER), CODE_REVIEW_CHILDREN))
    print("  is %s at any size: its cost is flat per scope, never scaled by lines. Minutes: %d per wave with a code scope," % (millions(code_scope), MINUTES_CODE_WAVE))
    print("  %d per wave without, %d for research. Basis: %s." % (MINUTES_OTHER_WAVE, MINUTES_RESEARCH, ESTIMATE_BASIS))
    print("  Wave cost: a code scope %d agents (code-reviewer + %d specialists), any other scope 1; a wave holds at most cap - %d." % (1 + CODE_REVIEW_CHILDREN, CODE_REVIEW_CHILDREN, CONCURRENCY_HEADROOM))
    print("  Tiers by lines: %s, else %s. Depth below %d is blocked (default %d); the cap defaults to %d." % (
        ", ".join("%s < %d" % pair for pair in TIER_CEILINGS), TIER_TOP, MIN_DEPTH, DEFAULT_MAX_DEPTH, DEFAULT_MAX_CONCURRENT))
    return EXIT_OK


# ----------------------------------------------------------------- main
PUBLIC_NAMES = {"_attach-prepare": "attach-research", "_attach-apply": "attach-research", "_url-check": "attach-research",
                "_usage-tables": "--help"}


def option_value(argv, flag):
    """The value given to a flag in raw arguments, or None: for a message written when parsing never finished."""
    for index, token in enumerate(argv[:-1]):
        if token == flag:
            return argv[index + 1]
    return None


def environment_problem(argv, problem):
    """The catch-all message for an OSError: the subcommand, the error, and the file it hit, relativized (for
    a rename, the target)."""
    ctx = Ctx(option_value(argv, "--config-dir"))
    root = option_value(argv, "--root")
    if root and os.path.isdir(os.path.expanduser(root)):
        ctx.set_root(root)
    name = problem.filename2 or problem.filename
    where = " on %s" % display_path(ctx, name) if isinstance(name, str) and name else ""
    return "%s: %s%s: %s" % (PUBLIC_NAMES.get(argv[0], argv[0]), type(problem).__name__, where, reason_of(problem))


COMMANDS = {
    "discover": cmd_discover, "capabilities": cmd_capabilities, "config-facts": cmd_config_facts, "plan": cmd_plan,
    "init-run": cmd_init_run, "next-wave": cmd_next_wave, "save-result": cmd_save_result, "validate": cmd_validate,
    "agenda": cmd_agenda, "scrub-check": cmd_scrub_check, "finalize": cmd_finalize, "status": cmd_status,
    "runs": cmd_runs, "diff": cmd_diff, "lookup": cmd_lookup, "demo-fixture": cmd_demo_fixture,
    "score-demo": cmd_score_demo, "_attach-prepare": cmd_attach_prepare, "_attach-apply": cmd_attach_apply,
    "_usage-tables": cmd_usage_tables, "_url-check": cmd_url_check,
}


def main(argv):
    if sys.version_info < MIN_PYTHON:
        log("ERROR", "python %d.%d or newer is needed" % MIN_PYTHON)
        return EXIT_USAGE
    if not argv or argv[0] not in COMMANDS:
        log("ERROR", "unknown subcommand (try --help)")
        return EXIT_USAGE
    try:
        return COMMANDS[argv[0]](argv[1:])
    except Fail as problem:
        if problem.code == EXIT_BLOCKED:
            print(str(problem))
        else:
            log("ERROR", str(problem))
        return problem.code
    except OSError as problem:
        log("ERROR", environment_problem(argv, problem))
        return EXIT_USAGE


sys.exit(main(sys.argv[1:]))
PYEOF
