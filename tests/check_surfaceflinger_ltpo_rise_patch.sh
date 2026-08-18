#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT/scripts/surfaceflinger_ltpo_rise_patch.sh"
SOURCE="$ROOT/bin/surfaceflinger.rmx5200.ltpo-oti"
TMPDIR_TEST=$(mktemp -d)
OUTPUT="$TMPDIR_TEST/surfaceflinger.patched"
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

sh -n "$HELPER"
sh -n "$ROOT/post-fs-data.sh"
sh -n "$ROOT/service.sh"
sh -n "$ROOT/uninstall.sh"

sh "$HELPER" test-patch "$SOURCE" "$OUTPUT"
[ "$(wc -c < "$OUTPUT" | tr -d '[:space:]')" = 11416600 ]
[ "$(sha256sum "$OUTPUT" | awk '{print $1}')" = \
    c1e6eaa6c2ea3a9105252c89c033b3cdbbb703a5c669c23c2d771e18d86024b2 ]

FIRST_MTIME=$(stat -c %Y "$OUTPUT")
sh "$HELPER" test-patch "$SOURCE" "$OUTPUT"
[ "$(stat -c %Y "$OUTPUT")" = "$FIRST_MTIME" ]

DIFFS=$(cmp -l "$SOURCE" "$OUTPUT" || true)
[ "$(printf '%s\n' "$DIFFS" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 48 ]
printf '%s\n' "$DIFFS" | awk '
    function inside(position, start) {
        return position >= start + 1 && position <= start + 4
    }
    function inside_range(position, start, end) {
        return position >= start + 1 && position <= end + 4
    }
    !inside($1, 3684132) && !inside($1, 3684136) &&
    !inside_range($1, 3685848, 3685888) { bad = 1 }
    END { exit bad }
'

grep -q '^EXPECTED_SOURCE_SHA=5f0ad29412b93f523252048b1b516363743694ff60f0465dab709fcebbc200d8$' "$HELPER"
grep -q '^EXPECTED_RUNTIME_SOURCE_SHA=e6be12449b4da89c0f736784a114cc3c4946ea5db4f6f7eebaa5b8e450483abe$' "$HELPER"
grep -q '^EXPECTED_PATCHED_SHA=c1e6eaa6c2ea3a9105252c89c033b3cdbbb703a5c669c23c2d771e18d86024b2$' "$HELPER"
grep -q '^TOKEN_VALUE=I_UNDERSTAND_RMX5200_LTPO_RISE_QTI_IMMEDIATE_TEST_ONCE$' "$HELPER"
grep -q 'fallback:previous_boot_incomplete' "$HELPER"
grep -q 'sf_rise_active=1' "$ROOT/post-fs-data.sh"
grep -q '\[ "$sf_rise_active" != 1 \]' "$ROOT/post-fs-data.sh"
grep -q 'sh "$SF_RISE_HELPER" mark-boot-success' "$ROOT/service.sh"
grep -q 'umount -l "$SOURCE_FILE"' "$HELPER"
grep -q 'error:restore_validation' "$HELPER"
grep -q 'surfaceflinger_ltpo_rise_patch.sh" restore' "$ROOT/uninstall.sh"

echo 'PASS: RMX5200 SurfaceFlinger QTI immediate patch is exact and one-shot'
