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
  echo "model=$(getprop ro.product.vendor.model 2>/dev/null| sed 's/^CPH2747$/PLK110/')"
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
  grep -E "^(version|versionCode|id)=" "$MODDIR/module.prop" 2>/dev/null
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

echo "==> module runtime"
mkdir -p "$WORK/module"
for f in daemon.log config/adfr_lock.log config/adfr_lock_state.txt          config/mode.txt config/rmx5200_display_policy.txt          config/rmx5200_adfr_mode.txt config/rmx5200_ltpo_daily_idle.txt          config/rmx5200_aod_duration.txt config/game_assistant_apps.txt          config/game_assistant_features.txt config/display_backend.txt          config/display_mode_backend.txt; do
  [ -f "$MODDIR/$f" ] && cp "$MODDIR/$f" "$WORK/module/" 2>/dev/null
done
[ -d "$MODDIR/config/auth" ] && {
  # 授权状态全量保留；package.previous 只留配置/日志/脚本供诊断，跳过二进制。
  mkdir -p "$WORK/module/auth"
  cp -a "$MODDIR/config/auth/"*.json "$MODDIR/config/auth/"*.hex         "$MODDIR/config/auth/"*.txt "$WORK/module/auth/" 2>/dev/null
  for sub in package package.previous; do
    [ -d "$MODDIR/config/auth/$sub" ] || continue
    (cd "$MODDIR/config/auth" && find "$sub" -type f         ! -name "*.ko" ! -name "*.so" ! -name "*.apk" ! -name "*.img"         ! -name "*.idsig" ! -name "rate_daemon_premium"         ! -name "surfaceflinger.*" ! -name "dtbo*" -print)         > "$WORK/module/auth/$sub.list" 2>/dev/null
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      mkdir -p "$WORK/module/auth/$(dirname "$rel")" 2>/dev/null
      cp "$MODDIR/config/auth/$rel" "$WORK/module/auth/$rel" 2>/dev/null
    done < "$WORK/module/auth/$sub.list"
  done
}
ls -la "$MODDIR/bin" "$MODDIR/premium/bin" > "$WORK/module/binaries.txt" 2>/dev/null
# ColorOS 刷新率/分辨率策略配置与运行状态（排查分辨率/DPI 振荡类问题：
# 挂载冲突、配置内容、生效设置值一包看全）。
for f in config/coloros/refresh_rate_config.xml config/coloros/oplus_vrr_config.json          config/custom_refresh_rates.txt; do
  [ -f "$MODDIR/$f" ] && mkdir -p "$WORK/module/$(dirname "$f")" &&         cp "$MODDIR/$f" "$WORK/module/$f" 2>/dev/null
done
[ -d "$MODDIR/runtime/coloros_config" ] &&         cp -a "$MODDIR/runtime/coloros_config" "$WORK/module/coloros_config_runtime" 2>/dev/null
{
  echo "user_preferred_screen_index=$(settings get secure user_preferred_screen_index 2>/dev/null)"
  echo "oplus_customize_screen_resolution_adjust=$(settings get secure oplus_customize_screen_resolution_adjust 2>/dev/null)"
  echo "user_preferred_resolution_width=$(settings get global user_preferred_resolution_width 2>/dev/null)"
  echo "user_preferred_resolution_height=$(settings get global user_preferred_resolution_height 2>/dev/null)"
  echo "peak_refresh_rate=$(settings get system peak_refresh_rate 2>/dev/null)"
  echo "min_refresh_rate=$(settings get system min_refresh_rate 2>/dev/null)"
} > "$WORK/module/resolution_settings.txt" 2>/dev/null
wm size > "$WORK/module/wm_size.txt" 2>/dev/null || true
wm density > "$WORK/module/wm_density.txt" 2>/dev/null || true

# UI 判定链现场证据：handler 实际输出（含 stderr）、安装版脚本指纹、
# 语法检查、CRLF 检查——定位"待重启"误显示的关键段。
WH="$MODDIR/scripts/web_handler.sh"
{
  echo "--- get_display_policy (stdout+stderr) ---"
  sh "$WH" get_display_policy 2>&1
  echo "--- sh -n syntax ---"
  sh -n "$WH" 2>&1 && echo syntax_ok || echo SYNTAX_FAIL
  echo "--- CRLF check ---"
  head -c 400 "$WH" | od -c | grep -m1 '\r' && echo HAS_CRLF || echo no_crlf
  echo "--- active-check fingerprint ---"
  grep -n "generic_adfr/active" "$WH" 2>/dev/null
  grep -c "PREMIUM_PATH/runtime/generic_adfr/active" "$WH" 2>/dev/null
  echo "--- version ---"
  grep -E "^(version|versionCode)=" "$MODDIR/module.prop" 2>/dev/null
} > "$WORK/module/display_policy_live.txt" 2>/dev/null


# props 禁用方案现场诊断：boot_id 对比、marker 新旧、gate 实测、现场重跑 apply
GA_DIR="$MODDIR/premium/runtime/generic_adfr"
{
  echo "current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
  echo "marker_boot_id=$(cat "$GA_DIR/active" 2>/dev/null)"
  [ "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" = "$(cat "$GA_DIR/active" 2>/dev/null)" ] && echo marker_current=yes || echo marker_current=NO_STALE
  ls -la "$GA_DIR" 2>/dev/null
  echo "--- gate_check live ---"
  . "$MODDIR/scripts/display_license_gate.sh" 2>/dev/null
  gate_check adfr_disable >/dev/null 2>&1; echo "gate_check_adfr_rc=$?"
  echo "--- resetprop ---"
  command -v resetprop 2>/dev/null; ls -la /data/adb/ksu/bin/resetprop 2>/dev/null || echo no_ksu_resetprop
  echo "--- live apply rerun ---"
  sh "$MODDIR/premium/scripts/generic_adfr_policy.sh" apply 2>&1 | head -5
  echo "apply_rc=$?"
  echo "status_after=$(cat "$GA_DIR/status.txt" 2>/dev/null)"
  echo "marker_after=$(cat "$GA_DIR/active" 2>/dev/null)"
  echo "--- module_notices ---"
  cat "$MODDIR/config/module_notices.txt" 2>/dev/null
} > "$WORK/module/generic_adfr_live.txt" 2>/dev/null

# pixelworks æ¸¸æå¢å¼ºéç½®å¨æï¼åæºåååä¸åï¼éè¦ç»æå¯¹æ¯ï¼
for f in /my_product/vendor/etc/multimedia_pixelworks_game_apps.xml          /vendor/etc/multimedia_pixelworks_game_apps.xml; do
  [ -f "$f" ] && cp "$f" "$WORK/module/" 2>/dev/null && break
done
if [ -f "$WORK/module/multimedia_pixelworks_game_apps.xml" ]; then
  {
    echo "filter-name: $(grep -m1 'filter-name' "$WORK/module/multimedia_pixelworks_game_apps.xml")"
    grep -oE '<mConfig[A-Za-z]+ type="[^"]*">' "$WORK/module/multimedia_pixelworks_game_apps.xml" | sort | uniq -c
  } > "$WORK/module/game_xml_structure.txt" 2>/dev/null
fi
dumpsys activity service com.android.systemui aod_display > "$WORK/module/systemui_aod.txt" 2>/dev/null
sh "$MODDIR/scripts/web_handler.sh" get_display_policy > "$WORK/module/policy_state.txt" 2>/dev/null
sh "$MODDIR/scripts/web_handler.sh" get_ltpo_daily_idle >> "$WORK/module/policy_state.txt" 2>/dev/null
sh "$MODDIR/scripts/web_handler.sh" get_ltpo_aod_duration >> "$WORK/module/policy_state.txt" 2>/dev/null

echo "==> premium 状态与机型探测"
mkdir -p "$WORK/module/premium_config" "$WORK/display" 2>/dev/null
for f in "$MODDIR/premium/config/adfr_lock_state.txt"          "$MODDIR/premium/config/adfr_lock.log"          "$MODDIR/premium/config/adfr_lock/oti_pause_last"          "$MODDIR/premium/config/adfr_lock/oti_pause_owner"; do
  [ -f "$f" ] && cp "$f" "$WORK/module/premium_config/" 2>/dev/null
done
[ -d "$MODDIR/premium/runtime/generic_adfr" ] &&   cp -a "$MODDIR/premium/runtime/generic_adfr" "$WORK/module/premium_config/" 2>/dev/null
{
  echo "lsmod_plq110=$(lsmod 2>/dev/null | grep -c plq110_adfr_lock)"
  echo "lsmod_rmx_adfr=$(lsmod 2>/dev/null | grep -c rmx5200_adfr_lock)"
  echo "my_product_game_xml=$(ls -la /my_product/vendor/etc/multimedia_pixelworks_game_apps.xml 2>/dev/null || echo missing)"
  echo "vendor_game_xml=$(ls -la /vendor/etc/multimedia_pixelworks_game_apps.xml 2>/dev/null || echo missing)"
  echo "oplus_display_nodes:"; ls /sys/kernel/oplus_display/ 2>/dev/null | head -40
} > "$WORK/module/premium_config/probe.txt" 2>/dev/null

echo "===> xml/files probe (game config discovery)"
for d in /my_product/vendor/etc /my_product/etc /vendor/etc /odm/etc /odm/vendor/etc /data/system; do
    ls -la "$d" 2>/dev/null | grep -iE "xml" | sed "s|^|$d/|" >> "$WORK/module/premium_config/probe.txt"
done
find /my_product /vendor /odm /product -maxdepth 5 \( -iname "*pixelworks*" -o -iname "*multimedia*game*" -o -iname "*multimedia*frame*" \) 2>/dev/null >> "$WORK/module/premium_config/probe.txt"
ls -la /data/system 2>/dev/null | grep -iE "multimedia|pixelworks" >> "$WORK/module/premium_config/probe.txt"

echo "==> DRM åç«¯ç¶æï¼drm.ko æ¥éè¯æ­ï¼"
mkdir -p "$WORK/module/display_backend" 2>/dev/null
for f in "$MODDIR/runtime/display_backend/runtime.log"          "$MODDIR/runtime/display_backend/state.txt"          "$MODDIR/runtime/drm_modes.txt"          "$MODDIR/runtime/custom_drm_modes.txt"; do
  [ -f "$f" ] && cp "$f" "$WORK/module/display_backend/" 2>/dev/null
done
{
  echo "drm_module_loaded=$(ls /sys/module/rmx5200_drm_modes/parameters/applied >/dev/null 2>&1 && echo yes || echo no)"
  for p in applied cache_applied failure_code mode_count_after mode_count_before injected_mode_count removed_stock_fhd_count removed_stock_fhd_drm_count; do
    echo "$p=$(cat /sys/module/rmx5200_drm_modes/parameters/$p 2>/dev/null || echo -)"
  done
} > "$WORK/module/display_backend/drm_params.txt" 2>/dev/null
ls -la "$MODDIR/runtime/" > "$WORK/module/display_backend/runtime_listing.txt" 2>/dev/null

echo "===> kcore CRC extractor (definitive: reads __kcrctab from live kernel)"
KC=/proc/kcore
KS=/proc/kallsyms
NEED_SYMS="module_layout memset _printk copy_from_kernel_nofault ksize strchr drm_mode_destroy drm_kms_helper_connector_hotplug_event drm_kms_helper_hotplug_event of_find_node_by_name of_get_property param_get_bool param_ops_ulong param_ops_uint param_ops_ullong param_ops_string param_ops_bool register_kprobe unregister_kprobe kstrtobool kstrtouint kstrtoull mutex_lock mutex_unlock __kmalloc kfree memcpy kmemdup"
if [ ! -r "$KC" ]; then echo "kcore_unreadable"; else
  echo "kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)"
  PHOFF=$(od -An -tu8 -j32 -N8 "$KC" 2>/dev/null | tr -d " ")
  PHENT=$(od -An -tu2 -j54 -N2 "$KC" 2>/dev/null | tr -d " ")
  PHNUM=$(od -An -tu2 -j56 -N2 "$KC" 2>/dev/null | tr -d " ")
  echo "kcore phoff=$PHOFF phent=$PHENT phnum=$PHNUM"
  read_kcore32()
  {
    AHEX=$1; VAL=""
    i=0
    while [ "$i" -lt "$PHNUM" ]; do
      PO=$(($PHOFF + i * $PHENT))
      PT=$(od -An -tu4 -j"$PO" -N4 "$KC" 2>/dev/null | tr -d " ")
      if [ "$PT" = "1" ]; then
        POFF=$(od -An -tx8 -j$((PO + 8)) -N8 "$KC" 2>/dev/null | tr -d " ")
        PV=$(od -An -tx8 -j$((PO + 16)) -N8 "$KC" 2>/dev/null | tr -d " ")
        PSZ=$(od -An -tu8 -j$((PO + 32)) -N8 "$KC" 2>/dev/null | tr -d " ")
        if [ "${AHEX}" \> "${PV}" ] && [ "${AHEX}" != "${PV}" ]; then
          case "$AHEX" in "$PV"*) ;; esac
        fi
        if [ "$AHEX" \> "$PV" ] 2>/dev/null || [ "$AHEX" = "$PV" ]; then
          D=$(($AHEX - 16#$PV))
          if [ "$D" -ge 0 ] && [ "$D" -lt "$PSZ" ]; then
            VAL=$(od -An -tx1 -j$(($POFF + D)) -N4 "$KC" 2>/dev/null | tr -d " 
")
            break
          fi
        fi
      fi
      i=$((i + 1))
    done
    echo "$VAL"
  }
  for sym in $NEED_SYMS; do
    AHEX=$(grep -w "__crc_$sym" "$KS" 2>/dev/null | head -1 | cut -d" " -f1)
    case "$AHEX" in ""|*[*!-]*) echo "$sym: kallsyms_no_addr"; continue;; esac
    while [ ${#AHEX} -lt 16 ]; do AHEX="0$AHEX"; done
    V=$(read_kcore32 "$AHEX")
    case "$V" in "") echo "$sym: kcore_read_fail"; continue;; esac
    echo "$sym: kcrc_bytes=$V"
  done
fi

echo "===> pstore (persist kernel console)"
mkdir -p "$WORK/pstore"
cp -a /sys/fs/pstore/* "$WORK/pstore/" 2>/dev/null || true
grep -aiE "insmod|plq110|adfr_lock|vermagic|signature|Unknown symbol|disagrees" "$WORK"/pstore/console-ramoops* 2>/dev/null | tail -40 > "$WORK/pstore/insmod_hints.txt" || true

echo "===> kernel log (insmod/adfr errors here)"
dmesg > "$WORK/kmsg_full.txt" 2>/dev/null || true
dmesg | tail -400 > "$WORK/kmsg_tail.txt" 2>/dev/null || true
dmesg | grep -iE "insmod|plq110|adfr|module|vermagic|signature" | tail -80 > "$WORK/kmsg_module.txt" 2>/dev/null || true

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
