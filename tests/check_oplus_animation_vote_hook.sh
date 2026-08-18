#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOOK="$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/OplusServicesHooks.java"

grep -q 'com.oplus.vrr.OPlusExternalRefreshRateManager' "$HOOK"
grep -q '"addFRTCFrameRate".equals(method.getName())' "$HOOK"
grep -q 'parameters.length != 6' "$HOOK"
grep -q 'fps > 0 && isObjectAnimationVote' "$HOOK"
grep -q 'contains("object-animation")' "$HOOK"
grep -q 'return Boolean.TRUE;' "$HOOK"
grep -q 'return chain.proceed();' "$HOOK"
grep -q 'A zero-rate call removes an existing vote' "$HOOK"

echo 'PASS: Oplus object-animation FRTC insertions are suppressed and removals pass through'
