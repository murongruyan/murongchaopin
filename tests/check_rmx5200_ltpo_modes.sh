#!/bin/sh
set -eu

SOURCE=src/ko/rmx5200_display_modes.c
WRAPPER=src/ko/rmx5200_ltpo_modes.c
BUILD=src/ko/build.sh
HELPER=scripts/rmx5200_ltpo_experiment.sh

grep -q '#define RMX5200_LOW_REFRESH_EXPERIMENT 1' "$WRAPPER"
grep -q '#include "rmx5200_display_modes.c"' "$WRAPPER"
grep -q '1440x3136@30:1113600000;1440x3136@10:1113600000;1440x3136@1:1113600000' "$SOURCE"
grep -q '#define OC_LOW_LINK_TRANSFER_US 6800U' "$SOURCE"
grep -q 'validate the live DT multiset and semantic anchors' "$SOURCE"
grep -q 'OC_MAX_RUNTIME_MODES + OC_MAX_DT_MODES' "$SOURCE"
grep -q 'source_transfer_time_us != OC_LOW_LINK_TRANSFER_US' "$SOURCE"
grep -q 'target_transfer_time_us = source_transfer_time_us' "$SOURCE"
grep -q 'refresh == OC_SOURCE_FPS' "$SOURCE"
grep -q 'OC_IRIS_TIMING_HEIGHT_OFFSET 0x10U' "$SOURCE"
grep -q 'OC_IRIS_TIMING_REFRESH_OFFSET 0x20U' "$SOURCE"
grep -q 'refresh != 30U && refresh != 10U && refresh != 1U' "$SOURCE"
grep -q 'OC_IRIS_TIMING_REFRESH_OFFSET), data->refresh' "$SOURCE"
grep -q 'register_kretprobe(&oc_iris_pre_switch_probe)' "$SOURCE"
grep -q 'register_kretprobe(&oc_iris_switch_probe)' "$SOURCE"
grep -q 'register_kretprobe(&oc_iris_update_panel_timing_probe)' "$SOURCE"
grep -q 'unregister_kretprobe(&oc_iris_pre_switch_probe)' "$SOURCE"
grep -q 'unregister_kretprobe(&oc_iris_switch_probe)' "$SOURCE"
grep -q 'unregister_kretprobe(&oc_iris_update_panel_timing_probe)' "$SOURCE"
grep -q '.kp.symbol_name = "iris_pre_switch"' "$SOURCE"
grep -q '.kp.symbol_name = "iris_switch"' "$SOURCE"
grep -q '.kp.symbol_name = "iris_update_panel_timing"' "$SOURCE"
grep -q 'oc_iris_timing_entry_common(instance, regs, 2U' "$SOURCE"
grep -q 'oc_iris_hook_registered_mask != OC_IRIS_ALL_HOOKS_MASK' "$SOURCE"
grep -q 'iris_pre_switch_missed' "$SOURCE"
grep -q 'iris_switch_missed' "$SOURCE"
grep -q 'iris_update_panel_timing_missed' "$SOURCE"
grep -q 'oc_unregister_iris_hook();' "$SOURCE"
grep -q 'OC_IRIS_WQHD60_SLOT, oc_iris_hook_registered_mask, rc' "$SOURCE"
grep -q 'module_param_named(physical_commit_hook_registered' "$SOURCE"
grep -q 'module_param_named(physical_commit_count' "$SOURCE"
grep -q 'module_param_named(physical_commit_mode_id' "$SOURCE"
grep -q '.kp.symbol_name = "dsi_display_set_mode"' "$SOURCE"
grep -q 'oc_dsi_display_set_mode_entry' "$SOURCE"
grep -q 'oc_dsi_display_set_mode_return' "$SOURCE"
grep -q 'OC_PANEL_CUR_MODE_OFFSET' "$SOURCE"
grep -q '#define OC_WQHD144_CLOCK 1452000000ULL' "$SOURCE"
grep -q '#define OC_WQHD144_SWITCH_CMD_COUNT 20U' "$SOURCE"
grep -q 'oc_capture_touch_boost_mode(record, 120U' "$SOURCE"
grep -q 'oc_capture_touch_boost_mode(record, 144U' "$SOURCE"
grep -q 'matches_120 != 1U || matches_144 != 1U' "$SOURCE"
grep -q 'module_param_cb(touch_boost_target_refresh' "$SOURCE"
grep -q 'module_param_named(touch_boost_last_target_refresh' "$SOURCE"
grep -q 'module_param_named(touch_boost_ept_target_matches' "$SOURCE"
grep -q 'module_param_named(touch_boost_ept_target_last_latency_us' "$SOURCE"
grep -q 'module_param_cb(touch_boost_chain_ceiling_refresh' "$SOURCE"
grep -q 'module_param_named(touch_boost_ept_progress_refresh' "$SOURCE"
grep -q 'refresh == READ_ONCE(oc_touch_boost_ept_request_refresh)' "$SOURCE"
grep -q 'WRITE_ONCE(oc_touch_boost_ept_target_refresh, 0U);' "$SOURCE"
grep -q 'target != 120U && target != 144U' "$SOURCE"
grep -q 'oc_touch_boost_request_target_refresh' "$SOURCE"
grep -q 'WRITE_ONCE(oc_touch_boost_last_target_refresh,' "$SOURCE"
grep -q 'static void oc_run_native_boost(u32 target_refresh' "$SOURCE"
grep -q 'static DECLARE_WORK(oc_late_low_guard_work' "$SOURCE"
grep -q 'module_param_cb(late_low_guard_trigger' "$SOURCE"
grep -q 'OC_LATE_LOW_GUARD_WINDOW_NS' "$SOURCE"
grep -q 'count > READ_ONCE(oc_late_low_guard_commit_baseline)' "$SOURCE"
grep -q 'refresh == 10U' "$SOURCE"
grep -q 'schedule_work(&oc_late_low_guard_work)' "$SOURCE"
grep -q 'cancel_work_sync(&oc_late_low_guard_work);' "$SOURCE"
grep -q 'late_low_guard_armed' "$HELPER"
grep -q 'late_low_guard_ready' "$HELPER"
grep -q 'ltpo_after" -eq $((ltpo_before + ltpo_injected))' "$HELPER"
if grep -q '\[ "$ltpo_before" = 12 \]' "$HELPER"; then
	echo 'FAIL: LTPO helper still hard-codes the pre-OTA mode count' >&2
	exit 1
fi
grep -q 'module_param_cb(rise_guard_trigger' "$SOURCE"
grep -q 'module_param_named(rise_guard_ready' "$SOURCE"
grep -q 'module_param_named(rise_guard_target_seen' "$SOURCE"
grep -q 'schedule_work(&oc_rise_guard_work)' "$SOURCE"
grep -q 'cancel_work_sync(&oc_rise_guard_work);' "$SOURCE"
grep -q 'rise_guard_ready' "$HELPER"
if grep -q 'work_busy' "$SOURCE"; then
	echo 'FAIL: native-anchor KO must not add a work_busy symbol dependency' >&2
	exit 1
fi
grep -q 'WRITE_ONCE(oc_physical_commit_mode_id, mode_id);' "$SOURCE"
grep -q 'WRITE_ONCE(oc_physical_commit_ns, ktime_get_ns());' "$SOURCE"
grep -q 'WRITE_ONCE(oc_physical_commit_count,' "$SOURCE"
grep -q 'register_kretprobe(&oc_dsi_display_set_mode_probe)' "$SOURCE"
grep -q 'unregister_kretprobe(&oc_dsi_display_set_mode_probe)' "$SOURCE"
grep -q 'rc = oc_register_physical_commit_hook();' "$SOURCE"
grep -q 'oc_unregister_physical_commit_hook();' "$SOURCE"
grep -q 'rmx5200-ltpo-modes)' "$BUILD"

if grep -Eq 'dsi_panel_tx_cmd_set|iris_send|iris_update_pq_opt|oplus_adfr_property_update' "$WRAPPER"; then
	echo 'FAIL: LTPO wrapper contains an active panel/Iris command sender' >&2
	exit 1
fi

echo 'PASS: RMX5200 LTPO runtime KO is QHD60-cloned, maps all live Iris switch paths to slot 2, and is reversible'
