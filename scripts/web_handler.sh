#!/system/bin/sh
# WebUI Handler Script

MOD_PATH="/data/adb/modules/murongchaopin"
# 自动探测路径
if [ ! -d "$MOD_PATH" ]; then
    MOD_PATH=$(dirname $(dirname "$0"))
fi

BIN_DIR="$MOD_PATH/bin"
IMG_DIR="$MOD_PATH/img"
WORK_DIR="$MOD_PATH/workspace"
CONFIG_FILE="$MOD_PATH/config/mode.txt"
DAEMON_BIN="$BIN_DIR/rate_daemon"
AVB_HELPER="$MOD_PATH/scripts/dtbo_avb.sh"

[ -f "$AVB_HELPER" ] && . "$AVB_HELPER"

mkdir -p "$(dirname "$CONFIG_FILE")"
[ ! -f "$CONFIG_FILE" ] && echo "1" > "$CONFIG_FILE"

# ============================================================
# 阶段化子流程（供 WebUI 日志弹窗分步调用）
#   pack_only   → 仅打包 → new_dtbo.img
#   merge_avb   → 复用官方 VBMeta 合成 → dtbo_final.img（签名）
#   flash_final → 写入分区 + 回读校验
# 每个子命令独立执行、单独返回，前端每步追加一行日志。
# ============================================================

# 阶段 1：打包（仅生成 new_dtbo.img，不刷入）
do_pack() {
    cd "$BIN_DIR" || { echo "错误：无法进入 $BIN_DIR"; return 1; }
    chmod +x * 2>/dev/null

    echo "== 步骤 1/3：打包 DTBO =="
    PACK_LOG="$BIN_DIR/pack.log"
    ./pack_dtbo >"$PACK_LOG" 2>&1
    if [ $? -ne 0 ]; then
        echo "错误：打包失败"
        cat "$PACK_LOG"
        return 1
    fi

    NEW_DTBO="$BIN_DIR/new_dtbo.img"
    if [ ! -f "$NEW_DTBO" ]; then
        NEW_DTBO="$BIN_DIR/dtbo.img"
    fi
    SIZE=$(ls -l "$NEW_DTBO" 2>/dev/null | awk '{print $5}')
    echo "打包工具输出（pack.log）:"
    # 过滤 avbtool 加载 .so 时的 linker DT_RPATH 警告噪音（不影响功能）
    tail -n 20 "$PACK_LOG" 2>/dev/null | grep -v 'WARNING: linker' | sed 's/^/  /'
    echo "生成镜像: $(basename "$NEW_DTBO") ($SIZE 字节)"
    echo "Success: 打包完成: $(basename "$NEW_DTBO")"
    return 0
}

# 阶段 2：合并官方 AVB（签名）
do_merge_avb() {
    SLOT=$(getprop ro.boot.slot_suffix)
    DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"

    NEW_DTBO="$BIN_DIR/new_dtbo.img"
    if [ ! -f "$NEW_DTBO" ]; then
        NEW_DTBO="$BIN_DIR/dtbo.img"
    fi

    STOCK_DTBO="$IMG_DIR/dtbo.img"
    FINAL_DTBO="$BIN_DIR/dtbo_final.img"
    PARTITION_SIZE=$(blockdev --getsize64 "$DTBO_PARTITION" 2>/dev/null)

    echo "== 步骤 2/3：合并官方 AVB 签名 =="
    echo "  目标分区: $DTBO_PARTITION ($PARTITION_SIZE 字节)"
    echo "  官方备份: $(basename "$STOCK_DTBO")"
    echo "  待签名镜像: $(basename "$NEW_DTBO")"

    if [ ! -f "$AVB_HELPER" ]; then
        echo "错误：缺少 DTBO AVB 处理脚本"
        return 1
    fi
    if [ ! -f "$STOCK_DTBO" ]; then
        echo "错误：找不到原厂 DTBO 备份，无法复用官方 AVB 信息"
        return 1
    fi

    echo "正在提取官方 VBMeta 并重算偏移..."
    if ! dtbo_apply_stock_avb "$STOCK_DTBO" "$NEW_DTBO" "$FINAL_DTBO" "$PARTITION_SIZE"; then
        echo "错误：官方 AVB 信息复用失败，未执行刷入（请勿重启，DTBO 分区未被修改）"
        return 1
    fi
    SIZE=$(ls -l "$FINAL_DTBO" 2>/dev/null | awk '{print $5}')
    echo "签名镜像: $(basename "$FINAL_DTBO") ($SIZE 字节)"
    echo "Success: 签名完成: $(basename "$FINAL_DTBO")"
    return 0
}

# 阶段 3：刷入 + 回读校验
do_flash() {
    SLOT=$(getprop ro.boot.slot_suffix)
    DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
    FINAL_DTBO="$BIN_DIR/dtbo_final.img"

    echo "== 步骤 3/3：写入分区并回读校验 =="
    if [ ! -f "$FINAL_DTBO" ]; then
        echo "错误：找不到 dtbo_final.img，请先执行合并步骤"
        return 1
    fi
    SIZE=$(ls -l "$FINAL_DTBO" 2>/dev/null | awk '{print $5}')
    echo "  目标分区: $DTBO_PARTITION"
    echo "  写入镜像: $(basename "$FINAL_DTBO") ($SIZE 字节)"
    if dtbo_write_partition "$FINAL_DTBO" "$DTBO_PARTITION"; then
        echo "Success: 刷入成功！请重启生效。"
        return 0
    else
        echo "错误：刷入失败（分区未被修改）"
        return 1
    fi
}

# 阶段 0（flash_dtbo 专用）：提取→解包→通用补丁→smart_add
do_smart_add() {
    CUSTOM_RATE="$1"
    echo "开始执行超频流程 (Multi-Model Mode)..."
    if [ ! -z "$CUSTOM_RATE" ]; then
        echo "目标自定义刷新率: ${CUSTOM_RATE}Hz"
    fi

    SLOT=$(getprop ro.boot.slot_suffix)
    DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"

    MODEL=$(getprop ro.product.vendor.model)
    TARGET_PANEL=""
    case "$MODEL" in
        "RMX5200") TARGET_PANEL="qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02" ;;
        "PLK110") TARGET_PANEL="qcom,mdss_dsi_panel_AD296_P_3_A0020_dsc_cmd" ;;
        "PJD110") TARGET_PANEL="qcom,mdss_dsi_panel_AA545_P_3_A0005_dsc_cmd" ;;
    esac

    mkdir -p "$WORK_DIR"
    mkdir -p "$BIN_DIR/dtbo_dts"

    echo "1. 提取 DTBO..."
    if dd if="$DTBO_PARTITION" of="$WORK_DIR/dtbo.img" bs=4096 2>&1; then
        echo "提取成功"
    else
        echo "错误：提取失败"
        return 1
    fi

    cd "$BIN_DIR" || return 1
    chmod +x * 2>/dev/null

    echo "2. 解包..."
    ./unpack_dtbo "../workspace/dtbo.img" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "错误：解包失败"
        return 1
    fi

    echo "3. 应用通用补丁..."
    ./process_dts
    RET=$?
    if [ $RET -ne 0 ]; then
        echo "提示：通用补丁未应用或发生错误 (代码 $RET)，但这可能不影响自定义刷新率。"
    fi

    if [ ! -z "$CUSTOM_RATE" ]; then
        echo "3.1 智能添加自定义刷新率 ($CUSTOM_RATE Hz)..."
        if [ ! -z "$TARGET_PANEL" ]; then
            echo "    - 目标面板: $TARGET_PANEL"
        fi
        PRJ_ID=$(getprop ro.boot.prjname)
        echo "    - Project ID: $PRJ_ID"
        ./dts_tool smart_add "$CUSTOM_RATE" "$TARGET_PANEL" "$PRJ_ID"
        if [ $? -eq 0 ]; then
            echo "Success: 自定义刷新率节点已生成。"
        else
            echo "错误：自定义刷新率添加失败！"
            return 1
        fi
    fi
    echo "Success: 超频流程处理完成"
    return 0
}


case "$1" in
    "init_workspace")
        echo "初始化工作区..."
        SLOT=$(getprop ro.boot.slot_suffix)
        DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
        
        mkdir -p "$WORK_DIR"
        mkdir -p "$BIN_DIR/dtbo_dts"
        
        # Always re-extract to be safe
        if dd if="$DTBO_PARTITION" of="$WORK_DIR/dtbo.img" bs=4096 2>&1; then
            echo "DTBO提取成功"
        else
            echo "错误：DTBO提取失败"
            exit 1
        fi
        
        cd "$BIN_DIR" || exit 1
        chmod +x *
        
        # Remove old DTS
        rm -rf dtbo_dts/*
        
        ./unpack_dtbo "../workspace/dtbo.img" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "错误：解包失败"
            exit 1
        fi
        echo "Success: 工作区准备就绪"
        ;;

    "scan_rates")
        cd "$BIN_DIR" || exit 1
        chmod +x dts_tool
        
        # Detect Model and Target Panel
        MODEL=$(getprop ro.product.vendor.model)
        TARGET_PANEL=""
        case "$MODEL" in
            "RMX5200") # Realme GT8 Pro
                TARGET_PANEL="qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02"
                ;;
            "PLK110") # OnePlus 15
                TARGET_PANEL="qcom,mdss_dsi_panel_AD296_P_3_A0020_dsc_cmd"
                ;;
            "PJD110") # OnePlus 12
                TARGET_PANEL="qcom,mdss_dsi_panel_AA545_P_3_A0005_dsc_cmd"
                ;;
            *)
                # Fallback or unknown model
                TARGET_PANEL=""
                ;;
        esac
        
        # Get Project ID
        PRJ_ID=$(getprop ro.boot.prjname)
        
        ./dts_tool scan "$TARGET_PANEL" "$PRJ_ID"
        ;;

    "auto_process")
        cd "$BIN_DIR" || exit 1
        chmod +x process_dts
        echo "Running Auto Process..."
        ./process_dts
        RET=$?
        if [ $RET -eq 0 ]; then
             echo "Success: Auto Process Completed"
        else
             echo "Error: process_dts failed with code $RET"
        fi
        ;;

    "add_rate")
        BASE_NODE="$2"
        TARGET_FPS="$3"
        CUSTOM_CLOCK="$4"      # 可选：自定义时钟 (Hz)，留空=自动计算
        CUSTOM_TRANSFER="$5"   # 可选：自定义传输时间 (µs)，留空=自动计算
        cd "$BIN_DIR" || exit 1
        chmod +x dts_tool
        
        # Detect Model and Target Panel
        MODEL=$(getprop ro.product.vendor.model)
        TARGET_PANEL=""
        case "$MODEL" in
            "RMX5200") TARGET_PANEL="qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02" ;;
            "PLK110") TARGET_PANEL="qcom,mdss_dsi_panel_AD296_P_3_A0020_dsc_cmd" ;;
            "PJD110") TARGET_PANEL="qcom,mdss_dsi_panel_AA545_P_3_A0005_dsc_cmd" ;;
        esac
        
        # Get Project ID
        PRJ_ID=$(getprop ro.boot.prjname)

        ./dts_tool add "$BASE_NODE" "$TARGET_FPS" "$TARGET_PANEL" "$PRJ_ID" "$CUSTOM_CLOCK" "$CUSTOM_TRANSFER"
        RET=$?
        if [ $RET -eq 0 ]; then
             echo "Success: 已添加 ${TARGET_FPS}Hz 节点"
        else
             echo "Error: dts_tool failed with code $RET"
        fi
        ;;

    "pack_only")
        do_pack
        ;;

    "merge_avb")
        do_merge_avb
        ;;

    "flash_final")
        do_flash
        ;;

    "smart_add_rate")
        do_smart_add "$2"
        ;;

    "remove_rate")
        TARGET_NODE="$2"
        cd "$BIN_DIR" || exit 1
        chmod +x dts_tool
        
        # Detect Model and Target Panel
        MODEL=$(getprop ro.product.vendor.model)
        TARGET_PANEL=""
        case "$MODEL" in
            "RMX5200") TARGET_PANEL="qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02" ;;
            "PLK110") TARGET_PANEL="qcom,mdss_dsi_panel_AD296_P_3_A0020_dsc_cmd" ;;
            "PJD110") TARGET_PANEL="qcom,mdss_dsi_panel_AA545_P_3_A0005_dsc_cmd" ;;
        esac

        # Get Project ID
        PRJ_ID=$(getprop ro.boot.prjname)

        ./dts_tool remove "$TARGET_NODE" "$TARGET_PANEL" "$PRJ_ID"
        RET=$?
        if [ $RET -eq 0 ]; then
             echo "Success"
        else
             echo "Error: dts_tool failed with code $RET"
        fi
        ;;

    "apply_changes")
        echo "开始应用更改..."
        do_pack || exit 1
        do_merge_avb || exit 1
        do_flash || exit 1
        echo "操作完成！请重启设备。"
        ;;

    "flash_dtbo")
        do_smart_add "$2" || exit 1
        do_pack || exit 1
        do_merge_avb || exit 1
        do_flash || exit 1
        echo "操作完成！请重启设备。"
        ;;

    # ---- 后台执行（供前端流式轮询日志）----
    # start_apply / start_flash：立即返回，流程在后台运行，日志写 apply.log，状态写 apply.status
    # apply_changes_bg / flash_dtbo_bg：后台实际执行体
    "start_apply")
        rm -f "$MOD_PATH/apply.log" "$MOD_PATH/apply.status"
        setsid sh "$MOD_PATH/scripts/web_handler.sh" apply_changes_bg > "$MOD_PATH/apply.log" 2>&1 &
        echo "Started: $MOD_PATH/apply.log"
        ;;

    "apply_changes_bg")
        rm -f "$MOD_PATH/apply.status"
        do_pack && do_merge_avb && do_flash
        if [ $? -eq 0 ]; then
            echo "操作完成！请重启设备。"
            echo "SUCCESS" > "$MOD_PATH/apply.status"
        else
            echo "FAIL" > "$MOD_PATH/apply.status"
        fi
        ;;

    "start_flash")
        rm -f "$MOD_PATH/apply.log" "$MOD_PATH/apply.status"
        setsid sh "$MOD_PATH/scripts/web_handler.sh" flash_dtbo_bg "$2" > "$MOD_PATH/apply.log" 2>&1 &
        echo "Started: $MOD_PATH/apply.log"
        ;;

    "flash_dtbo_bg")
        rm -f "$MOD_PATH/apply.status"
        do_smart_add "$2" && do_pack && do_merge_avb && do_flash
        if [ $? -eq 0 ]; then
            echo "操作完成！请重启设备。"
            echo "SUCCESS" > "$MOD_PATH/apply.status"
        else
            echo "FAIL" > "$MOD_PATH/apply.status"
        fi
        ;;

    "restore_dtbo")
        BACKUP_FILE=""
        # Prioritize the original backup in module directory
        if [ -f "$IMG_DIR/dtbo.img" ]; then
            BACKUP_FILE="$IMG_DIR/dtbo.img"
        fi

        if [ -z "$BACKUP_FILE" ]; then
            echo "错误：找不到备份文件"
            exit 1
        fi
        
        SLOT=$(getprop ro.boot.slot_suffix)
        DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
        
        echo "正在恢复原厂 DTBO..."
        if dd if="$BACKUP_FILE" of="$DTBO_PARTITION" bs=4096 2>&1; then
            echo "Success: 恢复成功！"
            # 不要删除备份文件，防止用户再次误操作需要恢复
            # rm -rf "$BIN_DIR/dtbo_dts"
            # rm -f "$BIN_DIR/new_dtbo.img"
        else
            echo "错误：恢复失败"
            exit 1
        fi
        ;;

    "set_config")
        # $2 is global mode id
        NEW_MODE="$2"
        if [ -z "$NEW_MODE" ]; then
            echo "Error: Missing mode ID"
            exit 1
        fi
        
        # 替换第一行，保持后续行不变
        # sed -i '1s/.*/NEW_MODE/' doesn't work well on android sed sometimes
        # 使用临时文件
        TMP_FILE="${CONFIG_FILE}.tmp"
        echo "$NEW_MODE" > "$TMP_FILE"
        # 从第二行开始追加原始内容
        tail -n +2 "$CONFIG_FILE" >> "$TMP_FILE" 2>/dev/null
        mv "$TMP_FILE" "$CONFIG_FILE"
        chmod 666 "$CONFIG_FILE"
        
        echo "Success: Global mode set to $NEW_MODE"
        ;;

    "set_app_config")
        # $2 is package, $3 is mode id (-1 to delete)
        PKG="$2"
        MODE="$3"
        
        if [ -z "$PKG" ] || [ -z "$MODE" ]; then
            echo "Error: Missing arguments"
            exit 1
        fi

        # 读取第一行作为全局配置
        GLOBAL_MODE=$(head -n 1 "$CONFIG_FILE")
        
        TMP_FILE="${CONFIG_FILE}.tmp"
        echo "$GLOBAL_MODE" > "$TMP_FILE"
        
        # 处理现有配置，排除当前包
        grep -v "^$PKG=" "$CONFIG_FILE" | grep "=" >> "$TMP_FILE"
        
        # 如果不是删除模式，追加新配置
        if [ "$MODE" != "-1" ]; then
            echo "$PKG=$MODE" >> "$TMP_FILE"
        fi
        
        mv "$TMP_FILE" "$CONFIG_FILE"
        chmod 666 "$CONFIG_FILE"
        
        echo "Success: App config saved"
        ;;

    "get_app_info")
        PKG="$2"
        if [ -z "$PKG" ]; then
            echo ""
            exit 0
        fi
        
        # Try to find base apk
        # pm path output format: package:/data/app/...
        BASE_APK=$(pm path "$PKG" | head -n 1 | sed 's/package://')
        if [ -z "$BASE_APK" ]; then
            echo ""
            exit 0
        fi
        
        # Ensure aapt is executable
        chmod +x "$BIN_DIR/aapt"
        
        # Use aapt to get label
        LABEL=$("$BIN_DIR/aapt" dump badging "$BASE_APK" 2>/dev/null | grep "application-label:" | sed "s/application-label://; s/'//g")
        
        if [ -z "$LABEL" ]; then
            echo ""
        else
            echo "$LABEL"
        fi
        ;;

    "check_backup")
        if [ -f "$IMG_DIR/dtbo.img" ] || [ -f "$MOD_PATH/backup_dtbo.img" ]; then
            echo "EXIST"
        else
            echo "NONE"
        fi
        ;;

    "uninstall_module")
        # Reuse restore_dtbo logic if possible, or just create remove file
        # Magisk/KSU uninstall way: create remove file
        
        # 1. Try to restore DTBO first if backup exists
        BACKUP_FILE=""
        if [ -f "$IMG_DIR/dtbo.img" ]; then
            BACKUP_FILE="$IMG_DIR/dtbo.img"
        elif [ -f "$MOD_PATH/backup_dtbo.img" ]; then
            BACKUP_FILE="$MOD_PATH/backup_dtbo.img"
        fi

        if [ ! -z "$BACKUP_FILE" ]; then
            SLOT=$(getprop ro.boot.slot_suffix)
            DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
            if [ -f "$AVB_HELPER" ]; then
                dtbo_write_partition "$BACKUP_FILE" "$DTBO_PARTITION" || exit 1
            else
                dd if="$BACKUP_FILE" of="$DTBO_PARTITION" bs=4096 conv=fsync || exit 1
            fi
        fi
        
        # 2. Create remove file for Magisk/KSU to handle cleanup on next boot
        touch "$MOD_PATH/remove"
        
        # 3. Stop daemon
        pkill -f "rate_daemon"
        
        echo "Success"
        ;;

    "toggle_adfr")
        # $2 = "disable" or "enable"
        ACTION="$2"
        PROP_BACKUP="$MOD_PATH/config/prop_backup.txt"
        ADFR_STATE="$MOD_PATH/config/adfr_state.txt"
        ADFR_CONFIG="/sys/kernel/oplus_display/adfr_config"
        ADFR_MIN_FPS="/sys/kernel/oplus_display/min_fps"
        
        # 解析目标模式规格: 优先取 mode.txt 默认档位 (HWC ID) 对应的 W H FPS
        # 输出: "W H FPS" 或空
        get_target_mode_spec() {
            DEFAULT_ID=$(head -n 1 "$MOD_PATH/config/mode.txt" 2>/dev/null | tr -d '[:space:]')
            if [ -n "$DEFAULT_ID" ] && [ "$DEFAULT_ID" -eq "$DEFAULT_ID" ] 2>/dev/null; then
                MODE_LINE=$(dumpsys SurfaceFlinger 2>/dev/null | \
                    grep -oE "id=${DEFAULT_ID}, hwcId=[0-9]+, resolution=[0-9]+x[0-9]+, vsyncRate=[0-9.]+" | \
                    head -n 1)
                if [ -n "$MODE_LINE" ]; then
                    RES=$(echo "$MODE_LINE" | sed -n 's/.*resolution=\([0-9]*\)x\([0-9]*\).*/\1 \2/p')
                    FPS=$(echo "$MODE_LINE" | sed -n 's/.*vsyncRate=\([0-9.]*\).*/\1/p')
                    W=$(echo "$RES" | cut -d' ' -f1)
                    H=$(echo "$RES" | cut -d' ' -f2)
                    if [ -n "$W" ] && [ -n "$H" ] && [ -n "$FPS" ]; then
                        echo "$W $H $FPS"
                        return 0
                    fi
                fi
            fi
            return 1
        }
        
        if [ "$ACTION" == "disable" ]; then
            # Backup current values if not exists
            if [ ! -f "$PROP_BACKUP" ]; then
                touch "$PROP_BACKUP"
                # GT8 Pro 使用 pdfr，旧机型使用 adfr，两个都备份
                echo "persist.oplus.display.vrr=$(getprop persist.oplus.display.vrr)" >> "$PROP_BACKUP"
                echo "persist.oplus.display.vrr.adfr=$(getprop persist.oplus.display.vrr.adfr)" >> "$PROP_BACKUP"
                echo "persist.oplus.display.vrr.pdfr=$(getprop persist.oplus.display.vrr.pdfr)" >> "$PROP_BACKUP"
                echo "sys.display.vrr.vote.support=$(getprop sys.display.vrr.vote.support)" >> "$PROP_BACKUP"
                echo "vendor.display.enable_dpps_dynamic_fps=$(getprop vendor.display.enable_dpps_dynamic_fps)" >> "$PROP_BACKUP"
                echo "vendor.display.enable_optimal_refresh_rate=$(getprop vendor.display.enable_optimal_refresh_rate)" >> "$PROP_BACKUP"
                echo "vendor.display.enable_idle_content_fps_hint=$(getprop vendor.display.enable_idle_content_fps_hint)" >> "$PROP_BACKUP"
                echo "persist.sys.oplus.display.brightness.mode=$(getprop persist.sys.oplus.display.brightness.mode)" >> "$PROP_BACKUP"
                echo "debug.egl.swapinterval=$(getprop debug.egl.swapinterval)" >> "$PROP_BACKUP"
            fi
            
            # Apply disable values
            # persist.* 使用持久化写入，重启后 HAL 仍能读到 0
            resetprop persist.oplus.display.vrr 0
            resetprop persist.oplus.display.vrr.adfr 0
            resetprop persist.oplus.display.vrr.pdfr 0
            resetprop -n sys.display.vrr.vote.support 0
            resetprop -n vendor.display.enable_dpps_dynamic_fps 0
            resetprop -n vendor.display.enable_optimal_refresh_rate 0
            resetprop -n vendor.display.enable_idle_content_fps_hint 0
            resetprop persist.sys.oplus.display.brightness.mode 1
            setprop debug.egl.swapinterval 1
            
            # 固定框架层显示模式（用户首选模式 = 目标档位），并启用内核 ADFR 下限
            SPEC=$(get_target_mode_spec)
            if [ -n "$SPEC" ]; then
                set -- $SPEC
                W="$1"; H="$2"; FPS="$3"
                echo "$W $H $FPS" > "$ADFR_STATE"
                cmd display set-user-preferred-display-mode "$W" "$H" "$FPS" > /dev/null 2>&1
                if [ -w "$ADFR_CONFIG" ]; then
                    echo 1 > "$ADFR_CONFIG" 2>/dev/null
                    echo "$FPS" > "$ADFR_MIN_FPS" 2>/dev/null
                fi
                echo "Success: ADFR Disabled (fixed ${FPS}Hz)"
            else
                echo "Success: ADFR Disabled (props only)"
            fi
            
        elif [ "$ACTION" == "enable" ]; then
            if [ -f "$PROP_BACKUP" ]; then
                # Restore from backup
                while IFS='=' read -r key value; do
                    if [ ! -z "$key" ]; then
                        # Use resetprop for persist props to ensure they stick/revert correctly
                        # or just setprop for normal ones. resetprop is safer for "restoring" system state.
                        if [ -z "$value" ]; then
                             # If value was empty, maybe we should unset it? or set to empty.
                             case "$key" in
                                 persist.*) resetprop "$key" "" ;;
                                 *) resetprop -n "$key" "" ;;
                             esac
                        else
                             case "$key" in
                                 persist.*) resetprop "$key" "$value" ;;
                                 *) resetprop -n "$key" "$value" ;;
                             esac
                        fi
                    fi
                done < "$PROP_BACKUP"
                
                # Clean up backup
                rm "$PROP_BACKUP"
            else
                echo "Error: No backup found, cannot restore."
                exit 1
            fi
            rm -f "$ADFR_STATE"
            cmd display clear-user-preferred-display-mode > /dev/null 2>&1
            if [ -w "$ADFR_CONFIG" ]; then
                echo 0 > "$ADFR_CONFIG" 2>/dev/null
            fi
            echo "Success: ADFR Restored"
        else
            echo "Error: Invalid action"
        fi
        ;;

    *)
        echo "Unknown command: $1"
        ;;
esac
