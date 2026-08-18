#!/bin/sh

# Kept under the historical filename because CI and downstream packagers call
# it directly. The Web policy and boot policy must share one persisted state.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NODE=${NODE:-node}

grep -q 'process_dts --rmx5200-drop-stock-fhd' "$ROOT/customize.sh"
grep -q './process_dts --rmx5200-drop-stock-fhd' "$ROOT/scripts/web_handler.sh"

grep -q 'id="policy-card"' "$ROOT/webroot/index.html"
grep -q 'id="btn-policy-stock"' "$ROOT/webroot/index.html"
grep -q 'id="btn-policy-custom"' "$ROOT/webroot/index.html"
grep -q 'id="btn-policy-adfr"' "$ROOT/webroot/index.html"
grep -q 'loadAdfrPolicy' "$ROOT/webroot/js/main.js"
grep -q "displayPolicyProfile === 'rmx5200' ? 'stock_ltps' : 'stock_ltpo'" "$ROOT/webroot/js/main.js"
grep -q "setDisplayPolicy('custom_ltpo')" "$ROOT/webroot/js/main.js"
grep -q "setDisplayPolicy('adfr_off')" "$ROOT/webroot/js/main.js"
grep -q 'get_display_policy' "$ROOT/webroot/js/main.js"
grep -q 'set_display_policy' "$ROOT/webroot/js/main.js"
grep -q "\['stock_ltpo', 'adfr_off'\]" "$ROOT/webroot/js/main.js"
grep -q "stock_ltpo: '原厂 LTPO'" "$ROOT/webroot/js/main.js"
grep -q "customButton.hidden = !isRmx5200" "$ROOT/webroot/js/main.js"
grep -q '重启设备后生效' "$ROOT/webroot/js/main.js"
grep -q 'ADFR_POLICY_FILE=' "$ROOT/scripts/web_handler.sh"
grep -q 'DISPLAY_POLICY_FILE=' "$ROOT/scripts/web_handler.sh"
grep -q 'read_adfr_policy()' "$ROOT/scripts/web_handler.sh"
grep -q 'write_adfr_policy()' "$ROOT/scripts/web_handler.sh"
grep -q 'read_display_policy()' "$ROOT/scripts/web_handler.sh"
grep -q 'write_display_policy()' "$ROOT/scripts/web_handler.sh"
grep -q '"get_display_policy")' "$ROOT/scripts/web_handler.sh"
grep -q '"set_display_policy")' "$ROOT/scripts/web_handler.sh"
grep -q 'PLK110|PJD110) DISPLAY_PROFILE=vendor_ltpo' "$ROOT/scripts/web_handler.sh"
grep -q '"get_adfr_policy")' "$ROOT/scripts/web_handler.sh"
grep -q '"toggle_adfr")' "$ROOT/scripts/web_handler.sh"
grep -q 'sh "$ADFR_LOCK_HELPER" apply' "$ROOT/scripts/web_handler.sh"
grep -q 'rm -f "$ADFR_TEST_BYPASS_FILE"' "$ROOT/scripts/web_handler.sh"
grep -q '^on$' "$ROOT/config/rmx5200_adfr_mode.txt"
grep -q '^stock_ltps$' "$ROOT/config/rmx5200_display_policy.txt"

SET_POLICY=$(sed -n '/    "set_display_policy")/,/    "get_adfr_policy")/p' \
    "$ROOT/scripts/web_handler.sh")
printf '%s\n' "$SET_POLICY" | grep -q 'reboot required'
if printf '%s\n' "$SET_POLICY" | grep -Eq \
        'ADFR_LOCK_HELPER.*apply|insmod|^[[:space:]]*reboot([[:space:]]|$)'; then
    echo 'FAIL: Web policy selection applies live state instead of waiting for reboot' >&2
    exit 1
fi

grep -q 'PREMIUM_POST_FS' "$ROOT/post-fs-data.sh"
grep -q 'sh "$ADFR_LOCK_HELPER" load' \
    "$ROOT/packaging/paid-payload/scripts/premium_post_fs_data.sh"
grep -q 'sh "$ADFR_LOCK_HELPER" apply' \
    "$ROOT/packaging/paid-payload/scripts/premium_service.sh"

sh -n "$ROOT/customize.sh"
sh -n "$ROOT/scripts/web_handler.sh"
if command -v "$NODE" >/dev/null 2>&1; then
    "$NODE" --check "$ROOT/webroot/js/main.js"
fi

echo 'PASS: Web exposes the RMX5200 three-way and vendor-LTPO two-way reboot policies'
