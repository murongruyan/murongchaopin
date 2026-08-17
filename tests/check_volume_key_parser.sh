#!/bin/sh

set -eu

CUSTOMIZE="${1:-customize.sh}"
[ -f "$CUSTOMIZE" ] || { echo "FAIL: missing customize script" >&2; exit 1; }

# Load only the input helpers. The rest of customize.sh is an installer body
# and must not run in this host-side parser test.
eval "$(awk '/^# 安装\/更新模块函数/ { exit } { print }' "$CUSTOMIZE")"

getevent() {
  printf '%s\n' '/dev/input/event2: EV_KEY KEY_VOLUMEUP DOWN'
}

[ "$(Read_volume_key)" = "KEY_VOLUMEUP" ] || {
  echo "FAIL: volume-up event was not recognized" >&2
  exit 1
}

getevent() {
  printf '%s\n' '/dev/input/event0: EV_KEY KEY_VOLUMEDOWN DOWN'
}

[ "$(Read_volume_key)" = "KEY_VOLUMEDOWN" ] || {
  echo "FAIL: volume-down event was not recognized" >&2
  exit 1
}

grep -q 'sleep 1' "$CUSTOMIZE" || {
  echo "FAIL: missing delay between the two installer selections" >&2
  exit 1
}

echo "PASS: simple volume-key parser and inter-selection delay are present"
