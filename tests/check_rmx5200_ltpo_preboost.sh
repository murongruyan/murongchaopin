#!/bin/sh
set -eu

SOURCE=${1:-src/rate_daemon.c}
OUT=${TMPDIR:-/tmp}/rmx5200_ltpo_preboost_unit

cc -std=c11 -O2 -Wall -Wextra -Werror \
    tests/rmx5200_ltpo_preboost_unit.c -o "$OUT"
"$OUT"

RISE=$(sed -n '/static int rmx5200_ltpo_submit_touch_rise/,/^}/p' "$SOURCE")
printf '%s\n' "$RISE" | grep -q 'RMX5200 LTPO native pre-boost adopted'
printf '%s\n' "$RISE" | grep -q 'current_mode_id = anchor_id'
printf '%s\n' "$RISE" | grep -q 'if (active_id == target_id) goto out;'
printf '%s\n' "$RISE" | grep -q 'set_surface_flinger_mode(anchor_id)'
if printf '%s\n' "$RISE" | grep -q 'native-120-anchor'; then
    echo 'FAIL: duplicate 120Hz physical wait remains' >&2
    exit 1
fi
if printf '%s\n' "$RISE" | grep -q 'logical 120Hz anchor'; then
    echo 'FAIL: duplicate 123Hz anchor state remains' >&2
    exit 1
fi

SETTLE=$(sed -n '/static int rmx5200_ltpo_settle_pending_ceiling/,/^}/p' "$SOURCE")
printf '%s\n' "$SETTLE" | grep -q 'physical_refresh == mode_fps(target_id)'

RISE=$(sed -n '/static int rmx5200_ltpo_submit_touch_rise/,/^}/p' "$SOURCE")
printf '%s\n' "$RISE" | grep -q 'anchor_id == target_id'
printf '%s\n' "$RISE" | grep -q 'RMX5200 LTPO touch rise native ceiling queued'
printf '%s\n' "$RISE" | grep -q 'set_surface_flinger_mode(anchor_id)'
printf '%s\n' "$RISE" | grep -q 'if (active_id == target_id) goto out;'

# 144Hz is a stock/native ceiling. Its KO target and adopted anchor are both
# 144Hz, so no 120Hz request may be inserted before the final logical sync.
grep -q 'target_fps >= 144 ? 144 : 120' "$SOURCE"
grep -q 'ceiling_fps >= 144 ? 144 : 120' "$SOURCE"

echo 'PASS: RMX5200 LTPO uses direct native 1->144 and verifies only the ceiling'
