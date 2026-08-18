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

mkdir -p "$TMP_DIR/config" "$TMP_DIR/run/dtbo_dts"
cp "$ROOT/config/display_mode_manifest.txt" \
    "$TMP_DIR/config/display_mode_manifest.txt"
cp "$FIXTURE" "$TMP_DIR/run/dtbo_dts/input.dts"
cp "$FIXTURE" "$TMP_DIR/run/before.dts"

if (cd "$TMP_DIR/run" && \
    MURONGCHAOPIN_MODE_MANIFEST="$TMP_DIR/config/display_mode_manifest.txt" \
    "$TMP_DIR/process_dts" --rmx5200-adfr-ltpo \
        --rmx5200-drop-stock-fhd >"$TMP_DIR/reject.log" 2>&1); then
    echo 'FAIL: unverified AE084 ADFR command injection was accepted' >&2
    exit 1
fi
grep -q -- '--rmx5200-adfr-ltpo is disabled' "$TMP_DIR/reject.log" || {
    echo 'FAIL: rejection did not identify the disabled LTPO payload path' >&2
    exit 1
}
grep -q 'not verified for AE084 DVT02' "$TMP_DIR/reject.log" || {
    echo 'FAIL: rejection did not identify the panel verification boundary' >&2
    exit 1
}
cmp -s "$TMP_DIR/run/dtbo_dts/input.dts" "$TMP_DIR/run/before.dts" || {
    echo 'FAIL: rejected LTPO payload path changed the DTS' >&2
    exit 1
}
if grep -q 'g_rmx5200_adfr_ltpo = 1' "$SOURCE"; then
    echo 'FAIL: the command-line parser can still enable active injection' >&2
    exit 1
fi

echo 'PASS: unverified RMX5200/AE084 active ADFR payload injection is fail-closed'
