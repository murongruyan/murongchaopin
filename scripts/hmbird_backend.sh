#!/system/bin/sh

MOD_DIR=${0%/*}
MOD_DIR=${MOD_DIR%/*}
BIN_DIR="$MOD_DIR/bin"
IMG_DIR="$MOD_DIR/img"
WORK_DIR="$MOD_DIR/workspace"
AVB_HELPER="$MOD_DIR/scripts/dtbo_avb.sh"
HMBIRD_PATCHER="$MOD_DIR/scripts/patch_hmbird_dtbo.awk"
STATE_DIR="$MOD_DIR/runtime/hmbird"
STATUS_FILE="$STATE_DIR/status.txt"
LOG_FILE="$STATE_DIR/runtime.log"

mkdir -p "$STATE_DIR" 2>/dev/null

detect_soc() {
    soc=$(getprop ro.soc.model 2>/dev/null | tr -d '[:space:]')
    case "$soc" in
        SM8850|SM8850P|SM8845|SM8750|SM8750P|SM8650|SM8650P|MT6991|MT6993|MT6995)
            printf '%s\n' "$soc" ;;
        *) return 1 ;;
    esac
}

expected_type() {
    case "$1" in
        SM8850|SM8850P|SM8845|MT6995) printf '%s\n' HMBIRD_EXT ;;
        SM8750|SM8750P|SM8650|SM8650P|MT6991|MT6993) printf '%s\n' HMBIRD_OGKI ;;
        *) return 1 ;;
    esac
}

write_status() {
    printf '%s\n' "$1" > "$STATUS_FILE"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" >> "$LOG_FILE"
}

prepare_hmbird_dtbo() {
    HMBIRD_PARTITION="$2"
    [ -n "$HMBIRD_PARTITION" ] || {
        HMBIRD_SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
        HMBIRD_PARTITION="/dev/block/by-name/dtbo$HMBIRD_SLOT"
    }
    [ -b "$HMBIRD_PARTITION" ] || {
        echo "Error: HMBIRD DTBO target is not a block device: $HMBIRD_PARTITION" >&2
        return 1
    }
    SOC_MODEL=$(detect_soc) || {
        echo "Error: unsupported HMBIRD SoC" >&2
        return 1
    }
    HMBIRD_TYPE=$(expected_type "$SOC_MODEL") || return 1
    DEVICE_MODEL=$(getprop ro.product.vendor.model 2>/dev/null | tr -d '[:space:]')
    case "$DEVICE_MODEL" in
        PJD110)
            PROCESS_DTS_MODE=--pjd110-ko-support
            DTBO_PROFILE=pjd110-ko-support
            [ -x "$BIN_DIR/process_dts" ] || {
                echo "Error: PJD110 capacity helper is missing" >&2
                return 1
            }
            ;;
        *)
            PROCESS_DTS_MODE=
            DTBO_PROFILE=hmbird-only
            ;;
    esac
    [ -r "$AVB_HELPER" ] && [ -r "$HMBIRD_PATCHER" ] &&
        [ -x "$BIN_DIR/unpack_dtbo" ] && [ -x "$BIN_DIR/pack_dtbo" ] || {
        echo "Error: HMBIRD DTBO tooling is incomplete" >&2
        return 1
    }
    . "$AVB_HELPER" || return 1
    HMBIRD_STOCK="$IMG_DIR/dtbo.img"
    HMBIRD_MANIFEST="$IMG_DIR/dtbo.img.sha256"
    HMBIRD_PARTITION_SIZE=$(blockdev --getsize64 "$HMBIRD_PARTITION" 2>/dev/null)
    case "$HMBIRD_PARTITION_SIZE" in ''|*[!0-9]*|0) return 1 ;; esac
    dtbo_validate_stock_backup "$HMBIRD_STOCK" "$HMBIRD_MANIFEST" \
        "$HMBIRD_PARTITION_SIZE" "$BIN_DIR" >/dev/null 2>&1 || {
        echo "Error: stock DTBO baseline failed validation" >&2
        return 1
    }

    mkdir -p "$WORK_DIR" "$BIN_DIR/dtbo_dts" || return 1
    for HMBIRD_STALE in "$BIN_DIR"/dtbo_dts/*.dts \
        "$BIN_DIR"/dtbo_dts/avb_info.cfg; do
        [ -f "$HMBIRD_STALE" ] && rm -f "$HMBIRD_STALE"
    done
    cd "$BIN_DIR" || return 1
    ./unpack_dtbo "$HMBIRD_STOCK" >/dev/null 2>&1 || {
        echo "Error: unable to unpack stock DTBO for HMBIRD" >&2
        return 1
    }
    # PJD110 keeps its separate battery-capacity companion patch. HMBIRD is
    # normalized by the structure-only pass below regardless of this step.
    if [ -n "$PROCESS_DTS_MODE" ]; then
        ./process_dts "$PROCESS_DTS_MODE" >/dev/null 2>&1 || {
            echo "Error: unable to create $DTBO_PROFILE DTS" >&2
            return 1
        }
    fi
    HMBIRD_PATCH_COUNT=0
    HMBIRD_DTS_COUNT=0
    for HMBIRD_DTS in "$BIN_DIR"/dtbo_dts/*.dts; do
        [ -f "$HMBIRD_DTS" ] || continue
        HMBIRD_DTS_COUNT=$((HMBIRD_DTS_COUNT + 1))
        HMBIRD_PATCH_TMP="$HMBIRD_DTS.hmbird.$$"
        awk -v requested_type="$HMBIRD_TYPE" -f "$HMBIRD_PATCHER" \
            "$HMBIRD_DTS" > "$HMBIRD_PATCH_TMP"
        HMBIRD_PATCH_RC=$?
        case "$HMBIRD_PATCH_RC" in
            0)
                mv -f "$HMBIRD_PATCH_TMP" "$HMBIRD_DTS" || return 1
                HMBIRD_PATCH_COUNT=$((HMBIRD_PATCH_COUNT + 1))
                ;;
            3)
                rm -f "$HMBIRD_PATCH_TMP"
                echo "Error: no unambiguous HMBIRD target structure in $HMBIRD_DTS" >&2
                return 1
                ;;
            *)
                rm -f "$HMBIRD_PATCH_TMP"
                echo "Error: malformed or conflicting HMBIRD structure in $HMBIRD_DTS" >&2
                return 1
                ;;
        esac
    done
    [ "$HMBIRD_DTS_COUNT" -gt 0 ] &&
        [ "$HMBIRD_PATCH_COUNT" -eq "$HMBIRD_DTS_COUNT" ] || {
        echo "Error: expected every DTBO entry to be patched (patched=$HMBIRD_PATCH_COUNT entries=$HMBIRD_DTS_COUNT)" >&2
        return 1
    }
    ./pack_dtbo >/dev/null 2>&1 || {
        echo "Error: unable to pack $DTBO_PROFILE DTBO" >&2
        return 1
    }
    HMBIRD_RAW="$BIN_DIR/new_dtbo.img"
    HMBIRD_FINAL="$WORK_DIR/$DTBO_PROFILE-final.img"
    [ -f "$HMBIRD_RAW" ] || return 1
    dtbo_apply_stock_avb "$HMBIRD_STOCK" "$HMBIRD_RAW" "$HMBIRD_FINAL" \
        "$HMBIRD_PARTITION_SIZE" "$BIN_DIR" >/dev/null 2>&1 || {
        echo "Error: unable to apply stock AVB metadata to $DTBO_PROFILE DTBO" >&2
        return 1
    }
    dtbo_write_partition "$HMBIRD_FINAL" "$HMBIRD_PARTITION" >/dev/null 2>&1 || {
        echo "Error: unable to write $DTBO_PROFILE DTBO" >&2
        return 1
    }
    if [ "$DEVICE_MODEL" = PJD110 ]; then
        printf 'Success: PJD110 KO companion DTBO applied (capacity=6000mAh, vbat=2800mV, reserve_soc=1, type=%s, display modes unchanged)\n' \
            "$HMBIRD_TYPE"
    else
        printf 'Success: HMBIRD-only DTBO applied (type=%s, display modes unchanged)\n' \
            "$HMBIRD_TYPE"
    fi
    return 0
}

apply_hmbird() {
    # Kept as a compatibility command for old WebUI callers. HMBIRD is now
    # DTBO-only; no standalone KO is present or loaded by this module.
    write_status disabled:dtbo_only
    return 0
}

case "$1" in
    apply) apply_hmbird ;;
    prepare-dtbo) prepare_hmbird_dtbo "$@" ;;
    status)
        printf 'feature=free_hmbird\n'
        [ -f "$STATUS_FILE" ] && printf 'status=%s\n' "$(sed -n '1p' "$STATUS_FILE")" || printf 'status=unknown\n'
        ;;
    *)
        echo "Usage: $0 {prepare-dtbo [partition]|status}" >&2
        exit 64
        ;;
esac
