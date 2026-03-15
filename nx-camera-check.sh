#!/usr/bin/env bash
# nx-camera-check.sh — Check Nx Witness v6.1 camera recording settings
# Dependencies: curl, bash (no jq required)

set -euo pipefail

BASE_URL="https://localhost:7001"

# ── Colour codes ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
AMBER='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Argument parsing ──────────────────────────────────────────────────────────
NX_USER=""
NX_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nx-user) NX_USER="$2"; shift 2 ;;
        --nx-pass) NX_PASS="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--nx-user USERNAME] [--nx-pass PASSWORD]"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$NX_USER" ]]; then
    read -rp "Nx Witness username: " NX_USER
fi
if [[ -z "$NX_PASS" ]]; then
    read -rsp "Nx Witness password: " NX_PASS
    echo
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# Print a labelled status line with colour
status_line() {
    local label="$1"
    local colour="$2"
    local value="$3"
    local tag
    case "$colour" in
        GREEN) tag="${GREEN}[OK]${RESET}" ;;
        AMBER) tag="${AMBER}[WARN]${RESET}" ;;
        RED)   tag="${RED}[FAIL]${RESET}" ;;
        *)     tag="[????]" ;;
    esac
    printf "  %-14s %s %s\n" "${label}:" "$tag" "$value"
}

# Extract first value for a JSON key from a string (no jq)
# Works on single-line or compact JSON
extract() {
    local json="$1"
    local key="$2"
    # Match "key": "value"  or  "key": 123  or  "key": true/false
    echo "$json" | grep -oP "\"${key}\"\s*:\s*\K(\"[^\"]*\"|[^,\}\]\s]+)" | head -1 | tr -d '"'
}

# Extract a block between the Nth occurrence of a pattern (used for scheduleTasks)
# Returns the content between balanced braces for each task object
extract_schedule_tasks() {
    local json="$1"
    # Pull everything inside "scheduleTasks": [ ... ]
    echo "$json" | grep -oP '"scheduleTasks"\s*:\s*\[\K[^\]]*'
}

# From a scheduleTasks array string, get the "most active" recordingType:
#   always > motionOnly > never
# Also pull fps and bitrateKbps from the first task that isn't "never"
parse_schedule() {
    local tasks_json="$1"
    local best_type="never"
    local best_fps=0
    local best_bitrate=0

    # Split into individual objects by splitting on "},{"
    local IFS_ORIG="$IFS"
    # Use awk to split task objects
    local task
    while IFS= read -r task; do
        [[ -z "$task" ]] && continue
        local rtype fps bitrate
        rtype=$(extract "$task" "recordingType")
        fps=$(extract "$task" "fps")
        bitrate=$(extract "$task" "bitrateKbps")
        fps=${fps:-0}
        bitrate=${bitrate:-0}

        # Priority: always > motionOnly > never
        if [[ "$rtype" == "always" ]]; then
            best_type="always"
            best_fps="$fps"
            best_bitrate="$bitrate"
            break  # can't do better
        elif [[ "$rtype" == "motionOnly" && "$best_type" == "never" ]]; then
            best_type="motionOnly"
            best_fps="$fps"
            best_bitrate="$bitrate"
        fi
    done < <(echo "$tasks_json" | awk 'BEGIN{RS="\\},\\s*\\{"} {print "{" $0 "}"}' | sed 's/^\s*{\s*{/{/' | sed 's/}\s*}\s*$/}/')

    IFS="$IFS_ORIG"
    echo "${best_type}|${best_fps}|${best_bitrate}"
}

# ── Login — obtain bearer token ───────────────────────────────────────────────
echo -e "${BOLD}Connecting to Nx Witness at ${BASE_URL}…${RESET}"

LOGIN_RESPONSE=$(curl -sk -w "\n__STATUS__%{http_code}" \
    -X POST "${BASE_URL}/rest/v3/login/sessions" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${NX_USER}\",\"password\":\"${NX_PASS}\"}") || {
    echo -e "${RED}ERROR: curl failed — is the server reachable?${RESET}" >&2
    exit 1
}

LOGIN_BODY=$(echo "$LOGIN_RESPONSE" | sed -n '/^__STATUS__/!p')
LOGIN_CODE=$(echo "$LOGIN_RESPONSE" | grep -oP '(?<=__STATUS__)\d+')

if [[ "$LOGIN_CODE" != "200" ]]; then
    echo -e "${RED}ERROR: Login failed (HTTP ${LOGIN_CODE}). Check credentials.${RESET}" >&2
    exit 1
fi

NX_TOKEN=$(extract "$LOGIN_BODY" "token")
if [[ -z "$NX_TOKEN" ]]; then
    echo -e "${RED}ERROR: Login succeeded but no token found in response.${RESET}" >&2
    exit 1
fi

# ── Fetch devices ─────────────────────────────────────────────────────────────
HTTP_RESPONSE=$(curl -sk -w "\n__STATUS__%{http_code}" \
    -H "Authorization: Bearer ${NX_TOKEN}" \
    "${BASE_URL}/rest/v3/devices") || {
    echo -e "${RED}ERROR: curl failed — is the server reachable?${RESET}" >&2
    exit 1
}

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -n '/^__STATUS__/!p')
HTTP_CODE=$(echo "$HTTP_RESPONSE" | grep -oP '(?<=__STATUS__)\d+')

if [[ "$HTTP_CODE" == "401" ]]; then
    echo -e "${RED}ERROR: Authentication failed (401). Token may have expired.${RESET}" >&2
    exit 1
elif [[ "$HTTP_CODE" != "200" ]]; then
    echo -e "${RED}ERROR: Unexpected HTTP ${HTTP_CODE} from API.${RESET}" >&2
    exit 1
fi

# ── Parse device list ─────────────────────────────────────────────────────────
# The response is a JSON array of device objects.
# Split on top-level object boundaries — each device starts with {"id":
# We use awk to split the array into one device JSON blob per line.

DEVICES_RAW=$(echo "$HTTP_BODY" | \
    awk 'BEGIN{RS="\\},\\s*\\{";ORS="\n"} {gsub(/^\s*\[?\s*\{/,"{",$0); gsub(/\}\s*\]?\s*$/,"}",$0); print}')

DEVICE_COUNT=$(echo "$DEVICES_RAW" | grep -c '"id"') || true

if [[ "$DEVICE_COUNT" -eq 0 ]]; then
    echo -e "${AMBER}No cameras found in the response.${RESET}"
    exit 0
fi

echo -e "${BOLD}Found ${DEVICE_COUNT} device(s).${RESET}\n"

# ── Process each device ───────────────────────────────────────────────────────
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

while IFS= read -r device_json; do
    [[ -z "$device_json" ]] && continue
    # Skip entries that don't look like a camera device
    [[ "$device_json" != *'"id"'* ]] && continue

    # Basic fields
    cam_name=$(extract "$device_json" "name")
    cam_ip=$(extract "$device_json" "url")
    # url is typically rtsp://ip/... — extract just the host
    cam_ip=$(echo "$cam_ip" | grep -oP '(?<=://)[^/:]+' || echo "$cam_ip")
    [[ -z "$cam_ip" ]] && cam_ip=$(extract "$device_json" "physicalId")
    [[ -z "$cam_name" ]] && cam_name="(unknown)"
    [[ -z "$cam_ip" ]] && cam_ip="(unknown)"

    # Resolution — look for "resolution" key (e.g. "1920x1080")
    resolution=$(extract "$device_json" "resolution")
    # Also try resolutionList — take the first entry
    if [[ -z "$resolution" ]]; then
        resolution=$(echo "$device_json" | grep -oP '"resolutionList"\s*:\s*\[\s*"\K[^"]+' | head -1)
    fi
    res_width=0
    if [[ "$resolution" =~ ^([0-9]+)[xX×]([0-9]+)$ ]]; then
        res_width="${BASH_REMATCH[1]}"
    fi

    # Codec
    codec=$(extract "$device_json" "codec")
    [[ -z "$codec" ]] && codec=$(extract "$device_json" "streamCodec")
    [[ -z "$codec" ]] && codec="unknown"

    # scheduleEnabled
    sched_enabled=$(extract "$device_json" "scheduleEnabled")

    # scheduleTasks
    tasks_raw=$(extract_schedule_tasks "$device_json")
    sched_info="never|0|0"
    if [[ -n "$tasks_raw" ]]; then
        sched_info=$(parse_schedule "$tasks_raw")
    fi
    rec_type=$(echo "$sched_info" | cut -d'|' -f1)
    fps=$(echo "$sched_info" | cut -d'|' -f2)
    bitrate=$(echo "$sched_info" | cut -d'|' -f3)

    # ── Print header ──────────────────────────────────────────────────────────
    echo -e "${BOLD}=== Camera: ${cam_name} (${cam_ip}) ===${RESET}"

    cam_fail=0
    cam_warn=0

    # Recording enabled
    if [[ "$sched_enabled" == "true" ]]; then
        status_line "Recording" "GREEN" "YES"
    else
        status_line "Recording" "RED" "NO  (schedule disabled)"
        cam_fail=1
    fi

    # Recording mode
    case "$rec_type" in
        always)
            status_line "Mode" "GREEN" "Continuous" ;;
        motionOnly)
            status_line "Mode" "AMBER" "Motion Only"
            cam_warn=1 ;;
        never|*)
            status_line "Mode" "RED" "Off"
            cam_fail=1 ;;
    esac

    # FPS
    if [[ "$fps" -ge 15 ]] 2>/dev/null; then
        status_line "FPS" "GREEN" "${fps} fps"
    elif [[ "$fps" -ge 10 ]] 2>/dev/null; then
        status_line "FPS" "AMBER" "${fps} fps  (<15)"
        cam_warn=1
    else
        status_line "FPS" "RED" "${fps} fps  (<10)"
        cam_fail=1
    fi

    # Resolution
    if [[ "$res_width" -ge 1920 ]] 2>/dev/null; then
        status_line "Resolution" "GREEN" "${resolution}"
    elif [[ "$res_width" -gt 0 ]] 2>/dev/null; then
        status_line "Resolution" "AMBER" "${resolution}  (<1080p)"
        cam_warn=1
    else
        status_line "Resolution" "AMBER" "${resolution:-unknown}  (could not parse)"
        cam_warn=1
    fi

    # Codec
    codec_upper=$(echo "$codec" | tr '[:lower:]' '[:upper:]')
    if [[ "$codec_upper" == *"H264"* || "$codec_upper" == *"H.264"* || \
          "$codec_upper" == *"H265"* || "$codec_upper" == *"H.265"* || \
          "$codec_upper" == *"HEVC"* || "$codec_upper" == *"AVC"* ]]; then
        status_line "Codec" "GREEN" "$codec"
    else
        status_line "Codec" "AMBER" "${codec}  (not H.264/H.265)"
        cam_warn=1
    fi

    # Bitrate
    if [[ "$bitrate" -gt 4096 ]] 2>/dev/null; then
        status_line "Bitrate" "AMBER" "${bitrate} kbps  (>4096)"
        cam_warn=1
    elif [[ "$bitrate" -gt 0 ]] 2>/dev/null; then
        status_line "Bitrate" "GREEN" "${bitrate} kbps"
    else
        status_line "Bitrate" "AMBER" "unknown"
        cam_warn=1
    fi

    # Tally
    if [[ "$cam_fail" -gt 0 ]]; then
        (( FAIL_COUNT++ )) || true
    elif [[ "$cam_warn" -gt 0 ]]; then
        (( WARN_COUNT++ )) || true
    else
        (( PASS_COUNT++ )) || true
    fi

    echo

done <<< "$DEVICES_RAW"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}────────────────────────────────────────${RESET}"
echo -e "${BOLD}Summary:${RESET}"
echo -e "  ${GREEN}OK   ${RESET}: ${PASS_COUNT} camera(s)"
echo -e "  ${AMBER}WARN ${RESET}: ${WARN_COUNT} camera(s)"
echo -e "  ${RED}FAIL ${RESET}: ${FAIL_COUNT} camera(s)"
echo -e "${BOLD}────────────────────────────────────────${RESET}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 2
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
