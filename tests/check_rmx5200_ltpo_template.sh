#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/process_dts.c"
FIXTURE="$ROOT/tests/fixtures/rmx5200_adfr_input.dts"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

bash -lc "cc -std=c11 -Wall -Wextra -Werror -DPROCESS_DTS_TEST_MODEL=1 -DPROCESS_DTS_TEST_PROJECT_ID=0x1234 '$SOURCE' -o '$TMP_DIR/process_dts'"
mkdir -p "$TMP_DIR/run/dtbo_dts" "$TMP_DIR/config"
cp "$ROOT/config/display_mode_manifest.txt" "$TMP_DIR/config/display_mode_manifest.txt"
cp "$FIXTURE" "$TMP_DIR/run/dtbo_dts/input.dts"

run_template() {
    (cd "$TMP_DIR/run" && \
        MURONGCHAOPIN_MODE_MANIFEST="$TMP_DIR/config/display_mode_manifest.txt" \
        "$TMP_DIR/process_dts" --rmx5200-ltpo-template \
            --rmx5200-drop-stock-fhd >/dev/null)
}

extract_node() {
    node="$1"
    file="$2"
    awk -v node="$node" '
        $0 ~ node "[[:space:]]*{" { in_node = 1; depth = 0 }
        in_node {
            line = $0
            opens = gsub(/\{/, "", line)
            line = $0
            closes = gsub(/\}/, "", line)
            depth += opens - closes
            print
            if (depth == 0) exit
        }
    ' "$file"
}

run_template
OUTPUT="$TMP_DIR/run/dtbo_dts/input.dts"

if grep -q 'timing@fhd_sdc_' "$OUTPUT"; then
    echo 'FAIL: stock FHD timing survived the LTPO template/dedup path' >&2
    exit 1
fi

LOW="$TMP_DIR/wqhd60.dts"
HIGH="$TMP_DIR/wqhd144.dts"
extract_node 'timing@wqhd_sdc_60' "$OUTPUT" > "$LOW"
extract_node 'timing@wqhd_sdc_144' "$OUTPUT" > "$HIGH"
grep -q 'qcom,mdss-dsi-panel-framerate = <0x3c>;' "$LOW"
ORIGINAL_INDEX=$(extract_node 'timing@wqhd_sdc_60' "$FIXTURE" |
    sed -n 's/.*cell-index = \([^;]*\);.*/\1/p')
grep -q "cell-index = $ORIGINAL_INDEX;" "$LOW"
LOW_CLOCK=$(sed -n 's/.*qcom,mdss-dsi-panel-clockrate = \([^;]*\);.*/\1/p' "$LOW")
HIGH_CLOCK=$(sed -n 's/.*qcom,mdss-dsi-panel-clockrate = \([^;]*\);.*/\1/p' "$HIGH")
LOW_TRANSFER=$(sed -n 's/.*qcom,mdss-mdp-transfer-time-us = \([^;]*\);.*/\1/p' "$LOW")
HIGH_TRANSFER=$(sed -n 's/.*qcom,mdss-mdp-transfer-time-us = \([^;]*\);.*/\1/p' "$HIGH")
[ "$LOW_CLOCK" = "$HIGH_CLOCK" ] || {
    echo "FAIL: LTPO template did not retain the 144Hz clock ($LOW_CLOCK != $HIGH_CLOCK)" >&2
    exit 1
}
[ "$LOW_TRANSFER" = "$HIGH_TRANSFER" ] || {
    echo "FAIL: LTPO template did not retain the 144Hz transfer time ($LOW_TRANSFER != $HIGH_TRANSFER)" >&2
    exit 1
}

before=$(sha256sum "$OUTPUT" | awk '{print $1}')
run_template
after=$(sha256sum "$OUTPUT" | awk '{print $1}')
[ "$before" = "$after" ] || {
    echo 'FAIL: LTPO template processing is not byte-for-byte idempotent' >&2
    exit 1
}

if (cd "$TMP_DIR/run" && "$TMP_DIR/process_dts" \
        --rmx5200-ltpo-template --rmx5200-adfr-ltpo >/dev/null 2>&1); then
    echo 'FAIL: LTPO template was allowed to mix with active ADFR command injection' >&2
    exit 1
fi

grep -q -- '--rmx5200-ltpo-template' "$SOURCE"
echo 'PASS: RMX5200 historical 144Hz-to-60Hz LTPO template is scoped, idempotent, and fail-closed'
