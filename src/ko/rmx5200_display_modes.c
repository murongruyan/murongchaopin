// SPDX-License-Identifier: GPL-2.0
/*
 * RMX5200 Qualcomm DRM-KO backend.
 *
 * The module does not write DTBO or any partition.  It discovers the primary
 * DSI display through the msm_drm exported get_main_display() helper, verifies
 * the live timing tree and the parsed mode array, removes the four explicit
 * stock FHD records, then appends runtime WQHD modes described by mode_specs.
 * Qualcomm regenerates one dynamic FHD group from that canonical WQHD array,
 * matching the DTBO backend without duplicate 60/90/120/144 Hz candidates.
 * The early loader supplies that string from the
 * module's canonical display_mode_manifest.txt; the KO intentionally keeps no
 * second compiled default list that could drift from the DTBO backend.
 *
 * The implementation follows the live-mode injection pattern used by
 * pmb110_170_mode.c: clone timing data, append verified mode records and DRM
 * modes, keep a rollback copy, and never touch the DTBO block device. Qualcomm's private
 * dsi_display_mode layout is discovered and checked against the live DT before
 * any write. A failed probe is fail-closed.
 */
#include <linux/init.h>
#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
#include <linux/atomic.h>
#include <linux/kprobes.h>
#include <linux/ktime.h>
#include <linux/workqueue.h>
#endif
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <drm/drm_connector.h>
#include <drm/drm_device.h>
#include <drm/drm_modes.h>
#include <drm/drm_probe_helper.h>

/* Exported by the OnePlus msm_drm module.  The object type is intentionally
 * opaque; all members are discovered and validated at runtime below. */
extern void *get_main_display(void);

#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
struct iris_cmd_desc;

struct iris_cmd_set {
	u32 state;
	u32 count;
	struct iris_cmd_desc *cmds;
};

struct iris_mode_info {
	u32 h_active;
	u32 h_back_porch;
	u32 h_sync_width;
	u32 h_front_porch;
	u32 v_active;
	u32 v_back_porch;
	u32 v_sync_width;
	u32 v_front_porch;
	u32 refresh_rate;
	u64 clk_rate_hz;
	u32 mdp_transfer_time_us;
	bool dsc_enabled;
};

extern void iris_pre_switch(struct iris_mode_info *new_timing);
extern int dsi_panel_tx_cmd_set(void *panel, unsigned int type,
	bool do_peripheral_flush);

#define OC_NATIVE_WIDTH 1440U
#define OC_NATIVE_HEIGHT 3136U
#define OC_SOURCE_FPS 60U
/* The Web backend may add or remove timing nodes.  Low-refresh discovery must
 * therefore validate the live DT multiset and semantic anchors, never a fixed
 * stock/OTA mode count. */
#define OC_MIN_REFRESH 1U
#define OC_HIGHEST_FPS 60U
#define OC_DEFAULT_MODE_SPECS \
	"1440x3136@30:1113600000;1440x3136@10:1113600000;1440x3136@1:1113600000"
#define OC_DROP_STOCK_FHD_DEFAULT false
#define OC_LOW_LINK_CLOCK 1113600000ULL
#define OC_LOW_LINK_TRANSFER_US 6800U
#define OC_IRIS_TIMING_HEIGHT_OFFSET 0x10U
#define OC_IRIS_TIMING_REFRESH_OFFSET 0x20U
#define OC_IRIS_WQHD60_SLOT 2U
#define OC_PANEL_LOCK_OFFSET 0x410U
#define OC_PANEL_CUR_MODE_OFFSET 0x598U
#define OC_TIMING_SWITCH_CMDSET_OFFSET 0x2a0U
#define OC_CMDSET_TYPE_OFFSET 0x00U
#define OC_CMDSET_STATE_OFFSET 0x04U
#define OC_CMDSET_COUNT_OFFSET 0x08U
#define OC_CMDSET_CMDS_OFFSET 0x10U
#define OC_TIMING_SWITCH_CMDSET_TYPE 21U
#define OC_WQHD120_CLOCK 1452000000ULL
#define OC_WQHD120_TRANSFER_US 6800U
#define OC_WQHD120_SWITCH_CMD_COUNT 20U
#define OC_WQHD144_CLOCK 1452000000ULL
#define OC_WQHD144_TRANSFER_US 6800U
#define OC_WQHD144_SWITCH_CMD_COUNT 20U
#define OC_TOUCH_BOOST_EPT_BYPASS_WINDOW_NS (4500ULL * NSEC_PER_MSEC)
#define OC_TOUCH_BOOST_EPT_POST_RECEIPT_WINDOW_NS (250ULL * NSEC_PER_MSEC)
#define OC_TOUCH_BOOST_EPT_BYPASS_MAX_HITS 2U
#define OC_LATE_LOW_GUARD_WINDOW_NS (4500ULL * NSEC_PER_MSEC)
#define OC_RISE_GUARD_WINDOW_NS (8000ULL * NSEC_PER_MSEC)
#define OC_RISE_GUARD_TARGET_WINDOW_NS (2700ULL * NSEC_PER_MSEC)
#define OC_TOUCH_BOOST_CESTA_EPT_ENTRY_OFFSET 0x164U
#define OC_TOUCH_BOOST_CESTA_EPT_RESUME_OFFSET 0x618U
#define OC_TOUCH_BOOST_CESTA_BEGIN_COMMIT 1U
#define OC_TOUCH_BOOST_CESTA_ENABLE_COMMIT 3U
#else
#define OC_NATIVE_WIDTH 1080U
#define OC_NATIVE_HEIGHT 2352U
#define OC_SOURCE_FPS 144U
#define OC_MODE_COUNT 8U
#define OC_MIN_REFRESH 20U
#define OC_HIGHEST_FPS 180U
#define OC_DEFAULT_MODE_SPECS ""
#define OC_DROP_STOCK_FHD_DEFAULT true
#endif
#define OC_STOCK_FHD_COUNT 4U
#define OC_TARGET_MODE_COUNT 3U
#define OC_MAX_RUNTIME_MODES 32U
#define OC_MAX_SPEC_MODES 32U
#define OC_MAX_SPEC_TEXT 2048U
#define OC_WQHD_WIDTH 1440U
#define OC_WQHD_HEIGHT 3136U
#define OC_PANEL_NODE "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02"
#define OC_MAX_REFRESH 300U
#define OC_MAX_DT_MODES 32U
#define OC_MAX_DISPLAY_SCAN 0x800U
#define OC_CONNECTOR_OFFSET 0x10U
#define OC_MIN_MODE_STRIDE 0x80U
#define OC_MAX_MODE_STRIDE 0x200U
#define OC_MAX_PRIV_SCAN 0x4000U
#define OC_MAX_PRIV_SIZE 0x10000U
#define OC_MAX_PROPERTIES 256U
#define OC_MAX_FIELD_POSITIONS 8U
#define OC_INVALID_OFFSET (~0U)
#define OC_PRIV_PHY_VALUES_OFFSET 0x1da0U
#define OC_PRIV_PHY_LENGTH_OFFSET 0x1da8U
#define OC_PHY_TIMING_LENGTH 14U
#define OC_PHY_TIMING_BYTES (OC_PHY_TIMING_LENGTH * sizeof(u32))
#define OC_PHY_PROFILE_TEXT 32U
#define OC_ADFR_PROFILE_TEXT 96U
#define OC_ADFR_STATE_TEXT 32U
#define OC_ADFR_COMMAND_FAMILY_TEXT 48U
#define OC_ADFR_PROFILE_ID "ae084-dvt02-ltpo1hz-dry-run-v1"
#define OC_ADFR_STATE "dry-run"
#define OC_ADFR_COMMAND_FAMILY "F0_55_AA_52"
#define OC_MODE_H_BACK_PORCH_OFFSET 0x04U
#define OC_MODE_H_SYNC_WIDTH_OFFSET 0x08U
#define OC_MODE_H_FRONT_PORCH_OFFSET 0x0cU
#define OC_MODE_V_BACK_PORCH_OFFSET 0x1cU
#define OC_MODE_V_SYNC_WIDTH_OFFSET 0x20U
#define OC_MODE_V_FRONT_PORCH_OFFSET 0x24U

static const u32 oc_stock_144_phy[OC_PHY_TIMING_LENGTH] = {
	0x00, 0x2f, 0x0c, 0x0c, 0x1e, 0x1b, 0x0c,
	0x0d, 0x0c, 0x02, 0x04, 0x00, 0x26, 0x11
};

struct oc_phy_target {
	u32 refresh;
	u64 clock;
	u32 timing[OC_PHY_TIMING_LENGTH];
};

/* Qualcomm v7.2 calculator deltas relative to the vendor-tuned 144 Hz
 * baseline. These are opt-in because the panel vendor's absolute values do
 * not match the generic calculator output. */
static const struct oc_phy_target oc_vendor_delta_phy[] = {
	{ 123U, 1488300000ULL,
		{ 0x00, 0x2f, 0x0d, 0x0d, 0x1e, 0x1b, 0x0d,
		  0x0d, 0x0c, 0x02, 0x04, 0x00, 0x26, 0x11 } },
	{ 150U, 1512500000ULL,
		{ 0x00, 0x30, 0x0d, 0x0d, 0x1e, 0x1b, 0x0d,
		  0x0d, 0x0c, 0x02, 0x04, 0x00, 0x26, 0x11 } },
	{ 155U, 1562916666ULL,
		{ 0x00, 0x32, 0x0d, 0x0d, 0x1f, 0x1c, 0x0d,
		  0x0e, 0x0c, 0x02, 0x04, 0x00, 0x2a, 0x12 } },
	{ 160U, 1613333333ULL,
		{ 0x00, 0x33, 0x0e, 0x0e, 0x20, 0x1d, 0x0d,
		  0x0e, 0x0d, 0x02, 0x04, 0x00, 0x2a, 0x11 } },
	{ 165U, 1663750000ULL,
		{ 0x00, 0x35, 0x0e, 0x0e, 0x20, 0x1d, 0x0e,
		  0x0e, 0x0d, 0x02, 0x04, 0x00, 0x2a, 0x11 } },
	{ 170U, 1714166666ULL,
		{ 0x00, 0x36, 0x0f, 0x0e, 0x21, 0x1e, 0x0e,
		  0x0f, 0x0d, 0x02, 0x04, 0x00, 0x2f, 0x13 } },
	{ 175U, 1764583333ULL,
		{ 0x00, 0x38, 0x0f, 0x0e, 0x22, 0x1e, 0x0f,
		  0x0f, 0x0e, 0x02, 0x04, 0x00, 0x2f, 0x13 } },
	{ 180U, 1815000000ULL,
		{ 0x00, 0x3a, 0x0f, 0x0e, 0x22, 0x1f, 0x0f,
		  0x10, 0x0e, 0x02, 0x04, 0x00, 0x2f, 0x13 } },
};

static char mode_specs[OC_MAX_SPEC_TEXT] = OC_DEFAULT_MODE_SPECS;
module_param_string(mode_specs, mode_specs, sizeof(mode_specs), 0400);
MODULE_PARM_DESC(mode_specs,
	"Semicolon separated modes: widthxheight@refresh[:clock_hz[:transfer_us[:source_refresh]]]");

static bool dynamic_modes = true;
module_param(dynamic_modes, bool, 0400);
MODULE_PARM_DESC(dynamic_modes,
	"Use the live timing canonicalization and append transaction");

static bool drop_stock_fhd = OC_DROP_STOCK_FHD_DEFAULT;
module_param(drop_stock_fhd, bool, 0400);
MODULE_PARM_DESC(drop_stock_fhd,
	"Remove explicit stock FHD modes before Qualcomm generates the dynamic FHD group");

static char phy_profile[OC_PHY_PROFILE_TEXT] = "stock";
module_param_string(phy_profile, phy_profile, sizeof(phy_profile), 0400);
MODULE_PARM_DESC(phy_profile,
	"DSI PHY profile: stock or v72_vendor_delta");

/* The kernel module cannot safely read a module-directory config file. The
 * early loader passes these fields from the same AE084 profile consumed by
 * process_dts, and the module rejects any mismatch before touching modes. */
static char adfr_profile_id[OC_ADFR_PROFILE_TEXT] = OC_ADFR_PROFILE_ID;
module_param_string(adfr_profile_id, adfr_profile_id, sizeof(adfr_profile_id), 0400);
MODULE_PARM_DESC(adfr_profile_id,
	"Shared AE084 ADFR profile identifier");

static char adfr_profile_state[OC_ADFR_STATE_TEXT] = OC_ADFR_STATE;
module_param_string(adfr_profile_state, adfr_profile_state,
	sizeof(adfr_profile_state), 0400);
MODULE_PARM_DESC(adfr_profile_state,
	"Shared AE084 ADFR profile state; dry-run is parser-only");

static char adfr_command_family[OC_ADFR_COMMAND_FAMILY_TEXT] =
	OC_ADFR_COMMAND_FAMILY;
module_param_string(adfr_command_family, adfr_command_family,
	sizeof(adfr_command_family), 0400);
MODULE_PARM_DESC(adfr_command_family,
	"AE084 DDIC command family recorded by the shared profile");

static bool adfr_profile_valid;
module_param(adfr_profile_valid, bool, 0444);
MODULE_PARM_DESC(adfr_profile_valid,
	"Whether the loader-supplied AE084 profile matches this KO");

static bool adfr_command_injection_supported;
module_param(adfr_command_injection_supported, bool, 0444);
MODULE_PARM_DESC(adfr_command_injection_supported,
	"False until AE084 command payloads are independently verified");

static bool phy_profile_applied;
module_param(phy_profile_applied, bool, 0444);
MODULE_PARM_DESC(phy_profile_applied,
	"Whether an opt-in DSI PHY profile changed at least one injected mode");

static unsigned int phy_profile_mode_count;
module_param(phy_profile_mode_count, uint, 0444);
MODULE_PARM_DESC(phy_profile_mode_count,
	"Number of injected modes using the opt-in DSI PHY profile");

static bool probe_only;
module_param(probe_only, bool, 0444);
MODULE_PARM_DESC(probe_only, "Probe and log the runtime layout without applying it");

static bool applied;
module_param(applied, bool, 0444);
MODULE_PARM_DESC(applied, "Whether the live timing replacement succeeded");

static bool cache_applied;
module_param(cache_applied, bool, 0444);
MODULE_PARM_DESC(cache_applied, "Whether the parsed mode array replacement succeeded");

static unsigned int failure_code;
module_param(failure_code, uint, 0444);
MODULE_PARM_DESC(failure_code, "Fail-closed probe error code");

static unsigned long long display_address;
module_param(display_address, ullong, 0444);
static unsigned int display_panel_offset = OC_INVALID_OFFSET;
module_param(display_panel_offset, uint, 0444);
static unsigned int display_modes_offset = OC_INVALID_OFFSET;
module_param(display_modes_offset, uint, 0444);
static unsigned int panel_count_offset = OC_INVALID_OFFSET;
module_param(panel_count_offset, uint, 0444);
static unsigned int panel_count_fields;
module_param(panel_count_fields, uint, 0444);
static unsigned int mode_count_before;
module_param(mode_count_before, uint, 0444);
static unsigned int mode_count_after;
module_param(mode_count_after, uint, 0444);
static unsigned int mode_stride;
module_param(mode_stride, uint, 0444);
static unsigned int mode_width_offset = OC_INVALID_OFFSET;
module_param(mode_width_offset, uint, 0444);
static unsigned int mode_height_offset = OC_INVALID_OFFSET;
module_param(mode_height_offset, uint, 0444);
static unsigned int mode_refresh_offset = OC_INVALID_OFFSET;
module_param(mode_refresh_offset, uint, 0444);
static unsigned int mode_clock_offset = OC_INVALID_OFFSET;
module_param(mode_clock_offset, uint, 0444);
static unsigned int mode_pixel_offset = OC_INVALID_OFFSET;
module_param(mode_pixel_offset, uint, 0444);
static unsigned int mode_index_offset = OC_INVALID_OFFSET;
module_param(mode_index_offset, uint, 0444);
static unsigned int mode_priv_offset = OC_INVALID_OFFSET;
module_param(mode_priv_offset, uint, 0444);
static unsigned int priv_clock_offset = OC_INVALID_OFFSET;
module_param(priv_clock_offset, uint, 0444);
static unsigned int priv_transfer_offset = OC_INVALID_OFFSET;
module_param(priv_transfer_offset, uint, 0444);
static unsigned int priv_phy_values_offset = OC_INVALID_OFFSET;
module_param(priv_phy_values_offset, uint, 0444);
static unsigned int priv_phy_length_offset = OC_INVALID_OFFSET;
module_param(priv_phy_length_offset, uint, 0444);
static unsigned int priv_phy_length;
module_param(priv_phy_length, uint, 0444);
static unsigned int source_mode_index = OC_INVALID_OFFSET;
module_param(source_mode_index, uint, 0444);
static unsigned int source_clock_hz;
module_param(source_clock_hz, uint, 0444);
static unsigned int target_clock_hz;
module_param(target_clock_hz, uint, 0444);
static unsigned int connector_mode_count_before;
module_param(connector_mode_count_before, uint, 0444);
static unsigned int connector_mode_count_after;
module_param(connector_mode_count_after, uint, 0444);
static unsigned int connector_hotplug_sent;
module_param(connector_hotplug_sent, uint, 0444);
static unsigned int injected_mode_count;
module_param(injected_mode_count, uint, 0444);
static unsigned int removed_stock_fhd_count;
module_param(removed_stock_fhd_count, uint, 0444);
MODULE_PARM_DESC(removed_stock_fhd_count,
	"Number of explicit stock FHD records removed from the runtime mode array");
static unsigned int removed_stock_fhd_drm_count;
module_param(removed_stock_fhd_drm_count, uint, 0444);
MODULE_PARM_DESC(removed_stock_fhd_drm_count,
	"Number of explicit stock FHD connector modes hidden until KO unload");

static unsigned int dt_mode_count;
module_param(dt_mode_count, uint, 0444);
MODULE_PARM_DESC(dt_mode_count,
	"Number of AE084 timing nodes discovered from the live DT");

static bool oc_adfr_profile_matches(void)
{
	return !strcmp(adfr_profile_id, OC_ADFR_PROFILE_ID) &&
		!strcmp(adfr_profile_state, OC_ADFR_STATE) &&
		!strcmp(adfr_command_family, OC_ADFR_COMMAND_FAMILY);
}

struct oc_dt_state {
	struct device_node *source_node;
	struct device_node *target_nodes[OC_TARGET_MODE_COUNT];
	struct device_node *timings_parent;
	u32 source_clock;
	u32 source_property_count;
	u32 width[OC_MAX_DT_MODES];
	u32 height[OC_MAX_DT_MODES];
	u32 fps[OC_MAX_DT_MODES];
	u32 clock[OC_MAX_DT_MODES];
	u32 transfer_time_us[OC_MAX_DT_MODES];
	unsigned int count;
	unsigned int target_count;
};

struct oc_mode_spec {
	u32 width;
	u32 height;
	u32 refresh;
	u64 clock;
	u32 transfer_time_us;
	u32 source_refresh;
	u32 h_front_porch;
	u32 v_front_porch;
};

struct oc_mode_layout {
	void *display;
	void *panel;
	void *modes;
	u32 count;
	u32 stride;
	u32 width_offset;
	u32 height_offset;
	u32 refresh_offset;
	u32 clock_offset;
	u32 pixel_offset;
	u32 index_offset;
	u32 priv_offset;
	u32 priv_clock_offset;
	u32 priv_transfer_offset;
	u32 priv_phy_values_offset;
	u32 priv_phy_length_offset;
	u32 priv_phy_length;
	u32 source_index;
	void *source_priv;
	size_t source_priv_size;
	u32 source_pixel;
	u64 source_clock;
	u32 panel_count_offsets[2];
	u32 panel_count_values[2];
	unsigned int panel_count_fields;
	struct drm_connector *connector;
	void *original_modes;
	void *runtime_modes;
	u32 runtime_base_count;
	u32 runtime_count;
	u32 runtime_added;
	void *runtime_priv[OC_MAX_SPEC_MODES];
	u32 runtime_priv_count;
	void *runtime_phy[OC_MAX_SPEC_MODES];
	u32 runtime_phy_expected[OC_MAX_SPEC_MODES][OC_PHY_TIMING_LENGTH];
	struct oc_mode_spec runtime_specs[OC_MAX_SPEC_MODES];
	struct drm_display_mode *runtime_drm_modes[OC_MAX_SPEC_MODES];
	u32 runtime_drm_count;
	struct drm_display_mode *hidden_stock_fhd_modes[OC_STOCK_FHD_COUNT];
	u32 hidden_stock_fhd_count;
};

static struct oc_dt_state oc_dt;
static struct oc_mode_layout oc_layout;
static u8 *oc_saved_modes;
static size_t oc_saved_modes_size;
static bool oc_read_mem(const void *address, void *buffer, size_t size);

#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
enum oc_touch_boost_skip_reason {
	OC_TOUCH_BOOST_SKIP_NONE = 0,
	OC_TOUCH_BOOST_SKIP_NOT_READY,
	OC_TOUCH_BOOST_SKIP_NOT_APPLIED,
	OC_TOUCH_BOOST_SKIP_NO_PANEL,
	OC_TOUCH_BOOST_SKIP_NO_CURRENT_MODE,
	OC_TOUCH_BOOST_SKIP_GEOMETRY,
	OC_TOUCH_BOOST_SKIP_NOT_LOW_MODE,
	OC_TOUCH_BOOST_SKIP_CMDSET_CHANGED,
};

static void oc_touch_boost_worker(struct work_struct *work);
static void oc_late_low_guard_worker(struct work_struct *work);
static void oc_rise_guard_worker(struct work_struct *work);
static int oc_touch_boost_trigger_set(const char *value,
	const struct kernel_param *kp);
static int oc_touch_boost_target_set(const char *value,
	const struct kernel_param *kp);
static int oc_late_low_guard_trigger_set(const char *value,
	const struct kernel_param *kp);
static int oc_rise_guard_trigger_set(const char *value,
	const struct kernel_param *kp);
static DECLARE_WORK(oc_touch_boost_work, oc_touch_boost_worker);
static DECLARE_WORK(oc_late_low_guard_work, oc_late_low_guard_worker);
static DECLARE_WORK(oc_rise_guard_work, oc_rise_guard_worker);
static struct iris_mode_info oc_touch_boost_timing;
static struct iris_cmd_set oc_touch_boost_cmdset;
static struct iris_mode_info oc_touch_boost_timing_144;
static struct iris_cmd_set oc_touch_boost_cmdset_144;
static bool oc_touch_boost_ready;
static bool oc_touch_boost_enabled;
static bool oc_touch_boost_one_shot = true;
static unsigned int oc_touch_boost_trigger;
static unsigned int oc_touch_boost_source_index = OC_INVALID_OFFSET;
static unsigned int oc_touch_boost_source_index_144 = OC_INVALID_OFFSET;
static unsigned int oc_touch_boost_cmd_state;
static unsigned int oc_touch_boost_cmd_count;
static unsigned int oc_touch_boost_target_refresh = 120U;
static unsigned int oc_touch_boost_request_target_refresh = 120U;
static unsigned int oc_touch_boost_last_target_refresh;
static unsigned int oc_touch_boost_attempts;
static unsigned int oc_touch_boost_successes;
static unsigned int oc_touch_boost_failures;
static unsigned int oc_touch_boost_skips;
static unsigned int oc_touch_boost_timing_pkt_sends;
static unsigned int oc_touch_boost_panel_tx_sends;
static unsigned int oc_touch_boost_last_skip;
static unsigned int oc_touch_boost_last_source_refresh;
static int oc_touch_boost_last_result;
static unsigned long long oc_touch_boost_request_ns;
static unsigned long long oc_touch_boost_last_latency_us;
static bool oc_late_low_guard_armed;
static unsigned int oc_late_low_guard_trigger;
static unsigned int oc_late_low_guard_target_refresh = 120U;
static unsigned int oc_late_low_guard_request_target_refresh = 120U;
static unsigned int oc_late_low_guard_commit_baseline;
static unsigned int oc_late_low_guard_armed_count;
static unsigned int oc_late_low_guard_matches;
static unsigned int oc_late_low_guard_recoveries;
static unsigned int oc_late_low_guard_failures;
static unsigned int oc_late_low_guard_expired;
static unsigned int oc_late_low_guard_last_target_refresh;
static unsigned long long oc_late_low_guard_armed_ns;
static unsigned long long oc_late_low_guard_last_latency_us;
static bool oc_rise_guard_ready;
static bool oc_rise_guard_armed;
static unsigned int oc_rise_guard_trigger;
static unsigned int oc_rise_guard_target_refresh;
static unsigned int oc_rise_guard_anchor_refresh;
static unsigned int oc_rise_guard_request_anchor_refresh;
static unsigned int oc_rise_guard_commit_baseline;
static unsigned int oc_rise_guard_armed_count;
static unsigned int oc_rise_guard_matches;
static unsigned int oc_rise_guard_replays;
static unsigned int oc_rise_guard_recoveries;
static unsigned int oc_rise_guard_successes;
static unsigned int oc_rise_guard_failures;
static unsigned int oc_rise_guard_expired;
static unsigned int oc_rise_guard_last_target_refresh;
static unsigned int oc_rise_guard_last_match_refresh;
static unsigned int oc_rise_guard_progress_refresh;
static int oc_rise_guard_last_result;
static unsigned long long oc_rise_guard_armed_ns;
static bool oc_rise_guard_target_seen;
static unsigned long long oc_rise_guard_target_seen_ns;
static unsigned long long oc_rise_guard_last_latency_us;
static bool oc_touch_boost_ept_bypass_registered;
static bool oc_touch_boost_ept_scope_registered;
static bool oc_touch_boost_cesta_ept_bypass_registered;
static bool oc_touch_boost_ept_bypass_armed;
static bool oc_touch_boost_ept_scope_active;
static bool oc_touch_boost_cesta_ept_bypass_used;
static bool oc_touch_boost_ept_target_receipt_seen;
static atomic_t oc_touch_boost_cesta_ept_claimed = ATOMIC_INIT(0);
static atomic_t oc_touch_boost_ept_request_claimed = ATOMIC_INIT(0);
static bool oc_touch_boost_ept_chain_accepting;
static unsigned int oc_touch_boost_chain_ceiling_refresh = 144U;
static unsigned int oc_touch_boost_ept_progress_refresh;
static unsigned int oc_touch_boost_ept_bypass_hits;
static unsigned int oc_touch_boost_ept_bypass_expired;
static unsigned int oc_touch_boost_ept_bypass_remaining;
static unsigned int oc_touch_boost_ept_scope_entries;
static unsigned int oc_touch_boost_ept_scope_completions;
static unsigned int oc_touch_boost_ept_scope_owner_pid;
static unsigned int oc_touch_boost_ept_source_refresh;
static unsigned int oc_touch_boost_ept_target_refresh;
static unsigned int oc_touch_boost_ept_request_refresh;
static unsigned int oc_touch_boost_ept_request_claims;
static unsigned int oc_touch_boost_ept_target_matches;
static unsigned int oc_touch_boost_ept_receipt_claims;
static unsigned int oc_touch_boost_cesta_ept_bypass_hits;
static unsigned long long oc_touch_boost_ept_bypass_armed_ns;
static unsigned long long oc_touch_boost_ept_target_receipt_ns;
static unsigned long long oc_touch_boost_ept_bypass_last_latency_us;
static unsigned long long oc_touch_boost_cesta_ept_bypass_last_latency_us;
static unsigned long long oc_touch_boost_ept_target_last_latency_us;
static void oc_touch_boost_ept_clear_chain(void);
static int oc_touch_boost_chain_ceiling_set(const char *value,
	const struct kernel_param *kp);
static const struct kernel_param_ops oc_touch_boost_trigger_ops = {
	.set = oc_touch_boost_trigger_set,
	.get = param_get_uint,
};
static const struct kernel_param_ops oc_touch_boost_target_ops = {
	.set = oc_touch_boost_target_set,
	.get = param_get_uint,
};
static const struct kernel_param_ops oc_touch_boost_chain_ceiling_ops = {
	.set = oc_touch_boost_chain_ceiling_set,
	.get = param_get_uint,
};
static const struct kernel_param_ops oc_late_low_guard_trigger_ops = {
	.set = oc_late_low_guard_trigger_set,
	.get = param_get_uint,
};
static const struct kernel_param_ops oc_rise_guard_trigger_ops = {
	.set = oc_rise_guard_trigger_set,
	.get = param_get_uint,
};

module_param_named(touch_boost_ready, oc_touch_boost_ready, bool, 0444);
module_param_named(touch_boost_enabled, oc_touch_boost_enabled, bool, 0600);
module_param_named(touch_boost_one_shot, oc_touch_boost_one_shot, bool, 0600);
module_param_cb(touch_boost_trigger, &oc_touch_boost_trigger_ops,
	&oc_touch_boost_trigger, 0600);
module_param_named(touch_boost_source_index, oc_touch_boost_source_index,
	uint, 0444);
module_param_named(touch_boost_source_index_144,
	oc_touch_boost_source_index_144, uint, 0444);
module_param_named(touch_boost_cmd_state, oc_touch_boost_cmd_state,
	uint, 0444);
module_param_named(touch_boost_cmd_count, oc_touch_boost_cmd_count,
	uint, 0444);
module_param_cb(touch_boost_target_refresh, &oc_touch_boost_target_ops,
	&oc_touch_boost_target_refresh, 0600);
module_param_named(touch_boost_last_target_refresh,
	oc_touch_boost_last_target_refresh, uint, 0444);
module_param_named(touch_boost_attempts, oc_touch_boost_attempts, uint, 0444);
module_param_named(touch_boost_successes, oc_touch_boost_successes,
	uint, 0444);
module_param_named(touch_boost_failures, oc_touch_boost_failures,
	uint, 0444);
module_param_named(touch_boost_skips, oc_touch_boost_skips, uint, 0444);
module_param_named(touch_boost_timing_pkt_sends,
	oc_touch_boost_timing_pkt_sends, uint, 0444);
module_param_named(touch_boost_panel_tx_sends,
	oc_touch_boost_panel_tx_sends, uint, 0444);
module_param_named(touch_boost_last_skip, oc_touch_boost_last_skip,
	uint, 0444);
module_param_named(touch_boost_last_source_refresh,
	oc_touch_boost_last_source_refresh, uint, 0444);
module_param_named(touch_boost_last_result, oc_touch_boost_last_result,
	int, 0444);
module_param_named(touch_boost_last_latency_us,
	oc_touch_boost_last_latency_us, ullong, 0444);
module_param_cb(late_low_guard_trigger, &oc_late_low_guard_trigger_ops,
	&oc_late_low_guard_trigger, 0600);
module_param_named(late_low_guard_target_refresh,
	oc_late_low_guard_target_refresh, uint, 0600);
module_param_named(late_low_guard_armed, oc_late_low_guard_armed, bool, 0444);
module_param_named(late_low_guard_armed_count,
	oc_late_low_guard_armed_count, uint, 0444);
module_param_named(late_low_guard_matches, oc_late_low_guard_matches,
	uint, 0444);
module_param_named(late_low_guard_recoveries,
	oc_late_low_guard_recoveries, uint, 0444);
module_param_named(late_low_guard_failures, oc_late_low_guard_failures,
	uint, 0444);
module_param_named(late_low_guard_expired, oc_late_low_guard_expired,
	uint, 0444);
module_param_named(late_low_guard_last_target_refresh,
	oc_late_low_guard_last_target_refresh, uint, 0444);
module_param_named(late_low_guard_last_latency_us,
	oc_late_low_guard_last_latency_us, ullong, 0444);
module_param_named(rise_guard_ready, oc_rise_guard_ready, bool, 0444);
module_param_named(rise_guard_armed, oc_rise_guard_armed, bool, 0444);
module_param_cb(rise_guard_trigger, &oc_rise_guard_trigger_ops,
	&oc_rise_guard_trigger, 0600);
module_param_named(rise_guard_target_refresh,
	oc_rise_guard_target_refresh, uint, 0600);
module_param_named(rise_guard_anchor_refresh,
	oc_rise_guard_anchor_refresh, uint, 0600);
module_param_named(rise_guard_armed_count,
	oc_rise_guard_armed_count, uint, 0444);
module_param_named(rise_guard_matches, oc_rise_guard_matches, uint, 0444);
module_param_named(rise_guard_replays, oc_rise_guard_replays, uint, 0444);
module_param_named(rise_guard_recoveries,
	oc_rise_guard_recoveries, uint, 0444);
module_param_named(rise_guard_successes,
	oc_rise_guard_successes, uint, 0444);
module_param_named(rise_guard_failures, oc_rise_guard_failures, uint, 0444);
module_param_named(rise_guard_expired, oc_rise_guard_expired, uint, 0444);
module_param_named(rise_guard_last_target_refresh,
	oc_rise_guard_last_target_refresh, uint, 0444);
module_param_named(rise_guard_last_match_refresh,
	oc_rise_guard_last_match_refresh, uint, 0444);
module_param_named(rise_guard_progress_refresh,
	oc_rise_guard_progress_refresh, uint, 0444);
module_param_named(rise_guard_last_result,
	oc_rise_guard_last_result, int, 0444);
module_param_named(rise_guard_target_seen,
	oc_rise_guard_target_seen, bool, 0444);
module_param_named(rise_guard_last_latency_us,
	oc_rise_guard_last_latency_us, ullong, 0444);
module_param_named(touch_boost_ept_bypass_registered,
	oc_touch_boost_ept_bypass_registered, bool, 0444);
module_param_named(touch_boost_ept_scope_registered,
	oc_touch_boost_ept_scope_registered, bool, 0444);
module_param_named(touch_boost_cesta_ept_bypass_registered,
	oc_touch_boost_cesta_ept_bypass_registered, bool, 0444);
module_param_named(touch_boost_ept_bypass_armed,
	oc_touch_boost_ept_bypass_armed, bool, 0444);
module_param_named(touch_boost_ept_scope_active,
	oc_touch_boost_ept_scope_active, bool, 0444);
module_param_named(touch_boost_cesta_ept_bypass_used,
	oc_touch_boost_cesta_ept_bypass_used, bool, 0444);
module_param_named(touch_boost_ept_target_receipt_seen,
	oc_touch_boost_ept_target_receipt_seen, bool, 0444);
module_param_named(touch_boost_ept_bypass_hits,
	oc_touch_boost_ept_bypass_hits, uint, 0444);
module_param_named(touch_boost_ept_bypass_expired,
	oc_touch_boost_ept_bypass_expired, uint, 0444);
module_param_named(touch_boost_ept_bypass_remaining,
	oc_touch_boost_ept_bypass_remaining, uint, 0444);
module_param_named(touch_boost_ept_scope_entries,
	oc_touch_boost_ept_scope_entries, uint, 0444);
module_param_named(touch_boost_ept_scope_completions,
	oc_touch_boost_ept_scope_completions, uint, 0444);
module_param_named(touch_boost_ept_scope_owner_pid,
	oc_touch_boost_ept_scope_owner_pid, uint, 0444);
module_param_named(touch_boost_ept_source_refresh,
	oc_touch_boost_ept_source_refresh, uint, 0444);
module_param_named(touch_boost_ept_target_refresh,
	oc_touch_boost_ept_target_refresh, uint, 0444);
module_param_cb(touch_boost_chain_ceiling_refresh,
	&oc_touch_boost_chain_ceiling_ops,
	&oc_touch_boost_chain_ceiling_refresh, 0600);
module_param_named(touch_boost_ept_chain_accepting,
	oc_touch_boost_ept_chain_accepting, bool, 0444);
module_param_named(touch_boost_ept_progress_refresh,
	oc_touch_boost_ept_progress_refresh, uint, 0444);
module_param_named(touch_boost_ept_request_refresh,
	oc_touch_boost_ept_request_refresh, uint, 0444);
module_param_named(touch_boost_ept_request_claims,
	oc_touch_boost_ept_request_claims, uint, 0444);
module_param_named(touch_boost_ept_target_matches,
	oc_touch_boost_ept_target_matches, uint, 0444);
module_param_named(touch_boost_ept_receipt_claims,
	oc_touch_boost_ept_receipt_claims, uint, 0444);
module_param_named(touch_boost_cesta_ept_bypass_hits,
	oc_touch_boost_cesta_ept_bypass_hits, uint, 0444);
module_param_named(touch_boost_ept_bypass_last_latency_us,
	oc_touch_boost_ept_bypass_last_latency_us, ullong, 0444);
module_param_named(touch_boost_cesta_ept_bypass_last_latency_us,
	oc_touch_boost_cesta_ept_bypass_last_latency_us, ullong, 0444);
module_param_named(touch_boost_ept_target_last_latency_us,
	oc_touch_boost_ept_target_last_latency_us, ullong, 0444);

struct oc_iris_hook_data {
	void *timing;
	u32 refresh;
	u8 hook_id;
	bool changed;
};

enum oc_iris_hook_id {
	OC_IRIS_PRE_SWITCH_HOOK = 0,
	OC_IRIS_SWITCH_HOOK,
	OC_IRIS_UPDATE_PANEL_TIMING_HOOK,
};

#define OC_IRIS_PRE_SWITCH_MASK BIT(OC_IRIS_PRE_SWITCH_HOOK)
#define OC_IRIS_SWITCH_MASK BIT(OC_IRIS_SWITCH_HOOK)
#define OC_IRIS_UPDATE_PANEL_TIMING_MASK \
	BIT(OC_IRIS_UPDATE_PANEL_TIMING_HOOK)
#define OC_IRIS_ALL_HOOKS_MASK \
	(OC_IRIS_PRE_SWITCH_MASK | OC_IRIS_SWITCH_MASK | \
	 OC_IRIS_UPDATE_PANEL_TIMING_MASK)

static bool oc_iris_hook_registered;
static unsigned int oc_iris_hook_registered_mask;
static unsigned int oc_iris_hook_count;
static unsigned int oc_iris_restore_count;
static unsigned int oc_iris_hook_missed;
static unsigned int oc_iris_pre_switch_hit;
static unsigned int oc_iris_pre_switch_restore;
static unsigned int oc_iris_switch_hit;
static unsigned int oc_iris_switch_restore;
static unsigned int oc_iris_update_panel_timing_hit;
static unsigned int oc_iris_update_panel_timing_restore;
static bool oc_physical_commit_hook_registered;
static unsigned int oc_physical_commit_count;
static unsigned int oc_physical_commit_mode_id = OC_INVALID_OFFSET;
static unsigned int oc_physical_commit_width;
static unsigned int oc_physical_commit_height;
static unsigned int oc_physical_commit_refresh;
static unsigned long long oc_physical_commit_ns;
module_param_named(iris_hook_registered, oc_iris_hook_registered, bool, 0444);
module_param_named(iris_hook_registered_mask, oc_iris_hook_registered_mask,
	uint, 0444);
module_param_named(iris_hook_count, oc_iris_hook_count, uint, 0444);
module_param_named(iris_restore_count, oc_iris_restore_count, uint, 0444);
module_param_named(iris_hook_missed, oc_iris_hook_missed, uint, 0444);
module_param_named(iris_pre_switch_hit, oc_iris_pre_switch_hit, uint, 0444);
module_param_named(iris_pre_switch_restore, oc_iris_pre_switch_restore,
	uint, 0444);
module_param_named(iris_switch_hit, oc_iris_switch_hit, uint, 0444);
module_param_named(iris_switch_restore, oc_iris_switch_restore, uint, 0444);
module_param_named(iris_update_panel_timing_hit,
	oc_iris_update_panel_timing_hit, uint, 0444);
module_param_named(iris_update_panel_timing_restore,
	oc_iris_update_panel_timing_restore, uint, 0444);
module_param_named(physical_commit_hook_registered,
	oc_physical_commit_hook_registered, bool, 0444);
module_param_named(physical_commit_count, oc_physical_commit_count,
	uint, 0444);
module_param_named(physical_commit_mode_id, oc_physical_commit_mode_id,
	uint, 0444);
module_param_named(physical_commit_width, oc_physical_commit_width,
	uint, 0444);
module_param_named(physical_commit_height, oc_physical_commit_height,
	uint, 0444);
module_param_named(physical_commit_refresh, oc_physical_commit_refresh,
	uint, 0444);
module_param_named(physical_commit_ns, oc_physical_commit_ns, ullong, 0444);

static unsigned int *oc_iris_hit_counter(enum oc_iris_hook_id hook_id)
{
	switch (hook_id) {
	case OC_IRIS_PRE_SWITCH_HOOK:
		return &oc_iris_pre_switch_hit;
	case OC_IRIS_SWITCH_HOOK:
		return &oc_iris_switch_hit;
	case OC_IRIS_UPDATE_PANEL_TIMING_HOOK:
		return &oc_iris_update_panel_timing_hit;
	}
	return NULL;
}

static unsigned int *oc_iris_restore_counter(enum oc_iris_hook_id hook_id)
{
	switch (hook_id) {
	case OC_IRIS_PRE_SWITCH_HOOK:
		return &oc_iris_pre_switch_restore;
	case OC_IRIS_SWITCH_HOOK:
		return &oc_iris_switch_restore;
	case OC_IRIS_UPDATE_PANEL_TIMING_HOOK:
		return &oc_iris_update_panel_timing_restore;
	}
	return NULL;
}

static void oc_iris_increment(unsigned int *counter)
{
	if (counter)
		WRITE_ONCE(*counter, READ_ONCE(*counter) + 1U);
}

static int __kprobes oc_iris_timing_entry_common(
	struct kretprobe_instance *instance, struct pt_regs *regs,
	unsigned int argument, enum oc_iris_hook_id hook_id)
{
	struct oc_iris_hook_data *data = (void *)instance->data;
	void *timing = (void *)(uintptr_t)regs->regs[argument];
	u32 width;
	u32 height;
	u32 refresh;

	data->timing = NULL;
	data->refresh = 0;
	data->hook_id = (u8)hook_id;
	data->changed = false;
	if (!oc_layout.runtime_modes || !timing)
		return 0;
	if (!oc_read_mem(timing, &width, sizeof(width)) ||
	    !oc_read_mem((u8 *)timing + OC_IRIS_TIMING_HEIGHT_OFFSET,
			 &height, sizeof(height)) ||
	    !oc_read_mem((u8 *)timing + OC_IRIS_TIMING_REFRESH_OFFSET,
			 &refresh, sizeof(refresh)) ||
	    width != OC_WQHD_WIDTH || height != OC_WQHD_HEIGHT ||
	    (refresh != 30U && refresh != 10U && refresh != 1U))
		return 0;
	data->timing = timing;
	data->refresh = refresh;
	data->changed = true;
	WRITE_ONCE(*(u32 *)((u8 *)timing + OC_IRIS_TIMING_REFRESH_OFFSET),
		   OC_SOURCE_FPS);
	oc_iris_increment(oc_iris_hit_counter(hook_id));
	oc_iris_increment(&oc_iris_hook_count);
	return 0;
}

static int __kprobes oc_iris_pre_switch_entry(
	struct kretprobe_instance *instance, struct pt_regs *regs)
{
	return oc_iris_timing_entry_common(instance, regs, 0U,
		OC_IRIS_PRE_SWITCH_HOOK);
}

static int __kprobes oc_iris_switch_entry(
	struct kretprobe_instance *instance, struct pt_regs *regs)
{
	return oc_iris_timing_entry_common(instance, regs, 2U,
		OC_IRIS_SWITCH_HOOK);
}

static int __kprobes oc_iris_update_panel_timing_entry(
	struct kretprobe_instance *instance, struct pt_regs *regs)
{
	return oc_iris_timing_entry_common(instance, regs, 0U,
		OC_IRIS_UPDATE_PANEL_TIMING_HOOK);
}

static int __kprobes oc_iris_timing_return(struct kretprobe_instance *instance,
					  struct pt_regs *regs)
{
	struct oc_iris_hook_data *data = (void *)instance->data;
	unsigned int *restore_counter;

	(void)regs;
	if (!data->changed || !data->timing)
		return 0;
	WRITE_ONCE(*(u32 *)((u8 *)data->timing +
		OC_IRIS_TIMING_REFRESH_OFFSET), data->refresh);
	restore_counter = oc_iris_restore_counter(
		(enum oc_iris_hook_id)data->hook_id);
	oc_iris_increment(restore_counter);
	oc_iris_increment(&oc_iris_restore_count);
	return 0;
}

static struct kretprobe oc_iris_pre_switch_probe = {
	.kp.symbol_name = "iris_pre_switch",
	.entry_handler = oc_iris_pre_switch_entry,
	.handler = oc_iris_timing_return,
	.maxactive = 64,
	.data_size = sizeof(struct oc_iris_hook_data),
};

static struct kretprobe oc_iris_switch_probe = {
	.kp.symbol_name = "iris_switch",
	.entry_handler = oc_iris_switch_entry,
	.handler = oc_iris_timing_return,
	.maxactive = 64,
	.data_size = sizeof(struct oc_iris_hook_data),
};

static struct kretprobe oc_iris_update_panel_timing_probe = {
	.kp.symbol_name = "iris_update_panel_timing",
	.entry_handler = oc_iris_update_panel_timing_entry,
	.handler = oc_iris_timing_return,
	.maxactive = 64,
	.data_size = sizeof(struct oc_iris_hook_data),
};

struct oc_dsi_set_mode_data {
	u32 requested_refresh;
	bool owned;
};

static bool oc_touch_boost_ept_bypass_is_valid(void);

static void oc_touch_boost_ept_clear_request(void)
{
	WRITE_ONCE(oc_touch_boost_ept_scope_active, false);
	WRITE_ONCE(oc_touch_boost_ept_scope_owner_pid, 0U);
	WRITE_ONCE(oc_touch_boost_ept_bypass_remaining, 0U);
	WRITE_ONCE(oc_touch_boost_cesta_ept_bypass_used, false);
	WRITE_ONCE(oc_touch_boost_ept_target_receipt_seen, false);
	WRITE_ONCE(oc_touch_boost_ept_target_receipt_ns, 0ULL);
	WRITE_ONCE(oc_touch_boost_ept_request_refresh, 0U);
	atomic_set(&oc_touch_boost_cesta_ept_claimed, 0);
	atomic_set(&oc_touch_boost_ept_request_claimed, 0);
}

static void oc_touch_boost_ept_clear_chain(void)
{
	WRITE_ONCE(oc_touch_boost_ept_chain_accepting, false);
	WRITE_ONCE(oc_touch_boost_ept_bypass_armed, false);
	oc_touch_boost_ept_clear_request();
	WRITE_ONCE(oc_touch_boost_ept_source_refresh, 0U);
	WRITE_ONCE(oc_touch_boost_ept_target_refresh, 0U);
	WRITE_ONCE(oc_touch_boost_ept_progress_refresh, 0U);
}

static int __kprobes oc_dsi_display_set_mode_entry(
	struct kretprobe_instance *instance, struct pt_regs *regs)
{
	struct oc_dsi_set_mode_data *data = (void *)instance->data;
	void *mode = (void *)(uintptr_t)regs->regs[1];
	u32 width;
	u32 height;
	u32 refresh;
	u32 progress;
	u32 ceiling;
	bool early_cesta_owner;
	bool mode_read;

	data->requested_refresh = 0U;
	data->owned = false;
	width = 0U;
	height = 0U;
	refresh = 0U;
	mode_read = mode &&
		oc_read_mem((u8 *)mode + oc_layout.width_offset,
			    &width, sizeof(width)) &&
		oc_read_mem((u8 *)mode + oc_layout.height_offset,
			    &height, sizeof(height)) &&
		oc_read_mem((u8 *)mode + oc_layout.refresh_offset,
			    &refresh, sizeof(refresh));
	if (!READ_ONCE(oc_touch_boost_ept_bypass_armed) ||
	    !READ_ONCE(oc_touch_boost_ept_chain_accepting) || !mode ||
	    READ_ONCE(oc_touch_boost_ept_source_refresh) > 30U ||
	    !oc_touch_boost_ept_bypass_is_valid() ||
	    !mode_read ||
	    width != OC_WQHD_WIDTH || height != OC_WQHD_HEIGHT) {
		if (mode_read &&
		    (width != OC_WQHD_WIDTH || height != OC_WQHD_HEIGHT))
			oc_touch_boost_ept_clear_chain();
		return 0;
	}

	progress = READ_ONCE(oc_touch_boost_ept_progress_refresh);
	ceiling = READ_ONCE(oc_touch_boost_chain_ceiling_refresh);
	if (!progress || refresh <= progress || refresh > ceiling ||
	    refresh * 100U >= progress * 110U) {
		if (refresh < progress || refresh > ceiling ||
		    (refresh > progress &&
		     refresh * 100U >= progress * 110U))
			oc_touch_boost_ept_clear_chain();
		return 0;
	}
	early_cesta_owner =
		READ_ONCE(oc_touch_boost_ept_scope_active) &&
		READ_ONCE(oc_touch_boost_cesta_ept_bypass_used) &&
		READ_ONCE(oc_touch_boost_ept_scope_owner_pid) ==
			(unsigned int)current->pid &&
		atomic_read(&oc_touch_boost_cesta_ept_claimed) == 1;
	if (!early_cesta_owner &&
	    atomic_cmpxchg(&oc_touch_boost_ept_request_claimed, 0, 1) != 0)
		return 0;

	data->requested_refresh = refresh;
	data->owned = true;
	WRITE_ONCE(oc_touch_boost_ept_request_refresh, refresh);
	if (!early_cesta_owner) {
		WRITE_ONCE(oc_touch_boost_ept_scope_owner_pid,
			(unsigned int)current->pid);
		WRITE_ONCE(oc_touch_boost_ept_bypass_remaining,
			OC_TOUCH_BOOST_EPT_BYPASS_MAX_HITS);
		WRITE_ONCE(oc_touch_boost_cesta_ept_bypass_used, false);
		atomic_set(&oc_touch_boost_cesta_ept_claimed, 0);
	}
	WRITE_ONCE(oc_touch_boost_ept_target_receipt_seen, false);
	WRITE_ONCE(oc_touch_boost_ept_target_receipt_ns, 0ULL);
	WRITE_ONCE(oc_touch_boost_ept_request_claims,
		READ_ONCE(oc_touch_boost_ept_request_claims) + 1U);
	smp_wmb();
	WRITE_ONCE(oc_touch_boost_ept_scope_active, true);
	return 0;
}

static int __kprobes oc_dsi_display_set_mode_return(
	struct kretprobe_instance *instance, struct pt_regs *regs)
{
	struct oc_dsi_set_mode_data *data = (void *)instance->data;
	void *panel = READ_ONCE(oc_layout.panel);
	void *current_mode = NULL;
	u32 mode_id;
	u32 width;
	u32 height;
	u32 refresh;

	if (data->owned && (long)regs->regs[0]) {
		oc_touch_boost_ept_clear_chain();
		return 0;
	}
	if (!panel || !oc_layout.runtime_modes ||
	    oc_layout.index_offset == OC_INVALID_OFFSET ||
	    !oc_read_mem((u8 *)panel + OC_PANEL_CUR_MODE_OFFSET,
			 &current_mode, sizeof(current_mode)) ||
	    !oc_read_mem((u8 *)current_mode + oc_layout.index_offset,
			 &mode_id, sizeof(mode_id)) ||
	    !oc_read_mem((u8 *)current_mode + oc_layout.width_offset,
			 &width, sizeof(width)) ||
	    !oc_read_mem((u8 *)current_mode + oc_layout.height_offset,
			 &height, sizeof(height)) ||
	    !oc_read_mem((u8 *)current_mode + oc_layout.refresh_offset,
			 &refresh, sizeof(refresh)) ||
	    !width || !height || !refresh ||
	    mode_id >= oc_layout.runtime_count) {
		if (data->owned)
			oc_touch_boost_ept_clear_chain();
		return 0;
	}

	WRITE_ONCE(oc_physical_commit_mode_id, mode_id);
	WRITE_ONCE(oc_physical_commit_width, width);
	WRITE_ONCE(oc_physical_commit_height, height);
	WRITE_ONCE(oc_physical_commit_refresh, refresh);
	WRITE_ONCE(oc_physical_commit_ns, ktime_get_ns());
	smp_wmb();
	WRITE_ONCE(oc_physical_commit_count,
		READ_ONCE(oc_physical_commit_count) + 1U);
	if (READ_ONCE(oc_touch_boost_ept_bypass_armed) &&
	    (width != OC_WQHD_WIDTH || height != OC_WQHD_HEIGHT ||
	     refresh < READ_ONCE(oc_touch_boost_ept_progress_refresh)))
		oc_touch_boost_ept_clear_chain();

	/* A synchronous native pre-boost is the physical 120/144 anchor. Each
	 * successful equal-or-strictly-under-10-percent DSI request advances that
	 * anchor without waiting for SurfaceFlinger's stale 1Hz logical timeline. */
	if (data->owned && READ_ONCE(oc_touch_boost_ept_bypass_armed) &&
	    width == OC_WQHD_WIDTH && height == OC_WQHD_HEIGHT &&
	    refresh == data->requested_refresh &&
	    refresh == READ_ONCE(oc_touch_boost_ept_request_refresh) &&
	    !READ_ONCE(oc_touch_boost_ept_target_receipt_seen)) {
		u64 armed_ns = READ_ONCE(oc_touch_boost_ept_bypass_armed_ns);
		u64 now_ns = ktime_get_ns();

		WRITE_ONCE(oc_touch_boost_ept_target_last_latency_us,
			(armed_ns && now_ns >= armed_ns) ?
			div_u64(now_ns - armed_ns, 1000ULL) : 0ULL);
		WRITE_ONCE(oc_touch_boost_ept_target_matches,
			READ_ONCE(oc_touch_boost_ept_target_matches) + 1U);
		WRITE_ONCE(oc_touch_boost_ept_target_receipt_ns, now_ns);
		WRITE_ONCE(oc_touch_boost_ept_target_refresh, refresh);
		WRITE_ONCE(oc_touch_boost_ept_progress_refresh, refresh);
		WRITE_ONCE(oc_touch_boost_ept_receipt_claims,
			READ_ONCE(oc_touch_boost_ept_receipt_claims) + 1U);
		if (refresh >= READ_ONCE(oc_touch_boost_chain_ceiling_refresh))
			WRITE_ONCE(oc_touch_boost_ept_chain_accepting, false);
		smp_wmb();
		WRITE_ONCE(oc_touch_boost_ept_target_receipt_seen, true);
	}

	/* SurfaceFlinger can submit a low activity mode while the panel is at 1Hz,
	 * then deliver that commit after a touch/high-activity native pre-boost.
	 * The daemon arms this guard only when it supersedes such a request. Never
	 * send DSI from the kretprobe: queue a normal worker after publishing the
	 * physical receipt so the panel mutex and command path stay unchanged. */
	if (READ_ONCE(oc_late_low_guard_armed)) {
		u64 armed_ns = READ_ONCE(oc_late_low_guard_armed_ns);
		u64 now_ns = ktime_get_ns();
		u32 count = READ_ONCE(oc_physical_commit_count);

		if (!armed_ns || now_ns < armed_ns ||
		    now_ns - armed_ns > OC_LATE_LOW_GUARD_WINDOW_NS) {
			WRITE_ONCE(oc_late_low_guard_armed, false);
			WRITE_ONCE(oc_late_low_guard_expired,
				READ_ONCE(oc_late_low_guard_expired) + 1U);
		} else if (count > READ_ONCE(oc_late_low_guard_commit_baseline) &&
			   width == OC_WQHD_WIDTH && height == OC_WQHD_HEIGHT &&
			   refresh == 10U) {
			WRITE_ONCE(oc_late_low_guard_armed, false);
			WRITE_ONCE(oc_late_low_guard_matches,
				READ_ONCE(oc_late_low_guard_matches) + 1U);
			if (!schedule_work(&oc_late_low_guard_work))
				WRITE_ONCE(oc_late_low_guard_failures,
					READ_ONCE(oc_late_low_guard_failures) + 1U);
		}
	}

	/* The native touch packet moves the panel immediately, while an older
	 * SurfaceFlinger transaction can still reach DSI on the old 1Hz timeline.
	 * Keep a native 120/144 anchor owned until HWC submits that anchor (or a
	 * higher timing). A late lower timing is restored from a normal workqueue;
	 * custom timings remain owned by HWC so their PHY/clock transaction is not
	 * imitated by a panel-command-only shortcut. */
	if (READ_ONCE(oc_rise_guard_armed)) {
		u64 armed_ns = READ_ONCE(oc_rise_guard_armed_ns);
		u64 now_ns = ktime_get_ns();
		u32 count = READ_ONCE(oc_physical_commit_count);
		u32 target = READ_ONCE(oc_rise_guard_target_refresh);
		u32 progress = READ_ONCE(oc_rise_guard_progress_refresh);
		bool target_seen = READ_ONCE(oc_rise_guard_target_seen);
		u64 target_seen_ns = READ_ONCE(oc_rise_guard_target_seen_ns);

		if (!armed_ns || now_ns < armed_ns ||
		    now_ns - armed_ns > OC_RISE_GUARD_WINDOW_NS ||
		    (target_seen && target_seen_ns && now_ns >= target_seen_ns &&
		     now_ns - target_seen_ns > OC_RISE_GUARD_TARGET_WINDOW_NS)) {
			WRITE_ONCE(oc_rise_guard_armed, false);
			WRITE_ONCE(oc_rise_guard_target_seen, false);
			WRITE_ONCE(oc_rise_guard_expired,
				READ_ONCE(oc_rise_guard_expired) + 1U);
		} else if (count > READ_ONCE(oc_rise_guard_commit_baseline) &&
			   width == OC_WQHD_WIDTH && height == OC_WQHD_HEIGHT) {
			if (refresh >= target) {
				WRITE_ONCE(oc_rise_guard_progress_refresh, refresh);
				if (!target_seen) {
					WRITE_ONCE(oc_rise_guard_target_seen_ns, now_ns);
					WRITE_ONCE(oc_rise_guard_target_seen, true);
					WRITE_ONCE(oc_rise_guard_successes,
						READ_ONCE(oc_rise_guard_successes) + 1U);
				}
			} else if (refresh < progress) {
				WRITE_ONCE(oc_rise_guard_last_match_refresh, refresh);
				WRITE_ONCE(oc_rise_guard_matches,
					READ_ONCE(oc_rise_guard_matches) + 1U);
				WRITE_ONCE(oc_rise_guard_replays,
					READ_ONCE(oc_rise_guard_replays) + 1U);
				if (refresh <= READ_ONCE(oc_rise_guard_anchor_refresh) &&
				    schedule_work(&oc_rise_guard_work)) {
					/* The replay counter was published before queuing so
					 * userspace can reconcile even if the worker coalesces. */
				}
			} else if (refresh > progress) {
				WRITE_ONCE(oc_rise_guard_progress_refresh, refresh);
			}
		}
	}
	return 0;
}

static struct kretprobe oc_dsi_display_set_mode_probe = {
	.kp.symbol_name = "dsi_display_set_mode",
	.entry_handler = oc_dsi_display_set_mode_entry,
	.handler = oc_dsi_display_set_mode_return,
	.maxactive = 64,
	.data_size = sizeof(struct oc_dsi_set_mode_data),
};

static bool oc_touch_boost_ept_bypass_is_valid(void)
{
	u64 armed_ns;
	u64 receipt_ns;
	u64 now_ns;

	if (!READ_ONCE(oc_touch_boost_ept_bypass_armed))
		return false;
	smp_rmb();
	armed_ns = READ_ONCE(oc_touch_boost_ept_bypass_armed_ns);
	receipt_ns = READ_ONCE(oc_touch_boost_ept_target_receipt_ns);
	now_ns = ktime_get_ns();
	if (armed_ns && now_ns >= armed_ns &&
	    now_ns - armed_ns <= OC_TOUCH_BOOST_EPT_BYPASS_WINDOW_NS) {
		if (!READ_ONCE(oc_touch_boost_ept_target_receipt_seen) ||
		    (receipt_ns && now_ns >= receipt_ns &&
		     now_ns - receipt_ns <=
			OC_TOUCH_BOOST_EPT_POST_RECEIPT_WINDOW_NS))
			return true;
		if (READ_ONCE(oc_touch_boost_ept_chain_accepting)) {
			oc_touch_boost_ept_clear_request();
			return true;
		}
	}

	oc_touch_boost_ept_clear_chain();
	WRITE_ONCE(oc_touch_boost_ept_bypass_expired,
		READ_ONCE(oc_touch_boost_ept_bypass_expired) + 1U);
	return false;
}

static int __kprobes oc_touch_boost_ept_delay_pre(struct kprobe *probe,
						  struct pt_regs *regs)
{
	unsigned int remaining;

	(void)probe;
	if (!READ_ONCE(oc_touch_boost_ept_scope_active) ||
	    READ_ONCE(oc_touch_boost_ept_scope_owner_pid) !=
		(unsigned int)current->pid ||
	    atomic_read(&oc_touch_boost_ept_request_claimed) != 1 ||
	    (!READ_ONCE(oc_touch_boost_cesta_ept_bypass_used) &&
	     !READ_ONCE(oc_touch_boost_ept_target_receipt_seen)) ||
	    !oc_touch_boost_ept_bypass_is_valid())
		return 0;
	remaining = READ_ONCE(oc_touch_boost_ept_bypass_remaining);
	if (!remaining)
		return 0;

	WRITE_ONCE(oc_touch_boost_ept_bypass_remaining, remaining - 1U);
	WRITE_ONCE(oc_touch_boost_ept_bypass_last_latency_us,
		div_u64(ktime_get_ns() -
			READ_ONCE(oc_touch_boost_ept_bypass_armed_ns), 1000ULL));
	WRITE_ONCE(oc_touch_boost_ept_bypass_hits,
		READ_ONCE(oc_touch_boost_ept_bypass_hits) + 1U);
	if (remaining == 1U) {
		if (READ_ONCE(oc_touch_boost_ept_chain_accepting))
			oc_touch_boost_ept_clear_request();
		else
			oc_touch_boost_ept_clear_chain();
	}
	/* The probe is at the function entry, before its stack frame exists. The
	 * target returns void, so continuing at LR is equivalent to an immediate
	 * function return. Returning nonzero tells arm64 kprobes not to single-step
	 * the replaced entry instruction. */
	regs->pc = regs->regs[30];
	return 1;
}

static struct kprobe oc_touch_boost_ept_delay_probe = {
	.symbol_name = "_sde_encoder_delay_kickoff_processing",
	.pre_handler = oc_touch_boost_ept_delay_pre,
};

/* AE084's 1 Hz rise can enter sde_encoder_cesta_update_on_ept() after the
 * panel has already accepted QHD120. That helper waits for the next 1 Hz EPT
 * boundary before the commit can reach the normal Cesta DB/ctrl/flush path.
 * Skip only that wait block for the authorized BEGIN/ENABLE commit states;
 * the live RMX5200 emits ENABLE_COMMIT for the first mode-change transaction
 * after the 1 Hz anchor. All shared Cesta programming at +0x618 and every
 * unarmed/downward commit remain untouched. */
static int __kprobes oc_touch_boost_cesta_ept_pre(struct kprobe *probe,
						 struct pt_regs *regs)
{
	u64 armed_ns;
	u64 now_ns;
	u32 progress;
	u32 request;
	u32 ceiling;
	bool exact_request_owner;
	bool terminal_receipt_owner;
	u32 commit_state = (u32)regs->regs[19];

	/* sde_crtc_commit_kickoff() is not on AE084's actual mode-change call
	 * chain, so its task-local scope cannot authorize this hook. Claim the
	 * bounded touch authorization at the Cesta commit that really runs on
	 * crtc_commit, then bind the remaining kickoff bypasses to this TID. */
	progress = READ_ONCE(oc_touch_boost_ept_progress_refresh);
	request = READ_ONCE(oc_touch_boost_ept_request_refresh);
	ceiling = READ_ONCE(oc_touch_boost_chain_ceiling_refresh);
	terminal_receipt_owner =
		!READ_ONCE(oc_touch_boost_ept_chain_accepting) &&
		READ_ONCE(oc_touch_boost_ept_target_receipt_seen) &&
		READ_ONCE(oc_touch_boost_ept_scope_active) &&
		atomic_read(&oc_touch_boost_ept_request_claimed) == 1 &&
		request == progress && progress >= ceiling;
	if ((!READ_ONCE(oc_touch_boost_ept_chain_accepting) &&
	     !terminal_receipt_owner) ||
	    !READ_ONCE(oc_touch_boost_ept_source_refresh) ||
	    READ_ONCE(oc_touch_boost_ept_source_refresh) > 30U ||
	    (commit_state != OC_TOUCH_BOOST_CESTA_BEGIN_COMMIT &&
	     commit_state != OC_TOUCH_BOOST_CESTA_ENABLE_COMMIT) ||
	    !oc_touch_boost_ept_bypass_is_valid())
		return 0;
	if (READ_ONCE(oc_touch_boost_ept_target_receipt_seen))
		oc_touch_boost_ept_clear_request();
	request = READ_ONCE(oc_touch_boost_ept_request_refresh);
	exact_request_owner =
		atomic_read(&oc_touch_boost_ept_request_claimed) == 1 &&
		READ_ONCE(oc_touch_boost_ept_scope_active) &&
		READ_ONCE(oc_touch_boost_ept_scope_owner_pid) ==
			(unsigned int)current->pid &&
		request > progress && request <= ceiling &&
		request * 100U < progress * 110U;
	if (!exact_request_owner &&
	    atomic_cmpxchg(&oc_touch_boost_ept_request_claimed, 0, 1) != 0)
		return 0;
	if (atomic_cmpxchg(&oc_touch_boost_cesta_ept_claimed, 0, 1) != 0) {
		return 0;
	}

	armed_ns = READ_ONCE(oc_touch_boost_ept_bypass_armed_ns);
	now_ns = ktime_get_ns();
	WRITE_ONCE(oc_touch_boost_ept_scope_owner_pid,
		(unsigned int)current->pid);
	WRITE_ONCE(oc_touch_boost_ept_bypass_remaining,
		OC_TOUCH_BOOST_EPT_BYPASS_MAX_HITS);
	if (!exact_request_owner)
		WRITE_ONCE(oc_touch_boost_ept_request_refresh, progress);
	WRITE_ONCE(oc_touch_boost_cesta_ept_bypass_used, true);
	smp_wmb();
	WRITE_ONCE(oc_touch_boost_ept_scope_active, true);
	WRITE_ONCE(oc_touch_boost_cesta_ept_bypass_last_latency_us,
		(now_ns >= armed_ns) ? div_u64(now_ns - armed_ns, 1000ULL) : 0ULL);
	WRITE_ONCE(oc_touch_boost_cesta_ept_bypass_hits,
		READ_ONCE(oc_touch_boost_cesta_ept_bypass_hits) + 1U);
	regs->pc = (unsigned long)probe->addr +
		(OC_TOUCH_BOOST_CESTA_EPT_RESUME_OFFSET -
		 OC_TOUCH_BOOST_CESTA_EPT_ENTRY_OFFSET);
	return 1;
}

static struct kprobe oc_touch_boost_cesta_ept_probe = {
	.symbol_name = "_sde_encoder_cesta_update",
	.offset = OC_TOUCH_BOOST_CESTA_EPT_ENTRY_OFFSET,
	.pre_handler = oc_touch_boost_cesta_ept_pre,
};

module_param_named(physical_commit_hook_missed,
	oc_dsi_display_set_mode_probe.nmissed, int, 0444);

module_param_named(iris_pre_switch_missed,
	oc_iris_pre_switch_probe.nmissed, int, 0444);
module_param_named(iris_switch_missed,
	oc_iris_switch_probe.nmissed, int, 0444);
module_param_named(iris_update_panel_timing_missed,
	oc_iris_update_panel_timing_probe.nmissed, int, 0444);

static void oc_unregister_iris_hooks(void)
{
	if (oc_iris_hook_registered_mask & OC_IRIS_UPDATE_PANEL_TIMING_MASK)
		unregister_kretprobe(&oc_iris_update_panel_timing_probe);
	if (oc_iris_hook_registered_mask & OC_IRIS_SWITCH_MASK)
		unregister_kretprobe(&oc_iris_switch_probe);
	if (oc_iris_hook_registered_mask & OC_IRIS_PRE_SWITCH_MASK)
		unregister_kretprobe(&oc_iris_pre_switch_probe);
	oc_iris_hook_missed =
		(unsigned int)oc_iris_pre_switch_probe.nmissed +
		(unsigned int)oc_iris_switch_probe.nmissed +
		(unsigned int)oc_iris_update_panel_timing_probe.nmissed;
	oc_iris_hook_registered_mask = 0U;
	oc_iris_hook_registered = false;
}

static int oc_register_iris_hooks(void)
{
	int ret;

	ret = register_kretprobe(&oc_iris_pre_switch_probe);
	if (ret)
		return ret;
	oc_iris_hook_registered_mask |= OC_IRIS_PRE_SWITCH_MASK;
	ret = register_kretprobe(&oc_iris_switch_probe);
	if (ret)
		goto fail;
	oc_iris_hook_registered_mask |= OC_IRIS_SWITCH_MASK;
	ret = register_kretprobe(&oc_iris_update_panel_timing_probe);
	if (ret)
		goto fail;
	oc_iris_hook_registered_mask |= OC_IRIS_UPDATE_PANEL_TIMING_MASK;
	if (oc_iris_hook_registered_mask != OC_IRIS_ALL_HOOKS_MASK) {
		ret = -EIO;
		goto fail;
	}
	oc_iris_hook_registered = true;
	return 0;

fail:
	oc_unregister_iris_hooks();
	return ret;
}

static int oc_register_physical_commit_hook(void)
{
	int ret = register_kretprobe(&oc_dsi_display_set_mode_probe);

	if (ret)
		return ret;
	oc_physical_commit_hook_registered = true;
	return 0;
}

static void oc_unregister_physical_commit_hook(void)
{
	if (oc_physical_commit_hook_registered)
		unregister_kretprobe(&oc_dsi_display_set_mode_probe);
	oc_physical_commit_hook_registered = false;
}

static int oc_register_touch_boost_ept_bypass(void)
{
	int ret = register_kprobe(&oc_touch_boost_ept_delay_probe);

	if (ret)
		return ret;
	oc_touch_boost_ept_bypass_registered = true;
	ret = register_kprobe(&oc_touch_boost_cesta_ept_probe);
	if (ret) {
		unregister_kprobe(&oc_touch_boost_ept_delay_probe);
		oc_touch_boost_ept_bypass_registered = false;
		return ret;
	}
	oc_touch_boost_cesta_ept_bypass_registered = true;
	return 0;
}

static void oc_unregister_touch_boost_ept_bypass(void)
{
	oc_touch_boost_ept_clear_chain();
	if (oc_touch_boost_cesta_ept_bypass_registered)
		unregister_kprobe(&oc_touch_boost_cesta_ept_probe);
	if (oc_touch_boost_ept_bypass_registered)
		unregister_kprobe(&oc_touch_boost_ept_delay_probe);
	oc_touch_boost_ept_bypass_registered = false;
	oc_touch_boost_ept_scope_registered = false;
	oc_touch_boost_cesta_ept_bypass_registered = false;
}

static void oc_unregister_iris_hook(void)
{
	oc_unregister_iris_hooks();
}
#endif

static bool oc_plausible_pointer(u64 value)
{
	return value && (value >> 56) == 0xff && !(value & 7);
}

static bool oc_read_mem(const void *address, void *buffer, size_t size)
{
	if (!address || !buffer || !size)
		return false;
	return copy_from_kernel_nofault(buffer, address, size) == 0;
}

static bool oc_read_pointer(const void *base, u32 offset, void **value)
{
	u64 raw;

	if (!oc_read_mem((const u8 *)base + offset, &raw, sizeof(raw)) ||
	    !oc_plausible_pointer(raw))
		return false;
	*value = (void *)(uintptr_t)raw;
	return true;
}

static u32 oc_buf_u32(const u8 *buffer, u32 offset)
{
	u32 value;

	memcpy(&value, buffer + offset, sizeof(value));
	return value;
}

static u64 oc_buf_u64(const u8 *buffer, u32 offset)
{
	u64 value;

	memcpy(&value, buffer + offset, sizeof(value));
	return value;
}

static void oc_write_u32(void *base, u32 offset, u32 value)
{
	WRITE_ONCE(*(u32 *)((u8 *)base + offset), value);
}

static void oc_write_u64(void *base, u32 offset, u64 value)
{
	WRITE_ONCE(*(u64 *)((u8 *)base + offset), value);
}

static void oc_write_pointer(void *base, u32 offset, void *value)
{
	WRITE_ONCE(*(void **)((u8 *)base + offset), value);
}

#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
static void *oc_touch_boost_priv;
static void *oc_touch_boost_live_mode;
static void *oc_touch_boost_priv_144;
static void *oc_touch_boost_live_mode_144;

static int oc_capture_touch_boost_mode(const u8 *record, u32 expected_refresh,
				       struct iris_mode_info *timing,
				       struct iris_cmd_set *cmdset,
				       void **priv_out, void **live_mode_out)
{
	void *priv;
	void *cmds;
	u64 first_cmd_word;
	u32 type;
	u32 state;
	u32 count;
	bool dsc_enabled;

	if (!record || !timing || !cmdset || !priv_out || !live_mode_out)
		return -EINVAL;
	if (!oc_read_pointer(record, oc_layout.priv_offset, &priv) ||
	    ksize(priv) < OC_TIMING_SWITCH_CMDSET_OFFSET +
			 OC_CMDSET_CMDS_OFFSET + sizeof(void *) ||
	    !oc_read_mem((u8 *)priv + OC_TIMING_SWITCH_CMDSET_OFFSET +
			 OC_CMDSET_TYPE_OFFSET, &type, sizeof(type)) ||
	    !oc_read_mem((u8 *)priv + OC_TIMING_SWITCH_CMDSET_OFFSET +
			 OC_CMDSET_STATE_OFFSET, &state, sizeof(state)) ||
	    !oc_read_mem((u8 *)priv + OC_TIMING_SWITCH_CMDSET_OFFSET +
			 OC_CMDSET_COUNT_OFFSET, &count, sizeof(count)) ||
	    !oc_read_pointer((u8 *)priv + OC_TIMING_SWITCH_CMDSET_OFFSET,
			     OC_CMDSET_CMDS_OFFSET, &cmds) ||
	    type != OC_TIMING_SWITCH_CMDSET_TYPE || state > 1U ||
	    count != (expected_refresh == 144U ?
		      OC_WQHD144_SWITCH_CMD_COUNT :
		      OC_WQHD120_SWITCH_CMD_COUNT) ||
	    !oc_read_mem(cmds, &first_cmd_word, sizeof(first_cmd_word)))
		return -EPROTO;

	memset(timing, 0, sizeof(*timing));
	memset(cmdset, 0, sizeof(*cmdset));
	timing->h_active = oc_buf_u32(record, 0x00U);
	timing->h_back_porch = oc_buf_u32(record, 0x04U);
	timing->h_sync_width = oc_buf_u32(record, 0x08U);
	timing->h_front_porch = oc_buf_u32(record, 0x0cU);
	timing->v_active = oc_buf_u32(record, 0x18U);
	timing->v_back_porch = oc_buf_u32(record, 0x1cU);
	timing->v_sync_width = oc_buf_u32(record, 0x20U);
	timing->v_front_porch = oc_buf_u32(record, 0x24U);
	timing->refresh_rate = oc_buf_u32(record, 0x2cU);
	timing->clk_rate_hz = oc_buf_u64(record, 0x30U);
	timing->mdp_transfer_time_us = oc_buf_u32(record, 0x40U);
	if (!oc_read_mem(record + 0x48U, &dsc_enabled,
			 sizeof(dsc_enabled)))
		return -EFAULT;
	timing->dsc_enabled = dsc_enabled;
	if (timing->h_active != OC_WQHD_WIDTH ||
	    timing->v_active != OC_WQHD_HEIGHT ||
	    timing->refresh_rate != expected_refresh ||
	    timing->clk_rate_hz != (expected_refresh == 144U ?
			      OC_WQHD144_CLOCK : OC_WQHD120_CLOCK) ||
	    timing->mdp_transfer_time_us != (expected_refresh == 144U ?
			      OC_WQHD144_TRANSFER_US :
			      OC_WQHD120_TRANSFER_US) ||
	    !timing->dsc_enabled)
		return -EPROTO;

	cmdset->state = state;
	cmdset->count = count;
	cmdset->cmds = cmds;
	*priv_out = priv;
	*live_mode_out = (void *)record;
	return 0;
}

static int oc_prepare_touch_boost(void)
{
	unsigned int matches_120 = 0;
	unsigned int matches_144 = 0;
	unsigned int i;
	int rc;

	memset(&oc_touch_boost_timing, 0, sizeof(oc_touch_boost_timing));
	memset(&oc_touch_boost_cmdset, 0, sizeof(oc_touch_boost_cmdset));
	memset(&oc_touch_boost_timing_144, 0,
	       sizeof(oc_touch_boost_timing_144));
	memset(&oc_touch_boost_cmdset_144, 0,
	       sizeof(oc_touch_boost_cmdset_144));
	oc_touch_boost_priv = NULL;
	oc_touch_boost_live_mode = NULL;
	oc_touch_boost_priv_144 = NULL;
	oc_touch_boost_live_mode_144 = NULL;
	oc_touch_boost_source_index = OC_INVALID_OFFSET;
	oc_touch_boost_source_index_144 = OC_INVALID_OFFSET;
	oc_touch_boost_ready = false;
	if (!oc_layout.runtime_modes || !oc_layout.stride ||
	    !oc_layout.runtime_count)
		return -ENODATA;

	for (i = 0; i < oc_layout.runtime_count; i++) {
		const u8 *record = (const u8 *)oc_layout.runtime_modes +
			i * oc_layout.stride;
		u32 refresh;

		if (oc_buf_u32(record, oc_layout.width_offset) != OC_WQHD_WIDTH ||
		    oc_buf_u32(record, oc_layout.height_offset) != OC_WQHD_HEIGHT)
			continue;
		refresh = oc_buf_u32(record, oc_layout.refresh_offset);
		if (refresh == 120U) {
			matches_120++;
			rc = oc_capture_touch_boost_mode(record, 120U,
				&oc_touch_boost_timing, &oc_touch_boost_cmdset,
				&oc_touch_boost_priv, &oc_touch_boost_live_mode);
			if (rc)
				return rc;
			oc_touch_boost_source_index = i;
			oc_touch_boost_cmd_state = oc_touch_boost_cmdset.state;
			oc_touch_boost_cmd_count = oc_touch_boost_cmdset.count;
		} else if (refresh == 144U) {
			matches_144++;
			rc = oc_capture_touch_boost_mode(record, 144U,
				&oc_touch_boost_timing_144,
				&oc_touch_boost_cmdset_144,
				&oc_touch_boost_priv_144,
				&oc_touch_boost_live_mode_144);
			if (rc)
				return rc;
			oc_touch_boost_source_index_144 = i;
		}
	}
	if (matches_120 != 1U || matches_144 != 1U ||
	    !oc_touch_boost_live_mode ||
	    !oc_touch_boost_priv ||
	    !oc_touch_boost_cmdset.cmds ||
	    !oc_touch_boost_live_mode_144 ||
	    !oc_touch_boost_priv_144 ||
	    !oc_touch_boost_cmdset_144.cmds)
		return -ENOENT;
	oc_touch_boost_ready = true;
	return 0;
}

static int oc_touch_boost_trigger_set(const char *value,
	const struct kernel_param *kp)
{
	unsigned int trigger;
	int ret;

	(void)kp;
	ret = kstrtouint(value, 0, &trigger);
	if (ret)
		return ret;
	if (trigger != 1U)
		return -EINVAL;
	if (!READ_ONCE(oc_touch_boost_ready))
		return -ENODEV;
	if (!READ_ONCE(oc_touch_boost_enabled))
		return -EACCES;
	WRITE_ONCE(oc_touch_boost_request_target_refresh,
		READ_ONCE(oc_touch_boost_target_refresh));
	WRITE_ONCE(oc_touch_boost_last_target_refresh, 0U);
	WRITE_ONCE(oc_touch_boost_trigger, trigger);
	WRITE_ONCE(oc_touch_boost_request_ns, ktime_get_ns());
	if (!schedule_work(&oc_touch_boost_work))
		return -EBUSY;
	return 0;
}

static int oc_touch_boost_target_set(const char *value,
	const struct kernel_param *kp)
{
	unsigned int target;
	int ret;

	(void)kp;
	ret = kstrtouint(value, 0, &target);
	if (ret)
		return ret;
	if (target != 120U && target != 144U)
		return -EINVAL;
	WRITE_ONCE(oc_touch_boost_target_refresh, target);
	return 0;
}

static int oc_touch_boost_chain_ceiling_set(const char *value,
	const struct kernel_param *kp)
{
	unsigned int ceiling;
	int ret;

	(void)kp;
	ret = kstrtouint(value, 0, &ceiling);
	if (ret)
		return ret;
	if (ceiling < 120U || ceiling > OC_MAX_REFRESH)
		return -EINVAL;
	if (ceiling != READ_ONCE(oc_touch_boost_chain_ceiling_refresh) &&
	    READ_ONCE(oc_touch_boost_ept_bypass_armed))
		oc_touch_boost_ept_clear_chain();
	WRITE_ONCE(oc_touch_boost_chain_ceiling_refresh, ceiling);
	return 0;
}

static int oc_late_low_guard_trigger_set(const char *value,
	const struct kernel_param *kp)
{
	unsigned int trigger;
	unsigned int target;
	int ret;

	(void)kp;
	ret = kstrtouint(value, 0, &trigger);
	if (ret)
		return ret;
	if (trigger == 0U) {
		WRITE_ONCE(oc_late_low_guard_armed, false);
		WRITE_ONCE(oc_late_low_guard_trigger, 0U);
		return 0;
	}
	if (trigger != 1U)
		return -EINVAL;
	target = READ_ONCE(oc_late_low_guard_target_refresh);
	if (target != 120U && target != 144U)
		return -EINVAL;
	if (!READ_ONCE(oc_touch_boost_ready) || !READ_ONCE(applied))
		return -ENODEV;

	WRITE_ONCE(oc_late_low_guard_request_target_refresh, target);
	WRITE_ONCE(oc_late_low_guard_commit_baseline,
		READ_ONCE(oc_physical_commit_count));
	WRITE_ONCE(oc_late_low_guard_armed_ns, ktime_get_ns());
	WRITE_ONCE(oc_late_low_guard_trigger, 1U);
	WRITE_ONCE(oc_late_low_guard_last_target_refresh, 0U);
	smp_wmb();
	WRITE_ONCE(oc_late_low_guard_armed, true);
	WRITE_ONCE(oc_late_low_guard_armed_count,
		READ_ONCE(oc_late_low_guard_armed_count) + 1U);
	return 0;
}

static int oc_rise_guard_trigger_set(const char *value,
	const struct kernel_param *kp)
{
	unsigned int trigger;
	unsigned int target;
	unsigned int anchor;
	int ret;

	(void)kp;
	ret = kstrtouint(value, 0, &trigger);
	if (ret)
		return ret;
	if (trigger == 0U) {
		WRITE_ONCE(oc_rise_guard_armed, false);
		WRITE_ONCE(oc_rise_guard_target_seen, false);
		WRITE_ONCE(oc_rise_guard_trigger, 0U);
		return 0;
	}
	if (trigger != 1U)
		return -EINVAL;
	target = READ_ONCE(oc_rise_guard_target_refresh);
	anchor = READ_ONCE(oc_rise_guard_anchor_refresh);
	if (target < 120U || target > 300U ||
	    (anchor != 120U && anchor != 144U) || anchor > target)
		return -EINVAL;
	if (!READ_ONCE(oc_rise_guard_ready) || !READ_ONCE(applied))
		return -ENODEV;

	WRITE_ONCE(oc_rise_guard_request_anchor_refresh, anchor);
	WRITE_ONCE(oc_rise_guard_commit_baseline,
		READ_ONCE(oc_physical_commit_count));
	WRITE_ONCE(oc_rise_guard_armed_ns, ktime_get_ns());
	WRITE_ONCE(oc_rise_guard_trigger, 1U);
	WRITE_ONCE(oc_rise_guard_last_target_refresh, 0U);
	WRITE_ONCE(oc_rise_guard_last_match_refresh, 0U);
	WRITE_ONCE(oc_rise_guard_progress_refresh, anchor);
	WRITE_ONCE(oc_rise_guard_last_result, -EINPROGRESS);
	WRITE_ONCE(oc_rise_guard_target_seen, false);
	WRITE_ONCE(oc_rise_guard_target_seen_ns, 0ULL);
	smp_wmb();
	WRITE_ONCE(oc_rise_guard_armed, true);
	WRITE_ONCE(oc_rise_guard_armed_count,
		READ_ONCE(oc_rise_guard_armed_count) + 1U);
	return 0;
}

static void oc_run_native_boost(u32 target_refresh, u64 request_ns,
			       bool late_guard, bool rise_guard)
{
	struct iris_mode_info timing;
	struct iris_cmd_set target_cmdset;
	void *current_mode = NULL;
	void *target_priv = NULL;
	void *expected_priv;
	void *target_live_mode;
	void *cmds = NULL;
	void *panel = READ_ONCE(oc_layout.panel);
	u64 end_ns;
	u64 first_cmd_word;
	u32 width = 0;
	u32 height = 0;
	u32 refresh = 0;
	u32 type = 0;
	u32 state = 0;
	u32 count = 0;
	u32 chain_ceiling;
	u32 skip = OC_TOUCH_BOOST_SKIP_NONE;
	int rc = 0;
	bool attempted = false;

	if (!READ_ONCE(oc_touch_boost_ready)) {
		skip = OC_TOUCH_BOOST_SKIP_NOT_READY;
		goto done;
	}
	if (!READ_ONCE(applied)) {
		skip = OC_TOUCH_BOOST_SKIP_NOT_APPLIED;
		goto done;
	}
	if (!panel) {
		skip = OC_TOUCH_BOOST_SKIP_NO_PANEL;
		goto done;
	}
	if (target_refresh == 144U) {
		timing = oc_touch_boost_timing_144;
		target_cmdset = oc_touch_boost_cmdset_144;
		expected_priv = oc_touch_boost_priv_144;
		target_live_mode = oc_touch_boost_live_mode_144;
	} else if (target_refresh == 120U) {
		timing = oc_touch_boost_timing;
		target_cmdset = oc_touch_boost_cmdset;
		expected_priv = oc_touch_boost_priv;
		target_live_mode = oc_touch_boost_live_mode;
	} else {
		skip = OC_TOUCH_BOOST_SKIP_CMDSET_CHANGED;
		goto done;
	}

	mutex_lock((struct mutex *)((u8 *)panel + OC_PANEL_LOCK_OFFSET));
	if (!oc_read_pointer(panel, OC_PANEL_CUR_MODE_OFFSET, &current_mode) ||
	    !oc_read_mem((u8 *)current_mode + oc_layout.width_offset,
			 &width, sizeof(width)) ||
	    !oc_read_mem((u8 *)current_mode + oc_layout.height_offset,
			 &height, sizeof(height)) ||
	    !oc_read_mem((u8 *)current_mode + oc_layout.refresh_offset,
			 &refresh, sizeof(refresh))) {
		skip = OC_TOUCH_BOOST_SKIP_NO_CURRENT_MODE;
		goto unlock;
	}
	if (!late_guard && !rise_guard)
		WRITE_ONCE(oc_touch_boost_last_source_refresh, refresh);
	if (width != OC_WQHD_WIDTH || height != OC_WQHD_HEIGHT) {
		skip = OC_TOUCH_BOOST_SKIP_GEOMETRY;
		goto unlock;
	}
	if (rise_guard && refresh == target_refresh) {
		attempted = true;
		goto unlock;
	}
	if ((!rise_guard && refresh > 30U) ||
	    (rise_guard && refresh > target_refresh)) {
		skip = OC_TOUCH_BOOST_SKIP_NOT_LOW_MODE;
		goto unlock;
	}
	if (!target_live_mode || !expected_priv ||
	    !oc_read_pointer(target_live_mode,
			     oc_layout.priv_offset, &target_priv) ||
	    target_priv != expected_priv ||
	    !oc_read_mem((u8 *)expected_priv +
			 OC_TIMING_SWITCH_CMDSET_OFFSET + OC_CMDSET_TYPE_OFFSET,
			 &type, sizeof(type)) ||
	    !oc_read_mem((u8 *)expected_priv +
			 OC_TIMING_SWITCH_CMDSET_OFFSET + OC_CMDSET_STATE_OFFSET,
			 &state, sizeof(state)) ||
	    !oc_read_mem((u8 *)expected_priv +
			 OC_TIMING_SWITCH_CMDSET_OFFSET + OC_CMDSET_COUNT_OFFSET,
			 &count, sizeof(count)) ||
	    !oc_read_pointer((u8 *)expected_priv +
			 OC_TIMING_SWITCH_CMDSET_OFFSET,
			 OC_CMDSET_CMDS_OFFSET, &cmds) ||
	    type != OC_TIMING_SWITCH_CMDSET_TYPE ||
	    state != target_cmdset.state ||
	    count != target_cmdset.count ||
	    cmds != target_cmdset.cmds ||
	    !oc_read_mem(cmds, &first_cmd_word, sizeof(first_cmd_word))) {
		skip = OC_TOUCH_BOOST_SKIP_CMDSET_CHANGED;
		goto unlock;
	}

	attempted = true;
	if (!late_guard && !rise_guard)
		WRITE_ONCE(oc_touch_boost_attempts,
			READ_ONCE(oc_touch_boost_attempts) + 1U);
	if (!late_guard && !rise_guard && READ_ONCE(oc_touch_boost_one_shot))
		WRITE_ONCE(oc_touch_boost_enabled, false);
	/* The live AE084 panel is in analog bypass. The normal HWC path therefore
	 * sends DSI_CMD_SET_TIMING_SWITCH through dsi_panel_tx_cmd_set(), not
	 * iris_switch()/iris_abyp_send_panel_cmd(). Reuse that exact path while the
	 * panel lock is held, and restore the low-refresh mode pointer before the
	 * worker releases it. */
	iris_pre_switch(&timing);
	oc_write_pointer(panel, OC_PANEL_CUR_MODE_OFFSET,
			 target_live_mode);
	rc = dsi_panel_tx_cmd_set(panel, OC_TIMING_SWITCH_CMDSET_TYPE, false);
	oc_write_pointer(panel, OC_PANEL_CUR_MODE_OFFSET, current_mode);
	if (!rc) {
		if (!late_guard && !rise_guard)
			WRITE_ONCE(oc_touch_boost_last_target_refresh,
				target_refresh);
		WRITE_ONCE(oc_touch_boost_panel_tx_sends,
			READ_ONCE(oc_touch_boost_panel_tx_sends) + 1U);
		/* Publish a fresh one-shot authorization. Clear every owner field
		 * before arming so a late commit from the previous rise cannot inherit
		 * either the Cesta jump or the subsequent kickoff-delay bypass. */
		chain_ceiling = READ_ONCE(oc_touch_boost_chain_ceiling_refresh);
		oc_touch_boost_ept_clear_chain();
		if (!late_guard && !rise_guard &&
		    chain_ceiling > target_refresh &&
		    chain_ceiling <= OC_MAX_REFRESH) {
			WRITE_ONCE(oc_touch_boost_ept_source_refresh, refresh);
			WRITE_ONCE(oc_touch_boost_ept_target_refresh,
				target_refresh);
			WRITE_ONCE(oc_touch_boost_ept_progress_refresh,
				target_refresh);
			WRITE_ONCE(oc_touch_boost_ept_bypass_armed_ns,
				ktime_get_ns());
			WRITE_ONCE(oc_touch_boost_ept_chain_accepting, true);
			smp_wmb();
			WRITE_ONCE(oc_touch_boost_ept_bypass_armed, true);
		}
	}

unlock:
	mutex_unlock((struct mutex *)((u8 *)panel + OC_PANEL_LOCK_OFFSET));
done:
	end_ns = ktime_get_ns();
	if (request_ns && end_ns >= request_ns) {
		if (rise_guard)
			WRITE_ONCE(oc_rise_guard_last_latency_us,
				div_u64(end_ns - request_ns, 1000ULL));
		else if (late_guard)
			WRITE_ONCE(oc_late_low_guard_last_latency_us,
				div_u64(end_ns - request_ns, 1000ULL));
		else
			WRITE_ONCE(oc_touch_boost_last_latency_us,
				div_u64(end_ns - request_ns, 1000ULL));
	}
	if (skip != OC_TOUCH_BOOST_SKIP_NONE) {
		if (rise_guard) {
			WRITE_ONCE(oc_rise_guard_failures,
				READ_ONCE(oc_rise_guard_failures) + 1U);
			WRITE_ONCE(oc_rise_guard_last_result, -EAGAIN);
		} else if (late_guard) {
			WRITE_ONCE(oc_late_low_guard_failures,
				READ_ONCE(oc_late_low_guard_failures) + 1U);
		} else {
			WRITE_ONCE(oc_touch_boost_skips,
				READ_ONCE(oc_touch_boost_skips) + 1U);
			WRITE_ONCE(oc_touch_boost_last_skip, skip);
			WRITE_ONCE(oc_touch_boost_last_result, -EAGAIN);
		}
		pr_info("rmx5200_ltpo_touch_boost: skipped reason=%u refresh=%u latency=%lluus\n",
			skip, refresh,
			rise_guard ? READ_ONCE(oc_rise_guard_last_latency_us) :
			late_guard ? READ_ONCE(oc_late_low_guard_last_latency_us) :
			READ_ONCE(oc_touch_boost_last_latency_us));
		return;
	}
	if (rise_guard) {
		WRITE_ONCE(oc_rise_guard_last_target_refresh, target_refresh);
		WRITE_ONCE(oc_rise_guard_last_result, rc);
		if (attempted && !rc)
			WRITE_ONCE(oc_rise_guard_recoveries,
				READ_ONCE(oc_rise_guard_recoveries) + 1U);
		else
			WRITE_ONCE(oc_rise_guard_failures,
				READ_ONCE(oc_rise_guard_failures) + 1U);
	} else if (late_guard) {
		WRITE_ONCE(oc_late_low_guard_last_target_refresh,
			target_refresh);
		if (attempted && !rc)
			WRITE_ONCE(oc_late_low_guard_recoveries,
				READ_ONCE(oc_late_low_guard_recoveries) + 1U);
		else
			WRITE_ONCE(oc_late_low_guard_failures,
				READ_ONCE(oc_late_low_guard_failures) + 1U);
	} else {
		WRITE_ONCE(oc_touch_boost_last_skip,
			OC_TOUCH_BOOST_SKIP_NONE);
		WRITE_ONCE(oc_touch_boost_last_result, rc);
		if (attempted && !rc)
			WRITE_ONCE(oc_touch_boost_successes,
				READ_ONCE(oc_touch_boost_successes) + 1U);
		else
			WRITE_ONCE(oc_touch_boost_failures,
				READ_ONCE(oc_touch_boost_failures) + 1U);
	}
	pr_info("rmx5200_ltpo_touch_boost: AE084 QHD%u direct panel switch source=%u rc=%d panel_tx=%u latency=%lluus\n",
		target_refresh, refresh, rc,
		READ_ONCE(oc_touch_boost_panel_tx_sends),
		rise_guard ? READ_ONCE(oc_rise_guard_last_latency_us) :
		late_guard ? READ_ONCE(oc_late_low_guard_last_latency_us) :
		READ_ONCE(oc_touch_boost_last_latency_us));
}

static void oc_touch_boost_worker(struct work_struct *work)
{
	(void)work;
	oc_run_native_boost(
		READ_ONCE(oc_touch_boost_request_target_refresh),
		READ_ONCE(oc_touch_boost_request_ns), false, false);
}

static void oc_late_low_guard_worker(struct work_struct *work)
{
	(void)work;
	oc_run_native_boost(
		READ_ONCE(oc_late_low_guard_request_target_refresh),
		READ_ONCE(oc_late_low_guard_armed_ns), true, false);
}

static void oc_rise_guard_worker(struct work_struct *work)
{
	u32 anchor = READ_ONCE(oc_rise_guard_request_anchor_refresh);
	u64 started_ns = READ_ONCE(oc_rise_guard_armed_ns);

	(void)work;
	oc_run_native_boost(anchor, started_ns, false, true);
}
#endif

static bool oc_read_dt_u32(const struct device_node *node, const char *name,
				   u32 *value)
{
	const __be32 *data;
	int length = 0;

	data = of_get_property(node, name, &length);
	if (!data || length != sizeof(*data))
		return false;
	*value = be32_to_cpup(data);
	return true;
}

static bool oc_read_dt_clock(const struct device_node *node, const char *name,
			     u32 *value)
{
	const void *data;
	int length = 0;
	u64 wide;

	data = of_get_property(node, name, &length);
	if (!data)
		return false;
	if (length == sizeof(__be32)) {
		*value = be32_to_cpup(data);
		return *value != 0;
	}
	if (length != sizeof(__be64))
		return false;
	wide = be64_to_cpup(data);
	if (!wide || wide > U32_MAX)
		return false;
	*value = (u32)wide;
	return true;
}

static unsigned int oc_property_count(const struct device_node *node)
{
	const struct property *property;
	unsigned int count = 0;

	if (!node)
		return 0;
	for (property = node->properties; property; property = property->next) {
		if (++count > OC_MAX_PROPERTIES)
			return 0;
	}
	return count;
}

static bool oc_is_timing_node(const struct device_node *node)
{
	return node && node->name && !strncmp(node->name, "timing", 6);
}

static bool oc_is_rmx_timing(const struct device_node *node)
{
	const char *name;

	if (!oc_is_timing_node(node) || !node->parent || !node->parent->parent)
		return false;
	name = node->parent->parent->name;
	return name && !strcmp(name, OC_PANEL_NODE);
}

static bool oc_is_fhd_timing(const struct device_node *node)
{
	u32 width;
	u32 height;

	if (!oc_is_rmx_timing(node) ||
	    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-width", &width) ||
	    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-height", &height))
		return false;
	return width == OC_NATIVE_WIDTH && height == OC_NATIVE_HEIGHT;
}

static noinline int oc_find_dt_state(void)
{
	struct device_node *node = NULL;
	struct device_node *next;

	memset(&oc_dt, 0, sizeof(oc_dt));
	while ((next = of_find_node_by_name(node, "timing")) != NULL) {
		u32 width;
		u32 height;
		u32 fps;
		u32 clock;
		u32 transfer_time_us;

		if (node)
			of_node_put(node);
		node = next;
		if (!oc_is_fhd_timing(node) ||
		    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-width", &width) ||
		    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-height", &height) ||
		    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-framerate", &fps) ||
		    !oc_read_dt_clock(node, "qcom,mdss-dsi-panel-clockrate", &clock) ||
		    !oc_read_dt_u32(node, "qcom,mdss-mdp-transfer-time-us",
				    &transfer_time_us))
			continue;
		if (fps != OC_SOURCE_FPS || !clock || !transfer_time_us ||
		    oc_dt.source_node)
			continue;
		oc_dt.source_node = of_node_get(node);
		oc_dt.timings_parent = of_node_get(node->parent);
		oc_dt.source_clock = clock;
		oc_dt.source_property_count = oc_property_count(node);
	}
	if (node)
		of_node_put(node);
	if (!oc_dt.source_node || !oc_dt.timings_parent ||
	    !oc_dt.source_property_count)
		return -ENODEV;

	{
		struct device_node *child;

		for (child = oc_dt.timings_parent->child; child;
		     child = child->sibling) {
			u32 width;
			u32 height;
			u32 fps;
			u32 clock;
			u32 transfer_time_us;

			if (!oc_is_rmx_timing(child) ||
			    !oc_read_dt_u32(child, "qcom,mdss-dsi-panel-width", &width) ||
			    !oc_read_dt_u32(child, "qcom,mdss-dsi-panel-height", &height) ||
			    !oc_read_dt_u32(child, "qcom,mdss-dsi-panel-framerate", &fps) ||
			    !oc_read_dt_clock(child, "qcom,mdss-dsi-panel-clockrate", &clock) ||
			    !oc_read_dt_u32(child, "qcom,mdss-mdp-transfer-time-us",
					    &transfer_time_us))
				continue;
			if (!clock || !transfer_time_us)
				continue;
			if (oc_dt.count >= OC_MAX_DT_MODES)
				return -E2BIG;
			oc_dt.width[oc_dt.count] = width;
			oc_dt.height[oc_dt.count] = height;
			oc_dt.fps[oc_dt.count] = fps;
			oc_dt.clock[oc_dt.count] = clock;
			oc_dt.transfer_time_us[oc_dt.count++] = transfer_time_us;
		}
		/* The DTBO backend may already have appended verified WQHD modes.
		 * Keep the original eight-mode ABI as the minimum baseline, but
		 * discover and validate every timing exposed by the active DTBO so
		 * the KO can add only modes that are not already present. */
		dt_mode_count = oc_dt.count;
#ifndef RMX5200_LOW_REFRESH_EXPERIMENT
		if (oc_dt.count < OC_MODE_COUNT)
			return -ENODEV;
#endif
#ifndef RMX5200_LOW_REFRESH_EXPERIMENT
		for (child = oc_dt.timings_parent->child; child;
		     child = child->sibling) {
			u32 width;
			u32 height;
			u32 fps;

			if (!oc_is_fhd_timing(child) || child == oc_dt.source_node ||
			    !oc_read_dt_u32(child, "qcom,mdss-dsi-panel-width", &width) ||
			    !oc_read_dt_u32(child, "qcom,mdss-dsi-panel-height", &height) ||
			    !oc_read_dt_u32(child,
					    "qcom,mdss-dsi-panel-framerate", &fps))
				continue;
			/* The native 1080p 144 Hz node is intentionally preserved. */
			if (fps != 60U && fps != 90U && fps != 120U)
				continue;
			{
				unsigned int target = fps == 60U ? 0U :
					fps == 90U ? 1U : 2U;

				if (oc_dt.target_nodes[target])
					return -EEXIST;
				if (child->child ||
				    of_find_property(child, "phandle", NULL) ||
				    of_find_property(child, "linux,phandle", NULL) ||
				    !oc_property_count(child))
					return -EINVAL;
				oc_dt.target_nodes[target] = of_node_get(child);
			}
		}
#endif
	}
#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
	if (oc_dt.source_clock != OC_LOW_LINK_CLOCK)
		return -EPROTO;
	oc_dt.target_count = 0;
#else
	oc_dt.target_count = OC_TARGET_MODE_COUNT;
	if (!oc_dt.target_nodes[0] || !oc_dt.target_nodes[1] ||
	    !oc_dt.target_nodes[2])
		return -ENODEV;
#endif
	return 0;
}

static u32 oc_clock_for_fps(u32 source_clock, u32 fps)
{
	return (u32)div_u64((u64)source_clock * fps, OC_SOURCE_FPS);
}

static bool oc_refresh_sane(u32 refresh)
{
	return refresh >= OC_MIN_REFRESH && refresh <= OC_MAX_REFRESH;
}

static bool oc_clock_sane(u64 clock, u64 source_clock)
{
	return clock >= source_clock / 4 && clock <= source_clock * 2;
}

static unsigned int oc_collect_positions(const u8 *buffer, u32 stride,
						 u64 value, bool wide, u32 *positions)
{
	unsigned int count = 0;
	u32 step = wide ? 8U : 4U;
	u32 offset;

	for (offset = 0; offset + (wide ? 8U : 4U) <= stride;
	     offset += step) {
		u64 current_value = wide ? oc_buf_u64(buffer, offset) :
					     (u64)oc_buf_u32(buffer, offset);
		if (current_value != value)
			continue;
		if (count < OC_MAX_FIELD_POSITIONS)
			positions[count++] = offset;
	}
	return count;
}

static bool oc_multiset_matches(const u8 *records, u32 stride, u32 count,
					 u32 width_offset, u32 height_offset,
					 u32 refresh_offset, u32 clock_offset)
{
	bool used[OC_MAX_DT_MODES] = { false };
	u32 i;
	(void)stride;

	for (i = 0; i < count; i++) {
		u32 width = oc_buf_u32(records + i * OC_MAX_MODE_STRIDE,
					       width_offset);
		u32 height = oc_buf_u32(records + i * OC_MAX_MODE_STRIDE,
						 height_offset);
		u32 refresh = oc_buf_u32(records + i * OC_MAX_MODE_STRIDE,
						 refresh_offset);
		u64 clock = oc_buf_u64(records + i * OC_MAX_MODE_STRIDE,
						       clock_offset);
		u32 j;
		bool found = false;

		if (width < 100U || width > 4096U || height < 100U ||
		    height > 8192U || !oc_refresh_sane(refresh) ||
		    !oc_clock_sane(clock, oc_dt.source_clock))
			return false;
		for (j = 0; j < oc_dt.count; j++) {
			if (!used[j] && oc_dt.width[j] == width &&
			    oc_dt.height[j] == height && oc_dt.fps[j] == refresh &&
			    oc_dt.clock[j] == clock) {
				used[j] = true;
				found = true;
				break;
			}
		}
		if (!found)
			return false;
	}
	return true;
}

static bool oc_validate_mode_candidate(const u8 *records, u32 stride,
						u32 width_offset, u32 height_offset,
						u32 refresh_offset, u32 clock_offset,
						u32 source_index)
{
	u32 i;

	for (i = 0; i < oc_dt.count; i++) {
		const u8 *record = records + i * OC_MAX_MODE_STRIDE;
		u32 width = oc_buf_u32(record, width_offset);
		u32 height = oc_buf_u32(record, height_offset);
		u32 refresh = oc_buf_u32(record, refresh_offset);
		u64 clock = oc_buf_u64(record, clock_offset);

		if (width < 100U || width > 4096U || height < 100U ||
		    height > 8192U || !oc_refresh_sane(refresh) ||
		    !oc_clock_sane(clock, oc_dt.source_clock))
			return false;
	}
	if (oc_buf_u32(records + source_index * OC_MAX_MODE_STRIDE,
			       width_offset) != OC_NATIVE_WIDTH ||
	    oc_buf_u32(records + source_index * OC_MAX_MODE_STRIDE,
			       height_offset) != OC_NATIVE_HEIGHT ||
	    oc_buf_u32(records + source_index * OC_MAX_MODE_STRIDE,
			       refresh_offset) != OC_SOURCE_FPS)
		return false;
	return oc_multiset_matches(records, stride, oc_dt.count,
					   width_offset, height_offset,
					   refresh_offset, clock_offset);
}

static bool oc_find_index_offset(const u8 *records, u32 stride, u32 count,
					 u32 *offset)
{
	u32 candidate;
	u32 i;

	for (candidate = 0; candidate + 4 <= stride; candidate += 4) {
		bool sequential = true;
		for (i = 0; i < count; i++) {
			if (oc_buf_u32(records + i * OC_MAX_MODE_STRIDE, candidate) != i) {
				sequential = false;
				break;
			}
		}
		if (sequential) {
			*offset = candidate;
			return true;
		}
	}
	return false;
}

static bool oc_find_pixel_offset(const u8 *records, u32 stride, u32 count,
					 u32 source_index, u32 width_offset,
					 u32 height_offset, u32 clock_offset,
					 u32 *offset, u32 *source_pixel)
{
	u32 candidate;
	u32 i;
	int best_error = INT_MAX;
	u32 best_offset = OC_INVALID_OFFSET;
	u32 best_pixel = 0;

	for (candidate = 0; candidate + 4 <= stride; candidate += 4) {
		u32 source = oc_buf_u32(
			records + source_index * OC_MAX_MODE_STRIDE, candidate);
		int error = 0;
		if (source < 10000U || source > 2000000U)
			continue;
		for (i = 0; i < count; i++) {
			u32 width = oc_buf_u32(records + i * OC_MAX_MODE_STRIDE,
						       width_offset);
			u32 height = oc_buf_u32(records + i * OC_MAX_MODE_STRIDE,
							 height_offset);
			u64 mode_clock = oc_buf_u64(records + i * OC_MAX_MODE_STRIDE,
							     clock_offset);
			u32 actual = oc_buf_u32(records + i * OC_MAX_MODE_STRIDE,
							 candidate);

			if (width != OC_NATIVE_WIDTH || height != OC_NATIVE_HEIGHT)
				continue;
			u32 expected = (u32)div_u64((u64)source * mode_clock,
								 oc_dt.source_clock);
			int delta = (int)actual - (int)expected;

			if (delta < 0)
				delta = -delta;
			if (delta > 32)
				error += delta;
		}
		if (error < best_error) {
			best_error = error;
			best_offset = candidate;
			best_pixel = source;
		}
	}
	if (best_offset == OC_INVALID_OFFSET || best_error)
		return false;
	*offset = best_offset;
	*source_pixel = best_pixel;
	return true;
}

static bool oc_expected_transfer_time(const u8 *record, u32 width_offset,
				      u32 height_offset, u32 refresh_offset,
				      u32 clock_offset, u32 *transfer_time_us)
{
	u32 width = oc_buf_u32(record, width_offset);
	u32 height = oc_buf_u32(record, height_offset);
	u32 refresh = oc_buf_u32(record, refresh_offset);
	u64 clock = oc_buf_u64(record, clock_offset);
	u32 expected = 0;
	u32 i;
	bool found = false;

	for (i = 0; i < oc_dt.count; i++) {
		if (oc_dt.width[i] != width || oc_dt.height[i] != height ||
		    oc_dt.fps[i] != refresh || oc_dt.clock[i] != clock)
			continue;
		if (found && expected != oc_dt.transfer_time_us[i])
			return false;
		expected = oc_dt.transfer_time_us[i];
		found = true;
	}
	if (!found || !expected)
		return false;
	*transfer_time_us = expected;
	return true;
}

static bool oc_phy_profile_valid(void)
{
	return !strcmp(phy_profile, "stock") ||
		!strcmp(phy_profile, "v72_vendor_delta");
}

static const struct oc_phy_target *oc_find_phy_target(u32 refresh)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(oc_vendor_delta_phy); i++) {
		if (oc_vendor_delta_phy[i].refresh == refresh)
			return &oc_vendor_delta_phy[i];
	}
	return NULL;
}

static int oc_prepare_phy_timing(const struct oc_mode_spec *spec, u64 clock,
				 const u32 *source, u32 *target, bool *tuned)
{
	const struct oc_phy_target *profile = NULL;

	memcpy(target, source, OC_PHY_TIMING_BYTES);
	*tuned = false;
	if (!strcmp(phy_profile, "stock"))
		return 0;
	if (strcmp(phy_profile, "v72_vendor_delta"))
		return -EINVAL;
	if (spec->width != OC_WQHD_WIDTH || spec->height != OC_WQHD_HEIGHT)
		return 0;
	profile = oc_find_phy_target(spec->refresh);
	if (!profile || clock != profile->clock)
		return 0;
	if (memcmp(source, oc_stock_144_phy, OC_PHY_TIMING_BYTES))
		return -EPROTO;
	memcpy(target, profile->timing, OC_PHY_TIMING_BYTES);
	*tuned = true;
	return 0;
}

static bool oc_private_transfer_matches(const u8 *records, void **privs,
					u32 count, u32 width_offset,
					u32 height_offset, u32 refresh_offset,
					u32 clock_offset, u32 candidate)
{
	u32 i;

	for (i = 0; i < count; i++) {
		u32 expected;
		u32 actual;
		size_t priv_size = ksize(privs[i]);

		if (!priv_size || priv_size > OC_MAX_PRIV_SIZE ||
		    candidate + sizeof(actual) > priv_size ||
		    !oc_expected_transfer_time(
			records + i * OC_MAX_MODE_STRIDE, width_offset,
			height_offset, refresh_offset, clock_offset, &expected) ||
		    !oc_read_mem((u8 *)privs[i] + candidate, &actual,
				 sizeof(actual)) || actual != expected)
			return false;
	}
	return true;
}

static bool oc_private_phy_layout_matches(const u8 *records, u32 count,
					  u32 priv_offset)
{
	u32 i;

	for (i = 0; i < count; i++) {
		const u8 *record = records + i * OC_MAX_MODE_STRIDE;
		void *priv;
		void *values;
		u32 length;
		u32 timing[OC_PHY_TIMING_LENGTH];
		size_t priv_size;

		if (!oc_read_pointer(record, priv_offset, &priv))
			return false;
		priv_size = ksize(priv);
		if (!priv_size || priv_size > OC_MAX_PRIV_SIZE ||
		    OC_PRIV_PHY_VALUES_OFFSET + sizeof(void *) > priv_size ||
		    OC_PRIV_PHY_LENGTH_OFFSET + sizeof(length) > priv_size ||
		    !oc_read_pointer(priv, OC_PRIV_PHY_VALUES_OFFSET, &values) ||
		    !oc_read_mem((u8 *)priv + OC_PRIV_PHY_LENGTH_OFFSET,
				 &length, sizeof(length)) ||
		    length != OC_PHY_TIMING_LENGTH ||
		    !oc_read_mem(values, timing, sizeof(timing)))
			return false;
	}
	return true;
}

static bool oc_find_private_layout(const u8 *records, u32 stride, u32 count,
					   u32 source_index, u32 width_offset,
					   u32 height_offset, u32 refresh_offset,
					   u32 clock_offset, u32 *priv_offset,
					   u32 *clock_in_priv,
					   u32 *transfer_in_priv,
					   void **source_priv)
{
	u32 pointer_offset;

	for (pointer_offset = 0; pointer_offset + 8 <= stride;
	     pointer_offset += 8) {
		void *privs[OC_MAX_DT_MODES];
		u32 i;
		bool pointers_ok = true;

		for (i = 0; i < count; i++) {
			u64 raw = oc_buf_u64(records + i * OC_MAX_MODE_STRIDE,
						 pointer_offset);
			if (!oc_plausible_pointer(raw)) {
				pointers_ok = false;
				break;
			}
			privs[i] = (void *)(uintptr_t)raw;
		}
		if (!pointers_ok)
			continue;
		for (u32 candidate = 0; candidate + 8 <= OC_MAX_PRIV_SCAN;
		     candidate += 8) {
			u64 source_clock;
			bool clocks_ok = true;
			u32 transfer_candidate = OC_INVALID_OFFSET;
			if (!oc_read_mem((u8 *)privs[source_index] + candidate,
					 &source_clock,
					 sizeof(source_clock)) ||
			    source_clock != oc_dt.source_clock)
				continue;
			for (i = 0; i < count; i++) {
				u64 private_clock;
				u64 mode_clock = oc_buf_u64(
					records + i * OC_MAX_MODE_STRIDE, clock_offset);
				if (!oc_read_mem((u8 *)privs[i] + candidate,
						 &private_clock, sizeof(private_clock)) ||
				    private_clock != mode_clock) {
					clocks_ok = false;
					break;
				}
			}
			if (!clocks_ok)
				continue;
			/* This RMX5200 msm_drm build reads mdp_transfer_time_us 0x18
			 * bytes before clk_rate_hz. Validate that ABI relationship
			 * against every stock mode and fall back to a bounded scan so
			 * an ABI change still fails closed rather than corrupting data. */
			if (candidate >= 0x18U &&
			    oc_private_transfer_matches(records, privs, count,
				width_offset, height_offset, refresh_offset,
				clock_offset, candidate - 0x18U)) {
				transfer_candidate = candidate - 0x18U;
			} else {
				u32 scan;

				for (scan = 0; scan + 4 <= OC_MAX_PRIV_SCAN;
				     scan += 4) {
					if (!oc_private_transfer_matches(records, privs,
						count, width_offset, height_offset,
						refresh_offset, clock_offset, scan))
						continue;
					transfer_candidate = scan;
					break;
				}
			}
			if (transfer_candidate != OC_INVALID_OFFSET) {
				*priv_offset = pointer_offset;
				*clock_in_priv = candidate;
				*transfer_in_priv = transfer_candidate;
				*source_priv = privs[source_index];
				return true;
			}
		}
	}
	return false;
}

static noinline int oc_find_mode_layout(struct oc_mode_layout *layout)
{
	u8 *records;
	u32 display_offset;

	records = kmalloc(OC_MAX_DT_MODES * OC_MAX_MODE_STRIDE, GFP_KERNEL);
	if (!records)
		return -ENOMEM;
	for (display_offset = 0; display_offset <= OC_MAX_DISPLAY_SCAN;
	     display_offset += 8) {
		void *modes;
		u32 stride;

		if (!oc_read_pointer(oc_layout.display, display_offset, &modes))
			continue;
		for (stride = OC_MIN_MODE_STRIDE; stride <= OC_MAX_MODE_STRIDE;
		     stride += 8) {
			u32 i;
			u32 source_index;
			bool records_ok = true;

			for (i = 0; i < oc_dt.count; i++) {
				if (!oc_read_mem((u8 *)modes + i * stride,
						 records + i * OC_MAX_MODE_STRIDE, stride)) {
					records_ok = false;
					break;
				}
			}
			if (!records_ok)
				continue;
			for (source_index = 0; source_index < oc_dt.count;
			     source_index++) {
				u32 hpos[OC_MAX_FIELD_POSITIONS];
				u32 vpos[OC_MAX_FIELD_POSITIONS];
				u32 fpos[OC_MAX_FIELD_POSITIONS];
				u32 cpos[OC_MAX_FIELD_POSITIONS];
				unsigned int hn;
				unsigned int vn;
				unsigned int fn;
				unsigned int cn;
				unsigned int hi;
				unsigned int vi;
				unsigned int fi;
				unsigned int ci;

				hn = oc_collect_positions(
					records + source_index * OC_MAX_MODE_STRIDE,
					stride, OC_NATIVE_WIDTH, false, hpos);
				vn = oc_collect_positions(
					records + source_index * OC_MAX_MODE_STRIDE,
					stride, OC_NATIVE_HEIGHT, false, vpos);
				fn = oc_collect_positions(
					records + source_index * OC_MAX_MODE_STRIDE,
					stride, OC_SOURCE_FPS, false, fpos);
				cn = oc_collect_positions(
					records + source_index * OC_MAX_MODE_STRIDE,
					stride, oc_dt.source_clock, true, cpos);
				for (hi = 0; hi < hn; hi++)
					for (vi = 0; vi < vn; vi++)
						for (fi = 0; fi < fn; fi++)
							for (ci = 0; ci < cn; ci++) {
								u32 index_offset = OC_INVALID_OFFSET;
								u32 pixel_offset = OC_INVALID_OFFSET;
								u32 source_pixel = 0;
								u32 priv_offset = OC_INVALID_OFFSET;
								u32 private_clock_offset = OC_INVALID_OFFSET;
								u32 private_transfer_offset = OC_INVALID_OFFSET;
								void *source_priv = NULL;

								if (hpos[hi] == vpos[vi] ||
								    hpos[hi] == fpos[fi] ||
								    hpos[hi] == cpos[ci] ||
								    vpos[vi] == fpos[fi] ||
								    vpos[vi] == cpos[ci] ||
								    fpos[fi] == cpos[ci])
									continue;
								if (!oc_validate_mode_candidate(records, stride,
										hpos[hi], vpos[vi], fpos[fi],
										cpos[ci], source_index))
									continue;
								oc_find_index_offset(records, stride, oc_dt.count,
										   &index_offset);
								oc_find_pixel_offset(records, stride, oc_dt.count,
										   source_index, hpos[hi],
										   vpos[vi], cpos[ci],
										   &pixel_offset,
										   &source_pixel);
								if (!oc_find_private_layout(records, stride,
											 oc_dt.count, source_index,
											 hpos[hi], vpos[vi], fpos[fi],
											 cpos[ci],
											 &priv_offset,
											 &private_clock_offset,
											 &private_transfer_offset,
											 &source_priv))
									continue;
								if (!oc_private_phy_layout_matches(records,
										oc_dt.count, priv_offset))
									continue;
								layout->modes = modes;
								layout->stride = stride;
								layout->count = oc_dt.count;
								layout->width_offset = hpos[hi];
								layout->height_offset = vpos[vi];
								layout->refresh_offset = fpos[fi];
								layout->clock_offset = cpos[ci];
								layout->pixel_offset = pixel_offset;
								layout->index_offset = index_offset;
								layout->priv_offset = priv_offset;
								layout->priv_clock_offset = private_clock_offset;
								layout->priv_transfer_offset = private_transfer_offset;
								layout->priv_phy_values_offset =
									OC_PRIV_PHY_VALUES_OFFSET;
								layout->priv_phy_length_offset =
									OC_PRIV_PHY_LENGTH_OFFSET;
								layout->priv_phy_length =
									OC_PHY_TIMING_LENGTH;
								layout->source_index = source_index;
								layout->source_priv = source_priv;
								layout->source_priv_size = ksize(source_priv);
								layout->source_pixel = source_pixel;
								layout->source_clock = oc_dt.source_clock;
				if (layout->source_priv_size < private_clock_offset + 8 ||
				    layout->source_priv_size < private_transfer_offset + 4 ||
				    layout->source_priv_size > OC_MAX_PRIV_SIZE)
					continue;
				kfree(records);
				return 0;
							}
			}
		}
	}
	kfree(records);
	pr_err("rmx5200_display_runtime_modes: mode layout scan failed dt_count=%u\n",
		oc_dt.count);
	return -EPROTO;
}

static noinline int oc_find_panel_layout(void)
{
	u32 display_offset;
	int best_score = -1;
	void *best_panel = NULL;
	u32 best_panel_offset = OC_INVALID_OFFSET;
	u32 best_count_offset = OC_INVALID_OFFSET;
	unsigned int best_fields = 0;
	u32 best_values[2] = { 0, 0 };
	void *known_panel;
	u32 known_a;
	u32 known_b;

	/* RMX5200's 6.12 dsi_display keeps the parsed panel at +0x108.
	 * Prefer this verified ABI over a blind scan; retain the scan below as a
	 * fail-closed fallback for minor vendor layout changes. */
	if (oc_read_pointer(oc_layout.display, 0x108, &known_panel) &&
	    oc_read_mem((u8 *)known_panel + 0x5a0, &known_a, sizeof(known_a)) &&
	    oc_read_mem((u8 *)known_panel + 0x5a4, &known_b, sizeof(known_b)) &&
	    known_a == oc_dt.count && known_b == oc_dt.count) {
		oc_layout.panel = known_panel;
		oc_layout.panel_count_offsets[0] = 0x5a0;
		oc_layout.panel_count_offsets[1] = 0x5a4;
		oc_layout.panel_count_values[0] = known_a;
		oc_layout.panel_count_values[1] = known_b;
		oc_layout.panel_count_fields = 2;
		display_panel_offset = 0x108;
		panel_count_offset = 0x5a0;
		panel_count_fields = 2;
		return 0;
	}

	for (display_offset = 0; display_offset <= OC_MAX_DISPLAY_SCAN;
	     display_offset += 8) {
		void *candidate;
		u32 offset;

		if (display_offset == display_modes_offset ||
		    !oc_read_pointer(oc_layout.display, display_offset, &candidate))
			continue;
		for (offset = 0x300; offset <= 0x900; offset += 4) {
			u32 count = 0;
			u32 next_count = 0;
			void *timing_info;
			int score;
			if (display_offset == 0x108 && offset == 0x5a0)
				pr_info("rmx5200_display_runtime_modes: panel_scan candidate=%px count=%u/%u expected=%u read=%d/%d\\n",
					candidate, count, next_count, oc_dt.count,
					oc_read_mem((u8 *)candidate + offset, &count, sizeof(count)),
					oc_read_mem((u8 *)candidate + offset + 4, &next_count, sizeof(next_count)));

			if (!oc_read_mem((u8 *)candidate + offset, &count,
					 sizeof(count)) || count != oc_dt.count)
				continue;
			if (!oc_read_mem((u8 *)candidate + offset + 4,
					 &next_count, sizeof(next_count)) ||
			    next_count != oc_dt.count)
				continue;
			score = 1;
			if (offset >= 0x500 && offset <= 0x700)
				score += 2;
			if (offset >= 0xc && oc_read_pointer(candidate, offset - 0xc,
						       &timing_info)) {
				u32 refresh;
				u32 width;
				u32 height;
				u64 clock;
				if (oc_read_mem((u8 *)timing_info + oc_layout.refresh_offset,
						 &refresh,
						 sizeof(refresh)) && oc_refresh_sane(refresh))
					score += 4;
				if (oc_read_mem((u8 *)timing_info + oc_layout.width_offset,
						 &width, sizeof(width)) &&
				    oc_read_mem((u8 *)timing_info + oc_layout.height_offset,
						 &height, sizeof(height)) &&
				    width == OC_NATIVE_WIDTH && height == OC_NATIVE_HEIGHT)
					score += 2;
				if (oc_read_mem((u8 *)timing_info + oc_layout.clock_offset,
						 &clock, sizeof(clock)) &&
				    clock == oc_dt.source_clock)
					score += 2;
			}
			if (score <= best_score)
				continue;
			best_score = score;
			best_panel = candidate;
			best_panel_offset = display_offset;
			best_count_offset = offset;
			best_fields = 2;
			best_values[0] = count;
			best_values[1] = next_count;
		}
	}
	if (!best_panel)
		return -EPROTO;
	oc_layout.panel = best_panel;
	oc_layout.panel_count_offsets[0] = best_count_offset;
	oc_layout.panel_count_offsets[1] = best_count_offset + 4;
	oc_layout.panel_count_values[0] = best_values[0];
	oc_layout.panel_count_values[1] = best_values[1];
	oc_layout.panel_count_fields = best_fields;
	display_panel_offset = best_panel_offset;
	panel_count_offset = best_count_offset;
	panel_count_fields = best_fields;
	return 0;
}

static int oc_discover_layout(void)
{
	int rc;
	void *connector;
	void *connector_dev = NULL;
	void *connector_funcs = NULL;

	memset(&oc_layout, 0, sizeof(oc_layout));
	oc_layout.display = get_main_display();
	if (!oc_layout.display)
		return -ENODEV;
	display_address = (unsigned long long)(uintptr_t)oc_layout.display;
	display_modes_offset = OC_INVALID_OFFSET;
	/* Find the parsed mode array first.  The mode scan validates every timing
	 * record against the live DT multiset, so random display pointers do not
	 * pass this step. */
	rc = oc_find_mode_layout(&oc_layout);
	if (rc)
		return rc;
	for (u32 offset = 0; offset <= OC_MAX_DISPLAY_SCAN; offset += 8) {
		void *candidate;
		if (oc_read_pointer(oc_layout.display, offset, &candidate) &&
		    candidate == oc_layout.modes) {
			display_modes_offset = offset;
			break;
		}
	}
	if (display_modes_offset == OC_INVALID_OFFSET)
		return -EPROTO;
	if (!oc_read_pointer(oc_layout.display, OC_CONNECTOR_OFFSET, &connector))
		return -EPROTO;
	oc_layout.connector = connector;
	oc_read_pointer(connector, offsetof(struct drm_connector, dev),
			&connector_dev);
	oc_read_pointer(connector, offsetof(struct drm_connector, funcs),
			&connector_funcs);
	pr_info("rmx5200_display_runtime_modes: connector=%px dev=%px funcs=%px offsets=%zu/%zu\\n",
		connector, connector_dev, connector_funcs,
		offsetof(struct drm_connector, dev),
		offsetof(struct drm_connector, funcs));
	if (!connector_dev || !connector_funcs)
		return -EPROTO;
	rc = oc_find_panel_layout();
	if (rc)
		return rc;
	mode_count_before = oc_layout.count;
	mode_stride = oc_layout.stride;
	mode_width_offset = oc_layout.width_offset;
	mode_height_offset = oc_layout.height_offset;
	mode_refresh_offset = oc_layout.refresh_offset;
	mode_clock_offset = oc_layout.clock_offset;
	mode_pixel_offset = oc_layout.pixel_offset;
	mode_index_offset = oc_layout.index_offset;
	mode_priv_offset = oc_layout.priv_offset;
	priv_clock_offset = oc_layout.priv_clock_offset;
	priv_transfer_offset = oc_layout.priv_transfer_offset;
	priv_phy_values_offset = oc_layout.priv_phy_values_offset;
	priv_phy_length_offset = oc_layout.priv_phy_length_offset;
	priv_phy_length = oc_layout.priv_phy_length;
	source_mode_index = oc_layout.source_index;
	source_clock_hz = oc_dt.source_clock;
	target_clock_hz = oc_clock_for_fps(oc_dt.source_clock, OC_HIGHEST_FPS);
	return 0;
}


static bool oc_mode_spec_sane(const struct oc_mode_spec *spec)
{
#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
	return spec && spec->width == OC_WQHD_WIDTH &&
		spec->height == OC_WQHD_HEIGHT &&
		(spec->refresh == 30U || spec->refresh == 10U ||
		 spec->refresh == 1U) &&
		(!spec->clock || spec->clock == OC_LOW_LINK_CLOCK);
#else
	return spec && spec->width >= 100U && spec->width <= 4096U &&
		spec->height >= 100U && spec->height <= 8192U &&
		oc_refresh_sane(spec->refresh) &&
		(!spec->source_refresh || oc_refresh_sane(spec->source_refresh)) &&
		(!spec->transfer_time_us ||
		 (spec->transfer_time_us >= 1000U &&
		  spec->transfer_time_us <= 20000U));
#endif
}

static noinline int oc_parse_mode_specs(struct oc_mode_spec *specs,
				       unsigned int *spec_count)
{
	char *text;
	char *cursor;
	char *item;
	const char *source = mode_specs;
	unsigned int count = 0;
	int ret = 0;

	if (!specs || !spec_count || !source[0])
		return -EINVAL;
	text = kmemdup_nul(source, strlen(source), GFP_KERNEL);
	if (!text)
		return -ENOMEM;
	if (strlen(source) >= OC_MAX_SPEC_TEXT) {
		kfree(text);
		return -E2BIG;
	}
	cursor = text;
	while ((item = strsep(&cursor, ";")) != NULL) {
		char *x;
		char *at;
		char *clock_sep;
		char *transfer_sep;
		char *source_sep;
		struct oc_mode_spec spec = { 0 };
		while (*item == ' ' || *item == '\t' || *item == '\n')
			item++;
		if (!*item)
			continue;
		x = strchr(item, 'x');
		at = strchr(item, '@');
		if (!x || !at || x >= at)
			goto invalid;
		*x = '\0';
		*at = '\0';
		clock_sep = strchr(at + 1, ':');
		transfer_sep = NULL;
		source_sep = NULL;
		if (clock_sep) {
			*clock_sep = '\0';
			transfer_sep = strchr(clock_sep + 1, ':');
			if (transfer_sep) {
				*transfer_sep = '\0';
				source_sep = strchr(transfer_sep + 1, ':');
				if (source_sep)
					*source_sep = '\0';
			}
		}
		ret = kstrtou32(item, 0, &spec.width);
		if (ret)
			goto parse_error;
		ret = kstrtou32(x + 1, 0, &spec.height);
		if (ret)
			goto parse_error;
		ret = kstrtou32(at + 1, 0, &spec.refresh);
		if (ret)
			goto parse_error;
		if (clock_sep && clock_sep[1]) {
			ret = kstrtoull(clock_sep + 1, 0, &spec.clock);
			if (ret)
				goto parse_error;
		}
		if (transfer_sep && transfer_sep[1]) {
			ret = kstrtou32(transfer_sep + 1, 0,
					 &spec.transfer_time_us);
			if (ret)
				goto parse_error;
		}
		if (source_sep && source_sep[1]) {
			ret = kstrtou32(source_sep + 1, 0,
					 &spec.source_refresh);
			if (ret)
				goto parse_error;
		}
		if (!oc_mode_spec_sane(&spec))
			goto range_error;
		if (count >= OC_MAX_SPEC_MODES)
			goto too_many;
		specs[count++] = spec;
	}
	if (!count)
		goto invalid;
	*spec_count = count;
	kfree(text);
	return 0;

parse_error:
	kfree(text);
	return ret;
range_error:
	kfree(text);
	return -ERANGE;
too_many:
	kfree(text);
	return -E2BIG;
invalid:
	kfree(text);
	return -EINVAL;
}

static unsigned int oc_connector_mode_count(struct drm_connector *connector)
{
	struct drm_display_mode *mode;
	unsigned int count = 0;

	if (!connector || !connector->dev || !connector->funcs)
		return 0;
	list_for_each_entry(mode, &connector->modes, head) {
		if (++count > OC_MAX_RUNTIME_MODES + OC_MAX_DT_MODES)
			return 0;
	}
	return count;
}

static u32 oc_stock_fhd_refresh_bit(u32 refresh)
{
	switch (refresh) {
	case 60U:
		return BIT(0);
	case 90U:
		return BIT(1);
	case 120U:
		return BIT(2);
	case 144U:
		return BIT(3);
	default:
		return 0;
	}
}

static bool oc_is_stock_fhd_record(const u8 *record)
{
	return record &&
		oc_buf_u32(record, oc_layout.width_offset) == OC_NATIVE_WIDTH &&
		oc_buf_u32(record, oc_layout.height_offset) == OC_NATIVE_HEIGHT &&
		oc_stock_fhd_refresh_bit(
			oc_buf_u32(record, oc_layout.refresh_offset));
}

static int oc_prepare_runtime_base(u8 *target, const u8 *source)
{
	u32 seen = 0;
	u32 input;
	u32 output = 0;
	u32 removed = 0;

	if (!target || !source)
		return -EINVAL;
	for (input = 0; input < oc_layout.count; input++) {
		const u8 *source_record = source + input * oc_layout.stride;
		u32 bit = oc_is_stock_fhd_record(source_record) ?
			oc_stock_fhd_refresh_bit(oc_buf_u32(
				source_record, oc_layout.refresh_offset)) : 0;

		if (drop_stock_fhd && bit) {
			if (seen & bit)
				return -EEXIST;
			seen |= bit;
			removed++;
			continue;
		}
		memcpy(target + output * oc_layout.stride, source_record,
		       oc_layout.stride);
		if (oc_layout.index_offset != OC_INVALID_OFFSET)
			oc_write_u32(target + output * oc_layout.stride,
				     oc_layout.index_offset, output);
		output++;
	}
	if (drop_stock_fhd &&
	    (removed != OC_STOCK_FHD_COUNT || seen != GENMASK(3, 0)))
		return -EPROTO;
	if (!output)
		return -ENODEV;
	oc_layout.runtime_base_count = output;
	oc_layout.runtime_count = output;
	removed_stock_fhd_count = removed;
	return 0;
}

static bool oc_verify_runtime_base(void)
{
	u8 expected[OC_MAX_MODE_STRIDE];
	u32 input;
	u32 output = 0;

	if (!oc_layout.runtime_modes || !oc_saved_modes ||
	    oc_layout.stride > sizeof(expected))
		return false;
	for (input = 0; input < mode_count_before; input++) {
		const u8 *source_record = oc_saved_modes +
			input * oc_layout.stride;
		const u8 *runtime_record;

		if (drop_stock_fhd && oc_is_stock_fhd_record(source_record))
			continue;
		if (output >= oc_layout.runtime_base_count)
			return false;
		memcpy(expected, source_record, oc_layout.stride);
		if (oc_layout.index_offset != OC_INVALID_OFFSET)
			memcpy(expected + oc_layout.index_offset, &output,
			       sizeof(output));
		runtime_record = (const u8 *)oc_layout.runtime_modes +
			output * oc_layout.stride;
		if (memcmp(runtime_record, expected, oc_layout.stride))
			return false;
		output++;
	}
	return output == oc_layout.runtime_base_count;
}

static void oc_restore_stock_fhd_drm_modes(void)
{
	struct drm_connector *connector = oc_layout.connector;
	u32 i;

	if (!connector || !connector->dev || !oc_layout.hidden_stock_fhd_count)
		return;
	mutex_lock(&connector->dev->mode_config.mutex);
	for (i = 0; i < oc_layout.hidden_stock_fhd_count; i++) {
		struct drm_display_mode *mode =
			oc_layout.hidden_stock_fhd_modes[i];

		if (!mode)
			continue;
		list_add_tail(&mode->head, &connector->modes);
		oc_layout.hidden_stock_fhd_modes[i] = NULL;
	}
	oc_layout.hidden_stock_fhd_count = 0;
	removed_stock_fhd_drm_count = 0;
	mutex_unlock(&connector->dev->mode_config.mutex);
}

static int oc_hide_stock_fhd_drm_modes(void)
{
	struct drm_connector *connector = oc_layout.connector;
	struct drm_display_mode *mode;
	struct drm_display_mode *next;
	u32 seen = 0;
	int ret = 0;

	if (!drop_stock_fhd)
		return 0;
	if (!connector || !connector->dev)
		return -ENODEV;
	mutex_lock(&connector->dev->mode_config.mutex);
	list_for_each_entry_safe(mode, next, &connector->modes, head) {
		u32 refresh;
		u32 bit;

		if (mode->hdisplay != OC_NATIVE_WIDTH ||
		    mode->vdisplay != OC_NATIVE_HEIGHT)
			continue;
		refresh = drm_mode_vrefresh(mode);
		bit = oc_stock_fhd_refresh_bit(refresh);
		if (!bit)
			continue;
		if ((seen & bit) ||
		    oc_layout.hidden_stock_fhd_count >= OC_STOCK_FHD_COUNT) {
			ret = -EEXIST;
			break;
		}
		seen |= bit;
		list_del_init(&mode->head);
		oc_layout.hidden_stock_fhd_modes[
			oc_layout.hidden_stock_fhd_count++] = mode;
	}
	if (!ret && (oc_layout.hidden_stock_fhd_count != OC_STOCK_FHD_COUNT ||
		    seen != GENMASK(3, 0)))
		ret = -EPROTO;
	if (ret) {
		u32 i;

		for (i = 0; i < oc_layout.hidden_stock_fhd_count; i++) {
			mode = oc_layout.hidden_stock_fhd_modes[i];
			if (mode)
				list_add_tail(&mode->head, &connector->modes);
			oc_layout.hidden_stock_fhd_modes[i] = NULL;
		}
		oc_layout.hidden_stock_fhd_count = 0;
		removed_stock_fhd_drm_count = 0;
	} else {
		removed_stock_fhd_drm_count =
			oc_layout.hidden_stock_fhd_count;
	}
	mutex_unlock(&connector->dev->mode_config.mutex);
	return ret;
}

static int oc_find_template_for_spec(const u8 *records, u32 count,
					     const struct oc_mode_spec *spec)
{
	unsigned int i;
#ifndef RMX5200_LOW_REFRESH_EXPERIMENT
	int best = -EINVAL;
	u32 best_refresh = 0;
	int best_above = -EINVAL;
	u32 lowest_above = UINT_MAX;
#endif

	for (i = 0; i < count; i++) {
		const u8 *record = records + i * oc_layout.stride;
		u32 width = oc_buf_u32(record, oc_layout.width_offset);
		u32 height = oc_buf_u32(record, oc_layout.height_offset);
		u32 refresh = oc_buf_u32(record, oc_layout.refresh_offset);

		if (width != spec->width || height != spec->height ||
			!oc_refresh_sane(refresh))
			continue;
		if (spec->source_refresh) {
			if (refresh == spec->source_refresh)
				return (int)i;
			continue;
		}
#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
		if (refresh == OC_SOURCE_FPS)
			return (int)i;
		continue;
#else
		/* Match process_dts: 123 derives from 120, while 150+ derives
		 * from 144. In general use the highest stock rate not exceeding
		 * the target, with the lowest higher rate as a fallback. */
		if (refresh <= spec->refresh && (best < 0 || refresh > best_refresh)) {
			best = (int)i;
			best_refresh = refresh;
		}
		if (refresh > spec->refresh && refresh < lowest_above) {
			best_above = (int)i;
			lowest_above = refresh;
		}
#endif
	}
#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
	return -ENOENT;
#else
	return best >= 0 ? best : best_above;
#endif
}

static bool oc_runtime_mode_exists(const u8 *records, u32 count,
					   const struct oc_mode_spec *spec)
{
	unsigned int i;

	for (i = 0; i < count; i++) {
		const u8 *record = records + i * oc_layout.stride;
		if (oc_buf_u32(record, oc_layout.width_offset) == spec->width &&
			oc_buf_u32(record, oc_layout.height_offset) == spec->height &&
			oc_buf_u32(record, oc_layout.refresh_offset) == spec->refresh)
			return true;
	}
	return false;
}

static int oc_clone_runtime_priv(const struct oc_mode_spec *spec, u64 clock,
				 void *source_priv, void **target_priv_out,
				 void **target_phy_out, bool *tuned)
{
	void *source_phy;
	u32 source_timing[OC_PHY_TIMING_LENGTH];
	u8 *target_priv;
	u32 *target_phy;
	u32 source_phy_length;
	size_t source_size;
	size_t phy_offset;
	int ret;

	if (!spec || !source_priv || !target_priv_out || !target_phy_out ||
	    !tuned)
		return -EINVAL;
	source_size = ksize(source_priv);
	if (!source_size || source_size > OC_MAX_PRIV_SIZE ||
	    oc_layout.priv_phy_values_offset + sizeof(void *) > source_size ||
	    oc_layout.priv_phy_length_offset + sizeof(source_phy_length) >
		source_size ||
	    !oc_read_pointer(source_priv, oc_layout.priv_phy_values_offset,
			     &source_phy) ||
	    !oc_read_mem((u8 *)source_priv + oc_layout.priv_phy_length_offset,
			 &source_phy_length, sizeof(source_phy_length)) ||
	    source_phy_length != OC_PHY_TIMING_LENGTH ||
	    !oc_read_mem(source_phy, source_timing, sizeof(source_timing)))
		return -EPROTO;
	phy_offset = ALIGN(source_size, sizeof(void *));
	if (phy_offset > OC_MAX_PRIV_SIZE ||
	    phy_offset + OC_PHY_TIMING_BYTES < phy_offset)
		return -EOVERFLOW;
	target_priv = kmalloc(phy_offset + OC_PHY_TIMING_BYTES, GFP_KERNEL);
	if (!target_priv)
		return -ENOMEM;
	memcpy(target_priv, source_priv, source_size);
	if (phy_offset > source_size)
		memset(target_priv + source_size, 0, phy_offset - source_size);
	target_phy = (u32 *)(target_priv + phy_offset);
	ret = oc_prepare_phy_timing(spec, clock, source_timing, target_phy,
				    tuned);
	if (ret) {
		kfree(target_priv);
		return ret;
	}
	oc_write_pointer(target_priv, oc_layout.priv_phy_values_offset,
			 target_phy);
	oc_write_u32(target_priv, oc_layout.priv_phy_length_offset,
		       OC_PHY_TIMING_LENGTH);
	*target_priv_out = target_priv;
	*target_phy_out = target_phy;
	return 0;
}

static void oc_free_runtime_priv(void)
{
	unsigned int i;

	for (i = 0; i < oc_layout.runtime_priv_count; i++) {
		kfree(oc_layout.runtime_priv[i]);
		oc_layout.runtime_priv[i] = NULL;
		oc_layout.runtime_phy[i] = NULL;
		memset(oc_layout.runtime_phy_expected[i], 0,
		       OC_PHY_TIMING_BYTES);
	}
	oc_layout.runtime_priv_count = 0;
}

static bool oc_verify_dynamic_modes(const struct oc_mode_spec *specs,
					    unsigned int spec_count)
{
	unsigned int i;

	if (!oc_layout.runtime_modes || !oc_saved_modes ||
		oc_layout.runtime_count !=
			oc_layout.runtime_base_count + oc_layout.runtime_added)
		return false;
	/* The retained WQHD records remain byte-identical except for their compact
	 * sequential index after the explicit stock FHD records are removed. */
	if (!oc_verify_runtime_base())
		return false;
	for (i = 0; i < oc_layout.runtime_added; i++) {
		const u8 *record = (const u8 *)oc_layout.runtime_modes +
			(oc_layout.runtime_base_count + i) * oc_layout.stride;
		const struct oc_mode_spec *spec = &oc_layout.runtime_specs[i];
		void *priv;
		void *phy;
		u64 private_clock;
		u32 private_transfer_time_us;
		u32 private_phy_length;
		u32 private_phy[OC_PHY_TIMING_LENGTH];

		if (!oc_mode_spec_sane(spec) ||
			oc_buf_u32(record, oc_layout.width_offset) != spec->width ||
			oc_buf_u32(record, oc_layout.height_offset) != spec->height ||
			oc_buf_u32(record, oc_layout.refresh_offset) != spec->refresh ||
			(oc_layout.index_offset != OC_INVALID_OFFSET &&
			 oc_buf_u32(record, oc_layout.index_offset) !=
				 oc_layout.runtime_base_count + i) ||
			oc_buf_u32(record, OC_MODE_H_FRONT_PORCH_OFFSET) !=
				spec->h_front_porch ||
			oc_buf_u32(record, OC_MODE_V_FRONT_PORCH_OFFSET) !=
				spec->v_front_porch ||
			!oc_read_mem(record + oc_layout.clock_offset, &private_clock,
				     sizeof(u64)))
			return false;
		priv = (void *)(uintptr_t)oc_buf_u64(record, oc_layout.priv_offset);
		if (!priv || !oc_read_mem((u8 *)priv + oc_layout.priv_clock_offset,
					 &private_clock, sizeof(private_clock)) ||
			private_clock != oc_buf_u64(record, oc_layout.clock_offset) ||
		    !spec->transfer_time_us ||
		    !oc_read_mem((u8 *)priv + oc_layout.priv_transfer_offset,
				 &private_transfer_time_us,
				 sizeof(private_transfer_time_us)) ||
		    private_transfer_time_us != spec->transfer_time_us ||
		    !oc_read_pointer(priv, oc_layout.priv_phy_values_offset, &phy) ||
		    phy != oc_layout.runtime_phy[i] ||
		    !oc_read_mem((u8 *)priv + oc_layout.priv_phy_length_offset,
				 &private_phy_length, sizeof(private_phy_length)) ||
		    private_phy_length != OC_PHY_TIMING_LENGTH ||
		    !oc_read_mem(phy, private_phy, sizeof(private_phy)) ||
		    memcmp(private_phy, oc_layout.runtime_phy_expected[i],
			   sizeof(private_phy)))
			return false;
	}
	for (i = 0; i < oc_layout.panel_count_fields; i++) {
		u32 value;
		if (!oc_read_mem((u8 *)oc_layout.panel +
				 oc_layout.panel_count_offsets[i], &value, sizeof(value)) ||
			value != oc_layout.runtime_count)
			return false;
	}
	(void)specs;
	(void)spec_count;
	return true;
}

static struct drm_display_mode *oc_find_drm_template(
	struct drm_connector *connector, const struct oc_mode_spec *spec)
{
	struct drm_display_mode *mode;
	struct drm_display_mode *best = NULL;
	int best_refresh = 0;
	struct drm_display_mode *best_above = NULL;
	int lowest_above = INT_MAX;

	list_for_each_entry(mode, &connector->modes, head) {
		int refresh;

		if (mode->hdisplay != spec->width || mode->vdisplay != spec->height)
			continue;
		refresh = drm_mode_vrefresh(mode);
		if (refresh <= spec->refresh && (!best || refresh > best_refresh)) {
			best = mode;
			best_refresh = refresh;
		}
		if (refresh > spec->refresh && refresh < lowest_above) {
			best_above = mode;
			lowest_above = refresh;
		}
	}
	return best ? best : best_above;
}

static void oc_restore_drm_modes(void)
{
	struct drm_connector *connector = oc_layout.connector;
	unsigned int i;

	if (!connector || !connector->dev || !oc_layout.runtime_drm_count)
		return;
	mutex_lock(&connector->dev->mode_config.mutex);
	for (i = 0; i < oc_layout.runtime_drm_count; i++) {
		struct drm_display_mode *mode = oc_layout.runtime_drm_modes[i];

		if (!mode)
			continue;
		list_del_init(&mode->head);
		drm_mode_destroy(connector->dev, mode);
		oc_layout.runtime_drm_modes[i] = NULL;
	}
	oc_layout.runtime_drm_count = 0;
	mutex_unlock(&connector->dev->mode_config.mutex);
}

static int oc_publish_drm_modes(void)
{
	struct drm_connector *connector = oc_layout.connector;
	unsigned int i;

	if (!connector || !connector->dev)
		return -ENODEV;
	mutex_lock(&connector->dev->mode_config.mutex);
	for (i = 0; i < oc_layout.runtime_added; i++) {
		const struct oc_mode_spec *spec = &oc_layout.runtime_specs[i];
		struct drm_display_mode *template;
		struct drm_display_mode *mode;
		const u8 *record;
		u32 h_active;
		u32 h_front;
		u32 h_sync;
		u32 h_back;
		u32 v_active;
		u32 v_front;
		u32 v_sync;
		u32 v_back;
		u32 h_total;
		u32 v_total;
		u64 pixel_clock_khz;

		template = oc_find_drm_template(connector, spec);
		if (!template) {
			mutex_unlock(&connector->dev->mode_config.mutex);
			return -ENOENT;
		}
		record = (const u8 *)oc_layout.runtime_modes +
			(oc_layout.runtime_base_count + i) * oc_layout.stride;
		h_active = oc_buf_u32(record, oc_layout.width_offset);
		h_front = oc_buf_u32(record, OC_MODE_H_FRONT_PORCH_OFFSET);
		h_sync = oc_buf_u32(record, OC_MODE_H_SYNC_WIDTH_OFFSET);
		h_back = oc_buf_u32(record, OC_MODE_H_BACK_PORCH_OFFSET);
		v_active = oc_buf_u32(record, oc_layout.height_offset);
		v_front = oc_buf_u32(record, OC_MODE_V_FRONT_PORCH_OFFSET);
		v_sync = oc_buf_u32(record, OC_MODE_V_SYNC_WIDTH_OFFSET);
		v_back = oc_buf_u32(record, OC_MODE_V_BACK_PORCH_OFFSET);
		h_total = h_active + h_front + h_sync + h_back;
		v_total = v_active + v_front + v_sync + v_back;
		pixel_clock_khz = div_u64((u64)h_total * v_total *
					 spec->refresh, 1000ULL);
		if (h_active > U16_MAX || v_active > U16_MAX ||
		    h_total > U16_MAX || v_total > U16_MAX ||
		    !pixel_clock_khz || pixel_clock_khz > INT_MAX) {
			mutex_unlock(&connector->dev->mode_config.mutex);
			return -ERANGE;
		}
		mode = drm_mode_duplicate(connector->dev, template);
		if (!mode) {
			mutex_unlock(&connector->dev->mode_config.mutex);
			return -ENOMEM;
		}
		mode->hdisplay = h_active;
		mode->hsync_start = h_active + h_front;
		mode->hsync_end = mode->hsync_start + h_sync;
		mode->htotal = h_total;
		mode->vdisplay = v_active;
		mode->vsync_start = v_active + v_front;
		mode->vsync_end = mode->vsync_start + v_sync;
		mode->vtotal = v_total;
		mode->clock = (int)pixel_clock_khz;
		mode->crtc_clock = mode->clock;
		mode->crtc_hdisplay = mode->hdisplay;
		mode->crtc_hblank_start = mode->hdisplay;
		mode->crtc_hblank_end = mode->htotal;
		mode->crtc_hsync_start = mode->hsync_start;
		mode->crtc_hsync_end = mode->hsync_end;
		mode->crtc_htotal = mode->htotal;
		mode->crtc_vdisplay = mode->vdisplay;
		mode->crtc_vblank_start = mode->vdisplay;
		mode->crtc_vblank_end = mode->vtotal;
		mode->crtc_vsync_start = mode->vsync_start;
		mode->crtc_vsync_end = mode->vsync_end;
		mode->crtc_vtotal = mode->vtotal;
		mode->type &= ~DRM_MODE_TYPE_PREFERRED;
		scnprintf(mode->name, sizeof(mode->name), "%ux%ux%ucmd",
			spec->width, spec->height, spec->refresh);
		if (drm_mode_vrefresh(mode) != spec->refresh) {
			drm_mode_destroy(connector->dev, mode);
			mutex_unlock(&connector->dev->mode_config.mutex);
			return -ERANGE;
		}
		drm_mode_probed_add(connector, mode);
		/* The internal list-update helper is not exported on this build.
		 * These modes are unique by clock, so the no-duplicate fast path is
		 * equivalent to list_move_tail() under the same mode-config lock. */
		list_move_tail(&mode->head, &connector->modes);
		oc_layout.runtime_drm_modes[oc_layout.runtime_drm_count++] = mode;
	}
	mutex_unlock(&connector->dev->mode_config.mutex);
	return 0;
}

static noinline int oc_apply_dynamic_modes(void)
{
	struct oc_mode_spec specs[OC_MAX_SPEC_MODES];
	u8 *new_modes;
	const u8 *old_modes;
	unsigned int spec_count;
	unsigned int i;
	int ret;

	ret = oc_parse_mode_specs(specs, &spec_count);
	if (ret)
		return ret;
	if (oc_layout.count + spec_count > OC_MAX_RUNTIME_MODES)
		return -E2BIG;
	oc_layout.original_modes = oc_layout.modes;
	oc_saved_modes_size = (size_t)oc_layout.count * oc_layout.stride;
	oc_saved_modes = kmemdup(oc_layout.modes, oc_saved_modes_size,
					 GFP_KERNEL);
	if (!oc_saved_modes)
		return -ENOMEM;
	old_modes = oc_saved_modes;
	new_modes = kmalloc((size_t)(oc_layout.count + spec_count) *
				    oc_layout.stride, GFP_KERNEL);
	if (!new_modes) {
		ret = -ENOMEM;
		goto fail;
	}
	ret = oc_prepare_runtime_base(new_modes, old_modes);
	if (ret)
		goto fail;
	oc_layout.runtime_added = 0;
	oc_layout.runtime_priv_count = 0;
	phy_profile_applied = false;
	phy_profile_mode_count = 0;

	for (i = 0; i < spec_count; i++) {
		struct oc_mode_spec *spec = &specs[i];
		int source_index;
		const u8 *source_record;
		void *source_priv;
		void *target_priv;
		void *target_phy;
		bool phy_tuned;
		u32 source_refresh;
		u32 source_transfer_time_us;
		u32 target_transfer_time_us;
		u64 source_clock;
		u64 target_clock;
		u32 target_index;
		u8 *target_record;
		u32 source_pixel = 0;

		if (oc_runtime_mode_exists(old_modes, oc_layout.count,
					  spec))
			continue;
		if (oc_runtime_mode_exists(new_modes, oc_layout.runtime_count,
					  spec))
			continue;
		source_index = oc_find_template_for_spec(old_modes, oc_layout.count,
							 spec);
		if (source_index < 0) {
			ret = -ENOENT;
			goto fail;
		}
		source_record = old_modes + source_index * oc_layout.stride;
		source_refresh = oc_buf_u32(source_record,
						oc_layout.refresh_offset);
		source_clock = oc_buf_u64(source_record, oc_layout.clock_offset);
		if (!source_refresh || !source_clock ||
			!oc_read_pointer(source_record, oc_layout.priv_offset,
					 &source_priv) ||
			oc_layout.priv_clock_offset + sizeof(u64) > ksize(source_priv) ||
			oc_layout.priv_transfer_offset + sizeof(u32) > ksize(source_priv) ||
			!oc_read_mem((u8 *)source_priv + oc_layout.priv_transfer_offset,
				     &source_transfer_time_us,
				     sizeof(source_transfer_time_us)) ||
			!source_transfer_time_us ||
			ksize(source_priv) > OC_MAX_PRIV_SIZE) {
			ret = -EPROTO;
			goto fail;
		}
		target_clock = spec->clock ? spec->clock :
			div_u64(source_clock * spec->refresh, source_refresh);
		if (!oc_clock_sane(target_clock, source_clock)) {
			ret = -ERANGE;
			goto fail;
		}
#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
		if (source_refresh != OC_SOURCE_FPS ||
		    source_clock != OC_LOW_LINK_CLOCK ||
		    source_transfer_time_us != OC_LOW_LINK_TRANSFER_US ||
		    target_clock != OC_LOW_LINK_CLOCK) {
			ret = -EPROTO;
			goto fail;
		}
		target_transfer_time_us = source_transfer_time_us;
#else
		target_transfer_time_us = spec->transfer_time_us ?
			spec->transfer_time_us : (u32)div_u64(
				(u64)source_transfer_time_us * source_refresh,
				spec->refresh);
#endif
		if (target_transfer_time_us < 1000U ||
		    target_transfer_time_us > 20000U) {
			ret = -ERANGE;
			goto fail;
		}
		target_index = oc_layout.runtime_count;
		target_record = new_modes + target_index * oc_layout.stride;
		memcpy(target_record, source_record, oc_layout.stride);
		oc_write_u32(target_record, oc_layout.width_offset, spec->width);
		oc_write_u32(target_record, oc_layout.height_offset, spec->height);
		oc_write_u32(target_record, oc_layout.refresh_offset, spec->refresh);
		oc_write_u64(target_record, oc_layout.clock_offset, target_clock);
		spec->h_front_porch = oc_buf_u32(
			source_record, OC_MODE_H_FRONT_PORCH_OFFSET);
		spec->v_front_porch = oc_buf_u32(
			source_record, OC_MODE_V_FRONT_PORCH_OFFSET);
		if (oc_layout.pixel_offset != OC_INVALID_OFFSET) {
			source_pixel = oc_buf_u32(source_record,
						  oc_layout.pixel_offset);
			if (source_pixel)
				oc_write_u32(target_record, oc_layout.pixel_offset,
						(u32)div_u64((u64)source_pixel * target_clock,
							     source_clock));
		}
		if (oc_layout.index_offset != OC_INVALID_OFFSET)
			oc_write_u32(target_record, oc_layout.index_offset,
					target_index);
		ret = oc_clone_runtime_priv(spec, target_clock, source_priv,
					    &target_priv, &target_phy, &phy_tuned);
		if (ret)
			goto fail;
		oc_layout.runtime_priv[oc_layout.runtime_priv_count++] = target_priv;
		oc_layout.runtime_phy[oc_layout.runtime_added] = target_phy;
		memcpy(oc_layout.runtime_phy_expected[oc_layout.runtime_added],
		       target_phy, OC_PHY_TIMING_BYTES);
		oc_write_u64(target_priv, oc_layout.priv_clock_offset,
				target_clock);
		oc_write_u32(target_priv, oc_layout.priv_transfer_offset,
				target_transfer_time_us);
		oc_write_pointer(target_record, oc_layout.priv_offset, target_priv);
		spec->transfer_time_us = target_transfer_time_us;
		oc_layout.runtime_specs[oc_layout.runtime_added++] = *spec;
		if (phy_tuned) {
			phy_profile_applied = true;
			phy_profile_mode_count++;
		}
		oc_layout.runtime_count++;
	}
	if (!oc_layout.runtime_added) {
		ret = -EEXIST;
		goto fail;
	}

	oc_layout.runtime_modes = new_modes;
	mutex_lock((struct mutex *)((u8 *)oc_layout.display + 0x48));
	oc_write_pointer(oc_layout.display, 0x338, new_modes);
	for (i = 0; i < oc_layout.panel_count_fields; i++)
		oc_write_u32(oc_layout.panel,
				 oc_layout.panel_count_offsets[i], oc_layout.runtime_count);
	oc_layout.modes = new_modes;
	oc_layout.count = oc_layout.runtime_count;
	mode_count_after = oc_layout.runtime_count;
	injected_mode_count = oc_layout.runtime_added;
	connector_mode_count_before = oc_connector_mode_count(oc_layout.connector);
	mutex_unlock((struct mutex *)((u8 *)oc_layout.display + 0x48));
	smp_wmb();
	if (!oc_verify_dynamic_modes(specs, spec_count)) {
		ret = -EIO;
		goto fail_published;
	}
	cache_applied = true;
	ret = oc_hide_stock_fhd_drm_modes();
	if (ret)
		goto fail_published;
	ret = oc_publish_drm_modes();
	if (ret)
		goto fail_published;
	connector_mode_count_after = oc_connector_mode_count(oc_layout.connector);
	if (drop_stock_fhd &&
	    (connector_mode_count_before < OC_STOCK_FHD_COUNT ||
	     connector_mode_count_after != connector_mode_count_before -
		OC_STOCK_FHD_COUNT + oc_layout.runtime_added)) {
		ret = -EIO;
		goto fail_published;
	}
	if (oc_layout.connector && oc_layout.connector->dev) {
		drm_kms_helper_connector_hotplug_event(oc_layout.connector);
		drm_kms_helper_hotplug_event(oc_layout.connector->dev);
		connector_hotplug_sent = 1;
	}
	return 0;

fail_published:
	oc_restore_drm_modes();
	oc_restore_stock_fhd_drm_modes();
	mutex_lock((struct mutex *)((u8 *)oc_layout.display + 0x48));
	oc_write_pointer(oc_layout.display, 0x338, oc_layout.original_modes);
	for (i = 0; i < oc_layout.panel_count_fields; i++)
		oc_write_u32(oc_layout.panel,
				 oc_layout.panel_count_offsets[i], mode_count_before);
	oc_layout.modes = oc_layout.original_modes;
	oc_layout.count = mode_count_before;
	mutex_unlock((struct mutex *)((u8 *)oc_layout.display + 0x48));
fail:
	kfree(new_modes);
	oc_layout.runtime_modes = NULL;
	oc_layout.runtime_base_count = 0;
	removed_stock_fhd_count = 0;
	oc_free_runtime_priv();
	kfree(oc_saved_modes);
	oc_saved_modes = NULL;
	oc_saved_modes_size = 0;
	return ret;
}

static void oc_restore_dynamic_modes(void)
{
	unsigned int i;

#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
	WRITE_ONCE(oc_touch_boost_enabled, false);
	WRITE_ONCE(oc_touch_boost_ready, false);
	WRITE_ONCE(oc_late_low_guard_armed, false);
	WRITE_ONCE(oc_rise_guard_armed, false);
	WRITE_ONCE(oc_rise_guard_ready, false);
	cancel_work_sync(&oc_touch_boost_work);
	cancel_work_sync(&oc_late_low_guard_work);
	cancel_work_sync(&oc_rise_guard_work);
	oc_unregister_touch_boost_ept_bypass();
	oc_unregister_physical_commit_hook();
	oc_unregister_iris_hook();
#endif
	if (!oc_layout.original_modes)
		return;
	oc_restore_drm_modes();
	oc_restore_stock_fhd_drm_modes();
	mutex_lock((struct mutex *)((u8 *)oc_layout.display + 0x48));
	oc_write_pointer(oc_layout.display, 0x338, oc_layout.original_modes);
	for (i = 0; i < oc_layout.panel_count_fields; i++)
		oc_write_u32(oc_layout.panel,
				 oc_layout.panel_count_offsets[i], mode_count_before);
	oc_layout.modes = oc_layout.original_modes;
	oc_layout.count = mode_count_before;
	mutex_unlock((struct mutex *)((u8 *)oc_layout.display + 0x48));
	if (oc_layout.connector && oc_layout.connector->dev) {
		drm_kms_helper_connector_hotplug_event(oc_layout.connector);
		drm_kms_helper_hotplug_event(oc_layout.connector->dev);
	}
	kfree(oc_layout.runtime_modes);
	oc_layout.runtime_modes = NULL;
	oc_free_runtime_priv();
	kfree(oc_saved_modes);
	oc_saved_modes = NULL;
	oc_saved_modes_size = 0;
	oc_layout.original_modes = NULL;
	oc_layout.runtime_base_count = 0;
	oc_layout.runtime_count = 0;
	oc_layout.runtime_added = 0;
	phy_profile_applied = false;
	phy_profile_mode_count = 0;
	cache_applied = false;
	mode_count_after = mode_count_before;
	injected_mode_count = 0;
	removed_stock_fhd_count = 0;
	removed_stock_fhd_drm_count = 0;
}

static void oc_release_dt(void)
{
	unsigned int i;

	if (oc_dt.source_node) {
		of_node_put(oc_dt.source_node);
		oc_dt.source_node = NULL;
	}
	for (i = 0; i < oc_dt.target_count; i++) {
		if (!oc_dt.target_nodes[i])
			continue;
		of_node_put(oc_dt.target_nodes[i]);
		oc_dt.target_nodes[i] = NULL;
	}
	oc_dt.target_count = 0;
	if (oc_dt.timings_parent) {
		of_node_put(oc_dt.timings_parent);
		oc_dt.timings_parent = NULL;
	}
}


static int __init rmx5200_display_runtime_modes_init(void)
{
	int rc;

	if (!oc_adfr_profile_matches()) {
		rc = -EKEYREJECTED;
		adfr_profile_valid = false;
		pr_err("rmx5200_display_runtime_modes: AE084 ADFR profile mismatch id=%s state=%s family=%s\n",
		       adfr_profile_id, adfr_profile_state, adfr_command_family);
		goto fail;
	}
	adfr_profile_valid = true;
	/* This KO canonicalizes the runtime mode array and appends DRM modes. It
	 * deliberately does not synthesize or transmit panel commands after the
	 * Qualcomm ADFR parser has run. */
	adfr_command_injection_supported = false;
	if (!oc_phy_profile_valid()) {
		rc = -EINVAL;
		pr_err("rmx5200_display_runtime_modes: unsupported PHY profile '%s'\n",
		       phy_profile);
		goto fail;
	}
	rc = oc_find_dt_state();
	if (rc) {
		pr_err("rmx5200_display_runtime_modes: DT discovery failed rc=%d source=%px targets=%u count=%u\n",
			rc, oc_dt.source_node, oc_dt.target_count, oc_dt.count);
		goto fail;
	}
	rc = oc_discover_layout();
	if (rc) {
		pr_err("rmx5200_display_runtime_modes: runtime layout failed rc=%d display=%px modes=%px modes_off=0x%x panel=%px\n",
			rc, oc_layout.display, oc_layout.modes,
			display_modes_offset, oc_layout.panel);
		goto fail;
	}
	pr_info("rmx5200_display_runtime_modes: display=%px modes=%px count=%u stride=0x%x source=%u panel=0x%x count_off=0x%x\n",
		oc_layout.display, oc_layout.modes, oc_layout.count,
		oc_layout.stride, oc_layout.source_index, display_panel_offset,
		panel_count_offset);
	if (probe_only) {
		pr_info("rmx5200_display_runtime_modes: probe_only layout accepted, no memory changed\n");
		return 0;
	}
	if (!dynamic_modes) {
		rc = -EOPNOTSUPP;
		goto fail;
	}
	rc = oc_apply_dynamic_modes();
	if (rc)
		goto fail;
#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
	rc = oc_prepare_touch_boost();
	if (rc) {
		pr_err("rmx5200_ltpo_runtime_modes: AE084 QHD120 touch boost validation failed rc=%d\n",
		       rc);
		goto fail;
	}
	rc = oc_register_iris_hooks();
	if (rc) {
		pr_err("rmx5200_ltpo_runtime_modes: Iris slot-%u hooks failed mask=0x%x rc=%d\n",
		       OC_IRIS_WQHD60_SLOT, oc_iris_hook_registered_mask, rc);
		goto fail;
	}
	rc = oc_register_physical_commit_hook();
	if (rc) {
		pr_err("rmx5200_ltpo_runtime_modes: DSI physical commit hook failed rc=%d\n",
		       rc);
		goto fail;
	}
	rc = oc_register_touch_boost_ept_bypass();
	if (rc) {
		pr_err("rmx5200_ltpo_runtime_modes: touch EPT bypass hook failed rc=%d\n",
		       rc);
		goto fail;
	}
	oc_rise_guard_ready = true;
#endif
	applied = true;
	pr_info("rmx5200_display_runtime_modes: removed stock FHD=%u connector=%u, appended WQHD=%u, count %u -> %u; PHY profile=%s tuned=%u; connector hotplug=%u; ADFR profile=%s command_injection=0; Iris hooks=0x%x; touch_boost=%u; physical_commit_hook=%u; ept_bypass_hook=%u; cesta_ept_bypass_hook=%u; late_low_guard=1; rise_guard=%u; DTBO untouched\n",
		removed_stock_fhd_count, removed_stock_fhd_drm_count,
		injected_mode_count, mode_count_before, mode_count_after,
		phy_profile, phy_profile_mode_count, connector_hotplug_sent,
		adfr_profile_id,
#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
		oc_iris_hook_registered_mask,
		oc_touch_boost_ready ? 1U : 0U,
		oc_physical_commit_hook_registered ? 1U : 0U,
		oc_touch_boost_ept_bypass_registered ? 1U : 0U,
		oc_touch_boost_cesta_ept_bypass_registered ? 1U : 0U,
		oc_rise_guard_ready ? 1U : 0U
#else
		0U, 0U, 0U, 0U, 0U, 0U
#endif
		);
	return 0;

fail:
	failure_code = (unsigned int)(rc < 0 ? -rc : rc);
	applied = false;
	oc_restore_dynamic_modes();
	oc_release_dt();
	pr_err("rmx5200_display_runtime_modes: refused to apply, error=%d\n", rc);
	return rc;
}

static void __exit rmx5200_display_runtime_modes_exit(void)
{
	oc_restore_dynamic_modes();
	oc_release_dt();
	applied = false;
	pr_info("rmx5200_display_runtime_modes: live mode array restored; connector hotplug sent\n");
}

module_init(rmx5200_display_runtime_modes_init);
module_exit(rmx5200_display_runtime_modes_exit);

#ifdef RMX5200_LOW_REFRESH_EXPERIMENT
MODULE_DESCRIPTION("RMX5200 AE084 reversible QHD 30/10/1Hz LTPO experiment");
MODULE_VERSION("0.5-rmx5200-ae084-rise-guard");
#else
MODULE_DESCRIPTION("RMX5200 Qualcomm DRM-KO runtime timing mode injector");
MODULE_VERSION("0.13-rmx5200-unique-fhd-group");
#endif
MODULE_AUTHOR("murongchaopin prototype");
MODULE_LICENSE("GPL");
