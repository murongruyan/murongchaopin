#!/bin/sh

set -eu

SOURCE="${1:-src/process_dts.c}"
BINARY="${2:-bin/process_dts}"
KO="${3:-bin/plk110_drm_modes.ko}"
KO_SOURCE="${4:-src/ko/plk110_display_modes.c}"

[ -f "$SOURCE" ] || { echo "FAIL: missing process_dts source" >&2; exit 1; }
[ -f "$BINARY" ] || { echo "FAIL: missing process_dts binary" >&2; exit 1; }
[ -f "$KO" ] || { echo "FAIL: missing PLK110 KO" >&2; exit 1; }
[ -f "$KO_SOURCE" ] || { echo "FAIL: missing PLK110 KO source" >&2; exit 1; }

grep -q 'inject_plk110_adfr_properties' "$SOURCE"
grep -q 'template_sdc_60' "$SOURCE"
grep -q 'oplus,adfr-min-fps-mapping-table' "$SOURCE"
grep -q 'Found PLK110 ADFR 60Hz template' "$BINARY" || {
    echo "FAIL: process_dts binary was not rebuilt with PLK110 ADFR support" >&2
    exit 1
}
if strings "$KO" | grep -q 'oneplus15_display_165_180_auto'; then
    echo "FAIL: stale PLK110 KO binary is still installed" >&2
    exit 1
fi
strings "$KO" | grep -q 'plk110_display_runtime_modes'
if grep -qE 'ltpo_fix|adfr_lock|oc_apply_ltpo' "$KO_SOURCE"; then
    echo "FAIL: stale LTPO/ADFR-lock path remains in PLK110 KO" >&2
    exit 1
fi

echo "PASS: PLK110 ADFR template path is present; real-device behavior remains unverified"
