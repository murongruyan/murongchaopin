#!/system/bin/sh

MODDIR=${0%/scripts/*}
STATE_DIR="$MODDIR/config/surfaceflinger_ltps_vote_patch"
STATE_FILE="$STATE_DIR/state.txt"
LOG_FILE="$STATE_DIR/apply.log"
BOOT_PENDING_FILE="$STATE_DIR/boot_pending.txt"
BOOT_BLOCK_FILE="$STATE_DIR/boot_guard_blocked.txt"
POLICY_FILE="$MODDIR/config/rmx5200_display_policy.txt"
SOURCE_FILE=/system/bin/surfaceflinger
PATCHED_FILE="$MODDIR/bin/surfaceflinger.rmx5200.stock-ltps-vote"

EXPECTED_MODEL=RMX5200
EXPECTED_POLICY=stock_ltps
EXPECTED_CONTEXT=u:object_r:surfaceflinger_exec:s0
VOTE_PATCH_OFFSET=5220408
VOTE_PATCH_SIZE=152
# The replaced block only emits tracing/logging before the request-map insert.
# Matching the complete block and its adjacent instructions pins the patch to
# this OTA implementation of OplusRefreshRateDirector::requestRefreshRate.
VOTE_ORIGINAL_HEX=400080527bbb13942003003688024039890a40f9e0dbffb000200491e203162ab80301d11f010072a80301d12115949ae0ba1394a8035c38a9035df8400080521f0100722115989ac4bb1394a8035c38a8000036a8035cf8a0035df801f97f92ecba139440008052c2bb139488024039890a40f9e1ddff9021443e91e2dbffb0422004911f01007260008052e403162a2315949a0fbb1394
VOTE_PATCHED_HEX=df020071ad040054880240391f010072810000540cfd41d389060091030000148c0640f9890a40f99f4100f1630300548c3d00d1eb4d8cd24badacf26b8ccef2ab25ecf2cd2d8dd2ad2dacf28d2ecdf2edcdedf22a0140f95f010beb810000542a0540f95f010deba0000054290500918c0500f101ffff5408000014a10000141f2003d51f2003d51f2003d51f2003d51f2003d51f2003d5
VOTE_PATCHED_OCTAL='\0337\0002\0000\0161\0255\0004\0000\0124\0210\0002\0100\0071\0037\0001\0000\0162\0201\0000\0000\0124\0014\0375\0101\0323\0211\0006\0000\0221\0003\0000\0000\0024\0214\0006\0100\0371\0211\0012\0100\0371\0237\0101\0000\0361\0143\0003\0000\0124\0214\0075\0000\0321\0353\0115\0214\0322\0113\0255\0254\0362\0153\0214\0316\0362\0253\0045\0354\0362\0315\0055\0215\0322\0255\0055\0254\0362\0215\0056\0315\0362\0355\0315\0355\0362\0052\0001\0100\0371\0137\0001\0013\0353\0201\0000\0000\0124\0052\0005\0100\0371\0137\0001\0015\0353\0240\0000\0000\0124\0051\0005\0000\0221\0214\0005\0000\0361\0001\0377\0377\0124\0010\0000\0000\0024\0241\0000\0000\0024\0037\0040\0003\0325\0037\0040\0003\0325\0037\0040\0003\0325\0037\0040\0003\0325\0037\0040\0003\0325\0037\0040\0003\0325'
CONTEXT_BEFORE_HEX=b8220091ab0700541f0300eb61070054
CONTEXT_AFTER_HEX=e8c30091e00313aae103162addfdff97
# The rejected first experiment modified this unrelated FRTC call. It must
# remain original in both the source and final payload.
LEGACY_CALL_OFFSET=2776340
LEGACY_CALL_ORIGINAL_HEX=de880194
LEGACY_CALL_NOP_HEX=1f2003d5
# updateBestFrameRate's AP-scale table remaps a correctly selected QHD60 mode
# to the overclocked 170Hz slot. Jump over only that remap block so every vote
# retains its own selected modePtr; this does not force or lock 60Hz.
AP_SCALE_AUDIT_OFFSET=5229872
AP_SCALE_ORIGINAL_HEX=01030054
AP_SCALE_PATCHED_HEX=18000014

hash_file()
{
    sha256sum "$1" 2>/dev/null | awk 'NR == 1 { print tolower($1) }'
}

file_size()
{
    wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

hex_range()
{
    od -An -tx1 -j "$2" -N "$3" "$1" 2>/dev/null |
        tr -d '[:space:]' | tr 'A-F' 'a-f'
}

hex_at()
{
    hex_range "$1" "$2" 4
}

log_line()
{
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

write_state()
{
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    printf '%s\n' "$1" > "$STATE_FILE" || return 1
    log_line "state=$1"
}

read_policy()
{
    sed -n '1{s/\r$//;p;q;}' "$POLICY_FILE" 2>/dev/null |
        tr -d '[:space:]'
}

verify_context()
{
    file=$1
    offset=${2:-$VOTE_PATCH_OFFSET}
    [ "$offset" -ge 16 ] 2>/dev/null || return 1
    [ "$(hex_range "$file" $((offset - 16)) 16)" = "$CONTEXT_BEFORE_HEX" ] &&
        [ "$(hex_range "$file" $((offset + VOTE_PATCH_SIZE)) 16)" = "$CONTEXT_AFTER_HEX" ]
}

verify_original()
{
    file=$1
    offset=${2:-$VOTE_PATCH_OFFSET}
    [ -r "$file" ] && verify_context "$file" "$offset" &&
        [ "$(hex_range "$file" "$offset" "$VOTE_PATCH_SIZE")" = "$VOTE_ORIGINAL_HEX" ] &&
        [ "$(hex_at "$file" "$LEGACY_CALL_OFFSET")" = "$LEGACY_CALL_ORIGINAL_HEX" ] &&
        [ "$(hex_at "$file" "$AP_SCALE_AUDIT_OFFSET")" = "$AP_SCALE_ORIGINAL_HEX" ]
}

verify_patched()
{
    file=$1
    offset=${2:-$VOTE_PATCH_OFFSET}
    [ -r "$file" ] && verify_context "$file" "$offset" &&
        [ "$(hex_range "$file" "$offset" "$VOTE_PATCH_SIZE")" = "$VOTE_PATCHED_HEX" ] &&
        [ "$(hex_at "$file" "$LEGACY_CALL_OFFSET")" = "$LEGACY_CALL_ORIGINAL_HEX" ] &&
        [ "$(hex_at "$file" "$AP_SCALE_AUDIT_OFFSET")" = "$AP_SCALE_PATCHED_HEX" ]
}

verify_legacy_patched()
{
    file=$1
    [ -r "$file" ] && verify_context "$file" "$VOTE_PATCH_OFFSET" &&
        [ "$(hex_range "$file" "$VOTE_PATCH_OFFSET" "$VOTE_PATCH_SIZE")" = "$VOTE_ORIGINAL_HEX" ] &&
        [ "$(hex_at "$file" "$LEGACY_CALL_OFFSET")" = "$LEGACY_CALL_NOP_HEX" ] &&
        { [ "$(hex_at "$file" "$AP_SCALE_AUDIT_OFFSET")" = "$AP_SCALE_ORIGINAL_HEX" ] ||
          [ "$(hex_at "$file" "$AP_SCALE_AUDIT_OFFSET")" = "$AP_SCALE_PATCHED_HEX" ]; }
}

verify_filter_only_patched()
{
    file=$1
    [ -r "$file" ] && verify_context "$file" "$VOTE_PATCH_OFFSET" &&
        [ "$(hex_range "$file" "$VOTE_PATCH_OFFSET" "$VOTE_PATCH_SIZE")" = "$VOTE_PATCHED_HEX" ] &&
        [ "$(hex_at "$file" "$LEGACY_CALL_OFFSET")" = "$LEGACY_CALL_ORIGINAL_HEX" ] &&
        [ "$(hex_at "$file" "$AP_SCALE_AUDIT_OFFSET")" = "$AP_SCALE_ORIGINAL_HEX" ]
}

# Build from the currently installed SurfaceFlinger. Whole-file hashes are
# audit output only; the semantic gate is the target instruction plus context.
patch_semantic_file()
{
    model=$1
    policy=$2
    source=$3
    output=$4
    offset=${5:-$VOTE_PATCH_OFFSET}

    [ "$model" = "$EXPECTED_MODEL" ] || return 10
    [ "$policy" = "$EXPECTED_POLICY" ] || return 11
    verify_original "$source" "$offset" || return 12

    output_dir=${output%/*}
    [ "$output_dir" != "$output" ] || output_dir=.
    mkdir -p "$output_dir" || return 13
    temp_file="$output.tmp.$$"
    rm -f "$temp_file" 2>/dev/null || true
    cp -f "$source" "$temp_file" || return 13
    if ! printf '%b' "$VOTE_PATCHED_OCTAL" |
            dd of="$temp_file" bs=1 seek="$offset" conv=notrunc \
                >/dev/null 2>&1 ||
            ! printf '\030\000\000\024' |
            dd of="$temp_file" bs=1 seek="$AP_SCALE_AUDIT_OFFSET" conv=notrunc \
                >/dev/null 2>&1 ||
            ! verify_patched "$temp_file" "$offset" ||
            [ "$(file_size "$temp_file")" != "$(file_size "$source")" ]; then
        rm -f "$temp_file" 2>/dev/null || true
        return 14
    fi
    mv -f "$temp_file" "$output" || {
        rm -f "$temp_file" 2>/dev/null || true
        return 15
    }
}

current_model()
{
    getprop ro.product.vendor.model 2>/dev/null
}

current_boot_id()
{
    sed -n '1p' /proc/sys/kernel/random/boot_id 2>/dev/null
}

pid1_mount_options()
{
    awk -v target="$SOURCE_FILE" \
        '$5 == target { options = $6 } END { print options }' \
        /proc/1/mountinfo 2>/dev/null
}

mount_allows_domain_transition()
{
    options=$(pid1_mount_options)
    [ -n "$options" ] || return 1
    case ",$options," in
        *,nosuid,*|*,noexec,*) return 1 ;;
    esac
    return 0
}

remount_for_domain_transition()
{
    # /data is nosuid. SurfaceFlinger needs an executable, suid-capable bind
    # for init to perform the SELinux domain transition at boot.
    mount -o remount,bind,suid,exec "$SOURCE_FILE" >/dev/null 2>&1 || return 1
    mount_allows_domain_transition
}

prepare_runtime_patch()
{
    model=$(current_model)
    policy=$(read_policy)
    if [ "$model" != "$EXPECTED_MODEL" ]; then
        write_state "skipped:model_${model:-unknown}"
        return 0
    fi
    if [ "$policy" != "$EXPECTED_POLICY" ]; then
        write_state "skipped:policy_${policy:-unknown}"
        return 0
    fi

    if verify_patched "$SOURCE_FILE"; then
        if remount_for_domain_transition; then
            write_state active:already_mounted
            return 0
        fi
        write_state error:existing_mount_nosuid
        return 1
    fi

    patch_semantic_file "$model" "$policy" "$SOURCE_FILE" "$PATCHED_FILE"
    result=$?
    if [ "$result" -ne 0 ]; then
        write_state "rejected:source_contract_${result}"
        return 1
    fi

    chmod 0755 "$PATCHED_FILE" || {
        write_state error:chmod
        return 1
    }
    chown 0:2000 "$PATCHED_FILE" || {
        write_state error:chown
        return 1
    }
    chcon "$EXPECTED_CONTEXT" "$PATCHED_FILE" >/dev/null 2>&1 || {
        write_state error:chcon
        return 1
    }
    if ! ls -Z "$PATCHED_FILE" 2>/dev/null | grep -q "$EXPECTED_CONTEXT"; then
        write_state error:context_mismatch
        return 1
    fi
    verify_patched "$PATCHED_FILE" || {
        write_state error:prepared_validation
        return 1
    }
    write_state prepared
}

apply_runtime_patch()
{
    model=$(current_model)
    policy=$(read_policy)
    if [ "$model" != "$EXPECTED_MODEL" ]; then
        write_state "skipped:model_${model:-unknown}"
        return 0
    fi
    if [ "$policy" != "$EXPECTED_POLICY" ]; then
        write_state "skipped:policy_${policy:-unknown}"
        return 0
    fi

    boot_id=$(current_boot_id)
    if [ -z "$boot_id" ]; then
        write_state rejected:boot_id_unavailable
        return 1
    fi
    if [ -s "$BOOT_BLOCK_FILE" ]; then
        write_state fallback:guard_blocked
        return 0
    fi
    pending_boot=$(sed -n '1p' "$BOOT_PENDING_FILE" 2>/dev/null)
    if [ -n "$pending_boot" ] && [ "$pending_boot" != "$boot_id" ]; then
        printf '%s\n' "$pending_boot" > "$BOOT_BLOCK_FILE" 2>/dev/null || true
        rm -f "$BOOT_PENDING_FILE" 2>/dev/null || true
        write_state fallback:previous_boot_incomplete
        return 0
    fi

    if verify_patched "$SOURCE_FILE"; then
        if remount_for_domain_transition; then
            write_state active:already_mounted
            return 0
        fi
        write_state error:existing_mount_nosuid
        return 1
    fi

    prepare_runtime_patch || return 1
    verify_original "$SOURCE_FILE" || {
        write_state rejected:pre_mount_source_changed
        return 1
    }
    printf '%s\n' "$boot_id" > "$BOOT_PENDING_FILE" || {
        write_state error:boot_guard_write
        return 1
    }
    mount --bind "$PATCHED_FILE" "$SOURCE_FILE" >/dev/null 2>&1 || {
        rm -f "$BOOT_PENDING_FILE" 2>/dev/null || true
        write_state error:bind_mount
        return 1
    }
    if ! remount_for_domain_transition; then
        umount "$SOURCE_FILE" >/dev/null 2>&1 || true
        rm -f "$BOOT_PENDING_FILE" 2>/dev/null || true
        write_state error:bind_mount_nosuid
        return 1
    fi
    if ! verify_patched "$SOURCE_FILE"; then
        umount "$SOURCE_FILE" >/dev/null 2>&1 || true
        rm -f "$BOOT_PENDING_FILE" 2>/dev/null || true
        write_state error:mounted_validation
        return 1
    fi
    if ! ls -Z "$SOURCE_FILE" 2>/dev/null | grep -q "$EXPECTED_CONTEXT"; then
        umount "$SOURCE_FILE" >/dev/null 2>&1 || true
        rm -f "$BOOT_PENDING_FILE" 2>/dev/null || true
        write_state error:mounted_context
        return 1
    fi
    write_state active
}

mark_boot_success()
{
    boot_id=$(current_boot_id)
    pending_boot=$(sed -n '1p' "$BOOT_PENDING_FILE" 2>/dev/null)
    [ -n "$boot_id" ] && [ "$pending_boot" = "$boot_id" ] || return 0
    [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || return 1
    pidof surfaceflinger >/dev/null 2>&1 || return 1
    verify_patched "$SOURCE_FILE" || return 1
    rm -f "$BOOT_PENDING_FILE" 2>/dev/null || return 1
    write_state active:boot_verified
}

clear_boot_guard()
{
    rm -f "$BOOT_PENDING_FILE" "$BOOT_BLOCK_FILE" 2>/dev/null || return 1
    write_state ready:guard_cleared
}

restore_runtime_patch()
{
    rm -f "$BOOT_PENDING_FILE" "$BOOT_BLOCK_FILE" 2>/dev/null || true
    if ! verify_patched "$SOURCE_FILE" &&
       ! verify_legacy_patched "$SOURCE_FILE" &&
       ! verify_filter_only_patched "$SOURCE_FILE"; then
        write_state restored:not_mounted
        return 0
    fi
    if ! umount "$SOURCE_FILE" >/dev/null 2>&1; then
        umount -l "$SOURCE_FILE" >/dev/null 2>&1 || {
            write_state error:unmount
            return 1
        }
    fi
    verify_original "$SOURCE_FILE" || {
        write_state error:restore_validation
        return 1
    }
    write_state restored
}

status_runtime_patch()
{
    printf 'state=%s\n' "$(sed -n '1p' "$STATE_FILE" 2>/dev/null)"
    printf 'model=%s\n' "$(current_model)"
    printf 'policy=%s\n' "$(read_policy)"
    printf 'source_sha256=%s\n' "$(hash_file "$SOURCE_FILE")"
    printf 'source_vote_filter_sha256=%s\n' \
        "$(hex_range "$SOURCE_FILE" "$VOTE_PATCH_OFFSET" "$VOTE_PATCH_SIZE" | sha256sum 2>/dev/null | awk 'NR == 1 { print tolower($1) }')"
    printf 'source_legacy_call_bytes=%s\n' \
        "$(hex_at "$SOURCE_FILE" "$LEGACY_CALL_OFFSET")"
    printf 'source_ap_scale_bytes=%s\n' \
        "$(hex_at "$SOURCE_FILE" "$AP_SCALE_AUDIT_OFFSET")"
    printf 'patched_sha256=%s\n' "$(hash_file "$PATCHED_FILE")"
    printf 'patched_context=%s\n' \
        "$(ls -Z "$PATCHED_FILE" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    printf 'boot_id=%s\n' "$(current_boot_id)"
    printf 'boot_pending=%s\n' "$(sed -n '1p' "$BOOT_PENDING_FILE" 2>/dev/null)"
    printf 'boot_guard_blocked=%s\n' \
        "$(sed -n '1p' "$BOOT_BLOCK_FILE" 2>/dev/null)"
    printf 'pid1_mount_options=%s\n' "$(pid1_mount_options)"
    if grep -F " $SOURCE_FILE " /proc/1/mountinfo >/dev/null 2>&1; then
        printf 'pid1_mount=present\n'
    else
        printf 'pid1_mount=absent\n'
    fi
}

mkdir -p "$STATE_DIR" 2>/dev/null || true
case "$1" in
    prepare) prepare_runtime_patch ;;
    apply) apply_runtime_patch ;;
    mark-boot-success) mark_boot_success ;;
    clear-boot-guard) clear_boot_guard ;;
    restore) restore_runtime_patch ;;
    status) status_runtime_patch ;;
    test-patch)
        [ "$#" -eq 5 ] || exit 2
        patch_semantic_file "$2" "$3" "$4" "$5"
        ;;
    *)
        printf 'usage: %s prepare|apply|mark-boot-success|clear-boot-guard|restore|status\n' "$0" >&2
        exit 2
        ;;
esac
