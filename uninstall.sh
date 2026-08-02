#!/system/bin/sh

# 卸载脚本 - 真我GT8 Pro DTBO 超频模块

# 设置模块路径
MODPATH="$1"

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

# 检查备份文件是否存在
# 优先检查 img/dtbo.img (新版路径)，兼容 backup_dtbo.img (旧版路径)
if [ -f "$MODPATH/img/dtbo.img" ]; then
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
  
  # 清理模块文件（可选）
  ui_print "清理模块文件..."
  rm -rf "$MODPATH/bin"
  rm -rf "$MODPATH/img"
  rm -f "$MODPATH/backup_dtbo.img" 2>/dev/null
  
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