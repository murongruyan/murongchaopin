#!/bin/sh
set -eu

SOURCE=${1:-src/rate_daemon.c}

grep -q '#include <linux/input.h>' "$SOURCE"
grep -q 'strcmp(name, "touchpanel") == 0' "$SOURCE"
grep -q 'event->code == BTN_TOUCH' "$SOURCE"
grep -q 'event->code == ABS_MT_TRACKING_ID' "$SOURCE"
grep -q 'rmx5200_ltpo_touch_released(was_down);' "$SOURCE"
grep -q 'RMX5200_LTPO_TOUCH_DEBOUNCE_MS 250' "$SOURCE"
grep -q 'RMX5200_LTPO_PENDING_POLL_MS 20' "$SOURCE"

# Preserve the hash-verified 12:40:46 rise path. The KO-owned native 120/144Hz
# pre-boost is adopted once. A 144Hz ceiling is a direct 1->144 rise; only
# ceilings above 144 continue through custom extension steps.
grep -q 'static int rmx5200_ltpo_request_receipted_mode' "$SOURCE"
grep -q 'static int rmx5200_ltpo_submit_touch_rise' "$SOURCE"
grep -q 'rmx5200_ltpo_run_iris_touch_boost(int target_refresh,' "$SOURCE"
grep -q 'target_fps >= 144 ? 144 : 120' "$SOURCE"
grep -q 'rmx5200_ltpo_submit_touch_rise(ceiling_id,' "$SOURCE"
grep -q 'RMX5200 LTPO native pre-boost adopted' "$SOURCE"
grep -q 'mode_fps(target_id) >= 144' "$SOURCE"
grep -q 'next_refresh_ladder_step(active_id, target_id)' "$SOURCE"
grep -q 'load_extension_rates(base_path)' "$SOURCE"
grep -q 'runtime/drm_modes.txt' "$SOURCE"
grep -q 'custom_refresh_rates.txt' "$SOURCE"
grep -q 'mode_fps(next_id) \* 100 >= mode_fps(active_id) \* 110' "$SOURCE"
grep -q 'pending_ceiling_mode_id = ceiling_id' "$SOURCE"

# High-rate touch rises must not block the input callback on a 500ms DSI wait.
# The ordered queue advances one custom node per main-loop receipt instead.
grep -q 'static int rmx5200_ltpo_start_rise_queue' "$SOURCE"
grep -q 'static int rmx5200_ltpo_process_rise_queue' "$SOURCE"
grep -q 'return rmx5200_ltpo_start_rise_queue(target_id, native_anchor_refresh)' "$SOURCE"
grep -q 'if (rmx5200_ltpo.rise_queue_active)' "$SOURCE"
grep -q 'RMX5200 LTPO async rise receipt' "$SOURCE"
grep -q 'RMX5200_LTPO_RISE_STEP_TIMEOUT_MS 4500' "$SOURCE"
grep -q 'RMX5200_LTPO_RISE_REFINE_TIMEOUT_MS 500' "$SOURCE"

# The synchronous KO success is the native physical receipt. Adopt that 144Hz
# anchor and immediately submit the first custom node; a duplicate logical
# 144Hz request adds a visible old-1Hz wait before the extension ladder.
START_QUEUE=$(sed -n '/static int rmx5200_ltpo_start_rise_queue/,/^}/p' "$SOURCE")
printf '%s\n' "$START_QUEUE" | grep -q \
    'RMX5200 LTPO async rise adopted physical native anchor'
printf '%s\n' "$START_QUEUE" | grep -q 'active_id = anchor_id'
printf '%s\n' "$START_QUEUE" | grep -q 'current_mode_id = anchor_id'
printf '%s\n' "$START_QUEUE" | grep -q \
    'next_id = next_refresh_ladder_step(active_id, target_id)'
printf '%s\n' "$START_QUEUE" | grep -q 'set_surface_flinger_mode(next_id)'
if printf '%s\n' "$START_QUEUE" | grep -q 'next_id = anchor_id'; then
    echo 'FAIL: async rise still queues a duplicate native anchor' >&2
    exit 1
fi
if printf '%s\n' "$START_QUEUE" | grep -q \
        'set_surface_flinger_mode(anchor_id)'; then
    echo 'FAIL: async rise still re-submits the KO-owned native anchor' >&2
    exit 1
fi

PROCESS_QUEUE=$(sed -n '/static int rmx5200_ltpo_process_rise_queue/,/^}/p' "$SOURCE")
printf '%s\n' "$PROCESS_QUEUE" | grep -q \
    'next_id = next_refresh_ladder_step(pending_id, target_id)'
printf '%s\n' "$PROCESS_QUEUE" | grep -q \
    'set_surface_flinger_mode(next_id)'
printf '%s\n' "$PROCESS_QUEUE" | grep -q \
    'next_id = nearest_overclock_between('
printf '%s\n' "$PROCESS_QUEUE" | grep -q \
    'RMX5200 LTPO async rise refines timed-out edge'
printf '%s\n' "$PROCESS_QUEUE" | grep -q \
    'RMX5200_LTPO_RISE_REFINE_TIMEOUT_MS'
if printf '%s\n' "$PROCESS_QUEUE" | grep -q \
        'set_surface_flinger_mode(pending_id)'; then
    echo 'FAIL: pending custom timing is re-submitted before its physical receipt' >&2
    exit 1
fi
if printf '%s\n' "$PROCESS_QUEUE" | grep -q 'async rise retry'; then
    echo 'FAIL: async rise still resets the pending HWC transaction timeline' >&2
    exit 1
fi

REFINE=$(sed -n '/static int nearest_overclock_between/,/^}/p' "$SOURCE")
printf '%s\n' "$REFINE" | grep -q 'is_overclock_mode(mode_id)'
printf '%s\n' "$REFINE" | grep -q 'fps < mode_fps(candidate)'
printf '%s\n' "$REFINE" | grep -q \
    'fps \* 100 >= current_fps \* 110'
if printf '%s\n' "$REFINE" | grep -Eq \
        'fps == (120|123|144|150|155|160|165|170|175|180)'; then
    echo 'FAIL: timed-out edge refinement hard-codes a refresh rate' >&2
    exit 1
fi

RISE=$(sed -n '/static int rmx5200_ltpo_submit_touch_rise/,/^}/p' "$SOURCE")
if printf '%s\n' "$RISE" | grep -q 'native-120-anchor'; then
    echo 'FAIL: KO pre-boost still submits a duplicate native 120Hz request' >&2
    exit 1
fi
if printf '%s\n' "$RISE" | grep -q 'logical 120Hz anchor'; then
    echo 'FAIL: 123Hz path still waits for a duplicate logical 120Hz commit' >&2
    exit 1
fi
printf '%s\n' "$RISE" | grep -q 'current_mode_id = anchor_id'
printf '%s\n' "$RISE" | grep -q 'if (active_id == target_id) goto out;'

# A physical pre-boost is not accepted as the logical ceiling. The final DSI
# receipt must match the selected target geometry and refresh exactly.
SETTLE=$(sed -n '/static int rmx5200_ltpo_settle_pending_ceiling/,/^}/p' "$SOURCE")
printf '%s\n' "$SETTLE" | grep -q 'physical_count > rmx5200_ltpo.touch_direct_commit_count'
printf '%s\n' "$SETTLE" | grep -q 'physical_width == get_mode_width(target_id)'
printf '%s\n' "$SETTLE" | grep -q 'physical_height == mode_height(target_id)'
printf '%s\n' "$SETTLE" | grep -q 'physical_refresh == mode_fps(target_id)'

# Idle descent remains receipt-driven. Generation ownership prevents an old
# low-refresh receipt from racing a later touch or animation rise.
grep -q 'rmx5200_drop_begin(&rmx5200_ltpo.drop_state)' "$SOURCE"
grep -q 'rmx5200_drop_receipt_is_owned(' "$SOURCE"
grep -q 'rmx5200_ltpo_quarantine_superseded_drop' "$SOURCE"
grep -q 'late idle-drop receipt quarantined' "$SOURCE"
grep -q '!rmx5200_ltpo.touch_down' "$SOURCE"

echo 'PASS: RMX5200 LTPO keeps the 12:40 rise path and generation-owned descent'
