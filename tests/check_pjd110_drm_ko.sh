#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/src/ko/pjd110_display_modes.c"
SHARED="$ROOT/src/ko/plk110_display_modes.c"
BUILD="$ROOT/src/ko/build.sh"
KO="$ROOT/bin/pjd110_drm_modes.ko"

[ -s "$SOURCE" ]
[ -s "$SHARED" ]
[ -s "$KO" ]

grep -q 'OC_NATIVE_WIDTH 1440U' "$SOURCE"
grep -q 'OC_NATIVE_HEIGHT 3168U' "$SOURCE"
grep -q 'OC_SOURCE_FPS 144U' "$SOURCE"
grep -q 'OC_MODE_COUNT 4U' "$SOURCE"
grep -q 'OC_EXPECT_60 1U' "$SOURCE"
grep -q 'OC_EXPECT_90 1U' "$SOURCE"
grep -q 'OC_EXPECT_120 1U' "$SOURCE"
grep -q 'OC_EXPECT_144 1U' "$SOURCE"
grep -q 'OC_DROP_STOCK_LOW_DEFAULT true' "$SOURCE"
grep -q 'offsetof(struct dsi_display, display_lock)' "$SOURCE"
grep -q 'offsetof(struct dsi_display, modes)' "$SOURCE"
grep -q 'offsetof(struct dsi_display, panel)' "$SOURCE"
grep -q 'offsetof(struct dsi_display, drm_conn)' "$SOURCE"

grep -q 'oc_hide_stock_low_drm_modes_locked' "$SHARED"
grep -q 'removed_stock_low_count' "$SHARED"
grep -q 'removed_stock_low_drm_count' "$SHARED"
grep -q 'oc_restore_drm_modes' "$SHARED"
grep -q 'display_modes_offset != OC_EXPECT_DISPLAY_MODES_OFFSET' "$SHARED"
grep -q 'oc_write_pointer(oc_layout.display, display_modes_offset' "$SHARED"
if grep -q 'oc_write_pointer(oc_layout.display, 0x338' "$SHARED"; then
    echo 'FAIL: shared write path still hard-codes the PLK110 modes offset' >&2
    exit 1
fi

grep -q 'pjd110_get_main_display_symvers.c' "$BUILD"
grep -q 'gki_pineappledispconf.h' "$BUILD"
grep -q '$3 = "msm_drm"' "$BUILD"
grep -q 'build_pjd110' "$BUILD"

if command -v modinfo >/dev/null 2>&1; then
    [ "$(modinfo -F name "$KO")" = pjd110_drm_modes ]
    [ "$(modinfo -F depends "$KO")" = msm_drm ]
    modinfo -F vermagic "$KO" | grep -q '^6[.]1[.]141-gd86625c3830b '
fi

echo 'PASS: PJD110 6.1 DRM-KO is compiler-bound, transactional and packaged'
