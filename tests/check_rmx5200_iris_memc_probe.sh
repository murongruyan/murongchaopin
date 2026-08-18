#!/bin/sh
set -eu

SOURCE=src/ko/rmx5200_iris_memc_probe.c
BUILD=src/ko/build.sh

for symbol in iris_is_abyp_timing iris_configure_i7p iris_send_lut_i7p \
    iris_switch_from_abyp_to_pt iris_memc_frc_phase_update_i7p \
    iris_memc_ctrl_frc_prepare_i7p iris_memc_ctrl_pt_frc_meta_set_i7p \
    iris_memc_ctrl_pt_post_i7p iris_memc_ctrl_pt_to_frc_i7p \
    iris_memc_ctrl_frc_to_pt_i7p iris_memc_ctrl_frc_post_i7p \
    iris_memc_ctrl_cmd_proc_i7p iris_configure_memc_i7p \
    iris_set_pwil_mode_i7p; do
    grep -q "\"$symbol\"" "$SOURCE"
done

grep -q 'IRIS_MODE_CONFIG_TYPE 0x38U' "$SOURCE"
grep -q 'IRIS_FRC_PHASE_LUT 0x87U' "$SOURCE"
grep -q 'AARCH64_ADRP_X9_VALUE 0x90000009U' "$SOURCE"
grep -q 'AARCH64_LDR_X9_X9_VALUE 0xf9400129U' "$SOURCE"
grep -q 'resolve_abyp_data()' "$SOURCE"
grep -q 'timing-cmd-map=%s count=%u' "$SOURCE"
grep -q 'abyp_map_abyp' "$SOURCE"
grep -q 'rmx5200-iris-memc-probe)' "$BUILD"
grep -q 'build_one rmx5200_iris_memc_probe rmx5200_iris_memc_probe.c' "$BUILD"

if grep -Eq 'regs->(regs\[[0-9]+\]|pc)[[:space:]]*=|register_kretprobe|write[bwlq]\(' "$SOURCE"; then
    echo 'FAIL: MEMC transition probe contains a mutation path' >&2
    exit 1
fi

echo 'PASS: RMX5200 Iris MEMC transition probe is read-only and build-wired'
