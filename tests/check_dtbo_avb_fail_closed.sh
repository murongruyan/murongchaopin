#!/bin/sh

set -eu

HELPER=${1:-scripts/dtbo_avb.sh}
[ -f "$HELPER" ] || { echo "FAIL: missing DTBO AVB helper" >&2; exit 1; }

# The original backup must still pass its official descriptor verification.
# A generated image follows the project's official-VBMeta reuse path: enforce
# image size/footer/VBMeta structure and byte identity, but do not reject the
# deliberately changed payload against the stock payload hash descriptor.
grep -q 'dtbo_verify_official_image' "$HELPER"
grep -q 'dtbo_validate_stock_backup' "$HELPER"
APPLY_BODY=$(sed -n '/^dtbo_apply_stock_avb()/,/^dtbo_write_partition()/p' "$HELPER")
printf '%s\n' "$APPLY_BODY" | grep -q 'dtbo_output_size'
printf '%s\n' "$APPLY_BODY" | grep -q 'dtbo_check_orig'
printf '%s\n' "$APPLY_BODY" | grep -q 'dtbo_check_voff'
printf '%s\n' "$APPLY_BODY" | grep -q 'cmp -s.*check_vbmeta.bin.*dtbo_vbmeta'
if printf '%s\n' "$APPLY_BODY" | grep -q 'dtbo_verify_official_image'; then
    echo "FAIL: modified payload is incorrectly checked against the stock descriptor" >&2
    exit 1
fi
if grep -Eq 'avbctl|disable-verity|disable_verification|do_not_use_ab' "$HELPER"; then
    echo "FAIL: DTBO helper contains an AVB verification bypass" >&2
    exit 1
fi

echo "PASS: stock verification and official-VBMeta structural reuse are enforced"
