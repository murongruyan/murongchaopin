#!/bin/sh

set -eu

CUSTOMIZE="${1:-customize.sh}"
[ -f "$CUSTOMIZE" ] || { echo "FAIL: missing customize script" >&2; exit 1; }

SH_BIN="${SH_BIN:-sh}"
"$SH_BIN" -n "$CUSTOMIZE"

# User-owned state that must survive a software-only module update.
for path in \
  'config/mode.txt' \
  'config/custom_refresh_rates.txt' \
  'config/game_assistant_apps.txt' \
  'config/video_memc_apps.txt' \
  'config/drm_phy_profile.txt' \
  'config/rmx5200_adfr_mode.txt' \
  'config/rmx5200_display_policy.txt' \
  'config/dts_backend.txt' \
  'config/adfr_lock' \
  'config/surfaceflinger_ltps_vote_patch' \
  'config/auth/account.json' \
  'config/auth/lease.json' \
  'config/auth/package.json' \
  'config/auth/state.json' \
  'config/auth/device_id.txt' \
  'config/install_system_fingerprint.txt' \
  'runtime/drm_modes.txt' \
  'img/dtbo.img' \
  'img/dtbo.img.sha256' \
  'img/dtbo.img.gz' \
  'img/dtbo.applied.sha256'; do
  grep -q "$path" "$CUSTOMIZE" || {
    echo "FAIL: update migration is missing $path" >&2
    exit 1
  }
done

grep -q 'MODULE_UPDATE=0' "$CUSTOMIZE"
grep -q 'MURONGCHAOPIN_UPDATE_BACKEND' "$CUSTOMIZE"
grep -q 'CURRENT_SYSTEM_FINGERPRINT' "$CUSTOMIZE"
grep -q 'PREVIOUS_SYSTEM_FINGERPRINT' "$CUSTOMIZE"
grep -q 'SYSTEM_VERSION_CHANGED=1' "$CUSTOMIZE"
grep -q 'DTBO_ROUTE="module_update"' "$CUSTOMIZE"
grep -q 'DTBO_ROUTE="applied_force"' "$CUSTOMIZE"
grep -q 'DTBO_ROUTE="stock"' "$CUSTOMIZE"
grep -q 'DTBO_ROUTE="first_stock"' "$CUSTOMIZE"
grep -q 'DTBO_ROUTE="stock_changed"' "$CUSTOMIZE"
grep -q 'DTBO_ROUTE="foreign"' "$CUSTOMIZE"
grep -q 'SKIP_DISPLAY_BACKEND=1' "$CUSTOMIZE"
grep -q 'recover_legacy_applied_manifest' "$CUSTOMIZE"
grep -q 'workspace/"\*-final.img' "$CUSTOMIZE"
grep -q 'raw new_dtbo.img intermediate' "$CUSTOMIZE"
grep -q 'dtbo_write_device_manifest' "$CUSTOMIZE"
grep -q 'dtbo_write_device_manifest' scripts/dtbo_avb.sh
grep -q 'dtbo_write_device_manifest' scripts/hmbird_backend.sh
grep -q 'dtbo_write_device_manifest' scripts/web_handler.sh
grep -q 'dtbo_clear_device_manifest' scripts/web_handler.sh
grep -q 'dtbo_write_device_manifest "\$DTBO_PARTITION" "\$PARTITION_SIZE"' \
  scripts/web_handler.sh
if grep -q 'dtbo_write_device_manifest "\$DTBO_PARTITION" "\$SIZE"' \
  scripts/web_handler.sh; then
  echo "FAIL: WebUI records the generated image size instead of partition size" >&2
  exit 1
fi
grep -q 'dtbo_verify_official_image "\$CURRENT_DTBO"' "$CUSTOMIZE"
if grep -q 'PERSISTENT_STATE_DIR\|murongchaopin-state' "$CUSTOMIZE"; then
  echo "FAIL: update detection must not depend on an external module state directory" >&2
  exit 1
fi

SYSTEM_VERSION_BODY=$(sed -n '/^SYSTEM_VERSION_CHANGED=0$/,/^fi$/p' "$CUSTOMIZE")
if printf '%s\n' "$SYSTEM_VERSION_BODY" | grep -q 'MODULE_UPDATE'; then
  echo "FAIL: system version detection is incorrectly tied to module update path" >&2
  exit 1
fi

# The install-time DTBO write is guarded by the route switch. The update and
# unknown-DTBO branches must remain software-only.
[ "$(grep -c 'dtbo_write_partition' "$CUSTOMIZE")" = 1 ] || {
  echo "FAIL: customize.sh has more than one install-time DTBO write" >&2
  exit 1
}
grep -q '^case "\$DTBO_ROUTE" in$' "$CUSTOMIZE"
grep -q '^  module_update)$' "$CUSTOMIZE"
grep -q '^  foreign|unavailable)$' "$CUSTOMIZE"
grep -q 'if \[ "\$SKIP_DISPLAY_BACKEND" = 0 \]; then' "$CUSTOMIZE"
grep -q 'DTBO_PARTITION_IMAGE_SIZE=.*blockdev --getsize64' "$CUSTOMIZE"
if grep -q 'REBUILD_DISPLAY_BACKEND\|SYSTEM_UPDATE\|MODULE_REINSTALL' "$CUSTOMIZE"; then
  echo "FAIL: stale update-routing variables remain in customize.sh" >&2
  exit 1
fi

grep -q '\[ ! -f "\$STOCK_DTBO" \] || set_perm' "$CUSTOMIZE"
echo "PASS: module updates preserve user state and route by DTBO hash"
