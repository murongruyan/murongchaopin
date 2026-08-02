#!/system/bin/sh
SKIPUNZIP=0

# 延迟输出函数（带错误流重定向）
Outputs() {
  echo "$@" >&2
  sleep 0.07
}

# 音量键检测优化（超时+事件过滤）
Volume_key_monitoring() {
  local choose
  # 设置10秒超时防止卡死
  timeout=100
  while [ $timeout -gt 0 ]; do
    # 精确匹配按键事件
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

# 安装/更新模块函数
install_module() {
    local MODULE_PATH="$1"
    
    # 检查模块文件是否存在
    if [ ! -f "$MODULE_PATH" ]; then
        ui_print "错误：模块文件不存在 - $MODULE_PATH"
        return 1
    fi

    ui_print "正在安装模块: $(basename "$MODULE_PATH")"

    # 检查Magisk/KSU/APD
    if command -v magisk >/dev/null 2>&1; then
        ui_print "使用Magisk安装模块..."
        magisk --install-module "$MODULE_PATH"
    elif command -v ksud >/dev/null 2>&1; then
        ui_print "使用KernelSU安装模块..."
        ksud module install "$MODULE_PATH"
    elif command -v apd >/dev/null 2>&1; then
        ui_print "使用APatch安装模块..."
        apd module install "$MODULE_PATH"
    else
        ui_print "错误：未找到支持的模块安装器（Magisk/KSU/APD）"
        return 1
    fi

    # 检查是否安装成功
    local install_status=$?
    if [ $install_status -eq 0 ]; then
        ui_print "模块安装成功！"
        return 0
    else
        ui_print "模块安装失败，退出码: $install_status"
        return 1
    fi
}

# 1. 提示确认
ui_print "=============================="
ui_print "    真我GT8 Pro DTBO 超频模块    "
ui_print "=============================="

# 按键确认
ui_print "- 请按 音量+ 确认是官方原版DTBO"
ui_print "- 请按 音量- 退出安装"

# 使用新的音量键检测函数
choose_key=$(Volume_key_monitoring)

if [ "$choose_key" = "1" ]; then
  abort "用户取消安装"
fi

ui_print "确认继续安装..."

# 2. 检测当前 Slot
SLOT=$(getprop ro.boot.slot_suffix)
if [ -z "$SLOT" ]; then
  ui_print "错误: 无法获取当前 Slot 分区信息"
  abort
fi
ui_print "检测到当前分区槽位: $SLOT"

# 3. 准备路径
MOD_PATH="$MODPATH"
BIN_DIR="$MOD_PATH/bin"
IMG_DIR="$MOD_PATH/img"
DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"

[ -f "$MODPATH/scripts/dtbo_avb.sh" ] && . "$MODPATH/scripts/dtbo_avb.sh" || abort "缺少 DTBO AVB 处理脚本"

DTBO_PARTITION_IMAGE_SIZE=$(blockdev --getsize64 "$DTBO_PARTITION" 2>/dev/null)
case "$DTBO_PARTITION_IMAGE_SIZE" in
  ""|*[!0-9]*|0)
    abort "无法读取 DTBO 分区大小"
    ;;
esac

mkdir -p "$IMG_DIR"
mkdir -p "$BIN_DIR/dtbo_dts"

# 4. 提取 DTBO
ui_print "正在提取当前 DTBO..."
if dd if="$DTBO_PARTITION" of="$IMG_DIR/dtbo.img" bs=1 count="$DTBO_PARTITION_IMAGE_SIZE" 2>/dev/null; then
  ui_print "DTBO 提取成功: $IMG_DIR/dtbo.img"
else
  ui_print "错误: DTBO 提取失败"
  abort
fi
if [ "$(dtbo_file_size "$IMG_DIR/dtbo.img")" != "$DTBO_PARTITION_IMAGE_SIZE" ]; then
  abort "DTBO 备份大小校验失败"
fi

# 4.1 提取 AVB 信息 (已集成到 unpack_dtbo)
# ui_print "正在提取 AVB 信息..."
# ... (Removed manual extraction logic)

# 5. 执行处理流程
# 切换到 bin 目录以确保工具能找到相对路径资源
cd "$BIN_DIR" || abort "无法进入 bin 目录"

# 赋予执行权限
chmod +x *

# (1) 解包
ui_print "正在解包 DTBO..."
# 注意：unpack_dtbo 已经修改为接受输入文件参数
$BIN_DIR/unpack_dtbo "../img/dtbo.img"
if [ $? -ne 0 ]; then
  ui_print "错误: 解包失败"
  abort
fi

# (2) 超频修改
ui_print "正在应用超频修改..."
$BIN_DIR/process_dts
if [ $? -ne 0 ]; then
  ui_print "错误: 修改 DTS 失败"
  abort
fi

# (3) 打包
ui_print "正在重新打包 DTBO..."
$BIN_DIR/pack_dtbo
if [ $? -ne 0 ]; then
  ui_print "错误: 打包失败"
  abort
fi

# 检查新镜像
NEW_DTBO="$BIN_DIR/new_dtbo.img"
if [ ! -f "$NEW_DTBO" ]; then
  ui_print "错误: 未找到生成的 new_dtbo.img"
  abort
fi

# 6. 使用官方 DTBO 的 AVB 信息合成免解镜像
FINAL_DTBO="$BIN_DIR/dtbo_final.img"
if ! dtbo_apply_stock_avb "$IMG_DIR/dtbo.img" "$NEW_DTBO" "$FINAL_DTBO" "$DTBO_PARTITION_IMAGE_SIZE"; then
  abort "官方 AVB 信息复用失败，已停止刷入"
fi

ui_print "正在刷入修改后的 DTBO..."
if dtbo_write_partition "$FINAL_DTBO" "$DTBO_PARTITION"; then
  ui_print "刷入成功!"
else
  ui_print "错误: 刷入失败"
  abort
fi

# 7. 处理 AVB (已集成到上方)
# ui_print "正在处理 AVB 校验..."
# AVB_MODULE="$MOD_PATH/avb_patch.zip"
# ... (Removed legacy logic)

# 清理临时文件（可选，建议保留以便调试）
# ui_print "清理临时文件..."
# rm -rf "$IMG_DIR"
# rm -rf "$BIN_DIR/dtbo_dts"
# rm -f "$BIN_DIR/new_dtbo.img"

ui_print "=============================="
ui_print "          安装完成            "
ui_print "    请重启手机以生效          "
ui_print "=============================="

# 设置模块文件权限
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755