// SPDX-License-Identifier: GPL-2.0
/*
 * rmx5200_vrr_range - expose the internal panel's VRR frequency range.
 *
 * Why this exists
 * ---------------
 * drm_debugfs.c's vrr_range_show() prints:
 *
 *     connector->display_info.monitor_range.min_vfreq
 *     connector->display_info.monitor_range.max_vfreq
 *
 * Those come from the EDID monitor-range descriptor.  An internal DSI panel has
 * no EDID, so both stay 0 and every consumer of the VRR range (the vendor HWC,
 * and therefore SurfaceFlinger's DisplayModeSpecs) sees "no VRR range".  The
 * result is that idleScreenRefreshRateConfig is never populated and the
 * framework never asks for the low tiers the panel already supports.
 *
 * Offsets were read from the device's own BTF (device_vmlinux.btf), not
 * guessed:
 *
 *     struct drm_connector        display_info   @ 0x0d8
 *     struct drm_display_info     monitor_range  @ 0x09a   (size 4)
 *     struct drm_monitor_range_info min_vfreq     @ 0x00  (u16, Hz)
 *                                   max_vfreq     @ 0x02  (u16, Hz)
 *
 *     => connector + 0x172 = min_vfreq
 *        connector + 0x174 = max_vfreq
 *
 * Safety
 * ------
 * The module defaults to probe-only: it reads and reports, and writes nothing.
 * Writing requires an explicit apply=1 at insmod time.
 */

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/types.h>
#include <linux/string.h>
#include <linux/delay.h>
#include <drm/drm_connector.h>

/* Exported by the OnePlus/Realme msm_drm module. */
extern void *get_main_display(void);

/* offsetof(struct dsi_display, drm_conn) on this ABI, same constant the
 * rmx5200_drm_modes module already uses for the same object. */
#define VRR_DSI_DISPLAY_CONNECTOR_OFFSET 0x10U

/* connector -> display_info.monitor_range.{min,max}_vfreq (see header comment) */
#define VRR_CONNECTOR_MONITOR_RANGE_OFFSET 0x172U

#define VRR_TAG "rmx5200_vrr_range"

static unsigned int apply;
module_param(apply, uint, 0644);
MODULE_PARM_DESC(apply, "0 = probe only (read + report, no writes); 1 = write the range");

static unsigned int min_vfreq = 1;
module_param(min_vfreq, uint, 0644);
MODULE_PARM_DESC(min_vfreq, "minimum vertical refresh rate in Hz to publish");

static unsigned int max_vfreq = 144;
module_param(max_vfreq, uint, 0644);
MODULE_PARM_DESC(max_vfreq, "maximum vertical refresh rate in Hz to publish");

static struct drm_connector *target_connector;

static u16 vrr_read_u16(const void *base, unsigned int offset)
{
	return *(const u16 *)((const char *)base + offset);
}

static void vrr_write_u16(void *base, unsigned int offset, u16 value)
{
	*(u16 *)((char *)base + offset) = value;
}

static struct drm_connector *vrr_resolve_connector(void)
{
	void *display;
	void *connector;

	display = get_main_display();
	if (!display) {
		pr_err(VRR_TAG ": get_main_display() returned NULL\n");
		return NULL;
	}

	connector = *(void **)((char *)display + VRR_DSI_DISPLAY_CONNECTOR_OFFSET);
	if (!connector) {
		pr_err(VRR_TAG ": dsi_display+0x%x drm_conn is NULL\n",
		       VRR_DSI_DISPLAY_CONNECTOR_OFFSET);
		return NULL;
	}

	return connector;
}

static void vrr_report(struct drm_connector *connector, const char *when)
{
	u16 lo = vrr_read_u16(connector, VRR_CONNECTOR_MONITOR_RANGE_OFFSET + 0);
	u16 hi = vrr_read_u16(connector, VRR_CONNECTOR_MONITOR_RANGE_OFFSET + 2);

	pr_info(VRR_TAG " %s: connector=%s status=%d monitor_range min_vfreq=%u max_vfreq=%u\n",
		when,
		connector->name ? connector->name : "(unnamed)",
		connector->status, lo, hi);
}

static int __init rmx5200_vrr_range_init(void)
{
	struct drm_connector *connector;

	connector = vrr_resolve_connector();
	if (!connector)
		return -ENODEV;

	target_connector = connector;
	vrr_report(connector, "probe");

	if (!apply) {
		pr_info(VRR_TAG ": probe-only, no write (insmod apply=1 to publish the range)\n");
		return 0;
	}

	if (min_vfreq > max_vfreq || max_vfreq > 1000) {
		pr_err(VRR_TAG ": refusing invalid range %u..%u\n", min_vfreq, max_vfreq);
		return -EINVAL;
	}

	{
		u16 before_lo = vrr_read_u16(connector, VRR_CONNECTOR_MONITOR_RANGE_OFFSET);
		u16 before_hi = vrr_read_u16(connector, VRR_CONNECTOR_MONITOR_RANGE_OFFSET + 2);

		vrr_write_u16(connector, VRR_CONNECTOR_MONITOR_RANGE_OFFSET,
			      (u16)min_vfreq);
		vrr_write_u16(connector, VRR_CONNECTOR_MONITOR_RANGE_OFFSET + 2,
			      (u16)max_vfreq);

		pr_info(VRR_TAG ": wrote %u..%u Hz (was %u..%u)\n",
			min_vfreq, max_vfreq, before_lo, before_hi);
	}

	vrr_report(connector, "after-write");
	return 0;
}

static void __exit rmx5200_vrr_range_exit(void)
{
	if (target_connector)
		vrr_report(target_connector, "unload");
	pr_info(VRR_TAG ": unloaded\n");
}

module_init(rmx5200_vrr_range_init);
module_exit(rmx5200_vrr_range_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Publish the internal DSI panel VRR range through drm_connector monitor_range");
MODULE_VERSION("0.1");