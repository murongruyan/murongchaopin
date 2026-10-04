#!/bin/sh
# Contract test for the v2.9.42 jank fixes.  Every assertion here corresponds to
# a defect proven from a field bugpack on 2026-10-05:
#
#   * the periodic dumpsys window holds WindowManagerGlobalLock inside
#     system_server, and the system gesture listener needs that same lock
#     (field ANR: "Input dispatching timed out ... Waited 5000ms for
#     MotionEvent", gesture thread blocked on the lock);
#   * the refresh-ladder verification re-dumped SurfaceFlinger every 100-150ms;
#   * every ladder step re-issued the live mode before the target, doubling the
#     SurfaceFlinger transactions of the common case;
#   * a switching burst (gesture navigation / recents) ran one full ladder per
#     intermediate foreground change.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DAEMON=src/rate_daemon.c
PREMIUM=../murongchaopin-premium/src/rate_daemon.c

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[ -f "$DAEMON" ] || fail "$DAEMON is missing"

# 1. The daemon must prefer the Hook-pushed foreground package, and must not
#    dump the window manager while that push is fresh.
grep -q 'FOREGROUND_PUSH_FRESH_MS' "$DAEMON" ||
    fail "no foreground push freshness window"
grep -q 'note_pushed_foreground_app' "$DAEMON" ||
    fail "no foreground push entry point"
grep -q 'strncmp(trim(request), "FRONTAPP ", 9)' "$DAEMON" ||
    fail "bridge does not accept FRONTAPP"
# The push must be consulted before the cached dumpsys answer.
awk '/^void get_foreground_app\(char \*buffer, int size\) \{/,/^\}/' "$DAEMON" |
    grep -q 'pushed_foreground_pkg\[0\]' ||
    fail "get_foreground_app ignores the pushed package"

# The push is only sent when the foreground app changes, so the pushed answer
# must also become the cached answer: otherwise the daemon forgets it when the
# freshness window expires and goes back to polling for a package it knows.
awk '/^static void note_pushed_foreground_app/,/^}/' "$DAEMON" |
    grep -q 'foreground_cached_pkg' ||
    fail "the pushed package is not published as the cached answer"
grep -q 'FOREGROUND_PUSH_RECONCILE_MS' "$DAEMON" ||
    fail "no slow reconciliation cadence once the Hook owns the answer"
awk '/^void get_foreground_app\(char \*buffer, int size\) \{/,/^\}/' "$DAEMON" |
    grep -q 'foreground_push_seen' ||
    fail "the window query ignores that the Hook owns the answer"

# 2. A device that proves the window dump is slow must be asked less often.
grep -q 'FOREGROUND_APP_SLOW_CACHE_MS' "$DAEMON" ||
    fail "no slow-dump backoff for the foreground query"
grep -q 'FOREGROUND_APP_SLOW_DUMP_MS' "$DAEMON" ||
    fail "no slow-dump threshold"

# 3. Mode verification samples are deliberate and bounded.  Verifying from the
#    cache would let one reading confirm itself, so the fix bounds the sample
#    count instead of the cache.
grep -q 'sample_system_mode_now' "$DAEMON" ||
    fail "no unconditional mode sampler"
awk '/^static int wait_for_active_mode/,/^\}/' "$DAEMON" |
    grep -q 'sample_system_mode_now();' ||
    fail "verification loop does not sample the mode"
if awk '/^static int wait_for_active_mode/,/^\}/' "$DAEMON" |
        grep -q 'int active_id = get_current_system_mode();'; then
    fail "verification loop still reads the cached mode"
fi
awk '/^static int wait_for_active_mode/,/^\}/' "$DAEMON" |
    grep -q 'samples < SYSTEM_MODE_VERIFY_MAX_SAMPLES' ||
    fail "verification sample count is unbounded"
grep -q 'SYSTEM_MODE_VERIFY_INTERVAL_MS' "$DAEMON" ||
    fail "verification interval constant missing"

# 4. The ladder must try the target first and only re-align on a failed
#    verification.  The old unconditional re-issue is what doubled the
#    transactions per step.
if grep -q 'SF_SELF_POLICY_TRUST_MS' "$DAEMON"; then
    fail "the old unconditional align transaction is back"
fi
awk '/^static int commit_refresh_step/,/^\}/' "$DAEMON" |
    grep -q 'target_applied' ||
    fail "ladder step does not track the target transaction"
awk '/^static int commit_refresh_step/,/^\}/' "$DAEMON" |
    grep -q 'Refresh ladder aligns stale policy' ||
    fail "ladder step lost the stale-policy recovery path"

# 5. A foreground switching burst must settle before the ladder runs.
grep -q 'APP_CHANGE_SETTLE_MS' "$DAEMON" ||
    fail "no foreground settle window"
grep -q 'if (monotonic_ms() < app_settle_until_ms) continue;' "$DAEMON" ||
    fail "foreground settle window is never applied"

# 6. The system_server Hook must actually push it. Without the push the daemon
#    falls back to the window dump this release exists to avoid.
grep -q 'pushForegroundApp' \
        src/settings_hook/java/com/murongchaopin/displayhook/OplusServicesHooks.java ||
    fail "the system_server Hook never pushes the foreground package"

# 7. The paid daemon ships from the same core and must carry the same fixes.
if [ -f "$PREMIUM" ]; then
    for marker in FOREGROUND_PUSH_FRESH_MS FOREGROUND_PUSH_RECONCILE_MS \
            foreground_push_seen note_pushed_foreground_app \
            sample_system_mode_now SYSTEM_MODE_VERIFY_MAX_SAMPLES \
            target_applied APP_CHANGE_SETTLE_MS 'FRONTAPP '; do
        grep -q "$marker" "$PREMIUM" ||
            fail "premium daemon is missing $marker"
    done
    if grep -q 'SF_SELF_POLICY_TRUST_MS' "$PREMIUM"; then
        fail "premium daemon still has the old align transaction"
    fi
fi

echo "PASS: daemon hot path avoids window dumps and ladder double transactions"
