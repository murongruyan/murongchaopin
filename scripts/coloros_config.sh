#!/system/bin/sh

# Free (public) ColorOS display configuration path.
#
# The ColorOS display services read these files from the read-only /my_product
# partition. Validate the module copies semantically, then bind mount them over
# the vendor files. Stock hashes are deliberately not an output requirement.
#
# This script handles ONLY the free VRR + refresh-rate policy files. The
# Pixelworks/MEMC overlay (multimedia_pixelworks_apps.xml) was moved to the
# paid package at premium/scripts/coloros_config_premium.sh so the public
# module never depends on, nor fails over, the premium MEMC files.

SCRIPT_DIR=${0%/*}
MOD_DIR=${SCRIPT_DIR%/*}
SOURCE_DIR="$MOD_DIR/config/coloros"
STATE_DIR="$MOD_DIR/runtime/coloros_config"
STATUS_FILE="$STATE_DIR/status.txt"
LOG_FILE="$STATE_DIR/runtime.log"

VRR_SOURCE="$SOURCE_DIR/oplus_vrr_config.json"
RATE_SOURCE="$SOURCE_DIR/refresh_rate_config.xml"
VRR_TARGET="/my_product/etc/oplus_vrr_config.json"
RATE_TARGET="/my_product/etc/refresh_rate_config.xml"

mkdir -p "$STATE_DIR" 2>/dev/null

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

model_supported() {
    MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
    [ -n "$MODEL" ] || MODEL=$(getprop ro.product.model 2>/dev/null)
    case "$MODEL" in
        RMX5200|PLK110|PJD110) return 0 ;;
        *) return 1 ;;
    esac
}

sha256_file() {
    sha256sum "$1" 2>/dev/null | awk 'NR == 1 { print $1; exit }'
}

validate_source() {
    [ -r "$VRR_SOURCE" ] && [ -r "$RATE_SOURCE" ] || return 1
    grep -Eq '"feature_sa"[[:space:]]*:[[:space:]]*"true"' "$VRR_SOURCE" || return 1
    grep -Eq '"adfr_enable"[[:space:]]*:[[:space:]]*true' "$VRR_SOURCE" || return 1
    grep -q '"sf_framerate_ranges"' "$VRR_SOURCE" || return 1
    grep -q '"frtc_framerate_ranges"' "$VRR_SOURCE" || return 1
    for RATE in 120 90 60 30 10 1; do
        grep -q "\"$RATE\"" "$VRR_SOURCE" || return 1
    done
    grep -Eq '<refresh_rate_config[^>]*version="20260225"' "$RATE_SOURCE" || return 1
    grep -Eq '<config[^>]*maxrefreshsettings="3"' "$RATE_SOURCE" || return 1
    grep -q '<config[^>]*defaultMaxRate=' "$RATE_SOURCE" && return 1
    grep -q '<config[^>]*extremeHighEnable=' "$RATE_SOURCE" && return 1
    grep -q '</refresh_rate_config>' "$RATE_SOURCE" || return 1
    return 0
}

validate_applied() {
    cmp -s "$VRR_SOURCE" "$VRR_TARGET" &&
        cmp -s "$RATE_SOURCE" "$RATE_TARGET"
}

is_bind_mounted() {
    TARGET="$1"
    awk -v target="$TARGET" '$5 == target { found = 1 } END { exit !found }' \
        /proc/self/mountinfo 2>/dev/null
}

bind_one() {
    SOURCE="$1"
    TARGET="$2"
    mount --bind "$SOURCE" "$TARGET" >/dev/null 2>&1 || return 1
    [ "$(sha256_file "$TARGET")" = "$(sha256_file "$SOURCE")" ] || {
        umount "$TARGET" >/dev/null 2>&1
        return 1
    }
    return 0
}

apply_config() {
    model_supported || {
        set_status unsupported:model
        return 0
    }
    validate_source || {
        set_status error:source_integrity
        return 1
    }

    # A module reboot can leave the source already visible at the target. Do
    # not attempt a second bind in that case.
    if is_bind_mounted "$VRR_TARGET" && is_bind_mounted "$RATE_TARGET" &&
       validate_applied; then
        set_status applied:already
        return 0
    fi

    [ -r "$VRR_TARGET" ] && [ -r "$RATE_TARGET" ] || {
        set_status error:target_missing
        return 1
    }
    is_bind_mounted "$RATE_TARGET" && umount "$RATE_TARGET" >/dev/null 2>&1
    is_bind_mounted "$VRR_TARGET" && umount "$VRR_TARGET" >/dev/null 2>&1

    if ! bind_one "$VRR_SOURCE" "$VRR_TARGET"; then
        set_status error:bind_vrr
        return 1
    fi
    if ! bind_one "$RATE_SOURCE" "$RATE_TARGET"; then
        umount "$VRR_TARGET" >/dev/null 2>&1
        set_status error:bind_rate
        return 1
    fi

    if ! validate_applied; then
        umount "$RATE_TARGET" >/dev/null 2>&1
        umount "$VRR_TARGET" >/dev/null 2>&1
        set_status error:post_bind_verify
        return 1
    fi
    set_status applied:coloros_config
    return 0
}

remove_config() {
    umount "$RATE_TARGET" >/dev/null 2>&1 || true
    umount "$VRR_TARGET" >/dev/null 2>&1 || true
    set_status removed:coloros_config
}

status_config() {
    printf 'model=%s\n' "$(getprop ro.product.vendor.model 2>/dev/null)"
    printf 'vrr_source_hash=%s\n' "$(sha256_file "$VRR_SOURCE")"
    printf 'rate_source_hash=%s\n' "$(sha256_file "$RATE_SOURCE")"
    printf 'vrr_target_hash=%s\n' "$(sha256_file "$VRR_TARGET")"
    printf 'rate_target_hash=%s\n' "$(sha256_file "$RATE_TARGET")"
    if [ -f "$STATUS_FILE" ]; then
        printf 'status=%s\n' "$(sed -n '1p' "$STATUS_FILE")"
    else
        printf 'status=unknown\n'
    fi
}

case "$1" in
    apply) apply_config ;;
    remove) remove_config ;;
    status) status_config ;;
    *)
        echo "Usage: $0 {apply|remove|status}" >&2
        exit 64
        ;;
esac
