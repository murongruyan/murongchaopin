#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE_MANIFEST_FILE="$ROOT/config/display_mode_manifest.txt"
MOD_DIR="$ROOT"
. "$ROOT/scripts/mode_manifest.sh"

mode_manifest_validate

[ "$(mode_manifest_specs RMX5200 dtbo)" = \
  '1440x3136@123;1440x3136@150;1440x3136@155;1440x3136@160;1440x3136@165;1440x3136@170;1440x3136@175;1440x3136@180' ]
[ "$(mode_manifest_specs RMX5200 drm)" = \
  '1440x3136@123;1440x3136@150;1440x3136@155;1440x3136@160;1440x3136@165;1440x3136@170;1440x3136@175;1440x3136@180' ]

# PLK110's overclock list is deliberately NOT pinned to a literal here. The list
# is being walked down under real-device test (the 123/170-199 set locked up a
# PLK110/C17 boot), and a hard-coded copy would turn every step of that reduction
# into a test edit - which is exactly how the earlier extremeHighEnable mistake
# happened: the assertion was relaxed while the runtime gate was left in place.
# What is worth asserting is the shape, not the digits.
PLK_DTBO_RATES=$(mode_manifest_rates PLK110 dtbo)
PLK_DRM_RATES=$(mode_manifest_rates PLK110 drm)
PLK_DTBO_SPECS=$(mode_manifest_specs PLK110 dtbo)
# The rate lists are comma separated, so they have to be split before the loop:
# a shell `for` splits on whitespace only, and iterating "123,170,175" as one
# word is what made the first version of this check report every list as
# containing a non-numeric entry.
for rate in $(printf '%s\n' "$PLK_DTBO_RATES" | tr ',' ' ') \
            $(printf '%s\n' "$PLK_DRM_RATES" | tr ',' ' '); do
    case "$rate" in
        ''|*[!0-9]*) echo "FAIL: PLK110 rate list has a non-numeric entry: '$rate'" >&2; exit 1 ;;
    esac
    # 123 is the one legitimate entry below the stock ceiling: it takes over the
    # vendor 120Hz slot (the panel's own 123Hz mode), and it is what makes the
    # global list unable to fall back to 120. Every other rate must sit above
    # 165, because a rate that collides with a stock timing either duplicates a
    # node or silently changes what the stock refresh ladder means.
    [ "$rate" = 123 ] && continue
    [ "$rate" -ge 60 ] && [ "$rate" -le 165 ] && {
        echo "FAIL: PLK110 carries a rate at or below the stock 165Hz ceiling: $rate" >&2; exit 1; }
done
# The two backends describe the same panel capability, and the DTBO list is the
# superset: it carries 123, which exists only as a replacement for the stock
# 120Hz node and has no meaning to the DRM backend (that one injects live modes
# and never deletes a vendor timing). So every DRM rate must appear in the DTBO
# list; the reverse does not hold.
#
# The comparison splits the list and uses grep -qxF rather than a case pattern:
# the lists are comma separated, so a ";$rate;" style pattern can never match,
# and a substring test would accept 70 as a member of a list holding 170.
for rate in $(printf '%s\n' "$PLK_DRM_RATES" | tr ',' ' '); do
    printf '%s\n' "$PLK_DTBO_RATES" | tr ',' '\n' | grep -qxF "$rate" || {
        echo "FAIL: PLK110 DRM rate $rate is missing from the DTBO list" >&2; exit 1; }
done
# When the list is non-empty, the DTBO specs must carry the same rate count.
if [ -n "$PLK_DTBO_RATES" ]; then
    specs_count=$(printf '%s' "$PLK_DTBO_SPECS" | tr ';' '\n' | grep -c . || true)
    rates_count=$(printf '%s' "$PLK_DTBO_RATES" | tr ',' '\n' | grep -c . || true)
    [ "$specs_count" = "$rates_count" ] || {
        echo "FAIL: PLK110 DTBO specs=$specs_count but rates=$rates_count" >&2; exit 1; }
    case "$PLK_DTBO_SPECS" in
        *'1272x2772@'*) ;;
        *) echo "FAIL: PLK110 DTBO specs lost the 1272x2772 geometry" >&2; exit 1 ;;
    esac
fi

[ "$(mode_manifest_rates PJD110 dtbo)" = "" ]
[ "$(mode_manifest_rates PJD110 drm)" = "" ]
[ "$(mode_manifest_resolution PJD110)" = "1440x3168" ]
if mode_manifest_specs PJD110 dtbo >/dev/null 2>&1; then
    echo "FAIL: PJD110 received invented default overclock rates" >&2
    exit 1
fi
[ "$(mode_manifest_value rmx5200_hmbird_dtbo)" = 1 ]
[ "$(mode_manifest_value hmbird_ko_free)" = 0 ]
[ "$(mode_manifest_value hmbird_ko_backends)" = dtbo ]
[ "$(mode_manifest_value pjd110_hmbird_dtbo)" = 1 ]
[ "$(mode_manifest_value pjd110_capacity_unlock_dtbo)" = 1 ]

# HMBIRD is a DTBO-only text-node patch. The retired live-OF sidecar must not
# be part of the current backend contract.
grep -q 'oplus,hmbird' "$ROOT/src/process_dts.c"
grep -q 'disabled:dtbo_only' "$ROOT/scripts/hmbird_backend.sh"
! grep -q 'insmod.*hmbird' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'MODEL_PJD110' "$ROOT/src/process_dts.c"
grep -q 'panel_id == 3' "$ROOT/src/process_dts.c"

echo "PASS: shared manifest keeps RMX5200/PLK110 explicit and PJD110 custom-rate-only"
