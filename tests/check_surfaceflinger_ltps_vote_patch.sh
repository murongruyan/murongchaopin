#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT/scripts/surfaceflinger_ltps_vote_patch.sh"
ASM="$ROOT/src/surfaceflinger/rmx5200_stock_ltps_vote_filter.S"
POST_FS="$ROOT/post-fs-data.sh"
SERVICE="$ROOT/service.sh"
UNINSTALL="$ROOT/uninstall.sh"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

MODEL=RMX5200
POLICY=stock_ltps
VOTE_OFFSET=5220408
VOTE_SIZE=152
LEGACY_OFFSET=2776340
AP_SCALE_OFFSET=5229872
SIZE=5230000
SOURCE="$TMPDIR_TEST/source.bin"
OUTPUT="$TMPDIR_TEST/output.bin"
RESTORED="$TMPDIR_TEST/restored.bin"

VOTE_ORIGINAL_OCTAL='\0100\0000\0200\0122\0173\0273\0023\0224\0040\0003\0000\0066\0210\0002\0100\0071\0211\0012\0100\0371\0340\0333\0377\0260\0000\0040\0004\0221\0342\0003\0026\0052\0270\0003\0001\0321\0037\0001\0000\0162\0250\0003\0001\0321\0041\0025\0224\0232\0340\0272\0023\0224\0250\0003\0134\0070\0251\0003\0135\0370\0100\0000\0200\0122\0037\0001\0000\0162\0041\0025\0230\0232\0304\0273\0023\0224\0250\0003\0134\0070\0250\0000\0000\0066\0250\0003\0134\0370\0240\0003\0135\0370\0001\0371\0177\0222\0354\0272\0023\0224\0100\0000\0200\0122\0302\0273\0023\0224\0210\0002\0100\0071\0211\0012\0100\0371\0341\0335\0377\0220\0041\0104\0076\0221\0342\0333\0377\0260\0102\0040\0004\0221\0037\0001\0000\0162\0140\0000\0200\0122\0344\0003\0026\0052\0043\0025\0224\0232\0017\0273\0023\0224'

write_bytes()
{
    printf '%b' "$3" |
        dd of="$1" bs=1 seek="$2" conv=notrunc >/dev/null 2>&1
}

# Sparse synthetic OTA image with the exact semantic anchors used at runtime.
dd if=/dev/zero of="$SOURCE" bs=1 count=0 seek="$SIZE" >/dev/null 2>&1
write_bytes "$SOURCE" "$LEGACY_OFFSET" '\0336\0210\0001\0224'
write_bytes "$SOURCE" $((VOTE_OFFSET - 16)) \
    '\0270\0042\0000\0221\0253\0007\0000\0124\0037\0003\0000\0353\0141\0007\0000\0124'
write_bytes "$SOURCE" "$VOTE_OFFSET" "$VOTE_ORIGINAL_OCTAL"
write_bytes "$SOURCE" $((VOTE_OFFSET + VOTE_SIZE)) \
    '\0350\0303\0000\0221\0340\0003\0023\0252\0341\0003\0026\0052\0335\0375\0377\0227'
write_bytes "$SOURCE" "$AP_SCALE_OFFSET" '\0001\0003\0000\0124'

sh "$HELPER" test-patch "$MODEL" "$POLICY" "$SOURCE" "$OUTPUT"
[ "$(wc -c < "$OUTPUT" | tr -d '[:space:]')" = "$SIZE" ]
[ "$(od -An -tx1 -j "$VOTE_OFFSET" -N "$VOTE_SIZE" "$OUTPUT" | tr -d '[:space:]')" = \
    df020071ad040054880240391f010072810000540cfd41d389060091030000148c0640f9890a40f99f4100f1630300548c3d00d1eb4d8cd24badacf26b8ccef2ab25ecf2cd2d8dd2ad2dacf28d2ecdf2edcdedf22a0140f95f010beb810000542a0540f95f010deba0000054290500918c0500f101ffff5408000014a10000141f2003d51f2003d51f2003d51f2003d51f2003d51f2003d5 ]
[ "$(od -An -tx1 -j $((VOTE_OFFSET + 124)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = \
    a1000014 ]
[ "$(od -An -tx1 -j "$LEGACY_OFFSET" -N 4 "$OUTPUT" | tr -d '[:space:]')" = \
    de880194 ]
[ "$(od -An -tx1 -j "$AP_SCALE_OFFSET" -N 4 "$OUTPUT" | tr -d '[:space:]')" = \
    18000014 ]

# Restoring the one replacement region must reconstruct the source exactly.
cp "$OUTPUT" "$RESTORED"
write_bytes "$RESTORED" "$VOTE_OFFSET" "$VOTE_ORIGINAL_OCTAL"
write_bytes "$RESTORED" "$AP_SCALE_OFFSET" '\0001\0003\0000\0124'
cmp -s "$SOURCE" "$RESTORED"

# Never reuse a payload from a previous OTA: an unrelated current-source byte
# must be carried into a newly generated output even when the output exists.
SOURCE_2="$TMPDIR_TEST/source-2.bin"
cp "$SOURCE" "$SOURCE_2"
write_bytes "$SOURCE_2" 128 '\0177'
sh "$HELPER" test-patch "$MODEL" "$POLICY" "$SOURCE_2" "$OUTPUT"
[ "$(od -An -tu1 -j 128 -N 1 "$OUTPUT" | tr -d '[:space:]')" = 127 ]
cp "$OUTPUT" "$RESTORED"
write_bytes "$RESTORED" "$VOTE_OFFSET" "$VOTE_ORIGINAL_OCTAL"
write_bytes "$RESTORED" "$AP_SCALE_OFFSET" '\0001\0003\0000\0124'
cmp -s "$SOURCE_2" "$RESTORED"

if sh "$HELPER" test-patch WRONG "$POLICY" "$SOURCE" \
        "$TMPDIR_TEST/wrong-model.bin"; then
    echo 'FAIL: wrong model was accepted' >&2
    exit 1
fi
for wrong_policy in custom_ltpo adfr_off stock_ltpo_typo; do
    if sh "$HELPER" test-patch "$MODEL" "$wrong_policy" "$SOURCE" \
            "$TMPDIR_TEST/$wrong_policy.bin"; then
        echo "FAIL: wrong policy was accepted: $wrong_policy" >&2
        exit 1
    fi
done

reject_mutation()
{
    name=$1
    offset=$2
    bytes=$3
    input="$TMPDIR_TEST/$name.bin"
    cp "$SOURCE" "$input"
    write_bytes "$input" "$offset" "$bytes"
    if sh "$HELPER" test-patch "$MODEL" "$POLICY" "$input" \
            "$TMPDIR_TEST/$name.out"; then
        echo "FAIL: invalid $name source was accepted" >&2
        exit 1
    fi
}

reject_mutation bad-context $((VOTE_OFFSET - 1)) '\0000'
reject_mutation bad-region "$VOTE_OFFSET" '\0000'
reject_mutation legacy-nop "$LEGACY_OFFSET" '\0037\0040\0003\0325'
reject_mutation bad-ap-scale "$AP_SCALE_OFFSET" '\0000\0000\0000\0000'

if grep -Eq 'EXPECTED_(SOURCE|PATCHED)_SHA=' "$HELPER"; then
    echo 'FAIL: whole-file hash is used as a runtime gate' >&2
    exit 1
fi
grep -q '^VOTE_PATCH_OFFSET=5220408$' "$HELPER"
grep -q '^VOTE_PATCH_SIZE=152$' "$HELPER"
grep -q '^LEGACY_CALL_OFFSET=2776340$' "$HELPER"
grep -q '^LEGACY_CALL_ORIGINAL_HEX=de880194$' "$HELPER"
grep -q '^AP_SCALE_AUDIT_OFFSET=5229872$' "$HELPER"
grep -q '^AP_SCALE_ORIGINAL_HEX=01030054$' "$HELPER"
grep -q '^AP_SCALE_PATCHED_HEX=18000014$' "$HELPER"
grep -q 'b       rmx5200_stock_ltps_vote_filter + 0x300' "$ASM"
grep -q 'sh "$LTPS_VOTE_HELPER" apply' "$POST_FS"
grep -q 'sh "$LTPS_VOTE_HELPER" mark-boot-success' "$SERVICE"
grep -q 'surfaceflinger_ltps_vote_patch.sh" restore' "$UNINSTALL"
grep -q 'fallback:previous_boot_incomplete' "$HELPER"
grep -q 'fallback:guard_blocked' "$HELPER"
grep -q 'mount -o remount,bind,suid,exec "$SOURCE_FILE"' "$HELPER"
grep -q 'umount -l "$SOURCE_FILE"' "$HELPER"
FEATURE_MANIFEST="$ROOT/packaging/feature-components.json"
if [ -f "$FEATURE_MANIFEST" ]; then
    grep -q 'stock-LTPS object-animation vote repair' "$FEATURE_MANIFEST"
fi

sh -n "$HELPER"
sh -n "$POST_FS"
sh -n "$SERVICE"
sh -n "$UNINSTALL"

echo 'PASS: RMX5200 stock LTPS filters animation votes and preserves selected modePtr'
