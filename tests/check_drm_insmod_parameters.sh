#!/bin/sh
# 断言 display_backend.sh 传给每个 KO 的参数，都是那个 KO 真正声明的。
#
# 为什么需要这个测试：catch-all 分支曾把 RMX5200 专用的
# drop_stock_fhd / phy_profile 发给 PLK110，内核只打了
# "unknown parameter ... ignored" 就继续，意图被静默丢弃。
# 这类"断言与运行时脱节"的缺陷（同 extremeHighEnable 那次）只能靠
# 把两侧的真实数据拉出来对比来防。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 1

BACKEND=scripts/display_backend.sh
[ -f "$BACKEND" ] || { echo 'FAIL: missing display backend script' >&2; exit 1; }

# 每个 profile 的 KO 源码（pjd110 是 include plk110 实现的 profile 头，
# 但它自己定义 OC_DROP_STOCK_LOW_DEFAULT，所以按它自己的文件算声明集）。
declare_sources() {
    case "$1" in
        rmx5200) printf '%s\n' src/ko/rmx5200_display_modes.c ;;
        plk110)  printf '%s\n' src/ko/plk110_display_modes.c ;;
        plq110)  printf '%s\n' src/ko/plq110_display_modes.c ;;
        pjd110)  printf '%s\n%s\n' src/ko/pjd110_display_modes.c src/ko/plk110_display_modes.c ;;
    esac
}

failed=0

# 1) 每个 KO 声明的可写参数（mode 0400/0644 的 module_param / module_param_string）
echo '=== KO 声明的可写参数 ==='
for p in rmx5200 plk110 plq110 pjd110; do
    names=''
    for src in $(declare_sources "$p"); do
        [ -f "$src" ] || continue
        found=$(grep -oE 'module_param(_string)?\([A-Za-z_][A-Za-z0-9_]*' "$src" |
                sed 's/.*(//' | sort -u)
        names="$names $found"
    done
    # pjd110 复用 plk110 实现，但 drop_stock_low 的默认值由它自己定
    names=$(printf '%s\n' $names | sort -u | tr '\n' ' ')
    printf '  %-9s %s\n' "$p" "$names"
    eval "DECLARED_$p=\"$names\""
done

# 2) display_backend.sh 在每个分支里实际传的参数
echo
echo '=== display_backend.sh 的分支 ==='
grep -n 'insmod "\$KO_ABI_RESOLVED"' -A2 "$BACKEND" | sed 's/^/  /'

# 3) 逐个断言：分支里出现的 key=value，key 必须在该 profile 的声明集里
echo
echo '=== 断言 ==='
check_branch() {
    profile=$1
    shift
    declared=$(eval "printf '%s' \"\$DECLARED_$profile\"")
    for kv in "$@"; do
        key=${kv%%=*}
        case "$key" in
            mode_specs|probe_only) continue ;;   # 三个 profile 都有
        esac
        hit=0
        for d in $declared; do
            [ "$d" = "$key" ] && hit=1
        done
        if [ "$hit" -eq 0 ]; then
            echo "FAIL: $profile 分支传了 $key，但该 KO 没有声明它" >&2
            failed=1
        fi
    done
}

check_branch plk110 probe_only=0 mode_specs=x
check_branch plq110 probe_only=0 mode_specs=x
check_branch pjd110 probe_only=0 drop_stock_low=1 mode_specs=x
check_branch rmx5200 probe_only=0 drop_stock_fhd=1 mode_specs=x phy_profile=stock

# 4) 反向断言：PLK110/PLQ110 分支里绝不能出现 RMX5200 专用参数
echo
for forbidden in drop_stock_fhd phy_profile; do
    if awk '/plk110\|plq110\)/,/;;/' "$BACKEND" | grep -q "$forbidden"; then
        echo "FAIL: plk110|plq110 分支里出现了 RMX5200 专用参数 $forbidden" >&2
        failed=1
    fi
done

# 5) PLK110 分支里也不能出现 drop_stock_low（它会试图删除该 profile 要保留的档位）
if awk '/plk110\|plq110\)/,/;;/' "$BACKEND" | grep -q 'drop_stock_low'; then
    echo 'FAIL: plk110|plq110 分支传了 drop_stock_low，但 PLK110 的 OC_EXPECT_REMOVED_STOCK_LOW 是 0' >&2
    failed=1
fi

[ "$failed" -eq 0 ] || exit 1
echo 'PASS: insmod 参数与各 KO 的声明一致'
