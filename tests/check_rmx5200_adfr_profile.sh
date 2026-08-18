#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROFILE="$ROOT/config/rmx5200_adfr_profile.txt"
SOURCE="$ROOT/src/process_dts.c"
FIXTURE="$ROOT/tests/fixtures/rmx5200_adfr_input.dts"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

[ -f "$PROFILE" ] || { echo "FAIL: shared RMX5200 ADFR profile is missing" >&2; exit 1; }
grep -q '^profile_version=1$' "$PROFILE"
grep -q '^profile_id=ae084-dvt02-ltpo1hz-dry-run-v1$' "$PROFILE"
grep -q '^state=dry-run$' "$PROFILE"
grep -q '^panel_token=AE084_P_3_A0033$' "$PROFILE"
grep -q '^command_family=F0_55_AA_52$' "$PROFILE"
grep -q '^command_set_count=0$' "$PROFILE"
grep -q '^mapping_low=60 40 30 20 10 1$' "$PROFILE"
grep -q '^mapping_high_suffix=60 30 20 10 1$' "$PROFILE"
grep -q '^physical_1hz_verified=0$' "$PROFILE"

cc -std=c11 -Wall -Wextra \
    -DPROCESS_DTS_TEST_MODEL=1 \
    -DPROCESS_DTS_TEST_PROJECT_ID=0x1234 \
    "$SOURCE" -o "$TMP_DIR/process_dts"

mkdir -p "$TMP_DIR/work/dtbo_dts" "$TMP_DIR/config"
cp "$FIXTURE" "$TMP_DIR/work/dtbo_dts/input.dts"
cp "$PROFILE" "$TMP_DIR/config/rmx5200_adfr_profile.txt"
cp "$ROOT/config/display_mode_manifest.txt" "$TMP_DIR/config/display_mode_manifest.txt"
cp "$TMP_DIR/work/dtbo_dts/input.dts" "$TMP_DIR/before.dts"
sed -i 's/^command_family=.*/command_family=FF_5A_A5_2D/' \
    "$TMP_DIR/config/rmx5200_adfr_profile.txt"
if (cd "$TMP_DIR/work" && \
    MURONGCHAOPIN_ADFR_PROFILE="$TMP_DIR/config/rmx5200_adfr_profile.txt" \
    "$TMP_DIR/process_dts" --rmx5200-adfr-dry-run >/dev/null 2>&1); then
    echo "FAIL: mismatched AE084 command family was accepted" >&2
    exit 1
fi
cmp -s "$TMP_DIR/work/dtbo_dts/input.dts" "$TMP_DIR/before.dts" || {
    echo "FAIL: rejected profile changed DTS" >&2
    exit 1
}

cp "$PROFILE" "$TMP_DIR/config/rmx5200_adfr_profile.txt"
printf '%s\n' 'state=dry-run' >> "$TMP_DIR/config/rmx5200_adfr_profile.txt"
if (cd "$TMP_DIR/work" && \
    MURONGCHAOPIN_ADFR_PROFILE="$TMP_DIR/config/rmx5200_adfr_profile.txt" \
    "$TMP_DIR/process_dts" --rmx5200-adfr-dry-run >/dev/null 2>&1); then
    echo "FAIL: duplicate profile field was accepted" >&2
    exit 1
fi
cmp -s "$TMP_DIR/work/dtbo_dts/input.dts" "$TMP_DIR/before.dts" || {
    echo "FAIL: duplicate profile changed DTS" >&2
    exit 1
}

grep -q 'RMX5200_ADFR_PROFILE_ID' "$SOURCE"
grep -q 'MURONGCHAOPIN_ADFR_PROFILE' "$SOURCE"
grep -q 'F0_55_AA_52' "$SOURCE"
grep -q 'command_count != 0' "$SOURCE"
grep -q 'physical_1hz_verified' "$SOURCE"
sh -n "$ROOT/tests/device_rmx5200_adfr_evidence.sh"
grep -q 'result=baseline_only_no_dtbo_sysfs_or_dsi_write' \
    "$ROOT/tests/device_rmx5200_adfr_evidence.sh"
grep -q 'adfr_profile_id' "$ROOT/src/ko/rmx5200_display_modes.c" || {
    echo "FAIL: DRM-KO has no shared profile parameter" >&2
    exit 1
}

echo "PASS: RMX5200 AE084 profile is shared, parser-only, and fail-closed"
