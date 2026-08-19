#!/bin/sh

set -eu

HANDLER="${1:-scripts/web_handler.sh}"
[ -f "$HANDLER" ] || { echo "FAIL: missing Web handler" >&2; exit 1; }

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' 0 1 2 15
MURONGCHAOPIN_MOD_PATH="$TEST_ROOT/module"
export MURONGCHAOPIN_MOD_PATH

# Load declarations and functions without executing the command dispatcher.
eval "$(sed '/^case "\$1" in$/,$d' "$HANDLER")"

acquire_dtbo_apply_lock || {
    echo "FAIL: first task could not acquire the DTBO lock" >&2
    exit 1
}
FIRST_TOKEN=$DTBO_APPLY_LOCK_TOKEN
[ -s "$DTBO_APPLY_LOCK_DIR/pid" ]
[ -s "$DTBO_APPLY_LOCK_DIR/token" ]

if (acquire_dtbo_apply_lock >/dev/null 2>&1); then
    echo "FAIL: concurrent task acquired the same DTBO workspace lock" >&2
    exit 1
fi

QUIET_LOCK_OUTPUT=$(acquire_dtbo_apply_lock 1 2>&1 || true)
[ -z "$QUIET_LOCK_OUTPUT" ] || {
    echo "FAIL: idempotent start leaked a misleading lock error" >&2
    exit 1
}

DTBO_APPLY_LOCK_TOKEN=$FIRST_TOKEN
release_dtbo_apply_lock
[ ! -e "$DTBO_APPLY_LOCK_DIR" ] || {
    echo "FAIL: completed task left its DTBO lock behind" >&2
    exit 1
}

mkdir -p "$DTBO_APPLY_LOCK_DIR"
printf '99999999\n' > "$DTBO_APPLY_LOCK_DIR/pid"
printf 'stale\n' > "$DTBO_APPLY_LOCK_DIR/token"
acquire_dtbo_apply_lock || {
    echo "FAIL: stale DTBO lock was not recovered" >&2
    exit 1
}
RECOVERED_TOKEN=$DTBO_APPLY_LOCK_TOKEN
[ "$RECOVERED_TOKEN" != stale ]
release_dtbo_apply_lock

grep -q 'setsid sh .* apply_changes_bg' "$HANDLER"
grep -q 'setsid sh .* flash_dtbo_bg' "$HANDLER"
grep -q 'claim_dtbo_apply_lock "\$2"' "$HANDLER"
grep -q 'claim_dtbo_apply_lock "\$3"' "$HANDLER"
grep -q '已有任务，继续读取当前流程' "$HANDLER"
grep -q 'acquire_dtbo_apply_lock 1' "$HANDLER"
grep -q 'dtbo_apply_lock_active' "$HANDLER"

echo "PASS: DTBO apply/flash tasks are serialized and stale locks recover"
