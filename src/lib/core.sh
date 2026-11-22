# ============================================================================
# core.sh - logging, error handling and the resume/progress state machine
# Shared across all platforms (DSM / macOS / Ubuntu / Proxmox VE / Reinstall).
# Part of the generated single-file scripts; not executable on its own.
# Compatible with bash 3.2 (macOS system bash) - avoid bash 4+ features here.
# ============================================================================

set -Eeuo pipefail

# The config block concatenates before this file and defines
# ZJDEPLOY_STATE_DIR (~/.zjdeploy); the :- fallback is a safety net for
# standalone sourcing (unit tests source this file directly).
ZJDEPLOY_STATE_DIR="${ZJDEPLOY_STATE_DIR:-${HOME}/.zjdeploy}"

# One structured run log per execution: every Log* line lands here
# (timestamped) in addition to the console, under ~/.zjdeploy/logs/.
# InitRun picks the per-run file - anything logging before InitRun stays
# console-only.
LogFile() {
    [ -n "${ZJDEPLOY_LOG_FILE:-}" ] || return 0  # logging starts at InitRun
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$ZJDEPLOY_LOG_FILE" 2> /dev/null || true
    chmod 600 "$ZJDEPLOY_LOG_FILE" 2> /dev/null || true
}

LogInfo() {
    printf '[ZJDeploy] %s\n' "$*"
    LogFile "$*"
}

# Detail lines: always recorded in the run log, shown on the console only
# under ZJDEPLOY_LOG_LEVEL=debug.
LogDebug() {
    LogFile "DEBUG: $*"
    if [ "${ZJDEPLOY_LOG_LEVEL:-info}" = "debug" ]; then
        printf '[ZJDeploy] %s\n' "$*"
    fi
}

# RunLogged
# Runs a command with stdout+stderr captured: the console stays clean at
# info level (the full output prints under debug), while the run log
# always gets it indented between begin/end markers with the exit status.
# The command's exit status propagates.
RunLogged() {
    local output status
    output=$( { "$@"; } 2>&1 ) && status=0 || status=$?
    if [ -n "${ZJDEPLOY_LOG_FILE:-}" ]; then
        {
            printf '    ---- begin: %s ----\n' "$*"
            if [ -n "$output" ]; then
                printf '%s\n' "$output" | sed 's/^/    /'
            fi
            printf '    ---- end: %s (exit %s) ----\n' "$*" "$status"
        } >> "$ZJDEPLOY_LOG_FILE" 2> /dev/null || true
    fi
    if [ "${ZJDEPLOY_LOG_LEVEL:-info}" = "debug" ] && [ -n "$output" ]; then
        printf '%s\n' "$output"
    fi
    return "$status"
}

LogWarn() {
    printf '[ZJDeploy] WARNING: %s\n' "$*" >&2
    LogFile "WARNING: $*"
}

Die() {
    printf '[ZJDeploy] ERROR: %s\n' "$*" >&2
    LogFile "ERROR: $*"
    if [ -f "$ZJDEPLOY_STATE_DIR/credentials.txt" ]; then
        printf '[ZJDeploy] NOTE: credentials minted so far are in %s\n' "$ZJDEPLOY_STATE_DIR/credentials.txt" >&2
        LogFile "credentials minted so far are in $ZJDEPLOY_STATE_DIR/credentials.txt"
    fi
    exit 1
}

# LogSeparator
# Full-width separator line for summary blocks; every block that frames a
# report prints these through here instead of inlining the dashes.
LogSeparator() {
    LogInfo "============================================================"
}

HaveCommand() {
    command -v "$1" > /dev/null 2>&1
}

RequireRoot() {
    if [ "$(id -u)" -ne 0 ]; then
        Die "this script must run as root (use sudo)"
    fi
}

# Move an existing file/directory aside instead of destroying it, so a re-run
# never wipes keys or configuration without a recovery path.
BackupPath() {
    local target="$1" backup
    if [ -e "$target" ]; then
        backup="${target}.bak.$(date '+%Y%m%d%H%M%S')"
        mv "$target" "$backup"
        LogInfo "backed up ${target} -> ${backup}"
    fi
}

# RecordCredential
# Append one name=value credential to credentials.txt inside the state
# directory (0600), next to `state` - minted passwords survive a mid-run
# failure. Debian-family platforms only (runs as root); unused on
# DSM/macOS.
RecordCredential() {
    local name="$1" value="$2"
    mkdir -p "$ZJDEPLOY_STATE_DIR"
    printf '%s=%s\n' "$name" "$value" >> "$ZJDEPLOY_STATE_DIR/credentials.txt"
    chmod 600 "$ZJDEPLOY_STATE_DIR/credentials.txt" 2> /dev/null || true
}

# MintRandomPassword
# 16 alphanumeric characters (~95 bits) from /dev/urandom: 16 bytes base64
# encoded, padding and +/ stripped, truncated to 16 (head reads the pipe
# fully fed by head -c, so no SIGPIPE games under pipefail). Same shape as
# the reinstall entry script's password. Linux-only; used when a password
# knob is left empty.
MintRandomPassword() {
    head -c 16 /dev/urandom | base64 | tr -d '=+/' | head -c 16
}

WarnDefaultPassword() {
    local name="$1" value="$2" default_value="$3"
    if [ "$value" = "$default_value" ]; then
        LogWarn "${name} is using the built-in default; change it after deployment or override it with ${name}=<value> before running"
    fi
}

# Under `curl | sudo bash`, whoami is root; SUDO_USER is the real operator.
# Used by DSM/macOS; debian platforms use DEFAULT_USERNAME instead.
GetCurrentUsername() {
    # shellcheck disable=SC2034
    CURRENT_USERNAME="${SUDO_USER:-$(whoami)}"
}

# Detect the package architecture (amd64 | arm64); anything else is fatal.
GetOSArchitecture() {
    if HaveCommand dpkg; then
        OS_ARCHITECTURE=$(dpkg --print-architecture)
    else
        case "$(uname -m)" in
            aarch64) OS_ARCHITECTURE="arm64" ;;
            x86_64) OS_ARCHITECTURE="amd64" ;;
        esac
    fi
    case "${OS_ARCHITECTURE:-}" in
        amd64|arm64) ;;
        *) Die "Unsupported architecture." ;;
    esac
}

SetGHProxyDomain() {
    GHPROXY_URL="${GHPROXY_URL:-}"
    if [ -n "$GHPROXY_URL" ]; then
        # Accept a bare domain (proxy.example.com) or a full URL
        # (https://proxy.example.com[/]); keep any given scheme.
        case "$GHPROXY_URL" in
            *://*) ;;
            *) GHPROXY_URL="https://${GHPROXY_URL}" ;;
        esac
        # Normalize to exactly one trailing slash.
        while [ "$GHPROXY_URL" != "${GHPROXY_URL%/}" ]; do
            GHPROXY_URL="${GHPROXY_URL%/}"
        done
        export GHPROXY_URL="${GHPROXY_URL}/"
    fi
}

## Resume + progress
# Each orchestration step runs through RunStep. A step is recorded in the state
# file only after it succeeds, so an interrupted run resumes at the first
# unfinished step. ZJDEPLOY_FORCE=true clears the state and re-runs everything.
# Platform must set: ZJDEPLOY_STATE_DIR, ZJDEPLOY_STEP_TOTAL.
GetStateFile() {
    printf '%s/state\n' "$ZJDEPLOY_STATE_DIR"
}

StepDone() {
    local state_file
    state_file=$(GetStateFile)
    [ -f "$state_file" ] && grep -qxF "$1" "$state_file"
}

MarkStep() {
    mkdir -p "$ZJDEPLOY_STATE_DIR"
    printf '%s\n' "$1" >> "$(GetStateFile)"
}

StepsCompleted() {
    local state_file
    state_file=$(GetStateFile)
    if [ -f "$state_file" ]; then
        wc -l < "$state_file" | tr -d ' '
    else
        printf '0\n'
    fi
}

RenderProgress() {
    local label="$1" total="${ZJDEPLOY_STEP_TOTAL:-0}" completed width=20 filled percent bar
    completed=$(StepsCompleted)
    if [ "$total" -le 0 ]; then
        LogInfo "$label"
        return 0
    fi
    percent=$((completed * 100 / total))
    filled=$((completed * width / total))
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$((width - filled))" '' | tr ' ' '-')"
    LogInfo "[${bar}] ${completed}/${total} (${percent}%) ${label}"
}

RunStep() {
    local step_id="$1"
    shift
    if [ "${ZJDEPLOY_FORCE:-false}" != "true" ] && StepDone "$step_id"; then
        LogFile "step ${step_id}: skipped (done in a previous run)"
        LogInfo "skip ${step_id} (completed in a previous run)"
        return 0
    fi
    local step_started
    step_started=$(date +%s)
    LogFile "step ${step_id}: running"
    RenderProgress "running ${step_id}"
    "$@"
    MarkStep "$step_id"
    LogFile "step ${step_id}: done ($(( $(date +%s) - step_started ))s)"
}

InitRun() {
    ZJDEPLOY_LOG_FILE="${ZJDEPLOY_STATE_DIR}/logs/$(date -u '+%Y%m%dT%H%M%SZ').log"
    mkdir -p "$ZJDEPLOY_STATE_DIR/logs" 2> /dev/null || true
    chmod 700 "$ZJDEPLOY_STATE_DIR/logs" 2> /dev/null || true
    local completed_count
    completed_count=$(StepsCompleted)
    LogInfo "run log: ${ZJDEPLOY_LOG_FILE}"
    LogFile "===== run started (force=${ZJDEPLOY_FORCE:-false}, ${completed_count}/${ZJDEPLOY_STEP_TOTAL} steps already complete) ====="
    if [ "${ZJDEPLOY_FORCE:-false}" = "true" ]; then
        rm -f "$(GetStateFile)"
        LogInfo "ZJDEPLOY_FORCE=true: re-running all steps"
    elif [ "$completed_count" -gt 0 ]; then
        LogInfo "resuming: ${completed_count}/${ZJDEPLOY_STEP_TOTAL} steps already complete"
    fi
    # Keep the last 10 run logs.
    ls -1t "$ZJDEPLOY_STATE_DIR/logs/" 2> /dev/null | tail -n +11 |
        while IFS= read -r old_log; do
            rm -f "${ZJDEPLOY_STATE_DIR}/logs/${old_log}" 2> /dev/null || true
        done
}

trap 'Die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
