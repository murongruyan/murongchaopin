// SPDX-License-Identifier: GPL-2.0
/* Build-only provider used to let genksyms derive the exact vendor symbol CRC. */
#include <linux/module.h>
#include <msm/dsi/dsi_display.h>

struct dsi_display *get_main_display(void)
{
	return NULL;
}
EXPORT_SYMBOL(get_main_display);

MODULE_LICENSE("GPL");
