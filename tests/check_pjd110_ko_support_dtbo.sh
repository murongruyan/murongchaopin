#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/process_dts.c"
FIXTURE="$ROOT/tests/fixtures/pjd110_ko_support_input.dts"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

cc -std=c11 -Wall -Wextra -Werror \
    -DPROCESS_DTS_TEST_MODEL=3 \
    -DPROCESS_DTS_TEST_PROJECT_ID=0x5929 \
    "$SOURCE" -o "$TMP_DIR/process_dts"
mkdir -p "$TMP_DIR/run/dtbo_dts" "$TMP_DIR/config"
cp "$ROOT/config/display_mode_manifest.txt" \
    "$TMP_DIR/config/display_mode_manifest.txt"
cp "$FIXTURE" "$TMP_DIR/run/dtbo_dts/input.dts"

sed -n '/qcom,mdss_dsi_panel_AA545_P_3_A0005_dsc_cmd/,$p' \
    "$FIXTURE" > "$TMP_DIR/panel.before"
(cd "$TMP_DIR/run" && "$TMP_DIR/process_dts" --pjd110-ko-support \
    > "$TMP_DIR/first.log")
OUTPUT="$TMP_DIR/run/dtbo_dts/input.dts"

grep -q 'oplus,batt_capacity_mah = <0x1770>;' "$OUTPUT"
grep -q 'oplus_spec,vbat_uv_thr_mv = <0xaf0>;' "$OUTPUT"
grep -q 'oplus,reserve_chg_soc = <0x1>;' "$OUTPUT"
[ "$(grep -c 'oplus,hmbird' "$OUTPUT")" -eq 1 ]
grep -q 'type = "HMBIRD_OGKI";' "$OUTPUT"

sed -n '/qcom,mdss_dsi_panel_AA545_P_3_A0005_dsc_cmd/,$p' \
    "$OUTPUT" > "$TMP_DIR/panel.after"
cmp -s "$TMP_DIR/panel.before" "$TMP_DIR/panel.after" || {
    echo 'FAIL: PJD110 KO companion DTBO changed panel timing data' >&2
    diff -u "$TMP_DIR/panel.before" "$TMP_DIR/panel.after" >&2 || true
    exit 1
}

before=$(sha256sum "$OUTPUT" | awk '{print $1}')
(cd "$TMP_DIR/run" && "$TMP_DIR/process_dts" --pjd110-ko-support >/dev/null)
after=$(sha256sum "$OUTPUT" | awk '{print $1}')
[ "$before" = "$after" ] || {
    echo 'FAIL: PJD110 KO companion DTBO is not idempotent' >&2
    exit 1
}

# The legacy full-DTBO backend must expose the same non-display changes. Its
# expected display-table edits (60/90 removal and reindexing) remain separate.
mkdir -p "$TMP_DIR/full-run/dtbo_dts"
cp "$FIXTURE" "$TMP_DIR/full-run/dtbo_dts/input.dts"
(cd "$TMP_DIR/full-run" && "$TMP_DIR/process_dts" > "$TMP_DIR/full.log")
FULL_OUTPUT="$TMP_DIR/full-run/dtbo_dts/input.dts"
for expected in \
    'oplus,batt_capacity_mah = <0x1770>;' \
    'oplus_spec,vbat_uv_thr_mv = <0xaf0>;' \
    'oplus,reserve_chg_soc = <0x1>;' \
    'type = "HMBIRD_OGKI";'; do
    grep -Fq "$expected" "$OUTPUT"
    grep -Fq "$expected" "$FULL_OUTPUT"
done

cc -std=c11 -Wall -Wextra -Werror \
    -DPROCESS_DTS_TEST_MODEL=2 \
    -DPROCESS_DTS_TEST_PROJECT_ID=0x595d \
    "$SOURCE" -o "$TMP_DIR/process_dts_plk110"
if "$TMP_DIR/process_dts_plk110" --pjd110-ko-support >/dev/null 2>&1; then
    echo 'FAIL: PJD110 KO-support mode accepted a non-PJD110 model' >&2
    exit 1
fi
if "$TMP_DIR/process_dts" --pjd110-ko-support \
        --hmbird-only=HMBIRD_OGKI >/dev/null 2>&1; then
    echo 'FAIL: PJD110 KO-support mode accepted a conflicting modification' >&2
    exit 1
fi

grep -q 'DEVICE_MODEL.*ro.product.vendor.model' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'PJD110)' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'PROCESS_DTS_MODE=--pjd110-ko-support' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'capacity=6000mAh, vbat=2800mV, reserve_soc=1' \
    "$ROOT/scripts/hmbird_backend.sh"

echo 'PASS: PJD110 DRM-KO companion DTBO unlocks capacity and preserves the complete stock timing table'
