#!/bin/sh

set -eu

SOURCE="${1:-src/rate_daemon.c}"
SERVICE="${2:-service.sh}"
[ -f "$SOURCE" ] || { echo "FAIL: missing rate daemon source" >&2; exit 1; }
[ -f "$SERVICE" ] || { echo "FAIL: missing service script" >&2; exit 1; }

grep -q 'oplus_customize_screen_resolution_adjust' "$SOURCE"
grep -q 'user_preferred_resolution_width' "$SOURCE"
grep -q 'user_preferred_resolution_height' "$SOURCE"
grep -q 'resolution_adjust_for_width' "$SOURCE"
grep -q 'width == maximum' "$SOURCE"
grep -q 'return 3' "$SOURCE"
grep -q 'width == minimum' "$SOURCE"
grep -q 'return 2' "$SOURCE"
grep -q 'snapshot_coloros_settings' "$SOURCE"
grep -q 'request_coloros_resolution_change' "$SOURCE"
grep -q 'ColorOS native resolution transition requested' "$SOURCE"
grep -q 'finalize_coloros_resolution_settings' "$SOURCE"
grep -q 'ColorOS restores its persisted resolution' "$SERVICE"

# The backup key is ColorOS recovery state and must never be written by the
# daemon. A refresh-only transaction must also avoid the resolution sync call.
if grep -qE 'settings (put|delete) secure oplus_customize_screen_resolution_backup' "$SOURCE"; then
    echo "FAIL: daemon writes ColorOS resolution backup key" >&2
    exit 1
fi

grep -q 'coloros_refresh_mode_index' "$SOURCE"
grep -q 'ColorOS refresh setting left unchanged' "$SOURCE"
echo "PASS: resolution and ColorOS settings synchronization is guarded"
