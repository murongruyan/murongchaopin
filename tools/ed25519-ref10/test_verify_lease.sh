#!/bin/sh
# test_verify_lease.sh - build and run verify_lease_sig against golden vectors.
# Runs in WSL/Linux (gcc) and on-device (already built binary, optional).
set -eu

TOOL_DIR=$(cd "$(dirname "$0")" && pwd)
GOLDEN_DIR="${GOLDEN_DIR:-$TOOL_DIR/golden}"
BIN="${BIN:-$TOOL_DIR/build/verify_lease_sig}"

failures=0

check_case() {
    name="$1"; expected="$2"; payload="$3"; signature="$4"
    pubkey=$(tr -d '\r\n' < "$GOLDEN_DIR/public.hex")
    signature_hex=$(tr -d '\r\n' < "$signature")
    if "$BIN" "$pubkey" "$payload" "$signature_hex" >/dev/null 2>&1; then
        actual=0
    else
        rc=$?
        actual=$rc
    fi
    if [ "$actual" = "$expected" ]; then
        echo "PASS $name"
    else
        echo "FAIL $name (expected exit $expected, got $actual)"
        failures=$((failures + 1))
    fi
}

if [ "${1:-}" = "device" ]; then
    echo "device mode: BIN must already be built for the target device"
fi

[ -x "$BIN" ] || {
    mkdir -p "$TOOL_DIR/build"
    echo "building $BIN with cc..."
    cc -O2 -o "$BIN" \
        "$TOOL_DIR/verify_lease_sig.c" \
        "$TOOL_DIR/add_scalar.c" \
        "$TOOL_DIR/fe.c" \
        "$TOOL_DIR/ge.c" \
        "$TOOL_DIR/key_exchange.c" \
        "$TOOL_DIR/keypair.c" \
        "$TOOL_DIR/sc.c" \
        "$TOOL_DIR/seed.c" \
        "$TOOL_DIR/sha512.c" \
        "$TOOL_DIR/sign.c" \
        "$TOOL_DIR/verify.c"
}

[ -f "$GOLDEN_DIR/public.hex" ] || {
    echo "generating golden vectors..."
    node "$TOOL_DIR/gen_golden.mjs" "$GOLDEN_DIR"
}

check_case "valid-signature"     0 "$GOLDEN_DIR/case-ok/payload.bin"       "$GOLDEN_DIR/case-ok/signature.hex"
check_case "tampered-payload"    1 "$GOLDEN_DIR/case-tampered/payload.bin" "$GOLDEN_DIR/case-tampered/signature.hex"
check_case "wrong-key"           1 "$GOLDEN_DIR/case-otherkey/payload.bin" "$GOLDEN_DIR/case-otherkey/signature.hex"
# Empty payload signed by nobody must fail: reuse tampered sig against /dev/null
if [ -f /dev/null ]; then
    check_case "empty-payload-reject" 1 /dev/null "$GOLDEN_DIR/case-ok/signature.hex"
fi
# Malformed public key must exit 2
if "$BIN" "deadbeef" "$GOLDEN_DIR/case-ok/payload.bin" "$(cat "$GOLDEN_DIR/case-ok/signature.hex")" >/dev/null 2>&1; then
    echo "FAIL malformed-key (expected exit 2)"
    failures=$((failures + 1))
else
    rc=$?
    if [ "$rc" = 2 ]; then
        echo "PASS malformed-key"
    else
        echo "FAIL malformed-key (expected exit 2, got $rc)"
        failures=$((failures + 1))
    fi
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$failures FAILURE(S)"
    exit 1
fi
