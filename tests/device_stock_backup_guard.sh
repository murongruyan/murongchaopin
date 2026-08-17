#!/system/bin/sh

MOD_DIR="${1:-/data/adb/modules/murongchaopin}"
EXPECTED_HASH="$2"
HELPER="$MOD_DIR/scripts/dtbo_avb.sh"
STOCK_IMAGE="$MOD_DIR/img/dtbo.img"
STOCK_MANIFEST="$MOD_DIR/img/dtbo.img.sha256"
STOCK_RECOVERY="$MOD_DIR/img/dtbo.img.gz"
BIN_DIR="$MOD_DIR/bin"
SLOT=$(getprop ro.boot.slot_suffix)
PARTITION="/dev/block/by-name/dtbo$SLOT"
PARTITION_SIZE=$(blockdev --getsize64 "$PARTITION" 2>/dev/null)
TEST_DIR="/data/local/tmp/murongchaopin-stock-guard-test.$$"

fail() {
    echo "FAIL: $*" >&2
    rm -rf "$TEST_DIR"
    exit 1
}

[ -n "$EXPECTED_HASH" ] || fail "missing expected stock SHA-256"
[ -f "$HELPER" ] || fail "missing AVB helper"
[ -f "$STOCK_IMAGE" ] || fail "missing stock image"
[ -f "$STOCK_MANIFEST" ] || fail "missing stock manifest"
[ -f "$STOCK_RECOVERY" ] || fail "missing compressed recovery copy"

. "$HELPER"
mkdir -p "$TEST_DIR" || fail "cannot create test directory"
cp "$STOCK_IMAGE" "$TEST_DIR/dtbo.img" || fail "cannot copy stock image"
cp "$STOCK_MANIFEST" "$TEST_DIR/dtbo.img.sha256" || fail "cannot copy manifest"
cp "$STOCK_RECOVERY" "$TEST_DIR/dtbo.img.gz" || fail "cannot copy recovery archive"

printf '\001' | dd of="$TEST_DIR/dtbo.img" bs=1 seek=4096 conv=notrunc \
    2>/dev/null || fail "cannot corrupt sandbox image"
[ "$(dtbo_hash_file "$TEST_DIR/dtbo.img")" != "$EXPECTED_HASH" ] || \
    fail "sandbox corruption did not change the hash"

dtbo_recover_stock_backup "$TEST_DIR/dtbo.img" \
    "$TEST_DIR/dtbo.img.sha256" "$TEST_DIR/dtbo.img.gz" \
    "$PARTITION_SIZE" "$BIN_DIR" >/dev/null 2>&1 || \
    fail "compressed recovery failed"

[ "$(dtbo_hash_file "$TEST_DIR/dtbo.img")" = "$EXPECTED_HASH" ] || \
    fail "recovered image hash mismatch"
dtbo_validate_stock_backup "$TEST_DIR/dtbo.img" \
    "$TEST_DIR/dtbo.img.sha256" "$PARTITION_SIZE" "$BIN_DIR" \
    >/dev/null 2>&1 || fail "recovered image failed AVB validation"

rm -f "$TEST_DIR/dtbo.img"
dtbo_recover_stock_backup "$TEST_DIR/dtbo.img" \
    "$TEST_DIR/dtbo.img.sha256" "$TEST_DIR/dtbo.img.gz" \
    "$PARTITION_SIZE" "$BIN_DIR" >/dev/null 2>&1 || \
    fail "missing stock image was not recovered"
[ "$(dtbo_hash_file "$TEST_DIR/dtbo.img")" = "$EXPECTED_HASH" ] || \
    fail "missing-image recovery hash mismatch"

printf '\001' | dd of="$TEST_DIR/dtbo.img.gz" bs=1 seek=32 conv=notrunc \
    2>/dev/null || fail "cannot corrupt sandbox recovery archive"
if dtbo_validate_stock_recovery "$TEST_DIR/dtbo.img.sha256" \
    "$TEST_DIR/dtbo.img.gz"; then
    fail "corrupt recovery archive passed validation"
fi
dtbo_write_stock_recovery "$TEST_DIR/dtbo.img" \
    "$TEST_DIR/dtbo.img.sha256" "$TEST_DIR/dtbo.img.gz" || \
    fail "corrupt recovery archive was not rebuilt"
dtbo_validate_stock_recovery "$TEST_DIR/dtbo.img.sha256" \
    "$TEST_DIR/dtbo.img.gz" || fail "rebuilt recovery archive is invalid"

rm -rf "$TEST_DIR"
echo "PASS: stock image and compressed recovery guard passed for $EXPECTED_HASH"
