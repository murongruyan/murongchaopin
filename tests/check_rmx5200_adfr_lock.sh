#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KO_SOURCE="$ROOT/src/ko/rmx5200_adfr_lock.c"
HELPER="$ROOT/scripts/adfr_lock.sh"
DAEMON="$ROOT/src/rate_daemon.c"
HTML="$ROOT/webroot/index.html"
JS="$ROOT/webroot/js/main.js"
WEB_HANDLER="$ROOT/scripts/web_handler.sh"

grep -q 'symbol_name = "oplus_adfr_property_update"' "$KO_SOURCE"
grep -q 'RMX_ADFR_SA_MAGIC | RMX_ADFR_MIN_FPS_MAGIC' "$KO_SOURCE"
if grep -q 'RMX_ADFR_PROPERTY_ID\|property_id !=' "$KO_SOURCE"; then
    echo 'FAIL: OPPO ADFR connector property ID is hard-coded' >&2
    exit 1
fi
grep -q 'module_param_cb(lock_enable' "$KO_SOURCE"
grep -q 'module_param(fixed_min_fps, uint, 0644)' "$KO_SOURCE"
grep -q '!floor || floor > RMX_ADFR_MAX_FLOOR' "$KO_SOURCE"
grep -q 'rmx_adfr_property_probe.addr = NULL;' "$KO_SOURCE"

grep -q 'settings_shutdown_adfr_oti' "$HELPER"
grep -q 'TEST_BYPASS_FILE="$BASE_DIR/config/adfr_lock_test_disabled"' "$HELPER"
grep -q 'POLICY_FILE="$BASE_DIR/config/rmx5200_adfr_mode.txt"' "$HELPER"
grep -q 'RMX5200|PLK110|PJD110' "$HELPER"
grep -q 'KO_FILE="$MODDIR/bin/pjd110_adfr_lock.ko"' "$HELPER"
grep -q 'MODULE_NAME=pjd110_adfr_lock' "$HELPER"
grep -q 'write_state test_bypass:ltpo_enabled' "$HELPER"
grep -q 'write_state policy:ltpo_enabled' "$HELPER"
grep -q 'settings put secure "$VRR_SETTING_NAME" 3' "$HELPER"
grep -q 'OTI_TRANSACTION_CODE=22015' "$HELPER"
grep -q 'OTI_PAUSE_SUBCOMMAND=1' "$HELPER"
grep -q 'set_oti_pause 1' "$HELPER"
grep -q 'set_oti_pause 0' "$HELPER"
grep -q 'OTI_OWNER_FILE="$CONFIG_DIR/oti_pause_owner"' "$HELPER"
grep -q 'custom_ltpo_owns_oti' "$HELPER"
grep -q 'pidof rate_daemon' "$HELPER"
grep -q 'oti_pause_owner=%s' "$HELPER"
grep -q 'restore) restore_lock force' "$HELPER"
grep -q 'value=$((raw | 1))' "$HELPER"
grep -q 'vendor.display.disable_content_fps_hint 1' "$HELPER"
grep -q 'ro.surface_flinger.use_content_detection_for_refresh_rate false' "$HELPER"
PREMIUM_POST_FS="$ROOT/packaging/paid-payload/scripts/premium_post_fs_data.sh"
PREMIUM_SERVICE="$ROOT/packaging/paid-payload/scripts/premium_service.sh"
grep -q 'sh "$ADFR_LOCK_HELPER" load' "$PREMIUM_POST_FS"
grep -q 'sh "$ADFR_LOCK_HELPER" apply' "$PREMIUM_SERVICE"
grep -q 'sh "$PREMIUM_SCRIPTS/adfr_lock.sh" restore' "$ROOT/uninstall.sh"

# Capability flags stay visible to Settings and Game Assistant. The retired
# Web implementation used to zero these values and must not return.
if grep -Eq 'resetprop([^\n]*)persist\.oplus\.display\.vrr([^\n]*)0|resetprop([^\n]*)sys\.display\.vrr\.vote\.support([^\n]*)0|resetprop([^\n]*)vendor\.display\.enable_dpps_dynamic_fps([^\n]*)0' \
        "$HELPER" "$ROOT/service.sh"; then
    echo 'FAIL: ADFR lock hides a vendor capability property' >&2
    exit 1
fi

grep -q '/sys/module/rmx5200_adfr_lock/parameters/fixed_min_fps' "$DAEMON"
grep -q 'floor = fps > 120 ? 120 : fps' "$DAEMON"
grep -q 'sync_adfr_lock_floor(target_id)' "$DAEMON"
grep -q 'maintain_adfr_lock(base_path' "$DAEMON"
grep -q 'adfr_lock_requested(base_path)' "$DAEMON"
grep -q 'static int adfr_lock_test_bypassed(const char \*base_path)' "$DAEMON"
grep -q '!adfr_lock_requested(NULL)' "$DAEMON"
grep -q 'framework_min_refresh_floor_for_state' "$DAEMON"
grep -q 'video_override_active || video_handoff_active' "$DAEMON"
grep -q 'write_setting_int("system", "min_refresh_rate", min_fps)' "$DAEMON"
grep -q 'base_path = "/data/adb/modules/murongchaopin"' "$DAEMON"
grep -q 'adfr_lock_test_bypassed(base_path)' "$DAEMON"
grep -q 'adfr_lock_test_disabled' "$DAEMON"
grep -q 'current != required_config' "$DAEMON"
grep -q 'current != floor' "$DAEMON"
grep -q 'RMX5200 ADFR keepalive repaired' "$DAEMON"
grep -q 'service call SurfaceFlinger 22015 i32 1 i32 1' "$DAEMON"
grep -q 'service call SurfaceFlinger 22015 i32 1 i32 0' "$DAEMON"
grep -q 'sync_oti_pause_policy(base_path, 0)' "$DAEMON"
grep -q 'sync_oti_pause_policy(base_path, 1)' "$DAEMON"
grep -q 'read_surfaceflinger_oti_pause_state(base_path)' "$DAEMON"
grep -q 'write_surfaceflinger_oti_pause_state(base_path, paused)' "$DAEMON"
grep -q 'pause == last_pause && pause == recorded_pause' "$DAEMON"

DISPATCH_LINE=$(grep -n 'sh "$PREMIUM_SERVICE"' "$ROOT/service.sh" |
    head -n 1 | cut -d: -f1)
DAEMON_LINE=$(grep -n 'nohup "$DAEMON_TO_START"' "$ROOT/service.sh" |
    head -n 1 | cut -d: -f1)
if [ -z "$DISPATCH_LINE" ] || [ -z "$DAEMON_LINE" ] ||
        [ "$DISPATCH_LINE" -ge "$DAEMON_LINE" ]; then
    echo 'FAIL: premium ADFR service must finish before rate_daemon claims OTI' >&2
    exit 1
fi
grep -q '^on$' "$ROOT/config/rmx5200_adfr_mode.txt"
grep -q '^stock_ltps$' "$ROOT/config/rmx5200_display_policy.txt"

grep -q 'id="btn-policy-stock"' "$HTML"
grep -q 'id="btn-policy-custom"' "$HTML"
grep -q 'id="btn-policy-adfr"' "$HTML"
grep -q "displayPolicyProfile === 'rmx5200' ? 'stock_ltps' : 'stock_ltpo'" "$JS"
grep -q "setDisplayPolicy('custom_ltpo')" "$JS"
grep -q "setDisplayPolicy('adfr_off')" "$JS"
grep -q 'get_display_policy' "$JS"
grep -q 'set_display_policy' "$JS"
grep -q '重启设备后生效' "$JS"
grep -q 'DISPLAY_POLICY_FILE=' "$WEB_HANDLER"
grep -q 'read_display_policy()' "$WEB_HANDLER"
grep -q 'write_display_policy()' "$WEB_HANDLER"
grep -q '"get_display_policy")' "$WEB_HANDLER"
grep -q '"set_display_policy")' "$WEB_HANDLER"
grep -q 'profile=\$DISPLAY_PROFILE' "$WEB_HANDLER"
grep -q '"get_adfr_policy")' "$WEB_HANDLER"
grep -q '"toggle_adfr")' "$WEB_HANDLER"
grep -q 'rm -f "$ADFR_TEST_BYPASS_FILE"' "$WEB_HANDLER"

sh -n "$HELPER"
sh -n "$ROOT/post-fs-data.sh"
sh -n "$ROOT/service.sh"
sh -n "$PREMIUM_POST_FS"
sh -n "$PREMIUM_SERVICE"
sh -n "$ROOT/uninstall.sh"
grep -q 'pjd110-adfr-lock)' "$ROOT/src/ko/build.sh"

echo 'PASS: RMX5200 three-way display policy defaults to stock LTPS and preserves ADFR compatibility'
