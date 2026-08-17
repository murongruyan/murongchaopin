#!/system/bin/sh

# Mirrors the module's semantic mode.txt state into ColorOS' legacy preference
# keys. The daemon and API-102 Settings hook remain the only writers of exact
# HWC modes. This helper must never pull coarse ColorOS enums back into the
# module, because mode 7 cannot represent 150/155/160/170/175/180Hz.

SCRIPT_DIR=${0%/*}
MOD_DIR=${SCRIPT_DIR%/*}
CONFIG_FILE="$MOD_DIR/config/mode.txt"
DEX_FILE="$MOD_DIR/bin/display_settings_bridge.dex"
STATE_DIR="$MOD_DIR/runtime/display_settings_bridge"
STATUS_FILE="$STATE_DIR/status.txt"
LOG_FILE="$STATE_DIR/runtime.log"
APP_PROCESS=${DISPLAY_BRIDGE_APP_PROCESS:-app_process}

mkdir -p "$STATE_DIR" 2>/dev/null

now() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown-time
}

write_status() {
    printf '%s\n' "$1" > "$STATUS_FILE"
    printf '%s %s\n' "$(now)" "$1" >> "$LOG_FILE"
}

valid_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_package() {
    case "$1" in
        ''|*[!A-Za-z0-9._]*) return 1 ;;
        *) return 0 ;;
    esac
}

read_mode_id() {
    line=$(sed -n '1p' "$CONFIG_FILE" 2>/dev/null | tr -d '\r')
    case "$line" in
        ''|\#*) return 1 ;;
        *[!0-9]*) ;;
        *) printf '%s\n' "$line"; return 0 ;;
    esac
    set -- $line
    [ "$#" -eq 2 ] || return 1
    width=$(resolution_width_for_token "$1") || return 1
    height=$(height_for_width "$width") || return 1
    mode_for_spec "$width" "$height" "$2"
}

display_widths() {
    dumpsys SurfaceFlinger 2>/dev/null |
        sed -n 's/.*resolution=\([0-9][0-9]*\)x[0-9][0-9]*.*/\1/p' |
        sort -n -u
}

height_for_width() {
    wanted_width=$1
    display_widths >/dev/null || return 1
    dumpsys SurfaceFlinger 2>/dev/null |
        sed -n "s/.*resolution=${wanted_width}x\([0-9][0-9]*\).*/\1/p" |
        head -n 1
}

resolution_width_for_token() {
    case "$1" in
        FHD+|FHD|1080P|1080p)
            display_widths | head -n 1 ;;
        QHD+|QHD|2K|2k)
            display_widths | tail -n 1 ;;
        *x*)
            printf '%s\n' "$1" | sed -n 's/^\([0-9][0-9]*\)x[0-9][0-9]*$/\1/p' ;;
        *) return 1 ;;
    esac
}

mode_line() {
    target_id=$1
    valid_number "$target_id" || return 1
    dumpsys SurfaceFlinger 2>/dev/null | grep "id=$target_id," | \
        grep 'resolution=.*vsyncRate=' | head -n 1
}

mode_spec() {
    line=$(mode_line "$1") || return 1
    width=$(printf '%s\n' "$line" | sed -n 's/.*resolution=\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1/p')
    height=$(printf '%s\n' "$line" | sed -n 's/.*resolution=\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\2/p')
    rate=$(printf '%s\n' "$line" | sed -n 's/.*vsyncRate=\([0-9.][0-9.]*\).*/\1/p')
    valid_number "$width" && valid_number "$height" || return 1
    fps=$(printf '%s\n' "$rate" | awk '{ printf "%d", $1 + 0.5 }')
    valid_number "$fps" || return 1
    printf '%s %s %s\n' "$width" "$height" "$fps"
}

mode_for_spec() {
    wanted_width=$1
    wanted_height=$2
    wanted_fps=$3
    valid_number "$wanted_width" && valid_number "$wanted_height" && valid_number "$wanted_fps" || return 1
    dumpsys SurfaceFlinger 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *'id='*','*'resolution='*'vsyncRate='*) ;;
            *) continue ;;
        esac
        id=$(printf '%s\n' "$line" | sed -n 's/.*id=\([0-9][0-9]*\),.*/\1/p')
        width=$(printf '%s\n' "$line" | sed -n 's/.*resolution=\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1/p')
        height=$(printf '%s\n' "$line" | sed -n 's/.*resolution=\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\2/p')
        rate=$(printf '%s\n' "$line" | sed -n 's/.*vsyncRate=\([0-9.][0-9.]*\).*/\1/p')
        fps=$(printf '%s\n' "$rate" | awk '{ printf "%d", $1 + 0.5 }')
        if [ "$width" = "$wanted_width" ] && [ "$height" = "$wanted_height" ] && [ "$fps" = "$wanted_fps" ]; then
            printf '%s\n' "$id"
            break
        fi
    done
}

settings_mode_for_fps() {
    case "$1" in
        90) printf '%s\n' 1 ;;
        60) printf '%s\n' 2 ;;
        120) printf '%s\n' 3 ;;
        144) printf '%s\n' 4 ;;
        *)
            [ "$1" -ge 120 ] 2>/dev/null || return 1
            printf '%s\n' 7 ;;
    esac
}

fps_for_settings_mode() {
    case "$1" in
        1) printf '%s\n' 90 ;;
        2) printf '%s\n' 60 ;;
        3) printf '%s\n' 120 ;;
        4) printf '%s\n' 144 ;;
        7) printf '%s\n' 165 ;;
        *) return 1 ;;
    esac
}

preserved_fps_for_settings_mode() {
    mode_id=$1
    setting_mode=$2
    spec=$(mode_spec "$mode_id") || return 1
    set -- $spec
    fps=$3
    represented_mode=$(settings_mode_for_fps "$fps") || return 1
    [ "$represented_mode" = "$setting_mode" ] || return 1
    printf '%s\n' "$fps"
}

resolution_adjust_for_width() {
    min_width=$(display_widths | head -n 1)
    max_width=$(display_widths | tail -n 1)
    [ -n "$min_width" ] && [ -n "$max_width" ] || return 1
    [ "$min_width" != "$max_width" ] || {
        [ "$1" = "$max_width" ] && printf '%s\n' 3
        return
    }
    [ "$1" = "$min_width" ] && printf '%s\n' 2 && return 0
    [ "$1" = "$max_width" ] && printf '%s\n' 3 && return 0
    return 1
}

resolution_token_for_width() {
    min_width=$(display_widths | head -n 1)
    max_width=$(display_widths | tail -n 1)
    [ -n "$min_width" ] && [ -n "$max_width" ] || return 1
    if [ "$min_width" != "$max_width" ] && [ "$1" = "$min_width" ]; then
        printf '%s\n' FHD+
    elif [ "$1" = "$max_width" ]; then
        printf '%s\n' QHD+
    else
        height_for_width "$1" | sed "s/^/${1}x/"
    fi
}

write_global_mode() {
    target_id=$1
    valid_number "$target_id" || return 1
    current=$(read_mode_id)
    [ "$current" = "$target_id" ] && return 0
    tmp="$CONFIG_FILE.settings-bridge.$$"
    spec=$(mode_spec "$target_id") || return 1
    set -- $spec
    token=$(resolution_token_for_width "$1") || return 1
    {
        printf '%s %s\n' "$token" "$3"
        tail -n +2 "$CONFIG_FILE" 2>/dev/null
    } > "$tmp" || return 1
    mv "$tmp" "$CONFIG_FILE" || return 1
    chmod 0666 "$CONFIG_FILE" 2>/dev/null || true
    return 0
}

write_app_mode() {
    package_name=$1
    target_id=$2
    valid_package "$package_name" && valid_number "$target_id" || return 1
    current=$(sed -n "s/^$package_name=\([0-9][0-9]*\)$/\1/p" "$CONFIG_FILE" 2>/dev/null | head -n 1)
    [ "$current" = "$target_id" ] && return 0
    global_mode=$(read_mode_id)
    valid_number "$global_mode" || return 1
    tmp="$CONFIG_FILE.settings-bridge.$$"
    {
        printf '%s\n' "$global_mode"
        tail -n +2 "$CONFIG_FILE" 2>/dev/null | grep -v "^$package_name="
        printf '%s=%s\n' "$package_name" "$target_id"
    } > "$tmp" || return 1
    mv "$tmp" "$CONFIG_FILE" || return 1
    chmod 0666 "$CONFIG_FILE" 2>/dev/null || true
    return 0
}

run_api() {
    [ -r "$DEX_FILE" ] || return 127
    CLASSPATH="$DEX_FILE" "$APP_PROCESS" /system/bin \
        com.murongchaopin.display.DisplaySettingsBridge "$@"
}

sync_global_to_settings() {
    mode_id=$(read_mode_id)
    spec=$(mode_spec "$mode_id") || {
        write_status error:global_mode_unavailable
        return 1
    }
    set -- $spec
    width=$1
    height=$2
    fps=$3
    setting_mode=$(settings_mode_for_fps "$fps") || {
        write_status error:global_rate_unsupported
        return 1
    }
    adjust=$(resolution_adjust_for_width "$width") || adjust=

    settings put secure support_highfps 1 >/dev/null 2>&1
    settings put system peak_refresh_rate "$fps" >/dev/null 2>&1
    settings put system user_refresh_rate "$fps" >/dev/null 2>&1
    settings put system default_refresh_rate "$fps" >/dev/null 2>&1
    settings put global user_preferred_refresh_rate "$fps" >/dev/null 2>&1
    settings put secure oplus_customize_screen_refresh_rate "$setting_mode" >/dev/null 2>&1
    if [ -n "$adjust" ]; then
        settings put secure user_preferred_screen_index "$adjust" >/dev/null 2>&1
        settings put secure oplus_customize_screen_resolution_adjust "$adjust" >/dev/null 2>&1
        settings put global user_preferred_resolution_width "$width" >/dev/null 2>&1
        settings put global user_preferred_resolution_height "$height" >/dev/null 2>&1
    fi
    # The ColorOS observer applies the enum asynchronously and can reset the
    # minimum rate after the writes above. Let that callback settle first.
    sleep 1
    # ColorOS resets min_refresh_rate while applying its enum; keep the v2.2
    # fixed-rate floor as the final write in the transaction.
    settings put system min_refresh_rate "$fps" >/dev/null 2>&1

    write_status "mirrored:global=${width}x${height}@${fps},settings_mode=${setting_mode}"
}

sync_app_to_settings() {
    package_name=$1
    mode_id=$2
    valid_package "$package_name" && valid_number "$mode_id" || return 1
    spec=$(mode_spec "$mode_id") || return 1
    set -- $spec
    fps=$3
    write_status "authoritative:app=$package_name,mode_id=$mode_id,fps=$fps,settings_ui=daemon"
}

pull_global_from_settings() {
    setting_mode=$(settings get secure oplus_customize_screen_refresh_rate 2>/dev/null | tr -d '[:space:]')
    desired_fps=$(fps_for_settings_mode "$setting_mode") || return 0
    current_mode=$(read_mode_id)
    preserved_fps=$(preserved_fps_for_settings_mode "$current_mode" "$setting_mode" 2>/dev/null) || preserved_fps=
    if valid_number "$preserved_fps"; then
        desired_fps=$preserved_fps
    fi
    width=$(settings get global user_preferred_resolution_width 2>/dev/null | tr -d '[:space:]')
    height=$(settings get global user_preferred_resolution_height 2>/dev/null | tr -d '[:space:]')
    if ! valid_number "$width" || ! valid_number "$height"; then
        current_spec=$(mode_spec "$current_mode") || return 1
        set -- $current_spec
        width=$1
        height=$2
    fi
    target_id=$(mode_for_spec "$width" "$height" "$desired_fps")
    valid_number "$target_id" || {
        write_status "blocked:settings_mode_unavailable,mode=$setting_mode"
        return 0
    }
    write_global_mode "$target_id" || return 1
    write_status "pulled:global=${width}x${height}@${desired_fps},settings_mode=$setting_mode"
}

pull_apps_from_settings() {
    current_spec=$(mode_spec "$(read_mode_id)") || return 1
    set -- $current_spec
    width=$1
    height=$2
    pulled=0
    run_api dump 2>/dev/null | while IFS='=' read -r package_name setting_mode; do
        valid_package "$package_name" || continue
        desired_fps=$(fps_for_settings_mode "$setting_mode") || continue
        existing_id=$(sed -n "s/^$package_name=\([0-9][0-9]*\)$/\1/p" "$CONFIG_FILE" 2>/dev/null | head -n 1)
        preserved_fps=$(preserved_fps_for_settings_mode "$existing_id" "$setting_mode" 2>/dev/null) || preserved_fps=
        if valid_number "$preserved_fps"; then
            target_id=$existing_id
        else
            target_id=$(mode_for_spec "$width" "$height" "$desired_fps")
        fi
        valid_number "$target_id" || continue
        write_app_mode "$package_name" "$target_id" || exit 1
        printf '%s\n' "$package_name=$target_id" >> "$STATE_DIR/pulled_apps.tmp"
        pulled=1
    done
    # The pipeline runs in a subshell on mksh; use the file as the durable
    # signal instead of relying on its local variable.
    if [ -s "$STATE_DIR/pulled_apps.tmp" ]; then
        count=$(wc -l < "$STATE_DIR/pulled_apps.tmp" 2>/dev/null | tr -d '[:space:]')
        mv "$STATE_DIR/pulled_apps.tmp" "$STATE_DIR/pulled_apps.txt"
        write_status "pulled:apps=$count"
    fi
}

game_filter_mode() {
    dumpsys oplus_vrr_service 2>/dev/null | \
        sed -n 's/.*GlobalGameFilterMode: *\([0-9][0-9]*\).*/\1/p' | head -n 1
}

request_daemon_reapply() {
    for pid in $(pidof rate_daemon 2>/dev/null); do
        kill -USR1 "$pid" 2>/dev/null || true
    done
}

watch() {
    last_game=''
    while true; do
        game_now=$(game_filter_mode)
        if valid_number "$game_now" && [ "$game_now" != "$last_game" ]; then
            request_daemon_reapply
            write_status "game_assistant_filter=$game_now,reapply_requested=1"
            last_game=$game_now
        fi
        sleep 3
    done
}

case "$1" in
    sync-global) sync_global_to_settings ;;
    sync-app) sync_app_to_settings "$2" "$3" ;;
    pull-once)
        write_status "authoritative:module_mode=$(read_mode_id),settings_pull=disabled"
        ;;
    watch) watch ;;
    status)
        [ -f "$STATUS_FILE" ] && cat "$STATUS_FILE" || printf '%s\n' unknown
        ;;
    *)
        echo "Usage: $0 {sync-global|sync-app|pull-once|watch|status}" >&2
        exit 64
        ;;
esac
