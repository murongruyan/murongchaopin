#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/ko/rmx5200_adfr_path_probe.c"
BUILD="$ROOT/src/ko/build.sh"

for symbol in \
	oplus_adfr_set_min_fps_attr \
	oplus_adfr_min_fps_update \
	oplus_adfr_display_cmd_set \
	oplus_adfr_panel_cmd_set \
	dsi_panel_tx_cmd_set \
	iris_pt_send_panel_cmd \
	iris_abyp_send_panel_cmd \
	iris_panel_cmd_passthrough; do
	grep -q "symbol_name = \"$symbol\"" "$SOURCE" || {
		echo "FAIL: missing read-only probe for $symbol" >&2
		exit 1
	}
done

grep -q 'register_kprobe(probes\[i\])' "$SOURCE"
grep -q 'unregister_kprobe(probes\[i - 1\])' "$SOURCE"
grep -q 'module_param_string(panel_cmd_trace' "$SOURCE"
grep -q 'append_panel_cmd((u32)regs->regs\[1\])' "$SOURCE"
grep -q 'rmx5200-adfr-path-probe)' "$BUILD"

if grep -Eq 'regs->regs\[[0-9]+\][[:space:]]*=|register_kretprobe|write[bwlq]\(' \
	"$SOURCE"; then
	echo 'FAIL: ADFR path probe contains mutation or return-hook logic' >&2
	exit 1
fi

echo 'PASS: RMX5200 ADFR path probe is read-only and covers DSI/Iris dispatch'
