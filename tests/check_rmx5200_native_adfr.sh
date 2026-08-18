#!/bin/sh
set -eu

KO=src/ko/rmx5200_native_adfr.c
BUILD=src/ko/build.sh
HELPER=scripts/rmx5200_native_adfr.sh
POST=post-fs-data.sh
PROFILE=config/rmx5200_adfr_profile.txt
HASH=config/ltpo.ko.sha256

grep -q 'probe_only = true' "$KO"
grep -q 'RMX_PANEL_NODE "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02"' "$KO"
grep -q 'RMX_DRY_RUN_INSN 0x374004a8' "$KO"
grep -q 'rmx_resolve_dry_run_target' "$KO"
grep -q 'rmx_instruction_pointer_ok' "$KO"
grep -q 'rmx_read_kernel_string' "$KO"
grep -q 'set.cmds == owned->cmds' "$KO"
grep -q 'candidate_payload_armed' "$KO"
grep -q '#define RMX_AE084_ACTIVE_PAYLOAD_VERIFIED 0' "$KO"
grep -q 'target_refresh' "$KO"
grep -q 'build_one ltpo rmx5200_native_adfr.c' "$BUILD"

# Native ltpo.ko is manual-only. The separate self-written LTPO controller may
# boot only after the persisted Web policy explicitly selects custom_ltpo.
grep -q '^stock_ltps$' config/rmx5200_display_policy.txt
grep -q 'LTPO_EXPERIMENT_HELPER=' "$POST"
grep -q 'sh "$LTPO_EXPERIMENT_HELPER" boot-apply' "$POST"
grep -q 'DISPLAY_POLICY_FILE=' scripts/rmx5200_ltpo_experiment.sh
grep -q '\[ "$ltpo_policy" = custom_ltpo \]' scripts/rmx5200_ltpo_experiment.sh
grep -q 'Manual gate for the independent native-AE084 ltpo.ko' "$HELPER"
grep -q 'blocked:ae084_oneplus15_payload_rejected' "$HELPER"
grep -q 'blocked:target_refresh_required' "$HELPER"
grep -q 'candidate_payload_armed=1' "$HELPER"
grep -q 'target_refresh="\$TARGET_REFRESH"' "$HELPER"
grep -q 'legacy_ltpo_modes_loaded' "$HELPER"
grep -q '^state=rejected$' "$PROFILE"
grep -Eq '^[0-9a-f]{64}$' "$HASH"

if grep -q 'rmx5200_ltpo_experiment.sh\|rmx5200_ltpo_activity.sh' "$HELPER"; then
    echo 'FAIL: native helper references legacy LTPO autoload path' >&2
    exit 1
fi

echo 'PASS: native AE084 ltpo.ko is manual, probe-first, and active-fail-closed'
