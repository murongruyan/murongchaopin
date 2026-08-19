#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

mkdir -p "$TMP_DIR/scripts" "$TMP_DIR/config" "$TMP_DIR/runtime/hmbird" "$TMP_DIR/bin"
cp "$ROOT/scripts/hmbird_backend.sh" "$TMP_DIR/scripts/hmbird_backend.sh"

run_helper() {
    MOD_DIR="$TMP_DIR" sh "$TMP_DIR/scripts/hmbird_backend.sh" apply
}

run_helper
[ "$(sed -n '1p' "$TMP_DIR/runtime/hmbird/status.txt")" = "disabled:dtbo_only" ]
[ ! -e "$TMP_DIR/state/insmod.log" ]

if grep -Eq '(^|[[:space:];])insmod[[:space:]].*hmbird|bin/hmbird\.ko' \
    "$ROOT/scripts/hmbird_backend.sh" "$ROOT/post-fs-data.sh" "$ROOT/customize.sh"; then
    echo "FAIL: current HMBIRD path still references standalone hmbird.ko/insmod" >&2
    exit 1
fi

grep -q 'prepare-dtbo' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'PROCESS_DTS_MODE="--hmbird-only=' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'process_dts.*PROCESS_DTS_MODE' "$ROOT/scripts/hmbird_backend.sh"
grep -q 'hmbird_ko_free=0' "$ROOT/config/display_mode_manifest.txt"
grep -q 'hmbird_ko_backends=dtbo' "$ROOT/config/display_mode_manifest.txt"

echo "PASS: HMBIRD apply is DTBO-only and never loads a standalone KO"
