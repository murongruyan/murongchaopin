#!/system/bin/sh
# WebUI Handler Script

MOD_PATH="${MURONGCHAOPIN_MOD_PATH:-/data/adb/modules/murongchaopin}"
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
DISPLAY_HELPER="$MOD_PATH/scripts/display_backend.sh"
HMBIRD_HELPER="$MOD_PATH/scripts/hmbird_backend.sh"
HMBIRD_PATCHER="$MOD_PATH/scripts/patch_hmbird_dtbo.awk"
GATE_HELPER="$MOD_PATH/scripts/display_license_gate.sh"
PREMIUM_PATH="$MOD_PATH/premium"
ADFR_LOCK_HELPER="$PREMIUM_PATH/scripts/adfr_lock.sh"
GENERIC_ADFR_HELPER="$PREMIUM_PATH/scripts/generic_adfr_policy.sh"
SF_VOTE_HELPER="$PREMIUM_PATH/scripts/surfaceflinger_vote_patch.sh"
SF_RISE_HELPER="$PREMIUM_PATH/scripts/surfaceflinger_ltpo_rise_patch.sh"
MEMC_GATE_HELPER="$PREMIUM_PATH/scripts/libpwiris_memc_gate_patch.sh"
COLOROS_PREMIUM_HELPER="$PREMIUM_PATH/scripts/coloros_config_premium.sh"
PREMIUM_SYSTEM_OVERLAY_HELPER="$PREMIUM_PATH/scripts/premium_system_overlay.sh"
ADFR_POLICY_FILE="$MOD_PATH/config/rmx5200_adfr_mode.txt"
ADFR_TEST_BYPASS_FILE="$MOD_PATH/config/adfr_lock_test_disabled"
DISPLAY_POLICY_FILE="$MOD_PATH/config/rmx5200_display_policy.txt"
LTPO_BOOT_TOKEN_FILE="$MOD_PATH/config/rmx5200_ltpo_boot_test_once"
LTPO_RISE_TOKEN_FILE="$MOD_PATH/config/rmx5200_ltpo_rise_boot_test_once"
DTS_BACKEND_FILE="$MOD_PATH/config/dts_backend.txt"
DRM_SPECS_FILE="$MOD_PATH/runtime/drm_modes.txt"
CUSTOM_RATES_FILE="$MOD_PATH/config/custom_refresh_rates.txt"
MODE_MANIFEST_FILE="$MOD_PATH/config/display_mode_manifest.txt"
SETTINGS_BRIDGE_HELPER="$MOD_PATH/scripts/display_settings_bridge.sh"
MODE_MANIFEST_HELPER="$MOD_PATH/scripts/mode_manifest.sh"
COLOROS_CONFIG_HELPER="$MOD_PATH/scripts/coloros_config.sh"
VIDEO_MEMC_APPS_FILE="$MOD_PATH/config/video_memc_apps.txt"
GAME_ASSISTANT_APPS_FILE="$MOD_PATH/config/game_assistant_apps.txt"
sync_game_assistant_property() {
    local value=""
    if [ -f "$GAME_ASSISTANT_APPS_FILE" ]; then
        value=$(tr '\n' ',' < "$GAME_ASSISTANT_APPS_FILE" | sed 's/,$//')
    fi
    setprop sys.murong.game_assistant_apps "$value" 2>/dev/null || true
}
VIDEO_MOTION_TARGET_KEY="murong_video_motion_target_rate"
BASE_API_URL="https://murongdiaodu.rl1.cc/api"
STOCK_DTBO="$IMG_DIR/dtbo.img"
STOCK_MANIFEST="$IMG_DIR/dtbo.img.sha256"
STOCK_RECOVERY="$IMG_DIR/dtbo.img.gz"
APPLIED_MANIFEST="$IMG_DIR/dtbo.applied.sha256"
DTBO_APPLY_LOCK_DIR="$MOD_PATH/runtime/dtbo_apply.lock"

[ -f "$AVB_HELPER" ] && . "$AVB_HELPER"
[ -r "$MODE_MANIFEST_HELPER" ] && . "$MODE_MANIFEST_HELPER"
[ -f "$GATE_HELPER" ] && . "$GATE_HELPER"

# require_premium <feature> - deny premium actions without a verified lease.
# Exit codes: 0 authorized, 2 grace (allowed with warning), 1 denied.
require_premium() {
    if [ ! -f "$GATE_HELPER" ]; then
        echo "Error: premium feature requires authorization (gate missing)"
        exit 1
    fi
    gate_check "$1"
    GATE_RC=$?
    if [ "$GATE_RC" = 1 ]; then
        echo "Error: premium feature requires authorization: $GATE_REASON"
        exit 1
    fi
    if [ "$GATE_RC" = 2 ]; then
        echo "Warning: lease expired, offline grace active"
    fi
    return 0
}

# A valid lease is not enough to apply a display policy: the corresponding
# signed runtime component must also be present.  Older package builds silently
# omitted these files, which left the WebUI persisting a policy that could never
# become active after reboot.
premium_payload_ready() {
    case "$1" in
        custom_ltpo)
            [ -r "$PREMIUM_PATH/bin/rmx5200_ltpo_modes.ko" ] &&
                [ -r "$PREMIUM_PATH/config/rmx5200_ltpo_modes.sha256" ] &&
                [ -x "$PREMIUM_PATH/scripts/rmx5200_ltpo_experiment.sh" ]
            ;;
        adfr_disable)
            [ -r "$PREMIUM_PATH/bin/rmx5200_adfr_lock.ko" ] &&
                [ -x "$PREMIUM_PATH/scripts/adfr_lock.sh" ]
            ;;
        *) return 1 ;;
    esac
}

require_premium_payload() {
    premium_payload_ready "$1" && return 0
    echo "Error: premium runtime component is missing; reinstall the paid package"
    return 1
}

mkdir -p "$(dirname "$CONFIG_FILE")"
[ ! -f "$CONFIG_FILE" ] && echo "1" > "$CONFIG_FILE"
[ ! -f "$DTS_BACKEND_FILE" ] && echo "dtbo" > "$DTS_BACKEND_FILE"
[ ! -f "$ADFR_POLICY_FILE" ] && printf 'on\n' > "$ADFR_POLICY_FILE"
[ ! -f "$DISPLAY_POLICY_FILE" ] && printf 'stock_ltps\n' > "$DISPLAY_POLICY_FILE"

mode_semantic_for_id() {
    MODE_LINE=$(dumpsys SurfaceFlinger 2>/dev/null | \
        grep -oE "id=$1, hwcId=[0-9]+, resolution=[0-9]+x[0-9]+, vsyncRate=[0-9.]+" | head -n 1)
    [ -n "$MODE_LINE" ] || return 1
    MODE_WIDTH=$(printf '%s\n' "$MODE_LINE" | sed -n 's/.*resolution=\([0-9]*\)x[0-9]*.*/\1/p')
    MODE_FPS=$(printf '%s\n' "$MODE_LINE" | sed -n 's/.*vsyncRate=\([0-9.]*\).*/\1/p' | awk '{printf "%d", $1 + 0.5}')
    case "$MODE_WIDTH" in
        1080) printf 'FHD+ %s\n' "$MODE_FPS" ;;
        1440) printf 'QHD+ %s\n' "$MODE_FPS" ;;
        *) return 1 ;;
    esac
}

read_adfr_policy() {
    ADFR_POLICY=$(sed -n '1{s/\r$//;p;q;}' "$ADFR_POLICY_FILE" 2>/dev/null | \
        tr -d '[:space:]')
    case "$ADFR_POLICY" in
        on|off) printf '%s\n' "$ADFR_POLICY" ;;
        *) printf 'on\n' ;;
    esac
}

write_adfr_policy() {
    NEW_ADFR_POLICY="$1"
    case "$NEW_ADFR_POLICY" in
        on|off) ;;
        *) return 1 ;;
    esac
    ADFR_POLICY_TMP="$ADFR_POLICY_FILE.tmp.$$"
    printf '%s\n' "$NEW_ADFR_POLICY" > "$ADFR_POLICY_TMP" || return 1
    mv -f "$ADFR_POLICY_TMP" "$ADFR_POLICY_FILE" || return 1
    chmod 0644 "$ADFR_POLICY_FILE" 2>/dev/null
}

read_display_policy() {
    DISPLAY_POLICY=$(sed -n '1{s/\r$//;p;q;}' "$DISPLAY_POLICY_FILE" 2>/dev/null |
        tr -d '[:space:]')
    case "$DISPLAY_POLICY" in
        stock_ltps|stock_ltpo|custom_ltpo|adfr_off) printf '%s\n' "$DISPLAY_POLICY" ;;
        *)
            if [ "$(read_adfr_policy)" = on ]; then
                printf 'stock_ltps\n'
            else
                printf 'adfr_off\n'
            fi
            ;;
    esac
}

write_display_policy() {
    NEW_DISPLAY_POLICY="$1"
    case "$NEW_DISPLAY_POLICY" in
        stock_ltps|stock_ltpo|custom_ltpo|adfr_off) ;;
        *) return 1 ;;
    esac
    DISPLAY_POLICY_TMP="$DISPLAY_POLICY_FILE.tmp.$$"
    printf '%s\n' "$NEW_DISPLAY_POLICY" > "$DISPLAY_POLICY_TMP" || return 1
    mv -f "$DISPLAY_POLICY_TMP" "$DISPLAY_POLICY_FILE" || return 1
    chmod 0644 "$DISPLAY_POLICY_FILE" 2>/dev/null
}

display_policy_for_model() {
    POLICY_MODEL="$1"
    POLICY_VALUE=$(read_display_policy)
    case "$POLICY_MODEL" in
        RMX5200)
            case "$POLICY_VALUE" in
                custom_ltpo|adfr_off) printf '%s\n' "$POLICY_VALUE" ;;
                *) printf 'stock_ltps\n' ;;
            esac
            ;;
        PLK110|PJD110)
            case "$POLICY_VALUE" in
                adfr_off) printf 'adfr_off\n' ;;
                *) printf 'stock_ltpo\n' ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

validate_stock_backup() {
    [ -f "$AVB_HELPER" ] || return 1
    VALIDATE_SLOT=$(getprop ro.boot.slot_suffix)
    VALIDATE_PARTITION="/dev/block/by-name/dtbo$VALIDATE_SLOT"
    VALIDATE_SIZE=$(blockdev --getsize64 "$VALIDATE_PARTITION" 2>/dev/null)
    chmod +x "$BIN_DIR/avbtool/avbtool" "$BIN_DIR/openssl" 2>/dev/null
    dtbo_validate_stock_backup "$STOCK_DTBO" "$STOCK_MANIFEST" \
        "$VALIDATE_SIZE" "$BIN_DIR"
}

ensure_stock_backup() {
    if validate_stock_backup; then
        if ! dtbo_validate_stock_recovery "$STOCK_MANIFEST" "$STOCK_RECOVERY"; then
            dtbo_write_stock_recovery "$STOCK_DTBO" "$STOCK_MANIFEST" \
                "$STOCK_RECOVERY" || return 1
        fi
        chmod 0444 "$STOCK_DTBO" "$STOCK_MANIFEST" "$STOCK_RECOVERY" 2>/dev/null
        return 0
    fi

    [ -f "$AVB_HELPER" ] || return 1
    VALIDATE_SLOT=$(getprop ro.boot.slot_suffix)
    VALIDATE_PARTITION="/dev/block/by-name/dtbo$VALIDATE_SLOT"
    VALIDATE_SIZE=$(blockdev --getsize64 "$VALIDATE_PARTITION" 2>/dev/null)
    if dtbo_recover_stock_backup "$STOCK_DTBO" "$STOCK_MANIFEST" \
        "$STOCK_RECOVERY" "$VALIDATE_SIZE" "$BIN_DIR" &&
       validate_stock_backup; then
        STOCK_BACKUP_RECOVERED=1
        return 0
    fi
    return 1
}

stock_guard_begin() {
    STOCK_BACKUP_RECOVERED=0
    ensure_stock_backup || {
        echo "错误：原厂 DTBO 基线无效，Web 工作区已停止"
        return 1
    }
    STOCK_GUARD_HASH=$(dtbo_hash_file "$STOCK_DTBO")
    [ "${#STOCK_GUARD_HASH}" -eq 64 ] || return 1
    # A repair before this operation is acceptable; a repair during it is not.
    STOCK_BACKUP_RECOVERED=0
}

stock_guard_end() {
    ensure_stock_backup || {
        echo "错误：Web 操作后原厂 DTBO 基线校验失败"
        return 1
    }
    STOCK_GUARD_HASH_AFTER=$(dtbo_hash_file "$STOCK_DTBO")
    if [ "$STOCK_GUARD_HASH_AFTER" != "$STOCK_GUARD_HASH" ]; then
        echo "错误：Web 操作改变了原厂 DTBO 基线"
        return 1
    fi
    if [ "$STOCK_BACKUP_RECOVERED" = 1 ]; then
        echo "错误：检测到 Web 覆盖原厂 DTBO，已从压缩副本自动恢复"
        return 1
    fi
    return 0
}

dtbo_apply_lock_pid_alive() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$1" 2>/dev/null
}

dtbo_apply_lock_active() {
    DTBO_APPLY_LOCK_ACTIVE=0
    [ -d "$DTBO_APPLY_LOCK_DIR" ] || return 1
    DTBO_LOCK_PID=$(sed -n '1p' "$DTBO_APPLY_LOCK_DIR/pid" 2>/dev/null |
        tr -d '[:space:]')
    if [ -z "$DTBO_LOCK_PID" ]; then
        sleep 1
        DTBO_LOCK_PID=$(sed -n '1p' "$DTBO_APPLY_LOCK_DIR/pid" 2>/dev/null |
            tr -d '[:space:]')
    fi
    if dtbo_apply_lock_pid_alive "$DTBO_LOCK_PID"; then
        DTBO_APPLY_LOCK_ACTIVE=1
        return 0
    fi
    return 1
}

acquire_dtbo_apply_lock() {
    DTBO_APPLY_LOCK_ACTIVE=0
    DTBO_APPLY_LOCK_QUIET_ACTIVE="${1:-0}"
    mkdir -p "$MOD_PATH/runtime" || return 1
    DTBO_APPLY_LOCK_TOKEN="$$.$(date +%s 2>/dev/null)"

    if ! mkdir "$DTBO_APPLY_LOCK_DIR" 2>/dev/null; then
        DTBO_LOCK_PID=$(sed -n '1p' "$DTBO_APPLY_LOCK_DIR/pid" 2>/dev/null |
            tr -d '[:space:]')
        if [ -z "$DTBO_LOCK_PID" ]; then
            sleep 1
            DTBO_LOCK_PID=$(sed -n '1p' "$DTBO_APPLY_LOCK_DIR/pid" 2>/dev/null |
                tr -d '[:space:]')
        fi
        if dtbo_apply_lock_pid_alive "$DTBO_LOCK_PID"; then
            DTBO_APPLY_LOCK_ACTIVE=1
            if [ "$DTBO_APPLY_LOCK_QUIET_ACTIVE" != 1 ]; then
                echo "Error: 已有 DTBO 应用任务正在运行（PID $DTBO_LOCK_PID），请等待当前任务完成"
            fi
            return 1
        fi

        DTBO_STALE_LOCK="$DTBO_APPLY_LOCK_DIR.stale.$$"
        if ! mv "$DTBO_APPLY_LOCK_DIR" "$DTBO_STALE_LOCK" 2>/dev/null; then
            echo "Error: DTBO 应用任务锁正被其他进程更新，请稍后重试"
            return 1
        fi
        rm -f "$DTBO_STALE_LOCK/pid" "$DTBO_STALE_LOCK/token" 2>/dev/null
        rmdir "$DTBO_STALE_LOCK" 2>/dev/null
        if ! mkdir "$DTBO_APPLY_LOCK_DIR" 2>/dev/null; then
            echo "Error: 无法取得 DTBO 应用任务锁，请稍后重试"
            return 1
        fi
    fi

    printf '%s\n' "$DTBO_APPLY_LOCK_TOKEN" > "$DTBO_APPLY_LOCK_DIR/token" || {
        rmdir "$DTBO_APPLY_LOCK_DIR" 2>/dev/null
        return 1
    }
    printf '%s\n' "$$" > "$DTBO_APPLY_LOCK_DIR/pid" || {
        rm -f "$DTBO_APPLY_LOCK_DIR/token"
        rmdir "$DTBO_APPLY_LOCK_DIR" 2>/dev/null
        return 1
    }
    return 0
}

claim_dtbo_apply_lock() {
    DTBO_CLAIM_TOKEN="$1"
    [ -n "$DTBO_CLAIM_TOKEN" ] || return 1
    [ "$(sed -n '1p' "$DTBO_APPLY_LOCK_DIR/token" 2>/dev/null)" = \
      "$DTBO_CLAIM_TOKEN" ] || return 1
    DTBO_APPLY_LOCK_TOKEN="$DTBO_CLAIM_TOKEN"
    printf '%s\n' "$$" > "$DTBO_APPLY_LOCK_DIR/pid" || return 1
}

release_dtbo_apply_lock() {
    [ -n "${DTBO_APPLY_LOCK_TOKEN:-}" ] || return 0
    [ "$(sed -n '1p' "$DTBO_APPLY_LOCK_DIR/token" 2>/dev/null)" = \
      "$DTBO_APPLY_LOCK_TOKEN" ] || return 0
    rm -f "$DTBO_APPLY_LOCK_DIR/pid" "$DTBO_APPLY_LOCK_DIR/token" 2>/dev/null
    rmdir "$DTBO_APPLY_LOCK_DIR" 2>/dev/null
}

arm_dtbo_apply_lock_cleanup() {
    trap 'release_dtbo_apply_lock' 0 1 2 15
}

read_dts_backend() {
    DTS_BACKEND=$(sed -n '1p' "$DTS_BACKEND_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$DTS_BACKEND" in
        dtbo|drm) echo "$DTS_BACKEND" ;;
        *) echo "dtbo" ;;
    esac
}

write_dts_backend() {
    NEW_BACKEND="$1"
    case "$NEW_BACKEND" in
        dtbo|drm) ;;
        *) return 1 ;;
    esac
    BACKEND_TMP="$DTS_BACKEND_FILE.tmp.$$"
    printf '%s\n' "$NEW_BACKEND" > "$BACKEND_TMP" || return 1
    mv -f "$BACKEND_TMP" "$DTS_BACKEND_FILE" || return 1
    chmod 0644 "$DTS_BACKEND_FILE" 2>/dev/null
}

dtbo_partition_matches_stock() {
    [ -f "$STOCK_DTBO" ] || return 1
    [ -f "$AVB_HELPER" ] || return 1
    TRANSITION_SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
    TRANSITION_PARTITION="/dev/block/by-name/dtbo$TRANSITION_SLOT"
    TRANSITION_SIZE=$(wc -c < "$STOCK_DTBO" 2>/dev/null | tr -d '[:space:]')
    case "$TRANSITION_SIZE" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(dtbo_hash_file "$STOCK_DTBO")" = \
      "$(dtbo_hash_device_prefix "$TRANSITION_PARTITION" "$TRANSITION_SIZE")" ]
}

prepare_backend_transition() {
    TRANSITION_TARGET="$1"
    case "$TRANSITION_TARGET" in
        drm)
            # Build from the verified stock baseline. All models add the free
            # HMBIRD node; PJD110 also keeps its DTBO-side capacity unlock.
            # Display timing remains stock and the selected DRM-KO is the sole
            # owner of overclock modes.
            ensure_stock_backup || {
                echo "错误：无法验证原厂 DTBO，拒绝切换到 DRM-KO"
                return 1
            }
            TRANSITION_SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
            TRANSITION_PARTITION="/dev/block/by-name/dtbo$TRANSITION_SLOT"
            [ -f "$HMBIRD_HELPER" ] || {
                echo "错误：缺少免费风驰兼容后端"
                return 1
            }
            echo "正在从原厂基线生成 KO 配套 DTBO（PJD110 含解容，显示 timing 不变）..."
            sh "$HMBIRD_HELPER" prepare-dtbo "$TRANSITION_PARTITION" || return 1
            ;;
        dtbo)
            # A loaded DRM mode injector is kept until the reboot boundary;
            # display_backend.sh deliberately offers no online unload path.
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

run_process_dts() {
    MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
    DTS_BACKEND=$(read_dts_backend)
    if [ "$MODEL" = RMX5200 ] && [ "$DTS_BACKEND" = dtbo ]; then
        echo "RMX5200 display mode fix: dropping four native AE084 FHD timings"
        ./process_dts --rmx5200-drop-stock-fhd
    else
        ./process_dts
    fi
    OGKI_PROCESS_RC=$?
    [ "$OGKI_PROCESS_RC" -eq 0 ] || return "$OGKI_PROCESS_RC"

    # Display processing remains model-specific. HMBIRD normalization is a
    # separate structure-only pass and never consumes the model/project ID.
    case "$(getprop ro.soc.model 2>/dev/null | tr -d '[:space:]')" in
        SM8850|SM8850P|SM8845|MT6995) HMBIRD_TYPE=HMBIRD_EXT ;;
        SM8750|SM8750P|SM8650|SM8650P|MT6991|MT6993) HMBIRD_TYPE=HMBIRD_OGKI ;;
        *) return 1 ;;
    esac
    [ -r "$HMBIRD_PATCHER" ] || return 1
    HMBIRD_PATCH_COUNT=0
    HMBIRD_DTS_COUNT=0
    for HMBIRD_DTS in "$BIN_DIR"/dtbo_dts/*.dts; do
        [ -f "$HMBIRD_DTS" ] || continue
        HMBIRD_DTS_COUNT=$((HMBIRD_DTS_COUNT + 1))
        HMBIRD_TMP="$HMBIRD_DTS.hmbird.$$"
        awk -v requested_type="$HMBIRD_TYPE" -f "$HMBIRD_PATCHER" \
            "$HMBIRD_DTS" > "$HMBIRD_TMP"
        HMBIRD_RC=$?
        case "$HMBIRD_RC" in
            0)
                mv -f "$HMBIRD_TMP" "$HMBIRD_DTS" || return 1
                HMBIRD_PATCH_COUNT=$((HMBIRD_PATCH_COUNT + 1))
                ;;
            *) rm -f "$HMBIRD_TMP"; return 1 ;;
        esac
    done
    [ "$HMBIRD_DTS_COUNT" -gt 0 ] &&
        [ "$HMBIRD_PATCH_COUNT" -eq "$HMBIRD_DTS_COUNT" ] || return 1
    return 0
}

drm_profile_spec_defaults() {
    DRM_SPEC_RES=""
    DRM_SPEC_DEFAULTS=""
    MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
    case "$MODEL" in
        RMX5200)
            DRM_SPEC_RES=$(mode_manifest_resolution RMX5200) || return 1
            DRM_SPEC_DEFAULTS=$(mode_manifest_specs RMX5200 drm) || return 1
            ;;
        PLK110)
            DRM_SPEC_RES=$(mode_manifest_resolution PLK110) || return 1
            DRM_SPEC_DEFAULTS=$(mode_manifest_specs PLK110 drm) || return 1
            ;;
        PJD110|*)
            if [ "$MODEL" = PJD110 ]; then
                DRM_SPEC_RES=$(mode_manifest_resolution PJD110) || return 1
                DRM_SPEC_DEFAULTS=""
            else
                return 1
            fi
            ;;
    esac
    return 0
}

remember_custom_rate() {
    CUSTOM_RATE_VALUE="$1"
    case "$CUSTOM_RATE_VALUE" in
        ''|*[!0-9]*) return 1 ;;
    esac
    mkdir -p "$(dirname "$CUSTOM_RATES_FILE")" || return 1
    touch "$CUSTOM_RATES_FILE" || return 1
    grep -Fxq "$CUSTOM_RATE_VALUE" "$CUSTOM_RATES_FILE" 2>/dev/null ||
        printf '%s\n' "$CUSTOM_RATE_VALUE" >> "$CUSTOM_RATES_FILE"
    chmod 0644 "$CUSTOM_RATES_FILE" 2>/dev/null
}

forget_custom_rate() {
    CUSTOM_RATE_VALUE="$1"
    [ -s "$CUSTOM_RATES_FILE" ] || return 0
    CUSTOM_RATES_TMP="$CUSTOM_RATES_FILE.tmp.$$"
    awk -v rate="$CUSTOM_RATE_VALUE" '$0 != rate' "$CUSTOM_RATES_FILE" \
        > "$CUSTOM_RATES_TMP" && mv -f "$CUSTOM_RATES_TMP" "$CUSTOM_RATES_FILE"
}

ensure_drm_specs_file() {
    [ -s "$DRM_SPECS_FILE" ] && return 0
    drm_profile_spec_defaults || return 1
    mkdir -p "$(dirname "$DRM_SPECS_FILE")" || return 1
    printf '%s\n' "$DRM_SPEC_DEFAULTS" > "$DRM_SPECS_FILE" || return 1
    chmod 0644 "$DRM_SPECS_FILE" 2>/dev/null
}

drm_add_spec() {
    RATE="$1"
    CLOCK="${2:-0}"
    TRANSFER="${3:-0}"
    SOURCE_REFRESH="${4:-0}"
    case "$RATE" in
        ''|*[!0-9]*) echo "错误：刷新率必须是整数"; return 1 ;;
    esac
    [ "$RATE" -ge 20 ] 2>/dev/null && [ "$RATE" -le 300 ] 2>/dev/null || {
        echo "错误：刷新率必须在 20-300Hz 范围内"; return 1;
    }
    for VALUE in "$CLOCK" "$TRANSFER" "$SOURCE_REFRESH"; do
        case "$VALUE" in ''|*[!0-9]*) echo "错误：时钟、传输时间和基准 timing 必须是整数"; return 1 ;; esac
    done
    [ "$TRANSFER" -eq 0 ] 2>/dev/null || {
        [ "$TRANSFER" -ge 1000 ] 2>/dev/null && [ "$TRANSFER" -le 20000 ] 2>/dev/null;
    } || { echo "错误：传输时间必须为 1000-20000us，0 表示自动"; return 1; }
    [ "$SOURCE_REFRESH" -eq 0 ] 2>/dev/null || {
        [ "$SOURCE_REFRESH" -ge 20 ] 2>/dev/null && [ "$SOURCE_REFRESH" -le 300 ] 2>/dev/null;
    } || { echo "错误：基准 timing 必须为 20-300Hz，0 表示自动"; return 1; }
    ensure_drm_specs_file || {
        echo "错误：当前机型没有已验证的 DRM-KO 自定义规格路径"; return 1;
    }
    drm_profile_spec_defaults || return 1
    MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
    if [ "$MODEL" != RMX5200 ] && {
        [ "$TRANSFER" -ne 0 ] 2>/dev/null || [ "$SOURCE_REFRESH" -ne 0 ] 2>/dev/null;
    }; then
        echo "错误：当前机型的 DRM-KO 尚未验证自定义传输时间或基准 timing"
        return 1
    fi
    CURRENT_SPECS=$(sed -n '1p' "$DRM_SPECS_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ "$MODEL" = RMX5200 ]; then
        ITEM="${DRM_SPEC_RES}@${RATE}:${CLOCK}:${TRANSFER}:${SOURCE_REFRESH}"
    elif [ "$CLOCK" -gt 0 ] 2>/dev/null; then
        ITEM="${DRM_SPEC_RES}@${RATE}:${CLOCK}"
    else
        ITEM="${DRM_SPEC_RES}@${RATE}"
    fi
    FILTERED_SPECS=$(printf '%s' "$CURRENT_SPECS" | tr ';' '\n' |
        awk -F '[@:]' -v rate="$RATE" 'NF < 2 || $2 != rate' | paste -sd ';' -)
    TMP="$DRM_SPECS_FILE.tmp.$$"
    if [ -n "$FILTERED_SPECS" ]; then
        printf '%s;%s\n' "$FILTERED_SPECS" "$ITEM" > "$TMP"
    else
        printf '%s\n' "$ITEM" > "$TMP"
    fi
    mv -f "$TMP" "$DRM_SPECS_FILE"
    remember_custom_rate "$RATE" || return 1
    echo "Success: DRM-KO 运行时规格已保存 ${ITEM}（不写入 DTBO）"
}

drm_remove_spec() {
    NODE="$1"
    RATE=$(printf '%s\n' "$NODE" | sed -n 's/[^0-9]*\([0-9][0-9]*\)[^0-9]*$/\1/p')
    [ -n "$RATE" ] || { echo "错误：无法从节点名解析刷新率"; return 1; }
    [ -s "$DRM_SPECS_FILE" ] || return 0
    CURRENT_SPECS=$(sed -n '1p' "$DRM_SPECS_FILE" | tr -d '[:space:]')
    NEW_SPECS=$(printf '%s' "$CURRENT_SPECS" | tr ';' '\n' |
        awk -F '[@:]' -v rate="$RATE" 'NF < 2 || $2 != rate' | paste -sd ';' -)
    printf '%s\n' "$NEW_SPECS" > "$DRM_SPECS_FILE"
    forget_custom_rate "$RATE" || return 1
    echo "Success: DRM-KO 运行时规格已移除 @${RATE}（不写入 DTBO）"
}

scan_drm_rates() {
    ensure_drm_specs_file || {
        echo '[]'
        return 1
    }
    DRM_SCAN_SPECS=$(sed -n '1p' "$DRM_SPECS_FILE" 2>/dev/null | tr -d '[:space:]')
    [ -n "$DRM_SCAN_SPECS" ] || {
        echo '[]'
        return 0
    }
    printf '['
    DRM_SCAN_FIRST=1
    for DRM_SCAN_ITEM in $(printf '%s' "$DRM_SCAN_SPECS" | tr ';' ' '); do
        DRM_SCAN_RES=${DRM_SCAN_ITEM%@*}
        DRM_SCAN_FIELDS=${DRM_SCAN_ITEM#*@}
        DRM_SCAN_RATE=${DRM_SCAN_FIELDS%%:*}
        DRM_SCAN_REST=${DRM_SCAN_FIELDS#*:}
        DRM_SCAN_CLOCK=0
        DRM_SCAN_TRANSFER=0
        DRM_SCAN_SOURCE=0
        if [ "$DRM_SCAN_REST" != "$DRM_SCAN_FIELDS" ]; then
            DRM_SCAN_CLOCK=${DRM_SCAN_REST%%:*}
            DRM_SCAN_REST_2=${DRM_SCAN_REST#*:}
            if [ "$DRM_SCAN_REST_2" != "$DRM_SCAN_REST" ]; then
                DRM_SCAN_TRANSFER=${DRM_SCAN_REST_2%%:*}
                DRM_SCAN_REST_3=${DRM_SCAN_REST_2#*:}
                [ "$DRM_SCAN_REST_3" = "$DRM_SCAN_REST_2" ] || DRM_SCAN_SOURCE=${DRM_SCAN_REST_3%%:*}
            fi
        fi
        case "$DRM_SCAN_RATE" in
            ''|*[!0-9]*) continue ;;
        esac
        case "$DRM_SCAN_CLOCK" in
            ''|*[!0-9]*) DRM_SCAN_CLOCK=0 ;;
        esac
        case "$DRM_SCAN_TRANSFER" in ''|*[!0-9]*) DRM_SCAN_TRANSFER=0 ;; esac
        case "$DRM_SCAN_SOURCE" in ''|*[!0-9]*) DRM_SCAN_SOURCE=0 ;; esac
        [ "$DRM_SCAN_FIRST" = 1 ] || printf ','
        printf '{"fps":%s,"clock":%s,"transfer":%s,"base":%s,"node":"runtime@%s","file":"runtime/drm_modes.txt","width":%s,"height":%s}' \
            "$DRM_SCAN_RATE" "$DRM_SCAN_CLOCK" "$DRM_SCAN_TRANSFER" "$DRM_SCAN_SOURCE" "$DRM_SCAN_RATE" \
            "${DRM_SCAN_RES%x*}" "${DRM_SCAN_RES#*x}"
        DRM_SCAN_FIRST=0
    done
    printf ']\n'
}

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
    if ! ensure_stock_backup; then
        echo "错误：原厂 DTBO 备份的哈希或官方 AVB 完整性校验失败"
        return 1
    fi

    echo "正在提取官方 VBMeta 并重算偏移..."
    if ! dtbo_apply_stock_avb "$STOCK_DTBO" "$NEW_DTBO" "$FINAL_DTBO" "$PARTITION_SIZE" "$BIN_DIR"; then
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
    IMAGE_SIZE=$(wc -c < "$FINAL_DTBO" 2>/dev/null | tr -d '[:space:]')
    PARTITION_SIZE=$(blockdev --getsize64 "$DTBO_PARTITION" 2>/dev/null)
    case "$PARTITION_SIZE" in
        ''|*[!0-9]*|0)
            echo "错误：无法读取 DTBO 分区容量，拒绝刷入"
            return 1
            ;;
    esac
    echo "  目标分区: $DTBO_PARTITION"
    echo "  写入镜像: $(basename "$FINAL_DTBO") ($IMAGE_SIZE 字节)"
    if dtbo_write_partition "$FINAL_DTBO" "$DTBO_PARTITION"; then
        dtbo_write_device_manifest "$DTBO_PARTITION" "$PARTITION_SIZE" \
            "$APPLIED_MANIFEST" >/dev/null 2>&1 || true
        echo "Success: 刷入成功！请重启生效。"
        return 0
    else
        echo "错误：刷入失败（分区未被修改）"
        return 1
    fi
}

do_ko_prepare() {
    MODEL=$(getprop ro.product.vendor.model)
    case "$MODEL" in
        RMX5200)
            KO_PROFILE=RMX5200
            KO_MODULE="$BIN_DIR/rmx5200_drm_modes.ko"
            KO_RATES="运行时 mode_specs（清单：$(mode_manifest_rates RMX5200 drm 2>/dev/null | tr ',' '/')；当前实测稳定到170，175有细线，180不可用）"
            ;;
        PLK110)
            KO_PROFILE=PLK110
            KO_MODULE="$BIN_DIR/plk110_drm_modes.ko"
            KO_RATES="清单默认 170/175/180/185/190/195/199Hz；首次加载按运行时 ABI 自检"
            ;;
        PJD110)
            KO_PROFILE=PJD110
            KO_MODULE="$BIN_DIR/pjd110_drm_modes.ko"
            KO_RATES="1440x3168 运行时 mode_specs；删除原生 60/90Hz；配套 DTBO 保留 6000mAh 解容"
            ;;
        *)
            echo "错误：未支持的设备型号 $MODEL"
            return 1
            ;;
    esac
    if [ ! -r "$KO_MODULE" ]; then
        echo "错误：缺少 $KO_PROFILE Qualcomm DRM injector: $(basename "$KO_MODULE")"
        return 1
    fi
    chmod 600 "$KO_MODULE" 2>/dev/null
    echo "Qualcomm DRM injector 已就绪：$KO_PROFILE 档位 $KO_RATES"
    echo "DRM-KO 通过 mode_specs 复制 Qualcomm timing，并在启动早期由 display_backend.sh 加载。高刷 timing 不写入 DTBO。"
    echo "RMX5200/PJD110 的 WebUI 自定义档位保存到 runtime/drm_modes.txt，不会写入 DTBO。"
    echo "风驰节点由安装阶段写入持久 DTBO；开机不再侧载独立 live-OF 模块，避免动态设备树修改卡住启动。"
    echo "DRM 后端不会把高刷 timing 写入 DTBO；PJD110 的 60/90Hz 去重由 6.1 DRM-KO 在内存中完成，解容由启动前配套 DTBO 生效。"
    return 0
}

do_apply_selected_backend() {
    SELECTED_BACKEND=$(read_dts_backend)
    echo "当前 DTS 后端: $SELECTED_BACKEND"
    case "$SELECTED_BACKEND" in
        dtbo)
            do_pack && do_merge_avb && do_flash
            ;;
        drm)
            prepare_backend_transition drm || return 1
            do_ko_prepare || return 1
            echo "Success: DRM-KO 已准备；重启时按 runtime/drm_modes.txt 早期加载，DTBO 仅含免费风驰兼容节点。"
            ;;
    esac
}

plan_selected_backend() {
    SELECTED_BACKEND=$(read_dts_backend)
    printf 'configured_backend=%s\n' "$SELECTED_BACKEND"
    case "$SELECTED_BACKEND" in
        dtbo)
            echo "planned_backend=dtbo"
            ;;
        drm)
            do_ko_prepare || return 1
            echo "planned_backend=drm"
            ;;
    esac
}

# 阶段 0（flash_dtbo 专用）：提取→解包→通用补丁→smart_add
do_smart_add() {
    CUSTOM_RATE="$1"
    if [ "$(read_dts_backend)" = drm ]; then
        if [ -n "$CUSTOM_RATE" ]; then
            drm_add_spec "$CUSTOM_RATE" || return $?
        else
            ensure_drm_specs_file || return 1
        fi
        do_ko_prepare
        return $?
    fi
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
    run_process_dts
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
            remember_custom_rate "$CUSTOM_RATE" || return 1
            echo "Success: 自定义刷新率节点已生成。"
        else
            echo "错误：自定义刷新率添加失败！"
            return 1
        fi
    fi
    echo "Success: 超频流程处理完成"
    return 0
}

valid_video_package() {
    VIDEO_PACKAGE="$1"
    case "$VIDEO_PACKAGE" in ''|*[!A-Za-z0-9._]*) return 1 ;; esac
    case "$VIDEO_PACKAGE" in *.*) return 0 ;; *) return 1 ;; esac
}

valid_video_activity() {
    VIDEO_PACKAGE="$1"
    VIDEO_ACTIVITY="$2"
    case "$VIDEO_ACTIVITY" in "$VIDEO_PACKAGE/"*) ;; *) return 1 ;; esac
    VIDEO_ACTIVITY_CLASS=${VIDEO_ACTIVITY#*/}
    case "$VIDEO_ACTIVITY_CLASS" in ''|*[!A-Za-z0-9_.$]*) return 1 ;; esac
    return 0
}

apply_video_memc_config() {
    [ -f "$COLOROS_PREMIUM_HELPER" ] || return 1
    VIDEO_MEMC_APPS_FILE="$VIDEO_MEMC_APPS_FILE" \
        sh "$COLOROS_PREMIUM_HELPER" apply-premium
}

http_get_file() {
    HTTP_URL="$1"
    HTTP_OUTPUT="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location \
            --connect-timeout 10 --max-time 25 --retry 2 --retry-delay 1 \
            --proto '=https' "$HTTP_URL" -o "$HTTP_OUTPUT"
        return $?
    fi
    if [ -x /data/adb/ksu/bin/busybox ]; then
        /data/adb/ksu/bin/busybox wget -q -T 25 -O "$HTTP_OUTPUT" "$HTTP_URL"
        return $?
    fi
    return 127
}

base64url_file() {
    if [ -x "$BIN_DIR/openssl" ]; then
        "$BIN_DIR/openssl" base64 -A -in "$1" 2>/dev/null | tr '/+' '_-' | tr -d '='
    else
        base64 "$1" 2>/dev/null | tr -d '\r\n' | tr '/+' '_-' | tr -d '='
    fi
}

check_base_update() {
    UPDATE_TMP=$(mktemp) || {
        echo "Error: 无法创建更新检查临时文件"
        return 1
    }
    LOCAL_VERSION=$(sed -n 's/^version=//p' "$MOD_PATH/module.prop" 2>/dev/null |
        head -n 1 | tr -cd '0-9A-Za-z._-')
    LOCAL_VERSION_CODE=$(sed -n 's/^versionCode=//p' "$MOD_PATH/module.prop" 2>/dev/null |
        head -n 1 | tr -d '[:space:]')
    case "$LOCAL_VERSION_CODE" in ''|*[!0-9]*) LOCAL_VERSION_CODE=0 ;; esac
    [ -n "$LOCAL_VERSION" ] || LOCAL_VERSION=0

    UPDATE_URL="$BASE_API_URL/version.php?action=check&version=$LOCAL_VERSION&version_code=$LOCAL_VERSION_CODE&platform=display_module"
    if ! http_get_file "$UPDATE_URL" "$UPDATE_TMP"; then
        rm -f "$UPDATE_TMP"
        echo "Error: 无法连接模块更新服务器"
        return 1
    fi
    if [ ! -s "$UPDATE_TMP" ]; then
        rm -f "$UPDATE_TMP"
        echo "Error: 模块更新服务器返回空响应"
        return 1
    fi
    if ! grep -q '"success"[[:space:]]*:[[:space:]]*true' "$UPDATE_TMP" 2>/dev/null; then
        UPDATE_MESSAGE=$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPDATE_TMP" | head -n 1)
        rm -f "$UPDATE_TMP"
        [ -n "$UPDATE_MESSAGE" ] || UPDATE_MESSAGE="模块更新信息不可用"
        echo "Error: $UPDATE_MESSAGE"
        return 1
    fi

    echo "local_version=$LOCAL_VERSION"
    echo "local_version_code=$LOCAL_VERSION_CODE"
    echo "update_source=server"
    printf 'remote_json_b64='
    base64url_file "$UPDATE_TMP"
    printf '\n'
    rm -f "$UPDATE_TMP"
}

api_request_proxy() {
    API_METHOD="$1"
    API_PATH="$2"
    API_AUTH="$3"
    API_BODY_B64="$4"
    API_NONCE="$5"
    case "$API_METHOD" in GET|POST) ;; *) echo "Error: 非法 API 方法"; return 1 ;; esac
    case "$API_PATH" in ''|/*|*://*|*..*) API_PATH_INVALID=1 ;; *) API_PATH_INVALID=0 ;; esac
    printf '%s\n' "$API_PATH" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_./?&=%+-]*$' || API_PATH_INVALID=1
    if [ "$API_PATH_INVALID" = 1 ]; then
        echo "Error: 非法 API 路径"
        return 1
    fi
    command -v curl >/dev/null 2>&1 || {
        echo "Error: 系统缺少 curl，无法使用后端网络通道"
        return 1
    }

    set -- --silent --show-error --location --connect-timeout 10 --max-time 25 \
        --retry 2 --retry-delay 1 --proto '=https' \
        --request "$API_METHOD" -H 'Accept: application/json'
    if [ "$API_AUTH" = 1 ]; then
        [ -f "$GATE_HELPER" ] || {
            echo "Error: 授权组件缺失"
            return 1
        }
        gate_init
        API_TOKEN=$(gate_json_field "$GATE_ACCOUNT_FILE" token)
        [ -n "$API_TOKEN" ] || {
            echo "Error: 请先登录账号"
            return 1
        }
        set -- "$@" -H "Authorization: Bearer $API_TOKEN"
    fi
    if [ -n "$API_NONCE" ]; then
        case "$API_NONCE" in *[!A-Za-z0-9-]*|????????????????????????????????????????????????????????????????*)
            echo "Error: 非法请求 nonce"
            return 1
            ;;
        esac
        set -- "$@" -H "X-Display-Request-Nonce: $API_NONCE"
    fi
    API_BODY_FILE=""
    if [ "$API_METHOD" = POST ]; then
        [ -n "$API_BODY_B64" ] || {
            echo "Error: POST 请求缺少正文"
            return 1
        }
        case "$API_BODY_B64" in *[!A-Za-z0-9_-]*) echo "Error: 非法 API 正文编码"; return 1 ;; esac
        [ "${#API_BODY_B64}" -le 196608 ] 2>/dev/null || {
            echo "Error: API 请求正文过大"
            return 1
        }
        API_BODY_FILE=$(mktemp) || {
            echo "Error: 无法创建 API 正文临时文件"
            return 1
        }
        gate_b64url_decode "$API_BODY_B64" "$API_BODY_FILE" || {
            rm -f "$API_BODY_FILE"
            echo "Error: API 请求正文解码失败"
            return 1
        }
        set -- "$@" -H 'Content-Type: application/json' --data-binary "@$API_BODY_FILE"
    elif [ -n "$API_BODY_B64" ]; then
        echo "Error: GET 请求不能携带正文"
        return 1
    fi
    API_RESPONSE=$(mktemp) || {
        [ -z "$API_BODY_FILE" ] || rm -f "$API_BODY_FILE"
        echo "Error: 无法创建 API 临时文件"
        return 1
    }
    if ! curl "$@" "$BASE_API_URL/$API_PATH" -o "$API_RESPONSE"; then
        rm -f "$API_RESPONSE" "$API_BODY_FILE"
        echo "Error: 服务器网络请求失败"
        return 1
    fi
    [ -z "$API_BODY_FILE" ] || rm -f "$API_BODY_FILE"
    [ -s "$API_RESPONSE" ] || {
        rm -f "$API_RESPONSE"
        echo "Error: 服务器返回空响应"
        return 1
    }
    cat "$API_RESPONSE"
    rm -f "$API_RESPONSE"
}

api_get_proxy() {
    api_request_proxy GET "$1" "$2" "" ""
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

download_paid_package() {
    PACKAGE_ID="$1"
    EXPECTED_SHA="$2"
    case "$PACKAGE_ID" in ''|*[!0-9]*) echo "Error: 付费组件 ID 无效"; return 1 ;; esac
    case "$EXPECTED_SHA" in ''|*[!0-9a-fA-F]*) echo "Error: 付费组件哈希无效"; return 1 ;; esac
    [ "${#EXPECTED_SHA}" -eq 64 ] || { echo "Error: 付费组件哈希长度无效"; return 1; }
    command -v curl >/dev/null 2>&1 || {
        echo "Error: 系统缺少 curl，无法下载付费组件"
        return 1
    }
    [ -f "$GATE_HELPER" ] || { echo "Error: 授权组件缺失"; return 1; }
    gate_init
    API_TOKEN=$(gate_json_field "$GATE_ACCOUNT_FILE" token)
    [ -n "$API_TOKEN" ] || { echo "Error: 请先登录账号"; return 1; }

    PACKAGE_REQUEST=$(mktemp) || { echo "Error: 无法创建下载请求"; return 1; }
    TOKEN_RESPONSE=$(mktemp) || { rm -f "$PACKAGE_REQUEST"; echo "Error: 无法创建令牌响应"; return 1; }
    DEVICE_ID=$(gate_device_id)
    DEVICE_SN=$(gate_device_sn)
    [ -n "$DEVICE_SN" ] || DEVICE_SN="$DEVICE_ID"
    DEVICE_IMEI1=$(gate_device_imei1)
    DEVICE_IMEI2=$(gate_device_imei2)
    DEVICE_HASH=$(gate_device_id_hash)
    DEVICE_MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
    SOC_MODEL=$(getprop ro.soc.model 2>/dev/null)
    BUILD_FINGERPRINT=$(getprop ro.build.fingerprint 2>/dev/null)
    BASE_VERSION=$(sed -n 's/^version=//p' "$MOD_PATH/module.prop" 2>/dev/null | head -n 1 | tr -d '\r')
    KERNEL_VERSION=$(uname -r 2>/dev/null)
    BACKEND=$(sed -n '1{s/\r$//;p;q;}' "$DTS_BACKEND_FILE" 2>/dev/null | tr -d '[:space:]')
    REQUEST_NONCE=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    [ -n "$REQUEST_NONCE" ] || REQUEST_NONCE="$(date +%s)-$$"
    printf '{"device_id":"%s","sn":"%s","imei1":"%s","imei2":"%s","device_id_hash":"%s","device_model":"%s","soc_model":"%s","build_fingerprint":"%s","base_version":"%s","kernel":"%s","backend":"%s","channel":"stable"}' \
        "$(json_escape "$DEVICE_ID")" "$(json_escape "$DEVICE_SN")" \
        "$(json_escape "$DEVICE_IMEI1")" "$(json_escape "$DEVICE_IMEI2")" \
        "$(json_escape "$DEVICE_HASH")" "$(json_escape "$DEVICE_MODEL")" \
        "$(json_escape "$SOC_MODEL")" "$(json_escape "$BUILD_FINGERPRINT")" \
        "$(json_escape "$BASE_VERSION")" "$(json_escape "$KERNEL_VERSION")" \
        "$(json_escape "$BACKEND")" > "$PACKAGE_REQUEST"

    if ! curl --silent --show-error --location --connect-timeout 10 --max-time 30 \
        --retry 2 --retry-delay 1 --proto '=https' \
        -H 'Accept: application/json' -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "X-Display-Request-Nonce: $REQUEST_NONCE" \
        --data-binary "@$PACKAGE_REQUEST" \
        "$BASE_API_URL/v1/display/packages/$PACKAGE_ID/download-token" \
        -o "$TOKEN_RESPONSE"; then
        rm -f "$PACKAGE_REQUEST" "$TOKEN_RESPONSE"
        echo "Error: 获取下载令牌失败"
        return 1
    fi
    rm -f "$PACKAGE_REQUEST"
    DOWNLOAD_TOKEN=$(gate_json_field "$TOKEN_RESPONSE" download_token)
    SERVER_SHA=$(gate_json_field "$TOKEN_RESPONSE" sha256 | tr 'A-F' 'a-f')
    SERVER_DTBO_ALLOWED=0
    gate_list_contains "$TOKEN_RESPONSE" supported_backends dtbo && SERVER_DTBO_ALLOWED=1
    if [ -z "$DOWNLOAD_TOKEN" ]; then
        SERVER_MESSAGE=$(gate_json_field "$TOKEN_RESPONSE" message)
        rm -f "$TOKEN_RESPONSE"
        echo "Error: ${SERVER_MESSAGE:-未获取到下载令牌}"
        return 1
    fi
    rm -f "$TOKEN_RESPONSE"
    case "$DOWNLOAD_TOKEN" in ''|*[!A-Za-z0-9._~-]*) echo "Error: 下载令牌格式无效"; return 1 ;; esac
    EXPECTED_SHA=$(printf '%s' "$EXPECTED_SHA" | tr 'A-F' 'a-f')
    [ -z "$SERVER_SHA" ] || [ "$SERVER_SHA" = "$EXPECTED_SHA" ] || {
        echo "Error: 服务器返回的组件哈希与版本列表不一致"
        return 1
    }

    gate_package_abort >/dev/null 2>&1
    DOWNLOAD_REQUEST=$(mktemp) || {
        echo "Error: 无法创建下载请求临时文件"
        return 1
    }
    printf '{"download_token":"%s"}' "$DOWNLOAD_TOKEN" > "$DOWNLOAD_REQUEST"
    if ! curl --fail --silent --show-error --location --connect-timeout 10 --max-time 180 \
        --proto '=https' --request POST \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $API_TOKEN" \
        --data-binary "@$DOWNLOAD_REQUEST" \
        "$BASE_API_URL/v1/display/packages/$PACKAGE_ID/download" \
        -o "$GATE_DOWNLOAD_FILE"; then
        rm -f "$DOWNLOAD_REQUEST"
        gate_package_abort >/dev/null 2>&1
        echo "Error: 付费组件下载失败"
        return 1
    fi
    rm -f "$DOWNLOAD_REQUEST"
    DOWNLOADED_BYTES=$(wc -c < "$GATE_DOWNLOAD_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$DOWNLOADED_BYTES" in ''|*[!0-9]*) DOWNLOADED_BYTES=0 ;; esac
    [ "$DOWNLOADED_BYTES" -gt 0 ] && [ "$DOWNLOADED_BYTES" -le "$GATE_MAX_PACKAGE_BYTES" ] || {
        gate_package_abort >/dev/null 2>&1
        echo "Error: 付费组件大小无效"
        return 1
    }
    ACTUAL_SHA=$(gate_sha256_bin "$GATE_DOWNLOAD_FILE")
    [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || {
        gate_package_abort >/dev/null 2>&1
        echo "Error: 付费组件下载哈希校验失败"
        return 1
    }
    # 1.0.3's signed manifest predates the DTBO release-matrix correction.
    # Record the server-authorized matrix beside the staged package; the gate
    # consumes it only with this exact release ID and package SHA.
    gate_backend_override_clear
    if [ "$BACKEND" = dtbo ] && [ "$SERVER_DTBO_ALLOWED" = 1 ]; then
        gate_backend_override_write "$PACKAGE_ID" "$EXPECTED_SHA" dtbo || {
            gate_package_abort >/dev/null 2>&1
            echo "Error: 无法保存服务器 DTBO 兼容授权"
            return 1
        }
    fi
    printf '%s\n' "$DOWNLOADED_BYTES" > "$GATE_DOWNLOAD_META"
    chmod 0600 "$GATE_DOWNLOAD_FILE" "$GATE_DOWNLOAD_META" 2>/dev/null
    echo "Success: paid package staged"
    echo "downloaded_bytes=$DOWNLOADED_BYTES"
    echo "sha256=$ACTUAL_SHA"
}

version_is_newer() {
    VERSION_REMOTE="$1"
    VERSION_LOCAL="$2"
    awk -v remote="$VERSION_REMOTE" -v local="$VERSION_LOCAL" 'BEGIN {
        remote_count = split(remote, r, ".")
        local_count = split(local, l, ".")
        count = remote_count > local_count ? remote_count : local_count
        for (i = 1; i <= count; i++) {
            rv = r[i] + 0
            lv = l[i] + 0
            if (rv > lv) exit 0
            if (rv < lv) exit 1
        }
        exit 1
    }' 2>/dev/null
}

install_latest_paid_package() {
    [ -f "$GATE_HELPER" ] || {
        echo "status=skipped"
        echo "reason=authorization_helper_missing"
        return 0
    }
    gate_init
    if ! gate_lease_verify; then
        echo "status=skipped"
        echo "reason=no_valid_signed_lease"
        return 0
    fi
    API_TOKEN=$(gate_json_field "$GATE_ACCOUNT_FILE" token)
    if [ -z "$API_TOKEN" ]; then
        echo "status=skipped"
        echo "reason=account_token_missing"
        return 0
    fi

    DEVICE_ID=$(gate_device_id)
    DEVICE_SN=$(gate_device_sn)
    [ -n "$DEVICE_SN" ] || DEVICE_SN="$DEVICE_ID"
    DEVICE_IMEI1=$(gate_device_imei1)
    DEVICE_IMEI2=$(gate_device_imei2)
    DEVICE_HASH=$(gate_device_id_hash)
    DEVICE_MODEL=$(getprop ro.product.vendor.model 2>/dev/null | tr -cd 'A-Za-z0-9._-')
    SOC_MODEL=$(getprop ro.soc.model 2>/dev/null | tr -cd 'A-Za-z0-9._-')
    BASE_VERSION=$(sed -n 's/^version=//p' "$MOD_PATH/module.prop" 2>/dev/null |
        head -n 1 | tr -cd '0-9A-Za-z._-')
    KERNEL_PREFIX=$(uname -r 2>/dev/null | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    BACKEND=$(sed -n '1{s/\r$//;p;q;}' "$DTS_BACKEND_FILE" 2>/dev/null |
        tr -cd 'A-Za-z0-9._-')
    [ -n "$BACKEND" ] || BACKEND=dtbo
    if [ -z "$DEVICE_HASH" ] || [ -z "$DEVICE_MODEL" ] ||
       [ -z "$BASE_VERSION" ] || [ -z "$KERNEL_PREFIX" ]; then
        echo "status=deferred"
        echo "reason=device_compatibility_data_missing"
        return 0
    fi

    PACKAGES_RESPONSE=$(mktemp) || {
        echo "status=deferred"
        echo "reason=temporary_file_failed"
        return 0
    }
    PACKAGES_PATH="v1/display/packages?device_id=$DEVICE_ID&sn=$DEVICE_SN&imei1=$DEVICE_IMEI1&imei2=$DEVICE_IMEI2&device_id_hash=$DEVICE_HASH&device_model=$DEVICE_MODEL&soc_model=$SOC_MODEL&base_version=$BASE_VERSION&kernel=$KERNEL_PREFIX&backend=$BACKEND&channel=stable"
    if ! api_get_proxy "$PACKAGES_PATH" 1 > "$PACKAGES_RESPONSE"; then
        rm -f "$PACKAGES_RESPONSE"
        echo "status=deferred"
        echo "reason=package_query_failed"
        return 0
    fi
    if ! grep -q '"success"[[:space:]]*:[[:space:]]*true' "$PACKAGES_RESPONSE" 2>/dev/null; then
        rm -f "$PACKAGES_RESPONSE"
        echo "status=deferred"
        echo "reason=package_query_rejected"
        return 0
    fi
    if grep -q '"data"[[:space:]]*:[[:space:]]*\[\]' "$PACKAGES_RESPONSE" 2>/dev/null; then
        rm -f "$PACKAGES_RESPONSE"
        echo "status=skipped"
        echo "reason=no_compatible_package"
        return 0
    fi

    # The API is ordered by version_code descending. Trim before the next
    # top-level package; nested manifest file objects never contain an id key.
    FIRST_PACKAGE=$(mktemp) || {
        rm -f "$PACKAGES_RESPONSE"
        echo "status=deferred"
        echo "reason=temporary_file_failed"
        return 0
    }
    sed 's/},{"id"[[:space:]]*:[[:space:]]*[0-9][0-9]*.*/}/' \
        "$PACKAGES_RESPONSE" > "$FIRST_PACKAGE"
    rm -f "$PACKAGES_RESPONSE"
    REMOTE_ID=$(gate_json_number "$FIRST_PACKAGE" id)
    REMOTE_VERSION=$(gate_json_field "$FIRST_PACKAGE" version)
    REMOTE_VERSION_CODE=$(gate_json_number "$FIRST_PACKAGE" version_code)
    REMOTE_SHA=$(gate_json_field "$FIRST_PACKAGE" file_sha256 | tr 'A-F' 'a-f')
    REMOTE_STATUS=$(gate_json_field "$FIRST_PACKAGE" status)
    REMOTE_COMPATIBLE=0
    grep -q '"compatible"[[:space:]]*:[[:space:]]*true' "$FIRST_PACKAGE" 2>/dev/null &&
        REMOTE_COMPATIBLE=1
    rm -f "$FIRST_PACKAGE"

    case "$REMOTE_ID" in ''|*[!0-9]*) REMOTE_METADATA_INVALID=1 ;; *) REMOTE_METADATA_INVALID=0 ;; esac
    case "$REMOTE_VERSION_CODE" in ''|*[!0-9]*) REMOTE_METADATA_INVALID=1 ;; esac
    case "$REMOTE_VERSION" in ''|*[!0-9A-Za-z._-]*) REMOTE_METADATA_INVALID=1 ;; esac
    case "$REMOTE_SHA" in ''|*[!0-9a-f]*) REMOTE_METADATA_INVALID=1 ;; esac
    [ "${#REMOTE_SHA}" -eq 64 ] || REMOTE_METADATA_INVALID=1
    [ "$REMOTE_STATUS" = published ] || REMOTE_METADATA_INVALID=1
    [ "$REMOTE_COMPATIBLE" = 1 ] || REMOTE_METADATA_INVALID=1
    if [ "$REMOTE_METADATA_INVALID" = 1 ]; then
        echo "status=deferred"
        echo "reason=latest_package_metadata_invalid"
        return 0
    fi

    LOCAL_VERSION=$(gate_json_field "$GATE_PACKAGE_FILE" version)
    LOCAL_VERSION_CODE=$(gate_json_number "$GATE_PACKAGE_FILE" version_code)
    if [ -n "$LOCAL_VERSION_CODE" ]; then
        case "$LOCAL_VERSION_CODE" in
            *[!0-9]*) LOCAL_VERSION_CODE=0 ;;
        esac
        if [ "$LOCAL_VERSION_CODE" -ge "$REMOTE_VERSION_CODE" ] 2>/dev/null; then
            echo "status=current"
            echo "version=$LOCAL_VERSION"
            echo "version_code=$LOCAL_VERSION_CODE"
            return 0
        fi
    elif [ -n "$LOCAL_VERSION" ] && ! version_is_newer "$REMOTE_VERSION" "$LOCAL_VERSION"; then
        echo "status=current"
        echo "version=$LOCAL_VERSION"
        return 0
    fi

    echo "status=downloading"
    echo "version=$REMOTE_VERSION"
    echo "version_code=$REMOTE_VERSION_CODE"
    if ! download_paid_package "$REMOTE_ID" "$REMOTE_SHA"; then
        gate_package_abort >/dev/null 2>&1
        echo "status=deferred"
        echo "reason=package_download_failed"
        return 0
    fi
    if ! gate_package_commit "$REMOTE_SHA" "$REMOTE_ID" "$REMOTE_VERSION" "$REMOTE_VERSION_CODE"; then
        gate_package_abort >/dev/null 2>&1
        echo "status=deferred"
        echo "reason=package_verification_or_install_failed"
        return 0
    fi
    echo "status=updated"
    echo "version=$REMOTE_VERSION"
    echo "version_code=$REMOTE_VERSION_CODE"
    return 0
}


case "$1" in
    "check_base_update")
        check_base_update
        ;;

    "api_get")
        api_get_proxy "$2" "$3"
        ;;

    "api_request")
        api_request_proxy "$2" "$3" "$4" "$5" "$6"
        ;;

    "auth_package_download")
        download_paid_package "$2" "$3"
        ;;

    "auth_install_latest")
        install_latest_paid_package
        ;;

    "get_video_motion_config")
        require_premium video_memc
        VIDEO_TARGET=$(settings get secure "$VIDEO_MOTION_TARGET_KEY" 2>/dev/null)
        case "$VIDEO_TARGET" in ''|null|*[!0-9]*) VIDEO_TARGET=0 ;; esac
        echo "target=$VIDEO_TARGET"
        case "$VIDEO_TARGET" in
            60|90|120|144) echo "native_memc=1" ;;
            *) echo "native_memc=0" ;;
        esac
        if [ -f "$COLOROS_PREMIUM_HELPER" ]; then
            VIDEO_MEMC_APPS_FILE="$VIDEO_MEMC_APPS_FILE" \
                sh "$COLOROS_PREMIUM_HELPER" status-premium 2>/dev/null | \
                grep '^status=' | head -n 1
        fi
        ;;

    "set_video_motion_target")
        require_premium video_memc
        VIDEO_TARGET="$2"
        case "$VIDEO_TARGET" in
            0) ;;
            ''|*[!0-9]*) echo "Error: invalid video target"; exit 1 ;;
            *)
                [ "$VIDEO_TARGET" -ge 30 ] 2>/dev/null &&
                    [ "$VIDEO_TARGET" -le 1000 ] 2>/dev/null || {
                    echo "Error: video target must be 30-1000Hz"
                    exit 1
                }
                ;;
        esac
        settings put secure "$VIDEO_MOTION_TARGET_KEY" "$VIDEO_TARGET" || exit 1
        settings put secure osie_iris5_switch 1 >/dev/null 2>&1 || true
        settings put secure osie_motion_fluency_switch 1 >/dev/null 2>&1 || true
        if [ "$VIDEO_TARGET" = 60 ]; then
            settings put secure osie_motion_value 0 >/dev/null 2>&1 || true
        else
            settings put secure osie_motion_value 1 >/dev/null 2>&1 || true
        fi
        echo "Success: video motion target saved"
        ;;

    "get_video_motion_apps")
        [ -f "$VIDEO_MEMC_APPS_FILE" ] && cat "$VIDEO_MEMC_APPS_FILE"
        ;;

    "get_game_assistant_apps")
        [ -f "$GAME_ASSISTANT_APPS_FILE" ] && cat "$GAME_ASSISTANT_APPS_FILE"
        ;;

    "add_game_assistant_app")
        require_premium game_assistant
        GAME_PACKAGE="$2"
        valid_video_package "$GAME_PACKAGE" || {
            echo "Error: invalid package"
            exit 1
        }
        mkdir -p "$(dirname "$GAME_ASSISTANT_APPS_FILE")" || exit 1
        [ -f "$GAME_ASSISTANT_APPS_FILE" ] || : > "$GAME_ASSISTANT_APPS_FILE"
        grep -Fqx "$GAME_PACKAGE" "$GAME_ASSISTANT_APPS_FILE" 2>/dev/null ||
            printf '%s\n' "$GAME_PACKAGE" >> "$GAME_ASSISTANT_APPS_FILE"
        sort -u "$GAME_ASSISTANT_APPS_FILE" > "$GAME_ASSISTANT_APPS_FILE.tmp.$$" || exit 1
        mv -f "$GAME_ASSISTANT_APPS_FILE.tmp.$$" "$GAME_ASSISTANT_APPS_FILE" || exit 1
        chmod 0644 "$GAME_ASSISTANT_APPS_FILE" 2>/dev/null
        sync_game_assistant_property
        echo "Success: game assistant enhancement app saved"
        ;;

    "remove_game_assistant_app")
        require_premium game_assistant
        GAME_PACKAGE="$2"
        valid_video_package "$GAME_PACKAGE" || exit 1
        [ -f "$GAME_ASSISTANT_APPS_FILE" ] || exit 0
        awk -v package="$GAME_PACKAGE" '$0 != package { print }' \
            "$GAME_ASSISTANT_APPS_FILE" > "$GAME_ASSISTANT_APPS_FILE.tmp.$$" || exit 1
        mv -f "$GAME_ASSISTANT_APPS_FILE.tmp.$$" "$GAME_ASSISTANT_APPS_FILE" || exit 1
        chmod 0644 "$GAME_ASSISTANT_APPS_FILE" 2>/dev/null
        sync_game_assistant_property
        echo "Success: game assistant enhancement app removed"
        ;;

    "add_video_motion_app")
        require_premium video_memc
        VIDEO_PACKAGE="$2"
        VIDEO_ACTIVITY="$3"
        VIDEO_VENDOR_RATE="$4"
        VIDEO_COMMAND="$5"
        valid_video_package "$VIDEO_PACKAGE" || {
            echo "Error: invalid package"
            exit 1
        }
        valid_video_activity "$VIDEO_PACKAGE" "$VIDEO_ACTIVITY" || {
            echo "Error: activity must be package/class"
            exit 1
        }
        case "$VIDEO_VENDOR_RATE" in ''|*[!0-9]*)
            echo "Error: MEMC refresh rate must be an integer"
            exit 1
        esac
        [ "$VIDEO_VENDOR_RATE" -ge 30 ] 2>/dev/null &&
            [ "$VIDEO_VENDOR_RATE" -le 1000 ] 2>/dev/null || {
            echo "Error: MEMC refresh rate must be 30-1000Hz"
            exit 1
        }
        case "$VIDEO_COMMAND" in 258-10-0-0|258-74-0-0) ;; *)
            echo "Error: unsupported MEMC command"
            exit 1
        esac
        mkdir -p "$(dirname "$VIDEO_MEMC_APPS_FILE")" || exit 1
        [ -f "$VIDEO_MEMC_APPS_FILE" ] || : > "$VIDEO_MEMC_APPS_FILE"
        VIDEO_TMP="$VIDEO_MEMC_APPS_FILE.tmp.$$"
        awk -F '|' -v package="$VIDEO_PACKAGE" -v activity="$VIDEO_ACTIVITY" \
            'NF != 4 || $1 != package || $3 != activity { print }' \
            "$VIDEO_MEMC_APPS_FILE" > "$VIDEO_TMP" || exit 1
        printf '%s|%s|%s|%s\n' "$VIDEO_PACKAGE" "$VIDEO_VENDOR_RATE" \
            "$VIDEO_ACTIVITY" "$VIDEO_COMMAND" >> "$VIDEO_TMP" || exit 1
        mv -f "$VIDEO_TMP" "$VIDEO_MEMC_APPS_FILE" || exit 1
        chmod 0644 "$VIDEO_MEMC_APPS_FILE" 2>/dev/null
        apply_video_memc_config || {
            echo "Error: failed to apply MEMC overlay"
            exit 1
        }
        echo "Success: video MEMC app saved; reboot required"
        ;;

    "remove_video_motion_app")
        require_premium video_memc
        VIDEO_PACKAGE="$2"
        VIDEO_ACTIVITY="$3"
        valid_video_package "$VIDEO_PACKAGE" || exit 1
        valid_video_activity "$VIDEO_PACKAGE" "$VIDEO_ACTIVITY" || exit 1
        [ -f "$VIDEO_MEMC_APPS_FILE" ] || exit 0
        VIDEO_TMP="$VIDEO_MEMC_APPS_FILE.tmp.$$"
        awk -F '|' -v package="$VIDEO_PACKAGE" -v activity="$VIDEO_ACTIVITY" \
            'NF != 4 || $1 != package || $3 != activity { print }' \
            "$VIDEO_MEMC_APPS_FILE" > "$VIDEO_TMP" || exit 1
        mv -f "$VIDEO_TMP" "$VIDEO_MEMC_APPS_FILE" || exit 1
        chmod 0644 "$VIDEO_MEMC_APPS_FILE" 2>/dev/null
        apply_video_memc_config || {
            echo "Error: failed to apply MEMC overlay"
            exit 1
        }
        echo "Success: video MEMC app removed; reboot required"
        ;;

    "get_foreground_activity")
        dumpsys activity activities 2>/dev/null | sed -n \
            's/.*mResumedActivity.* u[0-9][0-9]* \([^ ]*\/[^ ]*\).*/\1/p' | head -n 1
        ;;

    "get_recent_activity")
        VIDEO_PACKAGE="$2"
        valid_video_package "$VIDEO_PACKAGE" || {
            echo "Error: invalid package"
            exit 1
        }
        VIDEO_ACTIVITY=$(dumpsys activity activities 2>/dev/null | awk -v prefix="$VIDEO_PACKAGE/" '
            {
                for (i = 1; i <= NF; i++) {
                    value = $i
                    gsub(/^[{[(]+|[})],;]+$/, "", value)
                    if (index(value, prefix) == 1) { print value; exit }
                }
            }')
        if [ -z "$VIDEO_ACTIVITY" ]; then
            VIDEO_ACTIVITY=$(cmd package resolve-activity --brief \
                -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
                "$VIDEO_PACKAGE" 2>/dev/null | tail -n 1)
        fi
        case "$VIDEO_ACTIVITY" in "$VIDEO_PACKAGE/"*) printf '%s\n' "$VIDEO_ACTIVITY" ;; esac
        ;;

    "init_workspace")
        echo "初始化工作区..."
        stock_guard_begin || exit 1
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
        stock_guard_end || exit 1
        echo "Success: 工作区准备就绪"
        ;;

    "scan_rates")
        if [ "$(read_dts_backend)" = drm ]; then
            scan_drm_rates
            exit $?
        fi
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
        if [ "$(read_dts_backend)" = drm ]; then
            echo "DRM-KO 后端不处理 DTS；请使用运行时 mode_specs 添加或删除 mode"
            exit 0
        fi
        cd "$BIN_DIR" || exit 1
        chmod +x process_dts
        echo "Running Auto Process..."
        run_process_dts
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
        if [ "$(read_dts_backend)" = drm ]; then
            DRM_SOURCE_REFRESH=$(printf '%s' "$BASE_NODE" | sed -n 's/[^0-9]*\([0-9][0-9]*\)[^0-9]*$/\1/p')
            drm_add_spec "$TARGET_FPS" "${CUSTOM_CLOCK:-0}" \
                "${CUSTOM_TRANSFER:-0}" "${DRM_SOURCE_REFRESH:-0}"
            exit $?
        fi
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
             remember_custom_rate "$TARGET_FPS" || exit 1
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
        if [ "$(read_dts_backend)" = drm ]; then
            drm_remove_spec "$TARGET_NODE"
            exit $?
        fi
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
             REMOVED_FPS=$(printf '%s\n' "$TARGET_NODE" |
                 sed -n 's/[^0-9]*\([0-9][0-9]*\)[^0-9]*$/\1/p')
             [ -z "$REMOVED_FPS" ] || forget_custom_rate "$REMOVED_FPS" || exit 1
             echo "Success"
        else
             echo "Error: dts_tool failed with code $RET"
        fi
        ;;

    "apply_changes")
        acquire_dtbo_apply_lock || exit 1
        arm_dtbo_apply_lock_cleanup
        echo "开始应用更改..."
        stock_guard_begin || exit 1
        APPLY_RESULT=0
        do_apply_selected_backend || APPLY_RESULT=$?
        stock_guard_end || APPLY_RESULT=1
        [ "$APPLY_RESULT" -eq 0 ] || exit "$APPLY_RESULT"
        echo "操作完成！请重启设备。"
        ;;

    "flash_dtbo")
        acquire_dtbo_apply_lock || exit 1
        arm_dtbo_apply_lock_cleanup
        stock_guard_begin || exit 1
        FLASH_RESULT=0
        do_smart_add "$2" && do_apply_selected_backend || FLASH_RESULT=$?
        stock_guard_end || FLASH_RESULT=1
        [ "$FLASH_RESULT" -eq 0 ] || exit "$FLASH_RESULT"
        echo "操作完成！请重启设备。"
        ;;

    # ---- 后台执行（供前端流式轮询日志）----
    # start_apply / start_flash：立即返回，流程在后台运行，日志写 apply.log，状态写 apply.status
    # apply_changes_bg / flash_dtbo_bg：后台实际执行体
    "start_apply")
        if ! acquire_dtbo_apply_lock 1; then
            if [ "${DTBO_APPLY_LOCK_ACTIVE:-0}" = 1 ]; then
                echo "Started: $MOD_PATH/apply.log (已有任务，继续读取当前流程)"
                exit 0
            fi
            exit 1
        fi
        rm -f "$MOD_PATH/apply.log" "$MOD_PATH/apply.status"
        setsid sh "$MOD_PATH/scripts/web_handler.sh" apply_changes_bg \
            "$DTBO_APPLY_LOCK_TOKEN" > "$MOD_PATH/apply.log" 2>&1 &
        printf '%s\n' "$!" > "$DTBO_APPLY_LOCK_DIR/pid"
        echo "Started: $MOD_PATH/apply.log"
        ;;

    "apply_changes_bg")
        claim_dtbo_apply_lock "$2" || {
            echo "Error: DTBO 应用任务锁无效，已拒绝启动并发任务"
            echo "FAIL" > "$MOD_PATH/apply.status"
            exit 1
        }
        arm_dtbo_apply_lock_cleanup
        rm -f "$MOD_PATH/apply.status"
        APPLY_RESULT=0
        stock_guard_begin && do_apply_selected_backend || APPLY_RESULT=$?
        stock_guard_end || APPLY_RESULT=1
        if [ "$APPLY_RESULT" -eq 0 ]; then
            echo "操作完成！请重启设备。"
            echo "SUCCESS" > "$MOD_PATH/apply.status"
        else
            echo "FAIL" > "$MOD_PATH/apply.status"
        fi
        ;;

    "start_flash")
        if ! acquire_dtbo_apply_lock 1; then
            if [ "${DTBO_APPLY_LOCK_ACTIVE:-0}" = 1 ]; then
                echo "Started: $MOD_PATH/apply.log (已有任务，继续读取当前流程)"
                exit 0
            fi
            exit 1
        fi
        rm -f "$MOD_PATH/apply.log" "$MOD_PATH/apply.status"
        setsid sh "$MOD_PATH/scripts/web_handler.sh" flash_dtbo_bg "$2" \
            "$DTBO_APPLY_LOCK_TOKEN" > "$MOD_PATH/apply.log" 2>&1 &
        printf '%s\n' "$!" > "$DTBO_APPLY_LOCK_DIR/pid"
        echo "Started: $MOD_PATH/apply.log"
        ;;

    "flash_dtbo_bg")
        claim_dtbo_apply_lock "$3" || {
            echo "Error: DTBO 应用任务锁无效，已拒绝启动并发任务"
            echo "FAIL" > "$MOD_PATH/apply.status"
            exit 1
        }
        arm_dtbo_apply_lock_cleanup
        rm -f "$MOD_PATH/apply.status"
        FLASH_RESULT=0
        stock_guard_begin && do_smart_add "$2" && \
            do_apply_selected_backend || FLASH_RESULT=$?
        stock_guard_end || FLASH_RESULT=1
        if [ "$FLASH_RESULT" -eq 0 ]; then
            echo "操作完成！请重启设备。"
            echo "SUCCESS" > "$MOD_PATH/apply.status"
        else
            echo "FAIL" > "$MOD_PATH/apply.status"
        fi
        ;;

    "restore_dtbo")
        if ! ensure_stock_backup; then
            echo "错误：原厂 DTBO 备份完整性校验失败，拒绝恢复"
            exit 1
        fi
        BACKUP_FILE="$STOCK_DTBO"
        
        SLOT=$(getprop ro.boot.slot_suffix)
        DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
        
        echo "正在恢复原厂 DTBO..."
        if [ -f "$AVB_HELPER" ]; then
            dtbo_write_partition "$BACKUP_FILE" "$DTBO_PARTITION"
            RESTORE_RESULT=$?
        else
            dd if="$BACKUP_FILE" of="$DTBO_PARTITION" bs=4096 conv=fsync 2>&1
            RESTORE_RESULT=$?
        fi
        if [ "$RESTORE_RESULT" -eq 0 ]; then
            dtbo_clear_device_manifest "$APPLIED_MANIFEST"
            write_dts_backend dtbo
            echo "Success: 恢复成功！"
            # 不要删除备份文件，防止用户再次误操作需要恢复
            # rm -rf "$BIN_DIR/dtbo_dts"
            # rm -f "$BIN_DIR/new_dtbo.img"
        else
            echo "错误：恢复失败"
            exit 1
        fi
        ;;

    "get_display_policy")
        MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
        echo "model=${MODEL:-unknown}"
        case "$MODEL" in
            RMX5200) DISPLAY_PROFILE=rmx5200 ;;
            PLK110|PJD110) DISPLAY_PROFILE=vendor_ltpo ;;
            *) echo "supported=0"; exit 0 ;;
        esac
        echo "supported=1"
        echo "profile=$DISPLAY_PROFILE"
        echo "policy=$(display_policy_for_model "$MODEL")"
        if [ "$MODEL" = RMX5200 ] && [ -d /sys/module/rmx5200_ltpo_modes ] &&
           { [ "$(cat /sys/module/rmx5200_ltpo_modes/parameters/applied 2>/dev/null)" = Y ] ||
             [ "$(cat /sys/module/rmx5200_ltpo_modes/parameters/applied 2>/dev/null)" = 1 ]; }; then
            echo "active=custom_ltpo"
        else
            case "$MODEL" in
                RMX5200|PLK110) ADFR_PARAM_DIR=/sys/module/rmx5200_adfr_lock/parameters ;;
                PJD110) ADFR_PARAM_DIR=/sys/module/pjd110_adfr_lock/parameters ;;
            esac
            if [ "$(cat "$ADFR_PARAM_DIR/lock_active" 2>/dev/null)" = Y ]; then
                echo "active=adfr_off"
            elif [ "$MODEL" = RMX5200 ]; then
                echo "active=stock_ltps"
            elif [ -f "$MOD_PATH/runtime/generic_adfr/active" ] &&
                 [ "$(cat "$MOD_PATH/runtime/generic_adfr/active" 2>/dev/null)" =
                   "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]; then
                echo "active=adfr_off"
            else
                echo "active=stock_ltpo"
            fi
        fi
        ;;

    "set_display_policy")
        MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
        case "$MODEL:$2" in
            RMX5200:stock_ltps|RMX5200:custom_ltpo)
                TARGET_DISPLAY_POLICY="$2"; TARGET_ADFR_POLICY=on ;;
            RMX5200:adfr_off)
                TARGET_DISPLAY_POLICY=adfr_off; TARGET_ADFR_POLICY=off ;;
            PLK110:stock_ltpo|PJD110:stock_ltpo)
                TARGET_DISPLAY_POLICY=stock_ltpo; TARGET_ADFR_POLICY=on ;;
            PLK110:adfr_off|PJD110:adfr_off)
                TARGET_DISPLAY_POLICY=adfr_off; TARGET_ADFR_POLICY=off ;;
            RMX5200:*|PLK110:*|PJD110:*)
                echo "Error: invalid display policy for $MODEL"; exit 1 ;;
            *)
                echo "Error: display policy is unsupported on $MODEL"; exit 1 ;;
        esac
        case "$TARGET_DISPLAY_POLICY" in
            custom_ltpo)
                require_premium custom_ltpo || exit 1
                require_premium_payload custom_ltpo || exit 1
                ;;
            adfr_off)
                require_premium adfr_disable || exit 1
                require_premium_payload adfr_disable || exit 1
                ;;
        esac
        PREVIOUS_DISPLAY_POLICY=$(read_display_policy)
        PREVIOUS_ADFR_POLICY=$(read_adfr_policy)
        write_display_policy "$TARGET_DISPLAY_POLICY" || {
            echo "Error: unable to persist display policy"
            exit 1
        }
        if ! write_adfr_policy "$TARGET_ADFR_POLICY"; then
            write_display_policy "$PREVIOUS_DISPLAY_POLICY" >/dev/null 2>&1 || true
            write_adfr_policy "$PREVIOUS_ADFR_POLICY" >/dev/null 2>&1 || true
            echo "Error: unable to persist ADFR policy"
            exit 1
        fi
        rm -f "$ADFR_TEST_BYPASS_FILE" "$LTPO_BOOT_TOKEN_FILE" "$LTPO_RISE_TOKEN_FILE"
        sync
        echo "Success: display policy saved; reboot required"
        echo "policy=$TARGET_DISPLAY_POLICY"
        ;;

    "get_adfr_policy")
        MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
        echo "model=${MODEL:-unknown}"
        if [ "$MODEL" != RMX5200 ]; then
            echo "supported=0"
            exit 0
        fi
        echo "supported=1"
        echo "policy=$(read_adfr_policy)"
        if [ -f "$ADFR_LOCK_HELPER" ]; then
            sh "$ADFR_LOCK_HELPER" status 2>/dev/null
        else
            echo "state=helper_missing"
        fi
        ;;

    "toggle_adfr")
        MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
        if [ "$MODEL" != RMX5200 ]; then
            echo "Error: ADFR policy is only supported on RMX5200"
            exit 1
        fi
        case "$2" in
            enable) TARGET_ADFR_POLICY=on; TARGET_DISPLAY_POLICY=stock_ltps ;;
            disable) TARGET_ADFR_POLICY=off; TARGET_DISPLAY_POLICY=adfr_off ;;
            *)
                echo "Error: action must be enable or disable"
                exit 1
                ;;
        esac
        # Disabling ADFR is the premium action; restoring the stock policy is free.
        if [ "$TARGET_ADFR_POLICY" = off ]; then
            require_premium adfr_disable || exit 1
            require_premium_payload adfr_disable || exit 1
        fi
        [ -f "$ADFR_LOCK_HELPER" ] || {
            echo "Error: ADFR lock helper is missing"
            exit 1
        }

        PREVIOUS_ADFR_POLICY=$(read_adfr_policy)
        PREVIOUS_DISPLAY_POLICY=$(read_display_policy)
        write_adfr_policy "$TARGET_ADFR_POLICY" || {
            echo "Error: unable to persist ADFR policy"
            exit 1
        }
        write_display_policy "$TARGET_DISPLAY_POLICY" || {
            write_adfr_policy "$PREVIOUS_ADFR_POLICY" >/dev/null 2>&1 || true
            echo "Error: unable to persist display policy"
            exit 1
        }
        rm -f "$ADFR_TEST_BYPASS_FILE"
        if ! sh "$ADFR_LOCK_HELPER" apply >/dev/null 2>&1; then
            write_adfr_policy "$PREVIOUS_ADFR_POLICY" >/dev/null 2>&1 || true
            write_display_policy "$PREVIOUS_DISPLAY_POLICY" >/dev/null 2>&1 || true
            sh "$ADFR_LOCK_HELPER" apply >/dev/null 2>&1 || true
            echo "Error: unable to apply ADFR policy"
            exit 1
        fi

        if [ "$TARGET_ADFR_POLICY" = off ]; then
            [ "$(cat /sys/module/rmx5200_adfr_lock/parameters/lock_active 2>/dev/null)" = Y ] || {
                write_adfr_policy "$PREVIOUS_ADFR_POLICY" >/dev/null 2>&1 || true
                write_display_policy "$PREVIOUS_DISPLAY_POLICY" >/dev/null 2>&1 || true
                sh "$ADFR_LOCK_HELPER" apply >/dev/null 2>&1 || true
                echo "Error: ADFR lock did not become active"
                exit 1
            }
            echo "Success: ADFR disabled"
        else
            [ "$(cat /sys/module/rmx5200_adfr_lock/parameters/lock_active 2>/dev/null)" != Y ] || {
                write_adfr_policy "$PREVIOUS_ADFR_POLICY" >/dev/null 2>&1 || true
                write_display_policy "$PREVIOUS_DISPLAY_POLICY" >/dev/null 2>&1 || true
                sh "$ADFR_LOCK_HELPER" apply >/dev/null 2>&1 || true
                echo "Error: ADFR lock remained active"
                exit 1
            }
            echo "Success: ADFR enabled"
        fi
        sh "$ADFR_LOCK_HELPER" status 2>/dev/null
        ;;

    "get_dts_backend")
        CURRENT_BACKEND=$(read_dts_backend)
        echo "backend=$CURRENT_BACKEND"
        if [ "$CURRENT_BACKEND" = dtbo ]; then
            echo "status=skipped:dtbo"
            if [ -f "$DISPLAY_HELPER" ]; then
                sh "$DISPLAY_HELPER" status 2>/dev/null | \
                grep -E '^(result|display_driver|surfaceflinger|uptime_seconds|dsi_display_get_modes|sde_connector_get_modes|drm_hotplug)='
            fi
        elif [ -f "$DISPLAY_HELPER" ]; then
                sh "$DISPLAY_HELPER" status 2>/dev/null | grep -E '^(status|result|display_driver|surfaceflinger|uptime_seconds|get_main_display|dsi_display_get_modes|sde_connector_get_modes|drm_hotplug|ko_profile|ko_module)='
        else
            echo "status=helper_missing"
        fi
        ;;

    "set_dts_backend")
        case "$2" in
            drm) ;;
            dtbo) ;;
            *) echo "Error: backend must be dtbo or drm"; exit 1 ;;
        esac
        if write_dts_backend "$2"; then
            if [ "$2" = dtbo ] && [ -f "$DISPLAY_HELPER" ]; then
                sh "$DISPLAY_HELPER" mark-dtbo >/dev/null 2>&1
            fi
            echo "Success: DTS backend selected as $2; apply and reboot to activate"
        else
            echo "Error: backend must be dtbo or drm"
            exit 1
        fi
        ;;

    "probe_display_backend")
        if [ ! -f "$DISPLAY_HELPER" ]; then
            echo "Error: display backend helper missing"
            exit 1
        fi
        sh "$DISPLAY_HELPER" probe
        ;;

    "plan_dts_backend")
        plan_selected_backend
        ;;

    "set_config")
        # $2 is a runtime HWC mode id selected by WebUI. Persist its semantic
        # resolution/rate pair; the daemon resolves it back to an exact ID.
        NEW_MODE="$2"
        if [ -z "$NEW_MODE" ]; then
            echo "Error: Missing mode ID"
            exit 1
        fi
        
        NEW_SPEC=$(mode_semantic_for_id "$NEW_MODE") || {
            echo "Error: Unknown display mode $NEW_MODE"
            exit 1
        }
        TMP_FILE="${CONFIG_FILE}.tmp"
        echo "$NEW_SPEC" > "$TMP_FILE"
        # 从第二行开始追加原始内容
        tail -n +2 "$CONFIG_FILE" >> "$TMP_FILE" 2>/dev/null
        mv "$TMP_FILE" "$CONFIG_FILE"
        chmod 666 "$CONFIG_FILE"

        # The daemon owns the display transaction and synchronizes Settings
        # only after the physical mode is stable. An eager sync-global here
        # races ColorOS, Framework and SurfaceFlinger during resolution changes.
        echo "Success: Global mode set to $NEW_MODE"
        ;;

    "set_app_config")
        # $2 is package, $3 is runtime HWC mode id (-1 to delete), $4 is
        # optional explicit FHD+/QHD+; omitted/default inherits global width.
        PKG="$2"
        MODE="$3"
        APP_RESOLUTION="$4"
        
        if [ -z "$PKG" ] || [ -z "$MODE" ]; then
            echo "Error: Missing arguments"
            exit 1
        fi

        # 读取第一行作为全局语义配置
        GLOBAL_MODE=$(head -n 1 "$CONFIG_FILE")
        
        TMP_FILE="${CONFIG_FILE}.tmp"
        echo "$GLOBAL_MODE" > "$TMP_FILE"
        
        # 处理现有配置，按第一列排除当前包；同时保留旧格式行。
        awk -v package="$PKG" 'NR > 1 && $1 != package { print }' "$CONFIG_FILE" >> "$TMP_FILE"
        
        # 如果不是删除模式，追加新配置
        if [ "$MODE" != "-1" ]; then
            APP_SPEC=$(mode_semantic_for_id "$MODE") || {
                echo "Error: Unknown display mode $MODE"
                rm -f "$TMP_FILE"
                exit 1
            }
            APP_FPS=$(printf '%s\n' "$APP_SPEC" | awk '{print $2}')
            case "$APP_RESOLUTION" in
                FHD+|QHD+) echo "$PKG $APP_RESOLUTION $APP_FPS" >> "$TMP_FILE" ;;
                *) echo "$PKG $APP_FPS" >> "$TMP_FILE" ;;
            esac
        fi
        
        mv "$TMP_FILE" "$CONFIG_FILE"
        chmod 666 "$CONFIG_FILE"

        if [ "$MODE" != "-1" ] && { [ -x "$SETTINGS_BRIDGE_HELPER" ] || [ -f "$SETTINGS_BRIDGE_HELPER" ]; }; then
            sh "$SETTINGS_BRIDGE_HELPER" sync-app "$PKG" "$MODE" >/dev/null 2>&1 || true
        fi
        
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
        if [ ! -f "$STOCK_DTBO" ] && \
           { [ ! -f "$STOCK_MANIFEST" ] || [ ! -f "$STOCK_RECOVERY" ]; }; then
            echo "NONE"
        elif ensure_stock_backup >/dev/null 2>&1; then
            if [ "$STOCK_BACKUP_RECOVERED" = 1 ]; then
                echo "VALID $(dtbo_hash_file "$STOCK_DTBO") RECOVERED"
            else
                echo "VALID $(dtbo_hash_file "$STOCK_DTBO")"
            fi
        else
            echo "INVALID $(dtbo_hash_file "$STOCK_DTBO")"
        fi
        ;;

    "uninstall_module")
        # Restore the stock partition before mutating the live userspace. A
        # failed integrity check or write leaves the installed module intact.
        if ! ensure_stock_backup; then
            echo "Error: 原厂 DTBO 备份完整性校验失败，拒绝卸载和恢复"
            exit 1
        fi
        BACKUP_FILE="$STOCK_DTBO"
        if [ -f "$BACKUP_FILE" ]; then
            SLOT=$(getprop ro.boot.slot_suffix)
            DTBO_PARTITION="/dev/block/by-name/dtbo$SLOT"
            if [ -f "$AVB_HELPER" ]; then
                dtbo_write_partition "$BACKUP_FILE" "$DTBO_PARTITION" || exit 1
            else
                dd if="$BACKUP_FILE" of="$DTBO_PARTITION" bs=4096 conv=fsync || exit 1
            fi
            dtbo_clear_device_manifest "$APPLIED_MANIFEST"
        fi

        # Stop background observers before removing their bind mounts.
        pkill -f "$MEMC_GATE_HELPER watch-final-view" >/dev/null 2>&1 || true
        pkill -f "$SETTINGS_BRIDGE_HELPER watch" >/dev/null 2>&1 || true

        [ -f "$COLOROS_CONFIG_HELPER" ] &&
            sh "$COLOROS_CONFIG_HELPER" remove >/dev/null 2>&1 || true
        [ -f "$COLOROS_PREMIUM_HELPER" ] &&
            VIDEO_MEMC_APPS_FILE="$VIDEO_MEMC_APPS_FILE" \
                sh "$COLOROS_PREMIUM_HELPER" remove-premium >/dev/null 2>&1 || true
        [ -f "$PREMIUM_SYSTEM_OVERLAY_HELPER" ] &&
            sh "$PREMIUM_SYSTEM_OVERLAY_HELPER" remove >/dev/null 2>&1 || true
        [ -f "$MEMC_GATE_HELPER" ] &&
            sh "$MEMC_GATE_HELPER" restore >/dev/null 2>&1 || true
        [ -f "$SF_RISE_HELPER" ] &&
            sh "$SF_RISE_HELPER" restore >/dev/null 2>&1 || true
        [ -f "$SF_VOTE_HELPER" ] &&
            sh "$SF_VOTE_HELPER" restore >/dev/null 2>&1 || true
        [ -f "$ADFR_LOCK_HELPER" ] &&
            sh "$ADFR_LOCK_HELPER" restore >/dev/null 2>&1 || true
        [ -f "$GENERIC_ADFR_HELPER" ] &&
            sh "$GENERIC_ADFR_HELPER" restore >/dev/null 2>&1 || true

        # The Hook APK is removed only after every destructive prerequisite
        # has succeeded; a refused uninstall remains side-effect free.
        pm uninstall --user 0 com.murongchaopin.displayhook >/dev/null 2>&1 || true
        pm uninstall --user 0 com.murongchaopin.displayhook.premium >/dev/null 2>&1 || true
        touch "$MOD_PATH/remove"
        for daemon_pid in $(pidof rate_daemon 2>/dev/null); do
            kill "$daemon_pid" >/dev/null 2>&1 || true
        done
        
        echo "Success"
        ;;

    # ---- 显示授权门禁（display license gate）----
    "auth_state")
        if [ -f "$GATE_HELPER" ]; then
            gate_state_print
        else
            echo "account=none"
            echo "entitlement=unknown"
            echo "premium_available=0"
            echo "package_installed=0"
        fi
        ;;

    "auth_device_info")
        if [ -f "$GATE_HELPER" ]; then
            gate_device_info_print
        else
            echo "Error: authorization gate is missing"
            exit 1
        fi
        ;;

    "auth_save_account")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_account_save "$2" "$3" "$4"
        ;;

    "auth_clear_account")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_account_clear
        ;;

    "auth_save_lease")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_lease_save "$2"
        ;;

    "auth_entitlement_cache")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_entitlement_cache "$2" "$3" "$4"
        ;;

    "auth_package_write")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_package_write "$2" "$3"
        ;;

    "auth_package_abort")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_package_abort
        ;;

    "auth_package_state")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_package_state_print
        ;;

    "auth_package_commit")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_package_commit "$2" "$3" "$4" "$5"
        ;;

    "auth_package_remove")
        [ -f "$GATE_HELPER" ] || { echo "Error: authorization gate is missing"; exit 1; }
        gate_package_remove
        ;;

    *)
        echo "Unknown command: $1"
        ;;
esac
