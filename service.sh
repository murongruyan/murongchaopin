#!/system/bin/sh
MODDIR=${0%/*}
DAEMON_BIN="$MODDIR/bin/rate_daemon"

# 等待系统启动完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

# 若启用了"禁用 ADFR"(存在状态文件)，开机后重新应用固定模式与内核参数
ADFR_STATE="$MODDIR/config/adfr_state.txt"
if [ -f "$ADFR_STATE" ]; then
    SPEC=$(cat "$ADFR_STATE")
    set -- $SPEC
    if [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]; then
        cmd display set-user-preferred-display-mode "$1" "$2" "$3" > /dev/null 2>&1
        echo 1 > /sys/kernel/oplus_display/adfr_config 2>/dev/null
        echo "$3" > /sys/kernel/oplus_display/min_fps 2>/dev/null
        resetprop persist.oplus.display.vrr 0
        resetprop persist.oplus.display.vrr.adfr 0
        resetprop persist.oplus.display.vrr.pdfr 0
        resetprop -n sys.display.vrr.vote.support 0
        resetprop -n vendor.display.enable_dpps_dynamic_fps 0
        resetprop -n vendor.display.enable_optimal_refresh_rate 0
        resetprop -n vendor.display.enable_idle_content_fps_hint 0
    fi
fi

# 启动守护进程
# 传入模块路径作为参数
chmod +x "$DAEMON_BIN"
nohup "$DAEMON_BIN" "$MODDIR" > /dev/null 2>&1 &
