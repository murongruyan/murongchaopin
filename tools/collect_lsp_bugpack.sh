#!/system/bin/sh
# 收集 LSPosed / 显示模块 bug 诊断包。
# 用法（在用户设备上以 root 运行）：
#   su -c "sh /data/local/tmp/collect_lsp_bugpack.sh"
# 或者通过 adb：
#   adb push collect_lsp_bugpack.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/collect_lsp_bugpack.sh"
# 产物：/data/local/tmp/lsp_bugpack_<时间>.zip

OUT="/data/local/tmp/lsp_bugpack_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/lspd" "$OUT/anr" "$OUT/tombstones" "$OUT/dropbox" "$OUT/props" "$OUT/modules"

echo "==> LSPosed logs"
cp -a /data/adb/lspd/log/* "$OUT/lspd/" 2>/dev/null || true
cp -a /data/adb/lspd/log.old/* "$OUT/lspd/" 2>/dev/null || true

echo "==> ANR / watchdog traces"
ls -lat /data/anr/ > "$OUT/anr/listing.txt" 2>/dev/null || true
for f in /data/anr/traces_SystemServer_WDT* /data/anr/anr_*; do
  [ -f "$f" ] && cp "$f" "$OUT/anr/" 2>/dev/null
done

echo "==> Tombstones"
ls -lat /data/tombstones/ > "$OUT/tombstones/listing.txt" 2>/dev/null || true
for f in /data/tombstones/tombstone_*; do
  [ -f "$f" ] && cp "$f" "$OUT/tombstones/" 2>/dev/null
done

echo "==> Dropbox (watchdog/ANR/crash)"
dumpsys dropbox --print > "$OUT/dropbox/dropbox.txt" 2>/dev/null || true

echo "==> Device props"
getprop > "$OUT/props/props.txt" 2>/dev/null || true
{
  echo "model=$(getprop ro.product.vendor.model 2>/dev/null)"
  echo "android=$(getprop ro.build.version.release 2>/dev/null)"
  echo "incremental=$(getprop ro.build.version.incremental 2>/dev/null)"
  echo "kernel=$(uname -r 2>/dev/null)"
  echo "magisk=$(magisk -V 2>/dev/null || true)"
  echo "ksu=$(ksud -V 2>/dev/null || true)"
  echo "lspd=$(dumpsys package org.lsposed.manager 2>/dev/null | grep -m1 versionName)"
  echo "uptime=$(uptime)"
} > "$OUT/props/summary.txt" 2>/dev/null || true

echo "==> Module state"
cp /data/adb/lspd/config/modules_config.db* "$OUT/modules/" 2>/dev/null || true
pm list packages > "$OUT/modules/packages.txt" 2>/dev/null || true
pm path com.murongchaopin.displayhook > "$OUT/modules/free_path.txt" 2>/dev/null || true
pm path com.murongchaopin.displayhook.premium > "$OUT/modules/premium_path.txt" 2>/dev/null || true
dumpsys package com.murongchaopin.displayhook | grep -E 'versionCode|versionName' > "$OUT/modules/free_version.txt" 2>/dev/null || true
dumpsys package com.murongchaopin.displayhook.premium | grep -E 'versionCode|versionName' > "$OUT/modules/premium_version.txt" 2>/dev/null || true

echo "==> Recent logcat (main+events)"
logcat -d -v threadtime -t 3000 > "$OUT/logcat_main.txt" 2>/dev/null || true
logcat -d -b events -v threadtime -t 2000 > "$OUT/logcat_events.txt" 2>/dev/null || true

echo "==> Packing"
if command -v zip >/dev/null 2>&1; then
  (cd /data/local/tmp && zip -r "$OUT.zip" "$(basename "$OUT")" >/dev/null 2>&1)
  rm -rf "$OUT"
  echo "done: $OUT.zip"
else
  echo "zip not found, leaving folder: $OUT"
fi
