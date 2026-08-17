#!/system/bin/sh

SOURCE_MOD="${1:-/data/adb/modules/murongchaopin}"
EXPECTED_HASH="$2"
SLOT=$(getprop ro.boot.slot_suffix)
PARTITION="/dev/block/by-name/dtbo$SLOT"
TEST_DIR="/data/local/tmp/murongchaopin-invalid-backup-test.$$"

fail() {
    echo "FAIL: $*" >&2
    rm -rf "$TEST_DIR"
    exit 1
}

[ -n "$EXPECTED_HASH" ] || fail "missing expected partition SHA-256"
mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/img" "$TEST_DIR/config" || \
    fail "cannot create test module"
cp "$SOURCE_MOD/scripts/web_handler.sh" "$TEST_DIR/scripts/web_handler.sh" || \
    fail "cannot copy Web handler"
cp "$SOURCE_MOD/scripts/dtbo_avb.sh" "$TEST_DIR/scripts/dtbo_avb.sh" || \
    fail "cannot copy AVB helper"
cp "$SOURCE_MOD/img/dtbo.img" "$TEST_DIR/img/dtbo.img" || \
    fail "cannot copy stock image"
cp "$SOURCE_MOD/img/dtbo.img.sha256" "$TEST_DIR/img/dtbo.img.sha256" || \
    fail "cannot copy manifest"
ln -s "$SOURCE_MOD/bin" "$TEST_DIR/bin" || fail "cannot link test binaries"

printf '\001' | dd of="$TEST_DIR/img/dtbo.img" bs=1 seek=4096 conv=notrunc \
    2>/dev/null || fail "cannot corrupt sandbox backup"

CHECK_OUTPUT=$(MURONGCHAOPIN_MOD_PATH="$TEST_DIR" \
    sh "$TEST_DIR/scripts/web_handler.sh" check_backup 2>&1)
case "$CHECK_OUTPUT" in
    INVALID*) ;;
    *) fail "invalid backup was not reported: $CHECK_OUTPUT" ;;
esac

PARTITION_BEFORE=$(sha256sum "$PARTITION" 2>/dev/null | awk '{print $1}')
[ "$PARTITION_BEFORE" = "$EXPECTED_HASH" ] || fail "unexpected partition hash before test"

if MURONGCHAOPIN_MOD_PATH="$TEST_DIR" \
    sh "$TEST_DIR/scripts/web_handler.sh" restore_dtbo >/dev/null 2>&1; then
    fail "restore accepted an invalid backup"
fi

PARTITION_AFTER=$(sha256sum "$PARTITION" 2>/dev/null | awk '{print $1}')
[ "$PARTITION_AFTER" = "$PARTITION_BEFORE" ] || fail "partition changed after rejected restore"

rm -rf "$TEST_DIR"
echo "PASS: invalid backup was rejected before partition write"
