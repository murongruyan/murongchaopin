#!/system/bin/sh
# 慕容显示增强 · 一加 Ace 6（PLQ110）刷新率现场取证
#
# 用途：确认「切到 199/185 档位后，面板实际跑多少 Hz」，以及面板自己的时序表
#       到底声明了哪些档位。只读采集，不改任何显示设置。
#
# 用法（手机终端 / MT管理器终端）：
#   su -c "sh /sdcard/Download/murong-ace6-rate-probe.sh"
#
# 建议顺序（很重要）：
#   1) 打开模块 WebUI →「刷新率」页 → 选到 199Hz；
#   2) 在该页点一次「实测当前刷新率」，等它弹出实测结果；
#   3) 再执行本脚本，产物自动带上刚才的实测值。
#
# 产物：/sdcard/Download/murong-ace6-rate-<时间戳>.tar.gz

MODDIR=""
for cand in /data/adb/modules/*/; do
  [ -f "${cand}module.prop" ] || continue
  if grep -q '^id=murongchaopin$' "${cand}module.prop" 2>/dev/null; then
    MODDIR="${cand%/}"
    break
  fi
done
MODDIR=${MODDIR:-/data/adb/modules/murongchaopin}

STAMP=$(date +%Y%m%d-%H%M%S)
WORK="/sdcard/Download/murong-ace6-rate-$STAMP"
mkdir -p "$WORK" 2>/dev/null

echo "==> 设备与模块"
{
  echo "model=$(getprop ro.product.vendor.model 2>/dev/null)"
  echo "device=$(getprop ro.product.vendor.device 2>/dev/null)"
  echo "os=$(getprop ro.build.display.id 2>/dev/null)"
  echo "kernel=$(uname -r 2>/dev/null)"
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
  echo "uptime=$(uptime 2>/dev/null)"
  head -4 "$MODDIR/module.prop" 2>/dev/null
} > "$WORK/device.txt" 2>/dev/null

echo "==> 刷新率设置（用户选了什么）"
{
  echo "peak_refresh_rate=$(settings get system peak_refresh_rate 2>/dev/null)"
  echo "min_refresh_rate=$(settings get system min_refresh_rate 2>/dev/null)"
  echo "user_refresh_rate=$(settings get system user_refresh_rate 2>/dev/null)"
  echo "default_refresh_rate=$(settings get system default_refresh_rate 2>/dev/null)"
  echo "--- config/mode.txt ---"
  cat "$MODDIR/config/mode.txt" 2>/dev/null
  echo "--- 显示策略 ---"
  sh "$MODDIR/scripts/web_handler.sh" get_display_policy 2>&1 | head -8
} > "$WORK/settings.txt" 2>/dev/null

echo "==> 面板档位表（应用态 DT 声明的 timing）"
{
  for f in /proc/device-tree/fragment@*/__overlay__/*/qcom,mdss-dsi-display-timings \
           /proc/device-tree/soc/*/qcom,mdss-dsi-display-timings; do
    [ -d "$f" ] || continue
    echo "$f:"
    ls "$f" 2>/dev/null
  done
  echo "--- panel name ---"
  cat /proc/device-tree/fragment@*/__overlay__/*/qcom,mdss-dsi-panel-name 2>/dev/null
} > "$WORK/dt_timings.txt" 2>/dev/null

echo "==> 面板/驱动实测值"
{
  ls /sys/kernel/oplus_display/ 2>/dev/null
  echo "--- values ---"
  for n in adfr_config min_fps dump_info test_te test_te_config dynamic_float_te \
           dynamic_osc_clock panel_id esd_status power_status; do
    printf '%s=' "$n"
    cat "/sys/kernel/oplus_display/$n" 2>&1 | head -2
    echo
  done
} > "$WORK/panel_nodes.txt" 2>/dev/null

echo "==> 框架/合成器视图"
{
  echo "--- SurfaceFlinger display modes ---"
  dumpsys SurfaceFlinger 2>/dev/null | grep -E "activeMode=|\{id=.*vsyncRate" | head -40
  echo "--- RefreshRateSelector policy ---"
  dumpsys SurfaceFlinger 2>/dev/null | grep -E "RefreshRateSelector|Ranges|renderRate" | tail -20
  echo "--- dumpsys display ---"
  dumpsys display 2>/dev/null | grep -E "mActiveModeId|mActiveRenderFrameRate|mActiveSfDisplayMode" | head -10
} > "$WORK/framework.txt" 2>/dev/null

echo "==> WebUI 实测结果（若用户点过“实测当前刷新率”）"
cat "$MODDIR/runtime/panel_rate_probe.txt" 2>/dev/null > "$WORK/webui_probe.txt" || echo "no-probe-yet" > "$WORK/webui_probe.txt"
cat "$WORK/webui_probe.txt"

echo "==> 内核显示日志"
dmesg 2>/dev/null | grep -iE "dsi_display_set_mode|ADFR|adfr|iris|panel_cmd|timing-switch" | tail -400 > "$WORK/kmsg_display.txt" 2>/dev/null

echo "==> 打包"
cd /sdcard/Download 2>/dev/null || cd /data/local/tmp
tar -czf "/sdcard/Download/murong-ace6-rate-$STAMP.tar.gz" "$(basename "$WORK")" 2>/dev/null

if [ -f "/sdcard/Download/murong-ace6-rate-$STAMP.tar.gz" ]; then
  echo "完成：/sdcard/Download/murong-ace6-rate-$STAMP.tar.gz"
  echo "把这个压缩包发给开发者即可（上面 webui_probe.txt 里的 requested/measured 是关键证据）。"
else
  echo "打包失败，请把目录 $WORK 整个发给开发者。"
fi
