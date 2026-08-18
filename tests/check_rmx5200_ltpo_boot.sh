#!/bin/sh
set -eu

POST=post-fs-data.sh
SERVICE=service.sh
CUSTOM_HELPER=scripts/rmx5200_ltpo_experiment.sh
HELPER=scripts/rmx5200_native_adfr.sh
HASH=config/ltpo.ko.sha256
DISPLAY_POLICY=config/rmx5200_display_policy.txt
ADFR_POLICY=config/rmx5200_adfr_mode.txt

# The self-written LTPO controller is a reboot-applied opt-in. A fresh module
# must stay on stock LTPS, while the activity observer remains inert unless the
# custom KO was loaded during post-fs-data.
grep -q '^stock_ltps$' "$DISPLAY_POLICY"
grep -q '^on$' "$ADFR_POLICY"
grep -q 'LTPO_EXPERIMENT_HELPER=' "$POST"
grep -q 'sh "$LTPO_EXPERIMENT_HELPER" boot-apply' "$POST"
grep -q '\[ ! -d /sys/module/rmx5200_ltpo_modes \]' "$POST"
grep -q 'DISPLAY_POLICY_FILE=' "$CUSTOM_HELPER"
grep -q '\[ "$ltpo_policy" = custom_ltpo \]' "$CUSTOM_HELPER"
grep -q 'durable custom_ltpo policy is intentionally retained' "$CUSTOM_HELPER"
grep -q 'ltpo_rc=19' "$CUSTOM_HELPER"
grep -q '\[ "$ltpo_rc" -eq 19 \] || break' "$CUSTOM_HELPER"
grep -q 'sleep 0.25' "$CUSTOM_HELPER"
grep -q 'error:insmod:\$ltpo_rc:attempts=\$ltpo_attempt' "$CUSTOM_HELPER"
grep -q 'custom_ltpo_selected' "$ROOT/packaging/paid-payload/scripts/premium_post_fs_data.sh"
grep -q 'gate_ok custom_ltpo && custom_ltpo_selected' "$ROOT/packaging/paid-payload/scripts/premium_post_fs_data.sh"
grep -q 'gate_ok custom_ltpo && custom_ltpo_selected' "$ROOT/packaging/paid-payload/scripts/premium_service.sh"
grep -q 'LTPO_ACTIVITY_HELPER=' "$SERVICE"
grep -q '\[ -d /sys/module/rmx5200_ltpo_modes \]' scripts/rmx5200_ltpo_activity.sh

# The independent native AE084 experiment remains manual-only and is not the
# implementation selected by the Web's self-written LTPO option.
grep -q 'Manual gate for the independent native-AE084 ltpo.ko' "$HELPER"
grep -q 'I_UNDERSTAND_RMX5200_AE084_NATIVE_ADFR_ONCE' "$HELPER"
grep -q 'ro.product.vendor.model' "$HELPER"
grep -q 'sha256sum "$KO"' "$HELPER"
grep -q 'blocked:ae084_oneplus15_payload_rejected' "$HELPER"
grep -q 'probe_only=1' "$HELPER"
grep -q 'rmmod ltpo' "$HELPER"
grep -Eq '^[0-9a-f]{64}$' "$HASH"

echo 'PASS: stock LTPS is the default and self-written LTPO is reboot-gated by explicit policy'
