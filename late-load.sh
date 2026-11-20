#!/system/bin/sh

# Public dispatcher for metamodules whose late-load stage replaces the normal
# module post-fs-data stage. The signed paid script remains the only owner of
# feature activation and authorization bridge writes.
MODDIR=${0%/*}
GATE_HELPER="$MODDIR/scripts/display_license_gate.sh"
PREMIUM_POST_FS="$MODDIR/premium/scripts/premium_post_fs_data.sh"

cleanup_staged_premium_memc() {
    rm -f "$MODDIR/system/odm/lib64/libpwirisservicei7p.so" 2>/dev/null || true
}

# A skipped dispatcher must not leave a previously authorized SO for the
# metamodule's upcoming collection of the base module's system tree.
if [ -f "$MODDIR/runtime/skip_kernel_modules" ] || \
        [ ! -f "$GATE_HELPER" ] || [ ! -f "$PREMIUM_POST_FS" ]; then
    cleanup_staged_premium_memc
    exit 0
fi
export MURONGCHAOPIN_MOD_PATH="$MODDIR"
if ! . "$GATE_HELPER" 2>/dev/null || \
        ! command -v gate_json_field >/dev/null 2>&1; then
    cleanup_staged_premium_memc
    exit 0
fi
if [ "$(gate_json_field "$GATE_STATE_FILE" remove_premium)" = 1 ]; then
    cleanup_staged_premium_memc
    exit 0
fi
sh "$PREMIUM_POST_FS" >/dev/null 2>&1 || true
exit 0
