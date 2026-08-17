// SPDX-License-Identifier: GPL-2.0
/*
 * Standalone HMBIRD live device-tree injector.
 *
 * The DTBO path creates the vendor node before oplus_bsp_sched_ext starts.
 * This free module is independent of the selected display backend. It validates
 * the ROM family and SoC supplied by the early loader, verifies the requested HMBIRD type, then
 * creates the same /soc/oplus,hmbird/config_type/type tree with an OF
 * changeset. An existing DTBO node is validated and reused. The vendor
 * scheduler has no exported re-parse entry, so a node created after its init is
 * reported as parser-only and requires a reboot before the consumer can use it.
 */
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/string.h>

/* Some vendor kernels export the dynamic-OF implementation even when the
 * public config header leaves CONFIG_OF_DYNAMIC unset for external modules.
 * Weak references keep the validation-only path loadable when it is absent. */
extern void of_changeset_init(struct of_changeset *ocs) __weak;
extern void of_changeset_destroy(struct of_changeset *ocs) __weak;
extern int of_changeset_apply(struct of_changeset *ocs) __weak;
extern int of_changeset_revert(struct of_changeset *ocs) __weak;
extern struct device_node *of_changeset_create_node(struct of_changeset *ocs,
							struct device_node *parent,
							const char *full_name) __weak;
extern int of_changeset_add_prop_string(struct of_changeset *ocs,
							struct device_node *np,
							const char *prop_name,
							const char *str) __weak;

#define HB_UI_TEXT 32U
#define HB_SOC_TEXT 32U
#define HB_TYPE_TEXT 32U

static bool enable;
module_param(enable, bool, 0400);
MODULE_PARM_DESC(enable, "Enable the standalone HMBIRD live OF changeset");

static bool probe_only;
module_param(probe_only, bool, 0400);
MODULE_PARM_DESC(probe_only, "Validate ROM/SoC/node without changing the live tree");

static bool dynamic_of;
module_param(dynamic_of, bool, 0400);
MODULE_PARM_DESC(dynamic_of,
	"Loader verified that the kernel exports the dynamic OF changeset API");

static char ui_family[HB_UI_TEXT];
module_param_string(ui_family, ui_family, sizeof(ui_family), 0400);
MODULE_PARM_DESC(ui_family, "Validated UI family: coloros or realmeui");

static char soc_model[HB_SOC_TEXT];
module_param_string(soc_model, soc_model, sizeof(soc_model), 0400);
MODULE_PARM_DESC(soc_model, "Validated SoC model from ro.soc.model");

static char hmbird_type[HB_TYPE_TEXT];
module_param_string(hmbird_type, hmbird_type, sizeof(hmbird_type), 0400);
MODULE_PARM_DESC(hmbird_type, "Expected HMBIRD type: HMBIRD_EXT or HMBIRD_OGKI");

static bool ui_valid;
module_param(ui_valid, bool, 0444);
static bool soc_valid;
module_param(soc_valid, bool, 0444);
static bool type_valid;
module_param(type_valid, bool, 0444);
static bool node_present;
module_param(node_present, bool, 0444);
static bool node_created;
module_param(node_created, bool, 0444);
static bool consumer_reinit_supported;
module_param(consumer_reinit_supported, bool, 0444);
MODULE_PARM_DESC(consumer_reinit_supported,
	"False: vendor HMBIRD consumer has no exported post-init reparse hook");
static unsigned int failure_code;
module_param(failure_code, uint, 0444);
static char selected_type[HB_TYPE_TEXT];
module_param_string(selected_type, selected_type, sizeof(selected_type), 0444);

static struct of_changeset hb_changeset;
static bool hb_changeset_initialized;
static bool hb_changeset_applied;

static const char *hb_expected_type(const char *soc)
{
	if (!soc)
		return NULL;
	if (!strcmp(soc, "SM8850") || !strcmp(soc, "SM8850P") ||
	    !strcmp(soc, "SM8845"))
		return "HMBIRD_EXT";
	if (!strcmp(soc, "SM8750") || !strcmp(soc, "SM8750P") ||
	    !strcmp(soc, "SM8650") || !strcmp(soc, "SM8650P") ||
	    !strcmp(soc, "MT6991") || !strcmp(soc, "MT6993"))
		return "HMBIRD_OGKI";
	return NULL;
}

static struct device_node *hb_find_child(struct device_node *parent,
						 const char *name)
{
	struct device_node *child;

	if (!parent || !name)
		return NULL;
	for (child = parent->child; child; child = child->sibling) {
		if (child->name && !strcmp(child->name, name))
			return of_node_get(child);
	}
	return NULL;
}

static struct device_node *hb_parent(void)
{
	struct device_node *sim_detect;
	struct device_node *parent;

	/* Most Oplus trees expose the common node directly below /soc. */
	parent = of_find_node_by_path("/soc");
	if (parent)
		return parent;

	/* RMX5200's DTBO uses the sibling of oplus_sim_detect as the parent. */
	sim_detect = of_find_node_by_name(NULL, "oplus_sim_detect");
	if (!sim_detect)
		return NULL;
	parent = of_node_get(sim_detect->parent);
	of_node_put(sim_detect);
	return parent;
}

static bool hb_type_matches(struct device_node *node, const char *expected)
{
	struct device_node *config;
	const char *value;

	config = hb_find_child(node, "config_type");
	if (!config)
		return false;
	value = of_get_property(config, "type", NULL);
	if (!value || strcmp(value, expected)) {
		of_node_put(config);
		return false;
	}
	of_node_put(config);
	return true;
}

static int hb_apply_node(const char *expected)
{
	struct device_node *parent;
	struct device_node *existing;
	struct device_node *node = NULL;
	struct device_node *config = NULL;
	int ret;

	parent = hb_parent();
	if (!parent)
		return -ENOENT;
	existing = hb_find_child(parent, "oplus,hmbird");
	if (existing) {
		if (!hb_type_matches(existing, expected)) {
			of_node_put(existing);
			of_node_put(parent);
			return -EINVAL;
		}
		node_present = true;
		of_node_put(existing);
		of_node_put(parent);
		pr_info("hmbird: existing node type=%s accepted; consumer_reinit=0\n",
			expected);
		return 0;
	}
	if (probe_only) {
		of_node_put(parent);
		return -ENOENT;
	}
	if (!dynamic_of) {
		of_node_put(parent);
		return -EOPNOTSUPP;
	}

	of_changeset_init(&hb_changeset);
	hb_changeset_initialized = true;
	node = of_changeset_create_node(&hb_changeset, parent, "oplus,hmbird");
	if (!node) {
		ret = -ENOMEM;
		goto fail;
	}
	ret = of_changeset_add_prop_string(&hb_changeset, node, "name",
					   "oplus,hmbird");
	if (ret)
		goto fail;
	config = of_changeset_create_node(&hb_changeset, node, "config_type");
	if (!config) {
		ret = -ENOMEM;
		goto fail;
	}
	ret = of_changeset_add_prop_string(&hb_changeset, config, "name",
					   "config_type");
	if (ret)
		goto fail;
	ret = of_changeset_add_prop_string(&hb_changeset, config, "type", expected);
	if (ret)
		goto fail;
	ret = of_changeset_apply(&hb_changeset);
	if (ret)
		goto fail;
	hb_changeset_applied = true;
	node_present = true;
	node_created = true;
	of_node_put(node);
	of_node_put(config);
	of_node_put(parent);
	pr_warn("hmbird: created live node type=%s; vendor consumer reinit unavailable, reboot required\n",
		expected);
	return 0;

fail:
	failure_code = (unsigned int)(ret < 0 ? -ret : ret);
	if (hb_changeset_initialized) {
		if (hb_changeset_applied)
			of_changeset_revert(&hb_changeset);
		of_changeset_destroy(&hb_changeset);
		hb_changeset_initialized = false;
		hb_changeset_applied = false;
	}
	of_node_put(config);
	of_node_put(node);
	of_node_put(parent);
	return ret;
}

static void hb_restore_node(void)
{
	if (!hb_changeset_initialized)
		return;
	if (hb_changeset_applied) {
		int ret = of_changeset_revert(&hb_changeset);
		if (ret)
			pr_err("hmbird: changeset revert failed rc=%d\n", ret);
	}
	of_changeset_destroy(&hb_changeset);
	hb_changeset_initialized = false;
	hb_changeset_applied = false;
	node_present = false;
	node_created = false;
}

static int __init hmbird_init(void)
{
	const char *expected;
	int ret;

	ui_valid = !strcmp(ui_family, "coloros") || !strcmp(ui_family, "realmeui");
	expected = hb_expected_type(soc_model);
	soc_valid = expected != NULL;
	if (expected)
		strscpy(selected_type, expected, sizeof(selected_type));
	type_valid = expected && !strcmp(hmbird_type, expected);
	consumer_reinit_supported = false;
	if (!enable) {
		failure_code = EACCES;
		return -EACCES;
	}
	if (!ui_valid || !soc_valid || !type_valid) {
		failure_code = EINVAL;
		pr_err("hmbird: gate rejected ui=%s soc=%s requested_type=%s expected_type=%s\n",
		       ui_family, soc_model, hmbird_type, expected ?: "unsupported");
		return -EINVAL;
	}
	ret = hb_apply_node(expected);
	if (ret) {
		failure_code = (unsigned int)(ret < 0 ? -ret : ret);
		pr_err("hmbird: node apply rejected rc=%d type=%s probe_only=%u\n",
		       ret, expected, probe_only);
		return ret;
	}
	pr_info("hmbird: ui=%s soc=%s type=%s node_present=%u node_created=%u consumer_reinit=0\n",
		ui_family, soc_model, expected, node_present, node_created);
	return 0;
}

static void __exit hmbird_exit(void)
{
	hb_restore_node();
	pr_info("hmbird: live changeset restored\n");
}

module_init(hmbird_init);
module_exit(hmbird_exit);

MODULE_DESCRIPTION("Standalone ColorOS/Realme UI HMBIRD live OF injector");
MODULE_AUTHOR("murongchaopin prototype");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.1-hmbird-soc-gated");
