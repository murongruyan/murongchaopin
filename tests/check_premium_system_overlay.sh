#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/packaging/paid-payload/scripts/premium_system_overlay.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/bin" "$TMP/state"
cp "$ROOT/system/odm/etc/iris_page_i7p.json" "$TMP/source.json"
printf '{"header":{"platform":"iris7p"},"scs_panel_fps":{"d0":[60,90,120]}}\n' \
    > "$TMP/target.json"

cat > "$TMP/bin/mount" <<'SH'
#!/bin/sh
[ "$1" = --bind ] && cp "$2" "$3"
SH
cat > "$TMP/bin/umount" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TMP/bin/mount" "$TMP/bin/umount"

run_helper() {
    PATH="$TMP/bin:$PATH" \
    PREMIUM_MODEL_OVERRIDE=RMX5200 \
    PREMIUM_IRIS_SOURCE="$TMP/source.json" \
    PREMIUM_IRIS_TARGET="$TMP/target.json" \
    PREMIUM_SYSTEM_OVERLAY_STATE_DIR="$TMP/state" \
        sh "$HELPER" "$@"
}

run_helper apply
cmp -s "$TMP/source.json" "$TMP/target.json"
grep -q '^active:bind_iris$' "$TMP/state/state.txt"

sed 's/60, 90, 120, 144/60, 90, 120, 144, 165/' \
    "$ROOT/system/odm/etc/iris_page_i7p.json" > "$TMP/source.json"
if run_helper apply; then
    echo 'FAIL: premium Iris overlay accepted an over-144Hz whitelist' >&2
    exit 1
fi
grep -q '^rejected:iris_contract$' "$TMP/state/state.txt"

echo 'PASS: nested premium system overlay is validated and explicitly bound'
