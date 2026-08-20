#!/system/bin/sh

MODDIR=${0%/*}
DISPLAY_HELPER="$MODDIR/scripts/display_backend.sh"
COLOROS_CONFIG_HELPER="$MODDIR/scripts/coloros_config.sh"
GATE_HELPER="$MODDIR/scripts/display_license_gate.sh"
PREMIUM_POST_FS="$MODDIR/premium/scripts/premium_post_fs_data.sh"
LTPS_VOTE_HELPER="$MODDIR/scripts/surfaceflinger_ltps_vote_patch.sh"

# Write the premium authorization bridge (frozen contract 16.4). Root writes
# this after lease verification; the paid Hook and paid daemon read it as their
# ONLY authorization source (never written from the WebUI). It is reset to 0
# here first so a leftover "1" from a previous boot can never leak into this
# boot. The paid package overwrites it with the verified values below.
write_bridge() {
    # $1 = premium_enabled (0/1), $2 = premium_features (comma list, may be empty)
    mkdir -p "$MODDIR/runtime" 2>/dev/null
    chmod 0755 "$MODDIR/runtime" 2>/dev/null
    _tmp="$MODDIR/runtime/premium_enabled.tmp.$$"
    printf '%s\n' "$1" > "$_tmp" 2>/dev/null && \
        mv -f "$_tmp" "$MODDIR/runtime/premium_enabled" 2>/dev/null
    chmod 0644 "$MODDIR/runtime/premium_enabled" 2>/dev/null
    _tmp="$MODDIR/runtime/premium_features.tmp.$$"
    printf '%s\n' "$2" > "$_tmp" 2>/dev/null && \
        mv -f "$_tmp" "$MODDIR/runtime/premium_features" 2>/dev/null
    chmod 0644 "$MODDIR/runtime/premium_features" 2>/dev/null
    # /data/adb is root-only, so publish the verified boot snapshot through
    # read-only system properties for system_server and app-scoped Hooks.
    setprop sys.murong.premium_enabled "$1" 2>/dev/null || true
    setprop sys.murong.premium_features "$2" 2>/dev/null || true
}
write_bridge 0 ""

# Paid package dispatch runs first so the premium LTPO provider (if authorized)
# is loaded before the free display backend re-evaluates the active mode set.
# The free backend's boot-apply then skips itself when the custom LTPO module
# already owns the mode array.
if [ -f "$PREMIUM_POST_FS" ]; then
    . "$GATE_HELPER" 2>/dev/null
    gate_normalize_premium_scripts >/dev/null 2>&1 || true
    REMOVE_PREMIUM=$(gate_json_field "$GATE_STATE_FILE" remove_premium)
    if [ "$REMOVE_PREMIUM" != "1" ]; then
        sh "$PREMIUM_POST_FS" >/dev/null 2>&1 || true
    fi
fi

# RMX5200's stock LTPS framework can resolve QHD60 correctly, but a stale
# object-animation entry in SurfaceFlinger's vendor vote map can keep the
# overclocked 170Hz mode selected. For the free stock_ltps policy only, filter
# insertion of that exact internal vote name before SurfaceFlinger starts. It
# also bypasses the stale AP-scale table that otherwise remaps OTI's correct
# QHD60 pointer to 170Hz. This preserves each vote's selected mode instead of
# locking 60, so touch can still select the user ceiling. Vote removal and
# every other FRTC/OTI request retain the vendor path. The helper builds from
# this OTA's binary and fails closed on a complete instruction/context
# mismatch; other display policies never enter this path.
if [ -f "$LTPS_VOTE_HELPER" ]; then
    sh "$LTPS_VOTE_HELPER" apply >/dev/null 2>&1 || true
fi

# /my_product is EROFS and is not replaced by a normal module directory.
# Apply the semantically validated free VRR + refresh-rate configuration
# through a bind mount; an invalid source or model mismatch fails closed.
if [ -f "$COLOROS_CONFIG_HELPER" ]; then
    sh "$COLOROS_CONFIG_HELPER" apply >/dev/null 2>&1 || true
fi

# HMBIRD is supplied by the persistent DTBO written during installation.
# The retired live-OF sidecar path is intentionally disabled because it can
# block boot before the vendor consumer has initialized.

[ -f "$DISPLAY_HELPER" ] || exit 0
if [ ! -d /sys/module/rmx5200_ltpo_modes ]; then
    sh "$DISPLAY_HELPER" boot-apply >/dev/null 2>&1
fi
exit 0
