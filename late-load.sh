#!/system/bin/sh

# Public dispatcher for metamodules whose late-load stage replaces the normal
# module post-fs-data stage. The signed paid script remains the only owner of
# feature activation and authorization bridge writes.
MODDIR=${0%/*}
GATE_HELPER="$MODDIR/scripts/display_license_gate.sh"
PREMIUM_POST_FS="$MODDIR/premium/scripts/premium_post_fs_data.sh"

[ -f "$GATE_HELPER" ] && [ -f "$PREMIUM_POST_FS" ] || exit 0
export MURONGCHAOPIN_MOD_PATH="$MODDIR"
. "$GATE_HELPER" 2>/dev/null || exit 0
[ "$(gate_json_field "$GATE_STATE_FILE" remove_premium)" = 1 ] && exit 0
sh "$PREMIUM_POST_FS" >/dev/null 2>&1 || true
exit 0
