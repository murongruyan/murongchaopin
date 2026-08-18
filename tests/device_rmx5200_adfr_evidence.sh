#!/system/bin/sh

# Read-only RMX5200 ADFR baseline collector. It never writes DTBO, sysfs,
# module parameters, display settings, or DSI commands.
set -eu

ADB=${ADB:-adb}
SERIAL=${1:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROFILE="$ROOT/config/rmx5200_adfr_profile.txt"

adb_cmd() {
    if [ -n "$SERIAL" ]; then
        "$ADB" -s "$SERIAL" "$@"
    else
        "$ADB" "$@"
    fi
}

profile_field() {
    sed -n "s/^$1=//p" "$PROFILE" | sed -n '1p'
}

read_value() {
    label=$1
    path=$2
    value=$(adb_cmd shell cat "$path" 2>/dev/null || true)
    value=$(printf '%s' "$value" | tr -d '\r')
    [ -n "$value" ] || value=unavailable
    printf '%s=%s\n' "$label" "$value"
}

[ -r "$PROFILE" ] || { echo "FAIL: missing shared AE084 profile" >&2; exit 1; }
[ "$(profile_field state)" = dry-run ] || {
    echo "FAIL: this collector only accepts the parser-only profile" >&2
    exit 1
}
[ "$(profile_field command_set_count)" = 0 ] || {
    echo "FAIL: a command-bearing profile requires a separate physical test plan" >&2
    exit 1
}
[ "$(profile_field physical_1hz_verified)" = 0 ] || {
    echo "FAIL: profile must not self-attest physical 1Hz" >&2
    exit 1
}

MODEL=$(adb_cmd shell getprop ro.product.vendor.model | tr -d '\r')
[ "$MODEL" = RMX5200 ] || {
    echo "FAIL: expected RMX5200, got ${MODEL:-unknown}" >&2
    exit 1
}

echo "collector=read-only"
echo "profile_id=$(profile_field profile_id)"
echo "profile_state=$(profile_field state)"
echo "command_family=$(profile_field command_family)"
echo "physical_1hz_verified=$(profile_field physical_1hz_verified)"
echo "model=$MODEL"
adb_cmd shell getprop ro.boot.slot_suffix | tr -d '\r' | sed 's/^/slot=/'
adb_cmd shell uname -r | tr -d '\r' | sed 's/^/kernel=/'
read_value adfr_config /sys/kernel/oplus_display/adfr_config
read_value min_fps /sys/kernel/oplus_display/min_fps

echo "drm_modes_begin"
adb_cmd shell cat /sys/class/drm/card0-DSI-1/modes 2>/dev/null | tr -d '\r' || true
echo "drm_modes_end"
echo "adfr_symbols_begin"
adb_cmd shell "grep -E 'oplus_adfr_parse_dtsi_config|oplus_adfr_is_supported|oplus_adfr_min_fps_update' /proc/kallsyms" \
    2>/dev/null | tr -d '\r' || true
echo "adfr_symbols_end"
echo "result=baseline_only_no_dtbo_sysfs_or_dsi_write"
echo "physical_1hz=not_tested_command_profile_unavailable"
