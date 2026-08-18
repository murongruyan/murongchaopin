#!/bin/sh
set -eu

KO=src/ko/rmx5200_display_modes.c
DAEMON=${1:-src/rate_daemon.c}

grep -q '#define OC_PANEL_LOCK_OFFSET 0x410U' "$KO"
grep -q '#define OC_PANEL_CUR_MODE_OFFSET 0x598U' "$KO"
grep -q '#define OC_TIMING_SWITCH_CMDSET_TYPE 21U' "$KO"
grep -q '#define OC_WQHD120_CLOCK 1452000000ULL' "$KO"
grep -q 'oc_capture_touch_boost_mode(record, 120U' "$KO"
grep -q 'iris_pre_switch(&timing);' "$KO"
grep -q 'dsi_panel_tx_cmd_set(panel, OC_TIMING_SWITCH_CMDSET_TYPE, false)' "$KO"
grep -q 'oc_write_pointer(panel, OC_PANEL_CUR_MODE_OFFSET, current_mode);' "$KO"
grep -q 'module_param_cb(touch_boost_trigger' "$KO"
grep -q 'module_param_named(touch_boost_successes' "$KO"
grep -q 'module_param_named(physical_commit_count' "$KO"
grep -q 'module_param_named(physical_commit_refresh' "$KO"
grep -q '#define OC_TOUCH_BOOST_EPT_BYPASS_WINDOW_NS (4500ULL \* NSEC_PER_MSEC)' "$KO"
grep -q '#define OC_TOUCH_BOOST_EPT_POST_RECEIPT_WINDOW_NS (250ULL \* NSEC_PER_MSEC)' "$KO"
grep -q 'module_param_named(touch_boost_ept_target_refresh' "$KO"
grep -q 'refresh == READ_ONCE(oc_touch_boost_ept_request_refresh)' "$KO"
grep -q 'WRITE_ONCE(oc_touch_boost_ept_bypass_armed, false);' "$KO"
grep -q 'WRITE_ONCE(oc_touch_boost_ept_progress_refresh,' "$KO"
grep -q 'touch_boost_chain_ceiling_refresh' "$KO"
grep -q 'atomic_cmpxchg(&oc_touch_boost_cesta_ept_claimed, 0, 1)' "$KO"
grep -q 'WRITE_ONCE(oc_touch_boost_ept_scope_owner_pid,' "$KO"
grep -q '(unsigned int)current->pid);' "$KO"
grep -q 'OC_TOUCH_BOOST_CESTA_EPT_RESUME_OFFSET -' "$KO"
grep -q 'touch_boost_ept_target_receipt_seen' "$KO"
grep -q 'touch_boost_ept_receipt_claims' "$KO"
grep -q 'touch_boost_ept_request_claims' "$KO"
grep -q 'oc_dsi_display_set_mode_entry' "$KO"
grep -q 'regs->regs\[1\]' "$KO"
grep -q 'refresh \* 100U >= progress \* 110U' "$KO"
grep -q 'WRITE_ONCE(oc_touch_boost_ept_target_refresh, refresh);' "$KO"
grep -q 'if (remaining == 1U)' "$KO"

CESTA=$(sed -n '/static int __kprobes oc_touch_boost_cesta_ept_pre/,/^}/p' "$KO")
printf '%s\n' "$CESTA" | grep -q \
    '!READ_ONCE(oc_touch_boost_ept_chain_accepting)'
printf '%s\n' "$CESTA" | grep -q \
    'WRITE_ONCE(oc_touch_boost_ept_scope_owner_pid,'
printf '%s\n' "$CESTA" | grep -q \
    'atomic_cmpxchg(&oc_touch_boost_ept_request_claimed, 0, 1)'
printf '%s\n' "$CESTA" | grep -q \
    'commit_state != OC_TOUCH_BOOST_CESTA_BEGIN_COMMIT &&'
printf '%s\n' "$CESTA" | grep -q \
    'commit_state != OC_TOUCH_BOOST_CESTA_ENABLE_COMMIT'
printf '%s\n' "$CESTA" | grep -q \
    'terminal_receipt_owner ='
printf '%s\n' "$CESTA" | grep -q \
    'request == progress && progress >= ceiling'

DELAY=$(sed -n '/static int __kprobes oc_touch_boost_ept_delay_pre/,/^}/p' "$KO")
printf '%s\n' "$DELAY" | grep -q \
    'atomic_read(&oc_touch_boost_ept_request_claimed) != 1'
printf '%s\n' "$DELAY" | grep -q \
    '!READ_ONCE(oc_touch_boost_cesta_ept_bypass_used)'
printf '%s\n' "$DELAY" | grep -q \
    '!READ_ONCE(oc_touch_boost_ept_target_receipt_seen)'

REGISTER=$(sed -n '/static int oc_register_touch_boost_ept_bypass/,/^}/p' "$KO")
if printf '%s\n' "$REGISTER" | grep -q \
    'register_kretprobe(&oc_touch_boost_ept_scope_probe)'; then
    echo 'FAIL: missed sde_crtc_commit_kickoff scope remains registered' >&2
    exit 1
fi

WORKER=$(sed -n '/static void oc_run_native_boost/,/^}/p' "$KO")
if printf '%s\n' "$WORKER" | grep -Eq '^[[:space:]]*(rc[[:space:]]*=[[:space:]]*)?iris_switch\(|^[[:space:]]*iris_send_timing_switch_pkt\('; then
    echo 'FAIL: native boost must use the live ABYP panel path' >&2
    exit 1
fi
if grep -q 'AC180' "$KO"; then
    echo 'FAIL: AE084 touch boost must not contain AC180 payload references' >&2
    exit 1
fi

grep -q '#define RMX5200_LTPO_IRIS_BOOST_TIMEOUT_US 50000' "$DAEMON"
grep -q 'static int rmx5200_ltpo_run_iris_touch_boost(int target_refresh,' "$DAEMON"
grep -q 'RMX5200_LTPO_TOUCH_BOOST_TARGET_PATH' "$DAEMON"
grep -q 'target_fps >= 144 ? 144 : 120, target_fps' "$DAEMON"
grep -q 'ceiling_fps >= 144 ? 144 : 120, ceiling_fps' "$DAEMON"
grep -q 'RMX5200_LTPO_TOUCH_BOOST_CHAIN_CEILING_PATH' "$DAEMON"
grep -q 'write_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_TARGET_PATH' "$DAEMON"
grep -q 'write_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_TRIGGER_PATH, 1U, 0)' "$DAEMON"
grep -q 'successes > successes_before' "$DAEMON"
grep -q 'native_anchor_refresh = rmx5200_ltpo_run_iris_touch_boost(' "$DAEMON"
grep -q 'rmx5200_ltpo_submit_touch_rise(ceiling_id,' "$DAEMON"

echo 'PASS: AE084 native panel pre-boost feeds the 12:40 dynamic-ceiling rise path'
