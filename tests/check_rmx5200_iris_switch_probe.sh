#!/bin/sh
set -eu

SOURCE=src/ko/rmx5200_iris_switch_probe.c
BUILD=src/ko/build.sh

for symbol in dsi_panel_switch iris_pre_switch iris_switch \
    iris_set_panel_timing iris_update_last_pt_timing \
    iris_update_panel_timing iris_send_timing_switch_pkt \
    iris_timing_switch_setup iris_send_rfb_timing_switch_pkt \
    iris_is_same_timing_from_last_pt iris_is_res_switched_from_last_pt \
    iris_is_freq_switched_from_last_pt iris_is_clk_switched_from_last_pt; do
    grep -q "\"$symbol\"" "$SOURCE"
done
grep -q 'register_kprobe(&probe_states\[i\]->probe)' "$SOURCE"
grep -q 'unregister_kprobe(&probe_states\[i - 1\]->probe)' "$SOURCE"
grep -q 'probe_states\[i - 1\]->probe.addr = NULL' "$SOURCE"
grep -q 'rmx5200-iris-switch-probe)' "$BUILD"

if grep -Eq 'regs->regs\[[0-9]+\][[:space:]]*=|register_kretprobe|write[bwlq]\(' "$SOURCE"; then
    echo 'FAIL: Iris switch probe contains an active mutation path' >&2
    exit 1
fi

echo 'PASS: RMX5200 Iris switch probe is read-only and individually reversible'
