#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hana-autostart.sh
#
# HANA Cloud watchdog for Cloud Foundry.
#
# Behavior:
#   - If HANA is running, exit successfully.
#   - If HANA is stopped, issue a start command.
#   - Wait up to 3 minutes for the start operation to complete.
#   - If the start operation succeeds, exit successfully.
#   - If the operation fails or times out, exit with an error.
#
# Designed for GitHub Actions / cron / CI schedulers.
#
# Exit codes:
#   0  HANA is running or start operation succeeded
#   1  Configuration / prerequisite error
#   2  CF authentication or targeting failed
#   3  Service instance not found
#   4  Start operation timed out
#   5  CF reported the start operation as failed
# ---------------------------------------------------------------------------

set -u
set -o pipefail

# ===========================================================================
# CONFIGURATION
# ===========================================================================

CF_API="${CF_API:-}"
CF_ORG="${CF_ORG:-}"
CF_SPACE="${CF_SPACE:-}"

# HANA Cloud service instance name
CF_SERVICE="${CF_SERVICE:-}"

# Cloud Foundry credentials
CF_USERNAME="${CF_USERNAME:-}"
CF_PASSWORD="${CF_PASSWORD:-}"

# Check every 30 seconds after issuing a start command.
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"

# Maximum 3 minutes waiting for the start operation.
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-180}"

# Optional log file.
LOG_FILE="${LOG_FILE:-}"

# HANA Cloud start payload.
START_PAYLOAD='{"data":{"serviceStopped":false}}'

# ===========================================================================
# LOGGING
# ===========================================================================

log() {
    local ts line

    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    line="[$ts] [hana-autostart] $*"

    printf '%s\n' "$line"

    if [ -n "$LOG_FILE" ]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

die() {
    local code="$1"
    shift

    log "ERROR: $*"
    exit "$code"
}

if [ -n "$LOG_FILE" ]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
fi

# ===========================================================================
# JSON HELPER
# ===========================================================================

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
    HAVE_JQ=1
fi

HAVE_PY=0
if command -v python3 >/dev/null 2>&1; then
    HAVE_PY=1
fi

json_get() {
    local json="$1"
    local jq_path="$2"
    local py_path="$3"
    local out=""

    if [ "$HAVE_JQ" -eq 1 ]; then

        out="$(printf '%s' "$json" | jq -r "$jq_path // empty" 2>/dev/null)"

    elif [ "$HAVE_PY" -eq 1 ]; then

        out="$(printf '%s' "$json" | python3 -c '
import sys
import json

try:
    d = json.load(sys.stdin)
    v = eval("d" + sys.argv[1])
except Exception:
    v = None

print("" if v is None else v)
' "$py_path" 2>/dev/null)"

    fi

    printf '%s' "$out"
}

# ===========================================================================
# PREREQUISITES
# ===========================================================================

command -v cf >/dev/null 2>&1 \
    || die 1 "cf CLI not found on PATH. Install the Cloud Foundry CLI."

if [ "$HAVE_JQ" -eq 0 ] && [ "$HAVE_PY" -eq 0 ]; then
    die 1 "Neither jq nor python3 is available for JSON parsing."
fi

# ===========================================================================
# CONFIGURATION VALIDATION
# ===========================================================================

[ -n "$CF_API" ] \
    || die 1 "CF_API is not set."

[ -n "$CF_ORG" ] \
    || die 1 "CF_ORG is not set."

[ -n "$CF_SPACE" ] \
    || die 1 "CF_SPACE is not set."

[ -n "$CF_SERVICE" ] \
    || die 1 "CF_SERVICE is not set."

[ -n "$CF_USERNAME" ] \
    || die 1 "CF_USERNAME is not set."

[ -n "$CF_PASSWORD" ] \
    || die 1 "CF_PASSWORD is not set."

log "Starting HANA auto-start check."
log "Target: api=$CF_API org='$CF_ORG' space='$CF_SPACE' instance='$CF_SERVICE'"

# ===========================================================================
# 1. CLOUD FOUNDRY LOGIN
# ===========================================================================

cf api "$CF_API" >/dev/null 2>&1 \
    || die 2 "Failed to set CF API endpoint: $CF_API"

log "Authenticating to CF as '$CF_USERNAME'."

cf auth "$CF_USERNAME" "$CF_PASSWORD" >/dev/null 2>&1 \
    || die 2 "cf auth failed for user '$CF_USERNAME'. Check credentials."

# ===========================================================================
# 2. TARGET ORG / SPACE
# ===========================================================================

cf target -o "$CF_ORG" -s "$CF_SPACE" >/dev/null 2>&1 \
    || die 2 "Failed to target org='$CF_ORG' space='$CF_SPACE'. Check names and entitlements."

log "Targeted org/space successfully."

# ===========================================================================
# 3. RESOLVE SERVICE INSTANCE GUID
# ===========================================================================

SPACE_GUID="$(
    cf space "$CF_SPACE" --guid 2>/dev/null \
        | tr -d '[:space:]'
)"

[ -n "$SPACE_GUID" ] \
    || die 3 "Could not resolve GUID for space '$CF_SPACE'."

ENC_NAME="$CF_SERVICE"

if [ "$HAVE_PY" -eq 1 ]; then

    ENC_NAME="$(
        printf '%s' "$CF_SERVICE" |
        python3 -c '
import sys
import urllib.parse
print(urllib.parse.quote(sys.stdin.read()))
' 2>/dev/null ||
        printf '%s' "$CF_SERVICE"
    )"

fi

SI_JSON="$(
    cf curl "/v3/service_instances?names=${ENC_NAME}&space_guids=${SPACE_GUID}" \
        2>/dev/null
)"

GUID="$(
    json_get \
        "$SI_JSON" \
        '.resources[0].guid' \
        '["resources"][0]["guid"]'
)"

[ -n "$GUID" ] \
    || die 3 "Service instance '$CF_SERVICE' not found in space '$CF_SPACE'."

log "Resolved service instance GUID: $GUID"

# ===========================================================================
# 4. READ LAST OPERATION
# ===========================================================================

read_last_operation() {

    local j
    local t
    local s

    j="$(
        cf curl "/v3/service_instances/${GUID}" 2>/dev/null
    )"

    t="$(
        json_get \
            "$j" \
            '.last_operation.type' \
            '["last_operation"]["type"]'
    )"

    s="$(
        json_get \
            "$j" \
            '.last_operation.state' \
            '["last_operation"]["state"]'
    )"

    printf '%s %s' "${t:-unknown}" "${s:-unknown}"
}

# ===========================================================================
# 5. READ HANA STOPPED STATE
# ===========================================================================

read_service_stopped() {

    local j

    j="$(
        cf curl "/v3/service_instances/${GUID}/parameters" \
            2>/dev/null
    )"

    json_get \
        "$j" \
        '.data.serviceStopped' \
        '["data"]["serviceStopped"]'
}

# ===========================================================================
# 6. CHECK CURRENT HANA STATE
# ===========================================================================

LAST_OP="$(read_last_operation)"

log "Current last_operation: $LAST_OP"

STOPPED="$(read_service_stopped)"

log "Reported serviceStopped: '${STOPPED:-unknown}'"

# ===========================================================================
# 7. IF HANA IS ALREADY RUNNING, EXIT
# ===========================================================================

case "$STOPPED" in

    false|False|FALSE|0)

        log "SUCCESS: HANA instance '$CF_SERVICE' is already RUNNING."
        exit 0
        ;;

    true|True|TRUE|1)

        log "Instance is STOPPED. A start is required."
        ;;

    *)

        log "WARNING: HANA state could not be determined."
        log "State returned: '${STOPPED:-unknown}'"
        log "Conservatively attempting a start."
        ;;

esac

# ===========================================================================
# 8. ISSUE HANA START COMMAND
# ===========================================================================

log "Issuing start: cf update-service '$CF_SERVICE' -c '$START_PAYLOAD'"

if ! cf update-service \
    "$CF_SERVICE" \
    -c "$START_PAYLOAD" \
    >/dev/null 2>&1
then

    die 5 "cf update-service start command was rejected."

fi

log "Start command accepted."
log "Waiting up to ${POLL_TIMEOUT_SECONDS} seconds for the operation to complete."

# ===========================================================================
# 9. POLL START OPERATION FOR MAXIMUM 3 MINUTES
# ===========================================================================

deadline=$(
    (
        date +%s
    ) + POLL_TIMEOUT_SECONDS
)

while :; do

    LAST_OP="$(read_last_operation)"

    now="$(date +%s)"

    log "Current last_operation: $LAST_OP"

    # -----------------------------------------------------------------------
    # Start operation succeeded
    # -----------------------------------------------------------------------

    if printf '%s' "$LAST_OP" | grep -q 'succeeded'; then

        log "SUCCESS: HANA start operation completed successfully."
        exit 0

    fi

    # -----------------------------------------------------------------------
    # Start operation failed
    # -----------------------------------------------------------------------

    if printf '%s' "$LAST_OP" | grep -q 'failed'; then

        die 5 \
            "HANA start operation FAILED (last_operation: $LAST_OP)."

    fi

    # -----------------------------------------------------------------------
    # Timeout
    # -----------------------------------------------------------------------

    if [ "$now" -ge "$deadline" ]; then

        die 4 \
            "Timed out after ${POLL_TIMEOUT_SECONDS}s waiting for HANA '$CF_SERVICE' to start (last_operation: $LAST_OP)."

    fi

    # -----------------------------------------------------------------------
    # Wait before next check
    # -----------------------------------------------------------------------

    log "HANA start still in progress. Sleeping ${POLL_INTERVAL_SECONDS}s..."

    sleep "$POLL_INTERVAL_SECONDS"

done
