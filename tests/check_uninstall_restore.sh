#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UNINSTALL="$ROOT/uninstall.sh"
WEB="$ROOT/scripts/web_handler.sh"

sh -n "$UNINSTALL"
sh -n "$WEB"

CANCEL_LINE=$(grep -n 'if \[ "$choose_key" = "1" \]' "$UNINSTALL" |
    head -n 1 | cut -d: -f1)
APK_REMOVE_LINE=$(grep -n 'pm uninstall --user 0 com.murongchaopin.displayhook' \
    "$UNINSTALL" | head -n 1 | cut -d: -f1)
[ -n "$CANCEL_LINE" ] && [ -n "$APK_REMOVE_LINE" ] &&
    [ "$CANCEL_LINE" -lt "$APK_REMOVE_LINE" ] || {
    echo 'FAIL: cancelling uninstall can remove the Hook APK' >&2
    exit 1
}

RESTORE_SUCCESS=$(sed -n '/if \[ "$RESTORE_STATUS" -eq 0 \]/,/^else/p' \
    "$UNINSTALL")
printf '%s\n' "$RESTORE_SUCCESS" | grep -q 'restore_runtime_state'
printf '%s\n' "$RESTORE_SUCCESS" |
    grep -q 'pm uninstall --user 0 com.murongchaopin.displayhook'

for contract in \
    'coloros_config.sh" remove' \
    'coloros_config_premium.sh" remove-premium' \
    'libpwiris_memc_gate_patch.sh" restore' \
    'premium_system_overlay.sh" remove' \
    'surfaceflinger_ltpo_rise_patch.sh" restore' \
    'surfaceflinger_vote_patch.sh" restore' \
    'adfr_lock.sh" restore' \
    'generic_adfr_policy.sh" restore'
do
    grep -q "$contract" "$UNINSTALL" || {
        echo "FAIL: uninstall.sh misses runtime restore: $contract" >&2
        exit 1
    }
done

WEB_UNINSTALL=$(sed -n '/"uninstall_module")/,/^[[:space:]]*;;/p' "$WEB")
for contract in \
    '"$COLOROS_CONFIG_HELPER" remove' \
    '"$COLOROS_PREMIUM_HELPER" remove-premium' \
    '"$PREMIUM_SYSTEM_OVERLAY_HELPER" remove' \
    '"$MEMC_GATE_HELPER" restore' \
    '"$SF_RISE_HELPER" restore' \
    '"$SF_VOTE_HELPER" restore' \
    '"$ADFR_LOCK_HELPER" restore' \
    '"$GENERIC_ADFR_HELPER" restore'
do
    printf '%s\n' "$WEB_UNINSTALL" | grep -Fq "$contract" || {
        echo "FAIL: Web uninstall misses runtime restore: $contract" >&2
        exit 1
    }
done
printf '%s\n' "$WEB_UNINSTALL" |
    grep -q 'pm uninstall --user 0 com.murongchaopin.displayhook'
printf '%s\n' "$WEB_UNINSTALL" | grep -q 'touch "$MOD_PATH/remove"'

echo 'PASS: uninstall paths restore all live mounts and preserve cancellation'
