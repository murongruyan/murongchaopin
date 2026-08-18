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

run_keep() {
    (cd "$TMP_DIR/run" && \
        "$TMP_DIR/process_dts" --rmx5200-keep-stock-fhd60 >/dev/null)
}

run_keep
OUTPUT="$TMP_DIR/run/dtbo_dts/input.dts"

[ "$(grep -c 'qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02 {' \
        "$OUTPUT")" -eq 2 ] || {
    echo 'FAIL: the target panel structure was damaged' >&2
    exit 1
}
[ "$(grep -c 'timing@fhd_sdc_60 {' "$OUTPUT")" -eq 1 ] || {
    echo 'FAIL: stock FHD60 is missing or duplicated' >&2
    exit 1
}
for rate in 90 120 144; do
    if grep -q "timing@fhd_sdc_${rate} {" "$OUTPUT"; then
        echo "FAIL: stock FHD ${rate}Hz survived" >&2
        exit 1
    fi
done
for rate in 60 90 120 144 123 150 155 160 165 170 175 180; do
    grep -q "timing@wqhd_sdc_${rate} {" "$OUTPUT" || {
        echo "FAIL: required WQHD ${rate}Hz timing is missing" >&2
        exit 1
    }
done

timing_order=$(grep '^[[:space:]]*timing@.*{' "$OUTPUT" | \
    sed -n 's/^[[:space:]]*\(timing@[^[:space:]]*\).*/\1/p' | tr '\n' ',')
[ "$timing_order" = 'timing@wqhd_sdc_60,timing@wqhd_sdc_90,timing@wqhd_sdc_120,timing@wqhd_sdc_144,timing@wqhd_sdc_123,timing@wqhd_sdc_150,timing@wqhd_sdc_155,timing@wqhd_sdc_160,timing@wqhd_sdc_165,timing@wqhd_sdc_170,timing@wqhd_sdc_175,timing@wqhd_sdc_180,timing@wqhd_sdc_187,timing@fhd_sdc_60,' ] || {
    echo "FAIL: FHD60-retention experiment produced an invalid order: $timing_order" >&2
    exit 1
}

cell_indexes=$(grep 'cell-index' "$OUTPUT" | \
    sed -n 's/.*<0x\([0-9a-fA-F][0-9a-fA-F]*\)>.*/\1/p' | \
    tr 'A-F\n' 'a-f,' | sed 's/,$//')
[ "$cell_indexes" = '0,1,2,3,4,5,6,7,8,9,a,b,c,d' ] || {
    echo "FAIL: FHD60-retention cell-index values are invalid: $cell_indexes" >&2
    exit 1
}

before=$(sha256sum "$OUTPUT" | awk '{print $1}')
run_keep
after=$(sha256sum "$OUTPUT" | awk '{print $1}')
[ "$before" = "$after" ] || {
    echo 'FAIL: FHD60-retention experiment is not byte-for-byte idempotent' >&2
    exit 1
}

echo 'PASS: RMX5200 keeps only stock FHD60 after WQHD overclock generation'
