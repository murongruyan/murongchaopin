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
cp "$ROOT/config/rmx5200_adfr_profile.txt" \
    "$TMP_DIR/config/rmx5200_adfr_profile.txt"
cp "$ROOT/config/display_mode_manifest.txt" \
    "$TMP_DIR/config/display_mode_manifest.txt"
cp "$FIXTURE" "$TMP_DIR/run/dtbo_dts/input.dts"

run_drop() {
    (cd "$TMP_DIR/run" && \
        "$TMP_DIR/process_dts" --rmx5200-drop-stock-fhd >/dev/null)
}

run_drop
OUTPUT="$TMP_DIR/run/dtbo_dts/input.dts"

if grep -q 'timing@fhd_sdc_' "$OUTPUT"; then
    echo 'FAIL: a stock RMX5200 FHD timing survived the drop experiment' >&2
    exit 1
fi

timing_order=$(grep '^[[:space:]]*timing@.*{' "$OUTPUT" | \
    sed -n 's/^[[:space:]]*\(timing@[^[:space:]]*\).*/\1/p' | tr '\n' ',')
[ "$timing_order" = 'timing@wqhd_sdc_60,timing@wqhd_sdc_90,timing@wqhd_sdc_120,timing@wqhd_sdc_144,timing@wqhd_sdc_123,timing@wqhd_sdc_150,timing@wqhd_sdc_155,timing@wqhd_sdc_160,timing@wqhd_sdc_165,timing@wqhd_sdc_170,timing@wqhd_sdc_175,timing@wqhd_sdc_180,timing@wqhd_sdc_187,' ] || {
    echo "FAIL: drop experiment produced an invalid timing order: $timing_order" >&2
    exit 1
}

cell_indexes=$(grep 'cell-index' "$OUTPUT" | \
    sed -n 's/.*<0x\([0-9a-fA-F][0-9a-fA-F]*\)>.*/\1/p' | \
    tr 'A-F\n' 'a-f,' | sed 's/,$//')
[ "$cell_indexes" = '0,1,2,3,4,5,6,7,8,9,a,b,c' ] || {
    echo "FAIL: drop experiment cell-index values are invalid: $cell_indexes" >&2
    exit 1
}

if grep -q 'oplus,adfr-min-fps-mapping-table' "$OUTPUT"; then
    echo 'FAIL: final RMX5200 FHD drop unexpectedly injects ADFR mappings' >&2
    exit 1
fi

before=$(sha256sum "$OUTPUT" | awk '{print $1}')
run_drop
after=$(sha256sum "$OUTPUT" | awk '{print $1}')
[ "$before" = "$after" ] || {
    echo 'FAIL: drop experiment is not byte-for-byte idempotent' >&2
    exit 1
}

[ "$(grep -c -- '--rmx5200-drop-stock-fhd' "$ROOT/customize.sh")" -ge 1 ] || {
    echo 'FAIL: module install does not enable the RMX5200 FHD deduplication path' >&2
    exit 1
}

[ "$(grep -c -- '--rmx5200-drop-stock-fhd' "$ROOT/scripts/web_handler.sh")" -eq 1 ] || {
    echo 'FAIL: Web DTBO rebuild does not use the single final RMX5200 FHD-drop path' >&2
    exit 1
}

sh -n "$ROOT/customize.sh"
sh -n "$ROOT/scripts/web_handler.sh"

echo 'PASS: RMX5200 stock FHD drop is scoped, integrated, and idempotent'
