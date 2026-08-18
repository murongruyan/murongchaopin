#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/process_dts.c"
FIXTURE="$ROOT/tests/fixtures/rmx5200_adfr_input.dts"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

cc -std=c11 -Wall -Wextra -Werror \
    -DPROCESS_DTS_TEST_MODEL=1 \
    -DPROCESS_DTS_TEST_PROJECT_ID=0x1234 \
    "$SOURCE" -o "$TMP_DIR/process_dts"

mkdir -p "$TMP_DIR/run/dtbo_dts" "$TMP_DIR/config"
cp "$ROOT/config/display_mode_manifest.txt" \
    "$TMP_DIR/config/display_mode_manifest.txt"
cp "$FIXTURE" "$TMP_DIR/run/dtbo_dts/input.dts"

run_drop() {
    (cd "$TMP_DIR/run" && \
        "$TMP_DIR/process_dts" --rmx5200-drop-stock-wqhd >/dev/null)
}

run_drop
OUTPUT="$TMP_DIR/run/dtbo_dts/input.dts"

[ "$(grep -c 'qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02 {' \
        "$OUTPUT")" -eq 2 ] || {
    echo 'FAIL: the real target panel header was dropped with its first WQHD timing' >&2
    exit 1
}

for rate in 60 90 120 144; do
    if grep -q "timing@wqhd_sdc_${rate} {" "$OUTPUT"; then
        echo "FAIL: stock WQHD ${rate}Hz survived the A/B transform" >&2
        exit 1
    fi
done

for rate in 60 90 120 144; do
    grep -q "timing@fhd_sdc_${rate} {" "$OUTPUT" || {
        echo "FAIL: stock FHD ${rate}Hz was removed" >&2
        exit 1
    }
done

timing_order=$(grep '^[[:space:]]*timing@.*{' "$OUTPUT" | \
    sed -n 's/^[[:space:]]*\(timing@[^[:space:]]*\).*/\1/p' | tr '\n' ',')
[ "$timing_order" = 'timing@fhd_sdc_120,timing@fhd_sdc_90,timing@fhd_sdc_60,timing@fhd_sdc_144,timing@wqhd_sdc_123,timing@wqhd_sdc_150,timing@wqhd_sdc_155,timing@wqhd_sdc_160,timing@wqhd_sdc_165,timing@wqhd_sdc_170,timing@wqhd_sdc_175,timing@wqhd_sdc_180,timing@wqhd_sdc_187,' ] || {
    echo "FAIL: WQHD-drop experiment produced an invalid order: $timing_order" >&2
    exit 1
}

cell_indexes=$(grep 'cell-index' "$OUTPUT" | \
    sed -n 's/.*<0x\([0-9a-fA-F][0-9a-fA-F]*\)>.*/\1/p' | \
    tr 'A-F\n' 'a-f,' | sed 's/,$//')
[ "$cell_indexes" = '0,1,2,3,4,5,6,7,8,9,a,b,c' ] || {
    echo "FAIL: WQHD-drop cell-index values are invalid: $cell_indexes" >&2
    exit 1
}

before=$(sha256sum "$OUTPUT" | awk '{print $1}')
run_drop
after=$(sha256sum "$OUTPUT" | awk '{print $1}')
[ "$before" = "$after" ] || {
    echo 'FAIL: WQHD-drop experiment is not byte-for-byte idempotent' >&2
    exit 1
}

if "$TMP_DIR/process_dts" --rmx5200-drop-stock-wqhd \
        --rmx5200-drop-stock-fhd >/dev/null 2>&1; then
    echo 'FAIL: mutually exclusive stock-table drop modes were accepted' >&2
    exit 1
fi

echo 'PASS: RMX5200 overclock-first stock-WQHD drop is scoped and idempotent'
