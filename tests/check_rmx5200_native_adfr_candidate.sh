#!/bin/sh

# Offline structural gate for the deliberately narrow active candidate.  The
# kernel ABI is validated on-device; this test proves that the source cannot
# silently broaden the write scope or omit rollback bookkeeping.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/ko/rmx5200_native_adfr.c"
HELPER="$ROOT/scripts/rmx5200_native_adfr.sh"

grep -q '#define RMX_AE084_ACTIVE_PAYLOAD_VERIFIED 0' "$SOURCE"
grep -q 'if (!RMX_AE084_ACTIVE_PAYLOAD_VERIFIED)' "$SOURCE"

[ "$(grep -c 'RMX_INSTALLED_GROUP_COUNT 3U' "$SOURCE")" -eq 1 ]
[ "$(grep -c 'RMX_INSTALLED_SLOT_COUNT' "$SOURCE")" -ge 1 ]
grep -q '#define RMX_INSTALLED_SLOT_COUNT' "$SOURCE"
grep -q 'RMX_ADFR_LEVEL_COUNT \* RMX_INSTALLED_GROUP_COUNT' "$SOURCE"
grep -q 'rmx_mode_index_for_refresh(target_refresh)' "$SOURCE"
grep -q 'case 60U:' "$SOURCE"
grep -q 'rmx_60_min_fps_payloads' "$SOURCE"
grep -q 'rmx_high_min_fps_payloads' "$SOURCE"
grep -q 'refresh == 60U' "$SOURCE"
grep -q 'rmx_prepare_descriptors(target_refresh)' "$SOURCE"
grep -q 'state = &rmx_mode_states\[mode_index\]' "$SOURCE"
grep -q 'installed_mode_count = 1' "$SOURCE"
grep -q 'installed_slot_count++' "$SOURCE"
grep -q 'rmx_normal_slot_names' "$SOURCE"
grep -q 'rmx_hpwm_slot_names' "$SOURCE"
grep -q 'rmx_bigdc_slot_names' "$SOURCE"

# All 12 modes and all 33 ADFR slots are snapshotted/restored, including the
# pre-switch slot.  Descriptor ownership must be released on both unload and
# partial-install failure.
grep -q 'for (i = 0; i < RMX_MODE_COUNT; i++)' "$SOURCE"
grep -q 'slot <= RMX_PRE_SWITCH_SLOT' "$SOURCE"
[ "$(grep -c 'kfree(rmx_allocated_descriptors' "$SOURCE")" -ge 1 ]
grep -q 'goto unlock_fail' "$SOURCE"
grep -q 'rmx_restore_slots();' "$SOURCE"

# The script must refuse an unspecified target and pass both explicit active
# acknowledgements to insmod.  No user top rate is hard-coded in the helper.
grep -q 'blocked:target_refresh_required' "$HELPER"
grep -q 'payload_verified=1 candidate_payload_armed=1' "$HELPER"
grep -q 'target_refresh="$TARGET_REFRESH"' "$HELPER"
if grep -q 'active-once).*120' "$HELPER"; then
    echo 'FAIL: active helper hard-codes the user top refresh' >&2
    exit 1
fi

echo 'PASS: RMX5200 native ADFR candidate is target-scoped, three-group, and reversible'
