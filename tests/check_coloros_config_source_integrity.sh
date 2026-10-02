#!/system/bin/sh
# 把 coloros_config.sh 的 validate_source() 在离线状态下拉出来跑一遍。
# 起因：上一版我只删了测试里的断言、没改运行时代码，结果测试放行、真机报
#       error:source_integrity。这个脚本直接 source 真脚本、调用真函数，杜绝同类失误。
#
# 用法: sh tests/check_coloros_config_source_integrity.sh [模块根目录]

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=${1:-$(CDPATH= cd -- "$HERE/.." && pwd)}

SCRIPT="$ROOT/scripts/coloros_config.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: 找不到 $SCRIPT" >&2; exit 1; }

# coloros_config.sh 用 $0 反推 SCRIPT_DIR/MOD_DIR，而且尾部有 case "$1" 分发。
# 所以这里不 source，而是把它"截掉 case 段"后、以正确的 $0 交给子 shell 执行：
#   sh -c '<定义段>; validate_source' /path/to/scripts/coloros_config.sh
TMP=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/mcp_cfg_$$")
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

awk '/^case "\$1" in/{exit} {print}' "$SCRIPT" > "$TMP/defs.sh"

echo "跑真实的 validate_source()（subshell 里以正确的 \$0 执行，不是 grep 复刻）..."
if sh -c ". '$TMP/defs.sh'; validate_source" "$SCRIPT"; then
    echo "PASS: validate_source"
else
    echo "FAIL: validate_source 返回非 0 —— 这就是真机上 error:source_integrity 的来源" >&2
    echo "      VRR_SOURCE  = $ROOT/config/coloros/oplus_vrr_config.json" >&2
    echo "      RATE_SOURCE = $ROOT/config/coloros/refresh_rate_config.xml" >&2
    exit 1
fi

VRR_SOURCE="$ROOT/config/coloros/oplus_vrr_config.json"
RATE_SOURCE="$ROOT/config/coloros/refresh_rate_config.xml"

# 顺带把每条门槛单独点名，便于定位
check() {
    if grep -Eq "$2" "$3" 2>/dev/null; then
        printf '  %-34s 命中  %s\n' "$1" "$3"
    else
        printf '  %-34s 未命中 %s\n' "$1" "$3"
    fi
}
echo "门槛明细:"
check 'feature_sa == "true"'        '"feature_sa"[[:space:]]*:[[:space:]]*"true"' "$VRR_SOURCE"
check 'adfr_enable == true'         '"adfr_enable"[[:space:]]*:[[:space:]]*true'  "$VRR_SOURCE"
check 'sf_framerate_ranges'         '"sf_framerate_ranges"'                        "$VRR_SOURCE"
check 'frtc_framerate_ranges'       '"frtc_framerate_ranges"'                      "$VRR_SOURCE"
check 'xml version 已知集合'         '<refresh_rate_config[^>]*version="(20260811|20260918)"' "$RATE_SOURCE"
check 'maxrefreshsettings="3"'      '<config[^>]*maxrefreshsettings="3"'           "$RATE_SOURCE"

# 禁止项：命中即 validate_source 会失败
for banned in 'defaultMaxRate' 'extremeHighEnable'; do
    if grep -q "<config[^>]*${banned}=" "$RATE_SOURCE"; then
        echo "  !! 禁止项 $banned 出现在 <config> 里（会导致 validate_source 失败）" >&2
        exit 1
    fi
done
echo "  （<config> 里无 defaultMaxRate / extremeHighEnable，符合门槛）"

echo "PASS: ColorOS 配置能通过运行时的 validate_source"
