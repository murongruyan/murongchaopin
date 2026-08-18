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
[ "$(mode_manifest_specs PLK110 dtbo)" = \
  '1272x2772@123;1272x2772@170;1272x2772@175;1272x2772@180;1272x2772@185;1272x2772@190;1272x2772@195;1272x2772@199' ]
[ "$(mode_manifest_specs PLK110 drm)" = \
  '1272x2772@170;1272x2772@175;1272x2772@180;1272x2772@185;1272x2772@190;1272x2772@195;1272x2772@199' ]

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
