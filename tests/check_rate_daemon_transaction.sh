#!/bin/sh

set -eu

SOURCE="${1:-src/rate_daemon.c}"
[ -f "$SOURCE" ] || { echo "FAIL: missing rate daemon source" >&2; exit 1; }

# Qualcomm Android 16 exposes activeMode, not only the legacy activeConfig.
grep -q 'activeMode={id=' "$SOURCE"
grep -q 'mDisplayModePtr={id=' "$SOURCE"
grep -q 'group_has_extended_rate' "$SOURCE"
grep -q 'Duplicate mode resolved through extended group' "$SOURCE"

# A resolution transaction must be serialized and must preserve user display
# overrides. Refresh-only changes must not call wm density/size.
grep -q 'apply_mode_transaction' "$SOURCE"
grep -q 'snapshot_display_overrides' "$SOURCE"
grep -q 'restore_size_override' "$SOURCE"
grep -q 'set-user-preferred-display-mode' "$SOURCE"
grep -q 'wait_for_active_width' "$SOURCE"
grep -q 'wait_for_active_mode' "$SOURCE"
grep -q 'complete_resolution_geometry' "$SOURCE"
grep -q 'set_surface_flinger_mode' "$SOURCE"
grep -q 'service call SurfaceFlinger 1035 i32 %d' "$SOURCE"
grep -q 'user_preferred_screen_index' "$SOURCE"
grep -q 'Ordered refresh switch' "$SOURCE"
# API 102 hooks share one authenticated loopback protocol. Scene owns global
# changes while Settings and Game Assistant own per-app choices.
grep -q 'SO_PEERCRED' "$SOURCE"
grep -q '/proc/net/tcp' "$SOURCE"
grep -q 'tcp_peer_uid' "$SOURCE"
grep -q 'package_uid("com.android.settings")' "$SOURCE"
grep -q 'package_uid("com.oplus.games")' "$SOURCE"
grep -q 'package_uid("com.omarea.vtools")' "$SOURCE"
grep -q 'system_uid = 1000' "$SOURCE"
grep -q 'UNSET %127s' "$SOURCE"
grep -q 'CLEARAPPS' "$SOURCE"
grep -q 'DISPLAY_HOOK_TOKEN' "$SOURCE"
grep -q 'uid == -1 && authenticated' "$SOURCE"
grep -q 'SETAUTO' "$SOURCE"
grep -q '"PING"' "$SOURCE"
grep -q '"GETGLOBAL"' "$SOURCE"
grep -q '"SETGLOBAL %d"' "$SOURCE"
grep -q '"SETRES %d %d"' "$SOURCE"
grep -q '"PREPRES %d"' "$SOURCE"
grep -q '"ADOPTRES %d %d %d %lld"' "$SOURCE"
grep -q '"SETMODE %d %d %d"' "$SOURCE"
grep -q 'write_global_config' "$SOURCE"
grep -q 'write_resolution_config' "$SOURCE"
grep -q 'Resolved density for resolution switch' "$SOURCE"
grep -q 'ro.density.screenzoom.qdh' "$SOURCE"
grep -q 'ro.density.screenzoom.fdh' "$SOURCE"
grep -q 'Mapped ColorOS display-size slot' "$SOURCE"
grep -q 'Destination ColorOS display-size density already active' "$SOURCE"
grep -q 'pending_density_mode_id' "$SOURCE"
grep -q 'get_mode_width(current_mode_id) != get_mode_width(observed_id)' "$SOURCE"
grep -q 'LTPO geometry drift detected' "$SOURCE"
grep -q 'settings put system min_refresh_rate %d' "$SOURCE"
grep -q 'framework_min_refresh_floor(fps)' "$SOURCE"
grep -q 'write_setting_int("system", "min_refresh_rate", min_fps)' "$SOURCE"
grep -q 'usleep(350000)' "$SOURCE"
SMOOTH_START=$(grep -n '^void smooth_switch(int target_id)' "$SOURCE" | tail -n 1 | cut -d: -f1)
SMOOTH_BODY=$(tail -n +"$SMOOTH_START" "$SOURCE" | sed -n '1,/^}/p')
OBSERVE_LINE=$(printf '%s\n' "$SMOOTH_BODY" | grep -n 'observed_id = get_current_system_mode()' | head -n 1 | cut -d: -f1)
WIDTH_LINE=$(printf '%s\n' "$SMOOTH_BODY" | grep -n 'int current_width = get_mode_width(current_mode_id)' | head -n 1 | cut -d: -f1)
[ -n "$OBSERVE_LINE" ] && [ -n "$WIDTH_LINE" ] && [ "$OBSERVE_LINE" -lt "$WIDTH_LINE" ] || {
    echo "FAIL: smooth switch does not refresh the live HWC mode before density routing" >&2
    exit 1
}
TRANSACTION_START=$(grep -n 'static int apply_mode_transaction(' "$SOURCE" | tail -n 1 | cut -d: -f1)
TRANSACTION_BODY=$(tail -n +"$TRANSACTION_START" "$SOURCE" | sed -n '1,/^}/p')
[ "$(printf '%s\n' "$TRANSACTION_BODY" | grep -c 'set_display_preference(preference_id)')" -eq 1 ] || {
    echo "FAIL: only cross-resolution transactions may use DisplayManager" >&2
    exit 1
}
REFRESH_BODY=$(printf '%s\n' "$TRANSACTION_BODY" | sed -n '/Each physical step aligns/,$p')
printf '%s\n' "$REFRESH_BODY" | grep -q 'apply_refresh_ladder(target_id)'
if printf '%s\n' "$REFRESH_BODY" | grep -q 'set_display_preference('; then
    echo "FAIL: same-resolution refresh still goes through DisplayManager" >&2
    exit 1
fi
LADDER_LINE=$(printf '%s\n' "$REFRESH_BODY" | grep -n 'apply_refresh_ladder(target_id)' | head -n 1 | cut -d: -f1)
SYNC_LINE=$(printf '%s\n' "$REFRESH_BODY" | grep -n 'sync_android_settings(target_id)' | head -n 1 | cut -d: -f1)
[ "$LADDER_LINE" -lt "$SYNC_LINE" ] || {
    echo "FAIL: framework target is published before the physical ladder completes" >&2
    exit 1
}
REQUEST_LINE=$(printf '%s\n' "$TRANSACTION_BODY" | grep -n 'request_coloros_resolution_change' | head -n 1 | cut -d: -f1)
CLEAR_LINE=$(printf '%s\n' "$TRANSACTION_BODY" | grep -n 'clear_display_preference' | head -n 1 | cut -d: -f1)
WAIT_LINE=$(printf '%s\n' "$TRANSACTION_BODY" | grep -n 'complete_resolution_geometry(target_id, target_width)' | head -n 1 | cut -d: -f1)
DENSITY_LINE=$(printf '%s\n' "$TRANSACTION_BODY" | grep -n 'ensure_density_override(density, 1500)' | head -n 1 | cut -d: -f1)
FRAMEWORK_LINE=$(printf '%s\n' "$TRANSACTION_BODY" | grep -n 'set_display_preference(preference_id)' | head -n 1 | cut -d: -f1)
FINALIZE_LINE=$(printf '%s\n' "$TRANSACTION_BODY" | grep -n 'finalize_coloros_resolution_settings' | head -n 1 | cut -d: -f1)
[ "$CLEAR_LINE" -lt "$REQUEST_LINE" ] && [ "$REQUEST_LINE" -lt "$WAIT_LINE" ] && \
    [ "$WAIT_LINE" -lt "$DENSITY_LINE" ] && \
    [ "$DENSITY_LINE" -lt "$FRAMEWORK_LINE" ] && \
    [ "$FRAMEWORK_LINE" -lt "$FINALIZE_LINE" ] || {
    echo "FAIL: resolution transaction does not use ColorOS request -> geometry -> density -> DisplayManager" >&2
    exit 1
}
REQUEST_START=$(grep -n 'static int request_coloros_resolution_change(' "$SOURCE" | tail -n 1 | cut -d: -f1)
REQUEST_BODY=$(tail -n +"$REQUEST_START" "$SOURCE" | sed -n '1,/^}/p')
USER_DENSITY_LINE=$(printf '%s\n' "$REQUEST_BODY" | grep -n 'persist.sys.display.user_density' | head -n 1 | cut -d: -f1)
PRE_DENSITY_LINE=$(printf '%s\n' "$REQUEST_BODY" | grep -n 'ensure_density_override(density, 1000)' | head -n 1 | cut -d: -f1)
RESOLUTION_PROPERTY_LINE=$(printf '%s\n' "$REQUEST_BODY" | grep -n 'persist.sys.display.screen_resolution' | head -n 1 | cut -d: -f1)
[ "$USER_DENSITY_LINE" -lt "$PRE_DENSITY_LINE" ] && \
    [ "$PRE_DENSITY_LINE" -lt "$RESOLUTION_PROPERTY_LINE" ] || {
    echo "FAIL: destination density must be active before ColorOS publishes resolution" >&2
    exit 1
}
grep -q 'apply_hook_mode_request' "$SOURCE"
grep -q 'Display hook mode transaction completed' "$SOURCE"
SETGLOBAL_BODY=$(sed -n '/sscanf(request, "SETGLOBAL %d"/,/sscanf(request, "SETAUTO"/p' "$SOURCE")
printf '%s\n' "$SETGLOBAL_BODY" | grep -q 'apply_hook_mode_request(base_path, mode_id, width, density)'
APPLY_GLOBAL_LINE=$(printf '%s\n' "$SETGLOBAL_BODY" | grep -n 'apply_hook_mode_request' | head -n 1 | cut -d: -f1)
WRITE_GLOBAL_LINE=$(printf '%s\n' "$SETGLOBAL_BODY" | grep -n 'write_global_config' | head -n 1 | cut -d: -f1)
[ "$APPLY_GLOBAL_LINE" -lt "$WRITE_GLOBAL_LINE" ] || {
    echo "FAIL: SETGLOBAL commits config before exact physical verification" >&2
    exit 1
}
grep -q 'OplusDisplayModeService' "$SOURCE"
grep -q 'clear-user-preferred-display-mode' "$SOURCE"
grep -q 'prepared_resolution_matches' "$SOURCE"
grep -q 'rollback_resolution_transaction' "$SOURCE"
grep -q 'apply_hook_mode_request(base_path, mode_id, width, density)' "$SOURCE"
APPLY_LINE=$(grep -n 'apply_hook_mode_request(base_path, mode_id, width, density)' "$SOURCE" | head -n 1 | cut -d: -f1)
WRITE_AFTER_LINE=$(tail -n +"$APPLY_LINE" "$SOURCE" | grep -n 'write_resolution_config(base_path, mode_id, width)' | head -n 1 | cut -d: -f1)
[ -n "$WRITE_AFTER_LINE" ] || {
    echo "FAIL: resolution config is not committed after physical verification" >&2
    exit 1
}
grep -q 'queue_native_resolution_adoption' "$SOURCE"
grep -q 'process_native_resolution_adoption' "$SOURCE"
grep -q 'recover_native_resolution_adoption' "$SOURCE"
grep -q 'Native Settings adoption superseded' "$SOURCE"
grep -q 'native_resolution_adoption.target_observed_at_ms' "$SOURCE"
grep -q 'NATIVE_RESOLUTION_PHYSICAL_FALLBACK_MS' "$SOURCE"
grep -q 'Native Settings physical fallback completed' "$SOURCE"
grep -q 'delete_setting("global", "user_preferred_resolution_width")' "$SOURCE"
grep -q 'delete_setting("global", "user_preferred_resolution_height")' "$SOURCE"
grep -q 'if (native_resolution_adoption.valid)' "$SOURCE"
ADOPT_START=$(grep -n 'static void process_native_resolution_adoption(' "$SOURCE" | tail -n 1 | cut -d: -f1)
ADOPT_BODY=$(tail -n +"$ADOPT_START" "$SOURCE" | sed -n '1,/^}/p')
ADOPT_GEOMETRY=$(printf '%s\n' "$ADOPT_BODY" | grep -n 'active_width != native_resolution_adoption.target_width' | head -n 1 | cut -d: -f1)
ADOPT_DENSITY=$(printf '%s\n' "$ADOPT_BODY" | grep -n 'ensure_density_override(native_resolution_adoption.target_density' | head -n 1 | cut -d: -f1)
ADOPT_WRITE=$(printf '%s\n' "$ADOPT_BODY" | grep -n 'write_resolution_config(base_path, target_id' | head -n 1 | cut -d: -f1)
[ "$ADOPT_GEOMETRY" -lt "$ADOPT_DENSITY" ] && [ "$ADOPT_DENSITY" -lt "$ADOPT_WRITE" ] || {
    echo "FAIL: native adoption must observe geometry before density and mode.txt" >&2
    exit 1
}
if printf '%s\n' "$ADOPT_BODY" | grep -q 'target_id != active_id'; then
    echo "FAIL: native adoption can leave the framework user preference cleared" >&2
    exit 1
fi
if printf '%s\n' "$ADOPT_BODY" | grep -q 'request_coloros_resolution_change'; then
    echo "FAIL: native adoption initiates a second ColorOS geometry request" >&2
    exit 1
fi
grep -q 'monotonic_ms() <= deadline_ms' "$SOURCE"
if printf '%s\n' "$TRANSACTION_BODY" | grep -q 'usleep(120000)'; then
    echo "FAIL: resolution transaction retains the visible pre-density delay" >&2
    exit 1
fi
if printf '%s\n' "$TRANSACTION_BODY" | grep -q 'usleep(500000)'; then
    echo "FAIL: resolution transaction retains staged 500ms relayouts" >&2
    exit 1
fi
grep -q 'waitpid(-1, NULL, WNOHANG)' "$SOURCE"
if grep -q 'SIGCHLD, SIG_IGN' "$SOURCE"; then
    echo "FAIL: SIGCHLD ignore makes system() report false failures" >&2
    exit 1
fi
grep -q 'sync_global_settings_async' "$SOURCE"
grep -q 'reconcile_boot_resolution' "$SOURCE"
grep -q 'Boot resolution restore is unsettled' "$SOURCE"
grep -q 'Boot resolution reconciled' "$SOURCE"
grep -q 'target_width = active_width' "$SOURCE"

grep -q 'next_refresh_ladder_step' "$SOURCE"
grep -q 'highest_reachable_overclock' "$SOURCE"
grep -q 'immediate_lower_mode' "$SOURCE"
grep -q 'current_fps \* 110 - 1' "$SOURCE"
COMMIT_START=$(grep -n 'static int commit_refresh_step(' "$SOURCE" | tail -n 1 | cut -d: -f1)
COMMIT_BODY=$(tail -n +"$COMMIT_START" "$SOURCE" | sed -n '1,/^}/p')
COMMIT_ALIGN=$(printf '%s\n' "$COMMIT_BODY" | grep -n 'set_surface_flinger_mode(active_id)' | head -n 1 | cut -d: -f1)
COMMIT_HWC=$(printf '%s\n' "$COMMIT_BODY" | grep -n 'set_surface_flinger_mode(mode_id)' | head -n 1 | cut -d: -f1)
[ -n "$COMMIT_ALIGN" ] && [ -n "$COMMIT_HWC" ] && \
    [ "$COMMIT_ALIGN" -lt "$COMMIT_HWC" ] || {
    echo "FAIL: an HWC ladder step does not align the live mode first" >&2
    exit 1
}
if printf '%s\n' "$COMMIT_BODY" | grep -q 'set_display_preference'; then
    echo "FAIL: refresh ladder must not create a framework preferred-mode request" >&2
    exit 1
fi
if grep -q 'settings put system min_refresh_rate 0.0' "$SOURCE"; then
    echo "FAIL: fixed-rate v2.2 policy is reset to 0.0" >&2
    exit 1
fi
grep -q 'strcmp(device_model, "RMX5200")' "$SOURCE"
grep -q 'strcmp(device_model, "PLK110")' "$SOURCE"
grep -q 'strcmp(device_model, "PJD110")' "$SOURCE"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
${CC:-cc} -std=c11 -O0 "$ROOT/tests/rate_ladder_unit.c" \
    -o "$TMP_DIR/rate_ladder_unit"
"$TMP_DIR/rate_ladder_unit"

echo "PASS: rate daemon uses active-mode parsing, serialized transactions, and ordered refresh ladders"
