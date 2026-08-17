// SPDX-License-Identifier: GPL-2.0
/*
 * PLK110 Qualcomm DRM-KO backend.
 *
 * The module does not write DTBO or any partition.  It discovers the primary
 * DSI display through the msm_drm exported get_main_display() helper, verifies
 * the live timing tree and the parsed mode array, then appends runtime modes
 * described by mode_specs. The runtime path only clones the verified stock
 * 165Hz parsed timing record and recalculates its clock/pixel fields. Stock
 * low-refresh records are left untouched; ADFR command properties remain a
 * DTBO concern and are not synthesized after the panel parser has run.
 *
 * The implementation follows the live-mode injection pattern used by
 * pmb110_170_mode.c: clone timing data, append verified mode records and DRM
 * modes, keep a rollback copy, and never touch the DTBO block device. Qualcomm's private
 * dsi_display_mode layout is discovered and checked against the live DT before
 * any write. A failed probe is fail-closed.
 */
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <drm/drm_connector.h>
#include <drm/drm_device.h>
#include <drm/drm_modes.h>
#include <drm/drm_probe_helper.h>

/* Exported by the OnePlus msm_drm module. The shared PLK profile treats the
 * object as opaque. PJD110 includes the matching private 6.1 header first so
 * its write-side offsets are derived with offsetof() at build time. */
#ifndef OC_HAVE_GET_MAIN_DISPLAY_DECL
extern void *get_main_display(void);
#endif

#ifndef OC_PROFILE_NAME
#define OC_PROFILE_NAME "plk110"
#endif
#ifndef OC_LOG_PREFIX
#define OC_LOG_PREFIX "plk110_display_runtime_modes"
#endif
#ifndef OC_NATIVE_WIDTH
#define OC_NATIVE_WIDTH 1272U
#endif
#ifndef OC_NATIVE_HEIGHT
#define OC_NATIVE_HEIGHT 2772U
#endif
#ifndef OC_SOURCE_FPS
#define OC_SOURCE_FPS 165U
#endif
#ifndef OC_MODE_COUNT
#define OC_MODE_COUNT 6U
#endif
#define OC_TARGET_MODE_COUNT 3U
#define OC_MAX_RUNTIME_MODES 32U
#define OC_MAX_SPEC_MODES 32U
#define OC_MAX_SPEC_TEXT 2048U
#define OC_HIGHEST_FPS 199U
#define OC_TARGET_WIDTH OC_NATIVE_WIDTH
#define OC_TARGET_HEIGHT OC_NATIVE_HEIGHT
#ifndef OC_PANEL_TOKEN
#define OC_PANEL_TOKEN "AD296_P_3_A0020"
#endif
#ifndef OC_EXPECT_60
#define OC_EXPECT_60 1U
#endif
#ifndef OC_EXPECT_90
#define OC_EXPECT_90 1U
#endif
#ifndef OC_EXPECT_120
#define OC_EXPECT_120 2U
#endif
#ifndef OC_EXPECT_144
#define OC_EXPECT_144 1U
#endif
#ifndef OC_EXPECT_165
#define OC_EXPECT_165 1U
#endif
#ifndef OC_DROP_STOCK_LOW_DEFAULT
#define OC_DROP_STOCK_LOW_DEFAULT false
#endif
#ifndef OC_EXPECT_REMOVED_STOCK_LOW
#define OC_EXPECT_REMOVED_STOCK_LOW 0U
#endif
#define OC_MIN_REFRESH 20U
#define OC_MAX_REFRESH 300U
#define OC_MAX_DT_MODES 32U
#define OC_MAX_DISPLAY_SCAN 0x800U
#ifndef OC_CONNECTOR_OFFSET
#define OC_CONNECTOR_OFFSET 0x10U
#endif
#ifndef OC_DISPLAY_LOCK_OFFSET
#define OC_DISPLAY_LOCK_OFFSET 0x48U
#endif
#ifndef OC_EXPECT_DISPLAY_MODES_OFFSET
#define OC_EXPECT_DISPLAY_MODES_OFFSET 0x338U
#endif
#ifndef OC_EXPECT_DISPLAY_PANEL_OFFSET
#define OC_EXPECT_DISPLAY_PANEL_OFFSET 0x108U
#endif
#ifndef OC_MODULE_DESCRIPTION
#define OC_MODULE_DESCRIPTION "PLK110 Qualcomm DRM-KO process_dts-compatible mode injector"
#endif
#ifndef OC_MODULE_VERSION
#define OC_MODULE_VERSION "0.2-shared-runtime-profile"
#endif
#define OC_MIN_MODE_STRIDE 0x80U
#define OC_MAX_MODE_STRIDE 0x200U
#define OC_MAX_PRIV_SCAN 0x4000U
#define OC_MAX_PRIV_SIZE 0x10000U
#define OC_MAX_PROPERTIES 256U
#define OC_MAX_FIELD_POSITIONS 8U
#define OC_INVALID_OFFSET (~0U)

static char mode_specs[OC_MAX_SPEC_TEXT];
module_param_string(mode_specs, mode_specs, sizeof(mode_specs), 0400);
MODULE_PARM_DESC(mode_specs,
	"Semicolon separated modes: widthxheight@refresh[:clock_hz]");

static bool dynamic_modes = true;
module_param(dynamic_modes, bool, 0400);
MODULE_PARM_DESC(dynamic_modes,
	"Use the live timing append transaction without modifying stock modes");

static bool drop_stock_low = OC_DROP_STOCK_LOW_DEFAULT;
module_param(drop_stock_low, bool, 0400);
MODULE_PARM_DESC(drop_stock_low,
	"Remove the verified stock 60/90Hz records from parsed and DRM mode lists");

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
static unsigned int expected_display_modes_offset =
	OC_EXPECT_DISPLAY_MODES_OFFSET;
module_param(expected_display_modes_offset, uint, 0444);
static unsigned int display_lock_offset = OC_DISPLAY_LOCK_OFFSET;
module_param(display_lock_offset, uint, 0444);
static unsigned int expected_display_panel_offset =
	OC_EXPECT_DISPLAY_PANEL_OFFSET;
module_param(expected_display_panel_offset, uint, 0444);
static unsigned int display_connector_offset = OC_CONNECTOR_OFFSET;
module_param(display_connector_offset, uint, 0444);
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
static unsigned int removed_stock_low_count;
module_param(removed_stock_low_count, uint, 0444);
static unsigned int removed_stock_low_drm_count;
module_param(removed_stock_low_drm_count, uint, 0444);
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
	unsigned int count;
	unsigned int target_count;
};

struct oc_mode_spec {
	u32 width;
	u32 height;
	u32 refresh;
	u64 clock;
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
	u32 runtime_count;
	u32 runtime_base_count;
	u32 runtime_added;
	void *runtime_priv[OC_MAX_SPEC_MODES];
	u32 runtime_priv_count;
	struct oc_mode_spec runtime_specs[OC_MAX_SPEC_MODES];
	struct drm_display_mode *runtime_drm_modes[OC_MAX_SPEC_MODES];
	u32 runtime_drm_count;
	struct drm_display_mode *removed_stock_low_drm[OC_MAX_DT_MODES];
	struct list_head *removed_stock_low_drm_next[OC_MAX_DT_MODES];
	u32 removed_stock_low_drm_count;
};

static struct oc_dt_state oc_dt;
static struct oc_mode_layout oc_layout;
static u8 *oc_saved_modes;
static size_t oc_saved_modes_size;

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

static bool oc_is_profile_timing(const struct device_node *node)
{
	const char *name;
	unsigned int offset;

	if (!oc_is_timing_node(node) || !node->parent || !node->parent->parent)
		return false;
	name = node->parent->parent->name;
	if (!name)
		return false;
	for (; *name; name++) {
		for (offset = 0; OC_PANEL_TOKEN[offset] &&
		     name[offset] == OC_PANEL_TOKEN[offset]; offset++)
			;
		if (!OC_PANEL_TOKEN[offset])
			return true;
	}
	return false;
}

static bool oc_is_fhd_timing(const struct device_node *node)
{
	u32 width;
	u32 height;

	if (!oc_is_profile_timing(node) ||
	    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-width", &width) ||
	    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-height", &height))
		return false;
	return width == OC_NATIVE_WIDTH && height == OC_NATIVE_HEIGHT;
}

static noinline int oc_find_dt_state(void)
{
	struct device_node *node = NULL;
	struct device_node *next;
	unsigned int seen_60 = 0;
	unsigned int seen_90 = 0;
	unsigned int seen_120 = 0;
	unsigned int seen_144 = 0;
	unsigned int seen_165 = 0;

	memset(&oc_dt, 0, sizeof(oc_dt));
	while ((next = of_find_node_by_name(node, "timing")) != NULL) {
		u32 width;
		u32 height;
		u32 fps;
		u32 clock;

		if (node)
			of_node_put(node);
		node = next;
		if (!oc_is_fhd_timing(node) ||
		    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-width", &width) ||
		    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-height", &height) ||
		    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-framerate", &fps) ||
		    !oc_read_dt_u32(node, "qcom,mdss-dsi-panel-clockrate", &clock))
			continue;
		if (fps != OC_SOURCE_FPS || !clock || oc_dt.source_node)
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

			if (!oc_is_fhd_timing(child) ||
			    !oc_read_dt_u32(child, "qcom,mdss-dsi-panel-width", &width) ||
			    !oc_read_dt_u32(child, "qcom,mdss-dsi-panel-height", &height) ||
			    !oc_read_dt_u32(child,
					    "qcom,mdss-dsi-panel-framerate", &fps) ||
			    !oc_read_dt_u32(child,
					    "qcom,mdss-dsi-panel-clockrate", &clock) ||
			    !clock)
				continue;
			if (oc_dt.count >= OC_MAX_DT_MODES)
				return -E2BIG;
			oc_dt.width[oc_dt.count] = width;
			oc_dt.height[oc_dt.count] = height;
			oc_dt.fps[oc_dt.count] = fps;
			oc_dt.clock[oc_dt.count++] = clock;
			switch (fps) {
			case 60U: seen_60++; break;
			case 90U: seen_90++; break;
			case 120U: seen_120++; break;
			case 144U: seen_144++; break;
			case 165U: seen_165++; break;
			default: return -ESTALE;
			}
		}
	}
	if (oc_dt.count != OC_MODE_COUNT || seen_60 != OC_EXPECT_60 ||
	    seen_90 != OC_EXPECT_90 || seen_120 != OC_EXPECT_120 ||
	    seen_144 != OC_EXPECT_144 || seen_165 != OC_EXPECT_165)
		return -ENODEV;
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

static bool oc_find_private_layout(const u8 *records, u32 stride, u32 count,
					   u32 source_index, u32 clock_offset,
					   u32 *priv_offset,
					   u32 *clock_in_priv, void **source_priv)
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
			if (clocks_ok) {
				*priv_offset = pointer_offset;
				*clock_in_priv = candidate;
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
											 cpos[ci],
											 &priv_offset,
											 &private_clock_offset,
											 &source_priv))
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
								layout->source_index = source_index;
								layout->source_priv = source_priv;
								layout->source_priv_size = ksize(source_priv);
								layout->source_pixel = source_pixel;
								layout->source_clock = oc_dt.source_clock;
				if (layout->source_priv_size < private_clock_offset + 8 ||
				    layout->source_priv_size > OC_MAX_PRIV_SIZE)
					continue;
				kfree(records);
				return 0;
							}
			}
		}
	}
	kfree(records);
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

	/* Prefer the profile's compiler-verified panel offset. Retain the count
	 * scan below because dsi_panel itself is intentionally opaque here. */
	if (oc_read_pointer(oc_layout.display, OC_EXPECT_DISPLAY_PANEL_OFFSET,
			    &known_panel) &&
	    oc_read_mem((u8 *)known_panel + 0x5a0, &known_a, sizeof(known_a)) &&
	    oc_read_mem((u8 *)known_panel + 0x5a4, &known_b, sizeof(known_b)) &&
	    known_a == oc_dt.count && known_b == oc_dt.count) {
		oc_layout.panel = known_panel;
		oc_layout.panel_count_offsets[0] = 0x5a0;
		oc_layout.panel_count_offsets[1] = 0x5a4;
		oc_layout.panel_count_values[0] = known_a;
		oc_layout.panel_count_values[1] = known_b;
		oc_layout.panel_count_fields = 2;
		display_panel_offset = OC_EXPECT_DISPLAY_PANEL_OFFSET;
		panel_count_offset = 0x5a0;
		panel_count_fields = 2;
		return 0;
	}

	for (display_offset = 0; display_offset <= OC_MAX_DISPLAY_SCAN;
	     display_offset += 8) {
		void *candidate;
		u32 offset;

		if (display_offset != OC_EXPECT_DISPLAY_PANEL_OFFSET ||
		    display_offset == display_modes_offset ||
		    !oc_read_pointer(oc_layout.display, display_offset, &candidate))
			continue;
		for (offset = 0x300; offset <= 0x900; offset += 4) {
			u32 count = 0;
			u32 next_count = 0;
			void *timing_info;
			int score;
			if (display_offset == OC_EXPECT_DISPLAY_PANEL_OFFSET &&
			    offset == 0x5a0)
				pr_info(OC_LOG_PREFIX ": panel_scan candidate=%px count=%u/%u expected=%u read=%d/%d\\n",
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
	if (display_modes_offset != OC_EXPECT_DISPLAY_MODES_OFFSET)
		return -ESTALE;
	if (!oc_read_pointer(oc_layout.display, OC_CONNECTOR_OFFSET, &connector))
		return -EPROTO;
	oc_layout.connector = connector;
	oc_read_pointer(connector, offsetof(struct drm_connector, dev),
			&connector_dev);
	oc_read_pointer(connector, offsetof(struct drm_connector, funcs),
			&connector_funcs);
	pr_info(OC_LOG_PREFIX ": connector=%px dev=%px funcs=%px offsets=%zu/%zu\\n",
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
	source_mode_index = oc_layout.source_index;
	source_clock_hz = oc_dt.source_clock;
	target_clock_hz = oc_clock_for_fps(oc_dt.source_clock, OC_HIGHEST_FPS);
	return 0;
}


static bool oc_mode_spec_sane(const struct oc_mode_spec *spec)
{
	return spec && spec->width >= 100U && spec->width <= 4096U &&
		spec->height >= 100U && spec->height <= 8192U &&
		oc_refresh_sane(spec->refresh);
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

	if (!specs || !spec_count)
		return -EINVAL;
	if (!source[0]) {
		*spec_count = 0;
		return drop_stock_low ? 0 : -EINVAL;
	}
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
		if (clock_sep)
			*clock_sep = '\0';
		ret = kstrtou32(item, 0, &spec.width);
		if (ret)
			goto parse_error;
		ret = kstrtou32(x + 1, 0, &spec.height);
		if (ret)
			goto parse_error;
		ret = kstrtou32(at + 1, 0, &spec.refresh);
		if (ret)
			goto parse_error;
		if (clock_sep) {
			ret = kstrtoull(clock_sep + 1, 0, &spec.clock);
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
		if (++count > OC_MAX_RUNTIME_MODES + OC_MODE_COUNT)
			return 0;
	}
	return count;
}

static int oc_find_template_for_spec(const u8 *records, u32 count,
					     const struct oc_mode_spec *spec)
{
	unsigned int i;
	int best = -EINVAL;
	u32 best_refresh = 0;

	for (i = 0; i < count; i++) {
		const u8 *record = records + i * oc_layout.stride;
		u32 width = oc_buf_u32(record, oc_layout.width_offset);
		u32 height = oc_buf_u32(record, oc_layout.height_offset);
		u32 refresh = oc_buf_u32(record, oc_layout.refresh_offset);

		if (width != spec->width || height != spec->height ||
			!oc_refresh_sane(refresh))
			continue;
		/* process_dts clones the highest-rate timing template for a
		 * resolution. Prefer that template even for a lower target. */
		if (best < 0 || refresh > best_refresh) {
			best = (int)i;
			best_refresh = refresh;
		}
	}
	return best;
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

static bool oc_is_stock_low_record(const u8 *record)
{
	u32 refresh;

	if (!record ||
	    oc_buf_u32(record, oc_layout.width_offset) != OC_NATIVE_WIDTH ||
	    oc_buf_u32(record, oc_layout.height_offset) != OC_NATIVE_HEIGHT)
		return false;
	refresh = oc_buf_u32(record, oc_layout.refresh_offset);
	return refresh == 60U || refresh == 90U;
}

static void oc_free_runtime_priv(void)
{
	unsigned int i;

	for (i = 0; i < oc_layout.runtime_priv_count; i++) {
		kfree(oc_layout.runtime_priv[i]);
		oc_layout.runtime_priv[i] = NULL;
	}
	oc_layout.runtime_priv_count = 0;
}

static bool oc_verify_dynamic_modes(const struct oc_mode_spec *specs,
					    unsigned int spec_count)
{
	unsigned int i;

	if (!oc_layout.runtime_modes ||
	    oc_layout.runtime_count !=
		oc_layout.runtime_base_count + oc_layout.runtime_added ||
	    removed_stock_low_count !=
		(mode_count_before - oc_layout.runtime_base_count))
		return false;
	if (drop_stock_low) {
		for (i = 0; i < oc_layout.runtime_base_count; i++) {
			const u8 *record = (const u8 *)oc_layout.runtime_modes +
				i * oc_layout.stride;
			if (oc_is_stock_low_record(record))
				return false;
		}
	}
	for (i = 0; i < oc_layout.runtime_added; i++) {
		const u8 *record = (const u8 *)oc_layout.runtime_modes +
			(oc_layout.runtime_base_count + i) * oc_layout.stride;
		const struct oc_mode_spec *spec = &oc_layout.runtime_specs[i];
		void *priv;
		u64 private_clock;

		if (!oc_mode_spec_sane(spec) ||
			oc_buf_u32(record, oc_layout.width_offset) != spec->width ||
			oc_buf_u32(record, oc_layout.height_offset) != spec->height ||
			oc_buf_u32(record, oc_layout.refresh_offset) != spec->refresh ||
			(oc_layout.index_offset != OC_INVALID_OFFSET &&
			 oc_buf_u32(record, oc_layout.index_offset) !=
				 oc_layout.runtime_base_count + i) ||
			!oc_read_mem(record + oc_layout.clock_offset, &private_clock,
				     sizeof(u64)))
			return false;
		priv = (void *)(uintptr_t)oc_buf_u64(record, oc_layout.priv_offset);
		if (!priv || !oc_read_mem((u8 *)priv + oc_layout.priv_clock_offset,
					 &private_clock, sizeof(private_clock)) ||
			private_clock != oc_buf_u64(record, oc_layout.clock_offset))
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

	list_for_each_entry(mode, &connector->modes, head) {
		int refresh;

		if (mode->hdisplay != spec->width || mode->vdisplay != spec->height)
			continue;
		refresh = drm_mode_vrefresh(mode);
		if (!best || refresh > best_refresh) {
			best = mode;
			best_refresh = refresh;
		}
	}
	return best;
}

static int oc_hide_stock_low_drm_modes_locked(struct drm_connector *connector)
{
	struct drm_display_mode *mode;
	struct drm_display_mode *next;

	if (!drop_stock_low)
		return 0;
	list_for_each_entry_safe(mode, next, &connector->modes, head) {
		int refresh = drm_mode_vrefresh(mode);

		if (mode->hdisplay != OC_NATIVE_WIDTH ||
		    mode->vdisplay != OC_NATIVE_HEIGHT ||
		    (refresh != 60 && refresh != 90))
			continue;
		if (oc_layout.removed_stock_low_drm_count >= OC_MAX_DT_MODES)
			return -E2BIG;
		oc_layout.removed_stock_low_drm[
			oc_layout.removed_stock_low_drm_count] = mode;
		oc_layout.removed_stock_low_drm_next[
			oc_layout.removed_stock_low_drm_count] = mode->head.next;
		oc_layout.removed_stock_low_drm_count++;
		list_del_init(&mode->head);
	}
	removed_stock_low_drm_count =
		oc_layout.removed_stock_low_drm_count;
	return removed_stock_low_drm_count == OC_EXPECT_REMOVED_STOCK_LOW ?
		0 : -ESTALE;
}

static void oc_restore_drm_modes(void)
{
	struct drm_connector *connector = oc_layout.connector;
	unsigned int i;

	if (!connector || !connector->dev ||
	    (!oc_layout.runtime_drm_count &&
	     !oc_layout.removed_stock_low_drm_count))
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
	for (i = oc_layout.removed_stock_low_drm_count; i > 0; i--) {
		struct drm_display_mode *mode =
			oc_layout.removed_stock_low_drm[i - 1];
		struct list_head *next =
			oc_layout.removed_stock_low_drm_next[i - 1];

		if (mode && next)
			list_add_tail(&mode->head, next);
		oc_layout.removed_stock_low_drm[i - 1] = NULL;
		oc_layout.removed_stock_low_drm_next[i - 1] = NULL;
	}
	oc_layout.removed_stock_low_drm_count = 0;
	removed_stock_low_drm_count = 0;
	mutex_unlock(&connector->dev->mode_config.mutex);
}

static int oc_publish_drm_modes(void)
{
	struct drm_connector *connector = oc_layout.connector;
	unsigned int i;

	if (!connector || !connector->dev)
		return -ENODEV;
	mutex_lock(&connector->dev->mode_config.mutex);
	if (oc_hide_stock_low_drm_modes_locked(connector)) {
		mutex_unlock(&connector->dev->mode_config.mutex);
		return -ESTALE;
	}
	for (i = 0; i < oc_layout.runtime_added; i++) {
		const struct oc_mode_spec *spec = &oc_layout.runtime_specs[i];
		struct drm_display_mode *template;
		struct drm_display_mode *mode;
		const u8 *record;
		u64 clock_hz;

		template = oc_find_drm_template(connector, spec);
		if (!template) {
			mutex_unlock(&connector->dev->mode_config.mutex);
			return -ENOENT;
		}
		record = (const u8 *)oc_layout.runtime_modes +
			(oc_layout.runtime_base_count + i) * oc_layout.stride;
		clock_hz = oc_buf_u64(record, oc_layout.clock_offset);
		if (clock_hz < 1000000ULL || clock_hz > INT_MAX * 1000ULL) {
			mutex_unlock(&connector->dev->mode_config.mutex);
			return -ERANGE;
		}
		mode = drm_mode_duplicate(connector->dev, template);
		if (!mode) {
			mutex_unlock(&connector->dev->mode_config.mutex);
			return -ENOMEM;
		}
		mode->clock = (int)div_u64(clock_hz, 1000ULL);
		mode->crtc_clock = mode->clock;
		mode->type &= ~DRM_MODE_TYPE_PREFERRED;
		scnprintf(mode->name, sizeof(mode->name), "%ux%ux%ucmd",
			spec->width, spec->height, spec->refresh);
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
	u8 *new_modes = NULL;
	const u8 *old_modes;
	unsigned int spec_count;
	unsigned int i;
	unsigned int stock_count = 0;
	unsigned int removed_count = 0;
	int ret;

	ret = oc_parse_mode_specs(specs, &spec_count);
	if (ret)
		return ret;
	oc_layout.original_modes = oc_layout.modes;
	oc_saved_modes_size = (size_t)oc_layout.count * oc_layout.stride;
	oc_saved_modes = kmemdup(oc_layout.modes, oc_saved_modes_size,
					 GFP_KERNEL);
	if (!oc_saved_modes)
		return -ENOMEM;
	old_modes = oc_saved_modes;
	for (i = 0; i < oc_layout.count; i++) {
		const u8 *record = old_modes + i * oc_layout.stride;

		if (drop_stock_low && oc_is_stock_low_record(record)) {
			removed_count++;
			continue;
		}
		stock_count++;
	}
	if (removed_count != OC_EXPECT_REMOVED_STOCK_LOW) {
		ret = -ESTALE;
		goto fail;
	}
	if (stock_count + spec_count > OC_MAX_RUNTIME_MODES) {
		ret = -E2BIG;
		goto fail;
	}
	new_modes = kmalloc((size_t)(stock_count + spec_count) *
				    oc_layout.stride, GFP_KERNEL);
	if (!new_modes) {
		ret = -ENOMEM;
		goto fail;
	}
	stock_count = 0;
	for (i = 0; i < oc_layout.count; i++) {
		const u8 *record = old_modes + i * oc_layout.stride;
		u8 *target;

		if (drop_stock_low && oc_is_stock_low_record(record))
			continue;
		target = new_modes + stock_count * oc_layout.stride;
		memcpy(target, record, oc_layout.stride);
		if (oc_layout.index_offset != OC_INVALID_OFFSET)
			oc_write_u32(target, oc_layout.index_offset, stock_count);
		stock_count++;
	}
	oc_layout.runtime_count = stock_count;
	oc_layout.runtime_base_count = stock_count;
	oc_layout.runtime_added = 0;
	oc_layout.runtime_priv_count = 0;
	removed_stock_low_count = removed_count;

	for (i = 0; i < spec_count; i++) {
		struct oc_mode_spec *spec = &specs[i];
		int source_index;
		const u8 *source_record;
		void *source_priv;
		void *target_priv;
		u32 source_refresh;
		u64 source_clock;
		u64 target_clock;
		u32 target_index;
		u8 *target_record;
		u32 source_pixel = 0;

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
		target_index = oc_layout.runtime_count;
		target_record = new_modes + target_index * oc_layout.stride;
		memcpy(target_record, source_record, oc_layout.stride);
		oc_write_u32(target_record, oc_layout.width_offset, spec->width);
		oc_write_u32(target_record, oc_layout.height_offset, spec->height);
		oc_write_u32(target_record, oc_layout.refresh_offset, spec->refresh);
		oc_write_u64(target_record, oc_layout.clock_offset, target_clock);
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
		target_priv = kmemdup(source_priv, ksize(source_priv), GFP_KERNEL);
		if (!target_priv) {
			ret = -ENOMEM;
			goto fail;
		}
		oc_write_u64(target_priv, oc_layout.priv_clock_offset,
				target_clock);
		oc_write_pointer(target_record, oc_layout.priv_offset, target_priv);
		oc_layout.runtime_priv[oc_layout.runtime_priv_count++] = target_priv;
		oc_layout.runtime_specs[oc_layout.runtime_added++] = *spec;
		oc_layout.runtime_count++;
	}
	if (!oc_layout.runtime_added && !removed_stock_low_count) {
		ret = -EEXIST;
		goto fail;
	}

	oc_layout.runtime_modes = new_modes;
	mutex_lock((struct mutex *)((u8 *)oc_layout.display +
				    OC_DISPLAY_LOCK_OFFSET));
	oc_write_pointer(oc_layout.display, display_modes_offset, new_modes);
	for (i = 0; i < oc_layout.panel_count_fields; i++)
		oc_write_u32(oc_layout.panel,
				 oc_layout.panel_count_offsets[i], oc_layout.runtime_count);
	oc_layout.modes = new_modes;
	oc_layout.count = oc_layout.runtime_count;
	mode_count_after = oc_layout.runtime_count;
	injected_mode_count = oc_layout.runtime_added;
	connector_mode_count_before = oc_connector_mode_count(oc_layout.connector);
	mutex_unlock((struct mutex *)((u8 *)oc_layout.display +
				      OC_DISPLAY_LOCK_OFFSET));
	smp_wmb();
	if (!oc_verify_dynamic_modes(specs, spec_count)) {
		ret = -EIO;
		goto fail_published;
	}
	cache_applied = true;
	ret = oc_publish_drm_modes();
	if (ret)
		goto fail_published;
	if (oc_layout.connector && oc_layout.connector->dev) {
		drm_kms_helper_connector_hotplug_event(oc_layout.connector);
		drm_kms_helper_hotplug_event(oc_layout.connector->dev);
		connector_hotplug_sent = 1;
	}
	connector_mode_count_after = oc_connector_mode_count(oc_layout.connector);
	return 0;

fail_published:
	oc_restore_drm_modes();
	mutex_lock((struct mutex *)((u8 *)oc_layout.display +
				    OC_DISPLAY_LOCK_OFFSET));
	oc_write_pointer(oc_layout.display, display_modes_offset,
			 oc_layout.original_modes);
	for (i = 0; i < oc_layout.panel_count_fields; i++)
		oc_write_u32(oc_layout.panel,
				 oc_layout.panel_count_offsets[i], mode_count_before);
	oc_layout.modes = oc_layout.original_modes;
	oc_layout.count = mode_count_before;
	mutex_unlock((struct mutex *)((u8 *)oc_layout.display +
				      OC_DISPLAY_LOCK_OFFSET));
fail:
	kfree(new_modes);
	oc_layout.runtime_modes = NULL;
	oc_free_runtime_priv();
	kfree(oc_saved_modes);
	oc_saved_modes = NULL;
	oc_saved_modes_size = 0;
	removed_stock_low_count = 0;
	return ret;
}

static void oc_restore_dynamic_modes(void)
{
	unsigned int i;

	if (!oc_layout.original_modes)
		return;
	oc_restore_drm_modes();
	mutex_lock((struct mutex *)((u8 *)oc_layout.display +
				    OC_DISPLAY_LOCK_OFFSET));
	oc_write_pointer(oc_layout.display, display_modes_offset,
			 oc_layout.original_modes);
	for (i = 0; i < oc_layout.panel_count_fields; i++)
		oc_write_u32(oc_layout.panel,
				 oc_layout.panel_count_offsets[i], mode_count_before);
	oc_layout.modes = oc_layout.original_modes;
	oc_layout.count = mode_count_before;
	mutex_unlock((struct mutex *)((u8 *)oc_layout.display +
				      OC_DISPLAY_LOCK_OFFSET));
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
	oc_layout.runtime_count = 0;
	oc_layout.runtime_base_count = 0;
	oc_layout.runtime_added = 0;
	cache_applied = false;
	mode_count_after = mode_count_before;
	injected_mode_count = 0;
	removed_stock_low_count = 0;
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


static int __init plk110_display_runtime_modes_init(void)
{
	int rc;

	rc = oc_find_dt_state();
	if (rc) {
		pr_err("plk110_display_runtime_modes: DT discovery failed rc=%d source=%px targets=%u count=%u\n",
			rc, oc_dt.source_node, oc_dt.target_count, oc_dt.count);
		goto fail;
	}
	rc = oc_discover_layout();
	if (rc) {
		pr_err("plk110_display_runtime_modes: runtime layout failed rc=%d display=%px modes=%px modes_off=0x%x panel=%px\n",
			rc, oc_layout.display, oc_layout.modes,
			display_modes_offset, oc_layout.panel);
		goto fail;
	}
	pr_info("plk110_display_runtime_modes: display=%px modes=%px count=%u stride=0x%x source=%u panel=0x%x count_off=0x%x\n",
		oc_layout.display, oc_layout.modes, oc_layout.count,
		oc_layout.stride, oc_layout.source_index, display_panel_offset,
		panel_count_offset);
	if (probe_only) {
			pr_info(OC_LOG_PREFIX ": probe_only layout accepted, no memory changed\n");
		return 0;
	}
	if (!dynamic_modes) {
		rc = -EOPNOTSUPP;
		goto fail;
	}
	rc = oc_apply_dynamic_modes();
	if (rc)
		goto fail;
	applied = true;
	pr_info(OC_LOG_PREFIX ": appended %u mode(s), removed %u stock low mode(s), count %u -> %u; connector hotplug=%u; DTBO untouched\n",
		injected_mode_count, removed_stock_low_count,
		mode_count_before, mode_count_after,
		connector_hotplug_sent);
	return 0;

fail:
	failure_code = (unsigned int)(rc < 0 ? -rc : rc);
	applied = false;
	oc_restore_dynamic_modes();
	oc_release_dt();
	pr_err(OC_LOG_PREFIX ": refused to apply, error=%d\n", rc);
	return rc;
}

static void __exit plk110_display_runtime_modes_exit(void)
{
	oc_restore_dynamic_modes();
	oc_release_dt();
	applied = false;
	pr_info(OC_LOG_PREFIX ": live mode array restored; connector hotplug sent\n");
}

module_init(plk110_display_runtime_modes_init);
module_exit(plk110_display_runtime_modes_exit);

MODULE_DESCRIPTION(OC_MODULE_DESCRIPTION);
MODULE_AUTHOR("murongchaopin; based on AaTempSpoof runtime probing");
MODULE_LICENSE("GPL");
MODULE_VERSION(OC_MODULE_VERSION);
