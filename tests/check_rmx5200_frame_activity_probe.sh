#!/bin/sh
set -eu

SOURCE=src/ko/rmx5200_frame_activity_probe.c
BUILD=src/ko/build.sh

grep -q 'dsi_display_pre_kickoff' "$SOURCE"
grep -q 'sde_crtc_commit_kickoff' "$SOURCE"
grep -q 'sde_encoder_kickoff' "$SOURCE"
grep -q 'iris_sde_encoder_kickoff' "$SOURCE"
grep -q 'sde_encoder_trigger_kickoff_pending' "$SOURCE"
grep -q 'sde_crtc_frame_event_cb' "$SOURCE"
grep -q 'kgsl_ioctl_submit_commands' "$SOURCE"
grep -q 'kgsl_ioctl_rb_issueibcmds' "$SOURCE"
grep -q 'adreno_queue_cmds' "$SOURCE"
grep -q 'adreno_dispatcher_queue_cmds' "$SOURCE"
grep -q 'adreno_hwsched_queue_cmds' "$SOURCE"
grep -q 'current->group_leader->comm, "surfaceflinger"' "$SOURCE"
grep -q 'name##_non_sf_count' "$SOURCE"
grep -q 'register_kprobe(&probe_states\[i\]->probe)' "$SOURCE"
grep -q 'unregister_kprobe(&probe_states\[i - 1\]->probe)' "$SOURCE"
grep -q '(void)regs;' "$SOURCE"
grep -q 'rmx5200-frame-activity-probe)' "$BUILD"

if grep -Eq 'regs->regs\[[0-9]+\] *=' "$SOURCE"; then
	echo 'FAIL: frame activity probe modifies a probed register' >&2
	exit 1
fi

echo 'PASS: RMX5200 frame activity probe is read-only and reversible'
