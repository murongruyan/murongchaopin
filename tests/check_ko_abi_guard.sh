#!/bin/sh
# Offline tests for scripts/ko_abi_guard.sh: the guard must insmod the shipped
# module when the symbol contract matches, insmod an adapted copy when only the
# recorded CRCs drifted, refuse a module whose symbols are gone, and fall back
# to the previous behaviour when the guard cannot describe this kernel.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/runtime"

# The guard shells out to insmod; record what it would have loaded.
insmod() {
    printf '%s\n' "$1" >> "$WORK_DIR/insmod.txt"
    [ "${FAKE_INSMOD_RC:-0}" -eq 0 ] || return "$FAKE_INSMOD_RC"
    return 0
}

cat > "$WORK_DIR/bin/ko_abi_guard" <<'STUB'
#!/bin/sh
cmd=$1
shift
echo "$cmd" >> "$FAKE_CALLS"
case "$cmd" in
scan)
    out=
    providers=
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --out) out=$2; shift 2 ;;
        --out-providers) providers=$2; shift 2 ;;
        *) shift ;;
        esac
    done
    printf 'module_layout\t0x797f2b3e\n' > "$out"
    printf 'dsi_panel_tx_cmd_set\t1\n' > "$providers"
    echo "CONTRACT_MODULES=1"
    echo "CONTRACT_SYMBOLS=1"
    exit 0
    ;;
check)
    case "${FAKE_CHECK_RC:-0}" in
    0)
        echo "KO_ABI_CHECK=PASS"
        exit 0
        ;;
    3)
        echo "ENTRY symbol=module_layout ko=0xe976b219 device=0x797f2b3e action=patch"
        echo "KO_ABI_CHECK=NEEDS_PATCH"
        echo "reason=CRC_CONTRACT_DRIFT patched=1 neutralised=0 unresolved=0"
        exit 3
        ;;
    *)
        echo "IMPORT symbol=gone present=no"
        echo "KO_ABI_CHECK=FAIL"
        echo "reason=FAIL_MISSING_SYMBOL count=1"
        exit 1
        ;;
    esac
    ;;
patch)
    out=
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --output) out=$2; shift 2 ;;
        *) shift ;;
        esac
    done
    echo "adapted" > "$out"
    exit 0
    ;;
esac
exit 2
STUB
chmod 0755 "$WORK_DIR/bin/ko_abi_guard"

KO_ABI_MOD_DIR="$WORK_DIR"
KO_ABI_BIN="$WORK_DIR/bin/ko_abi_guard"
KO_ABI_STATE_DIR="$WORK_DIR/runtime/ko_abi"
KO_ABI_LOG_FILE="$WORK_DIR/daemon.log"
FAKE_CALLS="$WORK_DIR/calls.txt"
FAKE_CHECK_RC=0
FAKE_INSMOD_RC=0
export KO_ABI_MOD_DIR KO_ABI_BIN KO_ABI_STATE_DIR KO_ABI_LOG_FILE FAKE_CALLS
export FAKE_CHECK_RC FAKE_INSMOD_RC

. "$ROOT_DIR/scripts/ko_abi_guard.sh"

printf 'module\n' > "$WORK_DIR/fake.ko"

# 1) Matching contract: load the shipped file unchanged.
FAKE_CHECK_RC=0
ko_abi_insmod "$WORK_DIR/fake.ko" fake_module >/dev/null 2>&1 || fail "verified load failed"
[ "$KO_ABI_RESOLVED" = "$WORK_DIR/fake.ko" ] || fail "verified load used $KO_ABI_RESOLVED"
grep -qx "$WORK_DIR/fake.ko" "$WORK_DIR/insmod.txt" || fail "shipped module was not insmod-ed"
grep -q "fake_module loaded:verified" "$KO_ABI_STATE_DIR/status.txt" || fail "missing verified status"

# 2) CRC drift: an adapted copy is written and that copy is insmod-ed.
FAKE_CHECK_RC=3
: > "$WORK_DIR/insmod.txt"
ko_abi_insmod "$WORK_DIR/fake.ko" fake_module >/dev/null 2>&1 || fail "adapted load failed"
case "$KO_ABI_RESOLVED" in
"$KO_ABI_STATE_DIR"/*) ;;
*) fail "adapted load did not use a runtime copy ($KO_ABI_RESOLVED)" ;;
esac
[ -f "$KO_ABI_RESOLVED" ] || fail "adapted copy was not written"
grep -qx "$KO_ABI_RESOLVED" "$WORK_DIR/insmod.txt" || fail "adapted copy was not insmod-ed"
grep -q "fake_module loaded:adapted" "$KO_ABI_STATE_DIR/status.txt" || fail "missing adapted status"

# The contract is built once per boot and reused afterwards.
[ "$(grep -c '^scan$' "$FAKE_CALLS")" = "1" ] || fail "contract was rescanned"

# 3) A missing symbol must skip the module instead of force-loading it.
FAKE_CHECK_RC=1
: > "$WORK_DIR/insmod.txt"
if ko_abi_insmod "$WORK_DIR/fake.ko" fake_module >/dev/null 2>&1; then
    fail "module with missing symbols was loaded"
fi
[ ! -s "$WORK_DIR/insmod.txt" ] || fail "rejected module reached insmod"
grep -q "fake_module skipped:abi_rejected:FAIL_MISSING_SYMBOL" "$KO_ABI_STATE_DIR/status.txt" ||
    fail "missing rejected status"

# 4) No guard binary: keep the previous behaviour instead of blocking the load.
KO_ABI_BIN="$WORK_DIR/bin/does-not-exist"
: > "$WORK_DIR/insmod.txt"
ko_abi_insmod "$WORK_DIR/fake.ko" fake_module >/dev/null 2>&1 || fail "unverified fallback failed"
[ "$KO_ABI_RESOLVED" = "$WORK_DIR/fake.ko" ] || fail "fallback did not use the shipped module"

# 5) insmod failure is reported with the plan that was used.
KO_ABI_BIN="$WORK_DIR/bin/ko_abi_guard"
FAKE_CHECK_RC=0
FAKE_INSMOD_RC=19
if ko_abi_insmod "$WORK_DIR/fake.ko" fake_module >/dev/null 2>&1; then
    fail "insmod failure was reported as success"
fi
grep -q "fake_module insmod_failed:verified:19" "$KO_ABI_STATE_DIR/status.txt" ||
    fail "missing insmod failure status"

echo "ko abi guard tests passed"
