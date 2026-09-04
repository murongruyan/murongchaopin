#!/bin/sh

set -eu

SOURCE="${1:-src/rate_daemon.c}"
[ -f "$SOURCE" ] || { echo "FAIL: missing rate daemon source" >&2; exit 1; }

# Qualcomm Android 16 exposes activeMode, not only the legacy activeConfig.
grep -q 'activeMode={id=' "$SOURCE"
grep -q 'mDisplayModePtr={id=' "$SOURCE"
grep -q 'group_has_extended_rate' "$SOURCE"
grep -q 'Duplicate mode resolved through extended group' "$SOURCE"

# Display changes are selected by mode geometry and timing. The daemon must
# never derive, write, restore, or validate a WindowManager density override.
grep -q 'mode_for_resolution_fps' "$SOURCE"
grep -q 'mode_for_width_fps' "$SOURCE"
grep -q 'set_surface_flinger_mode' "$SOURCE"
grep -q 'service call SurfaceFlinger 1035 i32 %d' "$SOURCE"
grep -q 'apply_mode_transaction' "$SOURCE"
grep -q 'apply_refresh_ladder' "$SOURCE"
grep -q 'wait_for_active_width' "$SOURCE"
grep -q 'wait_for_active_mode' "$SOURCE"
grep -q 'write_resolution_config' "$SOURCE"
grep -q 'write_global_config' "$SOURCE"
if grep -qE 'wm[[:space:]]+(density|size)|display_density_forced|persist\.sys\.display\.user_density|density_for_resolution|apply_density_override|ensure_density_override|target_density|source_density|pending_density' "$SOURCE"; then
    echo "FAIL: daemon still contains display density or WindowManager override logic" >&2
    exit 1
fi

# The bridge protocol carries width/FPS and a native-resolution adoption
# generation; it does not carry a density or a legacy extra mode argument.
grep -q 'sscanf(request, "SETRES %d"' "$SOURCE"
grep -q 'sscanf(request, "PREPRES %d"' "$SOURCE"
grep -q 'sscanf(request, "ADOPTRES %d %d %lld %lld"' "$SOURCE"
grep -q 'sscanf(request, "SETMODE %d %d"' "$SOURCE"
if grep -qE '"SETRES %d %d"|"SETMODE %d %d %d"|"ADOPTRES %d %d %d %lld"' "$SOURCE"; then
    echo "FAIL: daemon still accepts the removed density-bearing protocol" >&2
    exit 1
fi

# Resolution transactions use the exact HWC mode and refresh transactions use
# the ordered ladder. Neither path should create a framework mode request.
TRANSACTION_START=$(grep -n 'static int apply_mode_transaction(' "$SOURCE" | tail -n 1 | cut -d: -f1)
TRANSACTION_BODY=$(tail -n +"$TRANSACTION_START" "$SOURCE" | sed -n '1,/^}/p')
printf '%s\n' "$TRANSACTION_BODY" | grep -q 'set_surface_flinger_mode(target_id)'
printf '%s\n' "$TRANSACTION_BODY" | grep -q 'apply_refresh_ladder(target_id)'
printf '%s\n' "$TRANSACTION_BODY" | grep -q 'sync_android_settings(target_id)'
if printf '%s\n' "$TRANSACTION_BODY" | grep -q 'set_display_preference'; then
    echo "FAIL: mode transaction still publishes a framework preferred mode" >&2
    exit 1
fi

APPLY_START=$(grep -n 'static int apply_hook_mode_request(' "$SOURCE" | tail -n 1 | cut -d: -f1)
APPLY_BODY=$(tail -n +"$APPLY_START" "$SOURCE" | sed -n '1,/^}/p')
SMOOTH_LINE=$(printf '%s\n' "$APPLY_BODY" | grep -n 'smooth_switch(mode_id)' | head -n 1 | cut -d: -f1)
VERIFY_LINE=$(printf '%s\n' "$APPLY_BODY" | grep -n 'active_id != mode_id' | head -n 1 | cut -d: -f1)
[ -n "$SMOOTH_LINE" ] && [ -n "$VERIFY_LINE" ] && [ "$SMOOTH_LINE" -lt "$VERIFY_LINE" ] || {
    echo "FAIL: hook reports success before the physical mode is verified" >&2
    exit 1
}

# Native Settings may request geometry, but adoption only observes geometry
# and then selects the configured width/FPS mode. It must not re-enter the
# old ColorOS geometry or density path.
grep -q 'queue_native_resolution_adoption' "$SOURCE"
grep -q 'process_native_resolution_adoption' "$SOURCE"
grep -q 'recover_native_resolution_adoption' "$SOURCE"
grep -q 'Native Settings resolution adopted' "$SOURCE"
ADOPT_START=$(grep -n 'static void process_native_resolution_adoption(' "$SOURCE" | tail -n 1 | cut -d: -f1)
ADOPT_BODY=$(tail -n +"$ADOPT_START" "$SOURCE" | sed -n '1,/^}/p')
printf '%s\n' "$ADOPT_BODY" | grep -q 'active_width != native_resolution_adoption.target_width'
printf '%s\n' "$ADOPT_BODY" | grep -q 'write_resolution_config(base_path, target_id'
if printf '%s\n' "$ADOPT_BODY" | grep -qE 'request_coloros_resolution_change|ensure_density_override|target_density|source_density'; then
    echo "FAIL: native resolution adoption retains a second geometry or density transaction" >&2
    exit 1
fi

grep -q 'SO_PEERCRED' "$SOURCE"
grep -q 'DISPLAY_HOOK_TOKEN' "$SOURCE"
grep -q 'CLEARAPPS' "$SOURCE"
grep -q 'waitpid(-1, NULL, WNOHANG)' "$SOURCE"
if grep -q 'SIGCHLD, SIG_IGN' "$SOURCE"; then
    echo "FAIL: SIGCHLD ignore makes system() report false failures" >&2
    exit 1
fi
grep -q 'next_refresh_ladder_step' "$SOURCE"
grep -q 'highest_reachable_overclock' "$SOURCE"
grep -q 'immediate_lower_mode' "$SOURCE"
grep -q 'current_fps \* 110 - 1' "$SOURCE"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
CC_BIN="${CC:-cc}"
if command -v "$CC_BIN" >/dev/null 2>&1; then
    "$CC_BIN" -std=c11 -O0 "$ROOT/tests/rate_ladder_unit.c" \
        -o "$TMP_DIR/rate_ladder_unit"
    "$TMP_DIR/rate_ladder_unit"
else
    NDK_CLANG_BIN="${NDK_CLANG:-/c/android-ndk-r27d-windows/android-ndk-r30-beta2/toolchains/llvm/prebuilt/windows-x86_64/bin/clang}"
    NDK_SYSROOT_DIR="${NDK_SYSROOT:-/c/android-ndk-r27d-windows/android-ndk-r30-beta2/toolchains/llvm/prebuilt/windows-x86_64/sysroot}"
    if [ -x "$NDK_CLANG_BIN" ] && [ -d "$NDK_SYSROOT_DIR" ]; then
        "$NDK_CLANG_BIN" --target=aarch64-linux-android30 \
            --sysroot="$NDK_SYSROOT_DIR" -std=c11 -O0 -fsyntax-only \
            "$ROOT/tests/rate_ladder_unit.c"
        echo "PASS: rate ladder unit syntax checked with Android NDK"
    else
        echo "SKIP: no host C compiler or Android NDK compiler available"
    fi
fi

echo "PASS: rate daemon selects mode geometry/FPS without DPI overrides"
