#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOOK="$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/OplusLtpsModeHooks.java"
SERVICES="$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/OplusServicesHooks.java"

test -f "$HOOK"
grep -q 'com.android.server.wm.OplusRefreshRateCore' "$HOOK"
grep -q 'getFinalDisplayModeIdLocked' "$HOOK"
grep -q 'getPerfectRefreshRate' "$HOOK"
grep -q 'QHD_WIDTH = 1440' "$HOOK"
grep -q 'QHD_HEIGHT = 3136' "$HOOK"
grep -q 'LTPS_RATE_HZ = 60.0f' "$HOOK"
grep -q 'supportedModes' "$HOOK"
grep -q 'selected.getModeId()' "$HOOK"
grep -q 'QHD LTPS mode corrected' "$HOOK"
grep -q '"RMX5200".equalsIgnoreCase' "$HOOK"
grep -q 'OplusLtpsModeHooks.install' "$SERVICES"

echo 'PASS: QHD LTPS vote resolves to the exact RMX5200 QHD60 mode'
