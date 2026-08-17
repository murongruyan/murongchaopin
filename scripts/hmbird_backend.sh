#!/system/bin/sh

MOD_DIR=${0%/*}
MOD_DIR=${MOD_DIR%/*}
BIN_DIR="$MOD_DIR/bin"
IMG_DIR="$MOD_DIR/img"
WORK_DIR="$MOD_DIR/workspace"
KO_MODULE="$MOD_DIR/bin/hmbird.ko"
AVB_HELPER="$MOD_DIR/scripts/dtbo_avb.sh"
STATE_DIR="$MOD_DIR/runtime/hmbird"
STATUS_FILE="$STATE_DIR/status.txt"
LOG_FILE="$STATE_DIR/runtime.log"
SYS_MODULE_ROOT=${HMBIRD_SYS_MODULE_ROOT:-/sys/module}

mkdir -p "$STATE_DIR" 2>/dev/null

detect_ui_family() {
    realme_ui=$(getprop ro.build.version.realmeui 2>/dev/null | tr -d '[:space:]')
    brand=$(getprop ro.product.brand 2>/dev/null | tr '[:upper:]' '[:lower:]')
    manufacturer=$(getprop ro.product.manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]')
    oplus_rom=$(getprop ro.build.version.oplusrom 2>/dev/null | tr -d '[:space:]')
    coloros=$(getprop ro.build.version.coloros 2>/dev/null | tr -d '[:space:]')
    if [ -n "$realme_ui" ] || [ "$brand" = realme ] || [ "$manufacturer" = realme ]; then
        printf '%s\n' realmeui
    elif [ -n "$coloros" ] || { [ "$brand" = oppo ] || [ "$brand" = oneplus ] ||
        [ "$manufacturer" = oppo ] || [ "$manufacturer" = oneplus ]; } && [ -n "$oplus_rom" ]; then
        printf '%s\n' coloros
    else
        return 1
    fi
}

detect_soc() {
    soc=$(getprop ro.soc.model 2>/dev/null | tr -d '[:space:]')
    case "$soc" in
        SM8850|SM8850P|SM8845|SM8750|SM8750P|SM8650|SM8650P|MT6991|MT6993)
            printf '%s\n' "$soc" ;;
        *) return 1 ;;
    esac
}

expected_type() {
    case "$1" in
        SM8850|SM8850P|SM8845) printf '%s\n' HMBIRD_EXT ;;
        SM8750|SM8750P|SM8650|SM8650P|MT6991|MT6993) printf '%s\n' HMBIRD_OGKI ;;
        *) return 1 ;;
    esac
}

module_parameter() {
    # Module parameters are read-only exports from hmbird.ko.  Treat a
    # missing parameter as an invalid pre-existing module rather than
    # assuming that any module with this name is ours.
    parameter="$1"
    [ -r "$SYS_MODULE_ROOT/hmbird/parameters/$parameter" ] || return 1
    sed -n '1p' "$SYS_MODULE_ROOT/hmbird/parameters/$parameter" 2>/dev/null |
        tr -d '[:space:]'
}

existing_module_matches() {
    [ "$(module_parameter ui_valid 2>/dev/null)" = 1 ] ||
        [ "$(module_parameter ui_valid 2>/dev/null)" = Y ] || return 1
    [ "$(module_parameter soc_valid 2>/dev/null)" = 1 ] ||
        [ "$(module_parameter soc_valid 2>/dev/null)" = Y ] || return 1
    [ "$(module_parameter type_valid 2>/dev/null)" = 1 ] ||
        [ "$(module_parameter type_valid 2>/dev/null)" = Y ] || return 1
    [ "$(module_parameter node_present 2>/dev/null)" = 1 ] ||
        [ "$(module_parameter node_present 2>/dev/null)" = Y ] || return 1
    [ "$(module_parameter selected_type 2>/dev/null)" = "$HMBIRD_TYPE" ] || return 1
    [ "$(module_parameter failure_code 2>/dev/null)" = 0 ] || return 1
}

detect_dynamic_of() {
    # The module has weak references so it can load on kernels without
    # CONFIG_OF_DYNAMIC.  Only allow live-node creation when the running
    # kernel advertises the complete changeset API.
    [ -r /proc/kallsyms ] || {
        printf '%s\n' 0
        return 0
    }
    for symbol in init destroy apply revert create_node add_prop_string; do
        grep -Eq "[[:space:]]of_changeset_${symbol}[[:space:]]" /proc/kallsyms 2>/dev/null || {
            printf '%s\n' 0
            return 0
        }
    done
    printf '%s\n' 1
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
    UI_FAMILY=$(detect_ui_family) || {
        echo "Error: HMBIRD requires ColorOS or Realme UI" >&2
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
            [ "$HMBIRD_TYPE" = HMBIRD_OGKI ] || {
                echo "Error: PJD110 requires HMBIRD_OGKI" >&2
                return 1
            }
            PROCESS_DTS_MODE=--pjd110-ko-support
            DTBO_PROFILE=pjd110-ko-support
            ;;
        *)
            PROCESS_DTS_MODE="--hmbird-only=$HMBIRD_TYPE"
            DTBO_PROFILE=hmbird-only
            ;;
    esac
    [ -r "$AVB_HELPER" ] && [ -x "$BIN_DIR/unpack_dtbo" ] &&
        [ -x "$BIN_DIR/process_dts" ] && [ -x "$BIN_DIR/pack_dtbo" ] || {
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
    ./process_dts "$PROCESS_DTS_MODE" >/dev/null 2>&1 || {
        echo "Error: unable to create $DTBO_PROFILE DTS" >&2
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
    [ -r "$KO_MODULE" ] || {
        write_status blocked:ko_missing
        return 0
    }
    UI_FAMILY=$(detect_ui_family) || {
        write_status unsupported:ui_family
        return 0
    }
    SOC_MODEL=$(detect_soc) || {
        write_status unsupported:soc_model
        return 0
    }
    HMBIRD_TYPE=$(expected_type "$SOC_MODEL") || {
        write_status unsupported:hmbird_type
        return 0
    }
    if [ -d "$SYS_MODULE_ROOT/hmbird" ]; then
        if existing_module_matches; then
            write_status "applied:module_existing,type=$HMBIRD_TYPE"
        else
            write_status blocked:existing_module_mismatch
        fi
        return 0
    fi
    chmod 0600 "$KO_MODULE" 2>/dev/null
    DYNAMIC_OF=$(detect_dynamic_of)
    insmod "$KO_MODULE" enable=1 probe_only=0 \
        dynamic_of="$DYNAMIC_OF" ui_family="$UI_FAMILY" soc_model="$SOC_MODEL" hmbird_type="$HMBIRD_TYPE" \
        >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        write_status error:insmod:$rc
        return 0
    fi
    node_created=$(cat "$SYS_MODULE_ROOT/hmbird/parameters/node_created" 2>/dev/null)
    node_present=$(cat "$SYS_MODULE_ROOT/hmbird/parameters/node_present" 2>/dev/null)
    selected_type=$(cat "$SYS_MODULE_ROOT/hmbird/parameters/selected_type" 2>/dev/null)
    reinit=$(cat "$SYS_MODULE_ROOT/hmbird/parameters/consumer_reinit_supported" 2>/dev/null)
    if [ "$node_present" = Y ] || [ "$node_present" = 1 ]; then
        write_status "applied:node_present=$node_present,node_created=$node_created,type=$selected_type,consumer_reinit=$reinit"
    else
        write_status "error:node_missing:type=$selected_type"
    fi
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
        echo "Usage: $0 {apply|prepare-dtbo [partition]|status}" >&2
        exit 64
        ;;
esac
