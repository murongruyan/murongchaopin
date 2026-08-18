#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

SCRIPT=scripts/libpwiris_memc_gate_patch.sh
SOURCE=work/libpwirisservicei7p.device.so
OUTPUT=work/libpwirisservicei7p.rmx5200.memc-gate.test.so
PATCHED=$(realpath bin/libpwirisservicei7p.rmx5200.memc-gate.so)
PRE_VIDEO=$(realpath work/libpwirisservicei7p.rmx5200.pre-video-gate.test.so)
PRE_GPU_FPS=$(realpath work/libpwirisservicei7p.rmx5200.pre-gpu-fps.test.so)
EXPECTED_FINGERPRINT='realme/RMX5200/RE6030L1:16/BP2A.250605.015/B.5db4d73-38e165c-395c506:user/release-keys'

grep -q 'EXPECTED_MODEL=RMX5200' "$SCRIPT"
grep -Fq "EXPECTED_FINGERPRINT=$EXPECTED_FINGERPRINT" "$SCRIPT"
grep -q 'umount -l "$SOURCE_FILE"' "$SCRIPT"
grep -q 'EXPECTED_SOURCE_SHA=e18ec5bf60ac512bd66b99df032050dfb71b53bf39eaf3b2125ab2e6a09387b1' "$SCRIPT"
grep -q 'EXPECTED_LEGACY_SHA=8f36b1d1ded5ec78933dd6cee384c31877b61f545c5ad6e7be80ed3f04104406' "$SCRIPT"
grep -q 'EXPECTED_QHD144_MINUS_ONE_SHA=fb49c78b4d24c91fa9456c9824303a60892bfcedb209cf84ee1055749d13483c' "$SCRIPT"
grep -q 'EXPECTED_QHD144_LEGACY_GATE_SHA=6354ccfb836248b144ce474a390c88405a62987bfb0ed8a1eba44651cdf1bf67' "$SCRIPT"
grep -q 'EXPECTED_ONE_GATE_SHA=5a9b567f3a3e5bf8b3d53d767b96a9aaa94b374095da394ba6aeec3952f4d1fd' "$SCRIPT"
grep -q 'EXPECTED_TWO_GATE_SHA=446c7719de5914c9ccf1520bc230b80ee5d1b1d979186adba4bf2049d2f86ed9' "$SCRIPT"
grep -q 'EXPECTED_PRE_ALLOW_GATE_SHA=444003f5f89c6c1f1c457cb03beb0ad57be91a9cb8206962407acdb77b279d68' "$SCRIPT"
grep -q 'EXPECTED_PRE_HW_GATE_SHA=ed0bf523023e98a527a3c8f13eecf9d7a037e2fadecc1d8b68cbea9c1a4d5bbc' "$SCRIPT"
grep -q 'EXPECTED_PRE_SWITCH_GATE_SHA=730684220fdf74a4be2b01c8cedfce59fefd04aa55b9413b1a46de6fef214180' "$SCRIPT"
grep -q 'EXPECTED_PRE_VIDEO_GATE_SHA=50251972d6488935cefd36740cfc0071f5b675ce00f088cc625352b88e14fd82' "$SCRIPT"
grep -q 'EXPECTED_PRE_GPU_FPS_SHA=582ba8f46cfe3eb4e2e3665bd9a80907ef8e39b39fd0f86b94fea43dba678891' "$SCRIPT"
grep -q 'EXPECTED_PATCHED_SHA=8b0c6c0361af470978cbfa93f65ed7d58d215fbc2a0c174acbcc3597fdc1fe00' "$SCRIPT"
grep -q 'GPU_MASK_OFFSET=\$((0xae7b8))' "$SCRIPT"
grep -q 'GPU_MASK_ORIGINAL_HEX=6a010032' "$SCRIPT"
grep -q 'GPU_MASK_PATCHED_HEX=6a050032' "$SCRIPT"
grep -q 'VIDEO_GATE_OFFSET=\$((0xae7c4))' "$SCRIPT"
grep -q 'VIDEO_GATE_ORIGINAL_HEX=6c000034' "$SCRIPT"
grep -q 'VIDEO_GATE_PRE_GPU_FPS_HEX=1f2003d5' "$SCRIPT"
grep -q 'VIDEO_GATE_PATCHED_HEX=6c000035' "$SCRIPT"
grep -q 'GPU_FPS_MOV_OFFSET=\$((0xae7c8))' "$SCRIPT"
grep -q 'GPU_FPS_MOV_PATCHED_HEX=0ca68e52' "$SCRIPT"
grep -q 'GPU_FPS_STORE_OFFSET=\$((0xae7cc))' "$SCRIPT"
grep -q 'GPU_FPS_STORE_PATCHED_HEX=0c7100b9' "$SCRIPT"
grep -q 'GATE_OFFSET=\$((0xae7e4))' "$SCRIPT"
grep -q 'GATE_ORIGINAL_HEX=6b000035' "$SCRIPT"
grep -q 'GATE_PATCHED_HEX=1f2003d5' "$SCRIPT"
grep -q 'FALLTHROUGH_GATE_OFFSET=\$((0xae868))' "$SCRIPT"
grep -q 'FALLTHROUGH_GATE_ORIGINAL_HEX=4bfcff35' "$SCRIPT"
grep -q 'FALLTHROUGH_GATE_PATCHED_HEX=1f2003d5' "$SCRIPT"
grep -q 'LEGACY_GATE_OFFSET=\$((0xae820))' "$SCRIPT"
grep -q 'LEGACY_GATE_ORIGINAL_HEX=69000036' "$SCRIPT"
grep -q 'ALLOW_LIMIT_MOV_W8_OFFSET=\$((0xc7130))' "$SCRIPT"
grep -q 'ALLOW_LIMIT_MOVK_W8_OFFSET=\$((0xc7134))' "$SCRIPT"
grep -q 'HW_LIMIT_MOV_W9_OFFSET=\$((0xc81e4))' "$SCRIPT"
grep -q 'HW_LIMIT_MOVK_W9_OFFSET=\$((0xc81ec))' "$SCRIPT"
grep -q 'SWITCH_LIMIT_MOV_W26_OFFSET=\$((0xc7f68))' "$SCRIPT"
grep -q 'SWITCH_LIMIT_MOVK_W26_OFFSET=\$((0xc7f70))' "$SCRIPT"
grep -q 'TIMING_MOV_W10_OFFSET=\$((0xc737c))' "$SCRIPT"
grep -q 'TIMING_MOVK_W10_OFFSET=\$((0xc7380))' "$SCRIPT"
grep -q 'TIMING_MOV_W8_OFFSET=\$((0xc74f8))' "$SCRIPT"
grep -q 'TIMING_MOVK_W8_OFFSET=\$((0xc7504))' "$SCRIPT"
grep -q 'runtime_timing_limit_valid' "$SCRIPT"
grep -q 'runtime_allow_limit_valid' "$SCRIPT"
grep -q 'runtime_hw_limit_valid' "$SCRIPT"
grep -q 'runtime_switch_limit_valid' "$SCRIPT"
grep -q 'runtime_legacy_gate_hex' "$SCRIPT"
grep -Fq 'stock|legacy|qhd144-minus-one|qhd144-legacy-gate|qhd144-one-overlay-gate|qhd144-two-overlay-gates|qhd144-pre-allow-gate|qhd144-pre-hw-gate|qhd144-pre-switch-gate)' "$SCRIPT"
grep -q 'PREMIUM_POST_FS' post-fs-data.sh
grep -q 'PREMIUM_POST_MOUNT' post-mount.sh
grep -q 'PREMIUM_POST_FS' late-load.sh
grep -q 'watch-final-view' packaging/paid-payload/scripts/premium_post_fs_data.sh
grep -q 'apply-stable' packaging/paid-payload/scripts/premium_post_mount.sh
grep -q 'mark-boot-success' packaging/paid-payload/scripts/premium_service.sh
grep -q 'error:boot_runtime_contract' "$SCRIPT"
grep -q 'fallback:previous_boot_incomplete' "$SCRIPT"
grep -q 'build_stock_fallback' "$SCRIPT"
grep -q 'metamodule_descriptor' "$SCRIPT"
grep -q 'topology_signature' "$SCRIPT"
grep -Fq 'base_decimal=$(printf '\''%d'\'' "0x$base"' "$SCRIPT"
grep -Fq 'printf "%.0f", base + offset' "$SCRIPT"

rm -f "$OUTPUT"
bash "$SCRIPT" test-patch "$SOURCE" "$OUTPUT"
[ "$(wc -c < "$OUTPUT" | tr -d '[:space:]')" = 1011592 ]
[ "$(sha256sum "$OUTPUT" | awk '{ print $1 }')" = 8b0c6c0361af470978cbfa93f65ed7d58d215fbc2a0c174acbcc3597fdc1fe00 ]
[ "$(sha256sum "$PATCHED" | awk '{ print $1 }')" = 8b0c6c0361af470978cbfa93f65ed7d58d215fbc2a0c174acbcc3597fdc1fe00 ]
[ "$(sha256sum "$PRE_VIDEO" | awk '{ print $1 }')" = 50251972d6488935cefd36740cfc0071f5b675ce00f088cc625352b88e14fd82 ]
[ "$(sha256sum "$PRE_GPU_FPS" | awk '{ print $1 }')" = 582ba8f46cfe3eb4e2e3665bd9a80907ef8e39b39fd0f86b94fea43dba678891 ]
[ "$(od -An -v -tx1 -j $((0xae7b8)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 6a050032 ]
[ "$(od -An -v -tx1 -j $((0xae7c4)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 6c000035 ]
[ "$(od -An -v -tx1 -j $((0xae7c8)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 0ca68e52 ]
[ "$(od -An -v -tx1 -j $((0xae7cc)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 0c7100b9 ]
[ "$(od -An -v -tx1 -j $((0xae7e4)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 1f2003d5 ]
[ "$(od -An -v -tx1 -j $((0xae868)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 1f2003d5 ]
[ "$(od -An -v -tx1 -j $((0xae820)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 1f2003d5 ]
[ "$(od -An -v -tx1 -j $((0xc7130)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 08009052 ]
[ "$(od -An -v -tx1 -j $((0xc7134)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 48d8a472 ]
[ "$(od -An -v -tx1 -j $((0xc81e4)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 29009052 ]
[ "$(od -An -v -tx1 -j $((0xc81ec)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 49d8a472 ]
[ "$(od -An -v -tx1 -j $((0xc7f68)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 3a009052 ]
[ "$(od -An -v -tx1 -j $((0xc7f70)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 5ad8a472 ]
[ "$(od -An -v -tx1 -j $((0xc737c)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 0a009052 ]
[ "$(od -An -v -tx1 -j $((0xc7380)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 4ad8a472 ]
[ "$(od -An -v -tx1 -j $((0xc74f8)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 08009052 ]
[ "$(od -An -v -tx1 -j $((0xc7504)) -N 4 "$OUTPUT" | tr -d '[:space:]')" = 48d8a472 ]

STOCK_ROUNDTRIP=work/libpwirisservicei7p.rmx5200.stock-roundtrip.test.so
rm -f "$STOCK_ROUNDTRIP"
# Exercise the exact inverse instruction and prove the full original hash.
cp "$PATCHED" "$STOCK_ROUNDTRIP"
printf '\152\001\000\062' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xae7b8)) \
    conv=notrunc >/dev/null 2>&1
printf '\154\000\000\064' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xae7c4)) \
    conv=notrunc >/dev/null 2>&1
printf '\152\005\000\062' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xae7c8)) \
    conv=notrunc >/dev/null 2>&1
printf '\012\000\000\271' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xae7cc)) \
    conv=notrunc >/dev/null 2>&1
printf '\153\000\000\065' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xae7e4)) \
    conv=notrunc >/dev/null 2>&1
printf '\113\374\377\065' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xae868)) \
    conv=notrunc >/dev/null 2>&1
printf '\151\000\000\066' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xae820)) \
    conv=notrunc >/dev/null 2>&1
printf '\350\377\227\122' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc7130)) \
    conv=notrunc >/dev/null 2>&1
printf '\210\011\244\162' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc7134)) \
    conv=notrunc >/dev/null 2>&1
printf '\011\000\230\122' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc81e4)) \
    conv=notrunc >/dev/null 2>&1
printf '\211\011\244\162' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc81ec)) \
    conv=notrunc >/dev/null 2>&1
printf '\032\000\230\122' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc7f68)) \
    conv=notrunc >/dev/null 2>&1
printf '\232\011\244\162' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc7f70)) \
    conv=notrunc >/dev/null 2>&1
printf '\352\377\227\122' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc737c)) \
    conv=notrunc >/dev/null 2>&1
printf '\212\011\244\162' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc7380)) \
    conv=notrunc >/dev/null 2>&1
printf '\350\377\227\122' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc74f8)) \
    conv=notrunc >/dev/null 2>&1
printf '\210\011\244\162' | dd of="$STOCK_ROUNDTRIP" bs=1 seek=$((0xc7504)) \
    conv=notrunc >/dev/null 2>&1
[ "$(sha256sum "$STOCK_ROUNDTRIP" | awk '{ print $1 }')" = e18ec5bf60ac512bd66b99df032050dfb71b53bf39eaf3b2125ab2e6a09387b1 ]
rm -f "$STOCK_ROUNDTRIP"

# IrisService uses unsigned `pixel_product > limit`. Prove the exact boundary
# rather than only checking encoded instruction bytes.
QHD144_LIMIT=$((1440 * 3136 * 144))
QHD144_STRICT_LIMIT=$((QHD144_LIMIT + 1))
[ "$QHD144_LIMIT" -eq $((0x26c28000)) ]
[ "$QHD144_STRICT_LIMIT" -eq $((0x26c28001)) ]
[ $((1440 * 3136 * 144)) -le "$QHD144_LIMIT" ]
[ $((1440 * 3136 * 144)) -lt "$QHD144_STRICT_LIMIT" ]
[ $((1440 * 3136 * 150)) -gt "$QHD144_LIMIT" ]
[ $((1440 * 3136 * 150)) -ge "$QHD144_STRICT_LIMIT" ]

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TARGET="$TMP/libpwirisservicei7p.so"
STATE="$TMP/state"
ENABLE="$TMP/enabled"
PROC="$TMP/proc"
META="$TMP/metamodule"
MOUNTINFO="$TMP/mountinfo"
SYSTEM_PAYLOAD="$TMP/system/odm/lib64/libpwirisservicei7p.so"
cp "$PATCHED" "$TARGET"
touch "$ENABLE"
mkdir -p "$PROC/321" "$META"
ln -s "$PATCHED" "$PROC/321/mem"
INODE=$(stat -c '%i' "$TARGET")
printf '0000000000000000-0000000000100000 r--p 00000000 00:00 %s %s\n' \
    "$INODE" "$TARGET" > "$PROC/321/maps"

run_helper() {
    MEMC_STATE_DIR="$STATE" \
    MEMC_ENABLE_FILE="$ENABLE" \
    MEMC_SYSTEM_PAYLOAD_FILE="$SYSTEM_PAYLOAD" \
    MEMC_TARGET_FILE="$TARGET" \
    MEMC_PATCHED_FILE="$PATCHED" \
    MEMC_MOUNTINFO_FILE="$MOUNTINFO" \
    MEMC_PROC_ROOT="$PROC" \
    MEMC_METAMODULE_LINK="$META" \
    MEMC_TEST_MODEL=RMX5200 \
    MEMC_TEST_FINGERPRINT="$EXPECTED_FINGERPRINT" \
    MEMC_TEST_BOOT_ID=fixture-boot \
    MEMC_STABLE_SAMPLES=2 \
    MEMC_WATCH_ATTEMPTS=5 \
    MEMC_WATCH_INTERVAL=0.01 \
        bash "$SCRIPT" "$@"
}

write_mountinfo() {
    kind=$1
    {
        printf '1 0 0:1 / / rw - rootfs rootfs rw\n'
        case "$kind" in
        meta_magic)
            printf '101 1 0:40 / /odm ro - erofs odm ro\n102 101 0:41 /work/odm/lib64 /odm/lib64 ro - tmpfs KSU ro\n'
            ;;
        meta_hybrid)
            printf '111 1 0:40 / /odm ro - erofs odm ro\n112 111 0:42 / /odm/lib64 rw - hymofs hybrid rw\n'
            ;;
        magic_mount_rs)
            printf '121 1 0:40 / /odm ro - erofs odm ro\n122 121 254:77 /module/system/odm/lib64/libpwirisservicei7p.so %s rw - f2fs userdata rw\n' "$TARGET"
            ;;
        mountify)
            printf '131 1 0:40 / /odm ro - erofs odm ro\n132 131 0:43 / /odm/lib64 rw - overlay anyfs rw,lowerdir=/module:/odm/lib64\n'
            ;;
        hymo)
            # HymoFS may hide its own mountinfo records. The visible inode and
            # exact payload contract still prove the resulting file view.
            printf '141 1 0:40 / /odm ro - erofs odm ro\n'
            ;;
        meta_overlayfs)
            printf '151 1 0:40 / /odm rw - overlay KSU rw,lowerdir=/module:/odm\n'
            ;;
            *) return 1 ;;
        esac
    } > "$MOUNTINFO"
}

make_meta() {
    rm -rf "$META"
    mkdir -p "$META"
    id=$1
    signature=$2
    printf 'id=%s\nmetamodule=true\n' "$id" > "$META/module.prop"
    case "$signature" in
        mmd|meta-mm|hybrid-mount|hymod|meta-overlayfs) touch "$META/$signature"; chmod +x "$META/$signature" ;;
        overlay-script) printf '#!/system/bin/sh\nmount -t overlay overlay /system\n' > "$META/metamount.sh" ;;
    esac
}

for fixture in meta_magic meta_hybrid magic_mount_rs mountify hymo meta_overlayfs; do
    write_mountinfo "$fixture"
    case "$fixture" in
        meta_magic) make_meta renamed_magic mmd; expected='magic:renamed_magic' ;;
        meta_hybrid) make_meta renamed_hybrid hybrid-mount; expected='hybrid:renamed_hybrid' ;;
        magic_mount_rs) make_meta renamed_magic_rs meta-mm; expected='magic:renamed_magic_rs' ;;
        mountify) make_meta renamed_mountify overlay-script; expected='overlay:renamed_mountify' ;;
        hymo) make_meta renamed_hymo hymod; expected='hybrid:renamed_hymo' ;;
        meta_overlayfs) make_meta renamed_meta_overlay meta-overlayfs; expected='overlay:renamed_meta_overlay' ;;
    esac
    status=$(run_helper status)
    grep -Fq "metamodule=$expected" <<< "$status"
    grep -Fq 'source_gpu_mask_bytes=6a050032' <<< "$status"
    grep -Fq 'source_video_gate_bytes=6c000035' <<< "$status"
    grep -Fq 'source_gpu_fps_bytes=0ca68e52,0c7100b9' <<< "$status"
    grep -Fq 'source_gate_bytes=1f2003d5' <<< "$status"
    grep -Fq 'source_fallthrough_gate_bytes=1f2003d5' <<< "$status"
    grep -Fq 'source_legacy_gate_bytes=1f2003d5' <<< "$status"
    grep -Fq 'source_allow_limit=08009052,48d8a472' <<< "$status"
    grep -Fq 'source_hw_limit=29009052,49d8a472' <<< "$status"
    grep -Fq 'source_switch_limit=3a009052,5ad8a472' <<< "$status"
    grep -Fq 'source_timing_limit=0a009052,4ad8a472,08009052,48d8a472' <<< "$status"
    grep -Eq 'composer=321:[0-9]+' <<< "$status"
    run_helper apply-stable
    grep -Fq "active:metamodule:$expected" "$STATE/state.txt"
done

# The fifth payload admitted GPU video but still sent VideoFPS=0. It is an
# exact upgrade source; the replacement must add only the conditional 30fps
# fallback sequence while preserving all established QHD144 gates.
cp "$PRE_GPU_FPS" "$TARGET"
status=$(run_helper status)
grep -Fq 'visible_contract=qhd144-pre-gpu-fps' <<< "$status"
grep -Fq 'source_gpu_mask_bytes=6a010032' <<< "$status"
grep -Fq 'source_video_gate_bytes=1f2003d5' <<< "$status"
grep -Fq 'source_gpu_fps_bytes=6a050032,0a0000b9' <<< "$status"
grep -Fq 'patched_sha256=8b0c6c0361af470978cbfa93f65ed7d58d215fbc2a0c174acbcc3597fdc1fe00' <<< "$status"
cp "$PATCHED" "$TARGET"

# The deployed pre-video payload must be recognized as an upgrade source and
# must retain the original GPU-video branch until the replacement is mounted.
cp "$PRE_VIDEO" "$TARGET"
status=$(run_helper status)
grep -Fq 'visible_contract=qhd144-pre-video-gate' <<< "$status"
grep -Fq 'source_video_gate_bytes=6c000034' <<< "$status"
grep -Fq 'patched_video_gate_bytes=6c000035' <<< "$status"
cp "$PATCHED" "$TARGET"

# The immediately preceding build patched both HighFpsOverLay branches but
# left the native portrait-orientation gate intact. Prove that this exact
# payload is recognized and can be upgraded at the next boot.
TWO_GATE="$TMP/libpwirisservicei7p.two-overlay-gates.so"
cp "$PRE_VIDEO" "$TWO_GATE"
printf '\151\000\000\066' | dd of="$TWO_GATE" bs=1 seek=$((0xae820)) \
    conv=notrunc >/dev/null 2>&1
printf '\350\377\227\122' | dd of="$TWO_GATE" bs=1 seek=$((0xc7130)) \
    conv=notrunc >/dev/null 2>&1
printf '\210\011\244\162' | dd of="$TWO_GATE" bs=1 seek=$((0xc7134)) \
    conv=notrunc >/dev/null 2>&1
printf '\011\000\230\122' | dd of="$TWO_GATE" bs=1 seek=$((0xc81e4)) \
    conv=notrunc >/dev/null 2>&1
printf '\211\011\244\162' | dd of="$TWO_GATE" bs=1 seek=$((0xc81ec)) \
    conv=notrunc >/dev/null 2>&1
printf '\032\000\230\122' | dd of="$TWO_GATE" bs=1 seek=$((0xc7f68)) \
    conv=notrunc >/dev/null 2>&1
printf '\232\011\244\162' | dd of="$TWO_GATE" bs=1 seek=$((0xc7f70)) \
    conv=notrunc >/dev/null 2>&1
[ "$(sha256sum "$TWO_GATE" | awk '{ print $1 }')" = 446c7719de5914c9ccf1520bc230b80ee5d1b1d979186adba4bf2049d2f86ed9 ]
cp "$TWO_GATE" "$TARGET"
status=$(run_helper status)
grep -Fq 'visible_contract=qhd144-two-overlay-gates' <<< "$status"
cp "$PATCHED" "$TARGET"

# The immediately preceding production payload raised setActiveConfig's two
# limits but not allowBypssToPt's independent copy. It must be recognized as
# an upgrade source and must not satisfy the final runtime contract.
PRE_ALLOW_GATE="$TMP/libpwirisservicei7p.pre-allow-gate.so"
cp "$PRE_VIDEO" "$PRE_ALLOW_GATE"
printf '\350\377\227\122' | dd of="$PRE_ALLOW_GATE" bs=1 seek=$((0xc7130)) \
    conv=notrunc >/dev/null 2>&1
printf '\210\011\244\162' | dd of="$PRE_ALLOW_GATE" bs=1 seek=$((0xc7134)) \
    conv=notrunc >/dev/null 2>&1
printf '\011\000\230\122' | dd of="$PRE_ALLOW_GATE" bs=1 seek=$((0xc81e4)) \
    conv=notrunc >/dev/null 2>&1
printf '\211\011\244\162' | dd of="$PRE_ALLOW_GATE" bs=1 seek=$((0xc81ec)) \
    conv=notrunc >/dev/null 2>&1
printf '\032\000\230\122' | dd of="$PRE_ALLOW_GATE" bs=1 seek=$((0xc7f68)) \
    conv=notrunc >/dev/null 2>&1
printf '\232\011\244\162' | dd of="$PRE_ALLOW_GATE" bs=1 seek=$((0xc7f70)) \
    conv=notrunc >/dev/null 2>&1
[ "$(sha256sum "$PRE_ALLOW_GATE" | awk '{ print $1 }')" = 444003f5f89c6c1f1c457cb03beb0ad57be91a9cb8206962407acdb77b279d68 ]
cp "$PRE_ALLOW_GATE" "$TARGET"
status=$(run_helper status)
grep -Fq 'visible_contract=qhd144-pre-allow-gate' <<< "$status"
grep -Fq 'source_allow_limit=e8ff9752,8809a472' <<< "$status"
cp "$PATCHED" "$TARGET"

# The allowBypssToPt payload exposed allowHwOperating's strict QHD120 gate.
# Preserve it as an independently recognized upgrade source.
PRE_HW_GATE="$TMP/libpwirisservicei7p.pre-hw-gate.so"
cp "$PRE_VIDEO" "$PRE_HW_GATE"
printf '\011\000\230\122' | dd of="$PRE_HW_GATE" bs=1 seek=$((0xc81e4)) \
    conv=notrunc >/dev/null 2>&1
printf '\211\011\244\162' | dd of="$PRE_HW_GATE" bs=1 seek=$((0xc81ec)) \
    conv=notrunc >/dev/null 2>&1
printf '\032\000\230\122' | dd of="$PRE_HW_GATE" bs=1 seek=$((0xc7f68)) \
    conv=notrunc >/dev/null 2>&1
printf '\232\011\244\162' | dd of="$PRE_HW_GATE" bs=1 seek=$((0xc7f70)) \
    conv=notrunc >/dev/null 2>&1
[ "$(sha256sum "$PRE_HW_GATE" | awk '{ print $1 }')" = ed0bf523023e98a527a3c8f13eecf9d7a037e2fadecc1d8b68cbea9c1a4d5bbc ]
cp "$PRE_HW_GATE" "$TARGET"
status=$(run_helper status)
grep -Fq 'visible_contract=qhd144-pre-hw-gate' <<< "$status"
grep -Fq 'source_hw_limit=09009852,8909a472' <<< "$status"
cp "$PATCHED" "$TARGET"

# The previous deployed payload passed the standalone allowHwOperating gate
# but left irisServiceModeSwitchBypassToPt's strict tuple gate at QHD120. It
# must be accepted as an upgrade source, but never pass the final contract.
PRE_SWITCH_GATE="$TMP/libpwirisservicei7p.pre-switch-gate.so"
cp "$PRE_VIDEO" "$PRE_SWITCH_GATE"
printf '\032\000\230\122' | dd of="$PRE_SWITCH_GATE" bs=1 seek=$((0xc7f68)) \
    conv=notrunc >/dev/null 2>&1
printf '\232\011\244\162' | dd of="$PRE_SWITCH_GATE" bs=1 seek=$((0xc7f70)) \
    conv=notrunc >/dev/null 2>&1
[ "$(sha256sum "$PRE_SWITCH_GATE" | awk '{ print $1 }')" = 730684220fdf74a4be2b01c8cedfce59fefd04aa55b9413b1a46de6fef214180 ]
cp "$PRE_SWITCH_GATE" "$TARGET"
status=$(run_helper status)
grep -Fq 'visible_contract=qhd144-pre-switch-gate' <<< "$status"
grep -Fq 'source_switch_limit=1a009852,9a09a472' <<< "$status"
grep -Fq 'patched_sha256=8b0c6c0361af470978cbfa93f65ed7d58d215fbc2a0c174acbcc3597fdc1fe00' <<< "$status"
cp "$PATCHED" "$TARGET"

# A device already running the previous QHD144-1 boundary payload must be
# upgraded in place instead of being rejected as an unknown vendor library.
cp work/libpwirisservicei7p.rmx5200.memc-gate-qhd144.test.so "$TARGET"
write_mountinfo hymo
status=$(run_helper status)
grep -Fq 'visible_contract=qhd144-minus-one' <<< "$status"
# The production upgrade is installed into system/odm and becomes the final
# metamodule view at the next full boot. This unprivileged fixture proves the
# old view is accepted and the exact replacement payload is selected; online
# bind behavior is covered separately by the mount fixtures above.
grep -Fq 'patched_sha256=8b0c6c0361af470978cbfa93f65ed7d58d215fbc2a0c174acbcc3597fdc1fe00' <<< "$status"
cp "$PATCHED" "$TARGET"

# A renamed or future metamodule still works when its implementation signature
# is unknown: runtime selection depends on the final view, never the ID.
write_mountinfo hymo
make_meta totally_new none
run_helper apply-stable
grep -Fq 'active:metamodule:unknown:totally_new' "$STATE/state.txt"

# Wrong firmware is rejected before any bind or state promotion.
if MEMC_STATE_DIR="$STATE" MEMC_ENABLE_FILE="$ENABLE" \
    MEMC_TARGET_FILE="$TARGET" MEMC_PATCHED_FILE="$PATCHED" \
    MEMC_MOUNTINFO_FILE="$MOUNTINFO" MEMC_PROC_ROOT="$PROC" \
    MEMC_METAMODULE_LINK="$META" MEMC_TEST_MODEL=OTHER \
    MEMC_TEST_FINGERPRINT="$EXPECTED_FINGERPRINT" \
        bash "$SCRIPT" apply-stable; then
    echo 'FAIL: non-RMX5200 firmware was accepted' >&2
    exit 1
fi
grep -Fq 'rejected:firmware_contract' "$STATE/state.txt"

echo 'PASS: RMX5200 Pixelworks MEMC patch is exact and metamodule-independent'
