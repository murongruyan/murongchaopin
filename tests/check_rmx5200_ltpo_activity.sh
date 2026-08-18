#!/bin/sh
set -eu

SOURCE=src/ko/rmx5200_ltpo_activity.c
BUILD=src/ko/build.sh
SERVICE=packaging/paid-payload/scripts/premium_service.sh
HELPER=scripts/rmx5200_ltpo_activity.sh
HASH=config/rmx5200_ltpo_activity.sha256

grep -q 'adreno_hwsched_queue_cmds' "$SOURCE"
grep -q '!strcmp(comm, "surfaceflinger")' "$SOURCE"
grep -q '!strcmp(comm, "ndroid.systemui")' "$SOURCE"
grep -q 'app_gpu_submit_count' "$SOURCE"
grep -q 'register_kprobe(&app_gpu_submit_probe)' "$SOURCE"
grep -q 'unregister_kprobe(&app_gpu_submit_probe)' "$SOURCE"
grep -q 'rmx5200-ltpo-activity)' "$BUILD"
grep -q 'rmx5200_ltpo_activity.sh' "$SERVICE"
grep -q '\[ -d /sys/module/rmx5200_ltpo_modes \]' "$HELPER"
grep -q 'sha256sum "$KO"' "$HELPER"
grep -Eq '^[0-9a-f]{64}$' "$HASH"

if grep -Eq 'regs->regs\[[0-9]+\] *=' "$SOURCE"; then
	echo 'FAIL: LTPO activity observer modifies a probed register' >&2
	exit 1
fi

echo 'PASS: RMX5200 LTPO activity observer is read-only, hash-pinned, and gated by the low-mode KO'
