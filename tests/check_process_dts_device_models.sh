#!/bin/sh
# Exercise the production property-based detector, not PROCESS_DTS_TEST_MODEL.
# The install failure on PLQ110 came from an old packaged process_dts binary.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CC=${CC:-cc}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/inc/sys" "$WORK/config"
cp "$ROOT/config/display_mode_manifest.txt" "$WORK/config/"

cat > "$WORK/inc/sys/system_properties.h" <<'EOF'
#ifndef PROCESS_DTS_PROPERTY_TEST_H
#define PROCESS_DTS_PROPERTY_TEST_H
#define PROP_VALUE_MAX 92
static inline int __system_property_get(const char *name, char *value) {
    const char *result = "";
    if (strcmp(name, "ro.product.vendor.model") == 0) {
        const char *model = getenv("TEST_DEVICE_MODEL");
        if (model) result = model;
    } else if (strcmp(name, "ro.boot.prjname") == 0) {
        result = "0x1234";
    }
    snprintf(value, PROP_VALUE_MAX, "%s", result);
    return (int)strlen(value);
}
#endif
EOF

"$CC" -std=c11 -O2 -I"$WORK/inc" "$ROOT/src/process_dts.c" \
    -o "$WORK/process_dts"

for model in RMX5200 PLK110 CPH2747 PLQ110 PJD110; do
    mkdir -p "$WORK/$model/dtbo_dts"
    (cd "$WORK/$model" && TEST_DEVICE_MODEL="$model" \
        "$WORK/process_dts" > output.log)
    grep -q "Detected Device Model: $model" "$WORK/$model/output.log"
    grep -q 'Identified as ' "$WORK/$model/output.log"
    grep -q 'All files processed.' "$WORK/$model/output.log"
done

# Reproduce the failing user's normal entry point with an Ace 6 panel fixture.
cp "$ROOT/tests/fixtures/plq110_index_input.dts" \
    "$WORK/PLQ110/dtbo_dts/input.dts"
(cd "$WORK/PLQ110" && TEST_DEVICE_MODEL=PLQ110 \
    "$WORK/process_dts" > transform.log)
grep -q 'Identified as OnePlus Ace 6 (PLQ110)' "$WORK/PLQ110/transform.log"
OUTPUT="$WORK/PLQ110/dtbo_dts/input.dts"
rates=$(sed -n 's/^plq110_dtbo_rates=//p' \
    "$ROOT/config/display_mode_manifest.txt" | tr -d '[:space:]')
[ -n "$rates" ] || { echo 'FAIL: PLQ110 default rates are empty' >&2; exit 1; }
for rate in $(printf '%s' "$rates" | tr ',' ' '); do
    grep -q "timing@sdc_fhd_$rate {" "$OUTPUT" || {
        echo "FAIL: PLQ110 did not generate ${rate}Hz" >&2; exit 1;
    }
done
for rate in 60 144 165; do
    grep -q "timing@sdc_fhd_$rate {" "$OUTPUT" || {
        echo "FAIL: PLQ110 lost stock ${rate}Hz timing" >&2; exit 1;
    }
done

# Unknown hardware must still be rejected before changing its DTS.
mkdir -p "$WORK/unknown/dtbo_dts"
cp "$ROOT/tests/fixtures/plq110_index_input.dts" \
    "$WORK/unknown/dtbo_dts/input.dts"
if (cd "$WORK/unknown" && TEST_DEVICE_MODEL=UNSUPPORTED \
    "$WORK/process_dts" > output.log 2>&1); then
    echo 'FAIL: unsupported hardware was accepted' >&2
    exit 1
fi
grep -q 'Unknown Model (UNSUPPORTED)' "$WORK/unknown/output.log"
cmp "$ROOT/tests/fixtures/plq110_index_input.dts" \
    "$WORK/unknown/dtbo_dts/input.dts"

# Check the shipped Android binary as well as the host-built source.
for identification in \
    'Identified as Realme GT8 Pro (RMX5200)' \
    'Identified as OnePlus 15 (PLK110)' \
    'Identified as OnePlus Ace 6 (PLQ110)' \
    'Identified as OnePlus 12 (PJD110)'; do
    strings "$ROOT/bin/process_dts" | grep -Fxq "$identification" || {
        echo "FAIL: packaged process_dts lacks $identification" >&2
        exit 1
    }
done

echo 'PASS: production model detection and Ace 6 DTS generation; Android binary includes every supported model'
