#!/usr/bin/env bash
# nx-camera-check.sh — Check Nx Witness v6.1 camera recording settings
# Dependencies: curl, python3, bash (no jq required)

set -euo pipefail
set +H  # Disable history expansion so ! in passwords is safe

BASE_URL="https://localhost:7001"

# ── Colour codes ──────────────────────────────────────────────────────────────
GREEN=$'\033[0;32m'
AMBER=$'\033[0;33m'
RED=$'\033[0;31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

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

# Split a JSON array of objects (by },{) and return the value of target_key
# from the first object where match_key == match_val.
# Usage: extract_stream_field array_json match_key match_val target_key
extract_stream_field() {
    local array_json="$1"
    local match_key="$2"
    local match_val="$3"
    local target_key="$4"
    local obj
    while IFS= read -r obj; do
        [[ -z "$obj" ]] && continue
        local val
        val=$(extract "$obj" "$match_key")
        if [[ "$val" == "$match_val" ]]; then
            extract "$obj" "$target_key"
            return
        fi
    done < <(echo "$array_json" | awk 'BEGIN{RS="\\},\\s*\\{"} {print "{" $0 "}"}' \
        | sed 's/^\s*{\s*{/{/' | sed 's/}\s*}\s*$/}/')
}

# Map a raw codec value (numeric ID or string) to a human label
map_codec() {
    local raw="$1"
    case "$raw" in
        173|H264|AVC)  echo "H.264" ;;
        174|H265|HEVC) echo "H.265" ;;
        0)             echo "transcoded/unknown" ;;
        *)             [[ -n "$raw" ]] && echo "unknown (${raw})" || echo "unknown" ;;
    esac
}

# From a schedule.tasks array, use dayOfWeek=1 as the canonical day
# (all days share the same settings). Returns: type|fps|bitrateKbps|streamQuality
parse_schedule() {
    local tasks_json="$1"
    local rec_type="never"
    local rec_fps=0
    local rec_bitrate=0
    local rec_quality="unknown"

    local task
    while IFS= read -r task; do
        [[ -z "$task" ]] && continue
        local dow
        dow=$(extract "$task" "dayOfWeek")
        [[ "$dow" != "1" ]] && continue
        rec_type=$(extract "$task" "recordingType")
        rec_fps=$(extract "$task" "fps")
        rec_bitrate=$(extract "$task" "bitrateKbps")
        rec_quality=$(extract "$task" "streamQuality")
        rec_fps=${rec_fps:-0}
        rec_bitrate=${rec_bitrate:-0}
        rec_quality=${rec_quality:-unknown}
        break
    done < <(echo "$tasks_json" | awk 'BEGIN{RS="\\},\\s*\\{"} {print "{" $0 "}"}' \
        | sed 's/^\s*{\s*{/{/' | sed 's/}\s*}\s*$/}/')

    echo "${rec_type}|${rec_fps}|${rec_bitrate}|${rec_quality}"
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

# ── Extract camera IDs from device list ───────────────────────────────────────
# Use python3 to reliably parse the JSON array (objects are too large/nested
# for awk-based splitting). We only need the id field from Camera entries.

if ! command -v python3 &>/dev/null; then
    echo -e "${RED}ERROR: python3 is required for JSON parsing.${RESET}" >&2
    exit 1
fi

CAMERA_IDS=$(echo "$HTTP_BODY" | python3 -c "
import json, sys
try:
    devices = json.load(sys.stdin)
    for d in devices:
        if d.get('deviceType') == 'Camera':
            print(d['id'])
except Exception as e:
    sys.stderr.write('JSON parse error: ' + str(e) + '\n')
    sys.exit(1)
") || {
    echo -e "${RED}ERROR: Failed to parse device list JSON.${RESET}" >&2
    exit 1
}

DEVICE_COUNT=$(echo "$CAMERA_IDS" | grep -c '.') || true

if [[ "$DEVICE_COUNT" -eq 0 ]]; then
    echo -e "${AMBER}No cameras found in the response.${RESET}"
    exit 0
fi

echo -e "${BOLD}Found ${DEVICE_COUNT} camera(s).${RESET}\n"

# ── Process each camera via individual API call ────────────────────────────────
# Fetching /rest/v3/devices/{id} returns a single device object which is
# reliable to parse — collapse to one line then apply targeted grep patterns.
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

while IFS= read -r cam_id; do
    [[ -z "$cam_id" ]] && continue

    DEV_RESPONSE=$(curl -sk -w "\n__STATUS__%{http_code}" \
        -H "Authorization: Bearer ${NX_TOKEN}" \
        "${BASE_URL}/rest/v3/devices/${cam_id}") || {
        echo -e "${AMBER}WARNING: curl failed for device ${cam_id}, skipping.${RESET}" >&2
        continue
    }

    DEV_BODY=$(echo "$DEV_RESPONSE" | sed -n '/^__STATUS__/!p')
    DEV_CODE=$(echo "$DEV_RESPONSE" | grep -oP '(?<=__STATUS__)\d+')

    if [[ "$DEV_CODE" != "200" ]]; then
        echo -e "${AMBER}WARNING: HTTP ${DEV_CODE} for device ${cam_id}, skipping.${RESET}" >&2
        continue
    fi

    # Collapse to a single line so all grep patterns work regardless of formatting
    device_json=$(echo "$DEV_BODY" | tr -d '\n' | tr -s ' ')

    # Basic fields
    cam_name=$(extract "$device_json" "name")
    cam_ip=$(extract "$device_json" "url")
    # url is typically rtsp://ip/... — extract just the host
    cam_ip=$(echo "$cam_ip" | grep -oP '(?<=://)[^/:]+' || echo "$cam_ip")
    [[ -z "$cam_ip" ]] && cam_ip=$(extract "$device_json" "physicalId")
    [[ -z "$cam_name" ]] && cam_name="(unknown)"
    [[ -z "$cam_ip" ]] && cam_ip="(unknown)"

    # schedule.isEnabled
    sched_enabled=$(echo "$device_json" | grep -oP '"isEnabled"\s*:\s*\K(true|false)' | head -1)

    # schedule.tasks — extract array content, parse day 1
    tasks_raw=$(echo "$device_json" | grep -oP '"tasks"\s*:\s*\[\K[^\]]*' | head -1)
    sched_info="never|0|0|unknown"
    if [[ -n "$tasks_raw" ]]; then
        sched_info=$(parse_schedule "$tasks_raw")
    fi
    rec_type=$(echo "$sched_info" | cut -d'|' -f1)
    fps=$(echo "$sched_info"      | cut -d'|' -f2)
    bitrate=$(echo "$sched_info"  | cut -d'|' -f3)
    quality=$(echo "$sched_info"  | cut -d'|' -f4)

    # Resolution and codec — mediaStreams where encoderIndex=0 (primary recorded stream)
    media_streams_raw=$(echo "$device_json" | grep -oP '"mediaStreams"\s*:\s*\[\K[^\]]*' | head -1)
    resolution=$(extract_stream_field "$media_streams_raw" "encoderIndex" "0" "resolution")
    codec_raw=$(extract_stream_field "$media_streams_raw" "encoderIndex" "0" "codec")
    codec=$(map_codec "$codec_raw")
    res_width=0
    if [[ "$resolution" =~ ^([0-9]+)[xX×]([0-9]+)$ ]]; then
        res_width="${BASH_REMATCH[1]}"
    fi

    # Actual bitrate — parameters.bitrateInfos.streams where encoderIndex=primary (Mbps)
    streams_raw=$(echo "$device_json" | grep -oP '"streams"\s*:\s*\[\K[^\]]*' | head -1)
    actual_bitrate_mbps=$(extract_stream_field "$streams_raw" "encoderIndex" "primary" "actualBitrate")

    # Effective bitrate for threshold comparison:
    #   bitrateKbps=0 means NX is managing bitrate automatically — show actual current value
    if [[ "$bitrate" -gt 0 ]] 2>/dev/null; then
        bitrate_kbps="$bitrate"
        bitrate_label="${bitrate} kbps"
    elif [[ -n "$actual_bitrate_mbps" && "$actual_bitrate_mbps" != "0" ]]; then
        bitrate_kbps=$(awk "BEGIN {printf \"%d\", ${actual_bitrate_mbps} * 1024}")
        bitrate_label="${actual_bitrate_mbps} Mbps  (actual)"
    else
        bitrate_kbps=0
        bitrate_label="unknown"
    fi

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
    case "$codec" in
        H.264|H.265)
            status_line "Codec" "GREEN" "$codec" ;;
        *)
            status_line "Codec" "AMBER" "${codec}  (not H.264/H.265)"
            cam_warn=1 ;;
    esac

    # Stream quality
    case "$quality" in
        highest|high)
            status_line "Quality" "GREEN" "$quality" ;;
        medium)
            status_line "Quality" "AMBER" "$quality"
            cam_warn=1 ;;
        low)
            status_line "Quality" "RED" "low"
            cam_fail=1 ;;
        *)
            status_line "Quality" "AMBER" "${quality:-unknown}"
            cam_warn=1 ;;
    esac

    # Bitrate
    if [[ "$bitrate_kbps" -gt 4096 ]] 2>/dev/null; then
        status_line "Bitrate" "AMBER" "${bitrate_label}  (>4096 kbps)"
        cam_warn=1
    elif [[ "$bitrate_kbps" -gt 0 ]] 2>/dev/null; then
        status_line "Bitrate" "GREEN" "${bitrate_label}"
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

done <<< "$CAMERA_IDS"

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
