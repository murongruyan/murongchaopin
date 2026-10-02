#!/bin/sh
# dtbo_avb.sh 的 applied-history 辅助函数单元测试。
# 存在理由：安装器把"本模块写过的历史镜像"判成 foreign 后会静默跳过底层刷写，
# 于是档位对比实验实际测的是旧 DTBO。这个测试保证历史记录能正确识别自己的产物。

set -eu
REPO=${1:-/mnt/c/android-ndk-r27d-windows/diaodu/apk/murongchaopin/murongchaopin}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 只加载函数定义（dtbo_avb.sh 顶层是纯函数定义，可以直接 source）
. "$REPO/scripts/dtbo_avb.sh"

H=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
H2=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
X=1111111111111111111111111111111111111111111111111111111111111111
M="$T/dtbo.applied.sha256"

dtbo_append_applied_history "$M" "$H"
dtbo_append_applied_history "$M" "$H2"
dtbo_append_applied_history "$M" "$H"

echo "--- history 内容（应去重、新的在前）---"
cat "$M.history"

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  PASS  %s\n' "$1"
    else
        printf '  FAIL  %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"
        fail=1
    fi
}

hit() { if dtbo_applied_history_matches "$1" "$M"; then echo yes; else echo no; fi; }

check "最新哈希可识别"      "$(hit $H)"    yes
check "较早哈希也可识别"    "$(hit $H2)"   yes
check "未知哈希不识别"      "$(hit $X)"    no
check "空哈希不识别"        "$(hit '')"    no
check "大写输入可识别"      "$(hit $(printf '%s' $H | tr 'a-f' 'A-F'))" yes

# 去重：H 写了两次，history 里只应出现一次
n=$(grep -c "^$H\$" "$M.history" || true)
check "重复写入被去重"      "$n" 1

# 上限：写入 20 个不同哈希，history 不应超过 16 行
i=0
while [ "$i" -lt 20 ]; do
    dtbo_append_applied_history "$M" "$(printf '%064d' "$i")"
    i=$((i + 1))
done
lines=$(grep -c . "$M.history" || true)
check "history 有上限(<=16)" "$([ "$lines" -le 16 ] && echo ok || echo "$lines")" ok

# 最新写入的必须还在
check "最新写入仍可识别"    "$(hit "$(printf '%064d' 19)")" yes

# 上一份历史（跨安装带过来的副本）也必须能命中：镜像可能是用 fastboot 刷进去的，
# 那条记录不会出现在"本次安装写出的"历史里。
PREV="$T/prev/dtbo.applied.sha256"
mkdir -p "$T/prev"
printf '%s\n' "$H2" > "$PREV.history.previous"
if dtbo_applied_history_matches "$H2" "$PREV"; then
    printf '  PASS  %s\n' "上一份历史(.previous)可识别"
else
    printf '  FAIL  %s\n' "上一份历史(.previous)可识别"
    fail=1
fi
if dtbo_applied_history_matches "$X" "$PREV"; then
    printf '  FAIL  %s\n' "未知哈希经 .previous 也不该命中"
    fail=1
else
    printf '  PASS  %s\n' "未知哈希经 .previous 也不命中"
fi

[ "$fail" -eq 0 ] && echo "PASS: DTBO applied-history helpers" || { echo "FAIL"; exit 1; }
