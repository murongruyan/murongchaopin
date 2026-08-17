#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/process_dts.c"
FIXTURE="$ROOT/tests/fixtures/rmx5200_adfr_input.dts"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

cc -std=c11 -Wall -Wextra \
    -DPROCESS_DTS_TEST_MODEL=1 \
    -DPROCESS_DTS_TEST_PROJECT_ID=0x1234 \
    "$SOURCE" -o "$TMP_DIR/process_dts"

mkdir -p "$TMP_DIR/default/dtbo_dts" "$TMP_DIR/rejected/dtbo_dts" \
    "$TMP_DIR/dry-run/dtbo_dts" "$TMP_DIR/config"
cat > "$TMP_DIR/config/rejected_profile.txt" <<'EOF'
profile_version=1
profile_id=ae084-dvt02-rejected-test
state=rejected
panel_token=AE084_P_3_A0033
panel_name=qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02
command_family=none
command_set_count=0
command_payload_sha256=none
mapping_low=60 40 30 20 10 1
mapping_high_suffix=60 30 20 10 1
adfr_config=0x101
physical_1hz_verified=0
EOF
cat > "$TMP_DIR/config/parser_profile.txt" <<'EOF'
profile_version=1
profile_id=ae084-dvt02-ltpo1hz-dry-run-v1
state=dry-run
panel_token=AE084_P_3_A0033
panel_name=qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02
command_family=F0_55_AA_52
command_set_count=0
command_payload_sha256=none
mapping_low=60 40 30 20 10 1
mapping_high_suffix=60 30 20 10 1
adfr_config=0x101
physical_1hz_verified=0
EOF
cp "$ROOT/config/display_mode_manifest.txt" "$TMP_DIR/config/display_mode_manifest.txt"
cp "$FIXTURE" "$TMP_DIR/default/dtbo_dts/input.dts"
cp "$FIXTURE" "$TMP_DIR/rejected/dtbo_dts/input.dts"
cp "$FIXTURE" "$TMP_DIR/dry-run/dtbo_dts/input.dts"

(cd "$TMP_DIR/default" && "$TMP_DIR/process_dts" >/dev/null)
if grep -q 'oplus,adfr-config\|oplus,adfr-min-fps-mapping-table' \
        "$TMP_DIR/default/dtbo_dts/input.dts"; then
    echo "FAIL: default process_dts path enabled experimental ADFR" >&2
    exit 1
fi

if (cd "$TMP_DIR/rejected" && \
    MURONGCHAOPIN_ADFR_PROFILE="$TMP_DIR/config/rejected_profile.txt" \
    "$TMP_DIR/process_dts" --rmx5200-adfr-dry-run >/dev/null 2>&1); then
    echo "FAIL: shipped rejected ADFR profile was accepted" >&2
    exit 1
fi
cmp -s "$FIXTURE" "$TMP_DIR/rejected/dtbo_dts/input.dts" || {
    echo "FAIL: rejected ADFR profile changed the DTS" >&2
    exit 1
}

(cd "$TMP_DIR/dry-run" && \
    MURONGCHAOPIN_ADFR_PROFILE="$TMP_DIR/config/parser_profile.txt" \
    "$TMP_DIR/process_dts" --rmx5200-adfr-dry-run >/dev/null)
OUTPUT="$TMP_DIR/dry-run/dtbo_dts/input.dts"

[ "$(grep -c 'oplus,adfr-config = <0x101>;' "$OUTPUT")" -eq 1 ] || {
    echo "FAIL: expected exactly one RMX5200 dry-run config" >&2
    exit 1
}
if ! awk '
    /__local_fixups__[[:space:]]*\{/ { in_fixups = 1 }
    in_fixups && /oplus,adfr-config/ { bad = 1 }
    in_fixups {
        line = $0
        opens = gsub(/\{/, "", line)
        line = $0
        closes = gsub(/\}/, "", line)
        depth += opens - closes
        if (depth == 0) in_fixups = 0
    }
    END { exit bad ? 1 : 0 }
' "$OUTPUT"; then
    echo "FAIL: dry-run config was injected into __local_fixups__" >&2
    exit 1
fi
[ "$(grep -c 'oplus,adfr-min-fps-mapping-table' "$OUTPUT")" -eq 17 ] || {
    echo "FAIL: not every original/generated timing has an ADFR mapping" >&2
    exit 1
}
if grep 'oplus,adfr-min-fps-mapping-table' "$OUTPUT" | \
   grep -vqE '<[[:space:]]*[0-9]+([[:space:]]+[0-9]+){5}[[:space:]]*>;'; then
    echo "FAIL: an ADFR mapping does not contain all six min-fps levels" >&2
    exit 1
fi
grep -q 'oplus,adfr-min-fps-mapping-table = <60 40 30 20 10 1>;' "$OUTPUT" || {
    echo "FAIL: 60Hz ADFR dry-run mapping is incomplete" >&2
    exit 1
}
grep -q 'oplus,adfr-min-fps-mapping-table = <120 60 30 20 10 1>;' "$OUTPUT" || {
    echo "FAIL: high-refresh ADFR dry-run mapping is incomplete" >&2
    exit 1
}
grep -q 'oplus,adfr-min-fps-mapping-table = <123 60 30 20 10 1>;' "$OUTPUT" || {
    echo "FAIL: generated 123Hz node inherited the 120Hz ADFR mapping" >&2
    exit 1
}
[ "$(grep -c 'qcom,mdss-dsi-h-sync-skew' "$OUTPUT")" -eq 17 ] || {
    echo "FAIL: h-sync-skew was omitted or duplicated" >&2
    exit 1
}
cell_indexes=$(grep 'cell-index' "$OUTPUT" | \
    sed -n 's/.*<0x\([0-9a-fA-F][0-9a-fA-F]*\)>.*/\1/p' | \
    tr 'A-F\n' 'a-f,' | sed 's/,$//')
[ "$cell_indexes" = '0,1,2,3,4,5,6,7,8,9,a,b,c,d,e,f,10' ] || {
    echo "FAIL: RMX5200 cell-index values are not contiguous: $cell_indexes" >&2
    exit 1
}
timing_order=$(grep '^[[:space:]]*timing@.*{' "$OUTPUT" | \
    sed -n 's/^[[:space:]]*\(timing@[^[:space:]]*\).*/\1/p' | tr '\n' ',')
[ "$timing_order" = 'timing@wqhd_sdc_60,timing@wqhd_sdc_90,timing@wqhd_sdc_120,timing@wqhd_sdc_144,timing@fhd_sdc_120,timing@fhd_sdc_90,timing@fhd_sdc_60,timing@fhd_sdc_144,timing@wqhd_sdc_123,timing@wqhd_sdc_150,timing@wqhd_sdc_155,timing@wqhd_sdc_160,timing@wqhd_sdc_165,timing@wqhd_sdc_170,timing@wqhd_sdc_175,timing@wqhd_sdc_180,timing@wqhd_sdc_187,' ] || {
    echo "FAIL: RMX5200 extensions were not appended after all stock modes: $timing_order" >&2
    exit 1
}
semantic_fingerprint() {
    grep -E '^[[:space:]]*timing@|cell-index|qcom,mdss-dsi-panel-(framerate|clockrate)|qcom,mdss-mdp-transfer-time-us|oplus,adfr-min-fps-mapping-table' "$1" | \
        sha256sum | awk '{ print $1 }'
}
semantic_before=$(semantic_fingerprint "$OUTPUT")
(cd "$TMP_DIR/dry-run" && \
    MURONGCHAOPIN_ADFR_PROFILE="$TMP_DIR/config/parser_profile.txt" \
    "$TMP_DIR/process_dts" --rmx5200-adfr-dry-run >/dev/null)
semantic_after=$(semantic_fingerprint "$OUTPUT")
[ "$semantic_before" = "$semantic_after" ] || {
    echo 'FAIL: reprocessing an existing RMX5200 extension table changes its semantics' >&2
    exit 1
}
[ "$(grep -c 'oplus,adfr-min-fps-mapping-table' "$OUTPUT")" -eq 17 ] || {
    echo 'FAIL: reprocessing duplicated or dropped RMX5200 extension mappings' >&2
    exit 1
}

# Simulate an old/custom tool leaving a differently named timing with the same
# physical width, height and refresh rate. Reprocessing must retain one mode.
DUPLICATE_DIR="$TMP_DIR/duplicate"
mkdir -p "$DUPLICATE_DIR/dtbo_dts"
awk '
    /^[[:space:]]*timing@wqhd_sdc_187[[:space:]]*\{/ {
        capture = 1
        block = ""
        depth = 0
    }
    capture {
        block = block $0 ORS
        line = $0
        opens = gsub(/\{/, "", line)
        line = $0
        closes = gsub(/\}/, "", line)
        depth += opens - closes
    }
    { print }
    capture && depth == 0 {
        gsub(/timing@wqhd_sdc_187/, "timing@custom_duplicate_187", block)
        printf "%s", block
        capture = 0
    }
' "$OUTPUT" > "$DUPLICATE_DIR/dtbo_dts/input.dts"
(cd "$DUPLICATE_DIR" && \
    MURONGCHAOPIN_ADFR_PROFILE="$TMP_DIR/config/parser_profile.txt" \
    "$TMP_DIR/process_dts" --rmx5200-adfr-dry-run >"$TMP_DIR/duplicate.log")
DUPLICATE_OUTPUT="$DUPLICATE_DIR/dtbo_dts/input.dts"
[ "$(grep -Ec '^[[:space:]]*timing@.*187.*\{' "$DUPLICATE_OUTPUT")" -eq 1 ] || {
    echo 'FAIL: semantic RMX5200 timing duplicate survived reprocessing' >&2
    cat "$TMP_DIR/duplicate.log" >&2
    grep -E '^[[:space:]]*timing@.*187.*\{' "$DUPLICATE_OUTPUT" >&2
    exit 1
}
[ "$(semantic_fingerprint "$DUPLICATE_OUTPUT")" = "$semantic_after" ] || {
    echo 'FAIL: semantic deduplication changed the canonical timing table' >&2
    exit 1
}
if grep -q 'qcom,mdss-dsi-.*adfr-min-fps-[0-9].*-command' "$OUTPUT"; then
    echo "FAIL: dry-run synthesized a panel command" >&2
    exit 1
fi

if (cd "$TMP_DIR/dry-run" && "$TMP_DIR/process_dts" --unknown >/dev/null 2>&1); then
    echo "FAIL: unknown process_dts option was accepted" >&2
    exit 1
fi

echo "PASS: RMX5200 ADFR dry-run is explicit, complete, and command-free"
