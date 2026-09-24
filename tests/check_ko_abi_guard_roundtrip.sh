#!/bin/sh
# Round-trip regression for the device-side kernel symbol contract guard.
#
# Adapting a module renames every version entry the running kernel cannot
# resolve, so the kernel treats those imports as unversioned.  check has to
# recognise that rename as the guard's own work: without it an already adapted
# module keeps reporting unresolved entries, so the round trip never settles
# and a cached adaptation looks like a module with missing symbols.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

guard=${KO_ABI_GUARD_BIN:-}
if [ -z "$guard" ]; then
    for candidate in "$ROOT_DIR/build/bin/ko_abi_guard" "$ROOT_DIR/bin/ko_abi_guard"; do
        if [ -x "$candidate" ]; then
            guard=$candidate
            break
        fi
    done
fi
if [ -z "$guard" ] || [ ! -x "$guard" ]; then
    echo "ko abi guard round-trip checks skipped (no ko_abi_guard binary)"
    exit 0
fi

module=
for candidate in \
    "$ROOT_DIR/bin/rmx5200_drm_modes.ko" \
    "$ROOT_DIR/bin/plq110_drm_modes.ko" \
    "$ROOT_DIR/bin/plk110_drm_modes.ko" \
    "$ROOT_DIR/bin/pjd110_drm_modes.ko"; do
    if [ -f "$candidate" ]; then
        module=$candidate
        break
    fi
done
if [ -z "$module" ]; then
    echo "ko abi guard round-trip checks skipped (no shipped kernel module)"
    exit 0
fi

: > "$WORK_DIR/empty-contract.txt"
: > "$WORK_DIR/empty-providers.txt"

# The guard lists every import it cannot resolve; for this module that list is
# exactly what the running kernel offers, so it doubles as the provider set.
"$guard" check --contract "$WORK_DIR/empty-contract.txt" \
    --providers "$WORK_DIR/empty-providers.txt" "$module" \
    > "$WORK_DIR/imports.txt" 2>&1 || true
# contract_load_file() only accepts "<name><TAB><hex>", so the collected names
# have to be written in that shape; a bare name is skipped silently.
awk '/^IMPORT symbol=/ {sub(/^IMPORT symbol=/, ""); sub(/ .*/, ""); print $0 "\t1"}' \
    "$WORK_DIR/imports.txt" | sort -u > "$WORK_DIR/providers.txt"
[ -s "$WORK_DIR/providers.txt" ] ||
    fail "guard reported no imports for $(basename "$module")"

"$guard" patch --contract "$WORK_DIR/empty-contract.txt" \
    --providers "$WORK_DIR/providers.txt" \
    --output "$WORK_DIR/adapted.ko" "$module" > "$WORK_DIR/patch.txt" 2>&1 ||
    fail "adapting $(basename "$module") failed"
[ -s "$WORK_DIR/adapted.ko" ] || fail "adapting produced no output"
cmp -s "$module" "$WORK_DIR/adapted.ko" &&
    fail "adapting an unverifiable module changed nothing"

"$guard" check --contract "$WORK_DIR/empty-contract.txt" \
    --providers "$WORK_DIR/providers.txt" \
    "$WORK_DIR/adapted.ko" > "$WORK_DIR/check.txt" 2>&1 ||
    fail "the adapted module no longer verifies: $(tail -n 2 "$WORK_DIR/check.txt" | tr '\n' ' ')"
grep -q '^KO_ABI_CHECK=PASS$' "$WORK_DIR/check.txt" ||
    fail "the adapted module did not settle on PASS: $(tail -n 2 "$WORK_DIR/check.txt" | tr '\n' ' ')"
grep -q 'action=already-neutralised' "$WORK_DIR/check.txt" ||
    fail "the neutralised version marker was not recognised"

echo "ko abi guard round-trip checks passed"