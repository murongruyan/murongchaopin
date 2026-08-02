#!/system/bin/sh

# Reuse the official DTBO AVB metadata instead of generating a new key.
# The input target must be the raw mkdtimg output, while stock_image is the
# complete official DTBO image copied from the current partition.

dtbo_msg() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$*"
    else
        echo "$*" >&2
    fi
}

dtbo_file_size() {
    wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

dtbo_is_number() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    return 0
}

dtbo_read_magic() {
    dd if="$1" bs=1 skip="$2" count=4 2>/dev/null |
        od -An -t x1 -v 2>/dev/null | tr -d '[:space:]'
}

dtbo_read_be64() {
    dtbo_be64_hex=$(dd if="$1" bs=1 skip="$2" count=8 2>/dev/null |
        od -An -t x1 -v 2>/dev/null | tr -d '[:space:]')
    [ "${#dtbo_be64_hex}" -eq 16 ] || {
        echo 0
        return 0
    }
    echo $((0x$dtbo_be64_hex))
}

dtbo_write_be64() {
    dtbo_be64_value="$1"
    dtbo_be64_output="$2"
    dtbo_be64_shift=56
    while [ "$dtbo_be64_shift" -ge 0 ]; do
        dtbo_be64_byte=$(( (dtbo_be64_value >> dtbo_be64_shift) & 255 ))
        dtbo_be64_octal=$(printf '%03o' "$dtbo_be64_byte") || return 1
        printf "\\$dtbo_be64_octal" >> "$dtbo_be64_output" || return 1
        dtbo_be64_shift=$((dtbo_be64_shift - 8))
    done
}

dtbo_hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

dtbo_hash_device_prefix() {
    dtbo_hash_device_path="$1"
    dtbo_hash_device_size="$2"
    if command -v sha256sum >/dev/null 2>&1; then
        head -c "$dtbo_hash_device_size" "$dtbo_hash_device_path" 2>/dev/null |
            sha256sum 2>/dev/null | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        head -c "$dtbo_hash_device_size" "$dtbo_hash_device_path" 2>/dev/null |
            md5sum 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

dtbo_extract_stock_vbmeta() {
    dtbo_stock_image="$1"
    dtbo_stock_vbmeta="$2"
    dtbo_stock_size=$(dtbo_file_size "$dtbo_stock_image")

    dtbo_is_number "$dtbo_stock_size" || return 1
    [ "$dtbo_stock_size" -ge 64 ] || return 1

    dtbo_stock_footer_offset=$((dtbo_stock_size - 64))
    [ "$(dtbo_read_magic "$dtbo_stock_image" "$dtbo_stock_footer_offset")" = "41564266" ] || return 1

    dtbo_stock_original_size=$(dtbo_read_be64 "$dtbo_stock_image" $((dtbo_stock_footer_offset + 12)))
    dtbo_stock_vbmeta_offset=$(dtbo_read_be64 "$dtbo_stock_image" $((dtbo_stock_footer_offset + 20)))
    dtbo_stock_vbmeta_size=$(dtbo_read_be64 "$dtbo_stock_image" $((dtbo_stock_footer_offset + 28)))

    dtbo_is_number "$dtbo_stock_original_size" || return 1
    dtbo_is_number "$dtbo_stock_vbmeta_offset" || return 1
    dtbo_is_number "$dtbo_stock_vbmeta_size" || return 1
    [ "$dtbo_stock_vbmeta_size" -gt 0 ] || return 1
    [ "$dtbo_stock_original_size" -le "$dtbo_stock_vbmeta_offset" ] || return 1
    [ $((dtbo_stock_vbmeta_offset + dtbo_stock_vbmeta_size)) -le "$dtbo_stock_footer_offset" ] || return 1

    dd if="$dtbo_stock_image" bs=1 skip="$dtbo_stock_vbmeta_offset" \
        count="$dtbo_stock_vbmeta_size" of="$dtbo_stock_vbmeta" 2>/dev/null || return 1
    [ "$(dtbo_file_size "$dtbo_stock_vbmeta")" = "$dtbo_stock_vbmeta_size" ] || return 1
    [ "$(dtbo_read_magic "$dtbo_stock_vbmeta" 0)" = "41564230" ] || return 1

    DTBO_STOCK_SIZE="$dtbo_stock_size"
    DTBO_STOCK_FOOTER_OFFSET="$dtbo_stock_footer_offset"
    DTBO_STOCK_ORIGINAL_SIZE="$dtbo_stock_original_size"
    DTBO_STOCK_VBMETA_OFFSET="$dtbo_stock_vbmeta_offset"
    DTBO_STOCK_VBMETA_SIZE="$dtbo_stock_vbmeta_size"
    return 0
}

dtbo_validate_stock_avb() {
    dtbo_validate_stock="$1"
    dtbo_validate_partition_size="$2"
    dtbo_validate_dir="${TMPDIR:-/data/local/tmp}/murongchaopin-avb-check.$$"
    mkdir -p "$dtbo_validate_dir" 2>/dev/null || return 1

    if ! dtbo_extract_stock_vbmeta "$dtbo_validate_stock" "$dtbo_validate_dir/vbmeta.bin"; then
        rm -rf "$dtbo_validate_dir"
        dtbo_msg "! 官方 DTBO 未找到有效的 AVB footer/VBMeta"
        return 1
    fi
    if dtbo_is_number "$dtbo_validate_partition_size" && [ "$dtbo_validate_partition_size" -gt 0 ] &&
        [ "$DTBO_STOCK_SIZE" != "$dtbo_validate_partition_size" ]; then
        rm -rf "$dtbo_validate_dir"
        dtbo_msg "! 官方 DTBO 大小与当前分区不一致"
        return 1
    fi

    rm -rf "$dtbo_validate_dir"
    return 0
}

dtbo_apply_stock_avb() {
    dtbo_stock_image="$1"
    dtbo_raw_image="$2"
    dtbo_output_image="$3"
    dtbo_partition_size="$4"
    dtbo_work="${TMPDIR:-/data/local/tmp}/murongchaopin-avb-$$"
    dtbo_vbmeta="$dtbo_work/vbmeta.bin"
    dtbo_footer="$dtbo_work/footer.bin"
    dtbo_output="$dtbo_work/output.img"
    dtbo_raw_input="$dtbo_work/raw.img"

    [ -f "$dtbo_stock_image" ] || {
        dtbo_msg "! 缺少官方 DTBO 备份: $dtbo_stock_image"
        return 1
    }
    [ -f "$dtbo_raw_image" ] || {
        dtbo_msg "! 缺少待写入的原始 DTBO: $dtbo_raw_image"
        return 1
    }
    mkdir -p "$dtbo_work" 2>/dev/null || return 1

    if ! dtbo_extract_stock_vbmeta "$dtbo_stock_image" "$dtbo_vbmeta"; then
        dtbo_msg "! 官方 DTBO 的 AVB footer/VBMeta 无效"
        rm -rf "$dtbo_work"
        return 1
    fi
    if dtbo_is_number "$dtbo_partition_size" && [ "$dtbo_partition_size" -gt 0 ] &&
        [ "$DTBO_STOCK_SIZE" != "$dtbo_partition_size" ]; then
        dtbo_msg "! 官方 DTBO 大小与当前分区不一致，拒绝刷入"
        rm -rf "$dtbo_work"
        return 1
    fi

    dtbo_raw_size=$(dtbo_file_size "$dtbo_raw_image")
    dtbo_is_number "$dtbo_raw_size" || {
        dtbo_msg "! 待写入 DTBO 大小读取失败"
        rm -rf "$dtbo_work"
        return 1
    }
    [ "$dtbo_raw_size" -gt 0 ] || {
        dtbo_msg "! 待写入 DTBO 为空"
        rm -rf "$dtbo_work"
        return 1
    }

    # Strip a footer produced by an older local pack_dtbo binary before
    # applying the official metadata, keeping upgrades compatible.
    if [ "$dtbo_raw_size" -ge 64 ] &&
        [ "$(dtbo_read_magic "$dtbo_raw_image" $((dtbo_raw_size - 64)))" = "41564266" ]; then
        dtbo_old_original_size=$(dtbo_read_be64 "$dtbo_raw_image" $((dtbo_raw_size - 52)))
        if dtbo_is_number "$dtbo_old_original_size" && [ "$dtbo_old_original_size" -gt 0 ] &&
            [ "$dtbo_old_original_size" -le $((dtbo_raw_size - 64)) ]; then
            head -c "$dtbo_old_original_size" "$dtbo_raw_image" > "$dtbo_raw_input" 2>/dev/null || {
                rm -rf "$dtbo_work"
                return 1
            }
            dtbo_raw_image="$dtbo_raw_input"
            dtbo_raw_size="$dtbo_old_original_size"
        fi
    fi
    [ "$dtbo_raw_size" -le "$DTBO_STOCK_VBMETA_OFFSET" ] || {
        dtbo_msg "! 修改后的 DTBO 超出官方 AVB 数据区"
        rm -rf "$dtbo_work"
        return 1
    }

    dtbo_padding_after=$((DTBO_STOCK_FOOTER_OFFSET - dtbo_raw_size - DTBO_STOCK_VBMETA_SIZE))
    [ "$dtbo_padding_after" -ge 0 ] || {
        dtbo_msg "! 修改后的 DTBO 没有足够的 AVB 空间"
        rm -rf "$dtbo_work"
        return 1
    }

    head -c "$dtbo_raw_size" "$dtbo_raw_image" > "$dtbo_output" 2>/dev/null || {
        rm -rf "$dtbo_work"
        return 1
    }
    cat "$dtbo_vbmeta" >> "$dtbo_output" || {
        rm -rf "$dtbo_work"
        return 1
    }
    if [ "$dtbo_padding_after" -gt 0 ]; then
        dd if=/dev/zero bs=1 count="$dtbo_padding_after" 2>/dev/null >> "$dtbo_output" || {
            rm -rf "$dtbo_work"
            return 1
        }
    fi

    # Preserve the official footer version and reserved bytes. Only the image
    # size and VBMeta offset are changed to match the new raw DTBO payload.
    dd if="$dtbo_stock_image" bs=1 skip="$DTBO_STOCK_FOOTER_OFFSET" count=12 \
        of="$dtbo_footer" 2>/dev/null || {
        rm -rf "$dtbo_work"
        return 1
    }
    dtbo_write_be64 "$DTBO_STOCK_ORIGINAL_SIZE" "$dtbo_footer" || {
        rm -rf "$dtbo_work"
        return 1
    }
    dtbo_write_be64 "$dtbo_raw_size" "$dtbo_footer" || {
        rm -rf "$dtbo_work"
        return 1
    }
    dtbo_write_be64 "$DTBO_STOCK_VBMETA_SIZE" "$dtbo_footer" || {
        rm -rf "$dtbo_work"
        return 1
    }
    dd if="$dtbo_stock_image" bs=1 skip=$((DTBO_STOCK_FOOTER_OFFSET + 36)) count=28 \
        >> "$dtbo_footer" 2>/dev/null || {
        rm -rf "$dtbo_work"
        return 1
    }
    [ "$(dtbo_file_size "$dtbo_footer")" = 64 ] || {
        rm -rf "$dtbo_work"
        return 1
    }
    cat "$dtbo_footer" >> "$dtbo_output" || {
        rm -rf "$dtbo_work"
        return 1
    }

    dtbo_output_size=$(dtbo_file_size "$dtbo_output")
    [ "$dtbo_output_size" = "$DTBO_STOCK_SIZE" ] || {
        dtbo_msg "! 组合后的 DTBO 大小异常"
        rm -rf "$dtbo_work"
        return 1
    }
    [ "$(dtbo_read_magic "$dtbo_output" $((dtbo_output_size - 64)))" = "41564266" ] || {
        dtbo_msg "! 组合后的 DTBO footer 校验失败"
        rm -rf "$dtbo_work"
        return 1
    }

    mv -f "$dtbo_output" "$dtbo_output_image" || {
        rm -rf "$dtbo_work"
        return 1
    }
    rm -rf "$dtbo_work"
    dtbo_msg "- 已复用官方 AVB 信息，生成免解 DTBO"
    return 0
}

dtbo_write_partition() {
    dtbo_image="$1"
    dtbo_partition="$2"
    [ -f "$dtbo_image" ] || return 1
    [ -e "$dtbo_partition" ] || {
        dtbo_msg "! 未找到 DTBO 分区: $dtbo_partition"
        return 1
    }

    dtbo_image_size=$(dtbo_file_size "$dtbo_image")
    dtbo_block_size=$(blockdev --getsize64 "$dtbo_partition" 2>/dev/null)
    dtbo_is_number "$dtbo_image_size" || return 1
    if dtbo_is_number "$dtbo_block_size" && [ "$dtbo_block_size" -gt 0 ] &&
        [ "$dtbo_image_size" != "$dtbo_block_size" ]; then
        dtbo_msg "! DTBO 镜像大小与分区不一致，拒绝写入"
        return 1
    fi

    dd if="$dtbo_image" of="$dtbo_partition" bs=4096 conv=fsync 2>/dev/null || return 1
    sync
    dtbo_source_hash=$(dtbo_hash_file "$dtbo_image")
    dtbo_readback_hash=$(dtbo_hash_device_prefix "$dtbo_partition" "$dtbo_image_size")
    [ -n "$dtbo_source_hash" ] && [ "$dtbo_source_hash" = "$dtbo_readback_hash" ] || {
        dtbo_msg "! DTBO 写入后回读校验失败"
        return 1
    }
    return 0
}
