#!/system/bin/sh

MODDIR=${0%/scripts/*}
STATE_DIR="$MODDIR/config/surfaceflinger_ltps_vote_patch"
STATE_FILE="$STATE_DIR/state.txt"
LOG_FILE="$STATE_DIR/apply.log"
BOOT_PENDING_FILE="$STATE_DIR/boot_pending.txt"
BOOT_BLOCK_FILE="$STATE_DIR/boot_guard_blocked.txt"
DYNAMIC_SITE_FILE="$STATE_DIR/dynamic-site-entry"
POLICY_FILE="$MODDIR/config/rmx5200_display_policy.txt"
SOURCE_FILE=/system/bin/surfaceflinger
PATCHED_FILE="$MODDIR/bin/surfaceflinger.rmx5200.stock-ltps-vote"

EXPECTED_MODEL=RMX5200

# This vote filter is an RMX5200-only mechanism, and the script must say so.
#
# RMX5200 is the device whose stock LTPS is broken by the vendor's own votes: an
# animation vote plus an AP-scale table lookup resolves a legitimate 144Hz
# request into the FHD-group 123Hz mode, and the filter drops that vote so the
# requested mode survives.  That is what "stock_ltps" means here.
#
# PLK110 / PLQ110 / PJD110 ship vendor LTPO - web_handler.sh sets
# DISPLAY_PROFILE=vendor_ltpo for all three - and there is nothing to filter:
# the vendor directs refresh rates itself.  So skipping on those models is not a
# limitation, it is the correct behaviour.
#
# It also closes a real hole.  The policy file ships as "stock_ltps" to every
# model and the installer does not rewrite it per model, while
# ltps_vote_wanted() treats "stock_ltps" as a request for this patch.  PLK110
# therefore arrived with a policy value that web_handler.sh rejects as invalid
# for that model (set_display_policy accepts only stock_ltpo / adfr_off there)
# AND that armed an RMX5200-only patch on hardware it was never validated on.
# Gating on the profile - not on the model name, and not on the policy alone -
# makes that combination inert.
current_display_profile()
{
    # Caller may name the model explicitly; the test harness does, because it
    # cannot reach the real getprop. Runtime callers omit it and get the device.
    case "${1:-$(current_model)}" in
        RMX5200) printf '%s\n' rmx5200 ;;
        PLK110|PLQ110|PJD110) printf '%s\n' vendor_ltpo ;;
        *) printf '%s\n' unsupported ;;
    esac
}

profile_uses_vote_filter()
{
    [ "$(current_display_profile "${1:-}")" = rmx5200 ]
}


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

# ColorOS 17 moved both companion sites, and the 152-byte block above only ever
# described the ColorOS 16 build.  This table carries the builds whose vote
# filter lives in the two surgical sites instead:
#
#   * the "<prefix>-animation" insert inside the vote-record writer.  The
#     "-animation" literal sits 0x88 bytes before it on ColorOS 17 and 0x90
#     bytes before the ColorOS 16 call this module already NOPs, so it is the
#     same site on both builds;
#   * the AP-scale table jump inside updateBestFrameRate, the one that resolves
#     a correct 144Hz request into 1080x2352@123 and drags the panel into the
#     FHD group.
#
# Each entry is <sha256>:<animation offset>:<animation original hex>:
# <ap-scale offset>:<ap-scale original hex>.  An unknown build keeps the legacy
# contract and therefore still fails closed on the context check.
# The AP-scale site is the one the ColorOS 16 patch has always used: the
# feature-flag branch that guards the whole "rewrite the selected modePtr from
# the stale pairing table" block.  Disassembly of both builds shows the same
# shape --
#
#   C16 0x4fcd20: ldr x8,[x19,#0x40]; ldr x8,[x8,#0x1e10]; ldrb w8,[x8,#0x15a]
#                 cmp w8,#1; b.ne 0x4fcd90        (orig 01030054 -> 18000014)
#   C17 0x37b8cc: ldr x8,[x19,#0x40]; ldr x8,[x8,#0x2da0]; ldrb w8,[x8,#0x162]
#                 cmp w8,#1; b.ne 0x37b924        (orig 41020054 -> 12000014)
#
# Forcing the branch keeps the requested mode and never consults the table.
# RMX5200 ColorOS 17 (Android 17, build 2026-10-05, sha256 c3b8273f...) carries
# the same two instructions at new offsets: the "-animation" insert is at 0x301da0 and
# the AP-scale guard at 0x37bc24.  Both were located from the signatures above and
# confirmed by disassembly -- 0x301da0 is the std::string::insert that turns the
# request name into "<prefix>-animation" (the literal is staged inline, 8 bytes at
# sp+9 plus "on" at sp+0x11), and 0x37bc24 is the "cmp w8, #1; b.ne" that guards
# the stale pairing-table rewrite.  Pinning the hash only shortens the lookup; the
# exact bytes are still verified before anything is written.
#
# The setIdleModeExternal type guard is deliberately not described for this OTA:
# the helper only needs it for the pure-custom-LTPO idle tier, and a site table
# without it rewrites just the two companion sites (the second entry works the
# same way).  Nothing regresses by leaving it out -- this build rejected the
# patch entirely before, so the idle tier had the guard in place anyway.
BUILD_SITE_TABLE="\
4b9a0ca743aabe6cada245f5e9b789cdd5a3d345c5bf37168b353d7f38b88e03:3152928:addbfb97:3651804:41020054:4388892:81020054\
 965929dcface4123f83cdabdffe4c161a3a6c2c3b9fa0cf756c7a6424e5d170b:3152940:53f00c94:3652276:41020054\
 c3b8273f211536783ba48229e4ea70314b0c979e3774ea3a2f5fc80b3836e2a9:3153312:06f00c94:3652644:41020054"

ANIMATION_PATCHED_HEX=1f2003d5
TABLE_AP_SCALE_PATCHED_HEX=12000014
# ColourOS 17's setIdleModeExternal refuses to apply the idle tier unless the
# current config type is 1, and every injected timing reports type 0, so the
# framework's own 1Hz idle request was silently dropped. Allow the type-0 config
# through by neutralising that guard.
TYPE_GUARD_OFFSET=4388892
TYPE_GUARD_ORIGINAL_HEX=81020054
TYPE_GUARD_PATCHED_HEX=1f2003d5
BUILD_CONTRACT=legacy

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

read_u32()
{
    od -An -tu4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d '[:space:]'
}

# Unknown builds keep the legacy contract, which then fails closed on the
# context check instead of patching an address nobody verified.
load_site_entry()
{
    entry_wanted=$1
    [ -n "$entry_wanted" ] || return 1
    for entry in $BUILD_SITE_TABLE; do
        entry_sha=${entry%%:*}
        [ "$entry_sha" = "$entry_wanted" ] || continue
        entry_rest=${entry#*:}
        SITE_ANIMATION_OFFSET=${entry_rest%%:*}
        entry_rest=${entry_rest#*:}
        SITE_ANIMATION_ORIGINAL_HEX=${entry_rest%%:*}
        entry_rest=${entry_rest#*:}
        SITE_AP_SCALE_OFFSET=${entry_rest%%:*}
        entry_rest=${entry_rest#*:}
        SITE_AP_SCALE_ORIGINAL_HEX=${entry_rest%%:*}
        entry_rest=${entry_rest#*:}
        SITE_AP_SCALE_PATCHED_HEX=$TABLE_AP_SCALE_PATCHED_HEX
        SITE_TYPE_GUARD_OFFSET=
        SITE_TYPE_GUARD_ORIGINAL_HEX=
        case "$entry_rest" in
            *:*)
                SITE_TYPE_GUARD_OFFSET=${entry_rest%%:*}
                entry_rest=${entry_rest#*:}
                SITE_TYPE_GUARD_ORIGINAL_HEX=${entry_rest%%:*}
                ;;
        esac
        return 0
    done
    return 1
}

load_dynamic_entry()
{
    entry_wanted=$1
    [ -n "$entry_wanted" ] || return 1
    [ -s "$DYNAMIC_SITE_FILE" ] || return 1
    entry=$(sed -n '1p' "$DYNAMIC_SITE_FILE" 2>/dev/null | tr -d '[:space:]')
    [ -n "$entry" ] || return 1
    entry_sha=${entry%%:*}
    [ "$entry_sha" = "$entry_wanted" ] || return 1
    entry_rest=${entry#*:}
    SITE_ANIMATION_OFFSET=${entry_rest%%:*}
    entry_rest=${entry_rest#*:}
    SITE_ANIMATION_ORIGINAL_HEX=${entry_rest%%:*}
    entry_rest=${entry_rest#*:}
    SITE_AP_SCALE_OFFSET=${entry_rest%%:*}
    entry_rest=${entry_rest#*:}
    SITE_AP_SCALE_ORIGINAL_HEX=${entry_rest%%:*}
    entry_rest=${entry_rest#*:}
    SITE_AP_SCALE_PATCHED_HEX=${entry_rest%%:*}
    SITE_TYPE_GUARD_OFFSET=
    SITE_TYPE_GUARD_ORIGINAL_HEX=
    [ -n "$SITE_ANIMATION_OFFSET" ] && [ -n "$SITE_ANIMATION_ORIGINAL_HEX" ] &&
        [ -n "$SITE_AP_SCALE_OFFSET" ] && [ -n "$SITE_AP_SCALE_ORIGINAL_HEX" ] &&
        [ -n "$SITE_AP_SCALE_PATCHED_HEX" ]
}

# Return file offsets whose compact hex form matches a fixed signature.
stream_matches()
{
    [ -s "$DYNAMIC_HEX_FILE" ] || return 1
    grep -abo -F "$1" "$DYNAMIC_HEX_FILE" 2>/dev/null |
        sed 's/:.*$//'
}

word_to_le_hex()
{
    word=$1
    printf '%02x%02x%02x%02x' \
        $((word & 0xff)) \
        $(((word >> 8) & 0xff)) \
        $(((word >> 16) & 0xff)) \
        $(((word >> 24) & 0xff))
}

save_dynamic_entry()
{
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    printf '%s:%s:%s:%s:%s:%s\n' \
        "$1" "$SITE_ANIMATION_OFFSET" "$SITE_ANIMATION_ORIGINAL_HEX" \
        "$SITE_AP_SCALE_OFFSET" "$SITE_AP_SCALE_ORIGINAL_HEX" \
        "$SITE_AP_SCALE_PATCHED_HEX" > "$DYNAMIC_SITE_FILE" || return 1
    chmod 0600 "$DYNAMIC_SITE_FILE" 2>/dev/null || true
}

# Locate the two C17 instructions by their surrounding code, not by a build
# hash.  The anchors are deliberately narrow and each located word is verified
# against the exact bytes before patch_site_table writes the output.
detect_dynamic_sites()
{
    file=$1
    [ -r "$file" ] || return 1

    DYNAMIC_HEX_FILE="$STATE_DIR/.surfaceflinger.hex.$$"
    rm -f "$DYNAMIC_HEX_FILE" 2>/dev/null || true
    if command -v xxd >/dev/null 2>&1; then
        xxd -p -c 0 "$file" 2>/dev/null | tr -d '\n' > "$DYNAMIC_HEX_FILE"
    else
        # xxd is not guaranteed: toybox only ships it on some ROMs, and a missing
        # xxd used to make detection fail closed for every unknown build.  od is
        # always there, and "-v" matters: without it od collapses runs of equal
        # bytes into "*" and the anchors below would not be found.
        od -An -v -tx1 "$file" 2>/dev/null | tr -d ' \n' > "$DYNAMIC_HEX_FILE"
    fi
    [ -s "$DYNAMIC_HEX_FILE" ] || {
        rm -f "$DYNAMIC_HEX_FILE" 2>/dev/null || true
        return 1
    }

    animation_anchor=d70e45f8080140f9e9cd8d52
    anchor_char=$(stream_matches "$animation_anchor" | head -n 1)
    [ -n "$anchor_char" ] || {
        rm -f "$DYNAMIC_HEX_FILE" 2>/dev/null || true
        return 1
    }
    anchor=$((anchor_char / 2))
    animation_site=
    bl_count=0
    i=0
    while [ "$i" -le 128 ]; do
        off=$((anchor + i))
        word_hex=$(hex_at "$file" "$off")
        case "$word_hex" in
            ??????94)
                bl_count=$((bl_count + 1))
                if [ "$bl_count" -eq 2 ]; then
                    animation_site=$off
                    break
                fi
                ;;
        esac
        i=$((i + 4))
    done
    [ -n "$animation_site" ] || {
        rm -f "$DYNAMIC_HEX_FILE" 2>/dev/null || true
        return 1
    }
    SITE_ANIMATION_OFFSET=$animation_site
    SITE_ANIMATION_ORIGINAL_HEX=$(hex_at "$file" "$animation_site")

    ap_prefix=682240f908d156f9088945391f050071
    ap_count=0
    for match in $(stream_matches "$ap_prefix"); do
        off=$((match / 2))
        branch_off=$((off + 16))
        branch_hex=$(hex_at "$file" "$branch_off")
        case "$branch_hex" in ????????) ;; *) continue ;; esac
        word=$(read_u32 "$file" "$branch_off")
        case "$word" in ''|*[!0-9]*) continue ;; esac
        [ $((word & 0xff000000)) -eq $((0x54000000)) ] || continue
        imm=$(((word >> 5) & 0x7ffff))
        [ "$imm" -ge 8 ] 2>/dev/null || continue
        [ "$imm" -le 64 ] 2>/dev/null || continue
        ap_count=$((ap_count + 1))
        SITE_AP_SCALE_OFFSET=$branch_off
        SITE_AP_SCALE_ORIGINAL_HEX=$branch_hex
        SITE_AP_SCALE_PATCHED_HEX=$(word_to_le_hex $((0x14000000 | imm)))
    done
    [ "$ap_count" -eq 1 ] || {
        rm -f "$DYNAMIC_HEX_FILE" 2>/dev/null || true
        return 1
    }

    SITE_TYPE_GUARD_OFFSET=
    SITE_TYPE_GUARD_ORIGINAL_HEX=
    rm -f "$DYNAMIC_HEX_FILE" 2>/dev/null || true
    return 0
}

# The build hash is only a cache key for known OTAs.  Unknown builds are
# located by instruction signatures in SurfaceFlinger itself, then the exact
# original bytes are verified before anything is written.  A failed dynamic
# lookup still falls back to the fail-closed legacy path.
select_build_sites()
{
    file=$1
    BUILD_CONTRACT=legacy
    build_sha=$(hash_file "$file")
    if [ -n "$build_sha" ] && load_site_entry "$build_sha"; then
        BUILD_CONTRACT=table
        record_contract "$build_sha"
        return 0
    fi
    if [ -n "$build_sha" ] && load_dynamic_entry "$build_sha"; then
        BUILD_CONTRACT=table
        return 0
    fi
    # A ColorOS 16 source still matches the legacy contract, so check that
    # before trusting the recorded contract: otherwise a different or
    # downgraded build would be mistaken for one of ours.
    if verify_original "$file" 2>/dev/null; then
        BUILD_CONTRACT=legacy
        return 0
    fi
    # The patched copy's own hash is not in the table, so verification of an
    # already generated patch has to fall back to the contract recorded when it
    # was built -- including the site offsets, which the record keeps alongside
    # the source hash it belongs to.  Key it on our own two paths so a
    # synthetic or foreign file never inherits it.
    case "$file" in
        "$SOURCE_FILE"|"$PATCHED_FILE") ;;
        *)
            if detect_dynamic_sites "$file"; then
                BUILD_CONTRACT=table
                record_contract "$build_sha"
                return 0
            fi
            BUILD_CONTRACT=legacy
            return 0
            ;;
    esac
    if [ -r "$STATE_DIR/contract" ] && [ -r "$STATE_DIR/contract-source" ]; then
        recorded=$(sed -n '1p' "$STATE_DIR/contract" 2>/dev/null | tr -d '[:space:]')
        recorded_sha=$(sed -n '1p' "$STATE_DIR/contract-source" 2>/dev/null | tr -d '[:space:]')
        case "$recorded" in
            table)
                if load_site_entry "$recorded_sha" || load_dynamic_entry "$recorded_sha"; then
                    BUILD_CONTRACT=table
                    return 0
                fi
                ;;
            legacy)
                # A recorded legacy verdict only describes the bytes that were
                # current when it was written, and record_contract() rewrites
                # contract-source on every attempt.  An OTA that replaces
                # SurfaceFlinger therefore leaves "legacy" bound to the NEW
                # hash: trusting it makes the 152-byte block check fail forever
                # and the filter never gets to relocate itself by signature.
                # Re-verify the block and fall through to the signature lookup
                # when it no longer describes this build.
                if verify_original "$file" 2>/dev/null; then
                    BUILD_CONTRACT=legacy
                    return 0
                fi
                ;;
        esac
    fi
    if detect_dynamic_sites "$file"; then
        save_dynamic_entry "$build_sha"
        BUILD_CONTRACT=table
        record_contract "$build_sha"
        return 0
    fi
    BUILD_CONTRACT=legacy
    return 0
}

record_contract()
{
    record_sha=$1
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\n' "$BUILD_CONTRACT" > "$STATE_DIR/contract" 2>/dev/null
    [ -n "$record_sha" ] &&
        printf '%s\n' "$record_sha" > "$STATE_DIR/contract-source" 2>/dev/null
    return 0
}

# Contract words arrive as little-endian hex, so this writer stays data driven.
write_patch_word()
{
    file=$1
    offset=$2
    hex=$3
    case "$hex" in
        ''|*[!0-9a-fA-F]*) return 1 ;;
    esac
    [ $(( ${#hex} % 2 )) -eq 0 ] || return 1
    escapes=''
    rest=$hex
    while [ -n "$rest" ]; do
        pair=${rest%"${rest#??}"}
        rest=${rest#??}
        escapes=$escapes$(printf '\\%03o' "$(( 0x$pair ))")
    done
    printf '%b' "$escapes" |
        dd of="$file" bs=1 seek="$offset" conv=notrunc >/dev/null 2>&1
}

# The ColorOS 17 site table optionally carries a third patch site: the
# setIdleModeExternal type guard.  A site table that does not describe it (and
# the synthetic table the tests build) leaves SITE_TYPE_GUARD_OFFSET empty, and
# then only the two companion sites are rewritten.  Real RMX5200 site tables do
# describe it, so the guard is still neutralised there.
type_guard_described()
{
    [ -n "${SITE_TYPE_GUARD_OFFSET:-}" ]
}

verify_table_original()
{
    file=$1
    [ -r "$file" ] || return 1
    [ "$(hex_at "$file" "$SITE_ANIMATION_OFFSET")" = "$SITE_ANIMATION_ORIGINAL_HEX" ] || return 1
    [ "$(hex_at "$file" "$SITE_AP_SCALE_OFFSET")" = "$SITE_AP_SCALE_ORIGINAL_HEX" ] || return 1
    if type_guard_described; then
        [ "$(hex_at "$file" "$SITE_TYPE_GUARD_OFFSET")" = "$SITE_TYPE_GUARD_ORIGINAL_HEX" ] || return 1
    fi
    return 0
}

verify_table_patched()
{
    file=$1
    [ -r "$file" ] || return 1
    [ "$(hex_at "$file" "$SITE_ANIMATION_OFFSET")" = "$ANIMATION_PATCHED_HEX" ] || return 1
    [ "$(hex_at "$file" "$SITE_AP_SCALE_OFFSET")" = "$SITE_AP_SCALE_PATCHED_HEX" ] || return 1
    if type_guard_described; then
        [ "$(hex_at "$file" "$SITE_TYPE_GUARD_OFFSET")" = "$TYPE_GUARD_PATCHED_HEX" ] || return 1
    fi
    return 0
}

# Every verification has to ask which contract applies: the legacy 152-byte
# block and the ColorOS 17 site table describe completely different bytes, so a
# caller that hard-codes verify_patched rejects a correct newer patch -- which is
# exactly how the ColorOS 17 vote filter first failed validation.
verify_source_contract()
{
    file=$1
    shift
    select_build_sites "$file"
    if [ "$BUILD_CONTRACT" = table ]; then
        verify_table_original "$file"
    else
        verify_original "$file" "$@"
    fi
}

verify_patched_contract()
{
    file=$1
    shift
    select_build_sites "$file"
    if [ "$BUILD_CONTRACT" = table ]; then
        verify_table_patched "$file"
    else
        verify_patched "$file" "$@"
    fi
}

patch_site_table()
{
    source=$1
    output=$2
    verify_table_original "$source" || return 12
    output_dir=${output%/*}
    [ "$output_dir" != "$output" ] || output_dir=.
    mkdir -p "$output_dir" || return 13
    temp_file="$output.tmp.$$"
    rm -f "$temp_file" 2>/dev/null || true
    cp -f "$source" "$temp_file" || return 13
    if ! write_patch_word "$temp_file" "$SITE_ANIMATION_OFFSET" "$ANIMATION_PATCHED_HEX" ||
            ! write_patch_word "$temp_file" "$SITE_AP_SCALE_OFFSET" "$SITE_AP_SCALE_PATCHED_HEX" ||
            { type_guard_described &&
                ! write_patch_word "$temp_file" "$SITE_TYPE_GUARD_OFFSET" "$TYPE_GUARD_PATCHED_HEX"; } ||
            ! verify_table_patched "$temp_file" ||
            [ "$(file_size "$temp_file")" != "$(file_size "$source")" ]; then
        rm -f "$temp_file" 2>/dev/null || true
        return 14
    fi
    mv -f "$temp_file" "$output" || {
        rm -f "$temp_file" 2>/dev/null || true
        return 15
    }
    return 0
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

# ColorOS 17 起纯自制 LTPO 改走"框架 hook 路由"：守护进程不再设置 SurfaceFlinger
# 模式，静止时由框架 hook 把原厂 60Hz 静止投票定向到注入的最低档（1Hz）。这条
# 路径仍然需要本补丁先把厂商 AP-scale 顶档（165/170）挡住，否则 hook 选中的节点
# 会被同一层改写掉。ColorOS 16 仍是守护进程直接设模式的阶梯方案，行为不变。
# 测试可以用 ANDROID_RELEASE_MAJOR_OVERRIDE 指定平台版本。
android_release_major()
{
    if [ -n "$ANDROID_RELEASE_MAJOR_OVERRIDE" ]; then
        printf '%s\n' "$ANDROID_RELEASE_MAJOR_OVERRIDE"
        return 0
    fi
    getprop ro.build.version.release 2>/dev/null |
        sed -n 's/^\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# 原厂 LTPS 子方案（"禁用日常 LTPO"开启，策略保留 custom_ltpo）同样依赖
# 本补丁放行 60Hz 投票；纯自制 LTPO（标志关闭）仍不应用，OTI 由控制器暂停。
DAILY_IDLE_FILE="$MODDIR/config/rmx5200_ltpo_daily_idle.txt"

ltps_vote_wanted()
{
    # 可选参数供 test-patch 显式指定策略；运行时无参数则读策略文件。
    if [ "$#" -ge 1 ]; then
        policy=$1
    else
        policy=$(read_policy)
    fi
    [ "$policy" = "$EXPECTED_POLICY" ] && return 0
    # 完美禁用 ADFR 同样需要这层过滤：关闭"超级帧率"（插帧）后，厂商的
    # AP-scale / scale_up 映射表会残留在插帧时的 123Hz 档，SurfaceFlinger 会把
    # 144fps 的解析（连 default 投票也是）指向 mode 11（1080x2352@123），面板被
    # 拖到 FHD 组、模块再把 1440p144 拉回来，来回翻转就是黑闪。补丁自带源码契约
    # 校验，机型或系统版本不匹配时会落到 skipped/rejected，不会挂上错误二进制。
    [ "$policy" = adfr_off ] && return 0
    if [ "$policy" = custom_ltpo ]; then
        daily_idle=$(sed -n '1{s/\r$//;p;q;}' "$DAILY_IDLE_FILE" 2>/dev/null |
            tr -d '[:space:]')
        [ "$daily_idle" = on ] && return 0
        # 纯自制 LTPO：ColorOS 17 起同样依赖本补丁放行/定向静止投票。
        release_major=$(android_release_major)
        [ -n "$release_major" ] && [ "$release_major" -ge 17 ] 2>/dev/null &&
            return 0
    fi
    return 1
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

    profile_uses_vote_filter "$model" || return 10
    ltps_vote_wanted "$policy" || return 11
    select_build_sites "$source"
    record_contract "$(hash_file "$source")"
    if [ "$BUILD_CONTRACT" = table ]; then
        patch_site_table "$source" "$output"
        return $?
    fi
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
    getprop ro.product.vendor.model 2>/dev/null| sed 's/^CPH2747$/PLK110/'
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
    if ! profile_uses_vote_filter "$model"; then
        write_state "skipped:profile_$(current_display_profile "$model")"
        return 0
    fi
    if ! ltps_vote_wanted; then
        write_state "skipped:policy_${policy:-unknown}"
        return 0
    fi

    if verify_patched_contract "$SOURCE_FILE"; then
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
    verify_patched_contract "$PATCHED_FILE" || {
        write_state error:prepared_validation
        return 1
    }
    write_state prepared
}

apply_runtime_patch()
{
    model=$(current_model)
    policy=$(read_policy)
    if ! profile_uses_vote_filter "$model"; then
        write_state "skipped:profile_$(current_display_profile "$model")"
        return 0
    fi
    if ! ltps_vote_wanted; then
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

    if verify_patched_contract "$SOURCE_FILE"; then
        if remount_for_domain_transition; then
            write_state active:already_mounted
            return 0
        fi
        write_state error:existing_mount_nosuid
        return 1
    fi

    prepare_runtime_patch || return 1
    verify_source_contract "$SOURCE_FILE" || {
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
    if ! verify_patched_contract "$SOURCE_FILE"; then
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
    # This marker is the boot-loop guard: it asks whether the boot completed,
    # not whether the patch is live.  Gating it on the patch left the marker set
    # whenever a boot failed to mount, and the next boot then refused to try --
    # one failure disabled the filter permanently.  Record the patch outcome
    # separately instead.
    if verify_patched_contract "$SOURCE_FILE"; then
        write_state active:boot_verified
    else
        write_state active:boot_unverified
    fi
    rm -f "$BOOT_PENDING_FILE" 2>/dev/null || return 1
    return 0
}

clear_boot_guard()
{
    rm -f "$BOOT_PENDING_FILE" "$BOOT_BLOCK_FILE" 2>/dev/null || return 1
    write_state ready:guard_cleared
}

restore_runtime_patch()
{
    rm -f "$BOOT_PENDING_FILE" "$BOOT_BLOCK_FILE" 2>/dev/null || true
    if ! verify_patched_contract "$SOURCE_FILE" &&
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
    verify_source_contract "$SOURCE_FILE" || {
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
    test-sites)
        [ "$#" -eq 9 ] || exit 2
        SITE_ANIMATION_OFFSET=$2
        SITE_ANIMATION_ORIGINAL_HEX=$3
        ANIMATION_PATCHED_HEX=$4
        SITE_AP_SCALE_OFFSET=$5
        SITE_AP_SCALE_ORIGINAL_HEX=$6
        TABLE_AP_SCALE_PATCHED_HEX=$7
        SITE_AP_SCALE_PATCHED_HEX=$7
        patch_site_table "$8" "$9"
        ;;
    *)
        printf 'usage: %s prepare|apply|mark-boot-success|clear-boot-guard|restore|status\n' "$0" >&2
        exit 2
        ;;
esac
