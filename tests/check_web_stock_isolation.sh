#!/bin/sh

set -eu

HANDLER="${1:-scripts/web_handler.sh}"

if grep -nE 'of="\$(IMG_DIR|STOCK_DTBO)(/dtbo\.img)?"' "$HANDLER"; then
    echo "Web handler must never extract an active partition into img/dtbo.img" >&2
    exit 1
fi

if grep -nF '../img/dtbo.img' "$HANDLER"; then
    echo "Web handler must unpack workspace/dtbo.img, not img/dtbo.img" >&2
    exit 1
fi

extract_count=$(grep -c 'of="$WORK_DIR/dtbo.img"' "$HANDLER")
[ "$extract_count" -eq 2 ] || {
    echo "Expected exactly two isolated Web extraction paths, found $extract_count" >&2
    exit 1
}

grep -q 'stock_guard_begin' "$HANDLER"
grep -q 'stock_guard_end' "$HANDLER"
grep -q 'dtbo.img.sha256' "$HANDLER"

echo "PASS: Web DTBO workspace is isolated from the stock backup"
