#!/system/bin/sh
MODDIR=${0%/*}
DAEMON_BIN="$MODDIR/bin/rate_daemon"
PREMIUM_DAEMON_BIN="$MODDIR/premium/bin/rate_daemon_premium"
COLOROS_CONFIG_HELPER="$MODDIR/scripts/coloros_config.sh"
SETTINGS_BRIDGE_HELPER="$MODDIR/scripts/display_settings_bridge.sh"
GATE_HELPER="$MODDIR/scripts/display_license_gate.sh"
PREMIUM_SERVICE="$MODDIR/premium/scripts/premium_service.sh"
DISPLAY_HOOK_PACKAGE="com.murongchaopin.displayhook"

# The free and premium daemons share OTI pause ownership through this private
# state directory. Create it before either daemon starts so the first boot does
# not retry a missing-path write on every policy poll.
mkdir -p "$MODDIR/config/adfr_lock" 2>/dev/null
chmod 0700 "$MODDIR/config/adfr_lock" 2>/dev/null

# Re-apply the free VRR + refresh-rate config in the service namespace as a
# harmless idempotence check. This is useful on managers that give
# post-fs-data and service.sh different mount namespaces.
if [ -f "$COLOROS_CONFIG_HELPER" ]; then
    sh "$COLOROS_CONFIG_HELPER" apply >/dev/null 2>&1 || true
fi

# 等待系统启动完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

# Paid package runtime (ADFR lock, LTPO activity observer, MEMC/SF boot
# success markers, Pixelworks overlay and the premium Hook). Dispatched only
# when the paid package is installed and not marked for removal.
if [ -f "$PREMIUM_SERVICE" ]; then
    . "$GATE_HELPER" 2>/dev/null
    REMOVE_PREMIUM=$(gate_json_field "$GATE_STATE_FILE" remove_premium)
    if [ "$REMOVE_PREMIUM" != "1" ]; then
        sh "$PREMIUM_SERVICE" >/dev/null 2>&1 || true
    fi
fi

# rate_daemon. Prefer the premium binary only when a premium display feature
# (custom LTPO or video MEMC) is actually authorized; otherwise the free
# daemon runs. Missing premium binary always falls back to the free daemon.
DAEMON_TO_START="$DAEMON_BIN"
if [ -f "$PREMIUM_DAEMON_BIN" ]; then
    if [ -f "$GATE_HELPER" ]; then
        . "$GATE_HELPER" 2>/dev/null
        gate_check custom_ltpo >/dev/null 2>&1
        ltpo_rc=$?
        gate_check video_memc >/dev/null 2>&1
        memc_rc=$?
        if [ "$ltpo_rc" -eq 0 ] || [ "$ltpo_rc" -eq 2 ] ||
           [ "$memc_rc" -eq 0 ] || [ "$memc_rc" -eq 2 ]; then
            DAEMON_TO_START="$PREMIUM_DAEMON_BIN"
        fi
    fi
fi
# ColorOS restores its persisted resolution after system_server starts. Let
# that become authoritative before mode.txt is replayed; otherwise a stale
# module width and the native boot width can fight across HWC mode groups.
sleep 2
if ! pidof rate_daemon >/dev/null 2>&1 &&
   ! pidof rate_daemon_premium >/dev/null 2>&1; then
    chmod +x "$DAEMON_TO_START" 2>/dev/null
    nohup "$DAEMON_TO_START" "$MODDIR" > /dev/null 2>&1 &
fi

# Settings only exposes a subset of the HWC refresh modes.  Keep its global
# resolution/refresh preferences and per-app overrides synchronized with the
# exact mode IDs maintained by the WebUI and rate daemon.
if [ -f "$SETTINGS_BRIDGE_HELPER" ] &&
   ! pm path "$DISPLAY_HOOK_PACKAGE" >/dev/null 2>&1; then
    nohup sh "$SETTINGS_BRIDGE_HELPER" watch >/dev/null 2>&1 &
fi
