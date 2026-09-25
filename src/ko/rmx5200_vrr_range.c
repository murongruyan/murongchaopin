// SPDX-License-Identifier: GPL-2.0
/*
 * rmx5200_vrr_range - publish the internal panel's VRR frequency range.
 *
 * drm_debugfs.c's vrr_range_show() prints:
 *
 *     connector->display_info.monitor_range.min_vfreq
 *     connector->display_info.monitor_range.max_vfreq
 *
 * Those are EDID-derived, so an internal DSI panel keeps them at 0 and every
 * VRR consumer sees "no range" -> SurfaceFlinger leaves
 * idleScreenRefreshRateConfig null and the framework never asks for the low
 * tiers the panel already supports.
 *
 * Offsets (device BTF, not guessed):
 *     drm_connector.display_info          @ 0x0d8
 *     drm_display_info.monitor_range      @ 0x09a
 *     drm_monitor_range_info.min_vfreq    @ 0x000  (u16, Hz)
 *     drm_monitor_range_info.max_vfreq    @ 0x002  (u16, Hz)
 *  => connector + 0x172 / connector + 0x174
 *
 * Timing
 * ------
 * A one-shot write from module_init does not survive: the panel driver
 * re-populates display_info while the connector is probed, which wiped the
 * value written from post-fs-data.  So the range is (re)applied from a
 * kretprobe on sde_connector_fill_modes() - i.e. after every probe / hotplug -
 * and only when the field still reads zero, so we never fight the driver.
 *
 * Safety
 * ------
 * Defaults to probe-only.  Writing requires apply=1.
 */

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/workqueue.h>
#include <drm/drm_connector.h>
#include <drm/drm_property.h>

extern void *get_main_display(void);
/* Exported by the DRM core; msm_drm never attaches these itself. */
extern int drm_connector_attach_vrr_capable_property(struct drm_connector *connector);
extern void drm_connector_set_vrr_capable_property(struct drm_connector *connector, bool capable);

#define VRR_DSI_DISPLAY_CONNECTOR_OFFSET 0x10U
#define VRR_CONNECTOR_MONITOR_RANGE_OFFSET 0x172U
#define VRR_TAG "rmx5200_vrr_range"

static unsigned int apply;
module_param(apply, uint, 0644);
MODULE_PARM_DESC(apply, "0 = probe only; 1 = publish the range");

static unsigned int min_vfreq = 1;
module_param(min_vfreq, uint, 0644);
MODULE_PARM_DESC(min_vfreq, "minimum vertical refresh rate (Hz)");

static unsigned int max_vfreq = 144;
module_param(max_vfreq, uint, 0644);
MODULE_PARM_DESC(max_vfreq, "maximum vertical refresh rate (Hz)");

static unsigned int applied;
module_param(applied, uint, 0444);
MODULE_PARM_DESC(applied, "number of times the range was written");

static unsigned int vrr_capable_set;
module_param(vrr_capable_set, uint, 0444);
MODULE_PARM_DESC(vrr_capable_set, "times the vrr_capable property was attached/set");

static unsigned int observed;
module_param(observed, uint, 0444);
MODULE_PARM_DESC(observed, "number of connector fills observed");

static struct drm_connector *main_connector;

static u16 vrr_read_u16(const void *base, unsigned int off)
{
	return *(const u16 *)((const char *)base + off);
}

static void vrr_apply(struct drm_connector *connector, const char *when)
{
	u16 lo, hi;

	if (!connector || !apply)
		return;
	if (connector->status != connector_status_connected)
		return;

	lo = vrr_read_u16(connector, VRR_CONNECTOR_MONITOR_RANGE_OFFSET);
	hi = vrr_read_u16(connector, VRR_CONNECTOR_MONITOR_RANGE_OFFSET + 2);
	if (lo == (u16)min_vfreq && hi == (u16)max_vfreq)
		return;

	*(u16 *)((char *)connector + VRR_CONNECTOR_MONITOR_RANGE_OFFSET) = (u16)min_vfreq;
	*(u16 *)((char *)connector + VRR_CONNECTOR_MONITOR_RANGE_OFFSET + 2) = (u16)max_vfreq;

	applied++;

	pr_info(VRR_TAG " %s: %s min_vfreq=%u max_vfreq=%u (was %u/%u) write#%u\n",
		when, connector->name ? connector->name : "?", min_vfreq, max_vfreq,
		lo, hi, applied);
}

/*
 * drm_connector_attach_vrr_capable_property() allocates a property and takes
 * DRM locks, so it must never run from a kretprobe handler: that context has
 * preemption disabled and is reached through a debug exception, which is why
 * an earlier revision produced drm_mode_object_add warnings.  Only the two
 * plain u16 stores are safe there; everything else is deferred to a work item.
 */
static struct work_struct vrr_capable_work;

static void vrr_capable_work_fn(struct work_struct *work)
{
	if (!main_connector)
		return;
	if (drm_connector_attach_vrr_capable_property(main_connector) != 0)
		return;
	drm_connector_set_vrr_capable_property(main_connector, true);
	vrr_capable_set++;
	pr_info(VRR_TAG ": vrr_capable attached+set in process context (#%u)\n",
		vrr_capable_set);
}

static int __kprobes vrr_fill_entry(struct kretprobe_instance *ri,
				    struct pt_regs *regs)
{
	void *connector = (void *)regs->regs[0];

	observed++;
	memcpy(ri->data, &connector, sizeof(connector));
	return 0;
}

static int __kprobes vrr_fill_return(struct kretprobe_instance *ri,
				     struct pt_regs *regs)
{
	struct drm_connector *connector = NULL;

	memcpy(&connector, ri->data, sizeof(connector));
	vrr_apply(connector, "fill_modes");
	return 0;
}

static struct kretprobe vrr_fill_probe = {
	.kp.symbol_name = "sde_connector_fill_modes",
	.entry_handler = vrr_fill_entry,
	.handler = vrr_fill_return,
	.data_size = sizeof(void *),
	.maxactive = 8,
};

static int __init rmx5200_vrr_range_init(void)
{
	void *display;
	int rc;

	pr_info(VRR_TAG ": apply=%u range=%u..%u\n", apply, min_vfreq, max_vfreq);

	display = get_main_display();
	if (display) {
		main_connector = *(void **)((char *)display +
					    VRR_DSI_DISPLAY_CONNECTOR_OFFSET);
	}
	if (main_connector)
		vrr_apply(main_connector, "init");

	if (apply && main_connector) {
		INIT_WORK(&vrr_capable_work, vrr_capable_work_fn);
		schedule_work(&vrr_capable_work);
	}

	rc = register_kretprobe(&vrr_fill_probe);
	if (rc) {
		pr_err(VRR_TAG ": register_kretprobe(%s) failed: %d\n",
		       vrr_fill_probe.kp.symbol_name, rc);
		return rc;
	}

	pr_info(VRR_TAG ": kretprobe armed on %s\n", vrr_fill_probe.kp.symbol_name);
	return 0;
}

static void __exit rmx5200_vrr_range_exit(void)
{
	unregister_kretprobe(&vrr_fill_probe);
	pr_info(VRR_TAG ": unloaded (observed=%u applied=%u)\n", observed, applied);
}

module_init(rmx5200_vrr_range_init);
module_exit(rmx5200_vrr_range_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Publish the internal DSI panel VRR range via drm_connector monitor_range");
MODULE_VERSION("0.2");