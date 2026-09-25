#!/bin/sh
# ColorOS 17 builds the hmbird governor into the kernel, so the DTBO node the
# module used to insert is already covered.  The C17 DTBO also dropped the
# oplus_sim_detect anchor, which made process_dts --hmbird-only fail and took
# the whole install down with it.  The backend must therefore look for the
# governor first and leave the partition alone when it is there.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BACKEND="$ROOT/scripts/hmbird_backend.sh"
INSTALLER="$ROOT/customize.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# 1) The governor is listed -> skip, and the helper says so without touching
#    anything.
printf 'walt conservative powersave performance schedutil hmbird\n' > "$WORK/govs"
if ! HMBIRD_GOVERNOR_FILES="$WORK/govs" HMBIRD_VENDOR_NODE="$WORK/absent" \
        sh "$BACKEND" governor-present; then
    fail "a listed hmbird governor was not detected"
fi
out=$(HMBIRD_GOVERNOR_FILES="$WORK/govs" HMBIRD_VENDOR_NODE="$WORK/absent" \
    sh "$BACKEND" prepare-dtbo /dev/null 2>&1) ||
    fail "prepare-dtbo failed instead of skipping"
printf '%s' "$out" | grep -q 'DTBO left untouched' ||
    fail "skip was not reported: $out"
printf '%s' "$out" | grep -q 'oplus_sim_detect' &&
    fail "skip path still tried to patch the DTBO"

# 2) No governor and no vendor node -> the old path still runs, i.e. the check
#    does not disable the feature on devices that need it.
printf 'walt conservative powersave performance schedutil\n' > "$WORK/govs_plain"
if HMBIRD_GOVERNOR_FILES="$WORK/govs_plain" HMBIRD_VENDOR_NODE="$WORK/absent" \
        sh "$BACKEND" governor-present; then
    fail "governor reported present on a kernel without it"
fi

# 3) The vendor node alone is enough.
: > "$WORK/vendor_node"
HMBIRD_GOVERNOR_FILES="$WORK/govs_plain" HMBIRD_VENDOR_NODE="$WORK/vendor_node" \
    sh "$BACKEND" governor-present ||
    fail "vendor hmbird node was not detected"

# 4) The installer has to branch on that check instead of always generating a
#    companion DTBO.
grep -q 'hmbird_backend.sh" governor-present' "$INSTALLER" ||
    fail "installer does not ask whether the governor is already present"
grep -q '无需修改 DTBO' "$INSTALLER" ||
    fail "installer does not report the skip"

sh -n "$BACKEND"
sh -n "$INSTALLER"

echo 'hmbird governor skip checks passed'