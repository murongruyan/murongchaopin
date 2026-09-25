#!/system/bin/sh
# Keep the active display density aligned with the width that is really on
# screen.
#
# ColorOS picks the density from the user's display-size slot and the active
# resolution: FHD ladders live in ro.density.screenzoom.fdh, QHD in
# ro.density.screenzoom.qdh, both comma separated per slot. The WebUI handler
# applies the same rule when the user switches resolution there; the daemon
# calls this script after any mode transaction that changed the geometry
# (global or per-application), because a width change on its own leaves the
# previous resolution's DPI active and the UI renders at the wrong scale.
#
# Usage:
#   geometry_density.sh apply  <width>
#   geometry_density.sh status <width>

set -u

MODE="${1:-apply}"
TARGET_WIDTH="${2:-}"

case "$TARGET_WIDTH" in
    ''|*[!0-9]*)
        echo "Error: a display width is required"
        exit 2
        ;;
esac

WIDTHS=$(dumpsys SurfaceFlinger 2>/dev/null |
    sed -n 's/.*resolution=\([0-9][0-9]*\)x[0-9][0-9]*.*/\1/p' |
    sort -n -u)
WIDTH_MIN=$(printf '%s\n' "$WIDTHS" | head -n 1)
WIDTH_MAX=$(printf '%s\n' "$WIDTHS" | tail -n 1)
case "$WIDTH_MIN:$WIDTH_MAX" in
    ''|*[!0-9:]*|:|*:|*::*)
        echo "Error: cannot read the display widths"
        exit 1
        ;;
esac

if [ "$TARGET_WIDTH" = "$WIDTH_MAX" ]; then
    ADJUST=3
    SCALE=$(getprop ro.density.screenzoom.qdh 2>/dev/null)
elif [ "$TARGET_WIDTH" = "$WIDTH_MIN" ] && [ "$WIDTH_MIN" != "$WIDTH_MAX" ]; then
    ADJUST=2
    SCALE=$(getprop ro.density.screenzoom.fdh 2>/dev/null)
else
    echo "Error: unknown display width $TARGET_WIDTH"
    exit 1
fi

INDEX=$(settings get system display_density_index_manual 2>/dev/null |
    tr -d '[:space:]')
case "$INDEX" in
    ''|*[!0-9]*)
        echo "Error: display_density_index_manual is unavailable"
        exit 1
        ;;
esac

DENSITY=$(printf '%s\n' "$SCALE" | awk -F, -v field="$((INDEX + 1))" \
    'field >= 1 && field <= NF && $field ~ /^[0-9]+$/ { print $field }')
case "$DENSITY" in
    ''|*[!0-9]*)
        echo "Error: no density for display-size slot $INDEX"
        exit 1
        ;;
esac
[ "$DENSITY" -ge 72 ] 2>/dev/null && [ "$DENSITY" -le 2000 ] 2>/dev/null || {
    echo "Error: density $DENSITY is out of range"
    exit 1
}

CURRENT_DENSITY=$(settings get secure display_density_forced 2>/dev/null |
    tr -d '[:space:]')
CURRENT_ADJUST=$(settings get secure oplus_customize_screen_resolution_adjust 2>/dev/null |
    tr -d '[:space:]')

case "$MODE" in
    status)
        printf 'width=%s adjust=%s density=%s forced=%s\n' \
            "$TARGET_WIDTH" "$ADJUST" "$DENSITY" "$CURRENT_DENSITY"
        ;;
    apply)
        if [ "$CURRENT_DENSITY" != "$DENSITY" ]; then
            wm density "$DENSITY" >/dev/null 2>&1 || {
                echo "Error: unable to apply density $DENSITY"
                exit 1
            }
        fi
        if [ "$CURRENT_ADJUST" != "$ADJUST" ]; then
            settings put secure oplus_customize_screen_resolution_adjust \
                "$ADJUST" >/dev/null 2>&1
            settings put secure user_preferred_screen_index \
                "$ADJUST" >/dev/null 2>&1
        fi
        printf 'applied width=%s adjust=%s density=%s\n' \
            "$TARGET_WIDTH" "$ADJUST" "$DENSITY"
        ;;
    *)
        echo "Usage: $0 {apply|status} <width>"
        exit 64
        ;;
esac
