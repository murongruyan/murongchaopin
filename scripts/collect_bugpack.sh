#!/system/bin/sh
# 自动收集显示模块 / LSPosed 诊断包，输出到用户可直接发送的路径。
# 由 service.sh 在检测到崩溃/安全模式后自动调用，也可手动执行：
#   su -c "sh /data/adb/modules/murongchaopin/scripts/collect_bugpack.sh"

if [ -z "${MODDIR:-}" ] || [ ! -f "$MODDIR/module.prop" ]; then
  MODDIR=""
  for cand in /data/adb/modules/*/; do
    [ -f "$cand/module.prop" ] || continue
    if grep -q '^id=murongchaopin$' "$cand/module.prop" 2>/dev/null; then
      MODDIR="${cand%/}"
      break
    fi
  done
fi
MODDIR=${MODDIR:-/data/adb/modules/murongchaopin}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="/sdcard/Download"
WORK="/data/local/tmp/murong-bugpack-$STAMP"
mkdir -p "$WORK/lspd" "$WORK/anr" "$WORK/tombstones" "$WORK/props" "$WORK/modules" "$WORK/dropbox"

echo "==> device info"
{
  echo "model=$(getprop ro.product.vendor.model 2>/dev/null)"
  echo "android=$(getprop ro.build.version.release 2>/dev/null)"
  echo "incremental=$(getprop ro.build.version.incremental 2>/dev/null)"
  echo "kernel=$(uname -r 2>/dev/null)"
  echo "magisk=$(magisk -V 2>/dev/null || echo none)"
  echo "ksu=$(ksud -V 2>/dev/null || echo none)"
  echo "lspd=$(dumpsys package org.lsposed.manager 2>/dev/null | grep -m1 versionName)"
  echo "uptime=$(uptime 2>/dev/null)"
} > "$WORK/props/summary.txt"
getprop > "$WORK/props/all_props.txt" 2>/dev/null

echo "==> module versions"
{
  echo "free_module:"
  sed -n 's/^\(version\|versionCode\|id\)=/\1=/p' "$MODDIR/module.prop" 2>/dev/null
  echo "free_hook:"
  dumpsys package com.murongchaopin.displayhook 2>/dev/null | grep -E 'versionCode|versionName'
  echo "premium_hook:"
  dumpsys package com.murongchaopin.displayhook.premium 2>/dev/null | grep -E 'versionCode|versionName'
  echo "premium_manifest:"
  sed -n '1,30p' "$MODDIR/premium/manifest.json" 2>/dev/null
} > "$WORK/modules/versions.txt"
pm list packages > "$WORK/modules/packages.txt" 2>/dev/null
cp "$MODDIR/module.prop" "$WORK/modules/" 2>/dev/null

echo "==> lsposed logs"
cp -a /data/adb/lspd/log/* "$WORK/lspd/" 2>/dev/null || true
cp -a /data/adb/lspd/log.old/* "$WORK/lspd/" 2>/dev/null || true
cp /data/adb/lspd/config/modules_config.db* "$WORK/modules/" 2>/dev/null || true

echo "==> anr / watchdog traces"
ls -lat /data/anr/ > "$WORK/anr/listing.txt" 2>/dev/null
for f in /data/anr/traces_SystemServer_WDT* /data/anr/anr_*; do
  [ -f "$f" ] && cp "$f" "$WORK/anr/" 2>/dev/null
done

echo "==> tombstones"
ls -lat /data/tombstones/ > "$WORK/tombstones/listing.txt" 2>/dev/null
for f in /data/tombstones/tombstone_*; do
  [ -f "$f" ] && cp "$f" "$WORK/tombstones/" 2>/dev/null
done

echo "==> dropbox"
dumpsys dropbox --print > "$WORK/dropbox/dropbox.txt" 2>/dev/null || true

echo "==> recent logcat"
logcat -d -v threadtime -t 4000 > "$WORK/logcat_main.txt" 2>/dev/null || true
logcat -d -b events -v threadtime -t 2000 > "$WORK/logcat_events.txt" 2>/dev/null || true

echo "==> packing"
ARCHIVE="$WORK.tar.gz"
if command -v tar >/dev/null 2>&1; then
  (cd /data/local/tmp && tar czf "$ARCHIVE" "$(basename "$WORK")" 2>/dev/null)
  rm -rf "$WORK"
  if [ -d "$OUT_DIR" ] && touch "$OUT_DIR/.w" 2>/dev/null; then
    cp "$ARCHIVE" "$OUT_DIR/murong_bugpack_$STAMP.tar.gz" 2>/dev/null
    rm -f "$OUT_DIR/.w"
  fi
  echo "bugpack: $ARCHIVE"
  [ -f "$OUT_DIR/murong_bugpack_$STAMP.tar.gz" ] && echo "user copy: $OUT_DIR/murong_bugpack_$STAMP.tar.gz"
else
  echo "tar not found, leaving folder: $WORK"
fi
