#!/bin/sh

set -eu

SOURCE="${1:-src/rate_daemon.c}"
SERVICE="${2:-service.sh}"
[ -f "$SOURCE" ] || { echo "FAIL: missing rate daemon source" >&2; exit 1; }
[ -f "$SERVICE" ] || { echo "FAIL: missing service script" >&2; exit 1; }

# ColorOS' resolution selector remains a boot-state observer. It is separate
# from the physical HWC mode transaction and must never be used as DPI state.
grep -q 'oplus_customize_screen_resolution_adjust' "$SOURCE"
grep -q 'resolution_adjust_for_width' "$SOURCE"
grep -q 'mode_for_width_fps' "$SOURCE"
grep -q 'write_resolution_config' "$SOURCE"
if grep -qE 'wm[[:space:]]+(density|size)|display_density_forced|persist\.sys\.display\.user_density|density_for_resolution|apply_density_override|ensure_density_override|target_density|source_density|pending_density' "$SOURCE"; then
    echo "FAIL: daemon still contains display density or WindowManager override logic" >&2
    exit 1
fi
grep -q 'resolution_adjust_for_width' "$SOURCE"
grep -q 'width == maximum' "$SOURCE"
grep -q 'return 3' "$SOURCE"
grep -q 'width == minimum' "$SOURCE"
grep -q 'return 2' "$SOURCE"
grep -q 'ColorOS restores its persisted resolution' "$SERVICE"

if grep -qE 'snapshot_coloros_settings|request_coloros_resolution_change|finalize_coloros_resolution_settings' "$SOURCE"; then
    echo "FAIL: removed staged ColorOS resolution transaction remains" >&2
    exit 1
fi

# The backup key is ColorOS recovery state and must never be written by the
# daemon. A refresh-only transaction must also avoid the resolution sync call.
if grep -qE 'settings (put|delete) secure oplus_customize_screen_resolution_backup' "$SOURCE"; then
    echo "FAIL: daemon writes ColorOS resolution backup key" >&2
    exit 1
fi

grep -q 'coloros_refresh_mode_index' "$SOURCE"
grep -q 'ColorOS refresh setting left unchanged' "$SOURCE"
echo "PASS: resolution and ColorOS settings synchronization is guarded"
