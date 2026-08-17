#!/bin/sh

set -eu

[ -f src/ko/rmx5200_display_modes.c ] || exit 1
[ -f src/ko/plk110_display_modes.c ] || exit 1
[ -f src/ko/pjd110_display_modes.c ] || exit 1
[ -f src/ko/build.sh ] || exit 1
[ -f bin/rmx5200_drm_modes.ko ] || {
    echo "FAIL: RMX5200 DRM-KO binary is missing" >&2
    exit 1
}
[ -f bin/plk110_drm_modes.ko ] || {
    echo "FAIL: PLK110 DRM-KO binary is missing" >&2
    exit 1
}
[ -f bin/pjd110_drm_modes.ko ] || {
    echo "FAIL: PJD110 DRM-KO binary is missing" >&2
    exit 1
}
[ -f bin/hmbird.ko ] || {
    echo "FAIL: standalone HMBIRD KO binary is missing" >&2
    exit 1
}

grep -q 'OC_PANEL_NODE "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02"' src/ko/rmx5200_display_modes.c
grep -q 'oc_apply_dynamic_modes' src/ko/rmx5200_display_modes.c
grep -q 'oc_publish_drm_modes' src/ko/rmx5200_display_modes.c
grep -q 'mode_specs' src/ko/rmx5200_display_modes.c
grep -q 'list_move_tail' src/ko/rmx5200_display_modes.c
grep -q 'oc_clone_runtime_priv' src/ko/rmx5200_display_modes.c
grep -q 'runtime_phy_expected' src/ko/rmx5200_display_modes.c
grep -q 'OC_DROP_STOCK_FHD_DEFAULT false' src/ko/rmx5200_display_modes.c
grep -q 'insmod "$KO_MODULE" probe_only=0 drop_stock_fhd=1' scripts/display_backend.sh
grep -q 'oc_prepare_runtime_base' src/ko/rmx5200_display_modes.c
grep -q 'oc_hide_stock_fhd_drm_modes' src/ko/rmx5200_display_modes.c
grep -q 'removed_stock_fhd_count' src/ko/rmx5200_display_modes.c
grep -q 'removed_stock_fhd_drm_count' src/ko/rmx5200_display_modes.c
grep -q 'of_changeset_create_node' src/ko/hmbird.c
grep -q 'dynamic_of' src/ko/hmbird.c
grep -q 'consumer_reinit_supported' src/ko/hmbird.c
grep -q 'v72_vendor_delta' src/ko/rmx5200_display_modes.c
grep -q '0x00, 0x38, 0x0f, 0x0e' src/ko/rmx5200_display_modes.c
grep -q '0x00, 0x3a, 0x0f, 0x0e' src/ko/rmx5200_display_modes.c
grep -q 'drm_mode_vrefresh(mode) != spec->refresh' src/ko/rmx5200_display_modes.c
if grep -Eq 'uniform_180_link|high_rate_porch_comp' src/ko/rmx5200_display_modes.c scripts/display_backend.sh; then
	echo "FAIL: rejected porch-compensation profile is still selectable" >&2
    exit 1
fi
if grep -q 'high_rate_step_down' src/ko/rmx5200_display_modes.c scripts/display_backend.sh; then
    echo "FAIL: refresh-relabel step-down profile is still selectable" >&2
    exit 1
fi
if grep -q 'fixed_185_link' src/ko/rmx5200_display_modes.c scripts/display_backend.sh; then
    echo "FAIL: rejected fixed-link profile is still selectable" >&2
    exit 1
fi
for refresh in 123 150 155 160 165 170 175 180; do
    grep -q "{ ${refresh}U," src/ko/rmx5200_display_modes.c
done
[ "$(sed -n '1p' config/drm_phy_profile.txt)" = stock ]
grep -q 'adfr_command_injection_supported = false' src/ko/rmx5200_display_modes.c
grep -q 'adfr_command_injection_supported' src/ko/rmx5200_display_modes.c
grep -q 'OC_NATIVE_WIDTH 1272U' src/ko/plk110_display_modes.c
grep -q 'OC_NATIVE_WIDTH 1440U' src/ko/pjd110_display_modes.c
grep -q 'OC_NATIVE_HEIGHT 3168U' src/ko/pjd110_display_modes.c
grep -q 'OC_SOURCE_FPS 144U' src/ko/pjd110_display_modes.c
grep -q 'OC_PANEL_TOKEN "AA545_P_3_A0005"' src/ko/pjd110_display_modes.c
grep -q 'offsetof(struct dsi_display, modes)' src/ko/pjd110_display_modes.c
grep -q 'OC_EXPECT_REMOVED_STOCK_LOW 2U' src/ko/pjd110_display_modes.c
grep -q 'removed_stock_low_drm_count' src/ko/plk110_display_modes.c
grep -q 'KO_MODULE_NAME=pjd110_drm_modes' scripts/display_backend.sh
grep -q 'drop_stock_low=1' scripts/display_backend.sh
grep -q 'KO_MODULE="$BIN_DIR/pjd110_drm_modes.ko"' scripts/web_handler.sh
grep -q 'pmb110_170_mode.c' src/ko/rmx5200_display_modes.c
grep -q 'pmb110_170_mode.c' src/ko/plk110_display_modes.c

[ -r config/display_mode_manifest.txt ] || {
    echo "FAIL: shared display mode manifest is missing" >&2
    exit 1
}
MODE_MANIFEST_FILE="$PWD/config/display_mode_manifest.txt"
. scripts/mode_manifest.sh
mode_manifest_validate
[ "$(mode_manifest_specs RMX5200 drm)" = \
  '1440x3136@123;1440x3136@150;1440x3136@155;1440x3136@160;1440x3136@165;1440x3136@170;1440x3136@175;1440x3136@180' ]
[ "$(mode_manifest_specs PLK110 dtbo)" = \
  '1272x2772@123;1272x2772@170;1272x2772@175;1272x2772@180;1272x2772@185;1272x2772@190;1272x2772@195;1272x2772@199' ]
if grep -q 'oc_default_mode_specs' src/ko/rmx5200_display_modes.c src/ko/plk110_display_modes.c; then
    echo "FAIL: KO still contains a second compiled default mode manifest" >&2
    exit 1
fi

if grep -Rqi 'dts_overlay\|CONFIG_OF_OVERLAY' src/ko scripts/display_backend.sh; then
    echo "FAIL: Overlay backend leaked into DRM-KO implementation" >&2
    exit 1
fi

echo "PASS: RMX5200, PLK110 and PJD110 DRM-KO profiles are present"
