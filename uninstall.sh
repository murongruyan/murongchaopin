#!/system/bin/sh

# 卸载脚本 - 真我GT8 Pro DTBO 超频模块

# 设置模块路径
MODPATH="$1"
BIN_DIR="$MODPATH/bin"
STOCK_MANIFEST="$MODPATH/img/dtbo.img.sha256"
STOCK_RECOVERY="$MODPATH/img/dtbo.img.gz"

[ -f "$MODPATH/scripts/dtbo_avb.sh" ] && . "$MODPATH/scripts/dtbo_avb.sh"

# 延迟输出函数
ui_print() {
  echo "$@" >&2
  sleep 0.07
}

# 音量键检测（与安装脚本保持一致）
Volume_key_monitoring() {
  local choose
  timeout=100
  while [ $timeout -gt 0 ]; do
    choose=$(getevent -qlc 1 | awk -F' ' '/KEY_VOLUME(UP|DOWN)/ {print $3; exit}')
    case "$choose" in
      KEY_VOLUMEUP) echo 0; return 0 ;;
      KEY_VOLUMEDOWN) echo 1; return 0 ;;
    esac
    timeout=$((timeout - 1))
    sleep 0.1
  done
  echo 1
}

# 卸载确认
ui_print "=============================="
ui_print "  真我GT8 Pro DTBO 超频模块卸载  "
ui_print "=============================="
ui_print ""
ui_print "警告: 此操作将恢复原始 DTBO 分区"
ui_print "      这可能会取消您的超频设置"
ui_print ""
ui_print "- 按 音量+ 确认卸载并恢复原版"
ui_print "- 按 音量- 取消卸载（保持修改）"

choose_key=$(Volume_key_monitoring)

if [ "$choose_key" = "1" ]; then
  ui_print "用户取消卸载"
  ui_print "模块修改将保持生效"
  exit 0
fi

ui_print "开始卸载..."

restore_runtime_state() {
  # Stop processes that can recreate a bind mount while it is being removed.
  pkill -f "$MODPATH/premium/scripts/libpwiris_memc_gate_patch.sh watch-final-view" \
    >/dev/null 2>&1 || true
  pkill -f "$MODPATH/scripts/libpwiris_memc_gate_patch.sh watch-final-view" \
    >/dev/null 2>&1 || true
  pkill -f "$MODPATH/scripts/display_settings_bridge.sh watch" \
    >/dev/null 2>&1 || true

  # Free VRR + refresh-rate overlay (MEMC overlay now lives in the paid package).
  [ ! -f "$MODPATH/scripts/coloros_config.sh" ] ||
    sh "$MODPATH/scripts/coloros_config.sh" remove >/dev/null 2>&1 || true
  [ ! -f "$MODPATH/scripts/surfaceflinger_ltps_vote_patch.sh" ] ||
    sh "$MODPATH/scripts/surfaceflinger_ltps_vote_patch.sh" restore \
      >/dev/null 2>&1 || true

  # Paid helpers live under premium/. Restore each only while the paid package
  # is still present; a removed premium/ is a no-op.
  PREMIUM_SCRIPTS="$MODPATH/premium/scripts"
  [ ! -f "$PREMIUM_SCRIPTS/coloros_config_premium.sh" ] ||
    sh "$PREMIUM_SCRIPTS/coloros_config_premium.sh" remove-premium >/dev/null 2>&1 || true
  [ ! -f "$PREMIUM_SCRIPTS/libpwiris_memc_gate_patch.sh" ] ||
    sh "$PREMIUM_SCRIPTS/libpwiris_memc_gate_patch.sh" restore >/dev/null 2>&1 || true
  [ ! -f "$PREMIUM_SCRIPTS/premium_system_overlay.sh" ] ||
    sh "$PREMIUM_SCRIPTS/premium_system_overlay.sh" remove >/dev/null 2>&1 || true
  [ ! -f "$PREMIUM_SCRIPTS/surfaceflinger_ltpo_rise_patch.sh" ] ||
    sh "$PREMIUM_SCRIPTS/surfaceflinger_ltpo_rise_patch.sh" restore >/dev/null 2>&1 || true
  [ ! -f "$PREMIUM_SCRIPTS/surfaceflinger_vote_patch.sh" ] ||
    sh "$PREMIUM_SCRIPTS/surfaceflinger_vote_patch.sh" restore >/dev/null 2>&1 || true
  [ ! -f "$PREMIUM_SCRIPTS/adfr_lock.sh" ] ||
    sh "$PREMIUM_SCRIPTS/adfr_lock.sh" restore >/dev/null 2>&1 || true
  [ ! -f "$PREMIUM_SCRIPTS/generic_adfr_policy.sh" ] ||
    sh "$PREMIUM_SCRIPTS/generic_adfr_policy.sh" restore >/dev/null 2>&1 || true
}

# 检查备份文件是否存在
# 优先检查 img/dtbo.img (新版路径)，兼容 backup_dtbo.img (旧版路径)
if [ -f "$MODPATH/img/dtbo.img" ] || \
   { [ -f "$STOCK_MANIFEST" ] && [ -f "$STOCK_RECOVERY" ]; }; then
  BACKUP_DTBO="$MODPATH/img/dtbo.img"
elif [ -f "$MODPATH/backup_dtbo.img" ]; then
  BACKUP_DTBO="$MODPATH/backup_dtbo.img"
else
  ui_print "错误: 未找到原始 DTBO 备份文件"
  ui_print "无法恢复原始 DTBO"
  ui_print ""
  ui_print "您可以手动执行以下操作:"
  ui_print "1. 重启到 Fastboot 模式"
  ui_print "2. 刷入官方固件中的原始 dtbo.img"
  ui_print "3. 或联系模块作者获取帮助"
  exit 1
fi

# 获取当前 Slot（与安装时相同的方式）
SLOT=$(getprop ro.boot.slot_suffix)
if [ -z "$SLOT" ]; then
  ui_print "警告: 无法获取当前 Slot 分区信息"
  ui_print "尝试使用默认分区路径..."
  DTBO_PARTITION="/dev/block/by-name/dtbo"
else
  DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
fi

# 确认分区存在
if [ ! -e "$DTBO_PARTITION" ]; then
  ui_print "错误: 找不到 DTBO 分区: $DTBO_PARTITION"
  exit 1
fi

DTBO_PARTITION_SIZE=$(blockdev --getsize64 "$DTBO_PARTITION" 2>/dev/null)
chmod +x "$BIN_DIR/avbtool/avbtool" "$BIN_DIR/openssl" 2>/dev/null
if [ ! -f "$MODPATH/scripts/dtbo_avb.sh" ]; then
  ui_print "错误: 缺少原厂 DTBO 完整性校验脚本"
  exit 1
fi
if ! dtbo_validate_stock_backup "$BACKUP_DTBO" "$STOCK_MANIFEST" \
    "$DTBO_PARTITION_SIZE" "$BIN_DIR"; then
  dtbo_recover_stock_backup "$BACKUP_DTBO" "$STOCK_MANIFEST" \
    "$STOCK_RECOVERY" "$DTBO_PARTITION_SIZE" "$BIN_DIR" >/dev/null 2>&1
fi
if ! dtbo_validate_stock_backup "$BACKUP_DTBO" "$STOCK_MANIFEST" \
    "$DTBO_PARTITION_SIZE" "$BIN_DIR"; then
  ui_print "错误: 原厂 DTBO 备份未通过哈希和官方 AVB 完整性校验"
  ui_print "为避免把修改版当成原厂版写入，已取消卸载"
  exit 1
fi

# 恢复原始 DTBO
ui_print "正在恢复原始 DTBO..."
ui_print "从: $BACKUP_DTBO"
ui_print "到: $DTBO_PARTITION"

if [ -f "$MODPATH/scripts/dtbo_avb.sh" ]; then
  dtbo_write_partition "$BACKUP_DTBO" "$DTBO_PARTITION"
  RESTORE_STATUS=$?
else
  dd if="$BACKUP_DTBO" of="$DTBO_PARTITION" bs=4096 conv=fsync
  RESTORE_STATUS=$?
fi
if [ "$RESTORE_STATUS" -eq 0 ]; then
  ui_print "原始 DTBO 恢复成功!"

  # Only mutate userspace after the stock partition restore has succeeded.
  # A cancelled or refused uninstall therefore leaves the installed Hook and
  # every active module mount untouched.
  restore_runtime_state
  pm uninstall --user 0 com.murongchaopin.displayhook >/dev/null 2>&1 || true
  pm uninstall --user 0 com.murongchaopin.displayhook.premium >/dev/null 2>&1 || true
  for daemon_pid in $(pidof rate_daemon 2>/dev/null) $(pidof rate_daemon_premium 2>/dev/null); do
    kill "$daemon_pid" >/dev/null 2>&1 || true
  done

  # 清理模块文件（可选）
  ui_print "清理模块文件..."
  rm -rf "$MODPATH/bin"
  rm -rf "$MODPATH/img"
  rm -f "$MODPATH/backup_dtbo.img" 2>/dev/null

  # 付费授权与付费包本地状态一并清除。设计决定：卸载时不向服务器解绑，
  # token/租约绑定关系保留在服务器侧，用户重装后可用原账号重新登录并恢复授权。
  rm -rf "$MODPATH/config/auth"
  rm -rf "$MODPATH/premium"

  # 保留卸载脚本直到下次重启
  ui_print ""
  ui_print "=============================="
  ui_print "        卸载完成              "
  ui_print "    请重启手机以生效          "
  ui_print "=============================="
  ui_print ""
  ui_print "提示: 重启后模块文件将被完全移除"
else
  ui_print "错误: DTBO 恢复失败"
  ui_print "请尝试以下方法:"
  ui_print "1. 检查设备是否已解锁 Bootloader"
  ui_print "2. 检查是否有足够的权限"
  ui_print "3. 手动进入 Recovery 刷入官方 dtbo"
  exit 1
fi

# 安全清理（在重启前保留关键文件）
exit 0
