#!/system/bin/sh

SCRIPT_DIR=${0%/*}
MOD_DIR=${SCRIPT_DIR%/*}
BIN_DIR="$MOD_DIR/bin"
CONFIG_FILE="$MOD_DIR/config/dts_backend.txt"
KO_MODULE_NAME=""
KO_MODULE=""
KO_PROFILE=""
DRM_PHY_PROFILE_FILE="$MOD_DIR/config/drm_phy_profile.txt"
MODE_MANIFEST_FILE="$MOD_DIR/config/display_mode_manifest.txt"
MODE_MANIFEST_HELPER="$MOD_DIR/scripts/mode_manifest.sh"
STATE_DIR="$MOD_DIR/runtime/display_backend"
STATUS_FILE="$STATE_DIR/status.txt"
PROBE_FILE="$STATE_DIR/probe.txt"
LOG_FILE="$STATE_DIR/runtime.log"
DRM_SPECS_FILE="$MOD_DIR/runtime/drm_modes.txt"

mkdir -p "$STATE_DIR" 2>/dev/null
[ -r "$MODE_MANIFEST_HELPER" ] && . "$MODE_MANIFEST_HELPER"

now() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown-time
}

log_line() {
    printf '%s %s\n' "$(now)" "$*" >> "$LOG_FILE"
}

set_status() {
    printf '%s\n' "$1" > "$STATUS_FILE"
    log_line "status=$1"
}

read_backend() {
    display_backend=$(sed -n '1p' "$CONFIG_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$display_backend" in
        dtbo|drm) printf '%s\n' "$display_backend" ;;
        *) printf '%s\n' dtbo ;;
    esac
}

validate_rmx5200_unique_fhd_runtime() {
    [ "$KO_PROFILE" = rmx5200 ] || return 0
    UNIQUE_FHD_BASE="/sys/module/$KO_MODULE_NAME/parameters"
    UNIQUE_FHD_ENABLED=$(cat "$UNIQUE_FHD_BASE/drop_stock_fhd" 2>/dev/null)
    { [ "$UNIQUE_FHD_ENABLED" = Y ] || [ "$UNIQUE_FHD_ENABLED" = 1 ]; } ||
        return 1
    [ "$(cat "$UNIQUE_FHD_BASE/removed_stock_fhd_count" 2>/dev/null)" = 4 ] ||
        return 1
    [ "$(cat "$UNIQUE_FHD_BASE/removed_stock_fhd_drm_count" 2>/dev/null)" = 4 ] ||
        return 1
}

validate_pjd110_low_runtime() {
    [ "$KO_PROFILE" = pjd110 ] || return 0
    PJD_LOW_BASE="/sys/module/$KO_MODULE_NAME/parameters"
    PJD_LOW_ENABLED=$(cat "$PJD_LOW_BASE/drop_stock_low" 2>/dev/null)
    { [ "$PJD_LOW_ENABLED" = Y ] || [ "$PJD_LOW_ENABLED" = 1 ]; } ||
        return 1
    [ "$(cat "$PJD_LOW_BASE/removed_stock_low_count" 2>/dev/null)" = 2 ] ||
        return 1
    [ "$(cat "$PJD_LOW_BASE/removed_stock_low_drm_count" 2>/dev/null)" = 2 ] ||
        return 1
}

validate_profile_runtime() {
    validate_rmx5200_unique_fhd_runtime &&
        validate_pjd110_low_runtime
}

select_ko_profile() {
    PROFILE_MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
    [ -n "$PROFILE_MODEL" ] || PROFILE_MODEL=$(getprop ro.product.model 2>/dev/null)
    case "$PROFILE_MODEL" in
        RMX5200)
            KO_PROFILE=rmx5200
            KO_MODULE_NAME=rmx5200_drm_modes
            ;;
        PLK110)
            KO_PROFILE=plk110
            KO_MODULE_NAME=plk110_drm_modes
            ;;
        PJD110)
            KO_PROFILE=pjd110
            KO_MODULE_NAME=pjd110_drm_modes
            ;;
        *)
            KO_PROFILE=unsupported
            KO_MODULE_NAME=""
            ;;
    esac
    [ -n "$KO_MODULE_NAME" ] && KO_MODULE="$BIN_DIR/${KO_MODULE_NAME}.ko" || KO_MODULE=""
}

ensure_drm_specs() {
    if [ -s "$DRM_SPECS_FILE" ]; then
        if [ "$KO_PROFILE" != pjd110 ]; then
            return 0
        fi
        PJD_SPECS=$(sed -n '1p' "$DRM_SPECS_FILE" 2>/dev/null |
            tr -d '[:space:]')
        [ -z "$PJD_SPECS" ] && return 0
        for PJD_SPEC in $(printf '%s' "$PJD_SPECS" | tr ';' ' '); do
            case "$PJD_SPEC" in
                1440x3168@[0-9]*|1440x3168@[0-9]*:[0-9]*) ;;
                *) return 1 ;;
            esac
        done
        return 0
    fi
    mkdir -p "$(dirname "$DRM_SPECS_FILE")" 2>/dev/null
    case "$KO_PROFILE" in
        rmx5200)
            mode_manifest_validate || return 1
            mode_manifest_specs RMX5200 drm > "$DRM_SPECS_FILE" || return 1
            ;;
        plk110)
            # PLK110 remains fail-closed until its Qualcomm mode ABI is
            # validated on a real device; do not feed its legacy profile here.
            return 1
            ;;
        pjd110)
            mode_manifest_validate || return 1
            printf '\n' > "$DRM_SPECS_FILE" || return 1
            ;;
        *)
            return 1
            ;;
    esac
    chmod 0644 "$DRM_SPECS_FILE" 2>/dev/null
}

read_drm_phy_profile() {
    DRM_PHY_PROFILE=$(sed -n '1p' "$DRM_PHY_PROFILE_FILE" 2>/dev/null |
        tr -d '[:space:]')
    [ -n "$DRM_PHY_PROFILE" ] || DRM_PHY_PROFILE=stock
    case "$KO_PROFILE:$DRM_PHY_PROFILE" in
        rmx5200:stock|rmx5200:v72_vendor_delta)
            printf '%s\n' "$DRM_PHY_PROFILE"
            ;;
        *:stock)
            printf '%s\n' stock
            ;;
        *)
            return 1
            ;;
    esac
}

has_symbol() {
    display_symbol="$1"
    [ -r /proc/kallsyms ] || return 1
    # Toybox grep has incomplete ERE support on some Android builds.  The
    # symbol is the third whitespace-separated kallsyms field, so use awk.
    awk -v symbol="$display_symbol" '$3 == symbol { found = 1 } END { exit !found }' \
        /proc/kallsyms 2>/dev/null
}

collect_probe() {
    PROBE_MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
    [ -n "$PROBE_MODEL" ] || PROBE_MODEL=$(getprop ro.product.model 2>/dev/null)
    PROBE_DRIVER=not_loaded
    [ -d /sys/module/msm_drm ] && PROBE_DRIVER=loaded
    PROBE_SURFACEFLINGER=not_running
    pidof surfaceflinger >/dev/null 2>&1 && PROBE_SURFACEFLINGER=running
    PROBE_UPTIME=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
    PROBE_GET_MAIN_DISPLAY=missing
    has_symbol get_main_display && PROBE_GET_MAIN_DISPLAY=available
    PROBE_DSI_GET_MODES=missing
    has_symbol dsi_display_get_modes && PROBE_DSI_GET_MODES=available
    PROBE_SDE_GET_MODES=missing
    has_symbol sde_connector_get_modes && PROBE_SDE_GET_MODES=available
    PROBE_DRM_HOTPLUG=missing
    has_symbol drm_kms_helper_hotplug_event && PROBE_DRM_HOTPLUG=available
    select_ko_profile
    PROBE_PROFILE=$KO_PROFILE
    PROBE_ADFR_PROFILE=not_modified
    PROBE_ADFR_COMMANDS=unsupported
    PROBE_KO=missing
    [ -n "$KO_MODULE" ] && [ -r "$KO_MODULE" ] && PROBE_KO=present
    PROBE_REASON=ok

    if [ "$KO_PROFILE" = unsupported ]; then
        PROBE_REASON=unsupported_model
    elif [ "$PROBE_DRIVER" != loaded ]; then
        PROBE_REASON=msm_drm_not_loaded
    elif [ "$PROBE_GET_MAIN_DISPLAY" != available ]; then
        PROBE_REASON=get_main_display_missing
    elif [ "$PROBE_DSI_GET_MODES" != available ] ||
         [ "$PROBE_SDE_GET_MODES" != available ]; then
        PROBE_REASON=qualcomm_mode_hooks_missing
    elif [ "$PROBE_KO" != present ]; then
        PROBE_REASON=ko_not_built
    fi
}

print_probe() {
    printf 'model=%s\n' "$PROBE_MODEL"
    printf 'display_driver=%s\n' "$PROBE_DRIVER"
    printf 'surfaceflinger=%s\n' "$PROBE_SURFACEFLINGER"
    printf 'uptime_seconds=%s\n' "$PROBE_UPTIME"
    printf 'get_main_display=%s\n' "$PROBE_GET_MAIN_DISPLAY"
    printf 'dsi_display_get_modes=%s\n' "$PROBE_DSI_GET_MODES"
    printf 'sde_connector_get_modes=%s\n' "$PROBE_SDE_GET_MODES"
    printf 'drm_hotplug=%s\n' "$PROBE_DRM_HOTPLUG"
    printf 'ko_profile=%s\n' "$PROBE_PROFILE"
    printf 'ko_module=%s\n' "$PROBE_KO"
    printf 'adfr_profile=%s\n' "$PROBE_ADFR_PROFILE"
    printf 'adfr_command_injection=%s\n' "$PROBE_ADFR_COMMANDS"
    printf 'result=%s\n' "$PROBE_REASON"
}

write_probe() {
    display_probe_tmp="$PROBE_FILE.tmp.$$"
    {
        printf 'recorded_at=%s\n' "$(now)"
        print_probe
    } > "$display_probe_tmp" && mv -f "$display_probe_tmp" "$PROBE_FILE"
}

probe_backend() {
    collect_probe
    write_probe
    print_probe
    [ "$PROBE_REASON" = ok ]
}

apply_drm_at_boot() {
    select_ko_profile
    collect_probe
    write_probe
    log_line "boot-probe backend=drm uptime=$PROBE_UPTIME driver=$PROBE_DRIVER surfaceflinger=$PROBE_SURFACEFLINGER result=$PROBE_REASON"

    if [ "$PROBE_REASON" != ok ]; then
        set_status "unsupported:drm:$PROBE_REASON"
        return 0
    fi
    if [ -z "$KO_MODULE" ] || [ ! -r "$KO_MODULE" ]; then
        set_status blocked:drm_injector_not_built
        return 0
    fi
    if [ -d "/sys/module/$KO_MODULE_NAME" ]; then
        if validate_profile_runtime; then
            set_status applied:drm_modes_only:adfr_not_modified
        else
            set_status error:drm_existing_unique_fhd_mismatch
        fi
        return 0
    fi

    chmod 0600 "$KO_MODULE" 2>/dev/null
    ensure_drm_specs || {
        set_status "unsupported:drm_specs:$KO_PROFILE"
        return 0
    }
    DRM_MODE_SPECS=$(sed -n '1p' "$DRM_SPECS_FILE" 2>/dev/null | tr -d '[:space:]')
    [ -n "$DRM_MODE_SPECS" ] || [ "$KO_PROFILE" = pjd110 ] || {
        set_status unsupported:drm_specs_empty
        return 0
    }
    DRM_PHY_PROFILE=$(read_drm_phy_profile) || {
        set_status error:drm_phy_profile_invalid
        return 0
    }
    log_line "drm-load profile=$KO_PROFILE phy_profile=$DRM_PHY_PROFILE"
    if [ "$KO_PROFILE" = pjd110 ]; then
        insmod "$KO_MODULE" probe_only=0 drop_stock_low=1 \
            mode_specs="$DRM_MODE_SPECS" >/dev/null 2>&1
    else
        insmod "$KO_MODULE" probe_only=0 drop_stock_fhd=1 \
            mode_specs="$DRM_MODE_SPECS" \
            phy_profile="$DRM_PHY_PROFILE" >/dev/null 2>&1
    fi
    display_rc=$?
    if [ "$display_rc" -ne 0 ]; then
        set_status "error:drm_insmod:$display_rc"
        return 0
    fi
    display_installed=$(cat "/sys/module/$KO_MODULE_NAME/parameters/applied" 2>/dev/null)
    display_cache=$(cat "/sys/module/$KO_MODULE_NAME/parameters/cache_applied" 2>/dev/null)
    display_failure=$(cat "/sys/module/$KO_MODULE_NAME/parameters/failure_code" 2>/dev/null)
    display_removed_fhd=$(cat "/sys/module/$KO_MODULE_NAME/parameters/removed_stock_fhd_count" 2>/dev/null)
    display_removed_fhd_drm=$(cat "/sys/module/$KO_MODULE_NAME/parameters/removed_stock_fhd_drm_count" 2>/dev/null)
    display_removed_low=$(cat "/sys/module/$KO_MODULE_NAME/parameters/removed_stock_low_count" 2>/dev/null)
    display_removed_low_drm=$(cat "/sys/module/$KO_MODULE_NAME/parameters/removed_stock_low_drm_count" 2>/dev/null)
    if { [ "$display_installed" = Y ] || [ "$display_installed" = 1 ]; } &&
       { [ "$display_cache" = Y ] || [ "$display_cache" = 1 ]; } &&
       [ "$display_failure" = 0 ] &&
       validate_profile_runtime; then
        set_status applied:drm_modes_only:adfr_not_modified
    else
        set_status "error:drm_apply:installed=$display_installed,failure=$display_failure,removed_fhd=$display_removed_fhd,removed_fhd_drm=$display_removed_fhd_drm,removed_low=$display_removed_low,removed_low_drm=$display_removed_low_drm"
    fi
    return 0
}

boot_apply() {
    display_backend=$(read_backend)
    if [ "$display_backend" = dtbo ]; then
        collect_probe
        write_probe
        set_status skipped:dtbo
        return 0
    fi
    apply_drm_at_boot
}

remove_backend() {
    select_ko_profile
    [ -n "$KO_MODULE_NAME" ] || {
        set_status error:drm_profile_not_verified
        echo "Error: 当前机型没有经过 ABI 验证的 DRM-KO" >&2
        return 1
    }
    if [ -d "/sys/module/$KO_MODULE_NAME" ]; then
        set_status error:drm_remove_requires_reboot
        echo "Error: DRM-KO 正在使用，不能在线卸载；切换回 DTBO 后重启回滚" >&2
        return 1
    fi
    set_status removed:drm
    echo "Success: DRM-KO 当前未加载"
}

mark_dtbo() {
    set_status skipped:dtbo
}

case "$1" in
    probe)
        probe_backend
        ;;
    boot-apply)
        boot_apply
        ;;
    remove)
        remove_backend
        ;;
    mark-dtbo)
        mark_dtbo
        ;;
    status)
        printf 'backend=%s\n' "$(read_backend)"
        select_ko_profile
        if DRM_STATUS_PHY=$(read_drm_phy_profile 2>/dev/null); then
            printf 'phy_profile=%s\n' "$DRM_STATUS_PHY"
        else
            printf 'phy_profile=invalid\n'
        fi
        if [ -f "$STATUS_FILE" ]; then
            printf 'status=%s\n' "$(sed -n '1p' "$STATUS_FILE")"
        else
            printf 'status=unknown\n'
        fi
        [ -f "$PROBE_FILE" ] && cat "$PROBE_FILE"
        ;;
    *)
        echo "Usage: $0 {probe|boot-apply|remove|mark-dtbo|status}" >&2
        exit 64
        ;;
esac
