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

        ./dts_tool add "$BASE_NODE" "$TARGET_FPS" "$TARGET_PANEL" "$PRJ_ID"
        RET=$?
        if [ $RET -eq 0 ]; then
             echo "Success"
        else
             echo "Error: dts_tool failed with code $RET"
        fi
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
        cd "$BIN_DIR" || exit 1
        chmod +x *
        
        echo "正在打包..."
        PACK_LOG="$BIN_DIR/pack.log"
        ./pack_dtbo >"$PACK_LOG" 2>&1
        if [ $? -ne 0 ]; then
            echo "错误：打包失败"
            cat "$PACK_LOG"
            exit 1
        fi
        
        echo "正在刷入..."
        SLOT=$(getprop ro.boot.slot_suffix)
        DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
        
        # pack_dtbo generates new_dtbo.img usually
        NEW_DTBO="new_dtbo.img"
        if [ ! -f "$NEW_DTBO" ]; then
             NEW_DTBO="dtbo.img" # Fallback just in case
        fi

        STOCK_DTBO="$IMG_DIR/dtbo.img"
        FINAL_DTBO="$BIN_DIR/dtbo_final.img"
        PARTITION_SIZE=$(blockdev --getsize64 "$DTBO_PARTITION" 2>/dev/null)
        if [ ! -f "$AVB_HELPER" ]; then
            echo "错误：缺少 DTBO AVB 处理脚本"
            exit 1
        fi
        if [ ! -f "$STOCK_DTBO" ]; then
            echo "错误：找不到原厂 DTBO 备份，无法复用官方 AVB 信息"
            exit 1
        fi
        if ! dtbo_apply_stock_avb "$STOCK_DTBO" "$NEW_DTBO" "$FINAL_DTBO" "$PARTITION_SIZE"; then
            echo "错误：官方 AVB 信息复用失败，未执行刷入（请勿重启，DTBO 分区未被修改）"
            exit 1
        fi

        if dtbo_write_partition "$FINAL_DTBO" "$DTBO_PARTITION"; then
            echo "Success: 刷入成功！请重启生效。"
        else
            echo "错误：刷入失败（分区未被修改）"
            exit 1
        fi
        ;;

    "flash_dtbo")
        CUSTOM_RATE="$2"
        echo "开始执行超频流程 (Multi-Model Mode)..."
        if [ ! -z "$CUSTOM_RATE" ]; then
            echo "目标自定义刷新率: ${CUSTOM_RATE}Hz"
        fi

        SLOT=$(getprop ro.boot.slot_suffix)
        DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
        
        # Detect Model and Target Panel
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
            exit 1
        fi
        
        cd "$BIN_DIR" || exit 1
        chmod +x *
        
        echo "2. 解包..."
        ./unpack_dtbo "../workspace/dtbo.img" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "错误：解包失败"
            exit 1
        fi
        
        echo "3. 应用通用补丁..."
        # process_dts 用于特定机型(如GT8Pro)的额外参数修正
        # 对于其他机型，此步骤可能跳过或仅做基础检查
        ./process_dts
        RET=$?
        if [ $RET -ne 0 ]; then
             echo "提示：通用补丁未应用或发生错误 (代码 $RET)，但这可能不影响自定义刷新率。"
        fi
        
        # 自定义刷新率处理 (真正多机型通用部分)
        if [ ! -z "$CUSTOM_RATE" ]; then
            echo "3.1 智能添加自定义刷新率 ($CUSTOM_RATE Hz)..."
            if [ ! -z "$TARGET_PANEL" ]; then
                echo "    - 目标面板: $TARGET_PANEL"
            fi
            
            # Get Project ID
            PRJ_ID=$(getprop ro.boot.prjname)
            echo "    - Project ID: $PRJ_ID"

            # 使用 dts_tool 的智能添加功能
            # 自动扫描最大 FPS 节点作为模板，支持所有 Qualcomm 平台
            ./dts_tool smart_add "$CUSTOM_RATE" "$TARGET_PANEL" "$PRJ_ID"
            
            if [ $? -eq 0 ]; then
                echo "自定义刷新率节点已生成。"
            else
                echo "错误：自定义刷新率添加失败！"
                exit 1
            fi
        fi
        
        echo "4. 打包..."
        PACK_LOG="$BIN_DIR/pack.log"
        ./pack_dtbo >"$PACK_LOG" 2>&1
        if [ $? -ne 0 ]; then
            echo "错误：打包失败"
            cat "$PACK_LOG"
            exit 1
        fi
        
        echo "5. 刷入分区..."
        NEW_DTBO="$BIN_DIR/new_dtbo.img"
        STOCK_DTBO="$IMG_DIR/dtbo.img"
        FINAL_DTBO="$BIN_DIR/dtbo_final.img"
        PARTITION_SIZE=$(blockdev --getsize64 "$DTBO_PARTITION" 2>/dev/null)
        if [ ! -f "$STOCK_DTBO" ]; then
            echo "错误：找不到原厂 DTBO 备份，无法复用官方 AVB 信息"
            exit 1
        fi
        if ! dtbo_apply_stock_avb "$STOCK_DTBO" "$NEW_DTBO" "$FINAL_DTBO" "$PARTITION_SIZE"; then
            echo "错误：官方 AVB 信息复用失败，未执行刷入（请勿重启，DTBO 分区未被修改）"
            exit 1
        fi
        if dtbo_write_partition "$FINAL_DTBO" "$DTBO_PARTITION"; then
            echo "Success: 刷入成功！请重启生效。"
        else
            echo "错误：刷入失败（分区未被修改）"
            exit 1
        fi
        
        echo "操作完成！请重启设备。"
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
        
        if [ "$ACTION" == "disable" ]; then
            # Backup current values if not exists
            if [ ! -f "$PROP_BACKUP" ]; then
                touch "$PROP_BACKUP"
                echo "persist.oplus.display.vrr=$(getprop persist.oplus.display.vrr)" >> "$PROP_BACKUP"
                echo "persist.oplus.display.vrr.adfr=$(getprop persist.oplus.display.vrr.adfr)" >> "$PROP_BACKUP"
                echo "debug.oplus.display.dynamic_fps_switch=$(getprop debug.oplus.display.dynamic_fps_switch)" >> "$PROP_BACKUP"
                echo "sys.display.vrr.vote.support=$(getprop sys.display.vrr.vote.support)" >> "$PROP_BACKUP"
                echo "vendor.display.enable_dpps_dynamic_fps=$(getprop vendor.display.enable_dpps_dynamic_fps)" >> "$PROP_BACKUP"
                echo "ro.display.brightness.brightness.mode=$(getprop ro.display.brightness.brightness.mode)" >> "$PROP_BACKUP"
                echo "debug.egl.swapinterval=$(getprop debug.egl.swapinterval)" >> "$PROP_BACKUP"
            fi
            
            # Apply disable values
            resetprop -n persist.oplus.display.vrr 0
            resetprop -n persist.oplus.display.vrr.adfr 0
            resetprop -n debug.oplus.display.dynamic_fps_switch 0
            resetprop -n sys.display.vrr.vote.support 0
            resetprop -n vendor.display.enable_dpps_dynamic_fps 0
            resetprop -n ro.display.brightness.brightness.mode 1
            setprop debug.egl.swapinterval 1
            
            echo "Success: ADFR Disabled"
            
        elif [ "$ACTION" == "enable" ]; then
            if [ -f "$PROP_BACKUP" ]; then
                # Restore from backup
                while IFS='=' read -r key value; do
                    if [ ! -z "$key" ]; then
                        # Use resetprop for persist props to ensure they stick/revert correctly
                        # or just setprop for normal ones. resetprop is safer for "restoring" system state.
                        if [ -z "$value" ]; then
                             # If value was empty, maybe we should unset it? or set to empty.
                             resetprop -n "$key" ""
                        else
                             resetprop -n "$key" "$value"
                        fi
                    fi
                done < "$PROP_BACKUP"
                
                # Clean up backup
                rm "$PROP_BACKUP"
                echo "Success: ADFR Restored"
            else
                echo "Error: No backup found, cannot restore."
            fi
        else
            echo "Error: Invalid action"
        fi
        ;;

    *)
        echo "Unknown command: $1"
        ;;
esac
