#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOOK_ROOT="$ROOT/src/settings_hook"
ENTRY="$HOOK_ROOT/java/com/murongchaopin/displayhook/DisplaySettingsHook.java"
BRIDGE="$HOOK_ROOT/java/com/murongchaopin/displayhook/BridgeClient.java"
SERVICES="$HOOK_ROOT/java/com/murongchaopin/displayhook/OplusServicesHooks.java"
FREE_GATE="$HOOK_ROOT/java-free/com/murongchaopin/displayhook/PremiumGateBridge.java"
FREE_META="$HOOK_ROOT/resources-free/META-INF/xposed"

test -f "$HOOK_ROOT/build.gradle.kts"
grep -q 'io.github.libxposed:api:102.0.0' "$HOOK_ROOT/build.gradle.kts"
grep -q 'java.directories.add("java-free")' "$HOOK_ROOT/build.gradle.kts"
grep -q 'res.directories.add("res-free")' "$HOOK_ROOT/build.gradle.kts"
grep -q 'extends XposedModule' "$ENTRY"
grep -q 'onPackageReady' "$ENTRY"
grep -q 'onSystemServerStarting' "$ENTRY"
grep -q 'SystemServerStartingParam' "$ENTRY"
grep -q '"system".equals(processName)' "$ENTRY"
grep -q 'SYSTEM.equals(packageName)' "$ENTRY"
grep -q 'minApiVersion=102' "$FREE_META/module.prop"
grep -q 'targetApiVersion=102' "$FREE_META/module.prop"
grep -q 'staticScope=true' "$FREE_META/module.prop"
grep -q '^system$' "$FREE_META/scope.list"
grep -q '^me.weishu.kernelsu$' "$FREE_META/scope.list"
grep -q '^com.murongchaopin.displayhook.DisplaySettingsHook$' \
    "$FREE_META/java_init.list"

if grep -qE '^(com\.android\.settings|com\.oplus\.games|com\.omarea\.vtools|com\.coloros\.video|tv\.danmaku\.bili)$' \
        "$FREE_META/scope.list"; then
    echo "FAIL: paid or stopped scope leaked into the free Hook" >&2
    exit 1
fi
if find "$HOOK_ROOT" -type f \( -name xposed_init -o -path '*/de/robv/*' \) | grep -q .; then
    echo "FAIL: legacy Xposed API files remain in the API 102 module" >&2
    exit 1
fi
if grep -R -q 'de\.robv\.android\.xposed' "$HOOK_ROOT/java" \
        "$HOOK_ROOT/java-free"; then
    echo "FAIL: API 102 hook still imports legacy Xposed APIs" >&2
    exit 1
fi

grep -q 'isVendorMemcActive' "$FREE_GATE"
if grep -qE 'isFeatureEnabled|premium_enabled|premium_features' "$FREE_GATE"; then
    echo "FAIL: signed-lease feature gate leaked into the free Hook" >&2
    exit 1
fi

grep -q 'displayRates(Context context)' "$BRIDGE"
grep -q 'LISTRATES' "$BRIDGE"
grep -q 'setGlobalRate' "$BRIDGE"
grep -q 'setGlobalResolution' "$BRIDGE"
grep -q 'setGlobalMode' "$BRIDGE"
grep -q 'setAppRate' "$BRIDGE"
grep -q 'OPlusRefreshRateService' "$SERVICES"
grep -q 'handleFrontAppChange' "$SERVICES"
grep -q 'getPreferredFrameRate' "$SERVICES"
grep -q 'setUsrOverrideRefreshRate' "$SERVICES"

# Resolution state is mode geometry/FPS state only. The bridge must not carry
# a density setting or derive one from DisplayMetrics.
grep -q 'ADOPTRES " + targetWidth + " " + sourceWidth' "$BRIDGE"
if grep -qE 'display_density_forced|sourceDensity|targetDensity|scaledDensity|wm density|persist\.sys\.display\.user_density' \
        "$BRIDGE"; then
    echo "FAIL: free resolution bridge still carries display density state" >&2
    exit 1
fi

echo "PASS: free Hook uses API 102 and mode-only display state"
