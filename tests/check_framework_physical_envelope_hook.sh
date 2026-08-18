#!/system/bin/sh
set -eu

root_dir="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
hook="$root_dir/src/settings_hook/java/com/murongchaopin/displayhook/FrameworkPhysicalEnvelopeHooks.java"
services="$root_dir/src/settings_hook/java/com/murongchaopin/displayhook/OplusServicesHooks.java"

test -f "$hook"
grep -q 'getDesiredDisplayModeSpecs' "$hook"
grep -q 'PRIORITY_USER_SETTING_DISPLAY_PREFERRED_SIZE' "$hook"
grep -q 'mAppSupportedModesByDisplay' "$hook"
grep -q 'Math.abs(base.getRefreshRate() - ENVELOPE_RATE_HZ)' "$hook"
grep -q 'setPhysicalRange(specs, "primary"' "$hook"
grep -q 'setPhysicalRange(specs, "appRequest"' "$hook"
grep -q 'Reflect.setField(specs, "baseModeId"' "$hook"
grep -q 'boolean extended = usesExtendedFhdGroup(mode)' "$hook"
grep -q 'extended && !selectedExtended' "$hook"
grep -q 'mode.getAlternativeRefreshRates()' "$hook"
grep -q 'rate > 144.0f + RATE_EPSILON_HZ' "$hook"
grep -q 'debug.tracing.screen_state' "$hook"
grep -q 'isScreenOn()' "$hook"
grep -q 'FrameworkPhysicalEnvelopeHooks.install' "$services"

if grep -qE 'PowerManager|isInteractive|getSystemContext|getSystemService' "$hook"; then
    echo 'FAIL: display lock callback may re-enter PowerManager or another service' >&2
    exit 1
fi

if grep -q 'Reflect.setField(.*"render"' "$hook"; then
    echo 'FAIL: physical envelope hook must not clamp the render range' >&2
    exit 1
fi

if grep -q 'base.getRefreshRate() > ENVELOPE_RATE_HZ' "$hook"; then
    echo 'FAIL: physical envelope still replaces native low-rate LTPS modes' >&2
    exit 1
fi

echo 'framework physical envelope hook: OK'
