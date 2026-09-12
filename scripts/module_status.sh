#!/system/bin/sh

# scripts/module_status.sh - module-level health notices.
#
# Collects user-visible error/conflict states (coloros config unmount war,
# ADFR lock failures, incomplete paid payload) into config/module_notices.txt
# and mirrors them into the module.prop description so the KernelSU module
# list shows them without opening the WebUI. `collect` prints the live
# notices; `refresh` rewrites the file + module.prop (called at boot).

SCRIPT_DIR=${0%/*}
MODDIR=${SCRIPT_DIR%/*}

NOTICES_FILE="$MODDIR/config/module_notices.txt"
MODULE_PROP="$MODDIR/module.prop"
DESCRIPTION_MARKER=" ｜ ⚠"

is_bind_mounted()
{
    awk -v target="$1" '$5 == target { found = 1 } END { exit !found }' \
        /proc/self/mountinfo 2>/dev/null
}

# 显示配置被其他 zygisk 模块逐进程卸载（温控伪装类）：全局挂载存在而
# system_server 视图缺失时，框架的分辨率/DPI 决策会互相矛盾并闪烁。
coloros_unmount_conflict()
{
    STATUS_FILE="$MODDIR/runtime/coloros_config/status.txt"
    [ -f "$STATUS_FILE" ] || return 1
    grep -q "unmount_conflict" "$STATUS_FILE" 2>/dev/null || return 1
    SS_PID=$(pidof system_server 2>/dev/null | tr ' ' '\n' | head -n 1)
    [ -n "$SS_PID" ] && [ -r "/proc/$SS_PID/mountinfo" ] || return 1
    grep -q "my_product/etc/refresh_rate_config.xml" /proc/self/mountinfo 2>/dev/null &&
        ! grep -q "my_product/etc/refresh_rate_config.xml" \
            "/proc/$SS_PID/mountinfo" 2>/dev/null
}

adfr_lock_error()
{
    STATE_FILE="$MODDIR/premium/config/adfr_lock_state.txt"
    [ -f "$STATE_FILE" ] || return 1
    case "$(sed -n '1{s/\r$//;p;q;}' "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')" in
        error:*) return 0 ;;
        *) return 1 ;;
    esac
}

premium_payload_broken()
{
    MANIFEST="$MODDIR/premium/manifest.json"
    [ -f "$MANIFEST" ] || return 1
    # 逐 target_path 抽查前 8 个已安装文件是否真实存在（与
    # display_license_gate 的按行校验同语义：相对 premium 目录、-s 判定；
    # 权威校验仍是 web_handler 的 gate_premium_installed）。
    MISSING=$(grep -o '"target_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
        "$MANIFEST" 2>/dev/null |
        sed 's/.*: *"//;s/"$//' | grep -v '^/' | head -n 8 |
        while IFS= read -r rel; do
            [ -s "$MODDIR/premium/$rel" ] || echo "$rel"
        done)
    [ -n "$MISSING" ]
}

collect_notices()
{
    if coloros_unmount_conflict; then
        printf '显示配置被其他模块卸载（常见于温控伪装类 zygisk 模块），自定义节点可能无效且分辨率/DPI 会闪烁'
    fi
    if adfr_lock_error; then
        printf 'ADFR 内核锁加载失败，完美禁用 ADFR 走 props 方案或不可用（详见日志页）'
    fi
    if premium_payload_broken; then
        printf '付费组件文件缺失，请在授权页重新安装最新付费包'
    fi
}

description_base()
{
    sed -n 's/^description=//p' "$MODULE_PROP" 2>/dev/null |
        sed "s/${DESCRIPTION_MARKER}.*$//"
}

refresh_status()
{
    mkdir -p "$(dirname "$NOTICES_FILE")" 2>/dev/null
    collect_notices > "$NOTICES_FILE.new" 2>/dev/null
    mv -f "$NOTICES_FILE.new" "$NOTICES_FILE" 2>/dev/null

    BASE=$(description_base)
    [ -n "$BASE" ] || return 0
    # 后缀只取第一条提示：tr 对多字节分隔符是字节级操作会产出非法 UTF-8；
    # 全部提示由 WebUI 弹窗展示，module.prop 仅放最重要的一条。
    FIRST_NOTICE=$(sed -n '/[^[:space:]]/p' "$NOTICES_FILE" 2>/dev/null | head -n 1)
    SUFFIX=""
    if [ -n "$FIRST_NOTICE" ]; then
        SUFFIX="${DESCRIPTION_MARKER} ${FIRST_NOTICE}"
    fi
    TMP="$MODULE_PROP.tmp.$$"
    # 不用 awk -v：toybox awk 对多字节长变量的行为不可靠。键值行直接用
    # shell 重组（description 顺序无关，KSU 按 key 解析）。
    grep -v '^description=' "$MODULE_PROP" > "$TMP" 2>/dev/null
    printf 'description=%s\n' "${BASE}${SUFFIX}" >> "$TMP"
    grep -q '^description=' "$TMP" && mv -f "$TMP" "$MODULE_PROP"
    rm -f "$MODULE_PROP.tmp.$$" 2>/dev/null
}

case "$1" in
    collect) collect_notices ;;
    refresh) refresh_status ;;
    *)
        printf 'usage: %s {collect|refresh}\n' "$0" >&2
        exit 64
        ;;
esac
