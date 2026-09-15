#!/bin/sh

set -eu

HTML="${1:-webroot/index.html}"
JS="${2:-webroot/js/main.js}"
CSS="${3:-webroot/css/style.css}"

[ -f "$HTML" ] || { echo "FAIL: missing refresh-rate page" >&2; exit 1; }
[ -f "$JS" ] || { echo "FAIL: missing refresh-rate renderer" >&2; exit 1; }
[ -f "$CSS" ] || { echo "FAIL: missing refresh-rate styles" >&2; exit 1; }

grep -q 'refresh-risk-notice' "$HTML"
grep -q '开机第一段和第二段动画交界处' "$HTML"
grep -q 'mode-risk' "$CSS"

# Tiers are model-driven now: the renderer must read the per-model profile
# instead of the retired hardcoded GT8 Pro thresholds.
grep -q 'for (const \[threshold, level, text\] of profile.tiers)' "$JS"
grep -q 'profile.specialOc.includes(fps) || fps > profile.ocBoundary' "$JS"

# Rates above the panel's own timing table must be reported by measurement,
# not asserted by the mode write.
grep -q 'panelCeiling' "$JS"
grep -q 'panel-rate-status' "$HTML"
grep -q 'btn-probe-rate' "$JS"

# The warning is additive: the renderer must continue iterating every mode.
grep -q 'filteredModes.forEach' "$JS"
echo "PASS: high-refresh modes remain visible with tiered risk warnings"
