#!/usr/bin/env bash
# nx-camera-check.sh — Check Nx Witness v6.1 camera recording settings
# Dependencies: curl, python3, bash (no jq required)

set -euo pipefail
set +H  # Disable history expansion so ! in passwords is safe

BASE_URL="https://localhost:7001"

# ── Colour codes ──────────────────────────────────────────────────────────────
GREEN=$'\e[0;32m'
AMBER=$'\e[0;33m'
RED=$'\e[0;31m'
BOLD=$'\e[1m'
RESET=$'\e[0m'

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
        GREEN) tag="${GREEN}[OK]${RESET}"   ;;
        AMBER) tag="${AMBER}[WARN]${RESET}" ;;
        RED)   tag="${RED}[FAIL]${RESET}"   ;;
        INFO)  tag="[INFO]"                 ;;
        *)     tag="[????]"                 ;;
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
        27|173|H264|AVC)   echo "H.264" ;;
        174|265|H265|HEVC) echo "H.265" ;;
        0)                 echo "transcoded/unknown" ;;
        *)                 [[ -n "$raw" ]] && echo "unknown (${raw})" || echo "unknown" ;;
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
printf "%s\n" "${BOLD}Connecting to Nx Witness at ${BASE_URL}…${RESET}"

LOGIN_RESPONSE=$(curl -sk -w "\n__STATUS__%{http_code}" \
    -X POST "${BASE_URL}/rest/v3/login/sessions" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${NX_USER}\",\"password\":\"${NX_PASS}\"}") || {
    printf "%s\n" "${RED}ERROR: curl failed — is the server reachable?${RESET}" >&2
    exit 1
}

LOGIN_BODY=$(echo "$LOGIN_RESPONSE" | sed -n '/^__STATUS__/!p')
LOGIN_CODE=$(echo "$LOGIN_RESPONSE" | grep -oP '(?<=__STATUS__)\d+')

if [[ "$LOGIN_CODE" != "200" ]]; then
    printf "%s\n" "${RED}ERROR: Login failed (HTTP ${LOGIN_CODE}). Check credentials.${RESET}" >&2
    exit 1
fi

NX_TOKEN=$(extract "$LOGIN_BODY" "token")
if [[ -z "$NX_TOKEN" ]]; then
    printf "%s\n" "${RED}ERROR: Login succeeded but no token found in response.${RESET}" >&2
    exit 1
fi

# ── Fetch devices ─────────────────────────────────────────────────────────────
HTTP_RESPONSE=$(curl -sk -w "\n__STATUS__%{http_code}" \
    -H "Authorization: Bearer ${NX_TOKEN}" \
    "${BASE_URL}/rest/v3/devices") || {
    printf "%s\n" "${RED}ERROR: curl failed — is the server reachable?${RESET}" >&2
    exit 1
}

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -n '/^__STATUS__/!p')
HTTP_CODE=$(echo "$HTTP_RESPONSE" | grep -oP '(?<=__STATUS__)\d+')

if [[ "$HTTP_CODE" == "401" ]]; then
    printf "%s\n" "${RED}ERROR: Authentication failed (401). Token may have expired.${RESET}" >&2
    exit 1
elif [[ "$HTTP_CODE" != "200" ]]; then
    printf "%s\n" "${RED}ERROR: Unexpected HTTP ${HTTP_CODE} from API.${RESET}" >&2
    exit 1
fi

# ── Extract camera IDs from device list ───────────────────────────────────────
# Use python3 to reliably parse the JSON array (objects are too large/nested
# for awk-based splitting). We only need the id field from Camera entries.

if ! command -v python3 &>/dev/null; then
    printf "%s\n" "${RED}ERROR: python3 is required for JSON parsing.${RESET}" >&2
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
    printf "%s\n" "${RED}ERROR: Failed to parse device list JSON.${RESET}" >&2
    exit 1
}

DEVICE_COUNT=$(echo "$CAMERA_IDS" | grep -c '.') || true

if [[ "$DEVICE_COUNT" -eq 0 ]]; then
    printf "%s\n" "${AMBER}No cameras found in the response.${RESET}"
    exit 0
fi

printf "%s\n\n" "${BOLD}Found ${DEVICE_COUNT} camera(s).${RESET}"

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
        printf "%s\n" "${AMBER}WARNING: curl failed for device ${cam_id}, skipping.${RESET}" >&2
        continue
    }

    DEV_BODY=$(echo "$DEV_RESPONSE" | sed -n '/^__STATUS__/!p')
    DEV_CODE=$(echo "$DEV_RESPONSE" | grep -oP '(?<=__STATUS__)\d+')

    if [[ "$DEV_CODE" != "200" ]]; then
        printf "%s\n" "${AMBER}WARNING: HTTP ${DEV_CODE} for device ${cam_id}, skipping.${RESET}" >&2
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

    # Resolution — mediaStreams where encoderIndex=0 (primary recorded stream)
    media_streams_raw=$(echo "$device_json" | grep -oP '"mediaStreams"\s*:\s*\[\K[^\]]*' | head -1)
    resolution=$(extract_stream_field "$media_streams_raw" "encoderIndex" "0" "resolution")

    # Codec — prefer primaryStreamConfiguration.codec (plain string); fall back to
    # mediaStreams[encoderIndex=0].codec (numeric FFmpeg ID)
    codec_raw=$(echo "$device_json" | grep -oP '"primaryStreamConfiguration"\s*:\s*\{[^{]*"codec"\s*:\s*"\K[^"]+' | head -1)
    if [[ -z "$codec_raw" ]]; then
        codec_raw=$(extract_stream_field "$media_streams_raw" "encoderIndex" "0" "codec")
    fi
    codec=$(map_codec "$codec_raw")
    res_width=0
    if [[ "$resolution" =~ ^([0-9]+)[xX×]([0-9]+)$ ]]; then
        res_width="${BASH_REMATCH[1]}"
    fi

    # Actual bitrate — parameters.bitrateInfos.streams where encoderIndex=primary (Mbps)
    streams_raw=$(echo "$device_json" | grep -oP '"streams"\s*:\s*\[\K[^\]]*' | head -1)
    actual_bitrate_mbps=$(extract_stream_field "$streams_raw" "encoderIndex" "primary" "actualBitrate")

    # Effective bitrate — always convert to Mbps for display and comparison.
    # When bitrateKbps is configured (>0) derive Mbps from it directly so that
    # the displayed value, threshold, and storage estimate are all consistent.
    # Only fall back to bitrateInfos.actualBitrate when NX is in auto mode (0).
    if [[ "$bitrate" -gt 0 ]] 2>/dev/null; then
        bitrate_kbps="$bitrate"
        bitrate_label="$(awk "BEGIN {printf \"%.2f\", ${bitrate} / 1024}") Mbps"
    elif [[ -n "$actual_bitrate_mbps" && "$actual_bitrate_mbps" != "0" ]]; then
        bitrate_kbps=$(awk "BEGIN {printf \"%d\", ${actual_bitrate_mbps} * 1024}")
        bitrate_label="$(printf '%.2f' "${actual_bitrate_mbps}") Mbps  (actual)"
    else
        bitrate_kbps=0
        bitrate_label="unknown"
    fi

    # ── Print header ──────────────────────────────────────────────────────────
    printf "%s\n" "${BOLD}=== Camera: ${cam_name} (${cam_ip}) ===${RESET}"

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

    # Codec note
    case "$codec" in
        H.264)
            printf "  %-14s %s\n" "Codec note:" "H.265 offers ~50-60% bitrate saving at 1080p but risks"
            printf "  %-14s %s\n" "" "missing fast motion at low bitrate — not recommended for"
            printf "  %-14s %s\n" "" "court evidence footage. Stay on H.264 at 3-4Mbps." ;;
        H.265)
            printf "  %-14s %s %s\n" "Codec note:" "${GREEN}[OK]${RESET}" "H.265 active — keep bitrate above 3Mbps to ensure"
            printf "  %-14s %s\n"    ""             "reliable motion capture for evidence integrity." ;;
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

    # Bitrate — resolve to Mbps for all severity and estimate calculations
    if [[ "$bitrate_kbps" -gt 0 ]] 2>/dev/null; then
        _bmps=$(awk "BEGIN {printf \"%.6f\", ${bitrate_kbps} / 1024}")
    elif [[ -n "$actual_bitrate_mbps" && "$actual_bitrate_mbps" != "0" ]]; then
        _bmps="$actual_bitrate_mbps"
    else
        _bmps="0"
    fi

    # Bitrate line — thresholds: <4 Mbps OK, 4-8 WARN, >8 FAIL
    _btier=$(awk -v b="$_bmps" 'BEGIN {
        if (b <= 0)    print "unknown"
        else if (b < 4) print "ok"
        else if (b < 8) print "warn"
        else            print "fail"
    }')
    case "$_btier" in
        ok)      status_line "Bitrate" "GREEN" "${bitrate_label}" ;;
        warn)    status_line "Bitrate" "AMBER" "${bitrate_label}"; cam_warn=1 ;;
        fail)    status_line "Bitrate" "RED"   "${bitrate_label}"; cam_fail=1 ;;
        *)       status_line "Bitrate" "AMBER" "unknown";          cam_warn=1 ;;
    esac

    # Storage estimate and 4G download time (skipped if bitrate unknown)
    if awk -v b="$_bmps" 'BEGIN {exit (b > 0) ? 0 : 1}'; then
        read -r _daily_gb _d30_gb _d30_tb _hr_gb _dl_min < <(awk -v b="$_bmps" 'BEGIN {
            daily = b * 86400 / 8 / 1000
            d30   = daily * 30
            tb30  = d30 / 1024
            hr    = b * 3600 / 8 / 1000
            dlm   = b * 3
            printf "%.1f %.0f %.2f %.2f %.0f\n", daily, d30, tb30, hr, dlm
        }')

        # Storage est line
        _store_colour="INFO"
        _store_note="2TB NVMe — OK"
        if [[ "$_d30_gb" -gt 2000 ]] 2>/dev/null; then
            _store_colour="RED"
            _store_note="Exceeds 2TB NVMe — reduce bitrate or retention period"
            cam_fail=1
        elif [[ "$_d30_gb" -gt 1800 ]] 2>/dev/null; then
            _store_colour="AMBER"
            _store_note="Approaching 2TB NVMe limit"
            cam_warn=1
        fi
        status_line "Storage est" "${_store_colour}" \
            "~${_daily_gb} GB/day  ~${_d30_tb} TB/30 days  (${_store_note})"

        # 4G download line — same severity tier as bitrate
        case "$_btier" in
            ok)   _4g_col="GREEN" ;;
            warn) _4g_col="AMBER" ;;
            fail) _4g_col="RED"   ;;
            *)    _4g_col="AMBER" ;;
        esac
        status_line "4G download" "${_4g_col}" \
            "1hr footage ≈ ${_hr_gb}GB — approx ${_dl_min}min on 4G"

        # Recommended target — static guidance, no status tag
        printf "  %-14s %s\n" "Recommended:" \
            "Target 3-4 Mbps — at 4Mbps: ~43GB/day ~1.3TB/30 days"
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
printf "%s\n" "${BOLD}────────────────────────────────────────${RESET}"
printf "%s\n" "${BOLD}Summary:${RESET}"
printf "  %s: %s\n" "${GREEN}OK   ${RESET}" "${PASS_COUNT} camera(s)"
printf "  %s: %s\n" "${AMBER}WARN ${RESET}" "${WARN_COUNT} camera(s)"
printf "  %s: %s\n" "${RED}FAIL ${RESET}"  "${FAIL_COUNT} camera(s)"
printf "%s\n" "${BOLD}────────────────────────────────────────${RESET}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 2
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
