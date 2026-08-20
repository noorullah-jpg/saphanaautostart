#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hana-autostart.sh
#
# Unattended watchdog that keeps a SAP HANA Cloud service instance running on
# Cloud Foundry. SAP HANA Cloud instances auto-stop (e.g. daily / after an
# idle window); this script checks the instance and, if it is stopped, issues
# the CF "start" action so you no longer have to click Start in the cockpit
# every morning.
#
# How HANA Cloud start/stop works on CF:
#   There is no `cf start-service` verb. Start/stop is driven by an
#   update-service parameter payload understood by the HANA broker:
#       stop  -> cf update-service <name> -c '{"data":{"serviceStopped":true}}'
#       start -> cf update-service <name> -c '{"data":{"serviceStopped":false}}'
#   This script sends the START payload and then polls last_operation until it
#   reports success (or times out).
#
# Designed for cron / CI schedulers:
#   - no interactive prompts
#   - all output is timestamped and written to stdout AND (optionally) a log file
#   - non-zero exit on any failure so a scheduler/monitor can alert
#
# Usage:
#   bash scripts/hana-autostart.sh
#   (configure via the variables below or matching environment variables)
#
# Exit codes:
#   0  instance is running (already up, or successfully started)
#   1  configuration / prerequisite error
#   2  CF authentication or targeting failed
#   3  service instance not found
#   4  start issued but instance did not reach running state before timeout
#   5  CF reported the (re)start operation as failed
# ---------------------------------------------------------------------------

set -u
set -o pipefail

# ===========================================================================
# CONFIGURATION  (override any value by exporting the same-named env var)
# ===========================================================================
# CF API endpoint, org and space that own the HANA instance.
CF_API="${CF_API}"
CF_ORG="${CF_ORG}"
CF_SPACE="${CF_SPACE}"

# The HANA Cloud service instance to keep running (as shown by `cf services`).
CF_SERVICE: ${{ secrets.CF_SERVICE }}

# Optional non-interactive login. If BOTH are set the script runs `cf auth`;
# otherwise it assumes an existing, valid CF session/config (e.g. a service
# key, `cf login --sso`, or a warm `~/.cf/config.json`).
#   For automation prefer a technical user or:  CF_USERNAME + CF_PASSWORD
CF_USERNAME="${CF_USERNAME}"
CF_PASSWORD="${CF_PASSWORD}"

# Polling behaviour after issuing the start command.
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"   # wait between status checks
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-1800}"   # give up after this long (30 min)

# Log file. Leave empty to log to stdout only. Directory is created if missing.
LOG_FILE="${LOG_FILE:-}"

# The start payload the HANA broker understands.
START_PAYLOAD='{"data":{"serviceStopped":false}}'

# ===========================================================================
# Logging
# ===========================================================================
log() {
    # Timestamped line to stdout and, if configured, appended to LOG_FILE.
    local ts line
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    line="[$ts] [hana-autostart] $*"
    printf '%s\n' "$line"
    if [ -n "$LOG_FILE" ]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

die() {
    # die <exit_code> <message...>
    local code="$1"; shift
    log "ERROR: $*"
    exit "$code"
}

if [ -n "$LOG_FILE" ]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
fi

# ===========================================================================
# JSON helper — prefer jq, fall back to python3, so this runs on lean images.
# json_get <json-string> <jq-path> <python-accessor>
#   jq-path          e.g.  '.resources[0].guid'
#   python-accessor  e.g.  '["resources"][0]["guid"]'  (appended to the dict `d`)
# Prints the value (empty string if missing/null).
# ===========================================================================
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; fi
HAVE_PY=0
if command -v python3 >/dev/null 2>&1; then HAVE_PY=1; fi

json_get() {
    local json="$1" jq_path="$2" py_path="$3" out=""
    if [ "$HAVE_JQ" -eq 1 ]; then
        out="$(printf '%s' "$json" | jq -r "$jq_path // empty" 2>/dev/null)"
    elif [ "$HAVE_PY" -eq 1 ]; then
        out="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    v = eval("d"+sys.argv[1])
except Exception:
    v = None
print("" if v is None else v)
' "$py_path" 2>/dev/null)"
    fi
    printf '%s' "$out"
}

# ===========================================================================
# Prerequisites
# ===========================================================================
command -v cf >/dev/null 2>&1 || die 1 "cf CLI not found on PATH. Install the Cloud Foundry CLI."
if [ "$HAVE_JQ" -eq 0 ] && [ "$HAVE_PY" -eq 0 ]; then
    die 1 "Neither 'jq' nor 'python3' is available for JSON parsing. Install one."
fi

log "Starting HANA auto-start check."
log "Target: api=$CF_API org='$CF_ORG' space='$CF_SPACE' instance='$SERVICE_INSTANCE'"

# ===========================================================================
# 1. Authenticate / target CF (non-interactive)
# ===========================================================================
cf api "$CF_API" >/dev/null 2>&1 || die 2 "Failed to set CF API endpoint: $CF_API"

if [ -n "$CF_USERNAME" ] && [ -n "$CF_PASSWORD" ]; then
    log "Authenticating to CF as '$CF_USERNAME' (cf auth)."
    cf auth "$CF_USERNAME" "$CF_PASSWORD" >/dev/null 2>&1 \
        || die 2 "cf auth failed for user '$CF_USERNAME'. Check credentials."
else
    # Rely on an existing session. Verify it is still valid.
    if ! cf target >/dev/null 2>&1; then
        die 2 "No CF_USERNAME/CF_PASSWORD provided and no valid existing CF session. \
Log in first (cf login) or set CF_USERNAME and CF_PASSWORD."
    fi
    log "Using existing CF session (no CF_USERNAME/CF_PASSWORD provided)."
fi

cf target -o "$CF_ORG" -s "$CF_SPACE" >/dev/null 2>&1 \
    || die 2 "Failed to target org='$CF_ORG' space='$CF_SPACE'. Check names and entitlements."
log "Targeted org/space successfully."

# ===========================================================================
# 2. Resolve the service instance GUID
# ===========================================================================
SPACE_GUID="$(cf space "$CF_SPACE" --guid 2>/dev/null | tr -d '[:space:]')"
[ -n "$SPACE_GUID" ] || die 3 "Could not resolve GUID for space '$CF_SPACE'."

# URL-encode the instance name for the query (spaces -> %20 etc. are rare here,
# but be safe). Fall back to raw name if we cannot encode.
ENC_NAME="$SERVICE_INSTANCE"
if [ "$HAVE_PY" -eq 1 ]; then
    ENC_NAME="$(printf '%s' "$SERVICE_INSTANCE" | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read()))' 2>/dev/null || printf '%s' "$SERVICE_INSTANCE")"
fi

SI_JSON="$(cf curl "/v3/service_instances?names=${ENC_NAME}&space_guids=${SPACE_GUID}" 2>/dev/null)"
GUID="$(json_get "$SI_JSON" '.resources[0].guid' '["resources"][0]["guid"]')"
[ -n "$GUID" ] || die 3 "Service instance '$SERVICE_INSTANCE' not found in space '$CF_SPACE'."
log "Resolved service instance GUID: $GUID"

# ===========================================================================
# 3. Determine current state
#    - last_operation.state must not be 'in progress' before we act
#    - serviceStopped (from instance parameters) tells us if it is down
# ===========================================================================
read_last_operation() {
    # echoes "<type> <state>" e.g. "update succeeded"
    local j
    j="$(cf curl "/v3/service_instances/${GUID}" 2>/dev/null)"
    local t s
    t="$(json_get "$j" '.last_operation.type'  '["last_operation"]["type"]')"
    s="$(json_get "$j" '.last_operation.state' '["last_operation"]["state"]')"
    printf '%s %s' "${t:-unknown}" "${s:-unknown}"
}

# serviceStopped: true (down) / false (up) / "" (unknown — broker may not
# expose parameters; in that case we act conservatively and issue start).
read_service_stopped() {
    local j
    j="$(cf curl "/v3/service_instances/${GUID}/parameters" 2>/dev/null)"
    json_get "$j" '.data.serviceStopped' '["data"]["serviceStopped"]'
}

LAST_OP="$(read_last_operation)"
log "Current last_operation: $LAST_OP"
case "$LAST_OP" in
    *"in progress"*)
        log "An operation is already in progress; will poll for completion instead of issuing a new start."
        ;;
esac

STOPPED="$(read_service_stopped)"
log "Reported serviceStopped: '${STOPPED:-unknown}'"

NEEDS_START=0
case "$STOPPED" in
    true|True|TRUE|1)
        NEEDS_START=1
        log "Instance is STOPPED. A start is required." ;;
    false|False|FALSE|0)
        # Already running; but if a previous op failed, a start still helps.
        case "$LAST_OP" in
            *failed*) NEEDS_START=1; log "Instance reports running but last operation FAILED; re-issuing start." ;;
            *)        log "Instance is already RUNNING. Nothing to do." ;;
        esac ;;
    *)
        # Unknown (parameters not exposed). Only start if not already busy.
        case "$LAST_OP" in
            *"in progress"*) log "State unknown and an operation is in progress; will just poll." ;;
            *) NEEDS_START=1; log "State could not be confirmed; conservatively issuing start (no-op if already up)." ;;
        esac ;;
esac

# ===========================================================================
# 4. Issue the start command if needed
# ===========================================================================
if [ "$NEEDS_START" -eq 1 ]; then
    log "Issuing start: cf update-service '$SERVICE_INSTANCE' -c '$START_PAYLOAD'"
    if ! cf update-service "$SERVICE_INSTANCE" -c "$START_PAYLOAD" >/dev/null 2>&1; then
        die 5 "cf update-service (start) command was rejected. Check plan/permissions/payload."
    fi
    log "Start command accepted; the broker will process it asynchronously."
fi

# ===========================================================================
# 5. Poll until running (or timeout)
# ===========================================================================
deadline=$(( $(date +%s) + POLL_TIMEOUT_SECONDS ))
log "Polling for running state (interval=${POLL_INTERVAL_SECONDS}s, timeout=${POLL_TIMEOUT_SECONDS}s)."

while :; do
    LAST_OP="$(read_last_operation)"
    STOPPED="$(read_service_stopped)"
    now=$(date +%s)

    # Success: last operation succeeded AND (serviceStopped is false or unknown).
    if printf '%s' "$LAST_OP" | grep -q 'succeeded'; then
        case "$STOPPED" in
            true|True|TRUE|1)
                log "Operation succeeded but instance still reports stopped; continuing to poll." ;;
            *)
                log "SUCCESS: instance '$SERVICE_INSTANCE' is running (last_operation: $LAST_OP)."
                exit 0 ;;
        esac
    fi

    if printf '%s' "$LAST_OP" | grep -q 'failed'; then
        die 5 "The (re)start operation FAILED (last_operation: $LAST_OP)."
    fi

    if [ "$now" -ge "$deadline" ]; then
        die 4 "Timed out after ${POLL_TIMEOUT_SECONDS}s waiting for '$SERVICE_INSTANCE' to reach running state (last_operation: $LAST_OP, serviceStopped: '${STOPPED:-unknown}')."
    fi

    log "Still working (last_operation: $LAST_OP). Sleeping ${POLL_INTERVAL_SECONDS}s..."
    sleep "$POLL_INTERVAL_SECONDS"
done
