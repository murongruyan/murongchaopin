#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export MURONGCHAOPIN_MOD_PATH="$ROOT_DIR"
. "$ROOT_DIR/scripts/display_license_gate.sh"

MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

expect_match() {
    _test_name=$1
    _test_kernel=$2
    gate_list_matches_pattern "$MANIFEST" supported_kernels "$_test_kernel" || fail "$_test_name"
}

expect_reject() {
    _test_name=$1
    _test_kernel=$2
    if gate_list_matches_pattern "$MANIFEST" supported_kernels "$_test_kernel"; then
        fail "$_test_name"
    fi
}

printf '%s\n' '{"supported_kernels":["6.12","6.1"]}' > "$MANIFEST"
[ "$(gate_json_array_values "$MANIFEST" supported_kernels)" = "6.12 6.1" ] || fail "compact array separators"
expect_match "6.12 release prefix" "6.12.23-android16-5-gb2a876903b49-ab14541642-4k"
expect_match "6.1 release prefix" "6.1.141-gd86625c3830b"
expect_reject "version boundary rejects 6.126" "6.126.0-test"
expect_reject "unsupported 5.15 kernel" "5.15.167-android14"

printf '%s\n' '{"supported_kernels": ["6.12.*"]}' > "$MANIFEST"
expect_match "wildcard kernel" "6.12.23-test"
expect_reject "wildcard boundary" "6.13.0-test"

printf '%s\n' '{"supported_kernels":[]}' > "$MANIFEST"
expect_reject "empty kernel list" "6.12.23-test"
printf '%s\n' '{"supported_kernels":' > "$MANIFEST"
expect_reject "malformed kernel list" "6.12.23-test"

echo "package kernel compatibility tests passed"
