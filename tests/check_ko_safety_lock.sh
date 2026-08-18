#!/bin/sh

set -eu

HELPER="${1:-scripts/display_backend.sh}"

[ -f "$HELPER" ] || { echo "FAIL: missing DTS helper" >&2; exit 1; }

# The selected DRM backend is a free feature and must not depend on a paid ADFR
# profile or a stale experiment token.
if grep -q 'DRM_EXPERIMENTAL_TOKEN\|I_UNDERSTAND_RMX5200_DRM_INJECTOR_RISK\|ADFR_PROFILE_FILE\|validate_rmx5200_adfr_profile' "$HELPER"; then
    echo "FAIL: free DRM-KO still depends on an experiment or paid ADFR gate" >&2
    exit 1
fi
grep -q 'DRM_PHY_PROFILE_FILE=' "$HELPER"
grep -q 'rmx5200:stock|rmx5200:v72_vendor_delta' "$HELPER"
grep -q 'error:drm_phy_profile_invalid' "$HELPER"
grep -q 'phy_profile="$DRM_PHY_PROFILE"' "$HELPER"
grep -q 'validate_rmx5200_unique_fhd_runtime' "$HELPER"
grep -q 'removed_stock_fhd_count' "$HELPER"
grep -q 'removed_stock_fhd_drm_count' "$HELPER"
grep -q 'drop_stock_fhd=1' "$HELPER"
grep -q 'applied:drm_modes_only:adfr_not_modified' "$HELPER"

# Online rmmod is unsafe for the prototype and must not be offered.
if grep -q 'rmmod "\$KO_MODULE_NAME"' "$HELPER"; then
    echo "FAIL: KO helper still unloads the experimental module online" >&2
    exit 1
fi
grep -q 'drm_remove_requires_reboot' "$HELPER"

echo "PASS: free DRM-KO is backend-selected, ADFR-independent, and not unloaded online"
