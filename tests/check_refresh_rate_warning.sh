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
grep -q 'mode.fps >= 180' "$JS"
grep -q 'mode.fps >= 175' "$JS"
grep -q 'mode.fps >= 170' "$JS"
grep -q 'mode-risk' "$CSS"

# The warning is additive: the renderer must continue iterating every mode.
grep -q 'filteredModes.forEach' "$JS"
echo "PASS: high-refresh modes remain visible with tiered risk warnings"
