// SPDX-License-Identifier: GPL-2.0
/*
 * OnePlus 12 (PJD110) Qualcomm 6.1 DRM-KO profile.
 *
 * The private dsi_display offsets below are compiler-derived from OnePlus'
 * matching SM8650 display source. This keeps the write transaction tied to
 * the 6.1 ABI instead of copying the PLK110 6.12 constants.
 */
#include <msm/dsi/dsi_display.h>

extern struct dsi_display *get_main_display(void);

#define OC_HAVE_GET_MAIN_DISPLAY_DECL 1
#define OC_PROFILE_NAME "pjd110"
#define OC_LOG_PREFIX "pjd110_display_runtime_modes"
#define OC_NATIVE_WIDTH 1440U
#define OC_NATIVE_HEIGHT 3168U
#define OC_SOURCE_FPS 144U
#define OC_MODE_COUNT 4U
#define OC_PANEL_TOKEN "AA545_P_3_A0005"
#define OC_EXPECT_60 1U
#define OC_EXPECT_90 1U
#define OC_EXPECT_120 1U
#define OC_EXPECT_144 1U
#define OC_EXPECT_165 0U
#define OC_DROP_STOCK_LOW_DEFAULT true
#define OC_EXPECT_REMOVED_STOCK_LOW 2U
#define OC_CONNECTOR_OFFSET ((u32)offsetof(struct dsi_display, drm_conn))
#define OC_DISPLAY_LOCK_OFFSET ((u32)offsetof(struct dsi_display, display_lock))
#define OC_EXPECT_DISPLAY_MODES_OFFSET ((u32)offsetof(struct dsi_display, modes))
#define OC_EXPECT_DISPLAY_PANEL_OFFSET ((u32)offsetof(struct dsi_display, panel))
#define OC_MODULE_DESCRIPTION "PJD110 Qualcomm 6.1 DRM-KO mode injector and stock 60/90Hz filter"
#define OC_MODULE_VERSION "0.1-pjd110-6.1-profile"

#include "plk110_display_modes.c"
