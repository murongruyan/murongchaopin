#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT/scripts/generic_adfr_policy.sh"
HANDLER="$ROOT/scripts/web_handler.sh"

grep -q 'PJD110) return 0' "$HELPER"
grep -q 'PROPERTY_VALUES=' "$HELPER"
grep -q 'persist.oplus.display.vrr.adfr=0' "$HELPER"
grep -q 'persist.oplus.display.vrr.pdfr=0' "$HELPER"
grep -q 'vendor.display.enable_dpps_dynamic_fps=0' "$HELPER"
grep -q '"$RESETPROP" -n "$name" "$target"' "$HELPER"
grep -q 'ACTIVE_FILE="$RUNTIME_DIR/active"' "$HELPER"
grep -q 'vendor_ltpo:untouched' "$HELPER"
grep -q 'restore_same_boot' "$HELPER"

PREMIUM_SERVICE="$ROOT/packaging/paid-payload/scripts/premium_service.sh"
grep -q 'GENERIC_ADFR_HELPER=' "$PREMIUM_SERVICE"
grep -q 'RMX5200|PLK110)' "$PREMIUM_SERVICE"
grep -q 'PJD110)' "$PREMIUM_SERVICE"
grep -q 'sh "$ADFR_LOCK_HELPER" apply' "$PREMIUM_SERVICE"
grep -q 'sh "$GENERIC_ADFR_HELPER" apply' "$PREMIUM_SERVICE"
grep -q 'sh "$GENERIC_ADFR_HELPER" restore' "$PREMIUM_SERVICE"
grep -q 'generic_adfr_policy.sh" restore' "$ROOT/uninstall.sh"

grep -q 'PLK110|PJD110) DISPLAY_PROFILE=vendor_ltpo' "$HANDLER"
grep -q 'PLK110:stock_ltpo|PJD110:stock_ltpo' "$HANDLER"
grep -q 'PLK110:adfr_off|PJD110:adfr_off' "$HANDLER"
grep -q 'runtime/generic_adfr/active' "$HANDLER"
grep -q '/sys/module/pjd110_adfr_lock/parameters' "$HANDLER"

sh -n "$HELPER"
sh -n "$ROOT/service.sh"
sh -n "$PREMIUM_SERVICE"
sh -n "$ROOT/uninstall.sh"

echo 'PASS: PLK110 shares the OPPO 6.12 KO and PJD110 prefers its 6.1 KO with a reboot-only fallback'
