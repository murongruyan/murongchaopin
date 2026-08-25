#!/usr/bin/env bash
set -euo pipefail

root="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
work="${RUNNER_TEMP:-$root/work}/murong-free-kernel"
rm -rf "$work"
mkdir -p "$work"

rmx_repo="https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8850.git"
rmx_commit="d9053b907db4bb5da938e9cf947d0ae32302ceaf"
rmx_release="6.12.23-android16-5-gb2a876903b49-ab14541642-4k"
pjd_repo="https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8650.git"
pjd_commit="d86625c3830b59553b4db6b1b383fddd9655cabf"
pjd_vendor_repo="https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8650.git"
pjd_vendor_commit="c1ec0629b3f9bb245577e65f1ed70d5a371e4b9b"
pjd_release="6.1.141-gd86625c3830b"

download_tree() {
  local url="$1" archive="$2" destination="$3" unpack="$3.unpacked"
  rm -rf "$destination" "$unpack"
  mkdir -p "$unpack"
  aria2c -s16 -x16 -k1M "$url" -o "$archive" -d "$work"
  unzip -q "$work/$archive" -d "$unpack"
  local source
  source=$(find "$unpack" -mindepth 1 -maxdepth 1 -type d -print -quit)
  test -n "$source"
  mv "$source" "$destination"
  rm -rf "$unpack" "$work/$archive"
}

download_toolchain() {
  local url="$1" archive="$2" destination="$3"
  rm -rf "$destination"
  mkdir -p "$destination"
  aria2c -s16 -x16 -k1M "$url" -o "$archive" -d "$work"
  unzip -q "$work/$archive" -d "$destination"
  rm -f "$work/$archive"
}

ensure_module_protect_list() {
  local tree="$1" config="$2" protect_list
  protect_list=$(sed -n 's/^CONFIG_MODULE_SIG_PROTECT_LIST="\([^" ]*\)"$/\1/p' "$config")
  [ -n "$protect_list" ] || return 0
  case "$protect_list" in
    */*|*..*) echo "unsafe CONFIG_MODULE_SIG_PROTECT_LIST: $protect_list" >&2; exit 1 ;;
  esac
  : > "$tree/$protect_list"
}

download_tree "${rmx_repo%.git}/archive/$rmx_commit.zip" rmx.zip "$work/rmx-tree"
download_toolchain 'https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225/clang-r536225.zip' clang19.zip "$work/clang19"
download_toolchain 'https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225/build-tools.zip' build-tools19.zip "$work/build-tools19"
download_tree "${pjd_repo%.git}/archive/$pjd_commit.zip" pjd.zip "$work/pjd-tree"
download_tree "${pjd_vendor_repo%.git}/archive/$pjd_vendor_commit.zip" pjd-vendor.zip "$work/pjd-vendor"
download_toolchain 'https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang20-r547379/clang-r547379.zip' clang20.zip "$work/clang20"
download_toolchain 'https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang20-r547379/build-tools.zip' build-tools20.zip "$work/build-tools20"

prepare_rmx() {
  local tree="$1" out="$2" clang="$3" tools="$4" config="$5"
  rm -rf "$out"
  mkdir -p "$out"
  export PATH="$clang:$tools:$PATH" LLVM=1 LLVM_IAS=1 ARCH=arm64 LOCALVERSION=
  export CC=clang HOSTCC=clang LD=ld.lld HOSTLD=ld.lld
  cp "$config" "$out/.config"
  local base target
  base=$(make -s -C "$tree" O="$out" ARCH=arm64 LLVM=1 LLVM_IAS=1 kernelversion)
  target="${rmx_release#"$base"}"
  grep -q '^CONFIG_LOCALVERSION=' "$out/.config" && sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"$target\"|" "$out/.config" || printf 'CONFIG_LOCALVERSION="%s"\n' "$target" >> "$out/.config"
  grep -q '^CONFIG_LOCALVERSION_AUTO=' "$out/.config" && sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|CONFIG_LOCALVERSION_AUTO=n|' "$out/.config" || printf 'CONFIG_LOCALVERSION_AUTO=n\n' >> "$out/.config"
  make -C "$tree" O="$out" CC=clang HOSTCC=clang olddefconfig
  ensure_module_protect_list "$tree" "$out/.config"
  make -C "$tree" O="$out" CC=clang HOSTCC=clang modules_prepare
  local release
  release=$(make -s -C "$tree" O="$out" LOCALVERSION= kernelrelease)
  test "$release" = "$rmx_release"
  node "$root/tools/build_rmx5200_symvers.mjs" --contract "$root/config/kernel/rmx5200-6.12.23-android16-5-gb2a876903b49-ab14541642-4k.ko-abi.json" --output "$out/Module.symvers"
  test -s "$out/Module.symvers"
}

prepare_pjd_layout() {
  local tree="$1" vendor="$2"
  test -d "$tree/kernel" -a -d "$vendor/vendor/oplus/kernel/cpu"
  if [ -L "$tree/vendor" ]; then
    [ "$(readlink "$tree/vendor")" = "$vendor/vendor" ] || { echo "unexpected PJD110 vendor link" >&2; exit 1; }
  elif [ -e "$tree/vendor" ]; then
    echo "PJD110 common tree already contains a non-link vendor path" >&2
    exit 1
  else
    ln -s "$vendor/vendor" "$tree/vendor"
  fi
  normalize_link() {
    local link="$1" target="$2"
    if [ -L "$link" ]; then
      [ "$(readlink "$link")" = "$target" ] || { rm -f "$link"; ln -s "$target" "$link"; }
    elif [ -e "$link" ]; then
      return 0
    else
      ln -s "$target" "$link"
    fi
  }
  normalize_link "$tree/kernel/oplus_cpu" "../vendor/oplus/kernel/cpu"
  normalize_link "$tree/drivers/soc/oplus/oplus_resctrl" "../../../vendor/oplus/kernel/oplus_performance_5.10/oplus_resctrl"
  normalize_link "$tree/drivers/soc/oplus/storage" "../../../vendor/oplus/kernel/storage"
  test -f "$tree/kernel/oplus_cpu/sched/Kconfig"
  test -f "$vendor/vendor/vendor/qcom/opensource/display-drivers/msm/dsi/dsi_display.h"
}

prepare_pjd() {
  local tree="$1" out="$2" clang="$3" tools="$4" config="$5"
  rm -rf "$out"
  mkdir -p "$out"
  export PATH="$clang:$tools:$PATH" LLVM=1 LLVM_IAS=1 ARCH=arm64 LOCALVERSION=
  export CC=clang HOSTCC=clang LD=ld.lld HOSTLD=ld.lld
  make -C "$tree" O="$out" CC=clang HOSTCC=clang gki_defconfig
  "$tree/scripts/kconfig/merge_config.sh" -m -r "$out/.config" "$config"
  grep -q '^CONFIG_LOCALVERSION=' "$out/.config" && sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="-gd86625c3830b"|' "$out/.config" || printf 'CONFIG_LOCALVERSION="-gd86625c3830b"\n' >> "$out/.config"
  grep -q '^CONFIG_LOCALVERSION_AUTO=' "$out/.config" && sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|CONFIG_LOCALVERSION_AUTO=n|' "$out/.config" || printf 'CONFIG_LOCALVERSION_AUTO=n\n' >> "$out/.config"
  make -C "$tree" O="$out" CC=clang HOSTCC=clang olddefconfig
  ensure_module_protect_list "$tree" "$out/.config"
  make -C "$tree" O="$out" CC=clang HOSTCC=clang modules_prepare
  local release
  release=$(make -s -C "$tree" O="$out" LOCALVERSION= kernelrelease)
  test "$release" = "$pjd_release"
  node "$root/tools/build_pjd110_symvers.mjs" --contract "$root/config/kernel/pjd110-6.1.141-gd86625c3830b.ko-abi.json" --output "$out/Module.symvers"
  test -s "$out/Module.symvers"
}

rm -f "$root/bin/rmx5200_drm_modes.ko" "$root/bin/plk110_drm_modes.ko" "$root/bin/pjd110_drm_modes.ko"
mkdir -p "$root/bin"

prepare_rmx "$work/rmx-tree" "$work/rmx-out" "$work/clang19/bin" "$work/build-tools19/bin" "$root/config/kernel/rmx5200-6.12.23-android16-5-gb2a876903b49-ab14541642-4k.config"
export KERNEL_TREE="$work/rmx-tree" KERNEL_OUT="$work/rmx-out" KERNEL_SYMVERS="$work/rmx-out/Module.symvers" LLVM_TOOLS="$work/clang19/bin" OUT_DIR="$root/bin"
sh "$root/src/ko/build.sh" rmx5200
sh "$root/src/ko/build.sh" plk110

prepare_pjd_layout "$work/pjd-tree" "$work/pjd-vendor"
prepare_pjd "$work/pjd-tree" "$work/pjd-out" "$work/clang20/bin" "$work/build-tools20/bin" "$root/config/kernel/pjd110-6.1.141-gd86625c3830b.config"
export KERNEL_TREE="$work/pjd-tree" KERNEL_OUT="$work/pjd-out" KERNEL_SYMVERS="$work/pjd-out/Module.symvers" LLVM_TOOLS="$work/clang20/bin" PJD_KERNEL_TREE="$work/pjd-tree" PJD_KERNEL_OUT="$work/pjd-out" PJD_DISPLAY_ROOT="$work/pjd-vendor/vendor/vendor/qcom/opensource/display-drivers" OUT_DIR="$root/bin"
sh "$root/src/ko/build.sh" pjd110

for ko in "$root/bin/rmx5200_drm_modes.ko" "$root/bin/plk110_drm_modes.ko" "$root/bin/pjd110_drm_modes.ko"; do
  test -s "$ko"
done
