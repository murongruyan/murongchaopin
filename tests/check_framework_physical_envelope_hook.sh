#!/system/bin/sh
set -eu

root_dir="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
hook="$root_dir/src/settings_hook/java/com/murongchaopin/displayhook/FrameworkPhysicalEnvelopeHooks.java"
services="$root_dir/src/settings_hook/java/com/murongchaopin/displayhook/OplusServicesHooks.java"

test -f "$hook"
grep -q 'getDesiredDisplayModeSpecs' "$hook"
# The selected geometry comes from the module's own mode.txt, and the vote
# priority name is looked up tolerantly because ColorOS 17 renamed it.
grep -q 'FrameworkResolutionVoteHooks.selectedDisplayTarget()' "$hook"
grep -q 'optionalUserSizePriority(voteClass)' "$hook"
grep -q 'mAppSupportedModesByDisplay' "$hook"
# The hook may only repoint baseModeId at a mode that already carries the
# selected geometry at the base refresh rate.  It must not force a rate and must
# not touch the render or physical ranges.
grep -q 'Reflect.setField(specs, "baseModeId"' "$hook"
grep -q 'findMode(modes, preferred, base.getRefreshRate())' "$hook"
# 1080p exists twice on ColorOS 17 (the plain and the extended FHD group), so
# the choice has to be deterministic or the panel flips between groups.
grep -q 'boolean extended = usesExtendedFhdGroup(mode)' "$hook"
grep -q 'extended && !selectedExtended' "$hook"
grep -q 'mode.getAlternativeRefreshRates()' "$hook"
grep -q 'debug.tracing.screen_state' "$hook"
grep -q 'isScreenOn()' "$hook"
grep -q 'FrameworkPhysicalEnvelopeHooks.install' "$services"

if grep -qE 'PowerManager|isInteractive|getSystemContext|getSystemService' "$hook"; then
    echo 'FAIL: display lock callback may re-enter PowerManager or another service' >&2
    exit 1
fi

if grep -qE 'setPhysicalRange|ENVELOPE_RATE_HZ' "$hook"; then
    echo 'FAIL: physical envelope must not pin a refresh rate' >&2
    exit 1
fi

if grep -q 'Reflect.setField(.*"render"' "$hook"; then
    echo 'FAIL: physical envelope hook must not clamp the render range' >&2
    exit 1
fi

echo 'framework physical envelope hook: OK'