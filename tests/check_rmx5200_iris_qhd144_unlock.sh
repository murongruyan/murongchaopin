#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/ko/rmx5200_iris_qhd144_unlock.c"
BUILD="$ROOT/src/ko/build.sh"

grep -q 'symbol_name = "iris_send_lut_i7p"' "$SOURCE"
grep -q 'IRIS_FRC_PHASE_LUT 0x87U' "$SOURCE"
grep -q 'IRIS_FRC_PHASE_144_INDEX 3U' "$SOURCE"
grep -q 'iris_fomat_lut_cmds(lut_type, lut_index);' "$SOURCE"
grep -q 'if (!READ_ONCE(phase_fix_enable))' "$SOURCE"
grep -q 'module_param(phase_fix_enable, bool, 0644)' "$SOURCE"
grep -q 'register_kprobe(&iris_phase_lut_probe)' "$SOURCE"
grep -q 'unregister_kprobe(&iris_phase_lut_probe)' "$SOURCE"
grep -q 'rmx5200-iris-qhd144-unlock)' "$BUILD"

if grep -qE 'iris_is_abyp_timing|unlock_enable|iris_abyp_probe|admitted .* from ABYP' "$SOURCE"; then
	echo 'FAIL: stale ABYP override path remains in the phase LUT candidate' >&2
	exit 1
fi

if grep -qE '(register|unregister)_kretprobe' "$SOURCE"; then
	echo 'FAIL: Android GKI does not export the kretprobe registration API' >&2
	exit 1
fi

echo 'PASS: RMX5200 Iris phase LUT unlock is disabled by default and has no ABYP override'
