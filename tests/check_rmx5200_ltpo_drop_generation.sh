#!/bin/sh
set -eu

SOURCE=${1:-src/rate_daemon.c}
OUT=${TMPDIR:-/tmp}/rmx5200_ltpo_drop_state_unit

cc -std=c11 -O2 -Wall -Wextra -Werror \
    tests/rmx5200_ltpo_drop_state_unit.c -o "$OUT"
"$OUT"

grep -q 'rmx5200_ltpo_invalidate_drop_for_activity(' "$SOURCE"
grep -q '"touch-down", now_ms' "$SOURCE"
grep -q 'rmx5200_drop_receipt_is_owned(' "$SOURCE"
grep -q 'rmx5200_ltpo_quarantine_superseded_drop' "$SOURCE"
grep -q 'rmx5200_drop_begin(&rmx5200_ltpo.drop_state)' "$SOURCE"
grep -q 'rmx5200_ltpo.touch_down' "$SOURCE"
grep -q 'RMX5200 LTPO late idle-drop receipt quarantined' "$SOURCE"
TOUCH_LOOP=$(sed -n '/if (ret > 0 && rmx5200_ltpo.touch_fd/,/continue;/p' "$SOURCE")
printf '%s\n' "$TOUCH_LOOP" | grep -q 'rmx5200_ltpo_quarantine_superseded_drop('
printf '%s\n' "$TOUCH_LOOP" | grep -q 'RMX5200_LTPO_PENDING_POLL_MS'

echo 'PASS: RMX5200 LTPO drop generation is wired into the daemon'
