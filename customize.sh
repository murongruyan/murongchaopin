#!/system/bin/sh
SKIPUNZIP=0

# 延迟输出函数（带错误流重定向）
Outputs() {
  echo "$@" >&2
  sleep 0.07
}

# KernelSU extracts ordinary files as 0644 before sourcing customize.sh.
# Restore only the tools required by both install backends before either one
# performs DTBO work.
Prepare_install_tools() {
  for relative_path in \
    avbtool/avbtool openssl dtc mkdtimg unpack_dtbo process_dts pack_dtbo; do
    install_tool="$BIN_DIR/$relative_path"
    [ -f "$install_tool" ] || return 1
    chmod 0755 "$install_tool" || return 1
  done
}

# 音量键检测：沿用原来的单事件读取，不设超时或默认值。
Read_volume_key() {
  local choose
  while :; do
    choose=$(getevent -qlc 1 2>/dev/null | awk -F' ' \
      '/KEY_VOLUME(UP|DOWN)/ {print $3; exit}')
    case "$choose" in
      KEY_VOLUMEUP|KEY_VOLUMEDOWN)
        echo "$choose"
        return 0
        ;;
    esac
  done
}

Volume_key_monitoring() {
  case "$(Read_volume_key)" in
    KEY_VOLUMEUP) echo 0 ;;
    KEY_VOLUMEDOWN) echo 1 ;;
    *) echo 1 ;;
  esac
}

# 安装阶段选择应用后端。原厂基线确认与后端选择必须是两次明确操作；
# 后端选择必须由用户明确完成，绝不默认写入 DTBO，避免用户只确认原厂基线
# 后发生隐式修改。这里不设选择倒计时，避免用户阅读提示期间被取消或误判。
Install_backend_selection() {
  case "${MURONGCHAOPIN_INSTALL_BACKEND:-}" in
    dtbo|drm)
      INSTALL_BACKEND="$MURONGCHAOPIN_INSTALL_BACKEND"
      return 0
      ;;
  esac

  # This function is called normally rather than through $(...). Keep prompts
  # on stdout so KernelSU streams the second step to the installer UI.
  ui_print "第二次确认：请选择首次应用后端:"
  ui_print "- 按 音量+ 选择 DTBO（本次安装会生成、合成并写入修改后的 DTBO）"
  ui_print "- 按 音量- 选择 DRM-KO（高刷由 KO 注入；PJD110 仅写入配套解容 DTBO）"
  case "$(Read_volume_key)" in
    KEY_VOLUMEUP) INSTALL_BACKEND=dtbo ;;
    KEY_VOLUMEDOWN) INSTALL_BACKEND=drm ;;
    *) INSTALL_BACKEND=cancel ;;
  esac
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
ui_print "- 请按 音量+ 确认当前是官方原版 DTBO（这里只确认基线，不会单独修改）"
ui_print "- 请按 音量- 退出安装"

# 使用新的音量键检测函数
choose_key=$(Volume_key_monitoring)

if [ "$choose_key" = "1" ]; then
  abort "用户取消安装"
fi

ui_print "确认继续安装..."
# 第一次按键只负责确认原厂基线。等待抬起事件结束后，再进入第二次选择。
sleep 1

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
WORK_DIR="$MOD_PATH/workspace"
MODULE_ID="murongchaopin"
INSTALLED_MOD_PATH="/data/adb/modules/$MODULE_ID"
STOCK_DTBO="$IMG_DIR/dtbo.img"
STOCK_MANIFEST="$IMG_DIR/dtbo.img.sha256"
STOCK_RECOVERY="$IMG_DIR/dtbo.img.gz"
DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"

[ -f "$MODPATH/scripts/dtbo_avb.sh" ] && . "$MODPATH/scripts/dtbo_avb.sh" || abort "缺少 DTBO AVB 处理脚本"

# KernelSU/Magisk updates are extracted into modules_update while the current
# module is still available below modules/. Preserve only user-owned state;
# runtime/ is intentionally regenerated on the next boot.
preserve_installed_file() {
  _relative_path="$1"
  _source_file="$INSTALLED_MOD_PATH/$_relative_path"
  _target_file="$MODPATH/$_relative_path"
  [ "$INSTALLED_MOD_PATH" != "$MODPATH" ] || return 0
  [ -f "$_source_file" ] && [ ! -L "$_source_file" ] || return 0
  mkdir -p "$(dirname "$_target_file")" || abort "无法创建更新迁移目录"
  cp -p "$_source_file" "$_target_file" || abort "无法保留用户配置: $_relative_path"
}

for USER_STATE_FILE in \
  config/mode.txt \
  config/drm_phy_profile.txt \
  config/rmx5200_adfr_mode.txt \
  config/rmx5200_display_policy.txt \
  config/auth/account.json \
  config/auth/lease.json \
  config/auth/package.json \
  config/auth/state.json \
  config/auth/device_id.txt; do
  preserve_installed_file "$USER_STATE_FILE"
done

# The paid package is downloaded and verified independently of the public base
# ZIP. A base-module update must not force an authorized user to download it
# again. Package validation rejects symlinks before installation, and this copy
# only accepts the root-owned installed directory with its signed manifest.
if [ "$INSTALLED_MOD_PATH" != "$MODPATH" ] && \
   [ -d "$INSTALLED_MOD_PATH/premium" ] && \
   [ ! -L "$INSTALLED_MOD_PATH/premium" ] && \
   [ -f "$INSTALLED_MOD_PATH/premium/manifest.json" ]; then
  rm -rf "$MODPATH/premium"
  cp -a "$INSTALLED_MOD_PATH/premium" "$MODPATH/premium" || \
    abort "无法保留已安装的付费资源包"
fi

DTBO_PARTITION_IMAGE_SIZE=$(blockdev --getsize64 "$DTBO_PARTITION" 2>/dev/null)
case "$DTBO_PARTITION_IMAGE_SIZE" in
  ""|*[!0-9]*|0)
    abort "无法读取 DTBO 分区大小"
    ;;
esac

mkdir -p "$IMG_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$BIN_DIR/dtbo_dts"
Prepare_install_tools || abort "显示后端工具缺失或无法设置执行权限"

# 4. 原厂备份只创建一次；更新安装时必须保留已验证的原厂基线。
# 当前分区可能已经被测试修改，不能无条件写回 img/dtbo.img。
VALID_STOCK_SOURCE=""
for STOCK_CANDIDATE in "$INSTALLED_MOD_PATH/img/dtbo.img" "$STOCK_DTBO"; do
  [ -f "$STOCK_CANDIDATE" ] || continue
  CANDIDATE_MANIFEST="$STOCK_CANDIDATE.sha256"
  CANDIDATE_RECOVERY="$STOCK_CANDIDATE.gz"
  if [ -f "$CANDIDATE_MANIFEST" ]; then
    if ! dtbo_validate_stock_backup "$STOCK_CANDIDATE" "$CANDIDATE_MANIFEST" \
        "$DTBO_PARTITION_IMAGE_SIZE" "$BIN_DIR" >/dev/null 2>&1; then
      dtbo_recover_stock_backup "$STOCK_CANDIDATE" "$CANDIDATE_MANIFEST" \
        "$CANDIDATE_RECOVERY" "$DTBO_PARTITION_IMAGE_SIZE" "$BIN_DIR" \
        >/dev/null 2>&1
    fi
    if dtbo_validate_stock_backup "$STOCK_CANDIDATE" "$CANDIDATE_MANIFEST" \
        "$DTBO_PARTITION_IMAGE_SIZE" "$BIN_DIR" >/dev/null 2>&1; then
      VALID_STOCK_SOURCE="$STOCK_CANDIDATE"
      break
    fi
  elif dtbo_verify_official_image "$STOCK_CANDIDATE" \
      "$DTBO_PARTITION_IMAGE_SIZE" "$BIN_DIR" >/dev/null 2>&1; then
    # 没有哈希清单的候选只能在官方 AVB 完整性通过时使用。
    VALID_STOCK_SOURCE="$STOCK_CANDIDATE"
    break
  fi
  ui_print "警告: 已安装模块的 DTBO 备份无效，不会继续使用"
done

if [ -n "$VALID_STOCK_SOURCE" ]; then
  ui_print "已验证并保留现有原厂 DTBO 备份"
  if [ "$VALID_STOCK_SOURCE" != "$STOCK_DTBO" ]; then
    cp "$VALID_STOCK_SOURCE" "$STOCK_DTBO" || abort "无法保留原厂 DTBO 备份"
  fi
else
  CURRENT_DTBO="$WORK_DIR/install-current.img"
  ui_print "首次建立原厂 DTBO 备份..."
  if ! dd if="$DTBO_PARTITION" of="$CURRENT_DTBO" bs=1 \
      count="$DTBO_PARTITION_IMAGE_SIZE" 2>/dev/null; then
    abort "DTBO 提取失败"
  fi
  if ! dtbo_verify_official_image "$CURRENT_DTBO" "$DTBO_PARTITION_IMAGE_SIZE" \
      "$BIN_DIR"; then
    abort "当前 DTBO 不是可验证的官方原版，已拒绝覆盖原厂备份"
  fi
  mv -f "$CURRENT_DTBO" "$STOCK_DTBO" || abort "无法保存原厂 DTBO 备份"
fi

dtbo_write_stock_manifest "$STOCK_DTBO" "$STOCK_MANIFEST" || \
  abort "无法写入原厂 DTBO 哈希清单"
if ! dtbo_validate_stock_backup "$STOCK_DTBO" "$STOCK_MANIFEST" \
    "$DTBO_PARTITION_IMAGE_SIZE" "$BIN_DIR"; then
  abort "原厂 DTBO 备份完整性校验失败"
fi
dtbo_write_stock_recovery "$STOCK_DTBO" "$STOCK_MANIFEST" "$STOCK_RECOVERY" || \
  abort "无法创建原厂 DTBO 压缩恢复副本"
ui_print "原厂 DTBO 备份: $(dtbo_hash_file "$STOCK_DTBO")"

INSTALL_BACKEND=""
Install_backend_selection
case "$INSTALL_BACKEND" in
  dtbo|drm) ;;
  *) abort "安装后端选择返回了无效值" ;;
esac
mkdir -p "$MODPATH/config"
printf '%s\n' "$INSTALL_BACKEND" > "$MODPATH/config/dts_backend.txt" || \
  abort "无法保存应用后端选择"
ui_print "安装应用后端: $INSTALL_BACKEND"

# 4.1 AVB 信息由 scripts/dtbo_avb.sh 和 unpack_dtbo 共同处理。

# 5. 执行选择的显示后端流程（DRM-KO 不向 DTBO 写高刷 timing）
if [ "$INSTALL_BACKEND" = "dtbo" ]; then
  # 切换到 bin 目录以确保工具能找到相对路径资源
  cd "$BIN_DIR" || abort "无法进入 bin 目录"

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
case "$(getprop ro.product.vendor.model 2>/dev/null)" in
  RMX5200)
    ui_print "RMX5200: 删除目标面板原生 FHD timing，保留 Framework 派生 FHD mode"
    $BIN_DIR/process_dts --rmx5200-drop-stock-fhd
    ;;
  *)
    $BIN_DIR/process_dts
    ;;
esac
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
if ! dtbo_validate_stock_backup "$STOCK_DTBO" "$STOCK_MANIFEST" \
    "$DTBO_PARTITION_IMAGE_SIZE" "$BIN_DIR"; then
  abort "原厂 DTBO 备份已损坏，已停止刷入"
fi
if ! dtbo_apply_stock_avb "$STOCK_DTBO" "$NEW_DTBO" "$FINAL_DTBO" "$DTBO_PARTITION_IMAGE_SIZE" "$BIN_DIR"; then
  abort "官方 AVB 信息复用失败，已停止刷入"
fi

ui_print "正在刷入修改后的 DTBO..."
  if dtbo_write_partition "$FINAL_DTBO" "$DTBO_PARTITION"; then
    ui_print "刷入成功!"
  else
    ui_print "错误: 刷入失败"
    abort
  fi
else
  ui_print "已选择 DRM-KO：高刷 timing 仅由 KO 注入"
  ui_print "正在生成不含显示改动的兼容 DTBO（PJD110 含解容）..."
  if sh "$MODPATH/scripts/hmbird_backend.sh" prepare-dtbo "$DTBO_PARTITION"; then
    ui_print "KO 配套 DTBO 写入成功，原厂显示 timing 保持不变"
  else
    abort "KO 配套 DTBO 生成或写入失败"
  fi
fi

# 7. AVB 处理已在 DTBO 应用分支完成。

# 显示设置 Hook 是独立的 API 102 APK。通过 stdin 安装可避免 Package
# Installer 无法直接读取 /data/adb/modules 下文件的 SELinux 路径问题。
DISPLAY_HOOK_APK="$BIN_DIR/display_settings_hook.apk"
if [ -f "$DISPLAY_HOOK_APK" ]; then
  DISPLAY_HOOK_SIZE=$(wc -c < "$DISPLAY_HOOK_APK" 2>/dev/null | tr -d '[:space:]')
  case "$DISPLAY_HOOK_SIZE" in
    ""|*[!0-9]*)
      ui_print "警告: 无法读取 API 102 Hook APK 大小，跳过安装"
      ;;
    *)
      if cat "$DISPLAY_HOOK_APK" | pm install -r -d -S "$DISPLAY_HOOK_SIZE" \
          >/dev/null 2>&1; then
        ui_print "已安装 libxposed API 102 显示设置 Hook"
        ui_print "静态作用域: system_server / 系统设置 / 游戏助手 / Scene"
      else
        ui_print "警告: API 102 Hook APK 安装失败，模块主体继续安装"
      fi
      ;;
  esac
fi

# Pixelworks/MEMC 固件补丁已拆入付费包（premium/scripts/）。付费包在
# 开机时由 premium_post_fs_data.sh 按授权执行 install-payload，安装阶段
# 不再处理任何 premium 载荷。免费 Hook 仍在上面安装（display_settings_hook.apk）。

# 更新免费底座时，如果旧模块已经保存了可验证的付费租约和账号 Token，
# 直接为新模块目录下载并原子安装最高兼容版本。首次安装、未授权、离线或
# 服务端异常都只跳过本步骤；已迁移的旧付费包和基础模块安装结果不会丢失。
if [ -f "$MODPATH/scripts/web_handler.sh" ] &&
   [ -s "$MODPATH/config/auth/lease.json" ] &&
   [ -s "$MODPATH/config/auth/account.json" ]; then
  ui_print "正在检查已授权账号的最新付费组件..."
  PAID_AUTO_RESULT=$(MURONGCHAOPIN_MOD_PATH="$MODPATH" \
    sh "$MODPATH/scripts/web_handler.sh" auth_install_latest 2>&1)
  PAID_AUTO_STATUS=$(printf '%s\n' "$PAID_AUTO_RESULT" |
    sed -n 's/^status=//p' | tail -n 1)
  PAID_AUTO_VERSION=$(printf '%s\n' "$PAID_AUTO_RESULT" |
    sed -n 's/^version=//p' | tail -n 1)
  case "$PAID_AUTO_STATUS" in
    updated)
      ui_print "付费组件已自动更新至 ${PAID_AUTO_VERSION:-最新版}，重启后生效"
      ;;
    current)
      ui_print "付费组件已是最新版本 ${PAID_AUTO_VERSION}"
      ;;
    skipped)
      ui_print "未检测到可自动续装的有效付费授权，继续安装免费底座"
      ;;
    *)
      ui_print "付费组件自动更新暂不可用，已保留现有组件并继续安装"
      ;;
  esac
fi

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
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/post-mount.sh" 0 0 0755
set_perm "$MODPATH/late-load.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
[ ! -d "$MODPATH/config/auth" ] || \
  set_perm_recursive "$MODPATH/config/auth" 0 0 0700 0600
if [ -d "$MODPATH/premium" ]; then
  set_perm_recursive "$MODPATH/premium" 0 0 0755 0644
  [ ! -d "$MODPATH/premium/bin" ] || \
    set_perm_recursive "$MODPATH/premium/bin" 0 0 0755 0755
  [ ! -d "$MODPATH/premium/scripts" ] || \
    set_perm_recursive "$MODPATH/premium/scripts" 0 0 0755 0755
fi
set_perm "$STOCK_DTBO" 0 0 0444
set_perm "$STOCK_MANIFEST" 0 0 0444
set_perm "$STOCK_RECOVERY" 0 0 0444
