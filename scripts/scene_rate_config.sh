#!/system/bin/sh

# Enable the refresh-rate feature inside Scene (com.omarea.vtools).
#
# Scene keeps its own feature switches under its private files directory; the
# refresh-rate panel is inert while features/refresh_rate.conf has enable=0,
# which is the default after a fresh install or an upgrade.  Scene then builds
# its list from Display.getSupportedModes(), so the modes published by the
# display backend (including the overclocked ones) appear as soon as the
# feature is on.  Only the flag is touched and only when Scene is installed.

SCENE_PKG=com.omarea.vtools
SCENE_FILES=/data/data/$SCENE_PKG/files
SCENE_CONF="$SCENE_FILES/features/refresh_rate.conf"
SCRIPT_DIR=${0%/*}
MOD_DIR=${SCRIPT_DIR%/*}
STATUS_DIR="$MOD_DIR/runtime/scene_rate_config"
STATUS_FILE="$STATUS_DIR/status.txt"

mkdir -p "$STATUS_DIR" 2>/dev/null

set_status() {
    printf '%s\n' "$1" > "$STATUS_FILE" 2>/dev/null
}

apply() {
    [ -d "$SCENE_FILES" ] || {
        set_status skipped:scene_not_installed
        return 0
    }
    [ -d "$SCENE_FILES/features" ] || mkdir -p "$SCENE_FILES/features" 2>/dev/null

    if [ -f "$SCENE_CONF" ] &&
       grep -q '^[[:space:]]*enable[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
           "$SCENE_CONF" 2>/dev/null; then
        set_status kept:already_enabled
        return 0
    fi

    owner=$(stat -c '%u:%g' "$SCENE_FILES" 2>/dev/null)
    tmp="$SCENE_CONF.tmp.$$"
    printf 'enable=1\n' > "$tmp" 2>/dev/null || {
        set_status error:write_failed
        return 1
    }
    chmod 0600 "$tmp" 2>/dev/null
    [ -n "$owner" ] && chown "$owner" "$tmp" 2>/dev/null
    mv -f "$tmp" "$SCENE_CONF" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null
        set_status error:replace_failed
        return 1
    }
    set_status "applied:enable=1,owner=${owner:-unknown}"
    return 0
}

status() {
    printf 'scene_conf=%s\n' "$SCENE_CONF"
    [ -f "$SCENE_CONF" ] && printf 'scene_value=%s\n' "$(sed -n '1p' "$SCENE_CONF")"
    [ -f "$STATUS_FILE" ] && printf 'status=%s\n' "$(sed -n '1p' "$STATUS_FILE")"
}

case "$1" in
    apply) apply ;;
    status) status ;;
    *)
        echo "Usage: $0 {apply|status}" >&2
        exit 64
        ;;
esac
