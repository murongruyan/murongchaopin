#!/system/bin/sh

MODDIR=${0%/*}
WEBUI_PKG="io.github.a13e300.ksuwebui"
WEBUI_APK="$MODDIR/KsuWebUI.apk"

print_result() {
    echo "$*" >&2
}

has_webui() {
    pm path "$WEBUI_PKG" 2>/dev/null | grep -q '^package:'
}

if ! has_webui; then
    if [ ! -f "$WEBUI_APK" ]; then
        print_result "未检测到 KsuWebUI，且模块内没有安装包。请先安装 KsuWebUI。"
        exit 1
    fi

    print_result "未检测到 KsuWebUI，正在安装模块内置版本..."
    pm install -r --user 0 "$WEBUI_APK" >/dev/null 2>&1 ||
        pm install -r "$WEBUI_APK" >/dev/null 2>&1

    if ! has_webui; then
        print_result "KsuWebUI 安装失败，请手动安装模块内置的 KsuWebUI.apk。"
        exit 1
    fi
    print_result "KsuWebUI 安装成功。"
fi

if ! am start -n "$WEBUI_PKG/.WebUIActivity" -e id "murongchaopin" >/dev/null 2>&1; then
    print_result "KsuWebUI 已安装，但启动失败，请先打开一次 KsuWebUI 并授予 Root 权限。"
    exit 1
fi
exit 0
