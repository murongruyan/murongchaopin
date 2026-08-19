#!/bin/sh

set -eu

ROOT=${1:-.}
PROCESS_DTS="$ROOT/src/process_dts.c"
RMX_KO="$ROOT/src/ko/rmx5200_display_modes.c"
PLK_KO="$ROOT/src/ko/plk110_display_modes.c"
PLK_FIXTURE="$ROOT/tests/fixtures/plk110_index_input.dts"
PLK_NO_INDEX_FIXTURE="$ROOT/tests/fixtures/plk110_no_index_input.dts"
PJD_FIXTURE="$ROOT/tests/fixtures/pjd110_index_input.dts"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

grep -q 'rmx5200_cell_index++' "$PROCESS_DTS"
grep -q 'plk110_cell_index++' "$PROCESS_DTS"
grep -q 'pjd110_cell_index++' "$PROCESS_DTS"
if grep -q 'int indexes\[\].*0x10' "$PROCESS_DTS"; then
    echo 'FAIL: hard-coded sparse RMX5200 cell indices remain' >&2
    exit 1
fi

for source in "$RMX_KO" "$PLK_KO"; do
    grep -q 'target_index = oc_layout.runtime_count' "$source"
    grep -q 'oc_write_u32(target_record, oc_layout.index_offset' "$source"
    grep -q 'oc_buf_u32(record, oc_layout.index_offset)' "$source"
done
tr '\n' ' ' < "$RMX_KO" | grep -Eq \
    'oc_buf_u32\(record, oc_layout.index_offset\) !=[[:space:]]*oc_layout.runtime_base_count \+ i'
tr '\n' ' ' < "$RMX_KO" | grep -Eq \
    'oc_write_u32\(target \+ output \* oc_layout.stride,[[:space:]]*oc_layout.index_offset, output\)'
tr '\n' ' ' < "$PLK_KO" | grep -Eq \
    'oc_buf_u32\(record, oc_layout.index_offset\) !=[[:space:]]*oc_layout.runtime_base_count \+ i'

cc -std=c11 -Wall -Wextra \
    -DPROCESS_DTS_TEST_MODEL=2 \
    -DPROCESS_DTS_TEST_PROJECT_ID=0x1234 \
    "$PROCESS_DTS" -o "$TMP_DIR/process_dts_plk110"
cc -std=c11 -Wall -Wextra \
    -DPROCESS_DTS_TEST_MODEL=3 \
    -DPROCESS_DTS_TEST_PROJECT_ID=0x5929 \
    "$PROCESS_DTS" -o "$TMP_DIR/process_dts_pjd110"

mkdir -p "$TMP_DIR/config" "$TMP_DIR/plk110/dtbo_dts" \
    "$TMP_DIR/pjd110/dtbo_dts"
cp "$ROOT/config/display_mode_manifest.txt" \
    "$TMP_DIR/config/display_mode_manifest.txt"
cp "$PLK_FIXTURE" "$TMP_DIR/plk110/dtbo_dts/input.dts"
cp "$PJD_FIXTURE" "$TMP_DIR/pjd110/dtbo_dts/input.dts"

(cd "$TMP_DIR/plk110" && "$TMP_DIR/process_dts_plk110" >/dev/null)
PLK_OUTPUT="$TMP_DIR/plk110/dtbo_dts/input.dts"
plk_indexes=$(grep 'cell-index' "$PLK_OUTPUT" | \
    sed -n 's/.*<0x\([0-9a-fA-F][0-9a-fA-F]*\)>.*/\1/p' | \
    tr 'A-F\n' 'a-f,' | sed 's/,$//')
[ "$plk_indexes" = '0,1,2,3,4,5,6,7,8,9,a' ] || {
    echo "FAIL: PLK110 final cell-index values are not contiguous: $plk_indexes" >&2
    exit 1
}
if grep -q 'timing@sdc_fhd_90\|timing@oplus_fhd_120' "$PLK_OUTPUT"; then
    echo 'FAIL: PLK110 removed modes remain in the final timing table' >&2
    exit 1
fi

mkdir -p "$TMP_DIR/plk110-no-index/dtbo_dts"
cp "$PLK_NO_INDEX_FIXTURE" "$TMP_DIR/plk110-no-index/dtbo_dts/input.dts"
(cd "$TMP_DIR/plk110-no-index" && "$TMP_DIR/process_dts_plk110" >/dev/null)
PLK_NO_INDEX_OUTPUT="$TMP_DIR/plk110-no-index/dtbo_dts/input.dts"
no_index_count=$(grep -c 'cell-index' "$PLK_NO_INDEX_OUTPUT")
[ "$no_index_count" -eq 11 ] || {
    echo "FAIL: missing PLK110 cell-index properties were not synthesized: $no_index_count" >&2
    exit 1
}

(cd "$TMP_DIR/pjd110" && "$TMP_DIR/process_dts_pjd110" >/dev/null)
PJD_OUTPUT="$TMP_DIR/pjd110/dtbo_dts/input.dts"
pjd_indexes=$(grep 'cell-index' "$PJD_OUTPUT" | \
    sed -n 's/.*<0x\([0-9a-fA-F][0-9a-fA-F]*\)>.*/\1/p' | \
    tr 'A-F\n' 'a-f,' | sed 's/,$//')
[ "$pjd_indexes" = '0,1,0,1' ] || {
    echo "FAIL: PJD110 panel-local cell-index values are invalid: $pjd_indexes" >&2
    exit 1
}
if grep -q 'qcom,mdss-dsi-panel-framerate = <0x3c>\|qcom,mdss-dsi-panel-framerate = <0x5a>' \
        "$PJD_OUTPUT"; then
    echo 'FAIL: PJD110 removed 60/90Hz timings remain in the final table' >&2
    exit 1
fi

echo 'PASS: DTBO and DRM-KO mode indices are contiguous and verified'
