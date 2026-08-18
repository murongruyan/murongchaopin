#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT/scripts/surfaceflinger_vote_patch.sh"
POST_FS="$ROOT/post-fs-data.sh"
UNINSTALL="$ROOT/uninstall.sh"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

MODEL=RMX5200
SIZE=96
ANIMATION_OFFSET=37
AP_SCALE_OFFSET=71
SOURCE="$TMPDIR_TEST/source.bin"
PATCHED_EXPECTED="$TMPDIR_TEST/patched.expected.bin"
OUTPUT="$TMPDIR_TEST/output.bin"

dd if=/dev/zero of="$SOURCE" bs=1 count="$SIZE" >/dev/null 2>&1
printf '\336\210\001\224' |
    dd of="$SOURCE" bs=1 seek="$ANIMATION_OFFSET" conv=notrunc >/dev/null 2>&1
printf '\001\003\000\124' |
    dd of="$SOURCE" bs=1 seek="$AP_SCALE_OFFSET" conv=notrunc >/dev/null 2>&1
cp "$SOURCE" "$PATCHED_EXPECTED"
printf '\037\040\003\325' |
    dd of="$PATCHED_EXPECTED" bs=1 seek="$ANIMATION_OFFSET" conv=notrunc >/dev/null 2>&1
printf '\030\000\000\024' |
    dd of="$PATCHED_EXPECTED" bs=1 seek="$AP_SCALE_OFFSET" conv=notrunc >/dev/null 2>&1
PATCHED_SHA=$(sha256sum "$PATCHED_EXPECTED" | awk '{print $1}')

sh "$HELPER" test-patch "$MODEL" "$SOURCE" "$OUTPUT" \
    "$ANIMATION_OFFSET" "$AP_SCALE_OFFSET"
[ "$(sha256sum "$OUTPUT" | awk '{print $1}')" = "$PATCHED_SHA" ]

# A valid output is accepted idempotently.
FIRST_MTIME=$(stat -c %Y "$OUTPUT")
sh "$HELPER" test-patch "$MODEL" "$SOURCE" "$OUTPUT" \
    "$ANIMATION_OFFSET" "$AP_SCALE_OFFSET"
[ "$(stat -c %Y "$OUTPUT")" = "$FIRST_MTIME" ]

# Only bytes inside the two four-byte instructions may differ. The third byte
# of the AP-scale instruction is already zero, so this fixture has seven byte
# differences even though both complete instructions are validated by hash.
DIFFS=$(cmp -l "$SOURCE" "$OUTPUT" || true)
[ "$(printf '%s\n' "$DIFFS" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 7 ]
printf '%s\n' "$DIFFS" | awk \
    -v first_start=$((ANIMATION_OFFSET + 1)) \
    -v second_start=$((AP_SCALE_OFFSET + 1)) '
    $1 < first_start || ($1 > first_start + 3 && $1 < second_start) ||
        $1 > second_start + 3 { bad = 1 }
    END { exit (bad || NR != 7) }
'

if sh "$HELPER" test-patch WRONG "$SOURCE" "$TMPDIR_TEST/wrong-model.bin" \
        "$ANIMATION_OFFSET" "$AP_SCALE_OFFSET"; then
    echo 'FAIL: wrong model was accepted' >&2
    exit 1
fi

BAD_BYTES="$TMPDIR_TEST/bad-bytes.bin"
cp "$SOURCE" "$BAD_BYTES"
printf '\000\000\000\000' |
    dd of="$BAD_BYTES" bs=1 seek="$ANIMATION_OFFSET" conv=notrunc >/dev/null 2>&1
if sh "$HELPER" test-patch "$MODEL" "$BAD_BYTES" "$TMPDIR_TEST/bad-bytes.out" \
        "$ANIMATION_OFFSET" "$AP_SCALE_OFFSET"; then
    echo 'FAIL: wrong original instruction bytes were accepted' >&2
    exit 1
fi

BAD_AP_SCALE="$TMPDIR_TEST/bad-ap-scale.bin"
cp "$SOURCE" "$BAD_AP_SCALE"
printf '\000\000\000\000' |
    dd of="$BAD_AP_SCALE" bs=1 seek="$AP_SCALE_OFFSET" conv=notrunc >/dev/null 2>&1
if sh "$HELPER" test-patch "$MODEL" "$BAD_AP_SCALE" \
        "$TMPDIR_TEST/bad-ap-scale.out" \
        "$ANIMATION_OFFSET" "$AP_SCALE_OFFSET"; then
    echo 'FAIL: wrong AP-scale instruction bytes were accepted' >&2
    exit 1
fi

if grep -Eq 'EXPECTED_(SOURCE|PATCHED)_SHA=' "$HELPER"; then
    echo 'FAIL: whole-file hash is still a runtime gate' >&2
    exit 1
fi
grep -q '^ANIMATION_PATCH_OFFSET=2776340$' "$HELPER"
grep -q '^ANIMATION_ORIGINAL_HEX=de880194$' "$HELPER"
grep -q '^AP_SCALE_PATCH_OFFSET=5229872$' "$HELPER"
grep -q '^AP_SCALE_ORIGINAL_HEX=01030054$' "$HELPER"
grep -q '^AP_SCALE_PATCHED_HEX=18000014$' "$HELPER"
grep -q 'sh "$SF_VOTE_HELPER" apply' "$POST_FS"
grep -q 'sh "$SF_VOTE_HELPER" mark-boot-success' "$ROOT/service.sh"
grep -q 'fallback:previous_boot_incomplete' "$HELPER"
grep -q 'BOOT_PENDING_FILE=' "$HELPER"
grep -q 'BOOT_BLOCK_FILE=' "$HELPER"
grep -q 'fallback:guard_blocked' "$HELPER"
grep -q 'clear-boot-guard) clear_boot_guard' "$HELPER"
grep -q 'mount -o remount,bind,suid,exec "$SOURCE_FILE"' "$HELPER"
grep -q 'umount -l "$SOURCE_FILE"' "$HELPER"
grep -q 'nosuid_transition' "$HELPER"
grep -q '\*,nosuid,\*|\*,noexec,\*' "$HELPER"
grep -q 'surfaceflinger_vote_patch.sh" restore' "$UNINSTALL"
sh -n "$HELPER"
sh -n "$POST_FS"
sh -n "$ROOT/service.sh"
sh -n "$UNINSTALL"

echo 'PASS: RMX5200 SurfaceFlinger LTPS patch checks only its two target instructions'
