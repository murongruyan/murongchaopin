#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOOK_ROOT="$ROOT/src/settings_hook/java/com/murongchaopin/displayhook"
BRIDGE="$HOOK_ROOT/BridgeClient.java"
SERVICES="$HOOK_ROOT/OplusServicesHooks.java"
VRR="$HOOK_ROOT/OplusVrrTierHooks.java"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

for file in "$BRIDGE" "$SERVICES" "$VRR"; do
    test -f "$file"
done

# 1. The two rate accessors that framework hooks call must only read the
#    volatile snapshot. A reload of WindowManagerGlobalLock must never wait on
#    the bridge daemon.
GLOBAL_RATE_BODY=$(sed -n '/private static int globalRate()/,/^    }/p' "$SERVICES")
test -n "$GLOBAL_RATE_BODY" || fail 'OplusServicesHooks.globalRate is missing'
if printf '%s\n' "$GLOBAL_RATE_BODY" | grep -q 'BridgeClient\.'; then
    fail 'OplusServicesHooks.globalRate still calls BridgeClient on a framework thread'
fi
if printf '%s\n' "$GLOBAL_RATE_BODY" | grep -qE 'requestSocket|Looper'; then
    fail 'OplusServicesHooks.globalRate still performs synchronous bridge I/O'
fi

MODULE_RATE_BODY=$(sed -n '/private static int moduleTargetRate()/,/^    }/p' "$VRR")
test -n "$MODULE_RATE_BODY" || fail 'OplusVrrTierHooks.moduleTargetRate is missing'
if printf '%s\n' "$MODULE_RATE_BODY" | grep -q 'BridgeClient\.'; then
    fail 'OplusVrrTierHooks.moduleTargetRate still calls BridgeClient on a framework thread'
fi
if printf '%s\n' "$MODULE_RATE_BODY" | grep -qE 'requestSocket|Looper'; then
    fail 'OplusVrrTierHooks.moduleTargetRate still performs synchronous bridge I/O'
fi

# 2. ltpoRoute is installed on setDesiredDisplayModeSpecsLocked, getModeId and
#    getFinalDisplayModeIdLocked: it must post the refresh and serve the last
#    known route instead of opening a socket.
LTPO_BODY=$(sed -n '/static LtpoRoute ltpoRoute()/,/^    }/p' "$BRIDGE")
test -n "$LTPO_BODY" || fail 'BridgeClient.ltpoRoute is missing'
if printf '%s\n' "$LTPO_BODY" | grep -qE 'requestSocket|future\.get|Looper'; then
    fail 'BridgeClient.ltpoRoute still performs a synchronous socket round trip'
fi
printf '%s\n' "$LTPO_BODY" | grep -q 'refreshLtpoRouteAsync' \
    || fail 'BridgeClient.ltpoRoute does not post the background refresh'
printf '%s\n' "$LTPO_BODY" | grep -q 'LTPO_HOLD_MS' \
    || fail 'BridgeClient.ltpoRoute lost the last-good-route hold window'
printf '%s\n' "$LTPO_BODY" | grep -q 'murong.ltpo.route.owner' \
    || fail 'BridgeClient.ltpoRoute lost the single-owner gate'

# 3. The refresh machinery itself: one worker thread, at most one request in
#    flight, and a failure backoff so an unavailable daemon is not reconnected
#    once per call.
grep -q 'newSingleThreadExecutor' "$BRIDGE" \
    || fail 'BridgeClient has no single background refresh worker'
grep -q 'FAIL_BACKOFF_MS = 5000L' "$BRIDGE" \
    || fail 'BridgeClient has no failure backoff constant'
grep -q 'AtomicBoolean GLOBAL_RATE_REFRESH' "$BRIDGE" \
    || fail 'BridgeClient does not guard the in-flight global-rate refresh'
grep -q 'AtomicBoolean LTPO_REFRESH' "$BRIDGE" \
    || fail 'BridgeClient does not guard the in-flight LTPO refresh'
grep -q 'static int globalRateSnapshot()' "$BRIDGE" \
    || fail 'BridgeClient has no non-blocking rate snapshot'
grep -qF '"murong.ltpo.route"' "$BRIDGE" \
    || fail 'BridgeClient lost the daemon route property mirror'

RATE_REFRESH_BODY=$(sed -n '/static void refreshGlobalRateAsync()/,/^    }/p' "$BRIDGE")
test -n "$RATE_REFRESH_BODY" || fail 'BridgeClient.refreshGlobalRateAsync is missing'
printf '%s\n' "$RATE_REFRESH_BODY" | grep -q 'WORKER.execute' \
    || fail 'the global-rate refresh does not run on the background worker'
printf '%s\n' "$RATE_REFRESH_BODY" | grep -q 'compareAndSet(false, true)' \
    || fail 'the global-rate refresh is not limited to one request in flight'
printf '%s\n' "$RATE_REFRESH_BODY" | grep -q 'FAIL_BACKOFF_MS' \
    || fail 'the global-rate refresh ignores the failure backoff'
printf '%s\n' "$RATE_REFRESH_BODY" | grep -q 'requestSocket("GETGLOBAL"' \
    || fail 'the global-rate refresh does not read GETGLOBAL on the worker'

LTPO_REFRESH_BODY=$(sed -n '/static void refreshLtpoRouteAsync/,/^    }/p' "$BRIDGE")
test -n "$LTPO_REFRESH_BODY" || fail 'BridgeClient.refreshLtpoRouteAsync is missing'
printf '%s\n' "$LTPO_REFRESH_BODY" | grep -q 'WORKER.execute' \
    || fail 'the LTPO refresh does not run on the background worker'
printf '%s\n' "$LTPO_REFRESH_BODY" | grep -q 'compareAndSet(false, true)' \
    || fail 'the LTPO refresh is not limited to one request in flight'
printf '%s\n' "$LTPO_REFRESH_BODY" | grep -q 'FAIL_BACKOFF_MS' \
    || fail 'the LTPO refresh ignores the failure backoff'
printf '%s\n' "$LTPO_REFRESH_BODY" | grep -q 'requestSocket("GETLTPO"' \
    || fail 'the LTPO refresh does not read GETLTPO on the worker'

# 4. BridgeClient stays the only place in the Hook that opens the bridge
#    socket; a hook class may never dial the daemon on its own thread.
for file in "$HOOK_ROOT"/*.java; do
    case "$file" in
        *BridgeClient.java) continue ;;
    esac
    if grep -qE 'requestSocket|new Socket\(' "$file"; then
        fail "$(basename "$file") performs its own socket round trip"
    fi
done

# 5. The paid Hook ships these same framework-thread paths from its own
#    checkout (both Hook packages are installed on an authorised device). When
#    that checkout is present next to this one, hold it to the same contract.
PREMIUM_HOOK_ROOT="$ROOT/../murongchaopin-premium/src/settings_hook/java/com/murongchaopin/displayhook"
if [ -d "$PREMIUM_HOOK_ROOT" ]; then
    PREMIUM_SERVICES="$PREMIUM_HOOK_ROOT/OplusServicesHooks.java"
    PREMIUM_VRR="$PREMIUM_HOOK_ROOT/OplusVrrTierHooks.java"
    PREMIUM_BRIDGE="$PREMIUM_HOOK_ROOT/BridgeClient.java"
    for file in "$PREMIUM_SERVICES" "$PREMIUM_VRR" "$PREMIUM_BRIDGE"; do
        test -f "$file"
    done
    if sed -n '/private static int globalRate()/,/^    }/p' "$PREMIUM_SERVICES" |
            grep -q 'BridgeClient\.'; then
        fail 'paid OplusServicesHooks.globalRate still calls BridgeClient on a framework thread'
    fi
    if sed -n '/private static int moduleTargetRate()/,/^    }/p' "$PREMIUM_VRR" |
            grep -q 'BridgeClient\.'; then
        fail 'paid OplusVrrTierHooks.moduleTargetRate still calls BridgeClient'
    fi
    grep -q 'FAIL_BACKOFF_MS' "$PREMIUM_BRIDGE" ||
        fail 'paid BridgeClient has no failure backoff'
    grep -q 'globalRateSnapshot' "$PREMIUM_BRIDGE" ||
        fail 'paid BridgeClient has no non-blocking rate snapshot'
    grep -q 'pushForegroundApp' "$PREMIUM_SERVICES" ||
        fail 'paid Hook never pushes the foreground package'
fi

echo 'PASS: no Hook reaches the bridge daemon from a framework thread'
