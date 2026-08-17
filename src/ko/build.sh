#!/bin/sh

set -eu

KERNEL_TREE=${KERNEL_TREE:-/home/murongruyan/android16-kernel-rmx5200}
KERNEL_OUT=${KERNEL_OUT:-/home/murongruyan/rmx5200-kernel-out}
LLVM_TOOLS=${LLVM_TOOLS:-/home/murongruyan/localtools/usr/bin}
KERNEL_SYMVERS=${KERNEL_SYMVERS:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT_DIR=${OUT_DIR:-"$SCRIPT_DIR/../../bin"}

[ -d "$KERNEL_TREE" ] || {
	printf 'kernel tree not found: %s\n' "$KERNEL_TREE" >&2
	exit 1
}
[ -d "$KERNEL_OUT/include/generated" ] || {
	printf 'prepared kernel output not found: %s\n' "$KERNEL_OUT" >&2
	exit 1
}
if [ -n "$KERNEL_SYMVERS" ] && [ -r "$KERNEL_SYMVERS" ]; then
	cp "$KERNEL_SYMVERS" "$KERNEL_OUT/Module.symvers"
fi

mkdir -p "$OUT_DIR"

build_one() {
	module=$1
	source=$2
	tmp=$(mktemp -d)
	cp "$SCRIPT_DIR/$source" "$tmp/source.c"
	printf 'obj-m += %s.o\n%s-y := source.o\n' "$module" "$module" > "$tmp/Makefile"
	PATH="$LLVM_TOOLS:$PATH" make -C "$KERNEL_TREE" O="$KERNEL_OUT" M="$tmp" \
		ARCH=arm64 LLVM=1 LLVM_IAS=1 KBUILD_MODPOST_WARN=1 modules
	install -m 0600 "$tmp/$module.ko" "$OUT_DIR/$module.ko"
	rm -rf "$tmp"
}

build_with_shared_source() {
	module=$1
	source=$2
	shared=$3
	tmp=$(mktemp -d)
	cp "$SCRIPT_DIR/$source" "$tmp/source.c"
	cp "$SCRIPT_DIR/$shared" "$tmp/$shared"
	printf 'obj-m += %s.o\n%s-y := source.o\n' "$module" "$module" > "$tmp/Makefile"
	PATH="$LLVM_TOOLS:$PATH" make -C "$KERNEL_TREE" O="$KERNEL_OUT" M="$tmp" \
		ARCH=arm64 LLVM=1 LLVM_IAS=1 KBUILD_MODPOST_WARN=1 modules
	install -m 0600 "$tmp/$module.ko" "$OUT_DIR/$module.ko"
	rm -rf "$tmp"
}

build_pjd110() {
	pjd_kernel_tree=${PJD_KERNEL_TREE:-/home/murongruyan/oneplus12-kernel-6.1/common}
	pjd_kernel_out=${PJD_KERNEL_OUT:-/home/murongruyan/oneplus12-kernel-6.1/vendor/out-b16}
	pjd_display_root=${PJD_DISPLAY_ROOT:-/home/murongruyan/oneplus12-kernel-6.1/vendor/vendor/qcom/opensource/display-drivers}
	pjd_tmp=$(mktemp -d)
	pjd_provider_tmp=$(mktemp -d)

	[ -d "$pjd_kernel_tree" ] || {
		printf 'PJD110 kernel tree not found: %s\n' "$pjd_kernel_tree" >&2
		exit 1
	}
	[ -d "$pjd_kernel_out/include/generated" ] || {
		printf 'PJD110 prepared kernel output not found: %s\n' "$pjd_kernel_out" >&2
		exit 1
	}
	[ -f "$pjd_display_root/msm/dsi/dsi_display.h" ] || {
		printf 'PJD110 display source not found: %s\n' "$pjd_display_root" >&2
		exit 1
	}

	for pjd_dir in "$pjd_provider_tmp" "$pjd_tmp"; do
		cp -R "$SCRIPT_DIR/vendor_stubs" "$pjd_dir/vendor_stubs"
		mkdir -p "$pjd_dir/vendor_stubs/soc/oplus"
		cp "$pjd_display_root/oplus/common/trackpoint/oplus_trackpoint_report.h" \
			"$pjd_dir/vendor_stubs/soc/oplus/oplus_trackpoint_report.h"
		printf '%s\n' \
			"ccflags-y += -I$pjd_dir/vendor_stubs" \
			"ccflags-y += -I$pjd_display_root" \
			"ccflags-y += -I$pjd_display_root/include" \
			"ccflags-y += -I$pjd_display_root/include/linux" \
			"ccflags-y += -I$pjd_display_root/include/uapi/display" \
			"ccflags-y += -I$pjd_display_root/msm" \
			"ccflags-y += -I$pjd_display_root/msm/dsi" \
			"ccflags-y += -include $pjd_display_root/config/gki_pineappledispconf.h" \
			> "$pjd_dir/profile-flags.mk"
	done

	cp "$SCRIPT_DIR/pjd110_get_main_display_symvers.c" \
		"$pjd_provider_tmp/source.c"
	{
		printf 'include %s/profile-flags.mk\n' "$pjd_provider_tmp"
		printf 'obj-m += pjd110_display_symbol_provider.o\n'
		printf 'pjd110_display_symbol_provider-y := source.o\n'
	} > "$pjd_provider_tmp/Makefile"
	PATH="$LLVM_TOOLS:$PATH" make -C "$pjd_kernel_tree" O="$pjd_kernel_out" \
		M="$pjd_provider_tmp" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
		KBUILD_MODPOST_WARN=1 modules
	grep -q '[[:space:]]get_main_display[[:space:]]' \
		"$pjd_provider_tmp/Module.symvers" || {
		printf 'failed to derive get_main_display symbol CRC\n' >&2
		exit 1
	}
	awk '$2 == "get_main_display" { $3 = "msm_drm" }
		{ printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5 }' \
		"$pjd_provider_tmp/Module.symvers" \
		> "$pjd_provider_tmp/Module.symvers.fixed"
	mv "$pjd_provider_tmp/Module.symvers.fixed" \
		"$pjd_provider_tmp/Module.symvers"

	cp "$SCRIPT_DIR/pjd110_display_modes.c" "$pjd_tmp/source.c"
	cp "$SCRIPT_DIR/plk110_display_modes.c" \
		"$pjd_tmp/plk110_display_modes.c"
	{
		printf 'include %s/profile-flags.mk\n' "$pjd_tmp"
		printf 'obj-m += pjd110_drm_modes.o\n'
		printf 'pjd110_drm_modes-y := source.o\n'
	} > "$pjd_tmp/Makefile"
	PATH="$LLVM_TOOLS:$PATH" make -C "$pjd_kernel_tree" O="$pjd_kernel_out" \
		M="$pjd_tmp" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
		KBUILD_EXTRA_SYMBOLS="$pjd_provider_tmp/Module.symvers" \
		KBUILD_MODPOST_WARN=1 modules
	install -m 0600 "$pjd_tmp/pjd110_drm_modes.ko" \
		"$OUT_DIR/pjd110_drm_modes.ko"
	rm -rf "$pjd_tmp" "$pjd_provider_tmp"
}

case "${1:-all}" in
	rmx5200)
		build_one rmx5200_drm_modes rmx5200_display_modes.c
		;;
	rmx5200-probe)
		build_one rmx5200_stock_probe rmx5200_display_modes.c
		;;
	rmx5200-adfr-probe)
		build_one rmx5200_adfr_probe rmx5200_adfr_probe.c
		;;
	rmx5200-adfr-lock)
		build_one rmx5200_adfr_lock rmx5200_adfr_lock.c
		;;
	pjd110-adfr-lock)
		build_one pjd110_adfr_lock rmx5200_adfr_lock.c
		;;
	rmx5200-adfr-path-probe)
		build_one rmx5200_adfr_path_probe rmx5200_adfr_path_probe.c
		;;
	rmx5200-adfr-slot-probe)
		build_one rmx5200_adfr_slot_probe rmx5200_adfr_slot_probe.c
		;;
	ltpo)
		build_one ltpo rmx5200_native_adfr.c
		;;
	rmx5200-iris-timing-probe)
		build_one rmx5200_iris_timing_probe rmx5200_iris_timing_probe.c
		;;
	rmx5200-iris-switch-probe)
		build_one rmx5200_iris_switch_probe rmx5200_iris_switch_probe.c
		;;
	rmx5200-iris-memc-probe)
		build_one rmx5200_iris_memc_probe rmx5200_iris_memc_probe.c
		;;
	rmx5200-iris-qhd144-unlock)
		build_one rmx5200_iris_qhd144_unlock rmx5200_iris_qhd144_unlock.c
		;;
	rmx5200-frame-activity-probe)
		build_one rmx5200_frame_activity_probe rmx5200_frame_activity_probe.c
		;;
	rmx5200-ltpo-activity)
		build_one rmx5200_ltpo_activity rmx5200_ltpo_activity.c
		;;
	rmx5200-ltpo-modes)
		build_with_shared_source rmx5200_ltpo_modes \
			rmx5200_ltpo_modes.c rmx5200_display_modes.c
		;;
	plk110)
		build_one plk110_drm_modes plk110_display_modes.c
		;;
	pjd110)
		build_pjd110
		;;
	hmbird)
		build_one hmbird hmbird.c
		;;
	all)
		build_one rmx5200_drm_modes rmx5200_display_modes.c
		build_one rmx5200_adfr_lock rmx5200_adfr_lock.c
		build_one plk110_drm_modes plk110_display_modes.c
		build_pjd110
		build_one hmbird hmbird.c
		;;
	*)
		printf 'usage: %s [all|rmx5200|rmx5200-probe|rmx5200-adfr-probe|rmx5200-adfr-lock|pjd110-adfr-lock|rmx5200-adfr-path-probe|rmx5200-adfr-slot-probe|ltpo|rmx5200-iris-timing-probe|rmx5200-iris-switch-probe|rmx5200-iris-memc-probe|rmx5200-iris-qhd144-unlock|rmx5200-frame-activity-probe|rmx5200-ltpo-activity|rmx5200-ltpo-modes|plk110|pjd110|hmbird]\n' "$0" >&2
		exit 2
		;;
esac
printf 'built %s KO target in %s\n' "${1:-all}" "$OUT_DIR"
