#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/ko/rmx5200_iris_timing_probe.c"
BUILD="$ROOT/src/ko/build.sh"

grep -q 'extern unsigned int iris_get_cmd_list_cnt(void);' "$SOURCE"
grep -q 'extern void iris_get_timing_info(unsigned int count, unsigned int \*values);' "$SOURCE"
grep -q 'IRIS_TIMING_MAX 8U' "$SOURCE"
grep -q 'timing_count = values\[0\]' "$SOURCE"
grep -q 'timing_count > IRIS_TIMING_MAX' "$SOURCE"
grep -q 'index=width,height,fps,clock_lo,clock_hi,extra' "$SOURCE"

if grep -Eq 'iris_(set|update)_panel_timing|iris_send|dsi_panel_tx' "$SOURCE"; then
	echo 'FAIL: read-only Iris timing probe contains a mutating/sending API' >&2
	exit 1
fi
grep -q 'rmx5200-iris-timing-probe)' "$BUILD"
grep -q 'build_one rmx5200_iris_timing_probe rmx5200_iris_timing_probe.c' "$BUILD"

echo 'PASS: RMX5200 Iris timing probe is bounded, read-only, and build-wired'
