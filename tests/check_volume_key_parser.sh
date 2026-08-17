#!/bin/sh

set -eu

CUSTOMIZE="${1:-customize.sh}"
[ -f "$CUSTOMIZE" ] || { echo "FAIL: missing customize script" >&2; exit 1; }

# Load only the input helpers. The rest of customize.sh is an installer body
# and must not run in this host-side parser test.
eval "$(awk '/^# 安装\/更新模块函数/ { exit } { print }' "$CUSTOMIZE")"

getevent() {
  printf '%s\n' \
    '[1] EV_KEY KEY_VOLUMEUP DOWN' \
    '[1] EV_SYN SYN_REPORT 00000000' \
    '[2] EV_KEY KEY_VOLUMEUP UP' \
    '[2] EV_SYN SYN_REPORT 00000000'
}

[ "$(Read_volume_key_press)" = "KEY_VOLUMEUP" ] || {
  echo "FAIL: text DOWN/UP pair was not recognized" >&2
  exit 1
}

getevent() {
  printf '%s\n' \
    'EV_KEY KEY_VOLUMEDOWN 00000001' \
    'EV_SYN SYN_REPORT 00000000' \
    'EV_KEY KEY_VOLUMEDOWN 00000000' \
    'EV_SYN SYN_REPORT 00000000'
}

[ "$(Read_volume_key_press)" = "KEY_VOLUMEDOWN" ] || {
  echo "FAIL: numeric press/release pair was not recognized" >&2
  exit 1
}

echo "PASS: continuous volume-key parser handles text and numeric event values"
