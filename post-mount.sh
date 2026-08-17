#!/system/bin/sh

# Public dispatcher for KernelSU/APatch metamodule post-mount stages. All
# premium behavior remains inside the signed premium payload.
MODDIR=${0%/*}
GATE_HELPER="$MODDIR/scripts/display_license_gate.sh"
PREMIUM_POST_MOUNT="$MODDIR/premium/scripts/premium_post_mount.sh"

[ -f "$GATE_HELPER" ] && [ -f "$PREMIUM_POST_MOUNT" ] || exit 0
export MURONGCHAOPIN_MOD_PATH="$MODDIR"
. "$GATE_HELPER" 2>/dev/null || exit 0
[ "$(gate_json_field "$GATE_STATE_FILE" remove_premium)" = 1 ] && exit 0
sh "$PREMIUM_POST_MOUNT" >/dev/null 2>&1 || true
exit 0
