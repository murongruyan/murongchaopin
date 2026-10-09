#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT/scripts/surfaceflinger_ltps_vote_patch.sh"
ASM="$ROOT/src/surfaceflinger/rmx5200_stock_ltps_vote_filter.S"
POST_FS="$ROOT/post-fs-data.sh"
SERVICE="$ROOT/service.sh"
UNINSTALL="$ROOT/uninstall.sh"
TMPDIR_TEST=$(mktemp -d)
STALE_STATE="$ROOT/config/surfaceflinger_ltps_vote_patch"
# bin/surfaceflinger.rmx5200.stock-ltps-vote is the helper's PATCHED_FILE, so a
# stub written there exercises the runtime selector path instead of the
# arbitrary-file shortcut.
STALE_SOURCE="$ROOT/bin/surfaceflinger.rmx5200.stock-ltps-vote"
trap 'rm -rf "$TMPDIR_TEST"; rm -f "$STALE_SOURCE"' EXIT HUP INT TERM

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
# Daily-idle sub-mode: custom_ltpo with the daily-idle flag must be accepted
# and produce the same patched bytes as stock_ltps.
printf 'on\n' > "$ROOT/config/rmx5200_ltpo_daily_idle.txt"
if sh "$HELPER" test-patch "$MODEL" custom_ltpo "$SOURCE" \
        "$TMPDIR_TEST/custom_ltpo_daily.bin"; then
    sh "$HELPER" test-patch "$MODEL" stock_ltps "$SOURCE" \
        "$TMPDIR_TEST/stock_ltps_reference.bin"
    cmp -s "$TMPDIR_TEST/stock_ltps_reference.bin" "$TMPDIR_TEST/custom_ltpo_daily.bin" || {
        echo 'FAIL: daily-idle patch bytes differ from stock_ltps' >&2
        exit 1
    }
else
    echo 'FAIL: custom_ltpo with daily-idle flag was rejected' >&2
    rm -f "$ROOT/config/rmx5200_ltpo_daily_idle.txt"
    exit 1
fi
rm -f "$ROOT/config/rmx5200_ltpo_daily_idle.txt"
# 完美禁用 ADFR 同样需要这层过滤：关闭"超级帧率"后厂商的 AP-scale / scale_up
# 映射表会残留在插帧时的 123Hz 档，SurfaceFlinger 会把 144fps 解析成
# 1080x2352@123（mode 11），面板被拖到 FHD 组再被拉回来就是黑闪。
# 必须与 stock_ltps 产出完全相同的补丁字节。
if sh "$HELPER" test-patch "$MODEL" adfr_off "$SOURCE" \
        "$TMPDIR_TEST/adfr_off.bin"; then
    cmp -s "$TMPDIR_TEST/stock_ltps_reference.bin" "$TMPDIR_TEST/adfr_off.bin" || {
        echo 'FAIL: adfr_off patch bytes differ from stock_ltps' >&2
        exit 1
    }
else
    echo 'FAIL: adfr_off policy was rejected' >&2
    exit 1
fi
# 纯自制 LTPO（未打开"禁用日常 LTPO"）在 ColorOS 17 上同样走这层过滤：
# 静止投票由框架 hook 定向到注入的最低档，必须先挡住厂商 AP-scale 顶档。
# The platform gate is pinned to 16 here: the assertion is about the gate, not
# about the device the suite happens to run on (ColorOS 17 devices otherwise
# satisfy the >= 17 arm and the check would "fail" on a correct helper).
if ANDROID_RELEASE_MAJOR_OVERRIDE=16 sh "$HELPER" test-patch "$MODEL" custom_ltpo "$SOURCE" \
        "$TMPDIR_TEST/custom_ltpo_plain_16.bin" 2>/dev/null; then
    echo 'FAIL: pure custom_ltpo was accepted without a ColorOS 17 platform' >&2
    exit 1
fi
if ANDROID_RELEASE_MAJOR_OVERRIDE=17 sh "$HELPER" test-patch "$MODEL" \
        custom_ltpo "$SOURCE" "$TMPDIR_TEST/custom_ltpo_plain_17.bin"; then
    cmp -s "$TMPDIR_TEST/stock_ltps_reference.bin" \
        "$TMPDIR_TEST/custom_ltpo_plain_17.bin" || {
        echo 'FAIL: pure custom_ltpo patch bytes differ from stock_ltps' >&2
        exit 1
    }
else
    echo 'FAIL: pure custom_ltpo on ColorOS 17 was rejected' >&2
    exit 1
fi

for wrong_policy in custom_ltpo stock_ltpo_typo; do
    if ANDROID_RELEASE_MAJOR_OVERRIDE=16 sh "$HELPER" test-patch "$MODEL" \
            "$wrong_policy" "$SOURCE" "$TMPDIR_TEST/$wrong_policy.bin"; then
        echo "FAIL: wrong policy was accepted: $wrong_policy" >&2
        exit 1
    fi
done

# The vote filter is RMX5200-only, and this must hold even when the policy file
# happens to name the RMX5200 policy.
#
# Every model ships config/rmx5200_display_policy.txt as "stock_ltps" and the
# installer does not rewrite it per model, while ltps_vote_wanted() treats
# "stock_ltps" as a request for this patch.  Without a profile gate, PLK110
# therefore arrived with a policy that web_handler.sh rejects as invalid for
# that model (set_display_policy accepts only stock_ltpo / adfr_off there) and
# that armed an RMX5200-only patch on hardware it was never validated on.
# PLK110 / PLQ110 / PJD110 ship vendor LTPO: there is no vendor vote to filter.
for vendor_ltpo_model in PLK110 PLQ110 PJD110; do
    for stray_policy in stock_ltps adfr_off custom_ltpo; do
        if ANDROID_RELEASE_MAJOR_OVERRIDE=17 sh "$HELPER" test-patch \
                "$vendor_ltpo_model" "$stray_policy" "$SOURCE" \
                "$TMPDIR_TEST/$vendor_ltpo_model-$stray_policy.bin"; then
            echo "FAIL: $vendor_ltpo_model accepted the RMX5200-only vote filter" \
                "under policy $stray_policy" >&2
            exit 1
        fi
    done
done

# ... and the same guard must be what the runtime paths consult, not just the
# test entry point, otherwise the two can drift apart.
grep -q 'profile_uses_vote_filter' "$HELPER"
grep -q "PLK110|PLQ110|PJD110) printf '%s\\\\n' vendor_ltpo" "$HELPER"
if grep -q 'model_is_supported' "$HELPER"; then
    echo 'FAIL: stale model allowlist gate is still present' >&2
    exit 1
fi

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

# ColorOS 17 carries the same two companion sites at new offsets; the 152-byte
# block contract above cannot describe that build, so the helper selects a site
# table by whole-file hash and rewrites only those instructions.
SITES_SOURCE="$TMPDIR_TEST/sites-source.bin"
SITES_OUTPUT="$TMPDIR_TEST/sites-output.bin"
SITES_SIZE=7000000
ANIMATION_OFFSET=3152928
AP_SCALE_PTR_OFFSET=3651804
dd if=/dev/zero of="$SITES_SOURCE" bs=1 count=0 seek="$SITES_SIZE" >/dev/null 2>&1
write_bytes "$SITES_SOURCE" "$ANIMATION_OFFSET" '\0255\0333\0373\0227'
write_bytes "$SITES_SOURCE" "$AP_SCALE_PTR_OFFSET" '\0200\0004\0000\0124'
sh "$HELPER" test-sites "$ANIMATION_OFFSET" addbfb97 1f2003d5 \
    "$AP_SCALE_PTR_OFFSET" 80040054 24000014 "$SITES_SOURCE" "$SITES_OUTPUT"
[ "$(od -An -tx1 -j "$ANIMATION_OFFSET" -N 4 "$SITES_OUTPUT" | tr -d '[:space:]')" = 1f2003d5 ]
[ "$(od -An -tx1 -j "$AP_SCALE_PTR_OFFSET" -N 4 "$SITES_OUTPUT" | tr -d '[:space:]')" = 24000014 ]
[ "$(wc -c < "$SITES_OUTPUT" | tr -d '[:space:]')" = "$SITES_SIZE" ]
[ "$(cmp -l "$SITES_SOURCE" "$SITES_OUTPUT" | wc -l | tr -d '[:space:]')" = 7 ]

cp "$SITES_SOURCE" "$TMPDIR_TEST/sites-bad.bin"
write_bytes "$TMPDIR_TEST/sites-bad.bin" "$ANIMATION_OFFSET" '\0000\0000\0000\0000'
if sh "$HELPER" test-sites "$ANIMATION_OFFSET" addbfb97 1f2003d5 \
        "$AP_SCALE_PTR_OFFSET" 80040054 24000014 \
        "$TMPDIR_TEST/sites-bad.bin" "$TMPDIR_TEST/sites-bad.out"; then
    echo 'FAIL: wrong animation original instruction was accepted' >&2
    exit 1
fi
[ ! -e "$TMPDIR_TEST/sites-bad.out" ] || {
    echo 'FAIL: rejected site patch still produced output' >&2
    exit 1
}

# The pinned site table also carries the RMX5200 ColorOS 17 2026-10-05 OTA
# (sha256 c3b8273f...), whose two companion sites sit at 3153312 / 3652644.
grep -q '^4b9a0ca743aabe6cada245f5e9b789cdd5a3d345c5bf37168b353d7f38b88e03:3152928:addbfb97:3651804:41020054' "$HELPER"
grep -q '^ c3b8273f211536783ba48229e4ea70314b0c979e3774ea3a2f5fc80b3836e2a9:3153312:06f00c94:3652644:41020054' "$HELPER"

# A recorded "legacy" verdict must not outlive the bytes it described.  An OTA
# that replaces SurfaceFlinger leaves contract=legacy while record_contract()
# rewrites contract-source to the NEW hash, and trusting that record kept the
# 152-byte block check failing forever: the vote filter never got to relocate
# itself by signature.  That is exactly how this device ended up as
# rejected:source_contract_12 on a build whose two sites were still there.
# The runtime selector has to re-verify the block and fall through to
# detect_dynamic_sites().
mkdir -p "$ROOT/bin" "$STALE_STATE"
cp "$STALE_STATE/contract" "$TMPDIR_TEST/contract.bak" 2>/dev/null || true
cp "$STALE_STATE/contract-source" "$TMPDIR_TEST/contract-source.bak" 2>/dev/null || true
cp "$STALE_STATE/dynamic-site-entry" "$TMPDIR_TEST/dynamic-site-entry.bak" 2>/dev/null || true
dd if=/dev/zero of="$STALE_SOURCE" bs=1 count=0 seek="$SITES_SIZE" >/dev/null 2>&1
# animation anchor d70e45f8080140f9e9cd8d52, then the second bl-shaped word
write_bytes "$STALE_SOURCE" 1000 '\0327\0016\0105\0370\0010\0001\0100\0371\0351\0315\0215\0122'
write_bytes "$STALE_SOURCE" 1012 '\0021\0042\0063\0224'
write_bytes "$STALE_SOURCE" 1016 '\0006\0360\0014\0224'
# AP-scale anchor 682240f908d156f9088945391f050071, branch word at +16
write_bytes "$STALE_SOURCE" 2000 '\0150\0042\0100\0371\0010\0321\0126\0371\0010\0211\0105\0071\0037\0005\0000\0161'
write_bytes "$STALE_SOURCE" 2016 '\0101\0002\0000\0124'
printf 'legacy\n' > "$STALE_STATE/contract"
sha256sum "$STALE_SOURCE" | awk '{ print $1 }' > "$STALE_STATE/contract-source"
STALE_OUTPUT="$TMPDIR_TEST/stale-dynamic.bin"
sh "$HELPER" test-patch "$MODEL" "$POLICY" "$STALE_SOURCE" "$STALE_OUTPUT"
[ "$(od -An -tx1 -j 1016 -N 4 "$STALE_OUTPUT" | tr -d '[:space:]')" = 1f2003d5 ] || {
    echo 'FAIL: stale legacy record blocked the animation site' >&2
    exit 1
}
[ "$(od -An -tx1 -j 2016 -N 4 "$STALE_OUTPUT" | tr -d '[:space:]')" = 12000014 ] || {
    echo 'FAIL: stale legacy record blocked the AP-scale site' >&2
    exit 1
}
[ "$(sed -n '1p' "$STALE_STATE/contract")" = table ] || {
    echo 'FAIL: signature relocation did not record the table contract' >&2
    exit 1
}
rm -f "$STALE_SOURCE" "$STALE_STATE/dynamic-site-entry"
if [ -f "$TMPDIR_TEST/contract.bak" ]; then
    cp "$TMPDIR_TEST/contract.bak" "$STALE_STATE/contract"
fi
if [ -f "$TMPDIR_TEST/contract-source.bak" ]; then
    cp "$TMPDIR_TEST/contract-source.bak" "$STALE_STATE/contract-source"
fi
if [ -f "$TMPDIR_TEST/dynamic-site-entry.bak" ]; then
    cp "$TMPDIR_TEST/dynamic-site-entry.bak" "$STALE_STATE/dynamic-site-entry"
fi

# Optional: feed a real installed SurfaceFlinger through the selector when one
# is supplied.  The current ColorOS 17 OTA has moved both sites again, and its
# hash is deliberately treated as a cache hint rather than a gate.  The second
# invocation mutates an unrelated byte, so the unknown-hash path must locate
# the same two instructions from their surrounding code.
if [ -n "${MURONG_RMX5200_SF:-}" ] && [ -r "$MURONG_RMX5200_SF" ]; then
    # Defaults describe the OTA whose sites are already in BUILD_SITE_TABLE.
    # Other builds pass theirs, e.g. the RMX5200 ColorOS 17 2026-10-05 OTA
    # (sha256 c3b8273f...) with 3153312 / 3652644.
    CURRENT_ANIMATION_OFFSET=${MURONG_RMX5200_SF_ANIMATION_OFFSET:-3152940}
    CURRENT_AP_SCALE_OFFSET=${MURONG_RMX5200_SF_AP_SCALE_OFFSET:-3652276}
    sh "$HELPER" test-patch "$MODEL" "$POLICY" "$MURONG_RMX5200_SF" \
        "$TMPDIR_TEST/real-sf.bin"
    [ "$(od -An -tx1 -j "$CURRENT_ANIMATION_OFFSET" -N 4 "$TMPDIR_TEST/real-sf.bin" | tr -d '[:space:]')" = 1f2003d5 ]
    [ "$(od -An -tx1 -j "$CURRENT_AP_SCALE_OFFSET" -N 4 "$TMPDIR_TEST/real-sf.bin" | tr -d '[:space:]')" = 12000014 ]
    [ "$(wc -c < "$TMPDIR_TEST/real-sf.bin" | tr -d '[:space:]')" = \
        "$(wc -c < "$MURONG_RMX5200_SF" | tr -d '[:space:]')" ]

    UNKNOWN_SF="$TMPDIR_TEST/real-sf-unknown.bin"
    cp "$MURONG_RMX5200_SF" "$UNKNOWN_SF"
    write_bytes "$UNKNOWN_SF" 128 '\0177'
    sh "$HELPER" test-patch "$MODEL" "$POLICY" "$UNKNOWN_SF" \
        "$TMPDIR_TEST/real-sf-unknown.out"
    [ "$(od -An -tx1 -j "$CURRENT_ANIMATION_OFFSET" -N 4 "$TMPDIR_TEST/real-sf-unknown.out" | tr -d '[:space:]')" = 1f2003d5 ]
    [ "$(od -An -tx1 -j "$CURRENT_AP_SCALE_OFFSET" -N 4 "$TMPDIR_TEST/real-sf-unknown.out" | tr -d '[:space:]')" = 12000014 ]
    [ "$(wc -c < "$TMPDIR_TEST/real-sf-unknown.out" | tr -d '[:space:]')" = \
        "$(wc -c < "$MURONG_RMX5200_SF" | tr -d '[:space:]')" ]
fi

sh -n "$HELPER"
sh -n "$POST_FS"
sh -n "$SERVICE"
sh -n "$UNINSTALL"

echo 'PASS: RMX5200 stock LTPS filters animation votes and preserves selected modePtr'
