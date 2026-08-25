#!/bin/sh

set -eu

SOURCE=${1:-src/rate_daemon.c}
[ -f "$SOURCE" ] || {
    echo "FAIL: missing rate daemon source: $SOURCE" >&2
    exit 1
}

grep -q 'static int screen_on_reapply_pending = 0;' "$SOURCE"
grep -q 'static int screen_on_reapply_transaction_ok = 0;' "$SOURCE"

SCREEN_ON=$(sed -n '/Screen ON after OFF\/DOZE/,/last_screen_state = screen_state/p' "$SOURCE")
printf '%s\n' "$SCREEN_ON" | grep -q 'force_reapply = 1;'
printf '%s\n' "$SCREEN_ON" | grep -q 'screen_on_reapply_pending = 1;'

# The applied DisplayManager mode is preferred, with a SurfaceFlinger fallback,
# before an ordered physical ladder is submitted.  Publishing ColorOS settings
# happens only after that ladder succeeds.
REAPPLY=$(sed -n '/} else if (screen_on_reapply_pending/,/if (!screen_on_reapply_pending) force_reapply = 0;/p' "$SOURCE")
printf '%s\n' "$REAPPLY" | grep -q 'get_current_applied_mode()'
printf '%s\n' "$REAPPLY" | grep -q 'get_current_system_mode()'
printf '%s\n' "$REAPPLY" | grep -q 'same_mode_geometry(observed_id, target_id)'
printf '%s\n' "$REAPPLY" | grep -q '"screen-on-reapply"'
printf '%s\n' "$REAPPLY" | grep -q 'sync_android_settings(target_id);'
printf '%s\n' "$REAPPLY" | grep -q 'screen_on_reapply_pending = 0;'
printf '%s\n' "$REAPPLY" | grep -q 'prepare_screen_on_reapply_anchor'

SYNC_LINE=$(printf '%s\n' "$REAPPLY" | grep -n 'sync_android_settings(target_id);' | head -n 1 | cut -d: -f1)
CLEAR_LINE=$(printf '%s\n' "$REAPPLY" | grep -n 'screen_on_reapply_pending = 0;' | head -n 1 | cut -d: -f1)
[ "$SYNC_LINE" -lt "$CLEAR_LINE" ] || {
    echo 'FAIL: screen-on state clears before Android refresh settings are synchronized' >&2
    exit 1
}

grep -q 'if (!screen_on_reapply_pending) force_reapply = 0;' "$SOURCE"
printf '%s\n' "$REAPPLY" | grep -q 'force_reapply = 1;'
GENERIC=$(sed -n '/int completing_screen_on = screen_on_reapply_pending;/,/Screen ON generic reapply retry pending/p' "$SOURCE")
printf '%s\n' "$GENERIC" | grep -q 'smooth_switch(target_id);'
printf '%s\n' "$GENERIC" | grep -q 'get_current_applied_mode()'
printf '%s\n' "$GENERIC" | grep -q 'Screen ON generic reapply completed'
printf '%s\n' "$GENERIC" | grep -q 'screen_on_reapply_pending = 0;'
printf '%s\n' "$GENERIC" | grep -q 'screen_on_reapply_transaction_ok'

FORCE_REAPPLY=$(sed -n '/if (force_reapply)/,/if (current_mode_id == -1)/p' "$SOURCE")
printf '%s\n' "$FORCE_REAPPLY" | grep -q 'prepare_screen_on_reapply_anchor'
if printf '%s\n' "$FORCE_REAPPLY" | grep -q 'apply_mode_transaction(target_id'; then
    echo 'FAIL: screen-on force replay bypasses the ordered refresh ladder' >&2
    exit 1
fi

echo 'PASS: RMX5200 screen-on replay preserves the physical extension and settings mirror'
