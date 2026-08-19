#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/process_dts.c"
FIXTURE="$ROOT/tests/fixtures/hmbird_only_input.dts"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

for pair in '1 HMBIRD_EXT' '2 HMBIRD_EXT' '3 HMBIRD_OGKI'; do
    set -- $pair
    model=$1
    expected_type=$2
    model_dir="$TMP_DIR/model-$model"
    cc -std=c11 -Wall -Wextra -Werror \
        -DPROCESS_DTS_TEST_MODEL="$model" \
        -DPROCESS_DTS_TEST_PROJECT_ID=0x1234 \
        "$SOURCE" -o "$model_dir-process_dts"
    mkdir -p "$model_dir/run/dtbo_dts" "$model_dir/config"
    cp "$ROOT/config/display_mode_manifest.txt" \
        "$model_dir/config/display_mode_manifest.txt"
    cp "$FIXTURE" "$model_dir/run/dtbo_dts/input.dts"

    if ! (cd "$model_dir/run" && \
        "$model_dir-process_dts" "--hmbird-only=$expected_type" \
            >"$model_dir/first.log" 2>&1); then
        cat "$model_dir/first.log" >&2
        exit 1
    fi
    output="$model_dir/run/dtbo_dts/input.dts"
    [ "$(grep -c 'oplus,hmbird' "$output")" -eq 1 ]
    grep -q "type = \"$expected_type\";" "$output"
    grep -q "^$(printf '\t\t')oplus,hmbird {$" "$output"
    grep -q "^$(printf '\t\t')oplus_sim_detect {$" "$output"
    grep -q 'oplus,batt_capacity_mah = <0x1388>;' "$output"
    grep -q 'test-display-rate = <0x78>;' "$output"
    [ "$(grep -c 'test-panel-data' "$output")" -eq 3 ]
    ! grep -q 'timing@.*123' "$output"

    before=$(sha256sum "$output" | awk '{print $1}')
    (cd "$model_dir/run" && \
        "$model_dir-process_dts" "--hmbird-only=$expected_type" >/dev/null)
    after=$(sha256sum "$output" | awk '{print $1}')
    [ "$before" = "$after" ] || {
        echo "FAIL: HMBIRD-only mode is not idempotent for model $model" >&2
        exit 1
    }

    wrong_type=HMBIRD_EXT
    [ "$expected_type" = HMBIRD_EXT ] && wrong_type=HMBIRD_OGKI
    if (cd "$model_dir/run" && \
        "$model_dir-process_dts" "--hmbird-only=$wrong_type" >/dev/null 2>&1); then
        echo "FAIL: conflicting HMBIRD type was accepted for model $model" >&2
        exit 1
    fi
done

if "$TMP_DIR/model-1-process_dts" --hmbird-only=HMBIRD_EXT \
    --rmx5200-drop-stock-fhd >/dev/null 2>&1; then
    echo 'FAIL: HMBIRD-only mode accepted a display modification' >&2
    exit 1
fi

grep -q 'prepare-dtbo' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'PROCESS_DTS_MODE="--hmbird-only=' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'process_dts.*PROCESS_DTS_MODE' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'hmbird_backend.sh.*prepare-dtbo' "$ROOT/customize.sh"
grep -q 'HMBIRD 已由 DTBO 显示流程写入' "$ROOT/customize.sh"
! grep -q 'patch_hmbird_dtbo.awk' "$ROOT/scripts/hmbird_backend.sh"
! grep -q 'patch_hmbird_dtbo.awk' "$ROOT/customize.sh"
grep -q 'HMBIRD_HELPER.*prepare-dtbo' "$ROOT/scripts/web_handler.sh"

echo 'PASS: HMBIRD-only DTBO is backend-independent, idempotent, and preserves non-HMBIRD data'
