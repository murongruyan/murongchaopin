#!/system/bin/sh

# Publish the "rapid refresh rate" level ColorOS needs to offer its high-rate
# menu.
#
# ColorOS 17 decides whether the "refresh rate setting" row is interactive from
# persist.performance.rapid.refresh_rate.level: the OnePlus builds ship it set
# to the panel maximum, while the realme builds leave it unset, which leaves
# the row inert and makes every rate the display backend publishes
# unselectable.  Report the highest rate the panel really reports and never
# lower a value the vendor already set.

SCRIPT_DIR=${0%/*}
MOD_DIR=${SCRIPT_DIR%/*}
STATUS_DIR="$MOD_DIR/runtime/display_rapid_rate"
STATUS_FILE="$STATUS_DIR/status.txt"
PROP=persist.performance.rapid.refresh_rate.level

mkdir -p "$STATUS_DIR" 2>/dev/null

set_status() {
    printf '%s\n' "$1" > "$STATUS_FILE" 2>/dev/null
}

find_resetprop() {
    RESETPROP=$(command -v resetprop 2>/dev/null)
    for candidate in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop \
                     /data/adb/ap/bin/resetprop; do
        [ -x "$candidate" ] || continue
        RESETPROP=$candidate
        break
    done
    [ -n "$RESETPROP" ] && [ -x "$RESETPROP" ]
}

# Highest refresh rate among the modes the connector currently exposes.
panel_max_rate() {
    best=0
    for node in /sys/class/drm/card0-DSI-1/modes \
                /sys/class/drm/card*-DSI-*/modes; do
        [ -r "$node" ] || continue
        while IFS= read -r mode; do
            rate=$(printf '%s\n' "$mode" |
                sed -n 's/^[0-9][0-9]*x[0-9][0-9]*x\([0-9][0-9]*\).*/\1/p')
            case "$rate" in
                ''|*[!0-9]*) continue ;;
            esac
            [ "$rate" -gt "$best" ] && best=$rate
        done < "$node"
    done
    [ "$best" -gt 120 ] || best=
    printf '%s\n' "$best"
}

apply_rate() {
    target=$(panel_max_rate)
    [ -n "$target" ] || {
        set_status skipped:no_high_rate_mode
        return 0
    }
    current=$(getprop "$PROP" 2>/dev/null | tr -d '[:space:]')
    case "$current" in
        ''|*[!0-9]*) current=0 ;;
    esac
    if [ "$current" -ge "$target" ]; then
        set_status "kept:current=${current}Hz"
        return 0
    fi
    find_resetprop || {
        set_status "error:resetprop_missing,target=${target}Hz"
        return 1
    }
    "$RESETPROP" -n "$PROP" "$target" >/dev/null 2>&1 || {
        set_status "error:setprop_failed,target=${target}Hz"
        return 1
    }
    set_status "applied:rapid=${target}Hz,previous=${current}Hz"
    return 0
}

case "$1" in
    apply) apply_rate ;;
    status)
        printf 'prop=%s\n' "$(getprop "$PROP" 2>/dev/null)"
        printf 'panel_max=%s\n' "$(panel_max_rate)"
        [ -f "$STATUS_FILE" ] && printf 'status=%s\n' "$(sed -n '1p' "$STATUS_FILE")"
        ;;
    *)
        echo "Usage: $0 {apply|status}" >&2
        exit 64
        ;;
esac
