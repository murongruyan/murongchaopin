#!/bin/sh

set -eu

CUSTOMIZE="${1:-customize.sh}"
[ -f "$CUSTOMIZE" ] || { echo "FAIL: missing customize script" >&2; exit 1; }

eval "$(awk '/^# 音量键检测/ { exit } { print }' "$CUSTOMIZE")"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR/avbtool"

for relative_path in \
  avbtool/avbtool openssl dtc mkdtimg unpack_dtbo process_dts pack_dtbo; do
  mkdir -p "$(dirname "$BIN_DIR/$relative_path")"
  : > "$BIN_DIR/$relative_path"
  chmod 0644 "$BIN_DIR/$relative_path"
done

Prepare_install_tools

for relative_path in \
  avbtool/avbtool openssl dtc mkdtimg unpack_dtbo process_dts pack_dtbo; do
  [ -x "$BIN_DIR/$relative_path" ] || {
    echo "FAIL: tool remains non-executable: $relative_path" >&2
    exit 1
  }
done

chmod 0644 "$BIN_DIR/process_dts"
rm -f "$BIN_DIR/pack_dtbo"
if Prepare_install_tools; then
  echo "FAIL: missing install tool was accepted" >&2
  exit 1
fi

echo "PASS: KernelSU 0644 tool extraction is repaired before backend dispatch"
