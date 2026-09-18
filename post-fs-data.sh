#!/system/bin/sh

MODDIR=${0%/*}
DISPLAY_HELPER="$MODDIR/scripts/display_backend.sh"
COLOROS_CONFIG_HELPER="$MODDIR/scripts/coloros_config.sh"
GATE_HELPER="$MODDIR/scripts/display_license_gate.sh"
PREMIUM_POST_FS="$MODDIR/premium/scripts/premium_post_fs_data.sh"
LTPS_VOTE_HELPER="$MODDIR/scripts/surfaceflinger_ltps_vote_patch.sh"

# ── 开机自保护（防砖）─────────────────────────────────────────────────
# 内核模块注入发生在 post-fs-data；Ace6 这类内核是 PANIC_ON_OOPS + 无自动重启
# 超时，KO 一旦崩就是永久 panic（表现为"刷入后不开机"）。机制：本阶段记下本次
# boot_id，service.sh 在系统启动完成并稳定一段时间后写入同一个 boot_id；下次
# 开机若发现两者不一致（上一次没走完），本次就只跑用户态部分、跳过所有内核模块
# 注入（付费侧退回 props 方案），保证设备一定能起来。
RUNTIME_DIR="$MODDIR/runtime"
BOOT_ATTEMPT_FILE="$RUNTIME_DIR/boot_attempt_id"
BOOT_COMPLETED_FILE="$RUNTIME_DIR/boot_completed_id"
BOOT_GUARD_FILE="$RUNTIME_DIR/boot_guard.txt"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '[:space:]')
BOOT_GUARD=0
mkdir -p "$RUNTIME_DIR" 2>/dev/null
# 判断"上一次开机是否走完"：post-fs-data 记下本次 boot_id，service.sh 在系统
# 起来一段时间后写下同一个 boot_id；两者不一致（或只有 attempt 没有 completed）
# 说明上一次开机中途崩了，本次启用保护。
if [ -n "$BOOT_ID" ]; then
    PREV_ATTEMPT=$(sed -n '1p' "$BOOT_ATTEMPT_FILE" 2>/dev/null | tr -d '[:space:]')
    PREV_COMPLETED=$(sed -n '1p' "$BOOT_COMPLETED_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$PREV_ATTEMPT" ] && [ "$PREV_COMPLETED" != "$PREV_ATTEMPT" ]; then
        BOOT_GUARD=1
    fi
    if [ "$BOOT_GUARD" = "1" ]; then
        {
            printf 'detected=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
            printf 'previous_boot_id=%s\n' \
                "$(sed -n '1p' "$BOOT_ATTEMPT_FILE" 2>/dev/null | tr -d '[:space:]')"
            printf 'previous_completed_id=%s\n' \
                "$(sed -n '1p' "$BOOT_COMPLETED_FILE" 2>/dev/null | tr -d '[:space:]')"
            printf 'action=skip-kernel-module-injection-this-boot\n'
        } > "$BOOT_GUARD_FILE" 2>/dev/null
    else
        rm -f "$BOOT_GUARD_FILE" 2>/dev/null
    fi
    printf '%s\n' "$BOOT_ID" > "$BOOT_ATTEMPT_FILE" 2>/dev/null
fi
export MURONG_BOOT_GUARD="$BOOT_GUARD"

# Write the premium authorization bridge (frozen contract 16.4). Root writes
# this after lease verification; the paid Hook and paid daemon read it as their
# ONLY authorization source (never written from the WebUI). It is reset to 0
# here first so a leftover "1" from a previous boot can never leak into this
# boot. The paid package overwrites it with the verified values below.
write_bridge() {
    # $1 = premium_enabled (0/1), $2 = premium_features (comma list, may be empty)
    mkdir -p "$MODDIR/runtime" 2>/dev/null
    chmod 0755 "$MODDIR/runtime" 2>/dev/null
    _tmp="$MODDIR/runtime/premium_enabled.tmp.$$"
    printf '%s\n' "$1" > "$_tmp" 2>/dev/null && \
        mv -f "$_tmp" "$MODDIR/runtime/premium_enabled" 2>/dev/null
    chmod 0644 "$MODDIR/runtime/premium_enabled" 2>/dev/null
    _tmp="$MODDIR/runtime/premium_features.tmp.$$"
    printf '%s\n' "$2" > "$_tmp" 2>/dev/null && \
        mv -f "$_tmp" "$MODDIR/runtime/premium_features" 2>/dev/null
    chmod 0644 "$MODDIR/runtime/premium_features" 2>/dev/null
    # /data/adb is root-only, so publish the verified boot snapshot through
    # read-only system properties for system_server and app-scoped Hooks.
    setprop sys.murong.premium_enabled "$1" 2>/dev/null || true
    setprop sys.murong.premium_features "$2" 2>/dev/null || true
}
write_bridge 0 ""

# RMX5200's stock LTPS framework can resolve QHD60 correctly, but a stale
# object-animation entry in SurfaceFlinger's vendor vote map can keep the
# overclocked 170Hz mode selected. For the free stock_ltps policy only, filter
# insertion of that exact internal vote name before SurfaceFlinger starts. It
# also bypasses the stale AP-scale table that otherwise remaps OTI's correct
# QHD60 pointer to 170Hz. This preserves each vote's selected mode instead of
# locking 60, so touch can still select the user ceiling. Vote removal and
# every other FRTC/OTI request retain the vendor path. The helper builds from
# this OTA's binary and fails closed on a complete instruction/context
# mismatch; other display policies never enter this path.
if [ -f "$LTPS_VOTE_HELPER" ]; then
    sh "$LTPS_VOTE_HELPER" apply >/dev/null 2>&1 || true
fi

# /my_product is EROFS and is not replaced by a normal module directory.
# Apply the semantically validated free VRR + refresh-rate configuration
# through a bind mount; an invalid source or model mismatch fails closed.
if [ -f "$COLOROS_CONFIG_HELPER" ]; then
    sh "$COLOROS_CONFIG_HELPER" apply >/dev/null 2>&1 || true
fi

# HMBIRD is supplied by the persistent DTBO written during installation.
# The retired live-OF sidecar path is intentionally disabled because it can
# block boot before the vendor consumer has initialized.

[ -f "$DISPLAY_HELPER" ] || exit 0
# Preserve the original two-stage ownership: the free DRM backend publishes
# the overclock modes first, then the paid LTPO provider appends 30/10/1Hz to
# that live mode array.  The LTPO helper no longer treats the DRM module as an
# error; loading it after DRM is the supported RMX5200 composition.
if [ "$BOOT_GUARD" = "1" ]; then
    printf '%s boot-guard: skipped display kernel-module injection\n' \
        "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" >> "$MODDIR/daemon.log" 2>/dev/null
else
    if [ ! -d /sys/module/rmx5200_drm_modes ]; then
        sh "$DISPLAY_HELPER" boot-apply >/dev/null 2>&1
    fi
fi

if [ -f "$PREMIUM_POST_FS" ]; then
    . "$GATE_HELPER" 2>/dev/null
    gate_normalize_premium_scripts >/dev/null 2>&1 || true
    REMOVE_PREMIUM=$(gate_json_field "$GATE_STATE_FILE" remove_premium)
    if [ "$REMOVE_PREMIUM" != "1" ]; then
        sh "$PREMIUM_POST_FS" >/dev/null 2>&1 || true
    fi
fi
exit 0
